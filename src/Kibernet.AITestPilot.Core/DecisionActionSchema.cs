using System.Text.Json;

namespace Kibernet.AITestPilot.Core;

public static class DecisionActionSchema
{
    public const string SchemaVersion = "ai-testpilot.action.v1";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
    };

    public static IReadOnlyList<string> AllowedActions { get; } = new[]
    {
        ActionVerbs.Click,
        ActionVerbs.Wait,
        ActionVerbs.PrepareAccount,
        ActionVerbs.Login,
        ActionVerbs.EnterScene,
        ActionVerbs.ClosePopup,
        ActionVerbs.ClaimReward,
        ActionVerbs.PlayFishing,
        ActionVerbs.Finish,
    };

    public static string CreateJsonSchema()
    {
        var schema = new Dictionary<string, object?>
        {
            ["$schema"] = "https://json-schema.org/draft/2020-12/schema",
            ["$id"] = SchemaVersion,
            ["title"] = "AI TestPilot action",
            ["type"] = "object",
            ["additionalProperties"] = false,
            ["required"] = new[] { "action" },
            ["properties"] = new Dictionary<string, object?>
            {
                ["action"] = new Dictionary<string, object?>
                {
                    ["type"] = "string",
                    ["enum"] = AllowedActions,
                },
                ["target"] = new Dictionary<string, object?>
                {
                    ["type"] = new[] { "string", "null" },
                },
                ["waitMilliseconds"] = new Dictionary<string, object?>
                {
                    ["type"] = "integer",
                    ["minimum"] = 0,
                },
                ["parameters"] = new Dictionary<string, object?>
                {
                    ["type"] = "object",
                    ["additionalProperties"] = new Dictionary<string, object?>
                    {
                        ["type"] = "string",
                    },
                },
            },
            ["allOf"] = new object[]
            {
                new Dictionary<string, object?>
                {
                    ["if"] = new Dictionary<string, object?>
                    {
                        ["properties"] = new Dictionary<string, object?>
                        {
                            ["action"] = new Dictionary<string, object?>
                            {
                                ["const"] = ActionVerbs.Click,
                            },
                        },
                    },
                    ["then"] = new Dictionary<string, object?>
                    {
                        ["required"] = new[] { "target" },
                    },
                },
                new Dictionary<string, object?>
                {
                    ["if"] = new Dictionary<string, object?>
                    {
                        ["properties"] = new Dictionary<string, object?>
                        {
                            ["action"] = new Dictionary<string, object?>
                            {
                                ["const"] = ActionVerbs.Wait,
                            },
                        },
                    },
                    ["then"] = new Dictionary<string, object?>
                    {
                        ["required"] = new[] { "waitMilliseconds" },
                    },
                },
            },
        };

        return JsonSerializer.Serialize(schema, JsonOptions);
    }
}
