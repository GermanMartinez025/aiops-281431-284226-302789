#!/bin/sh
# Chaos: CPU spike en pod. Uso: ./cpu-spike.sh [deployment] [segundos]
DEPLOY="${1:-pharmago-api-gateway}"
SECS="${2:-30}"
POD=$(kubectl get pod -n pharmago -l app="$DEPLOY" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$POD" ]; then
  echo "Error: no hay pods con app=$DEPLOY en el namespace pharmago."
  echo "  Verifica el nombre (ej: pharmago-api-gateway, pharmago-users-service)"
  exit 1
fi
echo "CPU spike: $POD (${SECS}s)"
kubectl exec -n pharmago "$POD" -- sh -c "(while :;do :;done)& (while :;do :;done)& (while :;do :;done)& (while :;do :;done)& sleep $SECS"
