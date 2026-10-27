# Guía de Logging con Elasticsearch + Kibana + Logstash - PharmaGo

## 📋 Configuración Implementada

### Stack de Logging Completo

**3 componentes:**
1. **Elasticsearch**: Almacenamiento y búsqueda de logs (puerto 9200)
2. **Kibana**: Visualización y consulta de logs (puerto 5601)
3. **Logstash**: Recopilación y procesamiento de logs (puerto 5044, 9600)

### Arquitectura

**Docker Compose:**
```
Contenedores Docker (stdout/stderr) → Archivos JSON → Logstash → Elasticsearch → Kibana
```

**Kubernetes (K8s):**
```
Pods (stdout/stderr) → Fluent Bit (DaemonSet) → Elasticsearch → Kibana
```
En K8s, **Fluent Bit** recolecta los logs de los pods y los envía a Elasticsearch con índice `pharmago-logs-*`.

## 🚀 Estado Actual

### Servicios Funcionando

- ✅ **Elasticsearch**: http://127.0.0.1:9200
- ✅ **Kibana**: http://127.0.0.1:5601
- ✅ **Logstash**: Recopilando logs de contenedores Docker

### Verificar que Funciona

1. **Verificar que hay índices en Elasticsearch** (antes de crear el data view):
   ```powershell
   Invoke-WebRequest -Uri "http://127.0.0.1:9200/_cat/indices?v" -UseBasicParsing
   ```
   Deberías ver índices `pharmago-logs-YYYY.MM.DD`. Si no hay ninguno, espera 2–3 minutos tras el despliegue para que Fluent Bit empiece a enviar logs (en K8s).

2. **Accede a Kibana**: http://127.0.0.1:5601
2. **Crea un Data View** (antes "Index Pattern" en Kibana 8+):
   - Ve a **Stack Management** → **Data Views** (o menú ☰ → Management → Data Views)
   - Click en **Create data view**
   - En **Name**: `pharmago-logs`
   - En **Index pattern**: `pharmago-logs-*`
   - En **Timestamp field**: `@timestamp`
   - Click en **Save data view to Kibana**

3. **Ver Logs en Discover**:
   - Ve a **Discover** en el menú lateral
   - En el selector superior, selecciona el data view `pharmago-logs`
   - Deberías ver logs de tus servicios

## 📊 Cómo Usar los Logs

### 1. Ver Logs en Kibana

1. Accede a Kibana: http://127.0.0.1:5601
2. Ve a **Discover**
3. Selecciona el data view `pharmago-logs`
4. Verás todos los logs de tus servicios

### 2. Filtrar Logs por Servicio

En la barra de búsqueda de Kibana:

```
kubernetes.labels.app: "pharmago-users-service"
```
o por namespace: `kubernetes.namespace_name: "pharmago"`

### 3. Buscar Logs de Login

Los mensajes del backend son:
- Éxito: `User X logged in successfully`
- Fallo: `User X failed log in`

**En Kibana**, Elasticsearch tokeniza el texto; palabras como "in" pueden ignorarse. Prueba:

```
# Opción 1: wildcards (más fiable)
log: *logged* or log: *failed*

# Opción 2: si el campo es "message"
message: *logged* or message: *failed*

# Opción 3: Lucene (cambiar KQL → Lucene en el selector de la barra)
log:*logged* OR log:*failed*
```

Si no encuentra nada, abre un documento de log para ver en qué campo está el texto real (`log`, `message`, `msg`, etc.) y usa ese campo.

**Test rápido:** Llama al login y comprueba que los logs aparecen:
1. Haz login en la app (http://127.0.0.1:4200) o llama al API:
   ```powershell
   Invoke-RestMethod -Uri "http://127.0.0.1:5000/api/login" -Method POST -ContentType "application/json" -Body '{"userName":"admin@pharmago.com","password":"Str0ngP@ssword!"}'
   ```
2. En Kibana, abre **Discover**, selecciona el data view `pharmago-logs`.
3. En la barra de búsqueda, cambia a **Lucene** y usa: `log:*logged* OR log:*failed*`
4. Deberías ver el log "User X logged in successfully" o "User X failed log in".

### 4. Búsquedas Avanzadas

```
# Buscar errores
log: *Error* OR log: *Exception*

# Buscar por nivel
log: *Warning* OR log: *Error*

# Combinar con servicio (filtrar en la columna kubernetes.labels.app)
log: *Rate limit*
```

### 5. Verificar Logs en Elasticsearch

```powershell
# Verificar que hay logs indexados
Invoke-WebRequest -Uri "http://127.0.0.1:9200/pharmago-logs-*/_count" -UseBasicParsing

# Ver algunos logs
Invoke-WebRequest -Uri "http://127.0.0.1:9200/pharmago-logs-*/_search?size=5" -UseBasicParsing
```

## 🔧 Configuración Actual

### Recolección de logs

**Docker Compose:** Logstash lee archivos JSON de Docker y envía a Elasticsearch.

**K8s:** Fluent Bit (DaemonSet) lee logs de `/var/log/containers` y envía a Elasticsearch con índice `pharmago-logs-YYYY.MM.DD`.

### Elasticsearch

- **Puerto HTTP**: 9200
- **Puerto Transport**: 9300
- **Seguridad**: Deshabilitada (para desarrollo)
- **Memoria**: 512MB (configurable)

### Kibana

- **Puerto**: 5601
- **Conectado a**: Elasticsearch en http://elasticsearch:9200

## 📈 Crear Dashboards en Kibana

### Dashboard Básico de Logs

1. Ve a **Dashboard** → **Create Dashboard**
2. Agrega visualizaciones:
   - **Logs por servicio** (Pie chart)
   - **Logs en el tiempo** (Line chart)
   - **Top errores** (Data table)
   - **Logs recientes** (Logs viewer)

### Visualización: Logs por Servicio

1. **Visualize** → **Create Visualization** → **Pie**
2. Selecciona el data view `pharmago-logs`
3. Agrega un bucket: **Split slices**
4. Agrega términos por campo: `service.keyword`
5. Guarda la visualización

### Visualización: Logs en el Tiempo

1. **Visualize** → **Create Visualization** → **Line**
2. Selecciona el data view `pharmago-logs`
3. Agrega eje X: **Date Histogram** por `@timestamp`
4. Agrega eje Y: **Count**
5. Guarda la visualización

## 🔍 Troubleshooting

### Problema: Kibana dice "no match any data streams, indices..."

**Causa:** No hay índices en Elasticsearch que coincidan con `pharmago-logs-*`.

**Solución (K8s):**
1. Verifica índices existentes:
   ```powershell
   Invoke-WebRequest -Uri "http://127.0.0.1:9200/_cat/indices?v" -UseBasicParsing
   ```
2. Si no hay `pharmago-logs-*`, comprueba Fluent Bit:
   ```bash
   kubectl get pods -n pharmago -l k8s-app=fluent-bit-logging
   kubectl logs -n pharmago -l k8s-app=fluent-bit-logging --tail=50
   ```
3. Espera 2–3 minutos tras el despliegue para que lleguen los primeros logs.
4. Si usas Docker Compose, verifica Logstash: `docker ps | grep logstash`

### Problema: No veo logs en Kibana (data view creado pero vacío)

**Solución:**
1. Verifica que Elasticsearch tenga datos:
   ```powershell
   Invoke-WebRequest -Uri "http://127.0.0.1:9200/pharmago-logs-*/_count" -UseBasicParsing
   ```
2. Verifica que el data view esté creado en Kibana (Stack Management → Data Views)

### Problema: Logstash no recopila logs

**Solución:**
1. Verifica que los contenedores estén generando logs:
   ```bash
   docker logs pharmago-api-gateway --tail 10
   ```
2. Verifica que Logstash tenga acceso a los archivos:
   ```bash
   docker exec logstash ls -la /var/lib/docker/containers/ | Select-Object -First 5
   ```
3. Revisa los logs de Logstash: `docker logs logstash`

### Problema: Elasticsearch no responde

**Solución:**
1. Verifica que Elasticsearch esté corriendo: `docker ps | grep elasticsearch`
2. Verifica los logs: `docker logs elasticsearch`
3. Verifica el health: http://127.0.0.1:9200/_cluster/health

## 📚 Recursos

- **Kibana Documentation**: https://www.elastic.co/guide/en/kibana/current/index.html
- **Elasticsearch Documentation**: https://www.elastic.co/guide/en/elasticsearch/reference/current/index.html
- **Logstash Documentation**: https://www.elastic.co/guide/en/logstash/current/index.html

## ✅ Checklist

- [x] Elasticsearch configurado y funcionando
- [x] Kibana configurado y funcionando
- [x] Logstash configurado y funcionando
- [ ] Data view creado en Kibana (`pharmago-logs-*`)
- [ ] Dashboard básico creado
- [ ] Logs verificados en Kibana

## 💡 Próximos Pasos

1. **Crear data view** en Kibana: Stack Management → Data Views → Create data view (`pharmago-logs-*`)
2. **Explorar logs** en Discover
3. **Crear dashboards** personalizados
4. **Configurar alertas** (opcional)
