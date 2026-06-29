namespace Kibernet.AITestPilot.Core;

public enum BugRisk
{
    Low,
    Medium,
    High,
}

public sealed class BugPackage
{
    public string BugId { get; init; } = string.Empty;

    public string Type { get; init; } = "RuntimeError";

    public string Scene { get; init; } = string.Empty;

    public string Log { get; init; } = string.Empty;

    public string? StackTrace { get; init; }

    public IReadOnlyList<string> Steps { get; init; } = Array.Empty<string>();

    public BugRisk Risk { get; init; } = BugRisk.Medium;

    public string? Module { get; init; }

    public string? Function { get; init; }

    public DateTimeOffset CreatedAtUtc { get; init; } = DateTimeOffset.UtcNow;
}
