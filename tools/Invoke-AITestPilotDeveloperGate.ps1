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
    [switch]$RunReplayProfileSchemaCheck,
    [string]$ReplayProfileJsonPath,
    [Alias("ManifestPath")]
    [string]$DeveloperGateManifestPath = "Temp\developer-gate-manifest.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Resolve-RelativePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    return Join-Path $repoRoot $Path
}

function Resolve-PathToRepoRoot {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return Join-Path $repoRoot $Path
}

function Assert-PathUnderRoot {
    param(
        [string]$Path,
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Label cannot be empty."
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($repoRoot)
    if ($fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath
    }

    if (-not $fullRoot.EndsWith(([System.IO.Path]::DirectorySeparatorChar).ToString())) {
        $fullRoot = $fullRoot + [System.IO.Path]::DirectorySeparatorChar
    }

    if (-not $fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must stay under repo root: $fullPath"
    }

    return $fullPath
}

$quickStartOutput = if ([string]::IsNullOrWhiteSpace($QuickStartOutputDir)) { Join-Path $repoRoot "Temp\quick-start" } else { Resolve-RelativePath -Path $QuickStartOutputDir }
$repairLoopOutput = if ([string]::IsNullOrWhiteSpace($RepairLoopOutputDir)) { Join-Path $repoRoot "Temp\repair-loop" } else { Resolve-RelativePath -Path $RepairLoopOutputDir }

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

    $LASTEXITCODE = 0
    & $scriptPath @Arguments
    $exitCode = 0
    if (Test-Path Variable:LASTEXITCODE) {
        if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            $exitCode = $LASTEXITCODE
        }
    }

    if ($exitCode -ne 0) {
        throw "$ScriptName failed with exit code $exitCode"
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

if ($RunReplayProfileSchemaCheck.IsPresent) {
    Write-Host "==> developer gate: replay profile schema check"
    try {
        $replayProfilePath = if ([string]::IsNullOrWhiteSpace($ReplayProfileJsonPath)) {
            Join-Path $repoRoot "Temp\release-evidence\latest\sample-business-replay-profile.json"
        } else {
            Resolve-PathToRepoRoot -Path $ReplayProfileJsonPath
        }

        $replayProfilePath = Assert-PathUnderRoot -Path $replayProfilePath -Label "ReplayProfileJsonPath"
        if (-not (Test-Path $replayProfilePath)) {
            throw "Replay profile JSON not found: $replayProfilePath"
        }

        $replayProfileEvidenceDir = Join-Path $repoRoot "Temp\release-evidence\latest"
        New-Item -ItemType Directory -Force $replayProfileEvidenceDir | Out-Null
        $replayProfileManifestPath = Join-Path $replayProfileEvidenceDir "replay-profile-schema-check-manifest.json"
        if (Test-Path $replayProfileManifestPath) {
            Remove-Item -Path $replayProfileManifestPath -Force
        }

        $replayProfileExecutionError = $null
        try {
            Invoke-CheckedScript "Invoke-AITestPilotReplayProfileSchemaCheck.ps1" @{
                ReplayProfileJsonPath = $replayProfilePath
                EvidenceBundleDir = $replayProfileEvidenceDir
                ManifestPath = $replayProfileManifestPath
            } | Out-Null
        }
        catch {
            $replayProfileExecutionError = $_.Exception.Message
        }

        $replayProfileManifest = Read-JsonSafely -Path $replayProfileManifestPath
        if (-not $replayProfileExecutionError -and $replayProfileManifest -and $replayProfileManifest.status -eq "PASS") {
            Add-Step -Name "Invoke-AITestPilotReplayProfileSchemaCheck.ps1" -Status "PASS"
        }
        else {
            $developerGate.status = "PARTIAL_FAIL"
            $replayProfileFailureReason = if ($replayProfileManifest -and $replayProfileManifest.status) {
                "Replay profile schema check status: $($replayProfileManifest.status)"
            } else {
                "Replay profile schema check failed. Check manifest for details."
            }
            if ($replayProfileExecutionError) {
                $replayProfileFailureReason = "$replayProfileFailureReason $replayProfileExecutionError"
            }

            $replayProfileFailReasons = @()
            if ($replayProfileManifest -and $replayProfileManifest.issues) {
                $replayProfileFailReasons = @(
                    @($replayProfileManifest.issues) |
                    Where-Object { $_.severity -eq "FAIL" } |
                    ForEach-Object { "[$($_.code)] $($_.path): $($_.message)" }
                )
            }

            if ($replayProfileFailReasons.Count -gt 0) {
                $replayProfileFailureReason = "$replayProfileFailureReason`n" + ($replayProfileFailReasons -join "`n")
            }

            Add-Step -Name "Invoke-AITestPilotReplayProfileSchemaCheck.ps1" `
                -Status "FAIL" `
                -Message $replayProfileFailureReason
        }
    }
    catch {
        $developerGate.status = "PARTIAL_FAIL"
        Add-Step -Name "Invoke-AITestPilotReplayProfileSchemaCheck.ps1" -Status "FAIL" -Message $_.Exception.Message
    }
}
else {
    Add-Step -Name "Invoke-AITestPilotReplayProfileSchemaCheck.ps1" -Status "SKIPPED" -Message "RunReplayProfileSchemaCheck was not set."
}

if (-not $SkipRepairLoop) {
    Write-Host "==> developer gate: repair loop"
    try {
        $repairLoopArgs = @{ OutputDir = $repairLoopOutput }
        if (-not [string]::IsNullOrWhiteSpace($RepairLoopEvidenceBundleDir)) {
            $repairLoopArgs.EvidenceBundleDir = Resolve-RelativePath -Path $RepairLoopEvidenceBundleDir
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
$developerManifest = Resolve-RelativePath -Path $DeveloperGateManifestPath
New-Item -ItemType Directory -Force (Split-Path $developerManifest -Parent) | Out-Null
$developerGate | ConvertTo-Json -Depth 8 | Set-Content -Path $developerManifest -Encoding UTF8

Write-Host "Developer gate manifest:"
Write-Host $developerManifest
Write-Host "Developer gate status: $($developerGate.status)"

if ($developerGate.status -ne "PASS") {
    throw "Developer gate completed with partial failures. Check manifest for details: $developerManifest"
}
