using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using Kibernet.AITestPilot.Unity;
using UnityEditor;
using UnityEngine;

namespace Kibernet.AITestPilot.Unity.Editor
{
    public static class ProductionReplayIntegrationPlanAssetUtility
    {
        public const string DefaultPlanAssetPath = "Assets/AITestPilotGenerated/ProductionReplayIntegrationPlan.asset";
        public const string TemplateReadyStatus = "TEMPLATE_READY";
        public const string BoundStatus = "BOUND";
        public const string InvalidStatus = "INVALID";

        [MenuItem("Tools/Kibernet/AI TestPilot/Create Production Replay Integration Plan")]
        public static void CreateProductionReplayIntegrationPlanMenu()
        {
            var plan = CreateOrUpdateTemplatePlan(DefaultPlanAssetPath);
            Selection.activeObject = plan;
        }

        public static ProductionReplayIntegrationPlan CreateOrUpdateTemplatePlan(string assetPath)
        {
            assetPath = NormalizeUnityAssetPath(assetPath);
            EnsureAssetDirectory(assetPath);

            var plan = AssetDatabase.LoadAssetAtPath<ProductionReplayIntegrationPlan>(assetPath);
            if (plan == null)
            {
                plan = ScriptableObject.CreateInstance<ProductionReplayIntegrationPlan>();
                AssetDatabase.CreateAsset(plan, assetPath);
            }

            plan.schemaVersion = "ai-testpilot.production_replay_integration.v1";
            plan.driverTypeName = "Your.Game.Tests.ProductionReplayDriver";
            plan.driverId = "your_game.production_replay";
            plan.realProjectBound = false;
            plan.qaAccountEnvironmentVariable = "AITESTPILOT_QA_ACCOUNT";
            plan.serverEnvironmentVariable = "AITESTPILOT_SERVER";
            plan.hookBindings = BuildTemplateHookBindings();
            plan.notes = new List<string>
            {
                "Template is intentionally not bound to a real game project.",
                "Set realProjectBound=true only after every required hook calls production game APIs and verifies resulting game state."
            };

            EditorUtility.SetDirty(plan);
            AssetDatabase.SaveAssets();
            AssetDatabase.Refresh();
            return plan;
        }

        public static ProductionReplayIntegrationEvidence ValidateTemplatePlan(ProductionReplayIntegrationPlan plan)
        {
            return ValidatePlan(plan);
        }

        public static ProductionReplayIntegrationEvidence ValidatePlan(ProductionReplayIntegrationPlan plan)
        {
            if (plan == null)
            {
                throw new ArgumentNullException("plan");
            }

            var requiredHookCount = 0;
            var boundRequiredHookCount = 0;
            var unresolved = new List<string>();
            var handlerKeys = new List<string>();
            var requiredBindingMetadataComplete = true;

            if (plan.hookBindings != null)
            {
                foreach (var binding in plan.hookBindings)
                {
                    if (binding == null)
                    {
                        continue;
                    }

                    if (!string.IsNullOrWhiteSpace(binding.handlerKey) &&
                        !handlerKeys.Contains(binding.handlerKey))
                    {
                        handlerKeys.Add(binding.handlerKey);
                    }

                    if (!binding.required)
                    {
                        continue;
                    }

                    requiredHookCount++;
                    if (!HasCompleteRequiredBindingMetadata(binding))
                    {
                        requiredBindingMetadataComplete = false;
                    }

                    if (binding.boundToRealGameApi)
                    {
                        boundRequiredHookCount++;
                    }
                    else
                    {
                        unresolved.Add(binding.action + ":" + binding.exampleTarget);
                    }
                }
            }

            var requiredHandlerKeysPresent = ContainsAllStandardHandlerKeys(handlerKeys);
            var unresolvedRequiredHookCount = requiredHookCount - boundRequiredHookCount;
            var basePlanComplete =
                !string.IsNullOrWhiteSpace(plan.driverTypeName) &&
                !string.IsNullOrWhiteSpace(plan.driverId) &&
                !string.IsNullOrWhiteSpace(plan.qaAccountEnvironmentVariable) &&
                !string.IsNullOrWhiteSpace(plan.serverEnvironmentVariable) &&
                requiredHookCount == 5 &&
                requiredHandlerKeysPresent;
            var templateReady =
                basePlanComplete &&
                unresolvedRequiredHookCount == 5 &&
                !plan.realProjectBound;
            var boundReady =
                basePlanComplete &&
                plan.realProjectBound &&
                boundRequiredHookCount == requiredHookCount &&
                unresolvedRequiredHookCount == 0 &&
                requiredBindingMetadataComplete;
            var status = InvalidStatus;
            if (boundReady)
            {
                status = BoundStatus;
            }
            else if (templateReady)
            {
                status = TemplateReadyStatus;
            }

            return new ProductionReplayIntegrationEvidence
            {
                schemaVersion = plan.schemaVersion,
                status = status,
                generatedAtUtc = DateTime.UtcNow.ToString("O"),
                planAssetPath = AssetDatabase.GetAssetPath(plan),
                driverTypeName = plan.driverTypeName,
                driverId = plan.driverId,
                realProjectBound = plan.realProjectBound,
                qaAccountEnvironmentVariable = plan.qaAccountEnvironmentVariable,
                serverEnvironmentVariable = plan.serverEnvironmentVariable,
                requiredHookCount = requiredHookCount,
                boundRequiredHookCount = boundRequiredHookCount,
                unresolvedRequiredHookCount = unresolvedRequiredHookCount,
                requiredHandlerKeysPresent = requiredHandlerKeysPresent,
                allRequiredHooksBound = requiredHookCount > 0 && boundRequiredHookCount == requiredHookCount,
                requiredBindingMetadataComplete = requiredBindingMetadataComplete,
                supportedHandlerKeys = handlerKeys,
                unresolvedHookTargets = unresolved,
                hookBindings = plan.hookBindings == null
                    ? new List<ProductionReplayHookBinding>()
                    : new List<ProductionReplayHookBinding>(plan.hookBindings),
                notes = plan.notes == null ? new List<string>() : new List<string>(plan.notes)
            };
        }

        public static void WriteEvidence(
            ProductionReplayIntegrationEvidence evidence,
            string jsonPath,
            string markdownPath)
        {
            if (evidence == null)
            {
                throw new ArgumentNullException("evidence");
            }

            EnsureFileDirectory(jsonPath);
            EnsureFileDirectory(markdownPath);
            File.WriteAllText(jsonPath, JsonUtility.ToJson(evidence, true), Encoding.UTF8);
            File.WriteAllText(markdownPath, ToMarkdown(evidence), Encoding.UTF8);
        }

        public static string ToMarkdown(ProductionReplayIntegrationEvidence evidence)
        {
            var builder = new StringBuilder();
            builder.AppendLine("# AI TestPilot Production Replay Integration");
            builder.AppendLine();
            builder.AppendLine("- Status: `" + evidence.status + "`");
            builder.AppendLine("- Driver type: `" + evidence.driverTypeName + "`");
            builder.AppendLine("- Driver id: `" + evidence.driverId + "`");
            builder.AppendLine("- Real project bound: `" + evidence.realProjectBound + "`");
            builder.AppendLine("- Required hooks: `" + evidence.requiredHookCount + "`");
            builder.AppendLine("- Bound required hooks: `" + evidence.boundRequiredHookCount + "`");
            builder.AppendLine("- Unresolved required hooks: `" + evidence.unresolvedRequiredHookCount + "`");
            builder.AppendLine("- Required binding metadata complete: `" + evidence.requiredBindingMetadataComplete + "`");
            builder.AppendLine();
            builder.AppendLine("## Required Environment");
            builder.AppendLine();
            builder.AppendLine("- `" + evidence.qaAccountEnvironmentVariable + "`: QA account alias.");
            builder.AppendLine("- `" + evidence.serverEnvironmentVariable + "`: target server or shard.");
            builder.AppendLine();
            builder.AppendLine("## Hook Bindings");
            builder.AppendLine();

            foreach (var binding in evidence.hookBindings)
            {
                if (binding == null)
                {
                    continue;
                }

                builder.AppendLine("### `" + binding.action + "`");
                builder.AppendLine();
                builder.AppendLine("- Handler key: `" + binding.handlerKey + "`");
                builder.AppendLine("- Example target: `" + binding.exampleTarget + "`");
                builder.AppendLine("- Game API owner: `" + binding.gameApiOwner + "`");
                builder.AppendLine("- Game API surface: `" + binding.gameApiSurface + "`");
                builder.AppendLine("- Verification signal: `" + binding.verificationSignal + "`");
                builder.AppendLine("- Bound to real game API: `" + binding.boundToRealGameApi + "`");
                builder.AppendLine();
            }

            builder.AppendLine("## Acceptance");
            builder.AppendLine();
            builder.AppendLine("Set `realProjectBound=true` only after every required hook returns `Pass` from real game APIs and verifies the resulting game state.");
            return builder.ToString();
        }

        private static List<ProductionReplayHookBinding> BuildTemplateHookBindings()
        {
            return new List<ProductionReplayHookBinding>
            {
                new ProductionReplayHookBinding
                {
                    action = ActionWhitelist.PrepareAccount,
                    handlerKey = GameActionReplayHandlerKeys.PrepareAccount,
                    exampleTarget = "qa_smoke_account",
                    gameApiOwner = "account/platform team",
                    gameApiSurface = "Create, reset, or select QA account before login.",
                    verificationSignal = "Account exists and is reset to the test baseline.",
                    boundToRealGameApi = false,
                    notes = "Use context.target as the account alias."
                },
                new ProductionReplayHookBinding
                {
                    action = ActionWhitelist.Login,
                    handlerKey = GameActionReplayHandlerKeys.Login,
                    exampleTarget = "qa_smoke_account",
                    gameApiOwner = "login/session team",
                    gameApiSurface = "Login with the prepared account and wait for stable lobby.",
                    verificationSignal = "Logged-in player id matches the requested QA account.",
                    boundToRealGameApi = false,
                    notes = "Fail if account preparation has not completed."
                },
                new ProductionReplayHookBinding
                {
                    action = ActionWhitelist.EnterScene,
                    handlerKey = GameActionReplayHandlerKeys.EnterScene,
                    exampleTarget = "Activity",
                    gameApiOwner = "navigation/activity team",
                    gameApiSurface = "Navigate to the requested scene or feature.",
                    verificationSignal = "Current scene or feature route equals context.target.",
                    boundToRealGameApi = false
                },
                new ProductionReplayHookBinding
                {
                    action = ActionWhitelist.ClaimReward,
                    handlerKey = GameActionReplayHandlerKeys.ClaimReward,
                    exampleTarget = "Activity.ClaimReward",
                    gameApiOwner = "activity/reward team",
                    gameApiSurface = "Claim the requested activity reward.",
                    verificationSignal = "Reward claim result is successful and duplicate claims are handled.",
                    boundToRealGameApi = false
                },
                new ProductionReplayHookBinding
                {
                    action = ActionWhitelist.PlayFishing,
                    handlerKey = GameActionReplayHandlerKeys.PlayFishing,
                    exampleTarget = "CastLine",
                    gameApiOwner = "fishing/gameplay team",
                    gameApiSurface = "Execute the requested fishing action.",
                    verificationSignal = "Fishing state advances to the expected phase without errors.",
                    boundToRealGameApi = false
                }
            };
        }

        private static bool ContainsAllStandardHandlerKeys(List<string> handlerKeys)
        {
            foreach (var key in GameActionReplayDriverDescriptorFactory.StandardHandlerKeys())
            {
                if (!handlerKeys.Contains(key))
                {
                    return false;
                }
            }

            return true;
        }

        private static bool HasCompleteRequiredBindingMetadata(ProductionReplayHookBinding binding)
        {
            return binding != null &&
                !string.IsNullOrWhiteSpace(binding.action) &&
                !string.IsNullOrWhiteSpace(binding.handlerKey) &&
                !string.IsNullOrWhiteSpace(binding.exampleTarget) &&
                !string.IsNullOrWhiteSpace(binding.gameApiOwner) &&
                !string.IsNullOrWhiteSpace(binding.gameApiSurface) &&
                !string.IsNullOrWhiteSpace(binding.verificationSignal);
        }

        private static string NormalizeUnityAssetPath(string assetPath)
        {
            if (string.IsNullOrWhiteSpace(assetPath))
            {
                throw new ArgumentException("Production replay integration plan asset path is required.", "assetPath");
            }

            var normalized = assetPath.Replace("\\", "/");
            if (!normalized.StartsWith("Assets/", StringComparison.Ordinal) &&
                !string.Equals(normalized, "Assets", StringComparison.Ordinal))
            {
                throw new ArgumentException("Production replay integration plan asset path must be under Assets/.", "assetPath");
            }

            if (!normalized.EndsWith(".asset", StringComparison.OrdinalIgnoreCase))
            {
                throw new ArgumentException("Production replay integration plan asset path must end with .asset.", "assetPath");
            }

            return normalized;
        }

        private static void EnsureAssetDirectory(string assetPath)
        {
            var directory = Path.GetDirectoryName(assetPath);
            if (string.IsNullOrWhiteSpace(directory))
            {
                return;
            }

            var parts = directory.Replace("\\", "/").Split('/');
            var current = parts[0];
            for (var i = 1; i < parts.Length; i++)
            {
                var next = current + "/" + parts[i];
                if (!AssetDatabase.IsValidFolder(next))
                {
                    AssetDatabase.CreateFolder(current, parts[i]);
                }

                current = next;
            }
        }

        private static void EnsureFileDirectory(string filePath)
        {
            var directory = Path.GetDirectoryName(filePath);
            if (!string.IsNullOrWhiteSpace(directory))
            {
                Directory.CreateDirectory(directory);
            }
        }
    }

    [Serializable]
    public sealed class ProductionReplayIntegrationEvidence
    {
        public string schemaVersion;
        public string status;
        public string generatedAtUtc;
        public string planAssetPath;
        public string driverTypeName;
        public string driverId;
        public bool realProjectBound;
        public string qaAccountEnvironmentVariable;
        public string serverEnvironmentVariable;
        public int requiredHookCount;
        public int boundRequiredHookCount;
        public int unresolvedRequiredHookCount;
        public bool requiredHandlerKeysPresent;
        public bool allRequiredHooksBound;
        public bool requiredBindingMetadataComplete;
        public List<string> supportedHandlerKeys;
        public List<string> unresolvedHookTargets;
        public List<ProductionReplayHookBinding> hookBindings;
        public List<string> notes;
    }
}
