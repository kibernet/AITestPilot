[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$DispatchReceiptIntakePath,
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

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "release-progress-notification-post-dispatch-snapshot-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "release-progress-notification-post-dispatch-snapshot.md"
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

function Join-TextList {
    param([object[]]$Values)

    $items = @($Values | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($items.Count -eq 0) {
        return "(none)"
    }

    return [string]::Join(", ", $items)
}

function Add-PostDispatchCheck {
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
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

$outboxManifestPath = Join-Path $evidenceBundlePath "release-progress-notification-outbox-manifest.json"
$snapshotPath = Join-Path $evidenceBundlePath "release-progress-notification-outbox\remaining-work-snapshot.json"
$snapshotMarkdownPath = Join-Path $evidenceBundlePath "release-progress-notification-outbox\remaining-work-snapshot.md"
if ([string]::IsNullOrWhiteSpace($DispatchReceiptIntakePath)) {
    $DispatchReceiptIntakePath = Join-Path $evidenceBundlePath "release-progress-notification-dispatch-receipt-intake-manifest.json"
}
$dispatchIntakePath = Assert-PathUnderRepo $DispatchReceiptIntakePath "DispatchReceiptIntakePath"

$outboxManifest = Read-JsonFile $outboxManifestPath "Release progress notification outbox manifest"
$sourceSnapshot = Read-JsonFile $snapshotPath "Release progress notification remaining-work snapshot"
$dispatchIntake = Read-JsonFile $dispatchIntakePath "Release progress notification dispatch receipt intake manifest"
$dispatchIntakeRelativePath = Convert-ToEvidenceRelativePath $dispatchIntakePath

$generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
$sourceItems = @(Convert-ToArray (Get-JsonValue $sourceSnapshot "externalRemainingWorkItems" @()))
$areaNames = @($sourceItems | ForEach-Object { [string](Get-JsonValue $_ "area" "") })
$sourceLocalMailItem = Get-JsonValue $sourceSnapshot "localProgressMailWorkItem" $null

$externalWorkItemCount = Convert-ToInt (Get-JsonValue $sourceSnapshot "externalRemainingWorkItemCount" 0)
$externalBlockingReasonCount = Convert-ToInt (Get-JsonValue $sourceSnapshot "externalRemainingBlockingReasonCount" 0)
$externalMissingFileCount = Convert-ToInt (Get-JsonValue $sourceSnapshot "externalRemainingMissingFileCount" 0)
$sourceLocalProgressMailRemainingActionCount = Convert-ToInt (Get-JsonValue $sourceSnapshot "localProgressMailRemainingActionCount" 0)
$sourceTrackedRemainingWorkItemCount = Convert-ToInt (Get-JsonValue $sourceSnapshot "trackedRemainingWorkItemCount" 0)

$receiptAccepted = Convert-ToBool (Get-JsonValue $dispatchIntake "receiptAccepted" $false)
$realEmailSentAccepted = Convert-ToBool (Get-JsonValue $dispatchIntake "realEmailSentAccepted" $false)
$operatorRealSendConfirmed = Convert-ToBool (Get-JsonValue $dispatchIntake "operatorRealSendConfirmed" $false)
$dispatchEvidencePresent = Convert-ToBool (Get-JsonValue $dispatchIntake "dispatchEvidencePresent" $false)
$receiptQueued = Convert-ToBool (Get-JsonValue $dispatchIntake "queued" $false)
$receiptMessageId = [string](Get-JsonValue $dispatchIntake "messageId" "")
$dispatchStatus = [string](Get-JsonValue $dispatchIntake "notificationDispatchStatus" "")
$dispatchEmailSent = Convert-ToBool (Get-JsonValue $dispatchIntake "emailSent" $false)
$dispatchReleasePipelineSendsEmail = Convert-ToBool (Get-JsonValue $dispatchIntake "releasePipelineSendsEmail" $true)

$postDispatchLocalProgressMailRemainingActionCount = if ($realEmailSentAccepted) { 0 } else { 1 }
$postDispatchTrackedRemainingWorkItemCount = $externalWorkItemCount + $postDispatchLocalProgressMailRemainingActionCount

$completedProgressMailWorkItem = [ordered]@{
    area = "release_progress_notification_send"
    status = $dispatchStatus
    recipient = [string](Get-JsonValue $dispatchIntake "recipient" "")
    subject = [string](Get-JsonValue $dispatchIntake "subject" "")
    remainingActionCount = [int]$postDispatchLocalProgressMailRemainingActionCount
    receiptPath = [string](Get-JsonValue $dispatchIntake "receiptPath" "")
    receiptQueued = [bool]$receiptQueued
    messageId = $receiptMessageId
    dispatchEvidencePresent = [bool]$dispatchEvidencePresent
    operatorRealSendConfirmed = [bool]$operatorRealSendConfirmed
    emailSent = [bool]$realEmailSentAccepted
}

$checks = @()
Add-PostDispatchCheck "post_dispatch_sources_available" `
    ((Get-JsonValue $outboxManifest "status" "") -eq "PASS" -and
        (Get-JsonValue $sourceSnapshot "status" "") -eq "PASS" -and
        (Get-JsonValue $dispatchIntake "status" "") -eq "PASS" -and
        (Test-Path $snapshotMarkdownPath)) `
    "Post-dispatch snapshot must read a passing outbox, source remaining-work snapshot, receipt intake manifest, and Markdown source snapshot."
Add-PostDispatchCheck "real_dispatch_receipt_accepted" `
    ($receiptAccepted -and
        $realEmailSentAccepted -and
        $operatorRealSendConfirmed -and
        $dispatchEvidencePresent -and
        $dispatchEmailSent -and
        $dispatchStatus -eq "SENT_BY_LOCAL_AGENTLY_CLI" -and
        -not (Convert-ToBool (Get-JsonValue $dispatchIntake "contractFixtureMode" $true)) -and
        -not $dispatchReleasePipelineSendsEmail) `
    "Post-dispatch snapshot may clear local mail only after a real, operator-confirmed local agently-cli send receipt is accepted."
Add-PostDispatchCheck "remaining_external_work_preserved" `
    ($externalWorkItemCount -eq 3 -and
        $sourceItems.Count -eq 3 -and
        $areaNames -contains "production_driver_binding" -and
        $areaNames -contains "production_lua_patch_evidence" -and
        $areaNames -contains "live_model_endpoint_smoke" -and
        $externalBlockingReasonCount -eq 11 -and
        $externalMissingFileCount -eq 9) `
    "Post-dispatch snapshot must preserve the three external owner areas, eleven blockers, and nine missing required evidence files."
Add-PostDispatchCheck "local_mail_remaining_work_cleared" `
    ($sourceLocalProgressMailRemainingActionCount -eq 1 -and
        $sourceTrackedRemainingWorkItemCount -eq 4 -and
        $null -ne $sourceLocalMailItem -and
        (Get-JsonValue $sourceLocalMailItem "status" "") -eq "PENDING_LOCAL_MAIL_AUTH_AND_CONFIRMATION" -and
        $postDispatchLocalProgressMailRemainingActionCount -eq 0 -and
        $postDispatchTrackedRemainingWorkItemCount -eq 3) `
    "Post-dispatch snapshot must reduce tracked remaining work from four items to the three external owner areas."
Add-PostDispatchCheck "production_evidence_boundary_preserved" `
    (-not (Convert-ToBool (Get-JsonValue $dispatchIntake "realDeliveryVerified" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $sourceSnapshot "realHostProjectEvidenceAccepted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $sourceSnapshot "externalEvidenceAccepted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $sourceSnapshot "fixtureEvidencePromoted" $true))) `
    "Clearing the local progress-mail action must not claim real delivery verification, host-project evidence acceptance, or fixture promotion."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$sourceFiles = @(
    "release-progress-notification-outbox-manifest.json",
    "release-progress-notification-outbox/remaining-work-snapshot.json",
    "release-progress-notification-outbox/remaining-work-snapshot.md",
    $dispatchIntakeRelativePath
)
$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestFullPath),
    (Convert-ToEvidenceRelativePath $reportFullPath)
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.release_progress_notification_post_dispatch_snapshot.v1"
    status = $status
    generatedAtUtc = $generatedAtUtc
    evidenceBundleDir = $evidenceBundlePath
    sourceSnapshotPath = $snapshotPath
    dispatchReceiptIntakePath = $dispatchIntakePath
    recipient = [string](Get-JsonValue $dispatchIntake "recipient" "")
    subject = [string](Get-JsonValue $dispatchIntake "subject" "")
    latestBigNodeName = [string](Get-JsonValue $sourceSnapshot "latestBigNodeName" "")
    latestBigNodeStatus = [string](Get-JsonValue $sourceSnapshot "latestBigNodeStatus" "")
    sourceNotificationDispatchStatus = [string](Get-JsonValue $sourceSnapshot "notificationDispatchStatus" "")
    notificationDispatchStatus = $dispatchStatus
    receiptAccepted = [bool]$receiptAccepted
    receiptQueued = [bool]$receiptQueued
    receiptMessageId = $receiptMessageId
    dispatchEvidencePresent = [bool]$dispatchEvidencePresent
    operatorRealSendConfirmed = [bool]$operatorRealSendConfirmed
    realEmailSentAccepted = [bool]$realEmailSentAccepted
    progressNotificationEmailSent = [bool]$realEmailSentAccepted
    emailSent = [bool]$realEmailSentAccepted
    releasePipelineSendsEmail = $false
    sourceLocalProgressMailRemainingActionCount = [int]$sourceLocalProgressMailRemainingActionCount
    sourceTrackedRemainingWorkItemCount = [int]$sourceTrackedRemainingWorkItemCount
    localProgressMailRemainingActionCount = [int]$postDispatchLocalProgressMailRemainingActionCount
    trackedRemainingWorkItemCount = [int]$postDispatchTrackedRemainingWorkItemCount
    externalRemainingWorkItemCount = [int]$externalWorkItemCount
    externalRemainingBlockingReasonCount = [int]$externalBlockingReasonCount
    externalRemainingMissingFileCount = [int]$externalMissingFileCount
    externalRemainingWorkItems = @($sourceItems)
    completedProgressMailWorkItem = $completedProgressMailWorkItem
    realDeliveryVerified = $false
    realHostProjectEvidenceAccepted = $false
    externalEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = if ($status -eq "PASS") {
        "release_progress_notification_post_dispatch_snapshot_only"
    } else {
        "release_progress_notification_post_dispatch_snapshot_not_accepted"
    }
    sourceFiles = @($sourceFiles)
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles + $sourceFiles)
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
}

$reportLines = @(
    "# AI TestPilot Release Progress Notification Post-Dispatch Snapshot",
    "",
    "Schema: ``aitestpilot.release_progress_notification_post_dispatch_snapshot.v1``",
    "Generated at UTC: $generatedAtUtc",
    "",
    "## Summary",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Status | $(Format-MarkdownCell $status) |",
    "| Dispatch status | $(Format-MarkdownCell $dispatchStatus) |",
    "| Email sent accepted | $realEmailSentAccepted |",
    "| Receipt queued | $receiptQueued |",
    "| Dispatch evidence present | $dispatchEvidencePresent |",
    "| Local progress mail remaining actions | $postDispatchLocalProgressMailRemainingActionCount |",
    "| Tracked remaining work items | $postDispatchTrackedRemainingWorkItemCount |",
    "| External work item count | $externalWorkItemCount |",
    "| External blocker count | $externalBlockingReasonCount |",
    "| External missing file count | $externalMissingFileCount |",
    "",
    "## Remaining External Areas",
    "",
    "| Area | Owner | Blockers | Missing Files | Reasons |",
    "| --- | --- | ---: | ---: | --- |"
)
foreach ($item in $sourceItems) {
    $area = Get-JsonValue $item "area" ""
    $owner = Get-JsonValue $item "owner" ""
    $itemBlockingReasonCount = Convert-ToInt (Get-JsonValue $item "remainingBlockingReasonCount" 0)
    $itemMissingFileCount = Convert-ToInt (Get-JsonValue $item "missingFileCount" 0)
    $itemReasons = Join-TextList @(Convert-ToArray (Get-JsonValue $item "remainingBlockingReasons" @()))
    $reportLines += "| $(Format-MarkdownCell $area) | $(Format-MarkdownCell $owner) | $itemBlockingReasonCount | $itemMissingFileCount | $(Format-MarkdownCell $itemReasons) |"
}
$reportLines += @(
    "",
    "## Completed Local Mail",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Recipient | $(Format-MarkdownCell $completedProgressMailWorkItem.recipient) |",
    "| Subject | $(Format-MarkdownCell $completedProgressMailWorkItem.subject) |",
    "| Remaining actions | $($completedProgressMailWorkItem.remainingActionCount) |",
    "| Receipt path | $(Format-MarkdownCell $completedProgressMailWorkItem.receiptPath) |",
    "",
    "## Boundary",
    "",
    "- This snapshot does not send email.",
    "- The release pipeline still does not send email.",
    "- Real host-project evidence remains unaccepted until the three external evidence directories are returned and verified.",
    "",
    "## Checks",
    "",
    "| Check | Result | Message |",
    "| --- | --- | --- |"
)
foreach ($check in $checks) {
    $result = if ([bool]$check.passed) { "PASS" } else { "FAIL" }
    $reportLines += "| $(Format-MarkdownCell $check.name) | $result | $(Format-MarkdownCell $check.message) |"
}

New-Item -ItemType Directory -Force (Split-Path $manifestFullPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestFullPath -Encoding UTF8
$reportLines | Set-Content -Path $reportFullPath -Encoding UTF8

if ($status -ne "PASS") {
    throw "Release progress notification post-dispatch snapshot failed: $($failedChecks.name -join ', ')"
}

Write-Output "Release progress notification post-dispatch snapshot manifest: $manifestFullPath"
Write-Output "Release progress notification post-dispatch snapshot report: $reportFullPath"
Write-Output "PASS AI TestPilot release progress notification post-dispatch snapshot"
