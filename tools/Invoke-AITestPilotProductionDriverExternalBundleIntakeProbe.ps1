[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ExternalBundleDir,
    [string]$ManifestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
if ([string]::IsNullOrWhiteSpace($ExternalBundleDir)) {
    $ExternalBundleDir = Join-Path $tempRoot "AITestPilot\production-driver-external-bundle-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-driver-external-bundle-intake-probe-manifest.json"
}

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
$externalBundlePath = Assert-PathUnderTemp $ExternalBundleDir "ExternalBundleDir"
$manifestPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if (Test-Path $externalBundlePath) {
    Remove-Item -LiteralPath $externalBundlePath -Recurse -Force
}

New-Item -ItemType Directory -Force $externalBundlePath | Out-Null

$missingFiles = @()
foreach ($fileName in $requiredInputFiles) {
    $sourcePath = Join-Path $evidenceBundlePath $fileName
    if (-not (Test-Path $sourcePath)) {
        $missingFiles += $fileName
        continue
    }

    Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $externalBundlePath $fileName) -Force
}

if ($missingFiles.Count -gt 0) {
    throw "Source evidence bundle is missing required files for external bundle probe: $($missingFiles -join ', ')"
}

$externalIntakeManifestPath = Join-Path $externalBundlePath "production-driver-evidence-intake-manifest.json"
$externalReadinessManifestPath = Join-Path $externalBundlePath "production-driver-evidence-intake-readiness-manifest.json"

& (Join-Path $PSScriptRoot "Invoke-AITestPilotProductionDriverEvidenceIntake.ps1") `
    -EvidenceBundleDir $externalBundlePath `
    -ManifestPath $externalIntakeManifestPath `
    -ExpectBlocked

$externalIntakeManifest = Read-JsonFile $externalIntakeManifestPath "External production driver evidence intake manifest"
$externalReadinessManifest = Read-JsonFile $externalReadinessManifestPath "External production driver readiness manifest"

$externalBundleUnderRepo = $externalBundlePath.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)
$expectedBlockedPassed = [bool]$externalIntakeManifest.expectedBlockedPassed -and
    [bool]$externalIntakeManifest.expectedSampleBlockingReasonsFound -and
    -not [bool]$externalIntakeManifest.intakeAccepted -and
    -not [bool]$externalIntakeManifest.readyForProductionDriverRelease -and
    $externalIntakeManifest.integrationChecklistStatus -eq "TEMPLATE_READY" -and
    -not [bool]$externalIntakeManifest.realProjectBound

if ($externalBundleUnderRepo) {
    throw "External bundle probe did not use a path outside the repo: $externalBundlePath"
}

if (-not $expectedBlockedPassed) {
    throw "External production driver bundle intake did not block the copied sample/unbound bundle as expected."
}

$copiedIntakeManifestName = "production-driver-external-bundle-intake-manifest.json"
$copiedReadinessManifestName = "production-driver-external-bundle-readiness-manifest.json"
Copy-Item -LiteralPath $externalIntakeManifestPath -Destination (Join-Path $evidenceBundlePath $copiedIntakeManifestName) -Force
Copy-Item -LiteralPath $externalReadinessManifestPath -Destination (Join-Path $evidenceBundlePath $copiedReadinessManifestName) -Force

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_driver_external_bundle_intake_probe.v1"
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    sourceEvidenceBundleDir = $evidenceBundlePath
    externalBundleDir = $externalBundlePath
    externalBundleUnderRepo = [bool]$externalBundleUnderRepo
    requiredFileCount = [int]$requiredInputFiles.Count
    requiredFilesCopied = @($requiredInputFiles)
    expectedBlocked = $true
    expectedBlockedPassed = [bool]$expectedBlockedPassed
    intakeAccepted = [bool]$externalIntakeManifest.intakeAccepted
    readyForProductionDriverRelease = [bool]$externalIntakeManifest.readyForProductionDriverRelease
    readinessCommandFailed = [bool]$externalIntakeManifest.readinessCommandFailed
    integrationChecklistStatus = $externalIntakeManifest.integrationChecklistStatus
    realProjectBound = [bool]$externalIntakeManifest.realProjectBound
    blockingReasonCount = [int]$externalIntakeManifest.blockingReasonCount
    blockingReasons = @($externalIntakeManifest.blockingReasons)
    readinessManifestStatus = $externalReadinessManifest.status
    readinessRequireProductionBound = [bool]$externalReadinessManifest.requireProductionBound
    files = @(
        $copiedIntakeManifestName,
        $copiedReadinessManifestName
    )
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

Write-Output "Production driver external bundle intake probe manifest: $manifestPath"
Write-Output "PASS AI TestPilot production driver external bundle intake probe"
