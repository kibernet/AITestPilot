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
