using System;
using System.Collections.Generic;

namespace Kibernet.AITestPilot.Unity
{
    public static class GameActionReplayHandlerKeys
    {
        public const string PrepareAccount = "game.prepare_account";
        public const string Login = "game.login";
        public const string EnterScene = "game.enter_scene";
        public const string ClaimReward = "game.claim_reward";
        public const string PlayFishing = "game.play_fishing";
    }

    public interface IGameActionReplayDriver
    {
        string DriverId { get; }

        ActionReplayResult PrepareAccount(
            string adapterId,
            ActionReplayRule rule,
            AIAction action,
            ActionReplayContext context);

        ActionReplayResult Login(
            string adapterId,
            ActionReplayRule rule,
            AIAction action,
            ActionReplayContext context);

        ActionReplayResult EnterScene(
            string adapterId,
            ActionReplayRule rule,
            AIAction action,
            ActionReplayContext context);

        ActionReplayResult ClaimReward(
            string adapterId,
            ActionReplayRule rule,
            AIAction action,
            ActionReplayContext context);

        ActionReplayResult PlayFishing(
            string adapterId,
            ActionReplayRule rule,
            AIAction action,
            ActionReplayContext context);
    }

    public interface IGameActionReplayStateProvider
    {
        GameActionReplayState GetReplayState();
    }

    public interface IGameActionReplayDriverDescriptorProvider
    {
        GameActionReplayDriverDescriptor GetReplayDriverDescriptor();
    }

    [Serializable]
    public sealed class GameActionReplayState
    {
        public string preparedAccount;
        public string loggedInAccount;
        public string currentScene;
        public int accountPreparationCount;
        public int loginCount;
        public int sceneEntryCount;
        public int rewardClaimCount;
        public int fishingCastCount;
    }

    [Serializable]
    public sealed class GameActionReplayDriverDescriptor
    {
        public string driverId;
        public string displayName;
        public string source;
        public List<string> supportedHandlerKeys = new List<string>();
        public List<GameActionReplayConfigurationRequirement> configurationRequirements =
            new List<GameActionReplayConfigurationRequirement>();
        public List<string> notes = new List<string>();
    }

    [Serializable]
    public sealed class GameActionReplayConfigurationRequirement
    {
        public string key;
        public string source;
        public bool required;
        public string description;
    }

    public static class GameActionReplayDriverDescriptorFactory
    {
        public static GameActionReplayDriverDescriptor Build(IGameActionReplayDriver driver, string source)
        {
            if (driver == null)
            {
                throw new ArgumentNullException("driver");
            }

            var provider = driver as IGameActionReplayDriverDescriptorProvider;
            var descriptor = provider == null
                ? null
                : provider.GetReplayDriverDescriptor();

            if (descriptor == null)
            {
                descriptor = BuildDefault(driver.DriverId);
            }

            descriptor.driverId = string.IsNullOrWhiteSpace(descriptor.driverId)
                ? driver.DriverId
                : descriptor.driverId;
            descriptor.source = source;
            EnsureStandardHandlerKeys(descriptor);
            if (descriptor.configurationRequirements == null)
            {
                descriptor.configurationRequirements = new List<GameActionReplayConfigurationRequirement>();
            }

            if (descriptor.notes == null)
            {
                descriptor.notes = new List<string>();
            }

            return descriptor;
        }

        public static GameActionReplayDriverDescriptor BuildDefault(string driverId)
        {
            var descriptor = new GameActionReplayDriverDescriptor
            {
                driverId = driverId,
                displayName = driverId,
                supportedHandlerKeys = StandardHandlerKeys(),
                configurationRequirements = new List<GameActionReplayConfigurationRequirement>(),
                notes = new List<string>()
            };
            return descriptor;
        }

        public static List<string> StandardHandlerKeys()
        {
            return new List<string>
            {
                GameActionReplayHandlerKeys.PrepareAccount,
                GameActionReplayHandlerKeys.Login,
                GameActionReplayHandlerKeys.EnterScene,
                GameActionReplayHandlerKeys.ClaimReward,
                GameActionReplayHandlerKeys.PlayFishing
            };
        }

        private static void EnsureStandardHandlerKeys(GameActionReplayDriverDescriptor descriptor)
        {
            if (descriptor.supportedHandlerKeys == null)
            {
                descriptor.supportedHandlerKeys = new List<string>();
            }

            foreach (var handlerKey in StandardHandlerKeys())
            {
                if (!descriptor.supportedHandlerKeys.Contains(handlerKey))
                {
                    descriptor.supportedHandlerKeys.Add(handlerKey);
                }
            }
        }
    }

    public abstract class GameActionReplayDriverBase : IGameActionReplayDriver
    {
        public abstract string DriverId { get; }

        public virtual ActionReplayResult PrepareAccount(
            string adapterId,
            ActionReplayRule rule,
            AIAction action,
            ActionReplayContext context)
        {
            return Unsupported(adapterId, action, ActionWhitelist.PrepareAccount);
        }

        public virtual ActionReplayResult Login(
            string adapterId,
            ActionReplayRule rule,
            AIAction action,
            ActionReplayContext context)
        {
            return Unsupported(adapterId, action, ActionWhitelist.Login);
        }

        public virtual ActionReplayResult EnterScene(
            string adapterId,
            ActionReplayRule rule,
            AIAction action,
            ActionReplayContext context)
        {
            return Unsupported(adapterId, action, ActionWhitelist.EnterScene);
        }

        public virtual ActionReplayResult ClaimReward(
            string adapterId,
            ActionReplayRule rule,
            AIAction action,
            ActionReplayContext context)
        {
            return Unsupported(adapterId, action, ActionWhitelist.ClaimReward);
        }

        public virtual ActionReplayResult PlayFishing(
            string adapterId,
            ActionReplayRule rule,
            AIAction action,
            ActionReplayContext context)
        {
            return Unsupported(adapterId, action, ActionWhitelist.PlayFishing);
        }

        protected static ActionReplayResult Pass(string adapterId, AIAction action, string message)
        {
            return ActionReplayResult.Pass(adapterId, action, message);
        }

        protected static ActionReplayResult Fail(string adapterId, AIAction action, string message)
        {
            return ActionReplayResult.Fail(adapterId, action, message);
        }

        private ActionReplayResult Unsupported(string adapterId, AIAction action, string verb)
        {
            return ActionReplayResult.Fail(
                adapterId,
                action,
                "Game replay driver '" + DriverId + "' does not implement action: " + verb);
        }
    }

    public static class GameActionReplayDriverRegistry
    {
        private static IGameActionReplayDriver activeDriver;

        public static void Register(IGameActionReplayDriver driver)
        {
            if (driver == null)
            {
                throw new ArgumentNullException("driver");
            }

            activeDriver = driver;
        }

        public static bool TryGet(out IGameActionReplayDriver driver)
        {
            driver = activeDriver;
            return driver != null;
        }

        public static void Clear()
        {
            activeDriver = null;
        }
    }

    public static class GameActionReplayDriverBindings
    {
        public static void RegisterStandardHandlers(IGameActionReplayDriver driver)
        {
            if (driver == null)
            {
                throw new ArgumentNullException("driver");
            }

            ActionReplayHandlerRegistry.Register(
                GameActionReplayHandlerKeys.PrepareAccount,
                delegate(string adapterId, ActionReplayRule rule, AIAction action, ActionReplayContext context)
                {
                    return driver.PrepareAccount(adapterId, rule, action, context);
                });

            ActionReplayHandlerRegistry.Register(
                GameActionReplayHandlerKeys.Login,
                delegate(string adapterId, ActionReplayRule rule, AIAction action, ActionReplayContext context)
                {
                    return driver.Login(adapterId, rule, action, context);
                });

            ActionReplayHandlerRegistry.Register(
                GameActionReplayHandlerKeys.EnterScene,
                delegate(string adapterId, ActionReplayRule rule, AIAction action, ActionReplayContext context)
                {
                    return driver.EnterScene(adapterId, rule, action, context);
                });

            ActionReplayHandlerRegistry.Register(
                GameActionReplayHandlerKeys.ClaimReward,
                delegate(string adapterId, ActionReplayRule rule, AIAction action, ActionReplayContext context)
                {
                    return driver.ClaimReward(adapterId, rule, action, context);
                });

            ActionReplayHandlerRegistry.Register(
                GameActionReplayHandlerKeys.PlayFishing,
                delegate(string adapterId, ActionReplayRule rule, AIAction action, ActionReplayContext context)
                {
                    return driver.PlayFishing(adapterId, rule, action, context);
                });
        }
    }
}
