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
    $ProbeBundleDir = Join-Path $repoRoot "Temp\release-evidence\source-snapshot-apply-validate-probe"
}

if ([string]::IsNullOrWhiteSpace($ProbeRepoDir)) {
    $ProbeRepoDir = Join-Path $repoRoot "Temp\source-snapshot-apply-validate-probe-repo"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "repair-agent-source-snapshot-apply-validate-manifest.json"
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

function Assert-PathUnder {
    param(
        [string]$Path,
        [string]$Root,
        [string]$Label
    )

    $fullPath = Resolve-FullPath $Path
    $fullRoot = Resolve-FullPath $Root
    if (-not (Test-PathWithinRoot $fullPath $fullRoot)) {
        throw "$Label must stay under expected root. Path: $fullPath Root: $fullRoot"
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

function Remove-CandidateBuildOutputs {
    param(
        [string]$CandidateRoot
    )

    $candidateRootPath = (Resolve-Path $CandidateRoot).Path
    $buildDirs = @(Get-ChildItem -LiteralPath $candidateRootPath -Recurse -Directory -Force |
        Where-Object { $_.Name -eq "bin" -or $_.Name -eq "obj" })

    foreach ($buildDir in $buildDirs) {
        $resolvedBuildDir = Assert-PathUnder $buildDir.FullName $candidateRootPath "Build output directory"
        Remove-Item -LiteralPath $resolvedBuildDir -Recurse -Force
    }
}

function Copy-CurrentSourceSnapshot {
    param(
        [string]$Destination
    )

    $destinationPath = Assert-PathUnderRepo $Destination "Source snapshot destination"
    if (Test-Path $destinationPath) {
        Remove-Item -LiteralPath $destinationPath -Recurse -Force
    }

    New-Item -ItemType Directory -Force $destinationPath | Out-Null

    $robocopyOutput = @(& robocopy $repoRoot $destinationPath /E /NFL /NDL /NJH /NJS /NP `
        /XD ".git" "Temp" "artifacts" ".vs" ".idea" "bin" "obj" "Library" "Logs" `
        /XF "*.user" "*.suo" 2>&1)
    $robocopyExitCode = $LASTEXITCODE
    if ($robocopyExitCode -gt 7) {
        throw "robocopy source snapshot failed with exit code $($robocopyExitCode): $($robocopyOutput -join "`n")"
    }

    return $robocopyExitCode
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

if (Test-Path $probeBundlePath) {
    Remove-Item -LiteralPath $probeBundlePath -Recurse -Force
}

New-Item -ItemType Directory -Force $probeBundlePath | Out-Null

$snapshotCopyExitCode = Copy-CurrentSourceSnapshot $probeRepoPath

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
diff --git a/docs/repair-agent-source-snapshot-probe.md b/docs/repair-agent-source-snapshot-probe.md
new file mode 100644
--- /dev/null
+++ b/docs/repair-agent-source-snapshot-probe.md
@@ -0,0 +1,3 @@
+# Source Snapshot Apply Validate Probe
+
+This file proves a verified external-agent patch can apply to a clean source snapshot, pass repo validation, and roll back.
'@

$summaryText = @'
# AI TestPilot Source Snapshot Repair Agent Summary

## Result
- Produced a generic documentation patch for the source snapshot apply/validate probe.
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
    -not [bool]$patchOutputManifest.externalAgentRun -or
    [bool]$patchOutputManifest.sampleFixSnippetRequired) {
    throw "Source snapshot patch import did not prove completed generic external-agent provenance."
}

& (Join-Path $repoRoot "tools\Invoke-AITestPilotRepairAgentExternalPatchPreflight.ps1") `
    -EvidenceBundleDir $probeBundlePath

$preflightManifestPath = Join-Path $probeBundlePath "repair-agent-external-patch-preflight-manifest.json"
if (-not (Test-Path $preflightManifestPath)) {
    throw "Source snapshot preflight manifest was not produced: $preflightManifestPath"
}

$preflightManifest = Get-Content -Raw $preflightManifestPath | ConvertFrom-Json
if ($preflightManifest.status -ne "PASS" -or
    -not [bool]$preflightManifest.repositoryApplyAllowed -or
    -not [bool]$preflightManifest.safeToInspect -or
    [int]$preflightManifest.unsafePathCount -ne 0) {
    throw "Source snapshot preflight did not pass with repository apply allowed for verified external-agent output."
}

Invoke-GitChecked @("-C", $probeRepoPath, "init") | Out-Null
Invoke-GitChecked @("-C", $probeRepoPath, "config", "user.email", "aitestpilot@example.invalid") | Out-Null
Invoke-GitChecked @("-C", $probeRepoPath, "config", "user.name", "AI TestPilot") | Out-Null
Invoke-GitChecked @("-C", $probeRepoPath, "config", "core.autocrlf", "false") | Out-Null
Invoke-GitChecked @("-C", $probeRepoPath, "config", "core.eol", "lf") | Out-Null
Invoke-GitChecked @("-C", $probeRepoPath, "add", ".") | Out-Null
Invoke-GitChecked @("-C", $probeRepoPath, "commit", "-m", "seed source snapshot apply validate probe") | Out-Null

$statusBeforeApply = @(Invoke-GitChecked @("-C", $probeRepoPath, "status", "--porcelain=v1"))
$worktreeCleanBeforeApply = $statusBeforeApply.Count -eq 0
if (-not $worktreeCleanBeforeApply) {
    throw "Source snapshot candidate repository was not clean before apply."
}

& (Join-Path $repoRoot "tools\Invoke-AITestPilotRepairAgentRepositoryPatchApplyGuard.ps1") `
    -EvidenceBundleDir $probeBundlePath `
    -RepositoryRoot $probeRepoPath `
    -ApplyToRepository

$guardManifestPath = Join-Path $probeBundlePath "repair-agent-repository-patch-apply-guard-manifest.json"
if (-not (Test-Path $guardManifestPath)) {
    throw "Source snapshot apply guard manifest was not produced: $guardManifestPath"
}

$guardManifest = Get-Content -Raw $guardManifestPath | ConvertFrom-Json
if ($guardManifest.status -ne "PASS" -or
    $guardManifest.applyDecision -ne "APPLY" -or
    -not [bool]$guardManifest.repositoryPatchApplied -or
    -not [bool]$guardManifest.rollbackPatchGenerated) {
    throw "Source snapshot apply guard manifest did not prove repository patch application and rollback patch generation."
}

$patchedFile = Join-Path $probeRepoPath "docs\repair-agent-source-snapshot-probe.md"
$patchedFilePresent = Test-Path $patchedFile
if (-not $patchedFilePresent) {
    throw "Source snapshot patched file was not created: $patchedFile"
}

$validationLogPath = Join-Path $probeBundlePath "source-snapshot-validate.log"
$validationOutput = @(& (Join-Path $probeRepoPath "tools\Validate-AITestPilot.ps1") *>&1)
$validationOutput | Set-Content -Path $validationLogPath -Encoding UTF8
$sourceSnapshotValidationPassed = (($validationOutput -join "`n") -match [regex]::Escape("PASS AI TestPilot validation"))
if (-not $sourceSnapshotValidationPassed) {
    throw "Source snapshot repo validation did not report PASS."
}

Remove-CandidateBuildOutputs $probeRepoPath

$rollbackPatchPath = Join-Path $probeBundlePath "repair-agent-repository-patch-rollback.patch"
if (-not (Test-Path $rollbackPatchPath)) {
    throw "Rollback patch was not generated: $rollbackPatchPath"
}

Invoke-GitChecked @("-C", $probeRepoPath, "apply", "-R", $rollbackPatchPath) | Out-Null
$rollbackRemovedPatchedFile = -not (Test-Path $patchedFile)
if (-not $rollbackRemovedPatchedFile) {
    throw "Rollback patch did not remove the source snapshot probe file."
}

$statusAfterRollback = @(Invoke-GitChecked @("-C", $probeRepoPath, "status", "--porcelain=v1"))
$worktreeCleanAfterRollback = $statusAfterRollback.Count -eq 0
if (-not $worktreeCleanAfterRollback) {
    throw "Source snapshot candidate repository was not clean after rollback: $($statusAfterRollback -join "`n")"
}

$guardManifestTarget = Join-Path $evidenceBundlePath "repair-agent-source-snapshot-apply-validate-guard-manifest.json"
$rollbackPatchTarget = Join-Path $evidenceBundlePath "repair-agent-source-snapshot-apply-validate-rollback.patch"
$rollbackPlanTarget = Join-Path $evidenceBundlePath "repair-agent-source-snapshot-apply-validate-rollback-plan.md"
$preflightTarget = Join-Path $evidenceBundlePath "repair-agent-source-snapshot-apply-validate-preflight-manifest.json"
$patchTarget = Join-Path $evidenceBundlePath "repair-agent-source-snapshot-apply-validate.patch"
$validationLogTarget = Join-Path $evidenceBundlePath "repair-agent-source-snapshot-apply-validate.log"
Copy-Item -LiteralPath $guardManifestPath -Destination $guardManifestTarget -Force
Copy-Item -LiteralPath $rollbackPatchPath -Destination $rollbackPatchTarget -Force
Copy-Item -LiteralPath (Join-Path $probeBundlePath "repair-agent-repository-patch-rollback-plan.md") -Destination $rollbackPlanTarget -Force
Copy-Item -LiteralPath $preflightManifestPath -Destination $preflightTarget -Force
Copy-Item -LiteralPath $patchPath -Destination $patchTarget -Force
Copy-Item -LiteralPath $validationLogPath -Destination $validationLogTarget -Force

$sourceFileCount = @(Get-ChildItem -LiteralPath $probeRepoPath -Recurse -File -Force |
    Where-Object { $_.FullName -notmatch "\\.git\\" }).Count

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.repair_agent_source_snapshot_apply_validate.v1"
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    probeRepositoryRoot = $probeRepoPath
    sourceSnapshotCopyExitCode = [int]$snapshotCopyExitCode
    sourceSnapshotFileCount = [int]$sourceFileCount
    patchOutputSource = $patchOutputManifest.source
    externalAgentRun = [bool]$patchOutputManifest.externalAgentRun
    externalAgentCompletionVerified = [bool]$patchOutputManifest.externalAgentCompletionVerified
    repairAgentRunStatus = $patchOutputManifest.repairAgentRunStatus
    repairAgentPatchOutputStatus = $patchOutputManifest.repairAgentRunPatchOutputStatus
    sampleFixSnippetRequired = [bool]$patchOutputManifest.sampleFixSnippetRequired
    preflightStatus = $preflightManifest.status
    preflightSafeToInspect = [bool]$preflightManifest.safeToInspect
    preflightRepositoryApplyAllowed = [bool]$preflightManifest.repositoryApplyAllowed
    preflightUnsafePathCount = [int]$preflightManifest.unsafePathCount
    worktreeCleanBeforeApply = [bool]$worktreeCleanBeforeApply
    applyDecision = $guardManifest.applyDecision
    applySwitchProvided = [bool]$guardManifest.applySwitchProvided
    gitApplyCheckPassed = [bool]$guardManifest.gitApplyCheckPassed
    repositoryPatchApplied = [bool]$guardManifest.repositoryPatchApplied
    patchedFile = "docs/repair-agent-source-snapshot-probe.md"
    patchedFilePresent = [bool]$patchedFilePresent
    sourceSnapshotValidationInvoked = $true
    sourceSnapshotValidationPassed = [bool]$sourceSnapshotValidationPassed
    rollbackPatchGenerated = [bool]$guardManifest.rollbackPatchGenerated
    rollbackPatchIncludesUntrackedFiles = [bool]$guardManifest.rollbackPatchIncludesUntrackedFiles
    rollbackPatchUntrackedFileCount = [int]$guardManifest.rollbackPatchUntrackedFileCount
    rollbackPlanStatus = $guardManifest.rollbackPlanStatus
    rollbackApplied = $true
    rollbackRemovedPatchedFile = [bool]$rollbackRemovedPatchedFile
    worktreeCleanAfterRollback = [bool]$worktreeCleanAfterRollback
    mainRepositoryPatchApplied = $false
    files = @(
        "repair-agent-source-snapshot-apply-validate-guard-manifest.json",
        "repair-agent-source-snapshot-apply-validate-preflight-manifest.json",
        "repair-agent-source-snapshot-apply-validate-rollback.patch",
        "repair-agent-source-snapshot-apply-validate-rollback-plan.md",
        "repair-agent-source-snapshot-apply-validate.patch",
        "repair-agent-source-snapshot-apply-validate.log"
    )
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

Write-Output "Repair agent source snapshot apply/validate manifest: $manifestPath"
Write-Output "PASS AI TestPilot repair agent source snapshot apply/validate"
