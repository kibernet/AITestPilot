[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$KitDir,
    [string]$ProbeBundleDir,
    [string]$ExternalConfigDir,
    [string]$ManifestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($KitDir)) {
    $KitDir = Join-Path $EvidenceBundleDir "live-model-endpoint-config-kit"
}

if ([string]::IsNullOrWhiteSpace($ProbeBundleDir)) {
    $ProbeBundleDir = Join-Path $repoRoot "Temp\release-evidence\live-model-endpoint-config-kit-probe"
}

if ([string]::IsNullOrWhiteSpace($ExternalConfigDir)) {
    $ExternalConfigDir = Join-Path $tempRoot "AITestPilot\live-model-endpoint-external-config-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "live-model-endpoint-config-kit-probe-manifest.json"
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

function Assert-PathUnderTemp {
    param(
        [string]$Path,
        [string]$Label
    )

    $fullPath = Resolve-FullPath $Path
    if (-not $fullPath.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must stay under system temp for this probe: $fullPath"
    }

    return $fullPath
}

function Read-JsonFile {
    param(
        [string]$Path,
        [string]$Label
    )

    if (-not (Test-Path $Path)) {
        throw "$Label is missing: $Path"
    }

    return Get-Content -Path $Path -Encoding UTF8 -Raw | ConvertFrom-Json
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

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$kitPath = Assert-PathUnderRepo $KitDir "KitDir"
$probeBundlePath = Assert-PathUnderRepo $ProbeBundleDir "ProbeBundleDir"
$externalConfigPath = Assert-PathUnderTemp $ExternalConfigDir "ExternalConfigDir"
$manifestPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"

New-Item -ItemType Directory -Force $evidenceBundlePath | Out-Null

$generatedKitManifestPath = Join-Path $kitPath "live-model-endpoint-config-kit-generated-manifest.json"
& (Join-Path $PSScriptRoot "New-AITestPilotLiveModelEndpointConfigKit.ps1") `
    -OutputDir $kitPath `
    -ManifestPath $generatedKitManifestPath

if (Test-Path $probeBundlePath) {
    Remove-Item -LiteralPath $probeBundlePath -Recurse -Force
}
New-Item -ItemType Directory -Force $probeBundlePath | Out-Null

$acceptedConfigDir = Join-Path $probeBundlePath "accepted-config"
$acceptedGeneratedManifestPath = Join-Path $acceptedConfigDir "live-model-endpoint-config-kit-generated-manifest.json"
& (Join-Path $PSScriptRoot "New-AITestPilotLiveModelEndpointConfigKit.ps1") `
    -OutputDir $acceptedConfigDir `
    -ManifestPath $acceptedGeneratedManifestPath `
    -GenerateAcceptedFixture

$acceptedIntakeBundleDir = Join-Path $probeBundlePath "accepted-intake-bundle"
New-Item -ItemType Directory -Force $acceptedIntakeBundleDir | Out-Null
$acceptedIntakeManifestPath = Join-Path $acceptedIntakeBundleDir "live-model-endpoint-config-intake-manifest.json"
& (Join-Path $PSScriptRoot "Invoke-AITestPilotLiveModelEndpointConfigIntake.ps1") `
    -EvidenceBundleDir $acceptedIntakeBundleDir `
    -ManifestPath $acceptedIntakeManifestPath `
    -ConfigDir $acceptedConfigDir `
    -RequireCompleteConfiguration

if (Test-Path $externalConfigPath) {
    Remove-Item -LiteralPath $externalConfigPath -Recurse -Force
}

$externalGeneratedManifestPath = Join-Path $externalConfigPath "live-model-endpoint-config-kit-generated-manifest.json"
& (Join-Path $PSScriptRoot "New-AITestPilotLiveModelEndpointConfigKit.ps1") `
    -OutputDir $externalConfigPath `
    -ManifestPath $externalGeneratedManifestPath

$externalIntakeBundleDir = Join-Path $probeBundlePath "external-intake-bundle"
New-Item -ItemType Directory -Force $externalIntakeBundleDir | Out-Null
$externalIntakeManifestPath = Join-Path $externalIntakeBundleDir "live-model-endpoint-config-intake-manifest.json"
$externalIntakeCommandFailed = $false
$externalIntakeError = ""
try {
    & (Join-Path $PSScriptRoot "Invoke-AITestPilotLiveModelEndpointConfigIntake.ps1") `
        -EvidenceBundleDir $externalIntakeBundleDir `
        -ManifestPath $externalIntakeManifestPath `
        -ConfigDir $externalConfigPath `
        -RequireCompleteConfiguration
}
catch {
    $externalIntakeCommandFailed = $true
    $externalIntakeError = $_.Exception.Message
}

$generatedManifest = Read-JsonFile $generatedKitManifestPath "Generated live model config kit manifest"
$templateConfig = Read-JsonFile (Join-Path $kitPath "live-model-endpoint-config.json") "Template live model config"
$acceptedGeneratedManifest = Read-JsonFile $acceptedGeneratedManifestPath "Accepted live model config kit manifest"
$acceptedIntake = Read-JsonFile $acceptedIntakeManifestPath "Accepted live model config intake manifest"
$externalIntake = Read-JsonFile $externalIntakeManifestPath "External live model config intake manifest"

$relativeKitDir = "live-model-endpoint-config-kit"
$generatedFiles = @(
    "$relativeKitDir/README.md",
    "$relativeKitDir/live-model-endpoint-config.json",
    "$relativeKitDir/live-model-endpoint-config-schema.md",
    "$relativeKitDir/live-model-endpoint-smoke-runbook.md",
    "$relativeKitDir/live-model-endpoint-config-kit-generated-manifest.json"
)

foreach ($fileName in $generatedFiles) {
    $path = Join-Path $evidenceBundlePath ($fileName -replace "/", "\")
    if (-not (Test-Path $path)) {
        throw "Live model endpoint config kit file is missing: $fileName"
    }
}

$copiedAcceptedIntakeName = "live-model-endpoint-config-kit-accepted-intake-manifest.json"
$copiedExternalIntakeName = "live-model-endpoint-external-config-intake-manifest.json"
$copiedExternalConfigName = "live-model-endpoint-external-config-template.json"
Copy-Item -LiteralPath $acceptedIntakeManifestPath -Destination (Join-Path $evidenceBundlePath $copiedAcceptedIntakeName) -Force
Copy-Item -LiteralPath $externalIntakeManifestPath -Destination (Join-Path $evidenceBundlePath $copiedExternalIntakeName) -Force
Copy-Item -LiteralPath (Join-Path $externalConfigPath "live-model-endpoint-config.json") -Destination (Join-Path $evidenceBundlePath $copiedExternalConfigName) -Force

$externalConfigUnderRepo = $externalConfigPath.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)

$templateKitValid = $generatedManifest.status -eq "PASS" -and
    $generatedManifest.schemaVersion -eq "aitestpilot.live_model_endpoint_config_kit_generated.v1" -and
    [bool]$generatedManifest.templateOnly -and
    -not [bool]$generatedManifest.acceptedFixtureGenerated -and
    -not [bool]$generatedManifest.realProviderAccessProven -and
    -not [bool]$generatedManifest.liveSmokeExecuted -and
    -not [bool]$generatedManifest.secretsSerialized -and
    $templateConfig.status -eq "PENDING_LIVE_ENDPOINT_CONFIGURATION" -and
    -not [bool]$templateConfig.configurationComplete

$acceptedFixturePassed = $acceptedGeneratedManifest.status -eq "PASS" -and
    [bool]$acceptedGeneratedManifest.acceptedFixtureGenerated -and
    $acceptedIntake.status -eq "PASS" -and
    [bool]$acceptedIntake.requireCompleteConfiguration -and
    [bool]$acceptedIntake.configRead -and
    [bool]$acceptedIntake.configurationAccepted -and
    [bool]$acceptedIntake.readyForLiveEndpointSmoke -and
    [bool]$acceptedIntake.providerPresetSupported -and
    [bool]$acceptedIntake.endpointConfigured -and
    [bool]$acceptedIntake.endpointValid -and
    [bool]$acceptedIntake.modelConfigured -and
    [bool]$acceptedIntake.requestFormatValid -and
    [bool]$acceptedIntake.apiKeyReferenceProvided -and
    -not [bool]$acceptedIntake.secretsSerialized -and
    [bool]$acceptedIntake.configurationComplete -and
    [bool]$acceptedIntake.liveSmokeRequiredForProduction -and
    -not [bool]$acceptedIntake.liveSmokeExecuted -and
    -not [bool]$acceptedIntake.productionLiveEndpointAccessProven -and
    [int]$acceptedIntake.blockingReasonCount -eq 1

$externalTemplateBlocked = -not [bool]$externalConfigUnderRepo -and
    [bool]$externalIntakeCommandFailed -and
    $externalIntake.status -eq "PASS" -and
    [bool]$externalIntake.requireCompleteConfiguration -and
    [bool]$externalIntake.configRead -and
    -not [bool]$externalIntake.configurationAccepted -and
    -not [bool]$externalIntake.readyForLiveEndpointSmoke -and
    -not [bool]$externalIntake.endpointConfigured -and
    -not [bool]$externalIntake.modelConfigured -and
    -not [bool]$externalIntake.apiKeyReferenceProvided -and
    -not [bool]$externalIntake.secretsSerialized -and
    -not [bool]$externalIntake.configurationComplete -and
    [int]$externalIntake.blockingReasonCount -ge 4

$checks = @()
Add-ProbeCheck "template_kit_generated" $templateKitValid "Template config kit must generate without claiming provider access."
Add-ProbeCheck "accepted_fixture_config_intake" $acceptedFixturePassed "Accepted config fixture must pass static intake without claiming live access."
Add-ProbeCheck "external_template_blocked" $externalTemplateBlocked "Repo-external pending config must be read and rejected under complete-configuration mode."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$files = @($generatedFiles + $copiedAcceptedIntakeName + $copiedExternalIntakeName + $copiedExternalConfigName)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.live_model_endpoint_config_kit_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    kitDir = $kitPath
    probeBundleDir = $probeBundlePath
    externalConfigDir = $externalConfigPath
    externalConfigUnderRepo = [bool]$externalConfigUnderRepo
    templateKitGenerated = [bool]$templateKitValid
    templateOnly = $true
    acceptedFixtureGenerated = [bool]$acceptedGeneratedManifest.acceptedFixtureGenerated
    acceptedFixtureIntakePassed = [bool]$acceptedFixturePassed
    acceptedFixtureReadyForLiveEndpointSmoke = [bool]$acceptedIntake.readyForLiveEndpointSmoke
    acceptedFixtureProductionLiveAccessProven = [bool]$acceptedIntake.productionLiveEndpointAccessProven
    acceptedFixtureLiveSmokeExecuted = [bool]$acceptedIntake.liveSmokeExecuted
    externalTemplateRead = [bool]$externalIntake.configRead
    externalTemplateBlocked = [bool]$externalTemplateBlocked
    externalTemplateCommandFailed = [bool]$externalIntakeCommandFailed
    externalTemplateError = $externalIntakeError
    releasePipelineUsesFixture = $false
    productionLiveEndpointAccessProven = $false
    liveSmokeRequiredForProduction = $true
    liveSmokeExecuted = $false
    secretsSerialized = $false
    generatedFileCount = [int]$generatedFiles.Count
    generatedFiles = @($generatedFiles)
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
    files = @($files)
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Live model endpoint config kit probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Live model endpoint config kit probe manifest: $manifestPath"
Write-Output "PASS AI TestPilot live model endpoint config kit probe"
