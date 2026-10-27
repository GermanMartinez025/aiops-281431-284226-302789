# Test Rate Limiting

Script simple para probar el rate limiting del API Gateway.

## Uso

```bash
cd tutoriales/rate-limit
chmod +x test-rate-limit.sh
./test-rate-limit.sh
```

O directamente:

```bash
bash tutoriales/rate-limit/test-rate-limit.sh
```

## Qué hace

- Envía 120 peticiones GET a `/api/drug`
- Espera 0.1 segundos entre cada petición
- Muestra cuántas fueron exitosas (200) y cuántas fueron bloqueadas (429)

## Resultado esperado

Si el rate limiting está activo:
- ~100 peticiones exitosas
- ~20 peticiones bloqueadas con código 429

## Requisitos

- API Gateway corriendo en `http://127.0.0.1:5000`
- Rate limiting configurado (modo IP o User)

