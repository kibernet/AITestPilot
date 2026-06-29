using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Kibernet.AITestPilot.Core;

public sealed class ModelEndpointDecisionClientOptions
{
    public required Uri Endpoint { get; init; }

    public string? ApiKey { get; init; }

    public string AuthorizationScheme { get; init; } = "Bearer";

    public string? Model { get; init; }

    public ModelEndpointRequestFormat RequestFormat { get; init; } = ModelEndpointRequestFormat.NativeJson;

    public string RunId { get; init; } = "manual";

    public string? TraceDirectory { get; init; }

    public string SystemPrompt { get; init; } =
        "You are AI TestPilot. Return exactly one JSON action that conforms to the supplied action schema. " +
        "Use only whitelisted actions and target visible automation ids when an action needs a target.";
}

public sealed class ModelEndpointDecisionClient : IDecisionClient
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        WriteIndented = true,
    };

    private static readonly Regex JsonCodeBlock = new(
        "```(?:json)?\\s*(?<json>.*?)\\s*```",
        RegexOptions.IgnoreCase | RegexOptions.Singleline | RegexOptions.Compiled);

    private readonly HttpClient httpClient;
    private readonly ModelEndpointDecisionClientOptions options;
    private readonly IDecisionTraceSink? traceSink;

    public ModelEndpointDecisionClient(
        HttpClient httpClient,
        ModelEndpointDecisionClientOptions options,
        IDecisionTraceSink? traceSink = null)
    {
        this.httpClient = httpClient ?? throw new ArgumentNullException(nameof(httpClient));
        this.options = options ?? throw new ArgumentNullException(nameof(options));
        this.traceSink = traceSink ?? CreateTraceSink(options.TraceDirectory);

        if (options.Endpoint == null)
        {
            throw new ArgumentException("Model endpoint is required.", nameof(options));
        }
    }

    public async ValueTask<TestPilotAction> DecideAsync(DecisionRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        var endpointRequest = ModelDecisionEndpointRequest.From(request, options);
        var requestJson = BuildRequestJson(endpointRequest, options);
        var responseJson = string.Empty;
        TestPilotAction? action = null;
        string? error = null;

        try
        {
            using var message = new HttpRequestMessage(HttpMethod.Post, options.Endpoint)
            {
                Content = new StringContent(requestJson, Encoding.UTF8, "application/json"),
            };

            if (!string.IsNullOrWhiteSpace(options.ApiKey))
            {
                message.Headers.Authorization = new AuthenticationHeaderValue(
                    options.AuthorizationScheme,
                    options.ApiKey);
            }

            using var response = await httpClient.SendAsync(message, cancellationToken).ConfigureAwait(false);
            responseJson = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);

            if (!response.IsSuccessStatusCode)
            {
                throw new ModelEndpointDecisionException(
                    "Model endpoint returned HTTP " + (int)response.StatusCode + ": " + responseJson);
            }

            action = ParseActionResponse(responseJson);
            action.Validate();
            return action;
        }
        catch (Exception ex)
        {
            error = ex.Message;
            throw;
        }
        finally
        {
            if (traceSink != null)
            {
                await traceSink
                    .RecordAsync(
                        new DecisionTraceRecord
                        {
                            RunId = options.RunId,
                            StepIndex = request.Snapshot.StepIndex,
                            Goal = request.Goal,
                            Snapshot = request.Snapshot,
                            PreviousSteps = request.PreviousSteps,
                            Prompt = endpointRequest.SystemPrompt,
                            RequestJson = requestJson,
                            ResponseJson = responseJson,
                            Action = action,
                            Status = error == null ? "PASS" : "FAIL",
                            Error = error,
                            RecordedAtUtc = DateTimeOffset.UtcNow,
                        },
                        cancellationToken)
                    .ConfigureAwait(false);
            }
        }
    }

    public static TestPilotAction ParseActionResponse(string responseJson)
    {
        if (string.IsNullOrWhiteSpace(responseJson))
        {
            throw new ModelEndpointDecisionException("Model endpoint returned an empty response.");
        }

        using var document = JsonDocument.Parse(responseJson);
        if (TryReadAction(document.RootElement, out var directAction))
        {
            return directAction;
        }

        if (TryReadWrappedAction(document.RootElement, out var wrappedAction))
        {
            return wrappedAction;
        }

        if (TryReadTextPayload(document.RootElement, out var textPayload) &&
            TryReadActionFromText(textPayload, out var textAction))
        {
            return textAction;
        }

        throw new ModelEndpointDecisionException("Model endpoint response did not contain a valid AI TestPilot action.");
    }

    public static string BuildRequestJson(
        ModelDecisionEndpointRequest endpointRequest,
        ModelEndpointDecisionClientOptions options)
    {
        ArgumentNullException.ThrowIfNull(endpointRequest);
        ArgumentNullException.ThrowIfNull(options);

        if (options.RequestFormat == ModelEndpointRequestFormat.OpenAICompatibleChatCompletions)
        {
            return JsonSerializer.Serialize(
                OpenAICompatibleChatCompletionRequest.From(endpointRequest, options),
                JsonOptions);
        }

        return JsonSerializer.Serialize(endpointRequest, JsonOptions);
    }

    private static IDecisionTraceSink? CreateTraceSink(string? traceDirectory)
    {
        return string.IsNullOrWhiteSpace(traceDirectory)
            ? null
            : new FileDecisionTraceSink(traceDirectory);
    }

    private static bool TryReadWrappedAction(JsonElement root, out TestPilotAction action)
    {
        action = TestPilotAction.Finish();

        foreach (var propertyName in new[] { "decision", "aiAction", "testPilotAction" })
        {
            if (root.TryGetProperty(propertyName, out var property) &&
                property.ValueKind == JsonValueKind.Object &&
                TryReadAction(property, out action))
            {
                return true;
            }
        }

        if (root.TryGetProperty("action", out var nestedAction) &&
            nestedAction.ValueKind == JsonValueKind.Object &&
            TryReadAction(nestedAction, out action))
        {
            return true;
        }

        return false;
    }

    private static bool TryReadTextPayload(JsonElement root, out string text)
    {
        text = string.Empty;

        if (root.TryGetProperty("output_text", out var outputText) &&
            outputText.ValueKind == JsonValueKind.String)
        {
            text = outputText.GetString() ?? string.Empty;
            return !string.IsNullOrWhiteSpace(text);
        }

        if (root.TryGetProperty("content", out var content) &&
            content.ValueKind == JsonValueKind.String)
        {
            text = content.GetString() ?? string.Empty;
            return !string.IsNullOrWhiteSpace(text);
        }

        if (root.TryGetProperty("choices", out var choices) &&
            choices.ValueKind == JsonValueKind.Array &&
            choices.GetArrayLength() > 0)
        {
            var firstChoice = choices[0];
            if (firstChoice.TryGetProperty("message", out var message) &&
                message.TryGetProperty("content", out var messageContent) &&
                messageContent.ValueKind == JsonValueKind.String)
            {
                text = messageContent.GetString() ?? string.Empty;
                return !string.IsNullOrWhiteSpace(text);
            }

            if (firstChoice.TryGetProperty("text", out var choiceText) &&
                choiceText.ValueKind == JsonValueKind.String)
            {
                text = choiceText.GetString() ?? string.Empty;
                return !string.IsNullOrWhiteSpace(text);
            }
        }

        return false;
    }

    private static bool TryReadActionFromText(string textPayload, out TestPilotAction action)
    {
        action = TestPilotAction.Finish();
        var trimmed = textPayload.Trim();
        var match = JsonCodeBlock.Match(trimmed);
        if (match.Success)
        {
            trimmed = match.Groups["json"].Value.Trim();
        }

        try
        {
            using var document = JsonDocument.Parse(trimmed);
            return TryReadAction(document.RootElement, out action) ||
                   TryReadWrappedAction(document.RootElement, out action);
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static bool TryReadAction(JsonElement element, out TestPilotAction action)
    {
        action = TestPilotAction.Finish();

        if (element.ValueKind != JsonValueKind.Object ||
            !element.TryGetProperty("action", out var actionProperty) ||
            actionProperty.ValueKind != JsonValueKind.String)
        {
            return false;
        }

        var parsed = element.Deserialize<TestPilotAction>(JsonOptions);
        if (parsed == null)
        {
            return false;
        }

        action = parsed;
        return true;
    }
}

public enum ModelEndpointRequestFormat
{
    NativeJson,
    OpenAICompatibleChatCompletions,
}

public sealed class ModelDecisionEndpointRequest
{
    public string SchemaVersion { get; init; } = "ai-testpilot.decision_request.v1";

    public string? Model { get; init; }

    public string SystemPrompt { get; init; } = string.Empty;

    public string Goal { get; init; } = string.Empty;

    public Snapshot Snapshot { get; init; } = new();

    public IReadOnlyList<string> PreviousSteps { get; init; } = Array.Empty<string>();

    public IReadOnlyList<string> FixHints { get; init; } = Array.Empty<string>();

    public string ActionSchemaVersion { get; init; } = DecisionActionSchema.SchemaVersion;

    public string ActionJsonSchema { get; init; } = string.Empty;

    public IReadOnlyList<string> AllowedActions { get; init; } = DecisionActionSchema.AllowedActions;

    public static ModelDecisionEndpointRequest From(
        DecisionRequest request,
        ModelEndpointDecisionClientOptions options)
    {
        return new ModelDecisionEndpointRequest
        {
            Model = options.Model,
            SystemPrompt = options.SystemPrompt,
            Goal = request.Goal,
            Snapshot = request.Snapshot,
            PreviousSteps = request.PreviousSteps,
            FixHints = request.FixHints,
            ActionJsonSchema = DecisionActionSchema.CreateJsonSchema(),
        };
    }
}

public sealed class OpenAICompatibleChatCompletionRequest
{
    public string? Model { get; init; }

    public IReadOnlyList<OpenAICompatibleChatMessage> Messages { get; init; } =
        Array.Empty<OpenAICompatibleChatMessage>();

    [JsonPropertyName("response_format")]
    public OpenAICompatibleResponseFormat ResponseFormat { get; init; } = new();

    public static OpenAICompatibleChatCompletionRequest From(
        ModelDecisionEndpointRequest endpointRequest,
        ModelEndpointDecisionClientOptions options)
    {
        var nativeContractJson = JsonSerializer.Serialize(endpointRequest, new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            WriteIndented = false,
        });

        return new OpenAICompatibleChatCompletionRequest
        {
            Model = options.Model,
            Messages = new[]
            {
                new OpenAICompatibleChatMessage
                {
                    Role = "system",
                    Content = endpointRequest.SystemPrompt,
                },
                new OpenAICompatibleChatMessage
                {
                    Role = "user",
                    Content =
                        "Return exactly one AI TestPilot action JSON object. " +
                        "Do not include markdown or commentary. Contract: " +
                        nativeContractJson,
                },
            },
        };
    }
}

public sealed class OpenAICompatibleChatMessage
{
    public string Role { get; init; } = string.Empty;

    public string Content { get; init; } = string.Empty;
}

public sealed class OpenAICompatibleResponseFormat
{
    public string Type { get; init; } = "json_object";
}

public sealed class ModelEndpointDecisionException : InvalidOperationException
{
    public ModelEndpointDecisionException(string message)
        : base(message)
    {
    }
}
