[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$SmokeEvidenceDir,
    [string]$ManifestPath,
    [switch]$RequireLiveModelEndpointSmoke,
    [switch]$PromoteToCanonical
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "live-model-endpoint-smoke-evidence-intake-manifest.json"
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

function Copy-IfExists {
    param(
        [string]$Source,
        [string]$Destination
    )

    if (Test-Path $Source) {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
        return $true
    }

    return $false
}

$evidencePath = Resolve-FullPath $EvidenceBundleDir
$manifestPath = Resolve-FullPath $ManifestPath

if (-not (Test-Path $evidencePath)) {
    New-Item -ItemType Directory -Force $evidencePath | Out-Null
}

$smokeEvidenceProvided = -not [string]::IsNullOrWhiteSpace($SmokeEvidenceDir)
$smokeEvidencePath = ""
$sourceSmokeManifestPath = ""
$sourceTracePath = ""
$smokeManifest = $null
$traceManifest = $null
$externalSmokeCopied = $false
$externalTraceCopied = $false
$canonicalSmokePromoted = $false
$canonicalTracePromoted = $false
$smokeStatus = "MISSING"

if ($smokeEvidenceProvided) {
    $smokeEvidencePath = Resolve-FullPath $SmokeEvidenceDir
    $sourceSmokeManifestPath = Join-Path $smokeEvidencePath "live-model-endpoint-smoke-manifest.json"
    $sourceTracePath = Join-Path $smokeEvidencePath "live-model-endpoint-decision-trace.json"
    $smokeManifest = Read-OptionalJsonFile $sourceSmokeManifestPath
    $traceManifest = Read-OptionalJsonFile $sourceTracePath
}

$blockingReasons = @()
if (-not $smokeEvidenceProvided -or $null -eq $smokeManifest) {
    Add-BlockingReason "live_model_endpoint_smoke_evidence_missing"
}

$schemaValid = (Get-JsonValue $smokeManifest "schemaVersion" "") -eq "ai-testpilot.live_model_endpoint_smoke.v1"
$smokeStatus = [string](Get-JsonValue $smokeManifest "status" "MISSING")
$apiKeyRequired = [bool](Get-JsonValue $smokeManifest "apiKeyRequired" $true)
$apiKeyConfigured = [bool](Get-JsonValue $smokeManifest "apiKeyConfigured" $false)
$apiKeyAccepted = $apiKeyConfigured -or -not $apiKeyRequired
$endpointConfigured = [bool](Get-JsonValue $smokeManifest "endpointConfigured" $false)
$modelConfigured = [bool](Get-JsonValue $smokeManifest "modelConfigured" $false)
$responseValidated = [bool](Get-JsonValue $smokeManifest "responseValidated" $false)
$requestContainsActionSchema = [bool](Get-JsonValue $smokeManifest "requestContainsActionSchema" $false)
$requestContainsAllowedActions = [bool](Get-JsonValue $smokeManifest "requestContainsAllowedActions" $false)
$traceStatus = [string](Get-JsonValue $smokeManifest "traceStatus" "")
$attemptCount = [int](Get-JsonValue $smokeManifest "attemptCount" 0)
$requestFormat = [string](Get-JsonValue $smokeManifest "requestFormat" "")
$actionSchemaVersion = [string](Get-JsonValue $smokeManifest "actionSchemaVersion" "")
$endpointMode = [string](Get-JsonValue $smokeManifest "endpointMode" "")
$clientType = [string](Get-JsonValue $smokeManifest "clientType" "")
$parsedAction = Get-JsonValue $smokeManifest "parsedAction" $null
$parsedActionName = [string](Get-JsonValue $parsedAction "action" "")
$traceRunId = [string](Get-JsonValue $traceManifest "runId" "")
$traceRequestJson = [string](Get-JsonValue $traceManifest "requestJson" "")
$traceResponseJson = [string](Get-JsonValue $traceManifest "responseJson" "")
$traceFilePresent = $null -ne $traceManifest

if (-not $schemaValid) {
    Add-BlockingReason "live_model_endpoint_smoke_schema_invalid"
}

if ($smokeStatus -ne "PASS") {
    Add-BlockingReason "live_model_endpoint_smoke_not_passed"
}

if (-not $endpointConfigured) {
    Add-BlockingReason "live_model_endpoint_not_configured"
}

if (-not $modelConfigured) {
    Add-BlockingReason "live_model_endpoint_model_missing"
}

if (-not $apiKeyAccepted) {
    Add-BlockingReason "live_model_endpoint_api_key_missing"
}

if (-not $traceFilePresent) {
    Add-BlockingReason "live_model_endpoint_trace_missing"
}

if ($smokeStatus -eq "PASS" -and
    $endpointMode -ne "live_http_endpoint") {
    Add-BlockingReason "live_model_endpoint_not_live_http"
}

if ($smokeStatus -eq "PASS" -and
    $clientType -ne "ModelEndpointDecisionClient") {
    Add-BlockingReason "live_model_endpoint_client_invalid"
}

if ($smokeStatus -eq "PASS" -and
    $actionSchemaVersion -ne "ai-testpilot.action.v1") {
    Add-BlockingReason "live_model_endpoint_action_schema_missing"
}

if ($smokeStatus -eq "PASS" -and
    (-not $requestContainsActionSchema -or -not $requestContainsAllowedActions)) {
    Add-BlockingReason "live_model_endpoint_request_contract_missing"
}

if ($smokeStatus -eq "PASS" -and -not $responseValidated) {
    Add-BlockingReason "live_model_endpoint_response_not_validated"
}

if ($smokeStatus -eq "PASS" -and $traceStatus -ne "PASS") {
    Add-BlockingReason "live_model_endpoint_trace_status_not_pass"
}

if ($smokeStatus -eq "PASS" -and $attemptCount -lt 1) {
    Add-BlockingReason "live_model_endpoint_attempt_missing"
}

if ($smokeStatus -eq "PASS" -and [string]::IsNullOrWhiteSpace($requestFormat)) {
    Add-BlockingReason "live_model_endpoint_request_format_missing"
}

if ($smokeStatus -eq "PASS" -and [string]::IsNullOrWhiteSpace($parsedActionName)) {
    Add-BlockingReason "live_model_endpoint_action_missing"
}

if ($smokeStatus -eq "PASS" -and
    ($traceRunId -ne "LIVE-MODEL-ENDPOINT-SMOKE" -or
        [string]::IsNullOrWhiteSpace($traceRequestJson) -or
        [string]::IsNullOrWhiteSpace($traceResponseJson))) {
    Add-BlockingReason "live_model_endpoint_trace_contract_invalid"
}

$smokeEvidenceAccepted = $schemaValid -and
    $smokeStatus -eq "PASS" -and
    $endpointMode -eq "live_http_endpoint" -and
    $clientType -eq "ModelEndpointDecisionClient" -and
    $endpointConfigured -and
    $modelConfigured -and
    $apiKeyAccepted -and
    $attemptCount -ge 1 -and
    -not [string]::IsNullOrWhiteSpace($requestFormat) -and
    $actionSchemaVersion -eq "ai-testpilot.action.v1" -and
    $requestContainsActionSchema -and
    $requestContainsAllowedActions -and
    $responseValidated -and
    $traceStatus -eq "PASS" -and
    -not [string]::IsNullOrWhiteSpace($parsedActionName) -and
    $traceFilePresent -and
    $traceRunId -eq "LIVE-MODEL-ENDPOINT-SMOKE" -and
    -not [string]::IsNullOrWhiteSpace($traceRequestJson) -and
    -not [string]::IsNullOrWhiteSpace($traceResponseJson)

$externalSmokeManifestName = "live-model-endpoint-external-smoke-manifest.json"
$externalTraceName = "live-model-endpoint-external-smoke-decision-trace.json"
$canonicalSmokeName = "live-model-endpoint-smoke-manifest.json"
$canonicalTraceName = "live-model-endpoint-decision-trace.json"
$files = @("live-model-endpoint-smoke-evidence-intake-manifest.json")

if ($smokeEvidenceProvided -and $null -ne $smokeManifest) {
    $externalSmokeCopied = Copy-IfExists $sourceSmokeManifestPath (Join-Path $evidencePath $externalSmokeManifestName)
    if ($externalSmokeCopied) {
        $files += $externalSmokeManifestName
    }

    $externalTraceCopied = Copy-IfExists $sourceTracePath (Join-Path $evidencePath $externalTraceName)
    if ($externalTraceCopied) {
        $files += $externalTraceName
    }
}

if ([bool]$PromoteToCanonical -and $smokeEvidenceAccepted) {
    $canonicalSmokePromoted = Copy-IfExists $sourceSmokeManifestPath (Join-Path $evidencePath $canonicalSmokeName)
    $canonicalTracePromoted = Copy-IfExists $sourceTracePath (Join-Path $evidencePath $canonicalTraceName)
}

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.live_model_endpoint_smoke_evidence_intake.v1"
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    requireLiveModelEndpointSmoke = [bool]$RequireLiveModelEndpointSmoke
    smokeEvidenceProvided = [bool]$smokeEvidenceProvided
    smokeEvidenceDir = $smokeEvidencePath
    sourceSmokeManifestPath = $sourceSmokeManifestPath
    sourceTracePath = $sourceTracePath
    smokeEvidenceRead = [bool]($null -ne $smokeManifest)
    smokeStatus = $smokeStatus
    smokeEvidenceAccepted = [bool]$smokeEvidenceAccepted
    productionLiveEndpointAccessProven = [bool]$smokeEvidenceAccepted
    endpointMode = $endpointMode
    clientType = $clientType
    endpointConfigured = [bool]$endpointConfigured
    apiKeyRequired = [bool]$apiKeyRequired
    apiKeyConfigured = [bool]$apiKeyConfigured
    apiKeyAccepted = [bool]$apiKeyAccepted
    modelConfigured = [bool]$modelConfigured
    requestFormat = $requestFormat
    actionSchemaVersion = $actionSchemaVersion
    requestContainsActionSchema = [bool]$requestContainsActionSchema
    requestContainsAllowedActions = [bool]$requestContainsAllowedActions
    responseValidated = [bool]$responseValidated
    traceStatus = $traceStatus
    traceFilePresent = [bool]$traceFilePresent
    traceRunId = $traceRunId
    parsedAction = $parsedActionName
    attemptCount = [int]$attemptCount
    externalSmokeCopied = [bool]$externalSmokeCopied
    externalTraceCopied = [bool]$externalTraceCopied
    promoteToCanonical = [bool]$PromoteToCanonical
    canonicalSmokePromoted = [bool]$canonicalSmokePromoted
    canonicalTracePromoted = [bool]$canonicalTracePromoted
    blockingReasonCount = [int]$blockingReasons.Count
    blockingReasons = @($blockingReasons)
    files = @($files)
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

Write-Output "Live model endpoint smoke evidence intake manifest: $manifestPath"

if ([bool]$RequireLiveModelEndpointSmoke -and -not $smokeEvidenceAccepted) {
    throw "Live model endpoint smoke evidence is not accepted: $($blockingReasons -join ', ')"
}

Write-Output "PASS AI TestPilot live model endpoint smoke evidence intake"
