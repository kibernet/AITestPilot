<#
.SYNOPSIS
Generate a release-readiness handoff block and optionally sync it to PR / issue / milestone.

.DESCRIPTION
This utility runs Invoke-AITestPilotReleaseReadinessBundle and writes the resulting
ready-to-paste block either to stdout (default) or directly to:
- a PR body (replace or append a marker-wrapped section),
- an issue body,
- or a milestone description.

By default, the block is generated with -IncludeRecommendedCommands.

.PARAMETER PullRequestNumber
GitHub pull-request number to update.

.PARAMETER IssueNumber
GitHub issue number to update.

.PARAMETER MilestoneNumber
GitHub milestone number to update by overwriting its description.

.PARAMETER IncludeRecommendedCommands
Pass through this flag to the readiness bundle.

.PARAMETER NoIncludeRecommendedCommands
Disable recommended commands in the generated handoff block.

.PARAMETER RequireReleasePipeline
Pass through this flag to the readiness bundle.

.PARAMETER FailOnWarning
Pass through this flag to the readiness bundle.

.PARAMETER IncludeFailedOnly
Pass through this flag to the readiness snippet.

.PARAMETER SummaryJsonPath
Bundle machine-readable summary path.

.PARAMETER ReportOutputPath
Bundle human-readable report path.

.PARAMETER SnippetOutputPath
Bundle PR snippet output path.

.PARAMETER DryRun
Generate the block and print it without writing back to GitHub.
#>
[CmdletBinding()]
param(
    [int]$PullRequestNumber = 0,
    [int]$IssueNumber = 0,
    [int]$MilestoneNumber = 0,
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
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$bundleScript = Join-Path $PSScriptRoot "Invoke-AITestPilotReleaseReadinessBundle.ps1"
if (-not (Test-Path $bundleScript)) {
    throw "Missing bundle script: $bundleScript"
}

$targets = 0
if ($PullRequestNumber -gt 0) { $targets++ }
if ($IssueNumber -gt 0) { $targets++ }
if ($MilestoneNumber -gt 0) { $targets++ }

if ($targets -gt 1) {
    throw "Specify only one target at most among -PullRequestNumber, -IssueNumber, -MilestoneNumber."
}

if (-not $DryRun -and $targets -gt 0 -and -not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI (gh) is required to sync to PR/issue/milestone targets. Install + login first, or rerun with -DryRun."
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Resolve-PathUnderRepo {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try {
        return Get-Content -Path $Path -Encoding UTF8 -Raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Get-TextOrEmpty {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return "" }
    try {
        return Get-Content -Path $Path -Encoding UTF8 -Raw
    }
    catch {
        return ""
    }
}

$summaryPath = Resolve-PathUnderRepo $SummaryJsonPath
$reportPath = Resolve-PathUnderRepo $ReportOutputPath
$snippetPath = Resolve-PathUnderRepo $SnippetOutputPath

$bundle = $null
$bundleError = ""

$bundleArgs = @{
    ReportOutputPath = $ReportOutputPath
    SummaryJsonPath = $SummaryJsonPath
    SnippetOutputPath = $SnippetOutputPath
    PassThru = $true
}
if (-not $NoIncludeRecommendedCommands) { $bundleArgs["IncludeRecommendedCommands"] = $true }
if ($RequireReleasePipeline) { $bundleArgs["RequireReleasePipeline"] = $true }
if ($FailOnWarning) { $bundleArgs["FailOnWarning"] = $true }
if ($IncludeFailedOnly) { $bundleArgs["IncludeFailedOnly"] = $true }

try {
    $bundleCommandOutput = & $bundleScript @bundleArgs
    if ($null -ne $bundleCommandOutput) {
        $bundleOutputs = @($bundleCommandOutput)
        $bundle = $bundleOutputs | Where-Object {
            $_ -is [System.Management.Automation.PSCustomObject] -or
            $_ -is [hashtable] -or
            $_ -is [System.Collections.Specialized.OrderedDictionary]
        } | Select-Object -Last 1
    }
}
catch {
    $bundleError = $_.Exception.Message
    Write-Output "Bundled readiness check completed with warning/blocking signal: $bundleError"
}

if ($null -eq $bundle) {
    $summaryPayload = Read-JsonFile -Path $summaryPath
    $bundle = [ordered]@{
        ReportPath = $reportPath
        SummaryJsonPath = $summaryPath
        SnippetPath = $snippetPath
        GateStatus = if ($null -ne $summaryPayload -and $summaryPayload.PSObject.Properties["gate_status"]) { [string]$summaryPayload.gate_status } else { "BLOCKED" }
        Counts = if ($null -ne $summaryPayload -and $summaryPayload.PSObject.Properties["counts"]) { $summaryPayload.counts } else { $null }
        Summary = $summaryPayload
        StrictMode = [bool]$FailOnWarning
        RequireReleasePipeline = [bool]$RequireReleasePipeline
        BundleCommandSucceeded = $false
        Error = $bundleError
    }
}

$counts = $bundle.Counts
$passCount = if ($null -ne $counts -and $counts.PSObject.Properties["pass"]) { [string]$counts.pass } else { "n/a" }
$warnCount = if ($null -ne $counts -and $counts.PSObject.Properties["warn"]) { [string]$counts.warn } else { "n/a" }
$failCount = if ($null -ne $counts -and $counts.PSObject.Properties["fail"]) { [string]$counts.fail } else { "n/a" }
$blockCount = if ($null -ne $counts -and $counts.PSObject.Properties["blocking"]) { [string]$counts.blocking } else { "n/a" }

$status = if ($null -ne $bundle.GateStatus -and -not [string]::IsNullOrWhiteSpace($bundle.GateStatus)) { $bundle.GateStatus } else { "UNKNOWN" }
$snippetText = Get-TextOrEmpty -Path $snippetPath

$statusLine = if ($bundle.BundleCommandSucceeded) {
    "Bundle status: **Succeeded**"
} else {
    "Bundle status: **Failed** (synced from latest generated artifacts when available)"
}

$blockLines = @(
    $MarkerStart,
    "## Release readiness handoff",
    "",
    $statusLine,
    "- Gate: **$status**",
    "- PASS: $passCount",
    "- WARN: $warnCount",
    "- FAIL: $failCount",
    "- Blocking: $blockCount",
    "- RequireReleasePipeline: $($bundle.RequireReleasePipeline)",
    "- FailOnWarning: $($bundle.StrictMode)",
    ""
)

if (-not [string]::IsNullOrWhiteSpace($bundleError)) {
    $blockLines += ("- Note: " + [Environment]::NewLine + "- $bundleError")
    $blockLines += ""
}

if (-not [string]::IsNullOrWhiteSpace($snippetText)) {
    $blockLines += '```text'
    $blockLines += $snippetText.Trim()
    $blockLines += '```'
}
else {
    $blockLines += "No snippet content was generated."
}

$blockLines += ""
$blockLines += $MarkerEnd
$handoffBlock = $blockLines -join [Environment]::NewLine

if ($DryRun -or $targets -eq 0) {
    Write-Output $handoffBlock
    if ($DryRun) { return }
}

if ($targets -eq 0) {
    return
}

function Merge-Or-AppendText {
    param([string]$OriginalText, [string]$NewBlock)
    $start = [System.Text.RegularExpressions.Regex]::Escape($MarkerStart)
    $end = [System.Text.RegularExpressions.Regex]::Escape($MarkerEnd)
    $pattern = "(?s)$start.*?$end"
    if ($OriginalText -match $pattern) {
        return [regex]::Replace($OriginalText, $pattern, $NewBlock)
    }
    if ([string]::IsNullOrWhiteSpace($OriginalText)) {
        return $NewBlock
    }
    return "$OriginalText`r`n`r`n$NewBlock"
}

if ($PullRequestNumber -gt 0) {
    $viewJson = gh pr view $PullRequestNumber --json body
    if ($LASTEXITCODE -ne 0) { throw "Unable to read PR body for #$PullRequestNumber. Check gh auth and PR number." }
    $prBody = ($viewJson | ConvertFrom-Json).body
    if ($null -eq $prBody) { $prBody = "" }
    $updatedBody = Merge-Or-AppendText -OriginalText ([string]$prBody) -NewBlock $handoffBlock
    $tmp = Join-Path $env:TEMP "ai-testpilot-readiness-pr-$PullRequestNumber-body.md"
    Set-Content -Path $tmp -Encoding UTF8 -Value $updatedBody
    gh pr edit $PullRequestNumber --body-file $tmp | Out-Null
    Write-Output "Updated PR body: #$PullRequestNumber"
    return
}

if ($IssueNumber -gt 0) {
    $viewJson = gh issue view $IssueNumber --json body
    if ($LASTEXITCODE -ne 0) { throw "Unable to read issue body for #$IssueNumber. Check gh auth and issue number." }
    $issueBody = ($viewJson | ConvertFrom-Json).body
    if ($null -eq $issueBody) { $issueBody = "" }
    $updatedBody = Merge-Or-AppendText -OriginalText ([string]$issueBody) -NewBlock $handoffBlock
    $tmp = Join-Path $env:TEMP "ai-testpilot-readiness-issue-$IssueNumber-body.md"
    Set-Content -Path $tmp -Encoding UTF8 -Value $updatedBody
    gh issue edit $IssueNumber --body-file $tmp | Out-Null
    Write-Output "Updated issue body: #$IssueNumber"
    return
}

if ($MilestoneNumber -gt 0) {
    $repo = (gh repo view --json nameWithOwner -q ".nameWithOwner").Trim()
    if ([string]::IsNullOrWhiteSpace($repo)) {
        throw "Unable to resolve current repository context via 'gh repo view'."
    }

    $milestoneJson = gh api -H "Accept: application/vnd.github+json" "repos/$repo/milestones/$MilestoneNumber"
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read milestone #$MilestoneNumber."
    }
    $existing = ($milestoneJson | ConvertFrom-Json).description
    if ($null -eq $existing) { $existing = "" }

    $description = Merge-Or-AppendText -OriginalText ([string]$existing) -NewBlock $handoffBlock

    $payload = @{ description = $description } | ConvertTo-Json -Depth 5
    $tmp = Join-Path $env:TEMP "ai-testpilot-readiness-milestone-$MilestoneNumber.json"
    Set-Content -Path $tmp -Encoding UTF8 -Value $payload
    gh api -X PATCH -H "Accept: application/vnd.github+json" "repos/$repo/milestones/$MilestoneNumber" --input $tmp | Out-Null
    Write-Output "Updated milestone description: #$MilestoneNumber"
}
