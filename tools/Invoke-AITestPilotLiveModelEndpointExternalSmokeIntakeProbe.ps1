[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ExternalBundleDir,
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
    $ExternalBundleDir = Join-Path $tempRoot "AITestPilot\live-model-endpoint-external-smoke-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "live-model-endpoint-external-smoke-intake-probe-manifest.json"
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
$manifestPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if (Test-Path $externalBundlePath) {
    Remove-Item -LiteralPath $externalBundlePath -Recurse -Force
}

New-Item -ItemType Directory -Force $externalBundlePath | Out-Null

$externalSmokeManifestPath = Join-Path $externalBundlePath "live-model-endpoint-smoke-manifest.json"
$skippedSmokeManifest = [ordered]@{
    schemaVersion = "ai-testpilot.live_model_endpoint_smoke.v1"
    status = "SKIPPED"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    endpointMode = "live_http_endpoint"
    required = $false
    endpointConfigured = $false
    apiKeyConfigured = $false
    apiKeyRequired = $true
    modelConfigured = $false
    endpointEnvironmentVariable = "AITESTPILOT_LIVE_MODEL_ENDPOINT"
    apiKeyEnvironmentVariable = "AI_TESTPILOT_MODEL_API_KEY"
    modelEnvironmentVariable = "AITESTPILOT_LIVE_MODEL"
    requestFormatEnvironmentVariable = "AITESTPILOT_LIVE_MODEL_REQUEST_FORMAT"
    requestFormat = "NativeJson"
    skippedReason = "External fixture missing environment variables: AITESTPILOT_LIVE_MODEL_ENDPOINT, AI_TESTPILOT_MODEL_API_KEY, AITESTPILOT_LIVE_MODEL"
    files = @()
}
$skippedSmokeManifest | ConvertTo-Json -Depth 8 | Set-Content -Path $externalSmokeManifestPath -Encoding UTF8

$externalIntakeBundlePath = Join-Path $externalBundlePath "intake-bundle"
New-Item -ItemType Directory -Force $externalIntakeBundlePath | Out-Null
$externalIntakeManifestPath = Join-Path $externalIntakeBundlePath "live-model-endpoint-smoke-evidence-intake-manifest.json"

$intakeCommandFailed = $false
$intakeError = ""
try {
    & (Join-Path $PSScriptRoot "Invoke-AITestPilotLiveModelEndpointSmokeEvidenceIntake.ps1") `
        -EvidenceBundleDir $externalIntakeBundlePath `
        -ManifestPath $externalIntakeManifestPath `
        -SmokeEvidenceDir $externalBundlePath `
        -RequireLiveModelEndpointSmoke
}
catch {
    $intakeCommandFailed = $true
    $intakeError = $_.Exception.Message
}

$externalSmokeManifest = Read-JsonFile $externalSmokeManifestPath "External live model endpoint smoke manifest"
$externalIntakeManifest = Read-JsonFile $externalIntakeManifestPath "External live model endpoint smoke evidence intake manifest"

$externalBundleUnderRepo = $externalBundlePath.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)
$blockingReasons = @($externalIntakeManifest.blockingReasons)
$expectedSkippedBlocked = [bool]$intakeCommandFailed -and
    $externalSmokeManifest.status -eq "SKIPPED" -and
    $externalIntakeManifest.status -eq "PASS" -and
    [bool]$externalIntakeManifest.requireLiveModelEndpointSmoke -and
    [bool]$externalIntakeManifest.smokeEvidenceRead -and
    $externalIntakeManifest.smokeStatus -eq "SKIPPED" -and
    -not [bool]$externalIntakeManifest.smokeEvidenceAccepted -and
    -not [bool]$externalIntakeManifest.productionLiveEndpointAccessProven -and
    ($blockingReasons -contains "live_model_endpoint_smoke_not_passed") -and
    ($blockingReasons -contains "live_model_endpoint_trace_missing")

$checks = @()
Add-ProbeCheck "external_bundle_outside_repo" (-not [bool]$externalBundleUnderRepo) "External live smoke evidence bundle must live outside the repository."
Add-ProbeCheck "external_smoke_manifest_read" ([bool]$externalIntakeManifest.smokeEvidenceRead) "Intake must read the external live-model-endpoint-smoke-manifest.json file."
Add-ProbeCheck "skipped_smoke_blocked_in_hard_mode" $expectedSkippedBlocked "RequireLiveModelEndpointSmoke must reject skipped external smoke evidence."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$copiedIntakeManifestName = "live-model-endpoint-external-smoke-intake-manifest.json"
$copiedSkippedSmokeName = "live-model-endpoint-external-smoke-skipped-manifest.json"
Copy-Item -LiteralPath $externalIntakeManifestPath -Destination (Join-Path $evidenceBundlePath $copiedIntakeManifestName) -Force
Copy-Item -LiteralPath $externalSmokeManifestPath -Destination (Join-Path $evidenceBundlePath $copiedSkippedSmokeName) -Force

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.live_model_endpoint_external_smoke_intake_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    sourceEvidenceBundleDir = $evidenceBundlePath
    externalBundleDir = $externalBundlePath
    externalBundleUnderRepo = [bool]$externalBundleUnderRepo
    expectedBlocked = $true
    expectedBlockedPassed = [bool]$expectedSkippedBlocked
    intakeCommandFailed = [bool]$intakeCommandFailed
    intakeError = $intakeError
    externalSmokeRead = [bool]$externalIntakeManifest.smokeEvidenceRead
    externalSmokeStatus = $externalSmokeManifest.status
    smokeEvidenceAccepted = [bool]$externalIntakeManifest.smokeEvidenceAccepted
    productionLiveEndpointAccessProven = [bool]$externalIntakeManifest.productionLiveEndpointAccessProven
    requireLiveModelEndpointSmoke = [bool]$externalIntakeManifest.requireLiveModelEndpointSmoke
    blockingReasonCount = [int]$externalIntakeManifest.blockingReasonCount
    blockingReasons = @($blockingReasons)
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
    files = @(
        $copiedIntakeManifestName,
        $copiedSkippedSmokeName
    )
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Live model endpoint external smoke intake probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Live model endpoint external smoke intake probe manifest: $manifestPath"
Write-Output "PASS AI TestPilot live model endpoint external smoke intake probe"
