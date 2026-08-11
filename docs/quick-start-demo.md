# AI TestPilot Quick Start Demo

This page is the fastest entry point for trying AI TestPilot locally in your machine.

## What this demo proves

Running the quick start does **not** require live-game credentials or model keys. It proves:

1. Core .NET project compiles and smoke tests pass.
2. Unity package imports and sample scene validation can run end-to-end (optional).
3. Offline model endpoint contract tracing works and writes decision evidence (optional).

## One-command path

From repo root:

```powershell
.\tools\Invoke-AITestPilotQuickStart.ps1
```

Run checklist:

```powershell
.\tools\Invoke-AITestPilotQuickStartChecklist.ps1
```

For local PR/push developer gate (recommended):

```powershell
.\tools\Invoke-AITestPilotDeveloperGate.ps1
```

Or use shorter command:

```powershell
.\tools\Run-DevGate.ps1
```

If you need a saved machine-readable summary:

```powershell
.\tools\Run-DevGate.ps1 -SummaryPath Temp\dev-gate-summary.json
```

If you need the developer gate manifest in a custom path:

```powershell
.\tools\Run-DevGate.ps1 -ManifestPath Temp\custom-developer-gate-manifest.json
```

CI-friendly single command (writes summary JSON to `Temp\ci-gate-summary.json`):

```powershell
.\tools\Invoke-AITestPilotCiGate.ps1
```

If you need a custom output path:

```powershell
.\tools\Invoke-AITestPilotCiGate.ps1 -SummaryPath Temp\ci-gate-summary.json
```

If you need a custom manifest location:

```powershell
.\tools\Invoke-AITestPilotCiGate.ps1 -ManifestPath Temp\custom-developer-gate-manifest.json
```

Default output:
- `Temp\quick-start\quick-start-manifest.json`
- `Temp\quick-start\model-endpoint-trace-manifest.json` (if model endpoint trace step is run)

For PR submission requirements, see [CONTRIBUTING.md](../CONTRIBUTING.md).

PR reviewers should only approve when one of the following is true:

- `Temp\developer-gate-manifest.json` exists and is `PASS`, or
- `PARTIAL_FAIL` is clearly justified and all skipped steps are explicitly listed in PR description

Expected output:

- `Temp\quick-start\quick-start-manifest.json`
- Console summary with `Quick start status: PASS` or `PARTIAL_FAIL`

When using `Run-DevGate.ps1`, copy the printed JSON summary (for example `developer_gate_status`, `quick_start_status`, `repair_loop_status`, and skip reasons) directly into the PR template.

Expected `Run-DevGate` copy/paste block:

```json
{
  "developer_gate_status": "PASS",
  "quick_start_status": "PASS",
  "repair_loop_status": "PASS",
  "quick_start_skipped": false,
  "repair_loop_skipped": false,
  "skip_reasons": [],
  "failed_steps": []
}
```

## Step-by-step

1. Open a new terminal at the repo root.
2. Install dependencies:
   - .NET 8 SDK
   - PowerShell 5.1+ or 7+
   - Unity 2021.3 LTS (for package import path)
3. Run baseline validation:

```powershell
.\tools\Validate-AITestPilot.ps1
```

4. Run package import and sample scene check:

```powershell
.\tools\Validate-UnityPackageImport.ps1
```

5. Run offline model-endpoint trace demo:

```powershell
.\tools\Invoke-AITestPilotModelEndpointTraceProbe.ps1
```

6. Capture quick-start evidence only in `Temp\quick-start\quick-start-manifest.json`.

## Day-1 Verification Checklist

Use this checklist after `Invoke-AITestPilotQuickStart.ps1` to verify onboarding readiness:

- [ ] Repository build and smoke tests pass
- [ ] Model endpoint offline trace probe writes evidence
- [ ] Quick-start manifest can be parsed by `Invoke-AITestPilotQuickStartChecklist.ps1`
- [ ] No unexpected `FAIL` step in `Temp\quick-start\quick-start-manifest.json`

If Unity is installed, add:

- [ ] `Validate-UnityPackageImport.ps1` is completed with PASS status
- [ ] Sample scene evidence exists under `Temp/release-evidence/latest/scene-validation.json`

Failure triage:

- `FAIL` only in `Validate-UnityPackageImport` with `-SkipUnityImport` selected is acceptable for Day-1 local checks.
- Any non-skipped `FAIL` should be fixed before opening a PR.

## Optional flags

- `-SkipUnityImport`  
  Skip Unity batch-mode import when Unity is unavailable.

- `-SkipModelEndpointTrace`  
  Skip offline model-endpoint trace demo and only keep core validation.

## Repair loop (post-change validation)

After you make changes, run:

```powershell
.\tools\Invoke-AITestPilotRepairLoop.ps1
```

This command:

- Keeps the same evidence bundle layout
- Re-runs core validation (unless `-SkipUnityCoreValidation`)
- Optionally runs `Invoke-AITestPilotRepairAgentPatchApplyRetest.ps1` when patch output evidence exists
- Optionally runs `Invoke-AITestPilotRepairRetest.ps1` when repair task evidence exists
- Writes `Temp\repair-loop\repair-loop-manifest.json`

For local-only code changes without a repair task or patch manifest, use:

```powershell
.\tools\Invoke-AITestPilotRepairLoop.ps1 -SkipPatchApplyRetest -SkipRepairRetest
```

## Next steps after PASS

- Open Unity sample scene evidence in `Temp/release-evidence/latest/scene-validation.json`
- Integrate your real replay driver
- Generate production driver and Lua evidence kits
- Wire a real model endpoint and move to a live smoke in controlled mode
