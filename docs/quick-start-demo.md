# AI TestPilot Quick Start Demo

This page is the fastest entry point for trying AI TestPilot locally in your machine.

## Bilingual command snippets (external-friendly) | 外部团队友好双语命令

Use the same commands for both English and Chinese teams—only the description text changes to remove ambiguity when sharing outside the project.

外部协作更稳妥方式：命令保持一致，只需按团队语言选择对应解释。下面命令可直接复制到工单、邮件或外部交付文档。

### English

```powershell
# 1) Run the full quick-start workflow
.\tools\Invoke-AITestPilotQuickStart.ps1

# 2) Validate the quick-start manifest
.\tools\Invoke-AITestPilotQuickStartChecklist.ps1

# 3) Run standard PR/push readiness (recommended)
.\tools\Run-DevGate.ps1

# 4) Run CI-gate style check locally
.\tools\Invoke-AITestPilotCiGate.ps1
```

### 中文

```powershell
# 1）执行完整快速上手流程
.\tools\Invoke-AITestPilotQuickStart.ps1

# 2）校验快速上手产物是否完整
.\tools\Invoke-AITestPilotQuickStartChecklist.ps1

# 3）执行标准 PR/Push 本地预检（推荐）
.\tools\Run-DevGate.ps1

# 4）本地执行 CI 级别预检
.\tools\Invoke-AITestPilotCiGate.ps1
```

### Ready-to-paste bilingual operator block | 可直接粘贴的双语块

```text
English:
cd <repo-root>; .\tools\Validate-AITestPilot.ps1; .\tools\Invoke-AITestPilotQuickStart.ps1; .\tools\Run-DevGate.ps1

中文:
进入仓库根目录后依次执行：
.\tools\Validate-AITestPilot.ps1
.\tools\Invoke-AITestPilotQuickStart.ps1
.\tools\Run-DevGate.ps1
```

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

`-ManifestPath`/`-SummaryPath` both accept absolute paths; if omitted or relative, they resolve to the repository root.
`-OutputPath` is now accepted as an alias for `-SummaryPath`.

`Run-DevGate` also resolves `-QuickStartOutputDir`, `-RepairLoopOutputDir`, and `-RepairLoopEvidenceBundleDir` the same way.

CI-friendly single command (writes summary JSON to `Temp\ci-gate-summary.json`):

```powershell
.\tools\Invoke-AITestPilotCiGate.ps1
```

If you need a custom output path:

```powershell
.\tools\Invoke-AITestPilotCiGate.ps1 -SummaryPath Temp\ci-gate-summary.json
```

`-OutputPath` is also an alias for `-SummaryPath` here.

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

If you use the PR checklist mode:

```powershell
.\tools\Run-DevGate.ps1 -SummaryPath Temp\dev-gate-summary.json -GeneratePrChecklist
```

Paste the generated `Temp\pr-validation-checklist.md` block into the PR template section.

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
