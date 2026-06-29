[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ProbeBundleDir,
    [string]$ManifestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ProbeBundleDir)) {
    $ProbeBundleDir = Join-Path $repoRoot "Temp\release-evidence\production-driver-bound-failure-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-replay-driver-bound-failure-probe-manifest.json"
}

$expectedBlockingReasons = @(
    "production_replay_integration_not_bound",
    "required_hooks_not_all_bound",
    "unresolved_required_hooks",
    "sample_game_replay_driver_used",
    "external_production_driver_not_selected"
)

function Assert-PathUnderRepo {
    param(
        [string]$Path,
        [string]$Label
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must stay under repo root: $fullPath"
    }

    return $fullPath
}

function Test-ContainsAll {
    param(
        [object[]]$Actual,
        [string[]]$Required
    )

    foreach ($item in $Required) {
        if ($Actual -notcontains $item) {
            return $false
        }
    }

    return $true
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$probeBundlePath = Assert-PathUnderRepo $ProbeBundleDir "ProbeBundleDir"
$manifestPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if (Test-Path $probeBundlePath) {
    Remove-Item -LiteralPath $probeBundlePath -Recurse -Force
}

New-Item -ItemType Directory -Force $probeBundlePath | Out-Null
Copy-Item -Path (Join-Path $evidenceBundlePath "*") -Destination $probeBundlePath -Recurse -Force

$readinessScript = Join-Path $PSScriptRoot "Invoke-AITestPilotProductionReplayDriverReadiness.ps1"
$probeReadinessManifestPath = Join-Path $probeBundlePath "production-replay-driver-readiness-manifest.json"
$readinessCommandFailed = $false
$failureMessage = ""

try {
    & $readinessScript `
        -EvidenceBundleDir $probeBundlePath `
        -ManifestPath $probeReadinessManifestPath `
        -RequireProductionBound
}
catch {
    $readinessCommandFailed = $true
    $failureMessage = $_.Exception.Message
}

if (-not $readinessCommandFailed) {
    throw "Expected production replay driver readiness to fail with -RequireProductionBound, but it passed."
}

if (-not (Test-Path $probeReadinessManifestPath)) {
    throw "Expected production-bound readiness failure manifest was not produced: $probeReadinessManifestPath"
}

$probeReadiness = Get-Content -Path $probeReadinessManifestPath -Encoding UTF8 -Raw | ConvertFrom-Json
$expectedBlockingReasonsFound = Test-ContainsAll @($probeReadiness.blockingReasons) $expectedBlockingReasons

$readyForProductionDriverRelease = [bool]$probeReadiness.readyForProductionDriverRelease
$realProjectBound = [bool]$probeReadiness.realProjectBound
$sampleGameReplayDriverUsed = [bool]$probeReadiness.sampleGameReplayDriverUsed
$externalProductionDriverSelected = [bool]$probeReadiness.externalProductionDriverSelected

$copiedReadinessManifestName = "production-replay-driver-bound-failure-readiness-manifest.json"
$copiedReadinessManifestPath = Join-Path $evidenceBundlePath $copiedReadinessManifestName
Copy-Item -LiteralPath $probeReadinessManifestPath -Destination $copiedReadinessManifestPath -Force

$status = "PASS"
if ($probeReadiness.status -ne "PASS" -or
    -not [bool]$probeReadiness.requireProductionBound -or
    $readyForProductionDriverRelease -or
    $realProjectBound -or
    -not $sampleGameReplayDriverUsed -or
    $externalProductionDriverSelected -or
    -not $expectedBlockingReasonsFound) {
    $status = "FAIL"
}

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_replay_driver_bound_failure_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    expectedFailure = $true
    readinessCommandFailed = [bool]$readinessCommandFailed
    failureMessage = $failureMessage
    requireProductionBound = [bool]$probeReadiness.requireProductionBound
    readinessStatus = $probeReadiness.status
    readyForProductionDriverRelease = [bool]$readyForProductionDriverRelease
    realProjectBound = [bool]$realProjectBound
    sampleGameReplayDriverUsed = [bool]$sampleGameReplayDriverUsed
    externalProductionDriverSelected = [bool]$externalProductionDriverSelected
    blockingReasonCount = [int]$probeReadiness.blockingReasonCount
    blockingReasons = @($probeReadiness.blockingReasons)
    expectedBlockingReasons = @($expectedBlockingReasons)
    expectedBlockingReasonsFound = [bool]$expectedBlockingReasonsFound
    files = @(
        $copiedReadinessManifestName
    )
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

if ($status -ne "PASS") {
    throw "Production-bound failure probe did not capture the expected sample/unbound blockers."
}

Write-Output "Production-bound failure probe manifest: $manifestPath"
Write-Output "PASS AI TestPilot production replay driver bound failure probe"
