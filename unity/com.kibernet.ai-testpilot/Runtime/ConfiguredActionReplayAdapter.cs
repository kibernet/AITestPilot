using System;
using System.Collections.Generic;
using UnityEngine;

namespace Kibernet.AITestPilot.Unity
{
    [CreateAssetMenu(menuName = "Kibernet/AI TestPilot/Action Replay Profile")]
    public sealed class ActionReplayProfile : ScriptableObject
    {
        public string adapterId = "configured.action_replay";
        public List<ActionReplayRule> rules = new List<ActionReplayRule>();

        public bool TryFindRule(AIAction action, out ActionReplayRule rule)
        {
            rule = null;
            if (action == null)
            {
                return false;
            }

            foreach (var candidate in rules)
            {
                if (candidate == null)
                {
                    continue;
                }

                if (!string.Equals(candidate.action, action.action, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                if (!string.IsNullOrWhiteSpace(candidate.target) &&
                    !string.Equals(candidate.target, action.target, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                rule = candidate;
                return true;
            }

            return false;
        }
    }

    [Serializable]
    public sealed class ActionReplayRule
    {
        public string action;
        public string target;
        public string handlerKey;
        public string successMessage;
        public bool allowDefaultFallback;
    }

    public delegate ActionReplayResult ActionReplayRuleHandler(
        string adapterId,
        ActionReplayRule rule,
        AIAction action,
        ActionReplayContext context);

    public static class ActionReplayHandlerRegistry
    {
        private static readonly Dictionary<string, ActionReplayRuleHandler> Handlers =
            new Dictionary<string, ActionReplayRuleHandler>(StringComparer.OrdinalIgnoreCase);

        public static void Register(string handlerKey, ActionReplayRuleHandler handler)
        {
            if (string.IsNullOrWhiteSpace(handlerKey))
            {
                throw new ArgumentException("Handler key is required.", "handlerKey");
            }

            if (handler == null)
            {
                throw new ArgumentNullException("handler");
            }

            Handlers[handlerKey] = handler;
        }

        public static void Clear()
        {
            Handlers.Clear();
        }

        public static bool TryReplay(
            string adapterId,
            ActionReplayRule rule,
            AIAction action,
            ActionReplayContext context,
            out ActionReplayResult result)
        {
            result = null;
            if (rule == null || string.IsNullOrWhiteSpace(rule.handlerKey))
            {
                return false;
            }

            ActionReplayRuleHandler handler;
            if (!Handlers.TryGetValue(rule.handlerKey, out handler))
            {
                return false;
            }

            result = handler(adapterId, rule, action, context);
            return true;
        }
    }

    public sealed class ConfiguredActionReplayAdapter : IActionReplayAdapter
    {
        private readonly ActionReplayProfile profile;

        public ConfiguredActionReplayAdapter(ActionReplayProfile profile)
        {
            if (profile == null)
            {
                throw new ArgumentNullException("profile");
            }

            this.profile = profile;
        }

        public string AdapterId
        {
            get
            {
                return string.IsNullOrWhiteSpace(profile.adapterId)
                    ? "configured.action_replay"
                    : profile.adapterId;
            }
        }

        public bool CanReplay(AIAction action, ActionReplayContext context)
        {
            ActionReplayRule rule;
            return profile.TryFindRule(action, out rule);
        }

        public ActionReplayResult Replay(AIAction action, ActionReplayContext context)
        {
            ActionReplayRule rule;
            if (!profile.TryFindRule(action, out rule))
            {
                return ActionReplayResult.Fail(AdapterId, action, "Configured replay profile has no matching rule.");
            }

            ActionReplayResult handlerResult;
            if (ActionReplayHandlerRegistry.TryReplay(AdapterId, rule, action, context, out handlerResult))
            {
                return handlerResult;
            }

            if (rule.allowDefaultFallback)
            {
                var executed = ActionExecutor.Execute(action);
                return executed
                    ? ActionReplayResult.Pass(AdapterId, action, "Configured replay profile fell back to ActionExecutor.")
                    : ActionReplayResult.Fail(AdapterId, action, "Configured replay profile fallback failed.");
            }

            return ActionReplayResult.Fail(
                AdapterId,
                action,
                "Configured replay rule has no registered handler: " + rule.handlerKey);
        }
    }
}
