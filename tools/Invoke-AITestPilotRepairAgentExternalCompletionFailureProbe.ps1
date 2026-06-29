[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ProbeBundleDir,
    [string]$ManifestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ProbeBundleDir)) {
    $ProbeBundleDir = Join-Path $repoRoot "Temp\release-evidence\repair-agent-external-completion-failure-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "repair-agent-external-completion-failure-probe-manifest.json"
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

function Write-Utf8NoBomFile {
    param(
        [string]$Path,
        [string]$Content
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Test-ContainsAll {
    param(
        [object[]]$Actual,
        [string[]]$Required
    )

    foreach ($item in $Required) {
        if ($Actual -notcontains $item) {
            return $false
        }
    }

    return $true
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

if (Test-Path $probeBundlePath) {
    Remove-Item -LiteralPath $probeBundlePath -Recurse -Force
}

New-Item -ItemType Directory -Force $probeBundlePath | Out-Null
Copy-Item -LiteralPath $repairAgentRunSource -Destination (Join-Path $probeBundlePath "repair-agent-run.json") -Force

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

Write-Utf8NoBomFile (Join-Path $probeBundlePath "repair-agent.patch") ($patchText + "`n")
Write-Utf8NoBomFile (Join-Path $probeBundlePath "repair-agent-summary.md") ($summaryText + "`n")

$importFailed = $false
$importErrorMessage = ""

try {
    & (Join-Path $repoRoot "tools\Invoke-AITestPilotRepairAgentPatchOutputImport.ps1") `
        -EvidenceBundleDir $probeBundlePath `
        -ConfirmExternalAgentCompleted
}
catch {
    $importFailed = $true
    $importErrorMessage = $_.Exception.Message
}

if (-not $importFailed) {
    throw "Expected patch output import to reject pending repair-agent run state, but it passed."
}

$importManifestPath = Join-Path $probeBundlePath "repair-agent-patch-output-manifest.json"
if (-not (Test-Path $importManifestPath)) {
    throw "Expected failed patch output import to write a manifest: $importManifestPath"
}

$importManifest = Get-Content -Raw $importManifestPath | ConvertFrom-Json
$expectedFailureReasons = @(
    "external_agent_run_not_completed",
    "external_agent_not_launched",
    "patch_output_status_not_produced",
    "patch_output_count_missing",
    "required_patch_outputs_not_marked_produced"
)

$failureReasons = @($importManifest.externalAgentCompletionFailureReasons)
$expectedReasonsFound = Test-ContainsAll $failureReasons $expectedFailureReasons

if ($importManifest.status -ne "FAIL" -or
    $importManifest.source -ne "external_agent_unverified" -or
    [bool]$importManifest.externalAgentRun -or
    [bool]$importManifest.externalAgentCompletionVerified -or
    -not $expectedReasonsFound) {
    throw "Pending repair-agent run failure manifest did not record the expected provenance rejection."
}

$importManifestTarget = Join-Path $evidenceBundlePath "repair-agent-external-completion-failure-probe-import-manifest.json"
Copy-Item -LiteralPath $importManifestPath -Destination $importManifestTarget -Force

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.repair_agent_external_completion_failure_probe.v1"
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    expectedFailure = $true
    importFailed = [bool]$importFailed
    importErrorMessage = $importErrorMessage
    importManifestStatus = $importManifest.status
    importManifestSource = $importManifest.source
    confirmExternalAgentCompleted = [bool]$importManifest.confirmExternalAgentCompleted
    externalAgentRun = [bool]$importManifest.externalAgentRun
    externalAgentCompletionVerified = [bool]$importManifest.externalAgentCompletionVerified
    failureReasonCount = [int]$importManifest.externalAgentCompletionFailureReasonCount
    expectedFailureReasonsFound = [bool]$expectedReasonsFound
    failureReasons = @($failureReasons)
    pendingRunStatus = $importManifest.repairAgentRunStatus
    pendingPatchOutputStatus = $importManifest.repairAgentRunPatchOutputStatus
    pendingPatchOutputCount = [int]$importManifest.repairAgentRunPatchOutputCount
    files = @(
        "repair-agent-external-completion-failure-probe-import-manifest.json"
    )
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

Write-Output "Repair agent external completion failure probe manifest: $manifestPath"
Write-Output "PASS AI TestPilot repair agent external completion failure probe"
