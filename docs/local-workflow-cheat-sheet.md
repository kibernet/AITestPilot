# Local AITestPilot Workflow Cheat Sheet

```powershell
Get-Help .\tools\Invoke-AITestPilotLocalPreflight.ps1 -Full
```

Use this checklist as a quick operational map.

## 0) Minimum command sequence (recommended baseline)

Run these in order for most changes:

```powershell
.\tools\Invoke-AITestPilotLocalPreflight.ps1
```

For release milestone verification, use the release preflight entrypoint:

```powershell
.\tools\Invoke-AITestPilotReleasePreflight.ps1
```

If you want the same checks without running the full release pipeline, add `-SkipReleasePipeline`:

```powershell
.\tools\Invoke-AITestPilotReleasePreflight.ps1 -SkipReleasePipeline -SkipStrictPathRegression
```

If the change touches only docs/markdown, run with `-SkipStrictPathRegression` as a fast-path exception.

Equivalent manual sequence:

```powershell
.\tools\Run-DevGate.ps1
.\tools\Validate-AITestPilot.ps1
.\tools\Validate-AITestPilot.ps1 -RunCiGatePathRegression
.\tools\Validate-AITestPilot.ps1 -RunCiGatePathRegressionStrict
.\tools\Validate-AITestPilot.ps1 -RunReplayProfileSchemaCheck
```

## 1) New task / onboarding

- Clone and run baseline validation

```powershell
git clone https://github.com/kibernet/AITestPilot.git
cd AITestPilot
.\tools\Validate-AITestPilot.ps1
```

- Quick start smoke path

```powershell
.\tools\Invoke-AITestPilotQuickStart.ps1
.\tools\Invoke-AITestPilotQuickStartChecklist.ps1
```

For release preflight with strict validation and docs-freshness regression enabled:

```powershell
.\tools\Invoke-AITestPilotReleasePreflight.ps1 -SummaryPath Temp\release-preflight-summary.json
```

For an auto-generated milestone readiness bundle:

```powershell
.\tools\Invoke-AITestPilotReleaseReadinessBundle.ps1 -ReportOutputPath Temp\release-readiness-report.md -SummaryJsonPath Temp\release-readiness-summary.json -SnippetOutputPath Temp\release-readiness-pr-snippet.md
```

For a single command that prints the same handoff block and can also push it into PR/issue/milestone text:

```powershell
.\tools\Set-AITestPilotReleaseReadinessMilestoneNotes.ps1 -DryRun
.\tools\Set-AITestPilotReleaseReadinessMilestoneNotes.ps1 -PullRequestNumber 123
.\tools\Set-AITestPilotReleaseReadinessMilestoneNotes.ps1 -IssueNumber 456
.\tools\Set-AITestPilotReleaseReadinessMilestoneNotes.ps1 -MilestoneNumber 7
```

If your PR checklist is file-driven, export handoff markdown first:

```powershell
.\tools\Export-AITestPilotReleaseReadinessHandoff.ps1 -OutputPath Temp\release-readiness-handoff-block.md
```

Use strict gate mode in automation:

```powershell
.\tools\Invoke-AITestPilotReleaseReadinessReport.ps1 -OutputPath Temp\release-readiness-report.md -IncludeRecommendedCommands -FailOnWarning
```

Legacy one-step machine-readable pair (compatible with older flow):

```powershell
.\tools\Invoke-AITestPilotReleaseReadinessReport.ps1 -OutputPath Temp\release-readiness-report.md -SummaryOutputPath Temp\release-readiness-summary.json
```

PR-friendly summary snippet:

```powershell
.\tools\Invoke-AITestPilotReleaseReadinessSummary.ps1 -SummaryJson Temp\release-readiness-summary.json -OutputPath Temp\release-readiness-pr-snippet.md
```

## 2) Daily local development

- PR/local quality gate

```powershell
.\tools\Run-DevGate.ps1
```

- Inspect gate summary for PR notes

```powershell
.\tools\Run-DevGate.ps1 -SummaryPath Temp\dev-gate-summary.json
```

- Run with replay profile schema check:

```powershell
.\tools\Run-DevGate.ps1 -RunReplayProfileSchemaCheck -ReplayProfileJsonPath Temp\release-evidence\latest\sample-business-replay-profile.json
```

- CI-style path regression (recommended after touching CI gate path logic)

```powershell
.\tools\Validate-AITestPilot.ps1 -RunCiGatePathRegression
```

- Release-docs-freshness regression stress check (default off, recommended for milestone/release-prep)

```powershell
.\tools\Validate-AITestPilot.ps1 -RunReleaseDocsFreshnessRegression
```

- Strict CI path regression (alias conflict guard)

```powershell
.\tools\Validate-AITestPilot.ps1 -RunCiGatePathRegressionStrict
```

- Replay profile schema check for a provided JSON profile:

```powershell
.\tools\Validate-AITestPilot.ps1 -RunReplayProfileSchemaCheck -ReplayProfileJsonPath Temp\release-evidence\latest\sample-business-replay-profile.json
```

- Path-regression script only (stand-alone)

```powershell
.\tools\Test-AITestPilotCiGatePathResolution.ps1 -StrictOutputPathAlias
```

- Query command help quickly

```powershell
Get-Help .\tools\Validate-AITestPilot.ps1 -Full
Get-Help .\tools\Test-AITestPilotCiGatePathResolution.ps1 -Full
```

## 3) Pre-merge / release confidence checks

- CI-style gate (non-strict by default)

```powershell
.\tools\Invoke-AITestPilotCiGate.ps1 -SummaryPath Temp\ci-gate-summary.json
```

- Full local validation + strict regression

```powershell
.\tools\Validate-AITestPilot.ps1 -RunCiGatePathRegressionStrict
```

- Package import validation

```powershell
.\tools\Validate-UnityPackageImport.ps1
```

## 4) Help / reference

- Local repo documentation

```text
.\docs\local-workflow-cheat-sheet.md
.\docs\quick-start-demo.md
.\docs\model-endpoint.md
```

## 5) PR / release preflight checklist

Use this minimal checklist before opening or updating a pull request:

- Run local validation and CI-path regression checks:

```powershell
.\tools\Validate-AITestPilot.ps1 -RunCiGatePathRegression
.\tools\Validate-AITestPilot.ps1 -RunCiGatePathRegressionStrict
.\tools\Validate-AITestPilot.ps1 -RunReleaseDocsFreshnessRegression
.\tools\Validate-AITestPilot.ps1 -RunReplayProfileSchemaCheck
```

- Run CI-style gate with an archived summary:

```powershell
.\tools\Run-DevGate.ps1 -SummaryPath Temp\dev-gate-summary.json
```

- If CI gates are touched in your change set, also run:

```powershell
.\tools\Run-DevGate.ps1
.\tools\Validate-AITestPilot.ps1
```

- For release / milestone PRs, also run:

```powershell
.\tools\Invoke-AITestPilotReleasePipeline.ps1
.\tools\Test-AITestPilotCiGatePathResolution.ps1 -StrictOutputPathAlias
```

- PR artifacts to include in description (and required by template):

```text
Temp\quick-start\quick-start-manifest.json
Temp\repair-loop\repair-loop-manifest.json
Temp\developer-gate-manifest.json
Temp\dev-gate-summary.json
Temp\ci-gate-summary.json
Temp\release-evidence\latest\...
artifacts\ai-testpilot-release\latest\...
```

Copy/paste this into PR description:

```text
## Validation run
- [ ] .\tools\Run-DevGate.ps1
- [ ] .\tools\Validate-AITestPilot.ps1
- [ ] .\tools\Validate-AITestPilot.ps1 -RunCiGatePathRegression
- [ ] .\tools\Validate-AITestPilot.ps1 -RunCiGatePathRegressionStrict *(if CI gate path logic changed)*
- [ ] .\tools\Validate-AITestPilot.ps1 -RunReleaseDocsFreshnessRegression *(for release scope or before docs freshness probe changes)*
- [ ] .\tools\Run-DevGate.ps1 -SummaryPath Temp\dev-gate-summary.json
- [ ] .\tools\Run-DevGate.ps1 -RunReplayProfileSchemaCheck *(if replay profile JSON is modified)*
- [ ] .\tools\Invoke-AITestPilotReleasePipeline.ps1 *(release scope)*

Artifacts produced:
- [ ] Temp\quick-start\quick-start-manifest.json (if available)
- [ ] Temp\repair-loop\repair-loop-manifest.json (if available)
- [ ] Temp\developer-gate-manifest.json
- [ ] Temp\dev-gate-summary.json
- [ ] Temp\ci-gate-summary.json (if CI gate run)
- [ ] Temp\release-evidence\latest\...
- [ ] artifacts\ai-testpilot-release\latest\...
```

PR template location:

```text
.github/PULL_REQUEST_TEMPLATE/default.md
```
