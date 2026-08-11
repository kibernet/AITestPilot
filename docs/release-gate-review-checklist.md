# Release Gate Review Checklist

Release Gate Review Checklist for AITestPilot versions and milestone publishing.

## 1) Gate execution requirements

- [ ] `Run-DevGate.ps1`
- [ ] `Validate-AITestPilot.ps1`
- [ ] `Validate-AITestPilot.ps1 -RunCiGatePathRegression`
- [ ] `Invoke-AITestPilotReleasePipeline.ps1` (if this is a release milestone)
- [ ] `Validate-AITestPilot.ps1 -RunCiGatePathRegressionStrict` (when path-related logic changed)
- [ ] `Validate-AITestPilot.ps1 -RunReleaseDocsFreshnessRegression` (for release milestone / docs-freshness probe changes)
- [ ] `Invoke-AITestPilotReleasePreflight.ps1` (release milestone full preflight)
- [ ] `Invoke-AITestPilotLocalPreflight.ps1` (for final local baseline)
- [ ] `Invoke-AITestPilotCiGate.ps1 -SummaryPath Temp\ci-gate-summary.json` (if CI gate path was required)
- [ ] `Test-AITestPilotCiGatePathResolution.ps1 -StrictOutputPathAlias`

### 1.1 Recommended release milestone command sequence (mainline-ready)

```powershell
# 1) local baseline (kept in release style by default)
.\tools\Invoke-AITestPilotReleasePreflight.ps1

# 2) local-only smoke when full release pipeline is intentionally deferred
.\tools\Invoke-AITestPilotReleasePreflight.ps1 -SkipReleasePipeline

# 3) strict docs-freshness-focused preflight (skip strict path checks to save time while keeping docs regression)
.\tools\Invoke-AITestPilotReleasePreflight.ps1 -SkipReleasePipeline -SkipStrictPathRegression

# 4) full release preflight with explicit pipeline options
.\tools\Invoke-AITestPilotReleasePreflight.ps1 -EvidenceBundleDir Temp\release-evidence\latest
```

```text
Expected key evidence:
- Temp\release-preflight-summary.json
- Temp\release-preflight-manifest.json
- Temp\release-evidence\latest\release-docs-freshness-manifest.json
- Temp\release-evidence\latest\release-docs-freshness-drift-manifest.json
- Temp\release-evidence\latest\release-docs-freshness-drift.md
- artifacts\ai-testpilot-release\latest\ (if full release pipeline executed)
```

## 2) Evidence required for release review

- [ ] `Temp\developer-gate-manifest.json`
- [ ] `Temp\quick-start\quick-start-manifest.json`
- [ ] `Temp\repair-loop\repair-loop-manifest.json`
- [ ] `Temp\dev-gate-summary.json`
- [ ] `Temp\ci-gate-summary.json`
- [ ] `Temp\release-evidence\latest\`
- [ ] `artifacts\ai-testpilot-release\latest\`

## 3) Risk control check

- [ ] PR has clear, explicit summary and approval path
- [ ] Environment assumptions and manual validation requirements are recorded (for skipped steps)
- [ ] Host-project integration points are listed (replay driver, production Lua, account workflow)
- [ ] Failure handling is actionable and has owner names
- [ ] Alias conflicts and path regression risk are understood with mitigation

## 4) Recommended release note block

```text
## Release Gate
- [ ] Run-DevGate passed
- [ ] Validate-AITestPilot passed
- [ ] Run-CiGatePathRegression passed
- [ ] Run-CiGatePathRegressionStrict passed (if required)
- [ ] Release pipeline passed (if run)

## Evidence index
- Developer gate: Temp\developer-gate-manifest.json
- Dev gate summary: Temp\dev-gate-summary.json
- CI gate summary: Temp\ci-gate-summary.json
- Release evidence: Temp\release-evidence\latest\
- Release artifacts: artifacts\ai-testpilot-release\latest\

## Risks and mitigations
- xxx
```

## 5) Post-review items

- [ ] Confirm pre-release and rollout checklists were completed:
  - `docs/local-workflow-cheat-sheet.md`
  - `docs/rollout-and-release-checklist.md`
- [ ] Confirm PR template and conventions were followed:
  - `CONTRIBUTING.md`
- [ ] Confirm CI/branching policy and release pipeline policy in:
  - `docs/ci-release-pipeline.md`
