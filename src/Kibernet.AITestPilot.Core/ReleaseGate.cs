namespace Kibernet.AITestPilot.Core;

public interface IReleaseCheck
{
    string Name { get; }

    ValueTask<ReleaseCheckResult> RunAsync(CancellationToken cancellationToken);
}

public sealed class ReleaseGate
{
    private readonly IReadOnlyList<IReleaseCheck> checks;

    public ReleaseGate(IEnumerable<IReleaseCheck> checks)
    {
        this.checks = checks.ToArray();
    }

    public async Task<ReleaseGateResult> RunAsync(CancellationToken cancellationToken = default)
    {
        var results = new List<ReleaseCheckResult>();

        foreach (var check in checks)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var result = await check.RunAsync(cancellationToken).ConfigureAwait(false);
            results.Add(result);
        }

        return new ReleaseGateResult(results);
    }
}

public sealed class ReleaseGateResult
{
    public ReleaseGateResult(IReadOnlyList<ReleaseCheckResult> checks)
    {
        Checks = checks;
    }

    public IReadOnlyList<ReleaseCheckResult> Checks { get; }

    public bool AllowRelease => Checks.Count > 0 && Checks.All(check => check.Passed);

    public IReadOnlyList<string> FailedCheckNames => Checks
        .Where(check => !check.Passed)
        .Select(check => check.Name)
        .ToArray();
}

public sealed class ReleaseCheckResult
{
    private ReleaseCheckResult(string name, bool passed, string message)
    {
        Name = name;
        Passed = passed;
        Message = message;
    }

    public string Name { get; }

    public bool Passed { get; }

    public string Message { get; }

    public static ReleaseCheckResult Pass(string name, string message = "")
    {
        return new ReleaseCheckResult(name, true, message);
    }

    public static ReleaseCheckResult Fail(string name, string message)
    {
        return new ReleaseCheckResult(name, false, message);
    }
}
