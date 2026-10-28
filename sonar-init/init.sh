#!/bin/sh
# Deja SonarQube conectado con Jenkins. Corre en cada `docker compose up`:
# lo que ya está hecho lo salta.
set -eu
SONAR=http://sonarqube:9000
TOKEN_FILE=/secrets/sonar_token

echo "> Esperando a SonarQube..."
until curl -fs "$SONAR/api/system/status" | grep -q '"status":"UP"'; do sleep 5; done

# admin/admin solo funciona la primera vez
if curl -fs -u admin:admin -X POST "$SONAR/api/users/change_password" \
    --data-urlencode login=admin \
    --data-urlencode previousPassword=admin \
    --data-urlencode "password=$SONAR_ADMIN_PASSWORD" >/dev/null; then
  echo "> Contraseña de admin de SonarQube cambiada"
fi

# Token para Jenkins (se regenera solo si no hay uno válido)
if [ -s "$TOKEN_FILE" ] && curl -fs -u "$(cat "$TOKEN_FILE"):" "$SONAR/api/authentication/validate" | grep -q '"valid":true'; then
  echo "> Token de SonarQube vigente"
  exit 0
fi

curl -fs -u "admin:$SONAR_ADMIN_PASSWORD" -X POST "$SONAR/api/user_tokens/revoke" --data-urlencode name=jenkins >/dev/null || true
curl -fs -u "admin:$SONAR_ADMIN_PASSWORD" -X POST "$SONAR/api/user_tokens/generate" \
    --data-urlencode name=jenkins \
    --data-urlencode type=GLOBAL_ANALYSIS_TOKEN \
  | sed -n 's/.*"token":"\([^"]*\)".*/\1/p' | tr -d '\n' > "$TOKEN_FILE"

if [ ! -s "$TOKEN_FILE" ]; then
  echo "No se pudo generar el token. Revisa SONAR_ADMIN_PASSWORD en .env" >&2
  exit 1
fi
echo "> Token de SonarQube para Jenkins generado"
