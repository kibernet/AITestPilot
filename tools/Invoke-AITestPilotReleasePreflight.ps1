<#
.SYNOPSIS
Run the release preflight with a local quality baseline and optional full release pipeline.

.DESCRIPTION
This wrapper first executes `Invoke-AITestPilotLocalPreflight.ps1` using release-oriented defaults
(`RunReleaseDocsFreshnessRegression` enabled by default). After local preflight succeeds, it optionally
runs `Invoke-AITestPilotReleasePipeline.ps1` using the same switches you pass to this script.

By default, local preflight + full release pipeline both run. Use `-SkipReleasePipeline`
to run only the local preflight in local environments.

.PARAMETER SummaryPath
Where to write the local preflight JSON summary.

.PARAMETER PreflightManifestPath
Where to write the local preflight manifest JSON.

.PARAMETER UnityPath
Optional Unity executable/path override passed to the release pipeline.

.PARAMETER EvidenceBundleDir
Optional artifact output directory passed to the release pipeline.

.PARAMETER ArtifactDir
Optional artifact root directory passed to the release pipeline.

.PARAMETER ReleaseGateFailureProbeDir
Optional `ReleaseGateFailureProbeDir` passed to the release pipeline.

.PARAMETER CursorAgentOutputDir
Optional output directory containing real Cursor Agent external task-output.

.PARAMETER ProductionLuaEvidenceDir
Optional production Lua evidence directory passed to release checks.

.PARAMETER LiveModelEndpointSmokeEvidenceDir
Optional live-smoke evidence directory passed to release checks.

.PARAMETER CursorAgentModel
Optional model name passed to Cursor Agent when `-UseCursorAgentExternalTaskOutput` is used.

.PARAMETER CursorAgentMaxAttempts
Maximum Cursor Agent attempts before giving up in release pipeline mode.

.PARAMETER CursorAgentRetryDelaySeconds
Delay between Cursor Agent attempts.

.PARAMETER UseCursorAgentExternalTaskOutput
Pass cursor-agent output into the release pipeline.

.PARAMETER RequireProductionReplayDriverBound
Require production replay-driver binding before release gate passes.

.PARAMETER RequireProductionLuaPatched
Require production Lua patches to be accepted before release gate passes.

.PARAMETER RequireLiveModelEndpointSmoke
Require real/required smoke evidence for live model endpoint verification.

.PARAMETER SkipReleasePipeline
Skip running the full release pipeline. Useful for fast local validation.

.PARAMETER RunReleasePipeline
Force running full release pipeline even when `-SkipReleasePipeline` is not set.

.PARAMETER SkipStrictPathRegression
Disable strict path regression check in local preflight.

.PARAMETER SkipDocsFreshnessRegression
Skip the release-docs-freshness regression step in local preflight (defaults to enabled).

.EXAMPLE
.\tools\Invoke-AITestPilotReleasePreflight.ps1

.EXAMPLE
.\tools\Invoke-AITestPilotReleasePreflight.ps1 -SkipReleasePipeline

.EXAMPLE
.\tools\Invoke-AITestPilotReleasePreflight.ps1 -SkipReleasePipeline -SkipStrictPathRegression -SkipDocsFreshnessRegression

.EXAMPLE
.\tools\Invoke-AITestPilotReleasePreflight.ps1 -UseCursorAgentExternalTaskOutput -CursorAgentMaxAttempts 2
#>
[CmdletBinding()]
param(
    [string]$SummaryPath = "Temp\release-preflight-summary.json",
    [string]$PreflightManifestPath = "Temp\release-preflight-manifest.json",
    [string]$UnityPath,
    [string]$EvidenceBundleDir,
    [string]$ArtifactDir,
    [string]$ReleaseGateFailureProbeDir,
    [string]$CursorAgentOutputDir,
    [string]$ProductionLuaEvidenceDir,
    [string]$LiveModelEndpointSmokeEvidenceDir,
    [string]$CursorAgentModel = "",
    [int]$CursorAgentMaxAttempts = 3,
    [int]$CursorAgentRetryDelaySeconds = 2,
    [switch]$UseCursorAgentExternalTaskOutput,
    [switch]$RequireProductionReplayDriverBound,
    [switch]$RequireProductionLuaPatched,
    [switch]$RequireLiveModelEndpointSmoke,
    [switch]$SkipReleasePipeline,
    [switch]$RunReleasePipeline,
    [switch]$SkipStrictPathRegression,
    [switch]$SkipDocsFreshnessRegression
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$localPreflight = Join-Path $PSScriptRoot "Invoke-AITestPilotLocalPreflight.ps1"
$releasePipeline = Join-Path $PSScriptRoot "Invoke-AITestPilotReleasePipeline.ps1"

function Invoke-CommandWithExit {
    param(
        [scriptblock]$Action,
        [string]$Label
    )

    Write-Host "==> $Label"
    & $Action
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE"
    }
}

Write-Host "AI TestPilot release preflight: local quality baseline"

$preflightArgs = @{
    SummaryPath = $SummaryPath
    PreflightManifestPath = $PreflightManifestPath
    RunReleaseDocsFreshnessRegression = $true
}

if ($SkipStrictPathRegression) {
    $preflightArgs["SkipStrictPathRegression"] = $true
}
if ($SkipDocsFreshnessRegression) {
    $preflightArgs.Remove("RunReleaseDocsFreshnessRegression")
}

Invoke-CommandWithExit -Action {
    & $localPreflight @preflightArgs
} -Label "Run local preflight (release mode)"

$shouldRunReleasePipeline = $RunReleasePipeline -or (-not $SkipReleasePipeline)
if ($shouldRunReleasePipeline) {
    $pipelineArgs = @{}

    if (-not [string]::IsNullOrWhiteSpace($UnityPath)) { $pipelineArgs.UnityPath = $UnityPath }
    if (-not [string]::IsNullOrWhiteSpace($EvidenceBundleDir)) { $pipelineArgs.EvidenceBundleDir = $EvidenceBundleDir }
    if (-not [string]::IsNullOrWhiteSpace($ArtifactDir)) { $pipelineArgs.ArtifactDir = $ArtifactDir }
    if (-not [string]::IsNullOrWhiteSpace($CursorAgentOutputDir)) { $pipelineArgs.CursorAgentOutputDir = $CursorAgentOutputDir }
    if (-not [string]::IsNullOrWhiteSpace($ProductionLuaEvidenceDir)) { $pipelineArgs.ProductionLuaEvidenceDir = $ProductionLuaEvidenceDir }
    if (-not [string]::IsNullOrWhiteSpace($LiveModelEndpointSmokeEvidenceDir)) { $pipelineArgs.LiveModelEndpointSmokeEvidenceDir = $LiveModelEndpointSmokeEvidenceDir }
    if (-not [string]::IsNullOrWhiteSpace($ReleaseGateFailureProbeDir)) { $pipelineArgs.ReleaseGateFailureProbeDir = $ReleaseGateFailureProbeDir }
    if (-not [string]::IsNullOrWhiteSpace($CursorAgentModel)) { $pipelineArgs.CursorAgentModel = $CursorAgentModel }
    if ($CursorAgentMaxAttempts -ge 1) { $pipelineArgs.CursorAgentMaxAttempts = $CursorAgentMaxAttempts }
    if ($CursorAgentRetryDelaySeconds -ge 0) { $pipelineArgs.CursorAgentRetryDelaySeconds = $CursorAgentRetryDelaySeconds }
    if ($UseCursorAgentExternalTaskOutput) { $pipelineArgs.UseCursorAgentExternalTaskOutput = $true }
    if ($RequireProductionReplayDriverBound) { $pipelineArgs.RequireProductionReplayDriverBound = $true }
    if ($RequireProductionLuaPatched) { $pipelineArgs.RequireProductionLuaPatched = $true }
    if ($RequireLiveModelEndpointSmoke) { $pipelineArgs.RequireLiveModelEndpointSmoke = $true }

    Invoke-CommandWithExit -Action {
        & $releasePipeline @pipelineArgs
    } -Label "Run full release pipeline"
}

Write-Host "PASS AI TestPilot release preflight"
