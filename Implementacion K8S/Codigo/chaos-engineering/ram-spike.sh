#!/bin/sh
# Chaos: RAM spike en pod. Uso: ./ram-spike.sh [deployment] [MB]
DEPLOY="${1:-pharmago-api-gateway}"
MB="${2:-200}"
POD=$(kubectl get pod -n pharmago -l app="$DEPLOY" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$POD" ]; then
  echo "Error: no hay pods con app=$DEPLOY en el namespace pharmago."
  exit 1
fi
echo "RAM spike: $POD (${MB}MB)"
kubectl exec -n pharmago "$POD" -- sh -c "dd if=/dev/zero of=/dev/shm/fill bs=1M count=$MB 2>/dev/null || dd if=/dev/zero of=/tmp/fill bs=1M count=$MB"
