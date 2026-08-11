## Summary

### What changed
-

### Why this change
-

## Local validation

Please run and report before merge:

- [ ] `.\tools\Run-DevGate.ps1`
- [ ] `.\tools\Invoke-AITestPilotCiGate.ps1` (optional in CI)

If you used skips, list them:

- [ ] `-SkipQuickStart` with reason:
- [ ] `-SkipRepairLoop` with reason:
- [ ] `-QuickStartSkipUnityImport` with reason:
- [ ] `-RepairLoopSkipPatchApplyRetest` with reason:
- [ ] `-RepairLoopSkipRepairRetest` with reason:

## Evidence (required)

- Quick start manifest: `Temp\quick-start\quick-start-manifest.json`
- Repair loop manifest: `Temp\repair-loop\repair-loop-manifest.json`
- Developer gate manifest: `Temp\developer-gate-manifest.json`
- CI gate summary: `Temp\ci-gate-summary.json` (if generated)
- Local run summary (optional): `Temp\dev-gate-summary.json`

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
  "summary_manifest": "Temp\\developer-gate-manifest.json"
}
```

## Checklist

- [ ] Relevant docs updated
- [ ] New behavior covered by scripts/evidence or tests where applicable
- [ ] No unexpected `FAIL` steps in passed manifests
