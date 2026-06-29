using System.Text.RegularExpressions;

namespace Kibernet.AITestPilot.Core;

public sealed class LuaSourceFile
{
    public string Path { get; init; } = string.Empty;

    public string Text { get; init; } = string.Empty;
}

public sealed class LuaStaticFinding
{
    public string RuleId { get; init; } = string.Empty;

    public string Severity { get; init; } = string.Empty;

    public string FilePath { get; init; } = string.Empty;

    public int LineNumber { get; init; }

    public string Message { get; init; } = string.Empty;

    public string Recommendation { get; init; } = string.Empty;

    public string Snippet { get; init; } = string.Empty;

    public bool AutoPatchCandidate { get; init; }
}

public sealed class LuaStaticAnalysisResult
{
    public string SchemaVersion { get; init; } = "aitestpilot.lua_static_analysis.v1";

    public string Status { get; init; } = "PASS";

    public int SourceFileCount { get; init; }

    public int AnalyzedLineCount { get; init; }

    public int FindingCount { get; init; }

    public int HighRiskFindingCount { get; init; }

    public int AutoPatchCandidateCount { get; init; }

    public IReadOnlyList<string> RuleIds { get; init; } = Array.Empty<string>();

    public IReadOnlyList<LuaStaticFinding> Findings { get; init; } = Array.Empty<LuaStaticFinding>();
}

public static partial class LuaStaticAnalyzer
{
    private static readonly HashSet<string> SafeFieldAccessPrefixes = new(StringComparer.Ordinal)
    {
        "self",
        "math",
        "string",
        "table",
        "os",
        "io",
        "coroutine",
        "debug",
        "GameApi",
        "CS",
        "UnityEngine",
    };

    public static LuaStaticAnalysisResult Analyze(IEnumerable<LuaSourceFile> files)
    {
        var sourceFiles = files.ToArray();
        var findings = new List<LuaStaticFinding>();
        var analyzedLineCount = 0;

        foreach (var file in sourceFiles)
        {
            var guardedVariables = new HashSet<string>(StringComparer.Ordinal);
            var lines = SplitLines(file.Text);
            for (var index = 0; index < lines.Length; index++)
            {
                var lineNumber = index + 1;
                var line = StripComment(lines[index]);
                if (string.IsNullOrWhiteSpace(line))
                {
                    continue;
                }

                analyzedLineCount++;
                RecordGuardedVariables(line, guardedVariables);
                AddGlobalWriteFinding(file.Path, line, lineNumber, findings);
                AddDynamicRequireFinding(file.Path, line, lineNumber, findings);
                AddUnprotectedGameApiFinding(file.Path, line, lineNumber, findings);
                AddUnguardedFieldAccessFinding(file.Path, line, lineNumber, guardedVariables, findings);
            }
        }

        var ruleIds = findings
            .Select(finding => finding.RuleId)
            .Distinct(StringComparer.Ordinal)
            .OrderBy(ruleId => ruleId, StringComparer.Ordinal)
            .ToArray();

        return new LuaStaticAnalysisResult
        {
            SourceFileCount = sourceFiles.Length,
            AnalyzedLineCount = analyzedLineCount,
            FindingCount = findings.Count,
            HighRiskFindingCount = findings.Count(finding => finding.Severity == "HIGH"),
            AutoPatchCandidateCount = findings.Count(finding => finding.AutoPatchCandidate),
            RuleIds = ruleIds,
            Findings = findings,
        };
    }

    private static string[] SplitLines(string text)
    {
        return text.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n');
    }

    private static string StripComment(string line)
    {
        var commentIndex = line.IndexOf("--", StringComparison.Ordinal);
        return commentIndex >= 0 ? line[..commentIndex] : line;
    }

    private static void RecordGuardedVariables(string line, HashSet<string> guardedVariables)
    {
        var match = NilGuardRegex().Match(line);
        if (match.Success)
        {
            foreach (var groupName in new[] { "notVar", "leftVar", "rightVar", "notNilVar" })
            {
                var value = match.Groups[groupName].Value;
                if (!string.IsNullOrWhiteSpace(value))
                {
                    guardedVariables.Add(value);
                }
            }
        }
    }

    private static void AddGlobalWriteFinding(
        string filePath,
        string line,
        int lineNumber,
        List<LuaStaticFinding> findings)
    {
        var match = GlobalWriteRegex().Match(line);
        if (!match.Success)
        {
            return;
        }

        var name = match.Groups["name"].Value;
        if (IsLuaKeyword(name))
        {
            return;
        }

        findings.Add(new LuaStaticFinding
        {
            RuleId = "lua.global_write",
            Severity = "MEDIUM",
            FilePath = filePath,
            LineNumber = lineNumber,
            Message = $"Global assignment '{name}' can leak state across replay runs.",
            Recommendation = $"Make '{name}' local or write through an explicit state owner.",
            Snippet = line.Trim(),
            AutoPatchCandidate = true,
        });
    }

    private static void AddDynamicRequireFinding(
        string filePath,
        string line,
        int lineNumber,
        List<LuaStaticFinding> findings)
    {
        var match = RequireRegex().Match(line);
        if (!match.Success)
        {
            return;
        }

        var argument = match.Groups["argument"].Value.Trim();
        if (argument.StartsWith("\"", StringComparison.Ordinal) || argument.StartsWith("'", StringComparison.Ordinal))
        {
            return;
        }

        findings.Add(new LuaStaticFinding
        {
            RuleId = "lua.dynamic_require",
            Severity = "MEDIUM",
            FilePath = filePath,
            LineNumber = lineNumber,
            Message = "Dynamic require makes replay repair scope hard to prove.",
            Recommendation = "Replace dynamic require with an explicit allowlisted module path.",
            Snippet = line.Trim(),
            AutoPatchCandidate = false,
        });
    }

    private static void AddUnprotectedGameApiFinding(
        string filePath,
        string line,
        int lineNumber,
        List<LuaStaticFinding> findings)
    {
        if (!line.Contains("GameApi.", StringComparison.Ordinal) ||
            line.Contains("pcall", StringComparison.Ordinal) ||
            line.Contains("xpcall", StringComparison.Ordinal))
        {
            return;
        }

        findings.Add(new LuaStaticFinding
        {
            RuleId = "lua.unprotected_game_api_call",
            Severity = "MEDIUM",
            FilePath = filePath,
            LineNumber = lineNumber,
            Message = "Game API call is not wrapped in pcall/xpcall.",
            Recommendation = "Wrap external game API calls so replay evidence can classify failures.",
            Snippet = line.Trim(),
            AutoPatchCandidate = true,
        });
    }

    private static void AddUnguardedFieldAccessFinding(
        string filePath,
        string line,
        int lineNumber,
        HashSet<string> guardedVariables,
        List<LuaStaticFinding> findings)
    {
        foreach (Match match in FieldAccessRegex().Matches(line))
        {
            var variableName = match.Groups["name"].Value;
            if (SafeFieldAccessPrefixes.Contains(variableName) || guardedVariables.Contains(variableName))
            {
                continue;
            }

            findings.Add(new LuaStaticFinding
            {
                RuleId = "lua.unguarded_field_access",
                Severity = "HIGH",
                FilePath = filePath,
                LineNumber = lineNumber,
                Message = $"Field access '{match.Value}' has no preceding nil guard in this file.",
                Recommendation = $"Add a nil guard for '{variableName}' before reading '{match.Value}'.",
                Snippet = line.Trim(),
                AutoPatchCandidate = true,
            });
            break;
        }
    }

    private static bool IsLuaKeyword(string value)
    {
        return value is "and" or "break" or "do" or "else" or "elseif" or "end" or "false" or "for" or "function" or "if" or "in" or "local" or "nil" or "not" or "or" or "repeat" or "return" or "then" or "true" or "until" or "while";
    }

    [GeneratedRegex(@"^\s*(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*=")]
    private static partial Regex GlobalWriteRegex();

    [GeneratedRegex(@"require\s*\(\s*(?<argument>[^)]+)\)")]
    private static partial Regex RequireRegex();

    [GeneratedRegex(@"(?<![\w.])(?<name>[A-Za-z_][A-Za-z0-9_]*)\.[A-Za-z_][A-Za-z0-9_]*")]
    private static partial Regex FieldAccessRegex();

    [GeneratedRegex(@"\bif\s+(?:(?:not\s+(?<notVar>[A-Za-z_][A-Za-z0-9_]*))|(?:(?<leftVar>[A-Za-z_][A-Za-z0-9_]*)\s*==\s*nil)|(?:nil\s*==\s*(?<rightVar>[A-Za-z_][A-Za-z0-9_]*))|(?:(?<notNilVar>[A-Za-z_][A-Za-z0-9_]*)\s*~=\s*nil))")]
    private static partial Regex NilGuardRegex();
}
