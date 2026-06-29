using System.Collections.Generic;
using Kibernet.AITestPilot.Unity;

namespace Your.Game.Tests
{
    public sealed class ProductionReplayDriver : HookedGameActionReplayDriver
    {
        public ProductionReplayDriver()
            : base(
                "your_game.production_replay",
                new ProductionReplayHooks(),
                new GameActionReplayState(),
                BuildDescriptor())
        {
        }

        private static GameActionReplayDriverDescriptor BuildDescriptor()
        {
            return new GameActionReplayDriverDescriptor
            {
                driverId = "your_game.production_replay",
                displayName = "Your Game Production Replay Driver",
                supportedHandlerKeys = GameActionReplayDriverDescriptorFactory.StandardHandlerKeys(),
                configurationRequirements = new List<GameActionReplayConfigurationRequirement>
                {
                    new GameActionReplayConfigurationRequirement
                    {
                        key = "AITESTPILOT_QA_ACCOUNT",
                        source = "environment",
                        required = true,
                        description = "QA account alias used by prepare_account and login."
                    },
                    new GameActionReplayConfigurationRequirement
                    {
                        key = "AITESTPILOT_SERVER",
                        source = "environment",
                        required = true,
                        description = "Server or shard used by login and scene navigation."
                    }
                },
                notes = new List<string>
                {
                    "Return Pass only after the game reaches the expected state for each hook."
                }
            };
        }
    }

    internal sealed class ProductionReplayHooks : GameActionReplayHooksBase
    {
        public override GameActionReplayHookResult PrepareAccount(GameActionReplayHookContext context)
        {
            // Create or reset the account identified by context.target.
            return GameActionReplayHookResult.Fail("Connect this hook to the game's account setup API.");
        }

        public override GameActionReplayHookResult Login(GameActionReplayHookContext context)
        {
            // Login with the account identified by context.target and wait until the lobby is ready.
            return GameActionReplayHookResult.Fail("Connect this hook to the game's login API.");
        }

        public override GameActionReplayHookResult EnterScene(GameActionReplayHookContext context)
        {
            // Navigate to the scene or feature identified by context.target.
            return GameActionReplayHookResult.Fail("Connect this hook to the game's scene navigation API.");
        }

        public override GameActionReplayHookResult ClaimReward(GameActionReplayHookContext context)
        {
            // Claim the activity or reward identified by context.target.
            return GameActionReplayHookResult.Fail("Connect this hook to the game's activity reward API.");
        }

        public override GameActionReplayHookResult PlayFishing(GameActionReplayHookContext context)
        {
            // Execute the fishing command identified by context.target.
            return GameActionReplayHookResult.Fail("Connect this hook to the game's fishing API.");
        }
    }
}
