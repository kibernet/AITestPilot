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

function Test-PathWithinRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    $fullPath = Resolve-FullPath $Path
    $fullRoot = Resolve-FullPath $Root
    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    if ($fullPath.Equals($fullRoot, $comparison)) {
        return $true
    }

    if (-not $fullRoot.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $fullRoot = $fullRoot + [System.IO.Path]::DirectorySeparatorChar
    }

    return $fullPath.StartsWith($fullRoot, $comparison)
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

function Assert-PathUnderTemp {
    param(
        [string]$Path,
        [string]$Label
    )

    $fullPath = Resolve-FullPath $Path
    if (-not (Test-PathWithinRoot $fullPath $tempRoot)) {
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

function Convert-ToArray {
    param([object]$Value)

    if ($null -eq $Value) {
        return @()
    }

    return @($Value)
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

function Invoke-ExpectedFailure {
    param(
        [scriptblock]$Command,
        [string]$ExpectedMessage
    )

    try {
        & $Command | Out-Null
        return [pscustomobject]@{
            rejected = $false
            message = ""
            expectedMessageFound = $false
        }
    }
    catch {
        $message = $_.Exception.Message
        return [pscustomobject]@{
            rejected = $true
            message = $message
            expectedMessageFound = $message.Contains($ExpectedMessage)
        }
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
    -ManifestPath $externalGeneratedManifestPath `
    -ExternalOutputRoot $tempRoot `
    -AllowExternalOutput

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
    "$relativeKitDir/Invoke-LiveModelEndpointSmokeEvidence.ps1",
    "$relativeKitDir/Export-LiveModelEndpointSmokeEvidenceBundle.ps1",
    "$relativeKitDir/live-model-endpoint-config-kit-generated-manifest.json"
)

foreach ($fileName in $generatedFiles) {
    $path = Join-Path $evidenceBundlePath ($fileName -replace "/", "\")
    if (-not (Test-Path $path)) {
        throw "Live model endpoint config kit file is missing: $fileName"
    }
}

$exportHelperPath = Join-Path $kitPath "Export-LiveModelEndpointSmokeEvidenceBundle.ps1"
$exportHelperText = Get-Content -Path $exportHelperPath -Encoding UTF8 -Raw

$missingSmokeDir = Join-Path $probeBundlePath "missing-smoke-evidence"
New-Item -ItemType Directory -Force $missingSmokeDir | Out-Null
$missingExportOutputDir = Join-Path $evidenceBundlePath "live-model-endpoint-smoke-evidence-export\missing-smoke-export\live-smoke-evidence"
$missingExportZipPath = Join-Path $evidenceBundlePath "live-model-endpoint-smoke-evidence-export\missing-smoke-export\live-smoke-evidence.zip"
$exportMissingEvidenceRejected = $false
$exportMissingEvidenceError = ""
try {
    & $exportHelperPath `
        -AITestPilotRepoRoot $repoRoot `
        -EvidenceBundleDir $evidenceBundlePath `
        -LiveModelEndpointSmokeEvidenceDir $missingSmokeDir `
        -OutputDir $missingExportOutputDir `
        -ZipPath $missingExportZipPath
}
catch {
    $exportMissingEvidenceRejected = $true
    $exportMissingEvidenceError = $_.Exception.Message
}

$contractFixtureSmokeDir = Join-Path $probeBundlePath "contract-fixture-live-smoke-evidence"
New-Item -ItemType Directory -Force $contractFixtureSmokeDir | Out-Null
$contractFixtureSmokeManifest = [ordered]@{
    schemaVersion = "ai-testpilot.live_model_endpoint_smoke.v1"
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    endpointMode = "live_http_endpoint"
    clientType = "ModelEndpointDecisionClient"
    endpointConfigured = $true
    modelConfigured = $true
    apiKeyRequired = $true
    apiKeyConfigured = $true
    requestFormat = "NativeJson"
    actionSchemaVersion = "ai-testpilot.action.v1"
    requestContainsActionSchema = $true
    requestContainsAllowedActions = $true
    responseValidated = $true
    traceStatus = "PASS"
    attemptCount = 1
    parsedAction = [ordered]@{ action = "finish" }
    fixtureOnly = $true
    contractFixtureMode = $true
    realProviderAccessProven = $false
    liveSmokeExecuted = $false
    productionLiveEndpointAccessProven = $false
    evidenceProvenance = "contract_fixture_live_smoke_shape"
    productionOutputBoundary = "contract_fixture_live_smoke_shape_only"
}
$contractFixtureTrace = [ordered]@{
    runId = "LIVE-MODEL-ENDPOINT-SMOKE"
    requestJson = '{"messages":[{"role":"user","content":"contract fixture"}],"allowedActions":["finish"]}'
    responseJson = '{"action":"finish"}'
    fixtureOnly = $true
    contractFixtureMode = $true
    realProviderAccessProven = $false
    liveSmokeExecuted = $false
    productionLiveEndpointAccessProven = $false
    evidenceProvenance = "contract_fixture_live_smoke_shape"
    productionOutputBoundary = "contract_fixture_live_smoke_shape_only"
}
$contractFixtureSmokeManifest | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $contractFixtureSmokeDir "live-model-endpoint-smoke-manifest.json") -Encoding UTF8
$contractFixtureTrace | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $contractFixtureSmokeDir "live-model-endpoint-decision-trace.json") -Encoding UTF8

$fixtureExportOutputDir = Join-Path $evidenceBundlePath "live-model-endpoint-smoke-evidence-export\contract-fixture-smoke-export\live-smoke-evidence"
$fixtureExportZipPath = Join-Path $evidenceBundlePath "live-model-endpoint-smoke-evidence-export\contract-fixture-smoke-export\live-smoke-evidence.zip"
$fixtureExportIntakeManifestPath = Join-Path (Split-Path $fixtureExportOutputDir -Parent) "live-model-endpoint-smoke-evidence-intake-for-export.json"
$exportContractFixtureRejected = $false
$exportContractFixtureError = ""
try {
    & $exportHelperPath `
        -AITestPilotRepoRoot $repoRoot `
        -EvidenceBundleDir $evidenceBundlePath `
        -LiveModelEndpointSmokeEvidenceDir $contractFixtureSmokeDir `
        -OutputDir $fixtureExportOutputDir `
        -ZipPath $fixtureExportZipPath
}
catch {
    $exportContractFixtureRejected = $true
    $exportContractFixtureError = $_.Exception.Message
}

$fixtureExportRejectionIntake = if (Test-Path $fixtureExportIntakeManifestPath) {
    Read-JsonFile $fixtureExportIntakeManifestPath "Contract fixture export rejection intake manifest"
} else {
    $null
}

$generatorOutputDirBoundary = Invoke-ExpectedFailure `
    -ExpectedMessage "OutputDir must stay under repo root unless -AllowExternalOutput" `
    -Command {
        & (Join-Path $PSScriptRoot "New-AITestPilotLiveModelEndpointConfigKit.ps1") `
            -OutputDir (Join-Path $tempRoot "AITestPilot\live-config-kit-boundary-probe\external-output") `
            -ManifestPath (Join-Path $tempRoot "AITestPilot\live-config-kit-boundary-probe\external-output\live-model-endpoint-config-kit-generated-manifest.json")
    }
$generatorManifestPathBoundary = Invoke-ExpectedFailure `
    -ExpectedMessage "ManifestPath must stay under allowed root" `
    -Command {
        & (Join-Path $PSScriptRoot "New-AITestPilotLiveModelEndpointConfigKit.ps1") `
            -OutputDir (Join-Path $probeBundlePath "manifest-boundary-output") `
            -ManifestPath (Join-Path $probeBundlePath "manifest-escape.json")
    }
$exportHelperOutputDirBoundary = Invoke-ExpectedFailure `
    -ExpectedMessage "OutputDir must stay under" `
    -Command {
        & $exportHelperPath `
            -AITestPilotRepoRoot $repoRoot `
            -EvidenceBundleDir $evidenceBundlePath `
            -LiveModelEndpointSmokeEvidenceDir $missingSmokeDir `
            -OutputDir (Join-Path $probeBundlePath "export-output-escape\live-smoke-evidence") `
            -ZipPath (Join-Path $evidenceBundlePath "live-model-endpoint-smoke-evidence-export\output-boundary\live-smoke-evidence.zip")
    }
$exportHelperZipPathBoundary = Invoke-ExpectedFailure `
    -ExpectedMessage "ZipPath must stay under" `
    -Command {
        & $exportHelperPath `
            -AITestPilotRepoRoot $repoRoot `
            -EvidenceBundleDir $evidenceBundlePath `
            -LiveModelEndpointSmokeEvidenceDir $missingSmokeDir `
            -OutputDir (Join-Path $evidenceBundlePath "live-model-endpoint-smoke-evidence-export\zip-boundary\live-smoke-evidence") `
            -ZipPath (Join-Path $probeBundlePath "zip-escape.zip")
    }

$copiedAcceptedIntakeName = "live-model-endpoint-config-kit-accepted-intake-manifest.json"
$copiedExternalIntakeName = "live-model-endpoint-external-config-intake-manifest.json"
$copiedExternalConfigName = "live-model-endpoint-external-config-template.json"
Copy-Item -LiteralPath $acceptedIntakeManifestPath -Destination (Join-Path $evidenceBundlePath $copiedAcceptedIntakeName) -Force
Copy-Item -LiteralPath $externalIntakeManifestPath -Destination (Join-Path $evidenceBundlePath $copiedExternalIntakeName) -Force
Copy-Item -LiteralPath (Join-Path $externalConfigPath "live-model-endpoint-config.json") -Destination (Join-Path $evidenceBundlePath $copiedExternalConfigName) -Force

$externalConfigUnderRepo = Test-PathWithinRoot $externalConfigPath $repoRoot

$templateKitValid = $generatedManifest.status -eq "PASS" -and
    $generatedManifest.schemaVersion -eq "aitestpilot.live_model_endpoint_config_kit_generated.v1" -and
    [bool]$generatedManifest.templateOnly -and
    -not [bool]$generatedManifest.acceptedFixtureGenerated -and
    -not [bool]$generatedManifest.realProviderAccessProven -and
    -not [bool]$generatedManifest.liveSmokeExecuted -and
    -not [bool]$generatedManifest.secretsSerialized -and
    [bool]$generatedManifest.invokeHelperGenerated -and
    [bool]$generatedManifest.exportHelperGenerated -and
    [bool]$generatedManifest.exportHelperRequiresRealProviderEvidence -and
    [bool]$generatedManifest.exportHelperRequiresProductionLiveEndpointAccess -and
    [bool]$generatedManifest.exportHelperRejectsFixtureEvidence -and
    [bool]$generatedManifest.exportHelperRejectsSkippedEvidence -and
    [bool]$generatedManifest.exportHelperRejectsContractFixtureEvidence -and
    [int]$generatedManifest.generatedFileCount -eq 7 -and
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

$fixtureExportBlockingReasonCount = if ($null -ne $fixtureExportRejectionIntake) {
    [int]$fixtureExportRejectionIntake.blockingReasonCount
} else {
    -1
}
$fixtureExportBlockingReasons = if ($null -ne $fixtureExportRejectionIntake) {
    @(Convert-ToArray $fixtureExportRejectionIntake.blockingReasons | ForEach-Object { [string]$_ })
} else {
    @()
}
$exportHelperBoundaryPassed = [bool]$exportMissingEvidenceRejected -and
    [bool]$exportContractFixtureRejected -and
    -not (Test-Path $missingExportZipPath) -and
    -not (Test-Path $fixtureExportZipPath) -and
    $exportHelperText.Contains("direct_live_http_endpoint_pass") -and
    $exportHelperText.Contains("realProviderAccessProven") -and
    $exportHelperText.Contains("productionLiveEndpointAccessProven") -and
    $exportHelperText.Contains("fixtureOnly=false") -and
    $null -ne $fixtureExportRejectionIntake -and
    -not [bool]$fixtureExportRejectionIntake.smokeEvidenceAccepted -and
    -not [bool]$fixtureExportRejectionIntake.realProviderEvidenceAccepted -and
    -not [bool]$fixtureExportRejectionIntake.productionLiveEndpointAccessProven -and
    -not [bool]$fixtureExportRejectionIntake.realProviderAccessProven -and
    -not [bool]$fixtureExportRejectionIntake.liveSmokeExecuted -and
    -not [bool]$fixtureExportRejectionIntake.contractFixtureMode -and
    [bool]$fixtureExportRejectionIntake.fixtureEvidenceDetected -and
    [bool]$fixtureExportRejectionIntake.fixtureOnly -and
    [int]$fixtureExportRejectionIntake.blockingReasonCount -ge 1 -and
    $fixtureExportBlockingReasons -contains "live_model_endpoint_fixture_smoke_not_allowed"

$pathBoundaryRejected = [bool]$generatorOutputDirBoundary.rejected -and
    [bool]$generatorOutputDirBoundary.expectedMessageFound -and
    [bool]$generatorManifestPathBoundary.rejected -and
    [bool]$generatorManifestPathBoundary.expectedMessageFound -and
    [bool]$exportHelperOutputDirBoundary.rejected -and
    [bool]$exportHelperOutputDirBoundary.expectedMessageFound -and
    [bool]$exportHelperZipPathBoundary.rejected -and
    [bool]$exportHelperZipPathBoundary.expectedMessageFound

$checks = @()
Add-ProbeCheck "template_kit_generated" $templateKitValid "Template config kit must generate without claiming provider access."
Add-ProbeCheck "accepted_fixture_config_intake" $acceptedFixturePassed "Accepted config fixture must pass static intake without claiming live access."
Add-ProbeCheck "external_template_blocked" $externalTemplateBlocked "Repo-external pending config must be read and rejected under complete-configuration mode."
Add-ProbeCheck "export_helper_boundary" $exportHelperBoundaryPassed "Export helper must reject missing and contract-fixture smoke evidence unless direct live provider provenance is present."
Add-ProbeCheck "path_boundary" $pathBoundaryRejected "Generator and export helper must reject unmanaged output, manifest, and zip paths before writing."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$copiedFixtureExportRejectionName = "live-model-endpoint-config-kit-export-helper-fixture-rejection-intake-manifest.json"
if ($null -ne $fixtureExportRejectionIntake) {
    Copy-Item -LiteralPath $fixtureExportIntakeManifestPath -Destination (Join-Path $evidenceBundlePath $copiedFixtureExportRejectionName) -Force
}
$exportProbeFiles = if ($null -ne $fixtureExportRejectionIntake) {
    @($copiedFixtureExportRejectionName)
} else {
    @()
}

$files = @($generatedFiles + $copiedAcceptedIntakeName + $copiedExternalIntakeName + $copiedExternalConfigName + $exportProbeFiles)

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
    invokeHelperGenerated = [bool]$generatedManifest.invokeHelperGenerated
    exportHelperGenerated = [bool]$generatedManifest.exportHelperGenerated
    exportHelperRequiresRealProviderEvidence = [bool]$generatedManifest.exportHelperRequiresRealProviderEvidence
    exportHelperRequiresProductionLiveEndpointAccess = [bool]$generatedManifest.exportHelperRequiresProductionLiveEndpointAccess
    exportHelperRejectsFixtureEvidence = [bool]$generatedManifest.exportHelperRejectsFixtureEvidence
    exportHelperRejectsSkippedEvidence = [bool]$generatedManifest.exportHelperRejectsSkippedEvidence
    exportHelperRejectsContractFixtureEvidence = [bool]$generatedManifest.exportHelperRejectsContractFixtureEvidence
    exportHelperRequiresDirectLiveHttpProvenance = [bool]$exportHelperText.Contains("direct_live_http_endpoint_pass")
    exportHelperRejectedMissingEvidence = [bool]$exportMissingEvidenceRejected
    exportHelperMissingEvidenceError = $exportMissingEvidenceError
    exportHelperRejectedContractFixtureEvidence = [bool]$exportContractFixtureRejected
    exportHelperContractFixtureError = $exportContractFixtureError
    exportFixtureRejectionBlockingReasonCount = [int]$fixtureExportBlockingReasonCount
    exportFixtureRejectionBlockingReasons = @($fixtureExportBlockingReasons)
    generatorOutputDirBoundaryRejected = [bool]$generatorOutputDirBoundary.rejected
    generatorOutputDirBoundaryMessage = $generatorOutputDirBoundary.message
    generatorManifestPathBoundaryRejected = [bool]$generatorManifestPathBoundary.rejected
    generatorManifestPathBoundaryMessage = $generatorManifestPathBoundary.message
    exportHelperOutputDirBoundaryRejected = [bool]$exportHelperOutputDirBoundary.rejected
    exportHelperOutputDirBoundaryMessage = $exportHelperOutputDirBoundary.message
    exportHelperZipPathBoundaryRejected = [bool]$exportHelperZipPathBoundary.rejected
    exportHelperZipPathBoundaryMessage = $exportHelperZipPathBoundary.message
    pathBoundaryRejected = [bool]$pathBoundaryRejected
    productionOutputBoundary = "live_model_endpoint_config_kit_probe_only"
    evidenceExportHelperCommand = [string]$generatedManifest.evidenceExportHelperCommand
    evidenceExportZipPath = [string]$generatedManifest.evidenceExportZipPath
    evidenceExportManifestPath = [string]$generatedManifest.evidenceExportManifestPath
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
