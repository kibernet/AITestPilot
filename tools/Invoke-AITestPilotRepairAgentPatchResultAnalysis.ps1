[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ManifestPath,
    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "repair-agent-patch-result-analysis-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "repair-agent-patch-result-analysis.md"
}

function Resolve-FullPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Assert-PathUnderRepo {
    param(
        [string]$Path,
        [string]$Label
    )

    $fullPath = Resolve-FullPath $Path
    if (-not $fullPath.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must stay under repo root: $fullPath"
    }

    return $fullPath
}

function Read-RequiredJson {
    param(
        [string]$FileName,
        [string]$Label
    )

    $path = Join-Path $evidenceBundlePath $FileName
    if (-not (Test-Path $path)) {
        throw "$Label is missing: $path"
    }

    return Get-Content -Path $path -Encoding UTF8 -Raw | ConvertFrom-Json
}

function Test-TextContains {
    param(
        [string]$Text,
        [string]$Needle
    )

    if ([string]::IsNullOrWhiteSpace($Needle)) {
        return $false
    }

    return $Text.IndexOf($Needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

$bugPackage = Read-RequiredJson "bug-package.json" "Bug package"
$bugKnowledgeGraph = Read-RequiredJson "bug-knowledge-graph.json" "Bug knowledge graph"
$repairTask = Read-RequiredJson "repair-task.json" "Repair task"
$externalTaskAcceptance = Read-RequiredJson "repair-agent-external-task-output-acceptance-manifest.json" "External task output acceptance manifest"
$mainWorktreeApply = Read-RequiredJson "repair-agent-main-worktree-apply-retest-rollback-manifest.json" "Main worktree apply/retest/rollback manifest"

$acceptedPatchPath = Join-Path $evidenceBundlePath "repair-agent-external-task-output.patch"
$acceptedSummaryPath = Join-Path $evidenceBundlePath "repair-agent-external-task-output-summary.md"
if (-not (Test-Path $acceptedPatchPath)) {
    throw "Accepted repair-agent patch is missing: $acceptedPatchPath"
}

if (-not (Test-Path $acceptedSummaryPath)) {
    throw "Accepted repair-agent summary is missing: $acceptedSummaryPath"
}

$acceptedPatchText = Get-Content -Path $acceptedPatchPath -Encoding UTF8 -Raw
$acceptedSummaryText = Get-Content -Path $acceptedSummaryPath -Encoding UTF8 -Raw

$bugId = [string]$repairTask.bugId
$taskId = [string]$repairTask.taskId
$suggestedFix = [string]$repairTask.suggestedFix

$matchingGraphNodes = @($bugKnowledgeGraph.nodes | Where-Object {
    [string]$_.bugId -eq $bugId
})

$matchingFixHintNodes = @($matchingGraphNodes | Where-Object {
    [string]$_.fix -eq $suggestedFix
})

$priorFixHintMatched = $matchingFixHintNodes.Count -gt 0
$patchMentionsPriorFixHint = Test-TextContains $acceptedPatchText $suggestedFix
$summaryMentionsPriorFixHint = Test-TextContains $acceptedSummaryText $suggestedFix
$patchMentionsBugId = Test-TextContains $acceptedPatchText $bugId
$summaryMentionsBugId = Test-TextContains $acceptedSummaryText $bugId
$patchMentionsTaskId = Test-TextContains $acceptedPatchText $taskId
$summaryMentionsTaskId = Test-TextContains $acceptedSummaryText $taskId

$externalTaskResultAccepted =
    $externalTaskAcceptance.status -eq "PASS" -and
    $externalTaskAcceptance.inputPackageSource -eq "external_output_directory" -and
    -not [bool]$externalTaskAcceptance.patchGeneratedByProbe -and
    [bool]$externalTaskAcceptance.taskBugMatchesPatchOutput -and
    [bool]$externalTaskAcceptance.patchMentionsSuggestedFix -and
    [bool]$externalTaskAcceptance.summaryContainsSuggestedFix

$postApplyRetestPassed =
    $mainWorktreeApply.status -eq "PASS" -and
    [bool]$mainWorktreeApply.externalAgentRun -and
    [bool]$mainWorktreeApply.externalAgentCompletionVerified -and
    [bool]$mainWorktreeApply.mainRepositoryPatchApplied -and
    [bool]$mainWorktreeApply.postApplyRetestPassed -and
    -not [bool]$mainWorktreeApply.postApplyBugStillPresent -and
    [bool]$mainWorktreeApply.retestRanBeforeRollback

$rollbackVerified =
    [bool]$mainWorktreeApply.rollbackPatchGenerated -and
    [bool]$mainWorktreeApply.rollbackApplied -and
    [bool]$mainWorktreeApply.mainRepositoryCleanAfterRollback -and
    -not [bool]$mainWorktreeApply.mainRepositoryPatchPersisted

$knowledgeGraphResult = [ordered]@{
    bugId = $bugId
    priorFixHint = $suggestedFix
    priorFixHintMatched = [bool]$priorFixHintMatched
    matchingNodeCount = [int]$matchingGraphNodes.Count
    matchingFixHintNodeCount = [int]$matchingFixHintNodes.Count
    highRiskCount = [int]$bugKnowledgeGraph.highRiskCount
    module = [string]$bugPackage.module
    failureType = [string]$bugPackage.type
    outcome = $(if ($postApplyRetestPassed -and $rollbackVerified) { "RETEST_PASSED_AFTER_PATCH" } else { "NEEDS_INVESTIGATION" })
}

$analysisStatus = "PASS"
$blockingReasons = @()
if (-not $priorFixHintMatched) {
    $blockingReasons += "prior_fix_hint_not_found_in_knowledge_graph"
}

if (-not ($patchMentionsPriorFixHint -or $summaryMentionsPriorFixHint)) {
    $blockingReasons += "repair_agent_output_did_not_reference_prior_fix_hint"
}

if (-not $externalTaskResultAccepted) {
    $blockingReasons += "external_task_output_not_accepted"
}

if (-not $postApplyRetestPassed) {
    $blockingReasons += "post_apply_retest_not_proven"
}

if (-not $rollbackVerified) {
    $blockingReasons += "rollback_not_verified"
}

if ($blockingReasons.Count -gt 0) {
    $analysisStatus = "FAIL"
}

$report = @(
    "# AI TestPilot Patch Result Analysis",
    "",
    "- Status: $analysisStatus",
    "- TaskId: $taskId",
    "- BugId: $bugId",
    "- Prior fix hint: $suggestedFix",
    "- Prior fix hint matched in knowledge graph: $priorFixHintMatched",
    "- External task output accepted: $externalTaskResultAccepted",
    "- Post-apply retest passed: $postApplyRetestPassed",
    "- Rollback verified: $rollbackVerified",
    "- Knowledge graph outcome: $($knowledgeGraphResult.outcome)"
) -join "`n"

$report += "`n"
Set-Content -Path $reportFullPath -Value $report -Encoding UTF8

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.repair_agent_patch_result_analysis.v1"
    status = $analysisStatus
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    taskId = $taskId
    bugId = $bugId
    bugType = [string]$bugPackage.type
    risk = [string]$bugPackage.risk
    priorFixHint = $suggestedFix
    priorFixHintMatched = [bool]$priorFixHintMatched
    patchMentionsPriorFixHint = [bool]$patchMentionsPriorFixHint
    summaryMentionsPriorFixHint = [bool]$summaryMentionsPriorFixHint
    patchMentionsBugId = [bool]$patchMentionsBugId
    summaryMentionsBugId = [bool]$summaryMentionsBugId
    patchMentionsTaskId = [bool]$patchMentionsTaskId
    summaryMentionsTaskId = [bool]$summaryMentionsTaskId
    externalTaskResultAccepted = [bool]$externalTaskResultAccepted
    postApplyRetestPassed = [bool]$postApplyRetestPassed
    postApplyBugStillPresent = [bool]$mainWorktreeApply.postApplyBugStillPresent
    rollbackVerified = [bool]$rollbackVerified
    mainRepositoryPatchPersisted = [bool]$mainWorktreeApply.mainRepositoryPatchPersisted
    patchOutputSource = [string]$mainWorktreeApply.patchOutputSource
    externalAgentRun = [bool]$mainWorktreeApply.externalAgentRun
    externalAgentCompletionVerified = [bool]$mainWorktreeApply.externalAgentCompletionVerified
    knowledgeGraphResult = $knowledgeGraphResult
    blockingReasonCount = [int]$blockingReasons.Count
    blockingReasons = @($blockingReasons)
    files = @(
        "repair-agent-patch-result-analysis.md",
        "bug-knowledge-graph.json",
        "repair-agent-external-task-output.patch",
        "repair-agent-external-task-output-summary.md",
        "repair-agent-main-worktree-apply-retest-rollback-manifest.json"
    )
}

New-Item -ItemType Directory -Force (Split-Path $manifestFullPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFullPath -Encoding UTF8

Write-Output "Repair agent patch result analysis manifest: $manifestFullPath"
if ($analysisStatus -ne "PASS") {
    throw "AI TestPilot repair agent patch result analysis failed: $($blockingReasons -join ', ')"
}

Write-Output "PASS AI TestPilot repair agent patch result analysis"
