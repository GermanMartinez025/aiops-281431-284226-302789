# Despliegue de PharmaGo en Kubernetes (Minikube)

Esta guía describe cómo desplegar la aplicación PharmaGo en un cluster de Kubernetes usando Minikube con un solo nodo.

## Arquitectura

La aplicación se ejecuta en un único nodo (minikube) con todos los componentes:

- **Frontend**: pharmago-ui
- **Backend**: pharmago-api-gateway, pharmago-users-service, pharmago-pharmacy-service
- **Base de datos**: pharmago-db (SQL Server Express)
- **Telemetría y observabilidad**: otlp-collector, prometheus, grafana, elasticsearch, kibana, fluent-bit

### Flujo de telemetría en Kubernetes

- Gateway, Users y Pharmacy envían métricas y trazas por OTLP/gRPC al Collector (`otlp-collector:4317`). Las trazas continúan hacia Jaeger.
- El Collector recibe métricas de aplicación por OTLP y adapta node-exporter/cAdvisor mediante scraping; exporta todas las métricas por OTLP/HTTP protobuf al receptor interno de Prometheus (`http://prometheus:9090/api/v1/otlp/v1/metrics`). No se expone un endpoint de métricas del Collector ni Prometheus lo scrapea.
- Prometheus usa `UnderscoreEscapingWithSuffixes` y promueve solo `service.name`, `service.instance.id` y `service.namespace`. Grafana consulta Prometheus; CPU/memoria por contenedor excluye series vacías y `POD`, y las métricas de nodo conservan el label `node`.
- Los tags de Prometheus y Collector están fijados a `prom/prometheus:v3.16.0` y `otel/opentelemetry-collector-contrib:0.165.0`. El Collector corre con una réplica y estrategia `Recreate` porque recolecta infraestructura.
- node-exporter se descubre por pods en `pharmago`; el Collector recibe permisos de lectura de pods solo en ese namespace. Las métricas describen el nodo donde corre Kubernetes (Minikube puede ser una VM o contenedor), no prueban por sí solas el hardware físico del equipo.

Los manifiestos describen configuración deseada; no acreditan una ejecución ni ingesta actual. Para comprobar el estado actual, revisa pods y Services, la bandera del receptor OTLP de Prometheus y el endpoint configurado en el Collector:

```bash
kubectl get pods -n pharmago -o wide
kubectl get services otlp-collector prometheus -n pharmago -o wide
kubectl get deployment prometheus -n pharmago -o yaml | grep -- '--web.enable-otlp-receiver'
kubectl get configmap otel-collector-config -n pharmago -o yaml | grep 'metrics_endpoint:'
kubectl logs deployment/otlp-collector -n pharmago --since=5m
```

Para aplicar selectivamente, usa los manifiestos específicos de ConfigMap, RBAC, Service y Deployments. No uses el script completo como mecanismo de actualización de telemetría: incluye pasos ajenos a este cambio, entre ellos operaciones sobre volúmenes persistentes.

**Requisito de memoria**: dimensionar el nodo para consumo real, Kubernetes y pods adicionales; se recomienda partir de 8GB de RAM para soportar Elasticsearch (1.5Gi), Kibana (2Gi), SQL Server Express (2Gi) y el resto de servicios.

## Prerrequisitos

1. **Minikube** instalado y configurado
2. **kubectl** instalado y configurado
3. **Docker** instalado (para construir las imágenes)

## Configuración Inicial

### 1. Crear cluster Minikube (un nodo, 8GB RAM)

```bash
# Crear cluster con suficiente memoria para telemetría (Elasticsearch, Kibana, etc.)
minikube start --memory=8192 --cpus=4

# Verificar nodo
kubectl get nodes
```

**Importante**: reservar margen para Kubernetes, consumo real y pods de surge. Los 8GB son un punto de partida, no una garantia de estabilidad.

### 2. Etiquetar nodo

El script `apply-k8s.sh` etiqueta el nodo automáticamente con `node-type=all`. Si despliegas manualmente:
```bash
kubectl label nodes minikube node-type=all --overwrite
```

### 3. Construir, instalar y actualizar

Se requiere Node >= 18 para los scripts de control. Las imagenes se construyen con
tags unicos y se conservan para rollback. No volver a aplicar plantillas con
`latest` encima de una version controlada.

Para una instalacion NUEVA (namespace y PV del proyecto ausentes):

```powershell
.\build-images.ps1 -Tag rollout-v1
.\apply-k8s.ps1 -Tag rollout-v1
```

El instalador no borra volumenes y se detiene si ya existe la instalacion. Para
una instalacion existente, usar el procedimiento de preparacion de base y luego
`update-app.ps1` o `update-app.sh`. El actualizador verifica disponibilidad y
realiza rollback automatico ante fallo o timeout de 300 s. No actualiza SQL.

La tecnica, sus limites, los comandos y el guion reproducible para el video estan
en [ROLLING-UPDATE.md](ROLLING-UPDATE.md). Ese documento distingue pruebas locales
de evidencias de trafico reales durante el reemplazo.

## Verificación

### Ver estado de los pods

```bash
# Ver todos los pods
kubectl get pods -n pharmago -o wide

# Ver pods por nodo (con un nodo, todos aparecen en minikube)
kubectl get pods -n pharmago -o wide --field-selector spec.nodeName=minikube
```

### Ver servicios

```bash
kubectl get svc -n pharmago
```

### Ver logs

```bash
# Logs de un pod específico
kubectl logs -n pharmago <pod-name>

# Logs con seguimiento
kubectl logs -n pharmago -f <pod-name>
```

## Acceso a los Servicios

Hay dos opciones para acceder a los servicios: **port-forward** (recomendado en Windows) o **minikube service**.

### Opción 1: Port-forward (Recomendado en Windows)

En Windows, `localhost` puede fallar con `kubectl port-forward` y herramientas como `sqlcmd`. Usa **127.0.0.1** para todas las conexiones.

```bash
cd k8s
./port-forward.sh
```

Servicios disponibles en:
- **Frontend**: http://127.0.0.1:4200
- **API Gateway**: http://127.0.0.1:5000
- **BD (SQL Server)**: `127.0.0.1,11433` (sa / Str0ngP@ssword!)
- **Prometheus**: http://127.0.0.1:9090
- **Grafana**: http://127.0.0.1:3000 (admin/admin)
- **Kibana**: http://127.0.0.1:5601

Para detener: `./port-forward.sh --stop`

### Opción 2: Minikube service

### Frontend

```bash
minikube service pharmago-ui -n pharmago --url
```

### Grafana

```bash
minikube service grafana -n pharmago --url
# Credenciales: admin / admin
```

### Kibana

```bash
minikube service kibana -n pharmago --url
```

### Prometheus

```bash
minikube service prometheus -n pharmago --url
```

## Configuración de Replicas

Para cambiar el número de réplicas de cualquier componente, edita el archivo de deployment correspondiente:

```yaml
spec:
  replicas: 1  # Cambiar este valor
```

Luego aplica los cambios:

```bash
kubectl apply -f deployments/<component>/<deployment>.yaml
```

## Troubleshooting

### Pods no se inician (Pending / telemetría)

Si los pods de telemetría (otel-collector, prometheus, grafana, elasticsearch, kibana, fluent-bit) quedan en `Pending`:

1. **Falta etiqueta en el nodo**: Los pods requieren `node-type=all`.
   - El instalador inicial etiqueta automáticamente; no reinstalar para corregir una etiqueta.
   - Manual: `kubectl label nodes minikube node-type=all --overwrite`
   
   ```bash
   kubectl get nodes --show-labels
   ```

2. Verificar eventos del pod:
   ```bash
   kubectl describe pod <pod-name> -n pharmago
   ```

3. Ver logs:
   ```bash
   kubectl logs <pod-name> -n pharmago
   ```

### Imágenes no encontradas

Si los pods fallan con `ImagePullBackOff`:

1. Verificar que las imágenes están cargadas en Minikube:
   ```bash
   minikube image ls | grep pharmago
   ```

2. Si faltan imágenes, construir una version nueva y cargarlas:
   ```bash
   ./build-images.sh --tag recuperacion-v1
   ```

3. Verificar `imagePullPolicy: Never` y usar `update-app` con esa nueva version.
   Si la base ya esta indisponible, seguir la preparacion `--bootstrap` de
   [ROLLING-UPDATE.md](ROLLING-UPDATE.md), sin acreditar cero cortes en esa recuperacion.

### Base de datos no está lista

Si los servicios backend no pueden conectarse a la base de datos:

1. Verificar que el pod de la base de datos está corriendo:
   ```bash
   kubectl get pods -n pharmago -l app=pharmago-db
   ```

2. Verificar logs de la base de datos:
   ```bash
   kubectl logs -n pharmago -l app=pharmago-db
   ```

3. Verificar el secret:
   ```bash
   kubectl get secret db-secret -n pharmago -o yaml
   ```

### PersistentVolumes no se montan

En Minikube, los PersistentVolumes usan `hostPath` con `DirectoryOrCreate`, que crea los directorios automáticamente. Si tienes problemas:

```bash
# Conectarse al nodo y crear directorios manualmente
minikube ssh
sudo mkdir -p /mnt/data/{sql,elasticsearch,prometheus,grafana}
sudo chmod 777 /mnt/data/{sql,elasticsearch,prometheus,grafana}
exit
```

**Nota**: El deployment de SQL Server incluye un initContainer que configura los permisos para el usuario `mssql` (UID 10001).

### Elasticsearch OOMKilled (Out of Memory)

Si Elasticsearch está en `CrashLoopBackOff` con `OOMKilled`:

1. **Verificar memoria disponible en el nodo:**
   ```bash
   kubectl describe node minikube | grep -A 5 "Allocated resources"
   ```

2. **Aumentar memoria de Minikube:**
   ```bash
   minikube stop
   minikube delete
   minikube start --memory=8192 --cpus=4
   ```

3. **Reducir memoria heap de Elasticsearch:**
   Edita `deployments/ops/elasticsearch-deployment.yaml` y reduce `ES_JAVA_OPTS`:
   ```yaml
   - name: ES_JAVA_OPTS
     value: "-Xms1g -Xmx1g"  # Reducir de 2g a 1g
   ```
   Luego aumenta el límite de memoria del contenedor a 3-4Gi para compensar.

4. **Deshabilitar características que consumen memoria:**
   Agrega estas variables de entorno en el deployment:
   ```yaml
   - name: xpack.monitoring.collection.enabled
     value: "false"
   - name: xpack.security.enabled
     value: "false"  # Ya está configurado
   ```

5. **Verificar logs:**
   ```bash
   kubectl logs -n pharmago -l app=elasticsearch --tail=50
   ```

**Nota**: Elasticsearch requiere al menos 2GB de heap de Java y memoria adicional para el sistema operativo y otros procesos. En un entorno con recursos limitados (Minikube), considera usar una versión más ligera o deshabilitar características no esenciales.

### Kibana no está Ready

Si Kibana está `Running` pero no `Ready`:

1. **Verificar que Elasticsearch está funcionando:**
   ```bash
   kubectl get pods -n pharmago -l app=elasticsearch
   ```

2. **Verificar logs de Kibana:**
   ```bash
   kubectl logs -n pharmago -l app=kibana --tail=50
   ```

3. **Kibana espera a Elasticsearch:** Si Elasticsearch no está listo, Kibana no puede conectarse y permanecerá en `Running` pero no `Ready`.

## Limpieza (Equivalente a `docker-compose down`)

### Opción 1: Script automatizado (Recomendado)

```bash
cd k8s
chmod +x cleanup.sh
./cleanup.sh
```

**Conservar volúmenes persistentes:**
```bash
./cleanup.sh --keep-volumes
```

### Opción 2: Comando manual

```bash
# Eliminar namespace (elimina todos los recursos dentro de él)
kubectl delete namespace pharmago

# Eliminar PersistentVolumes (están fuera del namespace)
kubectl delete pv sql-pv elasticsearch-pv prometheus-pv grafana-pv
```

### Opción 3: Eliminar recursos individualmente

```bash
# Eliminar recursos en orden inverso al despliegue
kubectl delete -f deployments/
kubectl delete -f services/
kubectl delete -f configmaps/
kubectl delete -f secrets/
kubectl delete -f persistent-volumes/
kubectl delete -f namespace.yaml
```

**Nota**: Eliminar el namespace es la forma más simple y equivalente a `docker-compose down`, ya que elimina todos los recursos (pods, services, deployments, configmaps, secrets, PVCs) de una vez. Los PersistentVolumes deben eliminarse por separado ya que están fuera del namespace.

## Notas Importantes

1. **Logs**: Fluent Bit (DaemonSet) recolecta los logs de los pods y los envía directamente a Elasticsearch con índice `pharmago-logs-*`. Kibana se usa para visualizarlos.

2. **PersistentVolumes**: Los PVs usan `hostPath` que es adecuado para desarrollo pero no para producción. En producción, usa storage classes apropiadas.

3. **Secrets**: La contraseña de la base de datos está en texto plano en el secret. Para producción, considera usar herramientas como Sealed Secrets o external secret managers.

4. **Health Checks**: Los deployments incluyen health checks básicos. Asegúrate de que tus aplicaciones expongan endpoints `/health` o ajusta las configuraciones según corresponda.

5. **Recursos**: Los límites de recursos están configurados de forma conservadora. Ajusta según las necesidades de tu entorno.

## Estructura de Archivos

```
k8s/
├── namespace.yaml
├── configmaps/
│   ├── prometheus-config.yaml
│   ├── otel-collector-config.yaml
│   ├── grafana-provisioning.yaml
│   └── fluent-bit-config.yaml
├── secrets/
│   └── db-secret.yaml
├── persistent-volumes/
│   ├── sql-pv.yaml
│   ├── elasticsearch-pv.yaml
│   ├── prometheus-pv.yaml
│   └── grafana-pv.yaml
├── deployments/
│   ├── frontend/
│   │   └── ui-deployment.yaml
│   ├── backend/
│   │   ├── api-gateway-deployment.yaml
│   │   ├── users-service-deployment.yaml
│   │   └── pharmacy-service-deployment.yaml
│   └── ops/
│       ├── db-deployment.yaml
│       ├── otel-collector-deployment.yaml
│       ├── prometheus-deployment.yaml
│       ├── grafana-deployment.yaml
│       ├── elasticsearch-deployment.yaml
│       ├── kibana-deployment.yaml
│       └── fluent-bit-daemonset.yaml
├── services/
│   ├── frontend/
│   │   └── ui-service.yaml
│   ├── backend/
│   │   ├── api-gateway-service.yaml
│   │   ├── users-service-service.yaml
│   │   └── pharmacy-service-service.yaml
│   └── ops/
│       ├── db-service.yaml
│       ├── otel-collector-service.yaml
│       ├── prometheus-service.yaml
│       ├── grafana-service.yaml
│       ├── elasticsearch-service.yaml
│       └── kibana-service.yaml
├── build-images.sh
├── apply-k8s.sh
├── cleanup.sh
└── README-k8s.md
```

