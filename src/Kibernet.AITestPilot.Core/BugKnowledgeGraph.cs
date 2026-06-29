namespace Kibernet.AITestPilot.Core;

public sealed class BugKnowledgeGraph
{
    private readonly List<BugNode> nodes = new();

    public IReadOnlyList<BugNode> Nodes => nodes;

    public BugNode Record(BugPackage package, string module, string function, string fix)
    {
        if (string.IsNullOrWhiteSpace(module))
        {
            module = package.Module ?? "Unknown";
        }

        if (string.IsNullOrWhiteSpace(function))
        {
            function = package.Function ?? "Unknown";
        }

        var node = new BugNode
        {
            BugId = string.IsNullOrWhiteSpace(package.BugId) ? BugIdFactory.Create(package.Scene, package.Log) : package.BugId,
            Type = package.Type,
            Scene = package.Scene,
            Function = function,
            Module = module,
            Fix = fix,
            Risk = package.Risk,
            LastSeenAtUtc = DateTimeOffset.UtcNow,
        };

        nodes.Add(node);
        return node;
    }

    public string? SuggestFix(BugPackage package)
    {
        return nodes
            .Where(node =>
                string.Equals(node.Type, package.Type, StringComparison.OrdinalIgnoreCase) &&
                (string.IsNullOrWhiteSpace(package.Module) ||
                 string.Equals(node.Module, package.Module, StringComparison.OrdinalIgnoreCase)))
            .OrderByDescending(node => node.Risk)
            .ThenByDescending(node => node.LastSeenAtUtc)
            .Select(node => node.Fix)
            .FirstOrDefault();
    }

    public IReadOnlyList<ModuleRisk> RankModulesByRisk()
    {
        return nodes
            .GroupBy(node => node.Module, StringComparer.OrdinalIgnoreCase)
            .Select(group => new ModuleRisk(
                group.Key,
                group.Count(),
                group.Count(node => node.Risk == BugRisk.High),
                group.Sum(node => node.Risk switch
                {
                    BugRisk.High => 5,
                    BugRisk.Medium => 2,
                    _ => 1,
                })))
            .OrderByDescending(risk => risk.Score)
            .ThenBy(risk => risk.Module, StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }
}

public sealed class BugNode
{
    public string BugId { get; init; } = string.Empty;

    public string Type { get; init; } = string.Empty;

    public string Scene { get; init; } = string.Empty;

    public string Function { get; init; } = string.Empty;

    public string Module { get; init; } = string.Empty;

    public string Fix { get; init; } = string.Empty;

    public BugRisk Risk { get; init; }

    public DateTimeOffset LastSeenAtUtc { get; init; }
}

public sealed class ModuleRisk
{
    public ModuleRisk(string module, int bugCount, int highRiskCount, int score)
    {
        Module = module;
        BugCount = bugCount;
        HighRiskCount = highRiskCount;
        Score = score;
    }

    public string Module { get; }

    public int BugCount { get; }

    public int HighRiskCount { get; }

    public int Score { get; }
}
