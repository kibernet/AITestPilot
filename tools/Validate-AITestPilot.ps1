[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-CheckedNative {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath failed with exit code $LASTEXITCODE"
    }
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Push-Location $repoRoot

try {
    Write-Host "==> dotnet build"
    Invoke-CheckedNative "dotnet" @("build", ".\AITestPilot.sln", "--nologo")

    Write-Host "==> model endpoint probe build"
    Invoke-CheckedNative "dotnet" @(
        "build",
        ".\tools\Kibernet.AITestPilot.ModelEndpointProbe\Kibernet.AITestPilot.ModelEndpointProbe.csproj",
        "--nologo")

    Write-Host "==> Lua static analysis probe build"
    Invoke-CheckedNative "dotnet" @(
        "build",
        ".\tools\Kibernet.AITestPilot.LuaStaticAnalysisProbe\Kibernet.AITestPilot.LuaStaticAnalysisProbe.csproj",
        "--nologo")

    Write-Host "==> smoke tests"
    Invoke-CheckedNative "dotnet" @("run", "--project", ".\tests\Kibernet.AITestPilot.Core.SmokeTests\Kibernet.AITestPilot.Core.SmokeTests.csproj", "--no-build")

    Write-Host "==> package shape"
    $required = @(
        "unity\com.kibernet.ai-testpilot\package.json",
        "unity\com.kibernet.ai-testpilot\Runtime\AutomationId.cs",
        "unity\com.kibernet.ai-testpilot\Runtime\SnapshotProvider.cs",
        "unity\com.kibernet.ai-testpilot\Runtime\ActionExecutor.cs",
        "unity\com.kibernet.ai-testpilot\Runtime\ActionReplayAdapters.cs",
        "unity\com.kibernet.ai-testpilot\Runtime\ActionStepParser.cs",
        "unity\com.kibernet.ai-testpilot\Runtime\ConfiguredActionReplayAdapter.cs",
        "unity\com.kibernet.ai-testpilot\Runtime\GameActionReplayDriver.cs",
        "unity\com.kibernet.ai-testpilot\Runtime\GameActionReplayHooks.cs",
        "unity\com.kibernet.ai-testpilot\Runtime\ModelEndpointSettings.cs",
        "unity\com.kibernet.ai-testpilot\Runtime\ModelEndpointDecisionClient.cs",
        "unity\com.kibernet.ai-testpilot\Runtime\ProductionReplayIntegrationPlan.cs",
        "unity\com.kibernet.ai-testpilot\Runtime\BugDetector.cs",
        "unity\com.kibernet.ai-testpilot\Editor\AITestPilotWindow.cs",
        "unity\com.kibernet.ai-testpilot\Editor\BugKnowledgeGraphExporter.cs",
        "unity\com.kibernet.ai-testpilot\Editor\BugPackageExporter.cs",
        "unity\com.kibernet.ai-testpilot\Editor\ModelEndpointSettingsAssetUtility.cs",
        "unity\com.kibernet.ai-testpilot\Editor\ProductionReplayIntegrationPlanAssetUtility.cs",
        "unity\com.kibernet.ai-testpilot\Editor\ProductionReplayIntegrationPlanContractProbe.cs",
        "unity\com.kibernet.ai-testpilot\Editor\ActionReplayProfileBatchImporter.cs",
        "unity\com.kibernet.ai-testpilot\Editor\ActionReplayProfileAssetUtility.cs",
        "unity\com.kibernet.ai-testpilot\Editor\ReplayDriverFailureProbeDrivers.cs",
        "unity\com.kibernet.ai-testpilot\Editor\RepairTaskRetestRunner.cs",
        "unity\com.kibernet.ai-testpilot\Editor\RepairAgentHandoffExporter.cs",
        "unity\com.kibernet.ai-testpilot\Editor\RepairAgentRunExporter.cs",
        "unity\com.kibernet.ai-testpilot\Samples~\ProductionReplayDriver\ProductionReplayDriverTemplate.cs",
        "src\Kibernet.AITestPilot.Core\DecisionActionSchema.cs",
        "src\Kibernet.AITestPilot.Core\DecisionTrace.cs",
        "src\Kibernet.AITestPilot.Core\LuaStaticAnalysis.cs",
        "src\Kibernet.AITestPilot.Core\ModelEndpointDecisionClient.cs",
        "tools\Kibernet.AITestPilot.ModelEndpointProbe\Kibernet.AITestPilot.ModelEndpointProbe.csproj",
        "tools\Kibernet.AITestPilot.ModelEndpointProbe\Program.cs",
        "tools\Kibernet.AITestPilot.LuaStaticAnalysisProbe\Kibernet.AITestPilot.LuaStaticAnalysisProbe.csproj",
        "tools\Kibernet.AITestPilot.LuaStaticAnalysisProbe\Program.cs",
        "docs\integration\production-driver.md",
        "docs\model-endpoint.md",
        "tools\Invoke-AITestPilotModelEndpointTraceProbe.ps1",
        "tools\Invoke-AITestPilotModelEndpointProviderDiagnostics.ps1",
        "tools\Invoke-AITestPilotModelEndpointProviderRetryPolicyProbe.ps1",
        "tools\New-AITestPilotLiveModelEndpointConfigKit.ps1",
        "tools\Invoke-AITestPilotLiveModelEndpointConfigIntake.ps1",
        "tools\Invoke-AITestPilotLiveModelEndpointConfigKitProbe.ps1",
        "tools\Invoke-AITestPilotLiveModelEndpointSmokeEvidenceIntake.ps1",
        "tools\Invoke-AITestPilotLiveModelEndpointExternalSmokeIntakeProbe.ps1",
        "tools\Invoke-AITestPilotLiveModelEndpointSmokeEvidenceContractProbe.ps1",
        "tools\Invoke-AITestPilotLuaStaticAnalysisProbe.ps1",
        "tools\Invoke-AITestPilotLuaAutoPatchSandboxProbe.ps1",
        "tools\Invoke-AITestPilotProductionLuaPatchReadiness.ps1",
        "tools\Invoke-AITestPilotProductionLuaPatchBoundFailureProbe.ps1",
        "tools\New-AITestPilotProductionLuaPatchEvidenceKit.ps1",
        "tools\Invoke-AITestPilotProductionLuaPatchEvidenceKitProbe.ps1",
        "tools\Invoke-AITestPilotProductionLuaPatchExternalBundleIntakeProbe.ps1",
        "tools\Invoke-AITestPilotLiveModelEndpointFailureProbe.ps1",
        "tools\Invoke-AITestPilotLiveModelEndpointSmoke.ps1",
        ".github\workflows\ai-testpilot-release.yml",
        "tools\Invoke-AITestPilotGitHubActionsWorkflowProbe.ps1",
        ".azure-pipelines\ai-testpilot-release.yml",
        "tools\Invoke-AITestPilotAzurePipelinesWorkflowProbe.ps1",
        "tools\Invoke-AITestPilotProviderCiQualityProbe.ps1",
        "tools\Invoke-AITestPilotProductionHandoffPackage.ps1",
        "tools\Invoke-AITestPilotProductionHandoffExternalEvidencePreflightProbe.ps1",
        "tools\Invoke-AITestPilotProductionExternalEvidenceAcceptance.ps1",
        "tools\Invoke-AITestPilotProductionExternalEvidenceAcceptanceContractProbe.ps1",
        "tools\Invoke-AITestPilotProductionExternalEvidenceAcceptanceFailureProbe.ps1",
        "tools\Invoke-AITestPilotProductionExternalEvidenceInbox.ps1",
        "tools\Invoke-AITestPilotProductionExternalEvidenceInboxContractProbe.ps1",
        "tools\Invoke-AITestPilotProductionHandoffDispatchPlan.ps1",
        "tools\Invoke-AITestPilotProductionHandoffContactReadiness.ps1",
        "tools\Invoke-AITestPilotProductionHandoffContactReadinessContractProbe.ps1",
        "tools\Invoke-AITestPilotProductionHandoffSendReadiness.ps1",
        "tools\Invoke-AITestPilotProductionHandoffMailAuthReadiness.ps1",
        "tools\Invoke-AITestPilotProductionHandoffOwnerUnblockPack.ps1",
        "tools\Invoke-AITestPilotProductionHandoffOwnerUnblockPackContractProbe.ps1",
        "tools\Invoke-AITestPilotProductionHandoffOwnerInputRequestPack.ps1",
        "tools\Invoke-AITestPilotProductionHandoffOwnerContactExternalIntakeProbe.ps1",
        "tools\Invoke-AITestPilotProductionHandoffSendDryRunProbe.ps1",
        "tools\Invoke-AITestPilotProductionHandoffOwnerResponseBundleProbe.ps1",
        "tools\Invoke-AITestPilotProductionHandoffOwnerResponseBundleKit.ps1",
        "tools\Invoke-AITestPilotProductionHandoffOwnerResponseBundleKitWorkflowProbe.ps1",
        "tools\Invoke-AITestPilotProductionExternalEvidenceAutoAcceptance.ps1",
        "tools\Invoke-AITestPilotProductionExternalEvidenceAutoAcceptanceProbe.ps1",
        "tools\Invoke-AITestPilotProductionExternalEvidenceActionQueue.ps1",
        "tools\Invoke-AITestPilotProductionExternalEvidenceActionQueueProbe.ps1",
        "tools\Invoke-AITestPilotProductionExternalEvidenceGapAnalysis.ps1",
        "tools\Invoke-AITestPilotProductionExternalEvidencePartialMatrixProbe.ps1",
        "tools\Invoke-AITestPilotProductionHandoffExportZipIndex.ps1",
        "tools\Invoke-AITestPilotReleaseProgressNotificationOutbox.ps1",
        "tools\Invoke-AITestPilotProductionHandoffMailHelperAuthStatusProbe.ps1",
        "tools\Invoke-AITestPilotReleaseProgressNotificationConfirmationProbe.ps1",
        "tools\Invoke-AITestPilotReleaseProgressNotificationReceiptProbe.ps1",
        "tools\Invoke-AITestPilotReleaseProgressNotificationDispatchReceiptIntake.ps1",
        "tools\Invoke-AITestPilotReleaseProgressNotificationPostDispatchSnapshot.ps1",
        "tools\Invoke-AITestPilotReleaseProgressNotificationPostDispatchSnapshotProbe.ps1",
        "tools\Invoke-AITestPilotReleaseProgressNotificationDispatchReceiptIntakeProbe.ps1",
        "tools\Invoke-AITestPilotReleaseProgressNotificationLocalSendWorkflowProbe.ps1",
        "tools\Invoke-AITestPilotReleaseProgressNotificationRealReceiptGuardProbe.ps1",
        "tools\Invoke-AITestPilotProductionHardModeFailureProbe.ps1",
        "tools\Invoke-AITestPilotProductionHardModeSuccessContractProbe.ps1",
        "tools\Invoke-AITestPilotReleaseRiskPolicy.ps1",
        "tools\Invoke-AITestPilotReplayDriverFailureProbe.ps1",
        "tools\Invoke-AITestPilotProductionDriverEvidenceIntake.ps1",
        "tools\Invoke-AITestPilotProductionDriverExternalBundleIntakeProbe.ps1",
        "tools\Invoke-AITestPilotProductionDriverEvidenceContractProbe.ps1",
        "tools\New-AITestPilotProductionDriverBindingKit.ps1",
        "tools\Invoke-AITestPilotProductionDriverBindingKitProbe.ps1",
        "tools\Invoke-AITestPilotProductionReplayIntegrationContractProbe.ps1",
        "tools\Invoke-AITestPilotProductionReplayDriverReadiness.ps1",
        "tools\Invoke-AITestPilotProductionReplayDriverBoundFailureProbe.ps1",
        "tools\Invoke-AITestPilotReleaseEvidenceIndex.ps1",
        "tools\Invoke-AITestPilotReleaseGate.ps1",
        "tools\Invoke-AITestPilotReleaseGateFailureProbe.ps1",
        "tools\Invoke-AITestPilotReleasePipeline.ps1",
        "tools\Invoke-AITestPilotRepairAgentPatchOutputImport.ps1",
        "tools\Invoke-AITestPilotRepairAgentExternalCompletionFailureProbe.ps1",
        "tools\Invoke-AITestPilotRepairAgentGenericPatchImportProbe.ps1",
        "tools\Invoke-AITestPilotRepairAgentExternalPatchPreflight.ps1",
        "tools\Invoke-AITestPilotRepairAgentExternalPatchPreflightFailureProbe.ps1",
        "tools\Invoke-AITestPilotRepairAgentRepositoryPatchApplyGuard.ps1",
        "tools\Invoke-AITestPilotRepairAgentRepositoryPatchApplyCleanProbe.ps1",
        "tools\Invoke-AITestPilotRepairAgentRepositoryPatchApplyCleanRetest.ps1",
        "tools\Invoke-AITestPilotRepairAgentSourceSnapshotApplyValidate.ps1",
        "tools\Invoke-AITestPilotMainWorktreeApplyReadiness.ps1",
        "tools\Invoke-AITestPilotCursorAgentExternalTaskOutput.ps1",
        "tools\Invoke-AITestPilotRepairAgentExternalTaskOutputAcceptance.ps1",
        "tools\Invoke-AITestPilotRepairAgentPatchResultAnalysis.ps1",
        "tools\Invoke-AITestPilotRepairAgentPatchResultHistoryProbe.ps1",
        "tools\Invoke-AITestPilotRepairAgentMainWorktreeApplyRetestRollback.ps1",
        "tools\Invoke-AITestPilotRepairAgentPatchApplyRetest.ps1",
        "tools\Invoke-AITestPilotReplayProfileImport.ps1"
    )

    foreach ($path in $required) {
        if (-not (Test-Path $path)) {
            throw "Missing required file: $path"
        }
    }

    $package = Get-Content -Raw "unity\com.kibernet.ai-testpilot\package.json" | ConvertFrom-Json
    if ($package.name -ne "com.kibernet.ai-testpilot") {
        throw "Unexpected package name: $($package.name)"
    }

    $actionFile = Get-Content -Raw "unity\com.kibernet.ai-testpilot\Runtime\AIAction.cs"
    foreach ($verb in @("click", "wait", "prepare_account", "login", "enter_scene", "close_popup", "claim_reward", "play_fishing", "finish")) {
        if ($actionFile -notmatch [regex]::Escape($verb)) {
            throw "Missing action verb in AIAction.cs: $verb"
        }
    }

    Write-Host "PASS AI TestPilot validation"
}
finally {
    Pop-Location
}
