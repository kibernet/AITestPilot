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
    [string]$UnityPath,
    [Alias("OutputPath")]
    [string]$SummaryPath,
    [Alias("ManifestPath")]
    [string]$DeveloperGateManifestPath = "Temp\developer-gate-manifest.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$devGateScript = Join-Path $PSScriptRoot "Invoke-AITestPilotDeveloperGate.ps1"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Resolve-ManifestPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    return Join-Path $repoRoot $Path
}

function Resolve-SummaryPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    return Join-Path $repoRoot $Path
}

function Resolve-OutputDir {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    return Join-Path $repoRoot $Path
}

$developerManifest = Resolve-ManifestPath -Path $DeveloperGateManifestPath
$defaultManifest = Join-Path $repoRoot "Temp\developer-gate-manifest.json"
$manifestParsePath = if (Test-Path $developerManifest) { $developerManifest } else { $defaultManifest }

$devGateParameters = @{}
foreach ($entry in $PSBoundParameters.GetEnumerator()) {
    if ($entry.Key -ne "SummaryPath" -and $entry.Key -ne "OutputPath") {
        $devGateParameters[$entry.Key] = $entry.Value
    }
}

if ($devGateParameters.ContainsKey("QuickStartOutputDir")) {
    $devGateParameters["QuickStartOutputDir"] = Resolve-OutputDir -Path $devGateParameters["QuickStartOutputDir"]
}

if ($devGateParameters.ContainsKey("RepairLoopOutputDir")) {
    $devGateParameters["RepairLoopOutputDir"] = Resolve-OutputDir -Path $devGateParameters["RepairLoopOutputDir"]
}

if ($devGateParameters.ContainsKey("RepairLoopEvidenceBundleDir")) {
    $devGateParameters["RepairLoopEvidenceBundleDir"] = Resolve-OutputDir -Path $devGateParameters["RepairLoopEvidenceBundleDir"]
}

& $devGateScript @devGateParameters

$summary = @{
    status = "UNKNOWN"
    quickStartStatus = "UNKNOWN"
    quickStartSkipped = $false
    repairLoopSkipped = $false
    skipReasons = @()
    failedSteps = @()
}

if (Test-Path $manifestParsePath) {
    try {
        $manifest = Get-Content -Raw $manifestParsePath | ConvertFrom-Json
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
    $summary.failedSteps += "developer-gate manifest not found at $manifestParsePath"
}

$summaryPayload = @{
    developer_gate_status = $summary.status
    quick_start_status = $summary.quickStartStatus
    repair_loop_status = $summary.repairLoopStatus
    quick_start_skipped = $summary.quickStartSkipped
    repair_loop_skipped = $summary.repairLoopSkipped
    summary_manifest = $developerManifest
    skip_reasons = $summary.skipReasons
    failed_steps = $summary.failedSteps
}

if (Test-Path $manifestParsePath) {
    $manifestParseResolved = (Resolve-Path $manifestParsePath).Path
    $developerManifestResolved = (Resolve-Path $developerManifest -ErrorAction SilentlyContinue)
    if (-not $developerManifestResolved -or $manifestParseResolved -ne $developerManifestResolved.Path) {
        $manifestDir = Split-Path $developerManifest -Parent
        if ($manifestDir) {
            New-Item -ItemType Directory -Force $manifestDir | Out-Null
        }
        Copy-Item -Path $manifestParsePath -Destination $developerManifest -Force
    }
}
else {
    $summary.failedSteps += "Unable to copy manifest to target path because source manifest does not exist: $manifestParsePath"
}

Write-Host ""
Write-Host "Run-DevGate summary:"
Write-Host ($summaryPayload | ConvertTo-Json -Depth 8)

if (-not [string]::IsNullOrWhiteSpace($SummaryPath)) {
    $summaryPathResolved = Resolve-SummaryPath -Path $SummaryPath
    New-Item -ItemType Directory -Force (Split-Path $summaryPathResolved -Parent) | Out-Null
    $summaryPayload | ConvertTo-Json -Depth 8 | Set-Content -Path $summaryPathResolved -Encoding UTF8
    Write-Host "Run-DevGate summary written to: $summaryPathResolved"
}

if ($summaryPayload.developer_gate_status -ne "PASS") {
    Write-Host "Please include this summary in PR description."
}
