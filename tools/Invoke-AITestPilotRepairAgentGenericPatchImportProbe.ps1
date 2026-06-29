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
    $ProbeBundleDir = Join-Path $repoRoot "Temp\release-evidence\repair-agent-generic-patch-import-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "repair-agent-generic-patch-import-probe-manifest.json"
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
diff --git a/docs/repair-agent-generic-probe.md b/docs/repair-agent-generic-probe.md
new file mode 100644
--- /dev/null
+++ b/docs/repair-agent-generic-probe.md
@@ -0,0 +1,3 @@
+# Generic Repair Agent Probe
+
+This file proves external-agent patch import is not tied to a sample null-guard snippet.
'@

$summaryText = @'
# AI TestPilot Generic External Repair Agent Summary

## Result
- Produced a generic documentation patch that does not contain the sample null-guard snippet.
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
    [bool]$patchOutputManifest.sampleFixSnippetRequired -or
    [bool]$patchOutputManifest.patchContainsSampleFix) {
    throw "Generic patch import did not prove external-agent import independent from the sample fix snippet."
}

& (Join-Path $repoRoot "tools\Invoke-AITestPilotRepairAgentExternalPatchPreflight.ps1") `
    -EvidenceBundleDir $probeBundlePath

$preflightManifestPath = Join-Path $probeBundlePath "repair-agent-external-patch-preflight-manifest.json"
if (-not (Test-Path $preflightManifestPath)) {
    throw "Generic patch preflight manifest was not produced: $preflightManifestPath"
}

$preflightManifest = Get-Content -Raw $preflightManifestPath | ConvertFrom-Json
if ($preflightManifest.status -ne "PASS" -or
    -not [bool]$preflightManifest.repositoryApplyAllowed -or
    -not [bool]$preflightManifest.safeToInspect -or
    [int]$preflightManifest.unsafePathCount -ne 0) {
    throw "Generic patch preflight did not pass with repository apply allowed for verified external-agent output."
}

$genericPatchTarget = Join-Path $evidenceBundlePath "repair-agent-generic.patch"
$genericSummaryTarget = Join-Path $evidenceBundlePath "repair-agent-generic-summary.md"
$genericPatchOutputManifestTarget = Join-Path $evidenceBundlePath "repair-agent-generic-patch-output-manifest.json"
$genericPreflightManifestTarget = Join-Path $evidenceBundlePath "repair-agent-generic-patch-preflight-manifest.json"
Copy-Item -LiteralPath $patchPath -Destination $genericPatchTarget -Force
Copy-Item -LiteralPath $summaryPath -Destination $genericSummaryTarget -Force
Copy-Item -LiteralPath $patchOutputManifestPath -Destination $genericPatchOutputManifestTarget -Force
Copy-Item -LiteralPath $preflightManifestPath -Destination $genericPreflightManifestTarget -Force

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.repair_agent_generic_patch_import_probe.v1"
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    patchOutputSource = $patchOutputManifest.source
    externalAgentRun = [bool]$patchOutputManifest.externalAgentRun
    externalAgentCompletionVerified = [bool]$patchOutputManifest.externalAgentCompletionVerified
    repairAgentRunStatus = $patchOutputManifest.repairAgentRunStatus
    repairAgentPatchOutputStatus = $patchOutputManifest.repairAgentRunPatchOutputStatus
    sampleFixSnippetRequired = [bool]$patchOutputManifest.sampleFixSnippetRequired
    patchContainsSampleFix = [bool]$patchOutputManifest.patchContainsSampleFix
    patchContainsDiffHeader = [bool]$patchOutputManifest.patchContainsDiffHeader
    summaryContainsRetestCommand = [bool]$patchOutputManifest.summaryContainsRetestCommand
    preflightStatus = $preflightManifest.status
    preflightSafeToInspect = [bool]$preflightManifest.safeToInspect
    preflightRepositoryApplyAllowed = [bool]$preflightManifest.repositoryApplyAllowed
    preflightUnsafePathCount = [int]$preflightManifest.unsafePathCount
    genericTargetPath = "docs/repair-agent-generic-probe.md"
    mainRepositoryPatchApplied = $false
    files = @(
        "repair-agent-generic.patch",
        "repair-agent-generic-summary.md",
        "repair-agent-generic-patch-output-manifest.json",
        "repair-agent-generic-patch-preflight-manifest.json"
    )
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

Write-Output "Repair agent generic patch import probe manifest: $manifestPath"
Write-Output "PASS AI TestPilot repair agent generic patch import probe"
