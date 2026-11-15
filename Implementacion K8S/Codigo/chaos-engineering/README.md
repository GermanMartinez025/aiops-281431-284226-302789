# Experimentos de caos de PharmaGo

Ejecutar desde Bash en el clúster docente. Se requiere `kubectl`, `curl`, `jq` y herramientas GNU básicas en la máquina que lanza el experimento. Las sondas HTTP y las consultas a Prometheus usan URLs de loopback. Preparar el acceso local antes de la ejecución.

```bash
cd 'Implementacion K8S/Codigo/chaos-engineering'
export CONTEXT=minikube NAMESPACE=pharmago
export DEPLOYMENT=pharmago-api-gateway SELECTOR=app=pharmago-api-gateway
export PROBE_URL=http://127.0.0.1:5000/health
export HYPOTHESIS='Durante la ráfaga habrá HTTP 429 y la sonda cumplirá el SLO'
export LOAD_URL=http://127.0.0.1:5000/api/login REQUESTS=2000 CONCURRENCY=20
bash load-requests.sh --dry-run
```

`--dry-run` valida los parámetros sin contactar Kubernetes ni crear evidencia. Para ejecutar, usar el mismo comando sin `--dry-run` después de confirmar el contexto, el objetivo, la intensidad y la ventana de prueba. Si el selector encuentra varias réplicas, definir `POD` explícitamente para los experimentos sobre un pod. Con varios contenedores, indicar `CONTAINER` para CPU, memoria y red.

| Script | Parámetros adicionales | Hipótesis de ejemplo |
|---|---|---|
| `load-requests.sh` | `REQUESTS` 1–2000, `CONCURRENCY` 1–32, `LOAD_URL` | Una ráfaga de login genera 429 mientras la ruta de lectura conserva el SLO. |
| `pod-delete.sh` | `POD` cuando hay más de una réplica Ready | Se repone una réplica en 60 s y la ruta de lectura conserva el SLO. |
| `cpu-spike.sh` | `WORKERS` 1–4 | Aumenta el throttling durante la carga y se recupera la latencia tras detenerla. |
| `ram-spike.sh` | `MEMORY_MIB` 1–256, por defecto 16 | Aumenta la memoria del contenedor sin reinicios y vuelve al rango basal. |
| `network-latency.sh` | `DELAY_MS` 1–1000, por defecto 200, `INTERFACE` por defecto eth0 | La latencia sube en el camino afectado y se recupera al retirar netem. |
| `network-loss.sh` | `LOSS_PCT` 1–10, por defecto 5, `INTERFACE` por defecto eth0 | Aumentan los timeouts o reintentos observados por la ruta afectada. |

`DURATION` fija el plazo de la ráfaga, la búsqueda del reemplazo o la inyección remota (1–300 s, por defecto 30). `BASELINE` configura la observación inicial (5–120 s, por defecto 15). `RECOVERY` acota cada espera de recuperación (10–300 s, por defecto 120). `SLO_P95_MS` y `SLO_SUCCESS_PCT` valen 500 ms y 99 % por defecto. Definirlos según el SLO del equipo y documentar la ruta evaluada. Para las sondas funcionales usar una ruta de lectura representativa con respuesta 2xx. `/health` mide disponibilidad de ese endpoint.

La expulsión usa la API de Eviction con precondición de UID y respeta el PodDisruptionBudget. Requiere dos réplicas listas y permiso para `pods/eviction`. El manifiesto de Gateway trae una réplica. Preparar un Deployment adecuado con al menos dos réplicas antes de este ensayo y usar una URL cuyo tráfico siga alcanzando al Service cuando cambie el pod. Un `kubectl port-forward service/...` puede quedar ligado al pod expulsado y cortar la sonda por fuera del Service.

Memoria requiere un límite finito en cgroups y espacio suficiente en `/dev/shm`. El total proyectado debe quedar por debajo del 80 % del límite. Red requiere `tc`, soporte netem y `NET_ADMIN` en el contenedor del laboratorio. Solo se instala la regla sobre una interfaz con disciplina por defecto `noqueue` o sin disciplina visible. La regla afecta tráfico saliente de esa interfaz. Elegir una ruta que realmente la atraviese y comprobar la retirada en `injection.log`. Si falta soporte, la alternativa es preparar Chaos Mesh con selector del mismo Deployment, modo de una réplica y duración explícita. Los scripts no instalan el operador ni modifican las capabilities.

CPU, memoria y red ejecutan la carga dentro de una sesión remota con plazo propio, cleanup y marcador de parada. Si el cliente pierde conexión, verificar el resultado en el contenedor cuando vuelva el acceso. El vencimiento y las trampas cubren la terminación normal y señales manejables. Una muerte forzada del proceso remoto o del nodo requiere verificar el estado del pod y del recurso antes de repetir.

`OBSERVE_AFTER` agrega entre 0 y 300 segundos de observación tras detectar la recuperación. Por defecto son 15 segundos.

## Rate limiting de login

El manifiesto Kubernetes configura **20 POST a `/api/login` por minuto por IP**, frente a 10 en la configuración base. Es un valor inicial para el laboratorio: tres clientes detrás de una IP, cinco intentos por minuto cada uno y cinco de margen. El script usa un usuario de prueba inexistente, así que una respuesta de credenciales inválidas es esperable en la ráfaga. Confirmar el estado de respuesta esperado con una solicitud basal. Mantener la sonda en una ruta independiente.

Comparar primero 15 intentos repartidos durante un minuto con límites 10 y 20 en la misma topología. Después de dejar vencer la ventana del limitador, repetir una ráfaga con una sola IP. Registrar 429, 5xx, timeouts y éxito de la sonda. El límite está en memoria por instancia, por lo que se debe anotar cuántas instancias atendieron solicitudes y qué IP observó el Gateway. El valor 20 queda como hipótesis de configuración hasta medirlo.

## Evidencia para la defensa

Cada ejecución escribe en `${EVIDENCE_DIR:-./chaos-evidence}/<experiment_id>`. `experiment.txt` registra objetivo, hipótesis y SLO. `timeline.txt` registra inyección, reemplazo, impacto HTTP, recuperación y código de salida. `probe.csv` conserva las muestras HTTP. La ráfaga agrega `load.csv` con respuestas y tiempos por solicitud. Los snapshots contienen Deployment, pods, eventos y logs. Los estados de contenedores incluyen reinicios y motivos de terminación.

Con `PROMETHEUS_URL` (por ejemplo `http://127.0.0.1:9090`), se guardan series de tráfico por código, p50/p95/p99, CPU, throttling y memoria. El script registra la primera alerta nueva de Prometheus observada tras la línea base. Verificar que corresponda al objetivo. Las alertas gestionadas por **Grafana** se verifican en su historial, incluidos los picos anómalos de tráfico HTTP y de red. Anotar la hora en UTC y restar `injection_started_at`. Las reglas de cinco minutos y el scrape de 15 segundos pueden requerir una ventana mayor que la falla. Buscar logs en Kibana y, si la ruta emite trazas, copiar los IDs de Jaeger en la ficha.

El SLO calculado corresponde a la sonda durante la fase de inyección. Se recupera cuando el Deployment vuelve al número esperado de réplicas y hay tres sondas consecutivas en el rango definido. Completar `verdict.txt` como confirmado, refutado o inconcluso según la hipótesis y las señales observadas. Si faltó una alerta, registrar si el umbral no se cruzó, la ventana fue insuficiente o la fuente no estuvo disponible.


## Trabajo de consistencia pendiente

Las operaciones de compras y stock quedan fuera de este ejercicio de operaciones y se posponen para un trabajo específico de consistencia. La revisión de código encontró que `PurchasesManager` separa el descuento de stock y el guardado del estado de la compra, y que `StockRequestManager` separa la lectura y escritura de stock sin control explícito de concurrencia. Con varias instancias de Pharmacy esto puede permitir actualizaciones perdidas, doble procesamiento o estados parciales. El circuit breaker de Gateway no corrige esos problemas ni hace atómicas las escrituras. Antes de depender de varias instancias para escrituras, queda pendiente diseñar y validar el manejo transaccional y de concurrencia.

## Circuit breaker Gateway → Pharmacy

La configuración activa un circuit breaker en el pipeline YARP únicamente para `pharmacy-cluster`: cinco fallos consecutivos abren el circuito durante 15 segundos. Se cuentan errores de transporte hacia Pharmacy y respuestas 502, 503 o 504. No cuentan errores 4xx, 429, errores HTTP 500 genéricos ni fallos de lectura o escritura del cliente. No hay reintentos ni repetición de solicitudes.

Mientras está abierto, el Gateway devuelve 503 con `Retry-After`; al entrar en half-open se permite una sola solicitud GET como sonda. Las demás solicitudes quedan rechazadas hasta que esa sonda GET cierre el circuito correctamente. Las transiciones se registran en logs. El clúster Pharmacy tiene además `ActivityTimeout` de 30 segundos, que limita el período sin actividad al reenviar; no es un límite total de duración ni revierte escrituras ya confirmadas.

El estado del circuito vive en memoria por proceso y se reinicia con el Gateway. Por eso, en una instalación con varias réplicas de Gateway cada instancia mantiene su propio circuito; una falla aislada de una instancia Pharmacy tampoco debería abrirlo salvo que produzca cinco fallos consecutivos observados por ese Gateway. Esta configuración no demuestra alta disponibilidad ni consistencia de datos. Se agregó una suite MSTest que ejecuta el middleware real con contextos HTTP en memoria, un delegado local como backend y el reloj controlado para validar apertura, rechazo, recuperación GET y clasificación de errores. El backend falso no abre conexiones de red; el ejecutor de pruebas puede usar IPC local. La guía y el alcance están en `Backend/PharmaGo.ApiGateway.Tests/README.md`. Estas pruebas aisladas no validan el pipeline completo alojado de YARP ni el despliegue en Kubernetes, que siguen pendientes.
