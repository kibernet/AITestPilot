## Summary

### What changed
-

### Why this change
-

## Local validation

Please run and report before merge:

### Required gate checks

- [ ] `.\tools\Run-DevGate.ps1`
- [ ] `.\tools\Validate-AITestPilot.ps1`
- [ ] `.\tools\Validate-AITestPilot.ps1 -RunCiGatePathRegression`
- [ ] `.\tools\Invoke-AITestPilotReleaseReadinessBundle.ps1 -ReportOutputPath Temp\release-readiness-report.md -SummaryJsonPath Temp\release-readiness-summary.json -SnippetOutputPath Temp\release-readiness-pr-snippet.md`

### Optional checks by scope

- [ ] `.\tools\Validate-AITestPilot.ps1 -RunCiGatePathRegressionStrict` (if touched CI-path logic)
- [ ] `.\tools\Invoke-AITestPilotCiGate.ps1` (if running CI-style aggregate validation)
- [ ] `.\tools\Invoke-AITestPilotLocalPreflight.ps1` (if local baseline is preferred)
- [ ] `.\tools\Test-AITestPilotCiGatePathResolution.ps1 -StrictOutputPathAlias` (if path alias regression is targeted)
- [ ] `.\tools\Invoke-AITestPilotReleaseReadinessReport.ps1 -OutputPath Temp\release-readiness-report.md -IncludeRecommendedCommands -FailOnWarning` (strict mode, if this PR is milestone/release-facing)
- [ ] `.\tools\Set-AITestPilotReleaseReadinessMilestoneNotes.ps1 -FailOnWarning -DryRun` (generate handoff block from readiness output)

If you used skips, list them:

- [ ] `-SkipQuickStart` with reason:
- [ ] `-SkipRepairLoop` with reason:
- [ ] `-QuickStartSkipUnityImport` with reason:
- [ ] `-RepairLoopSkipPatchApplyRetest` with reason:
- [ ] `-RepairLoopSkipRepairRetest` with reason:

## Evidence (required)

- [ ] Release gate review checklist completed: `.\docs\release-gate-review-checklist.md` (if milestone/release related)

- Quick start manifest: `Temp\quick-start\quick-start-manifest.json`
- Repair loop manifest: `Temp\repair-loop\repair-loop-manifest.json`
- Developer gate manifest: `Temp\developer-gate-manifest.json` (or custom `Run-DevGate.ps1 -ManifestPath` target)
- CI gate summary: `Temp\ci-gate-summary.json` (if generated)
- Local run summary (optional): `Temp\dev-gate-summary.json`
- Release evidence: `Temp\release-evidence\latest\...` (if release candidate scope)
- Release artifacts: `artifacts\ai-testpilot-release\latest\...` (if release pipeline run)
- Release readiness report: `Temp\release-readiness-report.md`
- Release readiness summary (optional): `Temp\release-readiness-summary.json`

## Copy/Paste release gate block (for milestone PR / pre-release PR)

```text
## Release Gate
- [ ] Run-DevGate passed
- [ ] Validate-AITestPilot passed
- [ ] Run-CiGatePathRegression passed
- [ ] Run-CiGatePathRegressionStrict passed (if required)
- [ ] Release pipeline passed (if run)

## Evidence index
- Developer gate manifest: Temp\developer-gate-manifest.json
- Dev gate summary: Temp\dev-gate-summary.json
- CI gate summary: Temp\ci-gate-summary.json
- Release evidence: Temp\release-evidence\latest\
- Release artifacts: artifacts\ai-testpilot-release\latest\
- Release readiness report: Temp\release-readiness-report.md
- Release readiness summary: Temp\release-readiness-summary.json
```

Status:

- [ ] PASS
- [ ] PARTIAL_FAIL

Notes:

-

Paste the `Run-DevGate` summary output here (recommended):

```
# paste this block directly from console output
{
  "developer_gate_status": "PASS",
  "quick_start_status": "PASS",
  "repair_loop_status": "PASS",
  "quick_start_skipped": false,
  "repair_loop_skipped": false,
  "skip_reasons": [],
  "failed_steps": [],
  "summary_manifest": "C:\\path\\to\\repo\\Temp\\developer-gate-manifest.json"
}
```

## Checklist

- [ ] Relevant docs updated
- [ ] New behavior covered by scripts/evidence or tests where applicable
- [ ] No unexpected `FAIL` steps in passed manifests
- [ ] Required evidence paths are included in PR description

Paste the readiness report/snippet here if generated:

```
# paste contents of Temp\\release-readiness-report.md
```

```
# paste contents of Temp\\release-readiness-pr-snippet.md
```

After opening the PR, if you have GitHub CLI auth configured, you can sync this block directly into the PR body:

```powershell
.\tools\Set-AITestPilotReleaseReadinessMilestoneNotes.ps1 -PullRequestNumber <YOUR_PR_NUMBER> -FailOnWarning
```
