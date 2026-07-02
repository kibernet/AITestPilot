[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$WorkflowPath,
    [string]$ManifestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Test-PathWithinRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root)
    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    if ($fullPath.Equals($fullRoot, $comparison)) {
        return $true
    }

    if (-not $fullRoot.EndsWith(([System.IO.Path]::DirectorySeparatorChar).ToString())) {
        $fullRoot = $fullRoot + [System.IO.Path]::DirectorySeparatorChar
    }

    return $fullPath.StartsWith($fullRoot, $comparison)
}

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($WorkflowPath)) {
    $WorkflowPath = Join-Path $repoRoot ".github\workflows\ai-testpilot-release.yml"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "github-actions-release-workflow-probe-manifest.json"
}

function Resolve-FullPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Assert-PathUnderRepo {
    param(
        [string]$Path,
        [string]$Label
    )

    $fullPath = Resolve-FullPath $Path
    if (-not (Test-PathWithinRoot $fullPath $repoRoot)) {
        throw "$Label must stay under repo root: $fullPath"
    }

    return $fullPath
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$workflowFullPath = Assert-PathUnderRepo $WorkflowPath "WorkflowPath"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"

if (-not (Test-Path $workflowFullPath)) {
    throw "GitHub Actions release workflow is missing: $workflowFullPath"
}

New-Item -ItemType Directory -Force $evidenceBundlePath | Out-Null

$workflowText = Get-Content -Path $workflowFullPath -Encoding UTF8 -Raw
$checks = @()

function Add-ProbeCheck {
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
}

$requiredInputs = @(
    "unity_path",
    "game_replay_driver_type",
    "require_production_replay_driver_bound",
    "require_production_lua_patched",
    "production_lua_evidence_dir",
    "live_model_endpoint_smoke_evidence_dir",
    "require_live_model_endpoint_smoke",
    "allow_missing_model_api_key",
    "use_cursor_agent_external_task_output"
)

$requiredSwitches = @(
    "-UnityPath",
    "-GameReplayDriverType",
    "-ArtifactDir",
    "-RequireProductionReplayDriverBound",
    "-RequireProductionLuaPatched",
    "-ProductionLuaEvidenceDir",
    "-LiveModelEndpointSmokeEvidenceDir",
    "-RequireLiveModelEndpointSmoke",
    "-AllowMissingModelApiKey",
    "-UseCursorAgentExternalTaskOutput"
)

$requiredSecretBindings = @(
    "AITESTPILOT_LIVE_MODEL_ENDPOINT",
    "AI_TESTPILOT_MODEL_API_KEY",
    "AITESTPILOT_LIVE_MODEL",
    "AITESTPILOT_LIVE_MODEL_REQUEST_FORMAT"
)

$workflowDispatchSupported = $workflowText -match "(?m)^\s*workflow_dispatch:\s*$"
$pushSupported = $workflowText -match "(?m)^\s*push:\s*$"
$pullRequestSupported = $workflowText -match "(?m)^\s*pull_request:\s*$"
$selfHostedRunner = $workflowText -match "(?mi)runs-on:\s*\[[^\]]*self-hosted[^\]]*\]"
$windowsRunner = $workflowText -match "(?mi)runs-on:\s*\[[^\]]*Windows[^\]]*\]"
$unityRunner = $workflowText -match "(?mi)runs-on:\s*\[[^\]]*Unity[^\]]*\]"
$releasePipelineCommandFound = $workflowText -match [regex]::Escape(".\tools\Invoke-AITestPilotReleasePipeline.ps1")
$artifactUploadConfigured = $workflowText -match "actions/upload-artifact@v4"
$artifactPathConfigured = $workflowText -match [regex]::Escape("artifacts\ai-testpilot-release\latest")
$manifestStatusCheckConfigured = $workflowText -match [regex]::Escape('$manifest.status -ne "PASS"')
$ciExitCodeCheckConfigured = $workflowText -match [regex]::Escape("[int]`$manifest.ciExitCode -ne 0")
$permissionsReadOnly = $workflowText -match "(?ms)permissions:\s*\r?\n\s+contents:\s*read"
$pwshShellConfigured = $workflowText -match "(?m)^\s*shell:\s*pwsh\s*$"
$checkoutConfigured = $workflowText -match "actions/checkout@v4"
$timeoutConfigured = $workflowText -match "(?m)^\s*timeout-minutes:\s*(\d+)\s*$"
$concurrencyConfigured = $workflowText -match "(?m)^\s*concurrency:\s*$"
$continueOnErrorDisabled = -not ($workflowText -match "(?mi)^\s*continue-on-error:\s*true\s*$")

$requiredInputsFound = @($requiredInputs | Where-Object { $workflowText -match "(?m)^\s*$([regex]::Escape($_)):\s*$" })
$requiredSwitchesFound = @($requiredSwitches | Where-Object { $workflowText -match [regex]::Escape($_) })
$requiredSecretBindingsFound = @($requiredSecretBindings | Where-Object { $workflowText -match [regex]::Escape($_) })

Add-ProbeCheck "workflow_dispatch" $workflowDispatchSupported "Workflow must support manual production-bound dispatch."
Add-ProbeCheck "push" $pushSupported "Workflow must run on pushes for package-release gating."
Add-ProbeCheck "pull_request" $pullRequestSupported "Workflow must run on pull requests."
Add-ProbeCheck "runner_labels" ($selfHostedRunner -and $windowsRunner -and $unityRunner) "Workflow must target a self-hosted Windows Unity runner."
Add-ProbeCheck "release_pipeline_command" $releasePipelineCommandFound "Workflow must call the release pipeline wrapper."
Add-ProbeCheck "required_inputs" ($requiredInputsFound.Count -eq $requiredInputs.Count) "Workflow must expose release-control inputs."
Add-ProbeCheck "required_switches" ($requiredSwitchesFound.Count -eq $requiredSwitches.Count) "Workflow must map inputs to release-pipeline switches."
Add-ProbeCheck "secret_bindings" ($requiredSecretBindingsFound.Count -eq $requiredSecretBindings.Count) "Workflow must bind live model endpoint secrets and request format."
Add-ProbeCheck "artifact_upload" ($artifactUploadConfigured -and $artifactPathConfigured) "Workflow must upload stable release evidence artifacts."
Add-ProbeCheck "manifest_enforcement" ($manifestStatusCheckConfigured -and $ciExitCodeCheckConfigured) "Workflow must fail when the pipeline manifest is not PASS with ciExitCode 0."
Add-ProbeCheck "permissions" $permissionsReadOnly "Workflow must use read-only repository permissions."
Add-ProbeCheck "pwsh_shell" $pwshShellConfigured "Workflow must use PowerShell for Windows release scripts."
Add-ProbeCheck "checkout" $checkoutConfigured "Workflow must checkout repository sources."
Add-ProbeCheck "timeout" $timeoutConfigured "Workflow must set a job timeout."
Add-ProbeCheck "concurrency" $concurrencyConfigured "Workflow must set release-gate concurrency."
Add-ProbeCheck "continue_on_error" $continueOnErrorDisabled "Workflow must not continue on release-gate errors."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = "PASS"
if ($failedChecks.Count -gt 0) {
    $status = "FAIL"
}

$workflowSnapshotName = "github-actions-ai-testpilot-release-workflow.yml"
Copy-Item -LiteralPath $workflowFullPath -Destination (Join-Path $evidenceBundlePath $workflowSnapshotName) -Force

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.github_actions_release_workflow_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    provider = "github_actions"
    workflowPath = $workflowFullPath
    workflowSnapshotFile = $workflowSnapshotName
    workflowDispatchSupported = [bool]$workflowDispatchSupported
    pushSupported = [bool]$pushSupported
    pullRequestSupported = [bool]$pullRequestSupported
    selfHostedRunner = [bool]$selfHostedRunner
    windowsRunner = [bool]$windowsRunner
    unityRunner = [bool]$unityRunner
    releasePipelineCommandFound = [bool]$releasePipelineCommandFound
    requiredInputCount = [int]$requiredInputs.Count
    requiredInputsFoundCount = [int]$requiredInputsFound.Count
    requiredInputs = @($requiredInputs)
    requiredSwitchCount = [int]$requiredSwitches.Count
    requiredSwitchesFoundCount = [int]$requiredSwitchesFound.Count
    requiredSwitches = @($requiredSwitches)
    secretBindingCount = [int]$requiredSecretBindings.Count
    secretBindingsFoundCount = [int]$requiredSecretBindingsFound.Count
    secretBindings = @($requiredSecretBindings)
    artifactUploadConfigured = [bool]$artifactUploadConfigured
    artifactPathConfigured = [bool]$artifactPathConfigured
    manifestStatusCheckConfigured = [bool]$manifestStatusCheckConfigured
    ciExitCodeCheckConfigured = [bool]$ciExitCodeCheckConfigured
    permissionsReadOnly = [bool]$permissionsReadOnly
    pwshShellConfigured = [bool]$pwshShellConfigured
    checkoutConfigured = [bool]$checkoutConfigured
    timeoutConfigured = [bool]$timeoutConfigured
    concurrencyConfigured = [bool]$concurrencyConfigured
    continueOnErrorDisabled = [bool]$continueOnErrorDisabled
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
    files = @($workflowSnapshotName)
}

New-Item -ItemType Directory -Force (Split-Path $manifestFullPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFullPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "GitHub Actions release workflow probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "GitHub Actions release workflow probe manifest: $manifestFullPath"
Write-Output "PASS AI TestPilot GitHub Actions release workflow probe"
