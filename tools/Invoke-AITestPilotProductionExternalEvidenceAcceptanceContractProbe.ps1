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
    $ExternalBundleRoot = Join-Path $tempRoot "AITestPilot\production-external-evidence-acceptance-contract-probe"
}

if ([string]::IsNullOrWhiteSpace($ProbeBundleDir)) {
    $ProbeBundleDir = Join-Path $EvidenceBundleDir "production-external-evidence-acceptance-contract-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-external-evidence-acceptance-contract-probe-manifest.json"
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
$luaRequiredFiles = @(
    "production-lua-patch-evidence.json",
    "production-lua-patch-retest-template.md",
    "production-lua-patch-rollback-plan-template.md"
)
$liveModelRequiredFiles = @(
    "live-model-endpoint-smoke-manifest.json",
    "live-model-endpoint-decision-trace.json"
)

$driverContract = Read-JsonFile (Join-Path $evidenceBundlePath "production-driver-evidence-contract-probe-manifest.json") "Production driver evidence contract probe manifest"
$luaContract = Read-JsonFile (Join-Path $evidenceBundlePath "production-lua-patch-evidence-kit-probe-manifest.json") "Production Lua patch evidence kit probe manifest"
$liveContract = Read-JsonFile (Join-Path $evidenceBundlePath "live-model-endpoint-smoke-evidence-contract-probe-manifest.json") "Live model smoke evidence contract probe manifest"

$driverAcceptedSourceDir = Resolve-FullPath ([string]$driverContract.acceptedFixtureBundleDir)
$luaAcceptedSourceDir = Join-Path (Resolve-FullPath ([string]$luaContract.probeBundleDir)) "accepted-fixture-evidence"
$liveAcceptedSourceDir = Resolve-FullPath ([string]$liveContract.externalBundleDir)

$externalDriverDir = Join-Path $externalBundlePath "production-driver-evidence"
$externalLuaDir = Join-Path $externalBundlePath "production-lua-evidence"
$externalLiveDir = Join-Path $externalBundlePath "live-model-smoke-evidence"

Copy-RequiredFiles $driverAcceptedSourceDir $externalDriverDir $driverRequiredFiles "Accepted production driver fixture"
Copy-RequiredFiles $luaAcceptedSourceDir $externalLuaDir $luaRequiredFiles "Accepted production Lua fixture"
Copy-RequiredFiles $liveAcceptedSourceDir $externalLiveDir $liveModelRequiredFiles "Accepted live model smoke fixture"

$acceptedAcceptanceName = "production-external-evidence-acceptance-contract-manifest.json"
$acceptedAcceptanceManifestPath = Join-Path $probeBundlePath $acceptedAcceptanceName
$acceptedAcceptanceBundlePath = Join-Path $probeBundlePath "acceptance-bundle"

& (Join-Path $PSScriptRoot "Invoke-AITestPilotProductionExternalEvidenceAcceptance.ps1") `
    -EvidenceBundleDir $evidenceBundlePath `
    -AcceptanceBundleDir $acceptedAcceptanceBundlePath `
    -ManifestPath $acceptedAcceptanceManifestPath `
    -ProductionDriverEvidenceDir $externalDriverDir `
    -ProductionLuaEvidenceDir $externalLuaDir `
    -LiveModelEndpointSmokeEvidenceDir $externalLiveDir `
    -GameReplayDriverType "Your.Game.Tests.AcceptedProductionReplayDriver" `
    -RequireAllEvidence `
    -ContractFixtureMode

$acceptedAcceptance = Read-JsonFile $acceptedAcceptanceManifestPath "Accepted external evidence acceptance manifest"
Copy-Item -LiteralPath $acceptedAcceptanceManifestPath -Destination (Join-Path $evidenceBundlePath $acceptedAcceptanceName) -Force

$externalBundleUnderRepo = $externalBundlePath.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)
$fixtureDirsGenerated = (Test-Path $externalDriverDir) -and (Test-Path $externalLuaDir) -and (Test-Path $externalLiveDir)
$acceptedContractPassed = $acceptedAcceptance.schemaVersion -eq "aitestpilot.production_external_evidence_acceptance.v1" -and
    $acceptedAcceptance.status -eq "PASS" -and
    [bool]$acceptedAcceptance.requireAllEvidence -and
    [bool]$acceptedAcceptance.contractFixtureMode -and
    [bool]$acceptedAcceptance.allRequiredExternalEvidenceFilesPresent -and
    [int]$acceptedAcceptance.missingExternalEvidenceAreaCount -eq 0 -and
    [int]$acceptedAcceptance.failedAcceptanceCount -eq 0 -and
    [bool]$acceptedAcceptance.productionDriverEvidenceAccepted -and
    [bool]$acceptedAcceptance.productionLuaEvidenceAccepted -and
    [bool]$acceptedAcceptance.liveModelSmokeEvidenceAccepted -and
    [bool]$acceptedAcceptance.allExternalEvidenceAccepted -and
    -not [bool]$acceptedAcceptance.realHostProjectEvidenceAccepted -and
    -not [bool]$acceptedAcceptance.releasePipelineUsesFixture -and
    $acceptedAcceptance.productionOutputBoundary -eq "accepted_fixture_external_evidence_acceptance_contract_only"

$checks = @()
Add-ProbeCheck "external_fixture_dirs_generated" $fixtureDirsGenerated "Accepted fixture directories must be generated outside the repository for acceptance only."
Add-ProbeCheck "accepted_contract_passed" $acceptedContractPassed "Stable external evidence acceptance command must accept complete host-project-shaped fixture evidence."
Add-ProbeCheck "driver_lua_live_accepted" `
    ([bool]$acceptedAcceptance.productionDriverEvidenceAccepted -and [bool]$acceptedAcceptance.productionLuaEvidenceAccepted -and [bool]$acceptedAcceptance.liveModelSmokeEvidenceAccepted) `
    "Driver, Lua, and live model evidence acceptance must all pass."
Add-ProbeCheck "fixture_boundary_preserved" `
    (-not [bool]$acceptedAcceptance.realHostProjectEvidenceAccepted -and -not [bool]$acceptedAcceptance.releasePipelineUsesFixture) `
    "Accepted fixture contract must not be promoted as real host-project evidence."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$files = @(
    "production-external-evidence-acceptance-contract-probe-manifest.json",
    $acceptedAcceptanceName
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_external_evidence_acceptance_contract_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    externalBundleRoot = $externalBundlePath
    probeBundleDir = $probeBundlePath
    externalBundleUnderRepo = [bool]$externalBundleUnderRepo
    acceptedFixtureDirsGenerated = [bool]$fixtureDirsGenerated
    acceptedAcceptanceManifest = $acceptedAcceptanceName
    acceptedAcceptancePassed = [bool]$acceptedContractPassed
    acceptedAcceptanceRequireAllEvidence = [bool]$acceptedAcceptance.requireAllEvidence
    acceptedAcceptanceContractFixtureMode = [bool]$acceptedAcceptance.contractFixtureMode
    acceptedAcceptanceAllRequiredFilesPresent = [bool]$acceptedAcceptance.allRequiredExternalEvidenceFilesPresent
    acceptedAcceptanceMissingAreaCount = [int]$acceptedAcceptance.missingExternalEvidenceAreaCount
    acceptedAcceptanceFailedCount = [int]$acceptedAcceptance.failedAcceptanceCount
    acceptedProductionDriverEvidenceAccepted = [bool]$acceptedAcceptance.productionDriverEvidenceAccepted
    acceptedProductionLuaEvidenceAccepted = [bool]$acceptedAcceptance.productionLuaEvidenceAccepted
    acceptedLiveModelSmokeEvidenceAccepted = [bool]$acceptedAcceptance.liveModelSmokeEvidenceAccepted
    acceptedAllExternalEvidenceAccepted = [bool]$acceptedAcceptance.allExternalEvidenceAccepted
    realHostProjectEvidenceAccepted = [bool]$acceptedAcceptance.realHostProjectEvidenceAccepted
    releasePipelineUsesFixture = [bool]$acceptedAcceptance.releasePipelineUsesFixture
    productionOutputBoundary = "accepted_fixture_external_evidence_acceptance_contract_only"
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
    files = @($files)
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Production external evidence acceptance contract probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production external evidence acceptance contract probe manifest: $manifestPath"
Write-Output "PASS AI TestPilot production external evidence acceptance contract probe"
