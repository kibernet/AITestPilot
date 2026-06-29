using System;
using System.Collections.Generic;
using System.IO;
using Kibernet.AITestPilot.Unity;
using UnityEditor;
using UnityEngine;

namespace Kibernet.AITestPilot.Unity.Editor
{
    public static class ActionReplayProfileAssetUtility
    {
        public const string SampleProfileAssetPath = "Assets/AITestPilotGenerated/SampleBusinessReplayProfile.asset";

        [MenuItem("Tools/Kibernet/AI TestPilot/Create Sample Business Replay Profile")]
        public static void CreateSampleBusinessReplayProfileMenu()
        {
            var profile = CreateOrUpdateSampleBusinessReplayProfile(SampleProfileAssetPath);
            Selection.activeObject = profile;
        }

        [MenuItem("Tools/Kibernet/AI TestPilot/Import Replay Profile From JSON")]
        public static void ImportReplayProfileFromJsonMenu()
        {
            var jsonPath = EditorUtility.OpenFilePanel(
                "Import AI TestPilot Replay Profile",
                Application.dataPath,
                "json");
            if (string.IsNullOrWhiteSpace(jsonPath))
            {
                return;
            }

            var assetPath = EditorUtility.SaveFilePanelInProject(
                "Save AI TestPilot Replay Profile",
                "ImportedReplayProfile",
                "asset",
                "Choose where to save the imported replay profile.");
            if (string.IsNullOrWhiteSpace(assetPath))
            {
                return;
            }

            var profile = ImportFromJson(jsonPath, assetPath);
            Selection.activeObject = profile;
        }

        public static ActionReplayProfile CreateOrUpdateSampleBusinessReplayProfile(string assetPath)
        {
            assetPath = NormalizeUnityAssetPath(assetPath);
            EnsureAssetDirectory(assetPath);

            var profile = AssetDatabase.LoadAssetAtPath<ActionReplayProfile>(assetPath);
            if (profile == null)
            {
                profile = ScriptableObject.CreateInstance<ActionReplayProfile>();
                AssetDatabase.CreateAsset(profile, assetPath);
            }

            profile.adapterId = "profile.sample_business_flow";
            profile.rules = new List<ActionReplayRule>
            {
                new ActionReplayRule
                {
                    action = ActionWhitelist.PrepareAccount,
                    target = "qa_smoke_account",
                    handlerKey = GameActionReplayHandlerKeys.PrepareAccount,
                    successMessage = "Configured profile prepared the QA smoke account."
                },
                new ActionReplayRule
                {
                    action = ActionWhitelist.Login,
                    target = "qa_smoke_account",
                    handlerKey = GameActionReplayHandlerKeys.Login,
                    successMessage = "Configured profile logged in with the QA smoke account."
                },
                new ActionReplayRule
                {
                    action = ActionWhitelist.EnterScene,
                    target = "Activity",
                    handlerKey = GameActionReplayHandlerKeys.EnterScene,
                    successMessage = "Configured profile entered Activity."
                },
                new ActionReplayRule
                {
                    action = ActionWhitelist.ClaimReward,
                    target = "Activity.ClaimReward",
                    handlerKey = GameActionReplayHandlerKeys.ClaimReward,
                    successMessage = "Configured profile claimed the activity reward."
                },
                new ActionReplayRule
                {
                    action = ActionWhitelist.PlayFishing,
                    target = "CastLine",
                    handlerKey = GameActionReplayHandlerKeys.PlayFishing,
                    successMessage = "Configured profile replayed fishing cast."
                }
            };

            EditorUtility.SetDirty(profile);
            AssetDatabase.SaveAssets();
            AssetDatabase.Refresh();
            return profile;
        }

        public static void ExportToJson(ActionReplayProfile profile, string jsonPath)
        {
            if (profile == null)
            {
                throw new ArgumentNullException("profile");
            }

            EnsureFileDirectory(jsonPath);
            var document = new ActionReplayProfileJsonDocument
            {
                adapterId = profile.adapterId,
                rules = new List<ActionReplayRuleJsonDocument>()
            };

            foreach (var rule in profile.rules)
            {
                if (rule == null)
                {
                    continue;
                }

                document.rules.Add(new ActionReplayRuleJsonDocument
                {
                    action = rule.action,
                    target = rule.target,
                    handlerKey = rule.handlerKey,
                    successMessage = rule.successMessage,
                    allowDefaultFallback = rule.allowDefaultFallback
                });
            }

            File.WriteAllText(jsonPath, JsonUtility.ToJson(document, true));
        }

        public static ActionReplayProfile ImportFromJson(string jsonPath, string assetPath)
        {
            var document = ReadJsonDocument(jsonPath);
            assetPath = NormalizeUnityAssetPath(assetPath);
            EnsureAssetDirectory(assetPath);

            var profile = AssetDatabase.LoadAssetAtPath<ActionReplayProfile>(assetPath);
            if (profile == null)
            {
                profile = ScriptableObject.CreateInstance<ActionReplayProfile>();
                AssetDatabase.CreateAsset(profile, assetPath);
            }

            profile.adapterId = document.adapterId;
            profile.rules = new List<ActionReplayRule>();
            foreach (var ruleDocument in document.rules)
            {
                if (ruleDocument == null)
                {
                    continue;
                }

                ValidateRule(ruleDocument);
                profile.rules.Add(new ActionReplayRule
                {
                    action = ruleDocument.action,
                    target = ruleDocument.target,
                    handlerKey = ruleDocument.handlerKey,
                    successMessage = ruleDocument.successMessage,
                    allowDefaultFallback = ruleDocument.allowDefaultFallback
                });
            }

            EditorUtility.SetDirty(profile);
            AssetDatabase.SaveAssets();
            AssetDatabase.Refresh();
            return profile;
        }

        public static ActionReplayProfileJsonDocument ReadJsonDocument(string jsonPath)
        {
            if (string.IsNullOrWhiteSpace(jsonPath))
            {
                throw new ArgumentException("Replay profile JSON path is required.", "jsonPath");
            }

            if (!File.Exists(jsonPath))
            {
                throw new FileNotFoundException("Replay profile JSON was not found.", jsonPath);
            }

            var document = JsonUtility.FromJson<ActionReplayProfileJsonDocument>(File.ReadAllText(jsonPath));
            if (document == null)
            {
                throw new InvalidDataException("Replay profile JSON could not be parsed.");
            }

            if (string.IsNullOrWhiteSpace(document.adapterId))
            {
                throw new InvalidDataException("Replay profile JSON is missing adapterId.");
            }

            if (document.rules == null || document.rules.Count == 0)
            {
                throw new InvalidDataException("Replay profile JSON must include at least one rule.");
            }

            foreach (var rule in document.rules)
            {
                if (rule != null)
                {
                    ValidateRule(rule);
                }
            }

            return document;
        }

        public static string NormalizeUnityAssetPath(string assetPath)
        {
            if (string.IsNullOrWhiteSpace(assetPath))
            {
                throw new ArgumentException("Replay profile asset path is required.", "assetPath");
            }

            var normalized = assetPath.Replace("\\", "/");
            if (!normalized.StartsWith("Assets/", StringComparison.Ordinal) &&
                !string.Equals(normalized, "Assets", StringComparison.Ordinal))
            {
                throw new ArgumentException("Replay profile asset path must be under Assets/.", "assetPath");
            }

            if (!normalized.EndsWith(".asset", StringComparison.OrdinalIgnoreCase))
            {
                throw new ArgumentException("Replay profile asset path must end with .asset.", "assetPath");
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

        private static void ValidateRule(ActionReplayRuleJsonDocument rule)
        {
            if (rule == null)
            {
                throw new InvalidDataException("Replay profile rule is missing.");
            }

            if (!ActionWhitelist.IsAllowed(rule.action))
            {
                throw new InvalidDataException("Replay profile rule uses a non-whitelisted action: " + rule.action);
            }

            if (string.IsNullOrWhiteSpace(rule.handlerKey) && !rule.allowDefaultFallback)
            {
                throw new InvalidDataException(
                    "Replay profile rule must include handlerKey unless allowDefaultFallback is true.");
            }
        }
    }

    [Serializable]
    public sealed class ActionReplayProfileJsonDocument
    {
        public string adapterId;
        public List<ActionReplayRuleJsonDocument> rules;
    }

    [Serializable]
    public sealed class ActionReplayRuleJsonDocument
    {
        public string action;
        public string target;
        public string handlerKey;
        public string successMessage;
        public bool allowDefaultFallback;
    }
}
