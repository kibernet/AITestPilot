using System;
using System.Collections.Generic;
using System.IO;
using Kibernet.AITestPilot.Unity;
using UnityEditor;
using UnityEngine;

namespace Kibernet.AITestPilot.Unity.Editor
{
    public static class ActionReplayProfileBatchImporter
    {
        private const string DefaultImportedProfileAssetPath = "Assets/AITestPilotGenerated/ImportedReplayProfile.asset";

        public static void ImportReplayProfileFromJson()
        {
            try
            {
                var jsonPath = ResolvePathArgument("-aiTestPilotReplayProfileJsonPath", string.Empty);
                if (string.IsNullOrWhiteSpace(jsonPath))
                {
                    throw new ArgumentException("Replay profile JSON path is required.");
                }

                var assetPath = ResolveStringArgument(
                    "-aiTestPilotReplayProfileAssetPath",
                    DefaultImportedProfileAssetPath);
                assetPath = ActionReplayProfileAssetUtility.NormalizeUnityAssetPath(assetPath);

                var evidencePath = ResolvePathArgument(
                    "-aiTestPilotReplayProfileImportEvidencePath",
                    Path.Combine("Temp", "AITestPilot", "replay-profile-import.json"));
                var normalizedJsonPath = ResolvePathArgument(
                    "-aiTestPilotReplayProfileNormalizedJsonPath",
                    Path.Combine("Temp", "AITestPilot", "imported-replay-profile.normalized.json"));

                var existedBefore = AssetDatabase.LoadAssetAtPath<ActionReplayProfile>(assetPath) != null;
                var sourceDocument = ActionReplayProfileAssetUtility.ReadJsonDocument(jsonPath);
                var profile = ActionReplayProfileAssetUtility.ImportFromJson(jsonPath, assetPath);
                ActionReplayProfileAssetUtility.ExportToJson(profile, normalizedJsonPath);

                var evidence = new ActionReplayProfileImportEvidence
                {
                    status = "PASS",
                    importedAtUtc = DateTime.UtcNow.ToString("O"),
                    sourceJsonPath = jsonPath,
                    assetPath = assetPath,
                    normalizedJsonPath = normalizedJsonPath,
                    adapterId = profile.adapterId,
                    ruleCount = profile.rules == null ? 0 : profile.rules.Count,
                    sourceRuleCount = sourceDocument.rules == null ? 0 : sourceDocument.rules.Count,
                    assetExistedBefore = existedBefore,
                    assetPresent = AssetDatabase.LoadAssetAtPath<ActionReplayProfile>(assetPath) != null,
                    handlerKeys = BuildHandlerKeyList(profile),
                    actions = BuildActionList(profile),
                    targets = BuildTargetList(profile)
                };

                WriteEvidence(evidencePath, evidence);
                Debug.Log("PASS AI TestPilot replay profile JSON import");
                EditorApplication.Exit(0);
            }
            catch (Exception ex)
            {
                Debug.LogError("FAIL AI TestPilot replay profile JSON import\n" + ex);
                EditorApplication.Exit(1);
            }
        }

        private static List<string> BuildHandlerKeyList(ActionReplayProfile profile)
        {
            var values = new List<string>();
            if (profile == null || profile.rules == null)
            {
                return values;
            }

            foreach (var rule in profile.rules)
            {
                AddUnique(values, rule == null ? string.Empty : rule.handlerKey);
            }

            return values;
        }

        private static List<string> BuildActionList(ActionReplayProfile profile)
        {
            var values = new List<string>();
            if (profile == null || profile.rules == null)
            {
                return values;
            }

            foreach (var rule in profile.rules)
            {
                AddUnique(values, rule == null ? string.Empty : rule.action);
            }

            return values;
        }

        private static List<string> BuildTargetList(ActionReplayProfile profile)
        {
            var values = new List<string>();
            if (profile == null || profile.rules == null)
            {
                return values;
            }

            foreach (var rule in profile.rules)
            {
                AddUnique(values, rule == null ? string.Empty : rule.target);
            }

            return values;
        }

        private static void AddUnique(List<string> values, string value)
        {
            if (!string.IsNullOrWhiteSpace(value) && !values.Contains(value))
            {
                values.Add(value);
            }
        }

        private static void WriteEvidence(string path, ActionReplayProfileImportEvidence evidence)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            File.WriteAllText(path, JsonUtility.ToJson(evidence, true));
            Debug.Log("AI TestPilot replay profile import evidence: " + path);
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
    }

    [Serializable]
    public sealed class ActionReplayProfileImportEvidence
    {
        public string status;
        public string importedAtUtc;
        public string sourceJsonPath;
        public string assetPath;
        public string normalizedJsonPath;
        public string adapterId;
        public int ruleCount;
        public int sourceRuleCount;
        public bool assetExistedBefore;
        public bool assetPresent;
        public List<string> handlerKeys;
        public List<string> actions;
        public List<string> targets;
    }
}
