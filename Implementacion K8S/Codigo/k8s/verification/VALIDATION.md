# Evidencia de validacion - 2026-11-15

## Cambios implementados

- Cuatro Deployments con RollingUpdate 0/1, minReadySeconds 10, preStop 10 s,
  gracia 30 s y progressDeadlineSeconds 300.
- Readiness HTTP; Users/Pharmacy verifican SQL sin acoplarlo a liveness.
- PDB por aplicacion, selectores exactos y minAvailable 1.
- Actualizador comun Node con wrappers Bash/PowerShell, imagenes versionadas,
  comprobaciones funcionales, rollback y verificacion de recuperacion.
- Instalador separado que rechaza instalaciones/PV existentes y no elimina
  volumenes. Migracion inicial explicita; los pods Users de Kubernetes no migran
  al arrancar. Compose/desarrollo conservan su comportamiento previo.
- Observador interno por Services y exportador que comprueba integridad de logs.

## Pruebas locales ejecutadas

- Node: 10 pruebas aprobadas, 0 fallidas y 1 omitida. La omitida requiere crear
  symlinks en Windows; el montaje ConfigMap real se valido despues en Kubernetes.
  Incluye rollback simulado, fallo funcional, fallo de rollback, concurrencia,
  manifiestos reales en dry-run de cliente, exportacion e identificacion de 503.
- Gateway: 57 pruebas existentes aprobadas con DOTNET_ROLL_FORWARD=Major sobre
  runtime .NET 8 local, porque no estaba instalado el runtime .NET 6.
- Users y Pharmacy compilan. Las imagenes reales de los tres backends se
  construyeron posteriormente con SDK/runtime .NET 6 mediante sus Dockerfiles.
- Frontend construido mediante su Dockerfile. Persisten advertencias previas de
  paquetes/CSS/nullability; no se hizo una actualizacion de dependencias.
- Sintaxis Node, PowerShell y Bash comprobada; git diff --check sin errores.
- Deployments, PDB y observador aceptados en dry-run del API server.

## Ensayo Kubernetes ejecutado

Entorno: perfil Minikube existente, un nodo Kubernetes v1.37.0. Se inicio el
perfil que estaba detenido, sin recrearlo. La preparacion inicial no se conto
como evidencia de continuidad: Pharmacy partia de 0/2 Ready por un endpoint
readiness 404 en la imagen antigua. Se recupero a 2/2 con las imagenes v1.

La primera ejecucion del observador no midio trafico por la resolucion de
symlinks de ConfigMap. Se corrigio y se agrego una marca de arranque con readiness.
Esa ejecucion vacia no se uso como evidencia.

Ventana valida: **19:38:11.853Z a 19:48:11.818Z**, aproximadamente 600 s.
Cinco rutas, cada 2500 ms, sin reintentos ni redirecciones automaticas:

| Ruta | Solicitudes | Errores |
|---|---:|---:|
| UI /, con contenido Angular esperado | 240 | 0 |
| Users /api/roles, array JSON | 240 | 0 |
| Pharmacy /api/drug, array JSON | 240 | 0 |
| Gateway -> Users /api/roles | 240 | 0 |
| Gateway -> Pharmacy /api/drug | 240 | 0 |
| Total | 1200 | 0 |

La ventana incluye el intento de Pharmacy con una imagen inexistente, manteniendo
sus dos replicas saludables. El Deployment alcanzo su deadline de progreso y el
script restauro automaticamente la especificacion v2, verifico disponibilidad,
endpoints y GET funcional y salio con codigo 1 por la actualizacion fallida.

Despues se reemplazaron los cuatro componentes de v2 a v3, con el observador
activo durante todo el recorrido:

| Aplicacion | Inicio UTC | Fin UTC |
|---|---|---|
| Pharmacy | 19:44:06 | 19:45:10 |
| Users | 19:45:10 | 19:45:51 |
| Gateway | 19:45:51 | 19:46:22 |
| UI | 19:46:22 | 19:46:44 |

Las versiones del ensayo contienen el mismo codigo funcional y tags/etiquetas
de imagen diferentes. Esto acredita reemplazo de pods; no prueba compatibilidad
de futuros cambios de esquema, contratos o assets Angular.

Los cuatro PVC conservaron nombre, UID, volumen y estado Bound antes/despues.
SQL y los Services no fueron reemplazados por el actualizador. Los GET de roles
y medicamentos devolvieron arrays vacios; no se insertaron datos de prueba ni
se ensayaron escrituras/concurrencia o restauracion de backups.

Se verifico ademas un ultimo ajuste de Users a `rollout-20261115-v4`: preserva la
migracion de arranque anterior para Compose/desarrollo y la desactiva de forma
explicita en Kubernetes. Ventana adicional de unos 180 s: **365 solicitudes
(73 por ruta), 0 errores**, exportadas en `traffic-users-v4/`. Total de ambas
ventanas: **1565 solicitudes, 0 errores**. Estado final disponible: UI/Gateway
1/1 en v3, Pharmacy 2/2 en v3 y Users 1/1 en v4. El observador temporal se retiro
despues de exportar los registros y se cerro el proxy local de la prueba.

## Archivos de evidencia local

Desde la raiz del repositorio, `artifacts/rolling-update-20261115/` contiene logs
de construccion, preparacion, reemplazo, rollback, snapshots de PVC y
`traffic/{observer.log,requests.csv,summary.json}`. El exportador verifico que los
conteos del resumen coincidan con cada fila de logs. Estos artefactos estan
ignorados por Git; conservarlos junto al video si se requieren como entrega.

## Limites y pendientes

- No se ensayo falla de nodo ni HA de SQL. RollingUpdate no aporta esas garantias.
- No se ensayo en vivo una imagen que arranca con readiness fallida ni una
  regresion funcional con readiness exitosa; el orquestador tiene cobertura
  simulada y el procedimiento describe como reproducir esos casos.
- No se forzaron respuestas largas, sesiones/streams persistentes ni carga maxima.
- La instalacion inicial nueva no se ejecuto sobre este entorno con datos.
- El manifiesto SQL recomienda ahora 2Gi; no se aplico al SQL existente durante
  este ensayo para evitar un reinicio Recreate. Su ajuste requiere mantenimiento
  separado. El ensayo no convierte la configuracion anterior en recomendada.
- Los cero errores son observaciones de estas rutas y ventanas, no una garantia
  absoluta del 100% ni de instantes no muestreados.

Procedimiento reproducible y guion del video: [ROLLING-UPDATE.md](../ROLLING-UPDATE.md).
