namespace Kibernet.AITestPilot.Core;

public sealed class StaticSnapshotProvider : ISnapshotProvider
{
    private readonly Func<int, Snapshot> capture;

    public StaticSnapshotProvider(Func<int, Snapshot> capture)
    {
        this.capture = capture;
    }

    public ValueTask<Snapshot> CaptureAsync(int stepIndex, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return ValueTask.FromResult(capture(stepIndex));
    }
}

public sealed class ScriptedDecisionClient : IDecisionClient
{
    private readonly Queue<TestPilotAction> actions;

    public ScriptedDecisionClient(IEnumerable<TestPilotAction> actions)
    {
        this.actions = new Queue<TestPilotAction>(actions);
    }

    public ValueTask<TestPilotAction> DecideAsync(DecisionRequest request, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return ValueTask.FromResult(actions.Count == 0 ? TestPilotAction.Finish() : actions.Dequeue());
    }
}

public sealed class RecordingActionExecutor : IActionExecutor
{
    private readonly List<TestPilotAction> actions = new();

    public IReadOnlyList<TestPilotAction> Actions => actions;

    public ValueTask ExecuteAsync(TestPilotAction action, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        actions.Add(action);
        return ValueTask.CompletedTask;
    }
}

public sealed class DelegatedReleaseCheck : IReleaseCheck
{
    private readonly Func<CancellationToken, ValueTask<ReleaseCheckResult>> run;

    public DelegatedReleaseCheck(string name, Func<CancellationToken, ValueTask<ReleaseCheckResult>> run)
    {
        Name = name;
        this.run = run;
    }

    public string Name { get; }

    public ValueTask<ReleaseCheckResult> RunAsync(CancellationToken cancellationToken)
    {
        return run(cancellationToken);
    }
}
