<#
.SYNOPSIS
Run a local AITestPilot preflight bundle.

.DESCRIPTION
Executes a curated sequence of local verification commands for development and PR readiness:
- Run-DevGate
- Validate-AITestPilot
- Optional strict CI gate path regression checks (can be skipped)

The command stops on first failure unless -ContinueOnFailure is set.

.PARAMETER SummaryPath
Output path for the preflight JSON summary.

.PARAMETER SkipStrictPathRegression
Skips the strict alias-conflict path regression step.

.PARAMETER ContinueOnFailure
Continue through failures and emit a summary with failed steps.

.PARAMETER PreflightManifestPath
Legacy compatibility argument; currently recorded in summary metadata.

.EXAMPLE
PS> .\tools\Invoke-AITestPilotLocalPreflight.ps1

.EXAMPLE
PS> .\tools\Invoke-AITestPilotLocalPreflight.ps1 -SkipStrictPathRegression
#>
[CmdletBinding()]
param(
    [string]$SummaryPath = "Temp\preflight-summary.json",
    [switch]$SkipStrictPathRegression,
    [switch]$ContinueOnFailure,
    [string]$PreflightManifestPath = "Temp\preflight-manifest.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Push-Location $repoRoot

try {
    function Invoke-Step {
        param(
            [string]$Name,
            [scriptblock]$Action,
            [string]$Command
        )

        Write-Host "=> $Name"

        try {
            # Capture command output so only the structured step result is returned.
            $null = & $Action
            if ($LASTEXITCODE -ne 0) {
                throw "Command failed with exit code $LASTEXITCODE"
            }
            return [pscustomobject]@{
                name = $Name
                script = $Command
                status = "PASS"
                args = ""
                error = ""
            }
        }
        catch {
            if (-not $ContinueOnFailure) {
                throw "Preflight step '$Name' failed: $($_.Exception.Message)"
            }
            Write-Host "  Skipping stop due to -ContinueOnFailure: $($_.Exception.Message)"
            return [pscustomobject]@{
                name = $Name
                script = $Command
                status = "FAIL"
                args = ""
                error = $_.Exception.Message
            }
        }
    }

    $steps = @(
        (Invoke-Step -Name "Run-DevGate" -Command ".\tools\Run-DevGate.ps1" -Action { & (Join-Path $PSScriptRoot "Run-DevGate.ps1") }),
        (Invoke-Step -Name "Validate-AITestPilot" -Command ".\tools\Validate-AITestPilot.ps1" -Action { & (Join-Path $PSScriptRoot "Validate-AITestPilot.ps1") }),
        (Invoke-Step -Name "Run-CiGatePathRegression" -Command ".\tools\Validate-AITestPilot.ps1 -RunCiGatePathRegression" -Action { & (Join-Path $PSScriptRoot "Validate-AITestPilot.ps1") -RunCiGatePathRegression }),
        (Invoke-Step -Name "Run-CiGatePathRegressionStrict" -Command ".\tools\Validate-AITestPilot.ps1 -RunCiGatePathRegressionStrict" -Action { & (Join-Path $PSScriptRoot "Validate-AITestPilot.ps1") -RunCiGatePathRegressionStrict })
    )

    if ($SkipStrictPathRegression) {
        $steps = @($steps | Where-Object { $_.name -ne "Run-CiGatePathRegressionStrict" })
        Write-Host "=> Skipped strict CI gate path regression (requested by -SkipStrictPathRegression)"
    }

    $failed = @($steps | Where-Object { $_.status -eq "FAIL" })
    $summary = [ordered]@{
        started_utc = (Get-Date).ToUniversalTime().ToString("o")
        preflight_manifest = $PreflightManifestPath
        steps = @($steps)
        status = if ($failed.Count -gt 0) { "FAIL" } else { "PASS" }
        failed_steps = @($failed | ForEach-Object { $_.name })
    }

    $summaryFullPath = Join-Path $repoRoot $SummaryPath
    $summaryDir = Split-Path $summaryFullPath -Parent
    if (-not (Test-Path $summaryDir)) {
        New-Item -ItemType Directory -Force $summaryDir | Out-Null
    }

    Set-Content -Path $summaryFullPath -Value ($summary | ConvertTo-Json -Depth 10) -Encoding UTF8
    Write-Host ""
    Write-Host "AI TestPilot local preflight summary:"
    Write-Host ($summary | ConvertTo-Json -Depth 10)

    if ($failed.Count -gt 0) {
        throw "Preflight failed. See summary: $SummaryPath"
    }

    Write-Host "PASS local preflight completed"
    exit 0
}
finally {
    Pop-Location
}
