[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$PostDispatchSnapshotPath,
    [string]$ManifestPath,
    [string]$ReportPath,
    [switch]$IgnorePostDispatchSnapshot,
    [switch]$RequirePostDispatch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-external-evidence-action-queue-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-external-evidence-action-queue.md"
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

function Add-QueueCheck {
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

$defaultPostDispatchPath = Join-Path $evidenceBundlePath "release-progress-notification-post-dispatch-snapshot-manifest.json"
if (-not [bool]$IgnorePostDispatchSnapshot -and [string]::IsNullOrWhiteSpace($PostDispatchSnapshotPath) -and (Test-Path $defaultPostDispatchPath)) {
    $PostDispatchSnapshotPath = $defaultPostDispatchPath
}

$postDispatchSnapshot = $null
$postDispatchSnapshotExists = -not [string]::IsNullOrWhiteSpace($PostDispatchSnapshotPath) -and (Test-Path $PostDispatchSnapshotPath)
if ($postDispatchSnapshotExists) {
    $postDispatchSnapshotPathFull = Assert-PathUnderRepo $PostDispatchSnapshotPath "PostDispatchSnapshotPath"
    $postDispatchSnapshot = Read-JsonFile $postDispatchSnapshotPathFull "Release progress notification post-dispatch snapshot"
}
else {
    $postDispatchSnapshotPathFull = ""
}

if ([bool]$RequirePostDispatch -and -not $postDispatchSnapshotExists) {
    throw "Post-dispatch snapshot is required but missing."
}

$remainingSnapshotPath = Join-Path $evidenceBundlePath "release-progress-notification-outbox\remaining-work-snapshot.json"
$remainingSnapshot = Read-JsonFile $remainingSnapshotPath "Release progress notification remaining-work snapshot"
$ownerInputRequest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-owner-input-request-pack-manifest.json") "Production handoff owner input request pack manifest"
$ownerResponseBundleKit = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-owner-response-bundle-kit-manifest.json") "Production handoff owner response bundle kit manifest"
$externalEvidenceInbox = Read-JsonFile (Join-Path $evidenceBundlePath "production-external-evidence-inbox-manifest.json") "Production external evidence inbox manifest"

$sourceSnapshot = if ($null -ne $postDispatchSnapshot) { $postDispatchSnapshot } else { $remainingSnapshot }
$sourceKind = if ($null -ne $postDispatchSnapshot) { "post_dispatch_snapshot" } else { "remaining_work_snapshot" }
$sourceSnapshotPath = if ($sourceKind -eq "post_dispatch_snapshot") { $postDispatchSnapshotPathFull } else { $remainingSnapshotPath }

$externalItems = @(Convert-ToArray (Get-JsonValue $sourceSnapshot "externalRemainingWorkItems" @()))
$inboxAreas = @(Convert-ToArray (Get-JsonValue $externalEvidenceInbox "areaStatuses" @()))
$inboxByArea = @{}
foreach ($area in $inboxAreas) {
    $inboxByArea[[string](Get-JsonValue $area "area" "")] = $area
}
$currentBundleResponseKitZipPath = Join-Path $evidenceBundlePath "production-handoff-owner-response-bundle-kit.zip"
$responseKitZipPath = if (Test-Path $currentBundleResponseKitZipPath) {
    $currentBundleResponseKitZipPath
}
else {
    [string](Get-JsonValue $ownerResponseBundleKit "zipPath" "")
}
$ownerResponseBundleAutoAcceptanceCommand = ".\tools\Invoke-AITestPilotProductionExternalEvidenceAutoAcceptance.ps1 -OwnerResponseBundleDir `"path\to\filled-owner-response-bundle`" -RequireAllEvidence"
$ownerResponseBundleZipAutoAcceptanceCommand = ".\tools\Invoke-AITestPilotProductionExternalEvidenceAutoAcceptance.ps1 -OwnerResponseBundleZipPath `"path\to\filled-owner-response-bundle.zip`" -RequireAllEvidence"
$ownerResponseBundleZipEnvironmentVariable = "AITESTPILOT_OWNER_RESPONSE_BUNDLE_ZIP_PATH"
$productionDriverEvidenceExportHelperPath = "production-driver-binding-kit/Export-ProductionDriverEvidenceBundle.ps1"
$productionDriverEvidenceExportHelperCommand = ".\production-driver-binding-kit\Export-ProductionDriverEvidenceBundle.ps1 -EvidenceBundleDir `"path\to\release-evidence`""
$productionDriverEvidenceExportZipPath = "production-driver-evidence-export/production-driver-evidence.zip"

$queueItems = @()
$totalMissing = 0
$totalBlockers = 0
foreach ($item in $externalItems) {
    $area = [string](Get-JsonValue $item "area" "")
    $inboxItem = $inboxByArea[$area]
    $missingFiles = @(Convert-ToArray (Get-JsonValue $item "missingFiles" @()) | ForEach-Object { [string]$_ })
    $requiredFiles = @(Convert-ToArray (Get-JsonValue $item "requiredEvidenceFiles" @()) | ForEach-Object { [string]$_ })
    $blockingReasons = @(Convert-ToArray (Get-JsonValue $item "remainingBlockingReasons" @()) | ForEach-Object { [string]$_ })
    $missingCount = Convert-ToInt (Get-JsonValue $item "missingFileCount" $missingFiles.Count)
    $blockerCount = Convert-ToInt (Get-JsonValue $item "remainingBlockingReasonCount" $blockingReasons.Count)
    $inboxDirectory = [string](Get-JsonValue $item "inboxDirectory" "")
    $currentBundleInboxPath = if ([string]::IsNullOrWhiteSpace($inboxDirectory)) {
        ""
    }
    else {
        Join-Path (Join-Path $evidenceBundlePath "production-external-evidence-inbox") $inboxDirectory
    }
    $inboxPath = if (-not [string]::IsNullOrWhiteSpace($currentBundleInboxPath)) {
        $currentBundleInboxPath
    }
    else {
        [string](Get-JsonValue $inboxItem "inboxPath" "")
    }
    $totalMissing += $missingCount
    $totalBlockers += $blockerCount
    $driverExportHelperPath = if ($area -eq "production_driver_binding") { $productionDriverEvidenceExportHelperPath } else { "" }
    $driverExportHelperCommand = if ($area -eq "production_driver_binding") { $productionDriverEvidenceExportHelperCommand } else { "" }
    $driverExportZipPath = if ($area -eq "production_driver_binding") { $productionDriverEvidenceExportZipPath } else { "" }

    $queueItems += [ordered]@{
        owner = [string](Get-JsonValue $item "owner" "")
        area = $area
        status = "WAITING_FOR_EXTERNAL_EVIDENCE"
        contactStatus = [string](Get-JsonValue $item "contactStatus" "")
        sendStatus = [string](Get-JsonValue $item "sendStatus" "")
        dispatchStatus = [string](Get-JsonValue $item "dispatchStatus" "")
        inboxDirectory = $inboxDirectory
        inboxPath = $inboxPath
        requiredEvidenceFiles = @($requiredFiles)
        missingFiles = @($missingFiles)
        missingFileCount = [int]$missingCount
        remainingBlockingReasons = @($blockingReasons)
        remainingBlockingReasonCount = [int]$blockerCount
        ownerPacketPath = [string](Get-JsonValue $item "ownerPacketPath" "")
        dispatchDraftPath = [string](Get-JsonValue $item "dispatchDraftPath" "")
        preflightCommand = [string](Get-JsonValue $item "preflightCommand" "")
        acceptanceWrapperCommand = [string](Get-JsonValue $item "acceptanceWrapperCommand" "")
        hardValidationCommand = [string](Get-JsonValue $item "hardValidationCommand" "")
        ownerResponseBundleTemplatePath = "production-handoff-owner-response-bundle-kit/owner-response-bundle-template"
        ownerResponseBundleAreaPath = "production-handoff-owner-response-bundle-kit/owner-response-bundle-template/$inboxDirectory"
        ownerResponseBundleRequiredFilesPath = "production-handoff-owner-response-bundle-kit/owner-response-bundle-template/$inboxDirectory/required-files.json"
        ownerResponseBundleAutoAcceptanceCommand = $ownerResponseBundleAutoAcceptanceCommand
        ownerResponseBundleZipAutoAcceptanceCommand = $ownerResponseBundleZipAutoAcceptanceCommand
        ownerResponseBundleZipEnvironmentVariable = $ownerResponseBundleZipEnvironmentVariable
        productionDriverEvidenceExportHelperPath = $driverExportHelperPath
        productionDriverEvidenceExportHelperCommand = $driverExportHelperCommand
        productionDriverEvidenceExportZipPath = $driverExportZipPath
    }
}

$localProgressMailRemainingActionCount = Convert-ToInt (Get-JsonValue $sourceSnapshot "localProgressMailRemainingActionCount" 0)
$trackedRemainingWorkItemCount = Convert-ToInt (Get-JsonValue $sourceSnapshot "trackedRemainingWorkItemCount" ($externalItems.Count + $localProgressMailRemainingActionCount))
$progressNotificationEmailSent = Convert-ToBool (Get-JsonValue $sourceSnapshot "progressNotificationEmailSent" (Get-JsonValue $sourceSnapshot "emailSent" $false))
$notificationDispatchStatus = [string](Get-JsonValue $sourceSnapshot "notificationDispatchStatus" "")
$productionDriverEvidenceExportHelperItemCount = @($queueItems | Where-Object {
        [string](Get-JsonValue $_ "area" "") -eq "production_driver_binding" -and
        ([string](Get-JsonValue $_ "productionDriverEvidenceExportHelperPath" "")).Contains("Export-ProductionDriverEvidenceBundle.ps1") -and
        ([string](Get-JsonValue $_ "productionDriverEvidenceExportHelperCommand" "")).Contains("Export-ProductionDriverEvidenceBundle.ps1") -and
        ([string](Get-JsonValue $_ "productionDriverEvidenceExportZipPath" "")).Contains("production-driver-evidence.zip")
    }).Count

$checks = @()
Add-QueueCheck "external_evidence_action_queue_sources_available" `
    ((Get-JsonValue $remainingSnapshot "status" "") -eq "PASS" -and
        (Get-JsonValue $ownerInputRequest "status" "") -eq "PASS" -and
        (Get-JsonValue $ownerResponseBundleKit "status" "") -eq "PASS" -and
        (Get-JsonValue $externalEvidenceInbox "status" "") -eq "PASS" -and
        ((-not [bool]$RequirePostDispatch) -or ($null -ne $postDispatchSnapshot -and (Get-JsonValue $postDispatchSnapshot "status" "") -eq "PASS"))) `
    "External evidence action queue must read passing remaining-work, owner-input, response-bundle-kit, inbox, and optional post-dispatch evidence."
Add-QueueCheck "external_evidence_action_queue_counts" `
    ($externalItems.Count -eq 3 -and
        $queueItems.Count -eq 3 -and
        $totalMissing -eq 9 -and
        $totalBlockers -eq 11 -and
        (Convert-ToInt (Get-JsonValue $sourceSnapshot "externalRemainingWorkItemCount" 0)) -eq 3 -and
        (Convert-ToInt (Get-JsonValue $sourceSnapshot "externalRemainingMissingFileCount" 0)) -eq 9 -and
        (Convert-ToInt (Get-JsonValue $sourceSnapshot "externalRemainingBlockingReasonCount" 0)) -eq 11) `
    "External evidence action queue must preserve the three external areas, nine missing files, and eleven blockers."
Add-QueueCheck "external_evidence_action_queue_commands" `
    (@($queueItems | Where-Object {
            [string]::IsNullOrWhiteSpace([string](Get-JsonValue $_ "preflightCommand" "")) -or
            [string]::IsNullOrWhiteSpace([string](Get-JsonValue $_ "acceptanceWrapperCommand" "")) -or
            [string]::IsNullOrWhiteSpace([string](Get-JsonValue $_ "hardValidationCommand" ""))
        }).Count -eq 0) `
    "Every external evidence queue item must include preflight, acceptance-wrapper, and hard-validation commands."
Add-QueueCheck "external_evidence_action_queue_auto_acceptance_commands" `
    ($ownerResponseBundleAutoAcceptanceCommand.Contains("Invoke-AITestPilotProductionExternalEvidenceAutoAcceptance.ps1") -and
        $ownerResponseBundleAutoAcceptanceCommand.Contains("-OwnerResponseBundleDir") -and
        $ownerResponseBundleZipAutoAcceptanceCommand.Contains("Invoke-AITestPilotProductionExternalEvidenceAutoAcceptance.ps1") -and
        $ownerResponseBundleZipAutoAcceptanceCommand.Contains("-OwnerResponseBundleZipPath") -and
        $ownerResponseBundleZipAutoAcceptanceCommand.Contains("-RequireAllEvidence")) `
    "Action queue must expose one-command auto-acceptance paths for filled owner response bundle directories and zip files."
Add-QueueCheck "external_evidence_action_queue_item_bundle_commands" `
    ((@($queueItems | Where-Object {
            [string]::IsNullOrWhiteSpace([string](Get-JsonValue $_ "ownerResponseBundleAreaPath" "")) -or
            [string]::IsNullOrWhiteSpace([string](Get-JsonValue $_ "ownerResponseBundleRequiredFilesPath" "")) -or
            -not ([string](Get-JsonValue $_ "ownerResponseBundleAreaPath" "")).Contains([string](Get-JsonValue $_ "inboxDirectory" "")) -or
            -not ([string](Get-JsonValue $_ "ownerResponseBundleRequiredFilesPath" "")).Contains("required-files.json") -or
            -not ([string](Get-JsonValue $_ "ownerResponseBundleAutoAcceptanceCommand" "")).Contains("-OwnerResponseBundleDir") -or
            -not ([string](Get-JsonValue $_ "ownerResponseBundleZipAutoAcceptanceCommand" "")).Contains("-OwnerResponseBundleZipPath") -or
            ([string](Get-JsonValue $_ "ownerResponseBundleZipEnvironmentVariable" "")) -ne $ownerResponseBundleZipEnvironmentVariable
        }).Count -eq 0) -and $productionDriverEvidenceExportHelperItemCount -eq 1) `
    "Every external evidence queue item must carry owner response bundle area paths and directory/zip auto-acceptance commands, and the production driver item must expose the evidence export helper."
Add-QueueCheck "external_evidence_action_queue_current_bundle_paths" `
    ((-not [string]::IsNullOrWhiteSpace($responseKitZipPath)) -and
        $responseKitZipPath.StartsWith($evidenceBundlePath, [System.StringComparison]::OrdinalIgnoreCase) -and
        @($queueItems | Where-Object {
                $itemInboxPath = [string](Get-JsonValue $_ "inboxPath" "")
                [string]::IsNullOrWhiteSpace($itemInboxPath) -or
                    -not $itemInboxPath.StartsWith($evidenceBundlePath, [System.StringComparison]::OrdinalIgnoreCase)
            }).Count -eq 0) `
    "Action queue paths must resolve under the current evidence bundle, not stale source artifact paths."
Add-QueueCheck "external_evidence_action_queue_post_dispatch_boundary" `
    ((($sourceKind -eq "post_dispatch_snapshot") -and $progressNotificationEmailSent -and $localProgressMailRemainingActionCount -eq 0 -and $trackedRemainingWorkItemCount -eq 3) -or
        (($sourceKind -eq "remaining_work_snapshot") -and -not $progressNotificationEmailSent -and $localProgressMailRemainingActionCount -eq 1 -and $trackedRemainingWorkItemCount -eq 4)) `
    "Action queue must distinguish operator post-dispatch state from CI pending-mail state."
Add-QueueCheck "external_evidence_action_queue_boundary_preserved" `
    (-not (Convert-ToBool (Get-JsonValue $sourceSnapshot "realHostProjectEvidenceAccepted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $sourceSnapshot "externalEvidenceAccepted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $sourceSnapshot "fixtureEvidencePromoted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $ownerResponseBundleKit "releasePipelineSendsEmail" $true))) `
    "External evidence queue must not accept host-project evidence, promote fixtures, or send mail."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }
$generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")

$sourceFiles = @(
    "release-progress-notification-outbox/remaining-work-snapshot.json",
    "production-handoff-owner-input-request-pack-manifest.json",
    "production-handoff-owner-response-bundle-kit-manifest.json",
    "production-external-evidence-inbox-manifest.json"
)
if ($sourceKind -eq "post_dispatch_snapshot") {
    $sourceFiles += Convert-ToEvidenceRelativePath $postDispatchSnapshotPathFull
}

$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestFullPath),
    (Convert-ToEvidenceRelativePath $reportFullPath)
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_external_evidence_action_queue.v1"
    status = $status
    generatedAtUtc = $generatedAtUtc
    evidenceBundleDir = $evidenceBundlePath
    sourceKind = $sourceKind
    sourceSnapshotPath = $sourceSnapshotPath
    requirePostDispatch = [bool]$RequirePostDispatch
    ignorePostDispatchSnapshot = [bool]$IgnorePostDispatchSnapshot
    notificationDispatchStatus = $notificationDispatchStatus
    progressNotificationEmailSent = [bool]$progressNotificationEmailSent
    localProgressMailRemainingActionCount = [int]$localProgressMailRemainingActionCount
    trackedRemainingWorkItemCount = [int]$trackedRemainingWorkItemCount
    externalRemainingWorkItemCount = [int]$externalItems.Count
    externalRemainingBlockingReasonCount = [int]$totalBlockers
    externalRemainingMissingFileCount = [int]$totalMissing
    ownerResponseBundleKitZipPath = $responseKitZipPath
    inboxAcceptanceCommand = [string](Get-JsonValue $externalEvidenceInbox "acceptanceCommand" "")
    ownerResponseBundleAutoAcceptanceCommand = $ownerResponseBundleAutoAcceptanceCommand
    ownerResponseBundleZipAutoAcceptanceCommand = $ownerResponseBundleZipAutoAcceptanceCommand
    ownerResponseBundleZipEnvironmentVariable = $ownerResponseBundleZipEnvironmentVariable
    productionDriverEvidenceExportHelperPath = $productionDriverEvidenceExportHelperPath
    productionDriverEvidenceExportHelperCommand = $productionDriverEvidenceExportHelperCommand
    productionDriverEvidenceExportZipPath = $productionDriverEvidenceExportZipPath
    productionDriverEvidenceExportHelperItemCount = [int]$productionDriverEvidenceExportHelperItemCount
    actionQueue = @($queueItems)
    releasePipelineSendsEmail = $false
    realHostProjectEvidenceAccepted = $false
    externalEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = if ($sourceKind -eq "post_dispatch_snapshot") {
        "production_external_evidence_action_queue_after_progress_mail"
    } else {
        "production_external_evidence_action_queue_pending_progress_mail"
    }
    sourceFiles = @($sourceFiles)
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles + $sourceFiles)
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
}

$reportLines = @(
    "# AI TestPilot Production External Evidence Action Queue",
    "",
    "Schema: ``aitestpilot.production_external_evidence_action_queue.v1``",
    "Generated at UTC: $generatedAtUtc",
    "",
    "## Summary",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Status | $(Format-MarkdownCell $status) |",
    "| Source kind | $(Format-MarkdownCell $sourceKind) |",
    "| Progress notification sent | $progressNotificationEmailSent |",
    "| Local progress mail remaining actions | $localProgressMailRemainingActionCount |",
    "| Tracked remaining work items | $trackedRemainingWorkItemCount |",
    "| External work items | $($queueItems.Count) |",
    "| External blockers | $totalBlockers |",
    "| External missing files | $totalMissing |",
    "| Response bundle kit zip | $(Format-MarkdownCell $responseKitZipPath) |",
    "| Owner response bundle auto acceptance | $(Format-MarkdownCell $ownerResponseBundleAutoAcceptanceCommand) |",
    "| Owner response bundle zip auto acceptance | $(Format-MarkdownCell $ownerResponseBundleZipAutoAcceptanceCommand) |",
    "| Production driver evidence export helper | $(Format-MarkdownCell $productionDriverEvidenceExportHelperCommand) |",
    "",
    "## Queue",
    "",
    "| Area | Owner | Missing Files | Blockers | Preflight | Inbox Acceptance | Bundle Area | Bundle Acceptance | Driver Export | Hard Validation |",
    "| --- | --- | ---: | ---: | --- | --- | --- | --- | --- | --- |"
)
foreach ($item in $queueItems) {
    $area = Get-JsonValue $item "area" ""
    $owner = Get-JsonValue $item "owner" ""
    $missingFileCount = Get-JsonValue $item "missingFileCount" 0
    $blockingReasonCount = Get-JsonValue $item "remainingBlockingReasonCount" 0
    $preflightCommand = Get-JsonValue $item "preflightCommand" ""
    $acceptanceWrapperCommand = Get-JsonValue $item "acceptanceWrapperCommand" ""
    $bundleAreaPath = Get-JsonValue $item "ownerResponseBundleAreaPath" ""
    $bundleAcceptanceCommand = Get-JsonValue $item "ownerResponseBundleZipAutoAcceptanceCommand" ""
    $driverExportCommand = Get-JsonValue $item "productionDriverEvidenceExportHelperCommand" ""
    $hardValidationCommand = Get-JsonValue $item "hardValidationCommand" ""
    $reportLines += "| $(Format-MarkdownCell $area) | $(Format-MarkdownCell $owner) | $missingFileCount | $blockingReasonCount | $(Format-MarkdownCell $preflightCommand) | $(Format-MarkdownCell $acceptanceWrapperCommand) | $(Format-MarkdownCell $bundleAreaPath) | $(Format-MarkdownCell $bundleAcceptanceCommand) | $(Format-MarkdownCell $driverExportCommand) | $(Format-MarkdownCell $hardValidationCommand) |"
}
$reportLines += @(
    "",
    "## Required Files",
    "",
    "| Area | Required Files | Missing Files | Reasons |",
    "| --- | --- | --- | --- |"
)
foreach ($item in $queueItems) {
    $area = Get-JsonValue $item "area" ""
    $requiredFiles = Join-TextList @(Get-JsonValue $item "requiredEvidenceFiles" @())
    $missingFiles = Join-TextList @(Get-JsonValue $item "missingFiles" @())
    $remainingReasons = Join-TextList @(Get-JsonValue $item "remainingBlockingReasons" @())
    $reportLines += "| $(Format-MarkdownCell $area) | $(Format-MarkdownCell $requiredFiles) | $(Format-MarkdownCell $missingFiles) | $(Format-MarkdownCell $remainingReasons) |"
}
$reportLines += @(
    "",
    "## Boundary",
    "",
    "- This queue does not send email.",
    "- This queue does not accept real host-project evidence.",
    "- Fixture evidence remains unpromoted.",
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
    throw "Production external evidence action queue failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production external evidence action queue manifest: $manifestFullPath"
Write-Output "Production external evidence action queue report: $reportFullPath"
Write-Output "PASS AI TestPilot production external evidence action queue"
