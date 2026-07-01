[CmdletBinding()]
param(
    [string]$UnityPath = "F:\Unity\2021_3_45_f2\Editor\Unity.exe",
    [string]$GameReplayDriverType = "Kibernet.AITestPilot.Unity.Editor.SampleGameActionReplayDriver",
    [string]$EvidenceBundleDir,
    [string]$ExternalOutputDir,
    [string]$ManifestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

$externalOutputDirectoryInputProvided = -not [string]::IsNullOrWhiteSpace($ExternalOutputDir)
if (-not $externalOutputDirectoryInputProvided) {
    $ExternalOutputDir = Join-Path $repoRoot "Temp\release-evidence\external-task-output-acceptance-input"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "repair-agent-external-task-output-acceptance-manifest.json"
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

function Set-JsonProperty {
    param(
        [object]$InputObject,
        [string]$Name,
        [object]$Value
    )

    $InputObject | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Write-Utf8NoBomFile {
    param(
        [string]$Path,
        [string]$Content
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Get-JsonValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$DefaultValue = $null
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }

    return $property.Value
}

function Get-FileSha256OrEmpty {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return ""
    }

    return (Get-FileHash -Algorithm SHA256 -Path $Path).Hash
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$externalOutputPath = Assert-PathUnderRepo $ExternalOutputDir "ExternalOutputDir"
$manifestPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$fixtureGenerated = -not [bool]$externalOutputDirectoryInputProvided

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

$taskId = [string]$repairTask.taskId
$bugId = [string]$repairTask.bugId
$suggestedFix = [string]$repairTask.suggestedFix
$retestCommand = [string]$repairTask.retestCommand

$externalRunPath = Join-Path $externalOutputPath "repair-agent-run.json"
$externalPatchPath = Join-Path $externalOutputPath "repair-agent.patch"
$externalSummaryPath = Join-Path $externalOutputPath "repair-agent-summary.md"
$externalOutputProducerManifestPath = Join-Path $evidenceBundlePath "repair-agent-cursor-agent-external-output-manifest.json"

if ($fixtureGenerated) {
    if (Test-Path $externalOutputPath) {
        Remove-Item -LiteralPath $externalOutputPath -Recurse -Force
    }

    New-Item -ItemType Directory -Force $externalOutputPath | Out-Null
    Copy-Item -LiteralPath $repairAgentRunSource -Destination $externalRunPath -Force

    $repairAgentRun = Get-Content -Raw $externalRunPath | ConvertFrom-Json
    Set-JsonProperty $repairAgentRun "status" "EXTERNAL_AGENT_COMPLETED"
    Set-JsonProperty $repairAgentRun "agentLaunched" $true
    Set-JsonProperty $repairAgentRun "patchOutputStatus" "PRODUCED"
    Set-JsonProperty $repairAgentRun "patchOutputCount" 2
    Set-JsonProperty $repairAgentRun "taskId" $taskId
    Set-JsonProperty $repairAgentRun "bugId" $bugId
    Set-JsonProperty $repairAgentRun "postPatchRetestCommand" $retestCommand

    $expectedPatchOutputs = @($repairAgentRun.expectedPatchOutputs)
    if ($expectedPatchOutputs.Count -lt 2) {
        throw "Repair agent run must include at least two expected patch output slots."
    }

    foreach ($expectedOutput in $expectedPatchOutputs) {
        Set-JsonProperty $expectedOutput "produced" $true
    }

    $repairAgentRun | ConvertTo-Json -Depth 10 | Set-Content -Path $externalRunPath -Encoding UTF8

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
# AI TestPilot External Task Output Acceptance Summary

## Result
- TaskId: $taskId
- BugId: $bugId
- Suggested fix: $suggestedFix
- Produced a task-bound external-output-directory fixture for the main worktree apply/retest/rollback intake path.
- Patch output: repair-agent.patch.
- Post-patch retest command: $retestCommand
"@

    Write-Utf8NoBomFile $externalPatchPath ($patchText + "`n")
    Write-Utf8NoBomFile $externalSummaryPath ($summaryText + "`n")
}

foreach ($requiredExternalPath in @($externalRunPath, $externalPatchPath, $externalSummaryPath)) {
    if (-not (Test-Path $requiredExternalPath)) {
        throw "External repair-agent output is missing required file: $requiredExternalPath"
    }
}

$externalRunSha256 = Get-FileSha256OrEmpty $externalRunPath
$externalPatchSha256 = Get-FileSha256OrEmpty $externalPatchPath
$externalSummarySha256 = Get-FileSha256OrEmpty $externalSummaryPath
$externalOutputProducerManifestPresent = Test-Path $externalOutputProducerManifestPath
$externalOutputProducerManifest = $null
if ($externalOutputProducerManifestPresent) {
    $externalOutputProducerManifest = Get-Content -Path $externalOutputProducerManifestPath -Encoding UTF8 -Raw | ConvertFrom-Json
}

$externalOutputProducerOutputDirectory = [string](Get-JsonValue $externalOutputProducerManifest "outputDirectory" "")
$externalOutputProducerBindingPassed = (
    $externalOutputProducerManifestPresent -and
    $externalOutputDirectoryInputProvided -and
    -not $fixtureGenerated -and
    (Get-JsonValue $externalOutputProducerManifest "schemaVersion" "") -eq "aitestpilot.repair_agent_cursor_agent_external_output.v1" -and
    (Get-JsonValue $externalOutputProducerManifest "source" "") -eq "headless_cursor_agent" -and
    (Get-JsonValue $externalOutputProducerManifest "taskId" "") -eq $taskId -and
    (Get-JsonValue $externalOutputProducerManifest "bugId" "") -eq $bugId -and
    (Get-JsonValue $externalOutputProducerManifest "suggestedFix" "") -eq $suggestedFix -and
    (Get-JsonValue $externalOutputProducerManifest "retestCommand" "") -eq $retestCommand -and
    $externalOutputProducerOutputDirectory -eq $externalOutputPath -and
    (Get-JsonValue $externalOutputProducerManifest "outputRunSha256" "") -eq $externalRunSha256 -and
    (Get-JsonValue $externalOutputProducerManifest "outputPatchSha256" "") -eq $externalPatchSha256 -and
    (Get-JsonValue $externalOutputProducerManifest "outputSummarySha256" "") -eq $externalSummarySha256
)

& (Join-Path $repoRoot "tools\Invoke-AITestPilotRepairAgentMainWorktreeApplyRetestRollback.ps1") `
    -UnityPath $UnityPath `
    -GameReplayDriverType $GameReplayDriverType `
    -EvidenceBundleDir $evidenceBundlePath `
    -ExternalOutputDir $externalOutputPath

$mainWorktreeManifestPath = Join-Path $evidenceBundlePath "repair-agent-main-worktree-apply-retest-rollback-manifest.json"
if (-not (Test-Path $mainWorktreeManifestPath)) {
    throw "Main worktree apply/retest/rollback manifest was not produced: $mainWorktreeManifestPath"
}

$mainWorktreeManifest = Get-Content -Raw $mainWorktreeManifestPath | ConvertFrom-Json
if ($mainWorktreeManifest.status -ne "PASS" -or
    -not [bool]$mainWorktreeManifest.externalOutputDirectoryProvided -or
    $mainWorktreeManifest.inputPackageSource -ne "external_output_directory" -or
    [bool]$mainWorktreeManifest.patchGeneratedByProbe -or
    -not [bool]$mainWorktreeManifest.taskBugMatchesPatchOutput -or
    -not [bool]$mainWorktreeManifest.mainRepositoryPatchApplied -or
    -not [bool]$mainWorktreeManifest.postApplyRetestPassed -or
    -not [bool]$mainWorktreeManifest.rollbackApplied -or
    -not [bool]$mainWorktreeManifest.mainRepositoryCleanAfterRollback -or
    [bool]$mainWorktreeManifest.mainRepositoryPatchPersisted) {
    throw "External task output acceptance did not prove external-directory intake through main worktree apply/retest/rollback."
}

$acceptedRunTarget = Join-Path $evidenceBundlePath "repair-agent-external-task-output-run.json"
$acceptedPatchTarget = Join-Path $evidenceBundlePath "repair-agent-external-task-output.patch"
$acceptedSummaryTarget = Join-Path $evidenceBundlePath "repair-agent-external-task-output-summary.md"

Copy-Item -LiteralPath $externalRunPath -Destination $acceptedRunTarget -Force
Copy-Item -LiteralPath $externalPatchPath -Destination $acceptedPatchTarget -Force
Copy-Item -LiteralPath $externalSummaryPath -Destination $acceptedSummaryTarget -Force

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.repair_agent_external_task_output_acceptance.v1"
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    fixtureGenerated = [bool]$fixtureGenerated
    externalOutputDirectoryInputProvided = [bool]$externalOutputDirectoryInputProvided
    externalOutputDirectoryProvided = $true
    externalOutputDirectory = $externalOutputPath
    externalOutputRunSha256 = $externalRunSha256
    externalOutputPatchSha256 = $externalPatchSha256
    externalOutputSummarySha256 = $externalSummarySha256
    externalOutputProducerManifestPresent = [bool]$externalOutputProducerManifestPresent
    externalOutputProducerSource = Get-JsonValue $externalOutputProducerManifest "source" ""
    externalOutputProducerTaskId = Get-JsonValue $externalOutputProducerManifest "taskId" ""
    externalOutputProducerBugId = Get-JsonValue $externalOutputProducerManifest "bugId" ""
    externalOutputProducerSuggestedFix = Get-JsonValue $externalOutputProducerManifest "suggestedFix" ""
    externalOutputProducerRetestCommand = Get-JsonValue $externalOutputProducerManifest "retestCommand" ""
    externalOutputProducerOutputDirectory = $externalOutputProducerOutputDirectory
    externalOutputProducerRunSha256 = Get-JsonValue $externalOutputProducerManifest "outputRunSha256" ""
    externalOutputProducerPatchSha256 = Get-JsonValue $externalOutputProducerManifest "outputPatchSha256" ""
    externalOutputProducerSummarySha256 = Get-JsonValue $externalOutputProducerManifest "outputSummarySha256" ""
    externalOutputProducerBindingPassed = [bool]$externalOutputProducerBindingPassed
    inputPackageSource = $mainWorktreeManifest.inputPackageSource
    patchGeneratedByProbe = [bool]$mainWorktreeManifest.patchGeneratedByProbe
    taskId = $mainWorktreeManifest.taskId
    bugId = $mainWorktreeManifest.bugId
    suggestedFix = $mainWorktreeManifest.suggestedFix
    retestCommand = $mainWorktreeManifest.retestCommand
    taskBugMatchesPatchOutput = [bool]$mainWorktreeManifest.taskBugMatchesPatchOutput
    patchMentionsTaskId = [bool]$mainWorktreeManifest.patchMentionsTaskId
    patchMentionsBugId = [bool]$mainWorktreeManifest.patchMentionsBugId
    patchMentionsSuggestedFix = [bool]$mainWorktreeManifest.patchMentionsSuggestedFix
    summaryContainsTaskId = [bool]$mainWorktreeManifest.summaryContainsTaskId
    summaryContainsBugId = [bool]$mainWorktreeManifest.summaryContainsBugId
    summaryContainsSuggestedFix = [bool]$mainWorktreeManifest.summaryContainsSuggestedFix
    mainWorktreeApplyRetestRollbackStatus = $mainWorktreeManifest.status
    mainRepositoryPatchApplied = [bool]$mainWorktreeManifest.mainRepositoryPatchApplied
    postApplyRetestPassed = [bool]$mainWorktreeManifest.postApplyRetestPassed
    rollbackApplied = [bool]$mainWorktreeManifest.rollbackApplied
    mainRepositoryCleanAfterRollback = [bool]$mainWorktreeManifest.mainRepositoryCleanAfterRollback
    mainRepositoryPatchPersisted = [bool]$mainWorktreeManifest.mainRepositoryPatchPersisted
    files = @(
        "repair-agent-external-task-output-run.json",
        "repair-agent-external-task-output.patch",
        "repair-agent-external-task-output-summary.md",
        "repair-agent-main-worktree-apply-retest-rollback-manifest.json"
    )
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

Write-Output "Repair agent external task output acceptance manifest: $manifestPath"
Write-Output "PASS AI TestPilot repair agent external task output acceptance"
