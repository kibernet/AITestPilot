using System;
using System.Collections.Generic;
using UnityEngine;

namespace Kibernet.AITestPilot.Unity
{
    [CreateAssetMenu(
        fileName = "AI TestPilot Model Endpoint Settings",
        menuName = "Kibernet/AI TestPilot/Model Endpoint Settings")]
    public sealed class ModelEndpointSettings : ScriptableObject
    {
        public string endpointUrl = "https://your-model-gateway.example/decide";
        public string model = "your-model";
        public ModelEndpointRequestFormat requestFormat = ModelEndpointRequestFormat.NativeJson;
        public string apiKeyEnvironmentVariable = "AI_TESTPILOT_MODEL_API_KEY";
        public string authorizationScheme = "Bearer";
        public int timeoutSeconds = 30;
        public bool liveRequestsEnabled;
        public string traceDirectory = "Temp/AITestPilot/ModelEndpointTraces";
        [TextArea(3, 8)]
        public string systemPrompt =
            "You are AI TestPilot. Return exactly one JSON action that conforms to the supplied action schema. " +
            "Use only whitelisted actions and target visible automation ids when an action needs a target.";

        public bool TryValidate(out List<string> issues)
        {
            issues = new List<string>();

            if (string.IsNullOrWhiteSpace(endpointUrl))
            {
                issues.Add("Endpoint URL is required.");
            }
            else if (!Uri.IsWellFormedUriString(endpointUrl, UriKind.Absolute))
            {
                issues.Add("Endpoint URL must be an absolute URI.");
            }

            if (string.IsNullOrWhiteSpace(model))
            {
                issues.Add("Model name is required.");
            }

            if (string.IsNullOrWhiteSpace(systemPrompt))
            {
                issues.Add("System prompt is required.");
            }

            if (timeoutSeconds <= 0)
            {
                issues.Add("Timeout must be greater than zero.");
            }

            if (string.IsNullOrWhiteSpace(traceDirectory))
            {
                issues.Add("Trace directory is required.");
            }

            if (liveRequestsEnabled &&
                !string.IsNullOrWhiteSpace(apiKeyEnvironmentVariable) &&
                string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable(apiKeyEnvironmentVariable)))
            {
                issues.Add("Live requests are enabled, but the configured API key environment variable is empty.");
            }

            return issues.Count == 0;
        }

        public string ResolveApiKey()
        {
            return string.IsNullOrWhiteSpace(apiKeyEnvironmentVariable)
                ? string.Empty
                : Environment.GetEnvironmentVariable(apiKeyEnvironmentVariable) ?? string.Empty;
        }
    }

    public enum ModelEndpointRequestFormat
    {
        NativeJson,
        OpenAICompatibleChatCompletions
    }
}
