[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ManifestPath,
    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "release-progress-notification-remaining-work-snapshot-probe-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "release-progress-notification-remaining-work-snapshot-probe.md"
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

function Add-SnapshotCheck {
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

$outboxManifest = Read-JsonFile (Join-Path $evidenceBundlePath "release-progress-notification-outbox-manifest.json") "Release progress notification outbox manifest"
$snapshotPath = Join-Path $evidenceBundlePath "release-progress-notification-outbox\remaining-work-snapshot.json"
$snapshotMarkdownPath = Join-Path $evidenceBundlePath "release-progress-notification-outbox\remaining-work-snapshot.md"
$snapshot = Read-JsonFile $snapshotPath "Release progress notification remaining-work snapshot"
$ownerInputRequestManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-owner-input-request-pack-manifest.json") "Production handoff owner input request pack manifest"
$productionDriverReadinessManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-replay-driver-readiness-manifest.json") "Production replay driver readiness manifest"
$productionLuaPatchReadinessManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-lua-patch-readiness-manifest.json") "Production Lua patch readiness manifest"
$productionExternalEvidenceInboxManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-external-evidence-inbox-manifest.json") "Production external evidence inbox manifest"

$snapshotItems = @(Convert-ToArray (Get-JsonValue $snapshot "externalRemainingWorkItems" @()))
$areaNames = @($snapshotItems | ForEach-Object { [string](Get-JsonValue $_ "area" "") })
$workByArea = @{}
foreach ($item in $snapshotItems) {
    $workByArea[[string](Get-JsonValue $item "area" "")] = $item
}

$driverItem = $workByArea["production_driver_binding"]
$luaItem = $workByArea["production_lua_patch_evidence"]
$liveItem = $workByArea["live_model_endpoint_smoke"]
$localMailItem = Get-JsonValue $snapshot "localProgressMailWorkItem" $null

$externalWorkItemCount = Convert-ToInt (Get-JsonValue $snapshot "externalRemainingWorkItemCount" 0)
$externalBlockingReasonCount = Convert-ToInt (Get-JsonValue $snapshot "externalRemainingBlockingReasonCount" 0)
$externalMissingFileCount = Convert-ToInt (Get-JsonValue $snapshot "externalRemainingMissingFileCount" 0)
$localProgressMailRemainingActionCount = Convert-ToInt (Get-JsonValue $snapshot "localProgressMailRemainingActionCount" 0)
$trackedRemainingWorkItemCount = Convert-ToInt (Get-JsonValue $snapshot "trackedRemainingWorkItemCount" 0)
$notificationDispatchStatus = [string](Get-JsonValue $snapshot "notificationDispatchStatus" "")

$driverBlockingReasonCount = Convert-ToInt (Get-JsonValue $productionDriverReadinessManifest "blockingReasonCount" 0)
$luaBlockingReasonCount = Convert-ToInt (Get-JsonValue $productionLuaPatchReadinessManifest "blockingReasonCount" 0)
$liveBlockingReasonCount = Convert-ToInt (Get-JsonValue $liveItem "remainingBlockingReasonCount" 0)

$checks = @()
Add-SnapshotCheck "remaining_work_snapshot_sources_available" `
    ($outboxManifest.status -eq "PASS" -and
        $ownerInputRequestManifest.status -eq "PASS" -and
        $productionDriverReadinessManifest.status -eq "PASS" -and
        $productionLuaPatchReadinessManifest.status -eq "PASS" -and
        $productionExternalEvidenceInboxManifest.status -eq "PASS" -and
        (Test-Path $snapshotMarkdownPath)) `
    "Remaining-work snapshot probe must be based on passing outbox, owner input, driver readiness, Lua readiness, external inbox, and Markdown snapshot evidence."

Add-SnapshotCheck "remaining_work_snapshot_schema_and_boundary" `
    ((Get-JsonValue $snapshot "schemaVersion" "") -eq "aitestpilot.release_progress_notification_remaining_work_snapshot.v1" -and
        $snapshot.status -eq "PASS" -and
        (Get-JsonValue $snapshot "latestBigNodeName" "") -eq "production_handoff_owner_response_bundle_kit" -and
        (Get-JsonValue $snapshot "latestBigNodeStatus" "") -eq "PASS" -and
        $notificationDispatchStatus -eq "PENDING_LOCAL_MAIL_AUTH_AND_CONFIRMATION" -and
        -not (Convert-ToBool (Get-JsonValue $snapshot "releasePipelineSendsEmail" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $snapshot "emailSent" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $snapshot "confirmationTokenCreated" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $snapshot "realHostProjectEvidenceAccepted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $snapshot "externalEvidenceAccepted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $snapshot "fixtureEvidencePromoted" $true)) -and
        (Get-JsonValue $snapshot "productionOutputBoundary" "") -eq "release_progress_notification_remaining_work_snapshot_only") `
    "Remaining-work snapshot must preserve the pending-send, not-sent, non-fixture-promoted boundary."

Add-SnapshotCheck "remaining_work_snapshot_owner_area_counts" `
    ($externalWorkItemCount -eq 3 -and
        $snapshotItems.Count -eq 3 -and
        $areaNames -contains "production_driver_binding" -and
        $areaNames -contains "production_lua_patch_evidence" -and
        $areaNames -contains "live_model_endpoint_smoke" -and
        $externalBlockingReasonCount -eq (Convert-ToInt (Get-JsonValue $ownerInputRequestManifest "remainingBlockingReasonCount" 0)) -and
        $externalMissingFileCount -eq (Convert-ToInt (Get-JsonValue $ownerInputRequestManifest "missingRequiredFileCount" 0)) -and
        $externalMissingFileCount -eq (Convert-ToInt (Get-JsonValue $productionExternalEvidenceInboxManifest "missingRequiredFileCount" 0))) `
    "Remaining-work snapshot must track the same three owner areas, eleven blockers, and nine missing files as owner input and external inbox evidence."

Add-SnapshotCheck "remaining_work_snapshot_readiness_breakdown" `
    ($driverBlockingReasonCount -eq 5 -and
        $luaBlockingReasonCount -eq 5 -and
        $liveBlockingReasonCount -eq 1 -and
        (Convert-ToInt (Get-JsonValue $driverItem "remainingBlockingReasonCount" 0)) -eq $driverBlockingReasonCount -and
        (Convert-ToInt (Get-JsonValue $luaItem "remainingBlockingReasonCount" 0)) -eq $luaBlockingReasonCount -and
        -not (Convert-ToBool (Get-JsonValue $productionDriverReadinessManifest "readyForProductionDriverRelease" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $productionLuaPatchReadinessManifest "readyForProductionLuaPatchRelease" $true)) -and
        @(Convert-ToArray (Get-JsonValue $driverItem "remainingBlockingReasons" @())) -contains "production_replay_integration_not_bound" -and
        @(Convert-ToArray (Get-JsonValue $luaItem "remainingBlockingReasons" @())) -contains "real_production_lua_bundle_missing" -and
        @(Convert-ToArray (Get-JsonValue $liveItem "remainingBlockingReasons" @())) -contains "real_live_model_endpoint_smoke_missing") `
    "Remaining-work snapshot must break the eleven blockers into driver, Lua, and live-smoke areas."

Add-SnapshotCheck "remaining_work_snapshot_local_mail_action" `
    ($localProgressMailRemainingActionCount -eq 1 -and
        $trackedRemainingWorkItemCount -eq 4 -and
        $null -ne $localMailItem -and
        (Get-JsonValue $localMailItem "area" "") -eq "release_progress_notification_send" -and
        (Get-JsonValue $localMailItem "status" "") -eq "PENDING_LOCAL_MAIL_AUTH_AND_CONFIRMATION" -and
        (Get-JsonValue $localMailItem "recipient" "") -eq "kibernet@sina.com" -and
        (Convert-ToBool (Get-JsonValue $localMailItem "twoStageConfirmationRequired" $false)) -and
        -not (Convert-ToBool (Get-JsonValue $localMailItem "releasePipelineSendsEmail" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $localMailItem "emailSent" $true))) `
    "Remaining-work snapshot must track the one local progress-mail action without claiming CI send or real email delivery."

$snapshotMarkdownContent = Get-Content -Path $snapshotMarkdownPath -Encoding UTF8 -Raw
$snapshotContent = Get-Content -Path $snapshotPath -Encoding UTF8 -Raw
$contentValidated = $snapshotContent.Contains("release_progress_notification_remaining_work_snapshot.v1") -and
    $snapshotContent.Contains("production_driver_binding") -and
    $snapshotContent.Contains("production_lua_patch_evidence") -and
    $snapshotContent.Contains("live_model_endpoint_smoke") -and
    $snapshotMarkdownContent.Contains("AI TestPilot Remaining Work Snapshot") -and
    $snapshotMarkdownContent.Contains("Local Progress Mail") -and
    -not $snapshotContent.Contains("System.Collections") -and
    -not $snapshotContent.Contains("@{") -and
    -not $snapshotMarkdownContent.Contains("System.Collections") -and
    -not $snapshotMarkdownContent.Contains("@{")

Add-SnapshotCheck "remaining_work_snapshot_content_validated" $contentValidated `
    "Remaining-work snapshot JSON and Markdown must be readable, area-specific, and free of PowerShell object leakage."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$manifestStatus = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$reportLines = @(
    "# AI TestPilot Release Progress Notification Remaining Work Snapshot Probe",
    "",
    "Schema: ``aitestpilot.release_progress_notification_remaining_work_snapshot_probe.v1``",
    "Generated at UTC: $((Get-Date).ToUniversalTime().ToString("O"))",
    "",
    "## Summary",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Status | $(Format-MarkdownCell $manifestStatus) |",
    "| Notification dispatch status | $(Format-MarkdownCell $notificationDispatchStatus) |",
    "| External work item count | $externalWorkItemCount |",
    "| External blocker count | $externalBlockingReasonCount |",
    "| External missing file count | $externalMissingFileCount |",
    "| Local progress mail remaining actions | $localProgressMailRemainingActionCount |",
    "| Tracked remaining work items | $trackedRemainingWorkItemCount |",
    "| Driver blockers | $driverBlockingReasonCount |",
    "| Lua blockers | $luaBlockingReasonCount |",
    "| Live-smoke blockers | $liveBlockingReasonCount |",
    "",
    "## Areas",
    "",
    "| Area | Owner | Blockers | Missing Files | Reasons |",
    "| --- | --- | ---: | ---: | --- |"
)
foreach ($item in $snapshotItems) {
    $area = Get-JsonValue $item "area" ""
    $owner = Get-JsonValue $item "owner" ""
    $itemBlockingReasonCount = Convert-ToInt (Get-JsonValue $item "remainingBlockingReasonCount" 0)
    $itemMissingFileCount = Convert-ToInt (Get-JsonValue $item "missingFileCount" 0)
    $itemReasons = Join-TextList @(Convert-ToArray (Get-JsonValue $item "remainingBlockingReasons" @()))
    $reportLines += "| $(Format-MarkdownCell $area) | $(Format-MarkdownCell $owner) | $itemBlockingReasonCount | $itemMissingFileCount | $(Format-MarkdownCell $itemReasons) |"
}
$reportLines += @(
    "",
    "## Checks",
    "",
    "| Check | Result |",
    "| --- | --- |"
)
foreach ($check in $checks) {
    $result = if ([bool]$check.passed) { "PASS" } else { "FAIL" }
    $reportLines += "| $(Format-MarkdownCell $check.name) | $result |"
}
$reportLines | Set-Content -Path $reportFullPath -Encoding UTF8

$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestFullPath),
    (Convert-ToEvidenceRelativePath $reportFullPath)
)
$sourceFiles = @(
    "release-progress-notification-outbox-manifest.json",
    "release-progress-notification-outbox/remaining-work-snapshot.json",
    "release-progress-notification-outbox/remaining-work-snapshot.md",
    "production-handoff-owner-input-request-pack-manifest.json",
    "production-replay-driver-readiness-manifest.json",
    "production-lua-patch-readiness-manifest.json",
    "production-external-evidence-inbox-manifest.json"
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.release_progress_notification_remaining_work_snapshot_probe.v1"
    status = $manifestStatus
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    reportPath = $reportFullPath
    snapshotPath = $snapshotPath
    snapshotMarkdownPath = $snapshotMarkdownPath
    outboxStatus = [string](Get-JsonValue $outboxManifest "status" "")
    snapshotSchemaVersionAccepted = (Get-JsonValue $snapshot "schemaVersion" "") -eq "aitestpilot.release_progress_notification_remaining_work_snapshot.v1"
    snapshotContentValidated = [bool]$contentValidated
    notificationDispatchStatus = $notificationDispatchStatus
    externalRemainingWorkItemCount = [int]$externalWorkItemCount
    externalRemainingBlockingReasonCount = [int]$externalBlockingReasonCount
    externalRemainingMissingFileCount = [int]$externalMissingFileCount
    localProgressMailRemainingActionCount = [int]$localProgressMailRemainingActionCount
    trackedRemainingWorkItemCount = [int]$trackedRemainingWorkItemCount
    productionDriverBlockingReasonCount = [int]$driverBlockingReasonCount
    productionLuaBlockingReasonCount = [int]$luaBlockingReasonCount
    liveModelSmokeBlockingReasonCount = [int]$liveBlockingReasonCount
    ownerAreas = @($areaNames)
    releasePipelineSendsEmail = $false
    emailSent = $false
    confirmationTokenCreated = $false
    realHostProjectEvidenceAccepted = $false
    externalEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "progress_notification_remaining_work_snapshot_probe_only"
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
    throw "Release progress notification remaining-work snapshot probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Release progress notification remaining-work snapshot probe manifest: $manifestFullPath"
Write-Output "Release progress notification remaining-work snapshot probe report: $reportFullPath"
Write-Output "PASS AI TestPilot release progress notification remaining-work snapshot probe"
