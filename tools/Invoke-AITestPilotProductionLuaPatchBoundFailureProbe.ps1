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
    $ProbeBundleDir = Join-Path $repoRoot "Temp\release-evidence\production-lua-patch-bound-failure-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-lua-patch-bound-failure-probe-manifest.json"
}

$expectedBlockingReasons = @(
    "real_production_lua_bundle_missing",
    "real_production_lua_not_analyzed",
    "real_production_lua_not_patched",
    "production_lua_retest_evidence_missing",
    "real_production_patch_rollback_missing"
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

$readinessScript = Join-Path $PSScriptRoot "Invoke-AITestPilotProductionLuaPatchReadiness.ps1"
$probeReadinessManifestPath = Join-Path $probeBundlePath "production-lua-patch-readiness-manifest.json"
$readinessCommandFailed = $false
$failureMessage = ""

try {
    & $readinessScript `
        -EvidenceBundleDir $probeBundlePath `
        -ManifestPath $probeReadinessManifestPath `
        -RequireProductionLuaPatched
}
catch {
    $readinessCommandFailed = $true
    $failureMessage = $_.Exception.Message
}

if (-not $readinessCommandFailed) {
    throw "Expected production Lua patch readiness to fail with -RequireProductionLuaPatched, but it passed."
}

if (-not (Test-Path $probeReadinessManifestPath)) {
    throw "Expected production Lua patch readiness failure manifest was not produced: $probeReadinessManifestPath"
}

$probeReadiness = Get-Content -Path $probeReadinessManifestPath -Encoding UTF8 -Raw | ConvertFrom-Json
$expectedBlockingReasonsFound = Test-ContainsAll @($probeReadiness.blockingReasons) $expectedBlockingReasons

$readyForProductionLuaPatchRelease = [bool]$probeReadiness.readyForProductionLuaPatchRelease
$productionLuaEvidenceAccepted = [bool]$probeReadiness.productionLuaEvidenceAccepted
$realProductionLuaAnalyzed = [bool]$probeReadiness.realProductionLuaAnalyzed
$realProductionLuaPatched = [bool]$probeReadiness.realProductionLuaPatched
$sandboxAfterFindingsCleared = [bool]$probeReadiness.sandboxAfterFindingsCleared
$sandboxBoundaryPreserved = [bool]$probeReadiness.sandboxBoundaryPreserved

$copiedReadinessManifestName = "production-lua-patch-bound-failure-readiness-manifest.json"
$copiedReadinessManifestPath = Join-Path $evidenceBundlePath $copiedReadinessManifestName
Copy-Item -LiteralPath $probeReadinessManifestPath -Destination $copiedReadinessManifestPath -Force

$status = "PASS"
if ($probeReadiness.status -ne "PASS" -or
    -not [bool]$probeReadiness.requireProductionLuaPatched -or
    $readyForProductionLuaPatchRelease -or
    $productionLuaEvidenceAccepted -or
    $realProductionLuaAnalyzed -or
    $realProductionLuaPatched -or
    -not $sandboxAfterFindingsCleared -or
    -not $sandboxBoundaryPreserved -or
    -not $expectedBlockingReasonsFound) {
    $status = "FAIL"
}

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_lua_patch_bound_failure_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    expectedFailure = $true
    readinessCommandFailed = [bool]$readinessCommandFailed
    failureMessage = $failureMessage
    requireProductionLuaPatched = [bool]$probeReadiness.requireProductionLuaPatched
    readinessStatus = $probeReadiness.status
    readyForProductionLuaPatchRelease = [bool]$readyForProductionLuaPatchRelease
    productionLuaEvidenceAccepted = [bool]$productionLuaEvidenceAccepted
    realProductionLuaAnalyzed = [bool]$realProductionLuaAnalyzed
    realProductionLuaPatched = [bool]$realProductionLuaPatched
    sandboxAfterFindingsCleared = [bool]$sandboxAfterFindingsCleared
    sandboxBoundaryPreserved = [bool]$sandboxBoundaryPreserved
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
    throw "Production Lua patch bound failure probe did not capture the expected real-production blockers."
}

Write-Output "Production Lua patch bound failure probe manifest: $manifestPath"
Write-Output "PASS AI TestPilot production Lua patch bound failure probe"
