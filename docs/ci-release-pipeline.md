# CI Release Pipeline

Use the release pipeline wrapper when CI needs one command with stable artifacts and exit-code behavior.

```powershell
.\tools\Invoke-AITestPilotReleasePipeline.ps1
```

The pipeline runs:

- repo validation and smoke tests.
- Unity package import and sample-scene validation.
- repair-agent patch output import with deterministic sample patch/summary artifacts.
- repair-agent external completion failure probe, proving pending runs cannot be promoted by patch files alone.
- generic external repair-agent patch import probe, proving real external patches are not tied to the deterministic sample null-guard snippet.
- source snapshot apply/validate/rollback probe, proving verified external patches can apply to a clean candidate made from the current source tree and pass repo validation.
- main worktree apply readiness, proving whether real repository apply remains blocked by source baseline cleanliness or can proceed to the explicit external patch apply gate.
- external task output directory acceptance, proving a task-bound three-file repair-agent output package can drive main worktree apply/retest/rollback with repair task context, run validation and repair retest, then roll back to clean.
- repair-agent patch result analysis, proving prior fix hints are connected to accepted external output, post-apply retest, rollback, and knowledge graph outcome.
- repair-agent patch result history, proving multi-bug outcome persistence, trend aggregates, and the deterministic-fixture versus real-production boundary.
- repair-agent external patch safety preflight and unsafe path-traversal failure probe.
- repository patch apply guard with explicit-switch, clean-worktree, and rollback-plan evidence.
- clean temporary repository apply/rollback probe for external-agent patch output.
- clean temporary repository apply/retest/rollback probe for external-agent patch output.
- sandbox patch apply/retest orchestration for imported repair-agent patch output.
- negative replay-driver failure probe.
- targeted repair retest with a selected game replay driver.
- replay profile JSON import.
- production replay integration contract probe, proving template, invalid flip, and bound checklist states.
- production driver binding kit probe, proving the host-project starter kit can be generated without claiming production-bound evidence.
- production replay driver readiness, separating package-release readiness from real-project driver binding readiness.
- production driver evidence intake, accepting real production-bound bundles or proving the current sample/unbound bundle is blocked.
- production driver evidence contract probe, proving an isolated BOUND fixture can pass the real intake path without being promoted as production evidence.
- production driver external bundle intake probe, proving a repo-external evidence directory can be inspected while sample/unbound evidence remains blocked.
- production-bound replay driver failure probe, proving the current sample/unbound evidence is rejected when production binding is required.
- model endpoint trace probe.
- model endpoint provider diagnostics.
- model endpoint provider retry policy probe.
- live model endpoint config kit probe, proving host-project endpoint configuration templates, accepted static intake, and blocked repo-external pending config without serializing secrets or claiming live provider access.
- live model endpoint external smoke intake probe, proving repo-external skipped live-smoke evidence is read and blocked when live smoke is required.
- live model endpoint smoke evidence contract probe, proving PASS-shaped host-project smoke evidence can be accepted in isolation without promoting fixture provider access.
- Lua static analysis probe, proving repair-risk rule coverage, safe-fixture behavior, and patch-plan evidence.
- Lua auto-patch sandbox probe, proving deterministic fixture patches clear findings without mutating production Lua.
- production Lua patch readiness and hard-bound failure probe, proving real production Lua evidence is required when production Lua patching is enforced.
- production Lua patch evidence kit probe, generating the host-project evidence template and proving the accepted readiness contract with an isolated fixture only.
- production Lua external bundle intake probe, proving repo-external template evidence is read and still blocked under hard production mode.
- deterministic live model endpoint failure probe.
- optional live model endpoint smoke.
- GitHub Actions release workflow probe, proving provider-specific CI maps release-control inputs to the release pipeline and uploads evidence.
- Azure Pipelines release workflow probe, proving a second provider maps release-control parameters to the release pipeline and publishes evidence.
- provider CI quality probe, proving GitHub Actions and Azure Pipelines run explicit provider-level build, smoke test, and vision evidence checks.
- production handoff package generation, consolidating driver, Lua, live-model, and CI hard-mode host-project next steps without promoting fixture evidence, with generated-content quality checks, a blocker-resolution map, and a runnable external-evidence preflight script.
- production handoff external evidence preflight probe, proving that generated preflight script accepts complete host-project-shaped fixture evidence with `-RequireAllEvidence -RunIntake` while preserving the fixture boundary.
- production hard-mode failure probe, proving combined driver, Lua, and live-model hard switches block the current sample or missing-evidence state.
- release risk policy, aggregating AI exploration, high-risk graph, production driver, production Lua, live endpoint, and CI provider release blockers.
- release evidence index, exporting a machine-readable source-manifest summary for CI, portal handoff, and audit consumers.
- repo-side release gate.
- release-gate failure probe.

## Artifacts

By default, the pipeline copies the latest evidence bundle to:

`artifacts/ai-testpilot-release/latest`

That directory includes `pipeline-manifest.json`, release gate manifests, release evidence index JSON/Markdown, release risk policy JSON/Markdown, provider CI quality probe evidence, production handoff package evidence, production handoff blocker-resolution evidence, production handoff external evidence preflight contract evidence, production hard-mode failure probe evidence, repair-agent patch output import evidence, external completion failure-probe evidence, generic external patch import evidence, source snapshot apply/validate evidence, main worktree apply-readiness evidence, external task output acceptance evidence, repair-agent patch result analysis evidence, repair-agent patch result history evidence, main worktree apply/retest/rollback evidence, external patch preflight evidence, unsafe patch failure-probe evidence, repository patch apply guard evidence, clean temporary repository apply/rollback evidence, clean temporary repository apply/retest/rollback evidence, repair-agent patch apply/retest evidence, retest evidence, failure-probe evidence, replay profile artifacts, production replay integration contract evidence, production driver binding kit evidence, production replay driver readiness evidence, production driver evidence intake evidence, production driver evidence contract evidence, repo-external production bundle intake evidence, production-bound failure-probe evidence, model endpoint request/response/trace evidence, provider diagnostics, provider retry policy evidence, live model endpoint config kit and intake evidence, external live-smoke intake evidence, live-smoke accepted-contract evidence, Lua static analysis evidence, Lua auto-patch sandbox evidence, production Lua patch readiness evidence, production Lua evidence kit evidence, production Lua external bundle intake evidence, live endpoint failure-classification evidence, optional live model smoke evidence, GitHub Actions workflow probe evidence, Azure Pipelines workflow probe evidence, and Unity logs.

`production-handoff-package-manifest.json` is generated before the release risk policy. It points host-project owners at the exact driver, Lua, and live-model evidence files and hard-mode release-pipeline commands needed to replace the package fixtures with real production evidence. The package also validates that generated Markdown and command files contain concrete owner names, kit paths, required evidence files, blocker-resolution rows, and release commands rather than serialized PowerShell object names. The generated `blocker-resolution-map.json` and `blocker-resolution-map.md` map every remaining production blocker to its owner, evidence files, acceptance criteria, and validation command. The generated `verify-external-evidence.ps1` preflights driver, Lua, and live-model evidence paths and writes `external-evidence-preflight-self-check.json`; the default self-check must remain pending for the three real host-project evidence areas. `production-handoff-external-evidence-preflight-probe-manifest.json` then runs the generated preflight against complete accepted fixture evidence from outside the repository with `-RequireAllEvidence -RunIntake`, and records `production-handoff-external-evidence-preflight-accepted-manifest.json` as contract proof only.

`production-hard-mode-failure-probe-manifest.json` is generated before the release risk policy. It records an isolated combined hard-mode run where production driver binding, production Lua patch evidence, and live model smoke are all required and the current package evidence is expected to block.

`release-risk-policy-manifest.json` is the machine-readable release-blocker decision for downstream CI, portal, or audit tooling. It is generated after the production handoff and hard-mode probes and before the release evidence index, recording whether package release is allowed under the active production driver, production Lua, and live-model enforcement switches.

`release-evidence-index.json` is the stable machine-readable summary for downstream CI, portal, or audit tooling. It indexes the primary release-gate source manifests, including the release risk policy, records source status coverage, listed-file coverage, optional live-smoke skip handling, and auxiliary manifest inventory. The release gate validates `release-evidence-index-manifest.json` before allowing release.

## GitHub Actions

`.github/workflows/ai-testpilot-release.yml` is the provider-specific CI entry point for GitHub Actions. It targets a self-hosted Windows Unity runner because the release pipeline runs Unity 2021.3 batchmode validation. The workflow runs on `push`, `pull_request`, and `workflow_dispatch`.

Manual dispatch exposes release-control inputs for `unity_path`, `game_replay_driver_type`, production-bound replay driver enforcement, production Lua patch enforcement, production Lua evidence directory, required live model smoke, missing API-key allowance for local gateways, and optional headless Cursor Agent output. The workflow passes those inputs to `Invoke-AITestPilotReleasePipeline.ps1`, enforces that `pipeline-manifest.json` reports `status=PASS` and `ciExitCode=0`, then uploads `artifacts\ai-testpilot-release\latest` as `ai-testpilot-release-evidence`.

The release pipeline runs `Invoke-AITestPilotGitHubActionsWorkflowProbe.ps1` before the release gate. That probe snapshots the workflow into the evidence bundle and proves the provider workflow still has the required triggers, self-hosted Windows Unity runner labels, read-only repository permission, pipeline switches, live endpoint secret bindings, manifest enforcement, and artifact upload.

The GitHub Actions workflow also runs provider-level build and smoke test checks before invoking the release pipeline, then runs a provider vision evidence check against `scene-validation.json` before enforcing and uploading release evidence.

## Azure Pipelines

`.azure-pipelines/ai-testpilot-release.yml` is the second provider-specific CI entry point. It targets a self-hosted `SelfHostedWindowsUnity` pool with a Windows agent demand, exposes matching release-control parameters, runs the same release pipeline wrapper with the same hardening switches, enforces `pipeline-manifest.json`, and publishes `artifacts\ai-testpilot-release\latest` as `ai-testpilot-release-evidence`.

The release pipeline runs `Invoke-AITestPilotAzurePipelinesWorkflowProbe.ps1` before the release gate. That probe snapshots the Azure workflow into the evidence bundle and proves the provider workflow still has push/PR triggers, release-control parameters, PowerShell Core tasks, runner prerequisite checks, live endpoint variable bindings, manifest enforcement, and artifact publishing.

The Azure Pipelines workflow mirrors the GitHub provider quality path with provider-level build and smoke test tasks before the release pipeline and a provider vision evidence task against `scene-validation.json` before manifest enforcement and artifact publishing.

## Cursor Agent Output

The default pipeline remains deterministic and uses the acceptance fixture. To replace that fixture with a real headless Cursor Agent output directory on a machine where `cursor-agent` is authenticated:

```powershell
.\tools\Invoke-AITestPilotReleasePipeline.ps1 -UseCursorAgentExternalTaskOutput
```

That optional mode inserts a `repair_agent_cursor_agent_external_task_output` step before acceptance, writes `repair-agent-cursor-agent-external-output-manifest.json`, and then passes `Temp\release-evidence\cursor-agent-external-output` into the same main worktree apply/retest/rollback acceptance path. The release gate validates the Cursor Agent manifest when it is present.
By default the wrapper does not pass `--model`, so the authenticated Cursor Agent account can use its current default model. If `-CursorAgentModel` is provided and the CLI rejects that model, the wrapper retries once without `--model` and records `cursorAgentRetriedWithoutModel=true` in the manifest. Transient network/socket failures, exit-0 runs that miss the required three-file output contract, and patches that do not apply with the required task context are retried within `-CursorAgentMaxAttempts`, and the manifest records attempt and retry counts.

## Exit Code Contract

- exit code `0`: every step passed and the release gate allowed release.
- nonzero exit code: one or more steps failed. The pipeline still writes `pipeline-manifest.json` when it can export artifacts.

## Production Driver

Pass a production driver type when testing a real project:

```powershell
.\tools\Invoke-AITestPilotReleasePipeline.ps1 -GameReplayDriverType "Your.Game.Tests.ProductionReplayDriver"
```

The driver must satisfy the descriptor and failure-probe requirements described in `docs/integration/production-driver.md`.

To generate the host-project starter kit before wiring real APIs:

```powershell
.\tools\New-AITestPilotProductionDriverBindingKit.ps1 -DriverTypeName "Your.Game.Tests.ProductionReplayDriver" -DriverId "your_game.production_replay"
```

The kit contains a customized driver template, an authoring checklist, and a host helper script. The release pipeline also runs `production_driver_binding_kit_probe`; the gate only accepts that proof when the kit is still marked as generated handoff material and `productionEvidenceAccepted=false`.

To make production binding a hard release condition, run:

```powershell
.\tools\Invoke-AITestPilotReleasePipeline.ps1 -GameReplayDriverType "Your.Game.Tests.ProductionReplayDriver" -RequireProductionReplayDriverBound
```

In that mode `Invoke-AITestPilotProductionReplayDriverReadiness.ps1` receives `-RequireProductionBound`, and the release gate requires `readyForProductionDriverRelease=true`, checklist `status=BOUND`, `realProjectBound=true`, zero unresolved hooks, complete binding metadata, a non-sample `type:` driver source, complete descriptor/configuration evidence, passing retest evidence, failure-probe evidence, and replay profile import evidence. The default package-release mode still runs `Invoke-AITestPilotProductionReplayDriverBoundFailureProbe.ps1` to prove the current sample/unbound evidence cannot pass the production-bound gate.

For a standalone real-project evidence bundle, run:

```powershell
.\tools\Invoke-AITestPilotProductionDriverEvidenceIntake.ps1 -EvidenceBundleDir "path\to\release-evidence"
```

The default repo pipeline runs the same script with `-ExpectBlocked`, so package-release artifacts prove the sample/unbound bundle is rejected by the production-bound intake path.
The default pipeline also runs `production_driver_evidence_contract_probe`, which builds an isolated BOUND fixture and proves that the same intake accepts complete production-bound-shaped evidence. The release gate requires that fixture to remain non-promoted through `releasePipelineUsesFixture=false`.
The intake path supports evidence directories outside this repository. The default repo pipeline runs `production_driver_external_bundle_intake_probe` by copying the current sample/unbound bundle to a system temp directory, running the same intake there with `-ExpectBlocked`, and copying the external intake/readiness manifests back into release evidence.

## Production Lua Patch

The default pipeline records `production-lua-patch-readiness-manifest.json` after the Lua auto-patch sandbox probe. In package-release mode this manifest is expected to be blocked on real production Lua evidence while still proving the sandbox patch plan is clean and the package repository was not mutated. The pipeline also runs `production_lua_patch_bound_failure_probe`, which reruns readiness with `-RequireProductionLuaPatched` and proves the current no-production-Lua evidence is rejected.

To generate the host-project evidence template before a real production run:

```powershell
.\tools\New-AITestPilotProductionLuaPatchEvidenceKit.ps1
```

The pipeline also runs `production_lua_patch_evidence_kit_probe`. It stores the template kit in release evidence, then uses an isolated accepted fixture only to prove the readiness contract. The gate requires `releasePipelineUsesFixture=false`, so this does not claim real production Lua evidence.

The pipeline also runs `production_lua_patch_external_bundle_intake_probe`. It creates a pending template evidence directory under system temp, runs readiness against that repo-external path with `-RequireProductionLuaPatched`, and expects the hard-mode rejection while proving the external evidence was read. This protects the real host-project handoff path from silently falling back to repo-local fixtures.

To make production Lua patch evidence a hard release condition, run:

```powershell
.\tools\Invoke-AITestPilotReleasePipeline.ps1 -RequireProductionLuaPatched
```

For a passing production run, provide the real host-project evidence directory:

```powershell
.\tools\Invoke-AITestPilotReleasePipeline.ps1 -ProductionLuaEvidenceDir "path\to\production-lua-evidence" -RequireProductionLuaPatched
```

In that mode the release gate requires real production Lua analysis, patch application, validation, retest, rollback proof, clean source-control state after validation, and zero remaining production findings.

## Live Model Endpoint

The pipeline always runs `Invoke-AITestPilotLiveModelEndpointFailureProbe.ps1` before the optional real live smoke. That probe uses a deterministic HTTP 401 response and proves the release evidence can classify auth failures, emit remediation hints, and produce a non-retryable escalation policy without contacting an external provider.

The pipeline also runs `Invoke-AITestPilotLiveModelEndpointConfigKitProbe.ps1`. It writes a pending host-project config kit into release evidence, proves an isolated accepted static config can pass intake, and proves an incomplete config from a repo-external temp directory is read and blocked. This step validates non-secret endpoint configuration handoff only; it records `liveSmokeExecuted=false` and `productionLiveEndpointAccessProven=false`.

The pipeline also runs `Invoke-AITestPilotLiveModelEndpointExternalSmokeIntakeProbe.ps1`. It creates a SKIPPED live-smoke fixture under system temp, runs smoke evidence intake with `-RequireLiveModelEndpointSmoke`, and expects rejection. This proves host-project smoke evidence directories are inspected without allowing skipped evidence to satisfy a required live smoke.

The pipeline also runs `Invoke-AITestPilotLiveModelEndpointSmokeEvidenceContractProbe.ps1`. It creates a PASS-shaped live-smoke fixture under system temp, accepts it through the same smoke evidence intake path inside an isolated bundle, and records that canonical manifest/trace promotion works while `releasePipelineUsesFixture=false` and `realProductionLiveEndpointAccessProven=false` stay explicit.

The pipeline always writes `live-model-endpoint-smoke-manifest.json`. Without live endpoint environment variables it records `status=SKIPPED` and release remains allowed.
When a configured live smoke fails, the manifest records `failureCategory`, `failureMessage`, `failureRemediation`, and `failurePolicy`. Retryable failures are retried by the wrapper before the release gate runs, and the final manifest includes `attemptCount` plus `attempts[]`.
Use `-LiveModelEndpointMaxPolicyRetries` and `-LiveModelEndpointMaxRetryBackoffSeconds` to cap live-smoke retry behavior through the release pipeline, or `-DisableLiveModelEndpointFailurePolicyRetry` when testing a single-attempt failure path. The lower-level live-smoke wrapper exposes the same controls as `-MaxPolicyRetries`, `-MaxRetryBackoffSeconds`, and `-DisableFailurePolicyRetry`.
The pipeline also writes `model-endpoint-provider-retry-policy-manifest.json`, which maps provider presets and failure categories to provider-specific retry counts, backoff ceilings, escalation owners, alert routes, and recommended production live-smoke retry arguments.

To require a real live model request in CI, set:

- `AITESTPILOT_LIVE_MODEL_ENDPOINT`
- `AI_TESTPILOT_MODEL_API_KEY`
- `AITESTPILOT_LIVE_MODEL`
- `AITESTPILOT_LIVE_MODEL_REQUEST_FORMAT` as `NativeJson` or `OpenAICompatibleChatCompletions` when the endpoint needs a specific request wrapper.

Then run:

```powershell
.\tools\Invoke-AITestPilotReleasePipeline.ps1 -RequireLiveModelEndpointSmoke
```

If a host project has already exported passing live-smoke evidence, provide that directory instead:

```powershell
.\tools\Invoke-AITestPilotReleasePipeline.ps1 -RequireLiveModelEndpointSmoke -LiveModelEndpointSmokeEvidenceDir "path\to\live-smoke-evidence"
```

For local OpenAI-compatible gateways with no authentication, also pass:

```powershell
.\tools\Invoke-AITestPilotReleasePipeline.ps1 -RequireLiveModelEndpointSmoke -AllowMissingModelApiKey
```
