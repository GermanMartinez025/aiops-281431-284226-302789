## 1. Objetivo y alcance

Este plan define cómo detectar, contener y recuperar incidentes que afecten la disponibilidad o el funcionamiento de PharmaGo. Ante una falla, la prioridad es reducir el impacto y restablecer el servicio, la investigación de la causa raíz puede continuar después.

El alcance incluye Frontend, API Gateway, Users, Pharmacy, SQL Server, Kubernetes y las herramientas de observabilidad. Se prioriza la consulta de medicamentos a través del Gateway, sin dejar de verificar cualquier otra operación afectada.

La arquitectura actual dispone de dos réplicas de Pharmacy y una réplica para los demás servicios. Todas se ejecutan en un único nodo Minikube y Pharmacy depende de una sola instancia de SQL Server. Por lo tanto, la recuperación automática de un pod no garantiza continuidad ante una caída del nodo o de la base de datos.

## 2. Responsables y severidad

Durante un incidente se utiliza un canal acordado para coordinar, compartir evidencias y registrar decisiones. Al ser un equipo pequeño, el Incident Commander también cubre comunicación y registro hasta que pueda delegarlos.

| Rol | Asignado a | Responsabilidad |
|---|---|---|
| **Incident Commander** | Agustín | Coordina la respuesta, establece la severidad, prioriza las acciones y centraliza la comunicación. |
| **Responders** | Germán y Franco | Investigan el incidente, analizan métricas y logs, ejecutan las acciones de mitigación y verifican la recuperación. |
| **Stakeholders** | A definir | Reciben información sobre el impacto, las acciones realizadas y el estado de recuperación del servicio. |

### Distribución del trabajo

- **Agustín — Incident Commander:** declara y clasifica el incidente, define la prioridad, asigna responsables por tarea, mantiene el resumen y el registro de decisiones, comunica actualizaciones y evita cambios incompatibles. Se concentra en coordinar, los cambios en Kubernetes o la aplicación los realizan los Responders.
- **Germán — Responder, frente Pharmacy y datos:** toma inicialmente la investigación de Pharmacy y SQL Server, incluyendo disponibilidad, operaciones afectadas y consistencia de compras y stock.
- **Franco — Responder, frente Gateway y plataforma:** toma inicialmente la investigación del Gateway, Kubernetes y telemetría, incluyendo rate limiting y circuit breaker.
- Antes de cambiar el sistema, quien ejecuta notifica la acción, el componente, el efecto esperado y cómo comprobar o revertir el cambio. Se evalúa una intervención a la vez y se registra el resultado.
- Agustín informa a Responders y Stakeholders cuando se declara el incidente, al cambiar el impacto o la estrategia, al recuperarse el servicio y al hacer un traspaso. Si el incidente se prolonga, fija una cadencia de actualización (por ejemplo, cada 10 minutos). Si no hay novedades, comunica que la investigación continúa.
- Si Agustín debe retirarse, acuerda el traspaso con la persona entrante: situación e impacto actuales, acciones realizadas, riesgos, siguiente decisión y responsable de cada tarea. Anuncia el cambio al grupo y espera confirmación explícita antes de dejar la coordinación.
- Tras estabilizar el servicio, se cierra la respuesta y se registran las tareas de seguimiento con responsable y próximo paso. La revisión posterior busca causas y mejoras, sin atribuir culpas.

Con tres personas no se abre por defecto un rol separado de comunicaciones u operaciones. Si se suma alguien, Agustín puede delegar las actualizaciones o el registro para liberar capacidad de coordinación. Debe mantenerse una sola voz de coordinación y un responsable claro por acción operativa.

---

| Nivel | Criterio | Prioridad |
| --- | --- | --- |
| **Alto** | Las operaciones principales no funcionan o falla una dependencia sin alternativa. | Restablecer el servicio de inmediato. |
| **Medio** | Hay errores intermitentes o degradación importante, pero el servicio funciona parcialmente. | Limitar el impacto y recuperar estabilidad. |
| **Bajo** | Hay una anomalía acotada, sin impacto significativo sobre las operaciones. | Registrar, observar y corregir de forma controlada. |

Estos niveles son criterios internos del equipo.

## 3. Detección y diagnóstico

El diagnóstico comienza por las alertas de Grafana y Prometheus, continúa con los logs en Kibana y Elasticsearch y, cuando corresponde, con las trazas distribuidas en Jaeger. Si los servicios de observabilidad no están disponibles, se consulta directamente el estado de Kubernetes y se comprueba una operación funcional.

## 4. Procedimiento de respuesta

1. **Confirmar:** verificar el síntoma con la telemetría. Registrar la hora de inicio de la afectación.
2. **Clasificar:** identificar la operación afectada, los componentes involucrados y la severidad.
3. **Contener:** priorizar las acciones que reduzcan el impacto, evitando cambios simultáneos que dificulten evaluar sus efectos.
4. **Recuperar:** aplicar el procedimiento correspondiente al escenario. Aprovechar los mecanismos automáticos y realizar intervenciones manuales solo cuando sean necesarias.
5. **Validar:** comprobar que el servicio responda, que los componentes necesarios estén saludables y que errores y latencia se estabilicen.
6. **Cerrar:** registrar la hora de recuperación, la medida aplicada y las mejoras pendientes.

## 5. Escenarios de contención y recuperación

| Incidente | Acción recomendada | Cómo validar |
| --- | --- | --- |
| **Caída de un pod** | Revisar eventos, logs y reinicios. Permitir que Kubernetes reponga o reinicie el contenedor cuando corresponda. Intervenir si no se recupera. | Pod `Ready` y operación afectada funcional. |
| **Pharmacy no responde** | Revisar las dos réplicas y los endpoints del Service. Si ambas están `NotReady`, comprobar primero SQL Server. | Dos réplicas disponibles y `GET /api/drug` exitoso a través del Gateway. |
| **SQL Server no disponible** | Revisar pod, eventos, logs, Service `pharmago-db` y PVC `sql-pvc`. | SQL accesible, readiness de Pharmacy restablecida y consulta de datos correcta. |
| **CPU o memoria saturadas** | Identificar el pod, reducir o eliminar la carga anormal cuando se pueda identificar con seguridad. | Recursos estables y solicitudes sin degradación relevante. |
| **Almacenamiento saturado** | Identificar el filesystem y el origen del consumo. Liberar únicamente archivos temporales prescindibles y confirmados. | Espacio disponible y operaciones de lectura/escritura normales. |
| **Tráfico excesivo** | Comprobar el rate limiting del Gateway y distinguir las respuestas `429` de fallas del servidor. Investigar y limitar el origen del tráfico anómalo si continúa la degradación. | Tráfico estabilizado y solicitudes legítimas atendidas. |
| **Falla de red o de una dependencia** | Revisar conectividad, DNS, Services y endpoints. Restablecer la dependencia. | Comunicación recuperada y solicitudes completas exitosas. |
| **Error tras un despliegue** | Identificar el cambio y la imagen en ejecución. Realizar rollback únicamente si existe una revisión estable, recuperable y compatible. | Versión esperada, pods saludables y operación afectada correcta. |
| **Pérdida de observabilidad** | Revisar Collector, Prometheus, Fluent Bit, Elasticsearch, Kibana o Jaeger según la señal ausente. | Vuelven a recibirse métricas, logs o trazas recientes. |

## 6. Consultas operativas básicas

Confirmar primero que se está trabajando en el contexto y namespace correctos:

```bash
kubectl config current-context
kubectl get nodes -o wide
kubectl get pods -n pharmago -o wide
kubectl get deployments -n pharmago
kubectl get events -n pharmago --sort-by=.lastTimestamp
```

Para analizar un componente afectado, reemplazar `<pod>` por su nombre real:

```bash
kubectl describe pod <pod> -n pharmago
kubectl logs <pod> -n pharmago --tail=100
kubectl get endpointslices -n pharmago
```

Para comprobar la recuperación del Deployment de Pharmacy:

```bash
kubectl rollout status deployment/pharmago-pharmacy-service -n pharmago --timeout=120s
```

Además del estado de Kubernetes, ejecutar `GET /api/drug` **a través del Gateway** y verificar cualquier otra operación afectada. Si hubo una escritura interrumpida, comprobar su resultado antes de reintentarla, especialmente en compras y actualizaciones de stock.

## 7. Verificación, cierre y aprendizaje

El incidente se considera contenido cuando su impacto deja de aumentar y se dispone de una medida de mitigación efectiva. Se considera recuperado cuando:

- Los componentes necesarios están `Ready` y tienen endpoints disponibles.
- Las operaciones afectadas responden correctamente a través del flujo habitual.
- Los errores y la latencia vuelven a valores normales o aceptables con tráfico representativo.
- No se observan nuevas fallas durante un período de seguimiento acorde con el incidente.

Registrar al menos:

| Campo | Información |
| --- | --- |
| Incidente e inicio | Descripción, fecha/hora y primera evidencia. |
| Impacto | Operaciones y componentes afectados; severidad. |
| Diagnóstico | Alertas, métricas, logs, trazas y eventos relevantes. |
| Acciones | Medidas aplicadas, responsables, horarios y resultados. |
| Recuperación | Hora de restablecimiento y verificaciones funcionales. |
| Seguimiento | Causa probable, acciones correctivas y mejoras pendientes. |

Después del cierre se realiza una revisión breve para identificar la causa, evaluar la respuesta y definir acciones que reduzcan la posibilidad o el impacto de futuras fallas.
