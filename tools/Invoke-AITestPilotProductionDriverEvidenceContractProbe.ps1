[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ProbeBundleDir,
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

if ([string]::IsNullOrWhiteSpace($ProbeBundleDir)) {
    $ProbeBundleDir = Join-Path $repoRoot "Temp\release-evidence\production-driver-evidence-contract-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-driver-evidence-contract-probe-manifest.json"
}

$requiredHandlerKeys = @(
    "game.prepare_account",
    "game.login",
    "game.enter_scene",
    "game.claim_reward",
    "game.play_fishing"
)

$requiredInputFiles = @(
    "production-replay-integration-checklist.json",
    "repair-retest-manifest.json",
    "repair-driver-failure-manifest.json",
    "replay-profile-import-manifest.json"
)

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

function Write-JsonFile {
    param(
        [object]$Value,
        [string]$Path
    )

    $Value | ConvertTo-Json -Depth 20 | Set-Content -Path $Path -Encoding UTF8
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
$probeBundlePath = Assert-PathUnderRepo $ProbeBundleDir "ProbeBundleDir"
$manifestPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if (Test-Path $probeBundlePath) {
    Remove-Item -LiteralPath $probeBundlePath -Recurse -Force
}

$acceptedFixtureBundlePath = Join-Path $probeBundlePath "accepted-fixture-bundle"
New-Item -ItemType Directory -Force $acceptedFixtureBundlePath | Out-Null

$missingFiles = @()
foreach ($fileName in $requiredInputFiles) {
    $sourcePath = Join-Path $evidenceBundlePath $fileName
    if (-not (Test-Path $sourcePath)) {
        $missingFiles += $fileName
        continue
    }

    Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $acceptedFixtureBundlePath $fileName) -Force
}

if ($missingFiles.Count -gt 0) {
    throw "Source evidence bundle is missing required production driver files for contract probe: $($missingFiles -join ', ')"
}

$acceptedDriverId = "accepted.production_replay_driver"
$acceptedDriverSource = "type:Your.Game.Tests.AcceptedProductionReplayDriver"
$acceptedDriverDisplayName = "Accepted Production Replay Driver Fixture"

$checklistPath = Join-Path $acceptedFixtureBundlePath "production-replay-integration-checklist.json"
$repairRetestPath = Join-Path $acceptedFixtureBundlePath "repair-retest-manifest.json"
$driverFailurePath = Join-Path $acceptedFixtureBundlePath "repair-driver-failure-manifest.json"

$checklist = Read-JsonFile $checklistPath "Accepted fixture production replay checklist"
$checklist.status = "BOUND"
$checklist.driverTypeName = "Your.Game.Tests.AcceptedProductionReplayDriver"
$checklist.driverId = $acceptedDriverId
$checklist.realProjectBound = $true
$checklist.requiredHookCount = [int]$requiredHandlerKeys.Count
$checklist.boundRequiredHookCount = [int]$requiredHandlerKeys.Count
$checklist.unresolvedRequiredHookCount = 0
$checklist.requiredHandlerKeysPresent = $true
$checklist.allRequiredHooksBound = $true
$checklist.requiredBindingMetadataComplete = $true
$checklist.supportedHandlerKeys = @($requiredHandlerKeys)
$checklist.unresolvedHookTargets = @()
foreach ($binding in @($checklist.hookBindings)) {
    if ($binding.required) {
        $binding.boundToRealGameApi = $true
    }
}
$checklist.notes = @(
    "Accepted fixture for production driver evidence intake contract only.",
    "This fixture is isolated from release pipeline production evidence and does not claim a real host project ran."
)
Write-JsonFile $checklist $checklistPath

$repairRetest = Read-JsonFile $repairRetestPath "Accepted fixture repair retest manifest"
$repairRetest.gameReplayDriverId = $acceptedDriverId
$repairRetest.gameReplayDriverSource = $acceptedDriverSource
if ($null -ne $repairRetest.gameReplayDriverDescriptor) {
    $repairRetest.gameReplayDriverDescriptor.driverId = $acceptedDriverId
    $repairRetest.gameReplayDriverDescriptor.displayName = $acceptedDriverDisplayName
    $repairRetest.gameReplayDriverDescriptor.source = $acceptedDriverSource
    $repairRetest.gameReplayDriverDescriptor.supportedHandlerKeys = @($requiredHandlerKeys)
    $repairRetest.gameReplayDriverDescriptor.notes = @(
        "Accepted fixture descriptor for production driver evidence intake contract."
    )
}
Write-JsonFile $repairRetest $repairRetestPath

$driverFailureProbe = Read-JsonFile $driverFailurePath "Accepted fixture driver failure probe manifest"
$driverFailureProbe.gameReplayDriverType = "Your.Game.Tests.AcceptedProductionReplayDriverFailureProbe"
$driverFailureProbe.expectedDriverId = "accepted.production_replay_driver_failure_probe"
Write-JsonFile $driverFailureProbe $driverFailurePath

$acceptedIntakeManifestPath = Join-Path $acceptedFixtureBundlePath "production-driver-evidence-intake-manifest.json"
& (Join-Path $PSScriptRoot "Invoke-AITestPilotProductionDriverEvidenceIntake.ps1") `
    -EvidenceBundleDir $acceptedFixtureBundlePath `
    -ManifestPath $acceptedIntakeManifestPath

$acceptedReadinessManifestPath = Join-Path $acceptedFixtureBundlePath "production-driver-evidence-intake-readiness-manifest.json"
$acceptedIntake = Read-JsonFile $acceptedIntakeManifestPath "Accepted fixture production driver evidence intake manifest"
$acceptedReadiness = Read-JsonFile $acceptedReadinessManifestPath "Accepted fixture production driver readiness manifest"
$acceptedChecklist = Read-JsonFile $checklistPath "Accepted fixture production replay checklist"
$acceptedRetest = Read-JsonFile $repairRetestPath "Accepted fixture repair retest manifest"

$acceptedFixtureIntakePassed = $acceptedIntake.status -eq "PASS" -and
    [bool]$acceptedIntake.intakeAccepted -and
    -not [bool]$acceptedIntake.expectedBlocked -and
    -not [bool]$acceptedIntake.readinessCommandFailed -and
    [bool]$acceptedIntake.readyForProductionDriverRelease -and
    $acceptedIntake.integrationChecklistStatus -eq "BOUND" -and
    [bool]$acceptedIntake.realProjectBound -and
    [int]$acceptedIntake.unresolvedRequiredHookCount -eq 0 -and
    [bool]$acceptedIntake.productionChecklistAllRequiredHooksBound -and
    [bool]$acceptedIntake.productionChecklistRequiredBindingMetadataComplete -and
    -not [bool]$acceptedIntake.sampleGameReplayDriverUsed -and
    [bool]$acceptedIntake.externalProductionDriverSelected -and
    [bool]$acceptedIntake.retestPassed -and
    [bool]$acceptedIntake.driverFailureProbePassed -and
    [bool]$acceptedIntake.replayProfileImportPassed -and
    [int]$acceptedIntake.blockingReasonCount -eq 0

$acceptedFixtureReadinessPassed = $acceptedReadiness.status -eq "PASS" -and
    [bool]$acceptedReadiness.readyForProductionDriverRelease -and
    [bool]$acceptedReadiness.requireProductionBound -and
    $acceptedReadiness.integrationChecklistStatus -eq "BOUND" -and
    [bool]$acceptedReadiness.realProjectBound -and
    [int]$acceptedReadiness.boundRequiredHookCount -eq [int]$acceptedReadiness.requiredHookCount -and
    [int]$acceptedReadiness.unresolvedRequiredHookCount -eq 0 -and
    -not [bool]$acceptedReadiness.sampleGameReplayDriverUsed -and
    [bool]$acceptedReadiness.externalProductionDriverSelected -and
    [int]$acceptedReadiness.blockingReasonCount -eq 0

$fixtureBoundaryPreserved = $acceptedRetest.gameReplayDriverId -eq $acceptedDriverId -and
    $acceptedRetest.gameReplayDriverSource -eq $acceptedDriverSource -and
    $acceptedChecklist.driverId -eq $acceptedDriverId -and
    [bool]$acceptedChecklist.realProjectBound -and
    -not ($acceptedRetest.gameReplayDriverSource -match "SampleGameActionReplayDriver")

$checks = @()
Add-ProbeCheck "accepted_fixture_generated" $fixtureBoundaryPreserved "Accepted fixture must be production-bound shaped and use a non-sample type driver."
Add-ProbeCheck "accepted_fixture_intake_passed" $acceptedFixtureIntakePassed "Accepted fixture must pass production driver evidence intake."
Add-ProbeCheck "accepted_fixture_readiness_passed" $acceptedFixtureReadinessPassed "Accepted fixture readiness must pass with RequireProductionBound."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$copiedIntakeManifestName = "production-driver-evidence-contract-accepted-intake-manifest.json"
$copiedReadinessManifestName = "production-driver-evidence-contract-accepted-readiness-manifest.json"
$copiedChecklistName = "production-driver-evidence-contract-accepted-checklist.json"
$copiedRetestName = "production-driver-evidence-contract-accepted-retest-manifest.json"

Copy-Item -LiteralPath $acceptedIntakeManifestPath -Destination (Join-Path $evidenceBundlePath $copiedIntakeManifestName) -Force
Copy-Item -LiteralPath $acceptedReadinessManifestPath -Destination (Join-Path $evidenceBundlePath $copiedReadinessManifestName) -Force
Copy-Item -LiteralPath $checklistPath -Destination (Join-Path $evidenceBundlePath $copiedChecklistName) -Force
Copy-Item -LiteralPath $repairRetestPath -Destination (Join-Path $evidenceBundlePath $copiedRetestName) -Force

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_driver_evidence_contract_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    probeBundleDir = $probeBundlePath
    acceptedFixtureBundleDir = $acceptedFixtureBundlePath
    acceptedFixtureGenerated = [bool]$fixtureBoundaryPreserved
    acceptedFixtureIntakePassed = [bool]$acceptedFixtureIntakePassed
    acceptedFixtureReadinessPassed = [bool]$acceptedFixtureReadinessPassed
    acceptedFixtureReadyForProductionDriverRelease = [bool]$acceptedReadiness.readyForProductionDriverRelease
    acceptedFixtureRealProjectBound = [bool]$acceptedReadiness.realProjectBound
    acceptedFixtureExternalProductionDriverSelected = [bool]$acceptedReadiness.externalProductionDriverSelected
    acceptedFixtureSampleGameReplayDriverUsed = [bool]$acceptedReadiness.sampleGameReplayDriverUsed
    acceptedFixtureBlockingReasonCount = [int]$acceptedReadiness.blockingReasonCount
    acceptedFixtureDriverId = $acceptedDriverId
    acceptedFixtureDriverSource = $acceptedDriverSource
    releasePipelineUsesFixture = $false
    realProductionDriverEvidenceAccepted = $false
    productionOutputBoundary = "accepted_fixture_contract_only"
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
    files = @(
        $copiedIntakeManifestName,
        $copiedReadinessManifestName,
        $copiedChecklistName,
        $copiedRetestName
    )
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Production driver evidence contract probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production driver evidence contract probe manifest: $manifestPath"
Write-Output "PASS AI TestPilot production driver evidence contract probe"
