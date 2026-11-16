# Reemplazo controlado de aplicaciones

## Alcance y tecnica

Se usa RollingUpdate para Frontend, Gateway/YARP, Users y Pharmacy. Las replicas
permanentes son 1/1/1/2. Cada Deployment permite un pod adicional (`maxSurge: 1`)
y no retira disponibilidad deseada voluntariamente (`maxUnavailable: 0`). El
reemplazo debe mantenerse Ready durante 10 s antes de que el controlador lo
considere Available (`minReadySeconds: 10`). No hace falta aumentar las replicas
permanentes para este reemplazo planificado.

Los Services conservan su identidad y seleccionan los pods por `app`. Readiness
excluye pods no preparados: Users y Pharmacy comprueban conexion SQL; Gateway
comprueba el host HTTP/proxy inicializado; UI sirve su pagina. Gateway no se
retira en cascada si una dependencia falla: la funcionalidad completa se verifica
con GET de negocio por separado. Liveness no depende de SQL.

Al terminar, el pod espera 10 s con preStop para permitir la propagacion de la
retirada de endpoints y despues recibe la senal de parada. .NET recibe SIGTERM
directamente y dispone de un ShutdownTimeout de 15 s; Nginx usa SIGQUIT para
apagado ordenado. La gracia total es 30 s, incluyendo preStop. Este presupuesto
requiere solicitudes que finalicen dentro de la ventana restante; no garantiza
preservar sesiones/streams arbitrariamente largos. Para esos casos hay que
medirlos y ampliar coordinadamente los tiempos, no prometer continuidad sin prueba.

Los PDB (`policy/v1`, `minAvailable: 1`) son uno por aplicacion con selectores
exactos. Limitan desalojos via Eviction, no el RollingUpdate del Deployment.
Con una replica impiden su desalojo voluntario sin reemplazo. No evitan una falla
del nodo, un delete directo de pods ni una falla de SQL.

SQL tiene una replica, almacenamiento local y estrategia Recreate. No se lo
reemplaza durante la actualizacion de aplicaciones. Lo mismo aplica a la
infraestructura de observabilidad. Este procedimiento no ofrece disponibilidad
absoluta, failover de SQL ni reemplazo sin cortes de TODOS los componentes de
infraestructura. El alcance academico demostrado debe explicitar esta diferencia.

## Requisitos previos

- Node >= 18 (para los scripts; el observador usa Node 22), kubectl, Docker,
  Minikube y PowerShell o Bash. Los wrappers comparten el mismo motor Node.
- Contexto `minikube` y namespace `pharmago`. Para otro contexto usar `--context`;
  el constructor usa `--profile` con el mismo nombre que el contexto.
- SQL/schema disponibles, contratos compatibles entre version anterior y nueva.
  Este cambio no agrega migraciones de esquema. Users ya no migra al iniciar un
  pod (`Database__MigrateOnStartup=false`): la instalacion inicial ejecuta un Job
  explicito con `--migrate-database`. Compose/desarrollo conservan la migracion
  de arranque anterior salvo configuracion explicita.
  Las futuras migraciones se revisan y ejecutan separadamente, con estrategia
  expand/contract. Un rollback de imagen no deshace una migracion destructiva.
- Una base completamente disponible con imagenes versionadas para actualizaciones
  normales. El script rechaza bases con replicas no disponibles o imagen `latest`.
- Capacidad para un surge de 128Mi y 50m (UI) o 128Mi y 100m (cada backend), mas
  consumo real de sistema y pods terminando. No usar solo requests como prueba.
  Actualizar uno por vez. No ejecutar cleanup, borrar namespace, PV ni PVC.

## Preparar una base estable existente (una vez)

Si se utiliza el entorno ya validado de esta entrega, la base esta preparada
(ver [resultados](verification/VALIDATION.md)): omitir bootstrap e ir directamente
a actualizacion y evidencia. Construir tags nuevos para el video; no reutilizar
los tags de la validacion.

Este paso NO es una demostracion de cero cortes: corrige una instalacion antigua
o no saludable. No borrar datos. Primero comprobar el esquema SQL existente.

Desde `Codigo/k8s`:

```powershell
.\build-images.ps1 -Tag rollout-v1
kubectl --context minikube -n pharmago get deployments,pods,pvc
# Terminal independiente; permanece abierta. El proxy NO se liga a un pod.
kubectl --context minikube proxy --port=8001
```

En otra terminal PowerShell, tambien desde `k8s`:

```powershell
$proxy = 'http://127.0.0.1:8001/api/v1/namespaces/pharmago/services'
.\update-app.ps1 -App pharmacy -Image pharmago-pharmacy-service:rollout-v1 -Bootstrap -ProbeUrl "$proxy/pharmago-pharmacy-service:80/proxy/api/drug" -ExpectBody '['
.\update-app.ps1 -App users -Image pharmago-users-service:rollout-v1 -Bootstrap -ProbeUrl "$proxy/pharmago-users-service:80/proxy/api/roles" -ExpectBody '['
.\update-app.ps1 -App gateway -Image pharmago-api-gateway:rollout-v1 -Bootstrap -ProbeUrl "$proxy/pharmago-api-gateway:80/proxy/api/drug" -ExpectBody '['
.\update-app.ps1 -App ui -Image pharmago-ui:rollout-v1 -Bootstrap -ProbeUrl "$proxy/pharmago-ui:80/proxy/" -ExpectBody '<app-root'
kubectl --context minikube -n pharmago get deployments,pdb,pods
```

`--bootstrap` omite la exigencia de base saludable, pero verifica el resultado.
Si falla intenta restaurar la especificacion anterior; una base ya rota puede
seguir rota y se informa ROLLBACK NO VERIFICADO. No llamarlo recuperacion exitosa.
Si falta el esquema, detenerse y preparar una migracion explicita; no desactivar
readiness para esconder el fallo.

Para instalacion nueva: construir `rollout-v1` y ejecutar
`.\apply-k8s.ps1 -Tag rollout-v1`. El instalador se niega a operar si el namespace
o los PV del proyecto existen, no borra recursos y se detiene ante fallos. No
utilizarlo para reparar/reinstalar la instalacion existente.

## Actualizacion y rollback automatico

Construir/cargar otra version sin sobrescribir tags:

```powershell
.\build-images.ps1 -Tag rollout-v2
.\update-app.ps1 -App pharmacy -Image pharmago-pharmacy-service:rollout-v2 -ProbeUrl "$proxy/pharmago-api-gateway:80/proxy/api/drug" -ExpectBody '['
```

Repetir uno por vez para Users, Gateway y UI, usando sus imagenes. Para Users
usar el recorrido Gateway `/api/roles`; para Gateway probar `/api/drug` y observar
tambien `/api/roles`; para UI usar su pagina. Un GET exitoso aislado no demuestra
continuidad: mantener el observador del apartado siguiente durante todo el cambio.

Bash usa los mismos argumentos del motor Node:

```bash
./build-images.sh --tag rollout-v2 --app pharmacy
./update-app.sh --app pharmacy --image pharmago-pharmacy-service:rollout-v2 \
  --probe-url http://127.0.0.1:8001/api/v1/namespaces/pharmago/services/pharmago-api-gateway:80/proxy/api/drug --expect-body '['
```

El actualizador:

1. Comprueba la base y la URL funcional antes de mutar. Captura la especificacion
   anterior en memoria; no modifica Services, SQL ni volumenes.
2. Lee la plantilla del repositorio e inyecta la imagen nueva en una unica
   operacion sobre el Deployment. Usa resourceVersion para detectar cambios
   concurrentes. Aplica los PDB.
3. Espera `rollout status --timeout=300s`. Ademas del timeout externo, los
   Deployments tienen `progressDeadlineSeconds: 300`.
4. Verifica replicas completas, imagen esperada, endpoints Ready y GET funcional.
5. Ante error/timeout restaura la especificacion capturada, espera otros 300 s y
   comprueba estado, endpoints y GET. Sale con codigo 1 incluso si recupero:
   la actualizacion fallo. Si no pudo verificar recuperacion lo dice explicitamente.
   No revierte una plantilla modificada por otro operador.

Las imagenes anteriores deben conservarse en Docker/Minikube. Los scripts
rechazan tags mutables comunes y el constructor rechaza tags locales existentes;
otros operadores tambien deben respetar no sobrescribirlos. La pausa de 10 s no
es una prueba de ausencia de cortes, y Kubernetes no hace rollback por si solo.

## Evidencia reproducible y guion para el video

No usar port-forward de un Service como medidor de continuidad: se liga a un
pod y puede caer al reemplazarlo. El proxy API anterior sirve para verificaciones
puntuales; la evidencia de trafico por Services la obtiene el observador interno.

Antes de cada ensayo, con todas las aplicaciones saludables:

```powershell
kubectl --context minikube -n pharmago create configmap rolling-update-observer --from-file=availability.mjs=verification/availability.mjs --dry-run=client -o yaml | kubectl --context minikube -n pharmago apply -f -
kubectl --context minikube -n pharmago apply -f verification/observer.yaml
kubectl --context minikube -n pharmago wait --for=condition=Ready pod/rolling-update-observer --timeout=120s
kubectl --context minikube -n pharmago logs -f pod/rolling-update-observer
```

El observador realiza GET sin reintentos por 420 s, cada 2,5 s por ruta: UI,
roles de Users, medicamentos de Pharmacy y ambos recorridos via Gateway. Valida
HTTP 200 y contenido esperado/array JSON; registra tambien timeouts y 429 como
fallos. La frecuencia de `/api/drug` via Gateway queda por debajo de 60/min;
evitar otros generadores que consuman ese presupuesto. Registra CSV y resumen.
No comprueba escrituras, navegador completo ni carga maxima: esos ensayos deben
agregarse si el alcance de la demostracion los incluye.

La convivencia de versiones requiere tambien compatibilidad de assets del
Frontend: este ensayo de reemplazo puede usar el mismo codigo con imagenes
versionadas diferentes. Si cambia el contenido Angular, conservar los assets
anteriores durante la transicion y probar navegacion/carga de JS y CSS; una
respuesta 200 del HTML sola no acredita esa compatibilidad.

Guion:

1. Mostrar estrategia, replicas, probes, lifecycle y PDB del repositorio y del
   clúster. Registrar imagenes/imageID y UID de los PVC antes del cambio.
2. Iniciar el observador y registrar al menos 15 s de base. En otra terminal:
   `kubectl --context minikube -n pharmago get pods -w`.
3. Ejecutar un solo update-app con la imagen v2. Mostrar coexistencia de versiones
   y salida del actualizador. Seguir observando al menos 30 s despues de completar.
4. Esperar la finalizacion del observador y conservar logs:
   `kubectl --context minikube -n pharmago logs rolling-update-observer > evidencia-pharmacy.txt`.
   Confirmar resumen `passed: true`, `failures: 0` y codigo terminado 0.
   Exportar CSV, resumen y logs con integridad de conteos (tambien funciona con
   el pod terminado; no depende de `kubectl cp`):
   `kubectl --context minikube -n pharmago logs rolling-update-observer | node verification/export-evidence.mjs --out artifacts/pharmacy`.
   No borrar el observador antes de guardar su evidencia.
5. Borrar SOLO ese pod observador terminado, repetir los pasos para cada otra
   aplicacion y guardar salidas por separado.
6. Ensayo de fallo: desde base v2, repetir con observador nuevo y una imagen
   inexistente, por ejemplo `pharmago-pharmacy-service:video-no-existe-20261115`.
   `imagePullPolicy: Never` deja el nuevo pod sin arrancar. Mostrar timeout,
   ROLLBACK VERIFICADO, version v2 recuperada y continuidad del trafico anterior.
   El observador dura 420 s, suficiente para el timeout mas una recuperacion normal;
   ampliarlo si la recuperacion necesita mas, nunca recortar errores del registro.
7. Repetir con imagen que arranca pero cuya readiness falla (construida para el
   ensayo), y verificar tambien fallo funcional con readiness exitosa. No
   presentar las pruebas simuladas locales como ensayos reales de estos casos.
8. Registrar PV/PVC despues y comprobar una lectura de datos conocida. Para
   solicitudes en curso usar conexiones keep-alive y respuestas representativas
   que duren cerca del presupuesto de drenaje. El observador reutiliza conexiones,
   pero no fuerza respuestas largas; ese caso necesita un ensayo adicional.

Para un monitor local usar `node verification/availability.mjs --targets '[...]'
--seconds 420 --out artifacts/ensayo`. Debe usar un endpoint estable que atraviese
el Service, nunca un port-forward al pod reemplazado.

## Validacion y limites de la afirmacion

Pruebas locales: `node --test verification/update-app.test.mjs`. Cubren rechazo de
base rota/mutable, exito, fallo de rollout, fallo funcional, rollback fallido,
actualizacion concurrente y deteccion HTTP real de un 503. Son pruebas del
orquestador con kubectl simulado y del monitor local, no un ensayo Kubernetes.

El criterio del video es **cero errores observados en todas las solicitudes de
las ventanas registradas**. Conservar carga, frecuencia, rutas, duracion, imagenes,
salidas y limites. No es una prueba matematica de 100% ni cubre instantes no
muestreados. Una sola maquina y SQL sin redundancia impiden prometer disponibilidad
absoluta. Si el requerimiento incluye reemplazar SQL o tolerar falla del nodo,
RollingUpdate de estas cuatro aplicaciones no alcanza y debe declararse pendiente.

Referencias: [Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/),
[terminacion](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination),
[disrupciones/PDB](https://kubernetes.io/docs/concepts/workloads/pods/disruptions/).
