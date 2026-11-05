# Gateway automated tests

Run from this directory with the .NET 6 SDK/runtime available:

```sh
dotnet test PharmaGo.ApiGateway.Tests.csproj
```

## Circuit breaker suite

The circuit breaker tests invoke the real Gateway middleware using in-memory `DefaultHttpContext` instances, YARP cluster features, and a counted in-process request delegate. Polly's clock is controlled by the fixture, so the 15-second open interval is tested without sleeping. The fake backend opens no network connection; the test runner may use local IPC. No Pharmacy service, database, Kubernetes cluster, or cloud resource is contacted.

## IP rate limiting suite

Run only the simulated IP rate limiting suite from this directory:

```sh
dotnet test PharmaGo.ApiGateway.Tests.csproj --filter FullyQualifiedName~RateLimitingTests
```

This suite copies and loads the Gateway's actual `appsettings.json` and invokes AspNetCoreRateLimit's actual `UseIpRateLimiting` middleware with the Gateway's service registrations. Requests use an in-memory `DefaultHttpContext`, a fixed remote IP, and a counted in-process backend delegate. The test scenarios assert the configured limits, 429 and `Retry-After` behavior, IP and endpoint isolation, exclusions, concurrent requests, and expiration using a test-local cache clock. For example, the login policy scenario expects ten `POST /api/login` requests from one IP to pass and the eleventh to receive 429; this describes the assertion, not a separately verified live API run.

Both suites validate middleware and policy behavior in isolation. They do not validate YARP's complete hosted pipeline, service connectivity, deployment configuration, or Kubernetes behavior.

Circuit breaker suite verification on 2026-10-30: **36 passed, 0 failed, 0 skipped**, using .NET 6 with SDK 6.0.428 installed in a temporary directory. The rate limiting suite has been added separately; its execution result is pending. The application's target framework and the global .NET installation were not changed.
