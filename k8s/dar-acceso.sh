#!/usr/bin/env bash
# Da a Jenkins permiso de desplegar en el namespace de un proyecto nuevo.
# Usa el mismo ServiceAccount (jenkins-deployer del namespace mobofacil), así que el
# kubeconfig de Jenkins no cambia. Córrelo en un master:
#   ./dar-acceso.sh <proyecto>
#   HARBOR_USER=robot\$ci HARBOR_PASS=... ./dar-acceso.sh <proyecto>   (además crea harbor-cred para descargar imágenes)
# Si lo llaman con `sh` (dash en Ubuntu/Debian), se vuelve a lanzar con bash
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -euo pipefail
APP=${1:?Uso: $0 <proyecto>   (el namespace se llama igual que el proyecto)}
HARBOR=${HARBOR:-harbor.mobo.local}

# En un master con sudo, root no tiene ~/.kube/config: se usa el acceso de admin que deja kubeadm
if [ -z "${KUBECONFIG:-}" ] && [ ! -f ~/.kube/config ] && [ -r /etc/kubernetes/admin.conf ]; then
  export KUBECONFIG=/etc/kubernetes/admin.conf
fi

kubectl create namespace "$APP" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: jenkins-deployer
  namespace: $APP
rules:
  # Lo que crea \`kubectl apply -k\` con los manifiestos k8s/ del proyecto
  - apiGroups: ["", "apps", "networking.k8s.io", "batch", "autoscaling"]
    resources: [deployments, services, configmaps, ingresses, jobs, cronjobs, horizontalpodautoscalers, persistentvolumeclaims, serviceaccounts]
    verbs: [get, list, watch, create, update, patch]
  # rollout status / rollout undo
  - apiGroups: ["apps"]
    resources: [replicasets]
    verbs: [get, list, watch]
  - apiGroups: [""]
    resources: [pods]
    verbs: [get, list, watch]
  # El pipeline revisa que exista $APP-env; ningún otro Secret es legible
  - apiGroups: [""]
    resources: [secrets]
    resourceNames: [$APP-env]
    verbs: [get]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: jenkins-deployer
  namespace: $APP
subjects:
  - kind: ServiceAccount
    name: jenkins-deployer
    namespace: mobofacil
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: jenkins-deployer
EOF

if [ -n "${HARBOR_USER:-}" ]; then
  kubectl -n "$APP" create secret docker-registry harbor-cred \
    --docker-server="$HARBOR" --docker-username="$HARBOR_USER" --docker-password="${HARBOR_PASS:?Falta HARBOR_PASS}" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

echo "> Jenkins ya puede desplegar en el namespace $APP"
kubectl -n "$APP" get secret harbor-cred >/dev/null 2>&1 \
  || echo "  Falta harbor-cred para descargar de Harbor: vuelve a correrlo con HARBOR_USER y HARBOR_PASS"
kubectl -n "$APP" get secret "$APP-env" >/dev/null 2>&1 \
  || echo "  Falta el Secret $APP-env con las variables de la app: kubectl -n $APP create secret generic $APP-env --from-env-file=.env"
