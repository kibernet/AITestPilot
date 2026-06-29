[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ManifestPath,
    [string]$HistoryPath,
    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "repair-agent-patch-result-history-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($HistoryPath)) {
    $HistoryPath = Join-Path $EvidenceBundleDir "repair-agent-patch-result-history.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "repair-agent-patch-result-history.md"
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

function New-HistoryRecord {
    param(
        [string]$RecordId,
        [string]$Source,
        [string]$TaskId,
        [string]$BugId,
        [string]$Module,
        [string]$FailureType,
        [string]$Risk,
        [string]$PriorFixHint,
        [string]$PatchOutputSource,
        [bool]$ExternalAgentRun,
        [bool]$PriorFixHintMatched,
        [bool]$PostApplyRetestPassed,
        [bool]$PostApplyBugStillPresent,
        [bool]$RollbackVerified,
        [bool]$MainRepositoryPatchPersisted,
        [string]$Outcome,
        [string[]]$EvidenceFiles
    )

    return [pscustomobject][ordered]@{
        recordId = $RecordId
        source = $Source
        taskId = $TaskId
        bugId = $BugId
        module = $Module
        failureType = $FailureType
        risk = $Risk
        priorFixHint = $PriorFixHint
        patchOutputSource = $PatchOutputSource
        externalAgentRun = [bool]$ExternalAgentRun
        priorFixHintMatched = [bool]$PriorFixHintMatched
        postApplyRetestPassed = [bool]$PostApplyRetestPassed
        postApplyBugStillPresent = [bool]$PostApplyBugStillPresent
        rollbackVerified = [bool]$RollbackVerified
        mainRepositoryPatchPersisted = [bool]$MainRepositoryPatchPersisted
        outcome = $Outcome
        evidenceFiles = @($EvidenceFiles)
    }
}

function New-CountRows {
    param(
        [object[]]$Records,
        [string]$PropertyName
    )

    $rows = @()
    foreach ($group in ($Records | Group-Object -Property $PropertyName | Sort-Object -Property Count -Descending)) {
        $rows += [ordered]@{
            name = [string]$group.Name
            count = [int]$group.Count
        }
    }

    return @($rows)
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$historyFullPath = Assert-PathUnderRepo $HistoryPath "HistoryPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

$currentAnalysis = Read-RequiredJson "repair-agent-patch-result-analysis-manifest.json" "Repair-agent patch result analysis manifest"

$currentRecord = New-HistoryRecord `
    -RecordId ("current-" + [string]$currentAnalysis.bugId) `
    -Source "current_release_analysis" `
    -TaskId ([string]$currentAnalysis.taskId) `
    -BugId ([string]$currentAnalysis.bugId) `
    -Module ([string]$currentAnalysis.knowledgeGraphResult.module) `
    -FailureType ([string]$currentAnalysis.knowledgeGraphResult.failureType) `
    -Risk ([string]$currentAnalysis.risk) `
    -PriorFixHint ([string]$currentAnalysis.priorFixHint) `
    -PatchOutputSource ([string]$currentAnalysis.patchOutputSource) `
    -ExternalAgentRun ([bool]$currentAnalysis.externalAgentRun) `
    -PriorFixHintMatched ([bool]$currentAnalysis.priorFixHintMatched) `
    -PostApplyRetestPassed ([bool]$currentAnalysis.postApplyRetestPassed) `
    -PostApplyBugStillPresent ([bool]$currentAnalysis.postApplyBugStillPresent) `
    -RollbackVerified ([bool]$currentAnalysis.rollbackVerified) `
    -MainRepositoryPatchPersisted ([bool]$currentAnalysis.mainRepositoryPatchPersisted) `
    -Outcome ([string]$currentAnalysis.knowledgeGraphResult.outcome) `
    -EvidenceFiles @("repair-agent-patch-result-analysis-manifest.json", "repair-agent-patch-result-analysis.md")

$records = @(
    $currentRecord,
    (New-HistoryRecord `
        -RecordId "history-login-timeout-0001" `
        -Source "deterministic_history_fixture" `
        -TaskId "TASK-HISTORY-LOGIN-0001" `
        -BugId "BUG-HISTORY-LOGIN-0001" `
        -Module "AccountLogin" `
        -FailureType "Timeout" `
        -Risk "HIGH" `
        -PriorFixHint "Wait for login session readiness before entering the target scene." `
        -PatchOutputSource "external_agent_history_fixture" `
        -ExternalAgentRun $true `
        -PriorFixHintMatched $true `
        -PostApplyRetestPassed $true `
        -PostApplyBugStillPresent $false `
        -RollbackVerified $true `
        -MainRepositoryPatchPersisted $false `
        -Outcome "RETEST_PASSED_AFTER_PATCH" `
        -EvidenceFiles @("repair-agent-patch-result-history.json")),
    (New-HistoryRecord `
        -RecordId "history-reward-state-0002" `
        -Source "deterministic_history_fixture" `
        -TaskId "TASK-HISTORY-REWARD-0002" `
        -BugId "BUG-HISTORY-REWARD-0002" `
        -Module "ActivityReward" `
        -FailureType "StateMismatch" `
        -Risk "MEDIUM" `
        -PriorFixHint "Refresh reward state after the activity panel becomes visible." `
        -PatchOutputSource "external_agent_history_fixture" `
        -ExternalAgentRun $true `
        -PriorFixHintMatched $true `
        -PostApplyRetestPassed $true `
        -PostApplyBugStillPresent $false `
        -RollbackVerified $true `
        -MainRepositoryPatchPersisted $false `
        -Outcome "RETEST_PASSED_AFTER_PATCH" `
        -EvidenceFiles @("repair-agent-patch-result-history.json")),
    (New-HistoryRecord `
        -RecordId "history-fishing-flow-0003" `
        -Source "deterministic_history_fixture" `
        -TaskId "TASK-HISTORY-FISHING-0003" `
        -BugId "BUG-HISTORY-FISHING-0003" `
        -Module "Fishing" `
        -FailureType "NullReference" `
        -Risk "HIGH" `
        -PriorFixHint "Guard the fishing reward result before updating the catch summary." `
        -PatchOutputSource "external_agent_history_fixture" `
        -ExternalAgentRun $true `
        -PriorFixHintMatched $true `
        -PostApplyRetestPassed $true `
        -PostApplyBugStillPresent $false `
        -RollbackVerified $true `
        -MainRepositoryPatchPersisted $false `
        -Outcome "RETEST_PASSED_AFTER_PATCH" `
        -EvidenceFiles @("repair-agent-patch-result-history.json"))
)

$blockingReasons = @()
if ($currentAnalysis.status -ne "PASS") {
    $blockingReasons += "current_patch_result_analysis_not_passing"
}

$duplicateRecordIds = @($records | Group-Object -Property recordId | Where-Object { $_.Count -gt 1 })
if ($duplicateRecordIds.Count -gt 0) {
    $blockingReasons += "duplicate_history_record_ids"
}

$invalidRecords = @()
foreach ($record in $records) {
    if ([string]::IsNullOrWhiteSpace([string]$record.recordId) -or
        [string]::IsNullOrWhiteSpace([string]$record.taskId) -or
        [string]::IsNullOrWhiteSpace([string]$record.bugId) -or
        [string]::IsNullOrWhiteSpace([string]$record.module) -or
        [string]::IsNullOrWhiteSpace([string]$record.failureType) -or
        [string]::IsNullOrWhiteSpace([string]$record.priorFixHint) -or
        -not [bool]$record.externalAgentRun -or
        -not [bool]$record.priorFixHintMatched -or
        -not [bool]$record.postApplyRetestPassed -or
        [bool]$record.postApplyBugStillPresent -or
        -not [bool]$record.rollbackVerified -or
        [bool]$record.mainRepositoryPatchPersisted -or
        [string]$record.outcome -ne "RETEST_PASSED_AFTER_PATCH") {
        $invalidRecords += [string]$record.recordId
    }
}

if ($invalidRecords.Count -gt 0) {
    $blockingReasons += "invalid_history_records"
}

$uniqueBugIds = @($records | ForEach-Object { [string]$_.bugId } | Sort-Object -Unique)
$uniqueModules = @($records | ForEach-Object { [string]$_.module } | Sort-Object -Unique)
$uniqueFailureTypes = @($records | ForEach-Object { [string]$_.failureType } | Sort-Object -Unique)
$retestPassedCount = @($records | Where-Object { [bool]$_.postApplyRetestPassed -and -not [bool]$_.postApplyBugStillPresent }).Count
$rollbackVerifiedCount = @($records | Where-Object { [bool]$_.rollbackVerified -and -not [bool]$_.mainRepositoryPatchPersisted }).Count
$unresolvedHighRiskCount = @($records | Where-Object {
        [string]$_.risk -eq "HIGH" -and
        ([string]$_.outcome -ne "RETEST_PASSED_AFTER_PATCH" -or [bool]$_.postApplyBugStillPresent)
    }).Count
$currentAnalysisIncluded = @($records | Where-Object {
        [string]$_.source -eq "current_release_analysis" -and
        [string]$_.bugId -eq [string]$currentAnalysis.bugId
    }).Count -eq 1

if ($records.Count -lt 4) {
    $blockingReasons += "history_record_count_too_low"
}

if ($uniqueBugIds.Count -lt 4) {
    $blockingReasons += "unique_bug_count_too_low"
}

if ($uniqueModules.Count -lt 3) {
    $blockingReasons += "unique_module_count_too_low"
}

if ($uniqueFailureTypes.Count -lt 3) {
    $blockingReasons += "unique_failure_type_count_too_low"
}

if ($retestPassedCount -ne $records.Count) {
    $blockingReasons += "not_all_history_records_retested_clean"
}

if ($rollbackVerifiedCount -ne $records.Count) {
    $blockingReasons += "not_all_history_records_rolled_back_clean"
}

if ($unresolvedHighRiskCount -ne 0) {
    $blockingReasons += "unresolved_high_risk_history_records"
}

if (-not $currentAnalysisIncluded) {
    $blockingReasons += "current_patch_result_analysis_not_included"
}

$status = "PASS"
if ($blockingReasons.Count -gt 0) {
    $status = "FAIL"
}

$history = [ordered]@{
    schemaVersion = "aitestpilot.repair_agent_patch_result_history.v1"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    source = "current_release_analysis_plus_deterministic_history_fixture"
    records = @($records)
    moduleCounts = @(New-CountRows $records "module")
    failureTypeCounts = @(New-CountRows $records "failureType")
    outcomeCounts = @(New-CountRows $records "outcome")
}

New-Item -ItemType Directory -Force (Split-Path $historyFullPath -Parent) | Out-Null
$history | ConvertTo-Json -Depth 12 | Set-Content -Path $historyFullPath -Encoding UTF8

$report = @(
    "# AI TestPilot Patch Result History",
    "",
    "- Status: $status",
    "- Record count: $($records.Count)",
    "- Unique bugs: $($uniqueBugIds.Count)",
    "- Unique modules: $($uniqueModules.Count)",
    "- Unique failure types: $($uniqueFailureTypes.Count)",
    "- Retest-passed records: $retestPassedCount",
    "- Rollback-verified records: $rollbackVerifiedCount",
    "- Unresolved high-risk records: $unresolvedHighRiskCount",
    "- Current analysis included: $currentAnalysisIncluded",
    "- Production output boundary: real production repair-agent output is not claimed by this fixture"
) -join "`n"

$report += "`n"
Set-Content -Path $reportFullPath -Value $report -Encoding UTF8

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.repair_agent_patch_result_history.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    source = "current_release_analysis_plus_deterministic_history_fixture"
    currentAnalysisStatus = [string]$currentAnalysis.status
    currentAnalysisBugId = [string]$currentAnalysis.bugId
    currentAnalysisTaskId = [string]$currentAnalysis.taskId
    currentAnalysisIncluded = [bool]$currentAnalysisIncluded
    recordCount = [int]$records.Count
    uniqueBugCount = [int]$uniqueBugIds.Count
    uniqueModuleCount = [int]$uniqueModules.Count
    uniqueFailureTypeCount = [int]$uniqueFailureTypes.Count
    retestPassedCount = [int]$retestPassedCount
    rollbackVerifiedCount = [int]$rollbackVerifiedCount
    unresolvedHighRiskCount = [int]$unresolvedHighRiskCount
    invalidRecordCount = [int]$invalidRecords.Count
    moduleCounts = @(New-CountRows $records "module")
    failureTypeCounts = @(New-CountRows $records "failureType")
    outcomeCounts = @(New-CountRows $records "outcome")
    realProductionOutputIncluded = $false
    productionOutputBoundary = "real_production_repair_agent_output_not_claimed"
    blockingReasonCount = [int]$blockingReasons.Count
    blockingReasons = @($blockingReasons)
    files = @(
        "repair-agent-patch-result-history.json",
        "repair-agent-patch-result-history.md",
        "repair-agent-patch-result-analysis-manifest.json"
    )
}

New-Item -ItemType Directory -Force (Split-Path $manifestFullPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestFullPath -Encoding UTF8

Write-Output "Repair agent patch result history manifest: $manifestFullPath"
if ($status -ne "PASS") {
    throw "AI TestPilot repair agent patch result history probe failed: $($blockingReasons -join ', ')"
}

Write-Output "PASS AI TestPilot repair agent patch result history probe"
