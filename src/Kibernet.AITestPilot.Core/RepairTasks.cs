namespace Kibernet.AITestPilot.Core;

public sealed class RepairTaskDocument
{
    public string TaskId { get; init; } = string.Empty;

    public DateTimeOffset CreatedAtUtc { get; init; }

    public string BugId { get; init; } = string.Empty;

    public string BugType { get; init; } = string.Empty;

    public BugRisk Risk { get; init; }

    public string Scene { get; init; } = string.Empty;

    public string SourceRunId { get; init; } = string.Empty;

    public string SourceGoal { get; init; } = string.Empty;

    public string SuggestedFix { get; init; } = string.Empty;

    public string RetestGoal { get; init; } = string.Empty;

    public string RetestCommand { get; init; } = string.Empty;

    public IReadOnlyList<string> ReproductionSteps { get; init; } = Array.Empty<string>();

    public IReadOnlyList<string> AcceptanceCriteria { get; init; } = Array.Empty<string>();

    public IReadOnlyList<RepairTaskArtifact> Artifacts { get; init; } = Array.Empty<RepairTaskArtifact>();
}

public sealed class RepairTaskArtifact
{
    public string Kind { get; init; } = string.Empty;

    public string Path { get; init; } = string.Empty;

    public string Description { get; init; } = string.Empty;
}

public static class RepairTaskFactory
{
    public static RepairTaskDocument Create(
        BugPackage bug,
        TestRunReport sourceRun,
        string? suggestedFix,
        string retestCommand,
        DateTimeOffset createdAtUtc,
        string? taskId = null)
    {
        if (bug is null)
        {
            throw new ArgumentNullException(nameof(bug));
        }

        if (sourceRun is null)
        {
            throw new ArgumentNullException(nameof(sourceRun));
        }

        if (string.IsNullOrWhiteSpace(sourceRun.RunId))
        {
            throw new ArgumentException("Source run must have a run id.", nameof(sourceRun));
        }

        var steps = bug.Steps.Count > 0
            ? bug.Steps
            : sourceRun.Steps
                .Where(step => !string.Equals(step.Action, ActionVerbs.Finish, StringComparison.OrdinalIgnoreCase))
                .Select(step => string.IsNullOrWhiteSpace(step.Target) ? step.Action : $"{step.Action}:{step.Target}")
                .ToArray();

        var normalizedSuggestedFix = string.IsNullOrWhiteSpace(suggestedFix)
            ? "No prior fix hint found. Inspect the failing run and fix the root cause."
            : suggestedFix;

        var normalizedRetestCommand = string.IsNullOrWhiteSpace(retestCommand)
            ? "Run the AI TestPilot retest command for this bug."
            : retestCommand;

        return new RepairTaskDocument
        {
            TaskId = string.IsNullOrWhiteSpace(taskId) ? CreateId("FIX") : taskId,
            CreatedAtUtc = createdAtUtc,
            BugId = bug.BugId,
            BugType = bug.Type,
            Risk = bug.Risk,
            Scene = bug.Scene,
            SourceRunId = sourceRun.RunId,
            SourceGoal = sourceRun.Goal,
            SuggestedFix = normalizedSuggestedFix,
            RetestGoal = $"retest_bug:{bug.BugId}",
            RetestCommand = normalizedRetestCommand,
            ReproductionSteps = steps.ToArray(),
            AcceptanceCriteria = new[]
            {
                "Reproduce or explain the recorded failure before changing code.",
                "Apply the smallest fix that addresses the root cause.",
                "Run the retest command and verify the original bug is absent.",
                "Keep release evidence blocked until the retest report passes.",
            },
            Artifacts = new[]
            {
                new RepairTaskArtifact
                {
                    Kind = "run_report",
                    Path = sourceRun.RunId,
                    Description = "Source AI run that detected the bug.",
                },
                new RepairTaskArtifact
                {
                    Kind = "bug_package",
                    Path = bug.BugId,
                    Description = "Structured bug package generated from the failing run.",
                },
            },
        };
    }

    public static string ToMarkdown(RepairTaskDocument task)
    {
        if (task is null)
        {
            throw new ArgumentNullException(nameof(task));
        }

        var lines = new List<string>
        {
            "# AI TestPilot Repair Task",
            string.Empty,
            "## Summary",
            $"- TaskId: {ValueOrUnknown(task.TaskId)}",
            $"- BugId: {ValueOrUnknown(task.BugId)}",
            $"- Type: {ValueOrUnknown(task.BugType)}",
            $"- Risk: {task.Risk}",
            $"- Scene: {ValueOrUnknown(task.Scene)}",
            $"- SourceRunId: {ValueOrUnknown(task.SourceRunId)}",
            string.Empty,
            "## Suggested Fix",
            ValueOrUnknown(task.SuggestedFix),
            string.Empty,
            "## Reproduction Steps",
        };

        if (task.ReproductionSteps.Count == 0)
        {
            lines.Add("No recorded steps. Use the source run report.");
        }
        else
        {
            for (var i = 0; i < task.ReproductionSteps.Count; i++)
            {
                lines.Add($"{i + 1}. {task.ReproductionSteps[i]}");
            }
        }

        lines.AddRange(new[]
        {
            string.Empty,
            "## Retest",
            $"- Goal: {ValueOrUnknown(task.RetestGoal)}",
            $"- Command: {ValueOrUnknown(task.RetestCommand)}",
            string.Empty,
            "## Acceptance Criteria",
        });

        foreach (var criterion in task.AcceptanceCriteria)
        {
            lines.Add("- " + criterion);
        }

        return string.Join(Environment.NewLine, lines) + Environment.NewLine;
    }

    private static string ValueOrUnknown(string? value)
    {
        return string.IsNullOrWhiteSpace(value) ? "Unknown" : value;
    }

    private static string CreateId(string prefix)
    {
        return $"{prefix}-{DateTimeOffset.UtcNow:yyyyMMddHHmmss}-{Guid.NewGuid():N}"[..(prefix.Length + 24)];
    }
}
