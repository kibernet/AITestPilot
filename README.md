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

That probe requires the main worktree readiness manifest to be clean and ready. It can consume an external repair-agent output directory with `-ExternalOutputDir`, requiring `repair-agent-run.json`, `repair-agent.patch`, and `repair-agent-summary.md`, then imports that verified `external_agent` patch in an isolated evidence bundle. It binds the patch and summary to the current `repair-task.json` `taskId`, `bugId`, and `suggestedFix`, preflights it, applies it to the real main worktree through `Invoke-AITestPilotRepairAgentRepositoryPatchApplyGuard.ps1 -ApplyToRepository`, runs repo validation and repair retest before rollback, applies the generated rollback patch, and verifies the main worktree is clean again. The manifest records `inputPackageSource`, `patchGeneratedByProbe`, `mainRepositoryPatchApplied=true` for the probe, and `mainRepositoryPatchPersisted=false` after rollback.

To run the release-gated external output directory intake acceptance:

```powershell
.\tools\Invoke-AITestPilotRepairAgentExternalTaskOutputAcceptance.ps1
```

That acceptance script creates a deterministic external-output-directory fixture unless `-ExternalOutputDir` is provided, then calls the main worktree apply/retest/rollback probe with that directory. It writes `repair-agent-external-task-output-acceptance-manifest.json`, copies the accepted three-file package into release evidence, and proves the intake path used `inputPackageSource=external_output_directory` with `patchGeneratedByProbe=false`. This is an intake contract for external repair-agent output files; a real agent-produced package remains the next boundary.

To analyze a repair-agent patch result against prior fix hints and retest evidence:

```powershell
.\tools\Invoke-AITestPilotRepairAgentPatchResultAnalysis.ps1
```

That analysis consumes the bug knowledge graph, repair task, accepted external task output, and main worktree apply/retest/rollback evidence. It writes `repair-agent-patch-result-analysis-manifest.json` plus Markdown, proving the prior fix hint was matched, the agent output referenced it, post-apply retest passed, rollback returned the worktree clean, and the knowledge graph outcome is `RETEST_PASSED_AFTER_PATCH`.

To persist patch-result analysis across a multi-bug historical trend:

```powershell
.\tools\Invoke-AITestPilotRepairAgentPatchResultHistoryProbe.ps1
```

That history probe consumes the current patch-result analysis, writes `repair-agent-patch-result-history-manifest.json`, `repair-agent-patch-result-history.json`, and Markdown, then proves the current analysis is included in a multi-bug history with module, failure-type, and outcome aggregates. The default history rows are deterministic release fixtures, so the manifest explicitly records that real production repair-agent output is not being claimed.

To produce that external output directory with the installed headless Cursor Agent:

```powershell
.\tools\Invoke-AITestPilotCursorAgentExternalTaskOutput.ps1
.\tools\Invoke-AITestPilotRepairAgentExternalTaskOutputAcceptance.ps1 -ExternalOutputDir .\Temp\release-evidence\cursor-agent-external-output
```

The Cursor Agent wrapper requires `cursor-agent` to be authenticated. It writes only to `Temp\release-evidence\cursor-agent-external-output`, captures `repair-agent-cursor-agent-external-output-manifest.json`, and validates the produced package through patch import and safety preflight before any main worktree apply occurs.

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

To prove the package can distinguish template, invalid, and bound integration-plan states:

```powershell
.\tools\Invoke-AITestPilotProductionReplayIntegrationContractProbe.ps1
```

That probe generates a contract fixture only: `TEMPLATE_READY` for the unbound template, `INVALID` when `realProjectBound` is flipped without bound hooks, and `BOUND` when all required hooks are marked bound with complete metadata. It records `realProjectApiCallsProven=false`; real production release still requires targeted retest evidence with a non-sample driver.

To generate a host-project production driver binding starter kit:

```powershell
.\tools\New-AITestPilotProductionDriverBindingKit.ps1 -OutputDir "Temp\production-driver-binding-kit\latest" -DriverTypeName "Your.Game.Tests.ProductionReplayDriver" -DriverId "your_game.production_replay"
```

The kit includes a customized `HookedGameActionReplayDriver` template, an authoring checklist, and a host CI helper that calls production-bound readiness plus evidence intake. The generated hooks intentionally return `Fail(...)` until the host project wires real APIs; the kit is handoff material, not production-bound evidence.

To write a machine-readable production driver readiness boundary:

```powershell
.\tools\Invoke-AITestPilotProductionReplayDriverReadiness.ps1
```

That script reads the production replay checklist, targeted retest, negative driver failure probe, and replay profile import evidence. It writes `production-replay-driver-readiness-manifest.json` with `readyForProductionDriverRelease=false` and explicit blockers while the repo still uses the sample driver and the checklist remains unbound. Passing `-RequireProductionBound` turns those blockers into a hard failure for real-project CI.

To intake a real game project's production driver evidence bundle:

```powershell
.\tools\Invoke-AITestPilotProductionDriverEvidenceIntake.ps1 -EvidenceBundleDir "path\to\release-evidence"
```

That intake requires production-bound readiness and writes `production-driver-evidence-intake-manifest.json`. In the default repo pipeline it runs with `-ExpectBlocked`, proving the current sample/unbound bundle is rejected instead of accepted as production evidence.
The evidence bundle may live outside this repository; the default release pipeline also runs `Invoke-AITestPilotProductionDriverExternalBundleIntakeProbe.ps1`, which copies the sample/unbound evidence to a system temp directory and proves that repo-external bundle paths are inspected while still blocked by production-bound policy.

To prove the production-bound evidence contract can accept a complete host-project-shaped bundle without promoting fixture data as production:

```powershell
.\tools\Invoke-AITestPilotProductionDriverEvidenceContractProbe.ps1
```

That probe builds an isolated BOUND fixture bundle, runs the same `Invoke-AITestPilotProductionDriverEvidenceIntake.ps1` path without `-ExpectBlocked`, and writes `production-driver-evidence-contract-probe-manifest.json`. It records `releasePipelineUsesFixture=false` and `realProductionDriverEvidenceAccepted=false`, so the default release still keeps the sample/unbound boundary while proving the acceptance contract for real host-project evidence.

To prove the production-bound CI mode blocks the current sample/unbound evidence:

```powershell
.\tools\Invoke-AITestPilotProductionReplayDriverBoundFailureProbe.ps1
```

That probe copies the current evidence bundle, reruns production replay driver readiness with `-RequireProductionBound`, expects it to fail on the sample/unbound blockers, and writes `production-replay-driver-bound-failure-probe-manifest.json` plus the failing readiness manifest copy into release evidence.

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

To export a machine-readable release evidence index:

```powershell
.\tools\Invoke-AITestPilotReleaseEvidenceIndex.ps1
```

That script scans the release gate source manifests, writes `release-evidence-index.json`, `release-evidence-index.md`, and `release-evidence-index-manifest.json`, and keeps expected-failure auxiliary probe manifests separate from primary release evidence. The full release pipeline runs it before the release gate so CI and portal handoff can consume one stable evidence summary.

To aggregate the release risk policy for AI exploration, high-risk graph nodes, production driver evidence, production Lua evidence, live endpoint configuration, external live-smoke evidence intake, live-smoke accepted-contract proof, returned-evidence inbox contract proof, owner contact readiness contract proof, owner send readiness proof, live endpoint policy, and CI provider controls:

```powershell
.\tools\Invoke-AITestPilotReleaseRiskPolicy.ps1
```

That script writes `release-risk-policy-manifest.json` and `release-risk-policy.md`. Default package-release mode accepts only explicitly recorded sample/unbound production-driver and no-production-Lua boundaries plus the production Lua evidence kit, live model endpoint configuration-kit, external live-smoke intake guard, accepted live-smoke evidence contract, returned-evidence inbox contract, owner contact readiness contract, and owner send readiness kit; production CI can make those hard requirements with `-RequireProductionReplayDriverBound`, `-RequireProductionLuaPatched`, `-ProductionLuaEvidenceDir`, `-RequireLiveModelEndpointSmoke`, and `-LiveModelEndpointSmokeEvidenceDir`.

To prove provider-specific CI build, smoke test, and vision evidence checks are wired for GitHub Actions and Azure Pipelines:

```powershell
.\tools\Invoke-AITestPilotProviderCiQualityProbe.ps1
```

That probe writes `provider-ci-quality-probe-manifest.json` and verifies both provider workflows run explicit .NET build checks, smoke tests, and post-pipeline scene-validation evidence checks around the release pipeline.

To generate the host-project production handoff package from the current release evidence:

```powershell
.\tools\Invoke-AITestPilotProductionHandoffPackage.ps1
```

That package writes `production-handoff-package-manifest.json` plus `production-handoff-package\README.md`, `action-plan.md`, `required-external-evidence.json`, `blocker-resolution-map.json`, `blocker-resolution-map.md`, `owner-packets\owner-packet-index.json`, one owner packet per remaining action item, `ci-commands.ps1`, `verify-external-evidence.ps1`, `accept-external-evidence.ps1`, and `external-evidence-preflight-self-check.json`. It consolidates the remaining production driver, production Lua, live-model, and CI hard-mode steps without promoting fixture evidence as real host-project evidence, validates that owner, kit, evidence, blocker-resolution, command, preflight, acceptance-wrapper, and per-owner packet details render as concrete handoff content, and includes host-project scripts for checking external evidence paths and running unified acceptance before hard validation. The release pipeline also runs `Invoke-AITestPilotProductionHandoffExternalEvidencePreflightProbe.ps1`, which feeds complete accepted fixture evidence into the generated preflight with `-RequireAllEvidence -RunIntake`, runs the generated acceptance wrapper in contract mode to produce a Markdown report, and records the result as contract proof without accepting it as real production evidence.

For a smaller owner-facing handoff artifact, run `.\tools\Invoke-AITestPilotProductionHandoffExport.ps1`. It writes `production-handoff-export-manifest.json`, `production-handoff-export\README.md`, and `production-handoff-export.zip` containing the handoff package, owner packets, generated kits, returned-evidence inbox, and contract reports without promoting fixture evidence as real host-project evidence.

To create the returned-evidence inbox that owners fill after receiving packets:

```powershell
.\tools\Invoke-AITestPilotProductionExternalEvidenceInbox.ps1
```

That script writes `production-external-evidence-inbox-manifest.json`, `production-external-evidence-inbox.md`, and `production-external-evidence-inbox\accept-returned-evidence.ps1`. The inbox contains `production-driver-evidence`, `production-lua-evidence`, and `live-smoke-evidence` directories with README files and required-file lists, so returned evidence can be accepted through one wrapper without promoting fixture evidence as real host-project evidence.

The release pipeline also runs `Invoke-AITestPilotProductionExternalEvidenceInboxContractProbe.ps1`, which fills the returned-evidence inbox with complete accepted fixture evidence from outside the repository, executes `accept-returned-evidence.ps1` in contract mode, and records the result as wrapper proof while keeping `realHostProjectEvidenceAccepted=false`.

To summarize external evidence collection after distributing owner packets, run `.\tools\Invoke-AITestPilotProductionHandoffStatus.ps1`. It writes `production-handoff-status-manifest.json` and `production-handoff-status.md`, showing accepted versus pending owner packets, remaining blocker counts, required evidence files, and the next acceptance-wrapper commands without promoting fixture evidence as real host-project evidence.

To prepare the owner dispatch queue and email drafts before real owner addresses are configured:

```powershell
.\tools\Invoke-AITestPilotProductionHandoffDispatchPlan.ps1
```

That script writes `production-handoff-dispatch-manifest.json`, `production-handoff-dispatch.md`, `production-handoff-dispatch\production-handoff-dispatch-queue.json`, and one draft per owner under `production-handoff-dispatch\email-drafts`. It keeps `realOwnerEmailAddressesConfigured=false` and `automaticEmailSendReady=false`, so the release evidence is ready for manual owner routing without claiming any message was sent or any real host-project evidence was returned.

To generate and validate the owner contact roster before dispatch:

```powershell
.\tools\Invoke-AITestPilotProductionHandoffContactReadiness.ps1
```

That script writes `production-handoff-contact-readiness-manifest.json`, `production-handoff-contact-readiness.md`, and `production-handoff-contact-roster.json`. In the default package-release path it creates one contact entry per owner packet but keeps the email fields empty, recording `missingOwnerContactCount=3`, `realOwnerEmailAddressesConfigured=false`, and `automaticEmailSendReady=false`.

The release pipeline also runs `Invoke-AITestPilotProductionHandoffContactReadinessContractProbe.ps1`, which supplies a complete fixture contact roster with reserved `example.invalid` addresses and proves contact readiness accepts configured owner contacts while preserving `automaticEmailSendReady=false`, `realHostProjectEvidenceAccepted=false`, and the default missing-contact release boundary.

To generate the guarded owner-packet send queue and agently-cli helper:

```powershell
.\tools\Invoke-AITestPilotProductionHandoffSendReadiness.ps1
```

That script writes `production-handoff-send-readiness-manifest.json`, `production-handoff-send-readiness.md`, `production-handoff-send\production-handoff-send-queue.json`, `production-handoff-send\send-owner-packets.ps1`, and `production-handoff-send\README.md`. In the default package-release path it reports `sendReadinessStatus=BLOCKED_MISSING_OWNER_EMAILS`, keeps `automaticEmailSendReady=false`, and generates a helper that requires real contact roster entries, `agently-cli` authorization, and explicit two-stage confirmation tokens before any owner packet email can be sent.

```powershell
.\tools\Invoke-AITestPilotProductionHandoffMailAuthReadiness.ps1
```

That script writes `production-handoff-mail-auth-readiness-manifest.json`, `production-handoff-mail-auth-readiness.md`, and `production-handoff-mail-auth\`. It generates local helpers for `agently-cli auth login` and `agently-cli +me` checks while keeping OAuth login, local authorization, and email sending outside the default CI pipeline.

```powershell
.\tools\Invoke-AITestPilotProductionHandoffOwnerUnblockPack.ps1
```

That script writes `production-handoff-owner-unblock-pack-manifest.json`, `production-handoff-owner-unblock-pack.md`, and `production-handoff-owner-unblock-pack\`. It consolidates the remaining owner contacts, blocked sends, mail authorization boundary, missing external evidence files, owner action matrix, operator next steps, and progress email draft without marking any email or host-project evidence as complete.

```powershell
.\tools\Invoke-AITestPilotProductionHandoffOwnerUnblockPackContractProbe.ps1
```

That probe writes `production-handoff-owner-unblock-pack-contract-probe-manifest.json` and proves the unblock pack preserves the default missing-contact/missing-evidence state while a complete fixture contact roster plus complete fixture returned evidence moves the copied pack to `READY_FOR_CONFIRMATION_PENDING_REAL_ACCEPTANCE` without running OAuth login, sending email, or accepting fixture evidence as real host-project evidence.

```powershell
.\tools\Invoke-AITestPilotProductionHandoffOwnerInputRequestPack.ps1
```

That script writes `production-handoff-owner-input-request-pack-manifest.json`, `production-handoff-owner-input-request-pack.md`, and `production-handoff-owner-input-request-pack\`. It turns the remaining external-owner blockers into a fill-in contact roster template, owner input checklist, returned-evidence checklist, and request email draft for `kibernet@sina.com` while keeping `ownerInputRequestStatus=AWAITING_EXTERNAL_OWNER_INPUT`, `automaticEmailSendReady=false`, and all real-evidence acceptance flags false.

```powershell
.\tools\Invoke-AITestPilotProductionHandoffOwnerContactExternalIntakeProbe.ps1
```

That probe writes `production-handoff-owner-contact-external-intake-probe-manifest.json` and a Markdown report. It starts with a repo-external contact roster fixture, imports it into an isolated bundle, proves contact readiness accepts all owner contacts, and proves send readiness moves to `READY_FOR_CONFIRMATION` while the default bundle still records missing contacts and `emailSent=false`.

```powershell
.\tools\Invoke-AITestPilotProductionHandoffSendDryRunProbe.ps1
```

That probe writes `production-handoff-send-dry-run-probe-manifest.json` and a Markdown report. It proves the generated `send-owner-packets.ps1` dry run works without local `agently-cli` authorization: the default bundle previews three blocked sends, and the external-contact intake bundle previews three prepared sends, without creating confirmation tokens or sending email.

```powershell
.\tools\Invoke-AITestPilotProductionHandoffOwnerResponseBundleProbe.ps1
```

That probe writes `production-handoff-owner-response-bundle-probe-manifest.json` and a Markdown report. It builds a repo-external owner response bundle containing a contact roster plus driver, Lua, and live-smoke evidence directories, imports it into an isolated bundle, and proves contacts, returned evidence, send dry-run previews, and owner unblock readiness move together without sending email or promoting fixture evidence as real host-project evidence.

```powershell
.\tools\Invoke-AITestPilotProductionHandoffOwnerResponseBundleKit.ps1
```

That script writes `production-handoff-owner-response-bundle-kit-manifest.json`, a Markdown report, `production-handoff-owner-response-bundle-kit\`, and `production-handoff-owner-response-bundle-kit.zip`. The kit is the fillable owner-return package: a contact roster template, driver/Lua/live-smoke evidence directories, required-file manifests, a local verifier, an import helper, and a request draft. It does not send email, run OAuth, accept production evidence, or include fixture evidence.

```powershell
.\tools\Invoke-AITestPilotReleaseProgressNotificationOutbox.ps1
```

That script writes `release-progress-notification-outbox-manifest.json`, `release-progress-notification-outbox.md`, and `release-progress-notification-outbox\`. It prepares the requested big-node progress email for `kibernet@sina.com`, records the current remaining external counts, writes a `BIG_NODE_ONLY` cadence policy that suppresses separate small proof/probe emails, writes `remaining-work-snapshot.json`/`.md` with the three external owner areas plus the local progress-mail action, and provides a local `agently-cli` send helper with optional `-ReceiptPath` output while keeping the notification in `PENDING_LOCAL_MAIL_AUTH_AND_CONFIRMATION` with `emailSent=false`.

```powershell
.\tools\Invoke-AITestPilotProductionHandoffMailHelperAuthStatusProbe.ps1
```

That probe writes `production-handoff-mail-helper-auth-status-probe-manifest.json`, a Markdown report, and `production-handoff-mail-helper-auth-status-probe\`. It runs the generated owner-packet and progress-notification send helpers against a fake unauthenticated `agently-cli` that emits JSON followed by the real-world `tip:` line, proving the helpers stop at the local-auth boundary without calling `+me`, creating confirmation tokens, or sending email.

```powershell
.\tools\Invoke-AITestPilotReleaseProgressNotificationConfirmationProbe.ps1
```

That probe writes `release-progress-notification-confirmation-probe-manifest.json`, a Markdown report, and `release-progress-notification-confirmation-probe\`. It runs the progress notification helper against a fake logged-in `agently-cli`, proving `-PrepareConfirmation` requests a confirmation token and a later `-ConfirmationToken` run includes that token. The probe keeps `emailSent=false` and uses fake CLI evidence only; real delivery still requires local OAuth plus the actual CLI confirmation token.

```powershell
.\tools\Invoke-AITestPilotReleaseProgressNotificationReceiptProbe.ps1
```

That probe writes `release-progress-notification-receipt-probe-manifest.json`, a Markdown report, and `release-progress-notification-receipt-probe\`. It runs the progress notification helper against a fake token-confirmed `agently-cli`, proving a successful helper run writes a machine-readable send receipt with the fake message id while keeping `emailSent=false` and `realDeliveryVerified=false`.

```powershell
.\tools\Invoke-AITestPilotReleaseProgressNotificationDispatchReceiptIntake.ps1 `
    -ReceiptPath "path\to\progress-notification-send-receipt.json" `
    -RequireReceipt
```

That intake script writes `release-progress-notification-dispatch-receipt-intake-manifest.json` and a Markdown report. It accepts a real local `agently-cli` send receipt only when the receipt matches the pending outbox recipient/subject, has a non-fake message id, was token-confirmed, and was not generated by the release pipeline. The paired `Invoke-AITestPilotReleaseProgressNotificationDispatchReceiptIntakeProbe.ps1` proves `msg_fake_*` receipts are rejected and contract-shaped receipts do not set `emailSent=true`.

```powershell
.\tools\Invoke-AITestPilotReleaseProgressNotificationLocalSendWorkflowProbe.ps1
```

That probe writes `release-progress-notification-local-send-workflow-probe-manifest.json`, a Markdown report, and `release-progress-notification-local-send-workflow-probe\`. It proves the complete local operator workflow with a fake CLI: unauthenticated runs stop before `message +send`, logged-in prepare requests a confirmation token, token-confirmed send writes a receipt, and dispatch receipt intake accepts only contract shape without claiming real email delivery.

```powershell
.\tools\Invoke-AITestPilotReleaseProgressNotificationRealReceiptGuardProbe.ps1
```

That probe writes `release-progress-notification-real-receipt-guard-probe-manifest.json`, a Markdown report, and `release-progress-notification-real-receipt-guard-probe\`. It proves a valid send receipt cannot set `emailSent=true` unless the operator explicitly runs receipt intake with `-ConfirmLocalSendReceipt`; contract fixture mode still cannot claim a real send even when that confirmation switch is present.

To run the stable repo-side acceptance entry point after host-project owners return driver, Lua, and live-smoke evidence directories:

```powershell
.\tools\Invoke-AITestPilotProductionExternalEvidenceAcceptance.ps1 `
    -ProductionDriverEvidenceDir "path\to\production-driver-evidence" `
    -ProductionLuaEvidenceDir "path\to\production-lua-evidence" `
    -LiveModelEndpointSmokeEvidenceDir "path\to\live-smoke-evidence" `
    -RequireAllEvidence
```

That command runs the production driver intake, production Lua readiness, and live-smoke evidence intake into an isolated acceptance bundle, then writes `production-external-evidence-acceptance-manifest.json` and a Markdown report summarizing status, missing files, command results, and the fixture boundary. The release pipeline also runs `Invoke-AITestPilotProductionExternalEvidenceAcceptanceContractProbe.ps1`, which proves this stable entry point accepts complete host-project-shaped fixture evidence while recording `realHostProjectEvidenceAccepted=false` and a validated Markdown report. It also runs `Invoke-AITestPilotProductionExternalEvidenceAcceptanceFailureProbe.ps1`, proving fully missing evidence and driver-only partial evidence fail under `-RequireAllEvidence` while still producing owner-readable rejection reports.

To prove all production hard-mode switches block the current sample or missing-evidence state together:

```powershell
.\tools\Invoke-AITestPilotProductionHardModeFailureProbe.ps1
```

That probe copies the current evidence into an isolated bundle, runs release risk policy, evidence index, and release gate with `-RequireProductionReplayDriverBound`, `-RequireProductionLuaPatched`, and `-RequireLiveModelEndpointSmoke`, then expects the combined hard-mode path to block on the current production driver, Lua, and live-model evidence gaps.

To prove the same combined hard-mode path can pass when complete production-shaped evidence is present:

```powershell
.\tools\Invoke-AITestPilotProductionHardModeSuccessContractProbe.ps1
```

That probe copies accepted fixture driver, Lua, and live-smoke evidence into an isolated bundle, runs release risk policy, evidence index, and release gate with all three hard-mode switches, and records `production-hard-mode-success-contract-probe-manifest.json` without replacing the default release evidence or accepting fixture data as real host-project evidence.

To run the full repo-side release gate over the evidence bundle:

```powershell
.\tools\Invoke-AITestPilotReleaseGate.ps1
```

The gate requires scene validation, repair-agent patch output import, external completion failure probe, generic external repair-agent patch import probe, source snapshot apply/validate/rollback probe, main worktree readiness, external task output directory acceptance, patch result analysis, patch result history, main worktree apply/retest/rollback evidence driven from that external directory, external patch safety preflight, unsafe-patch failure probe, repository patch apply guard, clean temporary repository apply/rollback probe, clean temporary repository apply/retest/rollback probe, patch apply/retest orchestration, targeted repair retest, driver descriptor/configuration, the negative driver failure probe, replay profile import, production driver readiness, Lua static analysis evidence, Lua auto-patch sandbox evidence, production Lua patch readiness, production Lua evidence kit proof, production Lua external bundle intake proof, live model endpoint configuration kit proof, external live-smoke evidence intake proof, live-smoke accepted-contract proof, production handoff package proof with a complete blocker-resolution map, returned external evidence inbox proof, production handoff export proof, production handoff status proof, owner dispatch plan proof, owner contact readiness proof, production external evidence acceptance contract and failure proof, production hard-mode failure proof, production hard-mode success contract proof, release risk policy acceptance, release evidence index coverage, and all listed evidence files. To prove the gate blocks incomplete evidence:

```powershell
.\tools\Invoke-AITestPilotReleaseGateFailureProbe.ps1
```

For CI, run the full pipeline wrapper:

```powershell
.\tools\Invoke-AITestPilotReleasePipeline.ps1
```

It runs the full chain and exports stable artifacts to `artifacts\ai-testpilot-release\latest`. See `docs\ci-release-pipeline.md`.
Production CI that must block until real game APIs are wired can run the same wrapper with `-RequireProductionReplayDriverBound`; in that mode the release gate no longer accepts the sample/unbound package-release boundary.
The repository also includes `.github\workflows\ai-testpilot-release.yml` for a self-hosted Windows Unity GitHub Actions runner and `.azure-pipelines\ai-testpilot-release.yml` for an Azure Pipelines self-hosted Windows Unity pool. Both expose production-bound driver, production Lua patch evidence directory, live model smoke, external live-smoke evidence directory, and Cursor Agent output controls, run the release pipeline, enforce `pipeline-manifest.json` status, and upload/publish the release evidence artifact. The release pipeline validates those provider workflows through `Invoke-AITestPilotGitHubActionsWorkflowProbe.ps1` and `Invoke-AITestPilotAzurePipelinesWorkflowProbe.ps1`.

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
To validate provider-specific live-smoke retry tuning and alert routing without calling a provider:

```powershell
.\tools\Invoke-AITestPilotModelEndpointProviderRetryPolicyProbe.ps1
```

The retry policy manifest covers the provider presets and live failure categories with provider-specific retry counts, backoff ceilings, escalation owners, alert routes, and recommended production CI live-smoke retry arguments. This is policy evidence; a real live endpoint still requires `Invoke-AITestPilotLiveModelEndpointSmoke.ps1 -RequireLive`.

To generate a host-project live model endpoint configuration template and prove the static intake contract without serializing secrets or calling a provider:

```powershell
.\tools\New-AITestPilotLiveModelEndpointConfigKit.ps1
.\tools\Invoke-AITestPilotLiveModelEndpointConfigIntake.ps1 -ConfigDir "path\to\live-model-config"
.\tools\Invoke-AITestPilotLiveModelEndpointConfigKitProbe.ps1
```

The kit writes `live-model-endpoint-config.json`, schema guidance, and a live-smoke runbook. The release pipeline runs the kit probe, which stores a pending template in release evidence, runs an isolated accepted fixture through config intake, and proves a pending repo-external config is read and blocked under hard configuration mode. This is static configuration evidence only: it records `secretsSerialized=false`, `liveSmokeExecuted=false`, and `productionLiveEndpointAccessProven=false`; a real endpoint still requires `Invoke-AITestPilotLiveModelEndpointSmoke.ps1 -RequireLive`.

To intake live smoke evidence exported by a host project:

```powershell
.\tools\Invoke-AITestPilotLiveModelEndpointSmokeEvidenceIntake.ps1 -SmokeEvidenceDir "path\to\live-smoke-evidence" -RequireLiveModelEndpointSmoke -PromoteToCanonical
.\tools\Invoke-AITestPilotLiveModelEndpointExternalSmokeIntakeProbe.ps1
```

The intake expects `live-model-endpoint-smoke-manifest.json` plus `live-model-endpoint-decision-trace.json` with a real `status=PASS` live HTTP request, validated action response, action schema evidence, and trace payload. `-PromoteToCanonical` copies accepted evidence into the canonical release-gate filenames so production CI can satisfy `-RequireLiveModelEndpointSmoke` from a host-project evidence directory. The release pipeline always runs the external smoke intake probe, which generates a SKIPPED fixture outside the repository and proves hard live-smoke mode rejects it.

To prove the accepted live-smoke evidence contract without promoting fixture provider access:

```powershell
.\tools\Invoke-AITestPilotLiveModelEndpointSmokeEvidenceContractProbe.ps1
```

That probe generates a PASS-shaped host-project smoke bundle outside the repository, runs the same intake path with `-RequireLiveModelEndpointSmoke -PromoteToCanonical` in an isolated bundle, and records that canonical smoke and trace evidence can be accepted while `releasePipelineUsesFixture=false` and `realProductionLiveEndpointAccessProven=false` remain explicit.

To prove Lua static analysis and patch-plan evidence for replay repair candidates:

```powershell
.\tools\Invoke-AITestPilotLuaStaticAnalysisProbe.ps1
```

The Lua static analyzer scans deterministic Lua fixtures for unguarded field access, global writes, dynamic `require`, and unprotected game API calls. It writes `lua-static-analysis-manifest.json`, a JSON/Markdown report, a patch-plan Markdown artifact, and fixture files into release evidence. The default probe is a package-side contract and explicitly records that real production Lua has not been analyzed yet.

To prove deterministic Lua auto-patch application in a sandbox:

```powershell
.\tools\Invoke-AITestPilotLuaAutoPatchSandboxProbe.ps1
```

That sandbox probe applies the generated Lua patch operations to fixture copies, writes `lua-auto-patch-sandbox-manifest.json`, before/after analysis reports, operation JSON, a patch artifact, and patched Lua copies. The release gate requires the pre-patch findings to be present, all operations applied, post-patch findings cleared, and `mainRepositoryMutated=false` / `realProductionLuaPatched=false`.

To record production Lua patch readiness without claiming the sample fixture is production code:

```powershell
.\tools\Invoke-AITestPilotProductionLuaPatchReadiness.ps1
```

That readiness check consumes the Lua static-analysis and auto-patch sandbox evidence, then records whether a real production Lua patch evidence bundle has been provided. The default package path writes `production-lua-patch-readiness-manifest.json` with explicit blockers such as `real_production_lua_bundle_missing`, while keeping package release separate. To prove the hard production mode blocks that sample/no-production boundary:

```powershell
.\tools\Invoke-AITestPilotProductionLuaPatchBoundFailureProbe.ps1
```

To generate the host-project evidence template and prove the accepted evidence contract without promoting fixture data as production:

```powershell
.\tools\New-AITestPilotProductionLuaPatchEvidenceKit.ps1
.\tools\Invoke-AITestPilotProductionLuaPatchEvidenceKitProbe.ps1
```

The kit writes `production-lua-patch-evidence.json`, schema guidance, retest and rollback templates. The release pipeline runs the kit probe, which keeps the generated template pending while using an isolated accepted fixture only to prove `Invoke-AITestPilotProductionLuaPatchReadiness.ps1` accepts a complete evidence contract. The probe records `releasePipelineUsesFixture=false` and `realProductionLuaPatchEvidenceAccepted=false`.

The default pipeline also proves repo-external production Lua evidence intake with:

```powershell
.\tools\Invoke-AITestPilotProductionLuaPatchExternalBundleIntakeProbe.ps1
```

That probe generates a pending evidence template under the system temp directory, copies the Lua readiness inputs beside it, runs readiness with `-RequireProductionLuaPatched`, and expects the command to fail while proving the external `production-lua-patch-evidence.json` was read and copied. This closes the path boundary without accepting incomplete template evidence as production.

Production CI can require real production Lua analysis, patch, validation, retest, and rollback evidence through:

```powershell
.\tools\Invoke-AITestPilotReleasePipeline.ps1 -ProductionLuaEvidenceDir "path\to\production-lua-evidence" -RequireProductionLuaPatched
```

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
- External repair-agent task output directory intake acceptance for the main worktree apply/retest/rollback path.
- Repair-agent patch result analysis connecting prior fix hints, accepted external output, post-apply retest, rollback, and knowledge graph outcome.
- Repair-agent patch result history aggregating multi-bug outcomes with module, failure-type, retest, rollback, and production-output boundary evidence.
- Optional headless Cursor Agent external output generation, with import/preflight evidence and no repository mutation before acceptance.
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
- Production replay integration contract probe for `TEMPLATE_READY`, invalid flip, and `BOUND` checklist states.
- Production driver binding kit generator and release-gated probe for host-project production replay driver starter files.
- Driver capability/configuration descriptor recorded in repair retest evidence.
- Negative replay-driver failure probe with driver, handler, action, target, and step diagnostics.
- Production replay driver readiness manifest separating package release readiness from real-project driver binding readiness.
- Production driver evidence intake manifest for accepting real production-bound bundles or proving sample/unbound bundles are blocked.
- Production driver evidence contract probe proving an isolated BOUND fixture can pass intake without being promoted as real production evidence.
- Production driver external bundle intake probe proving standalone repo-external evidence directories can be inspected without accepting sample/unbound evidence.
- Production-bound replay driver failure probe proving sample/unbound evidence fails when real production binding is required.
- Repo-side release gate that blocks missing driver descriptor, missing negative probe, failed retest, or missing evidence files.
- CI release pipeline wrapper with stable artifact output under `artifacts\ai-testpilot-release\latest`.
- GitHub Actions release workflow for self-hosted Windows Unity runners, with release-gated workflow probe and evidence artifact upload.
- Azure Pipelines release workflow for self-hosted Windows Unity pools, with release-gated workflow probe and evidence artifact publishing.
- Provider-specific build, smoke test, and vision evidence checks for GitHub Actions and Azure Pipelines, with release-gated quality probe evidence.
- Production handoff package that consolidates host-project production driver, Lua, live-model, and CI hard-mode next steps without promoting fixture evidence, with generated-content quality checks, a blocker-resolution map, per-owner action packets, a returned-evidence inbox, a compact owner-facing handoff export zip, an owner-level evidence collection status report, an owner dispatch queue with email drafts, an owner contact roster readiness report, progress-notification send-helper auth-status parsing proof, fake-CLI two-stage confirmation proof, a runnable external-evidence preflight script, a stable repo-side external evidence acceptance command, accepted-fixture contract probes, and missing/partial evidence failure probes for owner-facing action plans.
- Production hard-mode failure probe proving combined driver, Lua, and live-model hard switches block the current sample or missing-evidence state.
- Production hard-mode success contract probe proving the combined hard-mode path passes with complete accepted fixture evidence in an isolated bundle while preserving the default real-evidence boundary.
- Release-gated machine-readable release evidence index for CI, portal handoff, and audit consumers.
- Release-gated risk policy manifest that blocks failed AI exploration, unresolved high-risk graph nodes, missing driver evidence, missing production Lua evidence, missing live-smoke policy evidence, missing CI provider controls, missing production handoff evidence, or missing hard-mode failure/success contract evidence while preserving explicit package-release boundaries.
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
- Provider-specific live-smoke retry tuning and alert routing manifest for native, OpenAI, OpenAI-compatible, and local gateways.
- Live model endpoint configuration kit generator, static config intake, and release-gated probe proving host-project endpoint configs can be validated while secrets and real provider access remain outside repo evidence.
- Live model endpoint smoke evidence intake plus release-gated repo-external SKIPPED evidence rejection for host-project live-smoke handoff.
- Live model endpoint smoke evidence accepted-contract probe proving PASS-shaped host-project evidence can be accepted in isolation without claiming real provider access.
- Core Lua static analyzer plus release-gated Lua static analysis manifest for unguarded field access, global writes, dynamic `require`, unprotected game API calls, safe-fixture checks, and patch-plan evidence.
- Release-gated Lua auto-patch sandbox evidence proving deterministic fixture patches clear findings without mutating production Lua.
- Production Lua patch readiness manifest and hard-bound failure probe separating sandbox-proven patches from real production Lua analysis, patch, retest, and rollback evidence.
- Production Lua patch evidence kit generator plus release-gated contract probe for host-project Lua evidence templates.
- Production Lua external bundle intake probe proving repo-external evidence directories are inspected while incomplete template evidence is blocked.
- Sample business replay path covering account setup, login, `enter_scene`, activity reward, and `play_fishing`.
- Persisted replay profile asset plus JSON export for CI evidence.
- Replay profile JSON import back into an editable Unity `ActionReplayProfile` asset.

Not implemented yet:

- Cloud/local cluster orchestration.
- Real live model endpoint credentials, provider access, and required live-smoke evidence for the selected deployment.
- Real production Lua patch execution with host-project analysis, retest, rollback, and evidence export.
- Prefab mutation and retest orchestration across Unity editor restarts.
- Further CI providers beyond GitHub Actions and Azure Pipelines if required.
- Real game-project driver implementation for production login, account preparation, activity, fishing, and other game systems.
