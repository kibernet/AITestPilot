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
}

