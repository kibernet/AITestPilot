[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ExternalBundleDir,
    [string]$ProbeBundleDir,
    [string]$ManifestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ExternalBundleDir)) {
    $ExternalBundleDir = Join-Path $tempRoot "AITestPilot\live-model-endpoint-accepted-smoke-probe"
}

if ([string]::IsNullOrWhiteSpace($ProbeBundleDir)) {
    $ProbeBundleDir = Join-Path $repoRoot "Temp\release-evidence\live-model-endpoint-smoke-evidence-contract-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "live-model-endpoint-smoke-evidence-contract-probe-manifest.json"
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
$externalBundlePath = Assert-PathUnderTemp $ExternalBundleDir "ExternalBundleDir"
$probeBundlePath = Assert-PathUnderRepo $ProbeBundleDir "ProbeBundleDir"
$manifestPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if ($probeBundlePath -eq $evidenceBundlePath) {
    throw "ProbeBundleDir must be separate from EvidenceBundleDir."
}

if (Test-Path $externalBundlePath) {
    Remove-Item -LiteralPath $externalBundlePath -Recurse -Force
}

if (Test-Path $probeBundlePath) {
    Remove-Item -LiteralPath $probeBundlePath -Recurse -Force
}

New-Item -ItemType Directory -Force $externalBundlePath | Out-Null
New-Item -ItemType Directory -Force $probeBundlePath | Out-Null

$sourceSmokeManifestPath = Join-Path $externalBundlePath "live-model-endpoint-smoke-manifest.json"
$sourceTracePath = Join-Path $externalBundlePath "live-model-endpoint-decision-trace.json"

$requestJson = @{
    schemaVersion = "ai-testpilot.decision_request.v1"
    goal = "accepted live smoke fixture"
    actionSchemaVersion = "ai-testpilot.action.v1"
    allowedActions = @("click", "wait", "finish")
} | ConvertTo-Json -Depth 8 -Compress

$responseJson = @{
    action = "finish"
    target = "LiveModel.AcceptedSmoke"
    reason = "accepted fixture response"
} | ConvertTo-Json -Depth 8 -Compress

$trace = [ordered]@{
    schemaVersion = "ai-testpilot.decision_trace.v1"
    status = "PASS"
    runId = "LIVE-MODEL-ENDPOINT-SMOKE"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    requestJson = $requestJson
    responseJson = $responseJson
    parsedAction = [ordered]@{
        action = "finish"
        target = "LiveModel.AcceptedSmoke"
    }
    fixtureOnly = $true
    realProviderAccessProven = $false
}

$smoke = [ordered]@{
    schemaVersion = "ai-testpilot.live_model_endpoint_smoke.v1"
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    endpointMode = "live_http_endpoint"
    required = $true
    endpointConfigured = $true
    apiKeyConfigured = $true
    apiKeyRequired = $true
    modelConfigured = $true
    endpointEnvironmentVariable = "AITESTPILOT_LIVE_MODEL_ENDPOINT"
    apiKeyEnvironmentVariable = "AI_TESTPILOT_MODEL_API_KEY"
    modelEnvironmentVariable = "AITESTPILOT_LIVE_MODEL"
    requestFormatEnvironmentVariable = "AITESTPILOT_LIVE_MODEL_REQUEST_FORMAT"
    requestFormat = "NativeJson"
    clientType = "ModelEndpointDecisionClient"
    actionSchemaVersion = "ai-testpilot.action.v1"
    requestContainsActionSchema = $true
    requestContainsAllowedActions = $true
    responseValidated = $true
    traceStatus = "PASS"
    attemptCount = 1
    parsedAction = [ordered]@{
        action = "finish"
        target = "LiveModel.AcceptedSmoke"
    }
    fixtureOnly = $true
    fixtureBoundary = "accepted_live_smoke_contract_only"
    realProviderAccessProven = $false
    files = @(
        "live-model-endpoint-smoke-manifest.json",
        "live-model-endpoint-decision-trace.json"
    )
}

$smoke | ConvertTo-Json -Depth 10 | Set-Content -Path $sourceSmokeManifestPath -Encoding UTF8
$trace | ConvertTo-Json -Depth 10 | Set-Content -Path $sourceTracePath -Encoding UTF8

$acceptedIntakeManifestPath = Join-Path $probeBundlePath "live-model-endpoint-smoke-evidence-intake-manifest.json"
& (Join-Path $PSScriptRoot "Invoke-AITestPilotLiveModelEndpointSmokeEvidenceIntake.ps1") `
    -EvidenceBundleDir $probeBundlePath `
    -ManifestPath $acceptedIntakeManifestPath `
    -SmokeEvidenceDir $externalBundlePath `
    -RequireLiveModelEndpointSmoke `
    -PromoteToCanonical

$acceptedIntake = Read-JsonFile $acceptedIntakeManifestPath "Accepted live model endpoint smoke evidence intake manifest"
$acceptedSmoke = Read-JsonFile (Join-Path $probeBundlePath "live-model-endpoint-smoke-manifest.json") "Promoted accepted live smoke manifest"
$acceptedTrace = Read-JsonFile (Join-Path $probeBundlePath "live-model-endpoint-decision-trace.json") "Promoted accepted live smoke trace"

$externalBundleUnderRepo = $externalBundlePath.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)
$acceptedFixtureGenerated = (Test-Path $sourceSmokeManifestPath) -and (Test-Path $sourceTracePath)
$acceptedFixtureTraceContractPassed = $acceptedTrace.status -eq "PASS" -and
    $acceptedTrace.runId -eq "LIVE-MODEL-ENDPOINT-SMOKE" -and
    -not [string]::IsNullOrWhiteSpace($acceptedTrace.requestJson) -and
    -not [string]::IsNullOrWhiteSpace($acceptedTrace.responseJson)

$acceptedFixtureSmokeContractPassed = $acceptedSmoke.status -eq "PASS" -and
    $acceptedSmoke.endpointMode -eq "live_http_endpoint" -and
    $acceptedSmoke.clientType -eq "ModelEndpointDecisionClient" -and
    [bool]$acceptedSmoke.endpointConfigured -and
    [bool]$acceptedSmoke.modelConfigured -and
    [bool]$acceptedSmoke.apiKeyConfigured -and
    [bool]$acceptedSmoke.requestContainsActionSchema -and
    [bool]$acceptedSmoke.requestContainsAllowedActions -and
    [bool]$acceptedSmoke.responseValidated -and
    $acceptedSmoke.traceStatus -eq "PASS" -and
    [int]$acceptedSmoke.attemptCount -eq 1

$acceptedFixtureIntakePassed = $acceptedIntake.status -eq "PASS" -and
    [bool]$acceptedIntake.requireLiveModelEndpointSmoke -and
    [bool]$acceptedIntake.smokeEvidenceRead -and
    $acceptedIntake.smokeStatus -eq "PASS" -and
    [bool]$acceptedIntake.smokeEvidenceAccepted -and
    [bool]$acceptedIntake.productionLiveEndpointAccessProven -and
    [bool]$acceptedIntake.canonicalSmokePromoted -and
    [bool]$acceptedIntake.canonicalTracePromoted -and
    [int]$acceptedIntake.blockingReasonCount -eq 0

$checks = @()
Add-ProbeCheck "accepted_fixture_generated" $acceptedFixtureGenerated "Accepted live smoke fixture must include smoke manifest and trace files."
Add-ProbeCheck "accepted_fixture_intake_passed" $acceptedFixtureIntakePassed "Live smoke evidence intake must accept and promote the isolated PASS fixture."
Add-ProbeCheck "accepted_fixture_smoke_contract" $acceptedFixtureSmokeContractPassed "Accepted fixture smoke manifest must satisfy the live smoke contract."
Add-ProbeCheck "accepted_fixture_trace_contract" $acceptedFixtureTraceContractPassed "Accepted fixture trace must satisfy the live smoke trace contract."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$copiedIntakeManifestName = "live-model-endpoint-smoke-evidence-contract-accepted-intake-manifest.json"
$copiedSmokeManifestName = "live-model-endpoint-smoke-evidence-contract-accepted-smoke-manifest.json"
$copiedTraceName = "live-model-endpoint-smoke-evidence-contract-accepted-decision-trace.json"

Copy-Item -LiteralPath $acceptedIntakeManifestPath -Destination (Join-Path $evidenceBundlePath $copiedIntakeManifestName) -Force
Copy-Item -LiteralPath (Join-Path $probeBundlePath "live-model-endpoint-smoke-manifest.json") -Destination (Join-Path $evidenceBundlePath $copiedSmokeManifestName) -Force
Copy-Item -LiteralPath (Join-Path $probeBundlePath "live-model-endpoint-decision-trace.json") -Destination (Join-Path $evidenceBundlePath $copiedTraceName) -Force

$files = @(
    "live-model-endpoint-smoke-evidence-contract-probe-manifest.json",
    $copiedIntakeManifestName,
    $copiedSmokeManifestName,
    $copiedTraceName
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.live_model_endpoint_smoke_evidence_contract_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    externalBundleDir = $externalBundlePath
    probeBundleDir = $probeBundlePath
    externalBundleUnderRepo = [bool]$externalBundleUnderRepo
    acceptedFixtureGenerated = [bool]$acceptedFixtureGenerated
    acceptedFixtureIntakePassed = [bool]$acceptedFixtureIntakePassed
    acceptedFixtureSmokeEvidenceAccepted = [bool]$acceptedIntake.smokeEvidenceAccepted
    acceptedFixtureProductionLiveEndpointAccessProven = [bool]$acceptedIntake.productionLiveEndpointAccessProven
    acceptedFixtureCanonicalSmokePromoted = [bool]$acceptedIntake.canonicalSmokePromoted
    acceptedFixtureCanonicalTracePromoted = [bool]$acceptedIntake.canonicalTracePromoted
    acceptedFixtureSmokeContractPassed = [bool]$acceptedFixtureSmokeContractPassed
    acceptedFixtureTraceContractPassed = [bool]$acceptedFixtureTraceContractPassed
    acceptedFixtureEndpointMode = $acceptedIntake.endpointMode
    acceptedFixtureClientType = $acceptedIntake.clientType
    acceptedFixtureRequestFormat = $acceptedIntake.requestFormat
    acceptedFixtureParsedAction = $acceptedIntake.parsedAction
    acceptedFixtureBlockingReasonCount = [int]$acceptedIntake.blockingReasonCount
    releasePipelineUsesFixture = $false
    realProductionLiveEndpointAccessProven = $false
    realLiveSmokeExecuted = $false
    productionOutputBoundary = "accepted_fixture_contract_only"
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
    files = @($files)
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Live model endpoint smoke evidence contract probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Live model endpoint smoke evidence contract probe manifest: $manifestPath"
Write-Output "PASS AI TestPilot live model endpoint smoke evidence contract probe"
