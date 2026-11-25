# Cómo meter un proyecto nuevo al CI/CD

Jenkins corre en **srv-mbdcr01** (`~/ci`, http://192.168.10.215:18090) y SonarQube en el puerto 19090.
Kubernetes: masters 192.168.30.14-16 (API 192.168.30.10:6443) y workers 192.168.30.11-13.

En los comandos, `<app>` es el nombre del proyecto. También es el nombre del namespace, de la imagen y del Deployment.

---

## 1. En el repo del proyecto

Hacen falta tres cosas en la raíz:

| Archivo | Para qué |
|---|---|
| `Jenkinsfile` | El pipeline: pruebas, Sonar, imagen y despliegue. |
| `Dockerfile` | Cómo se construye la imagen. |
| `k8s/` | Manifiestos: `deployment.yaml`, `service.yaml` y `kustomization.yaml`. |

Para generarlos, abre Claude Code en el repo y pide *"hazle el Jenkinsfile a este proyecto"*. La skill `jenkinsfile-mobo` los arma con las convenciones de este servidor.

Antes de subirlos, revisa:
- El `nodePort` del `service.yaml` no lo usa nadie más (rango 30000-32767). Para ver los que ya están ocupados:
  `kubectl get svc -A | grep NodePort`
- Las etapas que despliegan tienen `when { branch 'main' }`.
- El `.env` del proyecto **no** está en git.

## 2. En el servidor de Jenkins (srv-mbdcr01)

Agrega el repo a `GIT_REPOS` en `~/ci/.env`. Es una lista separada por comas:

```bash
GIT_REPOS=https://github.com/org/mobofacil.git,https://github.com/org/<app>.git
```

Después recrea Jenkins:

```bash
cd ~/ci && docker compose up -d jenkins
```

Aparece un job `<app>` con una rama por cada branch que tenga `Jenkinsfile`. Jenkins revisa el repo cada minuto, así que no hay que configurar nada en GitHub.

## 3. En un master de Kubernetes (192.168.30.14)

Dale a Jenkins permiso sobre el namespace del proyecto. Desde srv-mbdcr01:

```bash
scp ~/ci/k8s/dar-acceso.sh madmin@192.168.30.14:~/
ssh -t madmin@192.168.30.14 'sudo bash ~/dar-acceso.sh <app>'
```

Luego crea el Secret con las variables de la app, usando el `.env` **del proyecto** con valores del ambiente. Elige la forma según lo que pida el `deployment.yaml`:

```bash
# Si usa envFrom (cada variable por separado):
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf -n <app> \
  create secret generic <app>-env --from-env-file=app.env

# Si monta el archivo .env completo (caso mobofacil-web):
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf -n <app> \
  create secret generic <app>-env --from-file=.env=app.env

rm app.env   # no lo dejes en el master
```

Para revisar que Jenkins ya tiene acceso:

```bash
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf auth can-i get deployments -n <app> \
  --as=system:serviceaccount:mobofacil:jenkins-deployer    # debe decir: yes
```

## 4. Probar

1. Haz push a `main` y espera menos de un minuto: el build arranca solo. También puedes darle **Build Now**.
2. SonarQube crea el proyecto en el primer análisis. Los resultados están en http://192.168.10.215:19090.
3. La app queda en `http://192.168.30.11:<nodePort>` (sirve cualquier worker).

---

## Errores que ya nos salieron

| Error | Causa | Solución |
|---|---|---|
| `Could not find credentials entry with ID 'nodes-ssh'` | Falta la llave SSH hacia los workers. | Debe existir `secrets/nodes-ssh` y Jenkins debe recrearse con `docker compose up -d --build jenkins`. |
| `Forbidden ... system:serviceaccount:mobofacil:jenkins-deployer` | Jenkins no tiene permiso en ese namespace. | Correr `dar-acceso.sh <app>` en un master. |
| `Falta el Secret <app>-env` | No se creó el Secret de la app. | Ver el paso 3. |
| `kubectl: command not found` | El comando se corrió en srv-mbdcr01. | `kubectl` solo está en los masters. |
| `sudo: a password is required` (ctr) | Falta la regla de sudo en ese worker. | Crear `/etc/sudoers.d/jenkins-ctr` en ese worker. |
| `port is already allocated` | El puerto ya lo usa otro contenedor del server. | Cambiar `JENKINS_PORT` o `SONAR_PORT` en `.env`. |
| `dubious ownership` (git) | Aviso de git dentro del contenedor. | Es inofensivo, se ignora. |

---

## Buenas prácticas de Kubernetes

- **Despliega solo desde `main`.** Las ramas de feature solo prueban y analizan. Hoy mobofacil despliega desde cualquier rama.
- **Usa un tag único por build** (`<build>-<commit>`). Nunca uses `latest`: Kubernetes no se entera de que la imagen cambió y no puedes regresar a una versión anterior.
- **Pon readiness y liveness probes.** Sin readiness, el Service manda tráfico a pods que todavía no arrancan.
- **Define requests y limits** de CPU y memoria en cada contenedor. Así un pod no se come el worker completo.
- **Usa 2 réplicas o más** para que un reinicio o un rollout no tire la app.
- **Ningún secreto va en git.** Todo va en el Secret `<app>-env`. Si un `.env` llegó a subirse a git, rota esas claves.
- **Usa un namespace por proyecto.** Jenkins solo puede tocar los namespaces que le diste con `dar-acceso.sh` y solo puede leer el Secret `<app>-env`.
- **Los logs van a stdout/stderr**, no a archivos dentro del pod. Se ven con `kubectl -n <app> logs deploy/<app>`.

### Para Laravel en particular
- **Migraciones:** córrelas en un `Job` o en una etapa del pipeline, no al arrancar el contenedor. Con 2 réplicas se ejecutarían dos veces al mismo tiempo.
- **`storage/` y archivos subidos:** los pods se borran y con ellos sus archivos. Usa un PVC o almacenamiento externo.
- **Colas y scheduler:** las colas (`queue:work`) van en un Deployment aparte, y el scheduler en un `CronJob`.
- **`APP_KEY`:** va en el Secret y debe ser la misma en todas las réplicas.

### Comandos útiles (en un master)
```bash
kubectl -n <app> get pods -o wide              # dónde corre y en qué estado está
kubectl -n <app> describe pod <pod>            # por qué no arranca (eventos al final)
kubectl -n <app> logs deploy/<app> --tail=100
kubectl -n <app> rollout history deploy/<app>
kubectl -n <app> rollout undo deploy/<app>     # regresar a la versión anterior
```

---

## Sugerencias pendientes

1. **Registry de imágenes.** Hoy la imagen se copia por SSH a cada worker. Esto funciona, pero no escala: es más lento con cada proyecto y un worker nuevo no tiene las imágenes. Cuando el equipo decida qué registry usar, el pipeline ya está preparado (`REGISTRY` en el Jenkinsfile y `registry-cred`).
2. **Usuario exclusivo para Jenkins en los workers.** Hoy Jenkins entra como `madmin` y puede correr `sudo ctr`. Conviene que sea un usuario que solo tenga eso.
3. **Sacar el ServiceAccount del namespace `mobofacil`.** `jenkins-deployer` vive ahí por herencia. Moverlo a algo como `jenkins-ci` implica regenerar el kubeconfig con `crear-kubeconfig.sh`.
4. **Ingress con dominio** en lugar de NodePort cuando haya más apps. Te da URLs limpias, HTTPS y te olvidas de cuidar que los puertos no choquen.
5. **Respaldar el volumen `jenkins-home`** y la carpeta `~/ci/secrets` del servidor.
6. **Rotar el token del kubeconfig si se filtra:**
   `kubectl -n mobofacil delete secret jenkins-deployer-token`. Después vuelve a correr `crear-kubeconfig.sh` y recrea Jenkins.
7. **mobofacil:** corregir los avisos `psr-4` de `SendOneDayWarning.php` y `API/AuthController.php`. El nombre de la clase o de la carpeta no coincide en mayúsculas.
