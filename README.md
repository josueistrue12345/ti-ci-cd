# CI/CD de mobofacil: Jenkins + SonarQube con Docker Compose

Todo corre en Docker y se levanta solo con `docker compose`, pensado para un servidor Linux.

```
 git push (repo remoto)
      │   Jenkins revisa el repo cada minuto
      ▼
 ┌──────────── Jenkins  http://<servidor>:18081 ────────────────────┐
 │ Preparar → Pruebas unitarias → SonarQube + Quality Gate →        │
 │ Construir imagen → ...                                           │
 └───────┬───────────────────────┬──────────────────────────────────┘
         ▼                       ▼
  Docker del servidor     SonarQube :19000
  (docker.sock)           (+ Postgres)
```

| Pieza | Contenedor | Para qué |
|---|---|---|
| **Jenkins** | `jenkins` | Orquesta el pipeline definido en el `Jenkinsfile` del repo |
| **SonarQube** | `sonarqube` + `sonar-db` (Postgres) | Analiza la calidad del código y decide si pasa el *Quality Gate* |
| **sonar-init** | corre una vez en cada `up` y termina | Cambia la contraseña por defecto de SonarQube y genera el token para Jenkins |

## Archivos

```
docker-compose.yml     -> Jenkins, SonarQube, Postgres y sonar-init
.env.example           -> plantilla de .env (contraseñas, repo, puertos)
sonar-init/init.sh     -> conecta SonarQube con Jenkins (token)
jenkins/Dockerfile     -> Jenkins + Docker CLI + kubectl + kind
jenkins/plugins.txt    -> plugins de Jenkins
jenkins/casc.yaml      -> configuración de Jenkins como código (usuario, credenciales, SonarQube, job)
```

## Requisitos del servidor

- Docker Engine con el plugin de Compose v2 (`docker compose version`).
- SonarQube usa Elasticsearch y necesita este ajuste del kernel:

  ```bash
  sudo sysctl -w vm.max_map_count=524288
  echo 'vm.max_map_count=524288' | sudo tee /etc/sysctl.d/99-sonarqube.conf
  ```

- Al menos 4 GB de RAM libres para SonarQube + Jenkins.

## Primera vez

```bash
cp .env.example .env
nano .env                       # llena contraseñas, GIT_* y DOCKER_GID
getent group docker | cut -d: -f3   # este número va en DOCKER_GID
docker compose up -d --build
```

La primera vez tarda unos minutos: SonarQube arranca, `sonar-init` genera el token y
después arranca Jenkins. Para seguirlo: `docker compose logs -f sonar-init jenkins`.

- Jenkins: `JENKINS_URL` del `.env` → usuario `admin` / `JENKINS_ADMIN_PASSWORD`
- SonarQube: `http://<servidor>:19000` → usuario `admin` / `SONAR_ADMIN_PASSWORD`

Si falla la descarga de plugins de Jenkins, vuelve a correr `docker compose up -d --build`:
algunos mirrors de Jenkins no responden (el mirror usado está fijo en `jenkins/Dockerfile`).

## Cómo funciona el flujo

- **Un job multibranch por repo**: por cada repo de `GIT_REPOS` (separados por coma) Jenkins crea
  un job con el nombre del repo, y dentro un pipeline por cada rama que tenga `Jenkinsfile`.
  Usa `GIT_USERNAME` / `GIT_TOKEN` para todos (un token con permiso de lectura basta).
- **Agregar un proyecto**: súmalo a `GIT_REPOS` y corre `docker compose up -d`. Su `Jenkinsfile`
  debe usar un `sonar.projectKey` propio para que SonarQube no lo mezcle con otro proyecto.
- **SonarQube + Quality Gate**: el scanner analiza el código y espera el veredicto.
  Si el Quality Gate falla, el pipeline se detiene.
- **Despliegue**: este compose ya no depende de un cluster kind. Las etapas del `Jenkinsfile`
  que cargan la imagen en kind y despliegan a Kubernetes hay que ajustarlas al destino real.

## Día a día

| Quiero... | Hago... |
|---|---|
| Disparar el pipeline | Haz push; o en Jenkins: el job del repo → *Scan Multibranch Pipeline Now* |
| Ver por qué falló | Jenkins → el build → *Console Output* |
| Apagar | `docker compose stop` |
| Prenderlo otra vez | `docker compose up -d` |
| Cambié casc.yaml, plugins.txt o .env | `docker compose up -d --build` |
| Ver logs | `docker compose logs -f jenkins` |
| Borrar todo (incluye historial y análisis) | `docker compose down -v` |

Cada build deja una imagen nueva en Docker; de vez en cuando limpia con `docker image prune`.
Los contenedores tienen `restart: unless-stopped`, así que vuelven solos si el servidor se reinicia.

## Notas de seguridad

- Jenkins corre como usuario `jenkins` pero tiene el socket de Docker (vía el grupo `DOCKER_GID`):
  quien controle Jenkins controla Docker en el servidor. No lo expongas a internet sin un proxy con HTTPS.
- `.env` tiene contraseñas y el token de Git: no se sube a git y debe quedar con `chmod 600 .env`.
- El Quality Gate se consulta desde el scanner (`sonar.qualitygate.wait`), sin webhook de SonarQube
  hacia Jenkins.
