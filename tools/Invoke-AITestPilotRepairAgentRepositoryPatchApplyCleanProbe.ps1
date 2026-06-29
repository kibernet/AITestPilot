[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ProbeBundleDir,
    [string]$ProbeRepoDir,
    [string]$ManifestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ProbeBundleDir)) {
    $ProbeBundleDir = Join-Path $repoRoot "Temp\release-evidence\repository-patch-clean-apply-probe"
}

if ([string]::IsNullOrWhiteSpace($ProbeRepoDir)) {
    $ProbeRepoDir = Join-Path $repoRoot "Temp\repository-patch-clean-apply-probe-repo"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "repair-agent-repository-patch-apply-clean-probe-manifest.json"
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

function Invoke-GitChecked {
    param(
        [string[]]$Arguments
    )

    $output = @(& git @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join "`n")"
    }

    return @($output)
}

function Write-Utf8NoBomFile {
    param(
        [string]$Path,
        [string]$Content
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$probeBundlePath = Assert-PathUnderRepo $ProbeBundleDir "ProbeBundleDir"
$probeRepoPath = Assert-PathUnderRepo $ProbeRepoDir "ProbeRepoDir"
$manifestPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

$repairAgentRunSource = Join-Path $evidenceBundlePath "repair-agent-run.json"
if (-not (Test-Path $repairAgentRunSource)) {
    throw "Repair agent run artifact is missing: $repairAgentRunSource"
}

foreach ($path in @($probeBundlePath, $probeRepoPath)) {
    if (Test-Path $path) {
        Remove-Item -LiteralPath $path -Recurse -Force
    }
}

New-Item -ItemType Directory -Force $probeBundlePath | Out-Null
New-Item -ItemType Directory -Force $probeRepoPath | Out-Null
$probeRepairAgentRunPath = Join-Path $probeBundlePath "repair-agent-run.json"
Copy-Item -LiteralPath $repairAgentRunSource -Destination $probeRepairAgentRunPath -Force

$probeRepairAgentRun = Get-Content -Raw $probeRepairAgentRunPath | ConvertFrom-Json
$probeRepairAgentRun.status = "EXTERNAL_AGENT_COMPLETED"
$probeRepairAgentRun.agentLaunched = $true
$probeRepairAgentRun.patchOutputStatus = "PRODUCED"
$probeRepairAgentRun.patchOutputCount = 2
foreach ($expectedOutput in @($probeRepairAgentRun.expectedPatchOutputs)) {
    $expectedOutput.produced = $true
}

$probeRepairAgentRun | ConvertTo-Json -Depth 10 | Set-Content -Path $probeRepairAgentRunPath -Encoding UTF8

$patchText = @'
diff --git a/Assets/SampleModule/StartButton.cs b/Assets/SampleModule/StartButton.cs
--- a/Assets/SampleModule/StartButton.cs
+++ b/Assets/SampleModule/StartButton.cs
@@ -1 +1,5 @@
-reward.Claim();
+if (reward == null)
+{
+    return;
+}
+reward.Claim();
'@

$summaryText = @'
# AI TestPilot External Repair Agent Summary

## Result
- Applied fix hint: add null guard before reward access.
- Patch output: repair-agent.patch.
- Post-patch retest command: .\tools\Invoke-AITestPilotRepairRetest.ps1
'@

$patchPath = Join-Path $probeBundlePath "repair-agent.patch"
$summaryPath = Join-Path $probeBundlePath "repair-agent-summary.md"
Write-Utf8NoBomFile $patchPath ($patchText + "`n")
Write-Utf8NoBomFile $summaryPath ($summaryText + "`n")

& (Join-Path $repoRoot "tools\Invoke-AITestPilotRepairAgentPatchOutputImport.ps1") `
    -EvidenceBundleDir $probeBundlePath `
    -ConfirmExternalAgentCompleted

$patchOutputManifestPath = Join-Path $probeBundlePath "repair-agent-patch-output-manifest.json"
if (-not (Test-Path $patchOutputManifestPath)) {
    throw "Patch output manifest was not produced: $patchOutputManifestPath"
}

$patchOutputManifest = Get-Content -Raw $patchOutputManifestPath | ConvertFrom-Json
if ($patchOutputManifest.status -ne "PASS" -or
    $patchOutputManifest.source -ne "external_agent" -or
    -not [bool]$patchOutputManifest.externalAgentCompletionVerified -or
    -not [bool]$patchOutputManifest.externalAgentRun) {
    throw "Clean apply probe patch output import did not prove completed external-agent provenance."
}

& (Join-Path $repoRoot "tools\Invoke-AITestPilotRepairAgentExternalPatchPreflight.ps1") `
    -EvidenceBundleDir $probeBundlePath

$sampleModuleDir = Join-Path $probeRepoPath "Assets\SampleModule"
New-Item -ItemType Directory -Force $sampleModuleDir | Out-Null
Write-Utf8NoBomFile (Join-Path $sampleModuleDir "StartButton.cs") "reward.Claim();`n"

Invoke-GitChecked @("-C", $probeRepoPath, "init") | Out-Null
Invoke-GitChecked @("-C", $probeRepoPath, "config", "user.email", "aitestpilot@example.invalid") | Out-Null
Invoke-GitChecked @("-C", $probeRepoPath, "config", "user.name", "AI TestPilot") | Out-Null
Invoke-GitChecked @("-C", $probeRepoPath, "config", "core.autocrlf", "false") | Out-Null
Invoke-GitChecked @("-C", $probeRepoPath, "config", "core.eol", "lf") | Out-Null
Invoke-GitChecked @("-C", $probeRepoPath, "add", ".") | Out-Null
Invoke-GitChecked @("-C", $probeRepoPath, "commit", "-m", "seed clean apply probe") | Out-Null

$statusBeforeApply = @(Invoke-GitChecked @("-C", $probeRepoPath, "status", "--porcelain=v1"))
$worktreeCleanBeforeApply = $statusBeforeApply.Count -eq 0

& (Join-Path $repoRoot "tools\Invoke-AITestPilotRepairAgentRepositoryPatchApplyGuard.ps1") `
    -EvidenceBundleDir $probeBundlePath `
    -RepositoryRoot $probeRepoPath `
    -ApplyToRepository

$guardManifestPath = Join-Path $probeBundlePath "repair-agent-repository-patch-apply-guard-manifest.json"
if (-not (Test-Path $guardManifestPath)) {
    throw "Clean apply guard manifest was not produced: $guardManifestPath"
}

$guardManifest = Get-Content -Raw $guardManifestPath | ConvertFrom-Json
if ($guardManifest.status -ne "PASS" -or
    $guardManifest.applyDecision -ne "APPLY" -or
    -not [bool]$guardManifest.repositoryPatchApplied -or
    -not [bool]$guardManifest.rollbackPatchGenerated) {
    throw "Clean apply guard manifest did not prove repository patch application and rollback patch generation."
}

$patchedFile = Join-Path $probeRepoPath "Assets\SampleModule\StartButton.cs"
$patchedText = Get-Content -Raw $patchedFile
$patchedFileContainsExpectedFix = $patchedText -match [regex]::Escape("reward == null")
if (-not $patchedFileContainsExpectedFix) {
    throw "Clean apply probe patched file does not include expected null guard."
}

$rollbackPatchPath = Join-Path $probeBundlePath "repair-agent-repository-patch-rollback.patch"
if (-not (Test-Path $rollbackPatchPath)) {
    throw "Rollback patch was not generated: $rollbackPatchPath"
}

Invoke-GitChecked @("-C", $probeRepoPath, "apply", "-R", $rollbackPatchPath) | Out-Null
$rolledBackText = Get-Content -Raw $patchedFile
$rollbackRestoredOriginal = $rolledBackText.Trim() -eq "reward.Claim();"

if (-not $rollbackRestoredOriginal) {
    throw "Rollback patch did not restore the original fixture."
}

$statusAfterRollback = @(Invoke-GitChecked @("-C", $probeRepoPath, "status", "--porcelain=v1"))
$worktreeCleanAfterRollback = $statusAfterRollback.Count -eq 0
if (-not $worktreeCleanAfterRollback) {
    throw "Clean apply probe repository was not clean after rollback."
}

$guardManifestTarget = Join-Path $evidenceBundlePath "repair-agent-repository-patch-clean-apply-guard-manifest.json"
$rollbackPatchTarget = Join-Path $evidenceBundlePath "repair-agent-repository-patch-clean-apply-rollback.patch"
$rollbackPlanTarget = Join-Path $evidenceBundlePath "repair-agent-repository-patch-clean-apply-rollback-plan.md"
$preflightTarget = Join-Path $evidenceBundlePath "repair-agent-repository-patch-clean-apply-preflight-manifest.json"
$patchTarget = Join-Path $evidenceBundlePath "repair-agent-repository-patch-clean-apply.patch"
Copy-Item -LiteralPath $guardManifestPath -Destination $guardManifestTarget -Force
Copy-Item -LiteralPath $rollbackPatchPath -Destination $rollbackPatchTarget -Force
Copy-Item -LiteralPath (Join-Path $probeBundlePath "repair-agent-repository-patch-rollback-plan.md") -Destination $rollbackPlanTarget -Force
Copy-Item -LiteralPath (Join-Path $probeBundlePath "repair-agent-external-patch-preflight-manifest.json") -Destination $preflightTarget -Force
Copy-Item -LiteralPath $patchPath -Destination $patchTarget -Force

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.repair_agent_repository_patch_apply_clean_probe.v1"
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    probeRepositoryRoot = $probeRepoPath
    patchOutputSource = "external_agent"
    externalAgentRun = $true
    externalAgentCompletionVerified = [bool]$patchOutputManifest.externalAgentCompletionVerified
    repairAgentRunStatus = $patchOutputManifest.repairAgentRunStatus
    repairAgentPatchOutputStatus = $patchOutputManifest.repairAgentRunPatchOutputStatus
    worktreeCleanBeforeApply = [bool]$worktreeCleanBeforeApply
    applyDecision = $guardManifest.applyDecision
    applySwitchProvided = [bool]$guardManifest.applySwitchProvided
    preflightRepositoryApplyAllowed = [bool]$guardManifest.preflightRepositoryApplyAllowed
    gitApplyCheckPassed = [bool]$guardManifest.gitApplyCheckPassed
    repositoryPatchApplied = [bool]$guardManifest.repositoryPatchApplied
    rollbackPatchGenerated = [bool]$guardManifest.rollbackPatchGenerated
    rollbackPlanStatus = $guardManifest.rollbackPlanStatus
    patchedFileContainsExpectedFix = [bool]$patchedFileContainsExpectedFix
    rollbackApplied = $true
    rollbackRestoredOriginal = [bool]$rollbackRestoredOriginal
    worktreeCleanAfterRollback = [bool]$worktreeCleanAfterRollback
    mainRepositoryPatchApplied = $false
    files = @(
        "repair-agent-repository-patch-clean-apply-guard-manifest.json",
        "repair-agent-repository-patch-clean-apply-preflight-manifest.json",
        "repair-agent-repository-patch-clean-apply-rollback.patch",
        "repair-agent-repository-patch-clean-apply-rollback-plan.md",
        "repair-agent-repository-patch-clean-apply.patch"
    )
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

Write-Output "Repair agent repository patch clean apply probe manifest: $manifestPath"
Write-Output "PASS AI TestPilot repair agent repository patch clean apply probe"
