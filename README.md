# Kibernet AI TestPilot

**Evidence-driven AI game QA for Unity.**

Kibernet AI TestPilot turns gameplay testing into a controlled engineering loop: capture a structured Unity state, choose an allowlisted action, detect and package failures, hand repair context to a coding agent, replay the exact scenario, and make the release decision from machine-readable evidence.

[![License: MIT](https://img.shields.io/badge/License-MIT-2ea44f.svg)](LICENSE)
![Unity 2021.3+](https://img.shields.io/badge/Unity-2021.3%2B-000000.svg)
![.NET 8](https://img.shields.io/badge/.NET-8.0-512BD4.svg)
![Status: Early Access](https://img.shields.io/badge/Status-Early%20Access-f59e0b.svg)
![Local Gate](https://img.shields.io/badge/PR%20Gate-Run--DevGate-0ea5e9.svg)

> [!IMPORTANT]
> AI TestPilot is an early-access engineering project. Its core, Unity package, smoke tests, evidence contracts, and package-release gates are implemented. Production use still requires a game-specific replay driver, real endpoint credentials and live-smoke evidence when a model is enabled, and host-project evidence for production Lua or repair workflows.

> [!NOTE]
> Required PR gate:
> 1. run `.\tools\Run-DevGate.ps1`
> 2. paste/attach `Temp\developer-gate-manifest.json` in PR notes
> 3. explain any skipped steps with reasons in PR description

## 项目简介

AI TestPilot 是一套面向 Unity 的 **证据驱动游戏质量工程平台**。它把“采集快照 → 决策执行 → 缺陷归档 → 修复交付 → 回放验证 → 发布准入”打造成一条可审计、可回放、可持续演进的闭环。

该项目不是“把 AI 放进 QA”这么浅层的功能叠加，而是通过工程化边界实现“AI 只在受控空间内参与决策”。你可以把它理解为：

- 自动采集可还原的游戏状态与上下文；
- 通过版本化动作规范与 allowlist 约束执行路径；
- 将缺陷、风险、修复证据结构化为可追踪资产；
- 将发布决策绑定到可验证的 artifact，而非团队主观判断。

### 典型适用场景

- 回归测试与缺陷复现：`Snapshot / UI / 日志 / 游戏状态`
- 规则或模型辅助的动作决策与执行
- 缺陷识别、风险分类与知识闭环沉淀
- 代理化修复流程：任务绑定、补丁预检、回放验证、回滚证明
- PR / Issue / Milestone 的发布就绪报告自动化

### 项目定位

- **可验证优先**：每条自动化结果都保留机器可读证据（JSON/Markdown/Manifest）
- **边界约束优先**：模型只能在可版本化的动作 schema 与 allowlist 下执行
- **发布可追溯**：报告、摘要、证据索引和门禁输出形成统一链路

### 使用说明（高层）

- 支持 Unity 2021.3+ 的脚本化验证与本地门禁
- 自动化覆盖 PR/Issue/Milestone 注入发布就绪内容
- 与修复环节对齐，降低上下文丢失与重复操作风险

### 合规与交付边界

- **授权协议**：MIT（[LICENSE](LICENSE)）
- **环境要求**：Windows PowerShell 5.1+ / .NET 8 / Git / Unity 2021.3+
- **生产前提**：接入真实 Replay Driver、真实模型调用链与生产凭据管理后再用于正式发布验证

## Why AI TestPilot

Game QA automation usually breaks at the boundaries between UI state, gameplay APIs, flaky replay steps, bug reports, repair tools, and CI. AI TestPilot provides one auditable contract across those boundaries.

- **Model-agnostic exploration**: Use deterministic policies, a native JSON model endpoint, or an OpenAI-compatible chat-completions gateway.
- **Constrained execution**: Model output is parsed against a versioned action schema and rejected unless it matches the allowlist.
- **Reproducible bugs**: Logs, state, steps, risk, source context, and artifacts are packaged into durable JSON and Markdown.
- **Repair-agent handoff**: Generate task-bound context, acceptance criteria, expected outputs, patch preflight, retest, and rollback evidence.
- **Learning from prior failures**: Persist a bug knowledge graph with module, failure-type, and fix-history signals.
- **Evidence-backed releases**: Gate releases on validated artifacts rather than optimistic status flags.

## System Flow

```mermaid
flowchart LR
    Game["Unity game under test"] --> Capture["Snapshot, UI, state, and logs"]
    Capture --> Decide["Rule-based or model decision client"]
    Decide --> Guard["Versioned schema and action allowlist"]
    Guard --> Execute["Unity action executor"]
    Execute --> Game
    Capture --> Detect["Bug detection and risk classification"]
    Detect --> Package["Bug package and knowledge graph"]
    Package --> Repair["Repair-agent handoff"]
    Repair --> Retest["Replay, retest, and rollback proof"]
    Retest --> Gate["Release evidence and policy gate"]
```

The runtime loop is intentionally narrow: an AI can propose an action, but it cannot bypass the product-owned schema, allowlist, executor, or release policy.

## Capabilities

| Area | What is implemented | Primary evidence |
| --- | --- | --- |
| Unity observation | `AutomationId`, UI extraction, game-state capture, log collection, snapshot serialization | Snapshot JSON and schema regression checks |
| Decision loop | Deterministic client, provider-neutral HTTP client, OpenAI-compatible request wrapper, prior fix hints | Per-step decision traces |
| Safe execution | Versioned action contract and allowlisted actions such as `click`, `wait`, login, scene entry, reward, and fishing flows | Parsed-action and validation results |
| Bug intelligence | Detection, risk classification, bug packages, persistent knowledge graph, recurring-module ranking | JSON and Markdown bug artifacts |
| Repair workflow | Structured repair task, agent handoff, output import, patch safety preflight, apply/retest/rollback probes | Task-bound patch and retest manifests |
| Replay integration | Configurable replay profiles and a production-driver contract for real game APIs | Driver descriptors and targeted retest reports |
| Release engineering | Repo validation, Unity batch validation, GitHub Actions, Azure Pipelines, risk policy, evidence index | Stable release-evidence bundle |
| Lua repair support | Static findings, deterministic sandbox patching, production evidence intake contract | Analysis, patch-plan, and readiness manifests |

## Quick Start

### Prerequisites

- Windows PowerShell 5.1 or PowerShell 7+
- .NET 8 SDK
- Unity 2021.3 LTS for package import and batchmode validation
- Git

### Clone and validate the core

```powershell
git clone https://github.com/kibernet/AITestPilot.git
cd AITestPilot
.\tools\Validate-AITestPilot.ps1
```

To include the CI gate path-resolution regression checks in the local validation run:

```powershell
.\tools\Validate-AITestPilot.ps1 -RunCiGatePathRegression
```

Quick command lookup (local development):

```text
.\tools\Run-DevGate.ps1
.\tools\Invoke-AITestPilotCiGate.ps1
.\tools\Invoke-AITestPilotLocalPreflight.ps1
.\tools\Validate-AITestPilot.ps1
.\tools\Validate-AITestPilot.ps1 -RunCiGatePathRegression
.\tools\Validate-AITestPilot.ps1 -RunCiGatePathRegressionStrict
.\tools\Validate-AITestPilot.ps1 -RunReleaseDocsFreshnessRegression
.\tools\Validate-AITestPilot.ps1 -RunReplayProfileSchemaCheck -ReplayProfileJsonPath Temp\release-evidence\latest\sample-business-replay-profile.json
Get-Help .\tools\Validate-AITestPilot.ps1 -Full
Get-Help .\tools\Test-AITestPilotCiGatePathResolution.ps1 -Full
.\tools\Run-DevGate.ps1 -SummaryPath Temp\dev-gate-summary.json -GeneratePrChecklist
```

See full local workflow cheat sheet: `.\docs\local-workflow-cheat-sheet.md`
It includes a minimum baseline command sequence and a PR/release preflight checklist for quick verification.

For one-click local preflight:

```powershell
.\tools\Invoke-AITestPilotLocalPreflight.ps1
```

For a release-grade preflight (release pipeline + strict checks + docs-freshness regression):

```powershell
.\tools\Invoke-AITestPilotReleasePreflight.ps1
```

Generate a ready-to-paste milestone/PR readiness report:

```powershell
.\tools\Invoke-AITestPilotReleaseReadinessReport.ps1 -OutputPath Temp\release-readiness-report.md -IncludeRecommendedCommands
```

For strict automation (non-zero exit on any WARN/FAIL item):

```powershell
.\tools\Invoke-AITestPilotReleaseReadinessReport.ps1 -OutputPath Temp\release-readiness-report.md -IncludeRecommendedCommands -FailOnWarning
```

For machine-readable consumption in CI/automation:

```powershell
.\tools\Invoke-AITestPilotReleaseReadinessReport.ps1 -OutputPath Temp\release-readiness-report.md -SummaryOutputPath Temp\release-readiness-summary.json
```

One-command bundle (report + summary + PR snippet):

```powershell
.\tools\Invoke-AITestPilotReleaseReadinessBundle.ps1 -ReportOutputPath Temp\release-readiness-report.md -SummaryJsonPath Temp\release-readiness-summary.json -SnippetOutputPath Temp\release-readiness-pr-snippet.md
```

Structured automation consumption:

```powershell
$result = .\tools\Invoke-AITestPilotReleaseReadinessBundle.ps1 -ReportOutputPath Temp\release-readiness-report.md -SummaryJsonPath Temp\release-readiness-summary.json -SnippetOutputPath Temp\release-readiness-pr-snippet.md -PassThru
$result.GateStatus
```

Generate a PR-ready copy block from the machine-readable summary:

```powershell
.\tools\Invoke-AITestPilotReleaseReadinessSummary.ps1 -SummaryJson Temp\release-readiness-summary.json -OutputPath Temp\release-readiness-pr-snippet.md
```

One-command handoff block generation (prints to console by default):

```powershell
.\tools\Set-AITestPilotReleaseReadinessMilestoneNotes.ps1 -DryRun
```

Export the handoff block directly into a file (paste-ready):

```powershell
.\tools\Export-AITestPilotReleaseReadinessHandoff.ps1 -OutputPath Temp\release-readiness-handoff-block.md
```

Push the same generated block directly into a PR body / issue body / milestone description:

```powershell
.\tools\Set-AITestPilotReleaseReadinessMilestoneNotes.ps1 -PullRequestNumber 123
.\tools\Set-AITestPilotReleaseReadinessMilestoneNotes.ps1 -IssueNumber 456
.\tools\Set-AITestPilotReleaseReadinessMilestoneNotes.ps1 -MilestoneNumber 7
```

Append flags are forwarded to the readiness bundle generator (`-IncludeRecommendedCommands`, `-RequireReleasePipeline`, `-FailOnWarning`, `-IncludeFailedOnly`).

For a lighter local preflight variant, add `-SkipReleasePipeline`:

```powershell
.\tools\Invoke-AITestPilotReleasePreflight.ps1 -SkipReleasePipeline
```

To include the optional release-docs-freshness regression matrix in that flow:

```powershell
.\tools\Invoke-AITestPilotLocalPreflight.ps1 -RunReleaseDocsFreshnessRegression
```

For strict alias-conflict assertions (including `OutputPath` + `SummaryPath` conflict rejection), run:

```powershell
.\tools\Validate-AITestPilot.ps1 -RunCiGatePathRegressionStrict
```

This strict mode validates the regression in a stricter way, including native command binding conflict failures.

For stronger release-docs-freshness coverage (including malformed prior manifests and drift edge cases), run:

```powershell
.\tools\Validate-AITestPilot.ps1 -RunReleaseDocsFreshnessRegression
```

This mode is recommended before release-milestone PRs and before changing release-docs-freshness-related probe logic.

You can also inspect full parameter docs with:

```powershell
Get-Help .\tools\Validate-AITestPilot.ps1 -Full
```

For day-one onboarding and a one-command smoke path, run:

```powershell
.\tools\Invoke-AITestPilotQuickStart.ps1
```

Then run:

```powershell
.\tools\Invoke-AITestPilotQuickStartChecklist.ps1
```

For a post-change revalidation loop (core validation + optional patch apply + repair retest), run:

```powershell
.\tools\Invoke-AITestPilotRepairLoop.ps1
```

For a one-command local developer gate before PR/push, run:

```powershell
.\tools\Invoke-AITestPilotDeveloperGate.ps1
```

Or use the shorter command:

```powershell
.\tools\Run-DevGate.ps1
```

If you need a machine-readable copy for CI artifacts or local archival, use:

```powershell
.\tools\Run-DevGate.ps1 -SummaryPath Temp\dev-gate-summary.json
```

If you also want a copy-paste PR checklist block, use:

```powershell
.\tools\Run-DevGate.ps1 -SummaryPath Temp\dev-gate-summary.json -GeneratePrChecklist -PrChecklistPath Temp\pr-validation-checklist.md
Get-Content Temp\pr-validation-checklist.md
```

If you need the manifest written to a custom location, use:

```powershell
.\tools\Run-DevGate.ps1 -ManifestPath Temp\custom-developer-gate-manifest.json
```

`-ManifestPath` and `-SummaryPath` both accept absolute paths; otherwise paths are resolved relative to repository root.
`-OutputPath` is now accepted as an alias for `-SummaryPath` (for CI-style parity).
`-QuickStartOutputDir`, `-RepairLoopOutputDir`, and `-RepairLoopEvidenceBundleDir` are also resolved against repository root when relative (absolute values are preserved).

CI-friendly mode (optional, writes `Temp\ci-gate-summary.json` and exits non-zero on non-pass unless `-AllowPartialFail` is set):

```powershell
.\tools\Invoke-AITestPilotCiGate.ps1
```

To write to a custom summary path:

```powershell
.\tools\Invoke-AITestPilotCiGate.ps1 -SummaryPath Temp\ci-gate-summary.json
```

`-OutputPath` is also accepted as an alias of `-SummaryPath` for CI summary output.

To read/write a custom developer gate manifest path:

```powershell
.\tools\Invoke-AITestPilotCiGate.ps1 -ManifestPath Temp\custom-developer-gate-manifest.json
```

The command writes a quick-start manifest to:

```text
Temp\quick-start\quick-start-manifest.json
```

The developer gate writes:

```text
Temp\developer-gate-manifest.json
```

You can also run a local path-resolution regression check (relative/absolute paths + `OutputPath` alias + whitespace-in-path cases):

```powershell
.\tools\Test-AITestPilotCiGatePathResolution.ps1
```

To run strict path-regression assertions (including strict alias conflict checks), use:

```powershell
.\tools\Test-AITestPilotCiGatePathResolution.ps1 -StrictOutputPathAlias
```

And inspect parameter docs with:

```powershell
Get-Help .\tools\Test-AITestPilotCiGatePathResolution.ps1 -Full
```

This command builds the .NET solution, builds the model-endpoint and Lua-analysis probes, runs the dependency-free smoke suite, and validates the Unity package structure.

`Run-DevGate.ps1` also prints a machine-readable summary block that can be copied directly into the PR template, including quick start and repair-loop statuses.

### Install the Unity package

Add the package through Unity Package Manager with the Git URL:

```text
https://github.com/kibernet/AITestPilot.git?path=/unity/com.kibernet.ai-testpilot#main
```

For local development, use **Package Manager -> Add package from disk** and select:

```text
unity/com.kibernet.ai-testpilot/package.json
```

Then:

1. Add `AutomationId` to UI objects that should be visible to the test agent.
2. Open **Tools -> Kibernet -> AI TestPilot**.
3. Capture and inspect a snapshot.
4. Start with the deterministic rule-based loop before enabling a live model endpoint.
5. Integrate a production replay driver before treating package evidence as proof of real game behavior.

### Validate Unity import and the sample scene

```powershell
.\tools\Validate-UnityPackageImport.ps1
```

The command imports the package into a temporary Unity project, compiles Runtime and Editor assemblies, runs a generated sample scene, exercises the decision loop and bug flow, and writes release evidence under `Temp/release-evidence/latest`.

## 落地与验收（7/30 计划）

给团队提供一条可执行的上线节奏示例：先跑基础验证，再补齐 PR 发布门禁，最后完成正式发布闭环。

- **第 1-3 天（项目接入）**
  - 运行 `\.\tools\Validate-AITestPilot.ps1` 与 `\.\tools\Invoke-AITestPilotLocalPreflight.ps1`
  - 确认输出目录（默认 `Temp\`）并固定记录 `Manifest / Summary`
  - 完成 Unity 首次接入：添加 `AutomationId`，验证 sample scene 与关键驱动点

- **第 4-7 天（PR 阶段）**
  - 在 PR 模板中附 `Temp\developer-gate-manifest.json` 与 `Temp\dev-gate-summary.json`
  - 建立故障处理回放；将主要失败归类并提交修复计划
  - 完成 Replay Driver 集成的最小闭环（可回放场景 + 回归验证）

- **第 8-30 天（发布就绪）**
  - 完成路径回归与严格别名冲突检测：`Run-CiGatePathRegression` / `Run-CiGatePathRegressionStrict`
  - 形成发布决策台账与发布证据矩阵
  - 运行 `\.\tools\Invoke-AITestPilotReleasePipeline.ps1`，确认可复用发布证据与清单

### 落地与验收清单

- `Temp\developer-gate-manifest.json`：开发门禁 manifest
- `Temp\dev-gate-summary.json`：PR 级开发门禁摘要
- `Temp\ci-gate-summary.json`：CI 门禁摘要
- `Temp\release-evidence\latest\`：发布证据集合
- `artifacts\ai-testpilot-release\latest\`：发布制品输出目录

更多说明请参考：
- [Rollout & Release Checklist](docs/rollout-and-release-checklist.md)
- [Release Gate Review Checklist](docs/release-gate-review-checklist.md)

## Model Endpoint Integration

AI TestPilot supports two request formats:

- `NativeJson` for a provider-neutral decision endpoint.
- `OpenAICompatibleChatCompletions` for OpenAI-compatible or local gateways.

Create a settings asset from Unity:

```text
Tools/Kibernet/AI TestPilot/Create Model Endpoint Settings
```

The asset stores endpoint and model configuration but never stores the API key itself. Secrets are referenced through environment variables, and live requests are disabled by default.

For contracts, configuration, traces, retry policy, failure classification, and live-smoke requirements, see [Model Endpoint Bridge](docs/model-endpoint.md).

## Production Replay Integration

Real projects bind business actions through `IGameActionReplayDriver` or `HookedGameActionReplayDriver`. The standard integration surface covers account preparation, login, scene entry, reward claiming, and fishing; projects can register additional replay handlers without weakening the action boundary.

Generate a host-project starter kit:

```powershell
.\tools\New-AITestPilotProductionDriverBindingKit.ps1 `
  -DriverTypeName "Your.Game.Tests.ProductionReplayDriver" `
  -DriverId "your_game.production_replay"
```

The generated hooks fail closed until real game APIs and state verification are implemented. See [Production Replay Driver Integration](docs/integration/production-driver.md).

## Evidence, Safety, and Trust Boundaries

AI TestPilot is designed so that fixtures prove contracts without being presented as production proof.

- Unknown or malformed actions fail before touching the game.
- API keys are referenced by environment-variable name and are not serialized into evidence.
- External patches are checked for absolute paths, traversal, repository metadata, sensitive files, and out-of-scope targets.
- Main-worktree patch application requires an explicit switch, a clean baseline, accepted external-agent provenance, and a passing preflight.
- Retest and rollback results are recorded separately from patch generation.
- Fixture, sample, skipped, contract-mode, and real-provider evidence are explicitly distinguished.
- Production hard mode rejects unbound replay drivers, missing production Lua proof, or missing required live-endpoint evidence.

These boundaries are part of the release contract, not documentation-only promises. See [Architecture](docs/architecture.md) and [CI Release Pipeline](docs/ci-release-pipeline.md).

## CI and Release Gates

Run the full release pipeline with:

```powershell
.\tools\Invoke-AITestPilotReleasePipeline.ps1
```

The pipeline produces a stable artifact bundle under:

```text
artifacts/ai-testpilot-release/latest
```

Repository workflows are provided for:

- GitHub Actions on a self-hosted Windows runner with Unity 2021.3.
- Azure Pipelines on a self-hosted Windows pool with Unity 2021.3.

Optional hard-mode switches can require a production replay driver, production Lua patch evidence, and a real live-model smoke test. The default package pipeline deliberately does not claim that those host-project integrations already exist.

## Repository Layout

```text
AITestPilot/
├─ src/Kibernet.AITestPilot.Core/          # Model-agnostic contracts and workflow logic
├─ tests/Kibernet.AITestPilot.Core.SmokeTests/
├─ unity/com.kibernet.ai-testpilot/        # Unity 2021.3 UPM package
├─ tools/                                  # Validation, evidence, repair, and release scripts
├─ docs/                                   # Architecture and integration documentation
├─ .github/workflows/                      # GitHub Actions release gate
└─ .azure-pipelines/                       # Azure Pipelines release gate
```

## Project Status

The current release is `0.1.0` and should be treated as early access.

**Ready today:**

- Core and Unity package development
- Deterministic exploration and offline model-contract validation
- Bug packaging, knowledge graph persistence, repair-task generation, and guarded retest workflows
- Package-level CI evidence and release-gate development

**Requires host-project integration:**

- Real login, account, gameplay, reward, and fishing APIs
- Real model credentials and provider smoke evidence when live decisions are required
- Real production Lua analysis, patch, retest, and rollback evidence
- Production repair-agent output against an actual game codebase

See the [Roadmap](docs/roadmap.md) for the implementation boundary and next milestones.

For contribution expectations and PR checklist, see [CONTRIBUTING.md](CONTRIBUTING.md).

## Contributing

Issues and pull requests are welcome. Contributions should preserve the project's core invariants:

1. Keep model output behind a versioned, validated action contract.
2. Do not serialize credentials or secret values into logs or evidence.
3. Distinguish fixture proof from real production evidence.
4. Add deterministic validation for new behavior.
5. Keep release-gate failures actionable and machine-readable.

Before opening a pull request, run:

```powershell
.\tools\Validate-AITestPilot.ps1
```

Unity-facing changes should also pass `Validate-UnityPackageImport.ps1` on Unity 2021.3.

## Documentation

- [Architecture](docs/architecture.md)
- [Model Endpoint Bridge](docs/model-endpoint.md)
- [Production Replay Driver Integration](docs/integration/production-driver.md)
- [Quick Start Demo](docs/quick-start-demo.md)
- [CI Release Pipeline](docs/ci-release-pipeline.md)
- [Rollout & Release Checklist](docs/rollout-and-release-checklist.md)
- [Release Gate Review Checklist](docs/release-gate-review-checklist.md)
- [Roadmap](docs/roadmap.md)
- [Original Product Specification](Kibernet_AI_TestPilot_FULL_SPEC.md)

## License

Kibernet AI TestPilot is released under the [MIT License](LICENSE). Commercial use, modification, distribution, sublicensing, and use in closed-source products are permitted under the license terms.

