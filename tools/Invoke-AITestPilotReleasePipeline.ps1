[CmdletBinding()]
param(
    [string]$UnityPath = "F:\Unity\2021_3_45_f2\Editor\Unity.exe",
    [string]$GameReplayDriverType = "Kibernet.AITestPilot.Unity.Editor.SampleGameActionReplayDriver",
    [string]$EvidenceBundleDir,
    [string]$ArtifactDir,
    [string]$ReleaseGateFailureProbeDir,
    [string]$CursorAgentOutputDir,
    [string]$CursorAgentModel = "gpt-5.3-codex-low-fast",
    [switch]$UseCursorAgentExternalTaskOutput,
    [switch]$RequireProductionReplayDriverBound,
    [switch]$RequireLiveModelEndpointSmoke,
    [switch]$AllowMissingModelApiKey,
    [switch]$DisableLiveModelEndpointFailurePolicyRetry,
    [int]$LiveModelEndpointMaxPolicyRetries = 2,
    [int]$LiveModelEndpointMaxRetryBackoffSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ArtifactDir)) {
    $ArtifactDir = Join-Path $repoRoot "artifacts\ai-testpilot-release\latest"
}

if ([string]::IsNullOrWhiteSpace($ReleaseGateFailureProbeDir)) {
    $ReleaseGateFailureProbeDir = Join-Path $repoRoot "Temp\release-evidence\release-gate-failure-probe"
}

if ([string]::IsNullOrWhiteSpace($CursorAgentOutputDir)) {
    $CursorAgentOutputDir = Join-Path $repoRoot "Temp\release-evidence\cursor-agent-external-output"
}

$steps = @()
$pipelineStartedAtUtc = (Get-Date).ToUniversalTime()

function Assert-PathUnderRepo {
    param(
        [string]$Path,
        [string]$Label
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith($script:repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must stay under repo root. Path: $fullPath"
    }

    return $fullPath
}

function Invoke-PipelineStep {
    param(
        [string]$Name,
        [scriptblock]$Command
    )

    $startedAtUtc = (Get-Date).ToUniversalTime()
    Write-Output "==> $Name"
    try {
        & $Command
        $finishedAtUtc = (Get-Date).ToUniversalTime()
        $script:steps += [ordered]@{
            name = $Name
            status = "PASS"
            startedAtUtc = $startedAtUtc.ToString("O")
            finishedAtUtc = $finishedAtUtc.ToString("O")
            durationSeconds = [Math]::Round(($finishedAtUtc - $startedAtUtc).TotalSeconds, 3)
            message = ""
        }
    }
    catch {
        $finishedAtUtc = (Get-Date).ToUniversalTime()
        $script:steps += [ordered]@{
            name = $Name
            status = "FAIL"
            startedAtUtc = $startedAtUtc.ToString("O")
            finishedAtUtc = $finishedAtUtc.ToString("O")
            durationSeconds = [Math]::Round(($finishedAtUtc - $startedAtUtc).TotalSeconds, 3)
            message = $_.Exception.Message
        }
        throw
    }
}

function Export-PipelineArtifacts {
    param(
        [bool]$PipelinePassed
    )

    $artifactPath = Assert-PathUnderRepo $ArtifactDir "ArtifactDir"
    $artifactParent = Split-Path $artifactPath -Parent
    New-Item -ItemType Directory -Force $artifactParent | Out-Null

    if (Test-Path $artifactPath) {
        Remove-Item -LiteralPath $artifactPath -Recurse -Force
    }

    New-Item -ItemType Directory -Force $artifactPath | Out-Null

    if (Test-Path $EvidenceBundleDir) {
        Copy-Item -Path (Join-Path $EvidenceBundleDir "*") -Destination $artifactPath -Recurse -Force
    }

    $pipelineFinishedAtUtc = (Get-Date).ToUniversalTime()
    if ($PipelinePassed) {
        $pipelineStatus = "PASS"
        $ciExitCode = 0
    }
    else {
        $pipelineStatus = "FAIL"
        $ciExitCode = 1
    }

    $manifest = [ordered]@{
        status = $pipelineStatus
        generatedAtUtc = $pipelineFinishedAtUtc.ToString("O")
        startedAtUtc = $pipelineStartedAtUtc.ToString("O")
        finishedAtUtc = $pipelineFinishedAtUtc.ToString("O")
        durationSeconds = [Math]::Round(($pipelineFinishedAtUtc - $pipelineStartedAtUtc).TotalSeconds, 3)
        evidenceBundleDir = $EvidenceBundleDir
        artifactDir = $artifactPath
        gameReplayDriverType = $GameReplayDriverType
        stepCount = $steps.Count
        steps = @($steps)
        ciExitCode = $ciExitCode
    }

    $manifestPath = Join-Path $artifactPath "pipeline-manifest.json"
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8
    Write-Output "Pipeline artifacts: $artifactPath"
    Write-Output "Pipeline manifest: $manifestPath"
}

$pipelinePassed = $false

try {
    Push-Location $repoRoot
    Invoke-PipelineStep "repo_validation" {
        & (Join-Path $repoRoot "tools\Validate-AITestPilot.ps1")
    }

    Invoke-PipelineStep "unity_import_scene_validation" {
        & (Join-Path $repoRoot "tools\Validate-UnityPackageImport.ps1") `
            -UnityPath $UnityPath `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "repair_agent_patch_output_import" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotRepairAgentPatchOutputImport.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir `
            -GenerateSampleOutput
    }

    Invoke-PipelineStep "repair_agent_external_completion_failure_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotRepairAgentExternalCompletionFailureProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "repair_agent_generic_patch_import_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotRepairAgentGenericPatchImportProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "repair_agent_source_snapshot_apply_validate" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotRepairAgentSourceSnapshotApplyValidate.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "repair_agent_main_worktree_apply_readiness" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotMainWorktreeApplyReadiness.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    if ($UseCursorAgentExternalTaskOutput) {
        Invoke-PipelineStep "repair_agent_cursor_agent_external_task_output" {
            & (Join-Path $repoRoot "tools\Invoke-AITestPilotCursorAgentExternalTaskOutput.ps1") `
                -EvidenceBundleDir $EvidenceBundleDir `
                -OutputDir $CursorAgentOutputDir `
                -CursorAgentModel $CursorAgentModel
        }
    }

    Invoke-PipelineStep "repair_agent_external_task_output_acceptance" {
        if ($UseCursorAgentExternalTaskOutput) {
            & (Join-Path $repoRoot "tools\Invoke-AITestPilotRepairAgentExternalTaskOutputAcceptance.ps1") `
                -UnityPath $UnityPath `
                -GameReplayDriverType $GameReplayDriverType `
                -EvidenceBundleDir $EvidenceBundleDir `
                -ExternalOutputDir $CursorAgentOutputDir
        }
        else {
            & (Join-Path $repoRoot "tools\Invoke-AITestPilotRepairAgentExternalTaskOutputAcceptance.ps1") `
                -UnityPath $UnityPath `
                -GameReplayDriverType $GameReplayDriverType `
                -EvidenceBundleDir $EvidenceBundleDir
        }
    }

    Invoke-PipelineStep "repair_agent_external_patch_preflight" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotRepairAgentExternalPatchPreflight.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "repair_agent_external_patch_preflight_failure_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotRepairAgentExternalPatchPreflightFailureProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "repair_agent_repository_patch_apply_guard" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotRepairAgentRepositoryPatchApplyGuard.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "repair_agent_repository_patch_apply_clean_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotRepairAgentRepositoryPatchApplyCleanProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "repair_agent_repository_patch_apply_clean_retest" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotRepairAgentRepositoryPatchApplyCleanRetest.ps1") `
            -UnityPath $UnityPath `
            -GameReplayDriverType $GameReplayDriverType `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "repair_agent_patch_apply_retest" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotRepairAgentPatchApplyRetest.ps1") `
            -UnityPath $UnityPath `
            -GameReplayDriverType $GameReplayDriverType `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "driver_failure_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotReplayDriverFailureProbe.ps1") `
            -UnityPath $UnityPath `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "targeted_repair_retest" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotRepairRetest.ps1") `
            -UnityPath $UnityPath `
            -GameReplayDriverType $GameReplayDriverType `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "replay_profile_import" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotReplayProfileImport.ps1") `
            -UnityPath $UnityPath `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_replay_driver_readiness" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionReplayDriverReadiness.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir `
            -RequireProductionBound:$RequireProductionReplayDriverBound
    }

    if (-not $RequireProductionReplayDriverBound) {
        Invoke-PipelineStep "production_replay_driver_bound_failure_probe" {
            & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionReplayDriverBoundFailureProbe.ps1") `
                -EvidenceBundleDir $EvidenceBundleDir
        }
    }

    Invoke-PipelineStep "model_endpoint_trace_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotModelEndpointTraceProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "model_endpoint_provider_diagnostics" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotModelEndpointProviderDiagnostics.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "live_model_endpoint_failure_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotLiveModelEndpointFailureProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "live_model_endpoint_smoke" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotLiveModelEndpointSmoke.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir `
            -RequireLive:$RequireLiveModelEndpointSmoke `
            -AllowMissingApiKey:$AllowMissingModelApiKey `
            -DisableFailurePolicyRetry:$DisableLiveModelEndpointFailurePolicyRetry `
            -MaxPolicyRetries $LiveModelEndpointMaxPolicyRetries `
            -MaxRetryBackoffSeconds $LiveModelEndpointMaxRetryBackoffSeconds
    }

    Invoke-PipelineStep "release_gate" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotReleaseGate.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir `
            -RequireProductionReplayDriverBound:$RequireProductionReplayDriverBound `
            -RequireLiveModelEndpointSmoke:$RequireLiveModelEndpointSmoke
    }

    Invoke-PipelineStep "release_gate_failure_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotReleaseGateFailureProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir `
            -ProbeBundleDir $ReleaseGateFailureProbeDir `
            -RequireProductionReplayDriverBound:$RequireProductionReplayDriverBound `
            -RequireLiveModelEndpointSmoke:$RequireLiveModelEndpointSmoke
    }

    $pipelinePassed = $true
}
finally {
    Pop-Location
    Export-PipelineArtifacts $pipelinePassed
}

if (-not $pipelinePassed) {
    throw "AI TestPilot release pipeline failed."
}

Write-Output "PASS AI TestPilot release pipeline"
