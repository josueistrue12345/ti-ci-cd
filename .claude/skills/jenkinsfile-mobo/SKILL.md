---
name: jenkinsfile-mobo
description: Crea o adapta el Jenkinsfile (y los manifiestos k8s/ y Dockerfile que necesite) de un proyecto para el CI/CD de Mobo — Jenkins + SonarQube en Docker Compose (srv-mbdcr01), con despliegue al cluster Kubernetes 192.168.30.x (un namespace por proyecto, NodePort). Sin registry: la imagen se copia por SSH a los workers. Úsalo siempre que el usuario quiera crear, generar, revisar o arreglar un Jenkinsfile o pipeline, meter un repo/proyecto nuevo al CI/CD, desplegar un proyecto a Kubernetes desde Jenkins, o pase un Jenkinsfile o log que falla, aunque no diga "skill" ni "Jenkinsfile" (p. ej. "mete este repo al pipeline", "que este proyecto se despliegue solo", "hazle el CI a esta API de Node", "falló la etapa Desplegar").
---

# Jenkinsfile para el CI/CD de Mobo

Genera pipelines que corren en el Jenkins del repo `ci-cd` y despliegan al cluster de Kubernetes de Mobo.
El resultado tiene que funcionar a la primera en esa infraestructura concreta, así que respeta las
convenciones de abajo: Jenkins, el cluster y los permisos ya están armados alrededor de ellas.
El pipeline de referencia que **ya funciona de punta a punta** es el `Jenkinsfile` de `mobofacil`.

## Cómo está armado el servidor

| Pieza | Dato |
|---|---|
| Jenkins | Contenedor `jenkins` en **srv-mbdcr01** (`~/ci`, http://192.168.10.215:18090), con el Docker del host (socket montado). Sin agentes: todo corre ahí |
| Herramientas en Jenkins | Solo `docker`, `kubectl`, `git`, `ssh`/`scp`. Node, PHP, Java, etc. **no** están: cada paso corre en un contenedor con `docker run --volumes-from jenkins -w "$WORKSPACE"` |
| SonarQube | Instalación `sonarqube` (`withSonarQubeEnv('sonarqube')`), Community Edition, puerto 19090. Desde los contenedores del pipeline se llega con `--network container:jenkins` |
| Credenciales | `kubeconfig` (archivo), `nodes-ssh` (SSH a los workers, usuario `madmin`), `sonar-token`, `git-cred`, `registry-cred` (vacía por ahora) |
| Registry de imágenes | **No hay todavía.** No lo preguntes ni propongas uno: el usuario lo definirá con su equipo |
| Cluster | API `https://192.168.30.10:6443` (VIP de 3 masters `.14`-`.16`). Workers `192.168.30.11`, `.12`, `.13` (containerd). `kubectl` solo existe en los masters, no en srv-mbdcr01 |
| Acceso de Jenkins al cluster | ServiceAccount `jenkins-deployer` (namespace `mobofacil`), con Role por namespace (`dar-acceso.sh`). Puede crear/actualizar deployments, services, configmaps, ingresses, jobs, cronjobs, HPA, PVC; leer pods/replicasets y **solo** el Secret `<namespace>-env`. No puede `exec`, ni ver logs, ni crear Namespaces |
| Workers | `madmin` entra con la llave `nodes-ssh` y puede correr `sudo ctr` sin contraseña (`/etc/sudoers.d/jenkins-ctr`) |
| Jobs | Multibranch: un job por repo de `GIT_REPOS` en el `.env` de `ci-cd`, revisión cada minuto |
| NodePorts ocupados | `30080` (otro servicio), `30081` (mobofacil). Antes de elegir uno, pide revisar el cluster |

### Cómo llega la imagen a los nodos

La variable `REGISTRY` del Jenkinsfile decide:

- **Vacía (lo de hoy):** la etapa *Copiar imagen a los nodos* hace `docker save | gzip`, la manda por SSH a cada worker y la importa con `sudo ctr -n k8s.io images import`. El Deployment usa `imagePullPolicy: IfNotPresent` (o `Never`), así Kubernetes usa la imagen que ya está en el nodo.
- **Con valor** (p. ej. `ghcr.io/mobo`): la etapa *Subir al registry* hace push y el overlay agrega `newName: $REGISTRY/<app>`. No hay que tocar nada más.

## Convenciones (todo cuelga del nombre del proyecto)

Sea `<app>` el nombre del repo en minúsculas con guiones (es también el nombre del job en Jenkins):

- Namespace: `<app>` · Deployment y Service: `<app>` · Imagen: `<app>:<build>-<commit>`
- Secret con las variables de la app: `<namespace>-env`. Lo crea una persona en un master; el pipeline solo verifica que exista.
- `sonar.projectKey` = `<app>` (si dos repos comparten key, SonarQube mezcla sus análisis)
- Rama que despliega: `main` (o `master`). Las demás prueban, analizan y construyen, pero no copian/suben ni despliegan.
- NodePort: uno libre entre 30000 y 32767, fijo por proyecto. Prueba de humo contra `http://192.168.30.11:<nodePort>`.

Excepción conocida: `mobofacil` usa namespace y Deployment `mobofacil-web`, Secret `mobofacil-web-env` con el `.env` montado como archivo, un Deployment `mobofacil-scheduler` apagado (`replicas: 0`) y un PVC en `storage/app`. Si trabajas en ese repo, respeta lo que ya tiene en `k8s/`; no enciendas el scheduler (manda cobros y mensajes reales).

## Flujo

1. **Mira el repo antes de preguntar.** Detecta el stack por sus archivos (`composer.json`, `package.json`,
   `pom.xml`/`build.gradle`, `*.csproj`/`*.sln`, `requirements.txt`/`pyproject.toml`), la versión del lenguaje,
   cómo se corren las pruebas, el puerto en que escucha la app y si ya hay `Dockerfile`, `.dockerignore`, `k8s/` o `Jenkinsfile`.
2. **Pregunta solo lo que no puedas deducir**, normalmente: el NodePort (pide que lo revisen en un master, ver abajo),
   la ruta de health check si no es obvia, y la rama de despliegue si no es `main`.
3. **Lee la sección del stack** en [references/stacks.md](references/stacks.md): imagen para pruebas, comando,
   reportes JUnit/cobertura, parámetros de Sonar y trampas conocidas del stack.
4. **Genera los archivos** a partir de las plantillas de `assets/`:
   - `Jenkinsfile` desde [assets/Jenkinsfile.template](assets/Jenkinsfile.template)
   - `k8s/deployment.yaml`, `k8s/service.yaml`, `k8s/kustomization.yaml` desde `assets/k8s/` si el repo no los tiene
   - `Dockerfile` y `.dockerignore` si faltan (multi-stage, con la guía del stack). `.dockerignore` debe excluir `.env*`, dependencias instaladas (`vendor`, `node_modules`), `.git`, `k8s`, `Jenkinsfile`, `reports`, `.scannerwork`, `.deploy`.
   Reemplaza todos los `__MARCADORES__`; no dejes ninguno.
5. **Entrega con los pasos pendientes del lado del servidor** (ver abajo), en ese orden.

## Qué dejar resuelto en el Jenkinsfile

- Cada paso de lenguaje corre en `docker run --rm --volumes-from jenkins -w "$WORKSPACE" -u 0 <imagen>`.
  `--volumes-from` es lo que hace que el contenedor vea el workspace en la misma ruta; sin eso no encuentra el código.
- Caches de dependencias en volúmenes con nombre del proyecto (`<app>-composer-cache`, `<app>-m2`, …).
- `env.DEPLOY` se calcula en *Preparar* (`BRANCH_NAME == DEPLOY_BRANCH`) y va en el `when` de copiar/subir, desplegar y prueba de humo.
- El overlay temporal `.deploy/kustomization.yaml` **siempre lleva `namespace:`**; sin él, `kubectl apply` usa el namespace del kubeconfig (`mobofacil`) y `rollout status` no encuentra el Deployment.
- `kubectl` siempre dentro de `withCredentials([file(credentialsId: 'kubeconfig', variable: 'KUBECONFIG')])` y con `-n "$NAMESPACE"`.
- `post { failure }` de *Desplegar*: `get pods -o wide` y `rollout undo` (en el primer despliegue el undo dice "no rollout history": es normal).
- La prueba de humo imprime el código HTTP; acepta 2xx/3xx. Un 500 no es "no responde": la app arrancó y truena.
- El `post { always }` del pipeline regresa el workspace a uid 1000 y borra la imagen local y `image.tar.gz`.

## Al entregar, dile al usuario qué falta fuera del repo

1. **srv-mbdcr01:** agregar la URL del repo a `GIT_REPOS` en `~/ci/.env` y `docker compose up -d jenkins` (crea el job).
2. **NodePort libre** (en un master):
   `sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get svc -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {.spec.ports[*].nodePort}{"\n"}{end}' | grep -E ': [0-9]'`
3. **Permisos de Jenkins en el namespace** (desde srv-mbdcr01, el script se corre en un master):
   `scp ~/ci/k8s/dar-acceso.sh madmin@192.168.30.14:~/ && ssh -t madmin@192.168.30.14 'sudo bash ~/dar-acceso.sh <namespace>'`
4. **Secret `<namespace>-env`** en un master, con el `.env` del proyecto (no el de ci-cd), según lo que use el Deployment:
   - `envFrom` → `kubectl -n <ns> create secret generic <ns>-env --from-env-file=app.env`
   - archivo montado con `subPath: .env` → `kubectl -n <ns> create secret generic <ns>-env --from-file=.env=app.env`
   Después, `shred -u app.env` y, si el Secret cambió con el pod ya corriendo, `kubectl -n <ns> rollout restart deploy/<app>`.
5. Push a la rama de despliegue y revisar el build en Jenkins.

Cuando haya registry (menciónalo en una línea, sin insistir): poner su dirección en `REGISTRY` del Jenkinsfile, `REGISTRY_USERNAME`/`REGISTRY_TOKEN` en el `.env` de `ci-cd`, y correr `dar-acceso.sh` con `REGISTRY`, `REGISTRY_USER` y `REGISTRY_PASS` para crear `registry-cred` en el namespace.

## Cuando un pipeline falla

Pide el log de la etapa que falló, no el código de la etapa (lo que muestra el Stage View al pasar el mouse es el script, no la salida). Si el log es muy largo para pegarlo, en srv-mbdcr01:

```bash
docker exec jenkins sh -c 'd=$(ls -d /var/jenkins_home/jobs/<repo>/branches/*<rama>*/builds); b=$(ls "$d" | grep -E "^[0-9]+$" | sort -n | tail -1); sed -n "/(<Etapa>)/,/(<Etapa siguiente>)/p" "$d/$b/log"'
```

Para ver por qué la app no levanta o truena, en un master: `kubectl -n <ns> get pods`, `describe pod <pod>`, `logs deploy/<app> --tail=40` (Jenkins no tiene permiso de logs/exec).

| Síntoma | Causa y arreglo |
|---|---|
| `Could not find credentials entry with ID 'nodes-ssh'` | Falta la credencial: `secrets/nodes-ssh` en srv-mbdcr01, legible por uid 1000, y `docker compose up -d --build jenkins` (va en `casc.yaml`) |
| `sudo: a password is required` al importar con `ctr` | Falta `/etc/sudoers.d/jenkins-ctr` (`madmin ALL=(root) NOPASSWD: /usr/bin/ctr`) en ese worker |
| `El nodo X no tiene <app>:<tag> después del import` | `ctr` importó en otro namespace: debe ser `-n k8s.io` |
| Pods en `ErrImageNeverPull` / `ImagePullBackOff` sin registry | La imagen no se copió a ese worker (revisa `NODES`), o el `image:` del manifiesto no coincide con `IMAGE` del Jenkinsfile |
| `Forbidden ... system:serviceaccount:mobofacil:jenkins-deployer` | No se corrió `dar-acceso.sh <namespace>`, o el recurso no está en el Role (p. ej. un `Namespace` dentro de `k8s/`: quítalo, lo crea el script) |
| `kubectl: command not found` | Se corrió en srv-mbdcr01; `kubectl` está en los masters |
| `Falta el Secret <ns>-env` | Paso 4 de arriba |
| `spec.ports[0].nodePort: ... provided port is already allocated` | NodePort en uso: elige otro (paso 2) y cámbialo en `service.yaml` y en `APP_URL` |
| `rollout status` falla al instante con "not found" | El overlay no tiene `namespace:` y se aplicó en `mobofacil` |
| Pod `Pending` mucho tiempo | PVC sin StorageClass que lo atienda (`kubectl get pvc,storageclass`), o no hay recursos (`describe pod`) |
| Prueba de humo da 500 | La app truena: ver `kubectl logs`. En Laravel, `MissingAppKeyException` + `.env: Is a directory` = el Secret no tiene la llave `.env` (se creó con `--from-env-file` para un montaje `subPath`) |
| Prueba de humo da 000 / timeout | NodePort distinto al de `service.yaml`, o la app tarda en arrancar: subir los reintentos |
| `x509` al hacer `docker login`/`push` | El host de Jenkins no confía en el certificado del registry: `/etc/docker/certs.d/<registry>/ca.crt` |
| `Permission denied` en el checkout | Falta el `chown` del `post { always }` |
| El scanner no llega a SonarQube | Falta `--network container:jenkins` |
| `dubious ownership` de git dentro de un contenedor | Aviso inofensivo |

SonarQube Community no separa ramas: el análisis de cualquier rama reemplaza al anterior en el mismo proyecto.
Si eso estorba, se puede limitar la etapa de Sonar a `main`, a cambio de no tener Quality Gate en las ramas.
