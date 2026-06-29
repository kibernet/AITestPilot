using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using UnityEngine;

namespace Kibernet.AITestPilot.Unity.Editor
{
    public static class RepairAgentRunExporter
    {
        public const string SchemaVersion = "aitestpilot.repair_agent_run.v1";

        public static RepairAgentRunDocument Build(RepairAgentHandoffDocument handoff)
        {
            if (handoff == null)
            {
                throw new ArgumentNullException("handoff");
            }

            return new RepairAgentRunDocument
            {
                schemaVersion = SchemaVersion,
                status = "AWAITING_EXTERNAL_AGENT",
                runId = "AGENT-RUN-" + SafeId(handoff.taskId),
                createdAtUtc = DateTime.UtcNow.ToString("O"),
                handoffId = handoff.handoffId,
                taskId = handoff.taskId,
                bugId = handoff.bugId,
                agentName = handoff.agentName,
                launchCommand = handoff.launchCommand,
                agentLaunched = false,
                externalAgentRequired = true,
                patchOutputStatus = "PENDING_EXTERNAL_AGENT",
                patchOutputCount = 0,
                postPatchRetestCommand = handoff.retestCommand,
                expectedPatchOutputs = new List<RepairAgentPatchOutput>
                {
                    new RepairAgentPatchOutput
                    {
                        kind = "patch",
                        path = "repair-agent.patch",
                        required = true,
                        produced = false,
                        description = "Unified diff or equivalent patch output from the repair agent."
                    },
                    new RepairAgentPatchOutput
                    {
                        kind = "summary",
                        path = "repair-agent-summary.md",
                        required = true,
                        produced = false,
                        description = "Human-readable repair summary from the repair agent."
                    }
                },
                nextRequiredActions = new List<string>
                {
                    "Launch the repair agent with the recorded launchCommand.",
                    "Store patch output as repair-agent.patch and summary as repair-agent-summary.md.",
                    "Apply or review the patch, then run the postPatchRetestCommand."
                }
            };
        }

        public static void Write(RepairAgentRunDocument run, string jsonPath, string markdownPath)
        {
            if (run == null)
            {
                throw new ArgumentNullException("run");
            }

            Directory.CreateDirectory(Path.GetDirectoryName(jsonPath));
            Directory.CreateDirectory(Path.GetDirectoryName(markdownPath));
            File.WriteAllText(jsonPath, JsonUtility.ToJson(run, true), Encoding.UTF8);
            File.WriteAllText(markdownPath, ToMarkdown(run), Encoding.UTF8);
        }

        public static string ToMarkdown(RepairAgentRunDocument run)
        {
            var builder = new StringBuilder();
            builder.AppendLine("# AI TestPilot Repair Agent Run");
            builder.AppendLine();
            builder.AppendLine("## Summary");
            builder.AppendLine("- SchemaVersion: " + ValueOrUnknown(run == null ? null : run.schemaVersion));
            builder.AppendLine("- Status: " + ValueOrUnknown(run == null ? null : run.status));
            builder.AppendLine("- RunId: " + ValueOrUnknown(run == null ? null : run.runId));
            builder.AppendLine("- HandoffId: " + ValueOrUnknown(run == null ? null : run.handoffId));
            builder.AppendLine("- TaskId: " + ValueOrUnknown(run == null ? null : run.taskId));
            builder.AppendLine("- BugId: " + ValueOrUnknown(run == null ? null : run.bugId));
            builder.AppendLine("- Agent: " + ValueOrUnknown(run == null ? null : run.agentName));
            builder.AppendLine("- LaunchCommand: " + ValueOrUnknown(run == null ? null : run.launchCommand));
            builder.AppendLine("- AgentLaunched: " + (run != null && run.agentLaunched));
            builder.AppendLine("- ExternalAgentRequired: " + (run != null && run.externalAgentRequired));
            builder.AppendLine("- PatchOutputStatus: " + ValueOrUnknown(run == null ? null : run.patchOutputStatus));
            builder.AppendLine("- PatchOutputCount: " + (run == null ? 0 : run.patchOutputCount));
            builder.AppendLine("- PostPatchRetestCommand: " + ValueOrUnknown(run == null ? null : run.postPatchRetestCommand));
            builder.AppendLine();
            builder.AppendLine("## Expected Patch Outputs");

            if (run == null || run.expectedPatchOutputs == null || run.expectedPatchOutputs.Count == 0)
            {
                builder.AppendLine("No patch outputs registered.");
            }
            else
            {
                foreach (var output in run.expectedPatchOutputs)
                {
                    builder.AppendLine(
                        "- " + ValueOrUnknown(output.kind) +
                        ": " + ValueOrUnknown(output.path) +
                        " required=" + output.required +
                        " produced=" + output.produced +
                        " - " + ValueOrUnknown(output.description));
                }
            }

            builder.AppendLine();
            builder.AppendLine("## Next Required Actions");

            if (run != null && run.nextRequiredActions != null)
            {
                foreach (var action in run.nextRequiredActions)
                {
                    builder.AppendLine("- " + action);
                }
            }

            return builder.ToString();
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
    public sealed class RepairAgentRunDocument
    {
        public string schemaVersion;
        public string status;
        public string runId;
        public string createdAtUtc;
        public string handoffId;
        public string taskId;
        public string bugId;
        public string agentName;
        public string launchCommand;
        public bool agentLaunched;
        public bool externalAgentRequired;
        public string patchOutputStatus;
        public int patchOutputCount;
        public string postPatchRetestCommand;
        public List<RepairAgentPatchOutput> expectedPatchOutputs;
        public List<string> nextRequiredActions;
    }

    [Serializable]
    public sealed class RepairAgentPatchOutput
    {
        public string kind;
        public string path;
        public bool required;
        public bool produced;
        public string description;
    }
}
