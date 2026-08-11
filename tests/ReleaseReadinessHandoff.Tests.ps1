param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$scriptsDir = Join-Path $repoRoot "tools"
$setScript = Join-Path $scriptsDir "Set-AITestPilotReleaseReadinessMilestoneNotes.ps1"
$exportScript = Join-Path $scriptsDir "Export-AITestPilotReleaseReadinessHandoff.ps1"

if (-not (Test-Path $setScript)) {
    throw "Set-AITestPilotReleaseReadinessMilestoneNotes.ps1 not found at $setScript"
}
if (-not (Test-Path $exportScript)) {
    throw "Export-AITestPilotReleaseReadinessHandoff.ps1 not found at $exportScript"
}

Describe "Release readiness handoff scripts" {
    It "throws when multiple targets are specified for Set script" {
        $threw = $false
        $message = ""
        try {
            & $setScript -NoIncludeRecommendedCommands -PullRequestNumber 12 -IssueNumber 34
        }
        catch {
            $threw = $true
            $message = $_.Exception.Message
        }

        $threw | Should Be $true
        ($message -match "Specify only one target at most among -PullRequestNumber, -IssueNumber, -MilestoneNumber.") | Should Be $true
    }

    It "throws when both include and no-include switches are used together in Set script" {
        $threw = $false
        $message = ""
        try {
            & $setScript -DryRun -IncludeRecommendedCommands -NoIncludeRecommendedCommands
        }
        catch {
            $threw = $true
            $message = $_.Exception.Message
        }

        $threw | Should Be $true
        ($message -match "Specify only one of -IncludeRecommendedCommands or -NoIncludeRecommendedCommands.") | Should Be $true
    }

    It "throws when both include and no-include switches are used together in Export script" {
        $threw = $false
        $message = ""
        try {
            & $exportScript -OutputPath (Join-Path $TestDrive "ignore.md") -IncludeRecommendedCommands -NoIncludeRecommendedCommands
        }
        catch {
            $threw = $true
            $message = $_.Exception.Message
        }

        $threw | Should Be $true
        ($message -match "Specify only one of -IncludeRecommendedCommands or -NoIncludeRecommendedCommands.") | Should Be $true
    }

    It "requires gh CLI before syncing handoff content to PR, issue, or milestone targets" {
        $threw = $false
        $message = ""

        $originalPath = $env:Path
        $isolatedPath = Join-Path $TestDrive "no-gh"
        if (-not (Test-Path $isolatedPath)) {
            New-Item -ItemType Directory -Path $isolatedPath | Out-Null
        }
        $env:Path = $isolatedPath
        try {
            & $setScript -PullRequestNumber 77 -NoIncludeRecommendedCommands
        }
        catch {
            $threw = $true
            $message = $_.Exception.Message
        }
        finally {
            $env:Path = $originalPath
        }

        $threw | Should Be $true
        ($message -match "GitHub CLI \(gh\) is required to sync to PR/issue/milestone targets") | Should Be $true
    }

    It "does not require gh CLI when PR sync is run in DryRun mode" {
        $threw = $false
        $output = $null

        $originalPath = $env:Path
        $isolatedPath = Join-Path $TestDrive "no-gh-dryrun-pr"
        if (-not (Test-Path $isolatedPath)) {
            New-Item -ItemType Directory -Path $isolatedPath | Out-Null
        }
        $env:Path = $isolatedPath
        try {
            $output = & $setScript -PullRequestNumber 77 -DryRun -NoIncludeRecommendedCommands
        }
        catch {
            $threw = $true
        }
        finally {
            $env:Path = $originalPath
        }

        $threw | Should Be $false
        $outputText = $output | Out-String
        ($outputText -match "<!-- ai-testpilot-release-readiness:start -->") | Should Be $true
        ($outputText -match "## Release readiness handoff") | Should Be $true
        ($outputText -match "Bundle status: \*\*") | Should Be $true
    }

    It "uses default recommended-command mode in PR DryRun (include recommended by default)" {
        $threw = $false
        $output = $null
        $reportPathRelative = Join-Path "Temp" "no-gh-pr-report.md"
        $reportPath = Join-Path $repoRoot $reportPathRelative

        $originalPath = $env:Path
        $isolatedPath = Join-Path $TestDrive "no-gh-dryrun-pr-default"
        if (-not (Test-Path $isolatedPath)) {
            New-Item -ItemType Directory -Path $isolatedPath | Out-Null
        }
        $env:Path = $isolatedPath
        try {
            $output = & $setScript -PullRequestNumber 77 -DryRun -ReportOutputPath $reportPathRelative
        }
        catch {
            $threw = $true
        }
        finally {
            $env:Path = $originalPath
        }

        $threw | Should Be $false
        $outputText = $output | Out-String
        ($outputText -match "<!-- ai-testpilot-release-readiness:start -->") | Should Be $true
        (Test-Path $reportPath) | Should Be $true
        $reportText = Get-Content -Path $reportPath -Raw
        ($reportText -match "## 2\) Recommended command sequence \(mainline\)") | Should Be $true
    }

    It "omits recommended-command mode when NoIncludeRecommendedCommands is used in PR DryRun" {
        $threw = $false
        $output = $null
        $reportPathRelative = Join-Path "Temp" "no-gh-pr-report-noinclude.md"
        $reportPath = Join-Path $repoRoot $reportPathRelative

        $originalPath = $env:Path
        $isolatedPath = Join-Path $TestDrive "no-gh-dryrun-pr-default"
        if (-not (Test-Path $isolatedPath)) {
            New-Item -ItemType Directory -Path $isolatedPath | Out-Null
        }
        $env:Path = $isolatedPath
        try {
            $output = & $setScript -PullRequestNumber 77 -DryRun -NoIncludeRecommendedCommands -ReportOutputPath $reportPathRelative
        }
        catch {
            $threw = $true
        }
        finally {
            $env:Path = $originalPath
        }

        $threw | Should Be $false
        (Test-Path $reportPath) | Should Be $true
        $reportText = Get-Content -Path $reportPath -Raw
        ($reportText -match "## 2\) Recommended command sequence \(mainline\)") | Should Be $false
    }

    It "allows explicit IncludeRecommendedCommands in PR DryRun and preserves custom markers" {
        $threw = $false
        $output = $null
        $startMarker = "<!-- custom-pr-dryrun-start -->"
        $endMarker = "<!-- custom-pr-dryrun-end -->"
        $reportPathRelative = Join-Path "Temp" "no-gh-pr-report-include.md"
        $reportPath = Join-Path $repoRoot $reportPathRelative

        $originalPath = $env:Path
        $isolatedPath = Join-Path $TestDrive "no-gh-dryrun-pr-include"
        if (-not (Test-Path $isolatedPath)) {
            New-Item -ItemType Directory -Path $isolatedPath | Out-Null
        }
        $env:Path = $isolatedPath
        try {
            $output = & $setScript -PullRequestNumber 77 -DryRun -IncludeRecommendedCommands `
                -MarkerStart $startMarker -MarkerEnd $endMarker -ReportOutputPath $reportPathRelative
        }
        catch {
            $threw = $true
        }
        finally {
            $env:Path = $originalPath
        }

        $threw | Should Be $false
        $outputText = $output | Out-String
        ($outputText -match [regex]::Escape($startMarker)) | Should Be $true
        ($outputText -match [regex]::Escape($endMarker)) | Should Be $true
        ($outputText -match [regex]::Escape("<!-- ai-testpilot-release-readiness:start -->")) | Should Be $false
        (Test-Path $reportPath) | Should Be $true
        $reportText = Get-Content -Path $reportPath -Raw
        ($reportText -match "## 2\) Recommended command sequence \(mainline\)") | Should Be $true
    }

    It "filters snippet checks to non-passing entries when IncludeFailedOnly is used in PR DryRun" {
        $threw = $false
        $output = $null
        $reportPathRelative = Join-Path "Temp" "no-gh-pr-report-failedonly.md"
        $reportPath = Join-Path $repoRoot $reportPathRelative

        $originalPath = $env:Path
        $isolatedPath = Join-Path $TestDrive "no-gh-dryrun-pr-failedonly"
        if (-not (Test-Path $isolatedPath)) {
            New-Item -ItemType Directory -Path $isolatedPath | Out-Null
        }
        $env:Path = $isolatedPath
        try {
            $output = & $setScript -PullRequestNumber 77 -DryRun -IncludeFailedOnly -ReportOutputPath $reportPathRelative
        }
        catch {
            $threw = $true
        }
        finally {
            $env:Path = $originalPath
        }

        $threw | Should Be $false
        $outputText = $output | Out-String
        ($outputText -match "<!-- ai-testpilot-release-readiness:start -->") | Should Be $true
        (Test-Path $reportPath) | Should Be $true

        $match = [regex]::Match($outputText, '(?s)```text\r?\n(?<snippet>.*?)\r?\n```')
        if (-not $match.Success) {
            throw "Expected snippet block not found."
        }
        $snippetText = $match.Groups["snippet"].Value
        ($snippetText -match "- \[x\]") | Should Be $false
    }

    It "combines IncludeFailedOnly and NoIncludeRecommendedCommands in PR DryRun" {
        $threw = $false
        $output = $null
        $reportPathRelative = Join-Path "Temp" "no-gh-pr-report-failedonly-noinclude.md"
        $reportPath = Join-Path $repoRoot $reportPathRelative

        $originalPath = $env:Path
        $isolatedPath = Join-Path $TestDrive "no-gh-dryrun-pr-failedonly-noinclude"
        if (-not (Test-Path $isolatedPath)) {
            New-Item -ItemType Directory -Path $isolatedPath | Out-Null
        }
        $env:Path = $isolatedPath
        try {
            $output = & $setScript -PullRequestNumber 77 -DryRun -IncludeFailedOnly -NoIncludeRecommendedCommands -ReportOutputPath $reportPathRelative
        }
        catch {
            $threw = $true
        }
        finally {
            $env:Path = $originalPath
        }

        $threw | Should Be $false
        $outputText = $output | Out-String
        ($outputText -match "<!-- ai-testpilot-release-readiness:start -->") | Should Be $true
        (Test-Path $reportPath) | Should Be $true

        $report = Get-Content -Path $reportPath -Raw
        ($report -match "## 2\) Recommended command sequence \(mainline\)") | Should Be $false

        $match = [regex]::Match($outputText, '(?s)```text\r?\n(?<snippet>.*?)\r?\n```')
        if (-not $match.Success) {
            throw "Expected snippet block not found."
        }
        $snippetText = $match.Groups["snippet"].Value
        ($snippetText -match "- \[x\]") | Should Be $false
    }

    It "does not require gh CLI when Issue sync is run in DryRun mode" {
        $threw = $false
        $output = $null

        $originalPath = $env:Path
        $isolatedPath = Join-Path $TestDrive "no-gh-dryrun-issue"
        if (-not (Test-Path $isolatedPath)) {
            New-Item -ItemType Directory -Path $isolatedPath | Out-Null
        }
        $env:Path = $isolatedPath
        try {
            $output = & $setScript -IssueNumber 456 -DryRun -NoIncludeRecommendedCommands
        }
        catch {
            $threw = $true
        }
        finally {
            $env:Path = $originalPath
        }

        $threw | Should Be $false
        $outputText = $output | Out-String
        ($outputText -match "<!-- ai-testpilot-release-readiness:start -->") | Should Be $true
        ($outputText -match "## Release readiness handoff") | Should Be $true
        ($outputText -match "Bundle status: \*\*") | Should Be $true
    }

    It "uses default recommended-command mode in Issue DryRun (include recommended by default)" {
        $threw = $false
        $output = $null
        $reportPathRelative = Join-Path "Temp" "no-gh-issue-report.md"
        $reportPath = Join-Path $repoRoot $reportPathRelative

        $originalPath = $env:Path
        $isolatedPath = Join-Path $TestDrive "no-gh-dryrun-issue-default"
        if (-not (Test-Path $isolatedPath)) {
            New-Item -ItemType Directory -Path $isolatedPath | Out-Null
        }
        $env:Path = $isolatedPath
        try {
            $output = & $setScript -IssueNumber 456 -DryRun -ReportOutputPath $reportPathRelative
        }
        catch {
            $threw = $true
        }
        finally {
            $env:Path = $originalPath
        }

        $threw | Should Be $false
        $outputText = $output | Out-String
        ($outputText -match "<!-- ai-testpilot-release-readiness:start -->") | Should Be $true
        (Test-Path $reportPath) | Should Be $true
        $reportText = Get-Content -Path $reportPath -Raw
        ($reportText -match "## 2\) Recommended command sequence \(mainline\)") | Should Be $true
    }

    It "allows explicit IncludeRecommendedCommands in Issue DryRun and preserves custom markers" {
        $threw = $false
        $output = $null
        $startMarker = "<!-- custom-issue-dryrun-start -->"
        $endMarker = "<!-- custom-issue-dryrun-end -->"
        $reportPathRelative = Join-Path "Temp" "no-gh-issue-report-include.md"
        $reportPath = Join-Path $repoRoot $reportPathRelative

        $originalPath = $env:Path
        $isolatedPath = Join-Path $TestDrive "no-gh-dryrun-issue-include"
        if (-not (Test-Path $isolatedPath)) {
            New-Item -ItemType Directory -Path $isolatedPath | Out-Null
        }
        $env:Path = $isolatedPath
        try {
            $output = & $setScript -IssueNumber 456 -DryRun -IncludeRecommendedCommands `
                -MarkerStart $startMarker -MarkerEnd $endMarker -ReportOutputPath $reportPathRelative
        }
        catch {
            $threw = $true
        }
        finally {
            $env:Path = $originalPath
        }

        $threw | Should Be $false
        $outputText = $output | Out-String
        ($outputText -match [regex]::Escape($startMarker)) | Should Be $true
        ($outputText -match [regex]::Escape($endMarker)) | Should Be $true
        ($outputText -match [regex]::Escape("<!-- ai-testpilot-release-readiness:start -->")) | Should Be $false
        (Test-Path $reportPath) | Should Be $true
        $reportText = Get-Content -Path $reportPath -Raw
        ($reportText -match "## 2\) Recommended command sequence \(mainline\)") | Should Be $true
    }

    It "combines IncludeFailedOnly and NoIncludeRecommendedCommands in Issue DryRun" {
        $threw = $false
        $output = $null
        $reportPathRelative = Join-Path "Temp" "no-gh-issue-report-failedonly-noinclude.md"
        $reportPath = Join-Path $repoRoot $reportPathRelative

        $originalPath = $env:Path
        $isolatedPath = Join-Path $TestDrive "no-gh-dryrun-issue-failedonly-noinclude"
        if (-not (Test-Path $isolatedPath)) {
            New-Item -ItemType Directory -Path $isolatedPath | Out-Null
        }
        $env:Path = $isolatedPath
        try {
            $output = & $setScript -IssueNumber 456 -DryRun -IncludeFailedOnly -NoIncludeRecommendedCommands -ReportOutputPath $reportPathRelative
        }
        catch {
            $threw = $true
        }
        finally {
            $env:Path = $originalPath
        }

        $threw | Should Be $false
        $outputText = $output | Out-String
        ($outputText -match "<!-- ai-testpilot-release-readiness:start -->") | Should Be $true
        (Test-Path $reportPath) | Should Be $true

        $report = Get-Content -Path $reportPath -Raw
        ($report -match "## 2\) Recommended command sequence \(mainline\)") | Should Be $false

        $match = [regex]::Match($outputText, '(?s)```text\r?\n(?<snippet>.*?)\r?\n```')
        if (-not $match.Success) {
            throw "Expected snippet block not found."
        }
        $snippetText = $match.Groups["snippet"].Value
        ($snippetText -match "- \[x\]") | Should Be $false
    }

    It "does not require gh CLI when Milestone sync is run in DryRun mode" {
        $threw = $false
        $output = $null

        $originalPath = $env:Path
        $isolatedPath = Join-Path $TestDrive "no-gh-dryrun-milestone"
        if (-not (Test-Path $isolatedPath)) {
            New-Item -ItemType Directory -Path $isolatedPath | Out-Null
        }
        $env:Path = $isolatedPath
        try {
            $output = & $setScript -MilestoneNumber 7 -DryRun -NoIncludeRecommendedCommands
        }
        catch {
            $threw = $true
        }
        finally {
            $env:Path = $originalPath
        }

        $threw | Should Be $false
        $outputText = $output | Out-String
        ($outputText -match "<!-- ai-testpilot-release-readiness:start -->") | Should Be $true
        ($outputText -match "## Release readiness handoff") | Should Be $true
        ($outputText -match "Bundle status: \*\*") | Should Be $true
    }

    It "uses default recommended-command mode in Milestone DryRun (include recommended by default)" {
        $threw = $false
        $output = $null
        $reportPathRelative = Join-Path "Temp" "no-gh-milestone-report.md"
        $reportPath = Join-Path $repoRoot $reportPathRelative

        $originalPath = $env:Path
        $isolatedPath = Join-Path $TestDrive "no-gh-dryrun-milestone-default"
        if (-not (Test-Path $isolatedPath)) {
            New-Item -ItemType Directory -Path $isolatedPath | Out-Null
        }
        $env:Path = $isolatedPath
        try {
            $output = & $setScript -MilestoneNumber 7 -DryRun -ReportOutputPath $reportPathRelative
        }
        catch {
            $threw = $true
        }
        finally {
            $env:Path = $originalPath
        }

        $threw | Should Be $false
        $outputText = $output | Out-String
        ($outputText -match "<!-- ai-testpilot-release-readiness:start -->") | Should Be $true
        (Test-Path $reportPath) | Should Be $true
        $reportText = Get-Content -Path $reportPath -Raw
        ($reportText -match "## 2\) Recommended command sequence \(mainline\)") | Should Be $true
    }

    It "allows explicit IncludeRecommendedCommands in Milestone DryRun and preserves custom markers" {
        $threw = $false
        $output = $null
        $startMarker = "<!-- custom-milestone-dryrun-start -->"
        $endMarker = "<!-- custom-milestone-dryrun-end -->"
        $reportPathRelative = Join-Path "Temp" "no-gh-milestone-report-include.md"
        $reportPath = Join-Path $repoRoot $reportPathRelative

        $originalPath = $env:Path
        $isolatedPath = Join-Path $TestDrive "no-gh-dryrun-milestone-include"
        if (-not (Test-Path $isolatedPath)) {
            New-Item -ItemType Directory -Path $isolatedPath | Out-Null
        }
        $env:Path = $isolatedPath
        try {
            $output = & $setScript -MilestoneNumber 7 -DryRun -IncludeRecommendedCommands `
                -MarkerStart $startMarker -MarkerEnd $endMarker -ReportOutputPath $reportPathRelative
        }
        catch {
            $threw = $true
        }
        finally {
            $env:Path = $originalPath
        }

        $threw | Should Be $false
        $outputText = $output | Out-String
        ($outputText -match [regex]::Escape($startMarker)) | Should Be $true
        ($outputText -match [regex]::Escape($endMarker)) | Should Be $true
        ($outputText -match [regex]::Escape("<!-- ai-testpilot-release-readiness:start -->")) | Should Be $false
        (Test-Path $reportPath) | Should Be $true
        $reportText = Get-Content -Path $reportPath -Raw
        ($reportText -match "## 2\) Recommended command sequence \(mainline\)") | Should Be $true
    }

    It "combines IncludeFailedOnly and NoIncludeRecommendedCommands in Milestone DryRun" {
        $threw = $false
        $output = $null
        $reportPathRelative = Join-Path "Temp" "no-gh-milestone-report-failedonly-noinclude.md"
        $reportPath = Join-Path $repoRoot $reportPathRelative

        $originalPath = $env:Path
        $isolatedPath = Join-Path $TestDrive "no-gh-dryrun-milestone-failedonly-noinclude"
        if (-not (Test-Path $isolatedPath)) {
            New-Item -ItemType Directory -Path $isolatedPath | Out-Null
        }
        $env:Path = $isolatedPath
        try {
            $output = & $setScript -MilestoneNumber 7 -DryRun -IncludeFailedOnly -NoIncludeRecommendedCommands -ReportOutputPath $reportPathRelative
        }
        catch {
            $threw = $true
        }
        finally {
            $env:Path = $originalPath
        }

        $threw | Should Be $false
        $outputText = $output | Out-String
        ($outputText -match "<!-- ai-testpilot-release-readiness:start -->") | Should Be $true
        (Test-Path $reportPath) | Should Be $true

        $report = Get-Content -Path $reportPath -Raw
        ($report -match "## 2\) Recommended command sequence \(mainline\)") | Should Be $false

        $match = [regex]::Match($outputText, '(?s)```text\r?\n(?<snippet>.*?)\r?\n```')
        if (-not $match.Success) {
            throw "Expected snippet block not found."
        }
        $snippetText = $match.Groups["snippet"].Value
        ($snippetText -match "- \[x\]") | Should Be $false
    }

    It "replaces an existing PR handoff marker block during sync instead of appending duplicates" {
        $fakeGhDir = Join-Path $TestDrive "fake-gh"
        if (-not (Test-Path $fakeGhDir)) {
            New-Item -ItemType Directory -Path $fakeGhDir | Out-Null
        }

        $capturePath = Join-Path $fakeGhDir "last-pr-body.md"
        $statePath = Join-Path $fakeGhDir "gh-state.json"
        $startMarker = "<!-- ai-testpilot-release-readiness:start -->"
        $endMarker = "<!-- ai-testpilot-release-readiness:end -->"
        $existingBody = @"
## PR Title

Some intro text.

$startMarker
## Release readiness handoff

- Gate: **OLD**
- PASS: 0
- WARN: 0
- FAIL: 0
- Blocking: 0

$endMarker

Trailing section.
"@
        @{
            ExistingPrBody = $existingBody
            LastPrEditBodyPath = $capturePath
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $statePath -Encoding UTF8

        Set-Content -Path (Join-Path $fakeGhDir "gh-fake.ps1") -Encoding UTF8 -Value @"
param([Parameter(ValueFromRemainingArguments)] [string[]]`$Args)

`$scriptRoot = Split-Path -Parent `$MyInvocation.MyCommand.Path
`$statePath = Join-Path `$scriptRoot "gh-state.json"
`$state = @{}
if (Test-Path `$statePath) {
    try {
        `$state = Get-Content -Path `$statePath -Encoding UTF8 -Raw | ConvertFrom-Json
    }
    catch {
        `$state = @{}
    }
}

if (`$Args.Count -lt 2) { exit 1 }

if (`$Args[0] -eq "pr" -and `$Args[1] -eq "view") {
    `$body = [string](`$state.ExistingPrBody)
    @{ body = `$body } | ConvertTo-Json -Depth 5
    return
}

if (`$Args[0] -eq "pr" -and `$Args[1] -eq "edit") {
    `$bodyFile = `$Args[3]
    if (`$bodyFile -eq "--body-file" -and `$Args.Count -gt 4) {
        `$bodyFile = `$Args[4]
    }
    if (-not (Test-Path `$bodyFile)) { exit 1 }
    Copy-Item -Path `$bodyFile -Destination `$state.LastPrEditBodyPath -Force
    return
}

exit 1
"@
        Set-Content -Path (Join-Path $fakeGhDir "gh.cmd") -Encoding UTF8 -Value @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gh-fake.ps1" %*
"@

        $originalPath = $env:Path
        $env:Path = "$fakeGhDir;$originalPath"
        try {
            & $setScript -PullRequestNumber 77 -NoIncludeRecommendedCommands
        }
        finally {
            $env:Path = $originalPath
        }

        if (-not (Test-Path $capturePath)) {
            throw "Expected PR update body capture file to be created."
        }
        $updatedBody = Get-Content -Path $capturePath -Raw -Encoding UTF8

        (([regex]::Matches($updatedBody, [regex]::Escape($startMarker)).Count) -eq 1) | Should Be $true
        (([regex]::Matches($updatedBody, [regex]::Escape($endMarker)).Count) -eq 1) | Should Be $true
        ($updatedBody -match "## Release readiness handoff") | Should Be $true
        ($updatedBody -match "Some intro text.") | Should Be $true
        ($updatedBody -match "Trailing section.") | Should Be $true
        ($updatedBody -notmatch "Gate: \*\*OLD\*\*") | Should Be $true
        ($updatedBody -match "Bundle status: \*\*") | Should Be $true
    }

    It "replaces an existing PR handoff marker block with custom markers during sync" {
        $fakeGhDir = Join-Path $TestDrive "fake-gh-custom-pr"
        if (-not (Test-Path $fakeGhDir)) {
            New-Item -ItemType Directory -Path $fakeGhDir | Out-Null
        }

        $capturePath = Join-Path $fakeGhDir "last-pr-body.md"
        $statePath = Join-Path $fakeGhDir "gh-state.json"
        $startMarker = "<!-- custom-pr-start -->"
        $endMarker = "<!-- custom-pr-end -->"
        $existingBody = @"
## PR Title

Some intro text.

$startMarker
## Release readiness handoff

- Gate: **OLD**
- PASS: 0
- WARN: 0
- FAIL: 0
- Blocking: 0

$endMarker

Trailing section.
"@
        @{
            ExistingPrBody = $existingBody
            LastPrEditBodyPath = $capturePath
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $statePath -Encoding UTF8

        Set-Content -Path (Join-Path $fakeGhDir "gh-fake.ps1") -Encoding UTF8 -Value @"
param([Parameter(ValueFromRemainingArguments)] [string[]]`$Args)

`$scriptRoot = Split-Path -Parent `$MyInvocation.MyCommand.Path
`$statePath = Join-Path `$scriptRoot "gh-state.json"
`$state = @{}
if (Test-Path `$statePath) {
    try {
        `$state = Get-Content -Path `$statePath -Encoding UTF8 -Raw | ConvertFrom-Json
    }
    catch {
        `$state = @{}
    }
}

if (`$Args.Count -lt 2) { exit 1 }

if (`$Args[0] -eq "pr" -and `$Args[1] -eq "view") {
    `$body = [string](`$state.ExistingPrBody)
    @{ body = `$body } | ConvertTo-Json -Depth 5
    return
}

if (`$Args[0] -eq "pr" -and `$Args[1] -eq "edit") {
    `$bodyFileIndex = [Array]::IndexOf(`$Args, "--body-file")
    `$bodyFile = `$null
    if (`$bodyFileIndex -ge 0 -and (`$bodyFileIndex + 1) -lt `$Args.Count) {
        `$bodyFile = `$Args[`$bodyFileIndex + 1]
    }
    else {
        `$bodyFile = `$Args[`$Args.Length - 1]
    }

    if (-not (Test-Path `$bodyFile)) { exit 1 }
    Copy-Item -Path `$bodyFile -Destination `$state.LastPrEditBodyPath -Force
    return
}

exit 1
"@
        Set-Content -Path (Join-Path $fakeGhDir "gh.cmd") -Encoding UTF8 -Value @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gh-fake.ps1" %*
"@

        $originalPath = $env:Path
        $env:Path = "$fakeGhDir;$originalPath"
        try {
            & $setScript -PullRequestNumber 77 -NoIncludeRecommendedCommands -MarkerStart $startMarker -MarkerEnd $endMarker
        }
        finally {
            $env:Path = $originalPath
        }

        if (-not (Test-Path $capturePath)) {
            throw "Expected PR update body capture file to be created."
        }
        $updatedBody = Get-Content -Path $capturePath -Raw -Encoding UTF8

        (([regex]::Matches($updatedBody, [regex]::Escape($startMarker)).Count) -eq 1) | Should Be $true
        (([regex]::Matches($updatedBody, [regex]::Escape($endMarker)).Count) -eq 1) | Should Be $true
        ($updatedBody -match "## Release readiness handoff") | Should Be $true
        ($updatedBody -match "Some intro text.") | Should Be $true
        ($updatedBody -match "Trailing section.") | Should Be $true
        ($updatedBody -notmatch "Gate: \*\*OLD\*\*") | Should Be $true
        ($updatedBody -match [regex]::Escape("<!-- ai-testpilot-release-readiness:start -->")) | Should Be $false
        ($updatedBody -match [regex]::Escape("<!-- ai-testpilot-release-readiness:end -->")) | Should Be $false
    }

    It "uses default recommended-command mode in PR sync (include recommended by default)" {
        $fakeGhDir = Join-Path $TestDrive "fake-gh-pr-default-include"
        if (-not (Test-Path $fakeGhDir)) {
            New-Item -ItemType Directory -Path $fakeGhDir | Out-Null
        }
        $reportPathRelative = Join-Path "Temp" "no-gh-pr-sync-default-report.md"
        $reportPath = Join-Path $repoRoot $reportPathRelative

        $capturePath = Join-Path $fakeGhDir "last-pr-body.md"
        $statePath = Join-Path $fakeGhDir "gh-state.json"
        $existingBody = @"
## PR Title

Existing PR body with setup notes.
"@
        @{
            ExistingPrBody = $existingBody
            LastPrEditBodyPath = $capturePath
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $statePath -Encoding UTF8

        Set-Content -Path (Join-Path $fakeGhDir "gh-fake.ps1") -Encoding UTF8 -Value @"
param([Parameter(ValueFromRemainingArguments)] [string[]]`$Args)

`$scriptRoot = Split-Path -Parent `$MyInvocation.MyCommand.Path
`$statePath = Join-Path `$scriptRoot "gh-state.json"
`$state = @{}
if (Test-Path `$statePath) {
    try {
        `$state = Get-Content -Path `$statePath -Encoding UTF8 -Raw | ConvertFrom-Json
    }
    catch {
        `$state = @{}
    }
}

if (`$Args.Count -lt 2) { exit 1 }

if (`$Args[0] -eq "pr" -and `$Args[1] -eq "view") {
    `$body = [string](`$state.ExistingPrBody)
    @{ body = `$body } | ConvertTo-Json -Depth 5
    return
}

if (`$Args[0] -eq "pr" -and `$Args[1] -eq "edit") {
    `$bodyFile = `$Args[3]
    if (`$bodyFile -eq "--body-file" -and `$Args.Count -gt 4) {
        `$bodyFile = `$Args[4]
    }
    if (-not (Test-Path `$bodyFile)) { exit 1 }
    Copy-Item -Path `$bodyFile -Destination `$state.LastPrEditBodyPath -Force
    return
}

exit 1
"@
        Set-Content -Path (Join-Path $fakeGhDir "gh.cmd") -Encoding UTF8 -Value @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gh-fake.ps1" %*
"@

        $originalPath = $env:Path
        $env:Path = "$fakeGhDir;$originalPath"
        try {
            & $setScript -PullRequestNumber 77 -ReportOutputPath $reportPathRelative
        }
        finally {
            $env:Path = $originalPath
        }

        if (-not (Test-Path $capturePath)) {
            throw "Expected PR update body capture file to be created."
        }
        $updatedBody = Get-Content -Path $capturePath -Raw -Encoding UTF8
        (Test-Path $reportPath) | Should Be $true
        $reportText = Get-Content -Path $reportPath -Raw
        ($reportText -match "## 2\) Recommended command sequence \(mainline\)") | Should Be $true

        ($updatedBody -match "Existing PR body with setup notes.") | Should Be $true
        ($updatedBody -match "Bundle status: \*\*") | Should Be $true
    }

    It "syncs filtered PR handoff snippet when IncludeFailedOnly and NoIncludeRecommendedCommands are used" {
        $fakeGhDir = Join-Path $TestDrive "fake-gh-pr-failedonly-noinclude"
        if (-not (Test-Path $fakeGhDir)) {
            New-Item -ItemType Directory -Path $fakeGhDir | Out-Null
        }

        $capturePath = Join-Path $fakeGhDir "last-pr-body.md"
        $statePath = Join-Path $fakeGhDir "gh-state.json"
        $startMarker = "<!-- ai-testpilot-release-readiness:start -->"
        $endMarker = "<!-- ai-testpilot-release-readiness:end -->"
        $existingBody = @"
## PR Title

Existing PR body with setup notes.
"@
        @{
            ExistingPrBody = $existingBody
            LastPrEditBodyPath = $capturePath
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $statePath -Encoding UTF8

        Set-Content -Path (Join-Path $fakeGhDir "gh-fake.ps1") -Encoding UTF8 -Value @"
param([Parameter(ValueFromRemainingArguments)] [string[]]`$Args)

`$scriptRoot = Split-Path -Parent `$MyInvocation.MyCommand.Path
`$statePath = Join-Path `$scriptRoot "gh-state.json"
`$state = @{}
if (Test-Path `$statePath) {
    try {
        `$state = Get-Content -Path `$statePath -Encoding UTF8 -Raw | ConvertFrom-Json
    }
    catch {
        `$state = @{}
    }
}

if (`$Args.Count -lt 2) { exit 1 }

if (`$Args[0] -eq "pr" -and `$Args[1] -eq "view") {
    `$body = [string](`$state.ExistingPrBody)
    @{ body = `$body } | ConvertTo-Json -Depth 5
    return
}

if (`$Args[0] -eq "pr" -and `$Args[1] -eq "edit") {
    `$bodyFile = `$Args[3]
    if (`$bodyFile -eq "--body-file" -and `$Args.Count -gt 4) {
        `$bodyFile = `$Args[4]
    }
    if (-not (Test-Path `$bodyFile)) { exit 1 }
    Copy-Item -Path `$bodyFile -Destination `$state.LastPrEditBodyPath -Force
    return
}

exit 1
"@
        Set-Content -Path (Join-Path $fakeGhDir "gh.cmd") -Encoding UTF8 -Value @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gh-fake.ps1" %*
"@

        $originalPath = $env:Path
        $env:Path = "$fakeGhDir;$originalPath"
        try {
            & $setScript -PullRequestNumber 77 -IncludeFailedOnly -NoIncludeRecommendedCommands
        }
        finally {
            $env:Path = $originalPath
        }

        if (-not (Test-Path $capturePath)) {
            throw "Expected PR update body capture file to be created."
        }
        $updatedBody = Get-Content -Path $capturePath -Raw -Encoding UTF8

        (([regex]::Matches($updatedBody, [regex]::Escape($startMarker)).Count) -eq 1) | Should Be $true
        (([regex]::Matches($updatedBody, [regex]::Escape($endMarker)).Count) -eq 1) | Should Be $true
        ($updatedBody -match "Existing PR body with setup notes.") | Should Be $true
        ($updatedBody -match "## 2\) Recommended command sequence \(mainline\)") | Should Be $false

        $match = [regex]::Match($updatedBody, '(?s)```text\r?\n(?<snippet>.*?)\r?\n```')
        if (-not $match.Success) {
            throw "Expected snippet block not found."
        }
        $snippetText = $match.Groups["snippet"].Value
        ($snippetText -match "- \[x\]") | Should Be $false
    }

    It "throws readable error when PR metadata returned by gh is not valid JSON" {
        $fakeGhDir = Join-Path $TestDrive "fake-gh-pr-bad-json"
        if (-not (Test-Path $fakeGhDir)) {
            New-Item -ItemType Directory -Path $fakeGhDir | Out-Null
        }

        Set-Content -Path (Join-Path $fakeGhDir "gh-fake.ps1") -Encoding UTF8 -Value @"
param([Parameter(ValueFromRemainingArguments)] [string[]]`$Args)

if (`$Args.Count -ge 2 -and `$Args[0] -eq "pr" -and `$Args[1] -eq "view") {
    Write-Output "not-json"
    exit 0
}

exit 1
"@
        Set-Content -Path (Join-Path $fakeGhDir "gh.cmd") -Encoding UTF8 -Value @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gh-fake.ps1" %*
"@

        $threw = $false
        $message = ""
        $originalPath = $env:Path
        $env:Path = "$fakeGhDir;$originalPath"
        try {
            & $setScript -PullRequestNumber 99 -NoIncludeRecommendedCommands
        }
        catch {
            $threw = $true
            $message = $_.Exception.Message
        }
        finally {
            $env:Path = $originalPath
        }

        $threw | Should Be $true
        ($message -match "Unable to parse JSON from GitHub response for PR #99") | Should Be $true
    }

    It "fails with clear error when PR handoff body update via gh fails" {
        $fakeGhDir = Join-Path $TestDrive "fake-gh-pr-fail-edit"
        if (-not (Test-Path $fakeGhDir)) {
            New-Item -ItemType Directory -Path $fakeGhDir | Out-Null
        }

        $statePath = Join-Path $fakeGhDir "gh-state.json"
        @{
            ExistingPrBody = "initial body"
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $statePath -Encoding UTF8

        Set-Content -Path (Join-Path $fakeGhDir "gh-fake.ps1") -Encoding UTF8 -Value @"
param([Parameter(ValueFromRemainingArguments)] [string[]]`$Args)

`$scriptRoot = Split-Path -Parent `$MyInvocation.MyCommand.Path
`$statePath = Join-Path `$scriptRoot "gh-state.json"
`$state = @{}
if (Test-Path `$statePath) {
    try { `$state = Get-Content -Path `$statePath -Encoding UTF8 -Raw | ConvertFrom-Json } catch { `$state = @{} }
}

if (`$Args.Count -lt 2) { exit 1 }

if (`$Args[0] -eq "pr" -and `$Args[1] -eq "view") {
    `$body = [string](`$state.ExistingPrBody)
    @{ body = `$body } | ConvertTo-Json -Depth 5
    return
}

if (`$Args[0] -eq "pr" -and `$Args[1] -eq "edit") {
    if (`$Args.Count -gt 2) { exit 1 }
    return
}

exit 1
"@
        Set-Content -Path (Join-Path $fakeGhDir "gh.cmd") -Encoding UTF8 -Value @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gh-fake.ps1" %*
"@

        $threw = $false
        $message = ""
        $originalPath = $env:Path
        $env:Path = "$fakeGhDir;$originalPath"
        try {
            & $setScript -PullRequestNumber 88 -NoIncludeRecommendedCommands
        }
        catch {
            $threw = $true
            $message = $_.Exception.Message
        }
        finally {
            $env:Path = $originalPath
        }

        $threw | Should Be $true
        ($message -match "Unable to update PR body for #88") | Should Be $true
    }

    It "appends a handoff block to issue body when no existing marker is present" {
        $fakeGhDir = Join-Path $TestDrive "fake-gh-issue"
        if (-not (Test-Path $fakeGhDir)) {
            New-Item -ItemType Directory -Path $fakeGhDir | Out-Null
        }

        $capturePath = Join-Path $fakeGhDir "last-issue-body.md"
        $statePath = Join-Path $fakeGhDir "gh-state.json"
        $startMarker = "<!-- ai-testpilot-release-readiness:start -->"
        $endMarker = "<!-- ai-testpilot-release-readiness:end -->"
        $existingBody = @"
## Issue Title

Existing issue body with setup notes.
"@
        @{
            ExistingIssueBody = $existingBody
            LastIssueEditBodyPath = $capturePath
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $statePath -Encoding UTF8

        Set-Content -Path (Join-Path $fakeGhDir "gh-fake.ps1") -Encoding UTF8 -Value @"
param([Parameter(ValueFromRemainingArguments)] [string[]]`$Args)

`$scriptRoot = Split-Path -Parent `$MyInvocation.MyCommand.Path
`$statePath = Join-Path `$scriptRoot "gh-state.json"
`$state = @{}
if (Test-Path `$statePath) {
    try {
        `$state = Get-Content -Path `$statePath -Encoding UTF8 -Raw | ConvertFrom-Json
    }
    catch {
        `$state = @{}
    }
}

if (`$Args.Count -lt 2) { exit 1 }

if (`$Args[0] -eq "issue" -and `$Args[1] -eq "view") {
    `$body = [string](`$state.ExistingIssueBody)
    @{ body = `$body } | ConvertTo-Json -Depth 5
    return
}

if (`$Args[0] -eq "issue" -and `$Args[1] -eq "edit") {
    `$bodyFile = `$null
    `$bodyFileIndex = [Array]::IndexOf(`$Args, "--body-file")
    if (`$bodyFileIndex -ge 0 -and (`$bodyFileIndex + 1) -lt `$Args.Count) {
        `$bodyFile = `$Args[`$bodyFileIndex + 1]
    }
    else {
        `$bodyFile = `$Args[`$Args.Length - 1]
    }
    if (-not (Test-Path `$bodyFile)) { exit 1 }
    Copy-Item -Path `$bodyFile -Destination `$state.LastIssueEditBodyPath -Force
    return
}

exit 1
"@
        Set-Content -Path (Join-Path $fakeGhDir "gh.cmd") -Encoding UTF8 -Value @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gh-fake.ps1" %*
"@

        $originalPath = $env:Path
        $env:Path = "$fakeGhDir;$originalPath"
        try {
            & $setScript -IssueNumber 456 -NoIncludeRecommendedCommands
        }
        finally {
            $env:Path = $originalPath
        }

        if (-not (Test-Path $capturePath)) {
            throw "Expected issue update body capture file to be created."
        }
        $updatedBody = Get-Content -Path $capturePath -Raw -Encoding UTF8

        ($updatedBody -match [regex]::Escape($startMarker)) | Should Be $true
        ($updatedBody -match [regex]::Escape($endMarker)) | Should Be $true
        ($updatedBody -match "Existing issue body with setup notes.") | Should Be $true
        ($updatedBody -match "Bundle status: \*\*") | Should Be $true
        (([regex]::Matches($updatedBody, [regex]::Escape($startMarker)).Count) -eq 1) | Should Be $true
    }

    It "replaces an existing issue handoff marker block during sync" {
        $fakeGhDir = Join-Path $TestDrive "fake-gh-issue-custom"
        if (-not (Test-Path $fakeGhDir)) {
            New-Item -ItemType Directory -Path $fakeGhDir | Out-Null
        }

        $capturePath = Join-Path $fakeGhDir "last-issue-body.md"
        $statePath = Join-Path $fakeGhDir "gh-state.json"
        $startMarker = "<!-- custom-issue-start -->"
        $endMarker = "<!-- custom-issue-end -->"
        $existingBody = @"
## Issue Title

Existing issue body with setup notes.

$startMarker
## Release readiness handoff

- Gate: **OLD**
- PASS: 0
- WARN: 0
- FAIL: 0
- Blocking: 0

$endMarker
"@
        @{
            ExistingIssueBody = $existingBody
            LastIssueEditBodyPath = $capturePath
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $statePath -Encoding UTF8

        Set-Content -Path (Join-Path $fakeGhDir "gh-fake.ps1") -Encoding UTF8 -Value @"
param([Parameter(ValueFromRemainingArguments)] [string[]]`$Args)

`$scriptRoot = Split-Path -Parent `$MyInvocation.MyCommand.Path
`$statePath = Join-Path `$scriptRoot "gh-state.json"
`$state = @{}
if (Test-Path `$statePath) {
    try { `$state = Get-Content -Path `$statePath -Encoding UTF8 -Raw | ConvertFrom-Json } catch { `$state = @{} }
}

if (`$Args.Count -lt 2) { exit 1 }

if (`$Args[0] -eq "issue" -and `$Args[1] -eq "view") {
    `$body = [string](`$state.ExistingIssueBody)
    @{ body = `$body } | ConvertTo-Json -Depth 5
    return
}

if (`$Args[0] -eq "issue" -and `$Args[1] -eq "edit") {
    `$bodyFile = `$null
    `$bodyFileIndex = [Array]::IndexOf(`$Args, "--body-file")
    if (`$bodyFileIndex -ge 0 -and (`$bodyFileIndex + 1) -lt `$Args.Count) {
        `$bodyFile = `$Args[`$bodyFileIndex + 1]
    }
    else {
        `$bodyFile = `$Args[`$Args.Length - 1]
    }
    if (-not (Test-Path `$bodyFile)) { exit 1 }
    Copy-Item -Path `$bodyFile -Destination `$state.LastIssueEditBodyPath -Force
    return
}

exit 1
"@
        Set-Content -Path (Join-Path $fakeGhDir "gh.cmd") -Encoding UTF8 -Value @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gh-fake.ps1" %*
"@

        $originalPath = $env:Path
        $env:Path = "$fakeGhDir;$originalPath"
        try {
            & $setScript -IssueNumber 789 -NoIncludeRecommendedCommands -MarkerStart $startMarker -MarkerEnd $endMarker
        }
        finally {
            $env:Path = $originalPath
        }

        if (-not (Test-Path $capturePath)) {
            throw "Expected issue update body capture file to be created."
        }
        $updatedBody = Get-Content -Path $capturePath -Raw -Encoding UTF8

        (([regex]::Matches($updatedBody, [regex]::Escape($startMarker)).Count) -eq 1) | Should Be $true
        (([regex]::Matches($updatedBody, [regex]::Escape($endMarker)).Count) -eq 1) | Should Be $true
        ($updatedBody -match "Existing issue body with setup notes.") | Should Be $true
        ($updatedBody -notmatch "Gate: \*\*OLD\*\*") | Should Be $true
        ($updatedBody -match [regex]::Escape("<!-- ai-testpilot-release-readiness:start -->")) | Should Be $false
        ($updatedBody -match [regex]::Escape("<!-- ai-testpilot-release-readiness:end -->")) | Should Be $false
    }

    It "syncs filtered issue handoff snippet when IncludeFailedOnly and NoIncludeRecommendedCommands are used" {
        $fakeGhDir = Join-Path $TestDrive "fake-gh-issue-failedonly-noinclude"
        if (-not (Test-Path $fakeGhDir)) {
            New-Item -ItemType Directory -Path $fakeGhDir | Out-Null
        }

        $capturePath = Join-Path $fakeGhDir "last-issue-body.md"
        $statePath = Join-Path $fakeGhDir "gh-state.json"
        $existingBody = @"
## Issue Title

Existing issue body with setup notes.
"@
        @{
            ExistingIssueBody = $existingBody
            LastIssueEditBodyPath = $capturePath
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $statePath -Encoding UTF8

        Set-Content -Path (Join-Path $fakeGhDir "gh-fake.ps1") -Encoding UTF8 -Value @"
param([Parameter(ValueFromRemainingArguments)] [string[]]`$Args)

`$scriptRoot = Split-Path -Parent `$MyInvocation.MyCommand.Path
`$statePath = Join-Path `$scriptRoot "gh-state.json"
`$state = @{}
if (Test-Path `$statePath) {
    try {
        `$state = Get-Content -Path `$statePath -Encoding UTF8 -Raw | ConvertFrom-Json
    }
    catch {
        `$state = @{}
    }
}

if (`$Args.Count -lt 2) { exit 1 }

if (`$Args[0] -eq "issue" -and `$Args[1] -eq "view") {
    `$body = [string](`$state.ExistingIssueBody)
    @{ body = `$body } | ConvertTo-Json -Depth 5
    return
}

if (`$Args[0] -eq "issue" -and `$Args[1] -eq "edit") {
    `$bodyFile = `$null
    `$bodyFileIndex = [Array]::IndexOf(`$Args, "--body-file")
    if (`$bodyFileIndex -ge 0 -and (`$bodyFileIndex + 1) -lt `$Args.Count) {
        `$bodyFile = `$Args[`$bodyFileIndex + 1]
    }
    else {
        `$bodyFile = `$Args[`$Args.Length - 1]
    }
    if (-not (Test-Path `$bodyFile)) { exit 1 }
    Copy-Item -Path `$bodyFile -Destination `$state.LastIssueEditBodyPath -Force
    return
}

exit 1
"@
        Set-Content -Path (Join-Path $fakeGhDir "gh.cmd") -Encoding UTF8 -Value @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gh-fake.ps1" %*
"@

        $originalPath = $env:Path
        $env:Path = "$fakeGhDir;$originalPath"
        try {
            & $setScript -IssueNumber 456 -IncludeFailedOnly -NoIncludeRecommendedCommands
        }
        finally {
            $env:Path = $originalPath
        }

        if (-not (Test-Path $capturePath)) {
            throw "Expected issue update body capture file to be created."
        }
        $updatedBody = Get-Content -Path $capturePath -Raw -Encoding UTF8

        ($updatedBody -match "Existing issue body with setup notes.") | Should Be $true
        ($updatedBody -match "## 2\) Recommended command sequence \(mainline\)") | Should Be $false

        $match = [regex]::Match($updatedBody, '(?s)```text\r?\n(?<snippet>.*?)\r?\n```')
        if (-not $match.Success) {
            throw "Expected snippet block not found."
        }
        $snippetText = $match.Groups["snippet"].Value
        ($snippetText -match "- \[x\]") | Should Be $false
    }

    It "uses default recommended-command mode in issue sync (include recommended by default)" {
        $fakeGhDir = Join-Path $TestDrive "fake-gh-issue-default-include"
        if (-not (Test-Path $fakeGhDir)) {
            New-Item -ItemType Directory -Path $fakeGhDir | Out-Null
        }
        $reportPathRelative = Join-Path "Temp" "no-gh-issue-sync-default-report.md"
        $reportPath = Join-Path $repoRoot $reportPathRelative

        $capturePath = Join-Path $fakeGhDir "last-issue-body.md"
        $statePath = Join-Path $fakeGhDir "gh-state.json"
        $existingBody = @"
## Issue Title

Existing issue body with setup notes.
"@
        @{
            ExistingIssueBody = $existingBody
            LastIssueEditBodyPath = $capturePath
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $statePath -Encoding UTF8

        Set-Content -Path (Join-Path $fakeGhDir "gh-fake.ps1") -Encoding UTF8 -Value @"
param([Parameter(ValueFromRemainingArguments)] [string[]]`$Args)

`$scriptRoot = Split-Path -Parent `$MyInvocation.MyCommand.Path
`$statePath = Join-Path `$scriptRoot "gh-state.json"
`$state = @{}
if (Test-Path `$statePath) {
    try {
        `$state = Get-Content -Path `$statePath -Encoding UTF8 -Raw | ConvertFrom-Json
    }
    catch {
        `$state = @{}
    }
}

if (`$Args.Count -lt 2) { exit 1 }

if (`$Args[0] -eq "issue" -and `$Args[1] -eq "view") {
    `$body = [string](`$state.ExistingIssueBody)
    @{ body = `$body } | ConvertTo-Json -Depth 5
    return
}

if (`$Args[0] -eq "issue" -and `$Args[1] -eq "edit") {
    `$bodyFile = `$null
    `$bodyFileIndex = [Array]::IndexOf(`$Args, "--body-file")
    if (`$bodyFileIndex -ge 0 -and (`$bodyFileIndex + 1) -lt `$Args.Count) {
        `$bodyFile = `$Args[`$bodyFileIndex + 1]
    }
    else {
        `$bodyFile = `$Args[`$Args.Length - 1]
    }
    if (-not (Test-Path `$bodyFile)) { exit 1 }
    Copy-Item -Path `$bodyFile -Destination `$state.LastIssueEditBodyPath -Force
    return
}

exit 1
"@
        Set-Content -Path (Join-Path $fakeGhDir "gh.cmd") -Encoding UTF8 -Value @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gh-fake.ps1" %*
"@

        $originalPath = $env:Path
        $env:Path = "$fakeGhDir;$originalPath"
        try {
            & $setScript -IssueNumber 456 -ReportOutputPath $reportPathRelative
        }
        finally {
            $env:Path = $originalPath
        }

        if (-not (Test-Path $capturePath)) {
            throw "Expected issue update body capture file to be created."
        }
        $updatedBody = Get-Content -Path $capturePath -Raw -Encoding UTF8
        (Test-Path $reportPath) | Should Be $true
        $reportText = Get-Content -Path $reportPath -Raw
        ($reportText -match "## 2\) Recommended command sequence \(mainline\)") | Should Be $true

        ($updatedBody -match "Existing issue body with setup notes.") | Should Be $true
        ($updatedBody -match "Bundle status: \*\*") | Should Be $true
    }

    It "throws readable error when issue metadata returned by gh is not valid JSON" {
        $fakeGhDir = Join-Path $TestDrive "fake-gh-issue-bad-json"
        if (-not (Test-Path $fakeGhDir)) {
            New-Item -ItemType Directory -Path $fakeGhDir | Out-Null
        }

        Set-Content -Path (Join-Path $fakeGhDir "gh-fake.ps1") -Encoding UTF8 -Value @"
param([Parameter(ValueFromRemainingArguments)] [string[]]`$Args)

if (`$Args.Count -ge 2 -and `$Args[0] -eq "issue" -and `$Args[1] -eq "view") {
    Write-Output "not-json"
    exit 0
}

exit 1
"@
        Set-Content -Path (Join-Path $fakeGhDir "gh.cmd") -Encoding UTF8 -Value @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gh-fake.ps1" %*
"@

        $threw = $false
        $message = ""
        $originalPath = $env:Path
        $env:Path = "$fakeGhDir;$originalPath"
        try {
            & $setScript -IssueNumber 790 -NoIncludeRecommendedCommands
        }
        catch {
            $threw = $true
            $message = $_.Exception.Message
        }
        finally {
            $env:Path = $originalPath
        }

        $threw | Should Be $true
        ($message -match "Unable to parse JSON from GitHub response for issue #790") | Should Be $true
    }

    It "fails with clear error when issue handoff body update via gh fails" {
        $fakeGhDir = Join-Path $TestDrive "fake-gh-issue-fail-edit"
        if (-not (Test-Path $fakeGhDir)) {
            New-Item -ItemType Directory -Path $fakeGhDir | Out-Null
        }

        $statePath = Join-Path $fakeGhDir "gh-state.json"
        @{
            ExistingIssueBody = "init issue body"
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $statePath -Encoding UTF8

        Set-Content -Path (Join-Path $fakeGhDir "gh-fake.ps1") -Encoding UTF8 -Value @"
param([Parameter(ValueFromRemainingArguments)] [string[]]`$Args)

`$scriptRoot = Split-Path -Parent `$MyInvocation.MyCommand.Path
`$statePath = Join-Path `$scriptRoot "gh-state.json"
`$state = @{}
if (Test-Path `$statePath) {
    try { `$state = Get-Content -Path `$statePath -Encoding UTF8 -Raw | ConvertFrom-Json } catch { `$state = @{} }
}

if (`$Args.Count -lt 2) { exit 1 }

if (`$Args[0] -eq "issue" -and `$Args[1] -eq "view") {
    `$body = [string](`$state.ExistingIssueBody)
    @{ body = `$body } | ConvertTo-Json -Depth 5
    return
}

if (`$Args[0] -eq "issue" -and `$Args[1] -eq "edit") {
    exit 1
}

exit 1
"@
        Set-Content -Path (Join-Path $fakeGhDir "gh.cmd") -Encoding UTF8 -Value @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gh-fake.ps1" %*
"@

        $threw = $false
        $message = ""
        $originalPath = $env:Path
        $env:Path = "$fakeGhDir;$originalPath"
        try {
            & $setScript -IssueNumber 456 -NoIncludeRecommendedCommands
        }
        catch {
            $threw = $true
            $message = $_.Exception.Message
        }
        finally {
            $env:Path = $originalPath
        }

        $threw | Should Be $true
        ($message -match "Unable to update issue body for #456") | Should Be $true
    }

    It "syncs handoff block into milestone description with repo path and milestone API shape" {
        $fakeGhDir = Join-Path $TestDrive "fake-gh-milestone"
        if (-not (Test-Path $fakeGhDir)) {
            New-Item -ItemType Directory -Path $fakeGhDir | Out-Null
        }

        $capturePath = Join-Path $fakeGhDir "last-milestone-description.json"
        $statePath = Join-Path $fakeGhDir "gh-state.json"
        @{
            Repository = "owner/repo"
            ExistingMilestoneDescription = "Owner repo release milestone initial description."
            LastMilestoneDescriptionPath = $capturePath
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $statePath -Encoding UTF8

        Set-Content -Path (Join-Path $fakeGhDir "gh-fake.ps1") -Encoding UTF8 -Value @"
param([Parameter(ValueFromRemainingArguments)] [string[]]`$Args)

`$scriptRoot = Split-Path -Parent `$MyInvocation.MyCommand.Path
`$statePath = Join-Path `$scriptRoot "gh-state.json"
`$state = @{}
if (Test-Path `$statePath) {
    try {
        `$state = Get-Content -Path `$statePath -Encoding UTF8 -Raw | ConvertFrom-Json
    }
    catch {
        `$state = @{}
    }
}

if (`$Args.Count -lt 1) { exit 1 }

if (`$Args[0] -eq "repo" -and `$Args[1] -eq "view") {
    Write-Output (`$state.Repository)
    return
}

if (`$Args[0] -eq "api") {
    if (`$Args.Contains("-X") -and `$Args.Contains("PATCH")) {
        `$bodyFileIndex = [Array]::IndexOf(`$Args, "--input")
        if (`$bodyFileIndex -ge 0 -and (`$bodyFileIndex + 1) -lt `$Args.Count) {
            `$bodyFile = `$Args[`$bodyFileIndex + 1]
            if (Test-Path `$bodyFile) {
                Copy-Item -Path `$bodyFile -Destination `$state.LastMilestoneDescriptionPath -Force
                return
            }
        }
        exit 1
    }

    @{ description = `$state.ExistingMilestoneDescription } | ConvertTo-Json -Depth 5
    return
}

exit 1
"@
        Set-Content -Path (Join-Path $fakeGhDir "gh.cmd") -Encoding UTF8 -Value @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gh-fake.ps1" %*
"@

        $originalPath = $env:Path
        $env:Path = "$fakeGhDir;$originalPath"
        try {
            & $setScript -MilestoneNumber 7 -NoIncludeRecommendedCommands
        }
        finally {
            $env:Path = $originalPath
        }

        if (-not (Test-Path $capturePath)) {
            throw "Expected milestone update payload capture file to be created."
        }
        $payload = Get-Content -Path $capturePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $payload.description) {
            throw "Expected description field in milestone PATCH payload."
        }

        $description = [string]$payload.description
        ($description -match "Owner repo release milestone initial description.") | Should Be $true
        ($description -match "<!-- ai-testpilot-release-readiness:start -->") | Should Be $true
        ($description -match "<!-- ai-testpilot-release-readiness:end -->") | Should Be $true
        ($description -match "## Release readiness handoff") | Should Be $true
    }

    It "replaces an existing milestone handoff block in description with custom markers" {
        $fakeGhDir = Join-Path $TestDrive "fake-gh-milestone-custom"
        if (-not (Test-Path $fakeGhDir)) {
            New-Item -ItemType Directory -Path $fakeGhDir | Out-Null
        }

        $capturePath = Join-Path $fakeGhDir "last-milestone-description.json"
        $statePath = Join-Path $fakeGhDir "gh-state.json"
        $startMarker = "<!-- custom-milestone-start -->"
        $endMarker = "<!-- custom-milestone-end -->"
        $existingDescription = @"
Milestone description with rules.

$startMarker
## Release readiness handoff

- Gate: **OLD**
- PASS: 0
- WARN: 0
- FAIL: 0
- Blocking: 0

$endMarker

More details.
"@
        @{
            Repository = "owner/repo"
            ExistingMilestoneDescription = $existingDescription
            LastMilestoneDescriptionPath = $capturePath
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $statePath -Encoding UTF8

        Set-Content -Path (Join-Path $fakeGhDir "gh-fake.ps1") -Encoding UTF8 -Value @"
param([Parameter(ValueFromRemainingArguments)] [string[]]`$Args)

`$scriptRoot = Split-Path -Parent `$MyInvocation.MyCommand.Path
`$statePath = Join-Path `$scriptRoot "gh-state.json"
`$state = @{}
if (Test-Path `$statePath) {
    try { `$state = Get-Content -Path `$statePath -Encoding UTF8 -Raw | ConvertFrom-Json } catch { `$state = @{} }
}

if (`$Args.Count -lt 1) { exit 1 }

if (`$Args[0] -eq "repo" -and `$Args[1] -eq "view") {
    Write-Output (`$state.Repository)
    return
}

if (`$Args[0] -eq "api") {
    if (`$Args.Contains("-X") -and `$Args.Contains("PATCH")) {
        `$bodyFileIndex = [Array]::IndexOf(`$Args, "--input")
        `$bodyFile = `$null
        if (`$bodyFileIndex -ge 0 -and (`$bodyFileIndex + 1) -lt `$Args.Count) {
            `$bodyFile = `$Args[`$bodyFileIndex + 1]
            if (Test-Path `$bodyFile) {
                Copy-Item -Path `$bodyFile -Destination `$state.LastMilestoneDescriptionPath -Force
                return
            }
        }
        exit 1
    }

    @{ description = `$state.ExistingMilestoneDescription } | ConvertTo-Json -Depth 5
    return
}

exit 1
"@
        Set-Content -Path (Join-Path $fakeGhDir "gh.cmd") -Encoding UTF8 -Value @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gh-fake.ps1" %*
"@

        $originalPath = $env:Path
        $env:Path = "$fakeGhDir;$originalPath"
        try {
            & $setScript -MilestoneNumber 17 -NoIncludeRecommendedCommands -MarkerStart $startMarker -MarkerEnd $endMarker
        }
        finally {
            $env:Path = $originalPath
        }

        if (-not (Test-Path $capturePath)) {
            throw "Expected milestone update payload capture file to be created."
        }
        $payload = Get-Content -Path $capturePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $payload.description) {
            throw "Expected description field in milestone PATCH payload."
        }

        $description = [string]$payload.description
        ($description -match [regex]::Escape("Milestone description with rules.")) | Should Be $true
        ($description -match [regex]::Escape("More details.")) | Should Be $true
        ($description -match [regex]::Escape($startMarker)) | Should Be $true
        ($description -match [regex]::Escape($endMarker)) | Should Be $true
        ($description -notmatch "Gate: \*\*OLD\*\*") | Should Be $true
        ($description -match [regex]::Escape("<!-- ai-testpilot-release-readiness:start -->")) | Should Be $false
        ($description -match [regex]::Escape("<!-- ai-testpilot-release-readiness:end -->")) | Should Be $false
    }

    It "uses default recommended-command mode in milestone sync (include recommended by default)" {
        $fakeGhDir = Join-Path $TestDrive "fake-gh-milestone-default-include"
        if (-not (Test-Path $fakeGhDir)) {
            New-Item -ItemType Directory -Path $fakeGhDir | Out-Null
        }
        $reportPathRelative = Join-Path "Temp" "no-gh-milestone-sync-default-report.md"
        $reportPath = Join-Path $repoRoot $reportPathRelative

        $capturePath = Join-Path $fakeGhDir "last-milestone-description.json"
        $statePath = Join-Path $fakeGhDir "gh-state.json"
        @{
            Repository = "owner/repo"
            ExistingMilestoneDescription = "Owner repo release milestone initial description."
            LastMilestoneDescriptionPath = $capturePath
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $statePath -Encoding UTF8

        Set-Content -Path (Join-Path $fakeGhDir "gh-fake.ps1") -Encoding UTF8 -Value @"
param([Parameter(ValueFromRemainingArguments)] [string[]]`$Args)

`$scriptRoot = Split-Path -Parent `$MyInvocation.MyCommand.Path
`$statePath = Join-Path `$scriptRoot "gh-state.json"
`$state = @{}
if (Test-Path `$statePath) {
    try {
        `$state = Get-Content -Path `$statePath -Encoding UTF8 -Raw | ConvertFrom-Json
    }
    catch {
        `$state = @{}
    }
}

if (`$Args.Count -lt 1) { exit 1 }

if (`$Args[0] -eq "repo" -and `$Args[1] -eq "view") {
    Write-Output (`$state.Repository)
    return
}

if (`$Args[0] -eq "api") {
    if (`$Args.Contains("-X") -and `$Args.Contains("PATCH")) {
        `$bodyFileIndex = [Array]::IndexOf(`$Args, "--input")
        if (`$bodyFileIndex -ge 0 -and (`$bodyFileIndex + 1) -lt `$Args.Count) {
            `$bodyFile = `$Args[`$bodyFileIndex + 1]
            if (Test-Path `$bodyFile) {
                Copy-Item -Path `$bodyFile -Destination `$state.LastMilestoneDescriptionPath -Force
                return
            }
        }
        exit 1
    }

    @{ description = `$state.ExistingMilestoneDescription } | ConvertTo-Json -Depth 5
    return
}

exit 1
"@
        Set-Content -Path (Join-Path $fakeGhDir "gh.cmd") -Encoding UTF8 -Value @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gh-fake.ps1" %*
"@

        $originalPath = $env:Path
        $env:Path = "$fakeGhDir;$originalPath"
        try {
            & $setScript -MilestoneNumber 7 -ReportOutputPath $reportPathRelative
        }
        finally {
            $env:Path = $originalPath
        }

        if (-not (Test-Path $capturePath)) {
            throw "Expected milestone update payload capture file to be created."
        }
        $payload = Get-Content -Path $capturePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $payload.description) {
            throw "Expected description field in milestone PATCH payload."
        }

        $description = [string]$payload.description
        ($description -match "Owner repo release milestone initial description.") | Should Be $true
        ($description -match [regex]::Escape("## Release readiness handoff")) | Should Be $true
        (Test-Path $reportPath) | Should Be $true
        $reportText = Get-Content -Path $reportPath -Raw
        ($reportText -match "## 2\) Recommended command sequence \(mainline\)") | Should Be $true
    }

    It "syncs filtered milestone handoff snippet when IncludeFailedOnly and NoIncludeRecommendedCommands are used" {
        $fakeGhDir = Join-Path $TestDrive "fake-gh-milestone-failedonly-noinclude"
        if (-not (Test-Path $fakeGhDir)) {
            New-Item -ItemType Directory -Path $fakeGhDir | Out-Null
        }

        $capturePath = Join-Path $fakeGhDir "last-milestone-description.json"
        $statePath = Join-Path $fakeGhDir "gh-state.json"
        $existingDescription = @"
Milestone description with setup notes.
"@
        @{
            Repository = "owner/repo"
            ExistingMilestoneDescription = $existingDescription
            LastMilestoneDescriptionPath = $capturePath
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $statePath -Encoding UTF8

        Set-Content -Path (Join-Path $fakeGhDir "gh-fake.ps1") -Encoding UTF8 -Value @"
param([Parameter(ValueFromRemainingArguments)] [string[]]`$Args)

`$scriptRoot = Split-Path -Parent `$MyInvocation.MyCommand.Path
`$statePath = Join-Path `$scriptRoot "gh-state.json"
`$state = @{}
if (Test-Path `$statePath) {
    try {
        `$state = Get-Content -Path `$statePath -Encoding UTF8 -Raw | ConvertFrom-Json
    }
    catch {
        `$state = @{}
    }
}

if (`$Args.Count -lt 1) { exit 1 }

if (`$Args[0] -eq "repo" -and `$Args[1] -eq "view") {
    Write-Output (`$state.Repository)
    return
}

if (`$Args[0] -eq "api") {
    if (`$Args.Contains("-X") -and `$Args.Contains("PATCH")) {
        `$bodyFileIndex = [Array]::IndexOf(`$Args, "--input")
        if (`$bodyFileIndex -ge 0 -and (`$bodyFileIndex + 1) -lt `$Args.Count) {
            `$bodyFile = `$Args[`$bodyFileIndex + 1]
            if (Test-Path `$bodyFile) {
                Copy-Item -Path `$bodyFile -Destination `$state.LastMilestoneDescriptionPath -Force
                return
            }
        }
        exit 1
    }

    @{ description = `$state.ExistingMilestoneDescription } | ConvertTo-Json -Depth 5
    return
}

exit 1
"@
        Set-Content -Path (Join-Path $fakeGhDir "gh.cmd") -Encoding UTF8 -Value @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gh-fake.ps1" %*
"@

        $originalPath = $env:Path
        $env:Path = "$fakeGhDir;$originalPath"
        try {
            & $setScript -MilestoneNumber 7 -IncludeFailedOnly -NoIncludeRecommendedCommands
        }
        finally {
            $env:Path = $originalPath
        }

        if (-not (Test-Path $capturePath)) {
            throw "Expected milestone update payload capture file to be created."
        }
        $payload = Get-Content -Path $capturePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $payload.description) {
            throw "Expected description field in milestone PATCH payload."
        }

        $description = [string]$payload.description
        ($description -match "Milestone description with setup notes.") | Should Be $true
        ($description -match "## 2\) Recommended command sequence \(mainline\)") | Should Be $false
        $match = [regex]::Match($description, '(?s)```text\r?\n(?<snippet>.*?)\r?\n```')
        if (-not $match.Success) {
            throw "Expected snippet block not found."
        }
        $snippetText = $match.Groups["snippet"].Value
        ($snippetText -match "- \[x\]") | Should Be $false
    }

    It "throws readable error when milestone metadata returned by gh is not valid JSON" {
        $fakeGhDir = Join-Path $TestDrive "fake-gh-milestone-bad-json"
        if (-not (Test-Path $fakeGhDir)) {
            New-Item -ItemType Directory -Path $fakeGhDir | Out-Null
        }

        Set-Content -Path (Join-Path $fakeGhDir "gh-fake.ps1") -Encoding UTF8 -Value @"
param([Parameter(ValueFromRemainingArguments)] [string[]]`$Args)

if (`$Args.Count -ge 1 -and `$Args[0] -eq "repo" -and `$Args[1] -eq "view") {
    Write-Output "owner/repo"
    return
}

if (`$Args.Count -ge 1 -and `$Args[0] -eq "api") {
    Write-Output "not-json"
    exit 0
}

exit 1
"@
        Set-Content -Path (Join-Path $fakeGhDir "gh.cmd") -Encoding UTF8 -Value @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gh-fake.ps1" %*
"@

        $threw = $false
        $message = ""
        $originalPath = $env:Path
        $env:Path = "$fakeGhDir;$originalPath"
        try {
            & $setScript -MilestoneNumber 17 -NoIncludeRecommendedCommands
        }
        catch {
            $threw = $true
            $message = $_.Exception.Message
        }
        finally {
            $env:Path = $originalPath
        }

        $threw | Should Be $true
        ($message -match "Unable to parse JSON from GitHub response for milestone #17") | Should Be $true
    }

    It "fails with clear error when milestone patch via gh api fails" {
        $fakeGhDir = Join-Path $TestDrive "fake-gh-milestone-fail-patch"
        if (-not (Test-Path $fakeGhDir)) {
            New-Item -ItemType Directory -Path $fakeGhDir | Out-Null
        }

        $statePath = Join-Path $fakeGhDir "gh-state.json"
        @{
            Repository = "owner/repo"
            ExistingMilestoneDescription = "initial description"
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $statePath -Encoding UTF8

        Set-Content -Path (Join-Path $fakeGhDir "gh-fake.ps1") -Encoding UTF8 -Value @"
param([Parameter(ValueFromRemainingArguments)] [string[]]`$Args)

`$scriptRoot = Split-Path -Parent `$MyInvocation.MyCommand.Path
`$statePath = Join-Path `$scriptRoot "gh-state.json"
`$state = @{}
if (Test-Path `$statePath) {
    try { `$state = Get-Content -Path `$statePath -Encoding UTF8 -Raw | ConvertFrom-Json } catch { `$state = @{} }
}

if (`$Args.Count -lt 1) { exit 1 }

if (`$Args[0] -eq "repo" -and `$Args[1] -eq "view") {
    Write-Output (`$state.Repository)
    return
}

if (`$Args[0] -eq "api" -and `$Args.Contains("-X") -and `$Args.Contains("PATCH")) {
    exit 1
}

if (`$Args[0] -eq "api") {
    @{ description = `$state.ExistingMilestoneDescription } | ConvertTo-Json -Depth 5
    return
}

exit 1
"@
        Set-Content -Path (Join-Path $fakeGhDir "gh.cmd") -Encoding UTF8 -Value @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gh-fake.ps1" %*
"@

        $threw = $false
        $message = ""
        $originalPath = $env:Path
        $env:Path = "$fakeGhDir;$originalPath"
        try {
            & $setScript -MilestoneNumber 19 -NoIncludeRecommendedCommands
        }
        catch {
            $threw = $true
            $message = $_.Exception.Message
        }
        finally {
            $env:Path = $originalPath
        }

        $threw | Should Be $true
        ($message -match "Unable to update milestone #19") | Should Be $true
    }

    It "exports a handoff block with marker wrappers" {
        $out = Join-Path $TestDrive "handoff-block.md"
        $result = & $exportScript -OutputPath $out -FailOnWarning -NoIncludeRecommendedCommands
        $resultText = $result | Out-String

        ($resultText -match "Wrote handoff block to:") | Should Be $true
        (Test-Path $out) | Should Be $true

        $content = Get-Content -Path $out -Raw
        ($content -match "<!-- ai-testpilot-release-readiness:start -->") | Should Be $true
        ($content -match "<!-- ai-testpilot-release-readiness:end -->") | Should Be $true
        ($content -match "## Release readiness handoff") | Should Be $true
    }

    It "exports handoff block with recommended command section by default" {
        $out = Join-Path $TestDrive "handoff-block-default-recommend.md"
        $reportOut = Join-Path "Temp" "release-readiness-report-default.md"
        $result = & $exportScript -OutputPath $out -FailOnWarning -ReportOutputPath $reportOut
        $resultText = $result | Out-String

        ($resultText -match "Wrote handoff block to:") | Should Be $true
        (Test-Path $out) | Should Be $true
        (Test-Path $reportOut) | Should Be $true

        $report = Get-Content -Path $reportOut -Raw
        ($report -match "## 2\) Recommended command sequence \(mainline\)") | Should Be $true
    }

    It "allows explicit IncludeRecommendedCommands in export and preserves custom markers" {
        $out = Join-Path $TestDrive "handoff-block-include-custom.md"
        $startMarker = "<!-- custom-export-include-start -->"
        $endMarker = "<!-- custom-export-include-end -->"
        $reportOut = Join-Path "Temp" "release-readiness-report-include.md"

        $result = & $exportScript -OutputPath $out -IncludeRecommendedCommands -MarkerStart $startMarker -MarkerEnd $endMarker -ReportOutputPath $reportOut
        $resultText = $result | Out-String

        ($resultText -match "Wrote handoff block to:") | Should Be $true
        (Test-Path $out) | Should Be $true
        (Test-Path $reportOut) | Should Be $true

        $content = Get-Content -Path $out -Raw
        ($content -match [regex]::Escape($startMarker)) | Should Be $true
        ($content -match [regex]::Escape($endMarker)) | Should Be $true
        ($content -match [regex]::Escape("<!-- ai-testpilot-release-readiness:start -->")) | Should Be $false

        $report = Get-Content -Path $reportOut -Raw
        ($report -match "## 2\) Recommended command sequence \(mainline\)") | Should Be $true
    }

    It "omits recommended command section when NoIncludeRecommendedCommands is used in export" {
        $out = Join-Path $TestDrive "handoff-block-noinclude.md"
        $reportOut = Join-Path "Temp" "release-readiness-report-noinclude.md"
        $result = & $exportScript -OutputPath $out -NoIncludeRecommendedCommands -FailOnWarning -ReportOutputPath $reportOut
        $resultText = $result | Out-String

        ($resultText -match "Wrote handoff block to:") | Should Be $true
        (Test-Path $out) | Should Be $true
        (Test-Path $reportOut) | Should Be $true

        $report = Get-Content -Path $reportOut -Raw
        ($report -match "## 2\) Recommended command sequence \(mainline\)") | Should Be $false
    }

    It "exports handoff snippet with only failed/warning checks when IncludeFailedOnly is enabled" {
        $out = Join-Path $TestDrive "handoff-block-failedonly.md"
        $reportOut = Join-Path "Temp" "release-readiness-report-failedonly.md"
        $snippetOut = Join-Path "Temp" "release-readiness-snippet-failedonly.md"

        $result = & $exportScript `
            -OutputPath $out `
            -IncludeFailedOnly `
            -FailOnWarning `
            -ReportOutputPath $reportOut `
            -SnippetOutputPath $snippetOut
        $resultText = $result | Out-String

        ($resultText -match "Wrote handoff block to:") | Should Be $true
        (Test-Path $out) | Should Be $true
        (Test-Path $snippetOut) | Should Be $true
        $snippetText = Get-Content -Path $snippetOut -Raw
        ($snippetText -match "### Checks") | Should Be $true
        ($snippetText -match "- \[x\]") | Should Be $false
    }

    It "combines IncludeFailedOnly and NoIncludeRecommendedCommands in export" {
        $out = Join-Path $TestDrive "handoff-block-failedonly-noinclude.md"
        $reportOut = Join-Path "Temp" "release-readiness-report-failedonly-noinclude.md"
        $snippetOut = Join-Path "Temp" "release-readiness-snippet-failedonly-noinclude.md"

        $result = & $exportScript `
            -OutputPath $out `
            -IncludeFailedOnly `
            -FailOnWarning `
            -NoIncludeRecommendedCommands `
            -ReportOutputPath $reportOut `
            -SnippetOutputPath $snippetOut
        $resultText = $result | Out-String

        ($resultText -match "Wrote handoff block to:") | Should Be $true
        (Test-Path $out) | Should Be $true
        (Test-Path $reportOut) | Should Be $true
        (Test-Path $snippetOut) | Should Be $true

        $report = Get-Content -Path $reportOut -Raw
        ($report -match "## 2\) Recommended command sequence \(mainline\)") | Should Be $false

        $snippetText = Get-Content -Path $snippetOut -Raw
        ($snippetText -match "### Checks") | Should Be $true
        ($snippetText -match "- \[x\]") | Should Be $false
    }

    It "writes the dry-run handoff block to console output" {
        $output = & $setScript -DryRun -NoIncludeRecommendedCommands
        $outputText = $output | Out-String
        ($outputText -match "<!-- ai-testpilot-release-readiness:start -->") | Should Be $true
        ($outputText -match "## Release readiness handoff") | Should Be $true
    }

    It "defaults to printing handoff to console when no sync target is specified" {
        $output = & $setScript -NoIncludeRecommendedCommands
        $outputText = $output | Out-String
        ($outputText -match "<!-- ai-testpilot-release-readiness:start -->") | Should Be $true
        ($outputText -match "<!-- ai-testpilot-release-readiness:end -->") | Should Be $true
        ($outputText -match "## Release readiness handoff") | Should Be $true
        ($outputText -match "Updated PR body") | Should Be $false
        ($outputText -match "Updated issue body") | Should Be $false
        ($outputText -match "Updated milestone description") | Should Be $false
    }

    It "prevents overwriting an existing output file when NoOverwrite is set" {
        $out = Join-Path $TestDrive "handoff-block.md"
        Set-Content -Path $out -Encoding UTF8 -Value "pre-existing"

        $threw = $false
        $message = ""
        try {
            & $exportScript -OutputPath $out -NoIncludeRecommendedCommands -NoOverwrite
        }
        catch {
            $threw = $true
            $message = $_.Exception.Message
        }

        $threw | Should Be $true
        (Test-Path $out) | Should Be $true
        ($existingContent = Get-Content -Path $out -Raw -Encoding UTF8).TrimEnd("`r", "`n") | Should Be "pre-existing"
        ($message -match "Output file already exists. Re-run without -NoOverwrite to replace") | Should Be $true
    }

    It "respects custom marker names when generating handoff blocks" {
        $startMarker = "<!-- custom-start -->"
        $endMarker = "<!-- custom-end -->"
        $out = Join-Path $TestDrive "custom-marker-handoff.md"

        $result = & $exportScript `
            -OutputPath $out `
            -NoIncludeRecommendedCommands `
            -MarkerStart $startMarker `
            -MarkerEnd $endMarker
        $resultText = $result | Out-String
        ($resultText -match "Wrote handoff block to:") | Should Be $true

        $content = Get-Content -Path $out -Raw
        ($content -match [regex]::Escape($startMarker)) | Should Be $true
        ($content -match [regex]::Escape($endMarker)) | Should Be $true
        ($content -match "<!-- ai-testpilot-release-readiness:start -->") | Should Be $false
        ($content -match "<!-- ai-testpilot-release-readiness:end -->") | Should Be $false

        $dryRunOutput = & $setScript -DryRun -NoIncludeRecommendedCommands -MarkerStart $startMarker -MarkerEnd $endMarker
        $dryRunText = $dryRunOutput | Out-String
        ($dryRunText -match [regex]::Escape($startMarker)) | Should Be $true
        ($dryRunText -match [regex]::Escape($endMarker)) | Should Be $true
        ($dryRunText -match "<!-- ai-testpilot-release-readiness:start -->") | Should Be $false
    }

    It "creates nested output directories automatically for the handoff file" {
        $nestedOut = Join-Path (Join-Path $TestDrive "nested") "artifacts\release\handoff-block.md"

        $result = & $exportScript `
            -OutputPath $nestedOut `
            -FailOnWarning `
            -NoIncludeRecommendedCommands
        $resultText = $result | Out-String

        ($resultText -match "Wrote handoff block to:") | Should Be $true
        (Test-Path $nestedOut) | Should Be $true
    }

    It "prevents overwrite even when nested output path exists" {
        $nestedOut = Join-Path (Join-Path $TestDrive "nested") "artifacts\release\handoff-block.md"
        if (-not (Test-Path (Split-Path $nestedOut -Parent))) {
            New-Item -ItemType Directory -Path (Split-Path $nestedOut -Parent) -Force | Out-Null
        }
        Set-Content -Path $nestedOut -Encoding UTF8 -Value "keep-me"

        $threw = $false
        $message = ""
        try {
            & $exportScript `
                -OutputPath $nestedOut `
                -FailOnWarning `
                -NoIncludeRecommendedCommands `
                -NoOverwrite
        }
        catch {
            $threw = $true
            $message = $_.Exception.Message
        }

        $threw | Should Be $true
        ($content = Get-Content -Path $nestedOut -Raw -Encoding UTF8).TrimEnd("`r", "`n") | Should Be "keep-me"
        ($message -match "Output file already exists. Re-run without -NoOverwrite to replace") | Should Be $true
    }
}
