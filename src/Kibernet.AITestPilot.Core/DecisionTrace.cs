using System.Globalization;
using System.Text.Json;

namespace Kibernet.AITestPilot.Core;

public interface IDecisionTraceSink
{
    ValueTask RecordAsync(DecisionTraceRecord record, CancellationToken cancellationToken);
}

public sealed class DecisionTraceRecord
{
    public string SchemaVersion { get; init; } = "ai-testpilot.decision_trace.v1";

    public string RunId { get; init; } = string.Empty;

    public int StepIndex { get; init; }

    public string Goal { get; init; } = string.Empty;

    public Snapshot Snapshot { get; init; } = new();

    public IReadOnlyList<string> PreviousSteps { get; init; } = Array.Empty<string>();

    public string Prompt { get; init; } = string.Empty;

    public string RequestJson { get; init; } = string.Empty;

    public string ResponseJson { get; init; } = string.Empty;

    public TestPilotAction? Action { get; init; }

    public string Status { get; init; } = string.Empty;

    public string? Error { get; init; }

    public DateTimeOffset RecordedAtUtc { get; init; } = DateTimeOffset.UtcNow;
}

public sealed class FileDecisionTraceSink : IDecisionTraceSink
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
    };

    private readonly string traceDirectory;

    public FileDecisionTraceSink(string traceDirectory)
    {
        if (string.IsNullOrWhiteSpace(traceDirectory))
        {
            throw new ArgumentException("Trace directory is required.", nameof(traceDirectory));
        }

        this.traceDirectory = traceDirectory;
    }

    public async ValueTask RecordAsync(DecisionTraceRecord record, CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(traceDirectory);

        var step = record.StepIndex.ToString("D4", CultureInfo.InvariantCulture);
        var json = JsonSerializer.Serialize(record, JsonOptions);

        await File.WriteAllTextAsync(
                Path.Combine(traceDirectory, $"step-{step}-decision.json"),
                json,
                cancellationToken)
            .ConfigureAwait(false);

        await File.WriteAllTextAsync(
                Path.Combine(traceDirectory, "latest-decision.json"),
                json,
                cancellationToken)
            .ConfigureAwait(false);
    }
}
