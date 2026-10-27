using Microsoft.Extensions.DependencyInjection;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
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
                    .AddOtlpExporter(options =>
                        {
                            options.Endpoint = new Uri("http://otlp-collector:4317");
                            options.Protocol = OtlpExportProtocol.Grpc;
                        });
                    });

            return services;
        }
    }
}

