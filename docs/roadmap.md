# AI TestPilot Roadmap

## V0.1 Repo Baseline

- Buildable .NET core.
- Smoke-tested decision loop.
- Unity UPM SDK package.
- Editor snapshot export and Cursor prompt bridge.
- Unity batchmode sample-scene validation.
- Multi-step `DecisionLoopRunner` validation with max-step boundary evidence.
- Snapshot JSON schema regression check.
- Durable run, retest, and release evidence documents.
- Persisted bug package JSON/Markdown artifacts.
- Persisted bug knowledge graph JSON/Markdown artifacts with module and failure-type risk ranking.
- Structured repair task JSON/Markdown for a fixing agent.
- Cursor-ready repair-agent handoff JSON/Markdown with launch command and required context files.
- Repair-agent run tracking JSON/Markdown with explicit external-agent boundary and expected patch output slots.
- Repair-agent patch output import manifest with deterministic sample patch/summary validation in the release pipeline.
- Repair-agent external completion provenance guard and pending-run failure probe.
- Generic external repair-agent patch import probe that is not tied to the deterministic sample null-guard snippet.
- Source snapshot apply/validate/rollback probe for verified external-agent patches.
- Main worktree apply-readiness evidence for dirty-baseline blockers and clean-baseline readiness.
- Task-bound main worktree apply/retest/rollback evidence for the explicit external-agent guarded path.
- External repair-agent task output directory intake acceptance for the main worktree apply/retest/rollback path.
- Repair-agent patch result analysis that feeds prior fix hints into post-agent retest and knowledge graph outcome.
- Optional headless Cursor Agent external output generation for replacing the acceptance fixture on authenticated developer machines.
- External repair-agent patch safety preflight with target-path policy and negative path-traversal probe.
- Repository patch apply guard with explicit apply switch, clean-worktree requirement, and rollback/no-mutation evidence.
- Clean temporary repository apply/rollback probe for external-agent patch output.
- Clean temporary repository apply/retest/rollback probe for external-agent patch output.
- Repair-agent patch apply/retest manifest with sandbox patch application and post-patch retest evidence.
- Targeted repair-task retest command.
- Replay adapter registry for game-specific action playback.
- Sample business replay path for scene entry, activity reward, and fishing action.
- Persisted ScriptableObject replay profile plus JSON export.
- Import-from-JSON profile tooling for non-Unity authoring workflows.
- Runtime `IGameActionReplayDriver` contract for account setup, login, scene entry, activity reward, and fishing.
- Driver registry plus batch retest type selection for production replay adapters.
- Hooks-based production driver adapter, diagnostics, and copyable driver template.
- Driver capability/configuration descriptor in repair retest evidence.
- Negative replay-driver failure probe for CI diagnostics.
- Production replay driver readiness manifest with explicit sample/unbound blockers.
- Repo-side release gate over scene, retest, driver descriptor, negative probe, and profile import evidence.
- One-command release pipeline with stable CI artifact output.
- Core HTTP/JSON model endpoint decision client with action schema validation and per-step trace artifacts.
- Model endpoint trace probe enforced by the repo-side release gate.
- Prior fix hints included in model endpoint requests and release evidence.
- Unity model endpoint settings asset, editor creation flow, and offline request-contract evidence.
- Optional live model endpoint smoke with a production CI enforcement switch.
- OpenAI-compatible chat-completions request wrapper for generic model gateways.
- Provider preset diagnostics for native, OpenAI, OpenAI-compatible, and local OpenAI-compatible model gateways.
- Deterministic live endpoint failure probe with auth failure classification and trace evidence.
- Live endpoint failure remediation hints for auth, rate limit, request/endpoint, provider outage, timeout, network, empty response, response contract, configuration, and unknown failures.
- Live endpoint retry/escalation policy recorded in failure evidence.
- Policy-driven live endpoint retry execution with per-attempt manifest evidence.
- Provider-specific live-smoke retry tuning and alert routing for native, OpenAI, OpenAI-compatible, and local gateways.
- Production replay integration plan asset plus JSON/Markdown checklist evidence, explicitly marked unbound until real project APIs are wired.
- Production replay integration contract probe proving `TEMPLATE_READY`, invalid flip, and `BOUND` checklist states without claiming real game API calls.
- Production driver evidence intake gate for standalone real-project evidence bundles, with default sample/unbound rejection evidence.
- Production driver binding kit generator plus release-gated probe for host-project starter files.
- Repo-external production driver evidence bundle intake probe for host-project release-evidence directories outside this repository.
- Production-bound replay driver failure probe plus release-pipeline/release-gate switches that make real project binding a hard CI requirement when requested.
- GitHub Actions release workflow for self-hosted Windows Unity runners, with workflow-dispatch release controls, evidence artifact upload, and release-gated workflow probe.

## V0.2 Unity Import Gate

- Export release evidence into a stable CI artifact directory.
- Replace the sample `IGameActionReplayDriver` and unbound production replay checklist with real project implementations for login, activity reward, fishing, and account setup, then run production readiness with `-RequireProductionBound` or the pipeline with `-RequireProductionReplayDriverBound`.

## V0.3 Model Bridge

- Real live endpoint credentials, provider access, and production smoke evidence for the selected deployment.

## V0.4 Retest and Repair Loop

- Replace the sample-domain patch target with actual production code or prefab changes from a completed real repair-agent run.
- Run a real external repair-agent patch against the main product worktree, generate rollback evidence, and re-run the captured steps after a production code or prefab change.

## V0.5 Knowledge Graph Persistence

- Persist patch-result analysis across multi-bug historical runs and real production repair-agent output.

## V0.6 CI/CD Gate

- Add provider-specific build/test/vision checks beyond the current release workflow.
- Extend provider-specific CI beyond the current GitHub Actions release workflow if other providers are required.
- Block release on failing AI exploration, missing driver evidence, or unresolved high-risk graph nodes.
- Export machine-readable release evidence.
