namespace Kibernet.AITestPilot.Core;

public sealed class Snapshot
{
    public string Scene { get; init; } = string.Empty;

    public IReadOnlyList<UiElementSnapshot> Ui { get; init; } = Array.Empty<UiElementSnapshot>();

    public GameStateSnapshot GameState { get; init; } = GameStateSnapshot.Empty;

    public IReadOnlyList<LogEntry> Logs { get; init; } = Array.Empty<LogEntry>();

    public int StepIndex { get; init; }

    public DateTimeOffset CapturedAtUtc { get; init; } = DateTimeOffset.UtcNow;
}

public sealed class UiElementSnapshot
{
    public string AutomationId { get; init; } = string.Empty;

    public string Name { get; init; } = string.Empty;

    public string Kind { get; init; } = string.Empty;

    public bool Interactable { get; init; } = true;
}

public sealed class GameStateSnapshot
{
    public static GameStateSnapshot Empty { get; } = new();

    public Dictionary<string, string> Values { get; init; } = new(StringComparer.OrdinalIgnoreCase);

    public string? Get(string key)
    {
        return Values.TryGetValue(key, out var value) ? value : null;
    }
}

public enum LogSeverity
{
    Info,
    Warning,
    Error,
    Exception,
}

public sealed class LogEntry
{
    public LogSeverity Severity { get; init; } = LogSeverity.Info;

    public string Message { get; init; } = string.Empty;

    public string? StackTrace { get; init; }

    public DateTimeOffset TimestampUtc { get; init; } = DateTimeOffset.UtcNow;
}
