<#
.SYNOPSIS
Generate release readiness report, machine-readable summary, and PR-ready snippet in one command.

.DESCRIPTION
This utility orchestrates:
 - Invoke-AITestPilotReleaseReadinessReport.ps1
 - Invoke-AITestPilotReleaseReadinessSummary.ps1

Use this as the one-command local workflow whenever you need both a full report and
paste-ready snippet for PR/Milestone handoff.

.PARAMETER ReportOutputPath
Output path for the human-readable markdown readiness report.

.PARAMETER SummaryJsonPath
Output path for machine-readable summary JSON.

.PARAMETER SnippetOutputPath
Output path for PR-ready markdown snippet.

.PARAMETER IncludeRecommendedCommands
Forwarded to the report script to include recommended follow-up commands section.

.PARAMETER RequireReleasePipeline
Forwarded to the report script to require release pipeline evidence in checks.

.PARAMETER FailOnWarning
Forwarded to report and summary generation as strict mode.

.PARAMETER IncludeFailedOnly
Only include non-PASS checks in the snippet output.

.PARAMETER SkipSnippet
Generate only report + machine-readable summary, but skip PR snippet generation.
#>
[CmdletBinding()]
param(
    [string]$ReportOutputPath = "Temp\release-readiness-report.md",
    [string]$SummaryJsonPath = "Temp\release-readiness-summary.json",
    [string]$SnippetOutputPath = "Temp\release-readiness-pr-snippet.md",
    [switch]$IncludeRecommendedCommands,
    [switch]$RequireReleasePipeline,
    [switch]$FailOnWarning,
    [switch]$IncludeFailedOnly,
    [switch]$SkipSnippet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$reportScript = Join-Path $PSScriptRoot "Invoke-AITestPilotReleaseReadinessReport.ps1"
$summaryScript = Join-Path $PSScriptRoot "Invoke-AITestPilotReleaseReadinessSummary.ps1"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Resolve-PathUnderRepo {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

if (-not (Test-Path $reportScript)) {
    throw "Missing report script: $reportScript"
}

if (-not (Test-Path $summaryScript)) {
    throw "Missing summary script: $summaryScript"
}

$reportParams = @{
    OutputPath = $ReportOutputPath
    SummaryOutputPath = $SummaryJsonPath
}

if ($IncludeRecommendedCommands) { $reportParams["IncludeRecommendedCommands"] = $true }
if ($RequireReleasePipeline) { $reportParams["RequireReleasePipeline"] = $true }
if ($FailOnWarning) { $reportParams["FailOnWarning"] = $true }

$reportError = $null
try {
    & $reportScript @reportParams
}
catch {
    $reportError = $_
}

if ($SkipSnippet) {
    if ($null -ne $reportError) { throw $reportError }
    Write-Output "Release readiness bundle complete without snippet. summary: $SummaryJsonPath"
    return
}

$summaryPath = Resolve-PathUnderRepo $SummaryJsonPath
if (-not (Test-Path $summaryPath)) {
    if ($null -ne $reportError) { throw $reportError }
    throw "Release readiness summary was not generated: $summaryPath"
}

$snippetParams = @{
    SummaryJson = $SummaryJsonPath
    OutputPath = $SnippetOutputPath
}

if ($IncludeFailedOnly) { $snippetParams["IncludeFailedOnly"] = $true }

& $summaryScript @snippetParams

if ($null -ne $reportError) { throw $reportError }
Write-Output "Release readiness bundle complete."
