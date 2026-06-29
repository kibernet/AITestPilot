[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ManifestPath,
    [switch]$ExpectBlocked
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-driver-evidence-intake-manifest.json"
}

$requiredInputFiles = @(
    "production-replay-integration-checklist.json",
    "repair-retest-manifest.json",
    "repair-driver-failure-manifest.json",
    "replay-profile-import-manifest.json"
)

$expectedSampleBlockingReasons = @(
    "production_replay_integration_not_bound",
    "required_hooks_not_all_bound",
    "unresolved_required_hooks",
    "sample_game_replay_driver_used",
    "external_production_driver_not_selected"
)

function Test-ContainsAll {
    param(
        [object[]]$Actual,
        [string[]]$Required
    )

    foreach ($item in $Required) {
        if ($Actual -notcontains $item) {
            return $false
        }
    }

    return $true
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

$evidenceBundlePath = [System.IO.Path]::GetFullPath($EvidenceBundleDir)
$manifestPath = [System.IO.Path]::GetFullPath($ManifestPath)

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

$missingFiles = @()
foreach ($fileName in $requiredInputFiles) {
    $path = Join-Path $evidenceBundlePath $fileName
    if (-not (Test-Path $path)) {
        $missingFiles += $fileName
    }
}

if ($missingFiles.Count -gt 0) {
    throw "Production driver evidence bundle is missing required files: $($missingFiles -join ', ')"
}

$readinessScript = Join-Path $PSScriptRoot "Invoke-AITestPilotProductionReplayDriverReadiness.ps1"
$readinessManifestFileName = "production-driver-evidence-intake-readiness-manifest.json"
$readinessManifestPath = Join-Path $evidenceBundlePath $readinessManifestFileName
$readinessCommandFailed = $false
$readinessFailureMessage = ""

try {
    & $readinessScript `
        -EvidenceBundleDir $evidenceBundlePath `
        -ManifestPath $readinessManifestPath `
        -RequireProductionBound
}
catch {
    $readinessCommandFailed = $true
    $readinessFailureMessage = $_.Exception.Message
}

if (-not (Test-Path $readinessManifestPath)) {
    throw "Production driver readiness manifest was not produced: $readinessManifestPath"
}

$readiness = Read-JsonFile $readinessManifestPath "Production driver readiness manifest"
$productionChecklist = Read-JsonFile (Join-Path $evidenceBundlePath "production-replay-integration-checklist.json") "Production replay integration checklist"
$repairRetest = Read-JsonFile (Join-Path $evidenceBundlePath "repair-retest-manifest.json") "Repair retest manifest"
$driverFailureProbe = Read-JsonFile (Join-Path $evidenceBundlePath "repair-driver-failure-manifest.json") "Driver failure probe manifest"
$replayProfileImport = Read-JsonFile (Join-Path $evidenceBundlePath "replay-profile-import-manifest.json") "Replay profile import manifest"

$readyForProductionDriverRelease = [bool]$readiness.readyForProductionDriverRelease
$blockingReasons = @($readiness.blockingReasons)
$expectedSampleBlockingReasonsFound = Test-ContainsAll $blockingReasons $expectedSampleBlockingReasons
$intakeAccepted = -not $readinessCommandFailed -and
    $readiness.status -eq "PASS" -and
    $readyForProductionDriverRelease -and
    $readiness.integrationChecklistStatus -eq "BOUND" -and
    [bool]$readiness.realProjectBound -and
    [int]$readiness.unresolvedRequiredHookCount -eq 0 -and
    [bool]$readiness.productionChecklistAllRequiredHooksBound -and
    [bool]$readiness.productionChecklistRequiredBindingMetadataComplete -and
    -not [bool]$readiness.sampleGameReplayDriverUsed -and
    [bool]$readiness.externalProductionDriverSelected -and
    [bool]$readiness.retestPassed -and
    [bool]$readiness.driverFailureProbePassed -and
    [bool]$readiness.replayProfileImportPassed -and
    [int]$readiness.blockingReasonCount -eq 0

$expectedBlockedPassed = [bool]$ExpectBlocked -and
    $readinessCommandFailed -and
    -not $readyForProductionDriverRelease -and
    $expectedSampleBlockingReasonsFound -and
    $readiness.integrationChecklistStatus -eq "TEMPLATE_READY" -and
    -not [bool]$readiness.realProjectBound -and
    [bool]$readiness.sampleGameReplayDriverUsed -and
    -not [bool]$readiness.externalProductionDriverSelected

$status = "PASS"
if ($ExpectBlocked) {
    if (-not $expectedBlockedPassed) {
        $status = "FAIL"
    }
}
elseif (-not $intakeAccepted) {
    $status = "FAIL"
}

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_driver_evidence_intake.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    expectedBlocked = [bool]$ExpectBlocked
    requireProductionBound = $true
    readinessCommandFailed = [bool]$readinessCommandFailed
    readinessFailureMessage = $readinessFailureMessage
    intakeAccepted = [bool]$intakeAccepted
    expectedBlockedPassed = [bool]$expectedBlockedPassed
    expectedSampleBlockingReasonsFound = [bool]$expectedSampleBlockingReasonsFound
    readyForProductionDriverRelease = [bool]$readyForProductionDriverRelease
    integrationChecklistStatus = $readiness.integrationChecklistStatus
    realProjectBound = [bool]$readiness.realProjectBound
    requiredHookCount = [int]$readiness.requiredHookCount
    boundRequiredHookCount = [int]$readiness.boundRequiredHookCount
    unresolvedRequiredHookCount = [int]$readiness.unresolvedRequiredHookCount
    productionChecklistAllRequiredHooksBound = [bool]$readiness.productionChecklistAllRequiredHooksBound
    productionChecklistRequiredBindingMetadataComplete = [bool]$readiness.productionChecklistRequiredBindingMetadataComplete
    gameReplayDriverId = $readiness.gameReplayDriverId
    gameReplayDriverSource = $readiness.gameReplayDriverSource
    sampleGameReplayDriverUsed = [bool]$readiness.sampleGameReplayDriverUsed
    externalProductionDriverSelected = [bool]$readiness.externalProductionDriverSelected
    retestPassed = [bool]$readiness.retestPassed
    driverFailureProbePassed = [bool]$readiness.driverFailureProbePassed
    replayProfileImportPassed = [bool]$readiness.replayProfileImportPassed
    blockingReasonCount = [int]$readiness.blockingReasonCount
    blockingReasons = @($blockingReasons)
    checklistDriverTypeName = $productionChecklist.driverTypeName
    retestDriverSource = $repairRetest.gameReplayDriverSource
    failureProbeStatus = $driverFailureProbe.status
    replayProfileImportStatus = $replayProfileImport.status
    requiredFiles = @($requiredInputFiles)
    files = @(
        $readinessManifestFileName
    )
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

if ($status -ne "PASS") {
    if ($ExpectBlocked) {
        throw "Production driver evidence intake did not block the sample/unbound evidence as expected."
    }

    throw "Production driver evidence intake rejected the bundle. Manifest: $manifestPath"
}

Write-Output "Production driver evidence intake manifest: $manifestPath"
if ($ExpectBlocked) {
    Write-Output "PASS AI TestPilot production driver evidence intake blocked as expected"
}
else {
    Write-Output "PASS AI TestPilot production driver evidence intake"
}
