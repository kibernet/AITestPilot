[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ProbeDir,
    [string]$ManifestPath,
    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Test-PathWithinRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root)
    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    if ($fullPath.Equals($fullRoot, $comparison)) {
        return $true
    }

    if (-not $fullRoot.EndsWith(([System.IO.Path]::DirectorySeparatorChar).ToString())) {
        $fullRoot = $fullRoot + [System.IO.Path]::DirectorySeparatorChar
    }

    return $fullPath.StartsWith($fullRoot, $comparison)
}

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ProbeDir)) {
    $ProbeDir = Join-Path $EvidenceBundleDir "production-handoff-owner-contact-external-intake-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-handoff-owner-contact-external-intake-probe-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-handoff-owner-contact-external-intake-probe.md"
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
    if (-not (Test-PathWithinRoot $fullPath $repoRoot)) {
        throw "$Label must stay under repo root: $fullPath"
    }

    return $fullPath
}

function Convert-ToEvidenceRelativePath {
    param([string]$Path)

    $fullPath = Resolve-FullPath $Path
    if (-not $fullPath.StartsWith($evidenceBundlePath, [System.StringComparison]::OrdinalIgnoreCase)) {
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
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if (Test-Path $probePath) {
    Remove-Item -LiteralPath $probePath -Recurse -Force
}
New-Item -ItemType Directory -Force $probePath | Out-Null

$defaultContactReadiness = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-contact-readiness-manifest.json") "Default production handoff contact readiness manifest"
$defaultSendReadiness = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-send-readiness-manifest.json") "Default production handoff send readiness manifest"
$defaultOwnerInputRequest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-owner-input-request-pack-manifest.json") "Default production handoff owner input request pack manifest"
$dispatchManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-dispatch-manifest.json") "Production handoff dispatch manifest"

$externalRoot = Join-Path $env:TEMP "AITestPilot\owner-contact-external-intake-probe"
if (Test-Path $externalRoot) {
    Remove-Item -LiteralPath $externalRoot -Recurse -Force
}
New-Item -ItemType Directory -Force $externalRoot | Out-Null

$externalRosterEntries = @()
foreach ($entry in @(Convert-ToArray (Get-JsonValue $dispatchManifest "dispatchEntries" @()))) {
    $owner = [string](Get-JsonValue $entry "owner" "")
    $area = [string](Get-JsonValue $entry "area" "")
    $slug = Convert-ToSlug $owner
    $externalRosterEntries += [ordered]@{
        owner = $owner
        area = $area
        contactSlug = $slug
        emailAddress = ($slug + "@example.invalid")
        configured = $true
        notes = "Repo-external contract fixture address. Replace with the real owner mailbox before live dispatch."
    }
}

$externalRosterPath = Join-Path $externalRoot "external-owner-contact-roster.json"
$externalRoster = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_contact_roster.v1"
    status = "CONTACTS_CONFIGURED"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    ownerContactCount = [int]$externalRosterEntries.Count
    configuredContactCount = [int]$externalRosterEntries.Count
    fixtureOnly = $true
    entries = @($externalRosterEntries)
}
$externalRoster | ConvertTo-Json -Depth 12 | Set-Content -Path $externalRosterPath -Encoding UTF8

$intakeBundlePath = Join-Path $probePath "intake-bundle"
New-Item -ItemType Directory -Force $intakeBundlePath | Out-Null

Copy-Item -LiteralPath (Join-Path $evidenceBundlePath "production-handoff-dispatch-manifest.json") -Destination $intakeBundlePath -Force
Copy-Item -LiteralPath (Join-Path $evidenceBundlePath "production-handoff-status-manifest.json") -Destination $intakeBundlePath -Force
Copy-Item -LiteralPath (Join-Path $evidenceBundlePath "production-handoff-export-manifest.json") -Destination $intakeBundlePath -Force
Copy-Item -LiteralPath (Join-Path $evidenceBundlePath "production-handoff-contact-readiness-contract-probe-manifest.json") -Destination $intakeBundlePath -Force
Copy-Item -LiteralPath (Join-Path $evidenceBundlePath "production-handoff-export.zip") -Destination $intakeBundlePath -Force
Copy-Item -LiteralPath (Join-Path $evidenceBundlePath "production-handoff-dispatch") -Destination (Join-Path $intakeBundlePath "production-handoff-dispatch") -Recurse -Force
New-Item -ItemType Directory -Force (Join-Path $intakeBundlePath "production-handoff-package") | Out-Null
Copy-Item -LiteralPath (Join-Path $evidenceBundlePath "production-handoff-package\owner-packets") -Destination (Join-Path $intakeBundlePath "production-handoff-package\owner-packets") -Recurse -Force

$importedRosterPath = Join-Path $intakeBundlePath "production-handoff-contact-roster.json"
Copy-Item -LiteralPath $externalRosterPath -Destination $importedRosterPath -Force

& (Join-Path $PSScriptRoot "Invoke-AITestPilotProductionHandoffContactReadiness.ps1") `
    -EvidenceBundleDir $intakeBundlePath `
    -ContactRosterPath $importedRosterPath | Out-Null

& (Join-Path $PSScriptRoot "Invoke-AITestPilotProductionHandoffSendReadiness.ps1") `
    -EvidenceBundleDir $intakeBundlePath | Out-Null

$acceptedContactReadiness = Read-JsonFile (Join-Path $intakeBundlePath "production-handoff-contact-readiness-manifest.json") "Accepted external contact readiness manifest"
$acceptedSendReadiness = Read-JsonFile (Join-Path $intakeBundlePath "production-handoff-send-readiness-manifest.json") "Accepted external contact send readiness manifest"

$ownerContactCount = Convert-ToInt (Get-JsonValue $defaultContactReadiness "ownerContactCount" 0)
$externalRosterOutsideRepo = -not (Test-PathWithinRoot (Resolve-FullPath $externalRosterPath) $repoRoot)
$defaultContactBoundaryPreserved = $defaultContactReadiness.status -eq "PASS" -and
    (Convert-ToInt (Get-JsonValue $defaultContactReadiness "missingOwnerContactCount" -1)) -eq $ownerContactCount -and
    (Convert-ToInt (Get-JsonValue $defaultContactReadiness "configuredOwnerContactCount" -1)) -eq 0 -and
    -not (Convert-ToBool (Get-JsonValue $defaultContactReadiness "automaticEmailSendReady" $true))
$defaultSendBoundaryPreserved = $defaultSendReadiness.status -eq "PASS" -and
    (Get-JsonValue $defaultSendReadiness "sendReadinessStatus" "") -eq "BLOCKED_MISSING_OWNER_EMAILS" -and
    (Convert-ToInt (Get-JsonValue $defaultSendReadiness "blockedSendCount" -1)) -eq $ownerContactCount -and
    -not (Convert-ToBool (Get-JsonValue $defaultSendReadiness "automaticEmailSendReady" $true))
$defaultOwnerInputBoundaryPreserved = $defaultOwnerInputRequest.status -eq "PASS" -and
    (Get-JsonValue $defaultOwnerInputRequest "ownerInputRequestStatus" "") -eq "AWAITING_EXTERNAL_OWNER_INPUT" -and
    (Convert-ToInt (Get-JsonValue $defaultOwnerInputRequest "missingOwnerContactCount" -1)) -eq $ownerContactCount
$externalContactIntakeAccepted = $acceptedContactReadiness.status -eq "PASS" -and
    (Convert-ToInt (Get-JsonValue $acceptedContactReadiness "ownerContactCount" -1)) -eq $ownerContactCount -and
    (Convert-ToInt (Get-JsonValue $acceptedContactReadiness "configuredOwnerContactCount" -1)) -eq $ownerContactCount -and
    (Convert-ToInt (Get-JsonValue $acceptedContactReadiness "missingOwnerContactCount" -1)) -eq 0 -and
    (Convert-ToInt (Get-JsonValue $acceptedContactReadiness "invalidOwnerContactCount" -1)) -eq 0 -and
    (Convert-ToBool (Get-JsonValue $acceptedContactReadiness "contactRosterComplete" $false)) -and
    (Convert-ToBool (Get-JsonValue $acceptedContactReadiness "configuredContactsAccepted" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $acceptedContactReadiness "automaticEmailSendReady" $true))
$externalSendReadyForConfirmation = $acceptedSendReadiness.status -eq "PASS" -and
    (Get-JsonValue $acceptedSendReadiness "sendReadinessStatus" "") -eq "READY_FOR_CONFIRMATION" -and
    (Convert-ToInt (Get-JsonValue $acceptedSendReadiness "readySendCount" -1)) -eq $ownerContactCount -and
    (Convert-ToInt (Get-JsonValue $acceptedSendReadiness "blockedSendCount" -1)) -eq 0 -and
    -not (Convert-ToBool (Get-JsonValue $acceptedSendReadiness "automaticEmailSendReady" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $acceptedSendReadiness "mailAuthorizationCheckedByPipeline" $true)) -and
    (Convert-ToBool (Get-JsonValue $acceptedSendReadiness "twoStageConfirmationRequired" $false))
$mailAndEvidenceBoundariesPreserved = -not (Convert-ToBool (Get-JsonValue $acceptedSendReadiness "releasePipelineUsesFixture" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $acceptedSendReadiness "realHostProjectEvidenceAccepted" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $acceptedSendReadiness "fixtureEvidencePromoted" $true))

$reportLines = @(
    "# AI TestPilot Production Handoff Owner Contact External Intake Probe",
    "",
    "Schema: ``aitestpilot.production_handoff_owner_contact_external_intake_probe.v1``",
    "Generated at UTC: $((Get-Date).ToUniversalTime().ToString("O"))",
    "",
    "## Summary",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| External roster outside repo | $externalRosterOutsideRepo |",
    "| External contact intake accepted | $externalContactIntakeAccepted |",
    "| External send ready for confirmation | $externalSendReadyForConfirmation |",
    "| Default contact boundary preserved | $defaultContactBoundaryPreserved |",
    "| Default send boundary preserved | $defaultSendBoundaryPreserved |",
    "| Default owner input boundary preserved | $defaultOwnerInputBoundaryPreserved |",
    "| Accepted configured contacts | $(Convert-ToInt (Get-JsonValue $acceptedContactReadiness "configuredOwnerContactCount" 0)) |",
    "| Accepted ready sends | $(Convert-ToInt (Get-JsonValue $acceptedSendReadiness "readySendCount" 0)) |",
    "",
    "## Boundary",
    "",
    "- The repo-external roster uses ``example.invalid`` fixture addresses for contract proof.",
    "- The default release bundle still records missing real owner contacts.",
    "- Ready-for-confirmation does not mean sent.",
    "- Local agently-cli authorization and two-stage confirmation are still required before any email send.",
    "- Real host-project evidence is not accepted and fixture data is not promoted."
)
$reportLines | Set-Content -Path $reportFullPath -Encoding UTF8

$reportContent = Get-Content -Path $reportFullPath -Encoding UTF8 -Raw
$reportContentValidated = $reportContent.Contains("Owner Contact External Intake Probe") -and
    $reportContent.Contains("External send ready for confirmation") -and
    $reportContent.Contains("Ready-for-confirmation does not mean sent") -and
    $reportContent.Contains("two-stage confirmation") -and
    -not $reportContent.Contains("System.Collections") -and
    -not $reportContent.Contains("@{")

$checks = @()
Add-ProbeCheck "external_contact_roster_generated_outside_repo" `
    ((Test-Path $externalRosterPath) -and $externalRosterOutsideRepo -and (Convert-ToInt $externalRoster.ownerContactCount) -eq $ownerContactCount) `
    "Probe must start from a repo-external owner contact roster with one configured contact per owner."
Add-ProbeCheck "external_contact_roster_imported" `
    ((Test-Path $importedRosterPath) -and (Get-JsonValue (Read-JsonFile $importedRosterPath "Imported contact roster") "schemaVersion" "") -eq "aitestpilot.production_handoff_contact_roster.v1") `
    "Probe must import the repo-external roster into an isolated release bundle before validation."
Add-ProbeCheck "default_boundaries_preserved" `
    ($defaultContactBoundaryPreserved -and $defaultSendBoundaryPreserved -and $defaultOwnerInputBoundaryPreserved) `
    "Default release evidence must keep missing owner contacts, blocked sends, and awaiting-owner-input status."
Add-ProbeCheck "external_contact_intake_accepted" `
    $externalContactIntakeAccepted `
    "Imported owner contacts must pass contact readiness in the isolated intake bundle."
Add-ProbeCheck "external_send_ready_for_confirmation" `
    $externalSendReadyForConfirmation `
    "Imported owner contacts must move send readiness to ready-for-confirmation without sending email."
Add-ProbeCheck "mail_and_evidence_boundaries_preserved" `
    $mailAndEvidenceBoundariesPreserved `
    "External owner contact intake must not claim mail authorization, sent email, real evidence, or fixture promotion."
Add-ProbeCheck "probe_report_content" `
    $reportContentValidated `
    "Probe report must summarize external contact intake, send readiness, and send/evidence boundaries."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestFullPath),
    (Convert-ToEvidenceRelativePath $reportFullPath),
    (Convert-ToEvidenceRelativePath $importedRosterPath),
    (Convert-ToEvidenceRelativePath (Join-Path $intakeBundlePath "production-handoff-contact-readiness-manifest.json")),
    (Convert-ToEvidenceRelativePath (Join-Path $intakeBundlePath "production-handoff-contact-readiness.md")),
    (Convert-ToEvidenceRelativePath (Join-Path $intakeBundlePath "production-handoff-send-readiness-manifest.json")),
    (Convert-ToEvidenceRelativePath (Join-Path $intakeBundlePath "production-handoff-send-readiness.md")),
    (Convert-ToEvidenceRelativePath (Join-Path $intakeBundlePath "production-handoff-send\production-handoff-send-queue.json")),
    (Convert-ToEvidenceRelativePath (Join-Path $intakeBundlePath "production-handoff-send\send-owner-packets.ps1")),
    (Convert-ToEvidenceRelativePath (Join-Path $intakeBundlePath "production-handoff-send\README.md"))
)
$sourceFiles = @(
    "production-handoff-contact-readiness-manifest.json",
    "production-handoff-send-readiness-manifest.json",
    "production-handoff-owner-input-request-pack-manifest.json",
    "production-handoff-dispatch-manifest.json",
    "production-handoff-contact-readiness-contract-probe-manifest.json",
    "production-handoff-export-manifest.json",
    "production-handoff-export.zip"
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_owner_contact_external_intake_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    probeDir = $probePath
    reportPath = $reportFullPath
    externalRosterPath = $externalRosterPath
    externalRosterOutsideRepo = [bool]$externalRosterOutsideRepo
    importedRosterPath = $importedRosterPath
    intakeBundlePath = $intakeBundlePath
    ownerContactCount = [int]$ownerContactCount
    defaultMissingOwnerContactCount = Convert-ToInt (Get-JsonValue $defaultContactReadiness "missingOwnerContactCount" 0)
    defaultBlockedSendCount = Convert-ToInt (Get-JsonValue $defaultSendReadiness "blockedSendCount" 0)
    defaultOwnerInputRequestStatus = [string](Get-JsonValue $defaultOwnerInputRequest "ownerInputRequestStatus" "")
    defaultContactBoundaryPreserved = [bool]$defaultContactBoundaryPreserved
    defaultSendBoundaryPreserved = [bool]$defaultSendBoundaryPreserved
    defaultOwnerInputBoundaryPreserved = [bool]$defaultOwnerInputBoundaryPreserved
    externalContactIntakeAccepted = [bool]$externalContactIntakeAccepted
    acceptedConfiguredOwnerContactCount = Convert-ToInt (Get-JsonValue $acceptedContactReadiness "configuredOwnerContactCount" 0)
    acceptedMissingOwnerContactCount = Convert-ToInt (Get-JsonValue $acceptedContactReadiness "missingOwnerContactCount" 0)
    acceptedInvalidOwnerContactCount = Convert-ToInt (Get-JsonValue $acceptedContactReadiness "invalidOwnerContactCount" 0)
    acceptedContactRosterComplete = Convert-ToBool (Get-JsonValue $acceptedContactReadiness "contactRosterComplete" $false)
    externalSendReadyForConfirmation = [bool]$externalSendReadyForConfirmation
    acceptedSendReadinessStatus = [string](Get-JsonValue $acceptedSendReadiness "sendReadinessStatus" "")
    acceptedReadySendCount = Convert-ToInt (Get-JsonValue $acceptedSendReadiness "readySendCount" 0)
    acceptedBlockedSendCount = Convert-ToInt (Get-JsonValue $acceptedSendReadiness "blockedSendCount" 0)
    acceptedAutomaticEmailSendReady = Convert-ToBool (Get-JsonValue $acceptedSendReadiness "automaticEmailSendReady" $false)
    acceptedMailAuthorizationCheckedByPipeline = Convert-ToBool (Get-JsonValue $acceptedSendReadiness "mailAuthorizationCheckedByPipeline" $false)
    acceptedTwoStageConfirmationRequired = Convert-ToBool (Get-JsonValue $acceptedSendReadiness "twoStageConfirmationRequired" $false)
    mailAndEvidenceBoundariesPreserved = [bool]$mailAndEvidenceBoundariesPreserved
    fixtureOwnerContactRosterUsed = $true
    fixtureOwnerContactsPromoted = $false
    releasePipelineSendsEmail = $false
    emailSent = $false
    releasePipelineUsesFixture = $false
    realHostProjectEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "repo_external_owner_contact_intake_contract_only"
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
    throw "Production handoff owner contact external intake probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production handoff owner contact external intake probe manifest: $manifestFullPath"
Write-Output "Production handoff owner contact external intake probe report: $reportFullPath"
Write-Output "PASS AI TestPilot production handoff owner contact external intake probe"
