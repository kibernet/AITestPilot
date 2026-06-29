[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ReceiptPath,
    [string]$ManifestPath,
    [string]$ReportPath,
    [switch]$RequireReceipt,
    [switch]$ContractFixtureMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "release-progress-notification-dispatch-receipt-intake-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "release-progress-notification-dispatch-receipt-intake.md"
}

function Resolve-FullPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
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

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }

    return $property.Value
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

$evidenceBundlePath = Resolve-FullPath $EvidenceBundleDir
$manifestFullPath = Resolve-FullPath $ManifestPath
$reportFullPath = Resolve-FullPath $ReportPath

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if ([string]::IsNullOrWhiteSpace($ReceiptPath)) {
    $ReceiptPath = Join-Path $evidenceBundlePath "release-progress-notification-outbox\progress-notification-send-receipt.json"
}
$receiptFullPath = Resolve-FullPath $ReceiptPath

$outboxManifest = Read-JsonFile (Join-Path $evidenceBundlePath "release-progress-notification-outbox-manifest.json") "Release progress notification outbox manifest"

$receiptExists = Test-Path $receiptFullPath
$receipt = $null
$receiptParseError = ""
if ($receiptExists) {
    try {
        $receipt = Get-Content -Path $receiptFullPath -Encoding UTF8 -Raw | ConvertFrom-Json
    }
    catch {
        $receiptParseError = $_.Exception.Message
    }
}

$recipient = [string](Get-JsonValue $receipt "recipient" "")
$subject = [string](Get-JsonValue $receipt "subject" "")
$messageId = [string](Get-JsonValue $receipt "messageId" "")
$receiptSchemaAccepted = (Get-JsonValue $receipt "schemaVersion" "") -eq "aitestpilot.release_progress_notification_send_receipt.v1"
$recipientMatches = $recipient -eq [string](Get-JsonValue $outboxManifest "recipient" "")
$subjectMatches = $subject -eq [string](Get-JsonValue $outboxManifest "subject" "")
$messageIdPresent = -not [string]::IsNullOrWhiteSpace($messageId)
$fakeReceiptRejected = $messageId -notlike "msg_fake*"
$receiptAccepted = (
    $receiptExists -and
    $null -ne $receipt -and
    [string]::IsNullOrWhiteSpace($receiptParseError) -and
    $receiptSchemaAccepted -and
    $recipientMatches -and
    $subjectMatches -and
    $messageIdPresent -and
    $fakeReceiptRejected -and
    (Get-JsonValue $receipt "confirmationTokenSupplied" $false) -and
    (Get-JsonValue $receipt "sendSucceeded" $false) -and
    (Get-JsonValue $receipt "agentlyCliExitCode" -1) -eq 0 -and
    -not (Get-JsonValue $receipt "releasePipelineGenerated" $true)
)
$realEmailSentAccepted = $receiptAccepted -and -not [bool]$ContractFixtureMode
$notificationDispatchStatus = if ($realEmailSentAccepted) {
    "SENT_BY_LOCAL_AGENTLY_CLI"
}
elseif ($receiptAccepted -and [bool]$ContractFixtureMode) {
    "CONTRACT_RECEIPT_ACCEPTED_NOT_REAL_SEND"
}
else {
    "PENDING_LOCAL_MAIL_AUTH_AND_CONFIRMATION"
}

$checks = @()
Add-ReceiptCheck "outbox_source_available" `
    ($outboxManifest.status -eq "PASS" -and
        (Get-JsonValue $outboxManifest "notificationDispatchStatus" "") -eq "PENDING_LOCAL_MAIL_AUTH_AND_CONFIRMATION") `
    "Dispatch receipt intake must be based on a passing pending progress notification outbox."
Add-ReceiptCheck "receipt_file_parseable" `
    ($receiptExists -and $null -ne $receipt -and [string]::IsNullOrWhiteSpace($receiptParseError)) `
    "Receipt file must exist and parse as JSON."
Add-ReceiptCheck "receipt_content_matches_outbox" `
    ($receiptSchemaAccepted -and $recipientMatches -and $subjectMatches -and $messageIdPresent) `
    "Receipt must match the outbox recipient and subject and include a message id."
Add-ReceiptCheck "receipt_success_boundary" `
    ((Get-JsonValue $receipt "confirmationTokenSupplied" $false) -and
        (Get-JsonValue $receipt "sendSucceeded" $false) -and
        (Get-JsonValue $receipt "agentlyCliExitCode" -1) -eq 0 -and
        -not (Get-JsonValue $receipt "releasePipelineGenerated" $true)) `
    "Receipt must come from a token-confirmed local helper success, not from the release pipeline."
Add-ReceiptCheck "fake_receipt_rejected" `
    $fakeReceiptRejected `
    "Receipts produced by fake CLI probes must not be accepted as dispatch evidence."
Add-ReceiptCheck "fixture_boundary_preserved" `
    ((-not [bool]$ContractFixtureMode -and $receiptAccepted) -or
        ([bool]$ContractFixtureMode -and $receiptAccepted -and -not $realEmailSentAccepted)) `
    "Contract fixture mode may validate receipt shape but must not claim a real email send."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($receiptAccepted) { "PASS" } elseif ([bool]$RequireReceipt) { "FAIL" } else { "PENDING_RECEIPT" }

$generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
$reportLines = @(
    "# AI TestPilot Release Progress Notification Dispatch Receipt Intake",
    "",
    "Schema: ``aitestpilot.release_progress_notification_dispatch_receipt_intake.v1``",
    "Generated at UTC: $generatedAtUtc",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Status | $(Format-MarkdownCell $status) |",
    "| Receipt path | $(Format-MarkdownCell $receiptFullPath) |",
    "| Recipient | $(Format-MarkdownCell $recipient) |",
    "| Subject | $(Format-MarkdownCell $subject) |",
    "| Message id | $(Format-MarkdownCell $messageId) |",
    "| Contract fixture mode | $([bool]$ContractFixtureMode) |",
    "| Receipt accepted | $receiptAccepted |",
    "| Real email sent accepted | $realEmailSentAccepted |",
    "| Dispatch status | $(Format-MarkdownCell $notificationDispatchStatus) |",
    "",
    "## Boundary",
    "",
    "- Release pipeline does not send email.",
    "- Fake CLI probe receipts are rejected.",
    "- Contract fixture mode does not claim real email delivery.",
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

$files = @(
    (Split-Path $manifestFullPath -Leaf),
    (Split-Path $reportFullPath -Leaf),
    "release-progress-notification-outbox-manifest.json"
)
if ($receiptExists -and $receiptFullPath.StartsWith($evidenceBundlePath, [System.StringComparison]::OrdinalIgnoreCase)) {
    $files += $receiptFullPath.Substring($evidenceBundlePath.Length).TrimStart([char[]]@("\", "/")).Replace("\", "/")
}

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.release_progress_notification_dispatch_receipt_intake.v1"
    status = $status
    generatedAtUtc = $generatedAtUtc
    evidenceBundleDir = $evidenceBundlePath
    receiptPath = $receiptFullPath
    receiptExists = [bool]$receiptExists
    receiptParseError = $receiptParseError
    receiptAccepted = [bool]$receiptAccepted
    receiptSchemaAccepted = [bool]$receiptSchemaAccepted
    recipient = $recipient
    subject = $subject
    messageId = $messageId
    confirmationTokenSupplied = (Get-JsonValue $receipt "confirmationTokenSupplied" $false)
    agentlyCliExitCode = (Get-JsonValue $receipt "agentlyCliExitCode" $null)
    sendSucceeded = (Get-JsonValue $receipt "sendSucceeded" $false)
    releasePipelineGenerated = (Get-JsonValue $receipt "releasePipelineGenerated" $true)
    realDeliveryVerified = (Get-JsonValue $receipt "realDeliveryVerified" $false)
    contractFixtureMode = [bool]$ContractFixtureMode
    fakeReceiptRejected = [bool]$fakeReceiptRejected
    releasePipelineSendsEmail = $false
    realEmailSentAccepted = [bool]$realEmailSentAccepted
    emailSent = [bool]$realEmailSentAccepted
    notificationDispatchStatus = $notificationDispatchStatus
    canonicalOutboxEmailSent = (Get-JsonValue $outboxManifest "emailSent" $false)
    fixtureEvidencePromoted = $false
    productionOutputBoundary = if ($realEmailSentAccepted) {
        "progress_notification_real_dispatch_receipt_accepted"
    } elseif ($receiptAccepted -and [bool]$ContractFixtureMode) {
        "progress_notification_dispatch_receipt_contract_only"
    } else {
        "progress_notification_dispatch_receipt_not_accepted"
    }
    sourceFiles = @("release-progress-notification-outbox-manifest.json")
    generatedFiles = @($files | Where-Object { $_ -ne "release-progress-notification-outbox-manifest.json" })
    files = @($files)
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
}

New-Item -ItemType Directory -Force (Split-Path $manifestFullPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestFullPath -Encoding UTF8

if ([bool]$RequireReceipt -and $status -ne "PASS") {
    throw "Release progress notification dispatch receipt intake failed. Manifest: $manifestFullPath"
}

Write-Output "Release progress notification dispatch receipt intake manifest: $manifestFullPath"
Write-Output "AI TestPilot release progress notification dispatch receipt intake status: $status"
