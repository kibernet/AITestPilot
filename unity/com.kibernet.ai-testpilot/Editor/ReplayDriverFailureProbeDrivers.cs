using Kibernet.AITestPilot.Unity;

namespace Kibernet.AITestPilot.Unity.Editor
{
    public sealed class FailingGameActionReplayDriver : HookedGameActionReplayDriver
    {
        public FailingGameActionReplayDriver()
            : base("failing.game_project_driver", new FailingGameActionReplayHooks())
        {
        }
    }

    internal sealed class FailingGameActionReplayHooks : GameActionReplayHooksBase
    {
        private string preparedAccount;
        private bool loggedIn;
        private string currentScene;

        public override GameActionReplayHookResult PrepareAccount(GameActionReplayHookContext context)
        {
            preparedAccount = context.target;
            return GameActionReplayHookResult.Pass("Failure probe prepared account.");
        }

        public override GameActionReplayHookResult Login(GameActionReplayHookContext context)
        {
            if (string.IsNullOrWhiteSpace(preparedAccount))
            {
                return GameActionReplayHookResult.Fail("Failure probe cannot login before account preparation.");
            }

            loggedIn = true;
            return GameActionReplayHookResult.Pass("Failure probe logged in.");
        }

        public override GameActionReplayHookResult EnterScene(GameActionReplayHookContext context)
        {
            if (!loggedIn)
            {
                return GameActionReplayHookResult.Fail("Failure probe cannot enter scene before login.");
            }

            currentScene = context.target;
            return GameActionReplayHookResult.Pass("Failure probe entered scene.");
        }

        public override GameActionReplayHookResult ClaimReward(GameActionReplayHookContext context)
        {
            return GameActionReplayHookResult.Fail(
                "Intentional failure probe for " + context.action + ":" + context.target +
                " after scene " + currentScene + ".");
        }

        public override GameActionReplayHookResult PlayFishing(GameActionReplayHookContext context)
        {
            return GameActionReplayHookResult.Pass("Failure probe should not reach fishing.");
        }
    }
}
