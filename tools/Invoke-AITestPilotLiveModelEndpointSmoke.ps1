[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$TraceDir,
    [string]$EndpointEnvironmentVariable = "AITESTPILOT_LIVE_MODEL_ENDPOINT",
    [string]$ApiKeyEnvironmentVariable = "AI_TESTPILOT_MODEL_API_KEY",
    [string]$ModelEnvironmentVariable = "AITESTPILOT_LIVE_MODEL",
    [string]$RequestFormatEnvironmentVariable = "AITESTPILOT_LIVE_MODEL_REQUEST_FORMAT",
    [string]$AuthorizationScheme = "Bearer",
    [int]$TimeoutSeconds = 30,
    [switch]$RequireLive,
    [switch]$AllowMissingApiKey,
    [switch]$DisableFailurePolicyRetry,
    [int]$MaxPolicyRetries = 2,
    [int]$MaxRetryBackoffSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ($MaxPolicyRetries -lt 0) {
    throw "MaxPolicyRetries must be zero or greater."
}

if ($MaxRetryBackoffSeconds -lt 0) {
    throw "MaxRetryBackoffSeconds must be zero or greater."
}

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($TraceDir)) {
    $TraceDir = Join-Path $repoRoot "Temp\live-model-endpoint-smoke"
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

function Add-LiveManifestMetadata {
    param(
        [object]$Manifest,
        [object[]]$Attempts
    )

    $Manifest | Add-Member -NotePropertyName "apiKeyRequired" -NotePropertyValue (-not [bool]$AllowMissingApiKey) -Force
    $Manifest | Add-Member -NotePropertyName "apiKeyEnvironmentVariable" -NotePropertyValue $ApiKeyEnvironmentVariable -Force
    $Manifest | Add-Member -NotePropertyName "endpointEnvironmentVariable" -NotePropertyValue $EndpointEnvironmentVariable -Force
    $Manifest | Add-Member -NotePropertyName "modelEnvironmentVariable" -NotePropertyValue $ModelEnvironmentVariable -Force
    $Manifest | Add-Member -NotePropertyName "requestFormatEnvironmentVariable" -NotePropertyValue $RequestFormatEnvironmentVariable -Force
    $Manifest | Add-Member -NotePropertyName "retryPolicyExecuted" -NotePropertyValue (-not [bool]$DisableFailurePolicyRetry) -Force
    $Manifest | Add-Member -NotePropertyName "maxPolicyRetries" -NotePropertyValue $MaxPolicyRetries -Force
    $Manifest | Add-Member -NotePropertyName "maxRetryBackoffSeconds" -NotePropertyValue $MaxRetryBackoffSeconds -Force
    $Manifest | Add-Member -NotePropertyName "attemptCount" -NotePropertyValue @($Attempts).Count -Force
    $Manifest | Add-Member -NotePropertyName "attempts" -NotePropertyValue @($Attempts) -Force
}

function Read-LiveManifest {
    if (-not (Test-Path $manifestPath)) {
        return $null
    }

    return Get-Content -Raw $manifestPath | ConvertFrom-Json
}

$evidencePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$tracePath = Assert-PathUnderRepo $TraceDir "TraceDir"

New-Item -ItemType Directory -Force $evidencePath | Out-Null

if (Test-Path $tracePath) {
    Remove-Item -LiteralPath $tracePath -Recurse -Force
}

New-Item -ItemType Directory -Force $tracePath | Out-Null

$endpoint = Get-EnvironmentValue $EndpointEnvironmentVariable
$apiKey = Get-EnvironmentValue $ApiKeyEnvironmentVariable
$model = Get-EnvironmentValue $ModelEnvironmentVariable
$requestFormat = Get-EnvironmentValue $RequestFormatEnvironmentVariable
if ([string]::IsNullOrWhiteSpace($requestFormat)) {
    $requestFormat = "NativeJson"
}

$manifestPath = Join-Path $evidencePath "live-model-endpoint-smoke-manifest.json"
$missing = @()
if ([string]::IsNullOrWhiteSpace($endpoint)) {
    $missing += $EndpointEnvironmentVariable
}

if ([string]::IsNullOrWhiteSpace($apiKey) -and -not [bool]$AllowMissingApiKey) {
    $missing += $ApiKeyEnvironmentVariable
}

if ([string]::IsNullOrWhiteSpace($model)) {
    $missing += $ModelEnvironmentVariable
}

if ($missing.Count -gt 0) {
    $manifest = [ordered]@{
        schemaVersion = "ai-testpilot.live_model_endpoint_smoke.v1"
        status = "SKIPPED"
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
        endpointMode = "live_http_endpoint"
        required = [bool]$RequireLive
        endpointConfigured = -not [string]::IsNullOrWhiteSpace($endpoint)
        apiKeyConfigured = -not [string]::IsNullOrWhiteSpace($apiKey)
        apiKeyRequired = -not [bool]$AllowMissingApiKey
        modelConfigured = -not [string]::IsNullOrWhiteSpace($model)
        endpointEnvironmentVariable = $EndpointEnvironmentVariable
        apiKeyEnvironmentVariable = $ApiKeyEnvironmentVariable
        modelEnvironmentVariable = $ModelEnvironmentVariable
        requestFormatEnvironmentVariable = $RequestFormatEnvironmentVariable
        requestFormat = $requestFormat
        skippedReason = "Missing environment variables: " + ($missing -join ", ")
        files = @()
    }

    $manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $manifestPath -Encoding UTF8

    if ($RequireLive) {
        throw "Live model endpoint smoke is required but configuration is missing: $($missing -join ', ')"
    }

    Write-Output "Live model endpoint smoke manifest: $manifestPath"
    Write-Output "SKIP AI TestPilot live model endpoint smoke: $($missing -join ', ')"
    exit 0
}

$probeProject = Join-Path $repoRoot "tools\Kibernet.AITestPilot.ModelEndpointProbe\Kibernet.AITestPilot.ModelEndpointProbe.csproj"

$attempts = @()
$attemptNumber = 0
$finalExitCode = 0

while ($true) {
    $attemptNumber++
    $attemptTracePath = Join-Path $tracePath ("attempt-" + $attemptNumber)
    if (Test-Path $attemptTracePath) {
        Remove-Item -LiteralPath $attemptTracePath -Recurse -Force
    }

    New-Item -ItemType Directory -Force $attemptTracePath | Out-Null

    dotnet run `
        --project $probeProject `
        -- `
        --mode live `
        --evidence-bundle-dir $evidencePath `
        --trace-dir $attemptTracePath `
        --endpoint $endpoint `
        --api-key-env $ApiKeyEnvironmentVariable `
        --authorization-scheme $AuthorizationScheme `
        --model $model `
        --request-format $requestFormat `
        --timeout-seconds $TimeoutSeconds

    $finalExitCode = $LASTEXITCODE
    $liveManifest = Read-LiveManifest
    $failureCategory = ""
    $retryable = $false
    $recommendedRetryCount = 0
    $backoffSeconds = 0
    $escalation = ""
    $releaseGateAction = ""
    $status = "NO_MANIFEST"

    if ($null -ne $liveManifest) {
        $status = $liveManifest.status
        if ($null -ne $liveManifest.PSObject.Properties["failureCategory"]) {
            $failureCategory = $liveManifest.failureCategory
        }

        if ($null -ne $liveManifest.failurePolicy) {
            $retryable = [bool]$liveManifest.failurePolicy.retryable
            $recommendedRetryCount = [int]$liveManifest.failurePolicy.recommendedRetryCount
            $backoffSeconds = [int]$liveManifest.failurePolicy.backoffSeconds
            $escalation = $liveManifest.failurePolicy.escalation
            $releaseGateAction = $liveManifest.failurePolicy.releaseGateAction
        }
    }

    $completedRetries = $attemptNumber - 1
    $effectiveRetryCount = [Math]::Min($recommendedRetryCount, $MaxPolicyRetries)
    $willRetry =
        $finalExitCode -ne 0 -and
        -not [bool]$DisableFailurePolicyRetry -and
        $retryable -and
        $completedRetries -lt $effectiveRetryCount

    $attempts += [ordered]@{
        attempt = $attemptNumber
        exitCode = $finalExitCode
        status = $status
        failureCategory = $failureCategory
        retryable = $retryable
        recommendedRetryCount = $recommendedRetryCount
        backoffSeconds = $backoffSeconds
        escalation = $escalation
        releaseGateAction = $releaseGateAction
        willRetry = $willRetry
    }

    if ($finalExitCode -eq 0 -or -not $willRetry) {
        break
    }

    $sleepSeconds = [Math]::Min($backoffSeconds, $MaxRetryBackoffSeconds)
    if ($sleepSeconds -gt 0) {
        Start-Sleep -Seconds $sleepSeconds
    }
}

$liveManifest = Read-LiveManifest
if ($null -ne $liveManifest) {
    Add-LiveManifestMetadata $liveManifest $attempts
    $liveManifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestPath -Encoding UTF8
}

if ($finalExitCode -ne 0) {
    throw "Live model endpoint smoke failed with exit code $finalExitCode"
}
