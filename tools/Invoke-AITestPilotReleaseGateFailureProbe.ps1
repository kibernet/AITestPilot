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
Copy-Item -Path (Join-Path $EvidenceBundleDir "*") -Destination $ProbeBundleDir -Force

$failureManifest = Join-Path $ProbeBundleDir "repair-driver-failure-manifest.json"
if (Test-Path $failureManifest) {
    Remove-Item -LiteralPath $failureManifest -Force
}

$failureLog = Join-Path $ProbeBundleDir "unity-repair-driver-failure.log"
if (Test-Path $failureLog) {
    Remove-Item -LiteralPath $failureLog -Force
}

$releaseGateScript = Join-Path $PSScriptRoot "Invoke-AITestPilotReleaseGate.ps1"
& $releaseGateScript `
    -EvidenceBundleDir $ProbeBundleDir `
    -ReleaseGateManifestPath (Join-Path $ProbeBundleDir "release-gate-manifest.json") `
    -ExpectBlocked `
    -RequireProductionReplayDriverBound:$RequireProductionReplayDriverBound `
    -RequireProductionLuaPatched:$RequireProductionLuaPatched `
    -RequireLiveModelEndpointSmoke:$RequireLiveModelEndpointSmoke
