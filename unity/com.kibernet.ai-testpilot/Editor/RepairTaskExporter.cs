using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using Kibernet.AITestPilot.Unity;
using UnityEngine;

namespace Kibernet.AITestPilot.Unity.Editor
{
    public static class RepairTaskExporter
    {
        public static RepairTaskDocument Build(
            BugPackage bug,
            string suggestedFix,
            ValidationRunReport sourceRun,
            ValidationRetestReport retestReport,
            string retestCommand)
        {
            if (bug == null)
            {
                throw new ArgumentNullException("bug");
            }

            if (sourceRun == null)
            {
                throw new ArgumentNullException("sourceRun");
            }

            var steps = bug.steps == null || bug.steps.Count == 0
                ? ExtractSteps(sourceRun)
                : new List<string>(bug.steps);

            return new RepairTaskDocument
            {
                taskId = "FIX-" + SafeId(bug.bugId),
                createdAtUtc = DateTime.UtcNow.ToString("O"),
                bugId = bug.bugId,
                bugType = bug.type,
                risk = bug.risk,
                scene = bug.scene,
                sourceRunId = sourceRun.runId,
                sourceGoal = sourceRun.goal,
                suggestedFix = string.IsNullOrWhiteSpace(suggestedFix)
                    ? "No prior fix hint found. Inspect the failing run and fix the root cause."
                    : suggestedFix,
                retestGoal = "retest_bug:" + bug.bugId,
                retestCommand = string.IsNullOrWhiteSpace(retestCommand)
                    ? ".\\tools\\Validate-UnityPackageImport.ps1"
                    : retestCommand,
                expectedRetestId = retestReport == null ? string.Empty : retestReport.retestId,
                reproductionSteps = steps,
                acceptanceCriteria = new List<string>
                {
                    "Reproduce or explain the recorded failure before changing code.",
                    "Apply the smallest fix that addresses the root cause.",
                    "Run the retest command and verify the original bug is absent.",
                    "Keep release evidence blocked until the retest report passes."
                },
                artifacts = new List<RepairTaskArtifact>
                {
                    new RepairTaskArtifact
                    {
                        kind = "run_report",
                        path = sourceRun.runId,
                        description = "Source AI run that detected the bug."
                    },
                    new RepairTaskArtifact
                    {
                        kind = "bug_package",
                        path = bug.bugId,
                        description = "Structured bug package generated from the failing run."
                    }
                }
            };
        }

        public static void Write(RepairTaskDocument task, string jsonPath, string markdownPath)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(jsonPath));
            Directory.CreateDirectory(Path.GetDirectoryName(markdownPath));
            File.WriteAllText(jsonPath, JsonUtility.ToJson(task, true), Encoding.UTF8);
            File.WriteAllText(markdownPath, ToMarkdown(task), Encoding.UTF8);
        }

        public static string ToMarkdown(RepairTaskDocument task)
        {
            var builder = new StringBuilder();
            builder.AppendLine("# AI TestPilot Repair Task");
            builder.AppendLine();
            builder.AppendLine("## Summary");
            builder.AppendLine("- TaskId: " + ValueOrUnknown(task == null ? null : task.taskId));
            builder.AppendLine("- BugId: " + ValueOrUnknown(task == null ? null : task.bugId));
            builder.AppendLine("- Type: " + ValueOrUnknown(task == null ? null : task.bugType));
            builder.AppendLine("- Risk: " + ValueOrUnknown(task == null ? null : task.risk));
            builder.AppendLine("- Scene: " + ValueOrUnknown(task == null ? null : task.scene));
            builder.AppendLine("- SourceRunId: " + ValueOrUnknown(task == null ? null : task.sourceRunId));
            builder.AppendLine();
            builder.AppendLine("## Suggested Fix");
            builder.AppendLine(ValueOrUnknown(task == null ? null : task.suggestedFix));
            builder.AppendLine();
            builder.AppendLine("## Reproduction Steps");

            if (task == null || task.reproductionSteps == null || task.reproductionSteps.Count == 0)
            {
                builder.AppendLine("No recorded steps. Use the source run report.");
            }
            else
            {
                for (var i = 0; i < task.reproductionSteps.Count; i++)
                {
                    builder.AppendLine((i + 1) + ". " + task.reproductionSteps[i]);
                }
            }

            builder.AppendLine();
            builder.AppendLine("## Retest");
            builder.AppendLine("- Goal: " + ValueOrUnknown(task == null ? null : task.retestGoal));
            builder.AppendLine("- Command: " + ValueOrUnknown(task == null ? null : task.retestCommand));
            builder.AppendLine("- ExpectedRetestId: " + ValueOrUnknown(task == null ? null : task.expectedRetestId));
            builder.AppendLine();
            builder.AppendLine("## Acceptance Criteria");

            if (task != null && task.acceptanceCriteria != null)
            {
                foreach (var criterion in task.acceptanceCriteria)
                {
                    builder.AppendLine("- " + criterion);
                }
            }

            return builder.ToString();
        }

        private static List<string> ExtractSteps(ValidationRunReport sourceRun)
        {
            var steps = new List<string>();
            if (sourceRun.steps == null)
            {
                return steps;
            }

            foreach (var step in sourceRun.steps)
            {
                if (step == null || string.Equals(step.action, ActionWhitelist.Finish, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                steps.Add(string.IsNullOrWhiteSpace(step.target) ? step.action : step.action + ":" + step.target);
            }

            return steps;
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
    public sealed class RepairTaskDocument
    {
        public string taskId;
        public string createdAtUtc;
        public string bugId;
        public string bugType;
        public string risk;
        public string scene;
        public string sourceRunId;
        public string sourceGoal;
        public string suggestedFix;
        public string retestGoal;
        public string retestCommand;
        public string expectedRetestId;
        public List<string> reproductionSteps;
        public List<string> acceptanceCriteria;
        public List<RepairTaskArtifact> artifacts;
    }

    [Serializable]
    public sealed class RepairTaskArtifact
    {
        public string kind;
        public string path;
        public string description;
    }
}
