[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ConfigDir,
    [string]$ManifestPath,
    [switch]$RequireCompleteConfiguration
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "live-model-endpoint-config-intake-manifest.json"
}

function Resolve-FullPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Read-OptionalJsonFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) {
        return $null
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

function Add-BlockingReason {
    param([string]$Reason)

    if ($script:blockingReasons -notcontains $Reason) {
        $script:blockingReasons += $Reason
    }
}

function Test-ContainsCaseInsensitive {
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

function Test-EndpointUrl {
    param([string]$Endpoint)

    if ([string]::IsNullOrWhiteSpace($Endpoint)) {
        return $false
    }

    $uri = $null
    return [Uri]::TryCreate($Endpoint, [UriKind]::Absolute, [ref]$uri) -and
        ($uri.Scheme -eq "http" -or $uri.Scheme -eq "https")
}

$evidencePath = Resolve-FullPath $EvidenceBundleDir
$manifestPath = Resolve-FullPath $ManifestPath

if (-not (Test-Path $evidencePath)) {
    New-Item -ItemType Directory -Force $evidencePath | Out-Null
}

$configProvided = -not [string]::IsNullOrWhiteSpace($ConfigDir)
$configDirPath = ""
$configPath = ""
$config = $null
$configCopied = $false
$copiedConfigName = "live-model-endpoint-config.json"

if ($configProvided) {
    $configDirPath = Resolve-FullPath $ConfigDir
    $configPath = Join-Path $configDirPath "live-model-endpoint-config.json"
    $config = Read-OptionalJsonFile $configPath
}

$supportedProviderPresets = @(
    "native-json-gateway",
    "openai-chat-completions",
    "openai-compatible-gateway",
    "local-openai-compatible"
)
$supportedRequestFormats = @(
    "NativeJson",
    "OpenAICompatibleChatCompletions"
)

$blockingReasons = @()
if (-not $configProvided -or $null -eq $config) {
    Add-BlockingReason "live_endpoint_config_missing"
}

$schemaValid = $false
$statusReady = $false
$providerPreset = ""
$providerPresetSupported = $false
$endpointUrl = ""
$endpointConfigured = $false
$endpointValid = $false
$model = ""
$modelConfigured = $false
$requestFormat = ""
$requestFormatValid = $false
$apiKeyRequired = $true
$apiKeyEnvironmentVariable = ""
$apiKeySecretReference = ""
$apiKeyReferenceProvided = $false
$secretsSerialized = $true
$configurationComplete = $false
$liveSmokeRequiredForProduction = $true
$liveSmokeExecuted = $false
$productionLiveEndpointAccessProven = $false

if ($null -ne $config) {
    $schemaValid = (Get-JsonValue $config "schemaVersion" "") -eq "aitestpilot.live_model_endpoint_config.v1"
    $statusReady = (Get-JsonValue $config "status" "") -eq "READY_FOR_LIVE_SMOKE"
    $providerPreset = [string](Get-JsonValue $config "providerPreset" "")
    $providerPresetSupported = Test-ContainsCaseInsensitive $supportedProviderPresets $providerPreset
    $endpointUrl = [string](Get-JsonValue $config "endpointUrl" "")
    $endpointConfigured = -not [string]::IsNullOrWhiteSpace($endpointUrl)
    $endpointValid = Test-EndpointUrl $endpointUrl
    $model = [string](Get-JsonValue $config "model" "")
    $modelConfigured = -not [string]::IsNullOrWhiteSpace($model)
    $requestFormat = [string](Get-JsonValue $config "requestFormat" "")
    $requestFormatValid = Test-ContainsCaseInsensitive $supportedRequestFormats $requestFormat
    $apiKeyRequired = [bool](Get-JsonValue $config "apiKeyRequired" $true)
    $apiKeyEnvironmentVariable = [string](Get-JsonValue $config "apiKeyEnvironmentVariable" "")
    $apiKeySecretReference = [string](Get-JsonValue $config "apiKeySecretReference" "")
    $apiKeyReferenceProvided = -not [bool]$apiKeyRequired -or
        (-not [string]::IsNullOrWhiteSpace($apiKeyEnvironmentVariable) -and
            -not [string]::IsNullOrWhiteSpace($apiKeySecretReference))
    $secretsSerialized = [bool](Get-JsonValue $config "secretsSerialized" $true)
    $configurationComplete = [bool](Get-JsonValue $config "configurationComplete" $false)
    $liveSmokeRequiredForProduction = [bool](Get-JsonValue $config "liveSmokeRequiredForProduction" $true)
    $liveSmokeExecuted = [bool](Get-JsonValue $config "liveSmokeExecuted" $false)
    $productionLiveEndpointAccessProven = [bool](Get-JsonValue $config "productionLiveEndpointAccessProven" $false)

    Copy-Item -LiteralPath $configPath -Destination (Join-Path $evidencePath $copiedConfigName) -Force
    $configCopied = $true
}

if (-not $schemaValid) {
    Add-BlockingReason "live_endpoint_config_schema_invalid"
}

if (-not $statusReady) {
    Add-BlockingReason "live_endpoint_config_not_ready"
}

if (-not $providerPresetSupported) {
    Add-BlockingReason "live_provider_preset_missing_or_unsupported"
}

if (-not $endpointConfigured) {
    Add-BlockingReason "live_endpoint_url_missing"
}
elseif (-not $endpointValid) {
    Add-BlockingReason "live_endpoint_url_invalid"
}

if (-not $modelConfigured) {
    Add-BlockingReason "live_model_missing"
}

if (-not $requestFormatValid) {
    Add-BlockingReason "live_request_format_missing_or_invalid"
}

if (-not $apiKeyReferenceProvided) {
    Add-BlockingReason "live_api_key_reference_missing"
}

if ($secretsSerialized) {
    Add-BlockingReason "live_endpoint_secret_value_serialized"
}

if (-not $configurationComplete) {
    Add-BlockingReason "live_endpoint_configuration_incomplete"
}

if (-not $liveSmokeRequiredForProduction) {
    Add-BlockingReason "live_endpoint_smoke_not_marked_required"
}

if (-not $liveSmokeExecuted) {
    Add-BlockingReason "live_endpoint_smoke_not_run"
}

$readyForLiveEndpointSmoke = $schemaValid -and
    $statusReady -and
    $providerPresetSupported -and
    $endpointConfigured -and
    $endpointValid -and
    $modelConfigured -and
    $requestFormatValid -and
    $apiKeyReferenceProvided -and
    -not $secretsSerialized -and
    $configurationComplete -and
    $liveSmokeRequiredForProduction

$configurationAccepted = $readyForLiveEndpointSmoke

$files = @("live-model-endpoint-config-intake-manifest.json")
if ($configCopied) {
    $files += $copiedConfigName
}

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.live_model_endpoint_config_intake.v1"
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    requireCompleteConfiguration = [bool]$RequireCompleteConfiguration
    configProvided = [bool]$configProvided
    configRead = [bool]($null -ne $config)
    configCopied = [bool]$configCopied
    configPath = $configPath
    configurationAccepted = [bool]$configurationAccepted
    readyForLiveEndpointSmoke = [bool]$readyForLiveEndpointSmoke
    productionLiveEndpointAccessProven = [bool]$productionLiveEndpointAccessProven
    liveSmokeRequiredForProduction = [bool]$liveSmokeRequiredForProduction
    liveSmokeExecuted = [bool]$liveSmokeExecuted
    providerPreset = $providerPreset
    providerPresetSupported = [bool]$providerPresetSupported
    endpointConfigured = [bool]$endpointConfigured
    endpointValid = [bool]$endpointValid
    modelConfigured = [bool]$modelConfigured
    requestFormat = $requestFormat
    requestFormatValid = [bool]$requestFormatValid
    apiKeyRequired = [bool]$apiKeyRequired
    apiKeyEnvironmentVariable = $apiKeyEnvironmentVariable
    apiKeySecretReferenceProvided = -not [string]::IsNullOrWhiteSpace($apiKeySecretReference)
    apiKeyReferenceProvided = [bool]$apiKeyReferenceProvided
    secretsSerialized = [bool]$secretsSerialized
    configurationComplete = [bool]$configurationComplete
    blockingReasonCount = [int]$blockingReasons.Count
    blockingReasons = @($blockingReasons)
    files = @($files)
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

Write-Output "Live model endpoint config intake manifest: $manifestPath"

if ($RequireCompleteConfiguration -and -not $readyForLiveEndpointSmoke) {
    throw "Live model endpoint config is not ready: $($blockingReasons -join ', ')"
}

Write-Output "PASS AI TestPilot live model endpoint config intake"
