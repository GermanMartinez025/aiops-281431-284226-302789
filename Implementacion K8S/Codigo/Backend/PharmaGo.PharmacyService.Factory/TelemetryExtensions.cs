using Microsoft.Extensions.DependencyInjection;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using OpenTelemetry.Exporter;
using System.Diagnostics;

namespace PharmaGo.PharmacyService.Factory
{
    public static class OpenTelemetryExtensions
    {
        public static IServiceCollection AddPharmaGoOpenTelemetryMetrics(this IServiceCollection services, string serviceName = "PharmaGo.PharmacyService")
        {
            services.AddOpenTelemetry()
                    .WithMetrics(metricsBuilder => { metricsBuilder
                    .SetResourceBuilder(ResourceBuilder.CreateDefault().AddService(serviceName))
                    .AddAspNetCoreInstrumentation()
                    .AddHttpClientInstrumentation()
                    .AddMeter("PharmaGo.CustomMetrics")
                    .AddPrometheusExporter()
                    .AddOtlpExporter(ConfigureOtlpExporter);
                    })
                    // Trazas distribuidas: requests entrantes, llamadas HTTP salientes y consultas SQL, exportadas por OTLP
                    .WithTracing(tracingBuilder => tracingBuilder
                        .SetResourceBuilder(ResourceBuilder.CreateDefault().AddService(serviceName))
                        .AddAspNetCoreInstrumentation(options => options.Filter = IsTraceableRequest)
                        .AddHttpClientInstrumentation()
                        .AddSqlClientInstrumentation(options => options.SetDbStatementForText = true)
                        .AddOtlpExporter(ConfigureOtlpExporter));

            return services;
        }

        private static void ConfigureOtlpExporter(OtlpExporterOptions options)
        {
            options.Endpoint = new Uri("http://otlp-collector:4317");
            options.Protocol = OtlpExportProtocol.Grpc;
        }

        // Excluye probes y scraping de métricas para no llenar el backend de trazas con ruido
        private static bool IsTraceableRequest(Microsoft.AspNetCore.Http.HttpContext context) =>
            !context.Request.Path.StartsWithSegments("/health") &&
            !context.Request.Path.StartsWithSegments("/metrics");
    }
}

