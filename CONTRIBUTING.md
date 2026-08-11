# Contributing to AITestPilot

Thanks for contributing! This project keeps engineering quality with a simple, reproducible local workflow.

## Branching and pushes

- All requested changes in this repo should be pushed only to `main`, unless otherwise specified.
- Keep each contribution focused and scoped.

## Minimum local checks before PR/push

Before opening a pull request, run the local developer gate:

```powershell
.\tools\Run-DevGate.ps1
```

To archive the same JSON summary locally (optional):

```powershell
.\tools\Run-DevGate.ps1 -SummaryPath Temp\dev-gate-summary.json
```

To write the developer gate manifest to a custom location:

```powershell
.\tools\Run-DevGate.ps1 -ManifestPath Temp\custom-developer-gate-manifest.json
```

`-ManifestPath` and `-SummaryPath` support absolute paths; relative paths are resolved against repository root.

Relative values for `-QuickStartOutputDir`, `-RepairLoopOutputDir`, and `-RepairLoopEvidenceBundleDir` are also resolved against the repository root.

For automation/CI style checks, use:

```powershell
.\tools\Invoke-AITestPilotCiGate.ps1
```

This runs:

- `Invoke-AITestPilotQuickStart.ps1` (+ `Invoke-AITestPilotQuickStartChecklist.ps1`)
- `Invoke-AITestPilotRepairLoop.ps1`
- Writes `Temp\ci-gate-summary.json` (or `-SummaryPath` / `-OutputPath` destination), reads `Temp\developer-gate-manifest.json` by default (or `-ManifestPath`).
- Fails by default when status is not PASS.

Optionally include path-resolution regression checks in local validation:

```powershell
.\tools\Validate-AITestPilot.ps1 -RunCiGatePathRegression
```

For stricter alias checks (including conflict validation between `OutputPath` and `SummaryPath`):

```powershell
.\tools\Validate-AITestPilot.ps1 -RunCiGatePathRegressionStrict
```

This strict mode exercises a real parameter-binding conflict and verifies it is rejected by PowerShell.

Tip: preview parameter docs via:

```powershell
Get-Help .\tools\Validate-AITestPilot.ps1 -Full
```

For stricter path-alias regression checks:

```powershell
.\tools\Test-AITestPilotCiGatePathResolution.ps1 -StrictOutputPathAlias
```

```powershell
Get-Help .\tools\Test-AITestPilotCiGatePathResolution.ps1 -Full
```

## What to include in PR description

Please include:

- Gate status (`PASS` / `PARTIAL_FAIL`)
- Commands run (for example: `Run-DevGate.ps1`, or `Skip...` options used)
- Paths for produced manifests when relevant:
  - `Temp\quick-start\quick-start-manifest.json`
  - `Temp\repair-loop\repair-loop-manifest.json`
  - `Temp\developer-gate-manifest.json` (or your custom `-ManifestPath`)
- Any skipped steps and reasons
- Known risks or follow-up work

## Documentation checklist

- Update related docs when you change behavior.
- Add/update tests where possible.
- Ensure new scripts or script arguments are documented in docs.
