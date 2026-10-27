# Guía de Rate Limiting - API Gateway

## 🎯 Problema: ¿Por IP o por Usuario?

### ❌ Problema con Rate Limiting por IP

Cuando tu frontend está desplegado (React, Angular, etc.), **todas las peticiones vienen desde el servidor del frontend**, no desde el navegador del usuario:

```
Usuario A (navegador) ──┐
Usuario B (navegador) ──┼──> Frontend Server (1 IP) ──> API Gateway
Usuario C (navegador) ──┘
```

**Resultado:** Los 3 usuarios comparten el mismo límite de peticiones → ❌ Bloqueos injustos

### Otros Escenarios Problemáticos:

1. **Usuarios corporativos**: Toda una empresa detrás de 1 IP pública
2. **ISPs con NAT**: Miles de usuarios con la misma IP
3. **CDN/Load Balancer**: Peticiones vienen desde IPs del CDN

## ✅ Soluciones Implementadas

### Opción 1: Rate Limiting por Usuario (Recomendado)

**Cómo funciona:**
- Usa el **token de autenticación** como identificador
- Cada usuario tiene su propio límite
- Para endpoints públicos (login), usa IP como fallback

**Configuración en `appsettings.json`:**

```json
{
  "RateLimiting": {
    "Mode": "User",
    "MaxRequestsPerMinute": 100,
    "MaxRequestsPerHour": 1000
  }
}
```

**Ventajas:**
- ✅ Cada usuario tiene su propio límite
- ✅ Funciona con frontend desplegado
- ✅ Justo para todos los usuarios
- ✅ Usa IP como fallback para endpoints públicos

**Desventajas:**
- ⚠️ Usuarios sin autenticar comparten límite por IP
- ⚠️ Requiere que el frontend envíe el token en cada petición

### Opción 2: Rate Limiting por IP

**Cómo funciona:**
- Usa la IP del cliente (con soporte para proxies)
- Lee headers `X-Forwarded-For` y `X-Real-IP`

**Configuración en `appsettings.json`:**

```json
{
  "RateLimiting": {
    "Mode": "IP"
  },
  "IpRateLimiting": {
    "EnableEndpointRateLimiting": true,
    "RealIpHeader": "X-Real-IP",
    "GeneralRules": [
      {
        "Endpoint": "POST:/api/login",
        "Period": "1m",
        "Limit": 10
      },
      {
        "Endpoint": "*",
        "Period": "1m",
        "Limit": 500
      }
    ]
  }
}
```

**Ventajas:**
- ✅ Simple de implementar
- ✅ Funciona sin autenticación
- ✅ Protege contra ataques DDoS básicos

**Desventajas:**
- ❌ Múltiples usuarios pueden compartir IP
- ❌ Puede bloquear usuarios legítimos

### Opción 3: Deshabilitado (Desarrollo)

**Configuración:**

```json
{
  "RateLimiting": {
    "Mode": "Disabled"
  }
}
```

**Uso:** Solo para desarrollo local

## 🔧 Configuración Recomendada por Ambiente

### Desarrollo Local (`appsettings.Development.json`)

```json
{
  "RateLimiting": {
    "Mode": "Disabled"
  }
}
```

### Producción (`appsettings.json`)

```json
{
  "RateLimiting": {
    "Mode": "User",
    "MaxRequestsPerMinute": 100,
    "MaxRequestsPerHour": 1000
  },
  "IpRateLimiting": {
    "EndpointWhitelist": [
      "get:/health",
      "get:/metrics"
    ],
    "GeneralRules": [
      {
        "Endpoint": "POST:/api/login",
        "Period": "1m",
        "Limit": 10
      }
    ]
  }
}
```

## 📝 Cómo Funciona el Rate Limiting por Usuario

### 1. Identificación del Usuario

El middleware intenta identificar al usuario en este orden:

```csharp
1. Header "Authorization" → Usa el token
2. Header "X-User-Id" → Usa el ID de usuario (si el frontend lo envía)
3. Fallback → Usa la IP (para endpoints públicos)
```

### 2. Ejemplo de Petición desde el Frontend

```javascript
// Frontend (React/Angular/Vue)
const response = await fetch('http://localhost:5000/api/drug', {
  headers: {
    'Authorization': 'Bearer abc123...',  // ← Esto se usa para rate limiting
    'Content-Type': 'application/json'
  }
});
```

### 3. Contadores Independientes

Cada usuario tiene sus propios contadores:

```
Usuario "token:abc123":
  - Minuto actual: 45/100 peticiones
  - Hora actual: 320/1000 peticiones

Usuario "token:xyz789":
  - Minuto actual: 12/100 peticiones
  - Hora actual: 89/1000 peticiones
```

## 🌐 Configuración para Frontend Desplegado

### Si tu frontend está en un servidor separado:

1. **Asegúrate de que el frontend envíe el token:**

```javascript
// Configuración global de axios (ejemplo)
axios.defaults.headers.common['Authorization'] = `Bearer ${token}`;
```

2. **Usa Mode: "User" en producción:**

```json
{
  "RateLimiting": {
    "Mode": "User"
  }
}
```

3. **Configura CORS correctamente:**

```json
{
  "AllowedOrigins": [
    "https://tu-frontend.com",
    "https://www.tu-frontend.com"
  ]
}
```

### Si tu frontend está en el mismo servidor (SSR):

Puedes usar `Mode: "IP"` con límites más altos:

```json
{
  "RateLimiting": {
    "Mode": "IP"
  },
  "IpRateLimiting": {
    "GeneralRules": [
      {
        "Endpoint": "*",
        "Period": "1m",
        "Limit": 5000
      }
    ]
  }
}
```

## 🧪 Testing

### Probar Rate Limiting por Usuario

```bash
# 1. Obtener un token
TOKEN=$(curl -X POST http://localhost:5000/api/login \
  -H "Content-Type: application/json" \
  -d '{"email":"test@test.com","password":"pass"}' \
  | jq -r '.token')

# 2. Hacer 150 peticiones con el mismo token
for i in {1..150}; do
  curl -H "Authorization: Bearer $TOKEN" \
    http://localhost:5000/api/drug
done
# Las últimas 50 deberían dar 429
```

### Probar Rate Limiting por IP

```bash
# Hacer 600 peticiones sin token
for i in {1..600}; do
  curl http://localhost:5000/api/drug
done
# Las últimas 100 deberían dar 429
```

## 📊 Monitoreo

### Logs del Rate Limiting

```
[Warning] Rate limit exceeded for user:abc123: Exceeded 100 requests per minute
[Warning] Rate limit exceeded for ip:192.168.1.1: Exceeded 500 requests per minute
```

### Métricas de Prometheus

Puedes crear métricas personalizadas para monitorear:

```csharp
// En UserRateLimitMiddleware.cs
private static readonly Counter RateLimitExceeded = Metrics
    .CreateCounter("rate_limit_exceeded_total", "Total rate limit violations",
        new CounterConfiguration { LabelNames = new[] { "identifier_type" } });

// Al bloquear una petición
RateLimitExceeded.WithLabels(identifier.StartsWith("user:") ? "user" : "ip").Inc();
```

## 🎛️ Ajustes Finos

### Límites Diferentes por Endpoint

```json
{
  "IpRateLimiting": {
    "GeneralRules": [
      {
        "Endpoint": "POST:/api/login",
        "Period": "1m",
        "Limit": 5
      },
      {
        "Endpoint": "GET:/api/drug/*",
        "Period": "1m",
        "Limit": 200
      },
      {
        "Endpoint": "POST:/api/purchases",
        "Period": "1m",
        "Limit": 20
      }
    ]
  }
}
```

### Whitelist de IPs (Servidores Internos)

```json
{
  "IpRateLimitPolicies": {
    "IpRules": [
      {
        "Ip": "10.0.0.0/8",
        "Rules": [
          {
            "Endpoint": "*",
            "Period": "1s",
            "Limit": 0
          }
        ]
      }
    ]
  }
}
```

### Whitelist de Endpoints (Health Checks)

```json
{
  "IpRateLimiting": {
    "EndpointWhitelist": [
      "get:/health",
      "get:/metrics",
      "get:/swagger/*"
    ]
  }
}
```

## 🚀 Recomendación Final

Para tu caso (frontend desplegado):

1. **Usa `Mode: "User"`** en producción
2. **Usa `Mode: "Disabled"`** en desarrollo
3. **Asegúrate de que el frontend envíe el token** en el header `Authorization`
4. **Configura límites razonables:**
   - Login: 10/minuto (previene brute force)
   - Otros endpoints: 100/minuto por usuario
   - Total por hora: 1000 por usuario

```json
{
  "RateLimiting": {
    "Mode": "User",
    "MaxRequestsPerMinute": 100,
    "MaxRequestsPerHour": 1000
  }
}
```

Esto te da:
- ✅ Protección contra abuso
- ✅ Cada usuario tiene su propio límite
- ✅ Funciona con frontend desplegado
- ✅ Fallback a IP para endpoints públicos

