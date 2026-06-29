using System.Net;
using System.Text;
using System.Text.Json;
using Kibernet.AITestPilot.Core;

var tests = new (string Name, Func<Task> Run)[]
{
    ("action whitelist rejects unknown actions", ActionWhitelistRejectsUnknownActions),
    ("action whitelist accepts business replay actions", ActionWhitelistAcceptsBusinessReplayActions),
    ("decision loop executes click then finish", DecisionLoopExecutesClickThenFinish),
    ("bug detector packages exception logs", BugDetectorPackagesExceptionLogs),
    ("Lua static analyzer finds risky replay repair patterns", LuaStaticAnalyzerFindsRiskyReplayRepairPatterns),
    ("Lua auto patcher clears sandbox findings", LuaAutoPatcherClearsSandboxFindings),
    ("knowledge graph reuses previous fixes", KnowledgeGraphReusesPreviousFixes),
    ("release gate blocks failed checks", ReleaseGateBlocksFailedChecks),
    ("run report summarizes loop result", RunReportSummarizesLoopResult),
    ("release evidence requires verified high risk bugs", ReleaseEvidenceRequiresVerifiedHighRiskBugs),
    ("repair task links bug run and retest command", RepairTaskLinksBugRunAndRetestCommand),
    ("action JSON schema lists model-safe constraints", ActionJsonSchemaListsModelSafeConstraints),
    ("model endpoint client posts schema and parses direct action", ModelEndpointClientPostsSchemaAndParsesDirectAction),
    ("model endpoint client supports OpenAI-compatible chat request", ModelEndpointClientSupportsOpenAICompatibleChatRequest),
    ("model endpoint client parses text payload and writes trace", ModelEndpointClientParsesTextPayloadAndWritesTrace),
    ("model endpoint client rejects unsafe action", ModelEndpointClientRejectsUnsafeAction),
};

foreach (var test in tests)
{
    await test.Run();
    Console.WriteLine($"PASS {test.Name}");
}

Console.WriteLine($"PASS {tests.Length} smoke tests");

static Task ActionWhitelistRejectsUnknownActions()
{
    var action = new TestPilotAction { Action = "delete_project" };
    AssertThrows<InvalidOperationException>(() => action.Validate());
    return Task.CompletedTask;
}

static Task ActionWhitelistAcceptsBusinessReplayActions()
{
    foreach (var action in new[]
             {
                 ActionVerbs.PrepareAccount,
                 ActionVerbs.Login,
                 ActionVerbs.EnterScene,
                 ActionVerbs.ClaimReward,
                 ActionVerbs.PlayFishing,
             })
    {
        new TestPilotAction { Action = action, Target = "qa_smoke_target" }.Validate();
    }

    return Task.CompletedTask;
}

static async Task DecisionLoopExecutesClickThenFinish()
{
    var provider = new StaticSnapshotProvider(step => new Snapshot
    {
        Scene = "Lobby",
        StepIndex = step,
        Ui = new[]
        {
            new UiElementSnapshot
            {
                AutomationId = "Lobby.ActivityButton",
                Name = "ActivityButton",
                Kind = "Button",
                Interactable = true,
            },
        },
    });

    var decisions = new ScriptedDecisionClient(new[]
    {
        TestPilotAction.Click("Lobby.ActivityButton"),
        TestPilotAction.Finish(),
    });

    var executor = new RecordingActionExecutor();
    var loop = new DecisionLoop(provider, decisions, executor);

    var result = await loop.RunAsync("enter activity");

    AssertEqual("finish", result.ExitReason, "exit reason");
    AssertEqual(2, result.Steps.Count, "step count");
    AssertEqual(1, executor.Actions.Count, "executed actions");
    AssertEqual("Lobby.ActivityButton", executor.Actions[0].Target, "click target");
}

static Task BugDetectorPackagesExceptionLogs()
{
    var detector = new BugDetector();
    var package = detector.TryCreatePackage(
        new Snapshot
        {
            Scene = "Activity",
            Logs = new[]
            {
                new LogEntry
                {
                    Severity = LogSeverity.Exception,
                    Message = "NullReferenceException: claimReward reward is null",
                },
            },
        },
        new[]
        {
            "prepare_account:qa_smoke_account",
            "login:qa_smoke_account",
            "enter_scene:Activity",
            "claim_reward:Activity.ClaimReward",
            "play_fishing:CastLine",
        });

    if (package is null)
    {
        throw new InvalidOperationException("bug package: expected a value.");
    }

    AssertEqual("NullReference", package.Type, "bug type");
    AssertEqual(BugRisk.High, package.Risk, "bug risk");
    AssertEqual(5, package.Steps.Count, "bug steps");
    return Task.CompletedTask;
}

static Task LuaStaticAnalyzerFindsRiskyReplayRepairPatterns()
{
    var result = LuaStaticAnalyzer.Analyze(new[]
    {
        new LuaSourceFile
        {
            Path = "RewardFlow.lua",
            Text = """
                   local reward = GameApi.ClaimDailyReward(playerId)
                   local itemId = reward.itemId
                   lastRewardItemId = itemId
                   """,
        },
        new LuaSourceFile
        {
            Path = "SafeRewardFlow.lua",
            Text = """
                   local ok, reward = pcall(GameApi.ClaimDailyReward, playerId)
                   if not ok then return nil end
                   if reward == nil then return nil end
                   local itemId = reward.itemId
                   local lastRewardItemId = itemId
                   return lastRewardItemId
                   """,
        },
    });

    AssertEqual(2, result.SourceFileCount, "lua source file count");
    AssertEqual(true, result.FindingCount >= 3, "lua finding count");
    AssertEqual(true, result.HighRiskFindingCount >= 1, "lua high risk finding count");
    AssertEqual(true, result.AutoPatchCandidateCount >= 2, "lua auto patch candidates");
    AssertEqual(true, result.RuleIds.Contains("lua.unguarded_field_access"), "lua unguarded access rule");
    AssertEqual(true, result.RuleIds.Contains("lua.global_write"), "lua global write rule");
    AssertEqual(true, result.RuleIds.Contains("lua.unprotected_game_api_call"), "lua game api rule");
    AssertEqual(0, result.Findings.Count(finding => finding.FilePath == "SafeRewardFlow.lua"), "safe lua finding count");
    return Task.CompletedTask;
}

static Task LuaAutoPatcherClearsSandboxFindings()
{
    var result = LuaAutoPatcher.ApplySandboxPatches(new[]
    {
        new LuaSourceFile
        {
            Path = "RewardFlow.lua",
            Text = """
                   local reward = GameApi.ClaimDailyReward(playerId)
                   local itemId = reward.itemId
                   lastRewardItemId = itemId
                   return itemId
                   """,
        },
        new LuaSourceFile
        {
            Path = "FishingFlow.lua",
            Text = """
                   local moduleName = "Fishing." .. fishType
                   local fishingModule = require(moduleName)
                   local result = GameApi.FinishFishing(sessionId)
                   return result.catchId
                   """,
        },
    });

    AssertEqual(true, result.BeforeAnalysis.FindingCount >= 5, "before lua finding count");
    AssertEqual(true, result.Operations.Count >= 6, "lua patch operation count");
    AssertEqual(true, result.Operations.All(operation => operation.Applied), "lua patch operations applied");
    AssertEqual(0, result.AfterAnalysis.FindingCount, "after lua finding count");
    AssertEqual(0, result.AfterAnalysis.HighRiskFindingCount, "after lua high risk finding count");
    AssertEqual(true, result.PatchedFiles.All(file => file.Changed), "patched lua files changed");
    AssertContains(result.PatchedFiles[0].PatchedText, "pcall(GameApi.ClaimDailyReward", "pcall patch");
    AssertContains(result.PatchedFiles[0].PatchedText, "if reward == nil then return nil end", "nil guard patch");
    AssertContains(result.PatchedFiles[0].PatchedText, "local lastRewardItemId", "global write patch");
    AssertContains(result.PatchedFiles[1].PatchedText, "require(\"Fishing.Default\")", "dynamic require patch");
    return Task.CompletedTask;
}

static Task KnowledgeGraphReusesPreviousFixes()
{
    var graph = new BugKnowledgeGraph();
    graph.Record(
        new BugPackage
        {
            BugId = "B001",
            Type = "NullReference",
            Scene = "Activity",
            Risk = BugRisk.High,
            Module = "ActivitySystem",
            Function = "claimReward",
        },
        "ActivitySystem",
        "claimReward",
        "add nil/null guard before reward claim");

    var suggestion = graph.SuggestFix(new BugPackage
    {
        Type = "NullReference",
        Module = "ActivitySystem",
    });

    AssertEqual("add nil/null guard before reward claim", suggestion, "suggested fix");
    AssertEqual("ActivitySystem", graph.RankModulesByRisk()[0].Module, "top risk module");
    return Task.CompletedTask;
}

static async Task ReleaseGateBlocksFailedChecks()
{
    var gate = new ReleaseGate(new IReleaseCheck[]
    {
        new DelegatedReleaseCheck("build", _ => ValueTask.FromResult(ReleaseCheckResult.Pass("build"))),
        new DelegatedReleaseCheck("vision", _ => ValueTask.FromResult(ReleaseCheckResult.Fail("vision", "missing snapshot baseline"))),
    });

    var result = await gate.RunAsync();

    AssertEqual(false, result.AllowRelease, "allow release");
    AssertEqual("vision", result.FailedCheckNames[0], "failed check");
}

static async Task RunReportSummarizesLoopResult()
{
    var provider = new StaticSnapshotProvider(step => new Snapshot
    {
        Scene = "Activity",
        StepIndex = step,
        Logs = step == 1
            ? new[]
            {
                new LogEntry
                {
                    Severity = LogSeverity.Exception,
                    Message = "NullReferenceException: reward is null",
                },
            }
            : Array.Empty<LogEntry>(),
    });

    var loop = new DecisionLoop(
        provider,
        new ScriptedDecisionClient(new[] { TestPilotAction.Click("Activity.ClaimReward") }),
        new RecordingActionExecutor(),
        options: new DecisionLoopOptions { StopOnBug = true, MaxSteps = 3 });

    var result = await loop.RunAsync("claim reward");
    var report = TestRunReportFactory.FromDecisionLoopResult(
        "claim reward",
        result,
        DateTimeOffset.Parse("2026-06-29T00:00:00Z"),
        DateTimeOffset.Parse("2026-06-29T00:00:01Z"),
        "RUN-BUG");

    AssertEqual(TestRunOutcome.BugDetected, report.Outcome, "run outcome");
    AssertEqual(1, report.Metrics.ActionCount, "action count");
    AssertEqual(1, report.Metrics.BugCount, "bug count");
    AssertEqual(1, report.Metrics.ErrorLogCount, "error log count");
    AssertEqual(true, report.HasHighRiskBug, "high risk bug");
}

static async Task ReleaseEvidenceRequiresVerifiedHighRiskBugs()
{
    var bug = new BugPackage
    {
        BugId = "BUG-001",
        Type = "NullReference",
        Scene = "Activity",
        Risk = BugRisk.High,
    };

    var beforeRun = new TestRunReport
    {
        RunId = "RUN-BEFORE",
        Goal = "claim reward",
        Outcome = TestRunOutcome.BugDetected,
        Bugs = new[] { bug },
    };

    var afterRun = new TestRunReport
    {
        RunId = "RUN-AFTER",
        Goal = "claim reward",
        Outcome = TestRunOutcome.Passed,
        Bugs = Array.Empty<BugPackage>(),
    };

    var gate = new ReleaseGate(new IReleaseCheck[]
    {
        new DelegatedReleaseCheck("build", _ => ValueTask.FromResult(ReleaseCheckResult.Pass("build"))),
        new DelegatedReleaseCheck("ai_scene", _ => ValueTask.FromResult(ReleaseCheckResult.Pass("ai_scene"))),
    });

    var gateResult = await gate.RunAsync();
    var blocked = TestRunReportFactory.BuildReleaseEvidence(
        "0.1.0",
        new[] { beforeRun },
        Array.Empty<RetestReport>(),
        gateResult,
        DateTimeOffset.Parse("2026-06-29T00:00:02Z"));

    AssertEqual(false, blocked.AllowRelease, "blocked release");
    AssertEqual(1, blocked.UnverifiedHighRiskBugCount, "unverified bug count");

    var retest = TestRunReportFactory.BuildRetestReport(
        bug,
        beforeRun,
        afterRun,
        DateTimeOffset.Parse("2026-06-29T00:00:03Z"),
        "RETEST-001");

    var allowed = TestRunReportFactory.BuildReleaseEvidence(
        "0.1.0",
        new[] { beforeRun, afterRun },
        new[] { retest },
        gateResult,
        DateTimeOffset.Parse("2026-06-29T00:00:04Z"));

    AssertEqual(true, retest.Passed, "retest passed");
    AssertEqual(true, allowed.AllowRelease, "allowed release");
    AssertEqual(0, allowed.UnverifiedHighRiskBugCount, "verified bug count");
}

static Task RepairTaskLinksBugRunAndRetestCommand()
{
    var bug = new BugPackage
    {
        BugId = "BUG-002",
        Type = "NullReference",
        Scene = "Activity",
        Risk = BugRisk.High,
        Steps = new[]
        {
            "prepare_account:qa_smoke_account",
            "login:qa_smoke_account",
            "enter_scene:Activity",
            "claim_reward:Activity.ClaimReward",
            "play_fishing:CastLine",
        },
    };

    var sourceRun = new TestRunReport
    {
        RunId = "RUN-BUG",
        Goal = "claim activity reward",
        Outcome = TestRunOutcome.BugDetected,
        Bugs = new[] { bug },
    };

    var task = RepairTaskFactory.Create(
        bug,
        sourceRun,
        "add nil/null guard before reward claim",
        ".\\tools\\Validate-UnityPackageImport.ps1",
        DateTimeOffset.Parse("2026-06-29T00:00:05Z"),
        "FIX-001");

    AssertEqual("FIX-001", task.TaskId, "task id");
    AssertEqual("BUG-002", task.BugId, "task bug id");
    AssertEqual("RUN-BUG", task.SourceRunId, "source run id");
    AssertEqual(5, task.ReproductionSteps.Count, "reproduction steps");
    AssertEqual("retest_bug:BUG-002", task.RetestGoal, "retest goal");
    AssertEqual(true, task.AcceptanceCriteria.Any(item => item.Contains("retest", StringComparison.OrdinalIgnoreCase)), "acceptance retest");

    var markdown = RepairTaskFactory.ToMarkdown(task);
    AssertContains(markdown, "BUG-002", "markdown bug id");
    AssertContains(markdown, "RUN-BUG", "markdown run id");
    AssertContains(markdown, ".\\tools\\Validate-UnityPackageImport.ps1", "markdown retest command");
    return Task.CompletedTask;
}

static Task ActionJsonSchemaListsModelSafeConstraints()
{
    var schema = DecisionActionSchema.CreateJsonSchema();

    AssertContains(schema, DecisionActionSchema.SchemaVersion, "schema version");
    AssertContains(schema, "\"click\"", "click action");
    AssertContains(schema, "\"prepare_account\"", "prepare account action");
    AssertContains(schema, "\"claim_reward\"", "claim reward action");
    AssertContains(schema, "\"target\"", "target property");
    AssertContains(schema, "\"minimum\": 0", "wait minimum");
    return Task.CompletedTask;
}

static async Task ModelEndpointClientPostsSchemaAndParsesDirectAction()
{
    var handler = new RecordingHttpMessageHandler("""{"action":"click","target":"Lobby.ActivityButton"}""");
    using var httpClient = new HttpClient(handler);
    var client = new ModelEndpointDecisionClient(
        httpClient,
        new ModelEndpointDecisionClientOptions
        {
            Endpoint = new Uri("https://model.example.test/decide"),
            ApiKey = "test-key",
            Model = "pilot-test",
            RunId = "RUN-MODEL-001",
        });

    var action = await client.DecideAsync(
        new DecisionRequest(
            "enter activity",
            BuildModelSnapshot(0),
            Array.Empty<string>(),
            new[] { "add null guard before reward access" }),
        CancellationToken.None);

    AssertEqual(ActionVerbs.Click, action.Action, "model action");
    AssertEqual("Lobby.ActivityButton", action.Target, "model target");
    AssertEqual(HttpMethod.Post, handler.RequestMethod, "request method");
    AssertEqual("Bearer test-key", handler.AuthorizationHeader, "authorization header");
    AssertContains(handler.RequestBody, "\"actionJsonSchema\"", "request schema");
    AssertContains(handler.RequestBody, "\"allowedActions\"", "allowed actions");
    AssertContains(handler.RequestBody, "\"fixHints\"", "fix hints");
    AssertContains(handler.RequestBody, "add null guard before reward access", "fix hint value");
    AssertContains(handler.RequestBody, "\"scene\": \"Lobby\"", "snapshot scene");
}

static async Task ModelEndpointClientSupportsOpenAICompatibleChatRequest()
{
    var response = """
    {
      "choices": [
        {
          "message": {
            "content": "{\"action\":\"click\",\"target\":\"Lobby.ActivityButton\"}"
          }
        }
      ]
    }
    """;

    var handler = new RecordingHttpMessageHandler(response);
    using var httpClient = new HttpClient(handler);
    var client = new ModelEndpointDecisionClient(
        httpClient,
        new ModelEndpointDecisionClientOptions
        {
            Endpoint = new Uri("https://model.example.test/v1/chat/completions"),
            ApiKey = "test-key",
            Model = "pilot-chat-test",
            RequestFormat = ModelEndpointRequestFormat.OpenAICompatibleChatCompletions,
            RunId = "RUN-MODEL-CHAT",
        });

    var action = await client.DecideAsync(
        new DecisionRequest(
            "enter activity",
            BuildModelSnapshot(0),
            Array.Empty<string>(),
            new[] { "add null guard before reward access" }),
        CancellationToken.None);

    AssertEqual(ActionVerbs.Click, action.Action, "chat action");
    AssertEqual("Lobby.ActivityButton", action.Target, "chat target");
    AssertContains(handler.RequestBody, "\"model\": \"pilot-chat-test\"", "chat model");
    AssertContains(handler.RequestBody, "\"messages\"", "chat messages");
    AssertContains(handler.RequestBody, "\"role\": \"system\"", "system message");
    AssertContains(handler.RequestBody, "\"role\": \"user\"", "user message");
    AssertContains(handler.RequestBody, "\"response_format\"", "response format");
    AssertContains(handler.RequestBody, "\"type\": \"json_object\"", "json object response format");
    AssertContains(handler.RequestBody, "actionJsonSchema", "embedded native contract");
    AssertContains(handler.RequestBody, "add null guard before reward access", "embedded fix hint");
    AssertContains(handler.RequestBody, "Lobby.ActivityButton", "embedded snapshot target");
}

static async Task ModelEndpointClientParsesTextPayloadAndWritesTrace()
{
    var traceDir = Path.Combine(Path.GetTempPath(), "ai-testpilot-trace-" + Guid.NewGuid().ToString("N"));
    try
    {
        var response = """
        {
          "choices": [
            {
              "message": {
                "content": "{\"action\":\"wait\",\"waitMilliseconds\":250}"
              }
            }
          ]
        }
        """;

        var handler = new RecordingHttpMessageHandler(response);
        using var httpClient = new HttpClient(handler);
        var client = new ModelEndpointDecisionClient(
            httpClient,
            new ModelEndpointDecisionClientOptions
            {
                Endpoint = new Uri("https://model.example.test/decide"),
                RunId = "RUN-MODEL-TRACE",
                TraceDirectory = traceDir,
            });

        var action = await client.DecideAsync(
            new DecisionRequest(
                "wait for animation",
                BuildModelSnapshot(3),
                new[] { "click:Lobby.ActivityButton" }),
            CancellationToken.None);

        AssertEqual(ActionVerbs.Wait, action.Action, "text payload action");
        AssertEqual(250, action.WaitMilliseconds, "text payload wait");

        var tracePath = Path.Combine(traceDir, "step-0003-decision.json");
        if (!File.Exists(tracePath))
        {
            throw new InvalidOperationException("decision trace was not written.");
        }

        var trace = JsonSerializer.Deserialize<DecisionTraceRecord>(
            File.ReadAllText(tracePath),
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
        if (trace == null)
        {
            throw new InvalidOperationException("decision trace could not be parsed.");
        }

        AssertEqual("RUN-MODEL-TRACE", trace.RunId, "trace run id");
        AssertEqual("PASS", trace.Status, "trace status");
        AssertEqual(ActionVerbs.Wait, trace.Action?.Action, "trace action");
        AssertContains(trace.RequestJson, "\"previousSteps\"", "trace request");
    }
    finally
    {
        if (Directory.Exists(traceDir))
        {
            Directory.Delete(traceDir, recursive: true);
        }
    }
}

static async Task ModelEndpointClientRejectsUnsafeAction()
{
    var handler = new RecordingHttpMessageHandler("""{"action":"delete_project","target":"Assets"}""");
    using var httpClient = new HttpClient(handler);
    var client = new ModelEndpointDecisionClient(
        httpClient,
        new ModelEndpointDecisionClientOptions
        {
            Endpoint = new Uri("https://model.example.test/decide"),
        });

    await AssertThrowsAsync<InvalidOperationException>(
        () => client.DecideAsync(
                new DecisionRequest(
                    "try unsafe action",
                    BuildModelSnapshot(1),
                    Array.Empty<string>()),
                CancellationToken.None)
            .AsTask());
}

static Snapshot BuildModelSnapshot(int stepIndex)
{
    return new Snapshot
    {
        Scene = "Lobby",
        StepIndex = stepIndex,
        Ui = new[]
        {
            new UiElementSnapshot
            {
                AutomationId = "Lobby.ActivityButton",
                Name = "ActivityButton",
                Kind = "Button",
                Interactable = true,
            },
        },
        GameState = new GameStateSnapshot
        {
            Values = new Dictionary<string, string>
            {
                ["account"] = "qa_smoke_account",
            },
        },
    };
}

static void AssertEqual<T>(T expected, T actual, string label)
{
    if (!EqualityComparer<T>.Default.Equals(expected, actual))
    {
        throw new InvalidOperationException($"{label}: expected '{expected}', got '{actual}'.");
    }
}

static void AssertContains(string value, string expectedSubstring, string label)
{
    if (!value.Contains(expectedSubstring, StringComparison.Ordinal))
    {
        throw new InvalidOperationException($"{label}: expected '{expectedSubstring}' in '{value}'.");
    }
}

static void AssertThrows<TException>(Action action)
    where TException : Exception
{
    try
    {
        action();
    }
    catch (TException)
    {
        return;
    }

    throw new InvalidOperationException($"Expected exception {typeof(TException).Name}.");
}

static async Task AssertThrowsAsync<TException>(Func<Task> action)
    where TException : Exception
{
    try
    {
        await action();
    }
    catch (TException)
    {
        return;
    }

    throw new InvalidOperationException($"Expected exception {typeof(TException).Name}.");
}

sealed class RecordingHttpMessageHandler : HttpMessageHandler
{
    private readonly string responseJson;

    public RecordingHttpMessageHandler(string responseJson)
    {
        this.responseJson = responseJson;
    }

    public string RequestBody { get; private set; } = string.Empty;

    public HttpMethod? RequestMethod { get; private set; }

    public string AuthorizationHeader { get; private set; } = string.Empty;

    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        RequestMethod = request.Method;
        AuthorizationHeader = request.Headers.Authorization?.ToString() ?? string.Empty;
        RequestBody = request.Content == null
            ? string.Empty
            : await request.Content.ReadAsStringAsync(cancellationToken);

        return new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent(responseJson, Encoding.UTF8, "application/json"),
        };
    }
}
