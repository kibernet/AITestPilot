[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ManifestPath,
    [switch]$RequireProductionBound
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-replay-driver-readiness-manifest.json"
}

$requiredHandlerKeys = @(
    "game.prepare_account",
    "game.login",
    "game.enter_scene",
    "game.claim_reward",
    "game.play_fishing"
)

function Assert-PathUnderRepo {
    param(
        [string]$Path,
        [string]$Label
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must stay under repo root: $fullPath"
    }

    return $fullPath
}

function Read-RequiredJson {
    param(
        [string]$FileName
    )

    $path = Join-Path $EvidenceBundleDir $FileName
    if (-not (Test-Path $path)) {
        throw "Required production replay readiness input is missing: $path"
    }

    return Get-Content -Raw $path | ConvertFrom-Json
}

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

function Add-BlockingReason {
    param(
        [string]$Reason
    )

    if ($script:blockingReasons -notcontains $Reason) {
        $script:blockingReasons += $Reason
    }
}

function Get-OptionalBool {
    param(
        [object]$Object,
        [string]$Name,
        [bool]$DefaultValue
    )

    if ($null -ne $Object -and @($Object.PSObject.Properties.Name) -contains $Name) {
        return [bool]$Object.$Name
    }

    return $DefaultValue
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$manifestPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

$productionChecklist = Read-RequiredJson "production-replay-integration-checklist.json"
$repairRetest = Read-RequiredJson "repair-retest-manifest.json"
$driverFailureProbe = Read-RequiredJson "repair-driver-failure-manifest.json"
$replayProfileImport = Read-RequiredJson "replay-profile-import-manifest.json"

$blockingReasons = @()

$integrationChecklistStatus = [string]$productionChecklist.status
$realProjectBound = [bool]$productionChecklist.realProjectBound
$requiredHookCount = [int]$productionChecklist.requiredHookCount
$boundRequiredHookCount = [int]$productionChecklist.boundRequiredHookCount
$unresolvedRequiredHookCount = [int]$productionChecklist.unresolvedRequiredHookCount
$checklistHandlerKeys = @($productionChecklist.supportedHandlerKeys)
$checklistHasStandardHandlerKeys = Test-ContainsAll $checklistHandlerKeys $requiredHandlerKeys
$checklistAllRequiredHooksBound = Get-OptionalBool $productionChecklist "allRequiredHooksBound" $false
$checklistRequiredBindingMetadataComplete = Get-OptionalBool $productionChecklist "requiredBindingMetadataComplete" $false

if (-not $realProjectBound) {
    Add-BlockingReason "production_replay_integration_not_bound"
}
elseif ($integrationChecklistStatus -ne "BOUND") {
    Add-BlockingReason "production_replay_integration_not_bound_status"
}

if ($requiredHookCount -lt $requiredHandlerKeys.Count) {
    Add-BlockingReason "required_hook_count_incomplete"
}

if ($boundRequiredHookCount -lt $requiredHandlerKeys.Count) {
    Add-BlockingReason "required_hooks_not_all_bound"
}

if ($unresolvedRequiredHookCount -ne 0) {
    Add-BlockingReason "unresolved_required_hooks"
}

if (-not $checklistHasStandardHandlerKeys) {
    Add-BlockingReason "production_checklist_missing_standard_handler_keys"
}

if ($realProjectBound -and -not $checklistAllRequiredHooksBound) {
    Add-BlockingReason "production_checklist_not_all_required_hooks_bound"
}

if ($realProjectBound -and -not $checklistRequiredBindingMetadataComplete) {
    Add-BlockingReason "production_checklist_binding_metadata_incomplete"
}

$descriptor = $repairRetest.gameReplayDriverDescriptor
$descriptorPresent = $null -ne $descriptor
$descriptorHandlerKeys = @()
$descriptorConfigurationRequirements = @()
$descriptorSupportsStandardHandlerKeys = $false
$descriptorConfigurationComplete = $false

if ($descriptorPresent) {
    $descriptorHandlerKeys = @($descriptor.supportedHandlerKeys)
    $descriptorConfigurationRequirements = @($descriptor.configurationRequirements)
    $descriptorSupportsStandardHandlerKeys = Test-ContainsAll $descriptorHandlerKeys $requiredHandlerKeys
    $descriptorConfigurationComplete = $descriptorConfigurationRequirements.Count -gt 0

    foreach ($requirement in $descriptorConfigurationRequirements) {
        if ([string]::IsNullOrWhiteSpace($requirement.key) -or
            [string]::IsNullOrWhiteSpace($requirement.source) -or
            [string]::IsNullOrWhiteSpace($requirement.description)) {
            $descriptorConfigurationComplete = $false
        }
    }
}

if (-not $descriptorPresent) {
    Add-BlockingReason "driver_descriptor_missing"
}

if (-not $descriptorSupportsStandardHandlerKeys) {
    Add-BlockingReason "driver_descriptor_missing_standard_handler_keys"
}

if (-not $descriptorConfigurationComplete) {
    Add-BlockingReason "driver_descriptor_configuration_incomplete"
}

$driverId = [string]$repairRetest.gameReplayDriverId
$driverSource = [string]$repairRetest.gameReplayDriverSource
$sampleGameReplayDriverUsed = $driverId -match "^sample\." -or
    $driverSource -eq "sample_fallback" -or
    $driverSource -match [regex]::Escape("SampleGameActionReplayDriver")
$externalProductionDriverSelected = -not $sampleGameReplayDriverUsed -and
    $driverSource -match "^type:" -and
    -not [string]::IsNullOrWhiteSpace($driverId)

if ($sampleGameReplayDriverUsed) {
    Add-BlockingReason "sample_game_replay_driver_used"
}

if (-not $externalProductionDriverSelected) {
    Add-BlockingReason "external_production_driver_not_selected"
}

$retestPassed = $repairRetest.status -eq "PASS" -and
    [bool]$repairRetest.retestPassed -and
    -not [bool]$repairRetest.bugStillPresent -and
    [int]$repairRetest.replayedStepCount -ge $requiredHandlerKeys.Count
if (-not $retestPassed) {
    Add-BlockingReason "production_driver_retest_not_passing"
}

$businessReplayState = $repairRetest.businessReplayState
$businessReplayStateComplete = $null -ne $businessReplayState -and
    [int]$businessReplayState.accountPreparationCount -ge 1 -and
    [int]$businessReplayState.loginCount -ge 1 -and
    [int]$businessReplayState.sceneEntryCount -ge 1 -and
    [int]$businessReplayState.rewardClaimCount -ge 1 -and
    [int]$businessReplayState.fishingCastCount -ge 1 -and
    -not [string]::IsNullOrWhiteSpace($businessReplayState.preparedAccount) -and
    -not [string]::IsNullOrWhiteSpace($businessReplayState.loggedInAccount) -and
    -not [string]::IsNullOrWhiteSpace($businessReplayState.currentScene)
if (-not $businessReplayStateComplete) {
    Add-BlockingReason "business_replay_state_incomplete"
}

$driverFailureProbePassed = $driverFailureProbe.status -eq "PASS" -and
    [bool]$driverFailureProbe.expectedFailure -and
    [int]$driverFailureProbe.retestExitCode -ne 0 -and
    -not [string]::IsNullOrWhiteSpace($driverFailureProbe.expectedDriverId) -and
    -not [string]::IsNullOrWhiteSpace($driverFailureProbe.expectedHandlerKey) -and
    -not [string]::IsNullOrWhiteSpace($driverFailureProbe.expectedAction) -and
    -not [string]::IsNullOrWhiteSpace($driverFailureProbe.expectedTarget)
if (-not $driverFailureProbePassed) {
    Add-BlockingReason "driver_failure_probe_missing_or_incomplete"
}

$profileImportHandlerKeys = @($replayProfileImport.handlerKeys)
$replayProfileImportPassed = $replayProfileImport.status -eq "PASS" -and
    [bool]$replayProfileImport.assetPresent -and
    [int]$replayProfileImport.ruleCount -ge $requiredHandlerKeys.Count -and
    (Test-ContainsAll $profileImportHandlerKeys $requiredHandlerKeys)
if (-not $replayProfileImportPassed) {
    Add-BlockingReason "replay_profile_import_missing_or_incomplete"
}

$readyForProductionDriverRelease = $blockingReasons.Count -eq 0

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_replay_driver_readiness.v1"
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    packageReleaseAllowedWithoutProductionBinding = $true
    productionBindingRequiredForPackageRelease = $false
    readyForProductionDriverRelease = [bool]$readyForProductionDriverRelease
    requireProductionBound = [bool]$RequireProductionBound
    blockingReasonCount = [int]$blockingReasons.Count
    blockingReasons = @($blockingReasons)
    integrationChecklistStatus = $integrationChecklistStatus
    realProjectBound = [bool]$realProjectBound
    requiredHookCount = [int]$requiredHookCount
    boundRequiredHookCount = [int]$boundRequiredHookCount
    unresolvedRequiredHookCount = [int]$unresolvedRequiredHookCount
    productionChecklistHasStandardHandlerKeys = [bool]$checklistHasStandardHandlerKeys
    productionChecklistAllRequiredHooksBound = [bool]$checklistAllRequiredHooksBound
    productionChecklistRequiredBindingMetadataComplete = [bool]$checklistRequiredBindingMetadataComplete
    repairRetestStatus = $repairRetest.status
    retestPassed = [bool]$retestPassed
    gameReplayDriverId = $driverId
    gameReplayDriverSource = $driverSource
    sampleGameReplayDriverUsed = [bool]$sampleGameReplayDriverUsed
    externalProductionDriverSelected = [bool]$externalProductionDriverSelected
    descriptorPresent = [bool]$descriptorPresent
    descriptorSupportsStandardHandlerKeys = [bool]$descriptorSupportsStandardHandlerKeys
    descriptorConfigurationRequirementCount = [int]$descriptorConfigurationRequirements.Count
    descriptorConfigurationComplete = [bool]$descriptorConfigurationComplete
    businessReplayStateComplete = [bool]$businessReplayStateComplete
    driverFailureProbePassed = [bool]$driverFailureProbePassed
    replayProfileImportPassed = [bool]$replayProfileImportPassed
    requiredHandlerKeys = @($requiredHandlerKeys)
    files = @(
        "production-replay-integration-checklist.json",
        "repair-retest-manifest.json",
        "repair-driver-failure-manifest.json",
        "replay-profile-import-manifest.json"
    )
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

Write-Output "Production replay driver readiness manifest: $manifestPath"

if ($RequireProductionBound -and -not $readyForProductionDriverRelease) {
    throw "Production replay driver is not ready: $($blockingReasons -join ', ')"
}

Write-Output "PASS AI TestPilot production replay driver readiness"
