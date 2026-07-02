[CmdletBinding()]
param(
    [string]$OutputDir,
    [string]$ManifestPath,
    [switch]$GenerateAcceptedFixture,
    [string]$ExternalOutputRoot,
    [switch]$AllowExternalOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

    if (-not $fullRoot.EndsWith(([System.IO.Path]::DirectorySeparatorChar).ToString())) {
        $fullRoot = $fullRoot + [System.IO.Path]::DirectorySeparatorChar
    }

    return $fullPath.StartsWith($fullRoot, $comparison)
}

function Assert-PathUnderRoot {
    param(
        [string]$Path,
        [string]$Root,
        [string]$Label
    )

    $fullPath = Resolve-FullPath $Path
    if (-not (Test-PathWithinRoot $fullPath $Root)) {
        throw "$Label must stay under allowed root: $fullPath"
    }

    return $fullPath
}

function Assert-ManagedOutputPath {
    param(
        [string]$Path,
        [string]$Label
    )

    $fullPath = Resolve-FullPath $Path
    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    $underRepo = Test-PathWithinRoot $fullPath $repoRoot
    $underExternalRoot = (Test-PathWithinRoot $fullPath $externalOutputRootPath)
    if (-not $underRepo -and -not ([bool]$AllowExternalOutput -and $underExternalRoot)) {
        throw "$Label must stay under repo root unless -AllowExternalOutput is set for the configured external output root: $fullPath"
    }

    $pathRoot = [System.IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Equals($pathRoot, $comparison) -or
        $fullPath.Equals($repoRoot, $comparison) -or
        $fullPath.Equals($repoTempRoot, $comparison) -or
        $fullPath.Equals($externalOutputRootPath, $comparison)) {
        throw "$Label must target a managed child directory, not a root directory: $fullPath"
    }

    return $fullPath
}

$repoRoot = Resolve-FullPath ((Resolve-Path (Join-Path $PSScriptRoot "..")).Path)
$repoTempRoot = Resolve-FullPath (Join-Path $repoRoot "Temp")
$tempRoot = Resolve-FullPath $env:TEMP
if ([string]::IsNullOrWhiteSpace($ExternalOutputRoot)) {
    $ExternalOutputRoot = $tempRoot
}
$externalOutputRootPath = Resolve-FullPath $ExternalOutputRoot

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $repoRoot "Temp\live-model-endpoint-config-kit\latest"
}

$outputPath = Assert-ManagedOutputPath $OutputDir "OutputDir"
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $outputPath "live-model-endpoint-config-kit-generated-manifest.json"
}

$manifestPath = Assert-PathUnderRoot $ManifestPath $outputPath "ManifestPath"

if (Test-Path $outputPath) {
    Remove-Item -LiteralPath $outputPath -Recurse -Force
}

New-Item -ItemType Directory -Force $outputPath | Out-Null

$expectedBlockingReasons = @(
    "live_endpoint_url_missing",
    "live_model_missing",
    "live_api_key_reference_missing",
    "live_endpoint_smoke_not_run"
)

$blockingReasons = @()
if (-not [bool]$GenerateAcceptedFixture) {
    $blockingReasons = @($expectedBlockingReasons)
}

$configStatus = if ($GenerateAcceptedFixture) { "READY_FOR_LIVE_SMOKE" } else { "PENDING_LIVE_ENDPOINT_CONFIGURATION" }

$config = [ordered]@{
    schemaVersion = "aitestpilot.live_model_endpoint_config.v1"
    status = $configStatus
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    providerPreset = if ($GenerateAcceptedFixture) { "openai-compatible-gateway" } else { "" }
    endpointUrl = if ($GenerateAcceptedFixture) { "https://model-gateway.example/v1/chat/completions" } else { "" }
    model = if ($GenerateAcceptedFixture) { "smoke-test-model" } else { "" }
    requestFormat = if ($GenerateAcceptedFixture) { "OpenAICompatibleChatCompletions" } else { "" }
    apiKeyRequired = $true
    apiKeyEnvironmentVariable = "AI_TESTPILOT_MODEL_API_KEY"
    apiKeySecretReference = if ($GenerateAcceptedFixture) { "ci-secret://AI_TESTPILOT_MODEL_API_KEY" } else { "" }
    endpointEnvironmentVariable = "AITESTPILOT_LIVE_MODEL_ENDPOINT"
    modelEnvironmentVariable = "AITESTPILOT_LIVE_MODEL"
    requestFormatEnvironmentVariable = "AITESTPILOT_LIVE_MODEL_REQUEST_FORMAT"
    authorizationScheme = "Bearer"
    timeoutSeconds = 30
    allowMissingApiKey = $false
    liveSmokeRequiredForProduction = $true
    liveSmokeExecuted = $false
    liveSmokeEvidence = ""
    productionLiveEndpointAccessProven = $false
    secretsSerialized = $false
    configurationComplete = [bool]$GenerateAcceptedFixture
    blockingReasonCount = [int]$blockingReasons.Count
    blockingReasons = @($blockingReasons)
    instructions = @(
        "Fill endpointUrl, model, providerPreset, requestFormat, and a secret reference owned by CI or the host project.",
        "Do not serialize the API key value into this file.",
        "Run Invoke-AITestPilotLiveModelEndpointConfigIntake.ps1 before enabling RequireLiveModelEndpointSmoke.",
        "Run Invoke-AITestPilotReleasePipeline.ps1 -RequireLiveModelEndpointSmoke only after the real secret and endpoint are available."
    )
}

$readme = @'
# AI TestPilot Live Model Endpoint Config Kit

This kit defines the host-project configuration evidence needed before required live model endpoint smoke can be enabled. It does not contain credentials and it does not prove provider access by itself.

## Files

- `live-model-endpoint-config.json`: machine-readable config contract for provider preset, endpoint URL, model, request format, and secret reference.
- `live-model-endpoint-config-schema.md`: acceptance rules for static config intake.
- `live-model-endpoint-smoke-runbook.md`: production CI steps for running the real live smoke after secrets exist.
- `Invoke-LiveModelEndpointSmokeEvidence.ps1`: owner-side helper that runs the live smoke and exports the return bundle.
- `Export-LiveModelEndpointSmokeEvidenceBundle.ps1`: packages the two required live-smoke files only after real provenance is accepted.

## Required validation

```powershell
.\tools\Invoke-AITestPilotLiveModelEndpointConfigIntake.ps1 -ConfigDir "path\to\live-model-config" -RequireCompleteConfiguration
```

Static config intake proves that the endpoint configuration is complete and that no secret value was serialized. It does not replace the real live request:

```powershell
.\tools\Invoke-AITestPilotReleasePipeline.ps1 -RequireLiveModelEndpointSmoke
```

To package returned live-smoke evidence after a real provider request passes:

```powershell
.\Export-LiveModelEndpointSmokeEvidenceBundle.ps1 -EvidenceBundleDir "path\to\release-evidence" -LiveModelEndpointSmokeEvidenceDir "path\to\live-smoke-evidence"
```
'@

$schema = @'
# Live Model Endpoint Config Schema

The file name must be `live-model-endpoint-config.json`.

Required values for accepted static configuration:

- `schemaVersion`: `aitestpilot.live_model_endpoint_config.v1`
- `status`: `READY_FOR_LIVE_SMOKE`
- `providerPreset`: one of `native-json-gateway`, `openai-chat-completions`, `openai-compatible-gateway`, `local-openai-compatible`
- `endpointUrl`: absolute `http` or `https` URL
- `model`: non-empty model identifier
- `requestFormat`: `NativeJson` or `OpenAICompatibleChatCompletions`
- `apiKeyRequired`: `true` unless the selected local gateway intentionally has auth disabled
- `apiKeyEnvironmentVariable`: non-empty when `apiKeyRequired=true`
- `apiKeySecretReference`: non-empty when `apiKeyRequired=true`
- `secretsSerialized`: `false`
- `configurationComplete`: `true`

This static config does not prove provider access. Required live release still needs `live-model-endpoint-smoke-manifest.json` with `status=PASS`.

The smoke manifest and decision trace must also prove:

- `fixtureOnly`: `false`
- `contractFixtureMode`: `false`
- `realProviderAccessProven`: `true`
- `liveSmokeExecuted`: `true`
- `productionLiveEndpointAccessProven`: `true`
- `evidenceProvenance`: `direct_live_http_endpoint_pass`
'@

$runbook = @'
# Live Model Endpoint Smoke Runbook

1. Store the provider API key in CI secrets.
2. Set `AITESTPILOT_LIVE_MODEL_ENDPOINT`, `AI_TESTPILOT_MODEL_API_KEY`, `AITESTPILOT_LIVE_MODEL`, and `AITESTPILOT_LIVE_MODEL_REQUEST_FORMAT`.
3. Run static intake:

```powershell
.\tools\Invoke-AITestPilotLiveModelEndpointConfigIntake.ps1 -ConfigDir "path\to\live-model-config" -RequireCompleteConfiguration
```

4. Run required live smoke:

```powershell
.\tools\Invoke-AITestPilotReleasePipeline.ps1 -RequireLiveModelEndpointSmoke
```

5. Export the owner response bundle:

```powershell
.\Export-LiveModelEndpointSmokeEvidenceBundle.ps1 -EvidenceBundleDir "path\to\release-evidence" -LiveModelEndpointSmokeEvidenceDir "path\to\live-smoke-evidence"
```

6. Keep the config JSON free of raw secret values. Store only environment variable names and CI secret references.
'@

$invokeScriptTemplate = @'
[CmdletBinding()]
param(
    [string]$AITestPilotRepoRoot = "__REPO_ROOT__",
    [string]$EvidenceBundleDir,
    [string]$LiveModelEndpointSmokeEvidenceDir,
    [string]$TraceDir,
    [switch]$AllowMissingApiKey,
    [switch]$DisableFailurePolicyRetry,
    [int]$MaxPolicyRetries = 2,
    [int]$MaxRetryBackoffSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $AITestPilotRepoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($LiveModelEndpointSmokeEvidenceDir)) {
    $LiveModelEndpointSmokeEvidenceDir = Join-Path $EvidenceBundleDir "live-smoke-evidence"
}

if ([string]::IsNullOrWhiteSpace($TraceDir)) {
    $TraceDir = Join-Path $LiveModelEndpointSmokeEvidenceDir "trace"
}

$smokeArgs = @{
    EvidenceBundleDir = $LiveModelEndpointSmokeEvidenceDir
    TraceDir = $TraceDir
    RequireLive = $true
    MaxPolicyRetries = $MaxPolicyRetries
    MaxRetryBackoffSeconds = $MaxRetryBackoffSeconds
}
if ([bool]$AllowMissingApiKey) {
    $smokeArgs["AllowMissingApiKey"] = $true
}
if ([bool]$DisableFailurePolicyRetry) {
    $smokeArgs["DisableFailurePolicyRetry"] = $true
}

& (Join-Path $AITestPilotRepoRoot "tools\Invoke-AITestPilotLiveModelEndpointSmoke.ps1") @smokeArgs

& (Join-Path $PSScriptRoot "Export-LiveModelEndpointSmokeEvidenceBundle.ps1") `
    -AITestPilotRepoRoot $AITestPilotRepoRoot `
    -EvidenceBundleDir $EvidenceBundleDir `
    -LiveModelEndpointSmokeEvidenceDir $LiveModelEndpointSmokeEvidenceDir
'@

$exportScriptTemplate = @'
[CmdletBinding()]
param(
    [string]$AITestPilotRepoRoot = "__REPO_ROOT__",
    [string]$EvidenceBundleDir,
    [string]$LiveModelEndpointSmokeEvidenceDir,
    [string]$OutputDir,
    [string]$ZipPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

    if (-not $fullRoot.EndsWith(([System.IO.Path]::DirectorySeparatorChar).ToString())) {
        $fullRoot = $fullRoot + [System.IO.Path]::DirectorySeparatorChar
    }

    return $fullPath.StartsWith($fullRoot, $comparison)
}

function Assert-PathUnderRoot {
    param(
        [string]$Path,
        [string]$Root,
        [string]$Label,
        [switch]$RequireChild
    )

    $fullPath = Resolve-FullPath $Path
    $fullRoot = Resolve-FullPath $Root
    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    if (-not (Test-PathWithinRoot $fullPath $fullRoot)) {
        throw "$Label must stay under ${fullRoot}: $fullPath"
    }

    if ($RequireChild -and $fullPath.Equals($fullRoot, $comparison)) {
        throw "$Label must target a child path under ${fullRoot}: $fullPath"
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

function Get-JsonValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$DefaultValue = $null
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }

    return $property.Value
}

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    throw "EvidenceBundleDir is required."
}

if ([string]::IsNullOrWhiteSpace($LiveModelEndpointSmokeEvidenceDir)) {
    throw "LiveModelEndpointSmokeEvidenceDir is required."
}

$evidenceBundlePath = Resolve-FullPath $EvidenceBundleDir
$smokeEvidencePath = Resolve-FullPath $LiveModelEndpointSmokeEvidenceDir

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if (-not (Test-Path $smokeEvidencePath)) {
    throw "Live model endpoint smoke evidence directory does not exist: $smokeEvidencePath"
}

$exportRoot = Join-Path $evidenceBundlePath "live-model-endpoint-smoke-evidence-export"
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $exportRoot "live-smoke-evidence"
}
$outputPath = Assert-PathUnderRoot $OutputDir $exportRoot "OutputDir" -RequireChild

if ([string]::IsNullOrWhiteSpace($ZipPath)) {
    $ZipPath = Join-Path (Split-Path $outputPath -Parent) "live-smoke-evidence.zip"
}
$zipFullPath = Assert-PathUnderRoot $ZipPath $exportRoot "ZipPath" -RequireChild

$requiredFiles = @(
    "live-model-endpoint-smoke-manifest.json",
    "live-model-endpoint-decision-trace.json"
)

$missingFiles = @()
foreach ($fileName in $requiredFiles) {
    if (-not (Test-Path (Join-Path $smokeEvidencePath $fileName))) {
        $missingFiles += $fileName
    }
}
if ($missingFiles.Count -gt 0) {
    throw "Live model endpoint smoke evidence export is missing required files: $($missingFiles -join ', ')"
}

$intakeManifestPath = Assert-PathUnderRoot (Join-Path (Split-Path $outputPath -Parent) "live-model-endpoint-smoke-evidence-intake-for-export.json") $exportRoot "Intake manifest path"
New-Item -ItemType Directory -Force (Split-Path $intakeManifestPath -Parent) | Out-Null

& (Join-Path $AITestPilotRepoRoot "tools\Invoke-AITestPilotLiveModelEndpointSmokeEvidenceIntake.ps1") `
    -EvidenceBundleDir $evidenceBundlePath `
    -SmokeEvidenceDir $smokeEvidencePath `
    -ManifestPath $intakeManifestPath `
    -RequireLiveModelEndpointSmoke

$intake = Read-JsonFile $intakeManifestPath "Live model endpoint smoke evidence intake manifest"
$smokeManifest = Read-JsonFile (Join-Path $smokeEvidencePath "live-model-endpoint-smoke-manifest.json") "Live model endpoint smoke manifest"
$traceManifest = Read-JsonFile (Join-Path $smokeEvidencePath "live-model-endpoint-decision-trace.json") "Live model endpoint decision trace"

$readyForExport = $intake.status -eq "PASS" -and
    [bool](Get-JsonValue $intake "smokeEvidenceAccepted" $false) -and
    [bool](Get-JsonValue $intake "realProviderEvidenceAccepted" $false) -and
    [bool](Get-JsonValue $intake "productionLiveEndpointAccessProven" $false) -and
    [bool](Get-JsonValue $intake "realProviderAccessProven" $false) -and
    [bool](Get-JsonValue $intake "liveSmokeExecuted" $false) -and
    -not [bool](Get-JsonValue $intake "contractFixtureMode" $true) -and
    -not [bool](Get-JsonValue $intake "fixtureOnly" $true) -and
    -not [bool](Get-JsonValue $intake "fixtureEvidenceDetected" $true) -and
    [int](Get-JsonValue $intake "blockingReasonCount" 1) -eq 0 -and
    (Get-JsonValue $intake "evidenceProvenance" "") -eq "direct_live_http_endpoint_pass"

if (-not $readyForExport) {
    throw "Live model endpoint smoke export requires accepted real provider provenance with fixtureOnly=false, contractFixtureMode=false, realProviderAccessProven=true, liveSmokeExecuted=true, productionLiveEndpointAccessProven=true, and evidenceProvenance=direct_live_http_endpoint_pass. Current intake: accepted=$($intake.smokeEvidenceAccepted), realProvider=$($intake.realProviderAccessProven), liveSmoke=$($intake.liveSmokeExecuted), productionAccess=$($intake.productionLiveEndpointAccessProven), fixtureOnly=$($intake.fixtureOnly), contractFixtureMode=$($intake.contractFixtureMode), blockers=$($intake.blockingReasonCount)."
}

if (Test-Path $outputPath) {
    Remove-Item -LiteralPath $outputPath -Recurse -Force
}
New-Item -ItemType Directory -Force $outputPath | Out-Null

foreach ($fileName in $requiredFiles) {
    Copy-Item -LiteralPath (Join-Path $smokeEvidencePath $fileName) -Destination (Join-Path $outputPath $fileName) -Force
}

New-Item -ItemType Directory -Force (Split-Path $zipFullPath -Parent) | Out-Null
if (Test-Path $zipFullPath) {
    Remove-Item -LiteralPath $zipFullPath -Force
}
Compress-Archive -LiteralPath $outputPath -DestinationPath $zipFullPath -Force

$manifestPath = Assert-PathUnderRoot (Join-Path (Split-Path $outputPath -Parent) "live-model-endpoint-smoke-evidence-export-manifest.json") $exportRoot "Export manifest path"
$manifest = [ordered]@{
    schemaVersion = "aitestpilot.live_model_endpoint_smoke_evidence_export.v1"
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    liveModelEndpointSmokeEvidenceDir = $smokeEvidencePath
    outputDir = $outputPath
    zipPath = $zipFullPath
    intakeManifestPath = $intakeManifestPath
    smokeEvidenceAccepted = [bool](Get-JsonValue $intake "smokeEvidenceAccepted" $false)
    realProviderEvidenceAccepted = [bool](Get-JsonValue $intake "realProviderEvidenceAccepted" $false)
    productionLiveEndpointAccessProven = [bool](Get-JsonValue $intake "productionLiveEndpointAccessProven" $false)
    realProviderAccessProven = [bool](Get-JsonValue $intake "realProviderAccessProven" $false)
    liveSmokeExecuted = [bool](Get-JsonValue $intake "liveSmokeExecuted" $false)
    fixtureOnly = [bool](Get-JsonValue $intake "fixtureOnly" $false)
    contractFixtureMode = [bool](Get-JsonValue $intake "contractFixtureMode" $false)
    evidenceProvenance = [string](Get-JsonValue $intake "evidenceProvenance" "")
    endpointMode = [string](Get-JsonValue $intake "endpointMode" "")
    clientType = [string](Get-JsonValue $intake "clientType" "")
    requestFormat = [string](Get-JsonValue $intake "requestFormat" "")
    parsedAction = [string](Get-JsonValue $intake "parsedAction" "")
    traceRunId = [string](Get-JsonValue $intake "traceRunId" "")
    smokeManifestStatus = [string](Get-JsonValue $smokeManifest "status" "")
    traceFixtureOnly = [bool](Get-JsonValue $traceManifest "fixtureOnly" $false)
    blockingReasonCount = [int](Get-JsonValue $intake "blockingReasonCount" 0)
    productionOutputBoundary = "real_live_model_endpoint_smoke_evidence_exported"
    requiredFiles = @($requiredFiles)
    exportedFileCount = [int]$requiredFiles.Count
    productionEvidenceExported = $true
    productionEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
}
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

Write-Output "Live model endpoint smoke evidence export: $outputPath"
Write-Output "Live model endpoint smoke evidence export zip: $zipFullPath"
Write-Output "Live model endpoint smoke evidence export manifest: $manifestPath"
Write-Output "PASS AI TestPilot live model endpoint smoke evidence export"
'@

$configPath = Join-Path $outputPath "live-model-endpoint-config.json"
$readmePath = Join-Path $outputPath "README.md"
$schemaPath = Join-Path $outputPath "live-model-endpoint-config-schema.md"
$runbookPath = Join-Path $outputPath "live-model-endpoint-smoke-runbook.md"
$invokeScriptPath = Join-Path $outputPath "Invoke-LiveModelEndpointSmokeEvidence.ps1"
$exportScriptPath = Join-Path $outputPath "Export-LiveModelEndpointSmokeEvidenceBundle.ps1"

$invokeScript = $invokeScriptTemplate.Replace("__REPO_ROOT__", ($repoRoot -replace "\\", "\\"))
$exportScript = $exportScriptTemplate.Replace("__REPO_ROOT__", ($repoRoot -replace "\\", "\\"))

$config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath -Encoding UTF8
$readme | Set-Content -Path $readmePath -Encoding UTF8
$schema | Set-Content -Path $schemaPath -Encoding UTF8
$runbook | Set-Content -Path $runbookPath -Encoding UTF8
$invokeScript | Set-Content -Path $invokeScriptPath -Encoding UTF8
$exportScript | Set-Content -Path $exportScriptPath -Encoding UTF8

$generatedFiles = @(
    "README.md",
    "live-model-endpoint-config.json",
    "live-model-endpoint-config-schema.md",
    "live-model-endpoint-smoke-runbook.md",
    "Invoke-LiveModelEndpointSmokeEvidence.ps1",
    "Export-LiveModelEndpointSmokeEvidenceBundle.ps1",
    "live-model-endpoint-config-kit-generated-manifest.json"
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.live_model_endpoint_config_kit_generated.v1"
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    outputDir = $outputPath
    templateOnly = -not [bool]$GenerateAcceptedFixture
    acceptedFixtureGenerated = [bool]$GenerateAcceptedFixture
    realProviderAccessProven = $false
    liveSmokeExecuted = $false
    secretsSerialized = $false
    configurationAccepted = $false
    readyForLiveEndpointSmoke = $false
    invokeHelperGenerated = $true
    exportHelperGenerated = $true
    exportHelperRequiresRealProviderEvidence = $true
    exportHelperRequiresProductionLiveEndpointAccess = $true
    exportHelperRejectsFixtureEvidence = $true
    exportHelperRejectsSkippedEvidence = $true
    exportHelperRejectsContractFixtureEvidence = $true
    evidenceExportHelperPath = "Export-LiveModelEndpointSmokeEvidenceBundle.ps1"
    evidenceExportHelperCommand = '.\Export-LiveModelEndpointSmokeEvidenceBundle.ps1 -EvidenceBundleDir "path\to\release-evidence" -LiveModelEndpointSmokeEvidenceDir "path\to\live-smoke-evidence"'
    evidenceExportOutputDir = "live-model-endpoint-smoke-evidence-export/live-smoke-evidence"
    evidenceExportZipPath = "live-model-endpoint-smoke-evidence-export/live-smoke-evidence.zip"
    evidenceExportManifestPath = "live-model-endpoint-smoke-evidence-export/live-model-endpoint-smoke-evidence-export-manifest.json"
    configStatus = $configStatus
    expectedBlockingReasonCount = [int]$expectedBlockingReasons.Count
    expectedBlockingReasons = @($expectedBlockingReasons)
    generatedFileCount = [int]$generatedFiles.Count
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles)
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

Write-Output "Live model endpoint config kit: $outputPath"
Write-Output "Live model endpoint config kit manifest: $manifestPath"
Write-Output "PASS AI TestPilot live model endpoint config kit"
