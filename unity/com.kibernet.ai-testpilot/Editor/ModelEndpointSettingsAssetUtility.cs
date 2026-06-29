using System;
using System.Collections.Generic;
using System.IO;
using Kibernet.AITestPilot.Unity;
using UnityEditor;
using UnityEngine;

namespace Kibernet.AITestPilot.Unity.Editor
{
    public static class ModelEndpointSettingsAssetUtility
    {
        public const string DefaultSettingsAssetPath = "Assets/AITestPilotGenerated/ModelEndpointSettings.asset";
        public const string OpenAICompatibleSettingsAssetPath = "Assets/AITestPilotGenerated/OpenAICompatibleModelEndpointSettings.asset";

        [MenuItem("Tools/Kibernet/AI TestPilot/Create Model Endpoint Settings")]
        public static void CreateModelEndpointSettingsMenu()
        {
            var settings = CreateOrUpdateSampleSettings(DefaultSettingsAssetPath);
            Selection.activeObject = settings;
        }

        [MenuItem("Tools/Kibernet/AI TestPilot/Create OpenAI-Compatible Model Endpoint Settings")]
        public static void CreateOpenAICompatibleModelEndpointSettingsMenu()
        {
            var settings = CreateOrUpdateOpenAICompatibleSettings(OpenAICompatibleSettingsAssetPath);
            Selection.activeObject = settings;
        }

        public static ModelEndpointSettings CreateOrUpdateSampleSettings(string assetPath)
        {
            assetPath = NormalizeUnityAssetPath(assetPath);
            EnsureAssetDirectory(assetPath);

            var settings = AssetDatabase.LoadAssetAtPath<ModelEndpointSettings>(assetPath);
            if (settings == null)
            {
                settings = ScriptableObject.CreateInstance<ModelEndpointSettings>();
                AssetDatabase.CreateAsset(settings, assetPath);
            }

            settings.endpointUrl = "https://your-model-gateway.example/decide";
            settings.model = "your-model";
            settings.requestFormat = ModelEndpointRequestFormat.NativeJson;
            settings.apiKeyEnvironmentVariable = "AI_TESTPILOT_MODEL_API_KEY";
            settings.authorizationScheme = "Bearer";
            settings.timeoutSeconds = 30;
            settings.liveRequestsEnabled = false;
            settings.traceDirectory = "Temp/AITestPilot/ModelEndpointTraces";
            settings.systemPrompt =
                "You are AI TestPilot. Return exactly one JSON action that conforms to the supplied action schema. " +
                "Use only whitelisted actions and target visible automation ids when an action needs a target.";

            EditorUtility.SetDirty(settings);
            AssetDatabase.SaveAssets();
            AssetDatabase.Refresh();
            return settings;
        }

        public static ModelEndpointSettings CreateOrUpdateOpenAICompatibleSettings(string assetPath)
        {
            var settings = CreateOrUpdateSampleSettings(assetPath);
            settings.endpointUrl = "https://your-openai-compatible-gateway.example/v1/chat/completions";
            settings.model = "your-chat-model";
            settings.requestFormat = ModelEndpointRequestFormat.OpenAICompatibleChatCompletions;
            EditorUtility.SetDirty(settings);
            AssetDatabase.SaveAssets();
            AssetDatabase.Refresh();
            return settings;
        }

        public static ModelEndpointSettingsEvidence ValidateOfflineContract(
            ModelEndpointSettings settings,
            AITestSnapshot snapshot,
            IList<string> fixHints = null)
        {
            if (settings == null)
            {
                throw new ArgumentNullException("settings");
            }

            var configurationValid = settings.TryValidate(out var issues);
            var requestJson = ModelEndpointDecisionClient.BuildRequestJson(
                settings,
                "click the sample start button",
                snapshot,
                new List<string>(),
                fixHints);
            var nativeRequest = ModelEndpointDecisionClient.BuildNativeRequest(
                settings,
                "click the sample start button",
                snapshot,
                new List<string>(),
                fixHints);
            var openAICompatibleChatRequestJson = JsonUtility.ToJson(
                ModelEndpointDecisionClient.BuildOpenAICompatibleChatRequest(settings, nativeRequest),
                true);
            var responseJson = "{\"action\":\"click\",\"target\":\"" + AITestPilotSampleSceneBuilder.ButtonAutomationId + "\"}";
            var action = ModelEndpointDecisionClient.ParseActionResponse(responseJson);
            var requestContainsSnapshot = requestJson.IndexOf("\"snapshot\"", StringComparison.Ordinal) >= 0 &&
                                          requestJson.IndexOf(AITestPilotSampleSceneBuilder.ButtonAutomationId, StringComparison.Ordinal) >= 0;
            var requestContainsActionSchema = requestJson.IndexOf(ModelEndpointDecisionClient.ActionSchemaVersion, StringComparison.Ordinal) >= 0 &&
                                              requestJson.IndexOf("\"allowedActions\"", StringComparison.Ordinal) >= 0;
            var requestContainsFixHints = requestJson.IndexOf("\"fixHints\"", StringComparison.Ordinal) >= 0 &&
                                          requestJson.IndexOf("add null guard before reward access", StringComparison.Ordinal) >= 0;
            var openAICompatibleChatRequestValid =
                openAICompatibleChatRequestJson.IndexOf("\"messages\"", StringComparison.Ordinal) >= 0 &&
                openAICompatibleChatRequestJson.IndexOf("\"response_format\"", StringComparison.Ordinal) >= 0 &&
                openAICompatibleChatRequestJson.IndexOf("\"json_object\"", StringComparison.Ordinal) >= 0 &&
                openAICompatibleChatRequestJson.IndexOf(ModelEndpointDecisionClient.ActionSchemaVersion, StringComparison.Ordinal) >= 0 &&
                openAICompatibleChatRequestJson.IndexOf("add null guard before reward access", StringComparison.Ordinal) >= 0 &&
                openAICompatibleChatRequestJson.IndexOf(AITestPilotSampleSceneBuilder.ButtonAutomationId, StringComparison.Ordinal) >= 0;
            var selectedRequestUsesProviderEnvelope =
                settings.requestFormat == ModelEndpointRequestFormat.OpenAICompatibleChatCompletions &&
                requestJson.IndexOf("\"messages\"", StringComparison.Ordinal) >= 0 &&
                requestJson.IndexOf("\"response_format\"", StringComparison.Ordinal) >= 0;

            return new ModelEndpointSettingsEvidence
            {
                status = configurationValid &&
                         requestContainsSnapshot &&
                         requestContainsActionSchema &&
                         requestContainsFixHints &&
                         openAICompatibleChatRequestValid &&
                         string.Equals(action.action, ActionWhitelist.Click, StringComparison.OrdinalIgnoreCase)
                    ? "PASS"
                    : "FAIL",
                settingsAssetPath = AssetDatabase.GetAssetPath(settings),
                endpointUrl = settings.endpointUrl,
                model = settings.model,
                requestFormat = settings.requestFormat.ToString(),
                apiKeyEnvironmentVariable = settings.apiKeyEnvironmentVariable,
                authorizationScheme = settings.authorizationScheme,
                timeoutSeconds = settings.timeoutSeconds,
                liveRequestsEnabled = settings.liveRequestsEnabled,
                traceDirectory = settings.traceDirectory,
                actionSchemaVersion = ModelEndpointDecisionClient.ActionSchemaVersion,
                allowedActionCount = CountAllowedActions(requestJson),
                configurationValid = configurationValid,
                validationIssues = issues,
                requestContainsSnapshot = requestContainsSnapshot,
                requestContainsActionSchema = requestContainsActionSchema,
                requestContainsFixHints = requestContainsFixHints,
                fixHintCount = fixHints == null ? 0 : fixHints.Count,
                selectedRequestUsesProviderEnvelope = selectedRequestUsesProviderEnvelope,
                openAICompatibleChatRequestValid = openAICompatibleChatRequestValid,
                parsedAction = action.action,
                parsedTarget = action.target
            };
        }

        public static string NormalizeUnityAssetPath(string assetPath)
        {
            if (string.IsNullOrWhiteSpace(assetPath))
            {
                throw new ArgumentException("Model endpoint settings asset path is required.", "assetPath");
            }

            var normalized = assetPath.Replace("\\", "/");
            if (!normalized.StartsWith("Assets/", StringComparison.Ordinal) &&
                !string.Equals(normalized, "Assets", StringComparison.Ordinal))
            {
                throw new ArgumentException("Model endpoint settings asset path must be under Assets/.", "assetPath");
            }

            if (!normalized.EndsWith(".asset", StringComparison.OrdinalIgnoreCase))
            {
                throw new ArgumentException("Model endpoint settings asset path must end with .asset.", "assetPath");
            }

            return normalized;
        }

        private static int CountAllowedActions(string requestJson)
        {
            var count = 0;
            foreach (var action in new[]
                     {
                         ActionWhitelist.Click,
                         ActionWhitelist.Wait,
                         ActionWhitelist.PrepareAccount,
                         ActionWhitelist.Login,
                         ActionWhitelist.EnterScene,
                         ActionWhitelist.ClosePopup,
                         ActionWhitelist.ClaimReward,
                         ActionWhitelist.PlayFishing,
                         ActionWhitelist.Finish
                     })
            {
                if (requestJson.IndexOf("\"" + action + "\"", StringComparison.Ordinal) >= 0)
                {
                    count++;
                }
            }

            return count;
        }

        private static void EnsureAssetDirectory(string assetPath)
        {
            var directory = Path.GetDirectoryName(assetPath);
            if (string.IsNullOrWhiteSpace(directory))
            {
                return;
            }

            var parts = directory.Replace("\\", "/").Split('/');
            var current = parts[0];
            for (var i = 1; i < parts.Length; i++)
            {
                var next = current + "/" + parts[i];
                if (!AssetDatabase.IsValidFolder(next))
                {
                    AssetDatabase.CreateFolder(current, parts[i]);
                }

                current = next;
            }
        }
    }

    [Serializable]
    public sealed class ModelEndpointSettingsEvidence
    {
        public string status;
        public string settingsAssetPath;
        public string endpointUrl;
        public string model;
        public string requestFormat;
        public string apiKeyEnvironmentVariable;
        public string authorizationScheme;
        public int timeoutSeconds;
        public bool liveRequestsEnabled;
        public string traceDirectory;
        public string actionSchemaVersion;
        public int allowedActionCount;
        public bool configurationValid;
        public List<string> validationIssues;
        public bool requestContainsSnapshot;
        public bool requestContainsActionSchema;
        public bool requestContainsFixHints;
        public int fixHintCount;
        public bool selectedRequestUsesProviderEnvelope;
        public bool openAICompatibleChatRequestValid;
        public string parsedAction;
        public string parsedTarget;
    }
}
