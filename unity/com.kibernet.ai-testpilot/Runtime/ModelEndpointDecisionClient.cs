using System;
using System.Collections;
using System.Collections.Generic;
using System.Text;
using UnityEngine;
using UnityEngine.Networking;

namespace Kibernet.AITestPilot.Unity
{
    public static class ModelEndpointDecisionClient
    {
        public const string DecisionRequestSchemaVersion = "ai-testpilot.decision_request.v1";
        public const string ActionSchemaVersion = "ai-testpilot.action.v1";

        private static readonly string[] AllowedActions =
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
        };

        public static string BuildRequestJson(
            ModelEndpointSettings settings,
            string goal,
            AITestSnapshot snapshot,
            IList<string> previousSteps,
            IList<string> fixHints = null)
        {
            if (settings == null)
            {
                throw new ArgumentNullException("settings");
            }

            if (snapshot == null)
            {
                throw new ArgumentNullException("snapshot");
            }

            var request = BuildNativeRequest(settings, goal, snapshot, previousSteps, fixHints);
            if (settings.requestFormat == ModelEndpointRequestFormat.OpenAICompatibleChatCompletions)
            {
                return JsonUtility.ToJson(BuildOpenAICompatibleChatRequest(settings, request), true);
            }

            return JsonUtility.ToJson(request, true);
        }

        public static ModelEndpointDecisionRequest BuildNativeRequest(
            ModelEndpointSettings settings,
            string goal,
            AITestSnapshot snapshot,
            IList<string> previousSteps,
            IList<string> fixHints = null)
        {
            if (settings == null)
            {
                throw new ArgumentNullException("settings");
            }

            if (snapshot == null)
            {
                throw new ArgumentNullException("snapshot");
            }

            return new ModelEndpointDecisionRequest
            {
                schemaVersion = DecisionRequestSchemaVersion,
                model = settings.model,
                systemPrompt = settings.systemPrompt,
                goal = goal,
                snapshot = snapshot,
                previousSteps = previousSteps == null ? new List<string>() : new List<string>(previousSteps),
                fixHints = fixHints == null ? new List<string>() : new List<string>(fixHints),
                actionSchemaVersion = ActionSchemaVersion,
                actionJsonSchema = BuildActionJsonSchema(),
                allowedActions = new List<string>(AllowedActions)
            };
        }

        public static ModelEndpointChatCompletionRequest BuildOpenAICompatibleChatRequest(
            ModelEndpointSettings settings,
            ModelEndpointDecisionRequest nativeRequest)
        {
            if (settings == null)
            {
                throw new ArgumentNullException("settings");
            }

            if (nativeRequest == null)
            {
                throw new ArgumentNullException("nativeRequest");
            }

            var nativeContractJson = JsonUtility.ToJson(nativeRequest, false);
            return new ModelEndpointChatCompletionRequest
            {
                model = settings.model,
                messages = new List<ModelEndpointChatMessage>
                {
                    new ModelEndpointChatMessage
                    {
                        role = "system",
                        content = nativeRequest.systemPrompt
                    },
                    new ModelEndpointChatMessage
                    {
                        role = "user",
                        content =
                            "Return exactly one AI TestPilot action JSON object. " +
                            "Do not include markdown or commentary. Contract: " +
                            nativeContractJson
                    }
                },
                response_format = new ModelEndpointResponseFormat
                {
                    type = "json_object"
                }
            };
        }

        public static string BuildActionJsonSchema()
        {
            return "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\"," +
                   "\"$id\":\"" + ActionSchemaVersion + "\"," +
                   "\"title\":\"AI TestPilot action\"," +
                   "\"type\":\"object\"," +
                   "\"additionalProperties\":false," +
                   "\"required\":[\"action\"]," +
                   "\"properties\":{" +
                   "\"action\":{\"type\":\"string\",\"enum\":[\"click\",\"wait\",\"prepare_account\",\"login\",\"enter_scene\",\"close_popup\",\"claim_reward\",\"play_fishing\",\"finish\"]}," +
                   "\"target\":{\"type\":[\"string\",\"null\"]}," +
                   "\"waitMilliseconds\":{\"type\":\"integer\",\"minimum\":0}," +
                   "\"parameters\":{\"type\":\"array\"}" +
                   "}}";
        }

        public static AIAction ParseActionResponse(string responseJson)
        {
            if (string.IsNullOrWhiteSpace(responseJson))
            {
                throw new InvalidOperationException("Model endpoint returned an empty response.");
            }

            var action = TryParseAction(responseJson);
            if (action == null)
            {
                var wrapper = JsonUtility.FromJson<ModelEndpointActionWrapper>(responseJson);
                if (wrapper != null)
                {
                    action = wrapper.decision ??
                             wrapper.aiAction ??
                             wrapper.testPilotAction;

                    if (action == null && !string.IsNullOrWhiteSpace(wrapper.output_text))
                    {
                        action = TryParseAction(wrapper.output_text);
                    }

                    if (action == null && !string.IsNullOrWhiteSpace(wrapper.content))
                    {
                        action = TryParseAction(wrapper.content);
                    }

                    if (action == null &&
                        wrapper.choices != null &&
                        wrapper.choices.Count > 0 &&
                        wrapper.choices[0] != null &&
                        wrapper.choices[0].message != null)
                    {
                        action = TryParseAction(wrapper.choices[0].message.content);
                    }

                    if (action == null &&
                        wrapper.choices != null &&
                        wrapper.choices.Count > 0 &&
                        wrapper.choices[0] != null)
                    {
                        action = TryParseAction(wrapper.choices[0].text);
                    }
                }
            }

            if (action == null)
            {
                throw new InvalidOperationException("Model endpoint response did not include a valid AI TestPilot action.");
            }

            ValidateAction(action);
            return action;
        }

        public static void ValidateAction(AIAction action)
        {
            if (action == null)
            {
                throw new InvalidOperationException("Model endpoint action is missing.");
            }

            if (!ActionWhitelist.IsAllowed(action.action))
            {
                throw new InvalidOperationException("Model endpoint action is not whitelisted: " + action.action);
            }

            if (string.Equals(action.action, ActionWhitelist.Click, StringComparison.OrdinalIgnoreCase) &&
                string.IsNullOrWhiteSpace(action.target))
            {
                throw new InvalidOperationException("Model endpoint click action requires a target.");
            }

            if (string.Equals(action.action, ActionWhitelist.Wait, StringComparison.OrdinalIgnoreCase) &&
                action.waitMilliseconds < 0)
            {
                throw new InvalidOperationException("Model endpoint wait action cannot use a negative duration.");
            }
        }

        public static IEnumerator DecideRoutine(
            ModelEndpointSettings settings,
            string goal,
            AITestSnapshot snapshot,
            IList<string> previousSteps,
            Action<AIAction> onCompleted,
            Action<string> onFailed)
        {
            var requestJson = BuildRequestJson(settings, goal, snapshot, previousSteps);
            var body = Encoding.UTF8.GetBytes(requestJson);

            using (var request = new UnityWebRequest(settings.endpointUrl, UnityWebRequest.kHttpVerbPOST))
            {
                request.uploadHandler = new UploadHandlerRaw(body);
                request.downloadHandler = new DownloadHandlerBuffer();
                request.SetRequestHeader("Content-Type", "application/json");
                request.timeout = settings.timeoutSeconds;

                var apiKey = settings.ResolveApiKey();
                if (!string.IsNullOrWhiteSpace(apiKey))
                {
                    request.SetRequestHeader(
                        "Authorization",
                        (string.IsNullOrWhiteSpace(settings.authorizationScheme)
                            ? "Bearer"
                            : settings.authorizationScheme) + " " + apiKey);
                }

                yield return request.SendWebRequest();

                if (request.result != UnityWebRequest.Result.Success)
                {
                    if (onFailed != null)
                    {
                        onFailed(request.error);
                    }

                    yield break;
                }

                try
                {
                    var action = ParseActionResponse(request.downloadHandler.text);
                    if (onCompleted != null)
                    {
                        onCompleted(action);
                    }
                }
                catch (Exception ex)
                {
                    if (onFailed != null)
                    {
                        onFailed(ex.Message);
                    }
                }
            }
        }

        private static AIAction TryParseAction(string json)
        {
            if (string.IsNullOrWhiteSpace(json))
            {
                return null;
            }

            var trimmed = TrimCodeFence(json.Trim());
            if (!ContainsTopLevelActionProperty(trimmed))
            {
                return null;
            }

            try
            {
                var action = JsonUtility.FromJson<AIAction>(trimmed);
                return action == null || string.IsNullOrWhiteSpace(action.action)
                    ? null
                    : action;
            }
            catch (ArgumentException)
            {
                return null;
            }
        }

        private static string TrimCodeFence(string value)
        {
            if (!value.StartsWith("```", StringComparison.Ordinal))
            {
                return value;
            }

            var firstLine = value.IndexOf('\n');
            var lastFence = value.LastIndexOf("```", StringComparison.Ordinal);
            if (firstLine >= 0 && lastFence > firstLine)
            {
                return value.Substring(firstLine + 1, lastFence - firstLine - 1).Trim();
            }

            return value;
        }

        private static bool ContainsTopLevelActionProperty(string json)
        {
            var depth = 0;
            var inString = false;
            var escaped = false;

            for (var i = 0; i < json.Length; i++)
            {
                var c = json[i];
                if (inString)
                {
                    if (escaped)
                    {
                        escaped = false;
                    }
                    else if (c == '\\')
                    {
                        escaped = true;
                    }
                    else if (c == '"')
                    {
                        inString = false;
                    }

                    continue;
                }

                if (c == '"')
                {
                    if (depth == 1 &&
                        TryReadJsonString(json, i, out var name, out var endIndex) &&
                        string.Equals(name, "action", StringComparison.Ordinal))
                    {
                        var next = SkipWhitespace(json, endIndex + 1);
                        return next < json.Length && json[next] == ':';
                    }

                    inString = true;
                }
                else if (c == '{' || c == '[')
                {
                    depth++;
                }
                else if (c == '}' || c == ']')
                {
                    depth--;
                }
            }

            return false;
        }

        private static bool TryReadJsonString(string json, int startIndex, out string value, out int endIndex)
        {
            value = string.Empty;
            endIndex = startIndex;

            if (startIndex < 0 || startIndex >= json.Length || json[startIndex] != '"')
            {
                return false;
            }

            var builder = new StringBuilder();
            var escaped = false;
            for (var i = startIndex + 1; i < json.Length; i++)
            {
                var c = json[i];
                if (escaped)
                {
                    builder.Append(c);
                    escaped = false;
                    continue;
                }

                if (c == '\\')
                {
                    escaped = true;
                    continue;
                }

                if (c == '"')
                {
                    value = builder.ToString();
                    endIndex = i;
                    return true;
                }

                builder.Append(c);
            }

            return false;
        }

        private static int SkipWhitespace(string value, int startIndex)
        {
            var index = startIndex;
            while (index < value.Length && char.IsWhiteSpace(value[index]))
            {
                index++;
            }

            return index;
        }
    }

    [Serializable]
    public sealed class ModelEndpointDecisionRequest
    {
        public string schemaVersion;
        public string model;
        public string systemPrompt;
        public string goal;
        public AITestSnapshot snapshot;
        public List<string> previousSteps;
        public List<string> fixHints;
        public string actionSchemaVersion;
        public string actionJsonSchema;
        public List<string> allowedActions;
    }

    [Serializable]
    public sealed class ModelEndpointChatCompletionRequest
    {
        public string model;
        public List<ModelEndpointChatMessage> messages;
        public ModelEndpointResponseFormat response_format;
    }

    [Serializable]
    public sealed class ModelEndpointChatMessage
    {
        public string role;
        public string content;
    }

    [Serializable]
    public sealed class ModelEndpointResponseFormat
    {
        public string type;
    }

    [Serializable]
    internal sealed class ModelEndpointActionWrapper
    {
        public AIAction decision;
        public AIAction aiAction;
        public AIAction testPilotAction;
        public string output_text;
        public string content;
        public List<ModelEndpointChoice> choices;
    }

    [Serializable]
    internal sealed class ModelEndpointChoice
    {
        public ModelEndpointChoiceMessage message;
        public string text;
    }

    [Serializable]
    internal sealed class ModelEndpointChoiceMessage
    {
        public string content;
    }
}
