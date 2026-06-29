[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$WorkflowPath,
    [string]$ManifestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($WorkflowPath)) {
    $WorkflowPath = Join-Path $repoRoot ".azure-pipelines\ai-testpilot-release.yml"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "azure-pipelines-release-workflow-probe-manifest.json"
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
    if (-not $fullPath.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must stay under repo root: $fullPath"
    }

    return $fullPath
}

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

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$workflowFullPath = Assert-PathUnderRepo $WorkflowPath "WorkflowPath"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"

if (-not (Test-Path $workflowFullPath)) {
    throw "Azure Pipelines release workflow is missing: $workflowFullPath"
}

New-Item -ItemType Directory -Force $evidenceBundlePath | Out-Null

$workflowText = Get-Content -Path $workflowFullPath -Encoding UTF8 -Raw
$checks = @()

$requiredParameters = @(
    "unityPath",
    "gameReplayDriverType",
    "requireProductionReplayDriverBound",
    "requireProductionLuaPatched",
    "requireLiveModelEndpointSmoke",
    "allowMissingModelApiKey",
    "useCursorAgentExternalTaskOutput"
)

$requiredSwitches = @(
    "-UnityPath",
    "-GameReplayDriverType",
    "-ArtifactDir",
    "-RequireProductionReplayDriverBound",
    "-RequireProductionLuaPatched",
    "-RequireLiveModelEndpointSmoke",
    "-AllowMissingModelApiKey",
    "-UseCursorAgentExternalTaskOutput"
)

$requiredVariableBindings = @(
    "AITESTPILOT_LIVE_MODEL_ENDPOINT",
    "AI_TESTPILOT_MODEL_API_KEY",
    "AITESTPILOT_LIVE_MODEL",
    "AITESTPILOT_LIVE_MODEL_REQUEST_FORMAT"
)

$triggerSupported = $workflowText -match "(?m)^\s*trigger:\s*$"
$pullRequestSupported = $workflowText -match "(?m)^\s*pr:\s*$"
$parametersConfigured = $workflowText -match "(?m)^\s*parameters:\s*$"
$poolConfigured = $workflowText -match "(?m)^\s*pool:\s*$"
$selfHostedPoolNamed = $workflowText -match "(?m)^\s*name:\s*SelfHostedWindowsUnity\s*$"
$windowsDemandConfigured = $workflowText -match [regex]::Escape("Agent.OS -equals Windows_NT")
$checkoutConfigured = $workflowText -match "(?m)^\s*-\s*checkout:\s*self\s*$"
$powerShellTasksConfigured = @([regex]::Matches($workflowText, "PowerShell@2")).Count -ge 3
$pwshConfigured = @([regex]::Matches($workflowText, "(?m)^\s*pwsh:\s*true\s*$")).Count -ge 3
$releasePipelineCommandFound = $workflowText -match [regex]::Escape(".\tools\Invoke-AITestPilotReleasePipeline.ps1")
$artifactPublishConfigured = $workflowText -match "(?m)^\s*-\s*publish:\s*artifacts\\ai-testpilot-release\\latest\s*$"
$artifactNameConfigured = $workflowText -match "(?m)^\s*artifact:\s*ai-testpilot-release-evidence\s*$"
$artifactAlwaysPublished = $workflowText -match "(?m)^\s*condition:\s*succeededOrFailed\(\)\s*$"
$manifestStatusCheckConfigured = $workflowText -match [regex]::Escape('$manifest.status -ne "PASS"')
$ciExitCodeCheckConfigured = $workflowText -match [regex]::Escape("[int]`$manifest.ciExitCode -ne 0")
$dotnetInfoConfigured = $workflowText -match [regex]::Escape("dotnet --info")
$unityPathCheckConfigured = $workflowText -match [regex]::Escape('Test-Path "$(AI_TESTPILOT_UNITY_PATH)"')

$requiredParametersFound = @($requiredParameters | Where-Object {
        $workflowText -match "(?m)^\s*-\s*name:\s*$([regex]::Escape($_))\s*$"
    })
$requiredSwitchesFound = @($requiredSwitches | Where-Object { $workflowText -match [regex]::Escape($_) })
$requiredVariableBindingsFound = @($requiredVariableBindings | Where-Object { $workflowText -match [regex]::Escape($_) })

Add-ProbeCheck "trigger" $triggerSupported "Azure workflow must run on pushes."
Add-ProbeCheck "pull_request" $pullRequestSupported "Azure workflow must run on pull requests."
Add-ProbeCheck "parameters" ($parametersConfigured -and $requiredParametersFound.Count -eq $requiredParameters.Count) "Azure workflow must expose release-control parameters."
Add-ProbeCheck "pool" ($poolConfigured -and $selfHostedPoolNamed -and $windowsDemandConfigured) "Azure workflow must target the self-hosted Windows Unity pool."
Add-ProbeCheck "checkout" $checkoutConfigured "Azure workflow must checkout repository sources."
Add-ProbeCheck "powershell_tasks" ($powerShellTasksConfigured -and $pwshConfigured) "Azure workflow must run release scripts with PowerShell Core."
Add-ProbeCheck "runner_prerequisites" ($dotnetInfoConfigured -and $unityPathCheckConfigured) "Azure workflow must verify dotnet and Unity prerequisites."
Add-ProbeCheck "release_pipeline_command" $releasePipelineCommandFound "Azure workflow must call the release pipeline wrapper."
Add-ProbeCheck "required_switches" ($requiredSwitchesFound.Count -eq $requiredSwitches.Count) "Azure workflow must map parameters to release-pipeline switches."
Add-ProbeCheck "variable_bindings" ($requiredVariableBindingsFound.Count -eq $requiredVariableBindings.Count) "Azure workflow must bind live model endpoint variables."
Add-ProbeCheck "manifest_enforcement" ($manifestStatusCheckConfigured -and $ciExitCodeCheckConfigured) "Azure workflow must fail when the pipeline manifest is not PASS with ciExitCode 0."
Add-ProbeCheck "artifact_publish" ($artifactPublishConfigured -and $artifactNameConfigured -and $artifactAlwaysPublished) "Azure workflow must publish stable release evidence artifacts."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = "PASS"
if ($failedChecks.Count -gt 0) {
    $status = "FAIL"
}

$workflowSnapshotName = "azure-pipelines-ai-testpilot-release-workflow.yml"
Copy-Item -LiteralPath $workflowFullPath -Destination (Join-Path $evidenceBundlePath $workflowSnapshotName) -Force

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.azure_pipelines_release_workflow_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    provider = "azure_pipelines"
    workflowPath = $workflowFullPath
    workflowSnapshotFile = $workflowSnapshotName
    triggerSupported = [bool]$triggerSupported
    pullRequestSupported = [bool]$pullRequestSupported
    parametersConfigured = [bool]$parametersConfigured
    requiredParameterCount = [int]$requiredParameters.Count
    requiredParametersFoundCount = [int]$requiredParametersFound.Count
    requiredParameters = @($requiredParameters)
    poolConfigured = [bool]$poolConfigured
    selfHostedPoolNamed = [bool]$selfHostedPoolNamed
    windowsDemandConfigured = [bool]$windowsDemandConfigured
    checkoutConfigured = [bool]$checkoutConfigured
    powerShellTasksConfigured = [bool]$powerShellTasksConfigured
    pwshConfigured = [bool]$pwshConfigured
    runnerPrerequisitesConfigured = [bool]($dotnetInfoConfigured -and $unityPathCheckConfigured)
    releasePipelineCommandFound = [bool]$releasePipelineCommandFound
    requiredSwitchCount = [int]$requiredSwitches.Count
    requiredSwitchesFoundCount = [int]$requiredSwitchesFound.Count
    requiredSwitches = @($requiredSwitches)
    variableBindingCount = [int]$requiredVariableBindings.Count
    variableBindingsFoundCount = [int]$requiredVariableBindingsFound.Count
    variableBindings = @($requiredVariableBindings)
    manifestStatusCheckConfigured = [bool]$manifestStatusCheckConfigured
    ciExitCodeCheckConfigured = [bool]$ciExitCodeCheckConfigured
    artifactPublishConfigured = [bool]$artifactPublishConfigured
    artifactNameConfigured = [bool]$artifactNameConfigured
    artifactAlwaysPublished = [bool]$artifactAlwaysPublished
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
    files = @($workflowSnapshotName)
}

New-Item -ItemType Directory -Force (Split-Path $manifestFullPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFullPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Azure Pipelines release workflow probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Azure Pipelines release workflow probe manifest: $manifestFullPath"
Write-Output "PASS AI TestPilot Azure Pipelines release workflow probe"
