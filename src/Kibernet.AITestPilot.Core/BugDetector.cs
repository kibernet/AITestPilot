namespace Kibernet.AITestPilot.Core;

public sealed class BugDetector
{
    private static readonly string[] ErrorTokens =
    {
        "Exception",
        "Error",
        "Assert",
        "Crash",
    };

    public bool HasBug(IEnumerable<LogEntry> logs)
    {
        return logs.Any(IsBugLog);
    }

    public BugPackage? TryCreatePackage(Snapshot snapshot, IReadOnlyList<string> steps)
    {
        var log = snapshot.Logs.FirstOrDefault(IsBugLog);
        if (log is null)
        {
            return null;
        }

        return new BugPackage
        {
            BugId = BugIdFactory.Create(snapshot.Scene, log.Message),
            Scene = snapshot.Scene,
            Log = log.Message,
            StackTrace = log.StackTrace,
            Steps = steps.ToArray(),
            Type = Classify(log.Message),
            Risk = ClassifyRisk(log),
            CreatedAtUtc = DateTimeOffset.UtcNow,
        };
    }

    private static bool IsBugLog(LogEntry log)
    {
        if (log.Severity is LogSeverity.Error or LogSeverity.Exception)
        {
            return true;
        }

        return ErrorTokens.Any(token => log.Message.Contains(token, StringComparison.OrdinalIgnoreCase));
    }

    private static string Classify(string message)
    {
        if (message.Contains("NullReferenceException", StringComparison.OrdinalIgnoreCase))
        {
            return "NullReference";
        }

        if (message.Contains("Lua", StringComparison.OrdinalIgnoreCase))
        {
            return "LuaRuntime";
        }

        if (message.Contains("MissingReferenceException", StringComparison.OrdinalIgnoreCase))
        {
            return "MissingReference";
        }

        return "RuntimeError";
    }

    private static BugRisk ClassifyRisk(LogEntry log)
    {
        if (log.Severity == LogSeverity.Exception ||
            log.Message.Contains("NullReferenceException", StringComparison.OrdinalIgnoreCase) ||
            log.Message.Contains("Crash", StringComparison.OrdinalIgnoreCase))
        {
            return BugRisk.High;
        }

        if (log.Severity == LogSeverity.Error)
        {
            return BugRisk.Medium;
        }

        return BugRisk.Low;
    }
}

internal static class BugIdFactory
{
    public static string Create(string scene, string log)
    {
        var hash = HashCode.Combine(scene, log, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        return $"BUG-{Math.Abs(hash):X8}";
    }
}
