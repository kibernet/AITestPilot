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
- Release-gated multi-bug patch-result history with module, failure-type, outcome, retest, rollback, and production-output boundary aggregates.
- Optional headless Cursor Agent external output generation for replacing the acceptance fixture on authenticated developer machines.
- Cursor Agent external output binding guard proving stale optional producer evidence cannot replace the current accepted external-output directory unless task context and file hashes match.
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
- Live model endpoint configuration kit, static config intake, and release-gated repo-external pending-config rejection evidence without serializing secrets or claiming provider access.
- Live model endpoint smoke evidence intake with release-gated repo-external skipped-evidence rejection for host-project live smoke handoff.
- Live model endpoint smoke evidence accepted-contract probe with isolated PASS-shaped host-project evidence intake, contract-mode-only canonical promotion, and fixture boundary proof.
- Core Lua static analyzer and release-gated static-analysis evidence for replay repair candidates.
- Release-gated Lua auto-patch sandbox evidence that clears deterministic fixture findings without mutating production Lua.
- Production Lua patch readiness gate plus hard-bound failure probe for real production Lua analysis, patch, retest, and rollback evidence.
- Production Lua patch evidence kit generator plus release-gated accepted-fixture contract probe for host-project Lua evidence handoff.
- Production Lua external bundle intake probe for repo-external host-project evidence directories, with incomplete template evidence blocked under hard production mode.
- Production replay integration plan asset plus JSON/Markdown checklist evidence, explicitly marked unbound until real project APIs are wired.
- Production replay integration contract probe proving `TEMPLATE_READY`, invalid flip, and `BOUND` checklist states without claiming real game API calls.
- Production driver evidence intake gate for standalone real-project evidence bundles, with default sample/unbound rejection evidence.
- Production driver binding kit generator plus release-gated probe for host-project starter files and a production-bound evidence export helper that rejects sample/unbound evidence.
- Production driver evidence contract probe proving an isolated BOUND fixture can pass intake without being promoted as real production evidence.
- Repo-external production driver evidence bundle intake probe for host-project release-evidence directories outside this repository.
- Production-bound replay driver failure probe plus release-pipeline/release-gate switches that make real project binding a hard CI requirement when requested.
- GitHub Actions release workflow for self-hosted Windows Unity runners, with workflow-dispatch release controls, evidence artifact upload, and release-gated workflow probe.
- Azure Pipelines release workflow for self-hosted Windows Unity pools, with release-control parameters, evidence artifact publishing, and release-gated workflow probe.
- Provider-specific build, smoke test, and vision evidence checks for GitHub Actions and Azure Pipelines, with release-gated quality probe evidence.
- Production handoff package that consolidates host-project production driver, Lua, live-model, and CI hard-mode next steps without promoting fixture evidence, with generated-content quality checks, a blocker-resolution map, per-owner action packets, a returned-evidence inbox and inbox contract probe that accept direct inbox files plus owner response bundle directories/zips, a compact production handoff export zip refreshed after owner kit workflow proof and action queue proof so it includes the fillable owner response bundle kit with source-to-export SHA256 proof for every kit file, final `operator-actions\NEXT-STEPS.md`, canonical action queue from the remaining-work snapshot, and separate probe proof, zip entry/hash index proof, owner-level evidence collection status, owner dispatch queue and email drafts, owner contact roster readiness and contact-readiness contract proof, guarded owner send readiness, owner send dry-run proof without local mail authorization, owner send local workflow proof with confirmation-token and fake-receipt boundaries, owner packet dispatch receipt intake proof, owner packet real receipt guard proof, repo-external owner response bundle proof, fillable owner response bundle kit and zip with semantic preflight called out before auto acceptance, generated-kit workflow proof for verifier/import helper behavior, canonical external evidence action queue proof plus separate pending/post-dispatch probe proof for queue-level and item-level owner response bundle directory/zip semantic-preflight-before-auto-acceptance commands, machine-readable external evidence gap analysis, production handoff owner route map and probe as release-gated handoff proof for the three external owner routes from owner packet/contact/send through owner response bundle required-files, semantic preflight, auto acceptance, and hard validation while preserving the 3 work items / 9 missing files / 11 blockers / 0 repo-side closable boundary, final progress-notification refresh targeting that owner route map, partial/malformed owner response bundle rejection matrix proof, returned-evidence semantic preflight proof via `production-external-evidence-semantic-preflight-probe-manifest.json` with `readyForAcceptanceCandidate`, `semanticPreflightStatus`, and `semanticFailCount` checks, external evidence auto-discovery/acceptance proof for evidence roots plus owner response bundle directories/zips, local mail authorization readiness, owner unblock packaging and contract proof, owner input request packaging for contacts, pending dispatches, returned evidence, and progress-recipient email drafts, repo-external owner contact intake proof, a release progress notification outbox for big-node status emails with small-node suppression and a remaining-work snapshot plus independent snapshot probe, mail-helper auth-status parsing proof, progress-notification fake confirmation proof, progress-notification receipt proof, progress-notification dispatch receipt intake proof, progress-notification local send workflow proof, progress-notification real receipt guard proof, operator-side post-dispatch remaining-work snapshot support plus a fixture rejection probe, runnable external-evidence preflight and acceptance-wrapper scripts, a stable repo-side external evidence acceptance command, accepted-fixture contract probes, and missing/partial evidence failure probes for owner-facing action plans.
- Production hard-mode failure probe proving combined production driver, Lua, and live-model hard switches block current sample or missing evidence.
- Production hard-mode success contract probe proving combined production driver, Lua, and live-model hard switches pass with complete accepted fixture evidence in an isolated bundle while preserving the default real-evidence boundary.
- release docs freshness guard proving README, CI release docs, architecture, roadmap, pipeline step IDs, core artifact names, source files, and release source-manifest lists stay aligned before hard-mode and release gate checks.
- Release-gated machine-readable release evidence index for CI, portal handoff, and audit consumers, with release evidence index field coverage for 80 semantic fields plus field-level definition/source-script SHA256 binding, a source manifest SHA256 hash set, and a six-scenario field coverage probe that protects the latest bundle from isolated-case pollution and proves no email is sent, no real host-project evidence is accepted, and no fixture evidence is promoted to production evidence.
- Release-gated Cursor Agent external output binding probe before the release gate, with `repair-agent-cursor-agent-external-output-binding-probe-manifest.json` covering no-Cursor baseline, stale optional evidence rejection, hash-mismatch rejection, and matched binding pass cases.
- Release-gated risk policy with release risk policy source script SHA256 binding, blocking failing AI exploration, unresolved high-risk graph nodes, missing production driver evidence, missing production Lua evidence, missing live endpoint policy evidence, missing CI provider controls, missing production handoff evidence, or missing hard-mode failure/success-contract evidence.

## V0.2 Unity Import Gate

- Export release evidence into a stable CI artifact directory.
- Replace the sample `IGameActionReplayDriver` and unbound production replay checklist with real project implementations for login, activity reward, fishing, and account setup, then run production readiness with `-RequireProductionBound` or the pipeline with `-RequireProductionReplayDriverBound`.

## V0.3 Model Bridge

- Real live endpoint credentials, provider access, and production smoke evidence for the selected deployment, with direct smoke-manifest provenance such as `realProviderAccessProven=true`, `liveSmokeExecuted=true`, `productionLiveEndpointAccessProven=true`, and `evidenceProvenance=direct_live_http_endpoint_pass`.

## V0.4 Retest and Repair Loop

- Provide a real production Lua evidence bundle that satisfies the guarded readiness contract and rerun the pipeline with `-RequireProductionLuaPatched`.
- Replace the sample-domain patch target with actual production code or prefab changes from a completed real repair-agent run.
- Run a real external repair-agent patch against the main product worktree, generate rollback evidence, and re-run the captured steps after a production code or prefab change.

## V0.5 Knowledge Graph Persistence

- Ingest real production repair-agent output into the persisted patch-result history.

## V0.6 CI/CD Gate

- Extend provider-specific CI beyond GitHub Actions and Azure Pipelines if other providers are required.
