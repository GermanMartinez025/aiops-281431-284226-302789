using AspNetCoreRateLimit;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Internal;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using System.Net;

namespace PharmaGo.ApiGateway.Tests;

[TestClass]
[DoNotParallelize]
public sealed class RateLimitingTests
{
    [DataTestMethod]
    [DataRow("POST", "/api/login", 10)]
    [DataRow("GET", "/api/drug", 60)]
    [DataRow("POST", "/api/purchases", 20)]
    [DataRow("GET", "/api/purchases/tracking", 30)]
    [DataRow("POST", "/api/export", 5)]
    public async Task ConfiguredPolicyAllowsLimitThenReturns429WithRetryAfter(string method, string path, int limit)
    {
        var backendCalls = 0;
        using var harness = new RateLimiterHarness(_ =>
        {
            Interlocked.Increment(ref backendCalls);
            return Task.CompletedTask;
        });

        for (var request = 0; request < limit; request++)
        {
            var allowed = await harness.SendAsync(method, path, "192.0.2.10");
            Assert.AreEqual(StatusCodes.Status200OK, allowed.StatusCode, $"Request {request + 1} of {limit} should pass.");
        }

        var blocked = await harness.SendAsync(method, path, "192.0.2.10");

        Assert.AreEqual(StatusCodes.Status429TooManyRequests, blocked.StatusCode);
        AssertRetryAfterIsPositiveInteger(blocked.RetryAfter);
        Assert.AreEqual(limit, backendCalls, "The request over quota must not reach the fake backend.");
    }

    [TestMethod]
    public async Task QuotasAreIndependentForDifferentRemoteIps()
    {
        var backendCalls = 0;
        using var harness = new RateLimiterHarness(_ =>
        {
            Interlocked.Increment(ref backendCalls);
            return Task.CompletedTask;
        });

        for (var i = 0; i < 10; i++)
        {
            Assert.AreEqual(StatusCodes.Status200OK, (await harness.SendAsync("POST", "/api/login", "192.0.2.20")).StatusCode);
        }

        Assert.AreEqual(StatusCodes.Status429TooManyRequests,
            (await harness.SendAsync("POST", "/api/login", "192.0.2.20")).StatusCode);
        Assert.AreEqual(StatusCodes.Status200OK,
            (await harness.SendAsync("POST", "/api/login", "192.0.2.21")).StatusCode);
        Assert.AreEqual(11, backendCalls);
    }

    [TestMethod]
    public async Task EndpointAndMethodPoliciesHaveIndependentCounters()
    {
        using var harness = new RateLimiterHarness(_ => Task.CompletedTask);

        for (var i = 0; i < 10; i++)
        {
            Assert.AreEqual(StatusCodes.Status200OK, (await harness.SendAsync("POST", "/api/login", "192.0.2.30")).StatusCode);
        }

        Assert.AreEqual(StatusCodes.Status429TooManyRequests,
            (await harness.SendAsync("POST", "/api/login", "192.0.2.30")).StatusCode);
        Assert.AreEqual(StatusCodes.Status200OK,
            (await harness.SendAsync("GET", "/api/login", "192.0.2.30")).StatusCode,
            "The POST-specific rate limit must not reject a GET to the same path.");
        Assert.AreEqual(StatusCodes.Status200OK,
            (await harness.SendAsync("GET", "/api/drug", "192.0.2.30")).StatusCode,
            "A different configured endpoint must retain its independent quota.");
    }

    [DataTestMethod]
    [DataRow(StatusCodes.Status400BadRequest)]
    [DataRow(StatusCodes.Status401Unauthorized)]
    [DataRow(StatusCodes.Status500InternalServerError)]
    public async Task DownstreamErrorsStillConsumeQuota(int downstreamStatus)
    {
        var backendCalls = 0;
        using var harness = new RateLimiterHarness(context =>
        {
            Interlocked.Increment(ref backendCalls);
            context.Response.StatusCode = downstreamStatus;
            return Task.CompletedTask;
        });

        for (var i = 0; i < 10; i++)
        {
            Assert.AreEqual(downstreamStatus,
                (await harness.SendAsync("POST", "/api/login", "192.0.2.40")).StatusCode);
        }

        var blocked = await harness.SendAsync("POST", "/api/login", "192.0.2.40");

        Assert.AreEqual(StatusCodes.Status429TooManyRequests, blocked.StatusCode);
        Assert.AreEqual(10, backendCalls);
    }

    [DataTestMethod]
    [DataRow("X-Real-IP", "203.0.113.1")]
    [DataRow("X-Forwarded-For", "203.0.113.2")]
    [DataRow("X-ClientId", "client-other")]
    [DataRow("X-User-Id", "user-other")]
    public async Task ClientSuppliedIdentityHeaderDoesNotChangeRemoteIpQuotaKey(string headerName, string forgedValue)
    {
        var backendCalls = 0;
        using var harness = new RateLimiterHarness(_ =>
        {
            Interlocked.Increment(ref backendCalls);
            return Task.CompletedTask;
        });

        for (var i = 0; i < 10; i++)
        {
            Assert.AreEqual(StatusCodes.Status200OK,
                (await harness.SendAsync("POST", "/api/login", "192.0.2.50")).StatusCode);
        }

        var forgedHeader = new Dictionary<string, string> { [headerName] = forgedValue };
        var blocked = await harness.SendAsync("POST", "/api/login", "192.0.2.50", forgedHeader);
        Assert.AreEqual(StatusCodes.Status429TooManyRequests, blocked.StatusCode);
        AssertRetryAfterIsPositiveInteger(blocked.RetryAfter);
        Assert.AreEqual(10, backendCalls, "A forged identity header must not refresh the exhausted IP quota.");
    }

    [TestMethod]
    public async Task QueryPathCaseAndTrailingSlashDoNotBypassConfiguredPolicy()
    {
        using var harness = new RateLimiterHarness(_ => Task.CompletedTask);

        for (var i = 0; i < 10; i++)
        {
            var pathVariant = (i % 3) switch
            {
                0 => "/api/login?next=/account",
                1 => "/API/LOGIN",
                _ => "/api/login/"
            };
            var allowed = await harness.SendAsync("POST", pathVariant, "192.0.2.60");
            Assert.AreEqual(StatusCodes.Status200OK, allowed.StatusCode);
        }

        var blocked = await harness.SendAsync("POST", "/api/login?next=/another", "192.0.2.60");
        Assert.AreEqual(StatusCodes.Status429TooManyRequests, blocked.StatusCode);
        AssertRetryAfterIsPositiveInteger(blocked.RetryAfter);
    }

    [TestMethod]
    public async Task ConcurrentRequestsAdmitExactlyTheConfiguredLoginLimit()
    {
        var backendCalls = 0;
        var start = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseBackend = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var tenthForwarded = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var harness = new RateLimiterHarness(_ =>
        {
            if (Interlocked.Increment(ref backendCalls) == 10)
            {
                tenthForwarded.TrySetResult();
            }

            return releaseBackend.Task;
        });

        var requests = Enumerable.Range(0, 100)
            .Select(_ => Task.Run(async () =>
            {
                await start.Task;
                return await harness.SendAsync("POST", "/api/login", "192.0.2.70");
            }))
            .ToArray();
        start.TrySetResult();

        try
        {
            await tenthForwarded.Task.WaitAsync(TimeSpan.FromSeconds(3));
        }
        finally
        {
            releaseBackend.TrySetResult();
        }

        var responses = await Task.WhenAll(requests).WaitAsync(TimeSpan.FromSeconds(5));

        Assert.AreEqual(10, responses.Count(response => response.StatusCode == StatusCodes.Status200OK));
        Assert.AreEqual(90, responses.Count(response => response.StatusCode == StatusCodes.Status429TooManyRequests));
        Assert.IsTrue(responses.All(response => response.StatusCode is StatusCodes.Status200OK or StatusCodes.Status429TooManyRequests));
        Assert.AreEqual(10, backendCalls);
        foreach (var response in responses.Where(response => response.StatusCode == StatusCodes.Status429TooManyRequests))
        {
            AssertRetryAfterIsPositiveInteger(response.RetryAfter);
        }
    }

    [DataTestMethod]
    [DataRow("GET", "/health")]
    [DataRow("GET", "/metrics")]
    [DataRow("OPTIONS", "/api/login")]
    [DataRow("GET", "/unprotected")]
    public async Task WhitelistedAndUnconfiguredRoutesRemainUnaffected(string method, string path)
    {
        var backendCalls = 0;
        using var harness = new RateLimiterHarness(_ =>
        {
            Interlocked.Increment(ref backendCalls);
            return Task.CompletedTask;
        });

        for (var i = 0; i < 20; i++)
        {
            var response = await harness.SendAsync(method, path, "192.0.2.80");
            Assert.AreEqual(StatusCodes.Status200OK, response.StatusCode, $"Unexpected block on repetition {i + 1}.");
        }

        Assert.AreEqual(20, backendCalls);
    }

    [TestMethod]
    public async Task ExpiredConfiguredWindowAllowsNewRequestsWithoutWaiting()
    {
        var clock = new ManualSystemClock(DateTimeOffset.UtcNow);
        using var harness = new RateLimiterHarness(_ => Task.CompletedTask, clock);

        for (var i = 0; i < 10; i++)
        {
            Assert.AreEqual(StatusCodes.Status200OK,
                (await harness.SendAsync("POST", "/api/login", "192.0.2.90")).StatusCode);
        }

        Assert.AreEqual(StatusCodes.Status429TooManyRequests,
            (await harness.SendAsync("POST", "/api/login", "192.0.2.90")).StatusCode);

        clock.Advance(TimeSpan.FromMinutes(2));

        var afterWindow = await harness.SendAsync("POST", "/api/login", "192.0.2.90");
        Assert.AreEqual(StatusCodes.Status200OK, afterWindow.StatusCode);
    }

    private static void AssertRetryAfterIsPositiveInteger(string? retryAfter)
    {
        Assert.IsTrue(int.TryParse(retryAfter, out var seconds), $"Retry-After should be an integer, got '{retryAfter}'.");
        Assert.IsTrue(seconds > 0, $"Retry-After should be positive, got '{seconds}'.");
    }

    private sealed class RateLimiterHarness : IDisposable
    {
        private readonly ServiceProvider _services;
        private readonly RequestDelegate _pipeline;
        private readonly Func<HttpContext, Task> _next;

        public RateLimiterHarness(Func<HttpContext, Task> next, ISystemClock? clock = null)
        {
            _next = next;
            var configuration = new ConfigurationBuilder()
                .SetBasePath(AppContext.BaseDirectory)
                .AddJsonFile("appsettings.json", optional: false)
                .Build();
            Assert.AreEqual("IP", configuration["RateLimiting:Mode"]);

            var services = new ServiceCollection();
            services.AddLogging();
            services.AddMemoryCache(options =>
            {
                if (clock is not null)
                {
                    options.Clock = clock;
                }
            });
            services.Configure<IpRateLimitOptions>(configuration.GetSection("IpRateLimiting"));
            services.Configure<IpRateLimitPolicies>(configuration.GetSection("IpRateLimitPolicies"));
            services.AddInMemoryRateLimiting();
            services.AddSingleton<IRateLimitConfiguration, RateLimitConfiguration>();
            _services = services.BuildServiceProvider();

            var app = new ApplicationBuilder(_services);
            app.UseIpRateLimiting();
            app.Run(context => _next(context));
            _pipeline = app.Build();

        }

        public async Task<RateLimitResponse> SendAsync(
            string method,
            string pathAndQuery,
            string remoteIp,
            IReadOnlyDictionary<string, string>? headers = null)
        {
            var context = new DefaultHttpContext();
            context.Request.Method = method;
            var queryIndex = pathAndQuery.IndexOf('?');
            context.Request.Path = queryIndex >= 0 ? pathAndQuery[..queryIndex] : pathAndQuery;
            if (queryIndex >= 0)
            {
                context.Request.QueryString = new QueryString(pathAndQuery[queryIndex..]);
            }

            context.Connection.RemoteIpAddress = IPAddress.Parse(remoteIp);
            context.RequestServices = _services;
            context.Response.Body = new MemoryStream();
            if (headers is not null)
            {
                foreach (var header in headers)
                {
                    context.Request.Headers[header.Key] = header.Value;
                }
            }

            try
            {
                await _pipeline(context);
                return new RateLimitResponse(
                    context.Response.StatusCode,
                    context.Response.Headers["Retry-After"].ToString());
            }
            finally
            {
                await context.Response.Body.DisposeAsync();
            }
        }

        public void Dispose() => _services.Dispose();
    }

    private sealed class ManualSystemClock : ISystemClock
    {
        public ManualSystemClock(DateTimeOffset utcNow) => UtcNow = utcNow;

        public DateTimeOffset UtcNow { get; private set; }

        public void Advance(TimeSpan duration) => UtcNow = UtcNow.Add(duration);
    }

    private sealed record RateLimitResponse(int StatusCode, string? RetryAfter);
}
