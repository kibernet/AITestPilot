namespace Kibernet.AITestPilot.Core;

public interface ISnapshotProvider
{
    ValueTask<Snapshot> CaptureAsync(int stepIndex, CancellationToken cancellationToken);
}

public interface IDecisionClient
{
    ValueTask<TestPilotAction> DecideAsync(DecisionRequest request, CancellationToken cancellationToken);
}

public interface IActionExecutor
{
    ValueTask ExecuteAsync(TestPilotAction action, CancellationToken cancellationToken);
}

public sealed class DecisionRequest
{
    public DecisionRequest(
        string goal,
        Snapshot snapshot,
        IReadOnlyList<string> previousSteps,
        IReadOnlyList<string>? fixHints = null)
    {
        Goal = goal;
        Snapshot = snapshot;
        PreviousSteps = previousSteps;
        FixHints = fixHints ?? Array.Empty<string>();
    }

    public string Goal { get; }

    public Snapshot Snapshot { get; }

    public IReadOnlyList<string> PreviousSteps { get; }

    public IReadOnlyList<string> FixHints { get; }
}
