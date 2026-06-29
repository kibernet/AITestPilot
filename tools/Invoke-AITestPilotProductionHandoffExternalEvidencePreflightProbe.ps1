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
    $ExternalBundleRoot = Join-Path $tempRoot "AITestPilot\production-handoff-external-evidence-preflight-probe"
}

if ([string]::IsNullOrWhiteSpace($ProbeBundleDir)) {
    $ProbeBundleDir = Join-Path $repoRoot "Temp\release-evidence\production-handoff-external-evidence-preflight-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-handoff-external-evidence-preflight-probe-manifest.json"
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

$handoffManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-package-manifest.json") "Production handoff package manifest"
$driverContract = Read-JsonFile (Join-Path $evidenceBundlePath "production-driver-evidence-contract-probe-manifest.json") "Production driver evidence contract probe manifest"
$luaContract = Read-JsonFile (Join-Path $evidenceBundlePath "production-lua-patch-evidence-kit-probe-manifest.json") "Production Lua patch evidence kit probe manifest"
$liveContract = Read-JsonFile (Join-Path $evidenceBundlePath "live-model-endpoint-smoke-evidence-contract-probe-manifest.json") "Live model smoke evidence contract probe manifest"

$handoffPackageDir = Join-Path $evidenceBundlePath "production-handoff-package"
$preflightScriptPath = Join-Path $handoffPackageDir "verify-external-evidence.ps1"
if (-not (Test-Path $preflightScriptPath)) {
    throw "Production handoff preflight script is missing: $preflightScriptPath"
}

$driverAcceptedSourceDir = Resolve-FullPath ([string]$driverContract.acceptedFixtureBundleDir)
$luaAcceptedSourceDir = Join-Path (Resolve-FullPath ([string]$luaContract.probeBundleDir)) "accepted-fixture-evidence"
$liveAcceptedSourceDir = Resolve-FullPath ([string]$liveContract.externalBundleDir)

$externalDriverDir = Join-Path $externalBundlePath "production-driver-evidence"
$externalLuaDir = Join-Path $externalBundlePath "production-lua-evidence"
$externalLiveDir = Join-Path $externalBundlePath "live-model-smoke-evidence"
$preflightIntakeBundleDir = Join-Path $probeBundlePath "preflight-intake-bundle"
New-Item -ItemType Directory -Force $preflightIntakeBundleDir | Out-Null

Copy-RequiredFiles $driverAcceptedSourceDir $externalDriverDir $driverRequiredFiles "Accepted production driver fixture"
Copy-RequiredFiles $luaAcceptedSourceDir $externalLuaDir $luaRequiredFiles "Accepted production Lua fixture"
Copy-RequiredFiles $liveAcceptedSourceDir $externalLiveDir $liveModelRequiredFiles "Accepted live model smoke fixture"

foreach ($fileName in @("lua-static-analysis-manifest.json", "lua-auto-patch-sandbox-manifest.json")) {
    $sourcePath = Join-Path $evidenceBundlePath $fileName
    if (-not (Test-Path $sourcePath)) {
        throw "Preflight intake bundle source file is missing: $sourcePath"
    }

    Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $preflightIntakeBundleDir $fileName) -Force
}

$acceptedPreflightName = "production-handoff-external-evidence-preflight-accepted-manifest.json"
$acceptedPreflightManifestPath = Join-Path $probeBundlePath $acceptedPreflightName

& $preflightScriptPath `
    -RepoRoot $repoRoot `
    -EvidenceBundleDir $preflightIntakeBundleDir `
    -ProductionDriverEvidenceDir $externalDriverDir `
    -ProductionLuaEvidenceDir $externalLuaDir `
    -LiveModelEndpointSmokeEvidenceDir $externalLiveDir `
    -GameReplayDriverType "Your.Game.Tests.AcceptedProductionReplayDriver" `
    -OutputPath $acceptedPreflightManifestPath `
    -RequireAllEvidence `
    -RunIntake

$acceptedPreflight = Read-JsonFile $acceptedPreflightManifestPath "Accepted external evidence preflight manifest"

$externalBundleUnderRepo = $externalBundlePath.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)
$fixtureDirsGenerated = (Test-Path $externalDriverDir) -and (Test-Path $externalLuaDir) -and (Test-Path $externalLiveDir)
$acceptedPreflightPassed = $acceptedPreflight.schemaVersion -eq "aitestpilot.production_handoff_external_evidence_preflight.v1" -and
    $acceptedPreflight.status -eq "PASS" -and
    [bool]$acceptedPreflight.requireAllEvidence -and
    [bool]$acceptedPreflight.runIntake -and
    [bool]$acceptedPreflight.allRequiredExternalEvidenceFilesPresent -and
    [int]$acceptedPreflight.missingExternalEvidenceAreaCount -eq 0 -and
    [int]$acceptedPreflight.failedIntakeCount -eq 0
$acceptedPreflightIntakePassed = @($acceptedPreflight.intakeResults).Count -eq 3 -and
    @($acceptedPreflight.intakeResults | Where-Object { -not [bool]$_.passed }).Count -eq 0
$acceptedPreflightRequiredFilesPassed = [bool]$acceptedPreflight.productionDriverEvidence.allPresent -and
    [bool]$acceptedPreflight.productionLuaEvidence.allPresent -and
    [bool]$acceptedPreflight.liveModelEndpointEvidence.allPresent
$handoffBoundaryPreserved = $handoffManifest.status -eq "PASS" -and
    [bool]$handoffManifest.externalEvidenceRequiredForProduction -and
    -not [bool]$handoffManifest.fixtureEvidencePromoted -and
    -not [bool]$handoffManifest.productionDriverReady -and
    -not [bool]$handoffManifest.productionLuaReady -and
    -not [bool]$handoffManifest.liveModelEndpointAccessProven

$checks = @()
Add-ProbeCheck "external_fixture_dirs_generated" $fixtureDirsGenerated "Accepted fixture directories must be generated outside the repository for preflight only."
Add-ProbeCheck "accepted_preflight_passed" $acceptedPreflightPassed "Generated handoff preflight must pass when accepted fixture evidence is supplied with RunIntake."
Add-ProbeCheck "accepted_preflight_intake_passed" $acceptedPreflightIntakePassed "Preflight RunIntake must pass driver, Lua, and live-model intake commands."
Add-ProbeCheck "accepted_preflight_required_files" $acceptedPreflightRequiredFilesPassed "Preflight must see all required files for driver, Lua, and live-model evidence."
Add-ProbeCheck "handoff_boundary_preserved" $handoffBoundaryPreserved "Accepted preflight fixture must not promote fixture data as real host-project evidence."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

Copy-Item -LiteralPath $acceptedPreflightManifestPath -Destination (Join-Path $evidenceBundlePath $acceptedPreflightName) -Force

$files = @(
    "production-handoff-external-evidence-preflight-probe-manifest.json",
    $acceptedPreflightName
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_external_evidence_preflight_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    externalBundleRoot = $externalBundlePath
    probeBundleDir = $probeBundlePath
    externalBundleUnderRepo = [bool]$externalBundleUnderRepo
    handoffPreflightScriptPath = "production-handoff-package/verify-external-evidence.ps1"
    acceptedPreflightManifest = $acceptedPreflightName
    acceptedFixtureDirsGenerated = [bool]$fixtureDirsGenerated
    acceptedPreflightPassed = [bool]$acceptedPreflightPassed
    acceptedPreflightRunIntake = [bool]$acceptedPreflight.runIntake
    acceptedPreflightRequireAllEvidence = [bool]$acceptedPreflight.requireAllEvidence
    acceptedPreflightAllRequiredFilesPresent = [bool]$acceptedPreflight.allRequiredExternalEvidenceFilesPresent
    acceptedPreflightMissingAreaCount = [int]$acceptedPreflight.missingExternalEvidenceAreaCount
    acceptedPreflightIntakeResultCount = [int]@($acceptedPreflight.intakeResults).Count
    acceptedPreflightFailedIntakeCount = [int]$acceptedPreflight.failedIntakeCount
    acceptedPreflightIntakePassed = [bool]$acceptedPreflightIntakePassed
    acceptedPreflightRequiredFilesPassed = [bool]$acceptedPreflightRequiredFilesPassed
    releasePipelineUsesFixture = $false
    realHostProjectEvidenceAccepted = $false
    productionOutputBoundary = "accepted_fixture_preflight_contract_only"
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
    files = @($files)
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Production handoff external evidence preflight probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production handoff external evidence preflight probe manifest: $manifestPath"
Write-Output "PASS AI TestPilot production handoff external evidence preflight probe"
