# Genera desde Windows el kubeconfig con el que Jenkins despliega en el cluster remoto.
# Entra por SSH a un master, corre ahí crear-kubeconfig.sh con el acceso de admin del cluster
# y trae el resultado a secrets\kubeconfig. No usa el kubectl de esta máquina.
#   .\k8s\crear-kubeconfig.ps1 -Master usuario@192.168.30.14
#   .\k8s\crear-kubeconfig.ps1 -Master usuario@192.168.30.14 -Server https://192.168.30.14:6443  (si el API no se ve igual desde Jenkins)
param(
  [Parameter(Mandatory)][string]$Master,
  [string]$Server,
  # kubeconfig de admin dentro del master (kubeadm lo deja aquí)
  [string]$AdminKubeconfig = '/etc/kubernetes/admin.conf'
)
$ErrorActionPreference = 'Stop'
$out = Join-Path (Split-Path $PSScriptRoot -Parent) 'secrets\kubeconfig'
$remoteDir = 'jenkins-kubeconfig'

function Invoke-Native($exe) {
  & $exe @args
  if ($LASTEXITCODE -ne 0) { throw "Falló: $exe $args" }
}

try {
  Write-Host "> Copiando k8s/ a $Master..."
  Invoke-Native ssh $Master "mkdir -p $remoteDir"
  Invoke-Native scp -q -r $PSScriptRoot "${Master}:$remoteDir/"

  Write-Host '> Creando el acceso de Jenkins en el cluster (puede pedir la contraseña de sudo)...'
  $vars = "KUBECONFIG=$AdminKubeconfig"
  if ($Server) { $vars += " K8S_SERVER=$Server" }
  Invoke-Native ssh -t $Master "cd $remoteDir && sudo env $vars bash k8s/crear-kubeconfig.sh && cd && sudo chown -R `$(id -u):`$(id -g) $remoteDir"

  New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
  Invoke-Native scp -q "${Master}:$remoteDir/secrets/kubeconfig" $out
} finally {
  # El kubeconfig lleva el token de Jenkins: no se queda en el master
  ssh $Master "sudo rm -rf $remoteDir 2>/dev/null || rm -rf $remoteDir"
}

$api = (Select-String -Path $out -Pattern 'server:').Line.Trim()
Write-Host ''
Write-Host "Listo: $out ($api)"
Write-Host 'Cópialo al servidor de Jenkins en ci-cd/secrets/kubeconfig y ahí corre:'
Write-Host '  sudo chown 1000:1000 secrets/kubeconfig && chmod 600 secrets/kubeconfig'
