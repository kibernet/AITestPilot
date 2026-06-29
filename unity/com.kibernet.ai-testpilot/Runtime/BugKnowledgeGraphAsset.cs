using System;
using System.Collections.Generic;
using UnityEngine;

namespace Kibernet.AITestPilot.Unity
{
    [CreateAssetMenu(menuName = "Kibernet/AI TestPilot/Bug Knowledge Graph")]
    public sealed class BugKnowledgeGraphAsset : ScriptableObject
    {
        public List<BugNode> bugs = new List<BugNode>();

        public BugNode Record(BugPackage package, string module, string function, string fix)
        {
            var node = new BugNode
            {
                bugId = package == null ? string.Empty : package.bugId,
                type = package == null ? "RuntimeError" : package.type,
                scene = package == null ? string.Empty : package.scene,
                module = string.IsNullOrWhiteSpace(module) ? "Unknown" : module,
                function = string.IsNullOrWhiteSpace(function) ? "Unknown" : function,
                fix = fix,
                risk = package == null ? "MEDIUM" : package.risk,
                lastSeenAtUtc = DateTime.UtcNow.ToString("O")
            };

            bugs.Add(node);
            return node;
        }

        public string SuggestFix(BugPackage package)
        {
            if (package == null)
            {
                return null;
            }

            for (var i = bugs.Count - 1; i >= 0; i--)
            {
                var node = bugs[i];
                if (node != null &&
                    string.Equals(node.type, package.type, StringComparison.OrdinalIgnoreCase) &&
                    (string.IsNullOrWhiteSpace(package.module) ||
                     string.Equals(node.module, package.module, StringComparison.OrdinalIgnoreCase)))
                {
                    return node.fix;
                }
            }

            return null;
        }
    }

    [Serializable]
    public sealed class BugNode
    {
        public string bugId;
        public string type;
        public string scene;
        public string module;
        public string function;
        public string fix;
        public string risk;
        public string lastSeenAtUtc;
    }
}
