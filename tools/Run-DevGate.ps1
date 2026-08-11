[CmdletBinding()]
param(
    [switch]$SkipQuickStart,
    [switch]$QuickStartSkipUnityImport,
    [switch]$QuickStartSkipModelEndpointTrace,
    [switch]$SkipRepairLoop,
    [switch]$RepairLoopSkipUnityCoreValidation,
    [switch]$RepairLoopSkipPatchApplyRetest,
    [switch]$RepairLoopSkipRepairRetest,
    [string]$QuickStartOutputDir,
    [string]$RepairLoopOutputDir,
    [string]$RepairLoopEvidenceBundleDir,
    [string]$UnityPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$devGateScript = Join-Path $PSScriptRoot "Invoke-AITestPilotDeveloperGate.ps1"
$developerManifest = Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..")).Path "Temp\developer-gate-manifest.json"

& $devGateScript @PSBoundParameters

$summary = @{
    status = "UNKNOWN"
    quickStartStatus = "UNKNOWN"
    quickStartSkipped = $false
    repairLoopSkipped = $false
    skipReasons = @()
    failedSteps = @()
}

if (Test-Path $developerManifest) {
    try {
        $manifest = Get-Content -Raw $developerManifest | ConvertFrom-Json
        $summary.status = if ($manifest.status) { $manifest.status } else { "UNKNOWN" }
        $summary.quickStartStatus = "NOT_RUN"
        $summary.repairLoopStatus = "NOT_RUN"

        if ($manifest.steps) {
            foreach ($step in $manifest.steps) {
                if ($step.name -eq "Invoke-AITestPilotQuickStart.ps1" -or $step.name -eq "Invoke-AITestPilotQuickStartChecklist.ps1" -or $step.name -like "QuickStart*" -or $step.name -like "quick-start*" -or $step.name -eq "Quick start block") {
                    $summary.quickStartStatus = $step.status
                    if ($step.status -eq "SKIPPED") {
                        $summary.quickStartSkipped = $true
                        $summary.skipReasons += "quick-start: $($step.message)"
                    }
                }

                if ($step.name -eq "Invoke-AITestPilotRepairLoop.ps1" -or $step.name -like "Repair loop*" -or $step.name -eq "Repair loop block") {
                    $summary.repairLoopStatus = $step.status
                    if ($step.status -eq "SKIPPED") {
                        $summary.repairLoopSkipped = $true
                        $summary.skipReasons += "repair-loop: $($step.message)"
                    }
                }

                if ($step.status -eq "FAIL" -or $step.status -eq "WARN") {
                    $errorMessage = if ($step.message) { $step.message } else { $step.error }
                    $summary.failedSteps += "$($step.name): $($step.status)$(if ($errorMessage) { \" - $($errorMessage)\" })"
                }
            }
        }
    }
    catch {
        $summary.failedSteps += "developer-gate manifest parse failed: $($_.Exception.Message)"
    }
}
else {
    $summary.failedSteps += "developer-gate manifest not found at $developerManifest"
}

$summaryPayload = @{
    developer_gate_status = $summary.status
    quick_start_status = $summary.quickStartStatus
    repair_loop_status = $summary.repairLoopStatus
    quick_start_skipped = $summary.quickStartSkipped
    repair_loop_skipped = $summary.repairLoopSkipped
    skip_reasons = $summary.skipReasons
    failed_steps = $summary.failedSteps
}

Write-Host ""
Write-Host "Run-DevGate summary:"
Write-Host ($summaryPayload | ConvertTo-Json -Depth 8)

if ($summaryPayload.developer_gate_status -ne "PASS") {
    Write-Host "Please include this summary in PR description."
}
