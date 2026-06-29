namespace Kibernet.AITestPilot.Core;

public static class ActionVerbs
{
    public const string Click = "click";
    public const string Wait = "wait";
    public const string PrepareAccount = "prepare_account";
    public const string Login = "login";
    public const string EnterScene = "enter_scene";
    public const string ClosePopup = "close_popup";
    public const string ClaimReward = "claim_reward";
    public const string PlayFishing = "play_fishing";
    public const string Finish = "finish";

    private static readonly HashSet<string> Allowed = new(StringComparer.OrdinalIgnoreCase)
    {
        Click,
        Wait,
        PrepareAccount,
        Login,
        EnterScene,
        ClosePopup,
        ClaimReward,
        PlayFishing,
        Finish,
    };

    public static IReadOnlyCollection<string> All => Allowed;

    public static bool IsAllowed(string? action)
    {
        return !string.IsNullOrWhiteSpace(action) && Allowed.Contains(action);
    }
}
