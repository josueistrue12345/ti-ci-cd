---
name: jenkinsfile-mobo
description: Crea o adapta el Jenkinsfile (y los manifiestos k8s/ y Dockerfile que necesite) de un proyecto para el CI/CD de Mobo — Jenkins + SonarQube en Docker Compose, con despliegue al cluster Kubernetes 192.168.30.x (un namespace por proyecto, NodePort) que se activa cuando haya registry de imágenes. Úsalo siempre que el usuario quiera crear, generar, revisar o arreglar un Jenkinsfile o pipeline, meter un repo/proyecto nuevo al CI/CD, desplegar un proyecto a Kubernetes desde Jenkins, o pase un Jenkinsfile que falla, aunque no diga "skill" ni "Jenkinsfile" (p. ej. "mete este repo al pipeline", "que este proyecto se despliegue solo", "hazle el CI a esta API de Node").
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
| Credenciales | `registry-cred` (usuario/token del registry, vacío por ahora), `kubeconfig` (archivo), `sonar-token`, `git-cred` |
| Registry de imágenes | **No hay todavía.** No lo preguntes ni propongas uno: el usuario lo definirá con su equipo |
| Cluster | API `https://192.168.30.10:6443` (VIP de 3 masters). Workers `192.168.30.11`, `.12`, `.13` |
| Acceso de Jenkins al cluster | ServiceAccount `jenkins-deployer` (namespace `mobofacil`), con Role por namespace. Puede crear/actualizar deployments, services, configmaps, ingresses, jobs, HPA, PVC; leer pods/replicasets y **solo** el Secret `<app>-env` |
| Jobs | Multibranch: un job por repo de `GIT_REPOS` en el `.env` de `ci-cd`, revisión cada minuto |

### Sin registry, qué hace el pipeline

Los nodos del cluster descargan las imágenes de un registry; sin él no hay forma de que reciban la imagen,
así que el despliegue no puede funcionar todavía. El template lo resuelve con la variable `REGISTRY`
del Jenkinsfile, que se deja vacía (`REGISTRY = ''`):

- Vacía: el pipeline corre pruebas, SonarQube y construye la imagen (valida el `Dockerfile`); las etapas de subir, desplegar y prueba de humo se saltan solas.
- Con valor (p. ej. `ghcr.io/mobo` o `registry.mobo.mx/proyecto`): esas etapas se activan en la rama de despliegue sin tocar nada más.

Genera las etapas de despliegue y los manifiestos `k8s/` igual, para que el proyecto quede listo cuando exista el registry.

## Convenciones (todo cuelga del nombre del proyecto)

Sea `<app>` el nombre del repo en minúsculas con guiones (es también el nombre del job en Jenkins):

- Namespace: `<app>` · Deployment y Service: `<app>` · Imagen: `<app>:<build>-<commit>` (en el registry: `$REGISTRY/<app>`)
- Secret con las variables de entorno de la app: `<app>-env` (lo crea una persona en el cluster; el pipeline solo verifica que exista)
- Secret para descargar del registry: `registry-cred` en el namespace (solo cuando haya registry privado)
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
- Las etapas de subir, desplegar y prueba de humo llevan la rama de despliegue **y** `REGISTRY` con valor en su `when`.
- `kubectl` siempre dentro de `withCredentials([file(credentialsId: 'kubeconfig', variable: 'KUBECONFIG')])` y con `-n "$NAMESPACE"`.
- Si el rollout falla, `rollout undo` en el `post { failure }` de la etapa de despliegue.

## Al entregar, dile al usuario qué falta fuera del repo

Hoy:
1. Agregar la URL del repo a `GIT_REPOS` en el `.env` de `ci-cd` y correr `docker compose up -d` (crea el job).
2. Push y revisar el build en Jenkins: pruebas, SonarQube e imagen.

Cuando haya registry (menciónalo en una línea, sin insistir):
3. Poner su dirección en `REGISTRY` del Jenkinsfile y `REGISTRY_USERNAME`/`REGISTRY_TOKEN` en el `.env` de `ci-cd`.
4. En un master: `sudo bash dar-acceso.sh <app>` (script en `ci-cd/k8s/`): crea el namespace, los permisos de Jenkins y, si se le pasa `REGISTRY`, `REGISTRY_USER` y `REGISTRY_PASS`, el Secret `registry-cred`.
5. En un master: crear `<app>-env` con las variables de la app (`kubectl -n <app> create secret generic <app>-env --from-env-file=.env`).

## Cuando un pipeline falla

| Síntoma | Causa probable |
|---|---|
| Las etapas de despliegue salen como saltadas | `REGISTRY` vacío (esperado mientras no haya registry) o la rama no es la de despliegue |
| `Forbidden` en `kubectl` | No se corrió `dar-acceso.sh <app>`, o el recurso no está en el Role (p. ej. un `Namespace` dentro de `k8s/`: quítalo, el namespace lo crea el script) |
| Pods en `ImagePullBackOff` | Falta `registry-cred` en el namespace, o los nodos no confían en el certificado del registry |
| `x509` al hacer `docker login`/`push` | El host de Jenkins no confía en el certificado del registry: `/etc/docker/certs.d/<registry>/ca.crt` |
| `Falta el Secret <app>-env` | Paso 5 de arriba |
| `Permission denied` en el checkout | Falta el `chown` del `post { always }` |
| El scanner no llega a SonarQube | Falta `--network container:jenkins` |
| La prueba de humo da timeout | NodePort distinto al de `k8s/service.yaml`, o la app tarda en arrancar: subir el `sleep`/reintentos |

SonarQube Community no separa ramas: el análisis de cualquier rama reemplaza al anterior en el mismo proyecto.
Si eso estorba, se puede limitar la etapa de Sonar a `main`, a cambio de no tener Quality Gate en las ramas.
