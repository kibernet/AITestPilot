[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ProbeDir,
    [string]$ExternalResponseBundleDir,
    [string]$IntakeBundleDir,
    [string]$ManifestPath,
    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ProbeDir)) {
    $ProbeDir = Join-Path $EvidenceBundleDir "production-handoff-owner-response-bundle-probe"
}

if ([string]::IsNullOrWhiteSpace($ExternalResponseBundleDir)) {
    $ExternalResponseBundleDir = Join-Path $env:TEMP "AITestPilot\owner-response-bundle-probe"
}

if ([string]::IsNullOrWhiteSpace($IntakeBundleDir)) {
    $IntakeBundleDir = Join-Path $repoRoot "Temp\release-evidence\owner-response-bundle-probe-intake"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-handoff-owner-response-bundle-probe-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-handoff-owner-response-bundle-probe.md"
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

    $tempRoot = Resolve-FullPath $env:TEMP
    $fullPath = Resolve-FullPath $Path
    if (-not (Test-PathWithinRoot $fullPath $tempRoot)) {
        throw "$Label must stay under temp root: $fullPath"
    }

    return $fullPath
}

function Convert-ToEvidenceRelativePath {
    param([string]$Path)

    $fullPath = Resolve-FullPath $Path
    if (-not (Test-PathWithinRoot $fullPath $evidenceBundlePath)) {
        throw "Generated file must stay under evidence bundle: $fullPath"
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

function Convert-ToBool {
    param([object]$Value)

    if ($null -eq $Value) {
        return $false
    }

    return [bool]$Value
}

function Convert-ToInt {
    param([object]$Value)

    if ($null -eq $Value) {
        return 0
    }

    return [int]$Value
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

function Format-MarkdownCell {
    param([object]$Value)

    if ($null -eq $Value) {
        return "(none)"
    }

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return "(none)"
    }

    return $text.Replace("`r", " ").Replace("`n", " ").Replace("|", "\|")
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

function Get-DirectoryFileCount {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return 0
    }

    return [int]@(Get-ChildItem -LiteralPath $Path -Recurse -File).Count
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
$probePath = Assert-PathUnderRepo $ProbeDir "ProbeDir"
$externalResponseBundlePath = Assert-PathUnderTemp $ExternalResponseBundleDir "ExternalResponseBundleDir"
$intakeBundlePath = Assert-PathUnderRepo $IntakeBundleDir "IntakeBundleDir"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if (Test-Path $probePath) {
    Remove-Item -LiteralPath $probePath -Recurse -Force
}
if (Test-Path $externalResponseBundlePath) {
    Remove-Item -LiteralPath $externalResponseBundlePath -Recurse -Force
}
if (Test-Path $intakeBundlePath) {
    Remove-Item -LiteralPath $intakeBundlePath -Recurse -Force
}

New-Item -ItemType Directory -Force $probePath | Out-Null
New-Item -ItemType Directory -Force $externalResponseBundlePath | Out-Null
New-Item -ItemType Directory -Force $intakeBundlePath | Out-Null

$ownerInputRequest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-owner-input-request-pack-manifest.json") "Production handoff owner input request pack manifest"
$defaultOwnerUnblockPack = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-owner-unblock-pack-manifest.json") "Production handoff owner unblock pack manifest"
$defaultContactReadiness = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-contact-readiness-manifest.json") "Production handoff contact readiness manifest"
$defaultSendReadiness = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-send-readiness-manifest.json") "Production handoff send readiness manifest"
$defaultInbox = Read-JsonFile (Join-Path $evidenceBundlePath "production-external-evidence-inbox-manifest.json") "Production external evidence inbox manifest"
$ownerUnblockContractProbe = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-owner-unblock-pack-contract-probe-manifest.json") "Production handoff owner unblock pack contract probe manifest"
$sendDryRunProbe = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-send-dry-run-probe-manifest.json") "Production handoff send dry-run probe manifest"
$driverContract = Read-JsonFile (Join-Path $evidenceBundlePath "production-driver-evidence-contract-probe-manifest.json") "Production driver evidence contract probe manifest"
$luaContract = Read-JsonFile (Join-Path $evidenceBundlePath "production-lua-patch-evidence-kit-probe-manifest.json") "Production Lua patch evidence kit probe manifest"
$liveContract = Read-JsonFile (Join-Path $evidenceBundlePath "live-model-endpoint-smoke-evidence-contract-probe-manifest.json") "Live model endpoint smoke evidence contract probe manifest"

$ownerInputs = @(Convert-ToArray (Get-JsonValue $ownerInputRequest "ownerInputs" @()))
$ownerContactCount = Convert-ToInt (Get-JsonValue $ownerInputRequest "ownerActionCount" 0)
$missingOwnerContactCount = Convert-ToInt (Get-JsonValue $ownerInputRequest "missingOwnerContactCount" 0)
$missingRequiredFileCount = Convert-ToInt (Get-JsonValue $ownerInputRequest "missingRequiredFileCount" 0)

$rosterEntries = @()
foreach ($item in $ownerInputs) {
    $owner = [string](Get-JsonValue $item "owner" "")
    $area = [string](Get-JsonValue $item "area" "")
    $slug = Convert-ToSlug $owner
    $rosterEntries += [ordered]@{
        owner = $owner
        area = $area
        contactSlug = $slug
        emailAddress = ($slug + "@example.invalid")
        configured = $true
        notes = "Owner response bundle contract fixture address. Replace with the real owner mailbox before live dispatch."
    }
}

$responseRosterPath = Join-Path $externalResponseBundlePath "owner-contact-roster.json"
$responseRoster = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_contact_roster.v1"
    status = "CONTACTS_CONFIGURED"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    ownerContactCount = [int]$rosterEntries.Count
    configuredContactCount = [int]$rosterEntries.Count
    fixtureOnly = $true
    entries = @($rosterEntries)
}
$responseRoster | ConvertTo-Json -Depth 12 | Set-Content -Path $responseRosterPath -Encoding UTF8

$driverFiles = @(
    "production-replay-integration-checklist.json",
    "repair-retest-manifest.json",
    "repair-driver-failure-manifest.json",
    "replay-profile-import-manifest.json"
)
$luaFiles = @(
    "production-lua-patch-evidence.json",
    "production-lua-patch-retest-template.md",
    "production-lua-patch-rollback-plan-template.md"
)
$liveFiles = @(
    "live-model-endpoint-smoke-manifest.json",
    "live-model-endpoint-decision-trace.json"
)

$driverSourceDir = Resolve-FullPath ([string](Get-JsonValue $driverContract "acceptedFixtureBundleDir" ""))
$luaSourceDir = Join-Path (Resolve-FullPath ([string](Get-JsonValue $luaContract "probeBundleDir" ""))) "accepted-fixture-evidence"
$liveSourceDir = Resolve-FullPath ([string](Get-JsonValue $liveContract "externalBundleDir" ""))

Copy-RequiredFiles $driverSourceDir (Join-Path $externalResponseBundlePath "production-driver-evidence") $driverFiles "Production driver accepted fixture"
Copy-RequiredFiles $luaSourceDir (Join-Path $externalResponseBundlePath "production-lua-evidence") $luaFiles "Production Lua accepted fixture"
Copy-RequiredFiles $liveSourceDir (Join-Path $externalResponseBundlePath "live-smoke-evidence") $liveFiles "Live smoke accepted fixture"

$responseReadmePath = Join-Path $externalResponseBundlePath "README.md"
$responseManifestPath = Join-Path $externalResponseBundlePath "owner-response-bundle-manifest.json"
$totalRequiredFileCount = [int]($driverFiles.Count + $luaFiles.Count + $liveFiles.Count)
$responseReadmeLines = @(
    "# AI TestPilot Owner Response Bundle",
    "",
    "This directory is the single owner-return format for production handoff inputs.",
    "",
    "Expected files:",
    "",
    "- `owner-contact-roster.json`: real owner mailbox entries.",
    "- `production-driver-evidence/`: production driver binding evidence.",
    "- `production-lua-evidence/`: production Lua patch evidence.",
    "- `live-smoke-evidence/`: live model endpoint smoke evidence.",
    "",
    "This probe-generated bundle uses contract fixtures only. Replace every fixture file with host-project evidence before production acceptance."
)
$responseReadmeLines | Set-Content -Path $responseReadmePath -Encoding UTF8

$responseBundleManifest = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_owner_response_bundle.v1"
    status = "COMPLETE_CONTRACT_FIXTURE"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    ownerContactCount = [int]$rosterEntries.Count
    configuredContactCount = [int]$rosterEntries.Count
    requiredEvidenceFileCount = [int]$totalRequiredFileCount
    presentEvidenceFileCount = [int](Get-DirectoryFileCount $externalResponseBundlePath)
    fixtureOnly = $true
    productionOutputBoundary = "owner_response_bundle_contract_fixture_only"
    directories = @(
        "production-driver-evidence",
        "production-lua-evidence",
        "live-smoke-evidence"
    )
}
$responseBundleManifest | ConvertTo-Json -Depth 8 | Set-Content -Path $responseManifestPath -Encoding UTF8

Get-ChildItem -LiteralPath $evidenceBundlePath -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $intakeBundlePath -Recurse -Force
}

$importedRosterPath = Join-Path $intakeBundlePath "production-handoff-contact-roster.json"
Copy-Item -LiteralPath $responseRosterPath -Destination $importedRosterPath -Force

$importedInboxPath = Join-Path $intakeBundlePath "production-external-evidence-inbox"
Copy-RequiredFiles (Join-Path $externalResponseBundlePath "production-driver-evidence") (Join-Path $importedInboxPath "production-driver-evidence") $driverFiles "Owner response production driver evidence"
Copy-RequiredFiles (Join-Path $externalResponseBundlePath "production-lua-evidence") (Join-Path $importedInboxPath "production-lua-evidence") $luaFiles "Owner response production Lua evidence"
Copy-RequiredFiles (Join-Path $externalResponseBundlePath "live-smoke-evidence") (Join-Path $importedInboxPath "live-smoke-evidence") $liveFiles "Owner response live smoke evidence"

& (Join-Path $PSScriptRoot "Invoke-AITestPilotProductionHandoffContactReadiness.ps1") `
    -EvidenceBundleDir $intakeBundlePath `
    -ContactRosterPath $importedRosterPath | Out-Null

& (Join-Path $PSScriptRoot "Invoke-AITestPilotProductionHandoffSendReadiness.ps1") `
    -EvidenceBundleDir $intakeBundlePath | Out-Null

& (Join-Path $PSScriptRoot "Invoke-AITestPilotProductionExternalEvidenceInbox.ps1") `
    -EvidenceBundleDir $intakeBundlePath `
    -InboxDir $importedInboxPath | Out-Null

& (Join-Path $PSScriptRoot "Invoke-AITestPilotProductionHandoffOwnerUnblockPack.ps1") `
    -EvidenceBundleDir $intakeBundlePath | Out-Null

$sendDryRunOutputPath = Join-Path $probePath "accepted-owner-response-send-dry-run.txt"
$sendHelperPath = Join-Path $intakeBundlePath "production-handoff-send\send-owner-packets.ps1"
& $sendHelperPath -EvidenceBundleDir $intakeBundlePath | Set-Content -Path $sendDryRunOutputPath -Encoding UTF8

$acceptedContactReadiness = Read-JsonFile (Join-Path $intakeBundlePath "production-handoff-contact-readiness-manifest.json") "Accepted owner response contact readiness manifest"
$acceptedSendReadiness = Read-JsonFile (Join-Path $intakeBundlePath "production-handoff-send-readiness-manifest.json") "Accepted owner response send readiness manifest"
$acceptedInbox = Read-JsonFile (Join-Path $intakeBundlePath "production-external-evidence-inbox-manifest.json") "Accepted owner response external evidence inbox manifest"
$acceptedOwnerUnblockPack = Read-JsonFile (Join-Path $intakeBundlePath "production-handoff-owner-unblock-pack-manifest.json") "Accepted owner response owner unblock pack manifest"

$sendDryRunOutput = Get-Content -Path $sendDryRunOutputPath -Encoding UTF8 -Raw
$preparedPreviewCount = [int]@($sendDryRunOutput -split "`r?`n" | Where-Object { $_ -like "Prepared send command for *" }).Count
$blockedPreviewCount = [int]@($sendDryRunOutput -split "`r?`n" | Where-Object { $_ -like "Blocked send command for *" }).Count

$externalBundleOutsideRepo = -not (Test-PathWithinRoot $externalResponseBundlePath $repoRoot)
$externalBundleComplete = (Test-Path $responseRosterPath) -and
    (Test-Path $responseManifestPath) -and
    [int]$responseBundleManifest.ownerContactCount -eq $ownerContactCount -and
    [int]$responseBundleManifest.requiredEvidenceFileCount -eq $missingRequiredFileCount -and
    (Get-DirectoryFileCount (Join-Path $externalResponseBundlePath "production-driver-evidence")) -eq $driverFiles.Count -and
    (Get-DirectoryFileCount (Join-Path $externalResponseBundlePath "production-lua-evidence")) -eq $luaFiles.Count -and
    (Get-DirectoryFileCount (Join-Path $externalResponseBundlePath "live-smoke-evidence")) -eq $liveFiles.Count

$defaultBoundaryPreserved = $defaultOwnerUnblockPack.status -eq "PASS" -and
    (Get-JsonValue $defaultOwnerUnblockPack "ownerUnblockStatus" "") -eq "BLOCKED_EXTERNAL_OWNER_INPUT" -and
    (Convert-ToInt (Get-JsonValue $defaultContactReadiness "missingOwnerContactCount" -1)) -eq $missingOwnerContactCount -and
    (Convert-ToInt (Get-JsonValue $defaultSendReadiness "blockedSendCount" -1)) -eq $missingOwnerContactCount -and
    (Convert-ToInt (Get-JsonValue $defaultInbox "missingRequiredFileCount" -1)) -eq $missingRequiredFileCount

$ownerResponseContactsAccepted = $acceptedContactReadiness.status -eq "PASS" -and
    (Convert-ToInt (Get-JsonValue $acceptedContactReadiness "missingOwnerContactCount" -1)) -eq 0 -and
    (Convert-ToInt (Get-JsonValue $acceptedContactReadiness "configuredOwnerContactCount" -1)) -eq $ownerContactCount -and
    (Convert-ToBool (Get-JsonValue $acceptedContactReadiness "contactRosterComplete" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $acceptedContactReadiness "automaticEmailSendReady" $true))

$ownerResponseSendReady = $acceptedSendReadiness.status -eq "PASS" -and
    (Get-JsonValue $acceptedSendReadiness "sendReadinessStatus" "") -eq "READY_FOR_CONFIRMATION" -and
    (Convert-ToInt (Get-JsonValue $acceptedSendReadiness "readySendCount" -1)) -eq $ownerContactCount -and
    (Convert-ToInt (Get-JsonValue $acceptedSendReadiness "blockedSendCount" -1)) -eq 0 -and
    -not (Convert-ToBool (Get-JsonValue $acceptedSendReadiness "automaticEmailSendReady" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $acceptedSendReadiness "mailAuthorizationCheckedByPipeline" $true)) -and
    (Convert-ToBool (Get-JsonValue $acceptedSendReadiness "twoStageConfirmationRequired" $false))

$ownerResponseEvidenceComplete = $acceptedInbox.status -eq "PASS" -and
    (Convert-ToInt (Get-JsonValue $acceptedInbox "missingRequiredFileCount" -1)) -eq 0 -and
    (Convert-ToInt (Get-JsonValue $acceptedInbox "completeAreaCount" -1)) -eq (Convert-ToInt (Get-JsonValue $acceptedInbox "evidenceAreaCount" -2)) -and
    (Convert-ToBool (Get-JsonValue $acceptedInbox "externalEvidenceCollectionComplete" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $acceptedInbox "realHostProjectEvidenceAccepted" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $acceptedInbox "externalEvidenceAccepted" $true))

$ownerResponseReadyForConfirmation = $acceptedOwnerUnblockPack.status -eq "PASS" -and
    (Get-JsonValue $acceptedOwnerUnblockPack "ownerUnblockStatus" "") -eq "READY_FOR_CONFIRMATION_PENDING_REAL_ACCEPTANCE" -and
    (Convert-ToInt (Get-JsonValue $acceptedOwnerUnblockPack "missingOwnerContactCount" -1)) -eq 0 -and
    (Convert-ToInt (Get-JsonValue $acceptedOwnerUnblockPack "missingRequiredFileCount" -1)) -eq 0 -and
    (Convert-ToInt (Get-JsonValue $acceptedOwnerUnblockPack "blockedSendCount" -1)) -eq 0 -and
    (Convert-ToInt (Get-JsonValue $acceptedOwnerUnblockPack "readySendCount" -1)) -eq $ownerContactCount -and
    -not (Convert-ToBool (Get-JsonValue $acceptedOwnerUnblockPack "automaticEmailSendReady" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $acceptedOwnerUnblockPack "mailAuthorizationCheckedByPipeline" $true))

$dryRunPreparedWithoutAuth = $preparedPreviewCount -eq $ownerContactCount -and
    $blockedPreviewCount -eq 0 -and
    $sendDryRunOutput.Contains("Dry run only") -and
    -not $sendDryRunOutput.Contains("ctk_")

$mailAndEvidenceBoundariesPreserved = -not (Convert-ToBool (Get-JsonValue $acceptedOwnerUnblockPack "releasePipelineSendsEmail" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $acceptedOwnerUnblockPack "emailSent" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $acceptedOwnerUnblockPack "confirmationTokenCreated" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $acceptedOwnerUnblockPack "mailAuthorizationCheckedByPipeline" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $acceptedOwnerUnblockPack "realHostProjectEvidenceAccepted" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $acceptedOwnerUnblockPack "externalEvidenceAccepted" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $acceptedOwnerUnblockPack "releasePipelineUsesFixture" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $acceptedOwnerUnblockPack "fixtureEvidencePromoted" $true))

$snapshotPath = Join-Path $probePath "external-owner-response-bundle-snapshot"
Copy-Item -LiteralPath $externalResponseBundlePath -Destination $snapshotPath -Recurse -Force

$acceptedManifestSnapshotFiles = @(
    "production-handoff-contact-readiness-manifest.json",
    "production-handoff-send-readiness-manifest.json",
    "production-external-evidence-inbox-manifest.json",
    "production-handoff-owner-unblock-pack-manifest.json"
)
foreach ($fileName in $acceptedManifestSnapshotFiles) {
    Copy-Item -LiteralPath (Join-Path $intakeBundlePath $fileName) -Destination (Join-Path $probePath ("accepted-" + $fileName)) -Force
}

$reportLines = @(
    "# AI TestPilot Production Handoff Owner Response Bundle Probe",
    "",
    "Schema: ``aitestpilot.production_handoff_owner_response_bundle_probe.v1``",
    "Generated at UTC: $((Get-Date).ToUniversalTime().ToString("O"))",
    "",
    "## Summary",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| External bundle outside repo | $externalBundleOutsideRepo |",
    "| External bundle complete | $externalBundleComplete |",
    "| Contacts accepted | $ownerResponseContactsAccepted |",
    "| Send ready for confirmation | $ownerResponseSendReady |",
    "| Evidence complete | $ownerResponseEvidenceComplete |",
    "| Owner unblock ready for confirmation | $ownerResponseReadyForConfirmation |",
    "| Prepared dry-run previews | $preparedPreviewCount |",
    "| Blocked dry-run previews | $blockedPreviewCount |",
    "| Default missing contacts | $missingOwnerContactCount |",
    "| Default missing evidence files | $missingRequiredFileCount |",
    "",
    "## Boundary",
    "",
    "- The response bundle is a contract fixture outside the repository.",
    "- The imported bundle does not send email and does not create confirmation tokens.",
    "- Local agently-cli authorization and two-stage confirmation are still required for live sends.",
    "- Fixture files are not promoted as real host-project evidence.",
    "- Real production completion still requires owner-provided non-fixture evidence."
)
$reportLines | Set-Content -Path $reportFullPath -Encoding UTF8

$reportContent = Get-Content -Path $reportFullPath -Encoding UTF8 -Raw
$reportContentValidated = $reportContent.Contains("Owner Response Bundle Probe") -and
    $reportContent.Contains("Owner unblock ready for confirmation") -and
    $reportContent.Contains("does not send email") -and
    $reportContent.Contains("Fixture files are not promoted") -and
    -not $reportContent.Contains("System.Collections") -and
    -not $reportContent.Contains("@{")

$checks = @()
Add-ProbeCheck "external_owner_response_bundle_generated" `
    ($externalBundleOutsideRepo -and $externalBundleComplete) `
    "Probe must generate a complete owner response bundle outside the repository."
Add-ProbeCheck "default_owner_input_boundary_preserved" `
    $defaultBoundaryPreserved `
    "Default release bundle must remain blocked on missing contacts and returned evidence."
Add-ProbeCheck "owner_response_contacts_accepted" `
    $ownerResponseContactsAccepted `
    "Imported owner response bundle contacts must satisfy contact readiness."
Add-ProbeCheck "owner_response_send_ready" `
    $ownerResponseSendReady `
    "Imported owner response bundle contacts must move sends to ready-for-confirmation without sending email."
Add-ProbeCheck "owner_response_evidence_complete" `
    $ownerResponseEvidenceComplete `
    "Imported owner response bundle evidence must fill every returned-evidence inbox area without accepting real evidence."
Add-ProbeCheck "owner_response_unblock_ready" `
    $ownerResponseReadyForConfirmation `
    "Imported owner response bundle must move owner unblock state to ready-for-confirmation pending real acceptance."
Add-ProbeCheck "owner_response_dry_run_preview" `
    $dryRunPreparedWithoutAuth `
    "Imported owner response bundle must allow send dry-run previews without local mail authorization or confirmation tokens."
Add-ProbeCheck "mail_and_evidence_boundaries_preserved" `
    $mailAndEvidenceBoundariesPreserved `
    "Owner response bundle probe must not send email, check local mail auth, accept real evidence, or promote fixture data."
Add-ProbeCheck "probe_report_content" `
    $reportContentValidated `
    "Owner response bundle probe must generate a readable boundary report."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestFullPath),
    (Convert-ToEvidenceRelativePath $reportFullPath),
    (Convert-ToEvidenceRelativePath $sendDryRunOutputPath)
)
foreach ($file in @(Get-ChildItem -LiteralPath $snapshotPath -Recurse -File)) {
    $generatedFiles += (Convert-ToEvidenceRelativePath $file.FullName)
}
foreach ($fileName in $acceptedManifestSnapshotFiles) {
    $generatedFiles += (Convert-ToEvidenceRelativePath (Join-Path $probePath ("accepted-" + $fileName)))
}

$sourceFiles = @(
    "production-handoff-owner-input-request-pack-manifest.json",
    "production-handoff-owner-unblock-pack-manifest.json",
    "production-handoff-contact-readiness-manifest.json",
    "production-handoff-send-readiness-manifest.json",
    "production-external-evidence-inbox-manifest.json",
    "production-handoff-owner-unblock-pack-contract-probe-manifest.json",
    "production-handoff-send-dry-run-probe-manifest.json",
    "production-driver-evidence-contract-probe-manifest.json",
    "production-lua-patch-evidence-kit-probe-manifest.json",
    "live-model-endpoint-smoke-evidence-contract-probe-manifest.json"
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_owner_response_bundle_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    probeDir = $probePath
    externalResponseBundleDir = $externalResponseBundlePath
    externalResponseBundleOutsideRepo = [bool]$externalBundleOutsideRepo
    intakeBundleDir = $intakeBundlePath
    reportPath = $reportFullPath
    ownerContactCount = [int]$ownerContactCount
    defaultMissingOwnerContactCount = [int]$missingOwnerContactCount
    defaultMissingRequiredFileCount = [int]$missingRequiredFileCount
    defaultOwnerInputRequestStatus = [string](Get-JsonValue $ownerInputRequest "ownerInputRequestStatus" "")
    defaultOwnerUnblockStatus = [string](Get-JsonValue $defaultOwnerUnblockPack "ownerUnblockStatus" "")
    defaultBoundaryPreserved = [bool]$defaultBoundaryPreserved
    externalResponseBundleGenerated = (Test-Path $externalResponseBundlePath)
    externalResponseBundleComplete = [bool]$externalBundleComplete
    responseBundleRequiredEvidenceFileCount = [int]$totalRequiredFileCount
    responseBundlePresentEvidenceFileCount = [int]($driverFiles.Count + $luaFiles.Count + $liveFiles.Count)
    ownerResponseContactsAccepted = [bool]$ownerResponseContactsAccepted
    ownerResponseSendReadyForConfirmation = [bool]$ownerResponseSendReady
    ownerResponseEvidenceComplete = [bool]$ownerResponseEvidenceComplete
    ownerResponseReadyForConfirmation = [bool]$ownerResponseReadyForConfirmation
    acceptedOwnerUnblockStatus = [string](Get-JsonValue $acceptedOwnerUnblockPack "ownerUnblockStatus" "")
    acceptedMissingOwnerContactCount = Convert-ToInt (Get-JsonValue $acceptedOwnerUnblockPack "missingOwnerContactCount" 0)
    acceptedMissingRequiredFileCount = Convert-ToInt (Get-JsonValue $acceptedOwnerUnblockPack "missingRequiredFileCount" 0)
    acceptedBlockedSendCount = Convert-ToInt (Get-JsonValue $acceptedOwnerUnblockPack "blockedSendCount" 0)
    acceptedReadySendCount = Convert-ToInt (Get-JsonValue $acceptedOwnerUnblockPack "readySendCount" 0)
    acceptedExternalEvidenceCollectionComplete = Convert-ToBool (Get-JsonValue $acceptedOwnerUnblockPack "externalEvidenceCollectionComplete" $false)
    dryRunPreparedPreviewCount = [int]$preparedPreviewCount
    dryRunBlockedPreviewCount = [int]$blockedPreviewCount
    dryRunDoesNotCreateConfirmationToken = (-not $sendDryRunOutput.Contains("ctk_"))
    dryRunAuthorizationFree = [bool]$dryRunPreparedWithoutAuth
    ownerUnblockContractProbeAccepted = Convert-ToBool (Get-JsonValue $ownerUnblockContractProbe "acceptedOwnerUnblockPackPassed" $false)
    sourceSendDryRunProbeAccepted = Convert-ToBool (Get-JsonValue $sendDryRunProbe "acceptedContactDryRunSucceeded" $false)
    releasePipelineSendsEmail = $false
    emailSent = $false
    confirmationTokenCreated = $false
    automaticEmailSendReady = $false
    mailAuthorizationCheckedByPipeline = $false
    releasePipelineUsesFixture = $false
    realHostProjectEvidenceAccepted = $false
    externalEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    mailAndEvidenceBoundariesPreserved = [bool]$mailAndEvidenceBoundariesPreserved
    productionOutputBoundary = "owner_response_bundle_contract_fixture_only"
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
    throw "Production handoff owner response bundle probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production handoff owner response bundle probe manifest: $manifestFullPath"
Write-Output "Production handoff owner response bundle probe report: $reportFullPath"
Write-Output "PASS AI TestPilot production handoff owner response bundle probe"
