[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$OutboxDir,
    [string]$ManifestPath,
    [string]$ReportPath,
    [string]$ProgressRecipient = "kibernet@sina.com",
    [switch]$RequireOwnerRouteMapLatestBigNode
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

function Read-OptionalJsonFile {
    param(
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        return $null
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
$productionDriverReadinessManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-replay-driver-readiness-manifest.json") "Production replay driver readiness manifest"
$productionLuaPatchReadinessManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-lua-patch-readiness-manifest.json") "Production Lua patch readiness manifest"
$productionExternalEvidenceInboxManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-external-evidence-inbox-manifest.json") "Production external evidence inbox manifest"
$ownerRouteMapManifest = Read-OptionalJsonFile (Join-Path $evidenceBundlePath "production-handoff-owner-route-map-manifest.json")
$ownerRouteMapProbeManifest = Read-OptionalJsonFile (Join-Path $evidenceBundlePath "production-handoff-owner-route-map-probe-manifest.json")

$ownerRouteMapRouteCount = Convert-ToInt (Get-JsonValue $ownerRouteMapManifest "ownerRouteCount" 0)
$ownerRouteMapMissingFileCount = Convert-ToInt (Get-JsonValue $ownerRouteMapManifest "externalRemainingMissingFileCount" 0)
$ownerRouteMapBlockingReasonCount = Convert-ToInt (Get-JsonValue $ownerRouteMapManifest "externalRemainingBlockingReasonCount" 0)
$ownerRouteMapRepoSideClosableGapCount = Convert-ToInt (Get-JsonValue $ownerRouteMapManifest "repoSideClosableGapCount" 1)
$ownerRouteMapProbeScenarioCount = Convert-ToInt (Get-JsonValue $ownerRouteMapProbeManifest "scenarioCount" 0)
$ownerRouteMapProbeFailedScenarioCount = Convert-ToInt (Get-JsonValue $ownerRouteMapProbeManifest "failedScenarioCount" 1)
$ownerRouteMapAccepted = (
    $null -ne $ownerRouteMapManifest -and
    (Get-JsonValue $ownerRouteMapManifest "status" "") -eq "PASS" -and
    $ownerRouteMapRouteCount -eq 3 -and
    $ownerRouteMapMissingFileCount -eq 9 -and
    $ownerRouteMapBlockingReasonCount -eq 11 -and
    $ownerRouteMapRepoSideClosableGapCount -eq 0 -and
    (Convert-ToInt (Get-JsonValue $ownerRouteMapManifest "routeMismatchCount" 1)) -eq 0 -and
    (Convert-ToInt (Get-JsonValue $ownerRouteMapManifest "requiredFileMismatchCount" 1)) -eq 0 -and
    (Convert-ToInt (Get-JsonValue $ownerRouteMapManifest "missingCommandCount" 1)) -eq 0 -and
    -not (Convert-ToBool (Get-JsonValue $ownerRouteMapManifest "releasePipelineSendsEmail" $true))
)
$ownerRouteMapProbeAccepted = (
    $null -ne $ownerRouteMapProbeManifest -and
    (Get-JsonValue $ownerRouteMapProbeManifest "status" "") -eq "PASS" -and
    $ownerRouteMapProbeScenarioCount -eq 4 -and
    $ownerRouteMapProbeFailedScenarioCount -eq 0 -and
    (Convert-ToBool (Get-JsonValue $ownerRouteMapProbeManifest "baselineCurrentRouteMapPassed" $false)) -and
    (Convert-ToBool (Get-JsonValue $ownerRouteMapProbeManifest "ownerRouteMismatchBlocked" $false)) -and
    (Convert-ToBool (Get-JsonValue $ownerRouteMapProbeManifest "missingRouteEndpointBlocked" $false)) -and
    (Convert-ToBool (Get-JsonValue $ownerRouteMapProbeManifest "autoAcceptanceWithoutSemanticPreflightBlocked" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $ownerRouteMapProbeManifest "releasePipelineSendsEmail" $true))
)
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
$ownerResponseBundleKitAccepted = (
    (Get-JsonValue $ownerResponseBundleKitManifest "status" "") -eq "PASS" -and
    $ownerResponseBundleKitGenerated -and
    $ownerResponseBundleKitZipGenerated -and
    $ownerResponseBundleKitRequiredFileCount -gt 0 -and
    -not (Convert-ToBool (Get-JsonValue $ownerResponseBundleKitManifest "emailSent" $true))
)
$latestBigNodeRouteRequirementSatisfied = $false
if ($ownerRouteMapAccepted -and $ownerRouteMapProbeAccepted) {
    $latestBigNodeName = "production_handoff_owner_route_map"
    $latestBigNodeStatus = [string](Get-JsonValue $ownerRouteMapManifest "status" "")
    $notificationSubject = "AI TestPilot progress - owner route map ready"
    $latestBigNodeAccepted = $true
} else {
    $latestBigNodeName = "production_handoff_owner_response_bundle_kit"
    $latestBigNodeStatus = [string](Get-JsonValue $ownerResponseBundleKitManifest "status" "")
    $notificationSubject = "AI TestPilot progress - owner response bundle kit ready"
    $latestBigNodeAccepted = $ownerResponseBundleKitAccepted
}
if ([bool]$RequireOwnerRouteMapLatestBigNode) {
    $latestBigNodeRouteRequirementSatisfied = (
        $latestBigNodeName -eq "production_handoff_owner_route_map" -and
        $ownerRouteMapAccepted -and
        $ownerRouteMapProbeAccepted
    )
} else {
    $latestBigNodeRouteRequirementSatisfied = (
        $latestBigNodeName -in @("production_handoff_owner_response_bundle_kit", "production_handoff_owner_route_map") -and
        ($latestBigNodeName -ne "production_handoff_owner_route_map" -or ($ownerRouteMapAccepted -and $ownerRouteMapProbeAccepted))
    )
}
$notificationDispatchStatus = "PENDING_LOCAL_MAIL_AUTH_AND_CONFIRMATION"
$notificationCadencePolicy = "BIG_NODE_ONLY"
$notificationTriggerKind = "BIG_NODE"
$bigNodeNotificationEligible = $true
$smallNodeEmailSuppression = $true
$eligibleBigNodeNames = @($latestBigNodeName)
$suppressedSmallNodeNames = @(
    "production_handoff_mail_helper_auth_status_probe",
    "release_progress_notification_confirmation_probe",
    "release_progress_notification_receipt_probe",
    "release_progress_notification_dispatch_receipt_intake_probe",
    "release_progress_notification_local_send_workflow_probe",
    "release_progress_notification_real_receipt_guard_probe",
    "release_progress_notification_remaining_work_snapshot_probe"
)
$suppressedSmallNodeCount = @($suppressedSmallNodeNames).Count

$ownerInputs = @(Convert-ToArray (Get-JsonValue $ownerInputRequestManifest "ownerInputs" @()))
$remainingExternalWorkItems = @()
$remainingExternalBlockingReasonCount = 0
$remainingExternalMissingFileCount = 0
foreach ($item in $ownerInputs) {
    $remainingReasons = @(Convert-ToArray (Get-JsonValue $item "remainingBlockingReasons" @()) | ForEach-Object { [string]$_ })
    $missingFiles = @(Convert-ToArray (Get-JsonValue $item "missingFiles" @()) | ForEach-Object { [string]$_ })
    $requiredFiles = @(Convert-ToArray (Get-JsonValue $item "requiredEvidenceFiles" @()) | ForEach-Object { [string]$_ })
    $itemBlockingReasonCount = Convert-ToInt (Get-JsonValue $item "remainingBlockingReasonCount" $remainingReasons.Count)
    $itemMissingFileCount = Convert-ToInt (Get-JsonValue $item "missingFileCount" $missingFiles.Count)

    $remainingExternalBlockingReasonCount += $itemBlockingReasonCount
    $remainingExternalMissingFileCount += $itemMissingFileCount

    $remainingExternalWorkItems += [ordered]@{
        owner = [string](Get-JsonValue $item "owner" "")
        area = [string](Get-JsonValue $item "area" "")
        ownerStatus = [string](Get-JsonValue $item "ownerStatus" "")
        contactStatus = [string](Get-JsonValue $item "contactStatus" "")
        sendStatus = [string](Get-JsonValue $item "sendStatus" "")
        dispatchStatus = [string](Get-JsonValue $item "dispatchStatus" "")
        inboxDirectory = [string](Get-JsonValue $item "inboxDirectory" "")
        missingFileCount = [int]$itemMissingFileCount
        missingFiles = @($missingFiles)
        requiredEvidenceFiles = @($requiredFiles)
        remainingBlockingReasonCount = [int]$itemBlockingReasonCount
        remainingBlockingReasons = @($remainingReasons)
        ownerPacketPath = [string](Get-JsonValue $item "ownerPacketPath" "")
        dispatchDraftPath = [string](Get-JsonValue $item "dispatchDraftPath" "")
        preflightCommand = [string](Get-JsonValue $item "preflightCommand" "")
        acceptanceWrapperCommand = [string](Get-JsonValue $item "acceptanceWrapperCommand" "")
        hardValidationCommand = [string](Get-JsonValue $item "hardValidationCommand" "")
    }
}

$localProgressMailRemainingActionCount = 1
$trackedRemainingWorkItemCount = [int](@($remainingExternalWorkItems).Count + $localProgressMailRemainingActionCount)
$localProgressMailWorkItem = [ordered]@{
    area = "release_progress_notification_send"
    status = $notificationDispatchStatus
    recipient = $ProgressRecipient
    subject = $notificationSubject
    remainingActionCount = [int]$localProgressMailRemainingActionCount
    remainingActions = @(
        "complete_local_agently_cli_oauth_login",
        "request_confirmation_token_with_prepare_confirmation",
        "rerun_with_operator_approved_confirmation_token",
        "record_and_confirm_real_send_receipt"
    )
    helperPath = "release-progress-notification-outbox/send-progress-notification.ps1"
    receiptIntakeCommand = ".\tools\Invoke-AITestPilotReleaseProgressNotificationDispatchReceiptIntake.ps1 -ReceiptPath ""path\to\progress-notification-send-receipt.json"" -RequireReceipt -ConfirmLocalSendReceipt"
    releasePipelineSendsEmail = $false
    emailSent = $false
    twoStageConfirmationRequired = $true
}

$statusPath = Join-Path $outboxPath "notification-status.json"
$cadencePolicyPath = Join-Path $outboxPath "notification-cadence-policy.json"
$remainingWorkSnapshotPath = Join-Path $outboxPath "remaining-work-snapshot.json"
$remainingWorkSnapshotMarkdownPath = Join-Path $outboxPath "remaining-work-snapshot.md"
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
    requireOwnerRouteMapLatestBigNode = [bool]$RequireOwnerRouteMapLatestBigNode
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
    ownerRouteMapAccepted = [bool]$ownerRouteMapAccepted
    ownerRouteMapProbeAccepted = [bool]$ownerRouteMapProbeAccepted
    ownerRouteMapRouteCount = [int]$ownerRouteMapRouteCount
    ownerRouteMapMissingFileCount = [int]$ownerRouteMapMissingFileCount
    ownerRouteMapBlockingReasonCount = [int]$ownerRouteMapBlockingReasonCount
    ownerRouteMapRepoSideClosableGapCount = [int]$ownerRouteMapRepoSideClosableGapCount
    notificationCadencePolicy = $notificationCadencePolicy
    notificationTriggerKind = $notificationTriggerKind
    bigNodeNotificationEligible = [bool]$bigNodeNotificationEligible
    smallNodeEmailSuppression = [bool]$smallNodeEmailSuppression
    eligibleBigNodeNames = @($eligibleBigNodeNames)
    suppressedSmallNodeNames = @($suppressedSmallNodeNames)
    suppressedSmallNodeCount = [int]$suppressedSmallNodeCount
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

$cadencePolicy = [ordered]@{
    schemaVersion = "aitestpilot.release_progress_notification_cadence_policy.v1"
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    notificationCadencePolicy = $notificationCadencePolicy
    notificationTriggerKind = $notificationTriggerKind
    bigNodeNotificationEligible = [bool]$bigNodeNotificationEligible
    latestBigNodeName = $latestBigNodeName
    latestBigNodeStatus = $latestBigNodeStatus
    eligibleBigNodeNames = @($eligibleBigNodeNames)
    smallNodeEmailSuppression = [bool]$smallNodeEmailSuppression
    suppressedSmallNodeNames = @($suppressedSmallNodeNames)
    suppressedSmallNodeCount = [int]$suppressedSmallNodeCount
    releasePipelineSendsEmail = $false
    emailSent = $false
    confirmationTokenCreated = $false
    productionOutputBoundary = "release_progress_notification_cadence_policy_only"
}
$cadencePolicy | ConvertTo-Json -Depth 8 | Set-Content -Path $cadencePolicyPath -Encoding UTF8

$remainingWorkSnapshot = [ordered]@{
    schemaVersion = "aitestpilot.release_progress_notification_remaining_work_snapshot.v1"
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    recipient = $ProgressRecipient
    subject = $notificationSubject
    latestBigNodeName = $latestBigNodeName
    latestBigNodeStatus = $latestBigNodeStatus
    ownerInputRequestStatus = $ownerInputRequestStatus
    ownerUnblockStatus = $ownerUnblockStatus
    notificationDispatchStatus = $notificationDispatchStatus
    externalRemainingWorkItemCount = [int]@($remainingExternalWorkItems).Count
    externalRemainingBlockingReasonCount = [int]$remainingExternalBlockingReasonCount
    externalRemainingMissingFileCount = [int]$remainingExternalMissingFileCount
    canonicalRemainingBlockingReasonCount = [int]$remainingBlockingReasonCount
    canonicalMissingRequiredFileCount = [int]$missingRequiredFileCount
    localProgressMailRemainingActionCount = [int]$localProgressMailRemainingActionCount
    trackedRemainingWorkItemCount = [int]$trackedRemainingWorkItemCount
    productionDriverReadinessStatus = [string](Get-JsonValue $productionDriverReadinessManifest "status" "")
    productionDriverReady = [bool](Convert-ToBool (Get-JsonValue $productionDriverReadinessManifest "readyForProductionDriverRelease" $false))
    productionDriverBlockingReasonCount = [int](Convert-ToInt (Get-JsonValue $productionDriverReadinessManifest "blockingReasonCount" 0))
    productionLuaReadinessStatus = [string](Get-JsonValue $productionLuaPatchReadinessManifest "status" "")
    productionLuaReady = [bool](Convert-ToBool (Get-JsonValue $productionLuaPatchReadinessManifest "readyForProductionLuaPatchRelease" $false))
    productionLuaBlockingReasonCount = [int](Convert-ToInt (Get-JsonValue $productionLuaPatchReadinessManifest "blockingReasonCount" 0))
    externalEvidenceInboxStatus = [string](Get-JsonValue $productionExternalEvidenceInboxManifest "status" "")
    externalEvidenceInboxMissingFileCount = [int](Convert-ToInt (Get-JsonValue $productionExternalEvidenceInboxManifest "missingRequiredFileCount" 0))
    externalRemainingWorkItems = @($remainingExternalWorkItems)
    localProgressMailWorkItem = $localProgressMailWorkItem
    releasePipelineSendsEmail = $false
    emailSent = $false
    confirmationTokenCreated = $false
    realHostProjectEvidenceAccepted = $false
    externalEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "release_progress_notification_remaining_work_snapshot_only"
}
$remainingWorkSnapshot | ConvertTo-Json -Depth 12 | Set-Content -Path $remainingWorkSnapshotPath -Encoding UTF8

$remainingWorkSnapshotLines = @(
    "# AI TestPilot Remaining Work Snapshot",
    "",
    "Schema: ``aitestpilot.release_progress_notification_remaining_work_snapshot.v1``",
    "Generated at UTC: $((Get-Date).ToUniversalTime().ToString("O"))",
    "",
    "## Summary",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Latest big node | $(Format-MarkdownCell $latestBigNodeName) |",
    "| Latest big node status | $(Format-MarkdownCell $latestBigNodeStatus) |",
    "| Owner input request status | $(Format-MarkdownCell $ownerInputRequestStatus) |",
    "| External remaining work items | $(@($remainingExternalWorkItems).Count) |",
    "| External remaining blocking reasons | $remainingExternalBlockingReasonCount |",
    "| External missing required files | $remainingExternalMissingFileCount |",
    "| Local progress mail pending actions | $localProgressMailRemainingActionCount |",
    "| Tracked remaining work items | $trackedRemainingWorkItemCount |",
    "| Notification dispatch status | $(Format-MarkdownCell $notificationDispatchStatus) |",
    "",
    "## External Owner Work",
    "",
    "| Owner | Area | Blockers | Missing Files | Hard Validation |",
    "| --- | --- | ---: | ---: | --- |"
)
foreach ($item in $remainingExternalWorkItems) {
    $remainingWorkSnapshotLines += "| $(Format-MarkdownCell $item.owner) | $(Format-MarkdownCell $item.area) | $($item.remainingBlockingReasonCount) | $($item.missingFileCount) | $(Format-MarkdownCell $item.hardValidationCommand) |"
}
$remainingWorkSnapshotLines += @(
    "",
    "## Blocking Reasons",
    ""
)
foreach ($item in $remainingExternalWorkItems) {
    $remainingWorkSnapshotLines += "- $($item.area): $(Join-TextList $item.remainingBlockingReasons)"
}
$remainingWorkSnapshotLines += @(
    "",
    "## Local Progress Mail",
    "",
    "- Status: $notificationDispatchStatus",
    "- Recipient: $ProgressRecipient",
    "- Helper: ``release-progress-notification-outbox/send-progress-notification.ps1``",
    "- Remaining actions: $(Join-TextList $localProgressMailWorkItem.remainingActions)",
    "",
    "## Boundary",
    "",
    "- Release pipeline does not send email.",
    "- Real host-project evidence has not been accepted.",
    "- Fixture evidence has not been promoted."
)
$remainingWorkSnapshotLines | Set-Content -Path $remainingWorkSnapshotMarkdownPath -Encoding UTF8

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
    "- Owner route map accepted: $ownerRouteMapAccepted",
    "- Owner route map probe accepted: $ownerRouteMapProbeAccepted",
    "- Owner route map routes: $ownerRouteMapRouteCount",
    "- Owner route map missing files: $ownerRouteMapMissingFileCount",
    "- Owner route map blockers: $ownerRouteMapBlockingReasonCount",
    "- Owner route map repo-side closable gaps: $ownerRouteMapRepoSideClosableGapCount",
    "- Notification cadence policy: $notificationCadencePolicy",
    "- Notification trigger kind: $notificationTriggerKind",
    "- Small-node email suppression active: $smallNodeEmailSuppression",
    "- Suppressed small-node notification count: $suppressedSmallNodeCount",
    "- Remaining work snapshot generated: true",
    "- External remaining work areas: $(@($remainingExternalWorkItems).Count)",
    "- External remaining blocking reasons: $remainingExternalBlockingReasonCount",
    "- Local progress mail remaining actions: $localProgressMailRemainingActionCount",
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
    "- production-handoff-owner-route-map-manifest.json",
    "- production-handoff-owner-route-map.md",
    "- production-handoff-owner-route-map-probe-manifest.json",
    "- production-handoff-owner-route-map-probe.md",
    "- release-progress-notification-outbox-manifest.json",
    "- release-progress-notification-outbox/remaining-work-snapshot.json",
    "- release-progress-notification-outbox/remaining-work-snapshot.md",
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
    "    [string]`$ConfirmationToken,",
    "    [string]`$ReceiptPath",
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
    "function Write-SendReceipt {",
    "    param([string[]]`$Lines)",
    "    if ([string]::IsNullOrWhiteSpace(`$ReceiptPath)) { return }",
    "    `$response = Read-JsonOutput `$Lines",
    "    `$messageId = ''",
    "    if (`$null -ne `$response.data -and `$null -ne `$response.data.PSObject.Properties['message_id']) {",
    "        `$messageId = [string]`$response.data.message_id",
    "    }",
    "    `$queued = `$false",
    "    if (`$null -ne `$response.data -and `$null -ne `$response.data.PSObject.Properties['queued']) {",
    "        `$queued = [bool]`$response.data.queued",
    "    }",
    "    `$receipt = [ordered]@{",
    "        schemaVersion = 'aitestpilot.release_progress_notification_send_receipt.v1'",
    "        generatedAtUtc = (Get-Date).ToUniversalTime().ToString('O')",
    "        recipient = `$recipient",
    "        subject = `$subject",
    "        bodyFile = `$bodyFile",
    "        confirmationTokenSupplied = -not [string]::IsNullOrWhiteSpace(`$ConfirmationToken)",
    "        prepareConfirmation = [bool]`$PrepareConfirmation",
    "        agentlyCliExitCode = 0",
    "        messageId = `$messageId",
    "        queued = [bool]`$queued",
    "        sendSucceeded = `$true",
    "        releasePipelineGenerated = `$false",
    "        realDeliveryVerified = `$false",
    "        cliOutput = @(`$Lines | ForEach-Object { [string]`$_ })",
    "    }",
    "    `$receiptParent = Split-Path `$ReceiptPath -Parent",
    "    if (-not [string]::IsNullOrWhiteSpace(`$receiptParent)) { New-Item -ItemType Directory -Force `$receiptParent | Out-Null }",
    "    `$receipt | ConvertTo-Json -Depth 8 | Set-Content -Path `$ReceiptPath -Encoding UTF8",
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
    "    `$sendOutput = & agently-cli @args 2>&1",
    "    `$sendExitCode = `$LASTEXITCODE",
    "    `$sendOutput | ForEach-Object { Write-Output `$_ }",
    "    if (`$sendExitCode -ne 0) { exit `$sendExitCode }",
    "    Write-SendReceipt `$sendOutput",
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
    "- ``notification-cadence-policy.json``: machine-readable big-node-only notification cadence policy.",
    "- ``remaining-work-snapshot.json`` and ``remaining-work-snapshot.md``: machine-readable and owner-readable remaining work grouped by owner area plus the local progress-mail action.",
    "- ``big-node-progress-email.md``: prepared email body for ``$ProgressRecipient``.",
    "- ``send-progress-notification.ps1``: local helper for the agently-cli two-stage send flow.",
    "",
    "The release pipeline does not send email, run OAuth login, or create confirmation tokens.",
    "Only big-node progress creates a prepared progress email. Small proof/probe nodes are recorded in evidence but do not create separate progress emails.",
    "",
    "Local workflow after agently-cli authorization:",
    "",
    "1. Run ``agently-cli auth status`` and ``agently-cli +me``.",
    "2. Run ``.\release-progress-notification-outbox\send-progress-notification.ps1 -PrepareConfirmation`` from the evidence bundle.",
    "3. If agently-cli returns a confirmation token, rerun the helper with ``-ConfirmationToken`` only after explicit operator approval.",
    "4. Optionally pass ``-ReceiptPath`` on the token-confirmed run to write a machine-readable send receipt."
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
    "| Owner route map accepted | $ownerRouteMapAccepted |",
    "| Owner route map probe accepted | $ownerRouteMapProbeAccepted |",
    "| Owner route map routes | $ownerRouteMapRouteCount |",
    "| Owner route map missing files | $ownerRouteMapMissingFileCount |",
    "| Owner route map blockers | $ownerRouteMapBlockingReasonCount |",
    "| Owner route map repo-side closable gaps | $ownerRouteMapRepoSideClosableGapCount |",
    "| Notification cadence policy | $(Format-MarkdownCell $notificationCadencePolicy) |",
    "| Notification trigger kind | $(Format-MarkdownCell $notificationTriggerKind) |",
    "| Big-node notification eligible | $bigNodeNotificationEligible |",
    "| Small-node email suppression | $smallNodeEmailSuppression |",
    "| Suppressed small-node notification count | $suppressedSmallNodeCount |",
    "| Remaining work snapshot generated | $(Test-Path $remainingWorkSnapshotPath) |",
    "| External remaining work items | $(@($remainingExternalWorkItems).Count) |",
    "| External remaining blocking reasons | $remainingExternalBlockingReasonCount |",
    "| External missing required files | $remainingExternalMissingFileCount |",
    "| Local progress mail remaining actions | $localProgressMailRemainingActionCount |",
    "| Tracked remaining work items | $trackedRemainingWorkItemCount |",
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
    "- Notification cadence is big-node-only; proof/probe nodes do not generate separate emails.",
    "- Release pipeline does not send email.",
    "- Local agently-cli authorization and two-stage confirmation are required.",
    "- Real host-project evidence has not been accepted.",
    "- Fixture evidence has not been promoted."
)
$reportLines | Set-Content -Path $reportFullPath -Encoding UTF8

$statusContent = Get-Content -Path $statusPath -Encoding UTF8 -Raw
$cadencePolicyContent = Get-Content -Path $cadencePolicyPath -Encoding UTF8 -Raw
$remainingWorkSnapshotContent = Get-Content -Path $remainingWorkSnapshotPath -Encoding UTF8 -Raw
$remainingWorkSnapshotMarkdownContent = Get-Content -Path $remainingWorkSnapshotMarkdownPath -Encoding UTF8 -Raw
$emailDraftContent = Get-Content -Path $emailDraftPath -Encoding UTF8 -Raw
$sendHelperContent = Get-Content -Path $sendHelperPath -Encoding UTF8 -Raw
$readmeContent = Get-Content -Path $readmePath -Encoding UTF8 -Raw
$reportContent = Get-Content -Path $reportFullPath -Encoding UTF8 -Raw
$noObjectLeakage = -not $statusContent.Contains("System.Collections") -and -not $statusContent.Contains("@{") -and
    -not $cadencePolicyContent.Contains("System.Collections") -and -not $cadencePolicyContent.Contains("@{") -and
    -not $remainingWorkSnapshotContent.Contains("System.Collections") -and -not $remainingWorkSnapshotContent.Contains("@{") -and
    -not $remainingWorkSnapshotMarkdownContent.Contains("System.Collections") -and -not $remainingWorkSnapshotMarkdownContent.Contains("@{") -and
    -not $emailDraftContent.Contains("System.Collections") -and -not $emailDraftContent.Contains("@{") -and
    -not $sendHelperContent.Contains("System.Collections") -and
    -not $readmeContent.Contains("System.Collections") -and -not $readmeContent.Contains("@{") -and
    -not $reportContent.Contains("System.Collections") -and -not $reportContent.Contains("@{")

$statusContentValidated = $statusContent.Contains("release_progress_notification_status.v1") -and
    $statusContent.Contains($ProgressRecipient) -and
    $statusContent.Contains($notificationDispatchStatus) -and
    $statusContent.Contains($latestBigNodeName) -and
    $statusContent.Contains($notificationCadencePolicy) -and
    $noObjectLeakage
$cadencePolicyContentValidated = $cadencePolicyContent.Contains("release_progress_notification_cadence_policy.v1") -and
    $cadencePolicyContent.Contains($notificationCadencePolicy) -and
    $cadencePolicyContent.Contains($latestBigNodeName) -and
    $cadencePolicyContent.Contains("release_progress_notification_real_receipt_guard_probe") -and
    $cadencePolicyContent.Contains("release_progress_notification_remaining_work_snapshot_probe") -and
    $noObjectLeakage
$remainingWorkSnapshotContentValidated = $remainingWorkSnapshotContent.Contains("release_progress_notification_remaining_work_snapshot.v1") -and
    $remainingWorkSnapshotContent.Contains($latestBigNodeName) -and
    $remainingWorkSnapshotContent.Contains("production_driver_binding") -and
    $remainingWorkSnapshotContent.Contains("production_lua_patch_evidence") -and
    $remainingWorkSnapshotContent.Contains("live_model_endpoint_smoke") -and
    $remainingWorkSnapshotContent.Contains("release_progress_notification_send") -and
    $remainingWorkSnapshotContent.Contains("production_replay_integration_not_bound") -and
    $remainingWorkSnapshotContent.Contains("real_production_lua_bundle_missing") -and
    $remainingWorkSnapshotContent.Contains("real_live_model_endpoint_smoke_missing") -and
    $remainingWorkSnapshotContent.Contains($notificationDispatchStatus) -and
    $remainingWorkSnapshotMarkdownContent.Contains("AI TestPilot Remaining Work Snapshot") -and
    $remainingWorkSnapshotMarkdownContent.Contains("Local Progress Mail") -and
    $noObjectLeakage
$emailDraftContentValidated = $emailDraftContent.Contains($ProgressRecipient) -and
    $emailDraftContent.Contains($notificationSubject) -and
    $emailDraftContent.Contains($latestBigNodeName) -and
    $emailDraftContent.Contains("Notification cadence policy: $notificationCadencePolicy") -and
    $emailDraftContent.Contains("Remaining work snapshot generated: true") -and
    $emailDraftContent.Contains("Missing owner contacts: $missingOwnerContactCount") -and
    $emailDraftContent.Contains("prepared but not sent") -and
    $noObjectLeakage
$sendHelperContentValidated = $sendHelperContent.Contains("agently-cli auth status") -and
    $sendHelperContent.Contains("Read-JsonOutput") -and
    $sendHelperContent.Contains("Command output did not contain a JSON object.") -and
    $sendHelperContent.Contains("message', '+send") -and
    $sendHelperContent.Contains("--confirmation-token") -and
    $sendHelperContent.Contains("-PrepareConfirmation") -and
    $sendHelperContent.Contains("ReceiptPath") -and
    $sendHelperContent.Contains("release_progress_notification_send_receipt.v1") -and
    $sendHelperContent.Contains("queued") -and
    $sendHelperContent.Contains("realDeliveryVerified") -and
    $sendHelperContent.Contains("sendExitCode") -and
    $noObjectLeakage
$readmeContentValidated = $readmeContent.Contains("two-stage send flow") -and
    $readmeContent.Contains("does not send email") -and
    $readmeContent.Contains("big-node-only") -and
    $readmeContent.Contains("agently-cli auth status") -and
    $noObjectLeakage
$reportContentValidated = $reportContent.Contains("Release Progress Notification Outbox") -and
    $reportContent.Contains($notificationDispatchStatus) -and
    $reportContent.Contains("emailSent=false") -and
    $reportContent.Contains($notificationCadencePolicy) -and
    $reportContent.Contains("two-stage confirmation") -and
    $noObjectLeakage

$checks = @()
Add-OutboxCheck "progress_notification_sources_available" `
    ($ownerInputRequestManifest.status -eq "PASS" -and $ownerContactExternalIntakeProbeManifest.status -eq "PASS" -and $sendDryRunProbeManifest.status -eq "PASS" -and $ownerResponseBundleProbeManifest.status -eq "PASS" -and $ownerResponseBundleKitManifest.status -eq "PASS" -and $ownerUnblockManifest.status -eq "PASS" -and $mailAuthReadinessManifest.status -eq "PASS" -and $sendReadinessManifest.status -eq "PASS" -and $productionDriverReadinessManifest.status -eq "PASS" -and $productionLuaPatchReadinessManifest.status -eq "PASS" -and $productionExternalEvidenceInboxManifest.status -eq "PASS") `
    "Progress notification outbox must be based on passing owner input request, owner contact external intake, send dry-run, owner response bundle, owner response bundle kit, owner unblock, mail-auth readiness, send readiness, production driver readiness, production Lua readiness, and external evidence inbox evidence."
Add-OutboxCheck "progress_notification_latest_big_node_accepted" `
    ($latestBigNodeAccepted -and
        $latestBigNodeRouteRequirementSatisfied -and
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
    "Progress notification outbox must report the latest eligible big node without claiming email was sent."
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
    ((Test-Path $statusPath) -and (Test-Path $cadencePolicyPath) -and (Test-Path $remainingWorkSnapshotPath) -and (Test-Path $remainingWorkSnapshotMarkdownPath) -and (Test-Path $emailDraftPath) -and (Test-Path $sendHelperPath) -and (Test-Path $readmePath) -and (Test-Path $reportFullPath)) `
    "Progress notification outbox must generate status, cadence policy, remaining-work snapshot, email draft, send helper, README, and report files."
Add-OutboxCheck "progress_notification_content_validated" `
    ($statusContentValidated -and $cadencePolicyContentValidated -and $remainingWorkSnapshotContentValidated -and $emailDraftContentValidated -and $sendHelperContentValidated -and $readmeContentValidated -and $reportContentValidated) `
    "Progress notification outbox files must contain recipient, subject, node, cadence policy, remaining-work snapshot, counts, agently-cli send flow, and not-sent boundary text."
Add-OutboxCheck "progress_notification_remaining_work_snapshot" `
    (@($remainingExternalWorkItems).Count -eq 3 -and
        $remainingExternalBlockingReasonCount -eq $remainingBlockingReasonCount -and
        $remainingExternalMissingFileCount -eq $missingRequiredFileCount -and
        $localProgressMailRemainingActionCount -eq 1 -and
        $trackedRemainingWorkItemCount -eq 4 -and
        (Convert-ToInt (Get-JsonValue $productionDriverReadinessManifest "blockingReasonCount" 0)) -eq 5 -and
        (Convert-ToInt (Get-JsonValue $productionLuaPatchReadinessManifest "blockingReasonCount" 0)) -eq 5 -and
        -not (Convert-ToBool (Get-JsonValue $productionDriverReadinessManifest "readyForProductionDriverRelease" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $productionLuaPatchReadinessManifest "readyForProductionLuaPatchRelease" $true)) -and
        (Convert-ToInt (Get-JsonValue $productionExternalEvidenceInboxManifest "missingRequiredFileCount" 0)) -eq $missingRequiredFileCount -and
        $remainingWorkSnapshotContentValidated) `
    "Progress notification outbox must write a remaining-work snapshot covering three external owner areas, eleven canonical blocking reasons, nine missing files, and one local progress-mail action."
Add-OutboxCheck "progress_notification_big_node_only_cadence" `
    ($notificationCadencePolicy -eq "BIG_NODE_ONLY" -and
        $notificationTriggerKind -eq "BIG_NODE" -and
        $bigNodeNotificationEligible -and
        $smallNodeEmailSuppression -and
        $suppressedSmallNodeCount -eq 7 -and
        $suppressedSmallNodeNames -contains "release_progress_notification_confirmation_probe" -and
        $suppressedSmallNodeNames -contains "release_progress_notification_real_receipt_guard_probe" -and
        $suppressedSmallNodeNames -contains "release_progress_notification_remaining_work_snapshot_probe" -and
        @($eligibleBigNodeNames).Count -eq 1 -and
        $eligibleBigNodeNames[0] -eq $latestBigNodeName) `
    "Progress notification cadence must be big-node-only and suppress separate emails for small proof/probe nodes."
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
    (Convert-ToEvidenceRelativePath $cadencePolicyPath),
    (Convert-ToEvidenceRelativePath $remainingWorkSnapshotPath),
    (Convert-ToEvidenceRelativePath $remainingWorkSnapshotMarkdownPath),
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
    "production-handoff-send-readiness-manifest.json",
    "production-replay-driver-readiness-manifest.json",
    "production-lua-patch-readiness-manifest.json",
    "production-external-evidence-inbox-manifest.json"
)
if ($null -ne $ownerRouteMapManifest) {
    $sourceFiles += "production-handoff-owner-route-map-manifest.json"
}
if ($null -ne $ownerRouteMapProbeManifest) {
    $sourceFiles += "production-handoff-owner-route-map-probe-manifest.json"
}

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
    requireOwnerRouteMapLatestBigNode = [bool]$RequireOwnerRouteMapLatestBigNode
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
    ownerRouteMapAccepted = [bool]$ownerRouteMapAccepted
    ownerRouteMapProbeAccepted = [bool]$ownerRouteMapProbeAccepted
    ownerRouteMapRouteCount = [int]$ownerRouteMapRouteCount
    ownerRouteMapMissingFileCount = [int]$ownerRouteMapMissingFileCount
    ownerRouteMapBlockingReasonCount = [int]$ownerRouteMapBlockingReasonCount
    ownerRouteMapRepoSideClosableGapCount = [int]$ownerRouteMapRepoSideClosableGapCount
    ownerRouteMapProbeScenarioCount = [int]$ownerRouteMapProbeScenarioCount
    ownerRouteMapProbeFailedScenarioCount = [int]$ownerRouteMapProbeFailedScenarioCount
    notificationCadencePolicy = $notificationCadencePolicy
    notificationTriggerKind = $notificationTriggerKind
    bigNodeNotificationEligible = [bool]$bigNodeNotificationEligible
    smallNodeEmailSuppression = [bool]$smallNodeEmailSuppression
    eligibleBigNodeNames = @($eligibleBigNodeNames)
    suppressedSmallNodeNames = @($suppressedSmallNodeNames)
    suppressedSmallNodeCount = [int]$suppressedSmallNodeCount
    notificationDispatchStatus = $notificationDispatchStatus
    statusGenerated = (Test-Path $statusPath)
    cadencePolicyGenerated = (Test-Path $cadencePolicyPath)
    remainingWorkSnapshotGenerated = (Test-Path $remainingWorkSnapshotPath)
    remainingWorkSnapshotMarkdownGenerated = (Test-Path $remainingWorkSnapshotMarkdownPath)
    progressEmailDraftGenerated = (Test-Path $emailDraftPath)
    sendHelperGenerated = (Test-Path $sendHelperPath)
    readmeGenerated = (Test-Path $readmePath)
    reportGenerated = (Test-Path $reportFullPath)
    statusContentValidated = [bool]$statusContentValidated
    cadencePolicyContentValidated = [bool]$cadencePolicyContentValidated
    remainingWorkSnapshotContentValidated = [bool]$remainingWorkSnapshotContentValidated
    progressEmailDraftContentValidated = [bool]$emailDraftContentValidated
    sendHelperContentValidated = [bool]$sendHelperContentValidated
    readmeContentValidated = [bool]$readmeContentValidated
    reportContentValidated = [bool]$reportContentValidated
    missingOwnerContactCount = [int]$missingOwnerContactCount
    pendingDispatchCount = [int]$pendingDispatchCount
    pendingOwnerPacketCount = [int]$pendingOwnerPacketCount
    missingRequiredFileCount = [int]$missingRequiredFileCount
    remainingBlockingReasonCount = [int]$remainingBlockingReasonCount
    externalRemainingWorkItemCount = [int]@($remainingExternalWorkItems).Count
    externalRemainingBlockingReasonCount = [int]$remainingExternalBlockingReasonCount
    externalRemainingMissingFileCount = [int]$remainingExternalMissingFileCount
    localProgressMailRemainingActionCount = [int]$localProgressMailRemainingActionCount
    trackedRemainingWorkItemCount = [int]$trackedRemainingWorkItemCount
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
