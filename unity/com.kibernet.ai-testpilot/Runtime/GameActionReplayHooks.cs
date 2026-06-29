using System;

namespace Kibernet.AITestPilot.Unity
{
    public interface IGameActionReplayHooks
    {
        GameActionReplayHookResult PrepareAccount(GameActionReplayHookContext context);

        GameActionReplayHookResult Login(GameActionReplayHookContext context);

        GameActionReplayHookResult EnterScene(GameActionReplayHookContext context);

        GameActionReplayHookResult ClaimReward(GameActionReplayHookContext context);

        GameActionReplayHookResult PlayFishing(GameActionReplayHookContext context);
    }

    [Serializable]
    public sealed class GameActionReplayHookContext
    {
        public string driverId;
        public string adapterId;
        public string handlerKey;
        public string action;
        public string target;
        public string taskId;
        public string bugId;
        public string retestGoal;
        public int stepIndex;
        public string rawStep;
        public AITestSnapshot snapshotBefore;
    }

    [Serializable]
    public sealed class GameActionReplayHookResult
    {
        public bool succeeded;
        public string message;

        public static GameActionReplayHookResult Pass(string message)
        {
            return new GameActionReplayHookResult
            {
                succeeded = true,
                message = message
            };
        }

        public static GameActionReplayHookResult Fail(string message)
        {
            return new GameActionReplayHookResult
            {
                succeeded = false,
                message = message
            };
        }
    }

    public abstract class GameActionReplayHooksBase : IGameActionReplayHooks
    {
        public virtual GameActionReplayHookResult PrepareAccount(GameActionReplayHookContext context)
        {
            return Unsupported(context);
        }

        public virtual GameActionReplayHookResult Login(GameActionReplayHookContext context)
        {
            return Unsupported(context);
        }

        public virtual GameActionReplayHookResult EnterScene(GameActionReplayHookContext context)
        {
            return Unsupported(context);
        }

        public virtual GameActionReplayHookResult ClaimReward(GameActionReplayHookContext context)
        {
            return Unsupported(context);
        }

        public virtual GameActionReplayHookResult PlayFishing(GameActionReplayHookContext context)
        {
            return Unsupported(context);
        }

        private static GameActionReplayHookResult Unsupported(GameActionReplayHookContext context)
        {
            return GameActionReplayHookResult.Fail(
                "No hook implementation for action '" + Safe(context == null ? string.Empty : context.action) +
                "' target '" + Safe(context == null ? string.Empty : context.target) + "'.");
        }

        private static string Safe(string value)
        {
            return string.IsNullOrWhiteSpace(value) ? "<empty>" : value;
        }
    }

    public class HookedGameActionReplayDriver :
        GameActionReplayDriverBase,
        IGameActionReplayStateProvider,
        IGameActionReplayDriverDescriptorProvider
    {
        private readonly string driverId;
        private readonly IGameActionReplayHooks hooks;
        private readonly GameActionReplayState state;
        private readonly GameActionReplayDriverDescriptor descriptor;

        public HookedGameActionReplayDriver(string driverId, IGameActionReplayHooks hooks)
            : this(driverId, hooks, new GameActionReplayState())
        {
        }

        public HookedGameActionReplayDriver(
            string driverId,
            IGameActionReplayHooks hooks,
            GameActionReplayState state)
            : this(driverId, hooks, state, null)
        {
        }

        public HookedGameActionReplayDriver(
            string driverId,
            IGameActionReplayHooks hooks,
            GameActionReplayState state,
            GameActionReplayDriverDescriptor descriptor)
        {
            if (string.IsNullOrWhiteSpace(driverId))
            {
                throw new ArgumentException("Driver id is required.", "driverId");
            }

            if (hooks == null)
            {
                throw new ArgumentNullException("hooks");
            }

            if (state == null)
            {
                throw new ArgumentNullException("state");
            }

            this.driverId = driverId;
            this.hooks = hooks;
            this.state = state;
            this.descriptor = descriptor;
        }

        public override string DriverId
        {
            get { return driverId; }
        }

        public GameActionReplayState GetReplayState()
        {
            return state;
        }

        public GameActionReplayDriverDescriptor GetReplayDriverDescriptor()
        {
            var result = descriptor ?? GameActionReplayDriverDescriptorFactory.BuildDefault(DriverId);
            result.driverId = DriverId;
            return result;
        }

        public override ActionReplayResult PrepareAccount(
            string adapterId,
            ActionReplayRule rule,
            AIAction action,
            ActionReplayContext context)
        {
            return RunHook(
                adapterId,
                rule,
                action,
                context,
                GameActionReplayHandlerKeys.PrepareAccount,
                hooks.PrepareAccount,
                delegate
                {
                    state.preparedAccount = action.target;
                    state.accountPreparationCount++;
                });
        }

        public override ActionReplayResult Login(
            string adapterId,
            ActionReplayRule rule,
            AIAction action,
            ActionReplayContext context)
        {
            return RunHook(
                adapterId,
                rule,
                action,
                context,
                GameActionReplayHandlerKeys.Login,
                hooks.Login,
                delegate
                {
                    state.loggedInAccount = action.target;
                    state.loginCount++;
                });
        }

        public override ActionReplayResult EnterScene(
            string adapterId,
            ActionReplayRule rule,
            AIAction action,
            ActionReplayContext context)
        {
            return RunHook(
                adapterId,
                rule,
                action,
                context,
                GameActionReplayHandlerKeys.EnterScene,
                hooks.EnterScene,
                delegate
                {
                    state.currentScene = action.target;
                    state.sceneEntryCount++;
                });
        }

        public override ActionReplayResult ClaimReward(
            string adapterId,
            ActionReplayRule rule,
            AIAction action,
            ActionReplayContext context)
        {
            return RunHook(
                adapterId,
                rule,
                action,
                context,
                GameActionReplayHandlerKeys.ClaimReward,
                hooks.ClaimReward,
                delegate
                {
                    state.rewardClaimCount++;
                });
        }

        public override ActionReplayResult PlayFishing(
            string adapterId,
            ActionReplayRule rule,
            AIAction action,
            ActionReplayContext context)
        {
            return RunHook(
                adapterId,
                rule,
                action,
                context,
                GameActionReplayHandlerKeys.PlayFishing,
                hooks.PlayFishing,
                delegate
                {
                    state.fishingCastCount++;
                });
        }

        private ActionReplayResult RunHook(
            string adapterId,
            ActionReplayRule rule,
            AIAction action,
            ActionReplayContext context,
            string handlerKey,
            Func<GameActionReplayHookContext, GameActionReplayHookResult> hook,
            Action onSuccess)
        {
            var hookContext = BuildHookContext(adapterId, rule, action, context, handlerKey);
            GameActionReplayHookResult hookResult;
            try
            {
                hookResult = hook(hookContext);
            }
            catch (Exception ex)
            {
                return ActionReplayResult.Fail(
                    adapterId,
                    action,
                    BuildDiagnostic(hookContext, "Hook threw " + ex.GetType().Name + ": " + ex.Message));
            }

            if (hookResult == null)
            {
                return ActionReplayResult.Fail(
                    adapterId,
                    action,
                    BuildDiagnostic(hookContext, "Hook returned no result."));
            }

            var message = string.IsNullOrWhiteSpace(hookResult.message)
                ? (rule == null ? string.Empty : rule.successMessage)
                : hookResult.message;

            if (!hookResult.succeeded)
            {
                return ActionReplayResult.Fail(adapterId, action, BuildDiagnostic(hookContext, message));
            }

            if (onSuccess != null)
            {
                onSuccess();
            }

            return ActionReplayResult.Pass(adapterId, action, BuildDiagnostic(hookContext, message));
        }

        private GameActionReplayHookContext BuildHookContext(
            string adapterId,
            ActionReplayRule rule,
            AIAction action,
            ActionReplayContext context,
            string handlerKey)
        {
            return new GameActionReplayHookContext
            {
                driverId = DriverId,
                adapterId = adapterId,
                handlerKey = handlerKey,
                action = action == null ? string.Empty : action.action,
                target = action == null ? string.Empty : action.target,
                taskId = context == null ? string.Empty : context.taskId,
                bugId = context == null ? string.Empty : context.bugId,
                retestGoal = context == null ? string.Empty : context.retestGoal,
                stepIndex = context == null ? -1 : context.stepIndex,
                rawStep = context == null ? string.Empty : context.rawStep,
                snapshotBefore = context == null ? null : context.snapshotBefore
            };
        }

        private string BuildDiagnostic(GameActionReplayHookContext context, string message)
        {
            return "driver=" + DriverId +
                   " handler=" + context.handlerKey +
                   " action=" + context.action +
                   " target=" + context.target +
                   " step=" + context.stepIndex +
                   " message=" + (string.IsNullOrWhiteSpace(message) ? "<empty>" : message);
        }
    }
}
