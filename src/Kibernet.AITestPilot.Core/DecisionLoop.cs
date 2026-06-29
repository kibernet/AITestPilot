namespace Kibernet.AITestPilot.Core;

public sealed class DecisionLoop
{
    private readonly ISnapshotProvider snapshotProvider;
    private readonly IDecisionClient decisionClient;
    private readonly IActionExecutor actionExecutor;
    private readonly BugDetector bugDetector;
    private readonly DecisionLoopOptions options;

    public DecisionLoop(
        ISnapshotProvider snapshotProvider,
        IDecisionClient decisionClient,
        IActionExecutor actionExecutor,
        BugDetector? bugDetector = null,
        DecisionLoopOptions? options = null)
    {
        this.snapshotProvider = snapshotProvider;
        this.decisionClient = decisionClient;
        this.actionExecutor = actionExecutor;
        this.bugDetector = bugDetector ?? new BugDetector();
        this.options = options ?? new DecisionLoopOptions();
    }

    public async Task<DecisionLoopResult> RunAsync(string goal, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(goal))
        {
            throw new ArgumentException("A test goal is required.", nameof(goal));
        }

        var steps = new List<DecisionStep>();
        var executedStepNames = new List<string>();
        BugPackage? firstBug = null;
        string exitReason = "max_steps";

        for (var index = 0; index < options.MaxSteps; index++)
        {
            cancellationToken.ThrowIfCancellationRequested();

            var snapshot = await snapshotProvider.CaptureAsync(index, cancellationToken).ConfigureAwait(false);
            var bug = bugDetector.TryCreatePackage(snapshot, executedStepNames);
            firstBug ??= bug;

            if (bug is not null && options.StopOnBug)
            {
                steps.Add(new DecisionStep(index, snapshot, TestPilotAction.Finish(), bug));
                exitReason = "bug_detected";
                break;
            }

            var action = await decisionClient
                .DecideAsync(new DecisionRequest(goal, snapshot, executedStepNames, options.FixHints), cancellationToken)
                .ConfigureAwait(false);

            action.Validate();
            steps.Add(new DecisionStep(index, snapshot, action, bug));

            if (action.IsFinish)
            {
                exitReason = "finish";
                break;
            }

            await actionExecutor.ExecuteAsync(action, cancellationToken).ConfigureAwait(false);
            executedStepNames.Add(FormatStep(action));
        }

        return new DecisionLoopResult(exitReason, steps, firstBug);
    }

    private static string FormatStep(TestPilotAction action)
    {
        return string.IsNullOrWhiteSpace(action.Target)
            ? action.Action
            : $"{action.Action}:{action.Target}";
    }
}

public sealed class DecisionLoopOptions
{
    public int MaxSteps { get; init; } = 100;

    public bool StopOnBug { get; init; }

    public IReadOnlyList<string> FixHints { get; init; } = Array.Empty<string>();
}

public sealed class DecisionStep
{
    public DecisionStep(int index, Snapshot snapshot, TestPilotAction action, BugPackage? bug)
    {
        Index = index;
        Snapshot = snapshot;
        Action = action;
        Bug = bug;
    }

    public int Index { get; }

    public Snapshot Snapshot { get; }

    public TestPilotAction Action { get; }

    public BugPackage? Bug { get; }
}

public sealed class DecisionLoopResult
{
    public DecisionLoopResult(string exitReason, IReadOnlyList<DecisionStep> steps, BugPackage? firstBug)
    {
        ExitReason = exitReason;
        Steps = steps;
        FirstBug = firstBug;
    }

    public string ExitReason { get; }

    public IReadOnlyList<DecisionStep> Steps { get; }

    public BugPackage? FirstBug { get; }

    public bool Finished => string.Equals(ExitReason, "finish", StringComparison.OrdinalIgnoreCase);
}
