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
