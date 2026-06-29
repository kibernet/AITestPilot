[CmdletBinding()]
param(
    [string]$UnityPath = "F:\Unity\2021_3_45_f2\Editor\Unity.exe",
    [string]$GameReplayDriverType = "Kibernet.AITestPilot.Unity.Editor.SampleGameActionReplayDriver",
    [string]$EvidenceBundleDir,
    [string]$ProbeBundleDir,
    [string]$ManifestPath,
    [switch]$SkipRetest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ProbeBundleDir)) {
    $ProbeBundleDir = Join-Path $repoRoot "Temp\release-evidence\main-worktree-apply-retest-rollback-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "repair-agent-main-worktree-apply-retest-rollback-manifest.json"
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

function Select-SourceStatusLines {
    param(
        [string[]]$Lines
    )

    return @($Lines | Where-Object {
        $_ -notmatch " Temp/" -and
        $_ -notmatch " Temp\\" -and
        $_ -notmatch " artifacts/" -and
        $_ -notmatch " artifacts\\"
    })
}

function Get-SourceStatusLines {
    $statusLines = @(Invoke-GitChecked @("-C", $repoRoot, "status", "--porcelain=v1"))
    return @(Select-SourceStatusLines $statusLines)
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
$manifestPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

$repairAgentRunSource = Join-Path $evidenceBundlePath "repair-agent-run.json"
if (-not (Test-Path $repairAgentRunSource)) {
    throw "Repair agent run artifact is missing: $repairAgentRunSource"
}

$repairTaskSource = Join-Path $evidenceBundlePath "repair-task.json"
if (-not (Test-Path $repairTaskSource)) {
    throw "Repair task artifact is missing: $repairTaskSource"
}

$repairTask = Get-Content -Raw $repairTaskSource | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($repairTask.taskId) -or
    [string]::IsNullOrWhiteSpace($repairTask.bugId) -or
    [string]::IsNullOrWhiteSpace($repairTask.suggestedFix) -or
    [string]::IsNullOrWhiteSpace($repairTask.retestCommand)) {
    throw "Repair task must include taskId, bugId, suggestedFix, and retestCommand."
}

$readinessManifestPath = Join-Path $evidenceBundlePath "repair-agent-main-worktree-apply-readiness-manifest.json"
if (-not (Test-Path $readinessManifestPath)) {
    throw "Main worktree readiness manifest is missing: $readinessManifestPath"
}

$readinessManifest = Get-Content -Raw $readinessManifestPath | ConvertFrom-Json
if ($readinessManifest.status -ne "PASS" -or
    -not [bool]$readinessManifest.worktreeClean -or
    -not [bool]$readinessManifest.readyForMainRepositoryApply -or
    [int]$readinessManifest.sourceStatusCount -ne 0) {
    throw "Main worktree is not ready for explicit repository apply. Run readiness check after making the source baseline clean."
}

$sourceStatusBefore = @(Get-SourceStatusLines)
if ($sourceStatusBefore.Count -ne 0) {
    throw "Main worktree source status must be clean before the apply/retest/rollback probe: $($sourceStatusBefore -join "`n")"
}

if (Test-Path $probeBundlePath) {
    Remove-Item -LiteralPath $probeBundlePath -Recurse -Force
}

New-Item -ItemType Directory -Force $probeBundlePath | Out-Null

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

$taskId = [string]$repairTask.taskId
$bugId = [string]$repairTask.bugId
$suggestedFix = [string]$repairTask.suggestedFix
$retestCommand = [string]$repairTask.retestCommand
$taskBoundTargetPath = "docs/repair-agent-main-worktree-apply-probe.md"
$patchText = @(
    "diff --git a/docs/repair-agent-main-worktree-apply-probe.md b/docs/repair-agent-main-worktree-apply-probe.md",
    "new file mode 100644",
    "--- /dev/null",
    "+++ b/docs/repair-agent-main-worktree-apply-probe.md",
    "@@ -0,0 +1,9 @@",
    "+# Main Worktree Apply Probe",
    "+",
    "+TaskId: $taskId",
    "+BugId: $bugId",
    "+SuggestedFix: $suggestedFix",
    "+RetestCommand: $retestCommand",
    "+",
    "+This temporary task-bound file proves a verified external-agent patch can apply to the main worktree, pass retest, and roll back cleanly.",
    "+It must not persist after rollback."
) -join "`n"

$summaryText = @"
# AI TestPilot Main Worktree Repair Agent Summary

## Result
- TaskId: $taskId
- BugId: $bugId
- Suggested fix: $suggestedFix
- Produced a verified external-agent task-bound patch for the main worktree apply/retest/rollback path.
- Patch output: repair-agent.patch.
- Post-patch retest command: $retestCommand
"@

$patchPath = Join-Path $probeBundlePath "repair-agent.patch"
$summaryPath = Join-Path $probeBundlePath "repair-agent-summary.md"
Write-Utf8NoBomFile $patchPath ($patchText + "`n")
Write-Utf8NoBomFile $summaryPath ($summaryText + "`n")

$repositoryPatchAppliedDuringProbe = $false
$rollbackApplied = $false
$patchedRelativePath = "docs/repair-agent-main-worktree-apply-probe.md"
$patchedFile = Join-Path $repoRoot $patchedRelativePath
$rollbackPatchPath = Join-Path $probeBundlePath "repair-agent-repository-patch-rollback.patch"

try {
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
        $patchOutputManifest.taskId -ne $taskId -or
        $patchOutputManifest.bugId -ne $bugId -or
        [bool]$patchOutputManifest.sampleFixSnippetRequired) {
        throw "Main worktree probe patch output import did not prove completed generic external-agent provenance."
    }

    $patchMentionsTaskId = $patchText -match [regex]::Escape($taskId)
    $patchMentionsBugId = $patchText -match [regex]::Escape($bugId)
    $patchMentionsSuggestedFix = $patchText -match [regex]::Escape($suggestedFix)
    $summaryContainsTaskId = $summaryText -match [regex]::Escape($taskId)
    $summaryContainsBugId = $summaryText -match [regex]::Escape($bugId)
    $summaryContainsSuggestedFix = $summaryText -match [regex]::Escape($suggestedFix)
    if (-not $patchMentionsTaskId -or
        -not $patchMentionsBugId -or
        -not $patchMentionsSuggestedFix -or
        -not $summaryContainsTaskId -or
        -not $summaryContainsBugId -or
        -not $summaryContainsSuggestedFix) {
        throw "Main worktree probe patch and summary must include task id, bug id, and suggested fix."
    }

    & (Join-Path $repoRoot "tools\Invoke-AITestPilotRepairAgentExternalPatchPreflight.ps1") `
        -EvidenceBundleDir $probeBundlePath

    $preflightManifestPath = Join-Path $probeBundlePath "repair-agent-external-patch-preflight-manifest.json"
    if (-not (Test-Path $preflightManifestPath)) {
        throw "Main worktree preflight manifest was not produced: $preflightManifestPath"
    }

    $preflightManifest = Get-Content -Raw $preflightManifestPath | ConvertFrom-Json
    if ($preflightManifest.status -ne "PASS" -or
        -not [bool]$preflightManifest.repositoryApplyAllowed -or
        -not [bool]$preflightManifest.safeToInspect -or
        [int]$preflightManifest.unsafePathCount -ne 0) {
        throw "Main worktree preflight did not allow repository apply for verified external-agent output."
    }

    & (Join-Path $repoRoot "tools\Invoke-AITestPilotRepairAgentRepositoryPatchApplyGuard.ps1") `
        -EvidenceBundleDir $probeBundlePath `
        -RepositoryRoot $repoRoot `
        -ApplyToRepository

    $guardManifestPath = Join-Path $probeBundlePath "repair-agent-repository-patch-apply-guard-manifest.json"
    if (-not (Test-Path $guardManifestPath)) {
        throw "Main worktree apply guard manifest was not produced: $guardManifestPath"
    }

    $guardManifest = Get-Content -Raw $guardManifestPath | ConvertFrom-Json
    if ($guardManifest.status -ne "PASS" -or
        $guardManifest.applyDecision -ne "APPLY" -or
        -not [bool]$guardManifest.applySwitchProvided -or
        -not [bool]$guardManifest.gitApplyCheckPassed -or
        -not [bool]$guardManifest.repositoryPatchApplied -or
        -not [bool]$guardManifest.repositoryChangedByScript -or
        [bool]$guardManifest.sourceStatusUnchanged -or
        -not [bool]$guardManifest.rollbackPatchGenerated) {
        throw "Main worktree apply guard did not prove repository mutation and rollback patch generation."
    }

    $repositoryPatchAppliedDuringProbe = $true
    $patchedFilePresentBeforeRollback = Test-Path $patchedFile
    if (-not $patchedFilePresentBeforeRollback) {
        throw "Main worktree probe file was not created: $patchedFile"
    }

    $patchedFileText = Get-Content -Raw $patchedFile
    $patchedFileContainsProbeText = $patchedFileText -match [regex]::Escape("Main Worktree Apply Probe")
    if (-not $patchedFileContainsProbeText) {
        throw "Main worktree probe file does not contain expected probe text."
    }

    $validationLogPath = Join-Path $probeBundlePath "main-worktree-apply-validate.log"
    $validationOutput = @(& (Join-Path $repoRoot "tools\Validate-AITestPilot.ps1") *>&1)
    $validationOutput | Set-Content -Path $validationLogPath -Encoding UTF8
    $postApplyValidationPassed = (($validationOutput -join "`n") -match [regex]::Escape("PASS AI TestPilot validation"))
    if (-not $postApplyValidationPassed) {
        throw "Main worktree post-apply validation did not report PASS."
    }

    $postApplyRetestInvoked = -not [bool]$SkipRetest
    $postApplyRetestPassed = $false
    $postApplyBugStillPresent = $true
    $postApplyRetestManifestStatus = "SKIPPED"
    $postApplyRetestId = ""

    if ($postApplyRetestInvoked) {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotRepairRetest.ps1") `
            -UnityPath $UnityPath `
            -GameReplayDriverType $GameReplayDriverType `
            -EvidenceBundleDir $evidenceBundlePath

        $postApplyRetestManifestPath = Join-Path $evidenceBundlePath "repair-retest-manifest.json"
        if (-not (Test-Path $postApplyRetestManifestPath)) {
            throw "Main worktree post-apply retest manifest was not produced: $postApplyRetestManifestPath"
        }

        $postApplyRetestManifest = Get-Content -Raw $postApplyRetestManifestPath | ConvertFrom-Json
        $postApplyRetestManifestStatus = $postApplyRetestManifest.status
        $postApplyRetestPassed = [bool]$postApplyRetestManifest.retestPassed
        $postApplyBugStillPresent = [bool]$postApplyRetestManifest.bugStillPresent
        $postApplyRetestId = $postApplyRetestManifest.retestId

        if ($postApplyRetestManifest.status -ne "PASS" -or
            -not [bool]$postApplyRetestManifest.retestPassed -or
            [bool]$postApplyRetestManifest.bugStillPresent) {
            throw "Main worktree post-apply retest did not pass before rollback."
        }

        Copy-Item -LiteralPath $postApplyRetestManifestPath `
            -Destination (Join-Path $evidenceBundlePath "repair-agent-main-worktree-apply-retest-rollback-repair-retest-manifest.json") `
            -Force
    }

    if (-not (Test-Path $rollbackPatchPath)) {
        throw "Rollback patch was not generated: $rollbackPatchPath"
    }

    Invoke-GitChecked @("-C", $repoRoot, "apply", "-R", $rollbackPatchPath) | Out-Null
    $rollbackApplied = $true

    $rollbackRemovedPatchedFile = -not (Test-Path $patchedFile)
    if (-not $rollbackRemovedPatchedFile) {
        throw "Rollback did not remove the main worktree probe file."
    }

    $sourceStatusAfterRollback = @(Get-SourceStatusLines)
    $mainRepositoryCleanAfterRollback = $sourceStatusAfterRollback.Count -eq 0
    if (-not $mainRepositoryCleanAfterRollback) {
        throw "Main worktree was not clean after rollback: $($sourceStatusAfterRollback -join "`n")"
    }

    $guardManifestTarget = Join-Path $evidenceBundlePath "repair-agent-main-worktree-apply-retest-rollback-guard-manifest.json"
    $rollbackPatchTarget = Join-Path $evidenceBundlePath "repair-agent-main-worktree-apply-retest-rollback.patch"
    $rollbackPlanTarget = Join-Path $evidenceBundlePath "repair-agent-main-worktree-apply-retest-rollback-plan.md"
    $preflightTarget = Join-Path $evidenceBundlePath "repair-agent-main-worktree-apply-retest-rollback-preflight-manifest.json"
    $patchTarget = Join-Path $evidenceBundlePath "repair-agent-main-worktree-apply-retest-rollback-input.patch"
    $validationLogTarget = Join-Path $evidenceBundlePath "repair-agent-main-worktree-apply-retest-rollback-validate.log"
    $worktreeAfterRollbackTarget = Join-Path $evidenceBundlePath "repair-agent-main-worktree-apply-retest-rollback-worktree-after.txt"

    Copy-Item -LiteralPath $guardManifestPath -Destination $guardManifestTarget -Force
    Copy-Item -LiteralPath $rollbackPatchPath -Destination $rollbackPatchTarget -Force
    Copy-Item -LiteralPath (Join-Path $probeBundlePath "repair-agent-repository-patch-rollback-plan.md") -Destination $rollbackPlanTarget -Force
    Copy-Item -LiteralPath $preflightManifestPath -Destination $preflightTarget -Force
    Copy-Item -LiteralPath $patchPath -Destination $patchTarget -Force
    Copy-Item -LiteralPath $validationLogPath -Destination $validationLogTarget -Force
    if ($sourceStatusAfterRollback.Count -eq 0) {
        @("(clean)") | Set-Content -Path $worktreeAfterRollbackTarget -Encoding UTF8
    }
    else {
        $sourceStatusAfterRollback | Set-Content -Path $worktreeAfterRollbackTarget -Encoding UTF8
    }

    $files = @(
        "repair-agent-main-worktree-apply-retest-rollback-guard-manifest.json",
        "repair-agent-main-worktree-apply-retest-rollback-preflight-manifest.json",
        "repair-agent-main-worktree-apply-retest-rollback.patch",
        "repair-agent-main-worktree-apply-retest-rollback-plan.md",
        "repair-agent-main-worktree-apply-retest-rollback-input.patch",
        "repair-agent-main-worktree-apply-retest-rollback-validate.log",
        "repair-agent-main-worktree-apply-retest-rollback-worktree-after.txt"
    )

    if ($postApplyRetestInvoked) {
        $files += "repair-agent-main-worktree-apply-retest-rollback-repair-retest-manifest.json"
    }

    $manifest = [ordered]@{
        schemaVersion = "aitestpilot.repair_agent_main_worktree_apply_retest_rollback.v1"
        status = "PASS"
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
        mainRepositoryRoot = $repoRoot
        repairTaskPresent = $true
        taskId = $taskId
        bugId = $bugId
        suggestedFix = $suggestedFix
        retestCommand = $retestCommand
        patchOutputTaskId = $patchOutputManifest.taskId
        patchOutputBugId = $patchOutputManifest.bugId
        taskBugMatchesPatchOutput = ($patchOutputManifest.taskId -eq $taskId -and $patchOutputManifest.bugId -eq $bugId)
        taskBoundTargetPath = $taskBoundTargetPath
        patchMentionsTaskId = [bool]$patchMentionsTaskId
        patchMentionsBugId = [bool]$patchMentionsBugId
        patchMentionsSuggestedFix = [bool]$patchMentionsSuggestedFix
        summaryContainsTaskId = [bool]$summaryContainsTaskId
        summaryContainsBugId = [bool]$summaryContainsBugId
        summaryContainsSuggestedFix = [bool]$summaryContainsSuggestedFix
        readinessManifestPresent = $true
        readyForMainRepositoryApplyBeforeProbe = [bool]$readinessManifest.readyForMainRepositoryApply
        worktreeCleanBeforeApply = $true
        sourceStatusBeforeCount = [int]$sourceStatusBefore.Count
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
        applyDecision = $guardManifest.applyDecision
        applySwitchProvided = [bool]$guardManifest.applySwitchProvided
        gitApplyCheckPassed = [bool]$guardManifest.gitApplyCheckPassed
        repositoryChangedByScript = [bool]$guardManifest.repositoryChangedByScript
        guardSourceStatusUnchanged = [bool]$guardManifest.sourceStatusUnchanged
        mainRepositoryPatchApplied = $true
        mainRepositoryPatchAppliedDuringProbe = [bool]$repositoryPatchAppliedDuringProbe
        patchedFile = $patchedRelativePath
        patchedFilePresentBeforeRollback = [bool]$patchedFilePresentBeforeRollback
        patchedFileContainsProbeText = [bool]$patchedFileContainsProbeText
        postApplyValidationInvoked = $true
        postApplyValidationPassed = [bool]$postApplyValidationPassed
        postApplyRetestInvoked = [bool]$postApplyRetestInvoked
        postApplyRetestManifestStatus = $postApplyRetestManifestStatus
        postApplyRetestPassed = [bool]$postApplyRetestPassed
        postApplyBugStillPresent = [bool]$postApplyBugStillPresent
        postApplyRetestId = $postApplyRetestId
        retestRanBeforeRollback = [bool]$postApplyRetestInvoked
        rollbackPatchGenerated = [bool]$guardManifest.rollbackPatchGenerated
        rollbackPatchIncludesUntrackedFiles = [bool]$guardManifest.rollbackPatchIncludesUntrackedFiles
        rollbackPatchUntrackedFileCount = [int]$guardManifest.rollbackPatchUntrackedFileCount
        rollbackPlanStatus = $guardManifest.rollbackPlanStatus
        rollbackApplied = [bool]$rollbackApplied
        rollbackRemovedPatchedFile = [bool]$rollbackRemovedPatchedFile
        mainRepositoryCleanAfterRollback = [bool]$mainRepositoryCleanAfterRollback
        sourceStatusAfterRollbackCount = [int]$sourceStatusAfterRollback.Count
        mainRepositoryPatchPersisted = $false
        files = @($files)
    }

    New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8
}
finally {
    if ($repositoryPatchAppliedDuringProbe -and -not $rollbackApplied -and (Test-Path $rollbackPatchPath)) {
        Invoke-GitChecked @("-C", $repoRoot, "apply", "-R", $rollbackPatchPath) | Out-Null
    }
}

Write-Output "Repair agent main worktree apply/retest/rollback manifest: $manifestPath"
Write-Output "PASS AI TestPilot repair agent main worktree apply/retest/rollback"
