# Kibernet AI TestPilot

Kibernet AI TestPilot is a Unity game QA automation system. The repo currently contains the first implementation slice:

- `src/Kibernet.AITestPilot.Core`: model-agnostic .NET core for snapshots, action whitelisting, decision loops, bug packaging, bug knowledge graph, and release gates.
- `tests/Kibernet.AITestPilot.Core.SmokeTests`: dependency-free smoke tests that exercise the core loop and bug flow.
- `unity/com.kibernet.ai-testpilot`: Unity 2021.3 UPM package with `AutomationId`, snapshot capture, UI extraction, log collection, action execution, rule-based exploration, bug prompt export, and an editor window.
- `Kibernet_AI_TestPilot_FULL_SPEC.md`: original product specification.

## Validate

Run from the repo root:

```powershell
.\tools\Validate-AITestPilot.ps1
```

The script builds the .NET solution, runs the smoke tests, and checks the Unity package shape. This is repo-side validation; Unity editor import validation is still a separate target.

To validate Unity package import, compilation, and the generated sample-scene automation loop with Unity 2021.3:

```powershell
.\tools\Validate-UnityPackageImport.ps1
```

That script writes scene-level evidence to `Temp\ai-testpilot-scene-validation.json`, including snapshot JSON schema evidence, `multiStepRunner`, `runReports`, a persisted `bugPackage`, a persisted `bugKnowledgeGraph`, a `retestReport`, a structured `repairTask`, a repair-agent handoff, repair-agent run tracking, `productionReplayIntegration`, and `releaseEvidence`. It also copies the current evidence, bug package JSON/Markdown, bug knowledge graph JSON/Markdown, repair task JSON/Markdown, repair-agent handoff JSON/Markdown, repair-agent run JSON/Markdown, production replay integration checklist JSON/Markdown, and Unity logs into `Temp\release-evidence\latest` with a `manifest.json` summary.

To retest a specific generated repair task:

```powershell
.\tools\Invoke-AITestPilotRepairRetest.ps1
```

By default it reads `Temp\release-evidence\latest\repair-task.json`, replays the recorded reproduction steps in Unity batchmode, and writes `repair-retest.json` plus `repair-retest-manifest.json` into the same evidence bundle.
The targeted retest also creates an editable replay profile asset in the temporary Unity project and exports `sample-business-replay-profile.json` into the evidence bundle.

To validate repair-agent patch output ingestion:

```powershell
.\tools\Invoke-AITestPilotRepairAgentPatchOutputImport.ps1 -GenerateSampleOutput
```

By default it reads `Temp\release-evidence\latest\repair-agent-run.json`, validates `repair-agent.patch` plus `repair-agent-summary.md`, and writes `repair-agent-patch-output-manifest.json`. The release pipeline uses `-GenerateSampleOutput` to prove the import and gate path deterministically without claiming that an external Cursor repair agent has already run.
For real external repair-agent output, the run artifact must be updated to `status=EXTERNAL_AGENT_COMPLETED`, `agentLaunched=true`, `patchOutputStatus=PRODUCED`, required patch outputs marked `produced=true`, and the import must be called with `-ConfirmExternalAgentCompleted`.

To prove pending external runs cannot be promoted just because patch files exist:

```powershell
.\tools\Invoke-AITestPilotRepairAgentExternalCompletionFailureProbe.ps1
```

That probe writes `repair-agent-external-completion-failure-probe-manifest.json` and expects `external_agent_unverified` output to be rejected while the run remains `AWAITING_EXTERNAL_AGENT`.

To prove real external patch import is not tied to the deterministic sample null-guard snippet:

```powershell
.\tools\Invoke-AITestPilotRepairAgentGenericPatchImportProbe.ps1
```

That probe imports a verified `external_agent` patch that does not contain `reward == null`, preflights it, and writes `repair-agent-generic-patch-import-probe-manifest.json` while keeping `mainRepositoryPatchApplied=false`.

To prove the same apply path against a clean candidate made from the current source snapshot:

```powershell
.\tools\Invoke-AITestPilotRepairAgentSourceSnapshotApplyValidate.ps1
```

That probe copies the current source tree into a clean temporary git repository, applies a verified external-agent patch through the repository apply guard, runs `Validate-AITestPilot.ps1` inside the candidate repository, generates rollback evidence that includes newly added files, applies the rollback, and verifies the candidate repository is clean while keeping `mainRepositoryPatchApplied=false`.

To record whether the current main worktree is ready for real repair-agent patch application:

```powershell
.\tools\Invoke-AITestPilotMainWorktreeApplyReadiness.ps1
```

That readiness check reads the source snapshot apply/validate proof, records the main repository `git status`, filters generated evidence directories, and writes `repair-agent-main-worktree-apply-readiness-manifest.json`. It records either `readyForMainRepositoryApply=false` with blocking reasons such as `dirty_worktree` and `untracked_source_files`, or `readyForMainRepositoryApply=true` once the source baseline is clean. It never applies a patch by itself and keeps `mainRepositoryPatchApplied=false`.

To prove the explicit apply/retest/rollback path against this main worktree:

```powershell
.\tools\Invoke-AITestPilotRepairAgentMainWorktreeApplyRetestRollback.ps1
```

That probe requires the main worktree readiness manifest to be clean and ready. It imports a verified `external_agent` patch in an isolated evidence bundle, preflights it, applies it to the real main worktree through `Invoke-AITestPilotRepairAgentRepositoryPatchApplyGuard.ps1 -ApplyToRepository`, runs repo validation and repair retest before rollback, applies the generated rollback patch, and verifies the main worktree is clean again. The manifest records `mainRepositoryPatchApplied=true` for the probe and `mainRepositoryPatchPersisted=false` after rollback.

To preflight an imported repair-agent patch before any repository application:

```powershell
.\tools\Invoke-AITestPilotRepairAgentExternalPatchPreflight.ps1
```

The preflight parses unified-diff target paths, rejects absolute paths, path traversal, `.git` metadata, sensitive file names, and paths outside the allowed repo/project prefixes, then writes `repair-agent-external-patch-preflight-manifest.json`. The release pipeline also runs `Invoke-AITestPilotRepairAgentExternalPatchPreflightFailureProbe.ps1` to prove unsafe `../` paths are blocked before any apply step.

To evaluate whether an imported patch is allowed to touch the real repository worktree:

```powershell
.\tools\Invoke-AITestPilotRepairAgentRepositoryPatchApplyGuard.ps1
```

Without `-ApplyToRepository`, this only writes `repair-agent-repository-patch-apply-guard-manifest.json`, worktree status snapshots, and a rollback plan. Real repository application requires the explicit switch, a clean source worktree, external-agent patch output, and a preflight manifest that allows repository apply; the deterministic sample path is intentionally blocked.

To prove the positive apply/rollback path without touching this repository:

```powershell
.\tools\Invoke-AITestPilotRepairAgentRepositoryPatchApplyCleanProbe.ps1
```

That probe creates a clean temporary git repository, marks a temporary repair-agent run copy as externally completed, imports the patch output as `external_agent`, runs the same repository apply guard with `-ApplyToRepository`, verifies the patch changed the fixture, generates a rollback patch, applies the rollback, and records `mainRepositoryPatchApplied=false`.

To prove the post-apply retest sequence on that positive path:

```powershell
.\tools\Invoke-AITestPilotRepairAgentRepositoryPatchApplyCleanRetest.ps1
```

That probe applies the verified external-agent patch in a clean temporary git repository, runs the post-patch repair retest before rollback, records the retest result, then applies the generated rollback patch and verifies the temporary repository is clean. It also records `mainRepositoryPatchApplied=false`.

To validate patch application and post-patch retest orchestration for the imported patch output:

```powershell
.\tools\Invoke-AITestPilotRepairAgentPatchApplyRetest.ps1
```

This applies the deterministic sample patch inside `Temp\release-evidence\latest\repair-agent-patch-apply-sandbox`, runs the post-patch retest command, and writes `repair-agent-patch-apply-retest-manifest.json`. It intentionally records `repositoryPatchApplied=false` so the evidence does not imply that real project source code was changed by the sample patch.

For a real game project, point the retest at a production replay driver type:

```powershell
.\tools\Invoke-AITestPilotRepairRetest.ps1 -GameReplayDriverType "Your.Game.Tests.ProductionReplayDriver"
```

That type must implement `IGameActionReplayDriver`; if it also implements `IGameActionReplayStateProvider`, the retest evidence records account, login, scene, reward, and fishing counters.
For the hooks-based production adapter path, see `docs\integration\production-driver.md` and `unity\com.kibernet.ai-testpilot\Samples~\ProductionReplayDriver\ProductionReplayDriverTemplate.cs`.
Scene validation also creates `Assets/AITestPilotGenerated/ProductionReplayIntegrationPlan.asset` and exports `production-replay-integration-checklist.json` plus `production-replay-integration-checklist.md` into the evidence bundle. That checklist is intentionally marked `TEMPLATE_READY` with `realProjectBound=false`; it is a handoff artifact for wiring real game APIs, not proof that a production game driver has already been implemented.

To prove that driver failures are surfaced with actionable hook diagnostics:

```powershell
.\tools\Invoke-AITestPilotReplayDriverFailureProbe.ps1
```

That probe intentionally fails `claim_reward` and writes `repair-driver-failure-manifest.json` plus Unity failure logs into the evidence bundle.

To import a replay profile JSON back into an editable Unity asset:

```powershell
.\tools\Invoke-AITestPilotReplayProfileImport.ps1
```

By default it reads `Temp\release-evidence\latest\sample-business-replay-profile.json`, imports it to `Assets/AITestPilotGenerated/ImportedReplayProfile.asset` inside the temporary Unity project, exports a normalized JSON copy, and writes `replay-profile-import-manifest.json` into the evidence bundle.

To run the full repo-side release gate over the evidence bundle:

```powershell
.\tools\Invoke-AITestPilotReleaseGate.ps1
```

The gate requires scene validation, repair-agent patch output import, external completion failure probe, generic external patch import probe, source snapshot apply/validate/rollback probe, external patch safety preflight, unsafe-patch failure probe, repository patch apply guard, clean temporary repository apply/rollback probe, clean temporary repository apply/retest/rollback probe, patch apply/retest orchestration, targeted repair retest, driver descriptor/configuration, the negative driver failure probe, replay profile import, and all listed evidence files. To prove the gate blocks incomplete evidence:

```powershell
.\tools\Invoke-AITestPilotReleaseGateFailureProbe.ps1
```

For CI, run the full pipeline wrapper:

```powershell
.\tools\Invoke-AITestPilotReleasePipeline.ps1
```

It runs the full chain and exports stable artifacts to `artifacts\ai-testpilot-release\latest`. See `docs\ci-release-pipeline.md`.

For a real model endpoint, use the generic HTTP/JSON `ModelEndpointDecisionClient` in the core library. It posts the goal, snapshot, previous steps, prior fix hints, allowed action list, and action JSON schema to a configured endpoint, validates the returned action before execution, and can write per-step trace files. See `docs\model-endpoint.md`.
The Unity package also includes a `ModelEndpointSettings` asset and editor entry under `Tools/Kibernet/AI TestPilot/Create Model Endpoint Settings`; sample-scene validation proves the settings asset, offline request contract, and action parser without calling an external provider.
For OpenAI-compatible or local chat-completions gateways, use `RequestFormat=OpenAICompatibleChatCompletions` or the Unity menu `Tools/Kibernet/AI TestPilot/Create OpenAI-Compatible Model Endpoint Settings`.

To prove the model endpoint contract and trace path for CI without calling an external model:

```powershell
.\tools\Invoke-AITestPilotModelEndpointTraceProbe.ps1
```

The full release pipeline runs this probe before the release gate.
To generate provider preset diagnostics without making a live network request:

```powershell
.\tools\Invoke-AITestPilotModelEndpointProviderDiagnostics.ps1
```

The diagnostics manifest records supported presets for native JSON, OpenAI chat completions, OpenAI-compatible gateways, and local OpenAI-compatible gateways. It never serializes API key values; it records only whether the relevant environment variables are configured.
To prove live endpoint failures are classified before hitting a real provider:

```powershell
.\tools\Invoke-AITestPilotLiveModelEndpointFailureProbe.ps1
```

The failure probe uses a deterministic HTTP 401 response, expects `failureCategory=auth`, and writes `live-model-endpoint-failure-probe-manifest.json` plus a failed decision trace into release evidence.
Failure manifests also include `failureRemediation` and `failurePolicy`, so CI artifacts point to concrete next steps and whether the failure should be retried or escalated to a configuration, network, quota, gateway, or model-owner path.
For explicit live endpoint validation, set `AITESTPILOT_LIVE_MODEL_ENDPOINT`, `AI_TESTPILOT_MODEL_API_KEY`, and `AITESTPILOT_LIVE_MODEL`, then run:

```powershell
.\tools\Invoke-AITestPilotLiveModelEndpointSmoke.ps1 -RequireLive
```

Production CI can require that same live check through `.\tools\Invoke-AITestPilotReleasePipeline.ps1 -RequireLiveModelEndpointSmoke`.
When a configured live smoke fails with a retryable `failurePolicy`, the wrapper retries within `-MaxPolicyRetries` and caps waits with `-MaxRetryBackoffSeconds`. The final manifest records `retryPolicyExecuted`, `attemptCount`, and per-attempt status so release artifacts prove whether retry policy actually ran.

## Unity Package Install

In a Unity project, add the package by local path:

```json
"com.kibernet.ai-testpilot": "file:E:/code/kibernet/AITestPilot/unity/com.kibernet.ai-testpilot"
```

Then:

1. Add `AutomationId` components to UI objects that should be visible to the AI.
2. Open `Tools/Kibernet/AI TestPilot`.
3. Capture snapshots, export snapshot JSON, or generate `bug_fix.md` for Cursor.
4. Add `DecisionLoopRunner` to run the deterministic local exploration loop.

## Current Boundary

Implemented now:

- Snapshot, UI, game-state, and log DTOs.
- Whitelisted actions: `click`, `wait`, `prepare_account`, `login`, `enter_scene`, `close_popup`, `claim_reward`, `play_fishing`, `finish`.
- Bug detection, bug package creation from logs, and persistent bug package JSON/Markdown evidence.
- Bug knowledge graph fix suggestion plus persistent graph JSON/Markdown evidence with module and failure-type risk ranking.
- Release gate abstraction.
- Unity SDK adapter and editor bridge.
- Unity batch validation for a generated sample scene: snapshot capture, rule-based click, action execution, bug packaging, and graph fix reuse.
- Unity batch validation for `DecisionLoopRunner` multi-step execution with max-step boundary evidence.
- Snapshot JSON schema regression check for the AI model input contract.
- Persistent report models for AI runs, bug retests, and release evidence.
- Structured repair task generation for Cursor or another fixing agent.
- Cursor-ready repair-agent handoff JSON/Markdown with required context files and retest command.
- Repair-agent run tracking JSON/Markdown with explicit external-agent boundary and expected patch output slots.
- Repair-agent patch output import manifest for patch and summary artifacts, with deterministic sample validation in CI.
- Repair-agent external completion provenance guard and negative probe proving pending runs cannot be promoted by patch files alone.
- Generic external repair-agent patch import probe proving real external patch import is not tied to the deterministic sample null-guard snippet.
- Source snapshot apply/validate/rollback probe proving verified external patches can apply to a clean candidate made from the current source tree, pass repo validation, and roll back newly added files.
- External repair-agent patch preflight manifest with target-path safety checks and a negative path-traversal failure probe.
- Repository patch apply guard manifest with explicit apply switch, clean-worktree, external-agent source, and rollback-plan evidence.
- Clean temporary repository apply/rollback probe proving the external-agent apply path and rollback patch mechanics without mutating the main repository.
- Clean temporary repository apply/retest/rollback probe proving post-apply retest runs before rollback without mutating the main repository.
- Repair-agent patch apply/retest manifest with sandbox patch application, explicit `repositoryPatchApplied=false`, and post-patch retest evidence.
- Targeted Unity batch retest from a repair-task JSON.
- Runtime replay adapter registry and configurable replay profile for game-specific action playback.
- Runtime `IGameActionReplayDriver` contract for account setup, login, scene entry, activity reward, and fishing flows.
- Runtime game replay driver registry and batch retest driver type selection.
- Hooks-based production driver adapter and copyable integration template.
- Production replay integration plan asset and release-evidence checklist for real game driver handoff.
- Driver capability/configuration descriptor recorded in repair retest evidence.
- Negative replay-driver failure probe with driver, handler, action, target, and step diagnostics.
- Repo-side release gate that blocks missing driver descriptor, missing negative probe, failed retest, or missing evidence files.
- CI release pipeline wrapper with stable artifact output under `artifacts\ai-testpilot-release\latest`.
- Generic HTTP/JSON model endpoint decision client with action schema validation and per-step trace artifacts.
- Model endpoint trace probe included in release evidence and enforced by the repo-side release gate.
- Unity `ModelEndpointSettings` asset, editor creation flow, request-contract builder, response parser, and batch evidence.
- Prior fix hints included in model endpoint decision requests and release-gate evidence.
- Optional live model endpoint smoke with release-gate enforcement when explicitly required.
- OpenAI-compatible chat-completions request wrapper for model gateways that do not accept the native AI TestPilot JSON contract directly.
- Model endpoint provider preset diagnostics for native, OpenAI, OpenAI-compatible, and local OpenAI-compatible gateways.
- Deterministic live model endpoint failure probe with auth failure classification and trace evidence.
- Live model endpoint failure remediation hints for auth, rate limit, request/endpoint, provider outage, timeout, network, empty response, response contract, and configuration failures.
- Live model endpoint retry/escalation policy in failure evidence.
- Policy-driven live model endpoint retry execution with per-attempt evidence.
- Sample business replay path covering account setup, login, `enter_scene`, activity reward, and `play_fishing`.
- Persisted replay profile asset plus JSON export for CI evidence.
- Replay profile JSON import back into an editable Unity `ActionReplayProfile` asset.

Not implemented yet:

- Cloud/local cluster orchestration.
- Provider-specific retry tuning beyond the current bounded policy-driven wrapper.
- Lua static analysis and automatic code patching.
- Prefab mutation and retest orchestration across Unity editor restarts.
- CI provider-specific release control.
- Real game-project driver implementation for production login, account preparation, activity, fishing, and other game systems.
