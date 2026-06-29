using System;
using System.Collections.Generic;
using System.IO;
using Kibernet.AITestPilot.Unity;
using UnityEditor;
using UnityEngine;

namespace Kibernet.AITestPilot.Unity.Editor
{
    public static class ProductionReplayIntegrationPlanContractProbe
    {
        private const string TemplatePlanAssetPath = "Assets/AITestPilotGenerated/ProductionReplayIntegrationContractTemplate.asset";
        private const string InvalidFlipPlanAssetPath = "Assets/AITestPilotGenerated/ProductionReplayIntegrationContractInvalidFlip.asset";
        private const string BoundPlanAssetPath = "Assets/AITestPilotGenerated/ProductionReplayIntegrationContractBound.asset";

        public static void Run()
        {
            try
            {
                var evidence = RunProbe();
                var path = ResolvePathArgument(
                    "-aiTestPilotProductionIntegrationContractProbePath",
                    Path.Combine("Temp", "AITestPilot", "production-replay-integration-contract-probe.json"));
                Directory.CreateDirectory(Path.GetDirectoryName(path));
                File.WriteAllText(path, JsonUtility.ToJson(evidence, true));
                Debug.Log("PASS AI TestPilot production replay integration contract probe");
                EditorApplication.Exit(0);
            }
            catch (Exception ex)
            {
                Debug.LogError("FAIL AI TestPilot production replay integration contract probe\n" + ex);
                EditorApplication.Exit(1);
            }
        }

        private static ProductionReplayIntegrationContractProbeEvidence RunProbe()
        {
            var templatePlan = ProductionReplayIntegrationPlanAssetUtility.CreateOrUpdateTemplatePlan(
                TemplatePlanAssetPath);
            var templateEvidence = ProductionReplayIntegrationPlanAssetUtility.ValidatePlan(templatePlan);

            var invalidFlipPlan = ProductionReplayIntegrationPlanAssetUtility.CreateOrUpdateTemplatePlan(
                InvalidFlipPlanAssetPath);
            invalidFlipPlan.realProjectBound = true;
            invalidFlipPlan.notes = new List<string>
            {
                "Contract probe invalid state: realProjectBound was flipped without binding hooks."
            };
            EditorUtility.SetDirty(invalidFlipPlan);
            AssetDatabase.SaveAssets();
            var invalidFlipEvidence = ProductionReplayIntegrationPlanAssetUtility.ValidatePlan(invalidFlipPlan);

            var boundPlan = ProductionReplayIntegrationPlanAssetUtility.CreateOrUpdateTemplatePlan(
                BoundPlanAssetPath);
            ConfigureBoundContractPlan(boundPlan);
            var boundEvidence = ProductionReplayIntegrationPlanAssetUtility.ValidatePlan(boundPlan);

            Require(
                string.Equals(templateEvidence.status, ProductionReplayIntegrationPlanAssetUtility.TemplateReadyStatus, StringComparison.Ordinal),
                "Template plan did not validate as TEMPLATE_READY.");
            Require(
                string.Equals(invalidFlipEvidence.status, ProductionReplayIntegrationPlanAssetUtility.InvalidStatus, StringComparison.Ordinal),
                "Invalid flipped plan did not validate as INVALID.");
            Require(
                string.Equals(boundEvidence.status, ProductionReplayIntegrationPlanAssetUtility.BoundStatus, StringComparison.Ordinal),
                "Bound contract plan did not validate as BOUND.");
            Require(boundEvidence.realProjectBound, "Bound contract evidence did not record realProjectBound=true.");
            Require(boundEvidence.requiredHookCount == 5, "Bound contract evidence did not include all required hooks.");
            Require(boundEvidence.boundRequiredHookCount == 5, "Bound contract evidence did not bind all required hooks.");
            Require(boundEvidence.unresolvedRequiredHookCount == 0, "Bound contract evidence still had unresolved hooks.");
            Require(boundEvidence.requiredHandlerKeysPresent, "Bound contract evidence is missing standard handler keys.");
            Require(boundEvidence.requiredBindingMetadataComplete, "Bound contract evidence is missing binding metadata.");

            return new ProductionReplayIntegrationContractProbeEvidence
            {
                schemaVersion = "aitestpilot.production_replay_integration_contract_probe.v1",
                status = "PASS",
                generatedAtUtc = DateTime.UtcNow.ToString("O"),
                fixtureGenerated = true,
                realProjectApiCallsProven = false,
                templateStatus = templateEvidence.status,
                invalidFlipStatus = invalidFlipEvidence.status,
                boundStatus = boundEvidence.status,
                boundRealProjectBound = boundEvidence.realProjectBound,
                boundRequiredHookCount = boundEvidence.requiredHookCount,
                boundRequiredHookBoundCount = boundEvidence.boundRequiredHookCount,
                boundUnresolvedRequiredHookCount = boundEvidence.unresolvedRequiredHookCount,
                boundRequiredHandlerKeysPresent = boundEvidence.requiredHandlerKeysPresent,
                boundAllRequiredHooksBound = boundEvidence.allRequiredHooksBound,
                boundRequiredBindingMetadataComplete = boundEvidence.requiredBindingMetadataComplete,
                templateEvidence = templateEvidence,
                invalidFlipEvidence = invalidFlipEvidence,
                boundEvidence = boundEvidence,
                notes = new List<string>
                {
                    "This probe validates the integration-plan contract only.",
                    "It does not prove calls to a real game API.",
                    "Real project release still requires production retest evidence with a non-sample driver."
                }
            };
        }

        private static void ConfigureBoundContractPlan(ProductionReplayIntegrationPlan plan)
        {
            plan.driverTypeName = "ContractProbe.Game.Tests.ProductionReplayDriver";
            plan.driverId = "contract_probe.production_replay";
            plan.realProjectBound = true;
            plan.qaAccountEnvironmentVariable = "AITESTPILOT_QA_ACCOUNT";
            plan.serverEnvironmentVariable = "AITESTPILOT_SERVER";
            plan.notes = new List<string>
            {
                "Contract probe fixture for BOUND validation.",
                "This fixture verifies metadata completeness and hook binding state only."
            };

            if (plan.hookBindings != null)
            {
                foreach (var binding in plan.hookBindings)
                {
                    if (binding == null)
                    {
                        continue;
                    }

                    binding.boundToRealGameApi = true;
                    binding.gameApiOwner = "contract probe owner for " + binding.action;
                    binding.gameApiSurface = "Contract probe API surface for " + binding.handlerKey;
                    binding.verificationSignal = "Contract probe state assertion for " + binding.handlerKey;
                    if (string.IsNullOrWhiteSpace(binding.notes))
                    {
                        binding.notes = "Contract probe fixture; replace with real game API notes in production.";
                    }
                }
            }

            EditorUtility.SetDirty(plan);
            AssetDatabase.SaveAssets();
            AssetDatabase.Refresh();
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
    public sealed class ProductionReplayIntegrationContractProbeEvidence
    {
        public string schemaVersion;
        public string status;
        public string generatedAtUtc;
        public bool fixtureGenerated;
        public bool realProjectApiCallsProven;
        public string templateStatus;
        public string invalidFlipStatus;
        public string boundStatus;
        public bool boundRealProjectBound;
        public int boundRequiredHookCount;
        public int boundRequiredHookBoundCount;
        public int boundUnresolvedRequiredHookCount;
        public bool boundRequiredHandlerKeysPresent;
        public bool boundAllRequiredHooksBound;
        public bool boundRequiredBindingMetadataComplete;
        public ProductionReplayIntegrationEvidence templateEvidence;
        public ProductionReplayIntegrationEvidence invalidFlipEvidence;
        public ProductionReplayIntegrationEvidence boundEvidence;
        public List<string> notes;
    }
}
