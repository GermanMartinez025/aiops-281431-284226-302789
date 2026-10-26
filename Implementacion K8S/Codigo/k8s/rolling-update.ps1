# Despliegue seguro (Rolling Update) de un componente de PharmaGo sin pérdida de disponibilidad.
# Construye una imagen con tag versionado, la carga en Minikube, actualiza el Deployment
# y espera el rollout. Si el rollout falla, hace rollback automático a la revisión anterior.
#
# Uso:   .\rolling-update.ps1 -Component <users|pharmacy|gateway|ui> [-Version <tag>]
# Ej.:   .\rolling-update.ps1 -Component users -Version v1.2.0

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("users", "pharmacy", "gateway", "ui")]
    [string]$Component,
    [string]$Version = (Get-Date -Format "yyyyMMdd-HHmmss")
)

$components = @{
    users    = @{ Name = "pharmago-users-service";    Context = "Backend";  Dockerfile = "PharmaGo.UsersService/Dockerfile" }
    pharmacy = @{ Name = "pharmago-pharmacy-service"; Context = "Backend";  Dockerfile = "PharmaGo.PharmacyService/Dockerfile" }
    gateway  = @{ Name = "pharmago-api-gateway";      Context = "Backend";  Dockerfile = "PharmaGo.ApiGateway/Dockerfile" }
    ui       = @{ Name = "pharmago-ui";               Context = "Frontend"; Dockerfile = "Dockerfile" }
}

$target = $components[$Component]
$name = $target.Name
$image = "${name}:$Version"
$namespace = "pharmago"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$codeDir = Split-Path -Parent $scriptDir

Write-Host "=== Rolling Update de $name -> $image ===" -ForegroundColor Green

Write-Host "`n1. Construyendo imagen..." -ForegroundColor Yellow
Push-Location "$codeDir\$($target.Context)"
docker build -f $target.Dockerfile -t $image .
$buildExit = $LASTEXITCODE
Pop-Location
if ($buildExit -ne 0) { Write-Host "Error construyendo $image" -ForegroundColor Red; exit 1 }

Write-Host "`n2. Cargando imagen en Minikube..." -ForegroundColor Yellow
minikube image load $image
if ($LASTEXITCODE -ne 0) { Write-Host "Error cargando $image en Minikube" -ForegroundColor Red; exit 1 }

Write-Host "`n3. Actualizando Deployment (maxSurge=1, maxUnavailable=0)..." -ForegroundColor Yellow
kubectl set image "deployment/$name" "$name=$image" -n $namespace
if ($LASTEXITCODE -ne 0) { exit 1 }
kubectl annotate "deployment/$name" "kubernetes.io/change-cause=Rolling update a $image" -n $namespace --overwrite | Out-Null

Write-Host "`n4. Esperando rollout..." -ForegroundColor Yellow
kubectl rollout status "deployment/$name" -n $namespace --timeout=300s
if ($LASTEXITCODE -ne 0) {
    Write-Host "`nRollout fallido. Ejecutando rollback a la revisión anterior..." -ForegroundColor Red
    kubectl rollout undo "deployment/$name" -n $namespace
    kubectl rollout status "deployment/$name" -n $namespace --timeout=300s
    exit 1
}

Write-Host "`n=== $name actualizado a $image sin downtime ===" -ForegroundColor Green
kubectl rollout history "deployment/$name" -n $namespace
kubectl get pods -n $namespace -l "app=$name" -o wide
