using System;
using System.IO;
using System.Text;
using Kibernet.AITestPilot.Unity;
using UnityEngine;

namespace Kibernet.AITestPilot.Unity.Editor
{
    public static class BugPackageExporter
    {
        public static void Write(BugPackage bug, string jsonPath, string markdownPath)
        {
            if (bug == null)
            {
                throw new ArgumentNullException("bug");
            }

            Directory.CreateDirectory(Path.GetDirectoryName(jsonPath));
            Directory.CreateDirectory(Path.GetDirectoryName(markdownPath));
            File.WriteAllText(jsonPath, JsonUtility.ToJson(bug, true), Encoding.UTF8);
            File.WriteAllText(markdownPath, ToMarkdown(bug), Encoding.UTF8);
        }

        public static string ToMarkdown(BugPackage bug)
        {
            var builder = new StringBuilder();
            builder.AppendLine("# AI TestPilot Bug Package");
            builder.AppendLine();
            builder.AppendLine("## Summary");
            builder.AppendLine("- BugId: " + ValueOrUnknown(bug == null ? null : bug.bugId));
            builder.AppendLine("- Type: " + ValueOrUnknown(bug == null ? null : bug.type));
            builder.AppendLine("- Risk: " + ValueOrUnknown(bug == null ? null : bug.risk));
            builder.AppendLine("- Scene: " + ValueOrUnknown(bug == null ? null : bug.scene));
            builder.AppendLine("- Module: " + ValueOrUnknown(bug == null ? null : bug.module));
            builder.AppendLine("- Function: " + ValueOrUnknown(bug == null ? null : bug.function));
            builder.AppendLine("- CreatedAtUtc: " + ValueOrUnknown(bug == null ? null : bug.createdAtUtc));
            builder.AppendLine();
            builder.AppendLine("## Reproduction Steps");

            if (bug == null || bug.steps == null || bug.steps.Count == 0)
            {
                builder.AppendLine("No recorded steps.");
            }
            else
            {
                for (var i = 0; i < bug.steps.Count; i++)
                {
                    builder.AppendLine((i + 1) + ". " + bug.steps[i]);
                }
            }

            builder.AppendLine();
            builder.AppendLine("## Log");
            builder.AppendLine(ValueOrUnknown(bug == null ? null : bug.log));
            builder.AppendLine();
            builder.AppendLine("## Stack Trace");
            builder.AppendLine(ValueOrUnknown(bug == null ? null : bug.stackTrace));
            return builder.ToString();
        }

        private static string ValueOrUnknown(string value)
        {
            return string.IsNullOrWhiteSpace(value) ? "Unknown" : value;
        }
    }
}
