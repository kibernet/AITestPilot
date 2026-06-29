[CmdletBinding()]
param(
    [string]$UnityPath = "F:\Unity\2021_3_45_f2\Editor\Unity.exe",
    [string]$GameReplayDriverType = "Kibernet.AITestPilot.Unity.Editor.SampleGameActionReplayDriver",
    [string]$EvidenceBundleDir,
    [string]$PatchOutputManifestPath,
    [string]$ManifestPath,
    [switch]$SkipRetest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($PatchOutputManifestPath)) {
    $PatchOutputManifestPath = Join-Path $EvidenceBundleDir "repair-agent-patch-output-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "repair-agent-patch-apply-retest-manifest.json"
}

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

function Invoke-GitApply {
    param(
        [string]$BundlePath,
        [string]$PatchFileName,
        [string]$DirectoryPrefix,
        [switch]$CheckOnly
    )

    $arguments = @(
        "-C",
        $BundlePath,
        "apply"
    )

    if ($CheckOnly) {
        $arguments += "--check"
    }

    $arguments += @(
        "--directory",
        $DirectoryPrefix,
        "--whitespace=nowarn",
        $PatchFileName
    )

    $output = & git @arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git apply failed: $($output -join "`n")"
    }
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$patchOutputManifestPath = Assert-PathUnderRepo $PatchOutputManifestPath "PatchOutputManifestPath"
$manifestPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"

if (-not (Test-Path $patchOutputManifestPath)) {
    throw "Repair-agent patch output manifest is missing: $patchOutputManifestPath"
}

$patchOutputManifest = Get-Content -Raw $patchOutputManifestPath | ConvertFrom-Json
if ($patchOutputManifest.schemaVersion -ne "aitestpilot.repair_agent_patch_output.v1") {
    throw "Unexpected patch output manifest schema: $($patchOutputManifest.schemaVersion)"
}

if ($patchOutputManifest.status -ne "PASS") {
    throw "Patch output manifest must pass before apply/retest orchestration."
}

if ($patchOutputManifest.source -ne "deterministic_sample") {
    throw "This repo-side apply/retest proof only supports deterministic_sample patch output. Source: $($patchOutputManifest.source)"
}

if ([bool]$patchOutputManifest.externalAgentRun) {
    throw "Deterministic sample patch output must not claim an external agent ran."
}

if ($patchOutputManifest.postPatchRetestCommand -ne ".\tools\Invoke-AITestPilotRepairRetest.ps1") {
    throw "Unexpected post-patch retest command: $($patchOutputManifest.postPatchRetestCommand)"
}

$patchPath = Join-Path $evidenceBundlePath "repair-agent.patch"
$summaryPath = Join-Path $evidenceBundlePath "repair-agent-summary.md"
if (-not (Test-Path $patchPath)) {
    throw "Patch output file is missing: $patchPath"
}

if (-not (Test-Path $summaryPath)) {
    throw "Patch summary file is missing: $summaryPath"
}

$sandboxRelativePath = "repair-agent-patch-apply-sandbox"
$sandboxPath = Assert-PathUnderRepo (Join-Path $evidenceBundlePath $sandboxRelativePath) "SandboxPath"
if (-not $sandboxPath.StartsWith($evidenceBundlePath, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Sandbox path must stay under the evidence bundle: $sandboxPath"
}

if (Test-Path $sandboxPath) {
    Remove-Item -LiteralPath $sandboxPath -Recurse -Force
}

$sampleModuleDir = Join-Path $sandboxPath "Assets\SampleModule"
New-Item -ItemType Directory -Force $sampleModuleDir | Out-Null
$samplePatchedFile = Join-Path $sampleModuleDir "StartButton.cs"
Set-Content -Path $samplePatchedFile -Value "reward.Claim();" -Encoding ASCII

Invoke-GitApply `
    -BundlePath $evidenceBundlePath `
    -PatchFileName "repair-agent.patch" `
    -DirectoryPrefix $sandboxRelativePath `
    -CheckOnly

Invoke-GitApply `
    -BundlePath $evidenceBundlePath `
    -PatchFileName "repair-agent.patch" `
    -DirectoryPrefix $sandboxRelativePath

$patchedText = Get-Content -Raw $samplePatchedFile
$sandboxPatchedFileContainsExpectedFix = $patchedText -match [regex]::Escape("reward == null")
if (-not $sandboxPatchedFileContainsExpectedFix) {
    throw "Sandbox patched file does not include the expected null guard."
}

$repairRetestManifestPath = Join-Path $evidenceBundlePath "repair-retest-manifest.json"
if (-not $SkipRetest) {
    & (Join-Path $repoRoot "tools\Invoke-AITestPilotRepairRetest.ps1") `
        -UnityPath $UnityPath `
        -GameReplayDriverType $GameReplayDriverType `
        -EvidenceBundleDir $evidenceBundlePath
}

if (-not (Test-Path $repairRetestManifestPath)) {
    throw "Repair retest manifest is missing after post-patch retest orchestration: $repairRetestManifestPath"
}

$repairRetestManifest = Get-Content -Raw $repairRetestManifestPath | ConvertFrom-Json
if ($repairRetestManifest.status -ne "PASS" -or -not [bool]$repairRetestManifest.retestPassed) {
    throw "Post-patch retest did not pass."
}

if ([bool]$repairRetestManifest.bugStillPresent) {
    throw "Post-patch retest reports that the original bug is still present."
}

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.repair_agent_patch_apply_retest.v1"
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    patchOutputSource = $patchOutputManifest.source
    externalAgentRun = [bool]$patchOutputManifest.externalAgentRun
    patchApplicationMode = "sandbox"
    sandboxPatchApplied = $true
    repositoryPatchApplied = $false
    repositoryPatchAppliedReason = "Deterministic sample patch is applied only inside the evidence sandbox."
    sandboxRelativePath = $sandboxRelativePath
    sandboxPatchedFile = "repair-agent-patch-apply-sandbox/Assets/SampleModule/StartButton.cs"
    sandboxPatchedFileContainsExpectedFix = [bool]$sandboxPatchedFileContainsExpectedFix
    postPatchRetestCommand = $patchOutputManifest.postPatchRetestCommand
    postPatchRetestInvoked = -not [bool]$SkipRetest
    postPatchRetestManifestStatus = $repairRetestManifest.status
    postPatchRetestPassed = [bool]$repairRetestManifest.retestPassed
    postPatchBugStillPresent = [bool]$repairRetestManifest.bugStillPresent
    taskId = $patchOutputManifest.taskId
    bugId = $patchOutputManifest.bugId
    retestId = $repairRetestManifest.retestId
    files = @(
        "repair-agent-patch-output-manifest.json",
        "repair-agent.patch",
        "repair-agent-summary.md",
        "repair-retest-manifest.json",
        "repair-agent-patch-apply-sandbox/Assets/SampleModule/StartButton.cs"
    )
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $manifestPath -Encoding UTF8

Write-Output "Repair agent patch apply/retest manifest: $manifestPath"
Write-Output "PASS AI TestPilot repair agent patch apply/retest"
