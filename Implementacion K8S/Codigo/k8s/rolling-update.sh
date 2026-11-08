#!/bin/bash
# Despliegue seguro (Rolling Update) de un componente de PharmaGo sin pérdida de disponibilidad.
# Construye una imagen con tag versionado, la carga en Minikube, actualiza el Deployment
# y espera el rollout. Si el rollout falla, hace rollback automático a la revisión anterior.
#
# Uso:   ./rolling-update.sh <users|pharmacy|gateway|ui> [version]
# Ej.:   ./rolling-update.sh users v1.2.0

set -e

COMPONENT="$1"
VERSION="${2:-$(date +%Y%m%d-%H%M%S)}"
NAMESPACE="pharmago"

case "$COMPONENT" in
    users)    NAME="pharmago-users-service";    CONTEXT="Backend";  DOCKERFILE="PharmaGo.UsersService/Dockerfile" ;;
    pharmacy) NAME="pharmago-pharmacy-service"; CONTEXT="Backend";  DOCKERFILE="PharmaGo.PharmacyService/Dockerfile" ;;
    gateway)  NAME="pharmago-api-gateway";      CONTEXT="Backend";  DOCKERFILE="PharmaGo.ApiGateway/Dockerfile" ;;
    ui)       NAME="pharmago-ui";               CONTEXT="Frontend"; DOCKERFILE="Dockerfile" ;;
    *) echo "Uso: $0 <users|pharmacy|gateway|ui> [version]"; exit 1 ;;
esac

IMAGE="$NAME:$VERSION"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CODE_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Rolling Update de $NAME -> $IMAGE ==="

echo ""
echo "1. Construyendo imagen..."
(cd "$CODE_DIR/$CONTEXT" && docker build -f "$DOCKERFILE" -t "$IMAGE" .)

echo ""
echo "2. Cargando imagen en Minikube..."
minikube image load "$IMAGE"

echo ""
echo "3. Actualizando Deployment (maxSurge=1, maxUnavailable=0)..."
kubectl set image "deployment/$NAME" "$NAME=$IMAGE" -n "$NAMESPACE"
kubectl annotate "deployment/$NAME" "kubernetes.io/change-cause=Rolling update a $IMAGE" -n "$NAMESPACE" --overwrite > /dev/null

echo ""
echo "4. Esperando rollout..."
if ! kubectl rollout status "deployment/$NAME" -n "$NAMESPACE" --timeout=300s; then
    echo ""
    echo "Rollout fallido. Ejecutando rollback a la revisión anterior..."
    kubectl rollout undo "deployment/$NAME" -n "$NAMESPACE"
    kubectl rollout status "deployment/$NAME" -n "$NAMESPACE" --timeout=300s
    exit 1
fi

echo ""
echo "=== $NAME actualizado a $IMAGE sin downtime ==="
kubectl rollout history "deployment/$NAME" -n "$NAMESPACE"
kubectl get pods -n "$NAMESPACE" -l "app=$NAME" -o wide
