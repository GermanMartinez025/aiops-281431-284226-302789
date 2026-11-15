# Script de despliegue para Kubernetes (Minikube)
# Uso: .\apply-k8s.ps1

param([switch]$Multinode)

Write-Host "=== Desplegando PharmaGo en Kubernetes ===" -ForegroundColor Green

# Verificar que kubectl está disponible
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    Write-Host "Error: kubectl no está instalado o no está en el PATH" -ForegroundColor Red
    exit 1
}

if ($Multinode) {
    foreach ($role in @('frontend', 'gateway', 'users', 'pharmacy', 'data', 'ops')) {
        $nodes = @(kubectl get nodes -l "node-type=$role" -o name)
        if ($LASTEXITCODE -ne 0 -or $nodes.Count -ne 1) {
            throw "Se requiere exactamente un nodo con node-type=$role."
        }
    }
    $localNodes = @(kubectl get nodes -l node-type=all -o name)
    if ($LASTEXITCODE -ne 0) { throw 'No se pudieron consultar las etiquetas de los nodos.' }
    if ($localNodes.Count -gt 0) { throw 'Retire node-type=all antes del despliegue multinodo.' }
} else {
    $nodes = @(kubectl get nodes -o name)
    if ($LASTEXITCODE -ne 0 -or $nodes.Count -ne 1) {
        throw 'El modo local requiere un nodo. Para varios nodos use -Multinode.'
    }
    kubectl label $nodes[0] node-type=all --overwrite
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo etiquetar el nodo local.' }
}


Write-Host "`n2. Creando namespace..." -ForegroundColor Yellow
kubectl apply -f namespace.yaml
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host "`n3. Creando secrets..." -ForegroundColor Yellow
kubectl apply -f secrets\db-secret.yaml
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host "`n4. Creando configmaps..." -ForegroundColor Yellow
kubectl apply -f configmaps\prometheus-config.yaml
kubectl apply -f configmaps\otel-collector-config.yaml
kubectl apply -f configmaps\grafana-provisioning.yaml
kubectl apply -f configmaps\grafana-dashboards.yaml
kubectl apply -f configmaps\grafana-dashboard-infra.yaml
kubectl apply -f configmaps\grafana-alerting.yaml
kubectl apply -f configmaps\fluent-bit-config.yaml
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host "`n5. Creando StorageClass y PersistentVolumes..." -ForegroundColor Yellow
kubectl apply -f persistent-volumes\storage-class.yaml
if ($LASTEXITCODE -ne 0) { exit 1 }

# Limpiar únicamente volúmenes huérfanos.
foreach ($pv in @('sql-pv', 'elasticsearch-pv', 'prometheus-pv', 'grafana-pv')) {
    $phase = kubectl get pv $pv --ignore-not-found -o jsonpath='{.status.phase}'
    if ($LASTEXITCODE -ne 0) { throw "No se pudo consultar el volumen $pv." }
    if ($phase -in @('Released', 'Failed')) {
        kubectl delete pv $pv --ignore-not-found=true
        if ($LASTEXITCODE -ne 0) { throw "No se pudo eliminar el volumen huérfano $pv." }
    }
}

kubectl apply -f persistent-volumes\sql-pv.yaml
kubectl apply -f persistent-volumes\elasticsearch-pv.yaml
kubectl apply -f persistent-volumes\prometheus-pv.yaml
kubectl apply -f persistent-volumes\grafana-pv.yaml
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host "`n6. Desplegando base de datos..." -ForegroundColor Yellow
kubectl apply -f services\ops\db-service.yaml
kubectl apply -f deployments\ops\db-deployment.yaml
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host "`n   Esperando a que la base de datos esté lista..." -ForegroundColor Yellow
# Esperar a que el pod esté Ready
$timeout = 0
$maxTimeout = 300
do {
    $podReady = kubectl get pod -l app=pharmago-db -n pharmago -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>&1
    if ($podReady -eq "True") {
        Write-Host "   Base de datos lista!" -ForegroundColor Green
        break
    }
    Start-Sleep -Seconds 5
    $timeout += 5
    if ($timeout -ge $maxTimeout) {
        Write-Host "   Timeout esperando la base de datos. Continuando..." -ForegroundColor Yellow
        break
    }
    Write-Host "   Esperando... ($timeout/$maxTimeout segundos)" -ForegroundColor Cyan
} while ($true)

Write-Host "`n7. Desplegando servicios de observabilidad..." -ForegroundColor Yellow
# Elasticsearch primero
kubectl apply -f services\ops\elasticsearch-service.yaml
kubectl apply -f deployments\ops\elasticsearch-deployment.yaml

# Esperar a que Elasticsearch esté listo
Write-Host "   Esperando a que Elasticsearch esté listo..." -ForegroundColor Yellow
$timeout = 0
$maxTimeout = 300
do {
    $podReady = kubectl get pod -l app=elasticsearch -n pharmago -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>&1
    if ($podReady -eq "True") {
        Write-Host "   Elasticsearch listo!" -ForegroundColor Green
        break
    }
    Start-Sleep -Seconds 5
    $timeout += 5
    if ($timeout -ge $maxTimeout) {
        Write-Host "   Timeout esperando Elasticsearch. Continuando..." -ForegroundColor Yellow
        break
    }
    Write-Host "   Esperando... ($timeout/$maxTimeout segundos)" -ForegroundColor Cyan
} while ($true)

# Resto de servicios ops
kubectl apply -f services\ops\otel-collector-service.yaml
kubectl apply -f deployments\ops\otel-collector-rbac.yaml
kubectl apply -f deployments\ops\otel-collector-deployment.yaml

kubectl apply -f services\ops\jaeger-service.yaml
kubectl apply -f deployments\ops\jaeger-deployment.yaml

# Fluent Bit: recolecta los logs JSON de los pods y los envía a Elasticsearch
kubectl apply -f deployments\ops\fluent-bit-serviceaccount.yaml
kubectl apply -f deployments\ops\fluent-bit-clusterrole.yaml
kubectl apply -f deployments\ops\fluent-bit-clusterrolebinding.yaml
kubectl apply -f deployments\ops\fluent-bit-daemonset.yaml

kubectl apply -f deployments\ops\prometheus-serviceaccount.yaml
kubectl apply -f deployments\ops\prometheus-clusterrole.yaml
kubectl apply -f deployments\ops\prometheus-clusterrolebinding.yaml
kubectl apply -f services\ops\prometheus-service.yaml
kubectl apply -f deployments\ops\prometheus-deployment.yaml
kubectl apply -f services\ops\node-exporter-service.yaml
kubectl apply -f deployments\ops\node-exporter-daemonset.yaml

kubectl apply -f services\ops\grafana-service.yaml
kubectl apply -f deployments\ops\grafana-deployment.yaml

kubectl apply -f services\ops\kibana-service.yaml
kubectl apply -f deployments\ops\kibana-deployment.yaml

if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host "`n8. Desplegando servicios backend..." -ForegroundColor Yellow
kubectl apply -f services\backend\users-service-service.yaml
kubectl apply -f deployments\backend\users-service-deployment.yaml

kubectl apply -f services\backend\pharmacy-service-service.yaml
kubectl apply -f deployments\backend\pharmacy-service-deployment.yaml

kubectl apply -f services\backend\api-gateway-service.yaml
kubectl apply -f deployments\backend\api-gateway-deployment.yaml

if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host "`n9. Desplegando frontend..." -ForegroundColor Yellow
kubectl apply -f services\frontend\ui-service.yaml
kubectl apply -f deployments\frontend\ui-deployment.yaml

if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host "`n=== Despliegue completado ===" -ForegroundColor Green
Write-Host "`nVerificando estado de los pods..." -ForegroundColor Yellow
kubectl get pods -n pharmago -o wide

Write-Host "`nPara ver los servicios expuestos:" -ForegroundColor Cyan
Write-Host "  Frontend:     minikube service pharmago-ui -n pharmago --url" -ForegroundColor White
Write-Host "  Grafana:      minikube service grafana -n pharmago --url" -ForegroundColor White
Write-Host "  Kibana:       minikube service kibana -n pharmago --url" -ForegroundColor White
Write-Host "  Prometheus:   minikube service prometheus -n pharmago --url" -ForegroundColor White

