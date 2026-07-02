[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$RepairAgentRunPath,
    [string]$PatchPath,
    [string]$SummaryPath,
    [string]$ManifestPath,
    [switch]$GenerateSampleOutput,
    [switch]$ConfirmExternalAgentCompleted
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($RepairAgentRunPath)) {
    $RepairAgentRunPath = Join-Path $EvidenceBundleDir "repair-agent-run.json"
}

if ([string]::IsNullOrWhiteSpace($PatchPath)) {
    $PatchPath = Join-Path $EvidenceBundleDir "repair-agent.patch"
}

if ([string]::IsNullOrWhiteSpace($SummaryPath)) {
    $SummaryPath = Join-Path $EvidenceBundleDir "repair-agent-summary.md"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "repair-agent-patch-output-manifest.json"
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

function Write-SamplePatchOutput {
    param(
        [string]$PatchTarget,
        [string]$SummaryTarget,
        [string]$RetestCommand
    )

    New-Item -ItemType Directory -Force (Split-Path $PatchTarget -Parent) | Out-Null
    New-Item -ItemType Directory -Force (Split-Path $SummaryTarget -Parent) | Out-Null

    $patch = @'
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

    $summary = @"
# AI TestPilot Repair Agent Summary

## Result
- Applied fix hint: add null guard before reward access.
- Patch output: repair-agent.patch.
- Post-patch retest command: $RetestCommand
"@

    Set-Content -Path $PatchTarget -Value $patch -Encoding UTF8
    Set-Content -Path $SummaryTarget -Value $summary -Encoding UTF8
}

function Test-SummaryContainsRetestCommand {
    param(
        [string]$SummaryText,
        [string]$RetestCommand
    )

    if ($SummaryText -match [regex]::Escape($RetestCommand)) {
        return $true
    }

    $markdownEscapedRetestCommand = $RetestCommand.Replace("\", "\\")
    return $SummaryText -match [regex]::Escape($markdownEscapedRetestCommand)
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$repairAgentRunPath = Assert-PathUnderRepo $RepairAgentRunPath "RepairAgentRunPath"
$patchPath = Assert-PathUnderRepo $PatchPath "PatchPath"
$summaryPath = Assert-PathUnderRepo $SummaryPath "SummaryPath"
$manifestPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"

if (-not (Test-Path $repairAgentRunPath)) {
    throw "Repair agent run artifact is missing: $repairAgentRunPath"
}

$repairAgentRun = Get-Content -Raw $repairAgentRunPath | ConvertFrom-Json
if ($repairAgentRun.schemaVersion -ne "aitestpilot.repair_agent_run.v1") {
    throw "Unexpected repair agent run schema: $($repairAgentRun.schemaVersion)"
}

if ($GenerateSampleOutput) {
    Write-SamplePatchOutput `
        -PatchTarget $patchPath `
        -SummaryTarget $summaryPath `
        -RetestCommand $repairAgentRun.postPatchRetestCommand
}

if (-not (Test-Path $patchPath)) {
    throw "Repair agent patch output is missing: $patchPath"
}

if (-not (Test-Path $summaryPath)) {
    throw "Repair agent summary output is missing: $summaryPath"
}

$patchText = Get-Content -Raw $patchPath
$summaryText = Get-Content -Raw $summaryPath
$patchContainsDiffHeader = $patchText -match [regex]::Escape("diff --git")
$sampleFixSnippet = "reward == null"
$sampleFixSnippetRequired = [bool]$GenerateSampleOutput
$patchContainsSampleFix = $patchText -match [regex]::Escape($sampleFixSnippet)
$patchContainsExpectedFix = [bool]$patchContainsSampleFix
$summaryContainsRetestCommand = Test-SummaryContainsRetestCommand `
    -SummaryText $summaryText `
    -RetestCommand $repairAgentRun.postPatchRetestCommand

if (-not $patchContainsDiffHeader) {
    throw "Repair agent patch output does not look like a unified diff."
}

if ($sampleFixSnippetRequired -and -not $patchContainsSampleFix) {
    throw "Repair agent patch output does not include the expected null-guard fix snippet."
}

if (-not $summaryContainsRetestCommand) {
    throw "Repair agent summary does not include the post-patch retest command."
}

$expectedPatchOutputs = @()
if ($null -ne $repairAgentRun.expectedPatchOutputs) {
    $expectedPatchOutputs = @($repairAgentRun.expectedPatchOutputs)
}

$requiredPatchOutputs = @($expectedPatchOutputs | Where-Object { [bool]$_.required })
$producedRequiredPatchOutputs = @($requiredPatchOutputs | Where-Object { [bool]$_.produced })
$externalAgentCompletionRequired = -not [bool]$GenerateSampleOutput
$externalAgentCompletionVerified = $false
$externalAgentCompletionFailureReasons = @()

if ($externalAgentCompletionRequired) {
    if (-not [bool]$ConfirmExternalAgentCompleted) {
        $externalAgentCompletionFailureReasons += "missing_external_agent_completion_confirmation"
    }

    if ($repairAgentRun.status -ne "EXTERNAL_AGENT_COMPLETED") {
        $externalAgentCompletionFailureReasons += "external_agent_run_not_completed"
    }

    if (-not [bool]$repairAgentRun.agentLaunched) {
        $externalAgentCompletionFailureReasons += "external_agent_not_launched"
    }

    if ($repairAgentRun.patchOutputStatus -ne "PRODUCED") {
        $externalAgentCompletionFailureReasons += "patch_output_status_not_produced"
    }

    if ([int]$repairAgentRun.patchOutputCount -lt 2) {
        $externalAgentCompletionFailureReasons += "patch_output_count_missing"
    }

    if ($requiredPatchOutputs.Count -lt 2) {
        $externalAgentCompletionFailureReasons += "required_patch_output_slots_missing"
    }

    if ($producedRequiredPatchOutputs.Count -ne $requiredPatchOutputs.Count) {
        $externalAgentCompletionFailureReasons += "required_patch_outputs_not_marked_produced"
    }

    $externalAgentCompletionVerified = $externalAgentCompletionFailureReasons.Count -eq 0
}

$source = if ($GenerateSampleOutput) {
    "deterministic_sample"
}
elseif ($externalAgentCompletionVerified) {
    "external_agent"
}
else {
    "external_agent_unverified"
}

$externalAgentRun = [bool]$externalAgentCompletionVerified
$status = if ($externalAgentCompletionFailureReasons.Count -eq 0) { "PASS" } else { "FAIL" }

$patchTarget = Join-Path $evidenceBundlePath "repair-agent.patch"
$summaryTarget = Join-Path $evidenceBundlePath "repair-agent-summary.md"
if ($status -eq "PASS" -and $patchPath -ne $patchTarget) {
    Copy-Item -LiteralPath $patchPath -Destination $patchTarget -Force
}

if ($status -eq "PASS" -and $summaryPath -ne $summaryTarget) {
    Copy-Item -LiteralPath $summaryPath -Destination $summaryTarget -Force
}

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.repair_agent_patch_output.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    source = $source
    externalAgentRun = [bool]$externalAgentRun
    confirmExternalAgentCompleted = [bool]$ConfirmExternalAgentCompleted
    externalAgentCompletionRequired = [bool]$externalAgentCompletionRequired
    externalAgentCompletionVerified = [bool]$externalAgentCompletionVerified
    externalAgentCompletionFailureReasonCount = [int]$externalAgentCompletionFailureReasons.Count
    externalAgentCompletionFailureReasons = @($externalAgentCompletionFailureReasons)
    repairAgentRunStatus = $repairAgentRun.status
    repairAgentRunAgentLaunched = [bool]$repairAgentRun.agentLaunched
    repairAgentRunPatchOutputStatus = $repairAgentRun.patchOutputStatus
    repairAgentRunPatchOutputCount = [int]$repairAgentRun.patchOutputCount
    repairAgentRunId = $repairAgentRun.runId
    taskId = $repairAgentRun.taskId
    bugId = $repairAgentRun.bugId
    expectedPatchOutputCount = [int]$expectedPatchOutputs.Count
    requiredPatchOutputCount = [int]$requiredPatchOutputs.Count
    producedRequiredPatchOutputCount = [int]$producedRequiredPatchOutputs.Count
    patchFilePresent = $true
    summaryFilePresent = $true
    patchOutputCount = 2
    patchLineCount = @($patchText -split "`r?`n").Count
    summaryLineCount = @($summaryText -split "`r?`n").Count
    patchContainsDiffHeader = [bool]$patchContainsDiffHeader
    sampleFixSnippetRequired = [bool]$sampleFixSnippetRequired
    sampleFixSnippet = $sampleFixSnippet
    patchContainsSampleFix = [bool]$patchContainsSampleFix
    patchContainsExpectedFix = [bool]$patchContainsExpectedFix
    summaryContainsRetestCommand = [bool]$summaryContainsRetestCommand
    postPatchRetestCommand = $repairAgentRun.postPatchRetestCommand
    files = @(
        "repair-agent.patch",
        "repair-agent-summary.md"
    )
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $manifestPath -Encoding UTF8

Write-Output "Repair agent patch output manifest: $manifestPath"
if ($status -ne "PASS") {
    throw "AI TestPilot repair agent patch output import failed provenance checks: $($externalAgentCompletionFailureReasons -join ', ')"
}

Write-Output "PASS AI TestPilot repair agent patch output import"
