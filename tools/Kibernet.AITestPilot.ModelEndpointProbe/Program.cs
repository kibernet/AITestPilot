using System.Net;
using System.Text;
using System.Text.Json;
using Kibernet.AITestPilot.Core;

var options = ProbeOptions.Parse(args);
try
{
    Directory.CreateDirectory(options.EvidenceBundleDir);
    Directory.CreateDirectory(options.TraceDirectory);

    if (options.Mode == ProbeMode.Live)
    {
        await RunLiveProbe(options);
        return;
    }

    if (options.Mode == ProbeMode.LiveFailure)
    {
        await RunLiveFailureProbe(options);
        return;
    }

    await RunDeterministicProbe(options);
}
catch (Exception ex)
{
    Console.Error.WriteLine(ex.Message);
    Environment.ExitCode = 1;
}

static async Task RunDeterministicProbe(ProbeOptions options)
{
    var responseJson = """
{
  "action": "click",
  "target": "Lobby.ActivityButton"
}
""";

    var handler = new DeterministicModelEndpointHandler(responseJson);
    using var httpClient = new HttpClient(handler);

    var client = new ModelEndpointDecisionClient(
        httpClient,
        new ModelEndpointDecisionClientOptions
        {
            Endpoint = new Uri("https://model-probe.local/decide"),
            ApiKey = "probe-secret",
            Model = "deterministic-contract-probe",
            RunId = "MODEL-ENDPOINT-PROBE",
            TraceDirectory = options.TraceDirectory,
        });

    var snapshot = BuildSnapshot();

    var action = await client.DecideAsync(
        new DecisionRequest(
            "enter activity",
            snapshot,
            Array.Empty<string>(),
            new[] { "add null guard before reward access" }),
        CancellationToken.None);

    action.Validate();
    if (!string.Equals(action.Action, ActionVerbs.Click, StringComparison.OrdinalIgnoreCase) ||
        !string.Equals(action.Target, "Lobby.ActivityButton", StringComparison.Ordinal))
    {
        throw new InvalidOperationException("Model endpoint probe returned an unexpected action.");
    }

    var request = JsonSerializer.Deserialize<ModelDecisionEndpointRequest>(
        handler.RequestBody,
        JsonOptions.Default);
    if (request == null)
    {
        throw new InvalidOperationException("Model endpoint request could not be parsed.");
    }

    var requestContainsActionSchema = !string.IsNullOrWhiteSpace(request.ActionJsonSchema) &&
                                      request.ActionJsonSchema.Contains(DecisionActionSchema.SchemaVersion, StringComparison.Ordinal);
    var requestContainsAllowedActions = request.AllowedActions.Contains(ActionVerbs.Click) &&
                                        request.AllowedActions.Contains(ActionVerbs.Finish) &&
                                        request.AllowedActions.Count == DecisionActionSchema.AllowedActions.Count;
    var requestContainsFixHints = request.FixHints.Contains("add null guard before reward access");
    var traceSource = Path.Combine(options.TraceDirectory, "step-0000-decision.json");
    if (!File.Exists(traceSource))
    {
        throw new InvalidOperationException("Model endpoint trace was not produced.");
    }

    var trace = JsonSerializer.Deserialize<DecisionTraceRecord>(
        await File.ReadAllTextAsync(traceSource),
        JsonOptions.Default);
    if (trace == null)
    {
        throw new InvalidOperationException("Model endpoint trace could not be parsed.");
    }

    if (!string.Equals(trace.Status, "PASS", StringComparison.OrdinalIgnoreCase) ||
        !string.Equals(trace.Action?.Action, ActionVerbs.Click, StringComparison.OrdinalIgnoreCase))
    {
        throw new InvalidOperationException("Model endpoint trace did not capture the validated action.");
    }

    var requestPath = Path.Combine(options.EvidenceBundleDir, "model-endpoint-request.json");
    var responsePath = Path.Combine(options.EvidenceBundleDir, "model-endpoint-response.json");
    var tracePath = Path.Combine(options.EvidenceBundleDir, "model-endpoint-decision-trace.json");
    var manifestPath = Path.Combine(options.EvidenceBundleDir, "model-endpoint-trace-manifest.json");

    await File.WriteAllTextAsync(requestPath, handler.RequestBody);
    await File.WriteAllTextAsync(responsePath, handler.ResponseJson);
    File.Copy(traceSource, tracePath, overwrite: true);

    var manifest = new
    {
        schemaVersion = "ai-testpilot.model_endpoint_trace_probe.v1",
        status = "PASS",
        generatedAtUtc = DateTimeOffset.UtcNow.ToString("O"),
        endpointMode = "deterministic_local_handler",
        fixtureOnly = true,
        contractFixtureMode = true,
        realProviderAccessProven = false,
        liveSmokeExecuted = false,
        productionLiveEndpointAccessProven = false,
        evidenceProvenance = "contract_fixture_deterministic_local_handler",
        directEvidenceProvenance = "Deterministic local HTTP handler only; no external provider access occurred.",
        clientType = nameof(ModelEndpointDecisionClient),
        requestMethod = handler.RequestMethod,
        authorizationScheme = handler.AuthorizationScheme,
        actionSchemaVersion = request.ActionSchemaVersion,
        allowedActionCount = request.AllowedActions.Count,
        requestContainsActionSchema,
        requestContainsAllowedActions,
        requestContainsFixHints,
        fixHintCount = request.FixHints.Count,
        responseValidated = true,
        traceStatus = trace.Status,
        parsedAction = new
        {
            action = action.Action,
            target = action.Target,
            waitMilliseconds = action.WaitMilliseconds,
        },
        files = new[]
        {
            "model-endpoint-request.json",
            "model-endpoint-response.json",
            "model-endpoint-decision-trace.json",
        },
    };

    await File.WriteAllTextAsync(
        manifestPath,
        JsonSerializer.Serialize(manifest, JsonOptions.Indented));

    Console.WriteLine("Model endpoint trace manifest: " + manifestPath);
    Console.WriteLine("PASS AI TestPilot model endpoint trace probe");
}

static async Task RunLiveProbe(ProbeOptions options)
{
    if (string.IsNullOrWhiteSpace(options.Endpoint))
    {
        throw new InvalidOperationException("Live model endpoint is required.");
    }

    using var httpClient = new HttpClient
    {
        Timeout = TimeSpan.FromSeconds(options.TimeoutSeconds),
    };

    var client = new ModelEndpointDecisionClient(
        httpClient,
        new ModelEndpointDecisionClientOptions
        {
            Endpoint = new Uri(options.Endpoint),
            ApiKey = options.ApiKey,
            AuthorizationScheme = options.AuthorizationScheme,
            Model = options.Model,
            RequestFormat = options.RequestFormat,
            RunId = "LIVE-MODEL-ENDPOINT-SMOKE",
            TraceDirectory = options.TraceDirectory,
        });

    var traceSource = Path.Combine(options.TraceDirectory, "step-0000-decision.json");
    var tracePath = Path.Combine(options.EvidenceBundleDir, "live-model-endpoint-decision-trace.json");
    var manifestPath = Path.Combine(options.EvidenceBundleDir, "live-model-endpoint-smoke-manifest.json");
    TestPilotAction? action = null;

    try
    {
        action = await client.DecideAsync(
            new DecisionRequest(
                "choose the visible activity button if it is safe, otherwise finish",
                BuildSnapshot(),
                Array.Empty<string>()),
            CancellationToken.None);

        action.Validate();
    }
    catch (Exception ex)
    {
        var failureTrace = await TryReadTraceAndCopy(traceSource, tracePath);
        await WriteLiveFailureManifest(options, manifestPath, failureTrace, ex);
        throw;
    }

    if (!File.Exists(traceSource))
    {
        throw new InvalidOperationException("Live model endpoint trace was not produced.");
    }

    var trace = JsonSerializer.Deserialize<DecisionTraceRecord>(
        await File.ReadAllTextAsync(traceSource),
        JsonOptions.Default);
    if (trace == null)
    {
        throw new InvalidOperationException("Live model endpoint trace could not be parsed.");
    }

    var requestContainsActionSchema = !string.IsNullOrWhiteSpace(trace.RequestJson) &&
                                      trace.RequestJson.Contains(DecisionActionSchema.SchemaVersion, StringComparison.Ordinal);
    var requestContainsAllowedActions = !string.IsNullOrWhiteSpace(trace.RequestJson) &&
                                        trace.RequestJson.Contains(ActionVerbs.Click, StringComparison.Ordinal) &&
                                        trace.RequestJson.Contains(ActionVerbs.Finish, StringComparison.Ordinal);
    var allowedActionCount = 0;
    foreach (var allowedAction in DecisionActionSchema.AllowedActions)
    {
        if (!string.IsNullOrWhiteSpace(trace.RequestJson) &&
            trace.RequestJson.Contains(allowedAction, StringComparison.Ordinal))
        {
            allowedActionCount++;
        }
    }

    File.Copy(traceSource, tracePath, overwrite: true);

    var manifest = new
    {
        schemaVersion = "ai-testpilot.live_model_endpoint_smoke.v1",
        status = "PASS",
        generatedAtUtc = DateTimeOffset.UtcNow.ToString("O"),
        endpointMode = "live_http_endpoint",
        fixtureOnly = false,
        contractFixtureMode = false,
        realProviderAccessProven = true,
        liveSmokeExecuted = true,
        productionLiveEndpointAccessProven = true,
        evidenceProvenance = "direct_live_http_endpoint_pass",
        directEvidenceProvenance = "ModelEndpointDecisionClient completed a configured live HTTP endpoint request and validated the returned action trace.",
        clientType = nameof(ModelEndpointDecisionClient),
        endpointConfigured = true,
        apiKeyConfigured = !string.IsNullOrWhiteSpace(options.ApiKey),
        failureCategory = string.Empty,
        failureMessage = string.Empty,
        failureRemediation = Array.Empty<string>(),
        failurePolicy = BuildFailurePolicy(string.Empty),
        model = options.Model,
        requestFormat = options.RequestFormat.ToString(),
        actionSchemaVersion = requestContainsActionSchema ? DecisionActionSchema.SchemaVersion : string.Empty,
        allowedActionCount,
        requestContainsActionSchema,
        requestContainsAllowedActions,
        responseValidated = true,
        traceStatus = trace.Status,
        parsedAction = new
        {
            action = action.Action,
            target = action.Target,
            waitMilliseconds = action.WaitMilliseconds,
        },
        files = new[]
        {
            "live-model-endpoint-decision-trace.json",
        },
    };

    await File.WriteAllTextAsync(
        manifestPath,
        JsonSerializer.Serialize(manifest, JsonOptions.Indented));

    Console.WriteLine("Live model endpoint smoke manifest: " + manifestPath);
    Console.WriteLine("PASS AI TestPilot live model endpoint smoke");
}

static async Task RunLiveFailureProbe(ProbeOptions options)
{
    var responseJson = """
{
  "error": {
    "message": "invalid api key"
  }
}
""";

    var handler = new StatusCodeModelEndpointHandler(HttpStatusCode.Unauthorized, responseJson);
    using var httpClient = new HttpClient(handler);

    var client = new ModelEndpointDecisionClient(
        httpClient,
        new ModelEndpointDecisionClientOptions
        {
            Endpoint = new Uri("https://model-probe.local/v1/chat/completions"),
            ApiKey = "probe-secret",
            AuthorizationScheme = "Bearer",
            Model = "live-failure-classification-probe",
            RequestFormat = ModelEndpointRequestFormat.OpenAICompatibleChatCompletions,
            RunId = "LIVE-MODEL-ENDPOINT-FAILURE-PROBE",
            TraceDirectory = options.TraceDirectory,
        });

    Exception? capturedException = null;
    try
    {
        await client.DecideAsync(
            new DecisionRequest(
                "choose the visible activity button if it is safe, otherwise finish",
                BuildSnapshot(),
                Array.Empty<string>()),
            CancellationToken.None);
    }
    catch (Exception ex)
    {
        capturedException = ex;
    }

    if (capturedException == null)
    {
        throw new InvalidOperationException("Expected live model endpoint failure probe to fail, but it passed.");
    }

    var traceSource = Path.Combine(options.TraceDirectory, "step-0000-decision.json");
    var traceTarget = Path.Combine(options.EvidenceBundleDir, "live-model-endpoint-failure-probe-decision-trace.json");
    var manifestPath = Path.Combine(options.EvidenceBundleDir, "live-model-endpoint-failure-probe-manifest.json");
    var trace = await TryReadTraceAndCopy(traceSource, traceTarget);
    if (trace == null)
    {
        throw new InvalidOperationException("Live model endpoint failure probe trace was not produced.");
    }

    var failureCategory = ClassifyLiveFailure(capturedException);
    var failureRemediation = BuildFailureRemediation(failureCategory, "AI_TESTPILOT_MODEL_API_KEY");
    if (!string.Equals(failureCategory, "auth", StringComparison.OrdinalIgnoreCase))
    {
        throw new InvalidOperationException("Expected auth failure category, got: " + failureCategory);
    }

    var requestContainsActionSchema = !string.IsNullOrWhiteSpace(trace.RequestJson) &&
                                      trace.RequestJson.Contains(DecisionActionSchema.SchemaVersion, StringComparison.Ordinal);
    var requestContainsAllowedActions = !string.IsNullOrWhiteSpace(trace.RequestJson) &&
                                        trace.RequestJson.Contains(ActionVerbs.Click, StringComparison.Ordinal) &&
                                        trace.RequestJson.Contains(ActionVerbs.Finish, StringComparison.Ordinal);
    var allowedActionCount = 0;
    foreach (var allowedAction in DecisionActionSchema.AllowedActions)
    {
        if (!string.IsNullOrWhiteSpace(trace.RequestJson) &&
            trace.RequestJson.Contains(allowedAction, StringComparison.Ordinal))
        {
            allowedActionCount++;
        }
    }

    var manifest = new
    {
        schemaVersion = "ai-testpilot.live_model_endpoint_failure_probe.v1",
        status = "PASS",
        generatedAtUtc = DateTimeOffset.UtcNow.ToString("O"),
        endpointMode = "deterministic_http_failure_handler",
        fixtureOnly = true,
        contractFixtureMode = true,
        realProviderAccessProven = false,
        liveSmokeExecuted = false,
        productionLiveEndpointAccessProven = false,
        evidenceProvenance = "contract_fixture_deterministic_failure_handler",
        directEvidenceProvenance = "Deterministic local HTTP failure handler only; no external provider access occurred.",
        clientType = nameof(ModelEndpointDecisionClient),
        expectedFailure = true,
        expectedHttpStatus = 401,
        expectedFailureCategory = "auth",
        failureCategory,
        failureMessage = SanitizeFailureMessage(capturedException.Message),
        failureRemediation,
        failurePolicy = BuildFailurePolicy(failureCategory),
        requestMethod = handler.RequestMethod,
        authorizationScheme = handler.AuthorizationScheme,
        requestFormat = ModelEndpointRequestFormat.OpenAICompatibleChatCompletions.ToString(),
        actionSchemaVersion = requestContainsActionSchema ? DecisionActionSchema.SchemaVersion : string.Empty,
        allowedActionCount,
        requestContainsActionSchema,
        requestContainsAllowedActions,
        responseValidated = false,
        traceStatus = trace.Status,
        files = new[]
        {
            "live-model-endpoint-failure-probe-decision-trace.json",
        },
    };

    await File.WriteAllTextAsync(
        manifestPath,
        JsonSerializer.Serialize(manifest, JsonOptions.Indented));

    Console.WriteLine("Live model endpoint failure probe manifest: " + manifestPath);
    Console.WriteLine("PASS AI TestPilot live model endpoint failure probe");
}

static async Task<DecisionTraceRecord?> TryReadTraceAndCopy(string traceSource, string tracePath)
{
    if (!File.Exists(traceSource))
    {
        return null;
    }

    File.Copy(traceSource, tracePath, overwrite: true);
    try
    {
        return JsonSerializer.Deserialize<DecisionTraceRecord>(
            await File.ReadAllTextAsync(traceSource),
            JsonOptions.Default);
    }
    catch (JsonException)
    {
        return null;
    }
}

static async Task WriteLiveFailureManifest(
    ProbeOptions options,
    string manifestPath,
    DecisionTraceRecord? trace,
    Exception exception)
{
    var requestContainsActionSchema = !string.IsNullOrWhiteSpace(trace?.RequestJson) &&
                                      trace.RequestJson.Contains(DecisionActionSchema.SchemaVersion, StringComparison.Ordinal);
    var requestContainsAllowedActions = !string.IsNullOrWhiteSpace(trace?.RequestJson) &&
                                        trace.RequestJson.Contains(ActionVerbs.Click, StringComparison.Ordinal) &&
                                        trace.RequestJson.Contains(ActionVerbs.Finish, StringComparison.Ordinal);
    var allowedActionCount = 0;
    foreach (var allowedAction in DecisionActionSchema.AllowedActions)
    {
        if (!string.IsNullOrWhiteSpace(trace?.RequestJson) &&
            trace.RequestJson.Contains(allowedAction, StringComparison.Ordinal))
        {
            allowedActionCount++;
        }
    }

    var files = new List<string>();
    if (trace != null)
    {
        files.Add("live-model-endpoint-decision-trace.json");
    }

    var failureCategory = ClassifyLiveFailure(exception);
    var manifest = new
    {
        schemaVersion = "ai-testpilot.live_model_endpoint_smoke.v1",
        status = "FAIL",
        generatedAtUtc = DateTimeOffset.UtcNow.ToString("O"),
        endpointMode = "live_http_endpoint",
        fixtureOnly = false,
        contractFixtureMode = false,
        realProviderAccessProven = false,
        liveSmokeExecuted = false,
        productionLiveEndpointAccessProven = false,
        evidenceProvenance = "live_http_endpoint_fail_closed",
        directEvidenceProvenance = "Live smoke did not complete with validated provider evidence; provenance proof fields are false.",
        clientType = nameof(ModelEndpointDecisionClient),
        endpointConfigured = !string.IsNullOrWhiteSpace(options.Endpoint),
        apiKeyConfigured = !string.IsNullOrWhiteSpace(options.ApiKey),
        failureCategory,
        failureMessage = SanitizeFailureMessage(exception.Message),
        failureRemediation = BuildFailureRemediation(failureCategory, options.ApiKeyEnvironmentVariable),
        failurePolicy = BuildFailurePolicy(failureCategory),
        model = options.Model,
        requestFormat = options.RequestFormat.ToString(),
        actionSchemaVersion = requestContainsActionSchema ? DecisionActionSchema.SchemaVersion : string.Empty,
        allowedActionCount,
        requestContainsActionSchema,
        requestContainsAllowedActions,
        responseValidated = false,
        traceStatus = trace?.Status ?? string.Empty,
        parsedAction = new
        {
            action = trace?.Action?.Action ?? string.Empty,
            target = trace?.Action?.Target ?? string.Empty,
            waitMilliseconds = trace?.Action?.WaitMilliseconds ?? 0,
        },
        files,
    };

    await File.WriteAllTextAsync(
        manifestPath,
        JsonSerializer.Serialize(manifest, JsonOptions.Indented));
}

static string ClassifyLiveFailure(Exception exception)
{
    var message = exception.ToString();
    if (exception is HttpRequestException &&
        exception.InnerException != null &&
        exception.InnerException.GetType().FullName == "System.Net.Sockets.SocketException")
    {
        return "network";
    }

    if (exception is TaskCanceledException ||
        message.Contains("timeout", StringComparison.OrdinalIgnoreCase) ||
        message.Contains("timed out", StringComparison.OrdinalIgnoreCase))
    {
        return "timeout";
    }

    if (message.Contains("HTTP 401", StringComparison.OrdinalIgnoreCase) ||
        message.Contains("HTTP 403", StringComparison.OrdinalIgnoreCase) ||
        message.Contains("unauthorized", StringComparison.OrdinalIgnoreCase) ||
        message.Contains("forbidden", StringComparison.OrdinalIgnoreCase))
    {
        return "auth";
    }

    if (message.Contains("HTTP 429", StringComparison.OrdinalIgnoreCase) ||
        message.Contains("rate limit", StringComparison.OrdinalIgnoreCase) ||
        message.Contains("quota", StringComparison.OrdinalIgnoreCase))
    {
        return "rate_limit";
    }

    if (message.Contains("HTTP 400", StringComparison.OrdinalIgnoreCase) ||
        message.Contains("HTTP 404", StringComparison.OrdinalIgnoreCase) ||
        message.Contains("HTTP 422", StringComparison.OrdinalIgnoreCase))
    {
        return "request_or_endpoint";
    }

    if (message.Contains("HTTP 500", StringComparison.OrdinalIgnoreCase) ||
        message.Contains("HTTP 502", StringComparison.OrdinalIgnoreCase) ||
        message.Contains("HTTP 503", StringComparison.OrdinalIgnoreCase) ||
        message.Contains("HTTP 504", StringComparison.OrdinalIgnoreCase))
    {
        return "provider_unavailable";
    }

    if (message.Contains("empty response", StringComparison.OrdinalIgnoreCase))
    {
        return "empty_response";
    }

    if (message.Contains("valid AI TestPilot action", StringComparison.OrdinalIgnoreCase) ||
        message.Contains("not whitelisted", StringComparison.OrdinalIgnoreCase) ||
        message.Contains("requires a target", StringComparison.OrdinalIgnoreCase) ||
        message.Contains("negative duration", StringComparison.OrdinalIgnoreCase))
    {
        return "response_contract";
    }

    if (message.Contains("No such host", StringComparison.OrdinalIgnoreCase) ||
        message.Contains("actively refused", StringComparison.OrdinalIgnoreCase) ||
        message.Contains("connection refused", StringComparison.OrdinalIgnoreCase) ||
        message.Contains("无法连接", StringComparison.OrdinalIgnoreCase) ||
        message.Contains("拒绝", StringComparison.OrdinalIgnoreCase) ||
        message.Contains("SSL", StringComparison.OrdinalIgnoreCase))
    {
        return "network";
    }

    if (message.Contains("Invalid URI", StringComparison.OrdinalIgnoreCase))
    {
        return "configuration";
    }

    return "unknown";
}

static string[] BuildFailureRemediation(string failureCategory, string apiKeyEnvironmentVariable)
{
    var apiKeyEnv = string.IsNullOrWhiteSpace(apiKeyEnvironmentVariable)
        ? "AI_TESTPILOT_MODEL_API_KEY"
        : apiKeyEnvironmentVariable;

    return failureCategory switch
    {
        "auth" => new[]
        {
            "Verify the API key environment variable is set: " + apiKeyEnv,
            "Verify the authorization scheme matches the provider, usually Bearer.",
            "Confirm the selected model is allowed for this key or project.",
        },
        "rate_limit" => new[]
        {
            "Retry after the provider's Retry-After window or lower CI concurrency.",
            "Check provider quota, billing status, and per-model rate limits.",
            "Use a lower-cost smoke model if the provider supports one.",
        },
        "request_or_endpoint" => new[]
        {
            "Verify AITESTPILOT_LIVE_MODEL_ENDPOINT points to the correct decision or chat-completions route.",
            "Match AITESTPILOT_LIVE_MODEL_REQUEST_FORMAT to the provider: NativeJson or OpenAICompatibleChatCompletions.",
            "Inspect the persisted request trace to compare the payload shape with the provider contract.",
        },
        "provider_unavailable" => new[]
        {
            "Retry after provider recovery or route CI to a healthy gateway.",
            "Check provider status and gateway upstream health.",
            "Keep live smoke required only on release lanes that can tolerate external outages.",
        },
        "timeout" => new[]
        {
            "Increase timeout seconds for slow gateways or choose a faster smoke model.",
            "Check gateway latency and network path from the CI runner.",
            "Confirm the endpoint streams or buffers responses in a way the smoke client supports.",
        },
        "network" => new[]
        {
            "Verify DNS, proxy, firewall, and TLS trust from the CI runner.",
            "Confirm AITESTPILOT_LIVE_MODEL_ENDPOINT is reachable over http(s).",
            "For local gateways, verify the service is listening before running the pipeline.",
        },
        "empty_response" => new[]
        {
            "Inspect gateway logs for empty or prematurely closed responses.",
            "Confirm the endpoint returns a JSON body for both success and error cases.",
            "Check reverse proxy buffering and upstream timeout settings.",
        },
        "response_contract" => new[]
        {
            "Update the model prompt or gateway adapter to return exactly one AI TestPilot action JSON object.",
            "Ensure actions are whitelisted and click actions include a visible automation id target.",
            "Inspect the persisted response trace before loosening parser behavior.",
        },
        "configuration" => new[]
        {
            "Set AITESTPILOT_LIVE_MODEL_ENDPOINT to an absolute http(s) URL.",
            "Set AITESTPILOT_LIVE_MODEL and request format before requiring live smoke.",
            "Run Invoke-AITestPilotModelEndpointProviderDiagnostics.ps1 to verify selected preset and env bindings.",
        },
        _ => new[]
        {
            "Inspect live-model-endpoint-decision-trace.json and provider logs.",
            "Re-run provider diagnostics to confirm endpoint, model, request format, and auth settings.",
            "Classify this provider-specific failure before making live smoke required in release CI.",
        },
    };
}

static object BuildFailurePolicy(string failureCategory)
{
    return failureCategory switch
    {
        "auth" => new
        {
            retryable = false,
            recommendedRetryCount = 0,
            backoffSeconds = 0,
            escalation = "secret_or_model_access_owner",
            releaseGateAction = "block",
        },
        "rate_limit" => new
        {
            retryable = true,
            recommendedRetryCount = 2,
            backoffSeconds = 60,
            escalation = "provider_quota_owner",
            releaseGateAction = "block_if_required",
        },
        "request_or_endpoint" => new
        {
            retryable = false,
            recommendedRetryCount = 0,
            backoffSeconds = 0,
            escalation = "endpoint_configuration_owner",
            releaseGateAction = "block",
        },
        "provider_unavailable" => new
        {
            retryable = true,
            recommendedRetryCount = 2,
            backoffSeconds = 120,
            escalation = "provider_status_owner",
            releaseGateAction = "block_if_required",
        },
        "timeout" => new
        {
            retryable = true,
            recommendedRetryCount = 2,
            backoffSeconds = 30,
            escalation = "gateway_performance_owner",
            releaseGateAction = "block_if_required",
        },
        "network" => new
        {
            retryable = true,
            recommendedRetryCount = 1,
            backoffSeconds = 30,
            escalation = "ci_network_owner",
            releaseGateAction = "block_if_required",
        },
        "empty_response" => new
        {
            retryable = true,
            recommendedRetryCount = 1,
            backoffSeconds = 15,
            escalation = "gateway_owner",
            releaseGateAction = "block",
        },
        "response_contract" => new
        {
            retryable = false,
            recommendedRetryCount = 0,
            backoffSeconds = 0,
            escalation = "model_prompt_or_gateway_adapter_owner",
            releaseGateAction = "block",
        },
        "configuration" => new
        {
            retryable = false,
            recommendedRetryCount = 0,
            backoffSeconds = 0,
            escalation = "ci_configuration_owner",
            releaseGateAction = "block",
        },
        "unknown" => new
        {
            retryable = false,
            recommendedRetryCount = 0,
            backoffSeconds = 0,
            escalation = "ai_testpilot_owner",
            releaseGateAction = "block",
        },
        _ => new
        {
            retryable = false,
            recommendedRetryCount = 0,
            backoffSeconds = 0,
            escalation = string.Empty,
            releaseGateAction = "none",
        },
    };
}

static string SanitizeFailureMessage(string message)
{
    if (string.IsNullOrWhiteSpace(message))
    {
        return string.Empty;
    }

    return message.Length <= 500
        ? message
        : message[..500];
}

static Snapshot BuildSnapshot()
{
    return new Snapshot
    {
        Scene = "Lobby",
        StepIndex = 0,
        Ui = new[]
        {
            new UiElementSnapshot
            {
                AutomationId = "Lobby.ActivityButton",
                Name = "ActivityButton",
                Kind = "Button",
                Interactable = true,
            },
        },
        GameState = new GameStateSnapshot
        {
            Values = new Dictionary<string, string>
            {
                ["account"] = "qa_smoke_account",
                ["server"] = "qa",
            },
        },
    };
}

internal static class JsonOptions
{
    public static JsonSerializerOptions Default { get; } = new()
    {
        PropertyNameCaseInsensitive = true,
    };

    public static JsonSerializerOptions Indented { get; } = new()
    {
        WriteIndented = true,
    };
}

internal sealed class ProbeOptions
{
    public ProbeMode Mode { get; init; } = ProbeMode.Deterministic;

    public required string EvidenceBundleDir { get; init; }

    public required string TraceDirectory { get; init; }

    public string Endpoint { get; init; } = string.Empty;

    public string ApiKey { get; init; } = string.Empty;

    public string ApiKeyEnvironmentVariable { get; init; } = string.Empty;

    public string AuthorizationScheme { get; init; } = "Bearer";

    public string Model { get; init; } = string.Empty;

    public ModelEndpointRequestFormat RequestFormat { get; init; } = ModelEndpointRequestFormat.NativeJson;

    public int TimeoutSeconds { get; init; } = 30;

    public static ProbeOptions Parse(string[] args)
    {
        var repoRoot = FindRepoRoot(AppContext.BaseDirectory);
        var evidenceBundleDir = Path.Combine(repoRoot, "Temp", "release-evidence", "latest");
        var traceDirectory = Path.Combine(repoRoot, "Temp", "model-endpoint-trace-probe");
        var mode = ProbeMode.Deterministic;
        var endpoint = string.Empty;
        var apiKey = string.Empty;
        var apiKeyEnvironmentVariable = string.Empty;
        var authorizationScheme = "Bearer";
        var model = string.Empty;
        var requestFormat = ModelEndpointRequestFormat.NativeJson;
        var timeoutSeconds = 30;

        for (var index = 0; index < args.Length; index++)
        {
            var arg = args[index];
            if (string.Equals(arg, "--mode", StringComparison.OrdinalIgnoreCase))
            {
                var modeValue = RequireValue(args, ref index, arg);
                if (string.Equals(modeValue, "live", StringComparison.OrdinalIgnoreCase))
                {
                    mode = ProbeMode.Live;
                }
                else if (string.Equals(modeValue, "live-failure", StringComparison.OrdinalIgnoreCase))
                {
                    mode = ProbeMode.LiveFailure;
                }
                else if (string.Equals(modeValue, "deterministic", StringComparison.OrdinalIgnoreCase))
                {
                    mode = ProbeMode.Deterministic;
                }
                else
                {
                    throw new InvalidOperationException("Unknown probe mode: " + modeValue);
                }
            }
            else if (string.Equals(arg, "--evidence-bundle-dir", StringComparison.OrdinalIgnoreCase))
            {
                evidenceBundleDir = RequireValue(args, ref index, arg);
            }
            else if (string.Equals(arg, "--trace-dir", StringComparison.OrdinalIgnoreCase))
            {
                traceDirectory = RequireValue(args, ref index, arg);
            }
            else if (string.Equals(arg, "--endpoint", StringComparison.OrdinalIgnoreCase))
            {
                endpoint = RequireValue(args, ref index, arg);
            }
            else if (string.Equals(arg, "--api-key", StringComparison.OrdinalIgnoreCase))
            {
                apiKey = RequireValue(args, ref index, arg);
            }
            else if (string.Equals(arg, "--api-key-env", StringComparison.OrdinalIgnoreCase))
            {
                apiKeyEnvironmentVariable = RequireValue(args, ref index, arg);
            }
            else if (string.Equals(arg, "--authorization-scheme", StringComparison.OrdinalIgnoreCase))
            {
                authorizationScheme = RequireValue(args, ref index, arg);
            }
            else if (string.Equals(arg, "--model", StringComparison.OrdinalIgnoreCase))
            {
                model = RequireValue(args, ref index, arg);
            }
            else if (string.Equals(arg, "--request-format", StringComparison.OrdinalIgnoreCase))
            {
                var requestFormatValue = RequireValue(args, ref index, arg);
                if (!Enum.TryParse<ModelEndpointRequestFormat>(requestFormatValue, ignoreCase: true, out requestFormat))
                {
                    throw new InvalidOperationException("Unknown request format: " + requestFormatValue);
                }
            }
            else if (string.Equals(arg, "--timeout-seconds", StringComparison.OrdinalIgnoreCase))
            {
                if (!int.TryParse(RequireValue(args, ref index, arg), out timeoutSeconds) || timeoutSeconds <= 0)
                {
                    throw new InvalidOperationException("Timeout seconds must be a positive integer.");
                }
            }
            else
            {
                throw new InvalidOperationException("Unknown argument: " + arg);
            }
        }

        if (string.IsNullOrWhiteSpace(apiKey) && !string.IsNullOrWhiteSpace(apiKeyEnvironmentVariable))
        {
            apiKey = Environment.GetEnvironmentVariable(apiKeyEnvironmentVariable) ?? string.Empty;
        }

        return new ProbeOptions
        {
            Mode = mode,
            EvidenceBundleDir = evidenceBundleDir,
            TraceDirectory = traceDirectory,
            Endpoint = endpoint,
            ApiKey = apiKey,
            ApiKeyEnvironmentVariable = apiKeyEnvironmentVariable,
            AuthorizationScheme = authorizationScheme,
            Model = model,
            RequestFormat = requestFormat,
            TimeoutSeconds = timeoutSeconds,
        };
    }

    private static string RequireValue(string[] args, ref int index, string name)
    {
        if (index + 1 >= args.Length)
        {
            throw new InvalidOperationException("Missing value for " + name);
        }

        index++;
        return args[index];
    }

    private static string FindRepoRoot(string startDirectory)
    {
        var current = new DirectoryInfo(startDirectory);
        while (current != null)
        {
            if (File.Exists(Path.Combine(current.FullName, "AITestPilot.sln")))
            {
                return current.FullName;
            }

            current = current.Parent;
        }

        throw new InvalidOperationException("Could not locate AITestPilot.sln.");
    }
}

internal enum ProbeMode
{
    Deterministic,
    Live,
    LiveFailure,
}

internal sealed class DeterministicModelEndpointHandler : HttpMessageHandler
{
    public DeterministicModelEndpointHandler(string responseJson)
    {
        ResponseJson = responseJson;
    }

    public string RequestBody { get; private set; } = string.Empty;

    public string ResponseJson { get; }

    public string RequestMethod { get; private set; } = string.Empty;

    public string AuthorizationScheme { get; private set; } = string.Empty;

    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        RequestMethod = request.Method.Method;
        AuthorizationScheme = request.Headers.Authorization?.Scheme ?? string.Empty;
        RequestBody = request.Content == null
            ? string.Empty
            : await request.Content.ReadAsStringAsync(cancellationToken);

        return new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent(ResponseJson, Encoding.UTF8, "application/json"),
        };
    }
}

internal sealed class StatusCodeModelEndpointHandler : HttpMessageHandler
{
    private readonly HttpStatusCode statusCode;
    private readonly string responseJson;

    public StatusCodeModelEndpointHandler(HttpStatusCode statusCode, string responseJson)
    {
        this.statusCode = statusCode;
        this.responseJson = responseJson;
    }

    public string RequestBody { get; private set; } = string.Empty;

    public string RequestMethod { get; private set; } = string.Empty;

    public string AuthorizationScheme { get; private set; } = string.Empty;

    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        RequestMethod = request.Method.Method;
        AuthorizationScheme = request.Headers.Authorization?.Scheme ?? string.Empty;
        RequestBody = request.Content == null
            ? string.Empty
            : await request.Content.ReadAsStringAsync(cancellationToken);

        return new HttpResponseMessage(statusCode)
        {
            Content = new StringContent(responseJson, Encoding.UTF8, "application/json"),
        };
    }
}
