# Cómo Ajustar Rate Limiting

## Modo IP

Editar `Backend/PharmaGo.ApiGateway/appsettings.json`:

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
        "Limit": 100    // ← Cambiar aquí
      },
      {
        "Endpoint": "*",
        "Period": "1h",
        "Limit": 1000   // ← Cambiar aquí
      }
    ]
  }
}
```

## Modo User

1. **Configuración** (`appsettings.json`):
```json
{
  "RateLimiting": {
    "Mode": "User",
    "MaxRequestsPerMinute": 100,  // ← Cambiar
    "MaxRequestsPerHour": 1000     // ← Cambiar
  }
}
```

2. **Código** (`UserRateLimitMiddleware.cs`):
```csharp
private const int MaxRequestsPerMinute = 100;  // ← Cambiar
private const int MaxRequestsPerHour = 1000;   // ← Cambiar
```

## Deshabilitar

```json
{
  "RateLimiting": {
    "Mode": "Disabled"
  }
}
```

## Endpoints Específicos

```json
{
  "IpRateLimiting": {
    "GeneralRules": [
      {
        "Endpoint": "POST:/api/login",
        "Period": "1m",
        "Limit": 10  // Login más restrictivo
      }
    ]
  }
}
```

