[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$OutboxDir,
    [string]$ManifestPath,
    [string]$ReportPath,
    [string]$ProgressRecipient = "kibernet@sina.com"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($OutboxDir)) {
    $OutboxDir = Join-Path $EvidenceBundleDir "release-progress-notification-outbox"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "release-progress-notification-outbox-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "release-progress-notification-outbox.md"
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

function Add-OutboxCheck {
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
$outboxPath = Assert-PathUnderRepo $OutboxDir "OutboxDir"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if (Test-Path $outboxPath) {
    Remove-Item -LiteralPath $outboxPath -Recurse -Force
}
New-Item -ItemType Directory -Force $outboxPath | Out-Null

$ownerInputRequestManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-owner-input-request-pack-manifest.json") "Production handoff owner input request pack manifest"
$ownerContactExternalIntakeProbeManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-owner-contact-external-intake-probe-manifest.json") "Production handoff owner contact external intake probe manifest"
$sendDryRunProbeManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-send-dry-run-probe-manifest.json") "Production handoff send dry-run probe manifest"
$ownerResponseBundleProbeManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-owner-response-bundle-probe-manifest.json") "Production handoff owner response bundle probe manifest"
$ownerResponseBundleKitManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-owner-response-bundle-kit-manifest.json") "Production handoff owner response bundle kit manifest"
$ownerUnblockManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-owner-unblock-pack-manifest.json") "Production handoff owner unblock pack manifest"
$mailAuthReadinessManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-mail-auth-readiness-manifest.json") "Production handoff mail auth readiness manifest"
$sendReadinessManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-send-readiness-manifest.json") "Production handoff send readiness manifest"

$latestBigNodeName = "production_handoff_owner_response_bundle_kit"
$latestBigNodeStatus = [string](Get-JsonValue $ownerResponseBundleKitManifest "status" "")
$ownerInputRequestStatus = [string](Get-JsonValue $ownerInputRequestManifest "ownerInputRequestStatus" "")
$ownerUnblockStatus = [string](Get-JsonValue $ownerInputRequestManifest "ownerUnblockStatus" "")
$missingOwnerContactCount = Convert-ToInt (Get-JsonValue $ownerInputRequestManifest "missingOwnerContactCount" 0)
$pendingDispatchCount = Convert-ToInt (Get-JsonValue $ownerInputRequestManifest "pendingDispatchCount" 0)
$pendingOwnerPacketCount = Convert-ToInt (Get-JsonValue $ownerInputRequestManifest "pendingOwnerPacketCount" 0)
$missingRequiredFileCount = Convert-ToInt (Get-JsonValue $ownerInputRequestManifest "missingRequiredFileCount" 0)
$remainingBlockingReasonCount = Convert-ToInt (Get-JsonValue $ownerInputRequestManifest "remainingBlockingReasonCount" 0)
$blockedSendCount = Convert-ToInt (Get-JsonValue $ownerInputRequestManifest "blockedSendCount" 0)
$readySendCount = Convert-ToInt (Get-JsonValue $ownerInputRequestManifest "readySendCount" 0)
$sendReadinessStatus = [string](Get-JsonValue $ownerInputRequestManifest "sendReadinessStatus" "")
$mailAuthReadinessStatus = [string](Get-JsonValue $ownerInputRequestManifest "mailAuthReadinessStatus" "")
$externalContactIntakeAccepted = Convert-ToBool (Get-JsonValue $ownerContactExternalIntakeProbeManifest "externalContactIntakeAccepted" $false)
$externalSendReadyForConfirmation = Convert-ToBool (Get-JsonValue $ownerContactExternalIntakeProbeManifest "externalSendReadyForConfirmation" $false)
$sendDryRunAuthorizationFree = Convert-ToBool (Get-JsonValue $sendDryRunProbeManifest "authorizationNotRequiredForDryRun" $false)
$defaultDryRunBlockedPreviewCount = Convert-ToInt (Get-JsonValue $sendDryRunProbeManifest "defaultBlockedPreviewCount" 0)
$acceptedContactDryRunPreparedPreviewCount = Convert-ToInt (Get-JsonValue $sendDryRunProbeManifest "acceptedContactPreparedPreviewCount" 0)
$ownerResponseBundleAccepted = Convert-ToBool (Get-JsonValue $ownerResponseBundleProbeManifest "ownerResponseReadyForConfirmation" $false)
$ownerResponseEvidenceComplete = Convert-ToBool (Get-JsonValue $ownerResponseBundleProbeManifest "ownerResponseEvidenceComplete" $false)
$ownerResponseDryRunPreparedPreviewCount = Convert-ToInt (Get-JsonValue $ownerResponseBundleProbeManifest "dryRunPreparedPreviewCount" 0)
$ownerResponseBundleOutsideRepo = Convert-ToBool (Get-JsonValue $ownerResponseBundleProbeManifest "externalResponseBundleOutsideRepo" $false)
$ownerResponseBundleKitGenerated = Convert-ToBool (Get-JsonValue $ownerResponseBundleKitManifest "responseBundleTemplateGenerated" $false)
$ownerResponseBundleKitZipGenerated = Convert-ToBool (Get-JsonValue $ownerResponseBundleKitManifest "zipGenerated" $false)
$ownerResponseBundleKitRequiredFileCount = Convert-ToInt (Get-JsonValue $ownerResponseBundleKitManifest "requiredEvidenceFileCount" 0)
$notificationSubject = "AI TestPilot progress - owner response bundle kit ready"
$notificationDispatchStatus = "PENDING_LOCAL_MAIL_AUTH_AND_CONFIRMATION"

$statusPath = Join-Path $outboxPath "notification-status.json"
$emailDraftPath = Join-Path $outboxPath "big-node-progress-email.md"
$sendHelperPath = Join-Path $outboxPath "send-progress-notification.ps1"
$readmePath = Join-Path $outboxPath "README.md"

$status = [ordered]@{
    schemaVersion = "aitestpilot.release_progress_notification_status.v1"
    status = "PENDING_SEND"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    recipient = $ProgressRecipient
    subject = $notificationSubject
    latestBigNodeName = $latestBigNodeName
    latestBigNodeStatus = $latestBigNodeStatus
    ownerInputRequestStatus = $ownerInputRequestStatus
    ownerUnblockStatus = $ownerUnblockStatus
    externalContactIntakeAccepted = [bool]$externalContactIntakeAccepted
    externalSendReadyForConfirmation = [bool]$externalSendReadyForConfirmation
    sendDryRunAuthorizationFree = [bool]$sendDryRunAuthorizationFree
    defaultDryRunBlockedPreviewCount = [int]$defaultDryRunBlockedPreviewCount
    acceptedContactDryRunPreparedPreviewCount = [int]$acceptedContactDryRunPreparedPreviewCount
    ownerResponseBundleAccepted = [bool]$ownerResponseBundleAccepted
    ownerResponseEvidenceComplete = [bool]$ownerResponseEvidenceComplete
    ownerResponseDryRunPreparedPreviewCount = [int]$ownerResponseDryRunPreparedPreviewCount
    ownerResponseBundleOutsideRepo = [bool]$ownerResponseBundleOutsideRepo
    ownerResponseBundleKitGenerated = [bool]$ownerResponseBundleKitGenerated
    ownerResponseBundleKitZipGenerated = [bool]$ownerResponseBundleKitZipGenerated
    ownerResponseBundleKitRequiredFileCount = [int]$ownerResponseBundleKitRequiredFileCount
    notificationDispatchStatus = $notificationDispatchStatus
    mailAuthReadinessStatus = $mailAuthReadinessStatus
    sendReadinessStatus = $sendReadinessStatus
    missingOwnerContactCount = [int]$missingOwnerContactCount
    pendingDispatchCount = [int]$pendingDispatchCount
    pendingOwnerPacketCount = [int]$pendingOwnerPacketCount
    missingRequiredFileCount = [int]$missingRequiredFileCount
    remainingBlockingReasonCount = [int]$remainingBlockingReasonCount
    blockedSendCount = [int]$blockedSendCount
    readySendCount = [int]$readySendCount
    automaticEmailSendReady = $false
    mailAuthorizationCheckedByPipeline = $false
    releasePipelineSendsEmail = $false
    emailSent = $false
    confirmationTokenCreated = $false
    twoStageConfirmationRequired = $true
    realHostProjectEvidenceAccepted = $false
    externalEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
}
$status | ConvertTo-Json -Depth 8 | Set-Content -Path $statusPath -Encoding UTF8

$emailDraftLines = @(
    "To: $ProgressRecipient",
    "Subject: $notificationSubject",
    "",
    "AI TestPilot big-node progress update:",
    "",
    "- Latest completed node: $latestBigNodeName",
    "- Node status: $latestBigNodeStatus",
    "- External owner contact intake accepted: $externalContactIntakeAccepted",
    "- External-contact send readiness path: $externalSendReadyForConfirmation",
    "- Send dry run works without local mail authorization: $sendDryRunAuthorizationFree",
    "- Default dry-run blocked previews: $defaultDryRunBlockedPreviewCount",
    "- Accepted-contact dry-run prepared previews: $acceptedContactDryRunPreparedPreviewCount",
    "- Owner response bundle path ready: $ownerResponseBundleAccepted",
    "- Owner response evidence complete in contract fixture: $ownerResponseEvidenceComplete",
    "- Owner response dry-run prepared previews: $ownerResponseDryRunPreparedPreviewCount",
    "- Owner response bundle generated outside repo: $ownerResponseBundleOutsideRepo",
    "- Owner response bundle kit generated: $ownerResponseBundleKitGenerated",
    "- Owner response bundle kit zip generated: $ownerResponseBundleKitZipGenerated",
    "- Owner response bundle kit required evidence files: $ownerResponseBundleKitRequiredFileCount",
    "- Release evidence boundary: repo-side package/gate evidence remains PASS; production completion still needs external owner input.",
    "- Owner input request status: $ownerInputRequestStatus",
    "- Owner unblock status: $ownerUnblockStatus",
    "",
    "Remaining external items:",
    "",
    "- Missing owner contacts: $missingOwnerContactCount",
    "- Pending dispatches: $pendingDispatchCount",
    "- Pending owner packets: $pendingOwnerPacketCount",
    "- Missing required evidence files: $missingRequiredFileCount",
    "- Remaining blocking reasons: $remainingBlockingReasonCount",
    "- Blocked sends: $blockedSendCount",
    "- Ready sends: $readySendCount",
    "",
    "Generated artifacts:",
    "",
    "- production-handoff-owner-input-request-pack-manifest.json",
    "- production-handoff-owner-input-request-pack.md",
    "- production-handoff-owner-input-request-pack/",
    "- production-handoff-owner-contact-external-intake-probe-manifest.json",
    "- production-handoff-owner-contact-external-intake-probe.md",
    "- production-handoff-send-dry-run-probe-manifest.json",
    "- production-handoff-send-dry-run-probe.md",
    "- production-handoff-owner-response-bundle-probe-manifest.json",
    "- production-handoff-owner-response-bundle-probe.md",
    "- production-handoff-owner-response-bundle-kit-manifest.json",
    "- production-handoff-owner-response-bundle-kit.md",
    "- production-handoff-owner-response-bundle-kit.zip",
    "- release-progress-notification-outbox-manifest.json",
    "- release-progress-notification-outbox/",
    "",
    "Mail boundary:",
    "",
    "- This notification is prepared but not sent by CI.",
    "- Local agently-cli authorization is still required before send.",
    "- The CLI send flow requires a two-stage confirmation token.",
    "- Real host-project evidence has not been accepted.",
    "- Fixture evidence has not been promoted."
)
$emailDraftLines | Set-Content -Path $emailDraftPath -Encoding UTF8

$sendHelperLines = @(
    "[CmdletBinding()]",
    "param(",
    "    [string]`$EvidenceBundleDir = (Resolve-Path (Join-Path `$PSScriptRoot '..')).Path,",
    "    [switch]`$PrepareConfirmation,",
    "    [string]`$ConfirmationToken",
    ")",
    "",
    "Set-StrictMode -Version Latest",
    "`$ErrorActionPreference = 'Stop'",
    "",
    "`$recipient = '$ProgressRecipient'",
    "`$subject = '$notificationSubject'",
    "`$bodyFile = '.\release-progress-notification-outbox\big-node-progress-email.md'",
    "",
    "function Read-JsonOutput {",
    "    param([string[]]`$Lines)",
    "    `$text = `$Lines -join [Environment]::NewLine",
    "    `$start = `$text.IndexOf('{')",
    "    `$end = `$text.LastIndexOf('}')",
    "    if (`$start -lt 0 -or `$end -lt `$start) { throw 'Command output did not contain a JSON object.' }",
    "    return `$text.Substring(`$start, `$end - `$start + 1) | ConvertFrom-Json",
    "}",
    "",
    "`$authStatusRaw = & agently-cli auth status",
    "`$authStatus = Read-JsonOutput `$authStatusRaw",
    "if (-not [bool]`$authStatus.data.logged_in) { throw 'agently-cli is not logged in. Run agently-cli auth login before preparing progress notification sends.' }",
    "& agently-cli +me | Out-Null",
    "",
    "`$args = @('message', '+send', '--to', `$recipient, '--subject', `$subject, '--body-file', `$bodyFile)",
    "if (-not [string]::IsNullOrWhiteSpace(`$ConfirmationToken)) {",
    "    `$args += @('--confirmation-token', `$ConfirmationToken)",
    "}",
    "elseif (-not `$PrepareConfirmation) {",
    "    Write-Output 'Dry run only. Pass -PrepareConfirmation to request a confirmation token, then rerun with -ConfirmationToken after operator approval.'",
    "    Write-Output ('Prepared send command for ' + `$recipient + ' with subject: ' + `$subject)",
    "    return",
    "}",
    "",
    "Push-Location `$EvidenceBundleDir",
    "try {",
    "    & agently-cli @args",
    "}",
    "finally {",
    "    Pop-Location",
    "}"
)
$sendHelperLines | Set-Content -Path $sendHelperPath -Encoding UTF8

$readmeLines = @(
    "# AI TestPilot Release Progress Notification Outbox",
    "",
    "This folder stores the prepared big-node progress notification for the current release evidence bundle.",
    "",
    "Files:",
    "",
    "- ``notification-status.json``: machine-readable pending notification state.",
    "- ``big-node-progress-email.md``: prepared email body for ``$ProgressRecipient``.",
    "- ``send-progress-notification.ps1``: local helper for the agently-cli two-stage send flow.",
    "",
    "The release pipeline does not send email, run OAuth login, or create confirmation tokens.",
    "",
    "Local workflow after agently-cli authorization:",
    "",
    "1. Run ``agently-cli auth status`` and ``agently-cli +me``.",
    "2. Run ``.\release-progress-notification-outbox\send-progress-notification.ps1 -PrepareConfirmation`` from the evidence bundle.",
    "3. If agently-cli returns a confirmation token, rerun the helper with ``-ConfirmationToken`` only after explicit operator approval."
)
$readmeLines | Set-Content -Path $readmePath -Encoding UTF8

$reportLines = @(
    "# AI TestPilot Release Progress Notification Outbox",
    "",
    "Schema: ``aitestpilot.release_progress_notification_outbox.v1``",
    "Generated at UTC: $((Get-Date).ToUniversalTime().ToString("O"))",
    "",
    "## Summary",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Recipient | $(Format-MarkdownCell $ProgressRecipient) |",
    "| Subject | $(Format-MarkdownCell $notificationSubject) |",
    "| Latest big node | $(Format-MarkdownCell $latestBigNodeName) |",
    "| Latest big node status | $(Format-MarkdownCell $latestBigNodeStatus) |",
    "| External owner contact intake accepted | $externalContactIntakeAccepted |",
    "| External-contact send readiness path | $externalSendReadyForConfirmation |",
    "| Send dry run works without local mail authorization | $sendDryRunAuthorizationFree |",
    "| Default dry-run blocked previews | $defaultDryRunBlockedPreviewCount |",
    "| Accepted-contact dry-run prepared previews | $acceptedContactDryRunPreparedPreviewCount |",
    "| Owner response bundle path ready | $ownerResponseBundleAccepted |",
    "| Owner response evidence complete | $ownerResponseEvidenceComplete |",
    "| Owner response dry-run prepared previews | $ownerResponseDryRunPreparedPreviewCount |",
    "| Owner response bundle outside repo | $ownerResponseBundleOutsideRepo |",
    "| Owner response bundle kit generated | $ownerResponseBundleKitGenerated |",
    "| Owner response bundle kit zip generated | $ownerResponseBundleKitZipGenerated |",
    "| Owner response bundle kit required files | $ownerResponseBundleKitRequiredFileCount |",
    "| Notification dispatch status | $(Format-MarkdownCell $notificationDispatchStatus) |",
    "| Owner input request status | $(Format-MarkdownCell $ownerInputRequestStatus) |",
    "| Missing owner contacts | $missingOwnerContactCount |",
    "| Pending dispatches | $pendingDispatchCount |",
    "| Pending owner packets | $pendingOwnerPacketCount |",
    "| Missing required evidence files | $missingRequiredFileCount |",
    "| Remaining blocking reasons | $remainingBlockingReasonCount |",
    "| Blocked sends | $blockedSendCount |",
    "| Ready sends | $readySendCount |",
    "| Mail auth readiness | $(Format-MarkdownCell $mailAuthReadinessStatus) |",
    "",
    "## Boundary",
    "",
    "- Prepared notification only; emailSent=false.",
    "- Release pipeline does not send email.",
    "- Local agently-cli authorization and two-stage confirmation are required.",
    "- Real host-project evidence has not been accepted.",
    "- Fixture evidence has not been promoted."
)
$reportLines | Set-Content -Path $reportFullPath -Encoding UTF8

$statusContent = Get-Content -Path $statusPath -Encoding UTF8 -Raw
$emailDraftContent = Get-Content -Path $emailDraftPath -Encoding UTF8 -Raw
$sendHelperContent = Get-Content -Path $sendHelperPath -Encoding UTF8 -Raw
$readmeContent = Get-Content -Path $readmePath -Encoding UTF8 -Raw
$reportContent = Get-Content -Path $reportFullPath -Encoding UTF8 -Raw
$noObjectLeakage = -not $statusContent.Contains("System.Collections") -and -not $statusContent.Contains("@{") -and
    -not $emailDraftContent.Contains("System.Collections") -and -not $emailDraftContent.Contains("@{") -and
    -not $sendHelperContent.Contains("System.Collections") -and -not $sendHelperContent.Contains("@{") -and
    -not $readmeContent.Contains("System.Collections") -and -not $readmeContent.Contains("@{") -and
    -not $reportContent.Contains("System.Collections") -and -not $reportContent.Contains("@{")

$statusContentValidated = $statusContent.Contains("release_progress_notification_status.v1") -and
    $statusContent.Contains($ProgressRecipient) -and
    $statusContent.Contains($notificationDispatchStatus) -and
    $statusContent.Contains($latestBigNodeName) -and
    $noObjectLeakage
$emailDraftContentValidated = $emailDraftContent.Contains($ProgressRecipient) -and
    $emailDraftContent.Contains($notificationSubject) -and
    $emailDraftContent.Contains($latestBigNodeName) -and
    $emailDraftContent.Contains("Missing owner contacts: $missingOwnerContactCount") -and
    $emailDraftContent.Contains("prepared but not sent") -and
    $noObjectLeakage
$sendHelperContentValidated = $sendHelperContent.Contains("agently-cli auth status") -and
    $sendHelperContent.Contains("Read-JsonOutput") -and
    $sendHelperContent.Contains("Command output did not contain a JSON object.") -and
    $sendHelperContent.Contains("message', '+send") -and
    $sendHelperContent.Contains("--confirmation-token") -and
    $sendHelperContent.Contains("-PrepareConfirmation") -and
    $noObjectLeakage
$readmeContentValidated = $readmeContent.Contains("two-stage send flow") -and
    $readmeContent.Contains("does not send email") -and
    $readmeContent.Contains("agently-cli auth status") -and
    $noObjectLeakage
$reportContentValidated = $reportContent.Contains("Release Progress Notification Outbox") -and
    $reportContent.Contains($notificationDispatchStatus) -and
    $reportContent.Contains("emailSent=false") -and
    $reportContent.Contains("two-stage confirmation") -and
    $noObjectLeakage

$checks = @()
Add-OutboxCheck "progress_notification_sources_available" `
    ($ownerInputRequestManifest.status -eq "PASS" -and $ownerContactExternalIntakeProbeManifest.status -eq "PASS" -and $sendDryRunProbeManifest.status -eq "PASS" -and $ownerResponseBundleProbeManifest.status -eq "PASS" -and $ownerResponseBundleKitManifest.status -eq "PASS" -and $ownerUnblockManifest.status -eq "PASS" -and $mailAuthReadinessManifest.status -eq "PASS" -and $sendReadinessManifest.status -eq "PASS") `
    "Progress notification outbox must be based on passing owner input request, owner contact external intake, send dry-run, owner response bundle, owner response bundle kit, owner unblock, mail-auth readiness, and send readiness evidence."
Add-OutboxCheck "progress_notification_latest_big_node_accepted" `
    ($latestBigNodeName -eq "production_handoff_owner_response_bundle_kit" -and
        $latestBigNodeStatus -eq "PASS" -and
        $externalContactIntakeAccepted -and
        $externalSendReadyForConfirmation -and
        $sendDryRunAuthorizationFree -and
        $defaultDryRunBlockedPreviewCount -gt 0 -and
        $acceptedContactDryRunPreparedPreviewCount -gt 0 -and
        $ownerResponseBundleAccepted -and
        $ownerResponseEvidenceComplete -and
        $ownerResponseDryRunPreparedPreviewCount -gt 0 -and
        $ownerResponseBundleOutsideRepo -and
        $ownerResponseBundleKitGenerated -and
        $ownerResponseBundleKitZipGenerated -and
        $ownerResponseBundleKitRequiredFileCount -gt 0 -and
        -not (Convert-ToBool (Get-JsonValue $ownerResponseBundleKitManifest "emailSent" $true))) `
    "Progress notification outbox must report the latest owner response bundle kit node without claiming email was sent."
Add-OutboxCheck "progress_notification_counts_match_owner_input" `
    ($missingOwnerContactCount -eq (Convert-ToInt (Get-JsonValue $ownerUnblockManifest "missingOwnerContactCount" -1)) -and
        $pendingDispatchCount -eq (Convert-ToInt (Get-JsonValue $ownerUnblockManifest "pendingDispatchCount" -1)) -and
        $pendingOwnerPacketCount -eq (Convert-ToInt (Get-JsonValue $ownerUnblockManifest "pendingOwnerPacketCount" -1)) -and
        $missingRequiredFileCount -eq (Convert-ToInt (Get-JsonValue $ownerUnblockManifest "missingRequiredFileCount" -1)) -and
        $remainingBlockingReasonCount -eq (Convert-ToInt (Get-JsonValue $ownerUnblockManifest "remainingBlockingReasonCount" -1)) -and
        $blockedSendCount -eq (Convert-ToInt (Get-JsonValue $sendReadinessManifest "blockedSendCount" -1)) -and
        $readySendCount -eq (Convert-ToInt (Get-JsonValue $sendReadinessManifest "readySendCount" -1))) `
    "Progress notification outbox counts must match the owner input and unblock source manifests."
Add-OutboxCheck "progress_notification_files_generated" `
    ((Test-Path $statusPath) -and (Test-Path $emailDraftPath) -and (Test-Path $sendHelperPath) -and (Test-Path $readmePath) -and (Test-Path $reportFullPath)) `
    "Progress notification outbox must generate status, email draft, send helper, README, and report files."
Add-OutboxCheck "progress_notification_content_validated" `
    ($statusContentValidated -and $emailDraftContentValidated -and $sendHelperContentValidated -and $readmeContentValidated -and $reportContentValidated) `
    "Progress notification outbox files must contain recipient, subject, node, counts, agently-cli send flow, and not-sent boundary text."
Add-OutboxCheck "progress_notification_mail_boundary_preserved" `
    ($notificationDispatchStatus -eq "PENDING_LOCAL_MAIL_AUTH_AND_CONFIRMATION" -and
        $mailAuthReadinessStatus -eq "BLOCKED_NOT_CHECKED_BY_RELEASE_PIPELINE" -and
        -not (Convert-ToBool (Get-JsonValue $mailAuthReadinessManifest "mailAuthorizationCheckedByPipeline" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $mailAuthReadinessManifest "automaticEmailSendReady" $true))) `
    "Progress notification outbox must not claim local mail authorization, automatic send readiness, or sent email."
Add-OutboxCheck "progress_notification_evidence_boundary_preserved" `
    (-not (Convert-ToBool (Get-JsonValue $ownerInputRequestManifest "realHostProjectEvidenceAccepted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $ownerInputRequestManifest "externalEvidenceAccepted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $ownerInputRequestManifest "fixtureEvidencePromoted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $ownerInputRequestManifest "releasePipelineUsesFixture" $true))) `
    "Progress notification outbox must preserve real-evidence and fixture boundaries."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$manifestStatus = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestFullPath),
    (Convert-ToEvidenceRelativePath $reportFullPath),
    (Convert-ToEvidenceRelativePath $statusPath),
    (Convert-ToEvidenceRelativePath $emailDraftPath),
    (Convert-ToEvidenceRelativePath $sendHelperPath),
    (Convert-ToEvidenceRelativePath $readmePath)
)
$sourceFiles = @(
    "production-handoff-owner-input-request-pack-manifest.json",
    "production-handoff-owner-contact-external-intake-probe-manifest.json",
    "production-handoff-send-dry-run-probe-manifest.json",
    "production-handoff-owner-response-bundle-probe-manifest.json",
    "production-handoff-owner-response-bundle-kit-manifest.json",
    "production-handoff-owner-unblock-pack-manifest.json",
    "production-handoff-mail-auth-readiness-manifest.json",
    "production-handoff-send-readiness-manifest.json"
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.release_progress_notification_outbox.v1"
    status = $manifestStatus
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    outboxDir = $outboxPath
    reportPath = $reportFullPath
    recipient = $ProgressRecipient
    subject = $notificationSubject
    latestBigNodeName = $latestBigNodeName
    latestBigNodeStatus = $latestBigNodeStatus
    ownerInputRequestStatus = $ownerInputRequestStatus
    ownerUnblockStatus = $ownerUnblockStatus
    externalContactIntakeAccepted = [bool]$externalContactIntakeAccepted
    externalSendReadyForConfirmation = [bool]$externalSendReadyForConfirmation
    sendDryRunAuthorizationFree = [bool]$sendDryRunAuthorizationFree
    defaultDryRunBlockedPreviewCount = [int]$defaultDryRunBlockedPreviewCount
    acceptedContactDryRunPreparedPreviewCount = [int]$acceptedContactDryRunPreparedPreviewCount
    ownerResponseBundleAccepted = [bool]$ownerResponseBundleAccepted
    ownerResponseEvidenceComplete = [bool]$ownerResponseEvidenceComplete
    ownerResponseDryRunPreparedPreviewCount = [int]$ownerResponseDryRunPreparedPreviewCount
    ownerResponseBundleOutsideRepo = [bool]$ownerResponseBundleOutsideRepo
    ownerResponseBundleKitGenerated = [bool]$ownerResponseBundleKitGenerated
    ownerResponseBundleKitZipGenerated = [bool]$ownerResponseBundleKitZipGenerated
    ownerResponseBundleKitRequiredFileCount = [int]$ownerResponseBundleKitRequiredFileCount
    notificationDispatchStatus = $notificationDispatchStatus
    statusGenerated = (Test-Path $statusPath)
    progressEmailDraftGenerated = (Test-Path $emailDraftPath)
    sendHelperGenerated = (Test-Path $sendHelperPath)
    readmeGenerated = (Test-Path $readmePath)
    reportGenerated = (Test-Path $reportFullPath)
    statusContentValidated = [bool]$statusContentValidated
    progressEmailDraftContentValidated = [bool]$emailDraftContentValidated
    sendHelperContentValidated = [bool]$sendHelperContentValidated
    readmeContentValidated = [bool]$readmeContentValidated
    reportContentValidated = [bool]$reportContentValidated
    missingOwnerContactCount = [int]$missingOwnerContactCount
    pendingDispatchCount = [int]$pendingDispatchCount
    pendingOwnerPacketCount = [int]$pendingOwnerPacketCount
    missingRequiredFileCount = [int]$missingRequiredFileCount
    remainingBlockingReasonCount = [int]$remainingBlockingReasonCount
    blockedSendCount = [int]$blockedSendCount
    readySendCount = [int]$readySendCount
    sendReadinessStatus = $sendReadinessStatus
    mailAuthReadinessStatus = $mailAuthReadinessStatus
    automaticEmailSendReady = $false
    mailAuthorizationCheckedByPipeline = $false
    releasePipelineSendsEmail = $false
    emailSent = $false
    confirmationTokenCreated = $false
    twoStageConfirmationRequired = $true
    releasePipelineUsesFixture = $false
    realHostProjectEvidenceAccepted = $false
    externalEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "release_progress_notification_outbox_only"
    sourceFiles = @($sourceFiles)
    generatedFiles = @($generatedFiles)
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
    files = @($generatedFiles + $sourceFiles)
}

New-Item -ItemType Directory -Force (Split-Path $manifestFullPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFullPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Release progress notification outbox failed: $($failedChecks.name -join ', ')"
}

Write-Output "Release progress notification outbox manifest: $manifestFullPath"
Write-Output "Release progress notification outbox report: $reportFullPath"
Write-Output "PASS AI TestPilot release progress notification outbox"
