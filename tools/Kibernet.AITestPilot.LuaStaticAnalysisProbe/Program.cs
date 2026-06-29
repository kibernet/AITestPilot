using System.Text.Json;
using Kibernet.AITestPilot.Core;

var evidenceBundleDir = GetOption(args, "--evidenceBundleDir");
if (string.IsNullOrWhiteSpace(evidenceBundleDir))
{
    evidenceBundleDir = Path.Combine(Environment.CurrentDirectory, "Temp", "release-evidence", "latest");
}

evidenceBundleDir = Path.GetFullPath(evidenceBundleDir);
Directory.CreateDirectory(evidenceBundleDir);

var fixtureDir = Path.Combine(evidenceBundleDir, "lua-static-analysis-fixtures");
Directory.CreateDirectory(fixtureDir);

var fixtureFiles = new[]
{
    new LuaSourceFile
    {
        Path = "lua-static-analysis-fixtures/RewardFlow.lua",
        Text = """
               local reward = GameApi.ClaimDailyReward(playerId)
               local itemId = reward.itemId
               lastRewardItemId = itemId
               return itemId
               """,
    },
    new LuaSourceFile
    {
        Path = "lua-static-analysis-fixtures/FishingFlow.lua",
        Text = """
               local moduleName = "Fishing." .. fishType
               local fishingModule = require(moduleName)
               local result = GameApi.FinishFishing(sessionId)
               return result.catchId
               """,
    },
    new LuaSourceFile
    {
        Path = "lua-static-analysis-fixtures/SafeRewardFlow.lua",
        Text = """
               local ok, reward = pcall(GameApi.ClaimDailyReward, playerId)
               if not ok then return nil end
               if reward == nil then return nil end
               local itemId = reward.itemId
               local lastRewardItemId = itemId
               return lastRewardItemId
               """,
    },
};

foreach (var fixture in fixtureFiles)
{
    File.WriteAllText(Path.Combine(evidenceBundleDir, NormalizeRelativePath(fixture.Path)), fixture.Text);
}

var result = LuaStaticAnalyzer.Analyze(fixtureFiles);
var requiredRules = new[]
{
    "lua.dynamic_require",
    "lua.global_write",
    "lua.unguarded_field_access",
    "lua.unprotected_game_api_call",
};

var requiredRulesFound = requiredRules.Count(rule => result.RuleIds.Contains(rule, StringComparer.Ordinal));
var safeFixtureFindingCount = result.Findings.Count(finding => finding.FilePath.EndsWith("SafeRewardFlow.lua", StringComparison.Ordinal));
var realProductionLuaAnalyzed = false;

var blockingReasons = new List<string>();
if (result.SourceFileCount < 3)
{
    blockingReasons.Add("source_file_count_too_low");
}

if (result.FindingCount < 5)
{
    blockingReasons.Add("finding_count_too_low");
}

if (result.HighRiskFindingCount < 2)
{
    blockingReasons.Add("high_risk_finding_count_too_low");
}

if (result.AutoPatchCandidateCount < 4)
{
    blockingReasons.Add("auto_patch_candidate_count_too_low");
}

if (requiredRulesFound != requiredRules.Length)
{
    blockingReasons.Add("required_rule_coverage_incomplete");
}

if (safeFixtureFindingCount != 0)
{
    blockingReasons.Add("safe_fixture_has_findings");
}

if (realProductionLuaAnalyzed)
{
    blockingReasons.Add("production_lua_unexpectedly_marked_analyzed");
}

var status = blockingReasons.Count == 0 ? "PASS" : "FAIL";
var files = new[]
{
    "lua-static-analysis-report.json",
    "lua-static-analysis-report.md",
    "lua-static-analysis-patch-plan.md",
    "lua-static-analysis-fixtures/RewardFlow.lua",
    "lua-static-analysis-fixtures/FishingFlow.lua",
    "lua-static-analysis-fixtures/SafeRewardFlow.lua",
};

var manifest = new
{
    schemaVersion = "aitestpilot.lua_static_analysis.v1",
    status,
    generatedAtUtc = DateTimeOffset.UtcNow.ToString("O"),
    source = "deterministic_lua_fixture",
    sourceFileCount = result.SourceFileCount,
    analyzedLineCount = result.AnalyzedLineCount,
    findingCount = result.FindingCount,
    highRiskFindingCount = result.HighRiskFindingCount,
    autoPatchCandidateCount = result.AutoPatchCandidateCount,
    requiredRuleCount = requiredRules.Length,
    requiredRuleIdsFoundCount = requiredRulesFound,
    requiredRuleIds = requiredRules,
    ruleIds = result.RuleIds,
    safeFixtureFindingCount,
    realProductionLuaAnalyzed,
    productionBoundary = "deterministic_lua_fixture_only",
    patchPlanGenerated = result.AutoPatchCandidateCount > 0,
    blockingReasonCount = blockingReasons.Count,
    blockingReasons,
    files,
};

var jsonOptions = new JsonSerializerOptions
{
    WriteIndented = true,
    PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
};

File.WriteAllText(
    Path.Combine(evidenceBundleDir, "lua-static-analysis-report.json"),
    JsonSerializer.Serialize(result, jsonOptions));
File.WriteAllText(
    Path.Combine(evidenceBundleDir, "lua-static-analysis-report.md"),
    BuildReportMarkdown(result, safeFixtureFindingCount, realProductionLuaAnalyzed));
File.WriteAllText(
    Path.Combine(evidenceBundleDir, "lua-static-analysis-patch-plan.md"),
    BuildPatchPlanMarkdown(result));
File.WriteAllText(
    Path.Combine(evidenceBundleDir, "lua-static-analysis-manifest.json"),
    JsonSerializer.Serialize(manifest, jsonOptions));

Console.WriteLine($"Lua static analysis manifest: {Path.Combine(evidenceBundleDir, "lua-static-analysis-manifest.json")}");
if (status != "PASS")
{
    Console.Error.WriteLine("AI TestPilot Lua static analysis probe failed: " + string.Join(", ", blockingReasons));
    return 1;
}

Console.WriteLine("PASS AI TestPilot Lua static analysis probe");
return 0;

static string? GetOption(string[] args, string name)
{
    for (var index = 0; index < args.Length - 1; index++)
    {
        if (string.Equals(args[index], name, StringComparison.Ordinal))
        {
            return args[index + 1];
        }
    }

    return null;
}

static string NormalizeRelativePath(string path)
{
    return path.Replace('/', Path.DirectorySeparatorChar);
}

static string BuildReportMarkdown(
    LuaStaticAnalysisResult result,
    int safeFixtureFindingCount,
    bool realProductionLuaAnalyzed)
{
    var lines = new List<string>
    {
        "# AI TestPilot Lua Static Analysis",
        "",
        $"- Status: {result.Status}",
        $"- Source files: {result.SourceFileCount}",
        $"- Analyzed lines: {result.AnalyzedLineCount}",
        $"- Findings: {result.FindingCount}",
        $"- High-risk findings: {result.HighRiskFindingCount}",
        $"- Auto-patch candidates: {result.AutoPatchCandidateCount}",
        $"- Safe fixture findings: {safeFixtureFindingCount}",
        $"- Real production Lua analyzed: {realProductionLuaAnalyzed}",
        "",
        "## Findings",
    };

    foreach (var finding in result.Findings)
    {
        lines.Add($"- {finding.RuleId} {finding.Severity} {finding.FilePath}:{finding.LineNumber} - {finding.Message}");
    }

    return string.Join(Environment.NewLine, lines) + Environment.NewLine;
}

static string BuildPatchPlanMarkdown(LuaStaticAnalysisResult result)
{
    var lines = new List<string>
    {
        "# AI TestPilot Lua Static Analysis Patch Plan",
        "",
        "This file records deterministic patch suggestions only; it does not modify production Lua.",
        "",
    };

    foreach (var finding in result.Findings.Where(finding => finding.AutoPatchCandidate))
    {
        lines.Add($"- {finding.FilePath}:{finding.LineNumber} `{finding.RuleId}`");
        lines.Add($"  - {finding.Recommendation}");
    }

    return string.Join(Environment.NewLine, lines) + Environment.NewLine;
}
