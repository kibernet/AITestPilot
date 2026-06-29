# Kibernet AI TestPilot Unity Package

This package provides the Unity-side SDK for AI-driven gameplay QA.

## Main APIs

- `AutomationId`: attach to UI objects that should appear in snapshots.
- `SnapshotProvider.Capture()`: captures scene name, UI automation ids, game state, and logs.
- `GameStateProvider.CustomProvider`: optional hook for game-specific state.
- `ActionExecutor`: executes whitelisted AI actions.
- `DecisionLoopRunner`: local rule-based exploration loop.
- `ModelEndpointSettings`: ScriptableObject configuration for a real model gateway without storing secrets.
- `ModelEndpointDecisionClient`: Unity runtime native/chat request builder, response parser, action validator, and optional `UnityWebRequest` live client.
- `ProductionReplayIntegrationPlan`: ScriptableObject checklist for binding production replay hooks to real game APIs.
- `BugDetector`: turns Unity logs into bug packages.
- `BugKnowledgeGraphAsset`: ScriptableObject for recording recurring bug fixes.
- `AITestPilotBatchValidator`: editor batch validation entry point for generated sample-scene automation and report evidence.

## Editor

Open `Tools/Kibernet/AI TestPilot` to capture snapshots, export JSON, create a scene runner, or write a Cursor bug prompt.

Use `Tools/Kibernet/AI TestPilot/Create Basic Automation Sample Scene` to create a minimal scene with an instrumented button and `DecisionLoopRunner`.

Use `Tools/Kibernet/AI TestPilot/Create Model Endpoint Settings` to create `Assets/AITestPilotGenerated/ModelEndpointSettings.asset`. The asset stores endpoint URL, model name, request format, authorization scheme, API-key environment variable, timeout, trace directory, live-request flag, and system prompt. Live requests are disabled by default and API keys are read from environment variables, not serialized into the asset.

Use `Tools/Kibernet/AI TestPilot/Create OpenAI-Compatible Model Endpoint Settings` when the gateway expects a chat-completions style request with `messages` and `response_format`.
Use the repo wrapper `tools/Invoke-AITestPilotModelEndpointProviderDiagnostics.ps1` to export provider preset diagnostics for native, OpenAI, OpenAI-compatible, and local OpenAI-compatible gateway setup without making a live request.
Use `tools/Invoke-AITestPilotLiveModelEndpointFailureProbe.ps1` to prove auth failures are classified, traced, and paired with remediation plus retry/escalation policy before enabling a real live endpoint in CI. Configured live smoke retries retryable failures through the repo wrapper and records per-attempt evidence.

Use `Tools/Kibernet/AI TestPilot/Create Production Replay Integration Plan` to create `Assets/AITestPilotGenerated/ProductionReplayIntegrationPlan.asset`. The template lists the required account, login, scene, reward, and fishing hooks and stays marked unbound until a real game project wires each hook to production APIs.

Batch validation writes a JSON evidence document with run reports, a source bug package, a bug knowledge graph export, a retest report, a repair task, a repair-agent handoff, repair-agent run tracking, and release evidence. The repo script checks those fields before accepting the package and copies `bug-package.json`, `bug-package.md`, `bug-knowledge-graph.json`, `bug-knowledge-graph.md`, `repair-task.json`, `repair-task.md`, `repair-agent-handoff.json`, `repair-agent-handoff.md`, `repair-agent-run.json`, and `repair-agent-run.md` into the release evidence bundle. The release pipeline imports repair-agent patch output separately as `repair-agent.patch`, `repair-agent-summary.md`, and `repair-agent-patch-output-manifest.json`, rejects pending repair-agent runs through an external completion failure probe, proves generic external patches are not tied to the deterministic sample null-guard snippet, proves verified external patches can apply to a clean source snapshot and pass repo validation, preflights patch target paths with an unsafe path-traversal failure probe, records repository apply guard and rollback-plan evidence, proves clean temporary repository apply/rollback mechanics, proves clean temporary repository apply/retest/rollback ordering, then validates sandbox patch application and post-patch retest evidence in `repair-agent-patch-apply-retest-manifest.json`.
Batch validation also runs `DecisionLoopRunner` through a three-step sample goal and records `multiStepRunner` plus `RUN-SAMPLE-MULTI-STEP-RUNNER` evidence, proving repeated action execution and max-step termination.
Batch validation also creates the sample model endpoint settings asset and validates the Unity request contract offline, including snapshot payload, action schema marker, allowed actions, prior fix hints, OpenAI-compatible wrapper proof, and parsed action evidence.
Batch validation also creates the production replay integration plan and exports `production-replay-integration-checklist.json` plus `production-replay-integration-checklist.md`. These files must report `TEMPLATE_READY` and `realProjectBound=false` so CI can distinguish the integration handoff checklist from a completed real game driver. Real project checklists validate as `BOUND` only after every required hook is bound and carries complete owner, API surface, target, and verification-signal metadata.
Use `tools/Invoke-AITestPilotProductionReplayIntegrationContractProbe.ps1` to prove the checklist validator can distinguish `TEMPLATE_READY`, invalid `realProjectBound` flips, and `BOUND` contract fixtures without claiming real game API calls.

`RepairTaskRetestRunner.RunRepairTaskRetest` is the batchmode entry point for targeted retests from a repair-task JSON. It replays the recorded steps and emits repair retest evidence.

Register custom `IActionReplayAdapter` implementations through `ActionReplayRegistry.Register(...)` to map generic AI actions into game-specific flows. Custom adapters are tried before the default `ActionExecutor` adapter, and retest evidence records both registered and used adapter ids.

For data-driven replay, create an `ActionReplayProfile` and register it through `ConfiguredActionReplayAdapter`. Each profile rule maps an action/target pair to a handler key; runtime code registers handlers in `ActionReplayHandlerRegistry`.

For game-project integration, implement `IGameActionReplayDriver` and call `GameActionReplayDriverBindings.RegisterStandardHandlers(driver)`. The standard handler keys cover `game.prepare_account`, `game.login`, `game.enter_scene`, `game.claim_reward`, and `game.play_fishing`.

Batch retests resolve a game replay driver in this order: `-aiTestPilotGameReplayDriverType`, `GameActionReplayDriverRegistry.Register(...)`, then the package sample fallback. A production driver can optionally implement `IGameActionReplayStateProvider` so retest evidence includes business-action counters.

For most projects, inherit from `HookedGameActionReplayDriver` and implement `IGameActionReplayHooks`. A copyable template is available under `Samples~/ProductionReplayDriver/ProductionReplayDriverTemplate.cs`.
Production drivers should provide a `GameActionReplayDriverDescriptor` with supported handler keys and configuration requirements; repair retest evidence records and validates that descriptor.
The repo wrapper `tools/Invoke-AITestPilotReplayDriverFailureProbe.ps1` runs a failing driver to verify that hook failures produce diagnostics with driver id, handler key, action, target, and step.

The package validation sample includes a configured business-flow profile that handles `prepare_account:qa_smoke_account`, `login:qa_smoke_account`, `enter_scene:Activity`, `claim_reward:Activity.ClaimReward`, and `play_fishing:CastLine`.

Use `Tools/Kibernet/AI TestPilot/Create Sample Business Replay Profile` to create an editable sample `ActionReplayProfile` asset. Batch targeted retests export the profile JSON into the release evidence bundle.

Use `Tools/Kibernet/AI TestPilot/Import Replay Profile From JSON` to turn a JSON replay profile back into an editable `ActionReplayProfile` asset. For CI or external agent workflows, call `ActionReplayProfileBatchImporter.ImportReplayProfileFromJson` in Unity batchmode; the repo wrapper is `tools/Invoke-AITestPilotReplayProfileImport.ps1`.
