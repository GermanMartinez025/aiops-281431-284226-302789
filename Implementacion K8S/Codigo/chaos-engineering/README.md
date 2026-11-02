# Chaos Engineering

Requiere: app en K8s + port-forward activo.

| Script | Uso |
|--------|-----|
| `cpu-spike.sh` | `./cpu-spike.sh [deploy] [seg]` |
| `ram-spike.sh` | `./ram-spike.sh [deploy] [MB]` |
| `volume-spike.sh` | `./volume-spike.sh [deploy] [MB]` |
| `load-requests.sh` | `./load-requests.sh [N] [url]` |

Default deploy: pharmago-api-gateway

**Ver impacto en Grafana:** Dashboard "PharmaGo - Infra" → paneles "CPU por pod (pharmago)" y "Memoria por pod (pharmago)".

## Trabajo de consistencia pendiente

Las operaciones de compras y stock quedan fuera de este ejercicio de operaciones y se posponen para un trabajo específico de consistencia. La revisión de código encontró que `PurchasesManager` separa el descuento de stock y el guardado del estado de la compra, y que `StockRequestManager` separa la lectura y escritura de stock sin control explícito de concurrencia. Con varias instancias de Pharmacy esto puede permitir actualizaciones perdidas, doble procesamiento o estados parciales. El circuit breaker de Gateway no corrige esos problemas ni hace atómicas las escrituras. Antes de depender de varias instancias para escrituras, queda pendiente diseñar y validar el manejo transaccional y de concurrencia.

## Circuit breaker Gateway → Pharmacy

La configuración activa un circuit breaker en el pipeline YARP únicamente para `pharmacy-cluster`: cinco fallos consecutivos abren el circuito durante 15 segundos. Se cuentan errores de transporte hacia Pharmacy y respuestas 502, 503 o 504. No cuentan errores 4xx, 429, errores HTTP 500 genéricos ni fallos de lectura o escritura del cliente. No hay reintentos ni repetición de solicitudes.

Mientras está abierto, el Gateway devuelve 503 con `Retry-After`; al entrar en half-open se permite una sola solicitud GET como sonda. Las demás solicitudes quedan rechazadas hasta que esa sonda GET cierre el circuito correctamente. Las transiciones se registran en logs. El clúster Pharmacy tiene además `ActivityTimeout` de 30 segundos, que limita el período sin actividad al reenviar; no es un límite total de duración ni revierte escrituras ya confirmadas.

El estado del circuito vive en memoria por proceso y se reinicia con el Gateway. Por eso, en una instalación con varias réplicas de Gateway cada instancia mantiene su propio circuito; una falla aislada de una instancia Pharmacy tampoco debería abrirlo salvo que produzca cinco fallos consecutivos observados por ese Gateway. Esta configuración no demuestra alta disponibilidad ni consistencia de datos. Se agregó una suite MSTest que ejecuta el middleware real con contextos HTTP en memoria, un delegado local como backend y el reloj controlado para validar apertura, rechazo, recuperación GET y clasificación de errores. El backend falso no abre conexiones de red; el ejecutor de pruebas puede usar IPC local. La guía y el alcance están en `Backend/PharmaGo.ApiGateway.Tests/README.md`. Estas pruebas aisladas no validan el pipeline completo alojado de YARP ni el despliegue en Kubernetes, que siguen pendientes.
