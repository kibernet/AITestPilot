using System;
using System.Collections.Generic;
using System.IO;
using Kibernet.AITestPilot.Unity;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;

namespace Kibernet.AITestPilot.Unity.Editor
{
    public static class RepairTaskRetestRunner
    {
        private const string GeneratedRetestSceneAssetPath = "Assets/AITestPilotGenerated/RepairTaskRetest.unity";

        public static void RunRepairTaskRetest()
        {
            try
            {
                var taskPath = ResolvePathArgument("-aiTestPilotRepairTaskJsonPath", string.Empty);
                if (string.IsNullOrWhiteSpace(taskPath) || !File.Exists(taskPath))
                {
                    throw new FileNotFoundException("Repair task JSON was not found.", taskPath);
                }

                var task = JsonUtility.FromJson<RepairTaskDocument>(File.ReadAllText(taskPath));
                var evidence = RunRetest(task, taskPath);
                WriteEvidence(evidence);

                Debug.Log("PASS AI TestPilot repair task retest");
                EditorApplication.Exit(0);
            }
            catch (Exception ex)
            {
                Debug.LogError("FAIL AI TestPilot repair task retest\n" + ex);
                EditorApplication.Exit(1);
            }
        }

        private static RepairTaskRetestEvidence RunRetest(RepairTaskDocument task, string taskPath)
        {
            Require(task != null, "Repair task JSON could not be parsed.");
            Require(!string.IsNullOrWhiteSpace(task.taskId), "Repair task is missing taskId.");
            Require(!string.IsNullOrWhiteSpace(task.bugId), "Repair task is missing bugId.");
            Require(task.reproductionSteps != null && task.reproductionSteps.Count > 0, "Repair task has no reproduction steps.");

            var startedAtUtc = DateTime.UtcNow;
            LogCollector.Clear();
            LogCollector.Init();

            var clickCount = 0;
            GameStateProvider.CustomProvider = () => new[]
            {
                new GameStateEntry { key = "coin", value = "100" },
                new GameStateEntry { key = "diamond", value = "10" }
            };
            var gameReplayDriverResolution = ResolveGameReplayDriver();
            var gameReplayDriver = gameReplayDriverResolution.Driver;
            var gameReplayDriverDescriptor = GameActionReplayDriverDescriptorFactory.Build(
                gameReplayDriver,
                gameReplayDriverResolution.Source);
            var businessReplayProfileAssetPath = ResolveStringArgument(
                "-aiTestPilotReplayProfileAssetPath",
                ActionReplayProfileAssetUtility.SampleProfileAssetPath);
            var businessReplayProfileJsonPath = ResolvePathArgument(
                "-aiTestPilotReplayProfileJsonPath",
                Path.Combine("Temp", "AITestPilot", "sample-business-replay-profile.json"));
            var businessReplayProfile = ActionReplayProfileAssetUtility.CreateOrUpdateSampleBusinessReplayProfile(
                businessReplayProfileAssetPath);
            ActionReplayProfileAssetUtility.ExportToJson(businessReplayProfile, businessReplayProfileJsonPath);
            ActionReplayRegistry.ClearCustomAdapters();
            ActionReplayHandlerRegistry.Clear();
            GameActionReplayDriverBindings.RegisterStandardHandlers(gameReplayDriver);
            ActionReplayRegistry.Register(new SampleBasicAutomationReplayAdapter());
            ActionReplayRegistry.Register(new ConfiguredActionReplayAdapter(businessReplayProfile));
            var registeredReplayAdapters = BuildRegisteredAdapterList();

            var handle = AITestPilotSampleSceneBuilder.CreateScene(() => clickCount++);
            SaveGeneratedRetestScene();
            var beforeSnapshot = SnapshotProvider.Capture(0);
            Require(!string.IsNullOrWhiteSpace(beforeSnapshot.scene), "Repair retest scene name should not be empty.");
            var replayedActions = new List<RepairTaskReplayedAction>();

            for (var i = 0; i < task.reproductionSteps.Count; i++)
            {
                var stepSnapshot = SnapshotProvider.Capture(i);
                var action = ActionStepParser.Parse(task.reproductionSteps[i]);
                var replayResult = ActionReplayRegistry.Replay(
                    action,
                    new ActionReplayContext
                    {
                        taskId = task.taskId,
                        bugId = task.bugId,
                        retestGoal = task.retestGoal,
                        stepIndex = i,
                        rawStep = task.reproductionSteps[i],
                        snapshotBefore = stepSnapshot
                    });

                replayedActions.Add(new RepairTaskReplayedAction
                {
                    index = i,
                    step = task.reproductionSteps[i],
                    action = replayResult.action,
                    target = replayResult.target,
                    adapterId = replayResult.adapterId,
                    executed = replayResult.executed,
                    message = replayResult.message
                });

                Require(
                    replayResult.executed,
                    "Failed to replay repair task step: " + task.reproductionSteps[i] +
                    ". " + replayResult.message);
            }

            var afterSnapshot = SnapshotProvider.Capture(task.reproductionSteps.Count);
            var bugStillPresent = ContainsBug(afterSnapshot, task);
            Require(!bugStillPresent, "Original bug is still present after repair task retest.");

            var retestId = string.IsNullOrWhiteSpace(task.expectedRetestId)
                ? "RETEST-" + task.taskId
                : task.expectedRetestId;

            return new RepairTaskRetestEvidence
            {
                status = "PASS",
                retestId = retestId,
                taskId = task.taskId,
                bugId = task.bugId,
                bugType = task.bugType,
                sourceRunId = task.sourceRunId,
                retestGoal = task.retestGoal,
                repairTaskPath = taskPath,
                generatedScenePath = GeneratedRetestSceneAssetPath,
                startedAtUtc = startedAtUtc.ToString("O"),
                finishedAtUtc = DateTime.UtcNow.ToString("O"),
                scene = afterSnapshot.scene,
                replayedStepCount = replayedActions.Count,
                clickCount = clickCount,
                bugStillPresent = false,
                beforeUiElementCount = beforeSnapshot.ui == null ? 0 : beforeSnapshot.ui.Count,
                afterUiElementCount = afterSnapshot.ui == null ? 0 : afterSnapshot.ui.Count,
                afterLogCount = afterSnapshot.logs == null ? 0 : afterSnapshot.logs.Count,
                businessReplayState = CaptureGameReplayState(gameReplayDriver),
                gameReplayDriverId = gameReplayDriver.DriverId,
                gameReplayDriverSource = gameReplayDriverResolution.Source,
                gameReplayDriverDescriptor = gameReplayDriverDescriptor,
                replayProfileId = businessReplayProfile.adapterId,
                replayProfileAssetPath = businessReplayProfileAssetPath,
                replayProfileJsonPath = businessReplayProfileJsonPath,
                replayProfileRuleCount = businessReplayProfile.rules.Count,
                replayHandlerKeys = BuildHandlerKeyList(businessReplayProfile),
                registeredReplayAdapters = registeredReplayAdapters,
                usedReplayAdapters = BuildUsedAdapterList(replayedActions),
                replayedActions = replayedActions,
                runReport = new ValidationRunReport
                {
                    runId = "RUN-" + retestId,
                    goal = task.retestGoal,
                    startedAtUtc = startedAtUtc.ToString("O"),
                    finishedAtUtc = DateTime.UtcNow.ToString("O"),
                    outcome = "PASSED",
                    exitReason = "finish",
                    stepCount = replayedActions.Count,
                    actionCount = replayedActions.Count,
                    bugCount = 0,
                    errorLogCount = 0,
                    steps = BuildStepReports(afterSnapshot.scene, replayedActions),
                    bugs = new List<ValidationBugReport>()
                },
                retestReport = new ValidationRetestReport
                {
                    retestId = retestId,
                    bugId = task.bugId,
                    bugType = task.bugType,
                    beforeRunId = task.sourceRunId,
                    afterRunId = "RUN-" + retestId,
                    passed = true,
                    result = "passed",
                    verifiedAtUtc = DateTime.UtcNow.ToString("O")
                },
                runnerPresent = handle.Runner != null
            };
        }

        private static void SaveGeneratedRetestScene()
        {
            var sceneDir = Path.Combine(Application.dataPath, "AITestPilotGenerated");
            Directory.CreateDirectory(sceneDir);
            var saved = EditorSceneManager.SaveScene(SceneManager.GetActiveScene(), GeneratedRetestSceneAssetPath);
            Require(saved, "Failed to save generated repair retest scene.");
        }

        private static GameReplayDriverResolution ResolveGameReplayDriver()
        {
            var typeName = ResolveStringArgument("-aiTestPilotGameReplayDriverType", string.Empty);
            if (!string.IsNullOrWhiteSpace(typeName))
            {
                var type = ResolveType(typeName);
                if (type == null)
                {
                    throw new InvalidOperationException("Game replay driver type was not found: " + typeName);
                }

                if (!typeof(IGameActionReplayDriver).IsAssignableFrom(type))
                {
                    throw new InvalidOperationException(
                        "Game replay driver type does not implement IGameActionReplayDriver: " + typeName);
                }

                var driver = Activator.CreateInstance(type) as IGameActionReplayDriver;
                if (driver == null)
                {
                    throw new InvalidOperationException("Game replay driver type could not be created: " + typeName);
                }

                return new GameReplayDriverResolution
                {
                    Driver = driver,
                    Source = "type:" + type.FullName
                };
            }

            IGameActionReplayDriver registeredDriver;
            if (GameActionReplayDriverRegistry.TryGet(out registeredDriver))
            {
                return new GameReplayDriverResolution
                {
                    Driver = registeredDriver,
                    Source = "registry"
                };
            }

            return new GameReplayDriverResolution
            {
                Driver = new SampleGameActionReplayDriver(),
                Source = "sample_fallback"
            };
        }

        private static Type ResolveType(string typeName)
        {
            var type = Type.GetType(typeName, false);
            if (type != null)
            {
                return type;
            }

            foreach (var assembly in AppDomain.CurrentDomain.GetAssemblies())
            {
                type = assembly.GetType(typeName, false);
                if (type != null)
                {
                    return type;
                }
            }

            return null;
        }

        private static GameActionReplayState CaptureGameReplayState(IGameActionReplayDriver driver)
        {
            var stateProvider = driver as IGameActionReplayStateProvider;
            if (stateProvider != null)
            {
                var state = stateProvider.GetReplayState();
                if (state != null)
                {
                    return state;
                }
            }

            return new GameActionReplayState();
        }

        private static List<string> BuildRegisteredAdapterList()
        {
            var adapters = new List<string>();
            var snapshot = ActionReplayRegistry.CustomAdapterSnapshot();
            foreach (var adapter in snapshot)
            {
                if (adapter != null)
                {
                    adapters.Add(adapter.AdapterId);
                }
            }

            adapters.Add("default.action_executor");
            return adapters;
        }

        private static List<string> BuildHandlerKeyList(ActionReplayProfile profile)
        {
            var keys = new List<string>();
            foreach (var rule in profile.rules)
            {
                if (rule != null &&
                    !string.IsNullOrWhiteSpace(rule.handlerKey) &&
                    !keys.Contains(rule.handlerKey))
                {
                    keys.Add(rule.handlerKey);
                }
            }

            return keys;
        }

        private static List<string> BuildUsedAdapterList(List<RepairTaskReplayedAction> actions)
        {
            var used = new List<string>();
            foreach (var action in actions)
            {
                if (action != null &&
                    !string.IsNullOrWhiteSpace(action.adapterId) &&
                    !used.Contains(action.adapterId))
                {
                    used.Add(action.adapterId);
                }
            }

            return used;
        }

        private static List<ValidationStepReport> BuildStepReports(string scene, List<RepairTaskReplayedAction> actions)
        {
            var steps = new List<ValidationStepReport>();
            foreach (var action in actions)
            {
                steps.Add(new ValidationStepReport
                {
                    index = action.index,
                    scene = scene,
                    action = action.action,
                    target = action.target,
                    uiElementCount = 1,
                    logCount = 0,
                    bugId = string.Empty
                });
            }

            return steps;
        }

        private static bool ContainsBug(AITestSnapshot snapshot, RepairTaskDocument task)
        {
            if (snapshot == null || snapshot.logs == null)
            {
                return false;
            }

            foreach (var log in snapshot.logs)
            {
                if (log == null || string.IsNullOrWhiteSpace(log.message))
                {
                    continue;
                }

                if (!string.IsNullOrWhiteSpace(task.bugType) &&
                    log.message.IndexOf(task.bugType, StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    return true;
                }

                if (log.message.IndexOf("Exception", StringComparison.OrdinalIgnoreCase) >= 0 ||
                    log.message.IndexOf("Error", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    return true;
                }
            }

            return false;
        }

        private static void WriteEvidence(RepairTaskRetestEvidence evidence)
        {
            var path = ResolvePathArgument(
                "-aiTestPilotRepairRetestEvidencePath",
                Path.Combine("Temp", "AITestPilot", "repair-task-retest.json"));
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            File.WriteAllText(path, JsonUtility.ToJson(evidence, true));
            Debug.Log("AI TestPilot repair task retest evidence: " + path);
        }

        private static string ResolvePathArgument(string argumentName, string defaultRelativePath)
        {
            var value = ResolveStringArgument(argumentName, string.Empty);
            if (!string.IsNullOrWhiteSpace(value))
            {
                return value;
            }

            if (string.IsNullOrWhiteSpace(defaultRelativePath))
            {
                return string.Empty;
            }

            var projectRoot = Path.GetFullPath(Path.Combine(Application.dataPath, ".."));
            return Path.Combine(projectRoot, defaultRelativePath);
        }

        private static string ResolveStringArgument(string argumentName, string defaultValue)
        {
            var args = Environment.GetCommandLineArgs();
            for (var i = 0; i < args.Length - 1; i++)
            {
                if (string.Equals(args[i], argumentName, StringComparison.OrdinalIgnoreCase))
                {
                    return args[i + 1];
                }
            }

            return defaultValue;
        }

        private static void Require(bool condition, string message)
        {
            if (!condition)
            {
                throw new InvalidOperationException(message);
            }
        }
    }

    [Serializable]
    public sealed class RepairTaskRetestEvidence
    {
        public string status;
        public string retestId;
        public string taskId;
        public string bugId;
        public string bugType;
        public string sourceRunId;
        public string retestGoal;
        public string repairTaskPath;
        public string generatedScenePath;
        public string startedAtUtc;
        public string finishedAtUtc;
        public string scene;
        public int replayedStepCount;
        public int clickCount;
        public bool bugStillPresent;
        public int beforeUiElementCount;
        public int afterUiElementCount;
        public int afterLogCount;
        public GameActionReplayState businessReplayState;
        public string gameReplayDriverId;
        public string gameReplayDriverSource;
        public GameActionReplayDriverDescriptor gameReplayDriverDescriptor;
        public string replayProfileId;
        public string replayProfileAssetPath;
        public string replayProfileJsonPath;
        public int replayProfileRuleCount;
        public List<string> replayHandlerKeys;
        public List<string> registeredReplayAdapters;
        public List<string> usedReplayAdapters;
        public List<RepairTaskReplayedAction> replayedActions;
        public ValidationRunReport runReport;
        public ValidationRetestReport retestReport;
        public bool runnerPresent;
    }

    [Serializable]
    public sealed class RepairTaskReplayedAction
    {
        public int index;
        public string step;
        public string action;
        public string target;
        public string adapterId;
        public bool executed;
        public string message;
    }

    internal sealed class GameReplayDriverResolution
    {
        public IGameActionReplayDriver Driver;
        public string Source;
    }

    internal sealed class SampleBasicAutomationReplayAdapter : IActionReplayAdapter
    {
        public string AdapterId
        {
            get { return "sample.basic_automation"; }
        }

        public bool CanReplay(AIAction action, ActionReplayContext context)
        {
            return action != null &&
                   string.Equals(action.action, ActionWhitelist.Click, StringComparison.OrdinalIgnoreCase) &&
                   string.Equals(action.target, AITestPilotSampleSceneBuilder.ButtonAutomationId, StringComparison.Ordinal);
        }

        public ActionReplayResult Replay(AIAction action, ActionReplayContext context)
        {
            var executed = ActionExecutor.Execute(action);
            return executed
                ? ActionReplayResult.Pass(AdapterId, action, "Sample basic automation adapter replayed the click.")
                : ActionReplayResult.Fail(AdapterId, action, "Sample basic automation adapter could not replay the click.");
        }
    }

    public sealed class SampleGameActionReplayDriver : HookedGameActionReplayDriver
    {
        public SampleGameActionReplayDriver()
            : this(new GameActionReplayState())
        {
        }

        public SampleGameActionReplayDriver(GameActionReplayState state)
            : base("sample.game_project_driver", new SampleGameActionReplayHooks(), state, BuildDescriptor())
        {
        }

        private static GameActionReplayDriverDescriptor BuildDescriptor()
        {
            return new GameActionReplayDriverDescriptor
            {
                driverId = "sample.game_project_driver",
                displayName = "Sample Game Project Replay Driver",
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
                        key = "qa_smoke_account",
                        source = "repair_task_target",
                        required = true,
                        description = "Repair task target used by prepare_account and login steps."
                    }
                },
                notes = new List<string>
                {
                    "Sample driver exercises the production hook adapter path."
                }
            };
        }
    }

    internal sealed class SampleGameActionReplayHooks : GameActionReplayHooksBase
    {
        private string preparedAccount;
        private bool loggedIn;
        private string currentScene;

        public override GameActionReplayHookResult PrepareAccount(GameActionReplayHookContext context)
        {
            preparedAccount = context.target;
            return GameActionReplayHookResult.Pass("Sample hooks prepared account.");
        }

        public override GameActionReplayHookResult Login(GameActionReplayHookContext context)
        {
            if (string.IsNullOrWhiteSpace(preparedAccount))
            {
                return GameActionReplayHookResult.Fail("Cannot login before account preparation.");
            }

            if (!string.Equals(preparedAccount, context.target, StringComparison.OrdinalIgnoreCase))
            {
                return GameActionReplayHookResult.Fail("Login account does not match the prepared account.");
            }

            loggedIn = true;
            return GameActionReplayHookResult.Pass("Sample hooks logged in.");
        }

        public override GameActionReplayHookResult EnterScene(GameActionReplayHookContext context)
        {
            if (!loggedIn)
            {
                return GameActionReplayHookResult.Fail("Cannot enter a business scene before login.");
            }

            currentScene = context.target;
            return GameActionReplayHookResult.Pass("Sample hooks entered scene.");
        }

        public override GameActionReplayHookResult ClaimReward(GameActionReplayHookContext context)
        {
            if (!string.Equals(currentScene, "Activity", StringComparison.OrdinalIgnoreCase))
            {
                return GameActionReplayHookResult.Fail("Cannot claim reward before entering Activity.");
            }

            return GameActionReplayHookResult.Pass("Sample hooks claimed reward.");
        }

        public override GameActionReplayHookResult PlayFishing(GameActionReplayHookContext context)
        {
            if (!loggedIn)
            {
                return GameActionReplayHookResult.Fail("Cannot play fishing before login.");
            }

            return GameActionReplayHookResult.Pass("Sample hooks replayed fishing.");
        }
    }
}
