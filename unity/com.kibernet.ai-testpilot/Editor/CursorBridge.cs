using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using Kibernet.AITestPilot.Unity;
using UnityEditor;
using Debug = UnityEngine.Debug;

namespace Kibernet.AITestPilot.Unity.Editor
{
    public static class CursorBridge
    {
        public static string WriteBugPrompt(BugPackage bug, string suggestedFix)
        {
            var root = Path.GetFullPath(Path.Combine(UnityEngine.Application.dataPath, ".."));
            var path = Path.Combine(root, "bug_fix.md");
            File.WriteAllText(path, BuildPrompt(bug, suggestedFix), Encoding.UTF8);
            AssetDatabase.Refresh();
            return path;
        }

        public static string WriteRepairTask(RepairTaskDocument task)
        {
            var root = Path.GetFullPath(Path.Combine(UnityEngine.Application.dataPath, ".."));
            var path = Path.Combine(root, "bug_fix.md");
            File.WriteAllText(path, RepairTaskExporter.ToMarkdown(task), Encoding.UTF8);
            AssetDatabase.Refresh();
            return path;
        }

        public static bool TryOpenCursor(string filePath)
        {
            try
            {
                var startInfo = new ProcessStartInfo
                {
                    FileName = "cursor",
                    Arguments = "\"" + filePath + "\"",
                    UseShellExecute = true
                };

                Process.Start(startInfo);
                return true;
            }
            catch (Exception ex)
            {
                Debug.LogWarning("AI TestPilot could not launch Cursor: " + ex.Message);
                return false;
            }
        }

        private static string BuildPrompt(BugPackage bug, string suggestedFix)
        {
            var builder = new StringBuilder();
            builder.AppendLine("# AI TestPilot Bug Fix Request");
            builder.AppendLine();
            builder.AppendLine("## Bug Package");
            builder.AppendLine("- BugId: " + ValueOrUnknown(bug == null ? null : bug.bugId));
            builder.AppendLine("- Type: " + ValueOrUnknown(bug == null ? null : bug.type));
            builder.AppendLine("- Scene: " + ValueOrUnknown(bug == null ? null : bug.scene));
            builder.AppendLine("- Risk: " + ValueOrUnknown(bug == null ? null : bug.risk));
            builder.AppendLine();
            builder.AppendLine("## Log");
            builder.AppendLine("```");
            builder.AppendLine(ValueOrUnknown(bug == null ? null : bug.log));
            builder.AppendLine("```");
            builder.AppendLine();
            builder.AppendLine("## Stack Trace");
            builder.AppendLine("```");
            builder.AppendLine(ValueOrUnknown(bug == null ? null : bug.stackTrace));
            builder.AppendLine("```");
            builder.AppendLine();
            builder.AppendLine("## Steps");
            if (bug != null && bug.steps != null && bug.steps.Count > 0)
            {
                for (var i = 0; i < bug.steps.Count; i++)
                {
                    builder.AppendLine((i + 1) + ". " + bug.steps[i]);
                }
            }
            else
            {
                builder.AppendLine("No steps captured.");
            }

            builder.AppendLine();
            builder.AppendLine("## Reused Fix Hint");
            builder.AppendLine(string.IsNullOrWhiteSpace(suggestedFix) ? "No prior fix found." : suggestedFix);
            builder.AppendLine();
            builder.AppendLine("## Request");
            builder.AppendLine("Fix the root cause, keep the change minimal, and preserve existing gameplay behavior. After fixing, run the relevant Unity smoke test or reproduce the recorded steps.");
            return builder.ToString();
        }

        private static string ValueOrUnknown(string value)
        {
            return string.IsNullOrWhiteSpace(value) ? "Unknown" : value;
        }
    }
}
