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
    $ExternalBundleRoot = Join-Path $tempRoot "AITestPilot\production-external-evidence-inbox-contract-probe"
}

if ([string]::IsNullOrWhiteSpace($ProbeBundleDir)) {
    $ProbeBundleDir = Join-Path $EvidenceBundleDir "production-external-evidence-inbox-contract-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-external-evidence-inbox-contract-probe-manifest.json"
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

$externalInboxPath = Join-Path $externalBundlePath "production-external-evidence-inbox"
$filledInboxManifestPath = Join-Path $probeBundlePath "production-external-evidence-inbox-filled-manifest.json"
$filledInboxReportPath = Join-Path $probeBundlePath "production-external-evidence-inbox-filled.md"

& (Join-Path $PSScriptRoot "Invoke-AITestPilotProductionExternalEvidenceInbox.ps1") `
    -EvidenceBundleDir $evidenceBundlePath `
    -InboxDir $externalInboxPath `
    -ManifestPath $filledInboxManifestPath `
    -ReportPath $filledInboxReportPath | Out-Null

$externalDriverDir = Join-Path $externalInboxPath "production-driver-evidence"
$externalLuaDir = Join-Path $externalInboxPath "production-lua-evidence"
$externalLiveDir = Join-Path $externalInboxPath "live-smoke-evidence"

Copy-RequiredFiles $driverAcceptedSourceDir $externalDriverDir $driverRequiredFiles "Accepted production driver fixture"
Copy-RequiredFiles $luaAcceptedSourceDir $externalLuaDir $luaRequiredFiles "Accepted production Lua fixture"
Copy-RequiredFiles $liveAcceptedSourceDir $externalLiveDir $liveModelRequiredFiles "Accepted live model smoke fixture"

& (Join-Path $PSScriptRoot "Invoke-AITestPilotProductionExternalEvidenceInbox.ps1") `
    -EvidenceBundleDir $evidenceBundlePath `
    -InboxDir $externalInboxPath `
    -ManifestPath $filledInboxManifestPath `
    -ReportPath $filledInboxReportPath | Out-Null

$filledInboxManifest = Read-JsonFile $filledInboxManifestPath "Filled production external evidence inbox manifest"

$acceptedOutputPath = Join-Path $probeBundlePath "acceptance-wrapper-output"
$acceptedWrapperManifestPath = Join-Path $acceptedOutputPath "external-evidence-acceptance-wrapper-manifest.json"
$acceptedAcceptanceManifestPath = Join-Path $acceptedOutputPath "production-external-evidence-acceptance-manifest.json"
$acceptedAcceptanceReportPath = Join-Path $acceptedOutputPath "production-external-evidence-acceptance.md"

& (Join-Path $externalInboxPath "accept-returned-evidence.ps1") `
    -RepoRoot $repoRoot `
    -EvidenceBundleDir $evidenceBundlePath `
    -OutputDir $acceptedOutputPath `
    -GameReplayDriverType "Your.Game.Tests.AcceptedProductionReplayDriver" `
    -ContractFixtureMode | Out-Null

$acceptedWrapper = Read-JsonFile $acceptedWrapperManifestPath "Accepted inbox wrapper manifest"
$acceptedAcceptance = Read-JsonFile $acceptedAcceptanceManifestPath "Accepted inbox acceptance manifest"

$wrapperManifestName = "production-external-evidence-inbox-acceptance-wrapper-manifest.json"
$acceptanceManifestName = "production-external-evidence-inbox-acceptance-manifest.json"
$acceptanceReportName = "production-external-evidence-inbox-acceptance.md"
Copy-Item -LiteralPath $acceptedWrapperManifestPath -Destination (Join-Path $evidenceBundlePath $wrapperManifestName) -Force
Copy-Item -LiteralPath $acceptedAcceptanceManifestPath -Destination (Join-Path $evidenceBundlePath $acceptanceManifestName) -Force
Copy-Item -LiteralPath $acceptedAcceptanceReportPath -Destination (Join-Path $evidenceBundlePath $acceptanceReportName) -Force

$externalBundleUnderRepo = $externalBundlePath.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)
$filledInboxComplete = $filledInboxManifest.status -eq "PASS" -and
    [int]$filledInboxManifest.evidenceAreaCount -eq 3 -and
    [int]$filledInboxManifest.completeAreaCount -eq 3 -and
    [int]$filledInboxManifest.missingRequiredFileCount -eq 0 -and
    [bool]$filledInboxManifest.externalEvidenceCollectionComplete -and
    -not [bool]$filledInboxManifest.realHostProjectEvidenceAccepted
$acceptedWrapperPassed = $acceptedWrapper.schemaVersion -eq "aitestpilot.production_handoff_external_evidence_acceptance_wrapper.v1" -and
    $acceptedWrapper.status -eq "PASS" -and
    [bool]$acceptedWrapper.acceptanceCommandPassed -and
    $acceptedWrapper.acceptanceStatus -eq "PASS" -and
    [bool]$acceptedWrapper.allExternalEvidenceAccepted -and
    [bool]$acceptedWrapper.contractFixtureMode -and
    -not [bool]$acceptedWrapper.realHostProjectEvidenceAccepted
$acceptedAcceptancePassed = $acceptedAcceptance.schemaVersion -eq "aitestpilot.production_external_evidence_acceptance.v1" -and
    $acceptedAcceptance.status -eq "PASS" -and
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
Add-ProbeCheck "external_inbox_generated" `
    ((-not [bool]$externalBundleUnderRepo) -and (Test-Path $externalInboxPath) -and [bool]$filledInboxManifest.inboxTemplateGenerated) `
    "Returned-evidence inbox must be generated outside the repository for contract probing."
Add-ProbeCheck "accepted_fixture_files_loaded" `
    $filledInboxComplete `
    "Accepted fixture files must fill every returned-evidence inbox area without claiming real evidence."
Add-ProbeCheck "inbox_wrapper_acceptance_passed" `
    ($acceptedWrapperPassed -and $acceptedAcceptancePassed) `
    "Returned-evidence inbox wrapper must accept complete host-project-shaped fixture evidence in contract mode."
Add-ProbeCheck "driver_lua_live_accepted" `
    ([bool]$acceptedAcceptance.productionDriverEvidenceAccepted -and [bool]$acceptedAcceptance.productionLuaEvidenceAccepted -and [bool]$acceptedAcceptance.liveModelSmokeEvidenceAccepted) `
    "Driver, Lua, and live model evidence acceptance must all pass through the inbox wrapper."
Add-ProbeCheck "fixture_boundary_preserved" `
    (-not [bool]$acceptedWrapper.realHostProjectEvidenceAccepted -and -not [bool]$acceptedAcceptance.realHostProjectEvidenceAccepted -and -not [bool]$acceptedAcceptance.releasePipelineUsesFixture) `
    "Inbox contract fixture evidence must not be promoted as real host-project evidence."
Add-ProbeCheck "accepted_markdown_report_generated" `
    ((Test-Path $acceptedAcceptanceReportPath) -and [bool]$acceptedAcceptance.reportGenerated -and [bool]$acceptedAcceptance.reportContentValidated) `
    "Inbox wrapper must generate a validated Markdown acceptance report."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$files = @(
    "production-external-evidence-inbox-contract-probe-manifest.json",
    $wrapperManifestName,
    $acceptanceManifestName,
    $acceptanceReportName
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_external_evidence_inbox_contract_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    externalBundleRoot = $externalBundlePath
    externalInboxDir = $externalInboxPath
    probeBundleDir = $probeBundlePath
    externalBundleUnderRepo = [bool]$externalBundleUnderRepo
    inboxTemplateGenerated = [bool]$filledInboxManifest.inboxTemplateGenerated
    filledInboxComplete = [bool]$filledInboxComplete
    filledInboxEvidenceAreaCount = [int]$filledInboxManifest.evidenceAreaCount
    filledInboxCompleteAreaCount = [int]$filledInboxManifest.completeAreaCount
    filledInboxMissingRequiredFileCount = [int]$filledInboxManifest.missingRequiredFileCount
    acceptedWrapperPassed = [bool]$acceptedWrapperPassed
    acceptedWrapperReportGenerated = [bool]$acceptedWrapper.acceptanceReportGenerated
    acceptedWrapperAcceptanceStatus = [string]$acceptedWrapper.acceptanceStatus
    acceptedWrapperAllExternalEvidenceAccepted = [bool]$acceptedWrapper.allExternalEvidenceAccepted
    acceptedWrapperContractFixtureMode = [bool]$acceptedWrapper.contractFixtureMode
    acceptedProductionDriverEvidenceAccepted = [bool]$acceptedAcceptance.productionDriverEvidenceAccepted
    acceptedProductionLuaEvidenceAccepted = [bool]$acceptedAcceptance.productionLuaEvidenceAccepted
    acceptedLiveModelSmokeEvidenceAccepted = [bool]$acceptedAcceptance.liveModelSmokeEvidenceAccepted
    acceptedAllExternalEvidenceAccepted = [bool]$acceptedAcceptance.allExternalEvidenceAccepted
    realHostProjectEvidenceAccepted = $false
    releasePipelineUsesFixture = $false
    productionOutputBoundary = "accepted_fixture_external_evidence_inbox_contract_only"
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
    files = @($files)
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Production external evidence inbox contract probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production external evidence inbox contract probe manifest: $manifestPath"
Write-Output "PASS AI TestPilot production external evidence inbox contract probe"
