[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ContactRosterPath,
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

if ([string]::IsNullOrWhiteSpace($ContactRosterPath)) {
    $ContactRosterPath = Join-Path $EvidenceBundleDir "production-handoff-contact-roster.json"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-handoff-contact-readiness-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-handoff-contact-readiness.md"
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

function Convert-ToEvidenceRelativePath {
    param([string]$Path)

    $fullPath = Resolve-FullPath $Path
    if (-not $fullPath.StartsWith($evidenceBundlePath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Generated file must stay under evidence bundle: $fullPath"
    }

    $relativePath = $fullPath.Substring($evidenceBundlePath.Length).TrimStart([char[]]@("\", "/"))
    return $relativePath.Replace("\", "/")
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

function Test-EmailAddress {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    $trimmed = $Value.Trim()
    if ($trimmed -like "replace-with-*-email") {
        return $false
    }

    return [bool]($trimmed -match "^[^@\s]+@[^@\s]+\.[^@\s]+$")
}

function Add-ContactCheck {
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
$contactRosterFullPath = Assert-PathUnderRepo $ContactRosterPath "ContactRosterPath"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

$dispatchManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-dispatch-manifest.json") "Production handoff dispatch manifest"
$dispatchQueue = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-dispatch\production-handoff-dispatch-queue.json") "Production handoff dispatch queue"
$ownerPacketIndex = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-package\owner-packets\owner-packet-index.json") "Production handoff owner packet index"
$handoffStatusManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-status-manifest.json") "Production handoff status manifest"

if (-not (Test-Path $contactRosterFullPath)) {
    $templateEntries = @()
    foreach ($entry in @(Convert-ToArray (Get-JsonValue $dispatchManifest "dispatchEntries" @()))) {
        $owner = [string](Get-JsonValue $entry "owner" "")
        $area = [string](Get-JsonValue $entry "area" "")
        $templateEntries += [ordered]@{
            owner = $owner
            area = $area
            contactSlug = Convert-ToSlug $owner
            emailAddress = ""
            configured = $false
            notes = "Replace emailAddress with the real host-project owner mailbox before dispatch."
        }
    }

    $template = [ordered]@{
        schemaVersion = "aitestpilot.production_handoff_contact_roster.v1"
        status = "PENDING_CONTACTS"
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
        ownerContactCount = [int]$templateEntries.Count
        configuredContactCount = 0
        entries = @($templateEntries)
    }

    New-Item -ItemType Directory -Force (Split-Path $contactRosterFullPath -Parent) | Out-Null
    $template | ConvertTo-Json -Depth 12 | Set-Content -Path $contactRosterFullPath -Encoding UTF8
}

$contactRoster = Read-JsonFile $contactRosterFullPath "Production handoff contact roster"
$dispatchEntries = @(Convert-ToArray (Get-JsonValue $dispatchManifest "dispatchEntries" @()))
$rosterEntries = @(Convert-ToArray (Get-JsonValue $contactRoster "entries" @()))
$contactStatuses = @()

foreach ($dispatchEntry in $dispatchEntries) {
    $owner = [string](Get-JsonValue $dispatchEntry "owner" "")
    $area = [string](Get-JsonValue $dispatchEntry "area" "")
    $matchingEntries = @($rosterEntries | Where-Object {
            [string](Get-JsonValue $_ "owner" "") -eq $owner -and
            [string](Get-JsonValue $_ "area" "") -eq $area
        })
    $contactEntry = if ($matchingEntries.Count -gt 0) { $matchingEntries[0] } else { $null }
    $emailAddress = [string](Get-JsonValue $contactEntry "emailAddress" "")
    $emailValid = Test-EmailAddress $emailAddress
    $configured = [bool](Get-JsonValue $contactEntry "configured" $false) -and $emailValid
    $status = if ($configured) {
        "CONTACT_CONFIGURED"
    } elseif ([string]::IsNullOrWhiteSpace($emailAddress)) {
        "MISSING_OWNER_EMAIL"
    } else {
        "INVALID_OWNER_EMAIL"
    }

    $contactStatuses += [ordered]@{
        owner = $owner
        area = $area
        status = $status
        rosterEntryFound = $null -ne $contactEntry
        emailAddress = $emailAddress
        emailAddressValid = [bool]$emailValid
        configured = [bool]$configured
        dispatchDraftPath = [string](Get-JsonValue $dispatchEntry "draftPath" "")
        ownerPacketPath = [string](Get-JsonValue $dispatchEntry "ownerPacketPath" "")
        requiredEvidenceFileCount = [int]@(Convert-ToArray (Get-JsonValue $dispatchEntry "requiredEvidenceFiles" @())).Count
    }
}

$configuredContactCount = @($contactStatuses | Where-Object { [bool](Get-JsonValue $_ "configured" $false) }).Count
$missingContactCount = @($contactStatuses | Where-Object { [string](Get-JsonValue $_ "status" "") -eq "MISSING_OWNER_EMAIL" }).Count
$invalidContactCount = @($contactStatuses | Where-Object { [string](Get-JsonValue $_ "status" "") -eq "INVALID_OWNER_EMAIL" }).Count
$mappedOwnerContactCount = @($contactStatuses | Where-Object { [bool](Get-JsonValue $_ "rosterEntryFound" $false) }).Count
$ownerContactCount = [int]$contactStatuses.Count
$contactRosterComplete = $ownerContactCount -gt 0 -and $configuredContactCount -eq $ownerContactCount
$realOwnerEmailAddressesConfigured = [bool]$contactRosterComplete
$automaticEmailSendReady = $false
$defaultMissingContactsExplicit = $ownerContactCount -gt 0 -and
    $missingContactCount -eq $ownerContactCount -and
    $configuredContactCount -eq 0 -and
    $invalidContactCount -eq 0 -and
    -not $contactRosterComplete -and
    -not $realOwnerEmailAddressesConfigured
$configuredContactsAccepted = $ownerContactCount -gt 0 -and
    $configuredContactCount -eq $ownerContactCount -and
    $missingContactCount -eq 0 -and
    $invalidContactCount -eq 0 -and
    $contactRosterComplete -and
    $realOwnerEmailAddressesConfigured
$pendingDispatchCount = [int](Get-JsonValue $dispatchManifest "pendingDispatchCount" 0)
$pendingExternalEvidenceFileCount = [int](Get-JsonValue $dispatchManifest "pendingExternalEvidenceFileCount" 0)
$remainingBlockingReasonCount = [int](Get-JsonValue $handoffStatusManifest "remainingBlockingReasonCount" 0)

$reportLines = @(
    "# AI TestPilot Production Handoff Contact Readiness",
    "",
    "Schema: ``aitestpilot.production_handoff_contact_readiness.v1``",
    "Generated at UTC: $((Get-Date).ToUniversalTime().ToString("O"))",
    "",
    "## Summary",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Owner contacts | $ownerContactCount |",
    "| Configured contacts | $configuredContactCount |",
    "| Missing contacts | $missingContactCount |",
    "| Invalid contacts | $invalidContactCount |",
    "| Contact roster complete | $contactRosterComplete |",
    "| Automatic email send ready | $automaticEmailSendReady |",
    "| Pending dispatches | $pendingDispatchCount |",
    "| Pending external evidence files | $pendingExternalEvidenceFileCount |",
    "",
    "## Contacts",
    "",
    "| Owner | Area | Status | Configured | Draft |",
    "| --- | --- | --- | --- | --- |"
)

foreach ($contactStatus in $contactStatuses) {
    $owner = Format-MarkdownCell (Get-JsonValue $contactStatus "owner" "")
    $area = Format-MarkdownCell (Get-JsonValue $contactStatus "area" "")
    $status = Format-MarkdownCell (Get-JsonValue $contactStatus "status" "")
    $configured = Format-MarkdownCell (Get-JsonValue $contactStatus "configured" $false)
    $draft = Format-MarkdownCell (Get-JsonValue $contactStatus "dispatchDraftPath" "")
    $reportLines += "| $owner | $area | $status | $configured | $draft |"
}

$reportLines += @(
    "",
    "## Boundary",
    "",
    "- This readiness report validates the contact roster only.",
    "- It does not send owner emails.",
    "- Automatic dispatch stays blocked until real owner addresses are configured outside fixture evidence."
)

$reportText = [string]::Join([Environment]::NewLine, $reportLines) + [Environment]::NewLine
New-Item -ItemType Directory -Force (Split-Path $reportFullPath -Parent) | Out-Null
$reportText | Set-Content -Path $reportFullPath -Encoding UTF8

$reportContentValidated = $reportText.Contains("AI TestPilot Production Handoff Contact Readiness") -and
    ($reportText.Contains("MISSING_OWNER_EMAIL") -or $reportText.Contains("CONTACT_CONFIGURED")) -and
    $reportText.Contains("Automatic dispatch stays blocked") -and
    -not $reportText.Contains("System.Collections") -and
    -not $reportText.Contains("@{")

$checks = @()
Add-ContactCheck "handoff_sources_available" `
    ($dispatchManifest.status -eq "PASS" -and $dispatchQueue.status -eq "PASS" -and $ownerPacketIndex.status -eq "PASS" -and $handoffStatusManifest.status -eq "PASS") `
    "Contact readiness must be based on passing dispatch, owner packet, and handoff status evidence."
Add-ContactCheck "contact_roster_generated" `
    ((Test-Path $contactRosterFullPath) -and (Get-JsonValue $contactRoster "schemaVersion" "") -eq "aitestpilot.production_handoff_contact_roster.v1") `
    "Contact roster template must be generated or supplied with the expected schema."
Add-ContactCheck "owner_contact_mapping" `
    ($mappedOwnerContactCount -eq $ownerContactCount -and $ownerContactCount -eq [int](Get-JsonValue $ownerPacketIndex "ownerPacketCount" -1)) `
    "Every owner packet must have one contact roster entry."
Add-ContactCheck "contact_state_consistent" `
    ($defaultMissingContactsExplicit -or $configuredContactsAccepted) `
    "Contact roster must be internally consistent for either the default missing-contact state or a fully configured roster."
Add-ContactCheck "send_boundary_preserved" `
    (-not $automaticEmailSendReady -and $pendingDispatchCount -eq $ownerContactCount -and ($defaultMissingContactsExplicit -or $configuredContactsAccepted)) `
    "Automatic owner email send must stay blocked until a separate send step proves real contacts and mail authorization."
Add-ContactCheck "fixture_boundary_preserved" `
    (-not [bool](Get-JsonValue $handoffStatusManifest "realHostProjectEvidenceAccepted" $true) -and -not [bool](Get-JsonValue $handoffStatusManifest "fixtureEvidencePromoted" $true)) `
    "Contact readiness must not promote fixture evidence as real host-project evidence."
Add-ContactCheck "contact_report_content" `
    $reportContentValidated `
    "Contact readiness report must summarize contact status and send boundary."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestFullPath),
    (Convert-ToEvidenceRelativePath $reportFullPath),
    (Convert-ToEvidenceRelativePath $contactRosterFullPath)
)
$sourceFiles = @(
    "production-handoff-dispatch-manifest.json",
    "production-handoff-dispatch/production-handoff-dispatch-queue.json",
    "production-handoff-package/owner-packets/owner-packet-index.json",
    "production-handoff-status-manifest.json"
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_contact_readiness.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    contactRosterPath = $contactRosterFullPath
    reportPath = $reportFullPath
    contactRosterGenerated = (Test-Path $contactRosterFullPath)
    contactReportGenerated = (Test-Path $reportFullPath)
    contactReportContentValidated = [bool]$reportContentValidated
    ownerContactCount = [int]$ownerContactCount
    mappedOwnerContactCount = [int]$mappedOwnerContactCount
    configuredOwnerContactCount = [int]$configuredContactCount
    missingOwnerContactCount = [int]$missingContactCount
    invalidOwnerContactCount = [int]$invalidContactCount
    contactRosterComplete = [bool]$contactRosterComplete
    defaultMissingContactsExplicit = [bool]$defaultMissingContactsExplicit
    configuredContactsAccepted = [bool]$configuredContactsAccepted
    realOwnerEmailAddressesConfigured = [bool]$realOwnerEmailAddressesConfigured
    automaticEmailSendReady = [bool]$automaticEmailSendReady
    pendingDispatchCount = [int]$pendingDispatchCount
    pendingExternalEvidenceFileCount = [int]$pendingExternalEvidenceFileCount
    remainingBlockingReasonCount = [int]$remainingBlockingReasonCount
    externalEvidenceCollectionComplete = [bool](Get-JsonValue $handoffStatusManifest "externalEvidenceCollectionComplete" $false)
    releasePipelineUsesFixture = $false
    realHostProjectEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "host_project_owner_contact_readiness_only"
    contactStatuses = @($contactStatuses)
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
    throw "Production handoff contact readiness failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production handoff contact readiness manifest: $manifestFullPath"
Write-Output "Production handoff contact readiness report: $reportFullPath"
Write-Output "PASS AI TestPilot production handoff contact readiness"
