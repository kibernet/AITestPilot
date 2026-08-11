<#
.SYNOPSIS
Generate a ready-to-paste PR summary block for AITestPilot changes.

.DESCRIPTION
Builds a standardized summary text block with severity, evidence, and reviewer notes.
Useful for PR triage workflows and the "PR summary block" convention in docs/local-workflow-cheat-sheet.md.

.PARAMETER Severity
Failure severity level: 0, 1, or 2.

.PARAMETER Status
Current state for the PR summary. Expected values:
- BLOCKED
- OPEN
- RESOLVED

.PARAMETER LastFailingCommand
The exact command that most recently failed.

.PARAMETER FailureReason
Short failure reason or related ticket/reference.

.PARAMETER ImmediateRemediation
What changed to address the issue.

.PARAMETER RecheckOutput
Result from re-run command (PASS / FAIL/WARN / SKIPPED).

.PARAMETER MergeDecision
Reviewer-facing merge decision:
- DO NOT MERGE
- HOLD
- MERGE

.PARAMETER RootCause
One-line root cause statement.

.PARAMETER WhatWasFixed
What changed to fix the issue.

.PARAMETER WatchPoints
Follow-up risk or watch points.

.PARAMETER OutputPath
Where to write the summary block. If not provided, output is still printed to console.

.PARAMETER CopyToClipboard
Attempt to copy the generated block to clipboard.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet(0, 1, 2)]
    [int]$Severity,

    [Parameter(Mandatory)]
    [ValidateSet("BLOCKED", "OPEN", "RESOLVED")]
    [string]$Status,

    [Parameter(Mandatory)]
    [string]$LastFailingCommand,

    [Parameter(Mandatory)]
    [string]$FailureReason,

    [Parameter(Mandatory)]
    [string]$ImmediateRemediation,

    [Parameter(Mandatory)]
    [ValidateSet("PASS", "WARN", "FAIL/WARN", "SKIPPED")]
    [string]$RecheckOutput,

    [Parameter(Mandatory)]
    [ValidateSet("DO NOT MERGE", "HOLD", "MERGE")]
    [string]$MergeDecision,

    [Parameter(Mandatory)]
    [string]$RootCause,

    [Parameter(Mandatory)]
    [string]$WhatWasFixed,

    [Parameter(Mandatory)]
    [string]$WatchPoints,

    [string]$TempDevGateSummary = "Temp\dev-gate-summary.json",
    [string]$TempQuickStartManifest = "Temp\quick-start\quick-start-manifest.json",
    [string]$TempRepairLoopManifest = "Temp\repair-loop\repair-loop-manifest.json",
    [string]$TempDeveloperGateManifest = "Temp\developer-gate-manifest.json",
    [string]$TempCiGateSummary = "Temp\ci-gate-summary.json",
    [string]$TempReleaseEvidence = "Temp\release-evidence\latest\*",
    [string]$ArtifactsRelease = "artifacts\ai-testpilot-release\latest\*",
    [string]$TempPrChecklist = "Temp\pr-validation-checklist.md",

    [string]$OutputPath,

    [switch]$CopyToClipboard,
    [switch]$AsPrBlock
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$summaryBlock = @"
## PR summary block (ready to paste in Description)

### Severity and outcome
- Severity: $Severity
- Current status: $Status
- Last failing command: $LastFailingCommand
- Failure reason: $FailureReason
- Immediate remediation: $ImmediateRemediation
- Re-check command output: $RecheckOutput

### Evidence
- `Temp\dev-gate-summary.json`: $TempDevGateSummary
- `Temp\quick-start\quick-start-manifest.json`: $TempQuickStartManifest
- `Temp\repair-loop\repair-loop-manifest.json`: $TempRepairLoopManifest
- `Temp\developer-gate-manifest.json`: $TempDeveloperGateManifest
- `Temp\ci-gate-summary.json`: $TempCiGateSummary
- `Temp\release-evidence\latest\*`: $TempReleaseEvidence
- `artifacts\ai-testpilot-release\latest\*`: $ArtifactsRelease
- `Temp\pr-validation-checklist.md`: $TempPrChecklist

### Commit / release decision
- Merge decision: $MergeDecision
- Reviewer-facing notes:
  - root cause: $RootCause
  - what was fixed: $WhatWasFixed
  - remaining risk / watch points: $WatchPoints
"@

if ($AsPrBlock) {
    $summaryBlock = @"
## PR summary block (ready to paste in Description)

**Severity:** $Severity
**Current status:** $Status
**Merge decision:** $MergeDecision

- Last failing command: $LastFailingCommand
- Failure reason: $FailureReason
- Remediation: $ImmediateRemediation
- Re-check result: $RecheckOutput
- Root cause: $RootCause
- What was fixed: $WhatWasFixed
- Watch points: $WatchPoints
"@
}

if ($OutputPath) {
    $outputFullPath = $OutputPath
    $parent = Split-Path $outputFullPath -Parent
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Set-Content -Path $outputFullPath -Value $summaryBlock -Encoding UTF8
    Write-Host "PR summary block written to: $outputFullPath"
}

if ($CopyToClipboard) {
    try {
        $summaryBlock | Set-Clipboard
        Write-Host "PR summary block copied to clipboard."
    }
    catch {
        Write-Host "Clipboard copy not available in this session. Output is still available in console." -ForegroundColor Yellow
    }
}

Write-Output $summaryBlock
