# Levanta el laboratorio de CI/CD y deja SonarQube conectado con Jenkins.
# Se puede correr las veces que quieras: lo que ya está hecho lo salta.
#   .\ci\setup.ps1
$ErrorActionPreference = 'Stop'
$ciDir = $PSScriptRoot
$envFile = Join-Path $ciDir '.env'
$sonarUrl = 'http://localhost:9000'

function New-Password {
  # Cumple la política de SonarQube: 12+ caracteres, mayúscula, minúscula, número y símbolo
  $chars = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
  $body = -join (1..16 | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
  return "Mf$body" + '9!'
}

function Read-CiEnv {
  $vars = @{}
  if (Test-Path $envFile) {
    Get-Content $envFile | Where-Object { $_ -match '^\s*([A-Z_]+)=(.*)$' } | ForEach-Object { $vars[$Matches[1]] = $Matches[2] }
  }
  return $vars
}

function Write-CiEnv($vars) {
  $lines = $vars.Keys | Sort-Object | ForEach-Object { "$_=$($vars[$_])" }
  [IO.File]::WriteAllLines($envFile, [string[]]$lines)
}

function Invoke-Sonar($method, $path, $user, $pass, $body) {
  $auth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${user}:${pass}"))
  return Invoke-RestMethod -Method $method -Uri "$sonarUrl$path" -Headers @{ Authorization = "Basic $auth" } -Body $body
}

# 0. El cluster de kind debe existir (Jenkins se une a su red)
if (-not (docker network ls --format '{{.Name}}' | Where-Object { $_ -eq 'kind' })) {
  throw 'No existe el cluster de kind. Primero: kind create cluster --config k8s/kind-cluster.yaml'
}

# 1. Contraseñas en ci/.env
$vars = Read-CiEnv
if (-not $vars['JENKINS_ADMIN_PASSWORD']) { $vars['JENKINS_ADMIN_PASSWORD'] = New-Password }
if (-not $vars['SONAR_ADMIN_PASSWORD']) { $vars['SONAR_ADMIN_PASSWORD'] = New-Password }
if (-not $vars['SONAR_TOKEN']) { $vars['SONAR_TOKEN'] = 'pendiente' }
Write-CiEnv $vars

# 2. SonarQube
Write-Host '> Levantando SonarQube...'
docker compose -f "$ciDir\docker-compose.yml" up -d sonar-db sonarqube
if ($LASTEXITCODE -ne 0) { throw 'Falló docker compose up' }
do {
  Start-Sleep -Seconds 5
  try { $status = (Invoke-RestMethod "$sonarUrl/api/system/status").status } catch { $status = 'STARTING' }
  Write-Host "  SonarQube: $status"
} while ($status -ne 'UP')

# 3. Cambiar la contraseña por defecto (admin/admin)
$pass = $vars['SONAR_ADMIN_PASSWORD']
try {
  Invoke-Sonar POST '/api/users/change_password' 'admin' 'admin' @{ login = 'admin'; previousPassword = 'admin'; password = $pass } | Out-Null
  Write-Host '> Contraseña de admin de SonarQube cambiada'
} catch {
  Write-Host '> La contraseña de admin de SonarQube ya estaba cambiada'
}

# 4. Token para Jenkins (se regenera solo si no hay uno válido)
$tokenOk = $false
if ($vars['SONAR_TOKEN'] -ne 'pendiente') {
  try { $tokenOk = (Invoke-Sonar GET '/api/authentication/validate' $vars['SONAR_TOKEN'] '' $null).valid } catch {}
}
if (-not $tokenOk) {
  try { Invoke-Sonar POST '/api/user_tokens/revoke' 'admin' $pass @{ name = 'jenkins' } | Out-Null } catch {}
  $vars['SONAR_TOKEN'] = (Invoke-Sonar POST '/api/user_tokens/generate' 'admin' $pass @{ name = 'jenkins'; type = 'GLOBAL_ANALYSIS_TOKEN' }).token
  Write-CiEnv $vars
  Write-Host '> Token de SonarQube para Jenkins generado'
}

# 5. Jenkins
Write-Host '> Construyendo y levantando Jenkins...'
docker compose -f "$ciDir\docker-compose.yml" up -d --build jenkins
if ($LASTEXITCODE -ne 0) { throw 'Falló docker compose up de Jenkins' }

Write-Host ''
Write-Host 'Listo:'
Write-Host "  Jenkins    http://localhost:8081   admin / $($vars['JENKINS_ADMIN_PASSWORD'])"
Write-Host "  SonarQube  http://localhost:9000   admin / $pass"
Write-Host '  App        http://localhost:8080'
Write-Host '(Las contraseñas quedan en ci/.env)'
