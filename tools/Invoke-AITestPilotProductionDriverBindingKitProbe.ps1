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

$repoRoot = [System.IO.Path]::GetFullPath((Resolve-Path (Join-Path $PSScriptRoot "..")).Path)
$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())

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

    $fullPath = Resolve-FullPath $Path
    if (-not (Test-PathWithinRoot $fullPath $repoRoot)) {
        throw "$Label must stay under repo root: $fullPath"
    }

    return $fullPath
}

function Resolve-FullPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Test-PathWithinRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    $fullPath = Resolve-FullPath $Path
    $fullRoot = Resolve-FullPath $Root
    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    if ($fullPath.Equals($fullRoot, $comparison)) {
        return $true
    }

    if (-not $fullRoot.EndsWith(([System.IO.Path]::DirectorySeparatorChar).ToString())) {
        $fullRoot = $fullRoot + [System.IO.Path]::DirectorySeparatorChar
    }

    return $fullPath.StartsWith($fullRoot, $comparison)
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

function Invoke-ExpectedFailure {
    param(
        [scriptblock]$Command,
        [string]$ExpectedMessage
    )

    try {
        & $Command | Out-Null
        return [pscustomobject]@{
            rejected = $false
            message = ""
            expectedMessageFound = $false
        }
    }
    catch {
        $message = $_.Exception.Message
        return [pscustomobject]@{
            rejected = $true
            message = $message
            expectedMessageFound = $message.Contains($ExpectedMessage)
        }
    }
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
    "$relativeKitDir/Export-ProductionDriverEvidenceBundle.ps1",
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
$exportScriptPath = Join-Path $kitPath "Export-ProductionDriverEvidenceBundle.ps1"
$exportScript = Get-Content -Path $exportScriptPath -Encoding UTF8 -Raw
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

$exportScriptRequiresProductionBoundReadiness = $exportScript -match [regex]::Escape("readyForProductionDriverRelease") -and
    $exportScript -match [regex]::Escape("requireProductionBound") -and
    $exportScript -match [regex]::Escape("integrationChecklistStatus") -and
    $exportScript -match [regex]::Escape("BOUND") -and
    $exportScript -match [regex]::Escape("sampleGameReplayDriverUsed") -and
    $exportScript -match [regex]::Escape("production-driver-evidence.zip") -and
    $exportScript -match [regex]::Escape("production-replay-integration-checklist.json") -and
    $exportScript -match [regex]::Escape("repair-retest-manifest.json") -and
    $exportScript -match [regex]::Escape("repair-driver-failure-manifest.json") -and
    $exportScript -match [regex]::Escape("replay-profile-import-manifest.json")

$readmeHasProductionBoundary = $readme -match [regex]::Escape("-RequireProductionReplayDriverBound") -and
    $readme -match [regex]::Escape("not production-bound evidence") -and
    $readme -match [regex]::Escape("Export-ProductionDriverEvidenceBundle.ps1") -and
    $readme -match [regex]::Escape("production-bound readiness passes with zero blockers")

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
Assert-True $exportScriptRequiresProductionBoundReadiness "Generated export helper must require production-bound readiness and package exactly the required driver evidence files."
Assert-True $readmeHasProductionBoundary "Generated README is missing production-bound boundary guidance."
Assert-True $authoringChecklistIsTemplate "Generated authoring checklist must remain TEMPLATE_READY and unbound."

$rejectionBundlePath = Join-Path $evidenceBundlePath "production-driver-binding-kit-export-rejection-probe"
if (Test-Path $rejectionBundlePath) {
    Remove-Item -LiteralPath $rejectionBundlePath -Recurse -Force
}
New-Item -ItemType Directory -Force $rejectionBundlePath | Out-Null

$requiredDriverEvidenceFiles = @(
    "production-replay-integration-checklist.json",
    "repair-retest-manifest.json",
    "repair-driver-failure-manifest.json",
    "replay-profile-import-manifest.json"
)
foreach ($fileName in $requiredDriverEvidenceFiles) {
    Copy-Item -LiteralPath (Join-Path $evidenceBundlePath $fileName) -Destination (Join-Path $rejectionBundlePath $fileName) -Force
}

$rejectionReadinessManifestPath = Join-Path $rejectionBundlePath "production-replay-driver-readiness-manifest.json"
$readinessRejectedCurrentSample = $false
$readinessFailureMessage = ""
try {
    & (Join-Path $PSScriptRoot "Invoke-AITestPilotProductionReplayDriverReadiness.ps1") `
        -EvidenceBundleDir $rejectionBundlePath `
        -ManifestPath $rejectionReadinessManifestPath `
        -RequireProductionBound | Out-Null
}
catch {
    $readinessRejectedCurrentSample = $true
    $readinessFailureMessage = $_.Exception.Message
}
Assert-True (Test-Path $rejectionReadinessManifestPath) "Production driver export rejection probe did not write readiness manifest."
$rejectionReadiness = Read-JsonFile $rejectionReadinessManifestPath "Production driver export rejection readiness manifest"

$exportRejectedCurrentSample = $false
$exportFailureMessage = ""
try {
    & $exportScriptPath -EvidenceBundleDir $rejectionBundlePath | Out-Null
}
catch {
    $exportRejectedCurrentSample = $true
    $exportFailureMessage = $_.Exception.Message
}
Assert-True $readinessRejectedCurrentSample "Production-bound readiness must reject the current sample/unbound evidence before export."
Assert-True $exportRejectedCurrentSample "Production driver evidence export helper must reject the current sample/unbound evidence."
Assert-True (-not (Test-Path (Join-Path $rejectionBundlePath "production-driver-evidence-export\production-driver-evidence.zip"))) "Production driver evidence export zip must not be written for sample/unbound evidence."

$generatorOutputDirBoundary = Invoke-ExpectedFailure `
    -ExpectedMessage "OutputDir must stay under repo root unless -AllowExternalOutput" `
    -Command {
        & (Join-Path $PSScriptRoot "New-AITestPilotProductionDriverBindingKit.ps1") `
            -OutputDir (Join-Path $tempRoot "AITestPilot\driver-kit-boundary-probe\external-output") `
            -ManifestPath (Join-Path $tempRoot "AITestPilot\driver-kit-boundary-probe\external-output\production-driver-binding-kit-generated-manifest.json") `
            -DriverTypeName $DriverTypeName `
            -DriverId $DriverId `
            -DisplayName $DisplayName
    }
$generatorManifestPathBoundary = Invoke-ExpectedFailure `
    -ExpectedMessage "ManifestPath must stay under allowed root" `
    -Command {
        & (Join-Path $PSScriptRoot "New-AITestPilotProductionDriverBindingKit.ps1") `
            -OutputDir (Join-Path $evidenceBundlePath "production-driver-binding-kit-manifest-boundary") `
            -ManifestPath (Join-Path $evidenceBundlePath "production-driver-binding-kit-manifest-escape.json") `
            -DriverTypeName $DriverTypeName `
            -DriverId $DriverId `
            -DisplayName $DisplayName
    }
$exportHelperOutputDirBoundary = Invoke-ExpectedFailure `
    -ExpectedMessage "OutputDir must stay under" `
    -Command {
        & $exportScriptPath `
            -EvidenceBundleDir $rejectionBundlePath `
            -OutputDir (Join-Path $evidenceBundlePath "driver-export-output-escape") `
            -ZipPath (Join-Path $rejectionBundlePath "production-driver-evidence-export\production-driver-evidence.zip")
    }
$exportHelperZipPathBoundary = Invoke-ExpectedFailure `
    -ExpectedMessage "ZipPath must stay under" `
    -Command {
        & $exportScriptPath `
            -EvidenceBundleDir $rejectionBundlePath `
            -OutputDir (Join-Path $rejectionBundlePath "production-driver-evidence-export\zip-boundary-output") `
            -ZipPath (Join-Path $evidenceBundlePath "driver-export-zip-escape.zip")
    }

$checks = @()
$pathBoundaryRejected = [bool]$generatorOutputDirBoundary.rejected -and
    [bool]$generatorOutputDirBoundary.expectedMessageFound -and
    [bool]$generatorManifestPathBoundary.rejected -and
    [bool]$generatorManifestPathBoundary.expectedMessageFound -and
    [bool]$exportHelperOutputDirBoundary.rejected -and
    [bool]$exportHelperOutputDirBoundary.expectedMessageFound -and
    [bool]$exportHelperZipPathBoundary.rejected -and
    [bool]$exportHelperZipPathBoundary.expectedMessageFound
Add-ProbeCheck "path_boundary" $pathBoundaryRejected "Generator and export helper must reject unmanaged output, manifest, and zip paths before writing."
$failedChecks = @($checks | Where-Object { -not [bool]$_["passed"] })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_driver_binding_kit_probe.v1"
    status = $status
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
    exportHelperGenerated = [bool](Test-Path $exportScriptPath)
    exportHelperRequiresProductionBoundReadiness = [bool]$exportScriptRequiresProductionBoundReadiness
    exportHelperRejectedSampleUnboundEvidence = [bool]$exportRejectedCurrentSample
    exportHelperSampleRejectionMessage = $exportFailureMessage
    exportRejectionReadinessRejectedCurrentSample = [bool]$readinessRejectedCurrentSample
    exportRejectionReadinessFailureMessage = $readinessFailureMessage
    exportRejectionBlockingReasonCount = [int]$rejectionReadiness.blockingReasonCount
    generatorOutputDirBoundaryRejected = [bool]$generatorOutputDirBoundary.rejected
    generatorOutputDirBoundaryMessage = $generatorOutputDirBoundary.message
    generatorManifestPathBoundaryRejected = [bool]$generatorManifestPathBoundary.rejected
    generatorManifestPathBoundaryMessage = $generatorManifestPathBoundary.message
    exportHelperOutputDirBoundaryRejected = [bool]$exportHelperOutputDirBoundary.rejected
    exportHelperOutputDirBoundaryMessage = $exportHelperOutputDirBoundary.message
    exportHelperZipPathBoundaryRejected = [bool]$exportHelperZipPathBoundary.rejected
    exportHelperZipPathBoundaryMessage = $exportHelperZipPathBoundary.message
    pathBoundaryRejected = [bool]$pathBoundaryRejected
    productionOutputBoundary = "production_driver_binding_kit_probe_only"
    readyForProductionDriverRelease = $false
    productionEvidenceAccepted = $false
    generatedKitOnly = $true
    nextRequiredEvidenceFiles = @(
        "production-replay-integration-checklist.json",
        "repair-retest-manifest.json",
        "repair-driver-failure-manifest.json",
        "replay-profile-import-manifest.json"
    )
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
    files = @($generatedFiles)
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Production driver binding kit probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production driver binding kit probe manifest: $manifestPath"
Write-Output "PASS AI TestPilot production driver binding kit probe"
