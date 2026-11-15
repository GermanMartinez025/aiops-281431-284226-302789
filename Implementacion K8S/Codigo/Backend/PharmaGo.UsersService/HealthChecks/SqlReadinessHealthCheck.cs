using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Diagnostics.HealthChecks;

namespace PharmaGo.UsersService.HealthChecks;

public sealed class SqlReadinessHealthCheck : IHealthCheck
{
    private readonly DbContext _dbContext;
    public SqlReadinessHealthCheck(DbContext dbContext) => _dbContext = dbContext;

    public async Task<HealthCheckResult> CheckHealthAsync(
        HealthCheckContext context, CancellationToken cancellationToken = default)
    {
        try
        {
            return await _dbContext.Database.CanConnectAsync(cancellationToken)
                ? HealthCheckResult.Healthy()
                : HealthCheckResult.Unhealthy("Database readiness check failed.");
        }
        catch (Exception) when (!cancellationToken.IsCancellationRequested)
        {
            return HealthCheckResult.Unhealthy("Database readiness check failed.");
        }
    }
}
