[CmdletBinding()]
param(
    [string]$UnityPath = "F:\Unity\2021_3_45_f2\Editor\Unity.exe",
    [string]$GameReplayDriverType = "Kibernet.AITestPilot.Unity.Editor.SampleGameActionReplayDriver",
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
    [switch]$AllowMissingModelApiKey,
    [switch]$DisableLiveModelEndpointFailurePolicyRetry,
    [int]$LiveModelEndpointMaxPolicyRetries = 2,
    [int]$LiveModelEndpointMaxRetryBackoffSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$repoTempRoot = Join-Path $repoRoot "Temp"
$repoArtifactRoot = Join-Path $repoRoot "artifacts"

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

function Resolve-FullPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Test-PathWithinRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    $fullPath = Resolve-FullPath $Path
    $rootPath = (Resolve-FullPath $Root).TrimEnd([char[]]@("\", "/"))
    return $fullPath.Equals($rootPath, [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($rootPath + "\", [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($rootPath + "/", [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-PathUnderRepo {
    param(
        [string]$Path,
        [string]$Label
    )

    $fullPath = Resolve-FullPath $Path
    if (-not (Test-PathWithinRoot $fullPath $script:repoRoot)) {
        throw "$Label must stay under repo root. Path: $fullPath"
    }

    return $fullPath
}

function Assert-ManagedOutputDir {
    param(
        [string]$Path,
        [string]$Label
    )

    $fullPath = Assert-PathUnderRepo $Path $Label
    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    $pathRoot = [System.IO.Path]::GetPathRoot($fullPath)
    $blockedRoots = @(
        $pathRoot,
        $repoRoot,
        $repoTempRoot,
        $repoArtifactRoot
    )

    foreach ($blockedRoot in $blockedRoots) {
        if ([string]::IsNullOrWhiteSpace($blockedRoot)) {
            continue
        }

        $blockedFullPath = Resolve-FullPath $blockedRoot
        if ($fullPath.Equals($blockedFullPath, $comparison)) {
            throw "$Label must target a managed child output directory, not a root directory. Path: $fullPath"
        }
    }

    return $fullPath
}

function Initialize-PipelineEvidenceBundle {
    param([string]$BundleDir)

    $bundlePath = Assert-ManagedOutputDir $BundleDir "EvidenceBundleDir"
    if (Test-Path $bundlePath) {
        Remove-Item -LiteralPath $bundlePath -Recurse -Force
    }

    New-Item -ItemType Directory -Force $bundlePath | Out-Null
    return $bundlePath
}

function Remove-FinalReleaseStatusArtifacts {
    param([string]$ArtifactPath)

    $finalReleaseFiles = @(
        "release-gate-manifest.json",
        "release-gate.md",
        "release-risk-policy-manifest.json",
        "release-risk-policy.md",
        "release-evidence-index-manifest.json",
        "release-evidence-index.json",
        "release-evidence-index.md",
        "release-evidence-index-field-coverage-probe-manifest.json",
        "release-evidence-index-field-coverage-probe.md",
        "release-docs-freshness-manifest.json",
        "release-docs-freshness.md"
    )

    $removed = @()
    foreach ($fileName in $finalReleaseFiles) {
        $path = Join-Path $ArtifactPath $fileName
        if (Test-Path $path) {
            Remove-Item -LiteralPath $path -Force
            $removed += $fileName
        }
    }

    return @($removed)
}

function Write-FailedPipelineArtifactInvalidation {
    param(
        [string]$ArtifactPath,
        [string[]]$InvalidatedFiles,
        [datetime]$GeneratedAtUtc
    )

    $manifestPath = Join-Path $ArtifactPath "release-artifact-invalidated-manifest.json"
    $manifest = [ordered]@{
        schemaVersion = "aitestpilot.release_artifact_invalidation.v1"
        status = "FAIL"
        generatedAtUtc = $GeneratedAtUtc.ToString("O")
        pipelineStatus = "FAIL"
        reason = "pipeline_failed_before_final_release_artifact_refresh"
        staleFinalReleaseArtifactsInvalidated = $true
        invalidatedFileCount = [int]$InvalidatedFiles.Count
        invalidatedFiles = @($InvalidatedFiles)
        releaseGateUsable = $false
        releaseRiskPolicyUsable = $false
        releaseEvidenceIndexUsable = $false
        generatedFiles = @(
            "pipeline-manifest.json",
            "release-artifact-invalidated-manifest.json"
        )
        files = @(
            "pipeline-manifest.json",
            "release-artifact-invalidated-manifest.json"
        )
    }

    $manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $manifestPath -Encoding UTF8
    return $manifestPath
}

function Remove-CursorAgentOptionalEvidence {
    param([string]$BundleDir)

    $bundlePath = Assert-ManagedOutputDir $BundleDir "EvidenceBundleDir"

    if (-not (Test-Path $bundlePath)) {
        return
    }

    $cursorAgentOptionalFiles = @(
        "repair-agent-cursor-agent-external-output-manifest.json",
        "repair-agent-cursor-agent-output-run.json",
        "repair-agent-cursor-agent-output.patch",
        "repair-agent-cursor-agent-output-summary.md",
        "repair-agent-cursor-agent-output.log",
        "repair-agent-cursor-agent-output-patch-output-manifest.json",
        "repair-agent-cursor-agent-output-preflight-manifest.json"
    )

    foreach ($fileName in $cursorAgentOptionalFiles) {
        $path = Join-Path $bundlePath $fileName
        if (Test-Path $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }
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

    $bundlePath = Assert-ManagedOutputDir $EvidenceBundleDir "EvidenceBundleDir"
    $artifactPath = Assert-ManagedOutputDir $ArtifactDir "ArtifactDir"
    $artifactParent = Split-Path $artifactPath -Parent
    New-Item -ItemType Directory -Force $artifactParent | Out-Null

    if (Test-Path $artifactPath) {
        Remove-Item -LiteralPath $artifactPath -Recurse -Force
    }

    New-Item -ItemType Directory -Force $artifactPath | Out-Null

    if (Test-Path $bundlePath) {
        Copy-Item -Path (Join-Path $bundlePath "*") -Destination $artifactPath -Recurse -Force
    }

    $pipelineFinishedAtUtc = (Get-Date).ToUniversalTime()
    $invalidatedFinalReleaseArtifacts = @()
    if ($PipelinePassed) {
        $pipelineStatus = "PASS"
        $ciExitCode = 0
    }
    else {
        $pipelineStatus = "FAIL"
        $ciExitCode = 1
        $invalidatedFinalReleaseArtifacts = @(Remove-FinalReleaseStatusArtifacts $artifactPath)
    }

    $manifest = [ordered]@{
        status = $pipelineStatus
        generatedAtUtc = $pipelineFinishedAtUtc.ToString("O")
        startedAtUtc = $pipelineStartedAtUtc.ToString("O")
        finishedAtUtc = $pipelineFinishedAtUtc.ToString("O")
        durationSeconds = [Math]::Round(($pipelineFinishedAtUtc - $pipelineStartedAtUtc).TotalSeconds, 3)
        evidenceBundleDir = $bundlePath
        artifactDir = $artifactPath
        gameReplayDriverType = $GameReplayDriverType
        productionLuaEvidenceDir = $ProductionLuaEvidenceDir
        stepCount = $steps.Count
        executedStepCount = $steps.Count
        steps = @($steps)
        ciExitCode = $ciExitCode
        finalReleaseArtifactsInvalidated = (-not $PipelinePassed)
        invalidatedFinalReleaseArtifactCount = [int]$invalidatedFinalReleaseArtifacts.Count
        invalidatedFinalReleaseArtifacts = @($invalidatedFinalReleaseArtifacts)
    }

    $manifestPath = Join-Path $artifactPath "pipeline-manifest.json"
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

    if (-not $PipelinePassed) {
        Write-FailedPipelineArtifactInvalidation `
            -ArtifactPath $artifactPath `
            -InvalidatedFiles $invalidatedFinalReleaseArtifacts `
            -GeneratedAtUtc $pipelineFinishedAtUtc | Out-Null
    }
    else {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotReleaseEvidenceIndex.ps1") `
            -EvidenceBundleDir $artifactPath `
            -RequireProductionReplayDriverBound:$RequireProductionReplayDriverBound `
            -RequireProductionLuaPatched:$RequireProductionLuaPatched `
            -RequireLiveModelEndpointSmoke:$RequireLiveModelEndpointSmoke | Out-Null

        $indexManifestPath = Join-Path $artifactPath "release-evidence-index-manifest.json"
        if (-not (Test-Path $indexManifestPath)) {
            throw "Final artifact release evidence index manifest was not produced: $indexManifestPath"
        }

        $indexManifest = Get-Content -Path $indexManifestPath -Encoding UTF8 -Raw | ConvertFrom-Json
        if ($indexManifest.status -ne "PASS" -or
            -not [bool]$indexManifest.pipelineManifestExpected -or
            -not [bool]$indexManifest.pipelineManifestIncluded) {
            throw "Final artifact release evidence index must include pipeline-manifest.json after pipeline export."
        }
    }

    Write-Output "Pipeline artifacts: $artifactPath"
    Write-Output "Pipeline manifest: $manifestPath"
}

$pipelinePassed = $false

$EvidenceBundleDir = Initialize-PipelineEvidenceBundle $EvidenceBundleDir
$ArtifactDir = Assert-ManagedOutputDir $ArtifactDir "ArtifactDir"
$ReleaseGateFailureProbeDir = Assert-ManagedOutputDir $ReleaseGateFailureProbeDir "ReleaseGateFailureProbeDir"
$CursorAgentOutputDir = Assert-ManagedOutputDir $CursorAgentOutputDir "CursorAgentOutputDir"

try {
    Push-Location $repoRoot
    if (-not $UseCursorAgentExternalTaskOutput) {
        Remove-CursorAgentOptionalEvidence $EvidenceBundleDir
    }

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
                -CursorAgentModel $CursorAgentModel `
                -CursorAgentMaxAttempts $CursorAgentMaxAttempts `
                -CursorAgentRetryDelaySeconds $CursorAgentRetryDelaySeconds
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

    Invoke-PipelineStep "repair_agent_patch_result_analysis" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotRepairAgentPatchResultAnalysis.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "repair_agent_patch_result_history" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotRepairAgentPatchResultHistoryProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
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

    Invoke-PipelineStep "production_replay_integration_contract_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionReplayIntegrationContractProbe.ps1") `
            -UnityPath $UnityPath `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_driver_binding_kit_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionDriverBindingKitProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_driver_evidence_contract_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionDriverEvidenceContractProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_replay_driver_readiness" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionReplayDriverReadiness.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir `
            -RequireProductionBound:$RequireProductionReplayDriverBound
    }

    Invoke-PipelineStep "production_driver_evidence_intake" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionDriverEvidenceIntake.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir `
            -ExpectBlocked:(-not [bool]$RequireProductionReplayDriverBound)
    }

    Invoke-PipelineStep "production_driver_external_bundle_intake_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionDriverExternalBundleIntakeProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
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

    Invoke-PipelineStep "model_endpoint_provider_retry_policy" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotModelEndpointProviderRetryPolicyProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "live_model_endpoint_config_kit_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotLiveModelEndpointConfigKitProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "lua_static_analysis_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotLuaStaticAnalysisProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "lua_auto_patch_sandbox_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotLuaAutoPatchSandboxProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_lua_patch_readiness" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionLuaPatchReadiness.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir `
            -ProductionLuaEvidenceDir $ProductionLuaEvidenceDir `
            -RequireProductionLuaPatched:$RequireProductionLuaPatched
    }

    if (-not $RequireProductionLuaPatched) {
        Invoke-PipelineStep "production_lua_patch_bound_failure_probe" {
            & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionLuaPatchBoundFailureProbe.ps1") `
                -EvidenceBundleDir $EvidenceBundleDir
        }
    }

    Invoke-PipelineStep "production_lua_patch_evidence_kit_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionLuaPatchEvidenceKitProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_lua_patch_external_bundle_intake_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionLuaPatchExternalBundleIntakeProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "live_model_endpoint_failure_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotLiveModelEndpointFailureProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    $requireDirectLiveModelEndpointSmoke = [bool]$RequireLiveModelEndpointSmoke -and
        [string]::IsNullOrWhiteSpace($LiveModelEndpointSmokeEvidenceDir)

    Invoke-PipelineStep "live_model_endpoint_smoke" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotLiveModelEndpointSmoke.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir `
            -RequireLive:$requireDirectLiveModelEndpointSmoke `
            -AllowMissingApiKey:$AllowMissingModelApiKey `
            -DisableFailurePolicyRetry:$DisableLiveModelEndpointFailurePolicyRetry `
            -MaxPolicyRetries $LiveModelEndpointMaxPolicyRetries `
            -MaxRetryBackoffSeconds $LiveModelEndpointMaxRetryBackoffSeconds
    }

    if (-not [string]::IsNullOrWhiteSpace($LiveModelEndpointSmokeEvidenceDir)) {
        Invoke-PipelineStep "live_model_endpoint_smoke_evidence_intake" {
            & (Join-Path $repoRoot "tools\Invoke-AITestPilotLiveModelEndpointSmokeEvidenceIntake.ps1") `
                -EvidenceBundleDir $EvidenceBundleDir `
                -SmokeEvidenceDir $LiveModelEndpointSmokeEvidenceDir `
                -RequireLiveModelEndpointSmoke:$RequireLiveModelEndpointSmoke `
                -PromoteToCanonical
        }
    }

    Invoke-PipelineStep "live_model_endpoint_external_smoke_intake_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotLiveModelEndpointExternalSmokeIntakeProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "live_model_endpoint_smoke_evidence_contract_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotLiveModelEndpointSmokeEvidenceContractProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "ci_provider_release_workflow_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotGitHubActionsWorkflowProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "ci_provider_azure_pipelines_workflow_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotAzurePipelinesWorkflowProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "ci_provider_quality_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProviderCiQualityProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_handoff_package" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionHandoffPackage.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_handoff_external_evidence_preflight_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionHandoffExternalEvidencePreflightProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_external_evidence_acceptance_contract_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionExternalEvidenceAcceptanceContractProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_external_evidence_acceptance_failure_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionExternalEvidenceAcceptanceFailureProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_external_evidence_inbox" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionExternalEvidenceInbox.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_external_evidence_inbox_contract_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionExternalEvidenceInboxContractProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_external_evidence_auto_acceptance_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionExternalEvidenceAutoAcceptanceProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_handoff_export" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionHandoffExport.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_handoff_status" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionHandoffStatus.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_handoff_dispatch_plan" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionHandoffDispatchPlan.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_handoff_contact_readiness" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionHandoffContactReadiness.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_handoff_contact_readiness_contract_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionHandoffContactReadinessContractProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_handoff_send_readiness" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionHandoffSendReadiness.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_handoff_mail_auth_readiness" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionHandoffMailAuthReadiness.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_handoff_owner_unblock_pack" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionHandoffOwnerUnblockPack.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_handoff_owner_unblock_pack_contract_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionHandoffOwnerUnblockPackContractProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_handoff_owner_input_request_pack" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionHandoffOwnerInputRequestPack.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_handoff_owner_contact_external_intake_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionHandoffOwnerContactExternalIntakeProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_handoff_send_dry_run_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionHandoffSendDryRunProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_handoff_owner_response_bundle_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionHandoffOwnerResponseBundleProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_handoff_owner_response_bundle_kit" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionHandoffOwnerResponseBundleKit.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_handoff_owner_response_bundle_kit_workflow_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionHandoffOwnerResponseBundleKitWorkflowProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_handoff_export_refresh" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionHandoffExport.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "release_progress_notification_outbox" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotReleaseProgressNotificationOutbox.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "release_progress_notification_remaining_work_snapshot_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotReleaseProgressNotificationRemainingWorkSnapshotProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_handoff_mail_helper_auth_status_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionHandoffMailHelperAuthStatusProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_handoff_send_local_workflow_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionHandoffSendLocalWorkflowProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_handoff_owner_packet_dispatch_receipt_intake_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionHandoffOwnerPacketDispatchReceiptIntakeProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_handoff_owner_packet_real_receipt_guard_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionHandoffOwnerPacketRealReceiptGuardProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "release_progress_notification_confirmation_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotReleaseProgressNotificationConfirmationProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "release_progress_notification_receipt_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotReleaseProgressNotificationReceiptProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "release_progress_notification_dispatch_receipt_intake_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotReleaseProgressNotificationDispatchReceiptIntakeProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "release_progress_notification_local_send_workflow_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotReleaseProgressNotificationLocalSendWorkflowProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "release_progress_notification_real_receipt_guard_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotReleaseProgressNotificationRealReceiptGuardProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "release_progress_notification_post_dispatch_snapshot_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotReleaseProgressNotificationPostDispatchSnapshotProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_external_evidence_action_queue" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionExternalEvidenceActionQueue.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_external_evidence_action_queue_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionExternalEvidenceActionQueueProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_external_evidence_gap_analysis" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionExternalEvidenceGapAnalysis.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_handoff_owner_route_map" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionHandoffOwnerRouteMap.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_handoff_owner_route_map_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionHandoffOwnerRouteMapProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "release_progress_notification_outbox_final_refresh" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotReleaseProgressNotificationOutbox.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir `
            -RequireOwnerRouteMapLatestBigNode
    }

    Invoke-PipelineStep "release_progress_notification_remaining_work_snapshot_final_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotReleaseProgressNotificationRemainingWorkSnapshotProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir `
            -RequireOwnerRouteMapLatestBigNode
    }

    Invoke-PipelineStep "production_external_evidence_partial_matrix_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionExternalEvidencePartialMatrixProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_external_evidence_semantic_preflight_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionExternalEvidenceSemanticPreflightProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_external_evidence_owner_return_bundle_status" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionExternalEvidenceOwnerReturnBundleStatus.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_external_evidence_owner_return_bundle_status_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionExternalEvidenceOwnerReturnBundleStatusProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "release_progress_notification_outbox_strict_payload_shape_refresh" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotReleaseProgressNotificationOutbox.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir `
            -RequireStrictPayloadShapeLatestBigNode
    }

    Invoke-PipelineStep "release_progress_notification_remaining_work_snapshot_strict_payload_shape_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotReleaseProgressNotificationRemainingWorkSnapshotProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir `
            -RequireStrictPayloadShapeLatestBigNode
    }

    Invoke-PipelineStep "production_handoff_export_final_refresh" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionHandoffExport.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_handoff_export_zip_index" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionHandoffExportZipIndex.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "release_docs_freshness" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotReleaseDocsFreshnessProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_hard_mode_failure_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionHardModeFailureProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "production_hard_mode_success_contract_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionHardModeSuccessContractProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "release_risk_policy" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotReleaseRiskPolicy.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir `
            -RequireProductionReplayDriverBound:$RequireProductionReplayDriverBound `
            -RequireProductionLuaPatched:$RequireProductionLuaPatched `
            -RequireLiveModelEndpointSmoke:$RequireLiveModelEndpointSmoke
    }

    Invoke-PipelineStep "repair_agent_cursor_agent_external_output_binding_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotCursorAgentExternalOutputBindingProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "release_evidence_index" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotReleaseEvidenceIndex.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir `
            -RequireProductionReplayDriverBound:$RequireProductionReplayDriverBound `
            -RequireProductionLuaPatched:$RequireProductionLuaPatched `
            -RequireLiveModelEndpointSmoke:$RequireLiveModelEndpointSmoke
    }

    Invoke-PipelineStep "release_evidence_index_field_coverage_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotReleaseEvidenceIndexFieldCoverageProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir
    }

    Invoke-PipelineStep "release_gate" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotReleaseGate.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir `
            -RequireProductionReplayDriverBound:$RequireProductionReplayDriverBound `
            -RequireProductionLuaPatched:$RequireProductionLuaPatched `
            -RequireLiveModelEndpointSmoke:$RequireLiveModelEndpointSmoke
    }

    Invoke-PipelineStep "release_gate_failure_probe" {
        & (Join-Path $repoRoot "tools\Invoke-AITestPilotReleaseGateFailureProbe.ps1") `
            -EvidenceBundleDir $EvidenceBundleDir `
            -ProbeBundleDir $ReleaseGateFailureProbeDir `
            -RequireProductionReplayDriverBound:$RequireProductionReplayDriverBound `
            -RequireProductionLuaPatched:$RequireProductionLuaPatched `
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
