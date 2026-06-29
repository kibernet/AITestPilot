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
        "tools\Invoke-AITestPilotLuaStaticAnalysisProbe.ps1",
        "tools\Invoke-AITestPilotLuaAutoPatchSandboxProbe.ps1",
        "tools\Invoke-AITestPilotProductionLuaPatchReadiness.ps1",
        "tools\Invoke-AITestPilotProductionLuaPatchBoundFailureProbe.ps1",
        "tools\Invoke-AITestPilotLiveModelEndpointFailureProbe.ps1",
        "tools\Invoke-AITestPilotLiveModelEndpointSmoke.ps1",
        ".github\workflows\ai-testpilot-release.yml",
        "tools\Invoke-AITestPilotGitHubActionsWorkflowProbe.ps1",
        ".azure-pipelines\ai-testpilot-release.yml",
        "tools\Invoke-AITestPilotAzurePipelinesWorkflowProbe.ps1",
        "tools\Invoke-AITestPilotReplayDriverFailureProbe.ps1",
        "tools\Invoke-AITestPilotProductionDriverEvidenceIntake.ps1",
        "tools\Invoke-AITestPilotProductionDriverExternalBundleIntakeProbe.ps1",
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
