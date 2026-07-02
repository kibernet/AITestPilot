[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$GitHubWorkflowPath,
    [string]$AzureWorkflowPath,
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

if ([string]::IsNullOrWhiteSpace($GitHubWorkflowPath)) {
    $GitHubWorkflowPath = Join-Path $repoRoot ".github\workflows\ai-testpilot-release.yml"
}

if ([string]::IsNullOrWhiteSpace($AzureWorkflowPath)) {
    $AzureWorkflowPath = Join-Path $repoRoot ".azure-pipelines\ai-testpilot-release.yml"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "provider-ci-quality-probe-manifest.json"
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

function Add-ProbeCheck {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Message
    )

    $script:checks += [ordered]@{
        name = $Name
        passed = [bool]$Passed
        message = $Message
    }
}

function Test-ContainsAllSnippets {
    param(
        [string]$Text,
        [string[]]$Snippets
    )

    foreach ($snippet in $Snippets) {
        if ($Text -notmatch [regex]::Escape($snippet)) {
            return $false
        }
    }

    return $true
}

function Get-IndexOfSnippet {
    param(
        [string]$Text,
        [string]$Snippet
    )

    return $Text.IndexOf($Snippet, [System.StringComparison]::Ordinal)
}

function Test-OrderedBefore {
    param(
        [string]$Text,
        [string[]]$BeforeSnippets,
        [string]$AfterSnippet
    )

    $afterIndex = Get-IndexOfSnippet $Text $AfterSnippet
    if ($afterIndex -lt 0) {
        return $false
    }

    foreach ($snippet in $BeforeSnippets) {
        $index = Get-IndexOfSnippet $Text $snippet
        if ($index -lt 0 -or $index -ge $afterIndex) {
            return $false
        }
    }

    return $true
}

function Test-OrderedAfter {
    param(
        [string]$Text,
        [string]$BeforeSnippet,
        [string[]]$AfterSnippets
    )

    $beforeIndex = Get-IndexOfSnippet $Text $BeforeSnippet
    if ($beforeIndex -lt 0) {
        return $false
    }

    foreach ($snippet in $AfterSnippets) {
        $index = Get-IndexOfSnippet $Text $snippet
        if ($index -lt 0 -or $index -le $beforeIndex) {
            return $false
        }
    }

    return $true
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$githubWorkflowFullPath = Assert-PathUnderRepo $GitHubWorkflowPath "GitHubWorkflowPath"
$azureWorkflowFullPath = Assert-PathUnderRepo $AzureWorkflowPath "AzureWorkflowPath"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"

if (-not (Test-Path $githubWorkflowFullPath)) {
    throw "GitHub Actions workflow is missing: $githubWorkflowFullPath"
}

if (-not (Test-Path $azureWorkflowFullPath)) {
    throw "Azure Pipelines workflow is missing: $azureWorkflowFullPath"
}

New-Item -ItemType Directory -Force $evidenceBundlePath | Out-Null

$githubText = Get-Content -Path $githubWorkflowFullPath -Encoding UTF8 -Raw
$azureText = Get-Content -Path $azureWorkflowFullPath -Encoding UTF8 -Raw
$checks = @()

$buildSnippets = @(
    "dotnet build .\AITestPilot.sln --nologo",
    "dotnet build .\tools\Kibernet.AITestPilot.ModelEndpointProbe\Kibernet.AITestPilot.ModelEndpointProbe.csproj --nologo",
    "dotnet build .\tools\Kibernet.AITestPilot.LuaStaticAnalysisProbe\Kibernet.AITestPilot.LuaStaticAnalysisProbe.csproj --nologo"
)

$testSnippets = @(
    "dotnet run --project .\tests\Kibernet.AITestPilot.Core.SmokeTests\Kibernet.AITestPilot.Core.SmokeTests.csproj --no-build"
)

$visionSnippets = @(
    "scene-validation.json",
    "snapshotSchemaVersion",
    "aitestpilot.snapshot.v1",
    "runReports",
    "releaseEvidence.allowRelease"
)

$githubBuildConfigured = $githubText -match [regex]::Escape("name: Provider build check") -and
    (Test-ContainsAllSnippets -Text $githubText -Snippets $buildSnippets)
$githubTestConfigured = $githubText -match [regex]::Escape("name: Provider smoke test check") -and
    (Test-ContainsAllSnippets -Text $githubText -Snippets $testSnippets)
$githubVisionConfigured = $githubText -match [regex]::Escape("name: Provider vision evidence check") -and
    (Test-ContainsAllSnippets -Text $githubText -Snippets $visionSnippets)
$githubBuildTestBeforePipeline = Test-OrderedBefore `
    -Text $githubText `
    -BeforeSnippets @("name: Provider build check", "name: Provider smoke test check") `
    -AfterSnippet "name: Run release pipeline"
$githubVisionAfterPipeline = Test-OrderedAfter `
    -Text $githubText `
    -BeforeSnippet "name: Run release pipeline" `
    -AfterSnippets @("name: Provider vision evidence check", "name: Enforce release manifest")

$azureBuildConfigured = $azureText -match [regex]::Escape("displayName: Provider build check") -and
    (Test-ContainsAllSnippets -Text $azureText -Snippets $buildSnippets)
$azureTestConfigured = $azureText -match [regex]::Escape("displayName: Provider smoke test check") -and
    (Test-ContainsAllSnippets -Text $azureText -Snippets $testSnippets)
$azureVisionConfigured = $azureText -match [regex]::Escape("displayName: Provider vision evidence check") -and
    (Test-ContainsAllSnippets -Text $azureText -Snippets $visionSnippets)
$azureBuildTestBeforePipeline = Test-OrderedBefore `
    -Text $azureText `
    -BeforeSnippets @("displayName: Provider build check", "displayName: Provider smoke test check") `
    -AfterSnippet "displayName: Run release pipeline"
$azureVisionAfterPipeline = Test-OrderedAfter `
    -Text $azureText `
    -BeforeSnippet "displayName: Run release pipeline" `
    -AfterSnippets @("displayName: Provider vision evidence check", "displayName: Enforce release manifest")

Add-ProbeCheck "github_provider_build_check" $githubBuildConfigured "GitHub Actions must run explicit provider-level .NET build checks before release pipeline."
Add-ProbeCheck "github_provider_smoke_test_check" $githubTestConfigured "GitHub Actions must run explicit provider-level smoke tests before release pipeline."
Add-ProbeCheck "github_provider_vision_evidence_check" $githubVisionConfigured "GitHub Actions must inspect scene-validation snapshot, run report, and release evidence after the release pipeline."
Add-ProbeCheck "github_provider_quality_order" ($githubBuildTestBeforePipeline -and $githubVisionAfterPipeline) "GitHub Actions provider quality checks must wrap the release pipeline in the expected order."

Add-ProbeCheck "azure_provider_build_check" $azureBuildConfigured "Azure Pipelines must run explicit provider-level .NET build checks before release pipeline."
Add-ProbeCheck "azure_provider_smoke_test_check" $azureTestConfigured "Azure Pipelines must run explicit provider-level smoke tests before release pipeline."
Add-ProbeCheck "azure_provider_vision_evidence_check" $azureVisionConfigured "Azure Pipelines must inspect scene-validation snapshot, run report, and release evidence after the release pipeline."
Add-ProbeCheck "azure_provider_quality_order" ($azureBuildTestBeforePipeline -and $azureVisionAfterPipeline) "Azure Pipelines provider quality checks must wrap the release pipeline in the expected order."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = "PASS"
if ($failedChecks.Count -gt 0) {
    $status = "FAIL"
}

$githubSnapshotName = "github-actions-ai-testpilot-release-workflow.yml"
$azureSnapshotName = "azure-pipelines-ai-testpilot-release-workflow.yml"
Copy-Item -LiteralPath $githubWorkflowFullPath -Destination (Join-Path $evidenceBundlePath $githubSnapshotName) -Force
Copy-Item -LiteralPath $azureWorkflowFullPath -Destination (Join-Path $evidenceBundlePath $azureSnapshotName) -Force

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.provider_ci_quality_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    providerCount = 2
    buildCheckProviderCount = [int]@($githubBuildConfigured, $azureBuildConfigured | Where-Object { $_ }).Count
    smokeTestProviderCount = [int]@($githubTestConfigured, $azureTestConfigured | Where-Object { $_ }).Count
    visionCheckProviderCount = [int]@($githubVisionConfigured, $azureVisionConfigured | Where-Object { $_ }).Count
    githubActionsQualityAccepted = [bool]($githubBuildConfigured -and $githubTestConfigured -and $githubVisionConfigured -and $githubBuildTestBeforePipeline -and $githubVisionAfterPipeline)
    azurePipelinesQualityAccepted = [bool]($azureBuildConfigured -and $azureTestConfigured -and $azureVisionConfigured -and $azureBuildTestBeforePipeline -and $azureVisionAfterPipeline)
    providerQualityAccepted = [bool]($failedChecks.Count -eq 0)
    githubActionsWorkflowSnapshotFile = $githubSnapshotName
    azurePipelinesWorkflowSnapshotFile = $azureSnapshotName
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
    files = @(
        $githubSnapshotName,
        $azureSnapshotName
    )
}

New-Item -ItemType Directory -Force (Split-Path $manifestFullPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFullPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Provider CI quality probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Provider CI quality probe manifest: $manifestFullPath"
Write-Output "PASS AI TestPilot provider CI quality probe"
