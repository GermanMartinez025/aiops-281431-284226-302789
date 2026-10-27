using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Builder;
using System.Diagnostics;
using InstrumentationInterface;

namespace Instrumentation
{
    /// <summary>
    /// Middleware que captura automáticamente métricas de todos los endpoints:
    /// - Cantidad de invocaciones por endpoint
    /// - Latencia/duración de cada request
    /// - Tasa de errores (status codes 4xx y 5xx)
    /// </summary>
    public class MetricsMiddleware
    {
        private readonly RequestDelegate _next;
        private readonly ICustomMetrics _metrics;

        public MetricsMiddleware(RequestDelegate next, ICustomMetrics metrics)
        {
            _next = next;
            _metrics = metrics;
        }

        public async Task InvokeAsync(HttpContext context)
        {
            var stopwatch = Stopwatch.StartNew();
            var endpoint = context.Request.Path.Value ?? "/";
            var method = context.Request.Method;

            try
            {
                await _next(context);
                stopwatch.Stop();

                // Registrar la petición exitosa
                var statusCode = context.Response.StatusCode;
                _metrics.RecordHttpRequest(endpoint, method, statusCode);
                _metrics.RecordEndpointDuration(endpoint, method, stopwatch.Elapsed.TotalMilliseconds);

                // Registrar como error si el status code es 4xx o 5xx
                if (statusCode >= 400)
                {
                    var errorType = statusCode >= 500 ? "server_error" : "client_error";
                    _metrics.RecordError(endpoint, errorType);
                }
            }
            catch (Exception ex)
            {
                stopwatch.Stop();

                // Registrar la excepción
                _metrics.RecordHttpRequest(endpoint, method, 500);
                _metrics.RecordEndpointDuration(endpoint, method, stopwatch.Elapsed.TotalMilliseconds);
                _metrics.RecordError(endpoint, ex.GetType().Name);

                // Re-lanzar la excepción para que sea manejada por otros middlewares
                throw;
            }
        }
    }

    /// <summary>
    /// Extension method para registrar el middleware fácilmente
    /// </summary>
    public static class MetricsMiddlewareExtensions
    {
        public static IApplicationBuilder UseMetricsMiddleware(this IApplicationBuilder builder)
        {
            return builder.UseMiddleware<MetricsMiddleware>();
        }
    }
}

