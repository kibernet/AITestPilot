[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$KitDir,
    [string]$ManifestPath,
    [string]$DriverTypeName = "AITestPilot.HostProject.Tests.ProductionReplayDriver",
    [string]$DriverId = "host_project.production_replay",
    [string]$DisplayName = "Host Project Production Replay Driver"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($KitDir)) {
    $KitDir = Join-Path $EvidenceBundleDir "production-driver-binding-kit"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-driver-binding-kit-manifest.json"
}

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

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
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

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$kitPath = Assert-PathUnderRepo $KitDir "KitDir"
$manifestPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"

New-Item -ItemType Directory -Force $evidenceBundlePath | Out-Null

$generatedKitManifestPath = Join-Path $kitPath "production-driver-binding-kit-generated-manifest.json"

& (Join-Path $PSScriptRoot "New-AITestPilotProductionDriverBindingKit.ps1") `
    -OutputDir $kitPath `
    -ManifestPath $generatedKitManifestPath `
    -DriverTypeName $DriverTypeName `
    -DriverId $DriverId `
    -DisplayName $DisplayName

$generatedManifest = Read-JsonFile $generatedKitManifestPath "Generated production driver binding kit manifest"

$driverClassName = ($DriverTypeName.Split(".") | Select-Object -Last 1)
$driverFileName = "$driverClassName.cs"
$relativeKitDir = "production-driver-binding-kit"
$generatedFiles = @(
    "$relativeKitDir/$driverFileName",
    "$relativeKitDir/Invoke-ProductionDriverEvidence.ps1",
    "$relativeKitDir/README.md",
    "$relativeKitDir/production-replay-integration-checklist.authoring.json",
    "$relativeKitDir/production-driver-binding-kit-generated-manifest.json"
)

foreach ($fileName in $generatedFiles) {
    $path = Join-Path $evidenceBundlePath ($fileName -replace "/", "\")
    Assert-True (Test-Path $path) "Production driver binding kit file is missing: $fileName"
}

$driverSource = Get-Content -Path (Join-Path $kitPath $driverFileName) -Encoding UTF8 -Raw
$hostScript = Get-Content -Path (Join-Path $kitPath "Invoke-ProductionDriverEvidence.ps1") -Encoding UTF8 -Raw
$readme = Get-Content -Path (Join-Path $kitPath "README.md") -Encoding UTF8 -Raw
$authoringChecklist = Read-JsonFile (Join-Path $kitPath "production-replay-integration-checklist.authoring.json") "Production driver binding authoring checklist"

$driverSourceHasHooks = $driverSource -match [regex]::Escape("HookedGameActionReplayDriver") -and
    $driverSource -match [regex]::Escape($DriverId) -and
    $driverSource -match [regex]::Escape("GameActionReplayHookResult.Fail") -and
    $driverSource -match [regex]::Escape("Bind prepare_account") -and
    $driverSource -match [regex]::Escape("Bind play_fishing")

$hostScriptHasProductionIntake = $hostScript -match [regex]::Escape("Invoke-AITestPilotProductionReplayDriverReadiness.ps1") -and
    $hostScript -match [regex]::Escape("-RequireProductionBound") -and
    $hostScript -match [regex]::Escape("Invoke-AITestPilotProductionDriverEvidenceIntake.ps1") -and
    $hostScript -match [regex]::Escape($DriverTypeName)

$readmeHasProductionBoundary = $readme -match [regex]::Escape("-RequireProductionReplayDriverBound") -and
    $readme -match [regex]::Escape("not production-bound evidence")

$authoringChecklistIsTemplate = $authoringChecklist.status -eq "TEMPLATE_READY" -and
    -not [bool]$authoringChecklist.realProjectBound -and
    [int]$authoringChecklist.requiredHookCount -eq 5 -and
    [int]$authoringChecklist.boundRequiredHookCount -eq 0 -and
    [int]$authoringChecklist.unresolvedRequiredHookCount -eq 5

Assert-True ($generatedManifest.status -eq "PASS") "Generated kit manifest did not pass."
Assert-True ([bool]$generatedManifest.generatedKitOnly) "Generated kit manifest must mark generatedKitOnly=true."
Assert-True (-not [bool]$generatedManifest.readyForProductionDriverRelease) "Generated kit must not claim production driver readiness."
Assert-True (-not [bool]$generatedManifest.productionEvidenceAccepted) "Generated kit must not claim production evidence acceptance."
Assert-True $driverSourceHasHooks "Generated driver source is missing hook placeholders."
Assert-True $hostScriptHasProductionIntake "Generated host script is missing production-bound intake commands."
Assert-True $readmeHasProductionBoundary "Generated README is missing production-bound boundary guidance."
Assert-True $authoringChecklistIsTemplate "Generated authoring checklist must remain TEMPLATE_READY and unbound."

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_driver_binding_kit_probe.v1"
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    kitDir = $kitPath
    generatedKitManifest = "$relativeKitDir/production-driver-binding-kit-generated-manifest.json"
    driverTypeName = $DriverTypeName
    driverId = $DriverId
    displayName = $DisplayName
    kitGenerated = $true
    generatedFileCount = $generatedFiles.Count
    generatedFiles = @($generatedFiles)
    requiredHookCount = 5
    generatedHooksFailUntilBound = $true
    authoringChecklistStatus = $authoringChecklist.status
    authoringChecklistRealProjectBound = [bool]$authoringChecklist.realProjectBound
    authoringChecklistUnresolvedRequiredHookCount = [int]$authoringChecklist.unresolvedRequiredHookCount
    hostValidationScriptIncludesProductionBoundIntake = [bool]$hostScriptHasProductionIntake
    readyForProductionDriverRelease = $false
    productionEvidenceAccepted = $false
    generatedKitOnly = $true
    nextRequiredEvidenceFiles = @(
        "production-replay-integration-checklist.json",
        "repair-retest-manifest.json",
        "repair-driver-failure-manifest.json",
        "replay-profile-import-manifest.json"
    )
    files = @($generatedFiles)
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

Write-Output "Production driver binding kit probe manifest: $manifestPath"
Write-Output "PASS AI TestPilot production driver binding kit probe"
