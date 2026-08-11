<#
.SYNOPSIS
Export a release-readiness handoff block to a local Markdown file.

.DESCRIPTION
This utility runs Set-AITestPilotReleaseReadinessMilestoneNotes.ps1 in dry-run mode
and writes the generated handoff block to a file. It is useful when you want a
stable, paste-ready artifact for PR templates, checklists, or change records.

.PARAMETER OutputPath
Destination path for the handoff block.

.PARAMETER IncludeRecommendedCommands
Pass through to readiness bundle generation.

.PARAMETER NoIncludeRecommendedCommands
Disable recommended commands in the generated handoff block.

.PARAMETER RequireReleasePipeline
Pass through to readiness bundle generation.

.PARAMETER FailOnWarning
Pass through to readiness bundle generation.

.PARAMETER IncludeFailedOnly
Pass through to readiness snippet generation.

.PARAMETER SummaryJsonPath
Bundle machine-readable summary path.

.PARAMETER ReportOutputPath
Bundle human-readable report path.

.PARAMETER SnippetOutputPath
Bundle PR snippet output path.

.PARAMETER MarkerStart
Override the opening marker used in the generated block.

.PARAMETER MarkerEnd
Override the closing marker used in the generated block.
#>
[CmdletBinding()]
param(
    [string]$OutputPath = "Temp\release-readiness-handoff-block.md",
    [switch]$IncludeRecommendedCommands,
    [switch]$NoIncludeRecommendedCommands,
    [switch]$RequireReleasePipeline,
    [switch]$FailOnWarning,
    [switch]$IncludeFailedOnly,
    [string]$SummaryJsonPath = "Temp\release-readiness-summary.json",
    [string]$ReportOutputPath = "Temp\release-readiness-report.md",
    [string]$SnippetOutputPath = "Temp\release-readiness-pr-snippet.md",
    [string]$MarkerStart = "<!-- ai-testpilot-release-readiness:start -->",
    [string]$MarkerEnd = "<!-- ai-testpilot-release-readiness:end -->",
    [switch]$NoOverwrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$generator = Join-Path $PSScriptRoot "Set-AITestPilotReleaseReadinessMilestoneNotes.ps1"
if (-not (Test-Path $generator)) {
    throw "Missing handoff generator script: $generator"
}

if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    $OutputPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputPath))
}

if ($IncludeRecommendedCommands -and $NoIncludeRecommendedCommands) {
    throw "Specify only one of -IncludeRecommendedCommands or -NoIncludeRecommendedCommands."
}

if ($NoOverwrite -and (Test-Path $OutputPath)) {
    throw "Output file already exists. Re-run without -NoOverwrite to replace: $OutputPath"
}

$outputDir = Split-Path $OutputPath -Parent
if (-not [string]::IsNullOrWhiteSpace($outputDir) -and -not (Test-Path $outputDir)) {
    New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
}

$generatorArgs = @{
    DryRun = $true
    RequireReleasePipeline = $RequireReleasePipeline
    FailOnWarning = $FailOnWarning
    SummaryJsonPath = $SummaryJsonPath
    ReportOutputPath = $ReportOutputPath
    SnippetOutputPath = $SnippetOutputPath
    MarkerStart = $MarkerStart
    MarkerEnd = $MarkerEnd
}
if (-not $NoIncludeRecommendedCommands) { $generatorArgs["IncludeRecommendedCommands"] = $true }
if ($NoIncludeRecommendedCommands) { $generatorArgs["NoIncludeRecommendedCommands"] = $true }
if ($IncludeFailedOnly) { $generatorArgs["IncludeFailedOnly"] = $true }

$raw = $null
try {
    $raw = & $generator @generatorArgs
}
catch {
    throw "Handoff generation failed while running Set-AITestPilotReleaseReadinessMilestoneNotes.ps1. $_"
}

$rawText = if ($null -ne $raw) { [string]::Join([Environment]::NewLine, $raw) } else { "" }

$handoffBlock = if ([string]::IsNullOrWhiteSpace($rawText)) {
    throw "No handoff block was generated."
} else {
    $rawText
}

Set-Content -Path $OutputPath -Encoding UTF8 -Value $handoffBlock
Write-Output "Wrote handoff block to: $OutputPath"
