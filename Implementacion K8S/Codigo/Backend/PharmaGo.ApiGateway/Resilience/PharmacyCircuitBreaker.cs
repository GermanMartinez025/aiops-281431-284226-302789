using Polly;
using Polly.CircuitBreaker;

namespace PharmaGo.ApiGateway.Resilience;

public sealed class PharmacyCircuitBreaker
{
    public const string PharmacyClusterId = "pharmacy-cluster";

    public PharmacyCircuitBreaker(IConfiguration configuration, ILogger<PharmacyCircuitBreaker> logger)
    {
        var section = configuration.GetSection("CircuitBreaker:Pharmacy");
        Enabled = section.GetValue<bool>("Enabled");

        var failureThreshold = section.GetValue<int>("FailureThreshold");
        var breakDurationSeconds = section.GetValue<int>("BreakDurationSeconds");
        if (failureThreshold <= 0)
        {
            throw new InvalidOperationException("CircuitBreaker:Pharmacy:FailureThreshold must be positive.");
        }

        if (breakDurationSeconds <= 0)
        {
            throw new InvalidOperationException("CircuitBreaker:Pharmacy:BreakDurationSeconds must be positive.");
        }

        BreakDuration = TimeSpan.FromSeconds(breakDurationSeconds);
        Policy = Policy<bool>
            .HandleResult(isFailure => isFailure)
            .CircuitBreakerAsync(
                failureThreshold,
                BreakDuration,
                onBreak: (_, duration) => logger.LogWarning(
                    "Pharmacy circuit breaker opened for {BreakDurationSeconds} seconds.",
                    duration.TotalSeconds),
                onReset: () => logger.LogInformation("Pharmacy circuit breaker closed after a successful probe."),
                onHalfOpen: () => logger.LogInformation("Pharmacy circuit breaker is half-open; allowing one GET probe."));
    }

    public bool Enabled { get; }

    public TimeSpan BreakDuration { get; }

    public AsyncCircuitBreakerPolicy<bool> Policy { get; }
}
