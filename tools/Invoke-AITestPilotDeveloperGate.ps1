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

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$quickStartOutput = if ([string]::IsNullOrWhiteSpace($QuickStartOutputDir)) { Join-Path $repoRoot "Temp\quick-start" } else { $QuickStartOutputDir }
$repairLoopOutput = if ([string]::IsNullOrWhiteSpace($RepairLoopOutputDir)) { Join-Path $repoRoot "Temp\repair-loop" } else { $RepairLoopOutputDir }

$developerGate = [ordered]@{
    startTime = (Get-Date).ToString("o")
    repository = $repoRoot
    status = "PASS"
    steps = @()
}

function Add-Step {
    param([string]$Name, [string]$Status, [string]$Message = "")

    $entry = [ordered]@{
        name = $Name
        status = $Status
        timestampUtc = (Get-Date).ToUniversalTime().ToString("O")
    }

    if ($Message) {
        $entry.message = $Message
    }

    $developerGate.steps += $entry
}

function Invoke-CheckedScript {
    param([string]$ScriptName, [hashtable]$Arguments = @{})

    $scriptPath = Join-Path $repoRoot ("tools\" + $ScriptName)
    if ($null -eq $Arguments) {
        $Arguments = @{}
    }

    & $scriptPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$ScriptName failed with exit code $LASTEXITCODE"
    }
}

function Read-JsonSafely {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        return $null
    }

    return Get-Content -Raw $Path | ConvertFrom-Json
}

New-Item -ItemType Directory -Force $quickStartOutput | Out-Null
New-Item -ItemType Directory -Force $repairLoopOutput | Out-Null

if (-not $SkipQuickStart) {
    Write-Host "==> developer gate: quick start"
    try {
        $quickStartArgs = @{
            OutputDir = $quickStartOutput
        }
        if ($QuickStartSkipUnityImport) { $quickStartArgs.SkipUnityImport = $true }
        if ($QuickStartSkipModelEndpointTrace) { $quickStartArgs.SkipModelEndpointTrace = $true }
        Invoke-CheckedScript "Invoke-AITestPilotQuickStart.ps1" $quickStartArgs
        Add-Step -Name "Invoke-AITestPilotQuickStart.ps1" -Status "PASS"

        $manifestPath = Join-Path $quickStartOutput "quick-start-manifest.json"
        $qsManifest = Read-JsonSafely $manifestPath
        if (-not $qsManifest) {
            Add-Step -Name "QuickStart manifest parse" -Status "FAIL" -Message "Manifest missing: $manifestPath"
            $developerGate.status = "PARTIAL_FAIL"
        }
        else {
            Invoke-CheckedScript "Invoke-AITestPilotQuickStartChecklist.ps1" @{
                ManifestPath = $manifestPath
                RequireAllChecks = $true
            }
            Add-Step -Name "Invoke-AITestPilotQuickStartChecklist.ps1" -Status "PASS"
            if ($qsManifest.status -ne "PASS") {
                $developerGate.status = "PARTIAL_FAIL"
                Add-Step -Name "QuickStart manifest status" -Status "WARN" -Message "manifest status=$($qsManifest.status)"
            }
        }
    }
    catch {
        $developerGate.status = "PARTIAL_FAIL"
        Add-Step -Name "Quick start block" -Status "FAIL" -Message $_.Exception.Message
    }
}
else {
    Add-Step -Name "Invoke-AITestPilotQuickStart.ps1" -Status "SKIPPED" -Message "SkipQuickStart was set."
}

if (-not $SkipRepairLoop) {
    Write-Host "==> developer gate: repair loop"
    try {
        $repairLoopArgs = @{ OutputDir = $repairLoopOutput }
        if (-not [string]::IsNullOrWhiteSpace($RepairLoopEvidenceBundleDir)) {
            $repairLoopArgs.EvidenceBundleDir = $RepairLoopEvidenceBundleDir
        }
        if ($RepairLoopSkipUnityCoreValidation) { $repairLoopArgs.SkipUnityCoreValidation = $true }
        if ($RepairLoopSkipPatchApplyRetest) { $repairLoopArgs.SkipPatchApplyRetest = $true }
        if ($RepairLoopSkipRepairRetest) { $repairLoopArgs.SkipRepairRetest = $true }
        if (-not [string]::IsNullOrWhiteSpace($UnityPath)) {
            $repairLoopArgs.UnityPath = $UnityPath
        }
        Invoke-CheckedScript "Invoke-AITestPilotRepairLoop.ps1" $repairLoopArgs

        $repairLoopManifestPath = Join-Path $repairLoopOutput "repair-loop-manifest.json"
        $repairLoopManifest = Read-JsonSafely $repairLoopManifestPath
        if ($repairLoopManifest -and $repairLoopManifest.status -ne "PASS") {
            $developerGate.status = "PARTIAL_FAIL"
            Add-Step -Name "Repair loop manifest status" -Status "WARN" -Message "status=$($repairLoopManifest.status)"
        }
        Add-Step -Name "Invoke-AITestPilotRepairLoop.ps1" -Status "PASS"
    }
    catch {
        $developerGate.status = "PARTIAL_FAIL"
        Add-Step -Name "Repair loop block" -Status "FAIL" -Message $_.Exception.Message
    }
}
else {
    Add-Step -Name "Invoke-AITestPilotRepairLoop.ps1" -Status "SKIPPED" -Message "SkipRepairLoop was set."
}

$developerGate.endTime = (Get-Date).ToString("o")
$developerManifest = Join-Path $repoRoot "Temp\developer-gate-manifest.json"
$developerGate | ConvertTo-Json -Depth 8 | Set-Content -Path $developerManifest -Encoding UTF8

Write-Host "Developer gate manifest:"
Write-Host $developerManifest
Write-Host "Developer gate status: $($developerGate.status)"

if ($developerGate.status -ne "PASS") {
    throw "Developer gate completed with partial failures. Check manifest for details: $developerManifest"
}
