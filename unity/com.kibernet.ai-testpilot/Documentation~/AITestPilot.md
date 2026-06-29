# Kibernet AI TestPilot Unity SDK

Install the package from `unity/com.kibernet.ai-testpilot`.

1. Add `AutomationId` to UI elements that the AI may inspect or click.
2. Register optional game-state capture through `GameStateProvider.CustomProvider`.
3. Open `Tools/Kibernet/AI TestPilot` to capture a snapshot, export JSON, or write a Cursor bug prompt.
4. Add `DecisionLoopRunner` to a scene for a local rule-based exploration pass.
5. Create `ModelEndpointSettings` from `Tools/Kibernet/AI TestPilot/Create Model Endpoint Settings` when wiring a model gateway.
6. Use `Tools/Kibernet/AI TestPilot/Create OpenAI-Compatible Model Endpoint Settings` when the gateway expects a chat-completions style request.
7. Create `ProductionReplayIntegrationPlan` from `Tools/Kibernet/AI TestPilot/Create Production Replay Integration Plan` when planning real game driver hook ownership.

The first package version intentionally ships a deterministic rule client so the SDK can be validated without a paid AI endpoint. `ModelEndpointSettings` and `ModelEndpointDecisionClient` define the Unity-side model gateway contract, including native JSON and OpenAI-compatible chat-completions request formats plus prior fix hints, but live requests are disabled by default and API keys should be provided through environment variables.
The production replay integration plan is a checklist artifact: generated validation evidence marks it `TEMPLATE_READY` and `realProjectBound=false` until the host game implements the required account, login, scene, reward, and fishing hooks against real project APIs.
Batch validation also proves `DecisionLoopRunner` can execute a multi-step sample goal and stop at the configured max-step boundary.
Batch validation also persists the source bug package as JSON/Markdown evidence before generating the repair task.
Batch validation also persists the bug knowledge graph as JSON/Markdown evidence with module and failure-type risk ranking.
Batch validation also persists a Cursor-ready repair-agent handoff with launch command, required context files, and retest command.
Batch validation also persists repair-agent run tracking with explicit external-agent boundary, expected patch output slots, and post-patch retest command.
The release pipeline also imports repair-agent patch output with deterministic sample patch/summary evidence, while marking `externalAgentRun=false` until an actual external repair agent has run.
The release pipeline also runs an external completion failure probe so pending repair-agent runs cannot be promoted to external-agent output just because patch files exist.
The release pipeline also proves verified external-agent patch import is not tied to the deterministic sample null-guard snippet.
The release pipeline also applies a verified external-agent patch to a clean candidate copied from the current source tree, runs repo validation there, and verifies rollback of newly added files.
Before any apply step, the release pipeline preflights repair-agent patch paths and runs a negative path-traversal probe so unsafe external diffs are blocked.
The release pipeline records a repository patch apply guard with explicit-switch, clean-worktree, external-source, and rollback-plan evidence before any real source mutation is allowed.
The release pipeline also proves the positive external-agent apply path in a clean temporary git repository and verifies the generated rollback patch restores the fixture.
The release pipeline also runs the post-patch repair retest after that clean temporary repository apply and before rollback, while keeping the main repository unmodified.
The release pipeline also applies the deterministic sample patch inside an evidence sandbox and runs the post-patch retest, while recording `repositoryPatchApplied=false`.
