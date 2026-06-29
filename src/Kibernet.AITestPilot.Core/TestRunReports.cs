namespace Kibernet.AITestPilot.Core;

public enum TestRunOutcome
{
    Passed,
    BugDetected,
    MaxStepsReached,
    Failed,
}

public sealed class TestRunReport
{
    public string RunId { get; init; } = string.Empty;

    public string Goal { get; init; } = string.Empty;

    public DateTimeOffset StartedAtUtc { get; init; }

    public DateTimeOffset FinishedAtUtc { get; init; }

    public string ExitReason { get; init; } = string.Empty;

    public TestRunOutcome Outcome { get; init; }

    public IReadOnlyList<TestRunStepReport> Steps { get; init; } = Array.Empty<TestRunStepReport>();

    public IReadOnlyList<BugPackage> Bugs { get; init; } = Array.Empty<BugPackage>();

    public TestRunMetrics Metrics { get; init; } = new();

    public bool HasHighRiskBug => Bugs.Any(bug => bug.Risk == BugRisk.High);
}

public sealed class TestRunStepReport
{
    public int Index { get; init; }

    public string Scene { get; init; } = string.Empty;

    public string Action { get; init; } = string.Empty;

    public string? Target { get; init; }

    public int UiElementCount { get; init; }

    public int LogCount { get; init; }

    public string? BugId { get; init; }
}

public sealed class TestRunMetrics
{
    public int StepCount { get; init; }

    public int ActionCount { get; init; }

    public int BugCount { get; init; }

    public int ErrorLogCount { get; init; }
}

public sealed class RetestReport
{
    public string RetestId { get; init; } = string.Empty;

    public string BugId { get; init; } = string.Empty;

    public string BugType { get; init; } = string.Empty;

    public string BeforeRunId { get; init; } = string.Empty;

    public string AfterRunId { get; init; } = string.Empty;

    public bool Passed { get; init; }

    public string Result { get; init; } = string.Empty;

    public DateTimeOffset VerifiedAtUtc { get; init; }
}

public sealed class ReleaseEvidenceDocument
{
    public string BuildVersion { get; init; } = string.Empty;

    public DateTimeOffset CreatedAtUtc { get; init; }

    public IReadOnlyList<TestRunReport> TestRuns { get; init; } = Array.Empty<TestRunReport>();

    public IReadOnlyList<RetestReport> Retests { get; init; } = Array.Empty<RetestReport>();

    public IReadOnlyList<ReleaseCheckEvidence> Checks { get; init; } = Array.Empty<ReleaseCheckEvidence>();

    public int UnverifiedHighRiskBugCount { get; init; }

    public bool AllowRelease { get; init; }

    public IReadOnlyList<string> FailedReasons { get; init; } = Array.Empty<string>();
}

public sealed class ReleaseCheckEvidence
{
    public string Name { get; init; } = string.Empty;

    public bool Passed { get; init; }

    public string Message { get; init; } = string.Empty;
}

public static class TestRunReportFactory
{
    public static TestRunReport FromDecisionLoopResult(
        string goal,
        DecisionLoopResult result,
        DateTimeOffset startedAtUtc,
        DateTimeOffset finishedAtUtc,
        string? runId = null)
    {
        var bugs = result.Steps
            .Select(step => step.Bug)
            .Where(bug => bug is not null)
            .Cast<BugPackage>()
            .GroupBy(bug => bug.BugId, StringComparer.OrdinalIgnoreCase)
            .Select(group => group.First())
            .ToArray();

        if (bugs.Length == 0 && result.FirstBug is not null)
        {
            bugs = new[] { result.FirstBug };
        }

        var steps = result.Steps
            .Select(step => new TestRunStepReport
            {
                Index = step.Index,
                Scene = step.Snapshot.Scene,
                Action = step.Action.Action,
                Target = step.Action.Target,
                UiElementCount = step.Snapshot.Ui.Count,
                LogCount = step.Snapshot.Logs.Count,
                BugId = step.Bug?.BugId,
            })
            .ToArray();

        return new TestRunReport
        {
            RunId = string.IsNullOrWhiteSpace(runId) ? CreateId("RUN") : runId,
            Goal = goal,
            StartedAtUtc = startedAtUtc,
            FinishedAtUtc = finishedAtUtc,
            ExitReason = result.ExitReason,
            Outcome = ResolveOutcome(result, bugs),
            Steps = steps,
            Bugs = bugs,
            Metrics = new TestRunMetrics
            {
                StepCount = steps.Length,
                ActionCount = steps.Count(step => !string.Equals(step.Action, ActionVerbs.Finish, StringComparison.OrdinalIgnoreCase)),
                BugCount = bugs.Length,
                ErrorLogCount = result.Steps.Sum(step => step.Snapshot.Logs.Count(IsErrorLog)),
            },
        };
    }

    public static RetestReport BuildRetestReport(
        BugPackage originalBug,
        TestRunReport beforeRun,
        TestRunReport afterRun,
        DateTimeOffset verifiedAtUtc,
        string? retestId = null)
    {
        var bugStillPresent = afterRun.Bugs.Any(bug =>
            string.Equals(bug.BugId, originalBug.BugId, StringComparison.OrdinalIgnoreCase) ||
            (string.Equals(bug.Type, originalBug.Type, StringComparison.OrdinalIgnoreCase) &&
             string.Equals(bug.Scene, originalBug.Scene, StringComparison.OrdinalIgnoreCase)));

        var passed = !bugStillPresent && afterRun.Outcome == TestRunOutcome.Passed;
        return new RetestReport
        {
            RetestId = string.IsNullOrWhiteSpace(retestId) ? CreateId("RETEST") : retestId,
            BugId = originalBug.BugId,
            BugType = originalBug.Type,
            BeforeRunId = beforeRun.RunId,
            AfterRunId = afterRun.RunId,
            Passed = passed,
            Result = passed ? "passed" : "failed",
            VerifiedAtUtc = verifiedAtUtc,
        };
    }

    public static ReleaseEvidenceDocument BuildReleaseEvidence(
        string buildVersion,
        IEnumerable<TestRunReport> testRuns,
        IEnumerable<RetestReport> retests,
        ReleaseGateResult gateResult,
        DateTimeOffset createdAtUtc)
    {
        var runArray = testRuns.ToArray();
        var retestArray = retests.ToArray();
        var passedRetestBugIds = retestArray
            .Where(retest => retest.Passed)
            .Select(retest => retest.BugId)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);

        var unverifiedHighRiskBugCount = runArray
            .SelectMany(run => run.Bugs)
            .Where(bug => bug.Risk == BugRisk.High)
            .Count(bug => !passedRetestBugIds.Contains(bug.BugId));

        var failedReasons = new List<string>();
        if (!gateResult.AllowRelease)
        {
            failedReasons.AddRange(gateResult.FailedCheckNames.Select(name => $"release_check_failed:{name}"));
        }

        if (unverifiedHighRiskBugCount > 0)
        {
            failedReasons.Add($"unverified_high_risk_bugs:{unverifiedHighRiskBugCount}");
        }

        var failedRetests = retestArray.Count(retest => !retest.Passed);
        if (failedRetests > 0)
        {
            failedReasons.Add($"failed_retests:{failedRetests}");
        }

        var incompleteRuns = runArray.Count(run =>
            run.Outcome is TestRunOutcome.Failed or TestRunOutcome.MaxStepsReached);
        if (incompleteRuns > 0)
        {
            failedReasons.Add($"incomplete_runs:{incompleteRuns}");
        }

        return new ReleaseEvidenceDocument
        {
            BuildVersion = buildVersion,
            CreatedAtUtc = createdAtUtc,
            TestRuns = runArray,
            Retests = retestArray,
            Checks = gateResult.Checks
                .Select(check => new ReleaseCheckEvidence
                {
                    Name = check.Name,
                    Passed = check.Passed,
                    Message = check.Message,
                })
                .ToArray(),
            UnverifiedHighRiskBugCount = unverifiedHighRiskBugCount,
            AllowRelease = failedReasons.Count == 0,
            FailedReasons = failedReasons,
        };
    }

    private static TestRunOutcome ResolveOutcome(DecisionLoopResult result, IReadOnlyList<BugPackage> bugs)
    {
        if (bugs.Count > 0 || string.Equals(result.ExitReason, "bug_detected", StringComparison.OrdinalIgnoreCase))
        {
            return TestRunOutcome.BugDetected;
        }

        if (result.Finished)
        {
            return TestRunOutcome.Passed;
        }

        if (string.Equals(result.ExitReason, "max_steps", StringComparison.OrdinalIgnoreCase))
        {
            return TestRunOutcome.MaxStepsReached;
        }

        return TestRunOutcome.Failed;
    }

    private static bool IsErrorLog(LogEntry log)
    {
        return log.Severity is LogSeverity.Error or LogSeverity.Exception;
    }

    private static string CreateId(string prefix)
    {
        return $"{prefix}-{DateTimeOffset.UtcNow:yyyyMMddHHmmss}-{Guid.NewGuid():N}"[..(prefix.Length + 24)];
    }
}
