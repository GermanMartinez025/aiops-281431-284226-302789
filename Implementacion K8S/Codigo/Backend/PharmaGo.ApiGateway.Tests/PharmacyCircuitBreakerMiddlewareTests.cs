using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using Polly;
using Polly.CircuitBreaker;
using Polly.Utilities;
using PharmaGo.ApiGateway.Middleware;
using PharmaGo.ApiGateway.Resilience;
using System.Net.Http;
using System.Text;
using Yarp.ReverseProxy.Configuration;
using Yarp.ReverseProxy.Forwarder;
using Yarp.ReverseProxy.Model;

namespace PharmaGo.ApiGateway.Tests;

[TestClass]
[DoNotParallelize]
public sealed class PharmacyCircuitBreakerMiddlewareTests
{
    private static readonly Func<DateTime> OriginalUtcNow = SystemClock.UtcNow;
    private readonly List<IDisposable> _testResources = new();
    private static DateTime _utcNow;

    [TestInitialize]
    public void InitializeClock()
    {
        _utcNow = DateTime.UtcNow;
        SystemClock.UtcNow = () => _utcNow;
    }

    [TestCleanup]
    public void RestoreClock()
    {
        SystemClock.UtcNow = OriginalUtcNow;
        foreach (var resource in _testResources)
        {
            resource.Dispose();
        }

        _testResources.Clear();
    }

    [TestMethod]
    public async Task ClosedCircuitForwardsRequestAndCountsExactlyFiveConsecutiveFailures()
    {
        var breaker = CreateBreaker();
        var calls = 0;
        var middleware = CreateMiddleware(breaker, _ =>
        {
            calls++;
            return Task.CompletedTask;
        });

        for (var attempt = 1; attempt <= 4; attempt++)
        {
            var context = CreateContext(statusCode: StatusCodes.Status502BadGateway);
            await middleware.InvokeAsync(context);
            Assert.AreEqual(StatusCodes.Status502BadGateway, context.Response.StatusCode);
            Assert.AreEqual(CircuitState.Closed, breaker.Policy.CircuitState);
        }

        var fifth = CreateContext(statusCode: StatusCodes.Status502BadGateway);
        await middleware.InvokeAsync(fifth);
        Assert.AreEqual(StatusCodes.Status502BadGateway, fifth.Response.StatusCode);
        Assert.AreEqual(CircuitState.Open, breaker.Policy.CircuitState);

        var rejected = CreateContext(statusCode: StatusCodes.Status200OK);
        await middleware.InvokeAsync(rejected);
        Assert.AreEqual(StatusCodes.Status503ServiceUnavailable, rejected.Response.StatusCode);
        Assert.AreEqual("15", rejected.Response.Headers.RetryAfter.ToString());
        Assert.AreEqual(5, calls, "An open circuit must not invoke the next delegate.");
    }

    [TestMethod]
    public async Task SuccessfulResponseResetsConsecutiveFailureCount()
    {
        var breaker = CreateBreaker();
        var statuses = new Queue<int>(new[] { 502, 502, 200, 502, 502, 502, 200, 502, 502, 502, 502, 502 });
        var middleware = CreateMiddleware(breaker, context =>
        {
            context.Response.StatusCode = statuses.Dequeue();
            return Task.CompletedTask;
        });

        for (var i = 0; i < 11; i++)
        {
            await middleware.InvokeAsync(CreateContext());
        }

        Assert.AreEqual(CircuitState.Closed, breaker.Policy.CircuitState);
        var fifthAfterLastSuccess = CreateContext();
        await middleware.InvokeAsync(fifthAfterLastSuccess);
        Assert.AreEqual(502, fifthAfterLastSuccess.Response.StatusCode);
        Assert.AreEqual(CircuitState.Open, breaker.Policy.CircuitState);
    }

    [DataTestMethod]
    [DataRow(502)]
    [DataRow(503)]
    [DataRow(504)]
    public async Task GatewayFailureStatusesOpenCircuit(int status)
    {
        var breaker = CreateBreaker(failureThreshold: 1);
        var middleware = CreateMiddleware(breaker, context =>
        {
            context.Response.StatusCode = status;
            return Task.CompletedTask;
        });

        var context = CreateContext();
        await middleware.InvokeAsync(context);

        Assert.AreEqual(status, context.Response.StatusCode);
        Assert.AreEqual(CircuitState.Open, breaker.Policy.CircuitState);
    }

    [DataTestMethod]
    [DataRow(400)]
    [DataRow(401)]
    [DataRow(403)]
    [DataRow(404)]
    [DataRow(429)]
    [DataRow(500)]
    public async Task NonGatewayFailureStatusesDoNotOpenCircuit(int status)
    {
        var breaker = CreateBreaker(failureThreshold: 1);
        var middleware = CreateMiddleware(breaker, context =>
        {
            context.Response.StatusCode = status;
            return Task.CompletedTask;
        });

        await middleware.InvokeAsync(CreateContext());

        Assert.AreEqual(CircuitState.Closed, breaker.Policy.CircuitState);
    }

    [DataTestMethod]
    [DataRow(ForwarderError.NoAvailableDestinations)]
    [DataRow(ForwarderError.Request)]
    [DataRow(ForwarderError.RequestTimedOut)]
    [DataRow(ForwarderError.RequestBodyDestination)]
    [DataRow(ForwarderError.ResponseBodyDestination)]
    [DataRow(ForwarderError.UpgradeRequestDestination)]
    [DataRow(ForwarderError.UpgradeResponseDestination)]
    public async Task DestinationForwarderErrorsCountEvenWhenResponseIsSuccessful(ForwarderError error)
    {
        var breaker = CreateBreaker(failureThreshold: 1);
        var middleware = CreateMiddleware(breaker, context =>
        {
            context.Response.StatusCode = StatusCodes.Status200OK;
            context.Features.Set<IForwarderErrorFeature>(new TestForwarderErrorFeature { Error = error });
            return Task.CompletedTask;
        });

        var context = CreateContext();
        await middleware.InvokeAsync(context);

        Assert.AreEqual(StatusCodes.Status200OK, context.Response.StatusCode);
        Assert.AreEqual(CircuitState.Open, breaker.Policy.CircuitState);
    }

    [TestMethod]
    public async Task ForwarderNoneUsesGatewayStatusFallback()
    {
        var breaker = CreateBreaker(failureThreshold: 1);
        var middleware = CreateMiddleware(breaker, context =>
        {
            context.Response.StatusCode = StatusCodes.Status502BadGateway;
            context.Features.Set<IForwarderErrorFeature>(new TestForwarderErrorFeature { Error = ForwarderError.None });
            return Task.CompletedTask;
        });

        await middleware.InvokeAsync(CreateContext());

        Assert.AreEqual(CircuitState.Open, breaker.Policy.CircuitState);
    }

    [TestMethod]
    public async Task FailedPostIsForwardedAndReadOnceWithoutReplayThenFurtherPostIsRejected()
    {
        var breaker = CreateBreaker(failureThreshold: 1);
        var nextCalls = 0;
        var requestBodyReads = 0;
        string? receivedBody = null;
        var middleware = CreateMiddleware(breaker, async context =>
        {
            nextCalls++;
            using var reader = new StreamReader(
                context.Request.Body,
                Encoding.UTF8,
                detectEncodingFromByteOrderMarks: false,
                bufferSize: 1024,
                leaveOpen: true);
            receivedBody = await reader.ReadToEndAsync();
            requestBodyReads++;
            context.Response.StatusCode = StatusCodes.Status502BadGateway;
            context.Features.Set<IForwarderErrorFeature>(new TestForwarderErrorFeature { Error = ForwarderError.RequestTimedOut });
        });

        var body = new MemoryStream(Encoding.UTF8.GetBytes("purchase=one"));
        _testResources.Add(body);
        var firstPost = CreateContext(method: "POST");
        firstPost.Request.Body = body;
        await middleware.InvokeAsync(firstPost);

        Assert.AreEqual(StatusCodes.Status502BadGateway, firstPost.Response.StatusCode);
        Assert.AreEqual(1, nextCalls);
        Assert.AreEqual(1, requestBodyReads);
        Assert.AreEqual("purchase=one", receivedBody);
        Assert.AreEqual(CircuitState.Open, breaker.Policy.CircuitState);

        var secondPost = CreateContext(method: "POST");
        await middleware.InvokeAsync(secondPost);

        Assert.AreEqual(StatusCodes.Status503ServiceUnavailable, secondPost.Response.StatusCode);
        Assert.AreEqual(1, nextCalls, "The rejected POST must not be forwarded or replayed.");
        Assert.AreEqual(1, requestBodyReads);
    }

    [DataTestMethod]
    [DataRow(ForwarderError.RequestBodyClient)]
    [DataRow(ForwarderError.ResponseBodyClient)]
    [DataRow(ForwarderError.RequestCanceled)]
    [DataRow(ForwarderError.RequestBodyCanceled)]
    [DataRow(ForwarderError.ResponseBodyCanceled)]
    [DataRow(ForwarderError.RequestCreation)]
    public async Task ClientCancellationAndRequestCreationErrorsDoNotCountEvenWithGatewayFailureStatus(ForwarderError error)
    {
        var breaker = CreateBreaker(failureThreshold: 1);
        var middleware = CreateMiddleware(breaker, context =>
        {
            context.Response.StatusCode = StatusCodes.Status502BadGateway;
            context.Features.Set<IForwarderErrorFeature>(new TestForwarderErrorFeature { Error = error });
            return Task.CompletedTask;
        });

        await middleware.InvokeAsync(CreateContext());

        Assert.AreEqual(CircuitState.Closed, breaker.Policy.CircuitState);
    }

    [TestMethod]
    public async Task RequestCancellationPropagatesAndDoesNotCountAsDependencyFailure()
    {
        var breaker = CreateBreaker(failureThreshold: 1);
        var middleware = CreateMiddleware(breaker, context =>
        {
            context.Response.StatusCode = StatusCodes.Status502BadGateway;
            context.Features.Set<IForwarderErrorFeature>(new TestForwarderErrorFeature { Error = ForwarderError.RequestBodyClient });
            context.RequestAborted = new CancellationToken(canceled: true);
            return Task.CompletedTask;
        });

        await Assert.ThrowsExceptionAsync<OperationCanceledException>(() => middleware.InvokeAsync(CreateContext()));
        Assert.AreEqual(CircuitState.Closed, breaker.Policy.CircuitState);
    }

    [TestMethod]
    public async Task DisabledBreakerAndNonPharmacyClusterBypassCircuit()
    {
        var disabled = CreateBreaker(enabled: false, failureThreshold: 1);
        var disabledCalls = 0;
        var disabledMiddleware = CreateMiddleware(disabled, _ =>
        {
            disabledCalls++;
            return Task.CompletedTask;
        });
        var disabledContext = CreateContext(statusCode: StatusCodes.Status502BadGateway);

        await disabledMiddleware.InvokeAsync(disabledContext);

        Assert.AreEqual(1, disabledCalls);
        Assert.AreEqual(CircuitState.Closed, disabled.Policy.CircuitState);

        var enabled = CreateBreaker(failureThreshold: 1);
        var pharmacyMiddleware = CreateMiddleware(enabled, c =>
        {
            c.Response.StatusCode = StatusCodes.Status502BadGateway;
            return Task.CompletedTask;
        });
        await pharmacyMiddleware.InvokeAsync(CreateContext());
        Assert.AreEqual(CircuitState.Open, enabled.Policy.CircuitState);

        var otherCalls = 0;
        var otherMiddleware = CreateMiddleware(enabled, _ =>
        {
            otherCalls++;
            return Task.CompletedTask;
        });
        var other = CreateContext(clusterId: "users-cluster", statusCode: StatusCodes.Status502BadGateway);
        await otherMiddleware.InvokeAsync(other);

        Assert.AreEqual(1, otherCalls);
        Assert.AreEqual(StatusCodes.Status502BadGateway, other.Response.StatusCode);
        Assert.AreEqual(CircuitState.Open, enabled.Policy.CircuitState);
    }

    [TestMethod]
    public async Task OpenCircuitRejectsWritesAndRecoveryRequiresSuccessfulGetProbe()
    {
        var breaker = CreateBreaker();
        var fail = CreateMiddleware(breaker, context =>
        {
            context.Response.StatusCode = StatusCodes.Status503ServiceUnavailable;
            return Task.CompletedTask;
        });
        for (var i = 0; i < 5; i++)
        {
            await fail.InvokeAsync(CreateContext());
        }

        AdvanceClock(TimeSpan.FromSeconds(16));
        var calls = 0;
        var success = CreateMiddleware(breaker, _ =>
        {
            calls++;
            return Task.CompletedTask;
        });
        foreach (var method in new[] { "POST", "PUT", "DELETE", "PATCH" })
        {
            var write = CreateContext(method: method);
            await success.InvokeAsync(write);
            Assert.AreEqual(StatusCodes.Status503ServiceUnavailable, write.Response.StatusCode, method);
        }

        Assert.AreEqual(0, calls);
        Assert.AreEqual(CircuitState.HalfOpen, breaker.Policy.CircuitState);

        var probe = CreateContext(method: "GET");
        await success.InvokeAsync(probe);

        Assert.AreEqual(1, calls);
        Assert.AreEqual(CircuitState.Closed, breaker.Policy.CircuitState);
        Assert.AreEqual(StatusCodes.Status200OK, probe.Response.StatusCode);
    }

    [TestMethod]
    public async Task FailedHalfOpenGetProbeReopensCircuit()
    {
        var breaker = CreateBreaker();
        var fail = CreateMiddleware(breaker, context =>
        {
            context.Response.StatusCode = StatusCodes.Status502BadGateway;
            return Task.CompletedTask;
        });
        for (var i = 0; i < 5; i++)
        {
            await fail.InvokeAsync(CreateContext());
        }

        AdvanceClock(TimeSpan.FromSeconds(16));
        var probe = CreateContext(method: "GET");
        await fail.InvokeAsync(probe);

        Assert.AreEqual(StatusCodes.Status502BadGateway, probe.Response.StatusCode);
        Assert.AreEqual(CircuitState.Open, breaker.Policy.CircuitState);
    }

    [TestMethod]
    public async Task OnlyOneHalfOpenGetProbeIsAdmittedWhileItIsInFlight()
    {
        var breaker = CreateBreaker();
        var failing = CreateMiddleware(breaker, context =>
        {
            context.Response.StatusCode = StatusCodes.Status503ServiceUnavailable;
            return Task.CompletedTask;
        });
        for (var i = 0; i < 5; i++)
        {
            await failing.InvokeAsync(CreateContext());
        }

        AdvanceClock(TimeSpan.FromSeconds(16));
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var calls = 0;
        var probeMiddleware = CreateMiddleware(breaker, async _ =>
        {
            Interlocked.Increment(ref calls);
            entered.TrySetResult();
            await release.Task;
        });

        var firstProbe = probeMiddleware.InvokeAsync(CreateContext(method: "GET"));
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(3));

            var secondProbe = CreateContext(method: "GET");
            await probeMiddleware.InvokeAsync(secondProbe);
            var write = CreateContext(method: "POST");
            await probeMiddleware.InvokeAsync(write);

            Assert.AreEqual(1, calls);
            Assert.AreEqual(StatusCodes.Status503ServiceUnavailable, secondProbe.Response.StatusCode);
            Assert.AreEqual(StatusCodes.Status503ServiceUnavailable, write.Response.StatusCode);
        }
        finally
        {
            release.TrySetResult();
            await firstProbe.WaitAsync(TimeSpan.FromSeconds(3));
        }

        Assert.AreEqual(CircuitState.Closed, breaker.Policy.CircuitState);
    }

    [TestMethod]
    public async Task MultipleMiddlewareInstancesShareTheSingletonPolicy()
    {
        var singleton = CreateBreaker(failureThreshold: 1);
        var firstCalls = 0;
        var first = CreateMiddleware(singleton, context =>
        {
            firstCalls++;
            context.Response.StatusCode = StatusCodes.Status502BadGateway;
            return Task.CompletedTask;
        });
        await first.InvokeAsync(CreateContext());

        var secondCalls = 0;
        var second = CreateMiddleware(singleton, _ =>
        {
            secondCalls++;
            return Task.CompletedTask;
        });
        var rejected = CreateContext();
        await second.InvokeAsync(rejected);

        Assert.AreEqual(1, firstCalls);
        Assert.AreEqual(0, secondCalls);
        Assert.AreEqual(StatusCodes.Status503ServiceUnavailable, rejected.Response.StatusCode);
        Assert.AreEqual("15", rejected.Response.Headers.RetryAfter.ToString());
    }

    [DataTestMethod]
    [DataRow(0, 15)]
    [DataRow(5, 0)]
    [DataRow(-1, 15)]
    [DataRow(5, -1)]
    public void InvalidThresholdOrDurationIsRejected(int threshold, int durationSeconds)
    {
        var configuration = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["CircuitBreaker:Pharmacy:Enabled"] = "true",
            ["CircuitBreaker:Pharmacy:FailureThreshold"] = threshold.ToString(),
            ["CircuitBreaker:Pharmacy:BreakDurationSeconds"] = durationSeconds.ToString()
        }).Build();

        Assert.ThrowsException<InvalidOperationException>(() => new PharmacyCircuitBreaker(
            configuration,
            NullLogger<PharmacyCircuitBreaker>.Instance));
    }

    private static PharmacyCircuitBreaker CreateBreaker(bool enabled = true, int failureThreshold = 5)
    {
        var configuration = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["CircuitBreaker:Pharmacy:Enabled"] = enabled.ToString(),
            ["CircuitBreaker:Pharmacy:FailureThreshold"] = failureThreshold.ToString(),
            ["CircuitBreaker:Pharmacy:BreakDurationSeconds"] = "15"
        }).Build();
        return new PharmacyCircuitBreaker(configuration, NullLogger<PharmacyCircuitBreaker>.Instance);
    }

    private static PharmacyCircuitBreakerMiddleware CreateMiddleware(PharmacyCircuitBreaker breaker, RequestDelegate next) =>
        new(next, breaker, NullLogger<PharmacyCircuitBreakerMiddleware>.Instance);

    private DefaultHttpContext CreateContext(
        string method = "GET",
        string clusterId = PharmacyCircuitBreaker.PharmacyClusterId,
        int? statusCode = null)
    {
        var context = new DefaultHttpContext();
        context.Request.Method = method;
        var responseBody = new MemoryStream();
        context.Response.Body = responseBody;
        if (statusCode.HasValue)
        {
            context.Response.StatusCode = statusCode.Value;
        }

        var invoker = new HttpMessageInvoker(new StubHttpMessageHandler());
        _testResources.Add(responseBody);
        _testResources.Add(invoker);
        var cluster = new ClusterModel(new ClusterConfig { ClusterId = clusterId }, invoker);
        context.Features.Set<IReverseProxyFeature>(new ReverseProxyFeature { Cluster = cluster });
        return context;
    }

    private static void AdvanceClock(TimeSpan duration) => _utcNow = _utcNow.Add(duration);

    private sealed class StubHttpMessageHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            throw new NotSupportedException("The middleware tests never send network requests.");
    }

    private sealed class TestForwarderErrorFeature : IForwarderErrorFeature
    {
        public ForwarderError Error { get; set; }

        public Exception? Exception { get; set; }
    }
}
