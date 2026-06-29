using System;
using System.Collections.Generic;

namespace Kibernet.AITestPilot.Unity
{
    [Serializable]
    public sealed class AIAction
    {
        public string action = ActionWhitelist.Finish;
        public string target;
        public int waitMilliseconds;
        public List<ActionParameter> parameters = new List<ActionParameter>();

        public static AIAction Click(string targetId)
        {
            return new AIAction { action = ActionWhitelist.Click, target = targetId };
        }

        public static AIAction Finish()
        {
            return new AIAction { action = ActionWhitelist.Finish };
        }
    }

    [Serializable]
    public sealed class ActionParameter
    {
        public string key;
        public string value;
    }

    public static class ActionWhitelist
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

        private static readonly HashSet<string> Allowed = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            Click,
            Wait,
            PrepareAccount,
            Login,
            EnterScene,
            ClosePopup,
            ClaimReward,
            PlayFishing,
            Finish
        };

        public static bool IsAllowed(string action)
        {
            return !string.IsNullOrWhiteSpace(action) && Allowed.Contains(action);
        }
    }
}
