[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ProbeBundleDir,
    [switch]$RequireProductionReplayDriverBound,
    [switch]$RequireProductionLuaPatched,
    [switch]$RequireLiveModelEndpointSmoke
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ProbeBundleDir)) {
    $ProbeBundleDir = Join-Path $repoRoot "Temp\release-evidence\release-gate-failure-probe"
}

function Resolve-FullPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Test-PathWithinRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    $fullPath = Resolve-FullPath $Path
    $rootPath = (Resolve-FullPath $Root).TrimEnd([char[]]@("\", "/"))
    return $fullPath.Equals($rootPath, [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($rootPath + "\", [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($rootPath + "/", [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-PathUnderRepo {
    param(
        [string]$Path,
        [string]$Label
    )

    $fullPath = Resolve-FullPath $Path
    if (-not (Test-PathWithinRoot $fullPath $repoRoot)) {
        throw "$Label must stay under repo root: $fullPath"
    }

    return $fullPath
}

$EvidenceBundleDir = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$ProbeBundleDir = Assert-PathUnderRepo $ProbeBundleDir "ProbeBundleDir"

$resolvedProbeParent = Split-Path $ProbeBundleDir -Parent
New-Item -ItemType Directory -Force $resolvedProbeParent | Out-Null
$resolvedProbeParent = (Resolve-Path $resolvedProbeParent).Path

if (Test-Path $ProbeBundleDir) {
    Remove-Item -LiteralPath $ProbeBundleDir -Recurse -Force
}

New-Item -ItemType Directory -Force $ProbeBundleDir | Out-Null

$releaseGateScript = Join-Path $PSScriptRoot "Invoke-AITestPilotReleaseGate.ps1"

function Invoke-MissingEvidenceScenario {
    param(
        [string]$Name,
        [string[]]$RelativePaths,
        [string[]]$ExpectedFailedReasonSubstrings,
        [string[]]$RemoveIndexSourceManifestNames = @()
    )

    $scenarioDir = Join-Path $ProbeBundleDir $Name
    New-Item -ItemType Directory -Force $scenarioDir | Out-Null
    Copy-Item -Path (Join-Path $EvidenceBundleDir "*") -Destination $scenarioDir -Recurse -Force

    $removedFiles = @()
    foreach ($relativePath in $RelativePaths) {
        $fullPath = Join-Path $scenarioDir $relativePath
        if (Test-Path $fullPath) {
            Remove-Item -LiteralPath $fullPath -Force
            $removedFiles += $relativePath
        }
    }

    if ($RemoveIndexSourceManifestNames.Count -gt 0) {
        $indexManifestPath = Join-Path $scenarioDir "release-evidence-index-manifest.json"
        $indexManifest = Get-Content -Path $indexManifestPath -Encoding UTF8 -Raw | ConvertFrom-Json
        $indexManifest.sourceManifestNames = @($indexManifest.sourceManifestNames | Where-Object {
                $RemoveIndexSourceManifestNames -notcontains [string]$_
            })
        $indexManifest | ConvertTo-Json -Depth 12 | Set-Content -Path $indexManifestPath -Encoding UTF8
    }

    $scenarioGateManifestPath = Join-Path $scenarioDir "release-gate-manifest.json"
    $releaseGateOutput = & $releaseGateScript `
        -EvidenceBundleDir $scenarioDir `
        -ReleaseGateManifestPath $scenarioGateManifestPath `
        -ExpectBlocked `
        -RequireProductionReplayDriverBound:$RequireProductionReplayDriverBound `
        -RequireProductionLuaPatched:$RequireProductionLuaPatched `
        -RequireLiveModelEndpointSmoke:$RequireLiveModelEndpointSmoke

    $scenarioGateManifest = Get-Content -Path $scenarioGateManifestPath -Encoding UTF8 -Raw | ConvertFrom-Json
    $failedReasons = @($scenarioGateManifest.failedReasons | ForEach-Object { [string]$_ })
    $matchedExpectedFailedReasons = @($ExpectedFailedReasonSubstrings | Where-Object {
            $expected = [string]$_
            @($failedReasons | Where-Object { $_.Contains($expected) }).Count -gt 0
        })
    $expectedFailedReasonsMatched = $matchedExpectedFailedReasons.Count -eq $ExpectedFailedReasonSubstrings.Count
    return [ordered]@{
        name = $Name
        removedFiles = @($removedFiles)
        expectedFailedReasonSubstrings = @($ExpectedFailedReasonSubstrings)
        matchedExpectedFailedReasonSubstrings = @($matchedExpectedFailedReasons)
        releaseGateManifestPath = $scenarioGateManifestPath
        releaseGateStatus = [string]$scenarioGateManifest.status
        failedReasonCount = [int]$scenarioGateManifest.failedReasonCount
        failedReasons = @($failedReasons)
        releaseGateOutput = @($releaseGateOutput | ForEach-Object { [string]$_ })
        blockedAsExpected = ([string]$scenarioGateManifest.status -eq "BLOCKED" -and [int]$scenarioGateManifest.failedReasonCount -gt 0 -and $expectedFailedReasonsMatched)
    }
}

function Invoke-ExtraSourceManifestScenario {
    param([string]$Name)

    $scenarioDir = Join-Path $ProbeBundleDir $Name
    New-Item -ItemType Directory -Force $scenarioDir | Out-Null
    Copy-Item -Path (Join-Path $EvidenceBundleDir "*") -Destination $scenarioDir -Recurse -Force

    $indexManifestPath = Join-Path $scenarioDir "release-evidence-index-manifest.json"
    $indexManifest = Get-Content -Path $indexManifestPath -Encoding UTF8 -Raw | ConvertFrom-Json
    $indexManifest.sourceManifestNames = @($indexManifest.sourceManifestNames) + "stale-extra-source-manifest.json"
    $indexManifest | ConvertTo-Json -Depth 12 | Set-Content -Path $indexManifestPath -Encoding UTF8

    $scenarioGateManifestPath = Join-Path $scenarioDir "release-gate-manifest.json"
    $releaseGateOutput = & $releaseGateScript `
        -EvidenceBundleDir $scenarioDir `
        -ReleaseGateManifestPath $scenarioGateManifestPath `
        -ExpectBlocked `
        -RequireProductionReplayDriverBound:$RequireProductionReplayDriverBound `
        -RequireProductionLuaPatched:$RequireProductionLuaPatched `
        -RequireLiveModelEndpointSmoke:$RequireLiveModelEndpointSmoke

    $scenarioGateManifest = Get-Content -Path $scenarioGateManifestPath -Encoding UTF8 -Raw | ConvertFrom-Json
    $failedReasons = @($scenarioGateManifest.failedReasons | ForEach-Object { [string]$_ })
    $coverageReasonMatched = @($failedReasons | Where-Object { $_.Contains("release_evidence_index_primary_manifest_coverage") }).Count -gt 0
    return [ordered]@{
        name = $Name
        addedSourceManifestName = "stale-extra-source-manifest.json"
        releaseGateManifestPath = $scenarioGateManifestPath
        releaseGateStatus = [string]$scenarioGateManifest.status
        failedReasonCount = [int]$scenarioGateManifest.failedReasonCount
        failedReasons = @($failedReasons)
        releaseGateOutput = @($releaseGateOutput | ForEach-Object { [string]$_ })
        blockedAsExpected = ([string]$scenarioGateManifest.status -eq "BLOCKED" -and [int]$scenarioGateManifest.failedReasonCount -gt 0 -and $coverageReasonMatched)
    }
}

$scenarioResults = @(
    (Invoke-MissingEvidenceScenario "missing-repair-driver-failure" @(
        "repair-driver-failure-manifest.json",
        "unity-repair-driver-failure.log"
    ) @(
        "file:repair-driver-failure-manifest.json"
    )),
    (Invoke-MissingEvidenceScenario "missing-canonical-action-queue" @(
        "production-external-evidence-action-queue-manifest.json"
    ) @(
        "file:production-external-evidence-action-queue-manifest.json"
    )),
    (Invoke-ExtraSourceManifestScenario "extra-release-evidence-index-source-manifest")
)

if (-not [bool]$RequireProductionReplayDriverBound) {
    $scenarioResults += Invoke-MissingEvidenceScenario `
        "missing-production-replay-bound-failure-source-manifest" `
        @("production-replay-driver-bound-failure-probe-manifest.json") `
        @(
            "file:production-replay-driver-bound-failure-probe-manifest.json",
            "release_evidence_index_primary_manifest_coverage"
        ) `
        @("production-replay-driver-bound-failure-probe-manifest.json")
}

if (-not [bool]$RequireProductionLuaPatched) {
    $scenarioResults += Invoke-MissingEvidenceScenario `
        "missing-production-lua-bound-failure-source-manifest" `
        @("production-lua-patch-bound-failure-probe-manifest.json") `
        @(
            "file:production-lua-patch-bound-failure-probe-manifest.json",
            "release_evidence_index_primary_manifest_coverage"
        ) `
        @("production-lua-patch-bound-failure-probe-manifest.json")
}

$failedScenarios = @($scenarioResults | Where-Object { -not [bool]$_["blockedAsExpected"] })
$manifestPath = Join-Path $ProbeBundleDir "release-gate-failure-probe-manifest.json"
$manifest = [ordered]@{
    schemaVersion = "aitestpilot.release_gate_failure_probe.v1"
    status = if ($failedScenarios.Count -eq 0) { "PASS" } else { "FAIL" }
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    scenarioCount = [int]$scenarioResults.Count
    failedScenarioCount = [int]$failedScenarios.Count
    scenarios = @($scenarioResults)
    files = @("release-gate-failure-probe-manifest.json")
}
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

if ($failedScenarios.Count -gt 0) {
    throw "Release gate failure probe did not block all scenarios: $($failedScenarios.name -join ', ')"
}

Write-Output "Release gate failure probe manifest: $manifestPath"
Write-Output "PASS AI TestPilot release gate failure probe"
