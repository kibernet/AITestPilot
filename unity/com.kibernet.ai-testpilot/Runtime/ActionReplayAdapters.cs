using System;
using System.Collections.Generic;

namespace Kibernet.AITestPilot.Unity
{
    public interface IActionReplayAdapter
    {
        string AdapterId { get; }

        bool CanReplay(AIAction action, ActionReplayContext context);

        ActionReplayResult Replay(AIAction action, ActionReplayContext context);
    }

    [Serializable]
    public sealed class ActionReplayContext
    {
        public string taskId;
        public string bugId;
        public string retestGoal;
        public int stepIndex;
        public string rawStep;
        public AITestSnapshot snapshotBefore;
    }

    [Serializable]
    public sealed class ActionReplayResult
    {
        public string adapterId;
        public string action;
        public string target;
        public bool executed;
        public string message;

        public static ActionReplayResult Pass(string adapterId, AIAction action, string message)
        {
            return new ActionReplayResult
            {
                adapterId = adapterId,
                action = action == null ? string.Empty : action.action,
                target = action == null ? string.Empty : action.target,
                executed = true,
                message = message
            };
        }

        public static ActionReplayResult Fail(string adapterId, AIAction action, string message)
        {
            return new ActionReplayResult
            {
                adapterId = adapterId,
                action = action == null ? string.Empty : action.action,
                target = action == null ? string.Empty : action.target,
                executed = false,
                message = message
            };
        }
    }

    public static class ActionReplayRegistry
    {
        private static readonly List<IActionReplayAdapter> CustomAdapters = new List<IActionReplayAdapter>();
        private static readonly IActionReplayAdapter DefaultAdapter = new DefaultActionReplayAdapter();

        public static void Register(IActionReplayAdapter adapter)
        {
            if (adapter == null)
            {
                throw new ArgumentNullException("adapter");
            }

            for (var i = CustomAdapters.Count - 1; i >= 0; i--)
            {
                if (string.Equals(CustomAdapters[i].AdapterId, adapter.AdapterId, StringComparison.OrdinalIgnoreCase))
                {
                    CustomAdapters.RemoveAt(i);
                }
            }

            CustomAdapters.Insert(0, adapter);
        }

        public static void ClearCustomAdapters()
        {
            CustomAdapters.Clear();
        }

        public static IReadOnlyList<IActionReplayAdapter> CustomAdapterSnapshot()
        {
            return CustomAdapters.ToArray();
        }

        public static ActionReplayResult Replay(AIAction action, ActionReplayContext context)
        {
            if (action == null)
            {
                return ActionReplayResult.Fail("none", action, "Action is missing.");
            }

            if (!ActionWhitelist.IsAllowed(action.action))
            {
                return ActionReplayResult.Fail("none", action, "Action is not whitelisted.");
            }

            foreach (var adapter in CustomAdapters)
            {
                if (adapter != null && adapter.CanReplay(action, context))
                {
                    return adapter.Replay(action, context);
                }
            }

            return DefaultAdapter.Replay(action, context);
        }
    }

    internal sealed class DefaultActionReplayAdapter : IActionReplayAdapter
    {
        public string AdapterId
        {
            get { return "default.action_executor"; }
        }

        public bool CanReplay(AIAction action, ActionReplayContext context)
        {
            return action != null && ActionWhitelist.IsAllowed(action.action);
        }

        public ActionReplayResult Replay(AIAction action, ActionReplayContext context)
        {
            if (string.Equals(action.action, ActionWhitelist.Wait, StringComparison.OrdinalIgnoreCase))
            {
                return ActionReplayResult.Pass(AdapterId, action, "Wait step accepted by replay adapter.");
            }

            var executed = ActionExecutor.Execute(action);
            return executed
                ? ActionReplayResult.Pass(AdapterId, action, "ActionExecutor executed the replay step.")
                : ActionReplayResult.Fail(AdapterId, action, "ActionExecutor could not execute the replay step.");
        }
    }
}
