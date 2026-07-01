[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ReceiptDir,
    [string]$ContactRosterPath,
    [string]$ManifestPath,
    [string]$ReportPath,
    [switch]$RequireReceipts,
    [switch]$ContractFixtureMode,
    [switch]$ConfirmLocalOwnerPacketReceipts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-handoff-owner-packet-dispatch-receipt-intake-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-handoff-owner-packet-dispatch-receipt-intake.md"
}

function Resolve-FullPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Convert-ToEvidenceRelativePath {
    param([string]$Path)

    $fullPath = Resolve-FullPath $Path
    if (-not $fullPath.StartsWith($evidenceBundlePath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath
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

function Convert-ToArray {
    param([object]$Value)

    if ($null -eq $Value) {
        return @()
    }

    return @($Value)
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

function Test-EmailAddress {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    if ($Value.Trim() -like "replace-with-*-email") {
        return $false
    }

    return [bool]($Value.Trim() -match "^[^@\s]+@[^@\s]+\.[^@\s]+$")
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

function Convert-ToSafeFileName {
    param([string]$Value)

    $safe = $Value -replace "[^A-Za-z0-9_.-]+", "-"
    $safe = $safe.Trim("-")
    if ([string]::IsNullOrWhiteSpace($safe)) {
        return "owner"
    }

    return $safe
}

function Get-ReceiptCliOutputText {
    param([object]$Receipt)

    $cliOutput = @(Convert-ToArray (Get-JsonValue $Receipt "cliOutput" @()))
    if ($cliOutput.Count -eq 0) {
        return ""
    }

    return [string]::Join([Environment]::NewLine, @($cliOutput | ForEach-Object { [string]$_ }))
}

function Get-ReceiptQueued {
    param(
        [object]$Receipt,
        [string]$CliOutputText
    )

    if (Convert-ToBool (Get-JsonValue $Receipt "queued" $false)) {
        return $true
    }

    if ([string]::IsNullOrWhiteSpace($CliOutputText)) {
        return $false
    }

    try {
        $start = $CliOutputText.IndexOf("{")
        $end = $CliOutputText.LastIndexOf("}")
        if ($start -lt 0 -or $end -lt $start) {
            return $false
        }

        $cliResponse = $CliOutputText.Substring($start, $end - $start + 1) | ConvertFrom-Json
        return Convert-ToBool (Get-JsonValue (Get-JsonValue $cliResponse "data" $null) "queued" $false)
    }
    catch {
        return $false
    }
}

function Test-FakeOwnerPacketReceipt {
    param(
        [string]$MessageId,
        [string]$CliOutputText
    )

    if ($MessageId -like "msg_fake*") {
        return $true
    }

    if ($MessageId -like "msg_owner_packet_workflow*") {
        return $true
    }

    if ($CliOutputText -match "msg_fake" -or $CliOutputText -match "msg_owner_packet_workflow") {
        return $true
    }

    return $false
}

function Add-ReceiptCheck {
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

$evidenceBundlePath = Resolve-FullPath $EvidenceBundleDir
$manifestFullPath = Resolve-FullPath $ManifestPath
$reportFullPath = Resolve-FullPath $ReportPath

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if ([string]::IsNullOrWhiteSpace($ReceiptDir)) {
    $ReceiptDir = Join-Path $evidenceBundlePath "production-handoff-send\owner-packet-send-receipts"
}
$receiptDirFullPath = Resolve-FullPath $ReceiptDir

if ([string]::IsNullOrWhiteSpace($ContactRosterPath)) {
    $ContactRosterPath = Join-Path $evidenceBundlePath "production-handoff-contact-roster.json"
}
$contactRosterFullPath = Resolve-FullPath $ContactRosterPath

$sendReadinessManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-send-readiness-manifest.json") "Production handoff send readiness manifest"
$sendQueue = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-send\production-handoff-send-queue.json") "Production handoff send queue"
$contactRoster = Read-JsonFile $contactRosterFullPath "Production handoff contact roster"

$queueEntries = @(Convert-ToArray (Get-JsonValue $sendQueue "entries" @()))
$contactEntries = @(Convert-ToArray (Get-JsonValue $contactRoster "entries" @()))
$receiptResults = @()
$missingReceiptCount = 0
$parseErrorCount = 0
$acceptedReceiptCount = 0
$fakeReceiptRejectedCount = 0
$fakeReceiptDetectedCount = 0
$dispatchEvidencePresentCount = 0
$messageIdCount = 0
$queuedReceiptCount = 0
$receiptFileCount = 0

foreach ($entry in $queueEntries) {
    $owner = [string](Get-JsonValue $entry "owner" "")
    $area = [string](Get-JsonValue $entry "area" "")
    $contact = @($contactEntries | Where-Object {
            [string](Get-JsonValue $_ "owner" "") -eq $owner -and
            [string](Get-JsonValue $_ "area" "") -eq $area
        } | Select-Object -First 1)
    if ($contact.Count -gt 0) {
        $contact = $contact[0]
    }
    else {
        $contact = $null
    }

    $receiptPath = Join-Path $receiptDirFullPath ((Convert-ToSafeFileName $owner) + ".json")
    $receiptExists = Test-Path $receiptPath
    $receipt = $null
    $receiptParseError = ""
    if ($receiptExists) {
        $receiptFileCount += 1
        try {
            $receipt = Get-Content -Path $receiptPath -Encoding UTF8 -Raw | ConvertFrom-Json
        }
        catch {
            $receiptParseError = $_.Exception.Message
            $parseErrorCount += 1
        }
    }
    else {
        $missingReceiptCount += 1
    }

    $recipient = [string](Get-JsonValue $receipt "recipient" "")
    $subject = [string](Get-JsonValue $receipt "subject" "")
    $messageId = [string](Get-JsonValue $receipt "messageId" "")
    $cliOutputText = Get-ReceiptCliOutputText $receipt
    $queued = Get-ReceiptQueued $receipt $cliOutputText
    $isFakeReceipt = Test-FakeOwnerPacketReceipt $messageId $cliOutputText
    $fakeReceiptRejected = -not $isFakeReceipt
    $dispatchEvidencePresent = (-not [string]::IsNullOrWhiteSpace($messageId)) -or $queued
    $schemaAccepted = (Get-JsonValue $receipt "schemaVersion" "") -eq "aitestpilot.production_handoff_owner_packet_send_receipt.v1"
    $ownerMatches = [string](Get-JsonValue $receipt "owner" "") -eq $owner
    $areaMatches = [string](Get-JsonValue $receipt "area" "") -eq $area
    $contactConfigured = Convert-ToBool (Get-JsonValue $contact "configured" $false)
    $recipientMatches = $recipient -eq [string](Get-JsonValue $contact "emailAddress" "")
    $recipientValid = Test-EmailAddress $recipient
    $subjectMatches = $subject -eq [string](Get-JsonValue $entry "subject" "")
    $successBoundary = (Convert-ToBool (Get-JsonValue $receipt "confirmationTokenSupplied" $false)) -and
        (Convert-ToBool (Get-JsonValue $receipt "sendSucceeded" $false)) -and
        (Convert-ToInt (Get-JsonValue $receipt "agentlyCliExitCode" -1)) -eq 0 -and
        -not (Convert-ToBool (Get-JsonValue $receipt "releasePipelineGenerated" $true))
    $receiptAccepted = $receiptExists -and
        $null -ne $receipt -and
        [string]::IsNullOrWhiteSpace($receiptParseError) -and
        $schemaAccepted -and
        $ownerMatches -and
        $areaMatches -and
        $contactConfigured -and
        $recipientMatches -and
        $recipientValid -and
        $subjectMatches -and
        $dispatchEvidencePresent -and
        $fakeReceiptRejected -and
        $successBoundary

    if ($receiptAccepted) {
        $acceptedReceiptCount += 1
    }
    if ($fakeReceiptRejected) {
        $fakeReceiptRejectedCount += 1
    }
    if ($isFakeReceipt) {
        $fakeReceiptDetectedCount += 1
    }
    if ($dispatchEvidencePresent) {
        $dispatchEvidencePresentCount += 1
    }
    if (-not [string]::IsNullOrWhiteSpace($messageId)) {
        $messageIdCount += 1
    }
    if ($queued) {
        $queuedReceiptCount += 1
    }

    $receiptResults += [ordered]@{
        owner = $owner
        area = $area
        receiptPath = $receiptPath
        receiptExists = [bool]$receiptExists
        receiptParseError = $receiptParseError
        receiptAccepted = [bool]$receiptAccepted
        schemaAccepted = [bool]$schemaAccepted
        ownerMatches = [bool]$ownerMatches
        areaMatches = [bool]$areaMatches
        contactConfigured = [bool]$contactConfigured
        recipient = $recipient
        recipientMatches = [bool]$recipientMatches
        subjectMatches = [bool]$subjectMatches
        messageId = $messageId
        queued = [bool]$queued
        dispatchEvidencePresent = [bool]$dispatchEvidencePresent
        fakeReceiptRejected = [bool]$fakeReceiptRejected
        confirmationTokenSupplied = Convert-ToBool (Get-JsonValue $receipt "confirmationTokenSupplied" $false)
        sendSucceeded = Convert-ToBool (Get-JsonValue $receipt "sendSucceeded" $false)
        releasePipelineGenerated = Convert-ToBool (Get-JsonValue $receipt "releasePipelineGenerated" $true)
        realDeliveryVerified = Convert-ToBool (Get-JsonValue $receipt "realDeliveryVerified" $false)
    }
}

$expectedOwnerPacketReceiptCount = $queueEntries.Count
$allReceiptsAccepted = $expectedOwnerPacketReceiptCount -gt 0 -and $acceptedReceiptCount -eq $expectedOwnerPacketReceiptCount
$realOwnerPacketEmailSentAccepted = $allReceiptsAccepted -and -not [bool]$ContractFixtureMode -and [bool]$ConfirmLocalOwnerPacketReceipts
$ownerPacketDispatchStatus = if ($realOwnerPacketEmailSentAccepted) {
    "OWNER_PACKETS_SENT_BY_LOCAL_AGENTLY_CLI"
}
elseif ($allReceiptsAccepted -and [bool]$ContractFixtureMode) {
    "CONTRACT_RECEIPTS_ACCEPTED_NOT_REAL_SEND"
}
elseif ($allReceiptsAccepted) {
    "VALID_RECEIPTS_PENDING_OPERATOR_REAL_SEND_CONFIRMATION"
}
else {
    "PENDING_LOCAL_MAIL_AUTH_AND_CONFIRMATION"
}

$checks = @()
Add-ReceiptCheck "owner_packet_dispatch_sources_available" `
    ($sendReadinessManifest.status -eq "PASS" -and
        $sendQueue.status -eq "PASS" -and
        $queueEntries.Count -gt 0 -and
        $contactEntries.Count -eq $queueEntries.Count) `
    "Owner-packet dispatch receipt intake must read passing send readiness, send queue, and one contact row per queue entry."
Add-ReceiptCheck "owner_packet_receipts_present" `
    ($receiptFileCount -eq $expectedOwnerPacketReceiptCount -and $missingReceiptCount -eq 0 -and $parseErrorCount -eq 0) `
    "One parseable receipt file must exist for each owner-packet send."
Add-ReceiptCheck "owner_packet_receipts_match_queue" `
    ($acceptedReceiptCount -eq $expectedOwnerPacketReceiptCount) `
    "Receipts must match owner, area, recipient, subject, token-confirmed local helper success, and dispatch evidence."
Add-ReceiptCheck "owner_packet_fake_receipts_rejected" `
    ($fakeReceiptRejectedCount -eq $expectedOwnerPacketReceiptCount) `
    "Fake CLI owner-packet receipts must not be accepted as dispatch evidence."
Add-ReceiptCheck "owner_packet_real_send_acceptance_guard" `
    (([bool]$ContractFixtureMode -and $allReceiptsAccepted -and -not $realOwnerPacketEmailSentAccepted) -or
        (-not [bool]$ContractFixtureMode -and [bool]$ConfirmLocalOwnerPacketReceipts -and $allReceiptsAccepted -and $realOwnerPacketEmailSentAccepted) -or
        (-not [bool]$ContractFixtureMode -and -not [bool]$ConfirmLocalOwnerPacketReceipts -and $allReceiptsAccepted -and -not $realOwnerPacketEmailSentAccepted) -or
        (-not $allReceiptsAccepted -and -not $realOwnerPacketEmailSentAccepted)) `
    "Valid owner-packet receipts may claim real local sends only when ContractFixtureMode is off and ConfirmLocalOwnerPacketReceipts is supplied."
Add-ReceiptCheck "owner_packet_release_boundary_preserved" `
    (-not (Convert-ToBool (Get-JsonValue $sendReadinessManifest "releasePipelineSendsEmail" $false)) -and
        -not (Convert-ToBool (Get-JsonValue $sendReadinessManifest "automaticEmailSendReady" $false))) `
    "Release pipeline must not send owner-packet email or mark the canonical send readiness automatically ready."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($allReceiptsAccepted) { "PASS" } elseif ([bool]$RequireReceipts) { "FAIL" } else { "PENDING_RECEIPTS" }

$generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
$reportLines = @(
    "# AI TestPilot Production Handoff Owner Packet Dispatch Receipt Intake",
    "",
    "Schema: ``aitestpilot.production_handoff_owner_packet_dispatch_receipt_intake.v1``",
    "Generated at UTC: $generatedAtUtc",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Status | $(Format-MarkdownCell $status) |",
    "| Receipt directory | $(Format-MarkdownCell $receiptDirFullPath) |",
    "| Expected owner packet receipts | $expectedOwnerPacketReceiptCount |",
    "| Receipt files | $receiptFileCount |",
    "| Accepted receipts | $acceptedReceiptCount |",
    "| Fake receipt rejected count | $fakeReceiptRejectedCount |",
    "| Fake receipt detected count | $fakeReceiptDetectedCount |",
    "| Contract fixture mode | $([bool]$ContractFixtureMode) |",
    "| Confirm local owner packet receipts | $([bool]$ConfirmLocalOwnerPacketReceipts) |",
    "| Real owner packet email sent accepted | $realOwnerPacketEmailSentAccepted |",
    "| Dispatch status | $(Format-MarkdownCell $ownerPacketDispatchStatus) |",
    "",
    "## Receipts",
    "",
    "| Owner | Area | Accepted | Message id | Queued | Fake rejected |",
    "| --- | --- | --- | --- | --- | --- |"
)
foreach ($result in $receiptResults) {
    $reportLines += "| $(Format-MarkdownCell $result.owner) | $(Format-MarkdownCell $result.area) | $($result.receiptAccepted) | $(Format-MarkdownCell $result.messageId) | $($result.queued) | $($result.fakeReceiptRejected) |"
}
$reportLines += @(
    "",
    "## Boundary",
    "",
    "- Release pipeline does not send owner-packet email.",
    "- Fake CLI probe receipts are rejected.",
    "- Contract fixture mode does not claim real email delivery.",
    "- Valid receipts require explicit operator confirmation before realOwnerPacketEmailSent=true.",
    "",
    "## Checks",
    "",
    "| Check | Passed | Message |",
    "| --- | --- | --- |"
)
foreach ($check in $checks) {
    $reportLines += "| $($check.name) | $($check.passed) | $($check.message) |"
}

New-Item -ItemType Directory -Force (Split-Path $reportFullPath -Parent) | Out-Null
$reportLines | Set-Content -Path $reportFullPath -Encoding UTF8

$sourceFiles = @(
    "production-handoff-send-readiness-manifest.json",
    "production-handoff-send/production-handoff-send-queue.json",
    (Convert-ToEvidenceRelativePath $contactRosterFullPath)
)
$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestFullPath),
    (Convert-ToEvidenceRelativePath $reportFullPath)
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_owner_packet_dispatch_receipt_intake.v1"
    status = $status
    generatedAtUtc = $generatedAtUtc
    evidenceBundleDir = $evidenceBundlePath
    receiptDir = $receiptDirFullPath
    contactRosterPath = $contactRosterFullPath
    receiptExpectedCount = [int]$expectedOwnerPacketReceiptCount
    receiptAcceptedCount = [int]$acceptedReceiptCount
    receiptMissingCount = [int]$missingReceiptCount
    receiptDuplicateCount = 0
    receiptUnexpectedCount = 0
    expectedOwnerPacketReceiptCount = [int]$expectedOwnerPacketReceiptCount
    receiptFileCount = [int]$receiptFileCount
    missingReceiptCount = [int]$missingReceiptCount
    parseErrorCount = [int]$parseErrorCount
    acceptedReceiptCount = [int]$acceptedReceiptCount
    fakeReceiptRejectedCount = [int]$fakeReceiptRejectedCount
    fakeReceiptDetectedCount = [int]$fakeReceiptDetectedCount
    dispatchEvidencePresentCount = [int]$dispatchEvidencePresentCount
    ownerPacketReceiptMessageIdCount = [int]$messageIdCount
    ownerPacketReceiptQueuedCount = [int]$queuedReceiptCount
    ownerPacketReceiptConfirmedCount = [int]$acceptedReceiptCount
    messageIdCount = [int]$messageIdCount
    queuedReceiptCount = [int]$queuedReceiptCount
    contractFixtureMode = [bool]$ContractFixtureMode
    confirmLocalOwnerPacketSendReceipt = [bool]$ConfirmLocalOwnerPacketReceipts
    confirmLocalOwnerPacketReceipts = [bool]$ConfirmLocalOwnerPacketReceipts
    operatorRealSendConfirmationRequired = [bool]($allReceiptsAccepted -and -not [bool]$ContractFixtureMode -and -not [bool]$ConfirmLocalOwnerPacketReceipts)
    operatorRealSendConfirmed = [bool]$realOwnerPacketEmailSentAccepted
    ownerPacketDispatchStatus = $ownerPacketDispatchStatus
    releasePipelineSendsEmail = $false
    realOwnerPacketEmailSentAccepted = [bool]$realOwnerPacketEmailSentAccepted
    realOwnerPacketEmailSent = [bool]$realOwnerPacketEmailSentAccepted
    emailSent = [bool]$realOwnerPacketEmailSentAccepted
    realHostProjectEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = if ($realOwnerPacketEmailSentAccepted) {
        "owner_packet_real_dispatch_receipts_accepted"
    } elseif ($allReceiptsAccepted -and [bool]$ContractFixtureMode) {
        "owner_packet_dispatch_receipts_contract_only"
    } elseif ($allReceiptsAccepted) {
        "owner_packet_dispatch_receipts_pending_operator_confirmation"
    } else {
        "owner_packet_dispatch_receipts_not_accepted"
    }
    receiptResults = @($receiptResults)
    sourceFiles = @($sourceFiles)
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles + $sourceFiles)
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
}

New-Item -ItemType Directory -Force (Split-Path $manifestFullPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestFullPath -Encoding UTF8

if ([bool]$RequireReceipts -and -not $allReceiptsAccepted) {
    throw "Production handoff owner packet dispatch receipt intake failed: receipts were required but not accepted."
}

if ($failedChecks.Count -gt 0 -and $status -eq "PASS") {
    throw "Production handoff owner packet dispatch receipt intake failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production handoff owner packet dispatch receipt intake manifest: $manifestFullPath"
Write-Output "Production handoff owner packet dispatch receipt intake report: $reportFullPath"
Write-Output "AI TestPilot production handoff owner packet dispatch receipt intake status: $status"
