#!/usr/bin/env bash
# Genera el kubeconfig con el que Jenkins despliega en el cluster remoto.
# Córrelo donde tengas kubectl con acceso de admin a ese cluster:
#   ./k8s/crear-kubeconfig.sh                 -> deja secrets/kubeconfig
#   K8S_SERVER=https://10.0.0.5:6443 ./k8s/crear-kubeconfig.sh   (si el API no se ve igual desde Jenkins)
# Si lo llaman con `sh` (dash en Ubuntu/Debian), se vuelve a lanzar con bash
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -euo pipefail
# El kubeconfig queda en secrets/ de la carpeta desde donde se corre;
# jenkins-deployer.yaml va junto a este script
OUT="$PWD/secrets/kubeconfig"
cd "$(dirname "$0")"
NAMESPACE=mobofacil

# En un master con sudo, root no tiene ~/.kube/config: se usa el acceso de admin que deja kubeadm
if [ -z "${KUBECONFIG:-}" ] && [ ! -f ~/.kube/config ] && [ -r /etc/kubernetes/admin.conf ]; then
  export KUBECONFIG=/etc/kubernetes/admin.conf
fi
if ! kubectl get namespaces >/dev/null 2>&1; then
  echo "kubectl no se conecta al cluster. Córrelo en un master con sudo, o indica el acceso:" >&2
  echo "  sudo KUBECONFIG=/ruta/al/admin.conf bash $0" >&2
  exit 1
fi

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f jenkins-deployer.yaml

echo "> Esperando el token del ServiceAccount..."
until TOKEN=$(kubectl -n "$NAMESPACE" get secret jenkins-deployer-token -o jsonpath='{.data.token}' | base64 -d) && [ -n "$TOKEN" ]; do sleep 1; done
CA=$(kubectl -n "$NAMESPACE" get secret jenkins-deployer-token -o jsonpath='{.data.ca\.crt}')
SERVER=${K8S_SERVER:-$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')}

case "$SERVER" in
  *127.0.0.1*|*localhost*)
    echo "El API del cluster es $SERVER y Jenkins no lo alcanza desde otro servidor." >&2
    echo "Vuelve a correrlo con K8S_SERVER=https://<ip-del-cluster>:6443" >&2
    exit 1 ;;
esac

mkdir -p "$(dirname "$OUT")"
umask 077
cat > "$OUT" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: remoto
    cluster:
      server: $SERVER
      certificate-authority-data: $CA
users:
  - name: jenkins-deployer
    user:
      token: $TOKEN
contexts:
  - name: jenkins
    context:
      cluster: remoto
      user: jenkins-deployer
      namespace: $NAMESPACE
current-context: jenkins
EOF

echo "> Listo: $OUT (API: $SERVER)"
echo "  Cópialo al servidor de Jenkins en ci-cd/secrets/kubeconfig y dale permisos al usuario jenkins del contenedor:"
echo "  sudo chown 1000:1000 secrets/kubeconfig && chmod 600 secrets/kubeconfig"
