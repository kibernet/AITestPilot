[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$DiagnosticsManifestPath,
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

if ([string]::IsNullOrWhiteSpace($DiagnosticsManifestPath)) {
    $DiagnosticsManifestPath = Join-Path $EvidenceBundleDir "model-endpoint-provider-diagnostics-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "model-endpoint-provider-retry-policy-manifest.json"
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

function New-Policy {
    param(
        [bool]$Retryable,
        [int]$RecommendedRetryCount,
        [int]$BackoffSeconds,
        [int]$MaxBackoffSeconds,
        [string]$Escalation,
        [string]$AlertRoute,
        [string]$ReleaseGateAction
    )

    return [ordered]@{
        retryable = [bool]$Retryable
        recommendedRetryCount = [int]$RecommendedRetryCount
        backoffSeconds = [int]$BackoffSeconds
        maxBackoffSeconds = [int]$MaxBackoffSeconds
        escalation = $Escalation
        alertRoute = $AlertRoute
        releaseGateAction = $ReleaseGateAction
    }
}

function Get-ProviderPolicy {
    param(
        [string]$ProviderId,
        [string]$FailureCategory
    )

    switch ($FailureCategory) {
        "auth" {
            return New-Policy $false 0 0 0 "secret_or_model_access_owner" "secrets.model_endpoint" "block"
        }
        "rate_limit" {
            if ($ProviderId -eq "local-openai-compatible") {
                return New-Policy $true 1 10 30 "local_gateway_owner" "gateway.local" "block_if_required"
            }

            if ($ProviderId -eq "openai-chat-completions") {
                return New-Policy $true 3 60 180 "provider_quota_owner" "provider.openai.quota" "block_if_required"
            }

            return New-Policy $true 2 45 120 "provider_quota_owner" "provider.gateway.quota" "block_if_required"
        }
        "request_or_endpoint" {
            return New-Policy $false 0 0 0 "endpoint_configuration_owner" "ci.model_endpoint_configuration" "block"
        }
        "provider_unavailable" {
            if ($ProviderId -eq "local-openai-compatible") {
                return New-Policy $true 2 15 60 "local_gateway_owner" "gateway.local.health" "block_if_required"
            }

            if ($ProviderId -eq "openai-chat-completions") {
                return New-Policy $true 2 120 300 "provider_status_owner" "provider.openai.status" "block_if_required"
            }

            return New-Policy $true 2 90 240 "provider_status_owner" "provider.gateway.status" "block_if_required"
        }
        "timeout" {
            if ($ProviderId -eq "local-openai-compatible") {
                return New-Policy $true 1 10 30 "local_gateway_owner" "gateway.local.performance" "block_if_required"
            }

            return New-Policy $true 2 30 120 "gateway_performance_owner" "gateway.performance" "block_if_required"
        }
        "network" {
            if ($ProviderId -eq "local-openai-compatible") {
                return New-Policy $true 2 5 30 "local_gateway_owner" "gateway.local.network" "block_if_required"
            }

            return New-Policy $true 1 30 90 "ci_network_owner" "ci.network" "block_if_required"
        }
        "empty_response" {
            return New-Policy $true 1 15 60 "gateway_owner" "gateway.response_contract" "block"
        }
        "response_contract" {
            return New-Policy $false 0 0 0 "model_prompt_or_gateway_adapter_owner" "model.response_contract" "block"
        }
        "configuration" {
            return New-Policy $false 0 0 0 "ci_configuration_owner" "ci.model_endpoint_configuration" "block"
        }
        default {
            return New-Policy $false 0 0 0 "ai_testpilot_owner" "ai_testpilot.model_endpoint_triage" "block"
        }
    }
}

$evidencePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$diagnosticsPath = Assert-PathUnderRepo $DiagnosticsManifestPath "DiagnosticsManifestPath"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"

if (-not (Test-Path $diagnosticsPath)) {
    throw "Model endpoint provider diagnostics manifest is missing: $diagnosticsPath"
}

$diagnostics = Get-Content -Path $diagnosticsPath -Encoding UTF8 -Raw | ConvertFrom-Json
if ($diagnostics.status -ne "PASS") {
    throw "Model endpoint provider diagnostics must pass before retry policy probe. Status: $($diagnostics.status)"
}

$providerIds = @($diagnostics.providerPresets | ForEach-Object { [string]$_.id })
$requiredProviderIds = @(
    "native-json-gateway",
    "openai-chat-completions",
    "openai-compatible-gateway",
    "local-openai-compatible"
)

$failureCategories = @(
    "auth",
    "rate_limit",
    "request_or_endpoint",
    "provider_unavailable",
    "timeout",
    "network",
    "empty_response",
    "response_contract",
    "configuration",
    "unknown"
)

$missingProviderIds = @($requiredProviderIds | Where-Object { $providerIds -notcontains $_ })
if ($missingProviderIds.Count -gt 0) {
    throw "Provider diagnostics is missing required presets: $($missingProviderIds -join ', ')"
}

$matrix = @()
foreach ($providerId in $requiredProviderIds) {
    foreach ($category in $failureCategories) {
        $policy = Get-ProviderPolicy $providerId $category
        $matrix += [ordered]@{
            providerId = $providerId
            failureCategory = $category
            policy = $policy
        }
    }
}

$providerProfiles = @()
foreach ($providerId in $requiredProviderIds) {
    $entries = @($matrix | Where-Object { $_.providerId -eq $providerId })
    $retryableCategories = @($entries | Where-Object { [bool]$_.policy.retryable } | ForEach-Object { $_.failureCategory })
    $blockingCategories = @($entries | Where-Object { $_.policy.releaseGateAction -eq "block" } | ForEach-Object { $_.failureCategory })
    $alertRoutes = @($entries | ForEach-Object { $_.policy.alertRoute } | Sort-Object -Unique)
    $maxRecommendedRetries = ($entries | ForEach-Object { [int]$_.policy.recommendedRetryCount } | Measure-Object -Maximum).Maximum
    $maxBackoffSeconds = ($entries | ForEach-Object { [int]$_.policy.maxBackoffSeconds } | Measure-Object -Maximum).Maximum

    $providerProfiles += [ordered]@{
        providerId = $providerId
        failureCategoryCount = [int]$entries.Count
        retryableCategoryCount = [int]$retryableCategories.Count
        blockingCategoryCount = [int]$blockingCategories.Count
        alertRouteCount = [int]$alertRoutes.Count
        maxRecommendedRetries = [int]$maxRecommendedRetries
        maxBackoffSeconds = [int]$maxBackoffSeconds
        retryableCategories = @($retryableCategories)
        blockingCategories = @($blockingCategories)
        alertRoutes = @($alertRoutes)
    }
}

$retryableEntryCount = @($matrix | Where-Object { [bool]$_.policy.retryable }).Count
$nonRetryableEntryCount = @($matrix | Where-Object { -not [bool]$_.policy.retryable }).Count
$alertRoutes = @($matrix | ForEach-Object { $_.policy.alertRoute } | Sort-Object -Unique)
$escalations = @($matrix | ForEach-Object { $_.policy.escalation } | Sort-Object -Unique)
$providersWithProfiles = @($providerProfiles | Where-Object {
    [int]$_.failureCategoryCount -eq $failureCategories.Count -and
    [int]$_.retryableCategoryCount -gt 0 -and
    [int]$_.blockingCategoryCount -gt 0 -and
    [int]$_.alertRouteCount -gt 0
})

$ciRecommendedArgs = [ordered]@{
    defaultMaxPolicyRetries = 2
    defaultMaxRetryBackoffSeconds = 5
    productionMaxPolicyRetries = 3
    productionMaxRetryBackoffSeconds = 60
    command = ".\tools\Invoke-AITestPilotReleasePipeline.ps1 -RequireLiveModelEndpointSmoke -LiveModelEndpointMaxPolicyRetries 3 -LiveModelEndpointMaxRetryBackoffSeconds 60"
}

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.model_endpoint_provider_retry_policy.v1"
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    diagnosticsManifest = "model-endpoint-provider-diagnostics-manifest.json"
    providerPolicyCount = [int]$requiredProviderIds.Count
    providerProfilesComplete = [bool]($providersWithProfiles.Count -eq $requiredProviderIds.Count)
    failureCategoryCount = [int]$failureCategories.Count
    policyMatrixEntryCount = [int]$matrix.Count
    expectedPolicyMatrixEntryCount = [int]($requiredProviderIds.Count * $failureCategories.Count)
    retryableEntryCount = [int]$retryableEntryCount
    nonRetryableEntryCount = [int]$nonRetryableEntryCount
    alertRouteCount = [int]$alertRoutes.Count
    escalationPathCount = [int]$escalations.Count
    providerIds = @($requiredProviderIds)
    failureCategories = @($failureCategories)
    providerProfiles = @($providerProfiles)
    policyMatrix = @($matrix)
    ciRecommendedArgs = $ciRecommendedArgs
    secretsSerialized = $false
    files = @("model-endpoint-provider-retry-policy-manifest.json")
}

New-Item -ItemType Directory -Force (Split-Path $manifestFullPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestFullPath -Encoding UTF8

Write-Output "Model endpoint provider retry policy manifest: $manifestFullPath"
Write-Output "PASS AI TestPilot model endpoint provider retry policy probe"
