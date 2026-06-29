using System.Text.Json;
using Kibernet.AITestPilot.Core;

var evidenceBundleDir = GetOption(args, "--evidenceBundleDir");
if (string.IsNullOrWhiteSpace(evidenceBundleDir))
{
    evidenceBundleDir = Path.Combine(Environment.CurrentDirectory, "Temp", "release-evidence", "latest");
}

evidenceBundleDir = Path.GetFullPath(evidenceBundleDir);
Directory.CreateDirectory(evidenceBundleDir);

var mode = GetOption(args, "--mode") ?? "staticAnalysis";
return mode switch
{
    "staticAnalysis" => RunStaticAnalysisProbe(evidenceBundleDir),
    "autoPatch" => RunAutoPatchProbe(evidenceBundleDir),
    _ => Fail($"Unknown Lua probe mode: {mode}"),
};

static int RunStaticAnalysisProbe(string evidenceBundleDir)
{
    var fixtureFiles = CreateFixtureFiles("lua-static-analysis-fixtures");
    WriteFixtureFiles(evidenceBundleDir, fixtureFiles);

    var result = LuaStaticAnalyzer.Analyze(fixtureFiles);
    var requiredRules = RequiredLuaStaticRules();
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

    var jsonOptions = CreateJsonOptions();
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
}

static int RunAutoPatchProbe(string evidenceBundleDir)
{
    var sourceFiles = CreateFixtureFiles("lua-auto-patch-sandbox/original");
    WriteFixtureFiles(evidenceBundleDir, sourceFiles);

    var result = LuaAutoPatcher.ApplySandboxPatches(sourceFiles);
    var changedFiles = result.PatchedFiles.Where(file => file.Changed).ToArray();
    foreach (var file in result.PatchedFiles)
    {
        var patchedRelativePath = ToPatchedSandboxPath(file.Path);
        WriteRelativeFile(evidenceBundleDir, patchedRelativePath, file.PatchedText);
    }

    var operationsApplied = result.Operations.Count(operation => operation.Applied);
    var sandboxOnly = true;
    var mainRepositoryMutated = false;
    var realProductionLuaPatched = false;
    var patchText = BuildUnifiedPatch(result.PatchedFiles);
    var patchFileGenerated = !string.IsNullOrWhiteSpace(patchText);

    var blockingReasons = new List<string>();
    if (result.BeforeAnalysis.FindingCount < 5)
    {
        blockingReasons.Add("before_finding_count_too_low");
    }

    if (result.BeforeAnalysis.HighRiskFindingCount < 2)
    {
        blockingReasons.Add("before_high_risk_count_too_low");
    }

    if (result.Operations.Count < 6)
    {
        blockingReasons.Add("patch_operation_count_too_low");
    }

    if (operationsApplied != result.Operations.Count)
    {
        blockingReasons.Add("not_all_patch_operations_applied");
    }

    if (changedFiles.Length < 2)
    {
        blockingReasons.Add("changed_file_count_too_low");
    }

    if (result.AfterAnalysis.FindingCount != 0)
    {
        blockingReasons.Add("after_analysis_findings_remaining");
    }

    if (result.AfterAnalysis.HighRiskFindingCount != 0)
    {
        blockingReasons.Add("after_analysis_high_risk_remaining");
    }

    if (!patchFileGenerated)
    {
        blockingReasons.Add("patch_file_not_generated");
    }

    if (!sandboxOnly || mainRepositoryMutated || realProductionLuaPatched)
    {
        blockingReasons.Add("sandbox_boundary_violated");
    }

    var status = blockingReasons.Count == 0 ? "PASS" : "FAIL";
    var files = new[]
    {
        "lua-auto-patch-sandbox-manifest.json",
        "lua-auto-patch-before-report.json",
        "lua-auto-patch-after-report.json",
        "lua-auto-patch-operations.json",
        "lua-auto-patch.patch",
        "lua-auto-patch-report.md",
        "lua-auto-patch-sandbox/original/RewardFlow.lua",
        "lua-auto-patch-sandbox/original/FishingFlow.lua",
        "lua-auto-patch-sandbox/original/SafeRewardFlow.lua",
        "lua-auto-patch-sandbox/patched/RewardFlow.lua",
        "lua-auto-patch-sandbox/patched/FishingFlow.lua",
        "lua-auto-patch-sandbox/patched/SafeRewardFlow.lua",
    };

    var manifest = new
    {
        schemaVersion = "aitestpilot.lua_auto_patch_sandbox.v1",
        status,
        generatedAtUtc = DateTimeOffset.UtcNow.ToString("O"),
        source = "deterministic_lua_fixture",
        beforeFindingCount = result.BeforeAnalysis.FindingCount,
        beforeHighRiskFindingCount = result.BeforeAnalysis.HighRiskFindingCount,
        beforeAutoPatchCandidateCount = result.BeforeAnalysis.AutoPatchCandidateCount,
        patchOperationCount = result.Operations.Count,
        appliedOperationCount = operationsApplied,
        changedFileCount = changedFiles.Length,
        afterFindingCount = result.AfterAnalysis.FindingCount,
        afterHighRiskFindingCount = result.AfterAnalysis.HighRiskFindingCount,
        afterAutoPatchCandidateCount = result.AfterAnalysis.AutoPatchCandidateCount,
        patchFileGenerated,
        sandboxOnly,
        mainRepositoryMutated,
        realProductionLuaPatched,
        productionBoundary = "deterministic_lua_fixture_only",
        blockingReasonCount = blockingReasons.Count,
        blockingReasons,
        files,
    };

    var jsonOptions = CreateJsonOptions();
    File.WriteAllText(
        Path.Combine(evidenceBundleDir, "lua-auto-patch-before-report.json"),
        JsonSerializer.Serialize(result.BeforeAnalysis, jsonOptions));
    File.WriteAllText(
        Path.Combine(evidenceBundleDir, "lua-auto-patch-after-report.json"),
        JsonSerializer.Serialize(result.AfterAnalysis, jsonOptions));
    File.WriteAllText(
        Path.Combine(evidenceBundleDir, "lua-auto-patch-operations.json"),
        JsonSerializer.Serialize(result.Operations, jsonOptions));
    File.WriteAllText(
        Path.Combine(evidenceBundleDir, "lua-auto-patch.patch"),
        patchText);
    File.WriteAllText(
        Path.Combine(evidenceBundleDir, "lua-auto-patch-report.md"),
        BuildAutoPatchReportMarkdown(result, sandboxOnly, realProductionLuaPatched));
    File.WriteAllText(
        Path.Combine(evidenceBundleDir, "lua-auto-patch-sandbox-manifest.json"),
        JsonSerializer.Serialize(manifest, jsonOptions));

    Console.WriteLine($"Lua auto patch sandbox manifest: {Path.Combine(evidenceBundleDir, "lua-auto-patch-sandbox-manifest.json")}");
    if (status != "PASS")
    {
        Console.Error.WriteLine("AI TestPilot Lua auto patch sandbox probe failed: " + string.Join(", ", blockingReasons));
        return 1;
    }

    Console.WriteLine("PASS AI TestPilot Lua auto patch sandbox probe");
    return 0;
}

static LuaSourceFile[] CreateFixtureFiles(string baseDirectory)
{
    return new[]
    {
        new LuaSourceFile
        {
            Path = $"{baseDirectory}/RewardFlow.lua",
            Text = """
                   local reward = GameApi.ClaimDailyReward(playerId)
                   local itemId = reward.itemId
                   lastRewardItemId = itemId
                   return itemId
                   """,
        },
        new LuaSourceFile
        {
            Path = $"{baseDirectory}/FishingFlow.lua",
            Text = """
                   local moduleName = "Fishing." .. fishType
                   local fishingModule = require(moduleName)
                   local result = GameApi.FinishFishing(sessionId)
                   return result.catchId
                   """,
        },
        new LuaSourceFile
        {
            Path = $"{baseDirectory}/SafeRewardFlow.lua",
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
}

static string[] RequiredLuaStaticRules()
{
    return new[]
    {
        "lua.dynamic_require",
        "lua.global_write",
        "lua.unguarded_field_access",
        "lua.unprotected_game_api_call",
    };
}

static void WriteFixtureFiles(string evidenceBundleDir, IEnumerable<LuaSourceFile> fixtureFiles)
{
    foreach (var fixture in fixtureFiles)
    {
        WriteRelativeFile(evidenceBundleDir, fixture.Path, fixture.Text);
    }
}

static void WriteRelativeFile(string evidenceBundleDir, string relativePath, string text)
{
    var fullPath = Path.Combine(evidenceBundleDir, NormalizeRelativePath(relativePath));
    Directory.CreateDirectory(Path.GetDirectoryName(fullPath) ?? evidenceBundleDir);
    File.WriteAllText(fullPath, text);
}

static string ToPatchedSandboxPath(string originalPath)
{
    return originalPath.Replace(
        "lua-auto-patch-sandbox/original/",
        "lua-auto-patch-sandbox/patched/",
        StringComparison.Ordinal);
}

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

static int Fail(string message)
{
    Console.Error.WriteLine(message);
    return 2;
}

static string NormalizeRelativePath(string path)
{
    return path.Replace('/', Path.DirectorySeparatorChar);
}

static JsonSerializerOptions CreateJsonOptions()
{
    return new JsonSerializerOptions
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };
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

static string BuildAutoPatchReportMarkdown(
    LuaAutoPatchResult result,
    bool sandboxOnly,
    bool realProductionLuaPatched)
{
    var lines = new List<string>
    {
        "# AI TestPilot Lua Auto Patch Sandbox",
        "",
        $"- Before findings: {result.BeforeAnalysis.FindingCount}",
        $"- Before high-risk findings: {result.BeforeAnalysis.HighRiskFindingCount}",
        $"- Patch operations: {result.Operations.Count}",
        $"- After findings: {result.AfterAnalysis.FindingCount}",
        $"- After high-risk findings: {result.AfterAnalysis.HighRiskFindingCount}",
        $"- Sandbox only: {sandboxOnly}",
        $"- Real production Lua patched: {realProductionLuaPatched}",
        "",
        "## Operations",
    };

    foreach (var operation in result.Operations)
    {
        lines.Add($"- {operation.RuleId} {operation.FilePath}:{operation.LineNumber} - {operation.Description}");
    }

    return string.Join(Environment.NewLine, lines) + Environment.NewLine;
}

static string BuildUnifiedPatch(IEnumerable<LuaPatchedSourceFile> patchedFiles)
{
    var blocks = new List<string>();
    foreach (var file in patchedFiles.Where(file => file.Changed))
    {
        blocks.Add($"diff --git a/{file.Path} b/{file.Path}");
        blocks.Add($"--- a/{file.Path}");
        blocks.Add($"+++ b/{file.Path}");
        blocks.Add("@@");
        foreach (var line in file.OriginalText.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n'))
        {
            blocks.Add("-" + line);
        }

        foreach (var line in file.PatchedText.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n'))
        {
            blocks.Add("+" + line);
        }
    }

    return string.Join(Environment.NewLine, blocks) + Environment.NewLine;
}
