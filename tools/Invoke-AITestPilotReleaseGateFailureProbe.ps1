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

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ProbeBundleDir)) {
    $ProbeBundleDir = Join-Path $repoRoot "Temp\release-evidence\release-gate-failure-probe"
}

$resolvedRepoRoot = (Resolve-Path $repoRoot).Path
$resolvedProbeParent = Split-Path $ProbeBundleDir -Parent
New-Item -ItemType Directory -Force $resolvedProbeParent | Out-Null
$resolvedProbeParent = (Resolve-Path $resolvedProbeParent).Path
$fullProbePath = [System.IO.Path]::GetFullPath($ProbeBundleDir)
if (-not $fullProbePath.StartsWith($resolvedRepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Probe bundle path must stay under repo root: $fullProbePath"
}

if (Test-Path $ProbeBundleDir) {
    Remove-Item -LiteralPath $ProbeBundleDir -Recurse -Force
}

New-Item -ItemType Directory -Force $ProbeBundleDir | Out-Null

$releaseGateScript = Join-Path $PSScriptRoot "Invoke-AITestPilotReleaseGate.ps1"

function Invoke-MissingEvidenceScenario {
    param(
        [string]$Name,
        [string[]]$RelativePaths,
        [string[]]$ExpectedFailedReasonSubstrings
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
    ))
)

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
