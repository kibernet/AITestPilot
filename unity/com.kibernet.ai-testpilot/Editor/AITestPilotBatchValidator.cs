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
    public static class AITestPilotBatchValidator
    {
        private const string SnapshotSchemaVersion = "aitestpilot.snapshot.v1";
        private const string GeneratedSceneAssetPath = "Assets/AITestPilotGenerated/BasicAutomation.unity";

        public static void RunSampleSceneValidation()
        {
            try
            {
                var evidence = ValidateSampleScene();
                WriteEvidence(evidence);
                Debug.Log("PASS AI TestPilot sample scene validation");
                EditorApplication.Exit(0);
            }
            catch (Exception ex)
            {
                Debug.LogError("FAIL AI TestPilot sample scene validation\n" + ex);
                EditorApplication.Exit(1);
            }
        }

        private static SampleSceneValidationEvidence ValidateSampleScene()
        {
            var startedAtUtc = DateTime.UtcNow;
            LogCollector.Clear();
            LogCollector.Init();

            var clickCount = 0;
            GameStateProvider.CustomProvider = () => new[]
            {
                new GameStateEntry { key = "coin", value = "100" },
                new GameStateEntry { key = "diamond", value = "10" }
            };

            var handle = AITestPilotSampleSceneBuilder.CreateScene(() => clickCount++);
            SaveGeneratedScene();
            var snapshot = SnapshotProvider.Capture(0);
            var knownFixHints = new List<string>
            {
                "add null guard before reward access"
            };
            var modelEndpointSettings = ModelEndpointSettingsAssetUtility.CreateOrUpdateSampleSettings(
                ModelEndpointSettingsAssetUtility.DefaultSettingsAssetPath);
            var modelEndpointEvidence = ModelEndpointSettingsAssetUtility.ValidateOfflineContract(
                modelEndpointSettings,
                snapshot,
                knownFixHints);
            var productionReplayIntegrationPlan = ProductionReplayIntegrationPlanAssetUtility.CreateOrUpdateTemplatePlan(
                ProductionReplayIntegrationPlanAssetUtility.DefaultPlanAssetPath);
            var productionReplayIntegration = ProductionReplayIntegrationPlanAssetUtility.ValidateTemplatePlan(
                productionReplayIntegrationPlan);
            var productionIntegrationJsonPath = ResolveProductionIntegrationJsonPath();
            var productionIntegrationMarkdownPath = ResolveProductionIntegrationMarkdownPath();
            ProductionReplayIntegrationPlanAssetUtility.WriteEvidence(
                productionReplayIntegration,
                productionIntegrationJsonPath,
                productionIntegrationMarkdownPath);

            Require(!string.IsNullOrWhiteSpace(snapshot.scene), "Snapshot scene name should not be empty.");
            Require(snapshot.ui != null && snapshot.ui.Count == 1, "Expected exactly one automation UI element.");
            Require(
                string.Equals(snapshot.ui[0].automationId, AITestPilotSampleSceneBuilder.ButtonAutomationId, StringComparison.Ordinal),
                "Snapshot did not include the expected AutomationId.");
            Require(snapshot.gameState != null && snapshot.gameState.Count == 2, "Expected custom game state entries.");
            Require(!BugDetector.HasBug(snapshot), "Fresh sample scene should not contain a bug.");
            Require(
                string.Equals(modelEndpointEvidence.status, "PASS", StringComparison.Ordinal),
                "Model endpoint settings contract evidence did not pass.");
            Require(
                !modelEndpointEvidence.liveRequestsEnabled,
                "Sample model endpoint settings must not enable live requests by default.");
            Require(
                string.Equals(modelEndpointEvidence.actionSchemaVersion, ModelEndpointDecisionClient.ActionSchemaVersion, StringComparison.Ordinal),
                "Model endpoint action schema version mismatch.");
            Require(
                modelEndpointEvidence.requestContainsSnapshot && modelEndpointEvidence.requestContainsActionSchema,
                "Model endpoint request evidence did not include snapshot and action schema.");
            Require(
                modelEndpointEvidence.requestContainsFixHints && modelEndpointEvidence.fixHintCount == 1,
                "Model endpoint request evidence did not include prior fix hints.");
            Require(
                string.Equals(productionReplayIntegration.status, "TEMPLATE_READY", StringComparison.Ordinal),
                "Production replay integration template evidence did not pass.");
            Require(
                !productionReplayIntegration.realProjectBound &&
                productionReplayIntegration.requiredHookCount == 5 &&
                productionReplayIntegration.unresolvedRequiredHookCount == 5 &&
                productionReplayIntegration.requiredHandlerKeysPresent,
                "Production replay integration evidence did not expose the expected unbound template state.");

            var action = RuleBasedDecisionClient.Decide("click the sample start button", snapshot);
            Require(action != null, "RuleBasedDecisionClient returned no action.");
            Require(string.Equals(action.action, ActionWhitelist.Click, StringComparison.OrdinalIgnoreCase), "Expected click action.");
            Require(string.Equals(action.target, AITestPilotSampleSceneBuilder.ButtonAutomationId, StringComparison.Ordinal), "Unexpected click target.");

            var executed = ActionExecutor.Execute(action);
            Require(executed, "ActionExecutor did not execute the sample click.");
            Require(clickCount == 1, "Sample button click handler was not invoked exactly once.");
            var manualClickCount = clickCount;
            clickCount = 0;

            var runnerResult = handle.Runner.RunImmediate();
            var runnerClickCount = clickCount;
            Require(runnerResult != null, "DecisionLoopRunner did not return a result.");
            Require(runnerResult.stepCount == 3, "DecisionLoopRunner did not execute the expected multi-step goal.");
            Require(runnerResult.actionCount == 3, "DecisionLoopRunner action count did not match the multi-step goal.");
            Require(
                string.Equals(runnerResult.exitReason, "max_steps", StringComparison.Ordinal),
                "DecisionLoopRunner did not stop at the configured max step boundary.");
            Require(runnerClickCount == 3, "DecisionLoopRunner did not invoke the sample button once per step.");
            foreach (var runnerStep in runnerResult.steps)
            {
                Require(
                    string.Equals(runnerStep, "click:" + AITestPilotSampleSceneBuilder.ButtonAutomationId, StringComparison.Ordinal),
                    "DecisionLoopRunner recorded an unexpected step: " + runnerStep);
            }

            var multiStepRunnerEvidence = new ValidationMultiStepRunnerEvidence
            {
                status = "PASS",
                goal = runnerResult.goal,
                maxSteps = runnerResult.maxSteps,
                stepCount = runnerResult.stepCount,
                actionCount = runnerResult.actionCount,
                clickCount = runnerClickCount,
                exitReason = runnerResult.exitReason,
                steps = new List<string>(runnerResult.steps)
            };

            var reproductionSteps = new List<string>
            {
                "prepare_account:qa_smoke_account",
                "login:qa_smoke_account",
                "enter_scene:Activity",
                "claim_reward:Activity.ClaimReward",
                "play_fishing:CastLine"
            };

            var package = BugDetector.TryBuildPackage(
                new AITestSnapshot
                {
                    scene = "AITestPilotBasicAutomation",
                    logs = new List<LogEntrySnapshot>
                    {
                        new LogEntrySnapshot
                        {
                            type = "Exception",
                            message = "NullReferenceException: validation reward is null",
                            stackTrace = "ValidationStack",
                            timestampUtc = DateTime.UtcNow.ToString("O")
                        }
                    }
                },
                reproductionSteps);

            Require(package != null, "BugDetector did not build a package from an exception log.");
            Require(string.Equals(package.type, "NullReference", StringComparison.Ordinal), "Bug package type mismatch.");

            package.module = "SampleModule";
            package.function = "StartButton";
            var graph = ScriptableObject.CreateInstance<BugKnowledgeGraphAsset>();
            graph.Record(package, package.module, package.function, "add null guard before reward access");
            var suggestedFix = graph.SuggestFix(package);
            Require(
                string.Equals(suggestedFix, "add null guard before reward access", StringComparison.Ordinal),
                "BugKnowledgeGraphAsset did not reuse the recorded fix.");
            var bugKnowledgeGraph = BugKnowledgeGraphExporter.Build(graph);
            Require(
                bugKnowledgeGraph.nodeCount == 1 &&
                bugKnowledgeGraph.highRiskCount == 1 &&
                bugKnowledgeGraph.moduleRisks != null &&
                bugKnowledgeGraph.moduleRisks.Count == 1 &&
                string.Equals(bugKnowledgeGraph.moduleRisks[0].module, "SampleModule", StringComparison.Ordinal) &&
                bugKnowledgeGraph.moduleFailureTypeRisks != null &&
                bugKnowledgeGraph.moduleFailureTypeRisks.Count == 1 &&
                string.Equals(bugKnowledgeGraph.moduleFailureTypeRisks[0].module, "SampleModule", StringComparison.Ordinal) &&
                string.Equals(bugKnowledgeGraph.moduleFailureTypeRisks[0].type, "NullReference", StringComparison.Ordinal) &&
                bugKnowledgeGraph.moduleRisks[0].score == 5,
                "Bug knowledge graph export did not summarize the expected high-risk module.");

            var postClickSnapshot = SnapshotProvider.Capture(1);
            var finishedAtUtc = DateTime.UtcNow;
            var explorationRun = new ValidationRunReport
            {
                runId = "RUN-SAMPLE-EXPLORE",
                goal = "click the sample start button",
                startedAtUtc = startedAtUtc.ToString("O"),
                finishedAtUtc = finishedAtUtc.ToString("O"),
                outcome = "PASSED",
                exitReason = "finish",
                stepCount = reproductionSteps.Count,
                actionCount = 1,
                bugCount = 0,
                errorLogCount = 0,
                steps = new List<ValidationStepReport>
                {
                    new ValidationStepReport
                    {
                        index = 0,
                        scene = snapshot.scene,
                        action = action.action,
                        target = action.target,
                        uiElementCount = snapshot.ui.Count,
                        logCount = snapshot.logs == null ? 0 : snapshot.logs.Count,
                        bugId = string.Empty
                    }
                },
                bugs = new List<ValidationBugReport>()
            };

            var runnerRun = new ValidationRunReport
            {
                runId = "RUN-SAMPLE-MULTI-STEP-RUNNER",
                goal = runnerResult.goal,
                startedAtUtc = startedAtUtc.ToString("O"),
                finishedAtUtc = DateTime.UtcNow.ToString("O"),
                outcome = "PASSED",
                exitReason = runnerResult.exitReason,
                stepCount = runnerResult.stepCount,
                actionCount = runnerResult.actionCount,
                bugCount = 0,
                errorLogCount = 0,
                steps = BuildStepReports(snapshot.scene, runnerResult.steps, snapshot.ui.Count, string.Empty),
                bugs = new List<ValidationBugReport>()
            };

            var bugRun = new ValidationRunReport
            {
                runId = "RUN-SAMPLE-BUG",
                goal = "package synthetic exception",
                startedAtUtc = startedAtUtc.ToString("O"),
                finishedAtUtc = finishedAtUtc.ToString("O"),
                outcome = "BUG_DETECTED",
                exitReason = "bug_detected",
                stepCount = 1,
                actionCount = reproductionSteps.Count,
                bugCount = 1,
                errorLogCount = 1,
                steps = BuildStepReports(package.scene, reproductionSteps, snapshot.ui.Count, package.bugId),
                bugs = new List<ValidationBugReport>
                {
                    new ValidationBugReport
                    {
                        bugId = package.bugId,
                        type = package.type,
                        scene = package.scene,
                        risk = package.risk,
                        log = package.log
                    }
                }
            };

            var retestRun = new ValidationRunReport
            {
                runId = "RUN-SAMPLE-RETEST",
                goal = "retest packaged bug path",
                startedAtUtc = finishedAtUtc.ToString("O"),
                finishedAtUtc = DateTime.UtcNow.ToString("O"),
                outcome = "PASSED",
                exitReason = "finish",
                stepCount = 1,
                actionCount = 0,
                bugCount = 0,
                errorLogCount = 0,
                steps = new List<ValidationStepReport>
                {
                    new ValidationStepReport
                    {
                        index = 0,
                        scene = postClickSnapshot.scene,
                        action = ActionWhitelist.Finish,
                        target = string.Empty,
                        uiElementCount = postClickSnapshot.ui == null ? 0 : postClickSnapshot.ui.Count,
                        logCount = postClickSnapshot.logs == null ? 0 : postClickSnapshot.logs.Count,
                        bugId = string.Empty
                    }
                },
                bugs = new List<ValidationBugReport>()
            };

            var retestReport = new ValidationRetestReport
            {
                retestId = "RETEST-SAMPLE-001",
                bugId = package.bugId,
                bugType = package.type,
                beforeRunId = bugRun.runId,
                afterRunId = retestRun.runId,
                passed = true,
                result = "passed",
                verifiedAtUtc = DateTime.UtcNow.ToString("O")
            };

            var bugPackageJsonPath = ResolveBugPackageJsonPath();
            var bugPackageMarkdownPath = ResolveBugPackageMarkdownPath();
            BugPackageExporter.Write(package, bugPackageJsonPath, bugPackageMarkdownPath);
            var bugKnowledgeGraphJsonPath = ResolveBugKnowledgeGraphJsonPath();
            var bugKnowledgeGraphMarkdownPath = ResolveBugKnowledgeGraphMarkdownPath();
            BugKnowledgeGraphExporter.Write(bugKnowledgeGraph, bugKnowledgeGraphJsonPath, bugKnowledgeGraphMarkdownPath);

            var repairTask = RepairTaskExporter.Build(
                package,
                suggestedFix,
                bugRun,
                retestReport,
                ".\\tools\\Invoke-AITestPilotRepairRetest.ps1");
            var repairTaskJsonPath = ResolveRepairTaskJsonPath();
            var repairTaskMarkdownPath = ResolveRepairTaskMarkdownPath();
            RepairTaskExporter.Write(repairTask, repairTaskJsonPath, repairTaskMarkdownPath);
            var repairAgentHandoff = RepairAgentHandoffExporter.Build(repairTask, package, bugKnowledgeGraph);
            var repairAgentHandoffJsonPath = ResolveRepairAgentHandoffJsonPath();
            var repairAgentHandoffMarkdownPath = ResolveRepairAgentHandoffMarkdownPath();
            RepairAgentHandoffExporter.Write(
                repairAgentHandoff,
                repairAgentHandoffJsonPath,
                repairAgentHandoffMarkdownPath);
            var repairAgentRun = RepairAgentRunExporter.Build(repairAgentHandoff);
            var repairAgentRunJsonPath = ResolveRepairAgentRunJsonPath();
            var repairAgentRunMarkdownPath = ResolveRepairAgentRunMarkdownPath();
            RepairAgentRunExporter.Write(repairAgentRun, repairAgentRunJsonPath, repairAgentRunMarkdownPath);

            var releaseEvidence = new ValidationReleaseEvidence
            {
                buildVersion = "0.1.0-sample",
                createdAtUtc = DateTime.UtcNow.ToString("O"),
                allowRelease = true,
                unverifiedHighRiskBugCount = 0,
                checks = new List<ValidationReleaseCheck>
                {
                    new ValidationReleaseCheck
                    {
                        name = "unity_package_compile",
                        passed = true,
                        message = "Runtime and Editor assemblies compiled before sample scene validation."
                    },
                    new ValidationReleaseCheck
                    {
                        name = "sample_scene_automation",
                        passed = true,
                        message = "Snapshot, rule decision, and click execution passed."
                    },
                    new ValidationReleaseCheck
                    {
                        name = "multi_step_runner",
                        passed = true,
                        message = "DecisionLoopRunner executed a three-step goal and stopped at the max step boundary."
                    },
                    new ValidationReleaseCheck
                    {
                        name = "bug_retest",
                        passed = true,
                        message = "Synthetic high-risk bug has a passing retest report."
                    },
                    new ValidationReleaseCheck
                    {
                        name = "repair_agent_handoff",
                        passed = true,
                        message = "Repair task has a Cursor-ready handoff document with required context files."
                    },
                    new ValidationReleaseCheck
                    {
                        name = "repair_agent_run_tracking",
                        passed = true,
                        message = "Repair-agent execution state and patch output slots are tracked without claiming an external agent has run."
                    },
                    new ValidationReleaseCheck
                    {
                        name = "model_endpoint_contract",
                        passed = true,
                        message = "Model endpoint settings asset, request schema, prior fix hints, and response action validation passed."
                    },
                    new ValidationReleaseCheck
                    {
                        name = "production_replay_integration_template",
                        passed = true,
                        message = "Production replay integration plan is template-ready and explicitly not bound to real game APIs."
                    }
                },
                failedReasons = new List<string>()
            };

            return new SampleSceneValidationEvidence
            {
                status = "PASS",
                scene = snapshot.scene,
                generatedScenePath = GeneratedSceneAssetPath,
                snapshotSchemaVersion = SnapshotSchemaVersion,
                snapshotJson = JsonUtility.ToJson(snapshot, true),
                uiElementCount = snapshot.ui.Count,
                gameStateCount = snapshot.gameState.Count,
                firstAction = action.action,
                firstTarget = action.target,
                clickCount = manualClickCount,
                bugType = package.type,
                suggestedFix = suggestedFix,
                postClickLogCount = postClickSnapshot.logs == null ? 0 : postClickSnapshot.logs.Count,
                runnerPresent = handle.Runner != null,
                multiStepRunner = multiStepRunnerEvidence,
                runReports = new List<ValidationRunReport> { explorationRun, runnerRun, bugRun, retestRun },
                bugPackage = package,
                bugKnowledgeGraph = bugKnowledgeGraph,
                retestReport = retestReport,
                repairTask = repairTask,
                repairAgentHandoff = repairAgentHandoff,
                repairAgentRun = repairAgentRun,
                modelEndpoint = modelEndpointEvidence,
                productionReplayIntegration = productionReplayIntegration,
                bugPackageJsonPath = bugPackageJsonPath,
                bugPackageMarkdownPath = bugPackageMarkdownPath,
                bugKnowledgeGraphJsonPath = bugKnowledgeGraphJsonPath,
                bugKnowledgeGraphMarkdownPath = bugKnowledgeGraphMarkdownPath,
                repairTaskJsonPath = repairTaskJsonPath,
                repairTaskMarkdownPath = repairTaskMarkdownPath,
                repairAgentHandoffJsonPath = repairAgentHandoffJsonPath,
                repairAgentHandoffMarkdownPath = repairAgentHandoffMarkdownPath,
                repairAgentRunJsonPath = repairAgentRunJsonPath,
                repairAgentRunMarkdownPath = repairAgentRunMarkdownPath,
                productionIntegrationJsonPath = productionIntegrationJsonPath,
                productionIntegrationMarkdownPath = productionIntegrationMarkdownPath,
                releaseEvidence = releaseEvidence
            };
        }

        private static void SaveGeneratedScene()
        {
            var sceneDir = Path.Combine(Application.dataPath, "AITestPilotGenerated");
            Directory.CreateDirectory(sceneDir);
            var saved = EditorSceneManager.SaveScene(SceneManager.GetActiveScene(), GeneratedSceneAssetPath);
            Require(saved, "Failed to save generated sample scene.");
        }

        private static List<ValidationStepReport> BuildStepReports(
            string scene,
            List<string> steps,
            int uiElementCount,
            string bugId)
        {
            var reports = new List<ValidationStepReport>();
            for (var i = 0; i < steps.Count; i++)
            {
                var action = ActionStepParser.Parse(steps[i]);
                reports.Add(new ValidationStepReport
                {
                    index = i,
                    scene = scene,
                    action = action.action,
                    target = action.target,
                    uiElementCount = uiElementCount,
                    logCount = i == steps.Count - 1 ? 1 : 0,
                    bugId = i == steps.Count - 1 ? bugId : string.Empty
                });
            }

            return reports;
        }

        private static void WriteEvidence(SampleSceneValidationEvidence evidence)
        {
            var path = ResolveEvidencePath();
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            File.WriteAllText(path, JsonUtility.ToJson(evidence, true));
            Debug.Log("AI TestPilot sample scene evidence: " + path);
        }

        private static string ResolveEvidencePath()
        {
            return ResolvePathArgument(
                "-aiTestPilotEvidencePath",
                Path.Combine("Temp", "AITestPilot", "sample_scene_validation.json"));
        }

        private static string ResolveRepairTaskJsonPath()
        {
            return ResolvePathArgument(
                "-aiTestPilotRepairTaskJsonPath",
                Path.Combine("Temp", "AITestPilot", "repair-task.json"));
        }

        private static string ResolveRepairTaskMarkdownPath()
        {
            return ResolvePathArgument(
                "-aiTestPilotRepairTaskMarkdownPath",
                Path.Combine("Temp", "AITestPilot", "repair-task.md"));
        }

        private static string ResolveRepairAgentHandoffJsonPath()
        {
            return ResolvePathArgument(
                "-aiTestPilotRepairAgentHandoffJsonPath",
                Path.Combine("Temp", "AITestPilot", "repair-agent-handoff.json"));
        }

        private static string ResolveRepairAgentHandoffMarkdownPath()
        {
            return ResolvePathArgument(
                "-aiTestPilotRepairAgentHandoffMarkdownPath",
                Path.Combine("Temp", "AITestPilot", "repair-agent-handoff.md"));
        }

        private static string ResolveRepairAgentRunJsonPath()
        {
            return ResolvePathArgument(
                "-aiTestPilotRepairAgentRunJsonPath",
                Path.Combine("Temp", "AITestPilot", "repair-agent-run.json"));
        }

        private static string ResolveRepairAgentRunMarkdownPath()
        {
            return ResolvePathArgument(
                "-aiTestPilotRepairAgentRunMarkdownPath",
                Path.Combine("Temp", "AITestPilot", "repair-agent-run.md"));
        }

        private static string ResolveBugPackageJsonPath()
        {
            return ResolvePathArgument(
                "-aiTestPilotBugPackageJsonPath",
                Path.Combine("Temp", "AITestPilot", "bug-package.json"));
        }

        private static string ResolveBugPackageMarkdownPath()
        {
            return ResolvePathArgument(
                "-aiTestPilotBugPackageMarkdownPath",
                Path.Combine("Temp", "AITestPilot", "bug-package.md"));
        }

        private static string ResolveBugKnowledgeGraphJsonPath()
        {
            return ResolvePathArgument(
                "-aiTestPilotBugKnowledgeGraphJsonPath",
                Path.Combine("Temp", "AITestPilot", "bug-knowledge-graph.json"));
        }

        private static string ResolveBugKnowledgeGraphMarkdownPath()
        {
            return ResolvePathArgument(
                "-aiTestPilotBugKnowledgeGraphMarkdownPath",
                Path.Combine("Temp", "AITestPilot", "bug-knowledge-graph.md"));
        }

        private static string ResolveProductionIntegrationJsonPath()
        {
            return ResolvePathArgument(
                "-aiTestPilotProductionIntegrationJsonPath",
                Path.Combine("Temp", "AITestPilot", "production-replay-integration-checklist.json"));
        }

        private static string ResolveProductionIntegrationMarkdownPath()
        {
            return ResolvePathArgument(
                "-aiTestPilotProductionIntegrationMarkdownPath",
                Path.Combine("Temp", "AITestPilot", "production-replay-integration-checklist.md"));
        }

        private static string ResolvePathArgument(string argumentName, string defaultRelativePath)
        {
            var args = Environment.GetCommandLineArgs();
            for (var i = 0; i < args.Length - 1; i++)
            {
                if (string.Equals(args[i], argumentName, StringComparison.OrdinalIgnoreCase))
                {
                    return args[i + 1];
                }
            }

            var projectRoot = Path.GetFullPath(Path.Combine(Application.dataPath, ".."));
            return Path.Combine(projectRoot, defaultRelativePath);
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
    public sealed class SampleSceneValidationEvidence
    {
        public string status;
        public string scene;
        public string generatedScenePath;
        public string snapshotSchemaVersion;
        public string snapshotJson;
        public int uiElementCount;
        public int gameStateCount;
        public string firstAction;
        public string firstTarget;
        public int clickCount;
        public string bugType;
        public string suggestedFix;
        public int postClickLogCount;
        public bool runnerPresent;
        public ValidationMultiStepRunnerEvidence multiStepRunner;
        public List<ValidationRunReport> runReports;
        public BugPackage bugPackage;
        public BugKnowledgeGraphDocument bugKnowledgeGraph;
        public ValidationRetestReport retestReport;
        public RepairTaskDocument repairTask;
        public RepairAgentHandoffDocument repairAgentHandoff;
        public RepairAgentRunDocument repairAgentRun;
        public ModelEndpointSettingsEvidence modelEndpoint;
        public ProductionReplayIntegrationEvidence productionReplayIntegration;
        public string bugPackageJsonPath;
        public string bugPackageMarkdownPath;
        public string bugKnowledgeGraphJsonPath;
        public string bugKnowledgeGraphMarkdownPath;
        public string repairTaskJsonPath;
        public string repairTaskMarkdownPath;
        public string repairAgentHandoffJsonPath;
        public string repairAgentHandoffMarkdownPath;
        public string repairAgentRunJsonPath;
        public string repairAgentRunMarkdownPath;
        public string productionIntegrationJsonPath;
        public string productionIntegrationMarkdownPath;
        public ValidationReleaseEvidence releaseEvidence;
    }

    [Serializable]
    public sealed class ValidationMultiStepRunnerEvidence
    {
        public string status;
        public string goal;
        public int maxSteps;
        public int stepCount;
        public int actionCount;
        public int clickCount;
        public string exitReason;
        public List<string> steps;
    }

    [Serializable]
    public sealed class ValidationRunReport
    {
        public string runId;
        public string goal;
        public string startedAtUtc;
        public string finishedAtUtc;
        public string outcome;
        public string exitReason;
        public int stepCount;
        public int actionCount;
        public int bugCount;
        public int errorLogCount;
        public List<ValidationStepReport> steps;
        public List<ValidationBugReport> bugs;
    }

    [Serializable]
    public sealed class ValidationStepReport
    {
        public int index;
        public string scene;
        public string action;
        public string target;
        public int uiElementCount;
        public int logCount;
        public string bugId;
    }

    [Serializable]
    public sealed class ValidationBugReport
    {
        public string bugId;
        public string type;
        public string scene;
        public string risk;
        public string log;
    }

    [Serializable]
    public sealed class ValidationRetestReport
    {
        public string retestId;
        public string bugId;
        public string bugType;
        public string beforeRunId;
        public string afterRunId;
        public bool passed;
        public string result;
        public string verifiedAtUtc;
    }

    [Serializable]
    public sealed class ValidationReleaseEvidence
    {
        public string buildVersion;
        public string createdAtUtc;
        public bool allowRelease;
        public int unverifiedHighRiskBugCount;
        public List<ValidationReleaseCheck> checks;
        public List<string> failedReasons;
    }

    [Serializable]
    public sealed class ValidationReleaseCheck
    {
        public string name;
        public bool passed;
        public string message;
    }
}
