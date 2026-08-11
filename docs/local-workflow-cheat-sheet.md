# Local AITestPilot Workflow Cheat Sheet

Use this checklist as a quick operational map.

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

## 2) Daily local development

- PR/local quality gate

```powershell
.\tools\Run-DevGate.ps1
```

- Inspect gate summary for PR notes

```powershell
.\tools\Run-DevGate.ps1 -SummaryPath Temp\dev-gate-summary.json
```

- CI-style path regression (recommended after touching CI gate path logic)

```powershell
.\tools\Validate-AITestPilot.ps1 -RunCiGatePathRegression
```

- Strict CI path regression (alias conflict guard)

```powershell
.\tools\Validate-AITestPilot.ps1 -RunCiGatePathRegressionStrict
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

- PR artifacts to include in description:

```text
Temp\quick-start\quick-start-manifest.json
Temp\repair-loop\repair-loop-manifest.json
Temp\developer-gate-manifest.json
Temp\dev-gate-summary.json
Temp\ci-gate-summary.json
```
