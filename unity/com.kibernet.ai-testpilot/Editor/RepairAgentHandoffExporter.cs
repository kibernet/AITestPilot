using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using Kibernet.AITestPilot.Unity;
using UnityEngine;

namespace Kibernet.AITestPilot.Unity.Editor
{
    public static class RepairAgentHandoffExporter
    {
        public const string SchemaVersion = "aitestpilot.repair_agent_handoff.v1";

        public static RepairAgentHandoffDocument Build(
            RepairTaskDocument task,
            BugPackage bug,
            BugKnowledgeGraphDocument graph)
        {
            if (task == null)
            {
                throw new ArgumentNullException("task");
            }

            return new RepairAgentHandoffDocument
            {
                schemaVersion = SchemaVersion,
                status = "READY",
                handoffId = "HANDOFF-" + SafeId(task.taskId),
                createdAtUtc = DateTime.UtcNow.ToString("O"),
                agentName = "Cursor",
                launchCommand = "cursor repair-agent-handoff.md",
                primaryContextFile = "repair-agent-handoff.md",
                taskId = task.taskId,
                bugId = task.bugId,
                bugType = task.bugType,
                risk = task.risk,
                scene = task.scene,
                sourceRunId = task.sourceRunId,
                suggestedFix = task.suggestedFix,
                retestCommand = task.retestCommand,
                graphSchemaVersion = graph == null ? string.Empty : graph.schemaVersion,
                graphNodeCount = graph == null ? 0 : graph.nodeCount,
                bugPackageLog = bug == null ? string.Empty : bug.log,
                contextFiles = BuildContextFiles(),
                reproductionSteps = task.reproductionSteps == null
                    ? new List<string>()
                    : new List<string>(task.reproductionSteps),
                acceptanceCriteria = task.acceptanceCriteria == null
                    ? new List<string>()
                    : new List<string>(task.acceptanceCriteria)
            };
        }

        public static void Write(RepairAgentHandoffDocument handoff, string jsonPath, string markdownPath)
        {
            if (handoff == null)
            {
                throw new ArgumentNullException("handoff");
            }

            Directory.CreateDirectory(Path.GetDirectoryName(jsonPath));
            Directory.CreateDirectory(Path.GetDirectoryName(markdownPath));
            File.WriteAllText(jsonPath, JsonUtility.ToJson(handoff, true), Encoding.UTF8);
            File.WriteAllText(markdownPath, ToMarkdown(handoff), Encoding.UTF8);
        }

        public static string ToMarkdown(RepairAgentHandoffDocument handoff)
        {
            var builder = new StringBuilder();
            builder.AppendLine("# AI TestPilot Repair Agent Handoff");
            builder.AppendLine();
            builder.AppendLine("## Summary");
            builder.AppendLine("- SchemaVersion: " + ValueOrUnknown(handoff == null ? null : handoff.schemaVersion));
            builder.AppendLine("- Status: " + ValueOrUnknown(handoff == null ? null : handoff.status));
            builder.AppendLine("- Agent: " + ValueOrUnknown(handoff == null ? null : handoff.agentName));
            builder.AppendLine("- LaunchCommand: " + ValueOrUnknown(handoff == null ? null : handoff.launchCommand));
            builder.AppendLine("- TaskId: " + ValueOrUnknown(handoff == null ? null : handoff.taskId));
            builder.AppendLine("- BugId: " + ValueOrUnknown(handoff == null ? null : handoff.bugId));
            builder.AppendLine("- Type: " + ValueOrUnknown(handoff == null ? null : handoff.bugType));
            builder.AppendLine("- Risk: " + ValueOrUnknown(handoff == null ? null : handoff.risk));
            builder.AppendLine("- SourceRunId: " + ValueOrUnknown(handoff == null ? null : handoff.sourceRunId));
            builder.AppendLine("- RetestCommand: " + ValueOrUnknown(handoff == null ? null : handoff.retestCommand));
            builder.AppendLine();
            builder.AppendLine("## Context Files");

            if (handoff == null || handoff.contextFiles == null || handoff.contextFiles.Count == 0)
            {
                builder.AppendLine("No context files.");
            }
            else
            {
                foreach (var contextFile in handoff.contextFiles)
                {
                    builder.AppendLine(
                        "- " + ValueOrUnknown(contextFile.kind) +
                        ": " + ValueOrUnknown(contextFile.path) +
                        " - " + ValueOrUnknown(contextFile.description));
                }
            }

            builder.AppendLine();
            builder.AppendLine("## Suggested Fix");
            builder.AppendLine(ValueOrUnknown(handoff == null ? null : handoff.suggestedFix));
            builder.AppendLine();
            builder.AppendLine("## Reproduction Steps");

            if (handoff == null || handoff.reproductionSteps == null || handoff.reproductionSteps.Count == 0)
            {
                builder.AppendLine("No recorded steps.");
            }
            else
            {
                for (var i = 0; i < handoff.reproductionSteps.Count; i++)
                {
                    builder.AppendLine((i + 1) + ". " + handoff.reproductionSteps[i]);
                }
            }

            builder.AppendLine();
            builder.AppendLine("## Acceptance Criteria");

            if (handoff != null && handoff.acceptanceCriteria != null)
            {
                foreach (var criterion in handoff.acceptanceCriteria)
                {
                    builder.AppendLine("- " + criterion);
                }
            }

            return builder.ToString();
        }

        private static List<RepairAgentHandoffContextFile> BuildContextFiles()
        {
            return new List<RepairAgentHandoffContextFile>
            {
                new RepairAgentHandoffContextFile
                {
                    kind = "repair_task",
                    path = "repair-task.json",
                    required = true,
                    description = "Machine-readable repair task with retest command and acceptance criteria."
                },
                new RepairAgentHandoffContextFile
                {
                    kind = "repair_task_markdown",
                    path = "repair-task.md",
                    required = true,
                    description = "Agent-readable repair task summary."
                },
                new RepairAgentHandoffContextFile
                {
                    kind = "bug_package",
                    path = "bug-package.json",
                    required = true,
                    description = "Structured source bug package."
                },
                new RepairAgentHandoffContextFile
                {
                    kind = "bug_knowledge_graph",
                    path = "bug-knowledge-graph.json",
                    required = true,
                    description = "Prior fix hints and module risk ranking."
                },
                new RepairAgentHandoffContextFile
                {
                    kind = "scene_validation",
                    path = "scene-validation.json",
                    required = true,
                    description = "Full scene validation evidence for the failing and retest runs."
                }
            };
        }

        private static string SafeId(string value)
        {
            return string.IsNullOrWhiteSpace(value) ? "UNKNOWN" : value.Replace(":", "-").Replace("/", "-").Replace("\\", "-");
        }

        private static string ValueOrUnknown(string value)
        {
            return string.IsNullOrWhiteSpace(value) ? "Unknown" : value;
        }
    }

    [Serializable]
    public sealed class RepairAgentHandoffDocument
    {
        public string schemaVersion;
        public string status;
        public string handoffId;
        public string createdAtUtc;
        public string agentName;
        public string launchCommand;
        public string primaryContextFile;
        public string taskId;
        public string bugId;
        public string bugType;
        public string risk;
        public string scene;
        public string sourceRunId;
        public string suggestedFix;
        public string retestCommand;
        public string graphSchemaVersion;
        public int graphNodeCount;
        public string bugPackageLog;
        public List<RepairAgentHandoffContextFile> contextFiles;
        public List<string> reproductionSteps;
        public List<string> acceptanceCriteria;
    }

    [Serializable]
    public sealed class RepairAgentHandoffContextFile
    {
        public string kind;
        public string path;
        public bool required;
        public string description;
    }
}
