[CmdletBinding()]
param(
    [string]$OutputDir,
    [string]$EvidenceBundleDir,
    [string]$UnityPath,
    [string]$ProjectPath,
    [string]$RepairTaskJsonPath,
    [switch]$SkipPatchApplyRetest,
    [switch]$SkipRepairRetest,
    [switch]$SkipUnityCoreValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $repoRoot "Temp\repair-loop"
}

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if (-not (Test-Path $EvidenceBundleDir)) {
    New-Item -ItemType Directory -Force $EvidenceBundleDir | Out-Null
}

if ([string]::IsNullOrWhiteSpace($ProjectPath)) {
    $ProjectPath = Join-Path $repoRoot "Temp\repair-loop-UnityProject"
}

if ([string]::IsNullOrWhiteSpace($RepairTaskJsonPath)) {
    $RepairTaskJsonPath = Join-Path $EvidenceBundleDir "repair-task.json"
}

if ([string]::IsNullOrWhiteSpace($UnityPath)) {
    $UnityPath = "F:\Unity\2021_3_45_f2\Editor\Unity.exe"
}

New-Item -ItemType Directory -Force $OutputDir | Out-Null

function Add-Step {
    param(
        [string]$Name,
        [string]$Status,
        [string]$ErrorMessage = ""
    )

    if (-not (Get-Variable -Name "steps" -ErrorAction SilentlyContinue)) {
        throw "steps collection is not initialized."
    }

    $record = [ordered]@{
        name = $Name
        status = $Status
        timestampUtc = (Get-Date).ToUniversalTime().ToString("O")
    }

    if ($ErrorMessage) {
        $record.error = $ErrorMessage
    }

    $steps += $record
}

function Invoke-CheckedScript {
    param(
        [string]$ScriptName,
        [hashtable]$Arguments
    )

    $scriptPath = Join-Path $repoRoot ("tools\" + $ScriptName)
    if ($null -eq $Arguments) {
        $Arguments = @{}
    }
    & $scriptPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$ScriptName failed with exit code $LASTEXITCODE"
    }
}

$evidence = [ordered]@{
    startTime = (Get-Date).ToString("o")
    status = "PASS"
    repository = $repoRoot
    outputDirectory = $OutputDir
    evidenceBundleDir = $EvidenceBundleDir
    steps = @()
}
$steps = $evidence.steps

Write-Host "==> Repair loop start"

if (-not $SkipUnityCoreValidation) {
    Write-Host "==> core validation"
    try {
        Invoke-CheckedScript -ScriptName "Validate-AITestPilot.ps1" -Arguments @{}
        Add-Step -Name "Validate-AITestPilot" -Status "PASS"
    }
    catch {
        Add-Step -Name "Validate-AITestPilot" -Status "FAIL" -ErrorMessage $_.Exception.Message
        $evidence.status = "PARTIAL_FAIL"
    }
} else {
    Add-Step -Name "Validate-AITestPilot" -Status "SKIPPED" -ErrorMessage "SkipUnityCoreValidation was set."
}

if (-not $SkipPatchApplyRetest) {
    $patchOutputManifestPath = Join-Path $EvidenceBundleDir "repair-agent-patch-output-manifest.json"
    if (Test-Path $patchOutputManifestPath) {
        Write-Host "==> patch apply + retest"
        try {
            Invoke-CheckedScript -ScriptName "Invoke-AITestPilotRepairAgentPatchApplyRetest.ps1" -Arguments @{
                EvidenceBundleDir = $EvidenceBundleDir
            }
            Add-Step -Name "Invoke-AITestPilotRepairAgentPatchApplyRetest" -Status "PASS"
        }
        catch {
            Add-Step -Name "Invoke-AITestPilotRepairAgentPatchApplyRetest" -Status "FAIL" -ErrorMessage $_.Exception.Message
            $evidence.status = "PARTIAL_FAIL"
        }
    } else {
        Add-Step -Name "Invoke-AITestPilotRepairAgentPatchApplyRetest" -Status "SKIPPED" -ErrorMessage "No patch-output manifest at: $patchOutputManifestPath"
    }
}
else {
    Add-Step -Name "Invoke-AITestPilotRepairAgentPatchApplyRetest" -Status "SKIPPED" -ErrorMessage "SkipPatchApplyRetest was set."
}

if (-not $SkipRepairRetest) {
    if (Test-Path $RepairTaskJsonPath) {
        Write-Host "==> repair task retest"
        try {
            $retestArgs = @{
                UnityPath = $UnityPath
                ProjectPath = $ProjectPath
                RepairTaskJsonPath = $RepairTaskJsonPath
                EvidenceBundleDir = $EvidenceBundleDir
            }

            Invoke-CheckedScript -ScriptName "Invoke-AITestPilotRepairRetest.ps1" -Arguments $retestArgs
            Add-Step -Name "Invoke-AITestPilotRepairRetest" -Status "PASS"
        }
        catch {
            Add-Step -Name "Invoke-AITestPilotRepairRetest" -Status "FAIL" -ErrorMessage $_.Exception.Message
            $evidence.status = "PARTIAL_FAIL"
        }
    }
    else {
        Add-Step -Name "Invoke-AITestPilotRepairRetest" -Status "SKIPPED" -ErrorMessage "Repair task was not found: $RepairTaskJsonPath"
    }
}
else {
    Add-Step -Name "Invoke-AITestPilotRepairRetest" -Status "SKIPPED" -ErrorMessage "SkipRepairRetest was set."
}

$evidence.steps = $steps
$evidence.endTime = (Get-Date).ToString("o")
$manifestPath = Join-Path $OutputDir "repair-loop-manifest.json"
$evidence | ConvertTo-Json -Depth 8 | Set-Content -Path $manifestPath -Encoding UTF8

Write-Host "Repair loop manifest:"
Write-Host $manifestPath
Write-Host "Repair loop status: $($evidence.status)"

if ($evidence.status -ne "PASS") {
    throw "Repair loop completed with non-blocking failures. Check manifest for details: $manifestPath"
}
