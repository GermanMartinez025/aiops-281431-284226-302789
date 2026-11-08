#!/bin/sh
# Chaos: llenar disco/ephemeral en pod. Uso: ./volume-spike.sh [deployment] [MB]
DEPLOY="${1:-pharmago-api-gateway}"
MB="${2:-300}"
POD=$(kubectl get pod -n pharmago -l app="$DEPLOY" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$POD" ]; then
  echo "Error: no hay pods con app=$DEPLOY en el namespace pharmago."
  exit 1
fi
echo "Volume spike: $POD (${MB}MB)"
kubectl exec -n pharmago "$POD" -- sh -c "dd if=/dev/zero of=/tmp/chaos_fill bs=1M count=$MB"
