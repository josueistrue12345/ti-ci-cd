---
name: jenkinsfile-mobo
description: Crea o adapta el Jenkinsfile (y los manifiestos k8s/ y Dockerfile que necesite) de un proyecto para el CI/CD de Mobo — Jenkins + SonarQube en Docker Compose, imágenes en Harbor y despliegue al cluster Kubernetes 192.168.30.x con un namespace por proyecto y NodePort. Úsalo siempre que el usuario quiera crear, generar, revisar o arreglar un Jenkinsfile o pipeline, meter un repo/proyecto nuevo al CI/CD, desplegar un proyecto a Kubernetes desde Jenkins, o pase un Jenkinsfile que falla, aunque no diga "skill" ni "Jenkinsfile" (p. ej. "mete este repo al pipeline", "que este proyecto se despliegue solo", "hazle el CI a esta API de Node").
---

# Jenkinsfile para el CI/CD de Mobo

Genera pipelines que corren en el Jenkins del repo `ci-cd` y despliegan al cluster de Kubernetes de Mobo.
El resultado tiene que funcionar a la primera en esa infraestructura concreta, así que respeta las
convenciones de abajo: Jenkins, el cluster y los permisos ya están armados alrededor de ellas.

## Cómo está armado el servidor

| Pieza | Dato |
|---|---|
| Jenkins | Contenedor `jenkins` con el Docker del host (socket montado). No tiene agentes: todo corre ahí |
| Herramientas en Jenkins | Solo `docker`, `kubectl` y `git`. Node, PHP, Java, etc. **no** están: cada paso corre en un contenedor con `docker run --volumes-from jenkins -w "$WORKSPACE"` |
| SonarQube | Instalación `sonarqube` (`withSonarQubeEnv('sonarqube')`), Community Edition. Desde los contenedores del pipeline se llega con `--network container:jenkins` |
| Credenciales | `registry-cred` (usuario/token de Harbor), `kubeconfig` (archivo), `sonar-token`, `git-cred` |
| Harbor | `harbor.mobo.local`, proyecto `mobo` → imagen `harbor.mobo.local/mobo/<app>` (**TODO: confirmar host y proyecto reales**) |
| Cluster | API `https://192.168.30.10:6443` (VIP de 3 masters). Workers `192.168.30.11`, `.12`, `.13` |
| Acceso de Jenkins al cluster | ServiceAccount `jenkins-deployer` (namespace `mobofacil`), con Role por namespace. Puede crear/actualizar deployments, services, configmaps, ingresses, jobs, HPA, PVC; leer pods/replicasets y **solo** el Secret `<app>-env` |
| Jobs | Multibranch: un job por repo de `GIT_REPOS` en el `.env` de `ci-cd`, revisión cada minuto |

Si el host de Harbor sigue marcado como TODO, pregúntalo una vez al usuario antes de escribir archivos.

## Convenciones (todo cuelga del nombre del proyecto)

Sea `<app>` el nombre del repo en minúsculas con guiones (es también el nombre del job en Jenkins):

- Namespace: `<app>` · Deployment y Service: `<app>` · Imagen: `<harbor>/<proyecto-harbor>/<app>:<build>-<commit>`
- Secret con las variables de entorno de la app: `<app>-env` (lo crea una persona en el cluster; el pipeline solo verifica que exista)
- Secret para descargar de Harbor: `harbor-cred` en el namespace
- `sonar.projectKey` = `<app>` (si dos repos comparten key, SonarQube mezcla sus análisis)
- Rama que despliega: `main` (o `master` si el repo usa esa). Las demás ramas prueban, analizan y construyen, pero no suben ni despliegan: si no, una rama de feature pisaría producción
- NodePort: uno libre entre 30000 y 32767, fijo por proyecto. Prueba de humo contra `http://192.168.30.11:<nodePort>`

La excepción conocida es `mobofacil`, que ya existía con Deployment `mobofacil-web`: si trabajas en ese repo, respeta los nombres que ya tiene en `k8s/`.

## Flujo

1. **Mira el repo antes de preguntar.** Detecta el stack por sus archivos (`composer.json`, `package.json`,
   `pom.xml`/`build.gradle`, `*.csproj`/`*.sln`, `requirements.txt`/`pyproject.toml`), la versión del lenguaje,
   cómo se corren las pruebas, el puerto en que escucha la app y si ya hay `Dockerfile`, `k8s/` o `Jenkinsfile`.
2. **Pregunta solo lo que no puedas deducir**, normalmente: el NodePort (que no choque con otros: el usuario puede
   verlo con `kubectl get svc -A | grep NodePort` en un master), la ruta de health check si no es obvia, y la rama
   de despliegue si no es `main`.
3. **Lee la sección del stack** en [references/stacks.md](references/stacks.md): imagen para pruebas, comando,
   reportes JUnit/cobertura y parámetros de Sonar.
4. **Genera los archivos** a partir de las plantillas de `assets/`:
   - `Jenkinsfile` desde [assets/Jenkinsfile.template](assets/Jenkinsfile.template)
   - `k8s/deployment.yaml`, `k8s/service.yaml`, `k8s/kustomization.yaml` desde `assets/k8s/` si el repo no los tiene
   - `Dockerfile` si falta (multi-stage, con la guía del stack)
   Reemplaza todos los `__MARCADORES__`; no dejes ninguno.
5. **Entrega con los pasos pendientes del lado del servidor** (ver abajo), en ese orden.

## Qué dejar resuelto en el Jenkinsfile

- Cada paso de lenguaje corre en `docker run --rm --volumes-from jenkins -w "$WORKSPACE" -u 0 <imagen>`.
  `--volumes-from` es lo que hace que el contenedor vea el workspace en la misma ruta; sin eso no encuentra el código.
- Caches de dependencias en volúmenes con nombre del proyecto (`<app>-npm-cache`, `<app>-m2`, …) para que los builds no descarguen todo cada vez.
- Como los contenedores corren como root, el `post { always }` del pipeline regresa el workspace al usuario
  de Jenkins (uid 1000) y borra la imagen local; si no, el siguiente checkout falla por permisos y el disco se llena.
- Las etapas de Harbor y despliegue llevan `when { branch 'main' }`.
- `kubectl` siempre dentro de `withCredentials([file(credentialsId: 'kubeconfig', variable: 'KUBECONFIG')])` y con `-n "$NAMESPACE"`.
- Si el rollout falla, `rollout undo` en el `post { failure }` de la etapa de despliegue.

## Al entregar, dile al usuario qué falta fuera del repo

1. Agregar la URL del repo a `GIT_REPOS` en el `.env` de `ci-cd` y correr `docker compose up -d` (crea el job).
2. En un master: `sudo bash dar-acceso.sh <app>` con `HARBOR_USER`/`HARBOR_PASS` (script en `ci-cd/k8s/`): crea el namespace, los permisos de Jenkins y `harbor-cred`.
3. En un master: crear `<app>-env` con las variables de la app (`kubectl -n <app> create secret generic <app>-env --from-env-file=.env`).
4. En Harbor: que exista el proyecto y que el usuario de `registry-cred` tenga permiso de push.
5. Push a `main` y revisar el build en Jenkins.

## Cuando un pipeline falla

| Síntoma | Causa probable |
|---|---|
| `Forbidden` en `kubectl` | No se corrió `dar-acceso.sh <app>`, o el recurso no está en el Role (p. ej. un `Namespace` dentro de `k8s/`: quítalo, el namespace lo crea el script) |
| Pods en `ImagePullBackOff` | Falta `harbor-cred` en el namespace, o los nodos no confían en el certificado de Harbor |
| `x509` al hacer `docker login`/`push` | El host de Jenkins no confía en el certificado de Harbor: `/etc/docker/certs.d/<harbor>/ca.crt` |
| `Falta el Secret <app>-env` | Paso 3 de arriba |
| `Permission denied` en el checkout | Falta el `chown` del `post { always }` |
| El scanner no llega a SonarQube | Falta `--network container:jenkins` |
| La prueba de humo da timeout | NodePort distinto al de `k8s/service.yaml`, o la app tarda en arrancar: subir el `sleep`/reintentos |

SonarQube Community no separa ramas: el análisis de cualquier rama reemplaza al anterior en el mismo proyecto.
Si eso estorba, se puede limitar la etapa de Sonar a `main`, a cambio de no tener Quality Gate en las ramas.
