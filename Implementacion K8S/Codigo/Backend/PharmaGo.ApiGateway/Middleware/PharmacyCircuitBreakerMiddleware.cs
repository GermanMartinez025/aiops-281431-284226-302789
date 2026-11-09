using Microsoft.AspNetCore.Http;
using System.Globalization;
using Polly.CircuitBreaker;
using PharmaGo.ApiGateway.Resilience;
using Yarp.ReverseProxy.Forwarder;

namespace PharmaGo.ApiGateway.Middleware;

public sealed class PharmacyCircuitBreakerMiddleware
{
    private readonly RequestDelegate _next;
    private readonly PharmacyCircuitBreaker _circuitBreaker;
    private readonly ILogger<PharmacyCircuitBreakerMiddleware> _logger;

    public PharmacyCircuitBreakerMiddleware(
        RequestDelegate next,
        PharmacyCircuitBreaker circuitBreaker,
        ILogger<PharmacyCircuitBreakerMiddleware> logger)
    {
        _next = next;
        _circuitBreaker = circuitBreaker;
        _logger = logger;
    }

    public async Task InvokeAsync(HttpContext context)
    {
        if (!_circuitBreaker.Enabled
            || context.GetReverseProxyFeature()?.Cluster.Config.ClusterId != PharmacyCircuitBreaker.PharmacyClusterId)
        {
            await _next(context);
            return;
        }

        var state = _circuitBreaker.Policy.CircuitState;
        if (state != CircuitState.Closed && !HttpMethods.IsGet(context.Request.Method))
        {
            await WriteUnavailableAsync(context);
            return;
        }

        try
        {
            await _circuitBreaker.Policy.ExecuteAsync(async () =>
            {
                await _next(context);

                if (context.RequestAborted.IsCancellationRequested)
                {
                    throw new OperationCanceledException(context.RequestAborted);
                }

                return IsDependencyFailure(context);
            });
        }
        catch (BrokenCircuitException)
        {
            await WriteUnavailableAsync(context);
        }
    }

    private static bool IsDependencyFailure(HttpContext context)
    {
        var error = context.GetForwarderErrorFeature()?.Error;
        if (error is not null && error != ForwarderError.None)
        {
            return error is ForwarderError.Request
                or ForwarderError.RequestTimedOut
                or ForwarderError.RequestBodyDestination
                or ForwarderError.ResponseBodyDestination
                or ForwarderError.UpgradeRequestDestination
                or ForwarderError.UpgradeResponseDestination
                or ForwarderError.NoAvailableDestinations;
        }

        if (context.Response.StatusCode is StatusCodes.Status502BadGateway
            or StatusCodes.Status503ServiceUnavailable
            or StatusCodes.Status504GatewayTimeout)
        {
            return true;
        }

        return false;
    }

    private async Task WriteUnavailableAsync(HttpContext context)
    {
        if (context.Response.HasStarted)
        {
            _logger.LogWarning("Pharmacy circuit breaker rejected a request after the response had started.");
            return;
        }

        context.Response.StatusCode = StatusCodes.Status503ServiceUnavailable;
        context.Response.Headers.RetryAfter = Math.Ceiling(_circuitBreaker.BreakDuration.TotalSeconds)
            .ToString(CultureInfo.InvariantCulture);
        context.Response.ContentType = "text/plain; charset=utf-8";
        await context.Response.WriteAsync("Pharmacy service is temporarily unavailable.", context.RequestAborted);
    }
}
