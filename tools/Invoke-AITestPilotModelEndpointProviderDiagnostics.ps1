[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ProviderEnvironmentVariable = "AITESTPILOT_MODEL_PROVIDER",
    [string]$EndpointEnvironmentVariable = "AITESTPILOT_LIVE_MODEL_ENDPOINT",
    [string]$ApiKeyEnvironmentVariable = "AI_TESTPILOT_MODEL_API_KEY",
    [string]$ModelEnvironmentVariable = "AITESTPILOT_LIVE_MODEL",
    [string]$RequestFormatEnvironmentVariable = "AITESTPILOT_LIVE_MODEL_REQUEST_FORMAT"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

function Assert-PathUnderRepo {
    param(
        [string]$Path,
        [string]$Label
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must stay under repo root. Path: $fullPath"
    }

    return $fullPath
}

function Get-EnvironmentValue {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ""
    }

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ($null -eq $value) {
        return ""
    }

    return $value
}

function Test-Contains {
    param(
        [string[]]$Values,
        [string]$Value
    )

    foreach ($item in $Values) {
        if ([string]::Equals($item, $Value, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Find-Preset {
    param(
        [object[]]$Presets,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    foreach ($preset in $Presets) {
        if ([string]::Equals($preset.id, $Value, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $preset
        }

        foreach ($alias in @($preset.aliases)) {
            if ([string]::Equals($alias, $Value, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $preset
            }
        }
    }

    return $null
}

$evidencePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
New-Item -ItemType Directory -Force $evidencePath | Out-Null

$supportedRequestFormats = @(
    "NativeJson",
    "OpenAICompatibleChatCompletions"
)

$presets = @(
    [ordered]@{
        id = "native-json-gateway"
        displayName = "Native AI TestPilot JSON gateway"
        aliases = @("native", "native-json", "custom-native")
        requestFormat = "NativeJson"
        endpointHint = "https://your-model-gateway.example/decide"
        apiKeyRequired = $true
        authorizationScheme = "Bearer"
        liveSmokeCommand = ".\tools\Invoke-AITestPilotLiveModelEndpointSmoke.ps1"
        notes = @("Posts the AI TestPilot decision request contract directly.")
    },
    [ordered]@{
        id = "openai-chat-completions"
        displayName = "OpenAI Chat Completions"
        aliases = @("openai", "chat-completions")
        requestFormat = "OpenAICompatibleChatCompletions"
        endpointHint = "https://api.openai.com/v1/chat/completions"
        apiKeyRequired = $true
        authorizationScheme = "Bearer"
        liveSmokeCommand = ".\tools\Invoke-AITestPilotLiveModelEndpointSmoke.ps1"
        notes = @("Wraps the AI TestPilot decision contract inside messages and response_format.type=json_object.")
    },
    [ordered]@{
        id = "openai-compatible-gateway"
        displayName = "OpenAI-compatible gateway"
        aliases = @("openai-compatible", "compatible", "gateway")
        requestFormat = "OpenAICompatibleChatCompletions"
        endpointHint = "https://your-gateway.example/v1/chat/completions"
        apiKeyRequired = $true
        authorizationScheme = "Bearer"
        liveSmokeCommand = ".\tools\Invoke-AITestPilotLiveModelEndpointSmoke.ps1"
        notes = @("Use for hosted gateways that expose the OpenAI chat-completions request shape.")
    },
    [ordered]@{
        id = "local-openai-compatible"
        displayName = "Local OpenAI-compatible gateway"
        aliases = @("local", "localhost", "ollama-compatible")
        requestFormat = "OpenAICompatibleChatCompletions"
        endpointHint = "http://localhost:11434/v1/chat/completions"
        apiKeyRequired = $false
        authorizationScheme = ""
        liveSmokeCommand = ".\tools\Invoke-AITestPilotLiveModelEndpointSmoke.ps1 -AllowMissingApiKey"
        notes = @("Use for local or lab gateways where authentication is intentionally disabled.")
    }
)

$provider = Get-EnvironmentValue $ProviderEnvironmentVariable
$endpoint = Get-EnvironmentValue $EndpointEnvironmentVariable
$apiKey = Get-EnvironmentValue $ApiKeyEnvironmentVariable
$model = Get-EnvironmentValue $ModelEnvironmentVariable
$requestFormat = Get-EnvironmentValue $RequestFormatEnvironmentVariable

$selectedPreset = Find-Preset $presets $provider
$providerExplicitlyConfigured = -not [string]::IsNullOrWhiteSpace($provider)
$blockingIssues = @()
$warnings = @()

if ($providerExplicitlyConfigured -and $null -eq $selectedPreset) {
    $blockingIssues += "Unknown provider preset in ${ProviderEnvironmentVariable}: $provider"
}

if ($null -eq $selectedPreset) {
    if ([string]::Equals($requestFormat, "OpenAICompatibleChatCompletions", [System.StringComparison]::OrdinalIgnoreCase)) {
        $selectedPreset = Find-Preset $presets "openai-compatible-gateway"
    }
    else {
        $selectedPreset = Find-Preset $presets "native-json-gateway"
    }
}

if ([string]::IsNullOrWhiteSpace($requestFormat)) {
    $requestFormat = $selectedPreset.requestFormat
}
elseif (-not (Test-Contains $supportedRequestFormats $requestFormat)) {
    $blockingIssues += "Unsupported request format in ${RequestFormatEnvironmentVariable}: $requestFormat"
}
elseif (-not [string]::Equals($requestFormat, $selectedPreset.requestFormat, [System.StringComparison]::OrdinalIgnoreCase)) {
    $blockingIssues += "Request format $requestFormat does not match provider preset $($selectedPreset.id), expected $($selectedPreset.requestFormat)."
}

$endpointConfigured = -not [string]::IsNullOrWhiteSpace($endpoint)
$endpointValid = $false
$endpointScheme = ""
$endpointHost = ""
if ($endpointConfigured) {
    $uri = $null
    if ([Uri]::TryCreate($endpoint, [UriKind]::Absolute, [ref]$uri) -and
        ($uri.Scheme -eq "http" -or $uri.Scheme -eq "https")) {
        $endpointValid = $true
        $endpointScheme = $uri.Scheme
        $endpointHost = $uri.Host
    }
    else {
        $blockingIssues += "Endpoint in $EndpointEnvironmentVariable must be an absolute http(s) URL."
    }
}
else {
    $warnings += "Endpoint is not configured; live smoke will be skipped unless $EndpointEnvironmentVariable is set."
}

$apiKeyConfigured = -not [string]::IsNullOrWhiteSpace($apiKey)
if ([bool]$selectedPreset.apiKeyRequired -and -not $apiKeyConfigured) {
    $warnings += "API key is not configured; live smoke will be skipped unless $ApiKeyEnvironmentVariable is set."
}

$modelConfigured = -not [string]::IsNullOrWhiteSpace($model)
if (-not $modelConfigured) {
    $warnings += "Model is not configured; live smoke will be skipped unless $ModelEnvironmentVariable is set."
}

$liveConfigurationReady =
    $endpointConfigured -and
    $endpointValid -and
    $modelConfigured -and
    ($apiKeyConfigured -or -not [bool]$selectedPreset.apiKeyRequired)

$manifestPath = Join-Path $evidencePath "model-endpoint-provider-diagnostics-manifest.json"
$manifest = [ordered]@{
    schemaVersion = "ai-testpilot.model_endpoint_provider_diagnostics.v1"
    status = $(if ($blockingIssues.Count -eq 0) { "PASS" } else { "FAIL" })
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    providerEnvironmentVariable = $ProviderEnvironmentVariable
    providerExplicitlyConfigured = $providerExplicitlyConfigured
    providerValue = $provider
    selectedPreset = $selectedPreset
    providerPresetCount = $presets.Count
    providerPresets = @($presets)
    supportedRequestFormats = @($supportedRequestFormats)
    configuredEnvironment = [ordered]@{
        endpointEnvironmentVariable = $EndpointEnvironmentVariable
        endpointConfigured = $endpointConfigured
        endpointValid = $endpointValid
        endpointScheme = $endpointScheme
        endpointHost = $endpointHost
        apiKeyEnvironmentVariable = $ApiKeyEnvironmentVariable
        apiKeyConfigured = $apiKeyConfigured
        apiKeyRequired = [bool]$selectedPreset.apiKeyRequired
        modelEnvironmentVariable = $ModelEnvironmentVariable
        modelConfigured = $modelConfigured
        requestFormatEnvironmentVariable = $RequestFormatEnvironmentVariable
        requestFormat = $requestFormat
        requestFormatConfigured = -not [string]::IsNullOrWhiteSpace((Get-EnvironmentValue $RequestFormatEnvironmentVariable))
    }
    liveConfigurationReady = $liveConfigurationReady
    missingForLiveSmoke = @(
        if (-not $endpointConfigured) { $EndpointEnvironmentVariable }
        if ([bool]$selectedPreset.apiKeyRequired -and -not $apiKeyConfigured) { $ApiKeyEnvironmentVariable }
        if (-not $modelConfigured) { $ModelEnvironmentVariable }
    )
    blockingIssues = @($blockingIssues)
    warnings = @($warnings)
    secretsSerialized = $false
    files = @("model-endpoint-provider-diagnostics-manifest.json")
}

$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

if ($blockingIssues.Count -gt 0) {
    throw "Model endpoint provider diagnostics failed: $($blockingIssues -join '; ')"
}

Write-Output "Model endpoint provider diagnostics manifest: $manifestPath"
Write-Output "PASS AI TestPilot model endpoint provider diagnostics"
