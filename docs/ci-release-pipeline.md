# CI Release Pipeline

Use the release pipeline wrapper when CI needs one command with stable artifacts and exit-code behavior.

```powershell
.\tools\Invoke-AITestPilotReleasePipeline.ps1
```

## Release Pipeline Step Index

`tools\Invoke-AITestPilotReleaseDocsFreshnessProbe.ps1` treats this table as the machine-checked release step coverage contract. Keep each step ID aligned with `Invoke-PipelineStep` entries in `tools\Invoke-AITestPilotReleasePipeline.ps1`.

| # | Step ID |
| ---: | --- |
| 1 | `repo_validation` |
| 2 | `unity_import_scene_validation` |
| 3 | `repair_agent_patch_output_import` |
| 4 | `repair_agent_external_completion_failure_probe` |
| 5 | `repair_agent_generic_patch_import_probe` |
| 6 | `repair_agent_source_snapshot_apply_validate` |
| 7 | `repair_agent_main_worktree_apply_readiness` |
| 8 | `repair_agent_cursor_agent_external_task_output` |
| 9 | `repair_agent_external_task_output_acceptance` |
| 10 | `repair_agent_patch_result_analysis` |
| 11 | `repair_agent_patch_result_history` |
| 12 | `repair_agent_external_patch_preflight` |
| 13 | `repair_agent_external_patch_preflight_failure_probe` |
| 14 | `repair_agent_repository_patch_apply_guard` |
| 15 | `repair_agent_repository_patch_apply_clean_probe` |
| 16 | `repair_agent_repository_patch_apply_clean_retest` |
| 17 | `repair_agent_patch_apply_retest` |
| 18 | `driver_failure_probe` |
| 19 | `targeted_repair_retest` |
| 20 | `replay_profile_import` |
| 21 | `production_replay_integration_contract_probe` |
| 22 | `production_driver_binding_kit_probe` |
| 23 | `production_driver_evidence_contract_probe` |
| 24 | `production_replay_driver_readiness` |
| 25 | `production_driver_evidence_intake` |
| 26 | `production_driver_external_bundle_intake_probe` |
| 27 | `production_replay_driver_bound_failure_probe` |
| 28 | `model_endpoint_trace_probe` |
| 29 | `model_endpoint_provider_diagnostics` |
| 30 | `model_endpoint_provider_retry_policy` |
| 31 | `live_model_endpoint_config_kit_probe` |
| 32 | `lua_static_analysis_probe` |
| 33 | `lua_auto_patch_sandbox_probe` |
| 34 | `production_lua_patch_readiness` |
| 35 | `production_lua_patch_bound_failure_probe` |
| 36 | `production_lua_patch_evidence_kit_probe` |
| 37 | `production_lua_patch_external_bundle_intake_probe` |
| 38 | `live_model_endpoint_failure_probe` |
| 39 | `live_model_endpoint_smoke` |
| 40 | `live_model_endpoint_smoke_evidence_intake` |
| 41 | `live_model_endpoint_external_smoke_intake_probe` |
| 42 | `live_model_endpoint_smoke_evidence_contract_probe` |
| 43 | `ci_provider_release_workflow_probe` |
| 44 | `ci_provider_azure_pipelines_workflow_probe` |
| 45 | `ci_provider_quality_probe` |
| 46 | `production_handoff_package` |
| 47 | `production_handoff_external_evidence_preflight_probe` |
| 48 | `production_external_evidence_acceptance_contract_probe` |
| 49 | `production_external_evidence_acceptance_failure_probe` |
| 50 | `production_external_evidence_inbox` |
| 51 | `production_external_evidence_inbox_contract_probe` |
| 52 | `production_external_evidence_auto_acceptance_probe` |
| 53 | `production_handoff_export` |
| 54 | `production_handoff_status` |
| 55 | `production_handoff_dispatch_plan` |
| 56 | `production_handoff_contact_readiness` |
| 57 | `production_handoff_contact_readiness_contract_probe` |
| 58 | `production_handoff_send_readiness` |
| 59 | `production_handoff_mail_auth_readiness` |
| 60 | `production_handoff_owner_unblock_pack` |
| 61 | `production_handoff_owner_unblock_pack_contract_probe` |
| 62 | `production_handoff_owner_input_request_pack` |
| 63 | `production_handoff_owner_contact_external_intake_probe` |
| 64 | `production_handoff_send_dry_run_probe` |
| 65 | `production_handoff_owner_response_bundle_probe` |
| 66 | `production_handoff_owner_response_bundle_kit` |
| 67 | `production_handoff_owner_response_bundle_kit_workflow_probe` |
| 68 | `production_handoff_export_refresh` |
| 69 | `release_progress_notification_outbox` |
| 70 | `release_progress_notification_remaining_work_snapshot_probe` |
| 71 | `production_handoff_mail_helper_auth_status_probe` |
| 72 | `production_handoff_send_local_workflow_probe` |
| 73 | `production_handoff_owner_packet_dispatch_receipt_intake_probe` |
| 74 | `production_handoff_owner_packet_real_receipt_guard_probe` |
| 75 | `release_progress_notification_confirmation_probe` |
| 76 | `release_progress_notification_receipt_probe` |
| 77 | `release_progress_notification_dispatch_receipt_intake_probe` |
| 78 | `release_progress_notification_local_send_workflow_probe` |
| 79 | `release_progress_notification_real_receipt_guard_probe` |
| 80 | `release_progress_notification_post_dispatch_snapshot_probe` |
| 81 | `production_external_evidence_action_queue` |
| 82 | `production_external_evidence_action_queue_probe` |
| 83 | `production_external_evidence_gap_analysis` |
| 84 | `production_handoff_owner_route_map` |
| 85 | `production_handoff_owner_route_map_probe` |
| 86 | `release_progress_notification_outbox_final_refresh` |
| 87 | `release_progress_notification_remaining_work_snapshot_final_probe` |
| 88 | `production_external_evidence_partial_matrix_probe` |
| 89 | `production_external_evidence_semantic_preflight_probe` |
| 90 | `production_handoff_export_final_refresh` |
| 91 | `production_handoff_export_zip_index` |
| 92 | `release_docs_freshness` |
| 93 | `production_hard_mode_failure_probe` |
| 94 | `production_hard_mode_success_contract_probe` |
| 95 | `release_risk_policy` |
| 96 | `repair_agent_cursor_agent_external_output_binding_probe` |
| 97 | `release_evidence_index` |
| 98 | `release_evidence_index_field_coverage_probe` |
| 99 | `release_gate` |
| 100 | `release_gate_failure_probe` |

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
- production driver binding kit probe, proving the host-project starter kit and production-bound evidence export helper can be generated without claiming production-bound evidence.
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
- live model endpoint smoke evidence contract probe, proving PASS-shaped host-project smoke evidence can be accepted and promoted only inside an isolated contract-mode bundle without proving fixture provider access.
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
- production handoff package generation, consolidating driver, Lua, live-model, and CI hard-mode host-project next steps without promoting fixture evidence, with generated-content quality checks, a blocker-resolution map, per-owner action packets, a runnable external-evidence preflight script, and a unified acceptance-wrapper script.
- production handoff external evidence preflight probe, proving that generated preflight script accepts complete host-project-shaped fixture evidence with `-RequireAllEvidence -RunIntake` and that the generated acceptance wrapper writes a validated Markdown report while preserving the fixture boundary.
- production external evidence inbox, generating the returned-evidence directory layout and wrapper owners use to submit driver, Lua, and live-smoke evidence.
- production external evidence inbox contract probe, proving the returned-evidence inbox wrapper accepts complete host-project-shaped fixture evidence while preserving the fixture boundary.
- production handoff export, creating a compact owner-facing export folder and zip with the handoff package, owner packets, generated kits, and contract reports.
- production handoff status, summarizing accepted versus pending owner packets, remaining blockers, required evidence files, and next acceptance commands.
- production handoff dispatch plan, generating a per-owner dispatch queue and email drafts while keeping real owner addresses and send state explicit.
- production handoff contact readiness, generating a contact roster template and proving real owner email addresses are still missing before automatic dispatch.
- production handoff contact readiness contract probe, proving a complete configured owner-contact roster can pass readiness while preserving the not-sent and fixture boundaries.
- production handoff send readiness, generating a guarded owner-packet send queue and agently-cli helper while keeping missing contacts, mail authorization, and two-stage confirmation explicit.
- production handoff mail auth readiness, generating local agently-cli authorization helper scripts while proving CI does not run OAuth login or send owner packet emails.
- production handoff owner unblock pack, consolidating the remaining owner contacts, blocked sends, mail auth boundary, missing returned evidence, and operator next steps into one distribution-ready artifact without claiming completion.
- production handoff owner unblock pack contract probe, proving the default unblock pack stays blocked and a complete fixture contact/evidence copy moves to ready-for-confirmation while preserving mail-auth and real-evidence boundaries.
- production handoff owner input request pack, turning the remaining owner contacts, pending dispatches, pending packets, returned-evidence files, and blocker reasons into an owner-facing request package and progress-recipient email draft without sending mail or accepting evidence.
- production handoff owner contact external intake probe, proving a repo-external owner contact roster can be imported into an isolated bundle and move owner sends to ready-for-confirmation while preserving default missing-contact and not-sent boundaries.
- production handoff send dry-run probe, proving owner-packet send previews work without local agently-cli authorization for both default blocked contacts and accepted external-contact intake bundles.
- production handoff send local workflow probe, proving the local owner-packet send workflow stops before unauthenticated send, requests confirmation tokens before sending, writes token-confirmed fake receipts, and preserves the no-real-send and no-CI-send boundaries.
- production handoff owner packet dispatch receipt intake probe, proving fake owner-packet workflow receipts are rejected while contract-shaped and queued-only receipts are accepted only as non-real-send dispatch evidence.
- production handoff owner packet real receipt guard probe, proving accepted owner-packet receipts still cannot set `emailSent=true` without explicit operator real-send confirmation and contract fixture mode cannot claim real delivery.
- production handoff owner response bundle probe, proving a repo-external owner response bundle can carry contacts plus returned driver, Lua, and live-smoke evidence into an isolated bundle and move owner unblock state to ready-for-confirmation without sending email or promoting fixtures.
- production handoff owner response bundle kit, producing a fillable owner-return template zip with contact roster, driver/Lua/live-smoke evidence directories, required-file manifests, verification/import helpers, and a request draft that keeps semantic preflight before auto acceptance without sending email or accepting evidence.
- production handoff export refresh, re-running the export after the owner response bundle kit workflow probe so the final owner-facing zip includes the fillable owner response bundle kit, source-to-export SHA256 proof for every kit file, and its returned folder/zip semantic-preflight-then-auto-acceptance instructions.
- production external evidence action queue, writing the canonical operator action queue from the current remaining-work snapshot before the probe runs, while preserving the no-mail, no-real-evidence, and no-fixture-promotion boundaries.
- production external evidence action queue probe, proving isolated pending and post-dispatch probe queues preserve the local-mail boundary, reduce tracked work to the three external evidence areas only after post-dispatch evidence, and expose owner response bundle directory/zip semantic-preflight and auto-acceptance commands at queue and item level without sending mail or accepting evidence.
- production external evidence gap analysis, converting the canonical action queue and current remaining-work snapshot into a machine-readable operator/audit summary with three external gaps, nine missing files, eleven blockers, zero repo-side-closable gaps, and the next owner/operator commands, with semantic preflight first.
- production handoff owner route map, tying each external gap to its owner packet, contact/send state, owner response bundle area, `required-files.json`, semantic preflight command, auto-acceptance command, and hard-validation command without claiming repo-side closure.
- production handoff owner route map probe, proving the current route map passes while owner-route mismatches, missing route endpoints, and auto acceptance without semantic preflight are blocked in isolated bundle copies.
- production external evidence partial matrix probe, proving driver-only, Lua-only, live-smoke-only, one-file-missing, and malformed owner response bundle returns are rejected before acceptance can claim all production evidence is ready.
- production external evidence semantic preflight probe, proving returned owner bundles are read-only checked for missing files, candidate-ready contract shape, and fixture/template semantic failures before auto acceptance runs; operators inspect `readyForAcceptanceCandidate`, `semanticPreflightStatus`, and `semanticFailCount`, and the preflight does not copy returned evidence or promote fixtures. `OwnerResponseBundleZipPath` covers complete owner response bundle zip, partial zip, semantic-bad zip, and arbitrary single top-level wrapper zip cases; unsafe, duplicate, absolute, or traversal zip entries are rejected before extraction, while safe zips resolve to the bundle root. The auto-acceptance probe also re-runs that semantic gate on evidence roots plus owner response bundle directories/zips, and rejects complete semantic-bad bundles before acceptance.
- production handoff export final refresh, re-running the export after the canonical action queue and action queue probe so `operator-actions\` carries `NEXT-STEPS.md`, the canonical action queue, remaining-work source snapshot, and separate action-queue probe proof in the final owner-facing zip.
- production handoff export zip index, opening the final owner-facing zip and proving its entries and per-entry hashes match the export manifest and source folder with no unsafe or duplicate paths.
- release docs freshness, proving the README, CI release pipeline docs, architecture doc, roadmap, pipeline step index, required release artifact names, source files, and source-manifest coverage stayed aligned before hard-mode copied-bundle probes run.
- release progress notification outbox, preparing the requested big-node status email for the progress recipient, writing a `BIG_NODE_ONLY` cadence policy that suppresses separate small proof/probe emails, writing a remaining-work snapshot for the three external owner areas plus the local progress-mail action, and keeping local agently-cli authorization plus two-stage send confirmation outside CI.
- release progress notification remaining-work snapshot probe, independently verifying the outbox snapshot against owner input, driver readiness, Lua readiness, and the returned-evidence inbox while preserving the local mail boundary; it is recorded as a suppressed small proof node under the big-node-only cadence.
- production handoff mail helper auth-status probe, proving owner-packet and progress-notification helpers parse unauthenticated agently-cli JSON-plus-tip output and stop before +me, confirmation tokens, or message sends.
- release progress notification confirmation probe, proving the progress helper requests a fake confirmation token first and only reaches the fake send success path after a token is supplied.
- release progress notification receipt probe, proving a fake token-confirmed progress helper success writes a machine-readable send receipt without claiming real delivery.
- release progress notification dispatch receipt intake probe, proving fake send receipts are rejected and contract-shaped receipts are accepted only as shape proof until a real local send receipt is provided.
- release progress notification post-dispatch snapshot helper, for operator-side use after a real local receipt intake has passed; it clears the local progress-mail action without changing the CI no-send boundary.
- release progress notification post-dispatch snapshot probe, proving contract fixture receipt intake is rejected by the post-dispatch helper and cannot clear the local progress-mail remaining action.
- release progress notification local send workflow probe, proving the operator flow stops before send when unauthenticated, requests a confirmation token first when logged in, writes a receipt after token confirmation, and keeps receipt intake contract-only.
- release progress notification real receipt guard probe, proving a valid receipt still cannot set `emailSent=true` without explicit operator receipt confirmation and contract fixture mode cannot claim a real send.
- production external evidence acceptance contract probe, proving the stable repo-side acceptance entry point accepts complete driver, Lua, and live-smoke evidence and writes a validated Markdown report without promoting fixture data.
- production external evidence acceptance failure probe, proving fully missing and driver-only partial evidence cannot satisfy the stable acceptance entry point under `-RequireAllEvidence` while still writing validated rejection reports.
- production hard-mode failure probe, proving combined driver, Lua, and live-model hard switches block the current sample or missing-evidence state.
- production hard-mode success contract probe, proving combined driver, Lua, and live-model hard switches can pass with complete accepted fixture evidence in an isolated bundle while preserving the default real-evidence boundary.
- release risk policy, aggregating AI exploration, high-risk graph, production driver, production Lua, live endpoint, and CI provider release blockers.
- Cursor Agent external output binding probe, proving stale optional headless Cursor Agent producer files cannot be treated as the current accepted external-output directory unless task context and run/patch/summary hashes match.
- release evidence index, exporting a machine-readable source-manifest summary for CI, portal handoff, and audit consumers, including field-level coverage for 74 semantic fields across the primary release evidence manifests plus field-level definition and source script SHA256 binding plus source manifest SHA256 hash set binding.
- release evidence index field coverage probe, proving six isolated scenarios for the index field checks and latest-bundle pollution guard before the release gate runs. The probe does not send email, accept real host-project evidence, or promote fixture evidence into production evidence.
- repo-side release gate.
- release-gate failure probe.

## Artifacts

By default, the pipeline copies the latest evidence bundle to:

`artifacts/ai-testpilot-release/latest`

That directory includes `pipeline-manifest.json`, `release-gate-manifest.json`, release gate manifests, release evidence index JSON/Markdown, release risk policy JSON/Markdown, `release-docs-freshness-manifest.json`, provider CI quality probe evidence, production handoff package evidence, production handoff blocker-resolution evidence, production handoff external evidence preflight contract evidence, returned external evidence inbox evidence and contract proof, production handoff export evidence and zip with final `operator-actions\NEXT-STEPS.md` content plus zip entry/hash index evidence, production handoff status evidence, owner dispatch queue and email drafts, owner contact roster readiness and contract evidence, guarded owner send readiness evidence, local mail authorization readiness evidence, owner unblock pack and contract evidence, owner input request pack evidence, owner contact external intake probe evidence, owner send dry-run probe evidence, owner send local workflow probe evidence, owner packet dispatch receipt intake proof, owner packet real receipt guard proof, owner response bundle probe evidence, owner response bundle kit evidence and zip, owner response bundle kit workflow proof, external evidence action queue proof with item-level returned-bundle paths and semantic-preflight-before-auto-acceptance commands, external evidence gap analysis, partial/malformed returned-bundle rejection matrix evidence, returned-evidence semantic preflight evidence with candidate-ready/status/fail-count fields plus complete owner response bundle zip, partial zip, semantic-bad zip, and arbitrary single top-level wrapper zip coverage, external evidence auto-acceptance proof for evidence roots plus owner response bundle directories/zips, release progress notification outbox evidence including the remaining-work snapshot and snapshot probe, mail-helper auth-status parsing proof, progress-notification confirmation proof, progress-notification receipt proof, progress-notification dispatch receipt intake proof, progress-notification local send workflow proof, progress-notification real receipt guard proof, post-dispatch snapshot fixture rejection proof, production external evidence acceptance contract and failure evidence, production hard-mode failure and success-contract probe evidence, repair-agent patch output import evidence, external completion failure-probe evidence, generic external patch import evidence, source snapshot apply/validate evidence, main worktree apply-readiness evidence, external task output acceptance evidence, optional Cursor Agent external output binding probe evidence, repair-agent patch result analysis evidence, repair-agent patch result history evidence, main worktree apply/retest/rollback evidence, external patch preflight evidence, unsafe patch failure-probe evidence, repository patch apply guard evidence, clean temporary repository apply/rollback evidence, clean temporary repository apply/retest/rollback evidence, repair-agent patch apply/retest evidence, retest evidence, failure-probe evidence, replay profile artifacts, production replay integration contract evidence, production driver binding kit evidence, production replay driver readiness evidence, production driver evidence intake evidence, production driver evidence contract evidence, repo-external production bundle intake evidence, production-bound failure-probe evidence, model endpoint request/response/trace evidence, provider diagnostics, provider retry policy evidence, live model endpoint config kit and intake evidence, external live-smoke intake evidence, live-smoke accepted-contract evidence, Lua static analysis evidence, Lua auto-patch sandbox evidence, production Lua patch readiness evidence, production Lua evidence kit evidence, production Lua external bundle intake evidence, live endpoint failure-classification evidence, optional live model smoke evidence, GitHub Actions workflow probe evidence, Azure Pipelines workflow probe evidence, and Unity logs.

`release-evidence-index-field-coverage-probe-manifest.json`, `release-evidence-index-field-coverage-probe.md`, and `release-evidence-index-field-coverage-probe\` are generated after `release_evidence_index` and before `release_gate`. They record six isolated scenarios: a baseline pass, owner-send auto-email promotion rejection, owner-packet fake-receipt promotion rejection, semantic-preflight read-only enforcement, handoff export NEXT-STEPS validation rejection, and live-smoke fixture rejection outside contract mode. The probe snapshots the latest bundle and must prove the index files, live-smoke manifest, and latest manifest count are unchanged except for its own report artifacts.

`repair-agent-cursor-agent-external-output-binding-probe-manifest.json`, `repair-agent-cursor-agent-external-output-binding-probe.md`, and `cursor-agent-external-output-binding-probe\` are generated after `release_risk_policy` and before `release_evidence_index`. The guard keeps the default deterministic pipeline valid with no Cursor Agent manifest, then proves stale optional Cursor Agent evidence paired with fixture acceptance is blocked, producer/acceptance hash mismatches are blocked, and a matched headless Cursor Agent producer manifest can pass without sending mail or accepting real host-project evidence.

`production-external-evidence-action-queue-manifest.json` is the canonical operator queue generated from the current remaining-work state. `production-external-evidence-action-queue-probe-manifest.json` remains the contract proof for pending versus post-dispatch queue behavior; both are required release evidence before gap analysis and the final owner-facing export refresh.

`production-handoff-owner-route-map-manifest.json`, `production-handoff-owner-route-map.md`, `production-handoff-owner-route-map-probe-manifest.json`, `production-handoff-owner-route-map-probe.md`, and `production-handoff-owner-route-map-probe\` are generated after `production_external_evidence_gap_analysis` and before the progress-notification final refresh. They prove each of the three external owner areas maps cleanly from owner packet and contact/send state through returned bundle required files, semantic preflight, auto acceptance, and hard validation; the probe blocks owner-route mismatches, missing route endpoints, and auto acceptance without semantic preflight.

`release_progress_notification_outbox_final_refresh` and `release_progress_notification_remaining_work_snapshot_final_probe` rerun the progress outbox and remaining-work snapshot probe after the owner route map is available. The final outbox latest big node is `production_handoff_owner_route_map`, while the earlier outbox snapshot remains available to feed action queue and gap analysis without sending email.

`production-handoff-package-manifest.json` is generated before the release risk policy. It points host-project owners at the exact driver, Lua, and live-model evidence files and hard-mode release-pipeline commands needed to replace the package fixtures with real production evidence. The package also validates that generated Markdown and command files contain concrete owner names, kit paths, required evidence files, blocker-resolution rows, per-owner packet commands, release commands, preflight commands, and acceptance-wrapper commands rather than serialized PowerShell object names. The generated `blocker-resolution-map.json` and `blocker-resolution-map.md` map every remaining production blocker to its owner, evidence files, acceptance criteria, and validation command. The generated `owner-packets\*.md` files split those rows into one executable packet per host-project owner, with required evidence, blocker reasons, preflight, acceptance-wrapper, and hard-validation commands. The generated `verify-external-evidence.ps1` preflights driver, Lua, and live-model evidence paths and writes `external-evidence-preflight-self-check.json`; the generated `accept-external-evidence.ps1` runs the stable external evidence acceptance command and writes the Markdown acceptance report before optional hard validation. The default self-check must remain pending for the three real host-project evidence areas. `production-handoff-external-evidence-preflight-probe-manifest.json` then runs the generated preflight and acceptance wrapper against complete accepted fixture evidence from outside the repository with contract boundaries preserved, recording `production-handoff-external-evidence-preflight-accepted-manifest.json` and `production-handoff-external-evidence-acceptance-wrapper-manifest.json` as contract proof only.

`production-handoff-export-manifest.json` is generated before the release risk policy. It validates `production-handoff-export.zip`, which packages the owner-facing handoff folder, owner packets, generated driver/Lua/live-model kits, semantic-preflight/auto-acceptance instructions, and accepted/rejected contract reports into a compact artifact for external owners while preserving `realHostProjectEvidenceAccepted=false` and `fixtureEvidencePromoted=false`.

`production-handoff-export-zip-index-manifest.json` is generated before the release risk policy. It validates `production-handoff-export.zip` by computing the archive SHA256, enumerating file entries, rejecting unsafe or duplicate entry names, and comparing every zipped entry hash to the matching `production-handoff-export\` source file.

`production-external-evidence-inbox-manifest.json` is generated before the release risk policy. It validates `production-external-evidence-inbox`, a returned-evidence directory layout containing driver, Lua, and live-smoke folders plus `accept-returned-evidence.ps1`; the wrapper accepts direct inbox files, a filled owner response bundle directory, or a filled owner response bundle zip. In the default package-release path it reports nine missing required files and no accepted real host-project evidence.

`production-external-evidence-inbox-contract-probe-manifest.json` is generated before the release risk policy. It fills the returned-evidence inbox with complete accepted fixture evidence from outside the repository, runs `accept-returned-evidence.ps1` with contract mode through direct inbox files, owner response bundle directory, and owner response bundle zip inputs, and records acceptance Markdown while preserving `realHostProjectEvidenceAccepted=false` and `releasePipelineUsesFixture=false`.

`production-external-evidence-gap-analysis-manifest.json` is generated before the release risk policy. It summarizes the post-dispatch external evidence queue as three remaining owner areas, nine missing files, eleven blockers, zero repo-side-closable gaps, and the next owner/export, operator/acceptance, and hard-validation commands while preserving the no-mail, no-real-evidence, and no-fixture-promotion boundaries.

`production-external-evidence-partial-matrix-probe-manifest.json` is generated before the release risk policy. It constructs isolated returned owner-bundle variants for driver-only, Lua-only, live-smoke-only, one required driver file missing, and malformed zip cases, and the probe passes only when all five are rejected without running acceptance or claiming real host-project evidence.

`production-external-evidence-semantic-preflight-probe-manifest.json` is generated before the final handoff export refresh and release risk policy. It runs the read-only semantic preflight over missing evidence, complete contract-shaped external roots, complete owner response bundle directories, complete owner response bundle zips, partial owner response bundle directories/zips, semantic-bad owner response bundle directories/zips, an arbitrary single top-level wrapper zip, and unsafe zip rejection, proving returned evidence can be diagnosed as pending, candidate-ready, or owner-repair-needed before auto acceptance runs. Operators inspect `readyForAcceptanceCandidate`, `semanticPreflightStatus`, and `semanticFailCount`; this preflight does not copy returned evidence, accept evidence, or promote fixtures. `OwnerResponseBundleZipPath` inputs are zip-safety checked so unsafe, duplicate, absolute, or traversal zip entries are rejected before extraction, and arbitrary single top-level wrapper resolution is accepted only for safe zips that contain the required bundle files. The expected manifest totals are `caseCount=10`, `completeCandidateCaseCount=4`, `rejectedCaseCount=6`, `checkCount=12`, `ownerResponseBundleZipCaseCount=5`, `ownerResponseBundleZipSafeCaseCount=4`, `ownerResponseBundleZipUnsafeCaseCount=1`, and `ownerResponseBundleZipArbitraryWrapperReady=true`. `production-external-evidence-auto-acceptance-probe-manifest.json` then proves auto acceptance reruns that semantic gate before delegating to stable acceptance for evidence roots and owner response bundle directories/zips, and that complete semantic-bad bundles are rejected before acceptance.

`production-handoff-status-manifest.json` is generated before the release risk policy. It validates `production-handoff-status.md`, an owner-level collection tracker that records accepted and pending owner packets, remaining blocker counts, required evidence files, and next acceptance commands. In the default package-release path it should report three pending owner packets, eleven remaining blockers, and `realHostProjectEvidenceAccepted=false`.

`production-handoff-dispatch-manifest.json` is generated before the release risk policy. It validates `production-handoff-dispatch.md`, `production-handoff-dispatch\production-handoff-dispatch-queue.json`, and one owner email draft per packet. The default package-release path should report three pending dispatches, nine pending external evidence files, `realOwnerEmailAddressesConfigured=false`, and `automaticEmailSendReady=false`.

`production-handoff-contact-readiness-manifest.json` is generated before the release risk policy. It validates `production-handoff-contact-roster.json` and `production-handoff-contact-readiness.md`, mapping one contact row per owner packet. The default package-release path should report three missing owner contacts, `contactRosterComplete=false`, and `automaticEmailSendReady=false`.

`production-handoff-contact-readiness-contract-probe-manifest.json` is generated before the release risk policy. It supplies a complete fixture contact roster with reserved `example.invalid` addresses, validates that contact readiness accepts configured contacts, and keeps `automaticEmailSendReady=false`, `realHostProjectEvidenceAccepted=false`, and the default missing-contact boundary intact.

`production-handoff-send-readiness-manifest.json` is generated before the release risk policy. It validates `production-handoff-send\production-handoff-send-queue.json`, `production-handoff-send\send-owner-packets.ps1`, and `production-handoff-send\README.md`, proving the owner-packet send helper requires configured contacts, local agently-cli authorization, and explicit two-stage confirmation tokens while the default package-release path remains blocked on missing owner emails.

`production-handoff-send-local-workflow-probe-manifest.json` is generated before the release risk policy. It validates the local owner-packet two-stage workflow with a fake `agently-cli`: unauthenticated runs stop before `message +send`, accepted contacts request one confirmation token per owner, token-confirmed sends write one fake receipt per owner, and the manifest keeps `realOwnerPacketEmailSent=false`, `emailSent=false`, `ownerPacketReceiptRealDeliveryVerifiedCount=0`, and `ownerPacketReceiptReleasePipelineGeneratedCount=0`.

`production-handoff-owner-packet-dispatch-receipt-intake-probe-manifest.json` is generated before the release risk policy. It proves the owner-packet dispatch receipt intake rejects fake local workflow receipts, accepts contract-shaped receipts only as fixture proof, accepts queued-only receipts as dispatch evidence without message IDs, and keeps `realOwnerPacketEmailSent=false`, `emailSent=false`, and `releasePipelineSendsEmail=false`.

`production-handoff-owner-packet-real-receipt-guard-probe-manifest.json` is generated before the release risk policy. It proves valid owner-packet receipts still require explicit operator real-send confirmation before real send state can be accepted, and that contract fixture mode cannot claim `emailSent=true` or real delivery even when the confirmation switch is present.

`production-handoff-mail-auth-readiness-manifest.json` is generated before the release risk policy. It validates `production-handoff-mail-auth\check-agently-mail-auth.ps1`, `production-handoff-mail-auth\start-agently-mail-login.ps1`, and the mail-auth runbook, proving local authorization can be checked by an operator while CI still records `mailAuthReadinessStatus=BLOCKED_NOT_CHECKED_BY_RELEASE_PIPELINE`.

`production-handoff-owner-unblock-pack-manifest.json` is generated before the release risk policy. It validates `production-handoff-owner-unblock-pack\owner-unblock-summary.json`, `owner-action-matrix.md`, `operator-next-steps.md`, `progress-email-draft.md`, and the top-level report, proving the remaining owner contacts, missing returned evidence, blocked sends, and mail authorization boundary are represented as one handoff artifact without reducing the real blocker counts.

`production-handoff-owner-unblock-pack-contract-probe-manifest.json` is generated before the release risk policy. It validates both the default unblock pack and a copied fixture bundle with configured `example.invalid` contacts plus complete fixture returned evidence, proving that ready owner sends and complete returned files still require local mail authorization and real host-project acceptance before completion.

`production-external-evidence-acceptance-contract-probe-manifest.json` is generated before the release risk policy. It runs `Invoke-AITestPilotProductionExternalEvidenceAcceptance.ps1` against accepted fixture evidence for driver, Lua, and live smoke, proving the long-lived repo command can accept all three returned evidence directories in one pass while recording `realHostProjectEvidenceAccepted=false`. It also requires `production-external-evidence-acceptance-contract.md`, a validated Markdown summary for host-project owners.

`production-external-evidence-acceptance-failure-probe-manifest.json` is generated before the release risk policy. It runs the same stable acceptance command with `-RequireAllEvidence` against fully missing evidence and against a driver-only partial fixture. The probe passes only when both scenarios fail, the driver-only case still proves driver evidence can be accepted independently, neither scenario claims real host-project evidence, and both rejection cases write validated Markdown reports.

`production-hard-mode-failure-probe-manifest.json` is generated before the release risk policy. It records an isolated combined hard-mode run where production driver binding, production Lua patch evidence, and live model smoke are all required and the current package evidence is expected to block.

`production-hard-mode-success-contract-probe-manifest.json` is generated before the release risk policy. It records an isolated combined hard-mode run where complete accepted fixture driver, Lua, and live-smoke evidence is copied into a probe bundle so risk policy, evidence index, and release gate can all pass with hard switches enabled. The manifest records `sourceCanonicalEvidencePreserved=true`, `releasePipelineUsesFixture=false`, and `realHostProjectEvidenceAccepted=false`.

`release-risk-policy-manifest.json` is the machine-readable release-blocker decision for downstream CI, portal, or audit tooling. It is generated after the production handoff and hard-mode probes and before the release evidence index, recording whether package release is allowed under the active production driver, production Lua, and live-model enforcement switches.

`release-evidence-index.json` is the stable machine-readable summary for downstream CI, portal, or audit tooling. It indexes the primary release-gate source manifests, including the release risk policy, records source status coverage, listed-file coverage, optional live-smoke skip handling, and auxiliary manifest inventory. The release gate validates `release-evidence-index-manifest.json` before allowing release; after the pipeline manifest is written, the pipeline refreshes the final artifact copy of the index so uploaded evidence also records `pipelineManifestIncluded=true`. If the wrapper fails before that final refresh, `artifacts\ai-testpilot-release\latest` keeps the failing `pipeline-manifest.json`, removes final release gate/risk/index status files from the copied artifact, and writes `release-artifact-invalidated-manifest.json`.

## GitHub Actions

`.github/workflows/ai-testpilot-release.yml` is the provider-specific CI entry point for GitHub Actions. It targets a self-hosted Windows Unity runner because the release pipeline runs Unity 2021.3 batchmode validation. The workflow runs on `push`, `pull_request`, and `workflow_dispatch`.

Manual dispatch exposes release-control inputs for `unity_path`, `game_replay_driver_type`, production-bound replay driver enforcement, production Lua patch enforcement, production Lua evidence directory, required live model smoke, missing API-key allowance for local gateways, and optional headless Cursor Agent output. The workflow passes those inputs to `Invoke-AITestPilotReleasePipeline.ps1`, enforces that `pipeline-manifest.json` reports `status=PASS` and `ciExitCode=0`, then uploads `artifacts\ai-testpilot-release\latest` as `ai-testpilot-release-evidence`. Failed uploads remain explicitly invalidated by `release-artifact-invalidated-manifest.json` instead of carrying stale PASS release summaries.

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
By default the wrapper does not pass `--model`, so the authenticated Cursor Agent account can use its current default model. On Windows the wrapper resolves `cursor-agent.cmd` before the extensionless command to avoid PowerShell script-shim execution policy failures; `-CursorAgentCommand` can still point at a specific executable. The wrapper passes `--sandbox disabled` by default so the headless agent can write its required output files under `Temp\release-evidence\cursor-agent-external-output`; the wrapper then validates those files before any main worktree apply occurs. Each attempt has a default 300-second `-CursorAgentTimeoutSeconds`; timeout exit code `124` is logged and can be retried within `-CursorAgentMaxAttempts`. If `-CursorAgentModel` is provided and the CLI rejects that model, the wrapper retries once without `--model` and records `cursorAgentRetriedWithoutModel=true` in the manifest. Transient network/socket failures, exit-0 runs that miss the required three-file output contract, and patches that do not apply with the required task context are retried within `-CursorAgentMaxAttempts`, and the manifest records attempt and retry counts. The committed repo-side contract for this optional agent node is `.agents/ai-testpilot-repair-agent.json`.

The release pipeline always runs `repair_agent_cursor_agent_external_output_binding_probe` after `release_risk_policy` and before `release_evidence_index`. It writes `repair-agent-cursor-agent-external-output-binding-probe-manifest.json` and prevents old optional `repair-agent-cursor-agent-*` evidence from being treated as the current Cursor Agent output unless the accepted external-output manifest is non-fixture, task-bound, and hash-bound to the producer manifest.

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

The kit contains a customized driver template, an authoring checklist, a host helper script, and `Export-ProductionDriverEvidenceBundle.ps1`, which packages the four required driver evidence files only after production-bound readiness passes with zero blockers. The release pipeline also runs `production_driver_binding_kit_probe`; the gate only accepts that proof when the kit is still marked as generated handoff material, `productionEvidenceAccepted=false`, and the export helper rejects the current sample/unbound evidence.

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

The pipeline also runs `Invoke-AITestPilotLiveModelEndpointSmokeEvidenceContractProbe.ps1`. It creates a PASS-shaped live-smoke fixture under system temp, accepts it through the same smoke evidence intake path inside an isolated contract-mode bundle, and records that canonical manifest/trace promotion works while `releasePipelineUsesFixture=false`, `realProductionLiveEndpointAccessProven=false`, and `realLiveSmokeExecuted=false` stay explicit. The promoted fixture files prove the contract path only; they do not prove production live endpoint/provider access.

The pipeline always writes `live-model-endpoint-smoke-manifest.json`. Without live endpoint environment variables it records `status=SKIPPED` and release remains allowed.
When a configured live smoke fails, the manifest records `failureCategory`, `failureMessage`, `failureRemediation`, and `failurePolicy`. Retryable failures are retried by the wrapper before the release gate runs, and the final manifest includes `attemptCount` plus `attempts[]`.
When production CI requires live smoke, the passing manifest must carry real provider provenance fields from the live path, including `fixtureOnly=false`, `contractFixtureMode=false`, `realProviderAccessProven=true`, `liveSmokeExecuted=true`, `productionLiveEndpointAccessProven=true`, `evidenceProvenance=direct_live_http_endpoint_pass`, `endpointMode=live_http_endpoint`, and `clientType=ModelEndpointDecisionClient`.
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
