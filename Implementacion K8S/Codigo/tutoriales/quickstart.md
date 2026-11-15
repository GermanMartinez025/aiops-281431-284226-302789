# Quickstart K8s - PharmaGo

```bash
# 1. Minikube
minikube start --memory=8192 --cpus=4

# 2. Imágenes (desde Implementacion K8S/Codigo)
cd k8s
./build-images.sh --tag inicio-v1

# 3. Instalacion NUEVA (namespace y PV del proyecto deben estar ausentes)
./apply-k8s.sh --tag inicio-v1

# 4. Port-forward (Windows: usar 127.0.0.1)
./port-forward.sh
```

**URLs:** http://127.0.0.1:4200 | :5000 | :3000 | :5601 | :9090

Para una instalacion existente no ejecutar de nuevo el instalador. Usar
[actualizacion controlada y guion de video](../k8s/ROLLING-UPDATE.md).
Los port-forwards sirven para acceso local; no miden continuidad al reemplazar
el pod al que quedaron ligados.
