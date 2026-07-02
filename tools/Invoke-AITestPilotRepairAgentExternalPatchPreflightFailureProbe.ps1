[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ProbeBundleDir,
    [string]$ManifestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Test-PathWithinRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root)
    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    if ($fullPath.Equals($fullRoot, $comparison)) {
        return $true
    }

    if (-not $fullRoot.EndsWith(([System.IO.Path]::DirectorySeparatorChar).ToString())) {
        $fullRoot = $fullRoot + [System.IO.Path]::DirectorySeparatorChar
    }

    return $fullPath.StartsWith($fullRoot, $comparison)
}

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ProbeBundleDir)) {
    $ProbeBundleDir = Join-Path $repoRoot "Temp\release-evidence\external-patch-preflight-failure-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "repair-agent-external-patch-preflight-failure-probe-manifest.json"
}

function Assert-PathUnderRepo {
    param(
        [string]$Path,
        [string]$Label
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-PathWithinRoot $fullPath $repoRoot)) {
        throw "$Label must stay under repo root: $fullPath"
    }

    return $fullPath
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

$unsafePatch = @'
diff --git a/../outside.txt b/../outside.txt
--- a/../outside.txt
+++ b/../outside.txt
@@ -1 +1 @@
-old
+new
'@

$unsafePatchPath = Join-Path $probeBundlePath "repair-agent.patch"
Set-Content -Path $unsafePatchPath -Value $unsafePatch -Encoding ASCII

$preflightScript = Join-Path $PSScriptRoot "Invoke-AITestPilotRepairAgentExternalPatchPreflight.ps1"
$unsafeManifestPath = Join-Path $probeBundlePath "repair-agent-external-patch-preflight-manifest.json"
$preflightFailed = $false
$preflightError = ""

try {
    & $preflightScript `
        -EvidenceBundleDir $probeBundlePath `
        -ManifestPath $unsafeManifestPath
}
catch {
    $preflightFailed = $true
    $preflightError = $_.Exception.Message
}

if (-not $preflightFailed) {
    throw "Expected unsafe external patch preflight to fail, but it passed."
}

if (-not (Test-Path $unsafeManifestPath)) {
    throw "Unsafe preflight manifest was not produced: $unsafeManifestPath"
}

$unsafeManifest = Get-Content -Raw $unsafeManifestPath | ConvertFrom-Json
if ($unsafeManifest.status -ne "FAIL" -or
    [int]$unsafeManifest.unsafePathCount -lt 1 -or
    [int]$unsafeManifest.failureReasonCount -lt 1) {
    throw "Unsafe preflight manifest did not record the expected failure."
}

$unsafePaths = @($unsafeManifest.pathChecks | Where-Object { $_.safetyStatus -ne "PASS" })
$pathTraversalFound = $false
foreach ($unsafePath in $unsafePaths) {
    if (@($unsafePath.reasons) -contains "path_traversal") {
        $pathTraversalFound = $true
    }
}

if (-not $pathTraversalFound) {
    throw "Unsafe preflight manifest did not record path_traversal."
}

$unsafeManifestTarget = Join-Path $evidenceBundlePath "repair-agent-external-patch-preflight-unsafe-manifest.json"
$unsafePatchTarget = Join-Path $evidenceBundlePath "repair-agent-external-patch-preflight-unsafe.patch"
Copy-Item -LiteralPath $unsafeManifestPath -Destination $unsafeManifestTarget -Force
Copy-Item -LiteralPath $unsafePatchPath -Destination $unsafePatchTarget -Force

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.repair_agent_external_patch_preflight_failure_probe.v1"
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    expectedFailure = $true
    preflightFailed = [bool]$preflightFailed
    preflightError = $preflightError
    unsafeManifestStatus = $unsafeManifest.status
    unsafePathCount = [int]$unsafeManifest.unsafePathCount
    failureReasonCount = [int]$unsafeManifest.failureReasonCount
    pathTraversalFound = [bool]$pathTraversalFound
    repositoryApplyAllowed = [bool]$unsafeManifest.repositoryApplyAllowed
    files = @(
        "repair-agent-external-patch-preflight-unsafe-manifest.json",
        "repair-agent-external-patch-preflight-unsafe.patch"
    )
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $manifestPath -Encoding UTF8

Write-Output "Repair agent external patch preflight failure probe manifest: $manifestPath"
Write-Output "PASS AI TestPilot repair agent external patch preflight failure probe"
