[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$SendDir,
    [string]$ManifestPath,
    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($SendDir)) {
    $SendDir = Join-Path $EvidenceBundleDir "production-handoff-send"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-handoff-send-readiness-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-handoff-send-readiness.md"
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

function Add-SendCheck {
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
$sendPath = Assert-PathUnderRepo $SendDir "SendDir"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if (Test-Path $sendPath) {
    Remove-Item -LiteralPath $sendPath -Recurse -Force
}
New-Item -ItemType Directory -Force $sendPath | Out-Null

$dispatchManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-dispatch-manifest.json") "Production handoff dispatch manifest"
$dispatchQueue = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-dispatch\production-handoff-dispatch-queue.json") "Production handoff dispatch queue"
$contactReadinessManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-contact-readiness-manifest.json") "Production handoff contact readiness manifest"
$contactReadinessContractManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-contact-readiness-contract-probe-manifest.json") "Production handoff contact readiness contract probe manifest"
$handoffExportManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-export-manifest.json") "Production handoff export manifest"
$handoffStatusManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-status-manifest.json") "Production handoff status manifest"

$sendQueuePath = Join-Path $sendPath "production-handoff-send-queue.json"
$sendScriptPath = Join-Path $sendPath "send-owner-packets.ps1"
$readmePath = Join-Path $sendPath "README.md"

$contactStatuses = @(Convert-ToArray (Get-JsonValue $contactReadinessManifest "contactStatuses" @()))
$sendEntries = @()
foreach ($entry in @(Convert-ToArray (Get-JsonValue $dispatchQueue "entries" @()))) {
    $owner = [string](Get-JsonValue $entry "owner" "")
    $area = [string](Get-JsonValue $entry "area" "")
    $matchingContacts = @($contactStatuses | Where-Object {
            [string](Get-JsonValue $_ "owner" "") -eq $owner -and
            [string](Get-JsonValue $_ "area" "") -eq $area
        })
    $contact = if ($matchingContacts.Count -gt 0) { $matchingContacts[0] } else { $null }
    $emailAddress = [string](Get-JsonValue $contact "emailAddress" "")
    $emailValid = Test-EmailAddress $emailAddress
    $contactConfigured = [bool](Get-JsonValue $contact "configured" $false) -and $emailValid
    $status = if ($contactConfigured) { "READY_FOR_CONFIRMATION" } else { "BLOCKED_MISSING_OWNER_EMAIL" }

    $sendEntries += [ordered]@{
        owner = $owner
        area = $area
        sendStatus = $status
        emailAddress = $emailAddress
        emailAddressValid = [bool]$emailValid
        contactConfigured = [bool]$contactConfigured
        subject = [string](Get-JsonValue $entry "subject" "")
        bodyFile = [string](Get-JsonValue $entry "draftPath" "")
        attachment = "production-handoff-export.zip"
        ownerPacketPath = [string](Get-JsonValue $entry "ownerPacketPath" "")
        requiredEvidenceFiles = @(Convert-ToArray (Get-JsonValue $entry "requiredEvidenceFiles" @()))
    }
}

$readySendCount = @($sendEntries | Where-Object { [string](Get-JsonValue $_ "sendStatus" "") -eq "READY_FOR_CONFIRMATION" }).Count
$blockedSendCount = @($sendEntries | Where-Object { [string](Get-JsonValue $_ "sendStatus" "") -ne "READY_FOR_CONFIRMATION" }).Count
$ownerContactCount = [int](Get-JsonValue $contactReadinessManifest "ownerContactCount" 0)
$missingOwnerContactCount = [int](Get-JsonValue $contactReadinessManifest "missingOwnerContactCount" 0)
$configuredOwnerContactCount = [int](Get-JsonValue $contactReadinessManifest "configuredOwnerContactCount" 0)
$automaticEmailSendReady = $false
$mailAuthorizationRequired = $true
$mailAuthorizationCheckedByPipeline = $false
$twoStageConfirmationRequired = $true
$sendReadinessStatus = if ($readySendCount -eq $sendEntries.Count -and $readySendCount -gt 0) {
    "READY_FOR_CONFIRMATION"
} else {
    "BLOCKED_MISSING_OWNER_EMAILS"
}

$sendQueue = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_send_queue.v1"
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    sendReadinessStatus = $sendReadinessStatus
    ownerContactCount = [int]$ownerContactCount
    sendQueueEntryCount = [int]$sendEntries.Count
    readySendCount = [int]$readySendCount
    blockedSendCount = [int]$blockedSendCount
    missingOwnerContactCount = [int]$missingOwnerContactCount
    configuredOwnerContactCount = [int]$configuredOwnerContactCount
    automaticEmailSendReady = $false
    mailAuthorizationRequired = $true
    mailAuthorizationCheckedByPipeline = $false
    twoStageConfirmationRequired = $true
    entries = @($sendEntries)
}
$sendQueue | ConvertTo-Json -Depth 12 | Set-Content -Path $sendQueuePath -Encoding UTF8

$sendScriptLines = @(
    "[CmdletBinding()]",
    "param(",
    "    [string]`$EvidenceBundleDir = (Resolve-Path (Join-Path `$PSScriptRoot '..')).Path,",
    "    [string]`$ContactRosterPath,",
    "    [string]`$ConfirmationTokenMapPath,",
    "    [switch]`$PrepareConfirmation,",
    "    [switch]`$Send",
    ")",
    "",
    "Set-StrictMode -Version Latest",
    "`$ErrorActionPreference = 'Stop'",
    "",
    "if (-not `$PrepareConfirmation -and -not `$Send) {",
    "    Write-Output 'Dry run only. Pass -PrepareConfirmation to request confirmation tokens, then pass -Send with -ConfirmationTokenMapPath after operator approval.'",
    "}",
    "",
    "if ([string]::IsNullOrWhiteSpace(`$ContactRosterPath)) {",
    "    `$ContactRosterPath = Join-Path `$EvidenceBundleDir 'production-handoff-contact-roster.json'",
    "}",
    "",
    "function Read-JsonFile {",
    "    param([string]`$Path)",
    "    if (-not (Test-Path `$Path)) { throw `"Missing JSON file: `$Path`" }",
    "    return Get-Content -Path `$Path -Encoding UTF8 -Raw | ConvertFrom-Json",
    "}",
    "",
    "function Test-EmailAddress {",
    "    param([string]`$Value)",
    "    if ([string]::IsNullOrWhiteSpace(`$Value)) { return `$false }",
    "    if (`$Value.Trim() -like 'replace-with-*-email') { return `$false }",
    "    return [bool](`$Value.Trim() -match '^[^@\s]+@[^@\s]+\.[^@\s]+$')",
    "}",
    "",
    "`$authStatusRaw = & agently-cli auth status",
    "`$authStatus = `$authStatusRaw | ConvertFrom-Json",
    "if (-not [bool]`$authStatus.data.logged_in) { throw 'agently-cli is not logged in. Run agently-cli auth login before preparing owner packet sends.' }",
    "& agently-cli +me | Out-Null",
    "",
    "`$queue = Read-JsonFile (Join-Path `$EvidenceBundleDir 'production-handoff-send/production-handoff-send-queue.json')",
    "`$contacts = Read-JsonFile `$ContactRosterPath",
    "`$tokens = @{}",
    "if (`$Send) {",
    "    if ([string]::IsNullOrWhiteSpace(`$ConfirmationTokenMapPath)) { throw '-Send requires -ConfirmationTokenMapPath.' }",
    "    `$tokenJson = Read-JsonFile `$ConfirmationTokenMapPath",
    "    foreach (`$entry in @(`$tokenJson.entries)) { `$tokens[[string]`$entry.owner] = [string]`$entry.confirmationToken }",
    "}",
    "",
    "Push-Location `$EvidenceBundleDir",
    "try {",
    "    foreach (`$entry in @(`$queue.entries)) {",
    "        `$contact = @(`$contacts.entries | Where-Object { `$_.owner -eq `$entry.owner -and `$_.area -eq `$entry.area }) | Select-Object -First 1",
    "        if (`$null -eq `$contact -or -not [bool]`$contact.configured -or -not (Test-EmailAddress ([string]`$contact.emailAddress))) {",
    "            throw `"Owner contact is not configured for `$(`$entry.owner).`"",
    "        }",
    "        `$args = @('message', '+send', '--to', [string]`$contact.emailAddress, '--subject', [string]`$entry.subject, '--body-file', [string]`$entry.bodyFile, '--attachment', '.\production-handoff-export.zip')",
    "        if (`$Send) {",
    "            if (-not `$tokens.ContainsKey([string]`$entry.owner)) { throw `"Missing confirmation token for `$(`$entry.owner).`" }",
    "            `$args += @('--confirmation-token', `$tokens[[string]`$entry.owner])",
    "        }",
    "        if (`$PrepareConfirmation -or `$Send) {",
    "            & agently-cli @args",
    "        } else {",
    "            Write-Output ('Prepared send command for ' + `$entry.owner + ' -> ' + `$contact.emailAddress)",
    "        }",
    "    }",
    "}",
    "finally {",
    "    Pop-Location",
    "}"
)
$sendScriptLines | Set-Content -Path $sendScriptPath -Encoding UTF8

$readmeLines = @(
    "# AI TestPilot Production Handoff Send Kit",
    "",
    "This folder contains a send queue and a guarded agently-cli send helper.",
    "",
    "Default release evidence does not send email because real owner addresses and local mail authorization are external prerequisites.",
    "",
    "Workflow:",
    "",
    "1. Fill ``production-handoff-contact-roster.json`` with real owner mailboxes.",
    "2. Run ``agently-cli auth login`` and verify ``agently-cli +me``.",
    "3. Run ``.\production-handoff-send\send-owner-packets.ps1 -PrepareConfirmation`` to request CLI confirmation tokens.",
    "4. After operator approval, pass those tokens through ``-ConfirmationTokenMapPath`` with ``-Send``.",
    "",
    "The helper does not bypass agently-cli two-stage confirmation."
)
$readmeLines | Set-Content -Path $readmePath -Encoding UTF8

$sendScriptText = Get-Content -Path $sendScriptPath -Encoding UTF8 -Raw
$sendScriptContentValidated = $sendScriptText.Contains("agently-cli auth status") -and
    $sendScriptText.Contains("agently-cli +me") -and
    $sendScriptText.Contains("message', '+send") -and
    $sendScriptText.Contains("--confirmation-token") -and
    $sendScriptText.Contains("PrepareConfirmation") -and
    $sendScriptText.Contains("Dry run only") -and
    -not $sendScriptText.Contains("System.Collections")

$sendQueueGenerated = Test-Path $sendQueuePath
$sendScriptGenerated = Test-Path $sendScriptPath
$readmeGenerated = Test-Path $readmePath
$handoffExportZipAvailable = (Test-Path (Join-Path $evidenceBundlePath "production-handoff-export.zip")) -and
    [bool](Get-JsonValue $handoffExportManifest "zipGenerated" $false)
$defaultContactBoundaryPreserved = [int](Get-JsonValue $contactReadinessManifest "missingOwnerContactCount" -1) -eq $ownerContactCount -and
    [int](Get-JsonValue $contactReadinessManifest "configuredOwnerContactCount" -1) -eq 0 -and
    -not [bool](Get-JsonValue $contactReadinessManifest "realOwnerEmailAddressesConfigured" $true) -and
    -not [bool](Get-JsonValue $contactReadinessManifest "automaticEmailSendReady" $true)
$configuredContactBoundaryPreserved = [int](Get-JsonValue $contactReadinessManifest "configuredOwnerContactCount" -1) -eq $ownerContactCount -and
    [int](Get-JsonValue $contactReadinessManifest "missingOwnerContactCount" -1) -eq 0 -and
    [bool](Get-JsonValue $contactReadinessManifest "realOwnerEmailAddressesConfigured" $false) -and
    -not [bool](Get-JsonValue $contactReadinessManifest "automaticEmailSendReady" $true)
$contactBoundaryPreserved = $defaultContactBoundaryPreserved -or $configuredContactBoundaryPreserved
$contactContractAccepted = $contactReadinessContractManifest.status -eq "PASS" -and
    [bool](Get-JsonValue $contactReadinessContractManifest "acceptedContactReadinessPassed" $false) -and
    [int](Get-JsonValue $contactReadinessContractManifest "acceptedConfiguredOwnerContactCount" -1) -eq $ownerContactCount -and
    -not [bool](Get-JsonValue $contactReadinessContractManifest "acceptedAutomaticEmailSendReady" $true)
$sendQueueStateAccepted = $sendQueueGenerated -and
    [int]$sendQueue.sendQueueEntryCount -eq $ownerContactCount -and
    ([int]$sendQueue.readySendCount + [int]$sendQueue.blockedSendCount) -eq $ownerContactCount -and
    (($sendReadinessStatus -eq "BLOCKED_MISSING_OWNER_EMAILS" -and [int]$sendQueue.blockedSendCount -eq $ownerContactCount) -or
        ($sendReadinessStatus -eq "READY_FOR_CONFIRMATION" -and [int]$sendQueue.readySendCount -eq $ownerContactCount))

$reportLines = @(
    "# AI TestPilot Production Handoff Send Readiness",
    "",
    "Schema: ``aitestpilot.production_handoff_send_readiness.v1``",
    "Generated at UTC: $((Get-Date).ToUniversalTime().ToString("O"))",
    "",
    "## Summary",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Send readiness status | $sendReadinessStatus |",
    "| Queue entries | $($sendEntries.Count) |",
    "| Ready sends | $readySendCount |",
    "| Blocked sends | $blockedSendCount |",
    "| Missing owner contacts | $missingOwnerContactCount |",
    "| Configured owner contacts | $configuredOwnerContactCount |",
    "| Mail authorization checked by pipeline | $mailAuthorizationCheckedByPipeline |",
    "| Two-stage confirmation required | $twoStageConfirmationRequired |",
    "| Automatic email send ready | $automaticEmailSendReady |",
    "",
    "## Send Queue",
    "",
    "| Owner | Area | Status | Body | Attachment |",
    "| --- | --- | --- | --- | --- |"
)

foreach ($entry in $sendEntries) {
    $owner = Format-MarkdownCell (Get-JsonValue $entry "owner" "")
    $area = Format-MarkdownCell (Get-JsonValue $entry "area" "")
    $statusText = Format-MarkdownCell (Get-JsonValue $entry "sendStatus" "")
    $bodyFile = Format-MarkdownCell (Get-JsonValue $entry "bodyFile" "")
    $attachment = Format-MarkdownCell (Get-JsonValue $entry "attachment" "")
    $reportLines += "| $owner | $area | $statusText | $bodyFile | $attachment |"
}

$reportLines += @(
    "",
    "## Boundary",
    "",
    "- This readiness report generates a send queue and guarded helper only.",
    "- The release pipeline does not check local agently-cli authorization and does not send email.",
    "- Real dispatch requires configured owner contacts, agently-cli login, and explicit two-stage confirmation tokens."
)

$reportText = [string]::Join([Environment]::NewLine, $reportLines) + [Environment]::NewLine
New-Item -ItemType Directory -Force (Split-Path $reportFullPath -Parent) | Out-Null
$reportText | Set-Content -Path $reportFullPath -Encoding UTF8

$reportContentValidated = $reportText.Contains("AI TestPilot Production Handoff Send Readiness") -and
    $reportText.Contains($sendReadinessStatus) -and
    $reportText.Contains("Two-stage confirmation required") -and
    $reportText.Contains("does not send email") -and
    $reportText.Contains("configured owner contacts") -and
    -not $reportText.Contains("System.Collections") -and
    -not $reportText.Contains("@{")

$checks = @()
Add-SendCheck "handoff_send_sources_available" `
    ($dispatchManifest.status -eq "PASS" -and $dispatchQueue.status -eq "PASS" -and $contactReadinessManifest.status -eq "PASS" -and $handoffExportManifest.status -eq "PASS" -and $handoffStatusManifest.status -eq "PASS") `
    "Send readiness must be based on passing dispatch, contact, export, and handoff status evidence."
Add-SendCheck "send_queue_generated" `
    $sendQueueStateAccepted `
    "Send queue must map every owner and preserve either the blocked or ready-for-confirmation state."
Add-SendCheck "send_helper_generated" `
    ($sendScriptGenerated -and $sendScriptContentValidated -and $readmeGenerated) `
    "Send kit must include a guarded agently-cli helper with dry-run and two-stage confirmation paths."
Add-SendCheck "handoff_export_attachment_available" `
    $handoffExportZipAvailable `
    "Owner packet sends must have the handoff export zip available as the attachment."
Add-SendCheck "contact_and_contract_boundaries" `
    ($contactBoundaryPreserved -and $contactContractAccepted) `
    "Send readiness must preserve contact boundaries while proving configured contacts can pass readiness in contract mode."
Add-SendCheck "mail_auth_boundary_preserved" `
    ($mailAuthorizationRequired -and -not $mailAuthorizationCheckedByPipeline -and $twoStageConfirmationRequired -and -not $automaticEmailSendReady) `
    "Release evidence must not claim local mail authorization or bypass two-stage confirmation."
Add-SendCheck "fixture_boundary_preserved" `
    (-not [bool](Get-JsonValue $handoffStatusManifest "realHostProjectEvidenceAccepted" $true) -and -not [bool](Get-JsonValue $handoffStatusManifest "fixtureEvidencePromoted" $true)) `
    "Send readiness must not promote fixture evidence as real host-project evidence."
Add-SendCheck "send_report_content" `
    $reportContentValidated `
    "Send readiness report must summarize blocked sends, mail authorization boundary, and two-stage confirmation."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestFullPath),
    (Convert-ToEvidenceRelativePath $reportFullPath),
    (Convert-ToEvidenceRelativePath $sendQueuePath),
    (Convert-ToEvidenceRelativePath $sendScriptPath),
    (Convert-ToEvidenceRelativePath $readmePath)
)
$sourceFiles = @(
    "production-handoff-dispatch-manifest.json",
    "production-handoff-dispatch/production-handoff-dispatch-queue.json",
    "production-handoff-contact-readiness-manifest.json",
    "production-handoff-contact-readiness-contract-probe-manifest.json",
    "production-handoff-export-manifest.json",
    "production-handoff-export.zip",
    "production-handoff-status-manifest.json"
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_send_readiness.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    sendDir = $sendPath
    sendQueuePath = $sendQueuePath
    sendScriptPath = $sendScriptPath
    reportPath = $reportFullPath
    sendReadinessStatus = $sendReadinessStatus
    sendKitGenerated = [bool]($sendQueueGenerated -and $sendScriptGenerated -and $readmeGenerated)
    sendQueueGenerated = [bool]$sendQueueGenerated
    sendScriptGenerated = [bool]$sendScriptGenerated
    sendScriptContentValidated = [bool]$sendScriptContentValidated
    sendReportGenerated = (Test-Path $reportFullPath)
    sendReportContentValidated = [bool]$reportContentValidated
    ownerContactCount = [int]$ownerContactCount
    sendQueueEntryCount = [int]$sendEntries.Count
    readySendCount = [int]$readySendCount
    blockedSendCount = [int]$blockedSendCount
    missingOwnerContactCount = [int]$missingOwnerContactCount
    configuredOwnerContactCount = [int]$configuredOwnerContactCount
    mailAuthorizationRequired = [bool]$mailAuthorizationRequired
    mailAuthorizationCheckedByPipeline = [bool]$mailAuthorizationCheckedByPipeline
    twoStageConfirmationRequired = [bool]$twoStageConfirmationRequired
    automaticEmailSendReady = [bool]$automaticEmailSendReady
    defaultContactBoundaryPreserved = [bool]$defaultContactBoundaryPreserved
    configuredContactBoundaryPreserved = [bool]$configuredContactBoundaryPreserved
    contactBoundaryPreserved = [bool]$contactBoundaryPreserved
    contactReadinessContractAccepted = [bool]$contactContractAccepted
    handoffExportZipAvailable = [bool]$handoffExportZipAvailable
    releasePipelineUsesFixture = $false
    realHostProjectEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "host_project_owner_send_readiness_only"
    sendEntries = @($sendEntries)
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
    throw "Production handoff send readiness failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production handoff send readiness manifest: $manifestFullPath"
Write-Output "Production handoff send readiness report: $reportFullPath"
Write-Output "PASS AI TestPilot production handoff send readiness"
