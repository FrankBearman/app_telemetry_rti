using System.Diagnostics;
using Azure.Monitor.OpenTelemetry.AspNetCore;

var builder = WebApplication.CreateBuilder(args);

// Without a connection string the app still runs locally; it just sends no telemetry.
var telemetryEnabled = !string.IsNullOrWhiteSpace(
    builder.Configuration["APPLICATIONINSIGHTS_CONNECTION_STRING"]);

if (telemetryEnabled)
{
    builder.Services.AddOpenTelemetry().UseAzureMonitor();
}

var app = builder.Build();

// Tags on the request Activity surface as customDimensions on the `requests` row,
// so they flow through the existing Fabric ingest.
app.Use(async (context, next) =>
{
    var activity = Activity.Current;
    activity?.SetTag("demo.app", "demo-dotnet-api");
    if (context.Request.Headers.TryGetValue("X-Demo-Run-Id", out var runId))
    {
        activity?.SetTag("clientRunId", runId.ToString());
    }
    await next();
});

app.MapGet("/", () => Results.Ok(new
{
    app = "demo-dotnet-api",
    telemetry = telemetryEnabled ? "enabled" : "disabled (APPLICATIONINSIGHTS_CONNECTION_STRING not set)",
    endpoints = new[] { "/weather", "/slow", "/error" }
}));

app.MapGet("/weather", () => Results.Ok(new
{
    tempC = Random.Shared.Next(-5, 30),
    observedUtc = DateTime.UtcNow
}));

app.MapGet("/slow", async (ILogger<Program> logger) =>
{
    var delayMs = Random.Shared.Next(500, 2500);
    logger.LogInformation("Slow endpoint delaying {DelayMs} ms", delayMs);
    await Task.Delay(delayMs);
    return Results.Ok(new { delayMs });
});

app.MapGet("/error", () =>
{
    throw new InvalidOperationException("Demo failure from /error");
});

app.Run();
