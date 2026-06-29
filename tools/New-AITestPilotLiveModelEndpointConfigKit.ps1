[CmdletBinding()]
param(
    [string]$OutputDir,
    [string]$ManifestPath,
    [switch]$GenerateAcceptedFixture
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $repoRoot "Temp\live-model-endpoint-config-kit\latest"
}

$outputPath = [System.IO.Path]::GetFullPath($OutputDir)
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $outputPath "live-model-endpoint-config-kit-generated-manifest.json"
}

$manifestPath = [System.IO.Path]::GetFullPath($ManifestPath)

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

## Required validation

```powershell
.\tools\Invoke-AITestPilotLiveModelEndpointConfigIntake.ps1 -ConfigDir "path\to\live-model-config" -RequireCompleteConfiguration
```

Static config intake proves that the endpoint configuration is complete and that no secret value was serialized. It does not replace the real live request:

```powershell
.\tools\Invoke-AITestPilotReleasePipeline.ps1 -RequireLiveModelEndpointSmoke
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

5. Keep the config JSON free of raw secret values. Store only environment variable names and CI secret references.
'@

$configPath = Join-Path $outputPath "live-model-endpoint-config.json"
$readmePath = Join-Path $outputPath "README.md"
$schemaPath = Join-Path $outputPath "live-model-endpoint-config-schema.md"
$runbookPath = Join-Path $outputPath "live-model-endpoint-smoke-runbook.md"

$config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath -Encoding UTF8
$readme | Set-Content -Path $readmePath -Encoding UTF8
$schema | Set-Content -Path $schemaPath -Encoding UTF8
$runbook | Set-Content -Path $runbookPath -Encoding UTF8

$generatedFiles = @(
    "README.md",
    "live-model-endpoint-config.json",
    "live-model-endpoint-config-schema.md",
    "live-model-endpoint-smoke-runbook.md",
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
