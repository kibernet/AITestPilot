using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using Kibernet.AITestPilot.Unity;
using UnityEngine;

namespace Kibernet.AITestPilot.Unity.Editor
{
    public static class BugKnowledgeGraphExporter
    {
        public const string SchemaVersion = "aitestpilot.bug_knowledge_graph.v1";

        public static BugKnowledgeGraphDocument Build(BugKnowledgeGraphAsset graph)
        {
            var nodes = new List<BugNode>();
            if (graph != null && graph.bugs != null)
            {
                foreach (var node in graph.bugs)
                {
                    if (node != null)
                    {
                        nodes.Add(node);
                    }
                }
            }

            return new BugKnowledgeGraphDocument
            {
                schemaVersion = SchemaVersion,
                createdAtUtc = DateTime.UtcNow.ToString("O"),
                nodeCount = nodes.Count,
                highRiskCount = CountHighRisk(nodes),
                moduleRisks = BuildModuleRisks(nodes),
                moduleFailureTypeRisks = BuildModuleFailureTypeRisks(nodes),
                nodes = nodes
            };
        }

        public static void Write(BugKnowledgeGraphDocument graph, string jsonPath, string markdownPath)
        {
            if (graph == null)
            {
                throw new ArgumentNullException("graph");
            }

            Directory.CreateDirectory(Path.GetDirectoryName(jsonPath));
            Directory.CreateDirectory(Path.GetDirectoryName(markdownPath));
            File.WriteAllText(jsonPath, JsonUtility.ToJson(graph, true), Encoding.UTF8);
            File.WriteAllText(markdownPath, ToMarkdown(graph), Encoding.UTF8);
        }

        public static string ToMarkdown(BugKnowledgeGraphDocument graph)
        {
            var builder = new StringBuilder();
            builder.AppendLine("# AI TestPilot Bug Knowledge Graph");
            builder.AppendLine();
            builder.AppendLine("## Summary");
            builder.AppendLine("- SchemaVersion: " + ValueOrUnknown(graph == null ? null : graph.schemaVersion));
            builder.AppendLine("- NodeCount: " + (graph == null ? 0 : graph.nodeCount));
            builder.AppendLine("- HighRiskCount: " + (graph == null ? 0 : graph.highRiskCount));
            builder.AppendLine("- CreatedAtUtc: " + ValueOrUnknown(graph == null ? null : graph.createdAtUtc));
            builder.AppendLine();
            builder.AppendLine("## Module Risk Summary");

            if (graph == null || graph.moduleRisks == null || graph.moduleRisks.Count == 0)
            {
                builder.AppendLine("No module risk data.");
            }
            else
            {
                foreach (var moduleRisk in graph.moduleRisks)
                {
                    builder.AppendLine(
                        "- " + ValueOrUnknown(moduleRisk.module) +
                        ": bugs=" + moduleRisk.bugCount +
                        ", highRisk=" + moduleRisk.highRiskCount +
                        ", score=" + moduleRisk.score);
                }
            }

            builder.AppendLine();
            builder.AppendLine("## Module Failure Type Risk Summary");

            if (graph == null || graph.moduleFailureTypeRisks == null || graph.moduleFailureTypeRisks.Count == 0)
            {
                builder.AppendLine("No module failure type risk data.");
            }
            else
            {
                foreach (var risk in graph.moduleFailureTypeRisks)
                {
                    builder.AppendLine(
                        "- " + ValueOrUnknown(risk.module) +
                        " / " + ValueOrUnknown(risk.type) +
                        ": bugs=" + risk.bugCount +
                        ", highRisk=" + risk.highRiskCount +
                        ", score=" + risk.score);
                }
            }

            builder.AppendLine();
            builder.AppendLine("## Nodes");

            if (graph == null || graph.nodes == null || graph.nodes.Count == 0)
            {
                builder.AppendLine("No bug nodes.");
            }
            else
            {
                foreach (var node in graph.nodes)
                {
                    builder.AppendLine("- " + ValueOrUnknown(node.bugId) +
                        " | " + ValueOrUnknown(node.type) +
                        " | " + ValueOrUnknown(node.risk) +
                        " | " + ValueOrUnknown(node.module) +
                        "." + ValueOrUnknown(node.function) +
                        " | fix=" + ValueOrUnknown(node.fix));
                }
            }

            return builder.ToString();
        }

        private static List<BugKnowledgeGraphModuleRisk> BuildModuleRisks(List<BugNode> nodes)
        {
            var summaries = new List<BugKnowledgeGraphModuleRisk>();
            foreach (var node in nodes)
            {
                var module = string.IsNullOrWhiteSpace(node.module) ? "Unknown" : node.module;
                var summary = FindModuleSummary(summaries, module);
                if (summary == null)
                {
                    summary = new BugKnowledgeGraphModuleRisk
                    {
                        module = module,
                        bugCount = 0,
                        highRiskCount = 0,
                        score = 0
                    };
                    summaries.Add(summary);
                }

                summary.bugCount++;
                if (IsHighRisk(node.risk))
                {
                    summary.highRiskCount++;
                }

                summary.score += ScoreRisk(node.risk);
            }

            summaries.Sort((left, right) =>
            {
                var scoreCompare = right.score.CompareTo(left.score);
                if (scoreCompare != 0)
                {
                    return scoreCompare;
                }

                return string.Compare(left.module, right.module, StringComparison.OrdinalIgnoreCase);
            });
            return summaries;
        }

        private static List<BugKnowledgeGraphModuleFailureTypeRisk> BuildModuleFailureTypeRisks(List<BugNode> nodes)
        {
            var summaries = new List<BugKnowledgeGraphModuleFailureTypeRisk>();
            foreach (var node in nodes)
            {
                var module = string.IsNullOrWhiteSpace(node.module) ? "Unknown" : node.module;
                var type = string.IsNullOrWhiteSpace(node.type) ? "RuntimeError" : node.type;
                var summary = FindModuleFailureTypeSummary(summaries, module, type);
                if (summary == null)
                {
                    summary = new BugKnowledgeGraphModuleFailureTypeRisk
                    {
                        module = module,
                        type = type,
                        bugCount = 0,
                        highRiskCount = 0,
                        score = 0
                    };
                    summaries.Add(summary);
                }

                summary.bugCount++;
                if (IsHighRisk(node.risk))
                {
                    summary.highRiskCount++;
                }

                summary.score += ScoreRisk(node.risk);
            }

            summaries.Sort((left, right) =>
            {
                var scoreCompare = right.score.CompareTo(left.score);
                if (scoreCompare != 0)
                {
                    return scoreCompare;
                }

                var moduleCompare = string.Compare(left.module, right.module, StringComparison.OrdinalIgnoreCase);
                if (moduleCompare != 0)
                {
                    return moduleCompare;
                }

                return string.Compare(left.type, right.type, StringComparison.OrdinalIgnoreCase);
            });
            return summaries;
        }

        private static BugKnowledgeGraphModuleRisk FindModuleSummary(
            List<BugKnowledgeGraphModuleRisk> summaries,
            string module)
        {
            foreach (var summary in summaries)
            {
                if (summary != null &&
                    string.Equals(summary.module, module, StringComparison.OrdinalIgnoreCase))
                {
                    return summary;
                }
            }

            return null;
        }

        private static BugKnowledgeGraphModuleFailureTypeRisk FindModuleFailureTypeSummary(
            List<BugKnowledgeGraphModuleFailureTypeRisk> summaries,
            string module,
            string type)
        {
            foreach (var summary in summaries)
            {
                if (summary != null &&
                    string.Equals(summary.module, module, StringComparison.OrdinalIgnoreCase) &&
                    string.Equals(summary.type, type, StringComparison.OrdinalIgnoreCase))
                {
                    return summary;
                }
            }

            return null;
        }

        private static int CountHighRisk(List<BugNode> nodes)
        {
            var count = 0;
            foreach (var node in nodes)
            {
                if (IsHighRisk(node.risk))
                {
                    count++;
                }
            }

            return count;
        }

        private static bool IsHighRisk(string risk)
        {
            return string.Equals(risk, "HIGH", StringComparison.OrdinalIgnoreCase) ||
                   string.Equals(risk, "High", StringComparison.OrdinalIgnoreCase);
        }

        private static int ScoreRisk(string risk)
        {
            if (IsHighRisk(risk))
            {
                return 5;
            }

            if (string.Equals(risk, "MEDIUM", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(risk, "Medium", StringComparison.OrdinalIgnoreCase))
            {
                return 2;
            }

            return 1;
        }

        private static string ValueOrUnknown(string value)
        {
            return string.IsNullOrWhiteSpace(value) ? "Unknown" : value;
        }
    }

    [Serializable]
    public sealed class BugKnowledgeGraphDocument
    {
        public string schemaVersion;
        public string createdAtUtc;
        public int nodeCount;
        public int highRiskCount;
        public List<BugKnowledgeGraphModuleRisk> moduleRisks;
        public List<BugKnowledgeGraphModuleFailureTypeRisk> moduleFailureTypeRisks;
        public List<BugNode> nodes;
    }

    [Serializable]
    public sealed class BugKnowledgeGraphModuleRisk
    {
        public string module;
        public int bugCount;
        public int highRiskCount;
        public int score;
    }

    [Serializable]
    public sealed class BugKnowledgeGraphModuleFailureTypeRisk
    {
        public string module;
        public string type;
        public int bugCount;
        public int highRiskCount;
        public int score;
    }
}
