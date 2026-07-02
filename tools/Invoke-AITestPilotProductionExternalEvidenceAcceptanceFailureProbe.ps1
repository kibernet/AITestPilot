[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ExternalBundleRoot,
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

if ([string]::IsNullOrWhiteSpace($ExternalBundleRoot)) {
    $ExternalBundleRoot = Join-Path $tempRoot "AITestPilot\production-external-evidence-acceptance-failure-probe"
}

if ([string]::IsNullOrWhiteSpace($ProbeBundleDir)) {
    $ProbeBundleDir = Join-Path $EvidenceBundleDir "production-external-evidence-acceptance-failure-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-external-evidence-acceptance-failure-probe-manifest.json"
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

    if (-not $fullRoot.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $fullRoot = $fullRoot + [System.IO.Path]::DirectorySeparatorChar
    }

    return $fullPath.StartsWith($fullRoot, $comparison)
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

function Assert-PathUnderTemp {
    param(
        [string]$Path,
        [string]$Label
    )

    $fullPath = Resolve-FullPath $Path
    if (-not (Test-PathWithinRoot $fullPath $tempRoot)) {
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

function Copy-RequiredFiles {
    param(
        [string]$SourceDir,
        [string]$DestinationDir,
        [string[]]$FileNames,
        [string]$Label
    )

    New-Item -ItemType Directory -Force $DestinationDir | Out-Null
    foreach ($fileName in $FileNames) {
        $sourcePath = Join-Path $SourceDir $fileName
        if (-not (Test-Path $sourcePath)) {
            throw "$Label source file is missing: $sourcePath"
        }

        Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $DestinationDir $fileName) -Force
    }
}

function Invoke-AcceptanceExpectFailure {
    param(
        [string]$AcceptanceBundleDir,
        [string]$ManifestPath,
        [string]$ReportPath,
        [string]$ProductionDriverEvidenceDir = "",
        [string]$ProductionLuaEvidenceDir = "",
        [string]$LiveModelEndpointSmokeEvidenceDir = ""
    )

    $failed = $false
    $errorMessage = ""
    try {
        & (Join-Path $PSScriptRoot "Invoke-AITestPilotProductionExternalEvidenceAcceptance.ps1") `
            -EvidenceBundleDir $script:evidenceBundlePath `
            -AcceptanceBundleDir $AcceptanceBundleDir `
            -ManifestPath $ManifestPath `
            -ReportPath $ReportPath `
            -ProductionDriverEvidenceDir $ProductionDriverEvidenceDir `
            -ProductionLuaEvidenceDir $ProductionLuaEvidenceDir `
            -LiveModelEndpointSmokeEvidenceDir $LiveModelEndpointSmokeEvidenceDir `
            -RequireAllEvidence `
            -ContractFixtureMode
    } catch {
        $failed = $true
        $errorMessage = $_.Exception.Message
    }

    if (-not (Test-Path $ManifestPath)) {
        throw "Expected failed acceptance manifest was not produced: $ManifestPath"
    }

    return [ordered]@{
        commandFailed = [bool]$failed
        errorMessage = $errorMessage
        manifest = (Read-JsonFile $ManifestPath "Failed external evidence acceptance manifest")
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
$externalBundlePath = Assert-PathUnderTemp $ExternalBundleRoot "ExternalBundleRoot"
$probeBundlePath = Assert-PathUnderRepo $ProbeBundleDir "ProbeBundleDir"
$manifestPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if (Test-Path $externalBundlePath) {
    Remove-Item -LiteralPath $externalBundlePath -Recurse -Force
}

if (Test-Path $probeBundlePath) {
    Remove-Item -LiteralPath $probeBundlePath -Recurse -Force
}

New-Item -ItemType Directory -Force $externalBundlePath | Out-Null
New-Item -ItemType Directory -Force $probeBundlePath | Out-Null

$driverRequiredFiles = @(
    "production-replay-integration-checklist.json",
    "repair-retest-manifest.json",
    "repair-driver-failure-manifest.json",
    "replay-profile-import-manifest.json"
)

$driverContract = Read-JsonFile (Join-Path $evidenceBundlePath "production-driver-evidence-contract-probe-manifest.json") "Production driver evidence contract probe manifest"
$driverAcceptedSourceDir = Resolve-FullPath ([string]$driverContract.acceptedFixtureBundleDir)
$partialDriverDir = Join-Path $externalBundlePath "driver-only-evidence"
Copy-RequiredFiles $driverAcceptedSourceDir $partialDriverDir $driverRequiredFiles "Accepted production driver fixture"

$missingAllAcceptanceDir = Join-Path $probeBundlePath "missing-all"
$missingAllManifestPath = Join-Path $missingAllAcceptanceDir "production-external-evidence-acceptance-manifest.json"
$missingAllReportPath = Join-Path $missingAllAcceptanceDir "production-external-evidence-acceptance-missing-all.md"
$partialDriverAcceptanceDir = Join-Path $probeBundlePath "driver-only"
$partialDriverManifestPath = Join-Path $partialDriverAcceptanceDir "production-external-evidence-acceptance-manifest.json"
$partialDriverReportPath = Join-Path $partialDriverAcceptanceDir "production-external-evidence-acceptance-driver-only.md"

$missingAllResult = Invoke-AcceptanceExpectFailure `
    -AcceptanceBundleDir $missingAllAcceptanceDir `
    -ManifestPath $missingAllManifestPath `
    -ReportPath $missingAllReportPath

$partialDriverResult = Invoke-AcceptanceExpectFailure `
    -AcceptanceBundleDir $partialDriverAcceptanceDir `
    -ManifestPath $partialDriverManifestPath `
    -ReportPath $partialDriverReportPath `
    -ProductionDriverEvidenceDir $partialDriverDir

$missingAll = $missingAllResult.manifest
$partialDriver = $partialDriverResult.manifest
$missingAllReportGenerated = (Test-Path $missingAllReportPath) -and
    [bool]$missingAll.reportGenerated -and
    [bool]$missingAll.reportContentValidated
$partialDriverReportGenerated = (Test-Path $partialDriverReportPath) -and
    [bool]$partialDriver.reportGenerated -and
    [bool]$partialDriver.reportContentValidated

$missingAllRejected = [bool]$missingAllResult.commandFailed -and
    $missingAll.schemaVersion -eq "aitestpilot.production_external_evidence_acceptance.v1" -and
    $missingAll.status -eq "FAIL" -and
    [bool]$missingAll.reportGenerated -and
    [bool]$missingAll.reportContentValidated -and
    [bool]$missingAll.requireAllEvidence -and
    [bool]$missingAll.contractFixtureMode -and
    -not [bool]$missingAll.allRequiredExternalEvidenceFilesPresent -and
    [int]$missingAll.missingExternalEvidenceAreaCount -eq 3 -and
    -not [bool]$missingAll.productionDriverEvidenceAccepted -and
    -not [bool]$missingAll.productionLuaEvidenceAccepted -and
    -not [bool]$missingAll.liveModelSmokeEvidenceAccepted -and
    -not [bool]$missingAll.allExternalEvidenceAccepted -and
    -not [bool]$missingAll.realHostProjectEvidenceAccepted -and
    [int]$missingAll.failedCheckCount -gt 0

$partialDriverRejected = [bool]$partialDriverResult.commandFailed -and
    $partialDriver.schemaVersion -eq "aitestpilot.production_external_evidence_acceptance.v1" -and
    $partialDriver.status -eq "FAIL" -and
    [bool]$partialDriver.reportGenerated -and
    [bool]$partialDriver.reportContentValidated -and
    [bool]$partialDriver.requireAllEvidence -and
    [bool]$partialDriver.contractFixtureMode -and
    -not [bool]$partialDriver.allRequiredExternalEvidenceFilesPresent -and
    [int]$partialDriver.missingExternalEvidenceAreaCount -eq 2 -and
    [bool]$partialDriver.productionDriverEvidenceAccepted -and
    -not [bool]$partialDriver.productionLuaEvidenceAccepted -and
    -not [bool]$partialDriver.liveModelSmokeEvidenceAccepted -and
    -not [bool]$partialDriver.allExternalEvidenceAccepted -and
    -not [bool]$partialDriver.realHostProjectEvidenceAccepted -and
    [int]$partialDriver.failedCheckCount -gt 0

Copy-Item -LiteralPath $missingAllManifestPath -Destination (Join-Path $evidenceBundlePath "production-external-evidence-acceptance-missing-all-manifest.json") -Force
Copy-Item -LiteralPath $partialDriverManifestPath -Destination (Join-Path $evidenceBundlePath "production-external-evidence-acceptance-driver-only-manifest.json") -Force
Copy-Item -LiteralPath $missingAllReportPath -Destination (Join-Path $evidenceBundlePath "production-external-evidence-acceptance-missing-all.md") -Force
Copy-Item -LiteralPath $partialDriverReportPath -Destination (Join-Path $evidenceBundlePath "production-external-evidence-acceptance-driver-only.md") -Force

$externalBundleUnderRepo = Test-PathWithinRoot $externalBundlePath $repoRoot

$checks = @()
Add-ProbeCheck "missing_all_evidence_rejected" $missingAllRejected "Acceptance command must reject a fully missing external evidence package under RequireAllEvidence."
Add-ProbeCheck "driver_only_evidence_rejected" $partialDriverRejected "Acceptance command must reject partial driver-only evidence under RequireAllEvidence."
Add-ProbeCheck "fixture_boundary_preserved" `
    (-not [bool]$missingAll.realHostProjectEvidenceAccepted -and -not [bool]$partialDriver.realHostProjectEvidenceAccepted) `
    "Rejected fixture evidence must never be promoted as real host-project evidence."
Add-ProbeCheck "external_partial_bundle_outside_repo" `
    (-not [bool]$externalBundleUnderRepo -and (Test-Path $partialDriverDir)) `
    "Partial fixture input must be generated outside the repository."
Add-ProbeCheck "rejection_markdown_reports_generated" `
    ([bool]$missingAllReportGenerated -and [bool]$partialDriverReportGenerated) `
    "Rejected evidence scenarios must generate validated Markdown reports for host-project owners."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$files = @(
    "production-external-evidence-acceptance-failure-probe-manifest.json",
    "production-external-evidence-acceptance-missing-all-manifest.json",
    "production-external-evidence-acceptance-missing-all.md",
    "production-external-evidence-acceptance-driver-only-manifest.json",
    "production-external-evidence-acceptance-driver-only.md"
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_external_evidence_acceptance_failure_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    externalBundleRoot = $externalBundlePath
    probeBundleDir = $probeBundlePath
    externalBundleUnderRepo = [bool]$externalBundleUnderRepo
    requireAllEvidence = $true
    contractFixtureMode = $true
    missingAllAcceptanceRejected = [bool]$missingAllRejected
    missingAllCommandFailed = [bool]$missingAllResult.commandFailed
    missingAllStatus = [string]$missingAll.status
    missingAllReportGenerated = [bool]$missingAll.reportGenerated
    missingAllReportContentValidated = [bool]$missingAll.reportContentValidated
    missingAllMissingAreaCount = [int]$missingAll.missingExternalEvidenceAreaCount
    missingAllExternalEvidenceAccepted = [bool]$missingAll.allExternalEvidenceAccepted
    missingAllRealHostProjectEvidenceAccepted = [bool]$missingAll.realHostProjectEvidenceAccepted
    driverOnlyAcceptanceRejected = [bool]$partialDriverRejected
    driverOnlyCommandFailed = [bool]$partialDriverResult.commandFailed
    driverOnlyStatus = [string]$partialDriver.status
    driverOnlyReportGenerated = [bool]$partialDriver.reportGenerated
    driverOnlyReportContentValidated = [bool]$partialDriver.reportContentValidated
    driverOnlyMissingAreaCount = [int]$partialDriver.missingExternalEvidenceAreaCount
    driverOnlyProductionDriverEvidenceAccepted = [bool]$partialDriver.productionDriverEvidenceAccepted
    driverOnlyProductionLuaEvidenceAccepted = [bool]$partialDriver.productionLuaEvidenceAccepted
    driverOnlyLiveModelSmokeEvidenceAccepted = [bool]$partialDriver.liveModelSmokeEvidenceAccepted
    driverOnlyExternalEvidenceAccepted = [bool]$partialDriver.allExternalEvidenceAccepted
    driverOnlyRealHostProjectEvidenceAccepted = [bool]$partialDriver.realHostProjectEvidenceAccepted
    productionOutputBoundary = "external_evidence_acceptance_failure_probe_only"
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
    files = @($files)
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Production external evidence acceptance failure probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production external evidence acceptance failure probe manifest: $manifestPath"
Write-Output "PASS AI TestPilot production external evidence acceptance failure probe"
