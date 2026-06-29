[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ProbeBundleDir,
    [string]$AcceptedBundleDir,
    [string]$ManifestPath,
    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ProbeBundleDir)) {
    $ProbeBundleDir = Join-Path $EvidenceBundleDir "production-handoff-owner-unblock-pack-contract-probe"
}

if ([string]::IsNullOrWhiteSpace($AcceptedBundleDir)) {
    $AcceptedBundleDir = Join-Path $repoRoot "Temp\release-evidence\production-handoff-owner-unblock-pack-contract-accepted"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-handoff-owner-unblock-pack-contract-probe-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-handoff-owner-unblock-pack-contract-probe.md"
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

function Convert-ToEvidenceRelativePath {
    param([string]$Path)

    $fullPath = Resolve-FullPath $Path
    if (-not $fullPath.StartsWith($evidenceBundlePath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Probe file must stay under evidence bundle: $fullPath"
    }

    $relativePath = $fullPath.Substring($evidenceBundlePath.Length).TrimStart([char[]]@("\", "/"))
    return $relativePath.Replace("\", "/")
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

function Convert-ToArray {
    param([object]$Value)

    if ($null -eq $Value) {
        return @()
    }

    return @($Value)
}

function Get-JsonValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$DefaultValue = $null
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }

    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) {
        return $Object[$Name]
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }

    return $property.Value
}

function Convert-ToSlug {
    param([string]$Value)

    $slug = $Value.ToLowerInvariant() -replace "[^a-z0-9_-]+", "-"
    $slug = $slug.Trim("-")
    if ([string]::IsNullOrWhiteSpace($slug)) {
        return "owner"
    }

    return $slug
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

function Copy-ProbeFile {
    param(
        [string]$SourcePath,
        [string]$DestinationName
    )

    $destinationPath = Join-Path $probeBundlePath $DestinationName
    New-Item -ItemType Directory -Force (Split-Path $destinationPath -Parent) | Out-Null
    Copy-Item -LiteralPath $SourcePath -Destination $destinationPath -Force
    return $destinationPath
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
$acceptedBundlePath = Assert-PathUnderRepo $AcceptedBundleDir "AcceptedBundleDir"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if (Test-Path $probeBundlePath) {
    Remove-Item -LiteralPath $probeBundlePath -Recurse -Force
}
if (Test-Path $acceptedBundlePath) {
    Remove-Item -LiteralPath $acceptedBundlePath -Recurse -Force
}

New-Item -ItemType Directory -Force $probeBundlePath | Out-Null
New-Item -ItemType Directory -Force $acceptedBundlePath | Out-Null

Get-ChildItem -LiteralPath $evidenceBundlePath -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $acceptedBundlePath -Recurse -Force
}

$defaultOwnerUnblockPack = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-owner-unblock-pack-manifest.json") "Default owner unblock pack manifest"
$defaultContactReadiness = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-contact-readiness-manifest.json") "Default contact readiness manifest"
$defaultSendReadiness = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-send-readiness-manifest.json") "Default send readiness manifest"
$defaultInbox = Read-JsonFile (Join-Path $evidenceBundlePath "production-external-evidence-inbox-manifest.json") "Default external evidence inbox manifest"

$acceptedDispatchManifest = Read-JsonFile (Join-Path $acceptedBundlePath "production-handoff-dispatch-manifest.json") "Accepted fixture dispatch manifest"
$acceptedRosterEntries = @()
foreach ($entry in @(Convert-ToArray (Get-JsonValue $acceptedDispatchManifest "dispatchEntries" @()))) {
    $owner = [string](Get-JsonValue $entry "owner" "")
    $area = [string](Get-JsonValue $entry "area" "")
    $slug = Convert-ToSlug $owner
    $acceptedRosterEntries += [ordered]@{
        owner = $owner
        area = $area
        contactSlug = $slug
        emailAddress = ($slug + "@example.invalid")
        configured = $true
        notes = "Contract fixture address only. Replace with the real owner mailbox before live dispatch."
    }
}

$acceptedRosterPath = Join-Path $acceptedBundlePath "production-handoff-contact-roster.json"
$acceptedRoster = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_contact_roster.v1"
    status = "CONTACTS_CONFIGURED"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    ownerContactCount = [int]$acceptedRosterEntries.Count
    configuredContactCount = [int]$acceptedRosterEntries.Count
    fixtureOnly = $true
    entries = @($acceptedRosterEntries)
}
$acceptedRoster | ConvertTo-Json -Depth 12 | Set-Content -Path $acceptedRosterPath -Encoding UTF8

& (Join-Path $PSScriptRoot "Invoke-AITestPilotProductionHandoffContactReadiness.ps1") `
    -EvidenceBundleDir $acceptedBundlePath `
    -ContactRosterPath $acceptedRosterPath | Out-Null

& (Join-Path $PSScriptRoot "Invoke-AITestPilotProductionHandoffSendReadiness.ps1") `
    -EvidenceBundleDir $acceptedBundlePath | Out-Null

& (Join-Path $PSScriptRoot "Invoke-AITestPilotProductionHandoffMailAuthReadiness.ps1") `
    -EvidenceBundleDir $acceptedBundlePath | Out-Null

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

$driverContract = Read-JsonFile (Join-Path $acceptedBundlePath "production-driver-evidence-contract-probe-manifest.json") "Accepted production driver evidence contract probe manifest"
$luaContract = Read-JsonFile (Join-Path $acceptedBundlePath "production-lua-patch-evidence-kit-probe-manifest.json") "Accepted production Lua patch evidence kit probe manifest"
$liveContract = Read-JsonFile (Join-Path $acceptedBundlePath "live-model-endpoint-smoke-evidence-contract-probe-manifest.json") "Accepted live model smoke evidence contract probe manifest"

$driverAcceptedSourceDir = Resolve-FullPath ([string]$driverContract.acceptedFixtureBundleDir)
$luaAcceptedSourceDir = Join-Path (Resolve-FullPath ([string]$luaContract.probeBundleDir)) "accepted-fixture-evidence"
$liveAcceptedSourceDir = Resolve-FullPath ([string]$liveContract.externalBundleDir)

$acceptedInboxDir = Join-Path $acceptedBundlePath "production-external-evidence-inbox"
Copy-RequiredFiles $driverAcceptedSourceDir (Join-Path $acceptedInboxDir "production-driver-evidence") $driverRequiredFiles "Accepted production driver fixture"
Copy-RequiredFiles $luaAcceptedSourceDir (Join-Path $acceptedInboxDir "production-lua-evidence") $luaRequiredFiles "Accepted production Lua fixture"
Copy-RequiredFiles $liveAcceptedSourceDir (Join-Path $acceptedInboxDir "live-smoke-evidence") $liveModelRequiredFiles "Accepted live model smoke fixture"

& (Join-Path $PSScriptRoot "Invoke-AITestPilotProductionExternalEvidenceInbox.ps1") `
    -EvidenceBundleDir $acceptedBundlePath `
    -InboxDir $acceptedInboxDir | Out-Null

& (Join-Path $PSScriptRoot "Invoke-AITestPilotProductionHandoffOwnerUnblockPack.ps1") `
    -EvidenceBundleDir $acceptedBundlePath | Out-Null

$acceptedContactReadiness = Read-JsonFile (Join-Path $acceptedBundlePath "production-handoff-contact-readiness-manifest.json") "Accepted fixture contact readiness manifest"
$acceptedSendReadiness = Read-JsonFile (Join-Path $acceptedBundlePath "production-handoff-send-readiness-manifest.json") "Accepted fixture send readiness manifest"
$acceptedMailAuthReadiness = Read-JsonFile (Join-Path $acceptedBundlePath "production-handoff-mail-auth-readiness-manifest.json") "Accepted fixture mail auth readiness manifest"
$acceptedInbox = Read-JsonFile (Join-Path $acceptedBundlePath "production-external-evidence-inbox-manifest.json") "Accepted fixture external evidence inbox manifest"
$acceptedOwnerUnblockPack = Read-JsonFile (Join-Path $acceptedBundlePath "production-handoff-owner-unblock-pack-manifest.json") "Accepted fixture owner unblock pack manifest"

$acceptedCopiedFiles = @(
    (Copy-ProbeFile (Join-Path $acceptedBundlePath "production-handoff-contact-readiness-manifest.json") "accepted-contact-readiness-manifest.json"),
    (Copy-ProbeFile (Join-Path $acceptedBundlePath "production-handoff-send-readiness-manifest.json") "accepted-send-readiness-manifest.json"),
    (Copy-ProbeFile (Join-Path $acceptedBundlePath "production-handoff-mail-auth-readiness-manifest.json") "accepted-mail-auth-readiness-manifest.json"),
    (Copy-ProbeFile (Join-Path $acceptedBundlePath "production-external-evidence-inbox-manifest.json") "accepted-external-evidence-inbox-manifest.json"),
    (Copy-ProbeFile (Join-Path $acceptedBundlePath "production-handoff-owner-unblock-pack-manifest.json") "accepted-owner-unblock-pack-manifest.json"),
    (Copy-ProbeFile (Join-Path $acceptedBundlePath "production-handoff-owner-unblock-pack.md") "accepted-owner-unblock-pack.md"),
    (Copy-ProbeFile (Join-Path $acceptedBundlePath "production-handoff-owner-unblock-pack\owner-unblock-summary.json") "accepted-owner-unblock-summary.json")
)

$defaultBoundaryPreserved = $defaultOwnerUnblockPack.status -eq "PASS" -and
    $defaultOwnerUnblockPack.ownerUnblockStatus -eq "BLOCKED_EXTERNAL_OWNER_INPUT" -and
    [int]$defaultOwnerUnblockPack.missingOwnerContactCount -eq [int]$defaultContactReadiness.missingOwnerContactCount -and
    [int]$defaultOwnerUnblockPack.missingRequiredFileCount -eq [int]$defaultInbox.missingRequiredFileCount -and
    [int]$defaultOwnerUnblockPack.blockedSendCount -eq [int]$defaultSendReadiness.blockedSendCount -and
    [int]$defaultOwnerUnblockPack.readySendCount -eq 0 -and
    -not [bool]$defaultOwnerUnblockPack.realHostProjectEvidenceAccepted -and
    -not [bool]$defaultOwnerUnblockPack.externalEvidenceAccepted

$acceptedContactsReady = $acceptedContactReadiness.status -eq "PASS" -and
    [int]$acceptedContactReadiness.missingOwnerContactCount -eq 0 -and
    [int]$acceptedContactReadiness.configuredOwnerContactCount -eq [int]$acceptedContactReadiness.ownerContactCount -and
    [bool]$acceptedContactReadiness.contactRosterComplete -and
    -not [bool]$acceptedContactReadiness.automaticEmailSendReady

$acceptedSendReady = $acceptedSendReadiness.status -eq "PASS" -and
    $acceptedSendReadiness.sendReadinessStatus -eq "READY_FOR_CONFIRMATION" -and
    [int]$acceptedSendReadiness.readySendCount -eq [int]$acceptedSendReadiness.ownerContactCount -and
    [int]$acceptedSendReadiness.blockedSendCount -eq 0 -and
    -not [bool]$acceptedSendReadiness.automaticEmailSendReady -and
    -not [bool]$acceptedSendReadiness.mailAuthorizationCheckedByPipeline

$acceptedInboxComplete = $acceptedInbox.status -eq "PASS" -and
    [int]$acceptedInbox.missingRequiredFileCount -eq 0 -and
    [int]$acceptedInbox.completeAreaCount -eq [int]$acceptedInbox.evidenceAreaCount -and
    [bool]$acceptedInbox.externalEvidenceCollectionComplete -and
    -not [bool]$acceptedInbox.realHostProjectEvidenceAccepted -and
    -not [bool]$acceptedInbox.externalEvidenceAccepted

$acceptedOwnerUnblockReady = $acceptedOwnerUnblockPack.status -eq "PASS" -and
    $acceptedOwnerUnblockPack.ownerUnblockStatus -eq "READY_FOR_CONFIRMATION_PENDING_REAL_ACCEPTANCE" -and
    [int]$acceptedOwnerUnblockPack.missingOwnerContactCount -eq 0 -and
    [int]$acceptedOwnerUnblockPack.missingRequiredFileCount -eq 0 -and
    [int]$acceptedOwnerUnblockPack.blockedSendCount -eq 0 -and
    [int]$acceptedOwnerUnblockPack.readySendCount -eq [int]$acceptedOwnerUnblockPack.ownerPacketCount -and
    $acceptedOwnerUnblockPack.sendReadinessStatus -eq "READY_FOR_CONFIRMATION" -and
    $acceptedOwnerUnblockPack.mailAuthReadinessStatus -eq "BLOCKED_NOT_CHECKED_BY_RELEASE_PIPELINE" -and
    -not [bool]$acceptedOwnerUnblockPack.automaticEmailSendReady -and
    -not [bool]$acceptedOwnerUnblockPack.mailAuthorizationCheckedByPipeline -and
    [bool]$acceptedOwnerUnblockPack.externalEvidenceCollectionComplete -and
    -not [bool]$acceptedOwnerUnblockPack.realHostProjectEvidenceAccepted -and
    -not [bool]$acceptedOwnerUnblockPack.externalEvidenceAccepted

$mailAuthBoundaryPreserved = $acceptedMailAuthReadiness.status -eq "PASS" -and
    $acceptedMailAuthReadiness.mailAuthReadinessStatus -eq "BLOCKED_NOT_CHECKED_BY_RELEASE_PIPELINE" -and
    -not [bool]$acceptedMailAuthReadiness.mailAuthorizationCheckedByPipeline -and
    [bool]$acceptedMailAuthReadiness.pipelineDoesNotRunOAuthLogin -and
    -not [bool]$acceptedMailAuthReadiness.automaticEmailSendReady

$checks = @()
Add-ProbeCheck "default_owner_unblock_boundary" `
    $defaultBoundaryPreserved `
    "Default owner unblock pack must preserve missing contacts, missing returned evidence, blocked sends, and non-real evidence boundaries."
Add-ProbeCheck "accepted_fixture_contacts_ready" `
    ($acceptedContactsReady -and $acceptedSendReady) `
    "Accepted fixture contact roster must make owner sends ready for confirmation without sending email."
Add-ProbeCheck "accepted_fixture_inbox_complete" `
    $acceptedInboxComplete `
    "Accepted fixture returned evidence must fill every inbox area without claiming real host-project evidence."
Add-ProbeCheck "accepted_owner_unblock_pack_ready" `
    $acceptedOwnerUnblockReady `
    "Owner unblock pack must enter the ready-for-confirmation pending-real-acceptance state when fixture contacts and files are complete."
Add-ProbeCheck "mail_auth_boundary_preserved" `
    $mailAuthBoundaryPreserved `
    "Accepted fixture readiness must still require local agently-cli authorization outside the release pipeline."
Add-ProbeCheck "fixture_boundary_preserved" `
    (-not [bool]$acceptedOwnerUnblockPack.realHostProjectEvidenceAccepted -and -not [bool]$acceptedOwnerUnblockPack.externalEvidenceAccepted -and -not [bool]$acceptedOwnerUnblockPack.releasePipelineUsesFixture -and -not [bool]$acceptedOwnerUnblockPack.fixtureEvidencePromoted) `
    "Accepted fixture unblock proof must not promote fixture data as real host-project evidence."

$reportLines = @(
    "# AI TestPilot Production Handoff Owner Unblock Pack Contract Probe",
    "",
    "Schema: ``aitestpilot.production_handoff_owner_unblock_pack_contract_probe.v1``",
    "Generated at UTC: $((Get-Date).ToUniversalTime().ToString("O"))",
    "",
    "## Summary",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Default owner unblock status | $($defaultOwnerUnblockPack.ownerUnblockStatus) |",
    "| Default missing contacts | $([int]$defaultOwnerUnblockPack.missingOwnerContactCount) |",
    "| Default missing evidence files | $([int]$defaultOwnerUnblockPack.missingRequiredFileCount) |",
    "| Accepted owner unblock status | $($acceptedOwnerUnblockPack.ownerUnblockStatus) |",
    "| Accepted ready sends | $([int]$acceptedOwnerUnblockPack.readySendCount) |",
    "| Accepted missing contacts | $([int]$acceptedOwnerUnblockPack.missingOwnerContactCount) |",
    "| Accepted missing evidence files | $([int]$acceptedOwnerUnblockPack.missingRequiredFileCount) |",
    "| Accepted mail auth readiness | $($acceptedOwnerUnblockPack.mailAuthReadinessStatus) |",
    "",
    "## Boundary",
    "",
    "- Accepted contacts use ``example.invalid`` fixture addresses.",
    "- Accepted returned evidence is copied from contract fixtures.",
    "- This probe does not run OAuth login and does not send email.",
    "- Real host-project evidence remains unaccepted."
)
$reportLines | Set-Content -Path $reportFullPath -Encoding UTF8

$reportContent = Get-Content -Path $reportFullPath -Encoding UTF8 -Raw
$reportContentValidated = $reportContent.Contains("Owner Unblock Pack Contract Probe") -and
    $reportContent.Contains("READY_FOR_CONFIRMATION_PENDING_REAL_ACCEPTANCE") -and
    $reportContent.Contains("Real host-project evidence remains unaccepted") -and
    -not $reportContent.Contains("System.Collections") -and
    -not $reportContent.Contains([char]7)

Add-ProbeCheck "contract_probe_report_content" `
    $reportContentValidated `
    "Owner unblock pack contract probe must generate a readable boundary report."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestFullPath),
    (Convert-ToEvidenceRelativePath $reportFullPath)
)
foreach ($filePath in $acceptedCopiedFiles) {
    $generatedFiles += (Convert-ToEvidenceRelativePath $filePath)
}

$sourceFiles = @(
    "production-handoff-owner-unblock-pack-manifest.json",
    "production-handoff-contact-readiness-manifest.json",
    "production-handoff-send-readiness-manifest.json",
    "production-handoff-mail-auth-readiness-manifest.json",
    "production-external-evidence-inbox-manifest.json",
    "production-driver-evidence-contract-probe-manifest.json",
    "production-lua-patch-evidence-kit-probe-manifest.json",
    "live-model-endpoint-smoke-evidence-contract-probe-manifest.json"
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_owner_unblock_pack_contract_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    probeBundleDir = $probeBundlePath
    acceptedBundleDir = $acceptedBundlePath
    reportPath = $reportFullPath
    defaultOwnerUnblockStatus = [string]$defaultOwnerUnblockPack.ownerUnblockStatus
    defaultMissingOwnerContactCount = [int]$defaultOwnerUnblockPack.missingOwnerContactCount
    defaultMissingRequiredFileCount = [int]$defaultOwnerUnblockPack.missingRequiredFileCount
    defaultBlockedSendCount = [int]$defaultOwnerUnblockPack.blockedSendCount
    defaultReadySendCount = [int]$defaultOwnerUnblockPack.readySendCount
    acceptedOwnerUnblockPackPassed = [bool]$acceptedOwnerUnblockReady
    acceptedOwnerUnblockStatus = [string]$acceptedOwnerUnblockPack.ownerUnblockStatus
    acceptedContactsReady = [bool]$acceptedContactsReady
    acceptedSendReadyForConfirmation = [bool]$acceptedSendReady
    acceptedInboxComplete = [bool]$acceptedInboxComplete
    acceptedMissingOwnerContactCount = [int]$acceptedOwnerUnblockPack.missingOwnerContactCount
    acceptedMissingRequiredFileCount = [int]$acceptedOwnerUnblockPack.missingRequiredFileCount
    acceptedBlockedSendCount = [int]$acceptedOwnerUnblockPack.blockedSendCount
    acceptedReadySendCount = [int]$acceptedOwnerUnblockPack.readySendCount
    acceptedSendReadinessStatus = [string]$acceptedOwnerUnblockPack.sendReadinessStatus
    acceptedMailAuthReadinessStatus = [string]$acceptedOwnerUnblockPack.mailAuthReadinessStatus
    acceptedExternalEvidenceCollectionComplete = [bool]$acceptedOwnerUnblockPack.externalEvidenceCollectionComplete
    acceptedRealHostProjectEvidenceAccepted = [bool]$acceptedOwnerUnblockPack.realHostProjectEvidenceAccepted
    acceptedExternalEvidenceAccepted = [bool]$acceptedOwnerUnblockPack.externalEvidenceAccepted
    acceptedAutomaticEmailSendReady = [bool]$acceptedOwnerUnblockPack.automaticEmailSendReady
    acceptedMailAuthorizationCheckedByPipeline = [bool]$acceptedOwnerUnblockPack.mailAuthorizationCheckedByPipeline
    acceptedReleasePipelineUsesFixture = [bool]$acceptedOwnerUnblockPack.releasePipelineUsesFixture
    acceptedFixtureEvidencePromoted = [bool]$acceptedOwnerUnblockPack.fixtureEvidencePromoted
    mailAuthBoundaryPreserved = [bool]$mailAuthBoundaryPreserved
    releasePipelineUsesFixture = $false
    realHostProjectEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "accepted_fixture_owner_unblock_pack_contract_only"
    sourceFiles = @($sourceFiles)
    generatedFiles = @($generatedFiles)
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
    files = @($generatedFiles + $sourceFiles)
}

New-Item -ItemType Directory -Force (Split-Path $manifestFullPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestFullPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Production handoff owner unblock pack contract probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production handoff owner unblock pack contract probe manifest: $manifestFullPath"
Write-Output "Production handoff owner unblock pack contract probe report: $reportFullPath"
Write-Output "PASS AI TestPilot production handoff owner unblock pack contract probe"
