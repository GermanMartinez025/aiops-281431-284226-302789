using PharmaGo.UsersService.Factory;
using PharmaGo.UsersService.Filters;
using System.Diagnostics.CodeAnalysis;
using Instrumentation;
using PharmaGo.UsersService.HealthChecks;
using Microsoft.AspNetCore.Diagnostics.HealthChecks;

var migrateOnly = args.Contains("--migrate-database");
var builder = WebApplication.CreateBuilder(args.Where(arg => arg != "--migrate-database").ToArray());
builder.Services.Configure<HostOptions>(options => options.ShutdownTimeout = TimeSpan.FromSeconds(15));

builder.Logging.SuppressEfAndSqlClientLogs();

builder.Services.AddHttpContextAccessor();
builder.Services.RegisterBusinessLogicServices(builder.Configuration);
builder.Services.RegisterDataAccessServices(builder.Configuration);
builder.Services.AddControllers(options => options.Filters.Add(typeof(ExceptionFilter)));

builder.Services.AddControllers();

builder.Services.AddHealthChecks()
    .AddCheck<SqlReadinessHealthCheck>("sql", tags: new[] { "ready" }, timeout: TimeSpan.FromSeconds(2));

builder.Services.AddPharmaGoOpenTelemetryMetrics("PharmaGo.UsersService");

builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();

builder.Services.AddCors(options =>
{
    options.AddPolicy("MyAllowedOrigins",
        policy =>
        {
            policy.WithOrigins("*")
                .AllowAnyHeader()
                .AllowAnyMethod();
        });
});

var app = builder.Build();

// Kubernetes desactiva la migracion al iniciar cada pod. Se conserva el
// comportamiento previo para desarrollo/Compose; el Job usa --migrate-database.
if (migrateOnly || builder.Configuration.GetValue("Database:MigrateOnStartup", true))
{
    app.MigrateDatabase();
    if (migrateOnly) return;
}
if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

app.UseCors("MyAllowedOrigins");
app.UseServiceCorrelationScope();

app.UseAuthorization();

app.MapHealthChecks("/health", new HealthCheckOptions { Predicate = _ => false });
app.MapHealthChecks("/health/ready", new HealthCheckOptions
{
    Predicate = check => check.Tags.Contains("ready")
});
app.UseMetricsMiddleware();

app.MapControllers();
app.MapPrometheusScrapingEndpoint();

app.Run();

[ExcludeFromCodeCoverage]
public partial class Program { }

