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
    [Alias("SummaryPath")]
    [string]$OutputPath = "Temp\ci-gate-summary.json",
    [Alias("ManifestPath")]
    [string]$DeveloperGateManifestPath = "Temp\developer-gate-manifest.json",
    [switch]$AllowPartialFail
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$devGateScript = Join-Path $PSScriptRoot "Run-DevGate.ps1"

function Resolve-OutputPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    return Join-Path $repoRoot $Path
}

$manifestPath = Resolve-OutputPath -Path $DeveloperGateManifestPath
$summaryOutputPath = Resolve-OutputPath -Path $OutputPath

function Build-RunDevGateArgs {
    param([hashtable]$BoundParameters)

    $args = @{}

    if ($BoundParameters.ContainsKey("SkipQuickStart") -and $BoundParameters["SkipQuickStart"]) { $args.SkipQuickStart = $true }
    if ($BoundParameters.ContainsKey("QuickStartSkipUnityImport") -and $BoundParameters["QuickStartSkipUnityImport"]) { $args.QuickStartSkipUnityImport = $true }
    if ($BoundParameters.ContainsKey("QuickStartSkipModelEndpointTrace") -and $BoundParameters["QuickStartSkipModelEndpointTrace"]) { $args.QuickStartSkipModelEndpointTrace = $true }
    if ($BoundParameters.ContainsKey("SkipRepairLoop") -and $BoundParameters["SkipRepairLoop"]) { $args.SkipRepairLoop = $true }
    if ($BoundParameters.ContainsKey("RepairLoopSkipUnityCoreValidation") -and $BoundParameters["RepairLoopSkipUnityCoreValidation"]) { $args.RepairLoopSkipUnityCoreValidation = $true }
    if ($BoundParameters.ContainsKey("RepairLoopSkipPatchApplyRetest") -and $BoundParameters["RepairLoopSkipPatchApplyRetest"]) { $args.RepairLoopSkipPatchApplyRetest = $true }
    if ($BoundParameters.ContainsKey("RepairLoopSkipRepairRetest") -and $BoundParameters["RepairLoopSkipRepairRetest"]) { $args.RepairLoopSkipRepairRetest = $true }
    if (-not [string]::IsNullOrWhiteSpace($BoundParameters["QuickStartOutputDir"])) { $args.QuickStartOutputDir = Resolve-OutputPath -Path $BoundParameters["QuickStartOutputDir"] }
    if (-not [string]::IsNullOrWhiteSpace($BoundParameters["RepairLoopOutputDir"])) { $args.RepairLoopOutputDir = Resolve-OutputPath -Path $BoundParameters["RepairLoopOutputDir"] }
    if (-not [string]::IsNullOrWhiteSpace($BoundParameters["RepairLoopEvidenceBundleDir"])) { $args.RepairLoopEvidenceBundleDir = Resolve-OutputPath -Path $BoundParameters["RepairLoopEvidenceBundleDir"] }
    if (-not [string]::IsNullOrWhiteSpace($BoundParameters["UnityPath"])) { $args.UnityPath = $BoundParameters["UnityPath"] }
    if (-not [string]::IsNullOrWhiteSpace($BoundParameters["ManifestPath"])) {
        $args.DeveloperGateManifestPath = Resolve-OutputPath -Path $BoundParameters["ManifestPath"]
    }
    if (-not [string]::IsNullOrWhiteSpace($BoundParameters["DeveloperGateManifestPath"])) {
        $args.DeveloperGateManifestPath = Resolve-OutputPath -Path $BoundParameters["DeveloperGateManifestPath"]
    }

    return $args
}

function Resolve-PathOrNull {
    param([string]$Path)

    try {
        return (Resolve-Path $Path -ErrorAction Stop).Path
    }
    catch {
        return $null
    }
}

function Parse-DeveloperGateSummary {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Developer gate manifest not found: $Path"
    }

    $manifest = Get-Content -Raw $Path | ConvertFrom-Json
    if (-not $manifest) {
        throw "Could not parse developer gate manifest JSON: $Path"
    }

    $quickStartStep = $manifest.steps | Where-Object {
        $_.name -eq "Invoke-AITestPilotQuickStart.ps1" -or
        $_.name -eq "Invoke-AITestPilotQuickStartChecklist.ps1" -or
        $_.name -eq "Quick start block"
    }
    $repairLoopStep = $manifest.steps | Where-Object {
        $_.name -eq "Invoke-AITestPilotRepairLoop.ps1" -or
        $_.name -eq "Repair loop block"
    }

    $quickStartStatus = if ($quickStartStep) { ($quickStartStep | Select-Object -Last 1).status } else { "NOT_RUN" }
    $repairLoopStatus = if ($repairLoopStep) { ($repairLoopStep | Select-Object -Last 1).status } else { "NOT_RUN" }

    $failed = [System.Collections.Generic.List[string]]::new()
    $skips = [System.Collections.Generic.List[string]]::new()

    foreach ($step in @($manifest.steps)) {
        if ($step.status -eq "SKIPPED" -and $step.message) {
            if ($step.name -eq "Invoke-AITestPilotQuickStart.ps1" -or $step.name -eq "Invoke-AITestPilotQuickStartChecklist.ps1" -or $step.name -eq "Quick start block") {
                $skips.Add("quick-start: $($step.message)")
            }
            elseif ($step.name -eq "Invoke-AITestPilotRepairLoop.ps1" -or $step.name -eq "Repair loop block") {
                $skips.Add("repair-loop: $($step.message)")
            }
        }

        if ($step.status -eq "FAIL" -or $step.status -eq "WARN") {
            $err = if ($step.message) { $step.message } else { $step.error }
            if ($err) {
                $failed.Add("$($step.name): $($step.status) - $err")
            } else {
                $failed.Add("$($step.name): $($step.status)")
            }
        }
    }

    return [pscustomobject]@{
        developer_gate_status = if ($manifest.status) { $manifest.status } else { "UNKNOWN" }
        quick_start_status = $quickStartStatus
        repair_loop_status = $repairLoopStatus
        quick_start_skipped = [bool]($quickStartStep | Where-Object { $_.status -eq "SKIPPED" })
        repair_loop_skipped = [bool]($repairLoopStep | Where-Object { $_.status -eq "SKIPPED" })
        skip_reasons = @($skips)
        failed_steps = @($failed)
    }
}

$start = Get-Date
$bound = @{}
$PSBoundParameters.GetEnumerator() | ForEach-Object { $bound[$_.Key] = $_.Value }
$runArgs = Build-RunDevGateArgs -BoundParameters $bound

try {
    & $devGateScript @runArgs
    $runSucceeded = $true
}
catch {
    $runSucceeded = $false
}

$summary = [ordered]@{
    started_utc = $start.ToUniversalTime().ToString("o")
    finished_utc = (Get-Date).ToUniversalTime().ToString("o")
    run_succeeded = $runSucceeded
    invoked_with = $runArgs
    developer_gate_manifest = $manifestPath
    developer_gate_status = "UNKNOWN"
    quick_start_status = "UNKNOWN"
    repair_loop_status = "UNKNOWN"
    quick_start_skipped = $false
    repair_loop_skipped = $false
    skip_reasons = @()
    failed_steps = @()
}

try {
    $manifestParsePath = if (Test-Path $manifestPath) { $manifestPath } else { Join-Path $repoRoot "Temp\developer-gate-manifest.json" }

    if (-not (Test-Path $manifestParsePath)) {
        throw "Developer gate manifest not found: $manifestPath (or default Temp\\developer-gate-manifest.json)"
    }

    $runSummary = Parse-DeveloperGateSummary -Path $manifestParsePath

    $manifestPathResolved = Resolve-PathOrNull -Path $manifestPath
    $manifestParseResolved = Resolve-PathOrNull -Path $manifestParsePath
    if ($manifestPathResolved -ne $manifestParseResolved) {
        $manifestDir = Split-Path $manifestPath -Parent
        if ($manifestDir) {
            New-Item -ItemType Directory -Force $manifestDir | Out-Null
        }
        Copy-Item -Path $manifestParsePath -Destination $manifestPath -Force
    }

    $summary.developer_gate_status = $runSummary.developer_gate_status
    $summary.quick_start_status = $runSummary.quick_start_status
    $summary.repair_loop_status = $runSummary.repair_loop_status
    $summary.quick_start_skipped = $runSummary.quick_start_skipped
    $summary.repair_loop_skipped = $runSummary.repair_loop_skipped
    $summary.skip_reasons = $runSummary.skip_reasons
    $summary.failed_steps = $runSummary.failed_steps
}
catch {
    $summary.skip_reasons = @("summary parse failed: $($_.Exception.Message)")
$summary.failed_steps = @("summary parse failed: $($_.Exception.Message)")
}

New-Item -ItemType Directory -Force (Split-Path $summaryOutputPath -Parent) | Out-Null
Set-Content -Path $summaryOutputPath -Value ($summary | ConvertTo-Json -Depth 8) -Encoding UTF8

Write-Host ""
Write-Host "AI TestPilot CI gate summary:"
Write-Host ($summary | ConvertTo-Json -Depth 8)

$requiredFail = $summary.developer_gate_status -ne "PASS"
if ($requiredFail -and -not $AllowPartialFail) {
    exit 1
}

if (-not $runSucceeded -and $summary.developer_gate_status -ne "PASS" -and -not $AllowPartialFail) {
    exit 2
}

if ($summary.developer_gate_status -eq "UNKNOWN") {
    exit 2
}

exit 0
