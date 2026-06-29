[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ReleaseGateManifestPath,
    [switch]$ExpectBlocked,
    [switch]$RequireLiveModelEndpointSmoke
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ReleaseGateManifestPath)) {
    $ReleaseGateManifestPath = Join-Path $EvidenceBundleDir "release-gate-manifest.json"
}

$requiredHandlerKeys = @(
    "game.prepare_account",
    "game.login",
    "game.enter_scene",
    "game.claim_reward",
    "game.play_fishing"
)

$checks = @()
$failedReasons = @()

function Add-ReleaseCheck {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Message
    )

    $script:checks += [ordered]@{
        name = $Name
        passed = $Passed
        message = $Message
    }

    if (-not $Passed) {
        $script:failedReasons += $Name + ":" + $Message
    }
}

function Read-Manifest {
    param(
        [string]$FileName
    )

    $path = Join-Path $EvidenceBundleDir $FileName
    if (-not (Test-Path $path)) {
        Add-ReleaseCheck "file:$FileName" $false "Manifest is missing."
        return $null
    }

    try {
        Add-ReleaseCheck "file:$FileName" $true "Manifest exists."
        return Get-Content -Raw $path | ConvertFrom-Json
    }
    catch {
        Add-ReleaseCheck "file:$FileName" $false ("Manifest could not be parsed: " + $_.Exception.Message)
        return $null
    }
}

function Read-OptionalManifest {
    param(
        [string]$FileName
    )

    $path = Join-Path $EvidenceBundleDir $FileName
    if (-not (Test-Path $path)) {
        return $null
    }

    try {
        Add-ReleaseCheck "file:$FileName" $true "Optional manifest exists."
        return Get-Content -Raw $path | ConvertFrom-Json
    }
    catch {
        Add-ReleaseCheck "file:$FileName" $false ("Optional manifest could not be parsed: " + $_.Exception.Message)
        return $null
    }
}

function Test-ContainsAll {
    param(
        [object[]]$Actual,
        [string[]]$Required
    )

    foreach ($item in $Required) {
        if ($Actual -notcontains $item) {
            return $false
        }
    }

    return $true
}

function Test-ListedFiles {
    param(
        [object]$Manifest,
        [string]$CheckPrefix
    )

    if ($null -eq $Manifest -or $null -eq $Manifest.files) {
        Add-ReleaseCheck ($CheckPrefix + ":files") $false "Manifest did not list files."
        return
    }

    foreach ($fileName in @($Manifest.files)) {
        $path = Join-Path $EvidenceBundleDir $fileName
        Add-ReleaseCheck ($CheckPrefix + ":file:" + $fileName) (Test-Path $path) "Listed file must exist."
    }
}

if (-not (Test-Path $EvidenceBundleDir)) {
    throw "Evidence bundle does not exist: $EvidenceBundleDir"
}

$sceneManifest = Read-Manifest "manifest.json"
$repairAgentPatchOutputManifest = Read-Manifest "repair-agent-patch-output-manifest.json"
$repairAgentExternalCompletionFailureProbeManifest = Read-Manifest "repair-agent-external-completion-failure-probe-manifest.json"
$repairAgentGenericPatchImportProbeManifest = Read-Manifest "repair-agent-generic-patch-import-probe-manifest.json"
$repairAgentSourceSnapshotApplyValidateManifest = Read-Manifest "repair-agent-source-snapshot-apply-validate-manifest.json"
$repairAgentMainWorktreeApplyReadinessManifest = Read-Manifest "repair-agent-main-worktree-apply-readiness-manifest.json"
$repairAgentMainWorktreeApplyRetestRollbackManifest = Read-Manifest "repair-agent-main-worktree-apply-retest-rollback-manifest.json"
$repairAgentCursorAgentExternalOutputManifest = Read-OptionalManifest "repair-agent-cursor-agent-external-output-manifest.json"
$repairAgentExternalTaskOutputAcceptanceManifest = Read-Manifest "repair-agent-external-task-output-acceptance-manifest.json"
$repairAgentExternalPatchPreflightManifest = Read-Manifest "repair-agent-external-patch-preflight-manifest.json"
$repairAgentExternalPatchPreflightFailureProbeManifest = Read-Manifest "repair-agent-external-patch-preflight-failure-probe-manifest.json"
$repairAgentRepositoryPatchApplyGuardManifest = Read-Manifest "repair-agent-repository-patch-apply-guard-manifest.json"
$repairAgentRepositoryPatchApplyCleanProbeManifest = Read-Manifest "repair-agent-repository-patch-apply-clean-probe-manifest.json"
$repairAgentRepositoryPatchApplyCleanRetestManifest = Read-Manifest "repair-agent-repository-patch-apply-clean-retest-manifest.json"
$repairAgentPatchApplyRetestManifest = Read-Manifest "repair-agent-patch-apply-retest-manifest.json"
$repairRetestManifest = Read-Manifest "repair-retest-manifest.json"
$failureProbeManifest = Read-Manifest "repair-driver-failure-manifest.json"
$profileImportManifest = Read-Manifest "replay-profile-import-manifest.json"
$modelEndpointManifest = Read-Manifest "model-endpoint-trace-manifest.json"
$modelEndpointProviderDiagnosticsManifest = Read-Manifest "model-endpoint-provider-diagnostics-manifest.json"
$liveModelEndpointFailureProbeManifest = Read-Manifest "live-model-endpoint-failure-probe-manifest.json"
$liveModelEndpointManifest = Read-Manifest "live-model-endpoint-smoke-manifest.json"

if ($null -ne $sceneManifest) {
    Add-ReleaseCheck "scene_validation" `
        ($sceneManifest.status -eq "PASS" -and
            [bool]$sceneManifest.allowRelease -and
            [int]$sceneManifest.unverifiedHighRiskBugCount -eq 0 -and
            [bool]$sceneManifest.retestPassed) `
        "Scene validation must allow release with no unverified high-risk bugs."

    Add-ReleaseCheck "scene_model_endpoint_contract" `
        ($null -ne $sceneManifest.summary -and
            [bool]$sceneManifest.summary.modelEndpointContractPassed -and
            $sceneManifest.summary.modelEndpointActionSchemaVersion -eq "ai-testpilot.action.v1" -and
            [bool]$sceneManifest.summary.modelEndpointOpenAICompatibleChatRequestValid -and
            [bool]$sceneManifest.summary.modelEndpointRequestContainsFixHints -and
            [int]$sceneManifest.summary.modelEndpointFixHintCount -eq 1 -and
            -not [bool]$sceneManifest.summary.modelEndpointLiveRequestsEnabled) `
        "Scene validation must prove Unity model endpoint settings, native contract, prior fix hints, and OpenAI-compatible chat request wrapper."

    Add-ReleaseCheck "scene_multi_step_runner" `
        ($null -ne $sceneManifest.summary -and
            $sceneManifest.summary.multiStepRunnerStatus -eq "PASS" -and
            [int]$sceneManifest.summary.multiStepRunnerStepCount -eq 3 -and
            [int]$sceneManifest.summary.multiStepRunnerActionCount -eq 3 -and
            [int]$sceneManifest.summary.multiStepRunnerClickCount -eq 3 -and
            $sceneManifest.summary.multiStepRunnerExitReason -eq "max_steps") `
        "Scene validation must prove DecisionLoopRunner can execute a multi-step goal and stop at the max-step boundary."

    Add-ReleaseCheck "scene_bug_package_artifact" `
        ($null -ne $sceneManifest.summary -and
            -not [string]::IsNullOrWhiteSpace($sceneManifest.summary.bugPackageId) -and
            $sceneManifest.summary.bugPackageType -eq "NullReference" -and
            $sceneManifest.summary.bugPackageRisk -eq "HIGH" -and
            $sceneManifest.summary.bugPackageModule -eq "SampleModule" -and
            $sceneManifest.summary.bugPackageFunction -eq "StartButton" -and
            [int]$sceneManifest.summary.bugPackageReproductionStepCount -ge 5) `
        "Scene validation must persist the source bug package as standalone JSON/Markdown evidence."

    Add-ReleaseCheck "scene_bug_knowledge_graph_artifact" `
        ($null -ne $sceneManifest.summary -and
            $sceneManifest.summary.bugKnowledgeGraphSchemaVersion -eq "aitestpilot.bug_knowledge_graph.v1" -and
            [int]$sceneManifest.summary.bugKnowledgeGraphNodeCount -eq 1 -and
            [int]$sceneManifest.summary.bugKnowledgeGraphHighRiskCount -eq 1 -and
            $sceneManifest.summary.bugKnowledgeGraphTopModule -eq "SampleModule" -and
            [int]$sceneManifest.summary.bugKnowledgeGraphTopModuleScore -eq 5 -and
            $sceneManifest.summary.bugKnowledgeGraphTopFailureModule -eq "SampleModule" -and
            $sceneManifest.summary.bugKnowledgeGraphTopFailureType -eq "NullReference" -and
            [int]$sceneManifest.summary.bugKnowledgeGraphTopFailureTypeScore -eq 5) `
        "Scene validation must persist the bug knowledge graph with module and failure-type risk ranking."

    Add-ReleaseCheck "scene_repair_agent_handoff_artifact" `
        ($null -ne $sceneManifest.summary -and
            $sceneManifest.summary.repairAgentHandoffSchemaVersion -eq "aitestpilot.repair_agent_handoff.v1" -and
            $sceneManifest.summary.repairAgentHandoffStatus -eq "READY" -and
            $sceneManifest.summary.repairAgentHandoffAgent -eq "Cursor" -and
            $sceneManifest.summary.repairAgentHandoffLaunchCommand -eq "cursor repair-agent-handoff.md" -and
            [int]$sceneManifest.summary.repairAgentHandoffContextFileCount -ge 5) `
        "Scene validation must persist a Cursor-ready repair agent handoff with required context files."

    Add-ReleaseCheck "scene_repair_agent_run_tracking" `
        ($null -ne $sceneManifest.summary -and
            $sceneManifest.summary.repairAgentRunSchemaVersion -eq "aitestpilot.repair_agent_run.v1" -and
            $sceneManifest.summary.repairAgentRunStatus -eq "AWAITING_EXTERNAL_AGENT" -and
            -not [bool]$sceneManifest.summary.repairAgentRunAgentLaunched -and
            [bool]$sceneManifest.summary.repairAgentRunExternalAgentRequired -and
            $sceneManifest.summary.repairAgentRunPatchOutputStatus -eq "PENDING_EXTERNAL_AGENT" -and
            [int]$sceneManifest.summary.repairAgentRunPatchOutputCount -eq 0 -and
            [int]$sceneManifest.summary.repairAgentRunExpectedPatchOutputCount -ge 2) `
        "Scene validation must track repair-agent execution state and patch output slots without claiming the external agent has run."

    Add-ReleaseCheck "scene_production_replay_integration_template" `
        ($null -ne $sceneManifest.summary -and
            $sceneManifest.summary.productionReplayIntegrationStatus -eq "TEMPLATE_READY" -and
            -not [bool]$sceneManifest.summary.productionReplayRealProjectBound -and
            [int]$sceneManifest.summary.productionReplayRequiredHookCount -eq 5 -and
            [int]$sceneManifest.summary.productionReplayUnresolvedRequiredHookCount -eq 5) `
        "Scene validation must export the production replay integration template and clearly mark real game hooks as unbound."

    Test-ListedFiles $sceneManifest "scene_validation"
}

if ($null -ne $repairAgentPatchOutputManifest) {
    Add-ReleaseCheck "repair_agent_patch_output_import" `
        ($repairAgentPatchOutputManifest.status -eq "PASS" -and
            $repairAgentPatchOutputManifest.schemaVersion -eq "aitestpilot.repair_agent_patch_output.v1" -and
            $repairAgentPatchOutputManifest.source -eq "deterministic_sample" -and
            -not [bool]$repairAgentPatchOutputManifest.externalAgentRun -and
            -not [bool]$repairAgentPatchOutputManifest.externalAgentCompletionRequired -and
            -not [bool]$repairAgentPatchOutputManifest.externalAgentCompletionVerified -and
            [int]$repairAgentPatchOutputManifest.externalAgentCompletionFailureReasonCount -eq 0 -and
            $repairAgentPatchOutputManifest.repairAgentRunStatus -eq "AWAITING_EXTERNAL_AGENT" -and
            [bool]$repairAgentPatchOutputManifest.patchFilePresent -and
            [bool]$repairAgentPatchOutputManifest.summaryFilePresent -and
            [int]$repairAgentPatchOutputManifest.patchOutputCount -eq 2 -and
            [bool]$repairAgentPatchOutputManifest.patchContainsDiffHeader -and
            [bool]$repairAgentPatchOutputManifest.patchContainsExpectedFix -and
            [bool]$repairAgentPatchOutputManifest.summaryContainsRetestCommand -and
            $repairAgentPatchOutputManifest.postPatchRetestCommand -eq ".\tools\Invoke-AITestPilotRepairRetest.ps1") `
        "Repair-agent patch output import must validate sample patch/summary outputs and preserve the external-agent boundary."

    Test-ListedFiles $repairAgentPatchOutputManifest "repair_agent_patch_output_import"
}

if ($null -ne $repairAgentExternalCompletionFailureProbeManifest) {
    Add-ReleaseCheck "repair_agent_external_completion_failure_probe" `
        ($repairAgentExternalCompletionFailureProbeManifest.status -eq "PASS" -and
            $repairAgentExternalCompletionFailureProbeManifest.schemaVersion -eq "aitestpilot.repair_agent_external_completion_failure_probe.v1" -and
            [bool]$repairAgentExternalCompletionFailureProbeManifest.expectedFailure -and
            [bool]$repairAgentExternalCompletionFailureProbeManifest.importFailed -and
            $repairAgentExternalCompletionFailureProbeManifest.importManifestStatus -eq "FAIL" -and
            $repairAgentExternalCompletionFailureProbeManifest.importManifestSource -eq "external_agent_unverified" -and
            [bool]$repairAgentExternalCompletionFailureProbeManifest.confirmExternalAgentCompleted -and
            -not [bool]$repairAgentExternalCompletionFailureProbeManifest.externalAgentRun -and
            -not [bool]$repairAgentExternalCompletionFailureProbeManifest.externalAgentCompletionVerified -and
            [int]$repairAgentExternalCompletionFailureProbeManifest.failureReasonCount -ge 5 -and
            [bool]$repairAgentExternalCompletionFailureProbeManifest.expectedFailureReasonsFound -and
            $repairAgentExternalCompletionFailureProbeManifest.pendingRunStatus -eq "AWAITING_EXTERNAL_AGENT" -and
            $repairAgentExternalCompletionFailureProbeManifest.pendingPatchOutputStatus -eq "PENDING_EXTERNAL_AGENT" -and
            [int]$repairAgentExternalCompletionFailureProbeManifest.pendingPatchOutputCount -eq 0) `
        "Repair-agent external completion failure probe must reject patch outputs while the tracked external run is still pending."

    Test-ListedFiles $repairAgentExternalCompletionFailureProbeManifest "repair_agent_external_completion_failure_probe"
}

if ($null -ne $repairAgentGenericPatchImportProbeManifest) {
    Add-ReleaseCheck "repair_agent_generic_patch_import_probe" `
        ($repairAgentGenericPatchImportProbeManifest.status -eq "PASS" -and
            $repairAgentGenericPatchImportProbeManifest.schemaVersion -eq "aitestpilot.repair_agent_generic_patch_import_probe.v1" -and
            $repairAgentGenericPatchImportProbeManifest.patchOutputSource -eq "external_agent" -and
            [bool]$repairAgentGenericPatchImportProbeManifest.externalAgentRun -and
            [bool]$repairAgentGenericPatchImportProbeManifest.externalAgentCompletionVerified -and
            $repairAgentGenericPatchImportProbeManifest.repairAgentRunStatus -eq "EXTERNAL_AGENT_COMPLETED" -and
            $repairAgentGenericPatchImportProbeManifest.repairAgentPatchOutputStatus -eq "PRODUCED" -and
            -not [bool]$repairAgentGenericPatchImportProbeManifest.sampleFixSnippetRequired -and
            -not [bool]$repairAgentGenericPatchImportProbeManifest.patchContainsSampleFix -and
            [bool]$repairAgentGenericPatchImportProbeManifest.patchContainsDiffHeader -and
            [bool]$repairAgentGenericPatchImportProbeManifest.summaryContainsRetestCommand -and
            $repairAgentGenericPatchImportProbeManifest.preflightStatus -eq "PASS" -and
            [bool]$repairAgentGenericPatchImportProbeManifest.preflightSafeToInspect -and
            [bool]$repairAgentGenericPatchImportProbeManifest.preflightRepositoryApplyAllowed -and
            [int]$repairAgentGenericPatchImportProbeManifest.preflightUnsafePathCount -eq 0 -and
            $repairAgentGenericPatchImportProbeManifest.genericTargetPath -eq "docs/repair-agent-generic-probe.md" -and
            -not [bool]$repairAgentGenericPatchImportProbeManifest.mainRepositoryPatchApplied) `
        "Repair-agent generic patch import probe must prove verified external-agent patches are not tied to the deterministic sample null-guard snippet."

    Test-ListedFiles $repairAgentGenericPatchImportProbeManifest "repair_agent_generic_patch_import_probe"
}

if ($null -ne $repairAgentSourceSnapshotApplyValidateManifest) {
    Add-ReleaseCheck "repair_agent_source_snapshot_apply_validate" `
        ($repairAgentSourceSnapshotApplyValidateManifest.status -eq "PASS" -and
            $repairAgentSourceSnapshotApplyValidateManifest.schemaVersion -eq "aitestpilot.repair_agent_source_snapshot_apply_validate.v1" -and
            [int]$repairAgentSourceSnapshotApplyValidateManifest.sourceSnapshotFileCount -gt 20 -and
            $repairAgentSourceSnapshotApplyValidateManifest.patchOutputSource -eq "external_agent" -and
            [bool]$repairAgentSourceSnapshotApplyValidateManifest.externalAgentRun -and
            [bool]$repairAgentSourceSnapshotApplyValidateManifest.externalAgentCompletionVerified -and
            $repairAgentSourceSnapshotApplyValidateManifest.repairAgentRunStatus -eq "EXTERNAL_AGENT_COMPLETED" -and
            $repairAgentSourceSnapshotApplyValidateManifest.repairAgentPatchOutputStatus -eq "PRODUCED" -and
            -not [bool]$repairAgentSourceSnapshotApplyValidateManifest.sampleFixSnippetRequired -and
            $repairAgentSourceSnapshotApplyValidateManifest.preflightStatus -eq "PASS" -and
            [bool]$repairAgentSourceSnapshotApplyValidateManifest.preflightSafeToInspect -and
            [bool]$repairAgentSourceSnapshotApplyValidateManifest.preflightRepositoryApplyAllowed -and
            [int]$repairAgentSourceSnapshotApplyValidateManifest.preflightUnsafePathCount -eq 0 -and
            [bool]$repairAgentSourceSnapshotApplyValidateManifest.worktreeCleanBeforeApply -and
            $repairAgentSourceSnapshotApplyValidateManifest.applyDecision -eq "APPLY" -and
            [bool]$repairAgentSourceSnapshotApplyValidateManifest.applySwitchProvided -and
            [bool]$repairAgentSourceSnapshotApplyValidateManifest.gitApplyCheckPassed -and
            [bool]$repairAgentSourceSnapshotApplyValidateManifest.repositoryPatchApplied -and
            [bool]$repairAgentSourceSnapshotApplyValidateManifest.patchedFilePresent -and
            [bool]$repairAgentSourceSnapshotApplyValidateManifest.sourceSnapshotValidationInvoked -and
            [bool]$repairAgentSourceSnapshotApplyValidateManifest.sourceSnapshotValidationPassed -and
            [bool]$repairAgentSourceSnapshotApplyValidateManifest.rollbackPatchGenerated -and
            [bool]$repairAgentSourceSnapshotApplyValidateManifest.rollbackPatchIncludesUntrackedFiles -and
            [int]$repairAgentSourceSnapshotApplyValidateManifest.rollbackPatchUntrackedFileCount -ge 1 -and
            $repairAgentSourceSnapshotApplyValidateManifest.rollbackPlanStatus -eq "READY" -and
            [bool]$repairAgentSourceSnapshotApplyValidateManifest.rollbackApplied -and
            [bool]$repairAgentSourceSnapshotApplyValidateManifest.rollbackRemovedPatchedFile -and
            [bool]$repairAgentSourceSnapshotApplyValidateManifest.worktreeCleanAfterRollback -and
            -not [bool]$repairAgentSourceSnapshotApplyValidateManifest.mainRepositoryPatchApplied) `
        "Repair-agent source snapshot apply/validate must prove verified external patch application, repo validation, rollback restore, and no main repository mutation."

    Test-ListedFiles $repairAgentSourceSnapshotApplyValidateManifest "repair_agent_source_snapshot_apply_validate"
}

if ($null -ne $repairAgentMainWorktreeApplyReadinessManifest) {
    $mainWorktreeIsReady = [bool]$repairAgentMainWorktreeApplyReadinessManifest.worktreeClean -and
        [bool]$repairAgentMainWorktreeApplyReadinessManifest.readyForMainRepositoryApply -and
        [int]$repairAgentMainWorktreeApplyReadinessManifest.sourceStatusCount -eq 0 -and
        [int]$repairAgentMainWorktreeApplyReadinessManifest.untrackedSourceStatusCount -eq 0 -and
        [int]$repairAgentMainWorktreeApplyReadinessManifest.untrackedSourceFileCount -eq 0 -and
        [int]$repairAgentMainWorktreeApplyReadinessManifest.blockingReasonCount -eq 0

    $mainWorktreeIsBlockedByBaseline = -not [bool]$repairAgentMainWorktreeApplyReadinessManifest.worktreeClean -and
        -not [bool]$repairAgentMainWorktreeApplyReadinessManifest.readyForMainRepositoryApply -and
        [int]$repairAgentMainWorktreeApplyReadinessManifest.sourceStatusCount -gt 0 -and
        [int]$repairAgentMainWorktreeApplyReadinessManifest.untrackedSourceStatusCount -gt 0 -and
        [int]$repairAgentMainWorktreeApplyReadinessManifest.untrackedSourceFileCount -gt 20 -and
        [int]$repairAgentMainWorktreeApplyReadinessManifest.blockingReasonCount -ge 2 -and
        (Test-ContainsAll @($repairAgentMainWorktreeApplyReadinessManifest.blockingReasons) @(
            "dirty_worktree",
            "untracked_source_files"
        ))

    Add-ReleaseCheck "repair_agent_main_worktree_apply_readiness" `
        ($repairAgentMainWorktreeApplyReadinessManifest.status -eq "PASS" -and
            $repairAgentMainWorktreeApplyReadinessManifest.schemaVersion -eq "aitestpilot.repair_agent_main_worktree_apply_readiness.v1" -and
            -not [bool]$repairAgentMainWorktreeApplyReadinessManifest.mainRepositoryPatchApplied -and
            $repairAgentMainWorktreeApplyReadinessManifest.repositoryApplyGuardPolicy -eq "main_repository_apply_requires_clean_source_worktree_verified_external_agent_preflight_explicit_apply_switch" -and
            ($mainWorktreeIsReady -or $mainWorktreeIsBlockedByBaseline) -and
            [bool]$repairAgentMainWorktreeApplyReadinessManifest.sourceSnapshotCandidateManifestPresent -and
            [bool]$repairAgentMainWorktreeApplyReadinessManifest.sourceSnapshotCandidateValidated -and
            [bool]$repairAgentMainWorktreeApplyReadinessManifest.sourceSnapshotCandidateRollbackClean -and
            -not [bool]$repairAgentMainWorktreeApplyReadinessManifest.sourceSnapshotCandidateMainRepositoryPatchApplied) `
        "Repair-agent main worktree readiness must prove either a clean main-worktree baseline ready for explicit external patch apply, or a machine-readable dirty-baseline blocker while clean source snapshot apply/validate/rollback evidence exists."

    Test-ListedFiles $repairAgentMainWorktreeApplyReadinessManifest "repair_agent_main_worktree_apply_readiness"
}

if ($null -ne $repairAgentMainWorktreeApplyRetestRollbackManifest) {
    $mainWorktreeTaskBindingPassed = [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.repairTaskPresent -and
        -not [string]::IsNullOrWhiteSpace($repairAgentMainWorktreeApplyRetestRollbackManifest.taskId) -and
        -not [string]::IsNullOrWhiteSpace($repairAgentMainWorktreeApplyRetestRollbackManifest.bugId) -and
        -not [string]::IsNullOrWhiteSpace($repairAgentMainWorktreeApplyRetestRollbackManifest.suggestedFix) -and
        [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.taskBugMatchesPatchOutput -and
        $repairAgentMainWorktreeApplyRetestRollbackManifest.patchOutputTaskId -eq $repairAgentMainWorktreeApplyRetestRollbackManifest.taskId -and
        $repairAgentMainWorktreeApplyRetestRollbackManifest.patchOutputBugId -eq $repairAgentMainWorktreeApplyRetestRollbackManifest.bugId -and
        [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.patchMentionsTaskId -and
        [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.patchMentionsBugId -and
        [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.patchMentionsSuggestedFix -and
        [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.summaryContainsTaskId -and
        [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.summaryContainsBugId -and
        [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.summaryContainsSuggestedFix

    Add-ReleaseCheck "repair_agent_main_worktree_apply_retest_rollback" `
        ($repairAgentMainWorktreeApplyRetestRollbackManifest.status -eq "PASS" -and
            $repairAgentMainWorktreeApplyRetestRollbackManifest.schemaVersion -eq "aitestpilot.repair_agent_main_worktree_apply_retest_rollback.v1" -and
            [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.externalOutputDirectoryProvided -and
            $repairAgentMainWorktreeApplyRetestRollbackManifest.inputPackageSource -eq "external_output_directory" -and
            -not [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.patchGeneratedByProbe -and
            $mainWorktreeTaskBindingPassed -and
            [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.readinessManifestPresent -and
            [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.readyForMainRepositoryApplyBeforeProbe -and
            [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.worktreeCleanBeforeApply -and
            [int]$repairAgentMainWorktreeApplyRetestRollbackManifest.sourceStatusBeforeCount -eq 0 -and
            $repairAgentMainWorktreeApplyRetestRollbackManifest.patchOutputSource -eq "external_agent" -and
            [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.externalAgentRun -and
            [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.externalAgentCompletionVerified -and
            $repairAgentMainWorktreeApplyRetestRollbackManifest.repairAgentRunStatus -eq "EXTERNAL_AGENT_COMPLETED" -and
            $repairAgentMainWorktreeApplyRetestRollbackManifest.repairAgentPatchOutputStatus -eq "PRODUCED" -and
            -not [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.sampleFixSnippetRequired -and
            $repairAgentMainWorktreeApplyRetestRollbackManifest.preflightStatus -eq "PASS" -and
            [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.preflightSafeToInspect -and
            [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.preflightRepositoryApplyAllowed -and
            [int]$repairAgentMainWorktreeApplyRetestRollbackManifest.preflightUnsafePathCount -eq 0 -and
            $repairAgentMainWorktreeApplyRetestRollbackManifest.applyDecision -eq "APPLY" -and
            [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.applySwitchProvided -and
            [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.gitApplyCheckPassed -and
            [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.repositoryChangedByScript -and
            -not [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.guardSourceStatusUnchanged -and
            [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.mainRepositoryPatchApplied -and
            [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.mainRepositoryPatchAppliedDuringProbe -and
            [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.patchedFilePresentBeforeRollback -and
            [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.patchedFileContainsProbeText -and
            [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.postApplyValidationInvoked -and
            [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.postApplyValidationPassed -and
            [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.postApplyRetestInvoked -and
            $repairAgentMainWorktreeApplyRetestRollbackManifest.postApplyRetestManifestStatus -eq "PASS" -and
            [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.postApplyRetestPassed -and
            -not [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.postApplyBugStillPresent -and
            [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.retestRanBeforeRollback -and
            [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.rollbackPatchGenerated -and
            [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.rollbackPatchIncludesUntrackedFiles -and
            [int]$repairAgentMainWorktreeApplyRetestRollbackManifest.rollbackPatchUntrackedFileCount -ge 1 -and
            $repairAgentMainWorktreeApplyRetestRollbackManifest.rollbackPlanStatus -eq "READY" -and
            [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.rollbackApplied -and
            [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.rollbackRemovedPatchedFile -and
            [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.mainRepositoryCleanAfterRollback -and
            [int]$repairAgentMainWorktreeApplyRetestRollbackManifest.sourceStatusAfterRollbackCount -eq 0 -and
            -not [bool]$repairAgentMainWorktreeApplyRetestRollbackManifest.mainRepositoryPatchPersisted) `
        "Repair-agent main worktree apply/retest/rollback must prove task-bound explicit verified external-directory patch application to the real main worktree, post-apply validation/retest before rollback, and clean rollback with no persistent patch."

    Test-ListedFiles $repairAgentMainWorktreeApplyRetestRollbackManifest "repair_agent_main_worktree_apply_retest_rollback"
}

if ($null -ne $repairAgentCursorAgentExternalOutputManifest) {
    $cursorAgentOutputTaskBindingPassed = -not [string]::IsNullOrWhiteSpace($repairAgentCursorAgentExternalOutputManifest.taskId) -and
        -not [string]::IsNullOrWhiteSpace($repairAgentCursorAgentExternalOutputManifest.bugId) -and
        -not [string]::IsNullOrWhiteSpace($repairAgentCursorAgentExternalOutputManifest.suggestedFix) -and
        [bool]$repairAgentCursorAgentExternalOutputManifest.patchMentionsTaskId -and
        [bool]$repairAgentCursorAgentExternalOutputManifest.patchMentionsBugId -and
        [bool]$repairAgentCursorAgentExternalOutputManifest.patchMentionsSuggestedFix -and
        [bool]$repairAgentCursorAgentExternalOutputManifest.summaryContainsTaskId -and
        [bool]$repairAgentCursorAgentExternalOutputManifest.summaryContainsBugId -and
        [bool]$repairAgentCursorAgentExternalOutputManifest.summaryContainsSuggestedFix

    Add-ReleaseCheck "repair_agent_cursor_agent_external_task_output" `
        ($repairAgentCursorAgentExternalOutputManifest.status -eq "PASS" -and
            $repairAgentCursorAgentExternalOutputManifest.schemaVersion -eq "aitestpilot.repair_agent_cursor_agent_external_output.v1" -and
            $repairAgentCursorAgentExternalOutputManifest.source -eq "headless_cursor_agent" -and
            -not [bool]$repairAgentCursorAgentExternalOutputManifest.fixtureGenerated -and
            [int]$repairAgentCursorAgentExternalOutputManifest.cursorAgentExitCode -eq 0 -and
            $repairAgentCursorAgentExternalOutputManifest.repairAgentRunStatus -eq "EXTERNAL_AGENT_COMPLETED" -and
            [bool]$repairAgentCursorAgentExternalOutputManifest.repairAgentRunAgentLaunched -and
            $repairAgentCursorAgentExternalOutputManifest.repairAgentPatchOutputStatus -eq "PRODUCED" -and
            [int]$repairAgentCursorAgentExternalOutputManifest.repairAgentPatchOutputCount -ge 2 -and
            [int]$repairAgentCursorAgentExternalOutputManifest.producedRequiredPatchOutputCount -eq [int]$repairAgentCursorAgentExternalOutputManifest.requiredPatchOutputCount -and
            $repairAgentCursorAgentExternalOutputManifest.patchOutputImportStatus -eq "PASS" -and
            $repairAgentCursorAgentExternalOutputManifest.patchOutputSource -eq "external_agent" -and
            [bool]$repairAgentCursorAgentExternalOutputManifest.externalAgentCompletionVerified -and
            $repairAgentCursorAgentExternalOutputManifest.preflightStatus -eq "PASS" -and
            [bool]$repairAgentCursorAgentExternalOutputManifest.preflightSafeToInspect -and
            [bool]$repairAgentCursorAgentExternalOutputManifest.preflightRepositoryApplyAllowed -and
            [int]$repairAgentCursorAgentExternalOutputManifest.preflightUnsafePathCount -eq 0 -and
            $cursorAgentOutputTaskBindingPassed -and
            -not [bool]$repairAgentCursorAgentExternalOutputManifest.mainRepositoryPatchApplied) `
        "Cursor Agent external task output must prove a headless non-fixture external package with import/preflight evidence and no repository mutation."

    Test-ListedFiles $repairAgentCursorAgentExternalOutputManifest "repair_agent_cursor_agent_external_task_output"
}

if ($null -ne $repairAgentExternalTaskOutputAcceptanceManifest) {
    $externalTaskOutputAcceptanceTaskBindingPassed = -not [string]::IsNullOrWhiteSpace($repairAgentExternalTaskOutputAcceptanceManifest.taskId) -and
        -not [string]::IsNullOrWhiteSpace($repairAgentExternalTaskOutputAcceptanceManifest.bugId) -and
        -not [string]::IsNullOrWhiteSpace($repairAgentExternalTaskOutputAcceptanceManifest.suggestedFix) -and
        [bool]$repairAgentExternalTaskOutputAcceptanceManifest.taskBugMatchesPatchOutput -and
        [bool]$repairAgentExternalTaskOutputAcceptanceManifest.patchMentionsTaskId -and
        [bool]$repairAgentExternalTaskOutputAcceptanceManifest.patchMentionsBugId -and
        [bool]$repairAgentExternalTaskOutputAcceptanceManifest.patchMentionsSuggestedFix -and
        [bool]$repairAgentExternalTaskOutputAcceptanceManifest.summaryContainsTaskId -and
        [bool]$repairAgentExternalTaskOutputAcceptanceManifest.summaryContainsBugId -and
        [bool]$repairAgentExternalTaskOutputAcceptanceManifest.summaryContainsSuggestedFix

    Add-ReleaseCheck "repair_agent_external_task_output_acceptance" `
        ($repairAgentExternalTaskOutputAcceptanceManifest.status -eq "PASS" -and
            $repairAgentExternalTaskOutputAcceptanceManifest.schemaVersion -eq "aitestpilot.repair_agent_external_task_output_acceptance.v1" -and
            ([bool]$repairAgentExternalTaskOutputAcceptanceManifest.fixtureGenerated -or [bool]$repairAgentExternalTaskOutputAcceptanceManifest.externalOutputDirectoryInputProvided) -and
            [bool]$repairAgentExternalTaskOutputAcceptanceManifest.externalOutputDirectoryProvided -and
            $repairAgentExternalTaskOutputAcceptanceManifest.inputPackageSource -eq "external_output_directory" -and
            -not [bool]$repairAgentExternalTaskOutputAcceptanceManifest.patchGeneratedByProbe -and
            $externalTaskOutputAcceptanceTaskBindingPassed -and
            $repairAgentExternalTaskOutputAcceptanceManifest.mainWorktreeApplyRetestRollbackStatus -eq "PASS" -and
            [bool]$repairAgentExternalTaskOutputAcceptanceManifest.mainRepositoryPatchApplied -and
            [bool]$repairAgentExternalTaskOutputAcceptanceManifest.postApplyRetestPassed -and
            [bool]$repairAgentExternalTaskOutputAcceptanceManifest.rollbackApplied -and
            [bool]$repairAgentExternalTaskOutputAcceptanceManifest.mainRepositoryCleanAfterRollback -and
            -not [bool]$repairAgentExternalTaskOutputAcceptanceManifest.mainRepositoryPatchPersisted) `
        "Repair-agent external task output acceptance must prove a task-bound external-output-directory package can drive main worktree apply/retest/rollback and roll back cleanly."

    Test-ListedFiles $repairAgentExternalTaskOutputAcceptanceManifest "repair_agent_external_task_output_acceptance"
}

if ($null -ne $repairAgentExternalPatchPreflightManifest) {
    Add-ReleaseCheck "repair_agent_external_patch_preflight" `
        ($repairAgentExternalPatchPreflightManifest.status -eq "PASS" -and
            $repairAgentExternalPatchPreflightManifest.schemaVersion -eq "aitestpilot.repair_agent_external_patch_preflight.v1" -and
            $repairAgentExternalPatchPreflightManifest.patchOutputSchemaVersion -eq "aitestpilot.repair_agent_patch_output.v1" -and
            $repairAgentExternalPatchPreflightManifest.patchOutputSource -eq "deterministic_sample" -and
            -not [bool]$repairAgentExternalPatchPreflightManifest.externalAgentRun -and
            [bool]$repairAgentExternalPatchPreflightManifest.patchLooksUnifiedDiff -and
            [bool]$repairAgentExternalPatchPreflightManifest.patchSizeBytesWithinLimit -and
            [int]$repairAgentExternalPatchPreflightManifest.uniqueTargetPathCount -ge 1 -and
            [int]$repairAgentExternalPatchPreflightManifest.unsafePathCount -eq 0 -and
            [bool]$repairAgentExternalPatchPreflightManifest.safeToInspect -and
            -not [bool]$repairAgentExternalPatchPreflightManifest.repositoryApplyAllowed -and
            [bool]$repairAgentExternalPatchPreflightManifest.requiresHumanReviewForRepositoryApply -and
            $repairAgentExternalPatchPreflightManifest.repositoryApplyPolicy -eq "requires_external_agent_source_safe_preflight_clean_worktree_explicit_apply_flag" -and
            (Test-ContainsAll @($repairAgentExternalPatchPreflightManifest.allowedPathPrefixes) @("Assets/", "src/", "unity/")) -and
            (Test-ContainsAll @($repairAgentExternalPatchPreflightManifest.uniqueTargetPaths) @("Assets/SampleModule/StartButton.cs"))) `
        "Repair-agent external patch preflight must validate safe target paths and keep repository apply disabled by default."

    Test-ListedFiles $repairAgentExternalPatchPreflightManifest "repair_agent_external_patch_preflight"
}

if ($null -ne $repairAgentExternalPatchPreflightFailureProbeManifest) {
    Add-ReleaseCheck "repair_agent_external_patch_preflight_failure_probe" `
        ($repairAgentExternalPatchPreflightFailureProbeManifest.status -eq "PASS" -and
            $repairAgentExternalPatchPreflightFailureProbeManifest.schemaVersion -eq "aitestpilot.repair_agent_external_patch_preflight_failure_probe.v1" -and
            [bool]$repairAgentExternalPatchPreflightFailureProbeManifest.expectedFailure -and
            [bool]$repairAgentExternalPatchPreflightFailureProbeManifest.preflightFailed -and
            $repairAgentExternalPatchPreflightFailureProbeManifest.unsafeManifestStatus -eq "FAIL" -and
            [int]$repairAgentExternalPatchPreflightFailureProbeManifest.unsafePathCount -ge 1 -and
            [int]$repairAgentExternalPatchPreflightFailureProbeManifest.failureReasonCount -ge 1 -and
            [bool]$repairAgentExternalPatchPreflightFailureProbeManifest.pathTraversalFound -and
            -not [bool]$repairAgentExternalPatchPreflightFailureProbeManifest.repositoryApplyAllowed) `
        "Repair-agent external patch preflight failure probe must prove unsafe path traversal patches are blocked."

    Test-ListedFiles $repairAgentExternalPatchPreflightFailureProbeManifest "repair_agent_external_patch_preflight_failure_probe"
}

if ($null -ne $repairAgentRepositoryPatchApplyGuardManifest) {
    $worktreeGuardPassed = [bool]$repairAgentRepositoryPatchApplyGuardManifest.worktreeClean -or
        (Test-ContainsAll @($repairAgentRepositoryPatchApplyGuardManifest.blockedReasons) @("dirty_worktree"))

    Add-ReleaseCheck "repair_agent_repository_patch_apply_guard" `
        ($repairAgentRepositoryPatchApplyGuardManifest.status -eq "PASS" -and
            $repairAgentRepositoryPatchApplyGuardManifest.schemaVersion -eq "aitestpilot.repair_agent_repository_patch_apply_guard.v1" -and
            $repairAgentRepositoryPatchApplyGuardManifest.applyDecision -eq "BLOCKED" -and
            [bool]$repairAgentRepositoryPatchApplyGuardManifest.explicitApplySwitchRequired -and
            -not [bool]$repairAgentRepositoryPatchApplyGuardManifest.applySwitchProvided -and
            [bool]$repairAgentRepositoryPatchApplyGuardManifest.cleanWorktreeRequired -and
            $worktreeGuardPassed -and
            [bool]$repairAgentRepositoryPatchApplyGuardManifest.externalAgentSourceRequired -and
            $repairAgentRepositoryPatchApplyGuardManifest.patchOutputSource -eq "deterministic_sample" -and
            -not [bool]$repairAgentRepositoryPatchApplyGuardManifest.externalAgentRun -and
            $repairAgentRepositoryPatchApplyGuardManifest.preflightStatus -eq "PASS" -and
            [bool]$repairAgentRepositoryPatchApplyGuardManifest.preflightSafeToInspect -and
            -not [bool]$repairAgentRepositoryPatchApplyGuardManifest.preflightRepositoryApplyAllowed -and
            -not [bool]$repairAgentRepositoryPatchApplyGuardManifest.repositoryPatchApplied -and
            -not [bool]$repairAgentRepositoryPatchApplyGuardManifest.repositoryChangedByScript -and
            [bool]$repairAgentRepositoryPatchApplyGuardManifest.sourceStatusUnchanged -and
            $repairAgentRepositoryPatchApplyGuardManifest.rollbackPlanStatus -eq "NOT_REQUIRED" -and
            [bool]$repairAgentRepositoryPatchApplyGuardManifest.rollbackPlanGenerated -and
            [bool]$repairAgentRepositoryPatchApplyGuardManifest.rollbackPlanHasContent -and
            -not [bool]$repairAgentRepositoryPatchApplyGuardManifest.rollbackPatchGenerated -and
            [int]$repairAgentRepositoryPatchApplyGuardManifest.blockedReasonCount -ge 3 -and
            (Test-ContainsAll @($repairAgentRepositoryPatchApplyGuardManifest.blockedReasons) @(
                "missing_explicit_apply_switch",
                "preflight_repository_apply_not_allowed",
                "not_external_agent_patch_output"
            ))) `
        "Repair-agent repository patch apply guard must block real source mutation without explicit apply switch, external-agent source, preflight allow, and clean worktree evidence."

    Test-ListedFiles $repairAgentRepositoryPatchApplyGuardManifest "repair_agent_repository_patch_apply_guard"
}

if ($null -ne $repairAgentRepositoryPatchApplyCleanProbeManifest) {
    Add-ReleaseCheck "repair_agent_repository_patch_apply_clean_probe" `
        ($repairAgentRepositoryPatchApplyCleanProbeManifest.status -eq "PASS" -and
            $repairAgentRepositoryPatchApplyCleanProbeManifest.schemaVersion -eq "aitestpilot.repair_agent_repository_patch_apply_clean_probe.v1" -and
            $repairAgentRepositoryPatchApplyCleanProbeManifest.patchOutputSource -eq "external_agent" -and
            [bool]$repairAgentRepositoryPatchApplyCleanProbeManifest.externalAgentRun -and
            [bool]$repairAgentRepositoryPatchApplyCleanProbeManifest.externalAgentCompletionVerified -and
            $repairAgentRepositoryPatchApplyCleanProbeManifest.repairAgentRunStatus -eq "EXTERNAL_AGENT_COMPLETED" -and
            $repairAgentRepositoryPatchApplyCleanProbeManifest.repairAgentPatchOutputStatus -eq "PRODUCED" -and
            [bool]$repairAgentRepositoryPatchApplyCleanProbeManifest.worktreeCleanBeforeApply -and
            $repairAgentRepositoryPatchApplyCleanProbeManifest.applyDecision -eq "APPLY" -and
            [bool]$repairAgentRepositoryPatchApplyCleanProbeManifest.applySwitchProvided -and
            [bool]$repairAgentRepositoryPatchApplyCleanProbeManifest.preflightRepositoryApplyAllowed -and
            [bool]$repairAgentRepositoryPatchApplyCleanProbeManifest.gitApplyCheckPassed -and
            [bool]$repairAgentRepositoryPatchApplyCleanProbeManifest.repositoryPatchApplied -and
            [bool]$repairAgentRepositoryPatchApplyCleanProbeManifest.rollbackPatchGenerated -and
            $repairAgentRepositoryPatchApplyCleanProbeManifest.rollbackPlanStatus -eq "READY" -and
            [bool]$repairAgentRepositoryPatchApplyCleanProbeManifest.patchedFileContainsExpectedFix -and
            [bool]$repairAgentRepositoryPatchApplyCleanProbeManifest.rollbackApplied -and
            [bool]$repairAgentRepositoryPatchApplyCleanProbeManifest.rollbackRestoredOriginal -and
            [bool]$repairAgentRepositoryPatchApplyCleanProbeManifest.worktreeCleanAfterRollback -and
            -not [bool]$repairAgentRepositoryPatchApplyCleanProbeManifest.mainRepositoryPatchApplied) `
        "Repair-agent repository patch clean apply probe must prove explicit external patch application, rollback patch generation, rollback restore, and no main repository mutation."

    Test-ListedFiles $repairAgentRepositoryPatchApplyCleanProbeManifest "repair_agent_repository_patch_apply_clean_probe"
}

if ($null -ne $repairAgentRepositoryPatchApplyCleanRetestManifest) {
    Add-ReleaseCheck "repair_agent_repository_patch_apply_clean_retest" `
        ($repairAgentRepositoryPatchApplyCleanRetestManifest.status -eq "PASS" -and
            $repairAgentRepositoryPatchApplyCleanRetestManifest.schemaVersion -eq "aitestpilot.repair_agent_repository_patch_apply_clean_retest.v1" -and
            $repairAgentRepositoryPatchApplyCleanRetestManifest.patchOutputSource -eq "external_agent" -and
            [bool]$repairAgentRepositoryPatchApplyCleanRetestManifest.externalAgentRun -and
            [bool]$repairAgentRepositoryPatchApplyCleanRetestManifest.externalAgentCompletionVerified -and
            $repairAgentRepositoryPatchApplyCleanRetestManifest.repairAgentRunStatus -eq "EXTERNAL_AGENT_COMPLETED" -and
            $repairAgentRepositoryPatchApplyCleanRetestManifest.repairAgentPatchOutputStatus -eq "PRODUCED" -and
            [bool]$repairAgentRepositoryPatchApplyCleanRetestManifest.worktreeCleanBeforeApply -and
            $repairAgentRepositoryPatchApplyCleanRetestManifest.applyDecision -eq "APPLY" -and
            [bool]$repairAgentRepositoryPatchApplyCleanRetestManifest.applySwitchProvided -and
            [bool]$repairAgentRepositoryPatchApplyCleanRetestManifest.preflightRepositoryApplyAllowed -and
            [bool]$repairAgentRepositoryPatchApplyCleanRetestManifest.gitApplyCheckPassed -and
            [bool]$repairAgentRepositoryPatchApplyCleanRetestManifest.repositoryPatchApplied -and
            [bool]$repairAgentRepositoryPatchApplyCleanRetestManifest.patchedFileContainsExpectedFix -and
            [bool]$repairAgentRepositoryPatchApplyCleanRetestManifest.postApplyRetestInvoked -and
            $repairAgentRepositoryPatchApplyCleanRetestManifest.postApplyRetestManifestStatus -eq "PASS" -and
            [bool]$repairAgentRepositoryPatchApplyCleanRetestManifest.postApplyRetestPassed -and
            -not [bool]$repairAgentRepositoryPatchApplyCleanRetestManifest.postApplyBugStillPresent -and
            [bool]$repairAgentRepositoryPatchApplyCleanRetestManifest.retestRanBeforeRollback -and
            [bool]$repairAgentRepositoryPatchApplyCleanRetestManifest.rollbackPatchGenerated -and
            $repairAgentRepositoryPatchApplyCleanRetestManifest.rollbackPlanStatus -eq "READY" -and
            [bool]$repairAgentRepositoryPatchApplyCleanRetestManifest.rollbackApplied -and
            [bool]$repairAgentRepositoryPatchApplyCleanRetestManifest.rollbackRestoredOriginal -and
            [bool]$repairAgentRepositoryPatchApplyCleanRetestManifest.worktreeCleanAfterRollback -and
            -not [bool]$repairAgentRepositoryPatchApplyCleanRetestManifest.mainRepositoryPatchApplied) `
        "Repair-agent repository patch clean apply/retest must prove explicit external patch application, post-apply retest before rollback, rollback restore, and no main repository mutation."

    Test-ListedFiles $repairAgentRepositoryPatchApplyCleanRetestManifest "repair_agent_repository_patch_apply_clean_retest"
}

if ($null -ne $repairAgentPatchApplyRetestManifest) {
    Add-ReleaseCheck "repair_agent_patch_apply_retest" `
        ($repairAgentPatchApplyRetestManifest.status -eq "PASS" -and
            $repairAgentPatchApplyRetestManifest.schemaVersion -eq "aitestpilot.repair_agent_patch_apply_retest.v1" -and
            $repairAgentPatchApplyRetestManifest.patchOutputSource -eq "deterministic_sample" -and
            -not [bool]$repairAgentPatchApplyRetestManifest.externalAgentRun -and
            $repairAgentPatchApplyRetestManifest.patchApplicationMode -eq "sandbox" -and
            [bool]$repairAgentPatchApplyRetestManifest.sandboxPatchApplied -and
            -not [bool]$repairAgentPatchApplyRetestManifest.repositoryPatchApplied -and
            [bool]$repairAgentPatchApplyRetestManifest.sandboxPatchedFileContainsExpectedFix -and
            [bool]$repairAgentPatchApplyRetestManifest.postPatchRetestInvoked -and
            $repairAgentPatchApplyRetestManifest.postPatchRetestManifestStatus -eq "PASS" -and
            [bool]$repairAgentPatchApplyRetestManifest.postPatchRetestPassed -and
            -not [bool]$repairAgentPatchApplyRetestManifest.postPatchBugStillPresent -and
            $repairAgentPatchApplyRetestManifest.postPatchRetestCommand -eq ".\tools\Invoke-AITestPilotRepairRetest.ps1") `
        "Repair-agent patch apply/retest must apply the sample patch in sandbox, run post-patch retest, and avoid claiming repository patch application."

    Test-ListedFiles $repairAgentPatchApplyRetestManifest "repair_agent_patch_apply_retest"
}

if ($null -ne $repairRetestManifest) {
    Add-ReleaseCheck "repair_retest" `
        ($repairRetestManifest.status -eq "PASS" -and
            [bool]$repairRetestManifest.retestPassed -and
            -not [bool]$repairRetestManifest.bugStillPresent -and
            [int]$repairRetestManifest.replayedStepCount -ge 5) `
        "Targeted repair retest must pass and replay the full business path."

    $descriptor = $repairRetestManifest.gameReplayDriverDescriptor
    Add-ReleaseCheck "driver_descriptor_present" ($null -ne $descriptor) "Repair retest must include driver descriptor."

    if ($null -ne $descriptor) {
        Add-ReleaseCheck "driver_descriptor_identity" `
            ($descriptor.driverId -eq $repairRetestManifest.gameReplayDriverId -and
                $descriptor.source -eq $repairRetestManifest.gameReplayDriverSource) `
            "Descriptor driver id/source must match the selected retest driver."

        $descriptorHandlerKeys = @($descriptor.supportedHandlerKeys)
        Add-ReleaseCheck "driver_descriptor_capabilities" `
            (Test-ContainsAll $descriptorHandlerKeys $requiredHandlerKeys) `
            "Descriptor must support all standard game replay handler keys."

        $configurationRequirements = @()
        if ($null -ne $descriptor.configurationRequirements) {
            $configurationRequirements = @($descriptor.configurationRequirements)
        }

        Add-ReleaseCheck "driver_descriptor_configuration" `
            ($configurationRequirements.Count -gt 0) `
            "Descriptor must declare configuration requirements."

        foreach ($requirement in $configurationRequirements) {
            Add-ReleaseCheck ("driver_config:" + $requirement.key) `
                (-not [string]::IsNullOrWhiteSpace($requirement.key) -and
                    -not [string]::IsNullOrWhiteSpace($requirement.source) -and
                    -not [string]::IsNullOrWhiteSpace($requirement.description)) `
                "Configuration requirement must include key, source, and description."
        }
    }

    Test-ListedFiles $repairRetestManifest "repair_retest"
}

if ($null -ne $failureProbeManifest) {
    Add-ReleaseCheck "driver_failure_probe" `
        ($failureProbeManifest.status -eq "PASS" -and
            [bool]$failureProbeManifest.expectedFailure -and
            [int]$failureProbeManifest.retestExitCode -ne 0 -and
            $failureProbeManifest.expectedHandlerKey -eq "game.claim_reward" -and
            $failureProbeManifest.expectedAction -eq "claim_reward" -and
            $failureProbeManifest.expectedTarget -eq "Activity.ClaimReward") `
        "Failure probe must prove hooked driver failures are diagnosable."

    $failureLogPath = Join-Path $EvidenceBundleDir "unity-repair-driver-failure.log"
    if (Test-Path $failureLogPath) {
        $failureLog = Get-Content -Raw $failureLogPath
        foreach ($snippet in @(
            "driver=failing.game_project_driver",
            "handler=game.claim_reward",
            "action=claim_reward",
            "target=Activity.ClaimReward",
            "step=3"
        )) {
            Add-ReleaseCheck ("driver_failure_log:" + $snippet) `
                ($failureLog -match [regex]::Escape($snippet)) `
                "Failure log must include diagnostic snippet."
        }
    }
    else {
        Add-ReleaseCheck "driver_failure_log" $false "Failure log is missing."
    }

    Test-ListedFiles $failureProbeManifest "driver_failure_probe"
}

if ($null -ne $profileImportManifest) {
    Add-ReleaseCheck "replay_profile_import" `
        ($profileImportManifest.status -eq "PASS" -and
            [bool]$profileImportManifest.assetPresent -and
            [int]$profileImportManifest.ruleCount -eq 5 -and
            (Test-ContainsAll @($profileImportManifest.handlerKeys) $requiredHandlerKeys)) `
        "Replay profile JSON must roundtrip into an editable Unity asset."
    Test-ListedFiles $profileImportManifest "replay_profile_import"
}

if ($null -ne $modelEndpointManifest) {
    Add-ReleaseCheck "model_endpoint_trace_probe" `
        ($modelEndpointManifest.status -eq "PASS" -and
            $modelEndpointManifest.clientType -eq "ModelEndpointDecisionClient" -and
            $modelEndpointManifest.endpointMode -eq "deterministic_local_handler" -and
            $modelEndpointManifest.actionSchemaVersion -eq "ai-testpilot.action.v1" -and
            [bool]$modelEndpointManifest.requestContainsActionSchema -and
            [bool]$modelEndpointManifest.requestContainsAllowedActions -and
            [bool]$modelEndpointManifest.requestContainsFixHints -and
            [int]$modelEndpointManifest.fixHintCount -eq 1 -and
            [bool]$modelEndpointManifest.responseValidated -and
            $modelEndpointManifest.traceStatus -eq "PASS") `
        "Model endpoint bridge must prove request schema, prior fix hints, response validation, and trace output."

    Add-ReleaseCheck "model_endpoint_action" `
        ($modelEndpointManifest.parsedAction.action -eq "click" -and
            $modelEndpointManifest.parsedAction.target -eq "Lobby.ActivityButton") `
        "Model endpoint probe must parse and validate the expected action."

    $requestPath = Join-Path $EvidenceBundleDir "model-endpoint-request.json"
    if (Test-Path $requestPath) {
        try {
            $modelRequest = Get-Content -Raw $requestPath | ConvertFrom-Json
            Add-ReleaseCheck "model_endpoint_request_contract" `
                ($modelRequest.schemaVersion -eq "ai-testpilot.decision_request.v1" -and
                    $modelRequest.actionSchemaVersion -eq "ai-testpilot.action.v1" -and
                    -not [string]::IsNullOrWhiteSpace($modelRequest.actionJsonSchema) -and
                    $modelRequest.actionJsonSchema -match [regex]::Escape("ai-testpilot.action.v1") -and
                    (Test-ContainsAll @($modelRequest.fixHints) @("add null guard before reward access")) -and
                    (Test-ContainsAll @($modelRequest.allowedActions) @("click", "wait", "finish"))) `
                "Model endpoint request must include schema version, action JSON schema, fix hints, and allowed action list."
        }
        catch {
            Add-ReleaseCheck "model_endpoint_request_contract" $false ("Request JSON could not be parsed: " + $_.Exception.Message)
        }
    }
    else {
        Add-ReleaseCheck "model_endpoint_request_contract" $false "Model endpoint request artifact is missing."
    }

    $tracePath = Join-Path $EvidenceBundleDir "model-endpoint-decision-trace.json"
    if (Test-Path $tracePath) {
        try {
            $modelTrace = Get-Content -Raw $tracePath | ConvertFrom-Json
            Add-ReleaseCheck "model_endpoint_trace_contract" `
                ($modelTrace.status -eq "PASS" -and
                    $modelTrace.runId -eq "MODEL-ENDPOINT-PROBE" -and
                    $modelTrace.action.action -eq "click" -and
                    -not [string]::IsNullOrWhiteSpace($modelTrace.requestJson) -and
                    -not [string]::IsNullOrWhiteSpace($modelTrace.responseJson)) `
                "Model endpoint trace must persist the request, response, parsed action, and status."
        }
        catch {
            Add-ReleaseCheck "model_endpoint_trace_contract" $false ("Trace JSON could not be parsed: " + $_.Exception.Message)
        }
    }
    else {
        Add-ReleaseCheck "model_endpoint_trace_contract" $false "Model endpoint trace artifact is missing."
    }

    Test-ListedFiles $modelEndpointManifest "model_endpoint_trace_probe"
}

if ($null -ne $modelEndpointProviderDiagnosticsManifest) {
    Add-ReleaseCheck "model_endpoint_provider_diagnostics" `
        ($modelEndpointProviderDiagnosticsManifest.status -eq "PASS" -and
            $modelEndpointProviderDiagnosticsManifest.schemaVersion -eq "ai-testpilot.model_endpoint_provider_diagnostics.v1" -and
            [int]$modelEndpointProviderDiagnosticsManifest.providerPresetCount -ge 4 -and
            -not [bool]$modelEndpointProviderDiagnosticsManifest.secretsSerialized) `
        "Model endpoint provider diagnostics must expose presets and avoid serializing secrets."

    Add-ReleaseCheck "model_endpoint_provider_request_formats" `
        (Test-ContainsAll @($modelEndpointProviderDiagnosticsManifest.supportedRequestFormats) @("NativeJson", "OpenAICompatibleChatCompletions")) `
        "Provider diagnostics must list both native JSON and OpenAI-compatible chat request formats."

    Add-ReleaseCheck "model_endpoint_provider_selected_preset" `
        ($null -ne $modelEndpointProviderDiagnosticsManifest.selectedPreset -and
            -not [string]::IsNullOrWhiteSpace($modelEndpointProviderDiagnosticsManifest.selectedPreset.id) -and
            (Test-ContainsAll @($modelEndpointProviderDiagnosticsManifest.supportedRequestFormats) @($modelEndpointProviderDiagnosticsManifest.selectedPreset.requestFormat))) `
        "Provider diagnostics must select a supported preset even when live env vars are absent."

    Add-ReleaseCheck "model_endpoint_provider_environment" `
        ($null -ne $modelEndpointProviderDiagnosticsManifest.configuredEnvironment -and
            -not [string]::IsNullOrWhiteSpace($modelEndpointProviderDiagnosticsManifest.configuredEnvironment.endpointEnvironmentVariable) -and
            -not [string]::IsNullOrWhiteSpace($modelEndpointProviderDiagnosticsManifest.configuredEnvironment.modelEnvironmentVariable) -and
            -not [string]::IsNullOrWhiteSpace($modelEndpointProviderDiagnosticsManifest.configuredEnvironment.requestFormat)) `
        "Provider diagnostics must record endpoint, model, and request-format environment bindings."

    Test-ListedFiles $modelEndpointProviderDiagnosticsManifest "model_endpoint_provider_diagnostics"
}

if ($null -ne $liveModelEndpointFailureProbeManifest) {
    Add-ReleaseCheck "live_model_endpoint_failure_probe" `
        ($liveModelEndpointFailureProbeManifest.status -eq "PASS" -and
            [bool]$liveModelEndpointFailureProbeManifest.expectedFailure -and
            [int]$liveModelEndpointFailureProbeManifest.expectedHttpStatus -eq 401 -and
            $liveModelEndpointFailureProbeManifest.expectedFailureCategory -eq "auth" -and
            $liveModelEndpointFailureProbeManifest.failureCategory -eq "auth" -and
            $liveModelEndpointFailureProbeManifest.traceStatus -eq "FAIL") `
        "Live model endpoint failure probe must classify deterministic auth failures."

    Add-ReleaseCheck "live_model_endpoint_failure_probe_contract" `
        ($liveModelEndpointFailureProbeManifest.requestFormat -eq "OpenAICompatibleChatCompletions" -and
            $liveModelEndpointFailureProbeManifest.actionSchemaVersion -eq "ai-testpilot.action.v1" -and
            [bool]$liveModelEndpointFailureProbeManifest.requestContainsActionSchema -and
            [bool]$liveModelEndpointFailureProbeManifest.requestContainsAllowedActions -and
            -not [bool]$liveModelEndpointFailureProbeManifest.responseValidated) `
        "Failure probe must preserve request-contract evidence while marking the response unvalidated."

    Add-ReleaseCheck "live_model_endpoint_failure_probe_remediation" `
        ($null -ne $liveModelEndpointFailureProbeManifest.failureRemediation -and
            @($liveModelEndpointFailureProbeManifest.failureRemediation).Count -ge 3 -and
            (@($liveModelEndpointFailureProbeManifest.failureRemediation) -join "`n") -match "API key" -and
            (@($liveModelEndpointFailureProbeManifest.failureRemediation) -join "`n") -match "authorization") `
        "Failure probe must include actionable auth remediation."

    Add-ReleaseCheck "live_model_endpoint_failure_probe_policy" `
        ($null -ne $liveModelEndpointFailureProbeManifest.failurePolicy -and
            -not [bool]$liveModelEndpointFailureProbeManifest.failurePolicy.retryable -and
            [int]$liveModelEndpointFailureProbeManifest.failurePolicy.recommendedRetryCount -eq 0 -and
            $liveModelEndpointFailureProbeManifest.failurePolicy.escalation -eq "secret_or_model_access_owner" -and
            $liveModelEndpointFailureProbeManifest.failurePolicy.releaseGateAction -eq "block") `
        "Failure probe must include retry/escalation policy for auth failures."

    Test-ListedFiles $liveModelEndpointFailureProbeManifest "live_model_endpoint_failure_probe"
}

if ($null -ne $liveModelEndpointManifest) {
    if ($liveModelEndpointManifest.status -eq "PASS") {
        $liveApiKeyRequired = $true
        if ($null -ne $liveModelEndpointManifest.PSObject.Properties["apiKeyRequired"]) {
            $liveApiKeyRequired = [bool]$liveModelEndpointManifest.apiKeyRequired
        }

        $liveApiKeyAccepted = [bool]$liveModelEndpointManifest.apiKeyConfigured -or -not $liveApiKeyRequired
        Add-ReleaseCheck "live_model_endpoint_smoke" `
            ($liveModelEndpointManifest.endpointMode -eq "live_http_endpoint" -and
                $liveModelEndpointManifest.clientType -eq "ModelEndpointDecisionClient" -and
                [bool]$liveModelEndpointManifest.endpointConfigured -and
                $liveApiKeyAccepted -and
                [int]$liveModelEndpointManifest.attemptCount -ge 1 -and
                -not [string]::IsNullOrWhiteSpace($liveModelEndpointManifest.requestFormat) -and
                $liveModelEndpointManifest.actionSchemaVersion -eq "ai-testpilot.action.v1" -and
                [bool]$liveModelEndpointManifest.requestContainsActionSchema -and
                [bool]$liveModelEndpointManifest.requestContainsAllowedActions -and
                [bool]$liveModelEndpointManifest.responseValidated -and
                $liveModelEndpointManifest.traceStatus -eq "PASS") `
            "Live model endpoint smoke must prove live request, response validation, and trace output."

        Add-ReleaseCheck "live_model_endpoint_action" `
            (-not [string]::IsNullOrWhiteSpace($liveModelEndpointManifest.parsedAction.action)) `
            "Live model endpoint smoke must parse a validated action."

        $liveTracePath = Join-Path $EvidenceBundleDir "live-model-endpoint-decision-trace.json"
        if (Test-Path $liveTracePath) {
            try {
                $liveTrace = Get-Content -Raw $liveTracePath | ConvertFrom-Json
                Add-ReleaseCheck "live_model_endpoint_trace_contract" `
                    ($liveTrace.status -eq "PASS" -and
                        $liveTrace.runId -eq "LIVE-MODEL-ENDPOINT-SMOKE" -and
                        -not [string]::IsNullOrWhiteSpace($liveTrace.requestJson) -and
                        -not [string]::IsNullOrWhiteSpace($liveTrace.responseJson)) `
                    "Live model endpoint trace must persist request, response, parsed action, and status."
            }
            catch {
                Add-ReleaseCheck "live_model_endpoint_trace_contract" $false ("Live trace JSON could not be parsed: " + $_.Exception.Message)
            }
        }
        else {
            Add-ReleaseCheck "live_model_endpoint_trace_contract" $false "Live model endpoint trace artifact is missing."
        }

        Test-ListedFiles $liveModelEndpointManifest "live_model_endpoint_smoke"
    }
    elseif ($liveModelEndpointManifest.status -eq "SKIPPED") {
        Add-ReleaseCheck "live_model_endpoint_smoke_optional" `
            (-not [bool]$RequireLiveModelEndpointSmoke) `
            ("Live model endpoint smoke skipped: " + $liveModelEndpointManifest.skippedReason)
    }
    elseif ($liveModelEndpointManifest.status -eq "FAIL") {
        $liveSmokeAttemptCount = 0
        if ($null -ne $liveModelEndpointManifest.PSObject.Properties["attemptCount"]) {
            $liveSmokeAttemptCount = [int]$liveModelEndpointManifest.attemptCount
        }

        $liveSmokeExpectedAttemptCount = 1
        if ($null -ne $liveModelEndpointManifest.failurePolicy -and
            [bool]$liveModelEndpointManifest.failurePolicy.retryable -and
            $null -ne $liveModelEndpointManifest.PSObject.Properties["retryPolicyExecuted"] -and
            [bool]$liveModelEndpointManifest.retryPolicyExecuted) {
            $policyRetries = [int]$liveModelEndpointManifest.failurePolicy.recommendedRetryCount
            $maxPolicyRetries = 0
            if ($null -ne $liveModelEndpointManifest.PSObject.Properties["maxPolicyRetries"]) {
                $maxPolicyRetries = [int]$liveModelEndpointManifest.maxPolicyRetries
            }

            $liveSmokeExpectedAttemptCount = 1 + [Math]::Min($policyRetries, $maxPolicyRetries)
        }

        Add-ReleaseCheck "live_model_endpoint_failure_classified" `
            (-not [string]::IsNullOrWhiteSpace($liveModelEndpointManifest.failureCategory) -and
                -not [string]::IsNullOrWhiteSpace($liveModelEndpointManifest.failureMessage) -and
                -not [string]::IsNullOrWhiteSpace($liveModelEndpointManifest.requestFormat) -and
                $null -ne $liveModelEndpointManifest.failureRemediation -and
                @($liveModelEndpointManifest.failureRemediation).Count -gt 0 -and
                $null -ne $liveModelEndpointManifest.failurePolicy -and
                -not [string]::IsNullOrWhiteSpace($liveModelEndpointManifest.failurePolicy.releaseGateAction) -and
                $liveSmokeAttemptCount -ge $liveSmokeExpectedAttemptCount) `
            "Failed live model endpoint smoke must include category, message, request format, remediation, retry/escalation policy, and policy-driven attempt evidence."

        Test-ListedFiles $liveModelEndpointManifest "live_model_endpoint_smoke"

        Add-ReleaseCheck "live_model_endpoint_smoke" $false `
            ("Live model endpoint smoke failed: " + $liveModelEndpointManifest.failureCategory)
    }
    else {
        Add-ReleaseCheck "live_model_endpoint_smoke" $false `
            ("Unexpected live model endpoint smoke status: " + $liveModelEndpointManifest.status)
    }
}

$allowRelease = $failedReasons.Count -eq 0
if ($allowRelease) {
    $gateStatus = "PASS"
}
else {
    $gateStatus = "BLOCKED"
}
$sourceManifests = @(
    "manifest.json",
    "repair-agent-patch-output-manifest.json",
    "repair-agent-external-completion-failure-probe-manifest.json",
    "repair-agent-generic-patch-import-probe-manifest.json",
    "repair-agent-source-snapshot-apply-validate-manifest.json",
    "repair-agent-main-worktree-apply-readiness-manifest.json",
    "repair-agent-main-worktree-apply-retest-rollback-manifest.json",
    "repair-agent-external-task-output-acceptance-manifest.json",
    "repair-agent-external-patch-preflight-manifest.json",
    "repair-agent-external-patch-preflight-failure-probe-manifest.json",
    "repair-agent-repository-patch-apply-guard-manifest.json",
    "repair-agent-repository-patch-apply-clean-probe-manifest.json",
    "repair-agent-repository-patch-apply-clean-retest-manifest.json",
    "repair-agent-patch-apply-retest-manifest.json",
    "repair-retest-manifest.json",
    "repair-driver-failure-manifest.json",
    "replay-profile-import-manifest.json",
    "model-endpoint-trace-manifest.json",
    "model-endpoint-provider-diagnostics-manifest.json",
    "live-model-endpoint-failure-probe-manifest.json",
    "live-model-endpoint-smoke-manifest.json"
)

if ($null -ne $repairAgentCursorAgentExternalOutputManifest) {
    $sourceManifests += "repair-agent-cursor-agent-external-output-manifest.json"
}

$manifest = [ordered]@{
    status = $gateStatus
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    allowRelease = $allowRelease
    checkCount = $checks.Count
    failedReasonCount = $failedReasons.Count
    failedReasons = @($failedReasons)
    checks = @($checks)
    sourceManifests = @($sourceManifests)
}

New-Item -ItemType Directory -Force (Split-Path $ReleaseGateManifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $ReleaseGateManifestPath -Encoding UTF8

if ($ExpectBlocked) {
    if ($allowRelease) {
        throw "Expected release gate to block, but it allowed release."
    }

    Write-Output "Release gate manifest: $ReleaseGateManifestPath"
    Write-Output "PASS AI TestPilot release gate blocked as expected"
    exit 0
}

if (-not $allowRelease) {
    throw "AI TestPilot release gate blocked release. Manifest: $ReleaseGateManifestPath"
}

Write-Output "Release gate manifest: $ReleaseGateManifestPath"
Write-Output "PASS AI TestPilot release gate"
