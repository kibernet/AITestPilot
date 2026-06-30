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

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ProbeDir)) {
    $ProbeDir = Join-Path $EvidenceBundleDir "production-external-evidence-action-queue-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-external-evidence-action-queue-probe-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-external-evidence-action-queue-probe.md"
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

function Invoke-ActionQueue {
    param(
        [string]$Name,
        [string]$PostDispatchSnapshotPath,
        [switch]$IgnorePostDispatchSnapshot,
        [switch]$RequirePostDispatch
    )

    $queueManifestPath = Join-Path $probePath "$Name-manifest.json"
    $queueReportPath = Join-Path $probePath "$Name.md"
    $outputPath = Join-Path $probePath "$Name-output.txt"

    $powerShellArgs = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionExternalEvidenceActionQueue.ps1"),
        "-EvidenceBundleDir",
        $evidenceBundlePath,
        "-ManifestPath",
        $queueManifestPath,
        "-ReportPath",
        $queueReportPath
    )
    if (-not [string]::IsNullOrWhiteSpace($PostDispatchSnapshotPath)) {
        $powerShellArgs += @("-PostDispatchSnapshotPath", $PostDispatchSnapshotPath)
    }
    if ([bool]$IgnorePostDispatchSnapshot) {
        $powerShellArgs += "-IgnorePostDispatchSnapshot"
    }
    if ([bool]$RequirePostDispatch) {
        $powerShellArgs += "-RequirePostDispatch"
    }

    $oldErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & powershell.exe @powerShellArgs 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }
    @($output | ForEach-Object { [string]$_ }) | Set-Content -Path $outputPath -Encoding UTF8

    $manifest = $null
    if (Test-Path $queueManifestPath) {
        $manifest = Read-JsonFile $queueManifestPath "$Name action queue manifest"
    }

    return [ordered]@{
        name = $Name
        exitCode = [int]$exitCode
        outputPath = $outputPath
        manifestPath = $queueManifestPath
        reportPath = $queueReportPath
        manifest = $manifest
    }
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$probePath = Assert-PathUnderRepo $ProbeDir "ProbeDir"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

New-Item -ItemType Directory -Force $probePath | Out-Null
New-Item -ItemType Directory -Force (Split-Path $manifestFullPath -Parent) | Out-Null

$remainingSnapshot = Read-JsonFile (Join-Path $evidenceBundlePath "release-progress-notification-outbox\remaining-work-snapshot.json") "Release progress notification remaining-work snapshot"
$ownerInputRequest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-owner-input-request-pack-manifest.json") "Production handoff owner input request pack manifest"
$responseBundleKit = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-owner-response-bundle-kit-manifest.json") "Production handoff owner response bundle kit manifest"
$externalInbox = Read-JsonFile (Join-Path $evidenceBundlePath "production-external-evidence-inbox-manifest.json") "Production external evidence inbox manifest"

$pendingResult = Invoke-ActionQueue -Name "pending-progress-mail-action-queue" -IgnorePostDispatchSnapshot

$contractPostDispatchPath = Join-Path $probePath "contract-post-dispatch-snapshot-manifest.json"
$contractPostDispatch = [ordered]@{
    schemaVersion = "aitestpilot.release_progress_notification_post_dispatch_snapshot.v1"
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    sourceSnapshotPath = Join-Path $evidenceBundlePath "release-progress-notification-outbox\remaining-work-snapshot.json"
    notificationDispatchStatus = "SENT_BY_LOCAL_AGENTLY_CLI"
    progressNotificationEmailSent = $true
    emailSent = $true
    releasePipelineSendsEmail = $false
    localProgressMailRemainingActionCount = 0
    trackedRemainingWorkItemCount = 3
    externalRemainingWorkItemCount = 3
    externalRemainingBlockingReasonCount = 11
    externalRemainingMissingFileCount = 9
    externalRemainingWorkItems = @(Convert-ToArray (Get-JsonValue $remainingSnapshot "externalRemainingWorkItems" @()))
    realHostProjectEvidenceAccepted = $false
    externalEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "release_progress_notification_post_dispatch_snapshot_contract_probe_only"
}
$contractPostDispatch | ConvertTo-Json -Depth 12 | Set-Content -Path $contractPostDispatchPath -Encoding UTF8

$postDispatchResult = Invoke-ActionQueue `
    -Name "post-dispatch-action-queue" `
    -PostDispatchSnapshotPath $contractPostDispatchPath `
    -RequirePostDispatch

$missingPostDispatchResult = Invoke-ActionQueue `
    -Name "missing-post-dispatch-action-queue" `
    -PostDispatchSnapshotPath (Join-Path $probePath "missing-post-dispatch-snapshot.json") `
    -RequirePostDispatch

$pendingManifest = $pendingResult.manifest
$postDispatchManifest = $postDispatchResult.manifest
$missingPostDispatchManifest = $missingPostDispatchResult.manifest

$checks = @()
Add-ProbeCheck "action_queue_sources_available" `
    ((Get-JsonValue $remainingSnapshot "status" "") -eq "PASS" -and
        (Get-JsonValue $ownerInputRequest "status" "") -eq "PASS" -and
        (Get-JsonValue $responseBundleKit "status" "") -eq "PASS" -and
        (Get-JsonValue $externalInbox "status" "") -eq "PASS" -and
        (Test-Path (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionExternalEvidenceActionQueue.ps1"))) `
    "Action queue probe must use passing remaining-work, owner-input, response-bundle-kit, inbox, and source script evidence."
Add-ProbeCheck "pending_queue_keeps_progress_mail_action" `
    ($pendingResult.exitCode -eq 0 -and
        (Get-JsonValue $pendingManifest "status" "") -eq "PASS" -and
        (Get-JsonValue $pendingManifest "sourceKind" "") -eq "remaining_work_snapshot" -and
        (Convert-ToBool (Get-JsonValue $pendingManifest "ignorePostDispatchSnapshot" $false)) -and
        -not (Convert-ToBool (Get-JsonValue $pendingManifest "progressNotificationEmailSent" $true)) -and
        (Convert-ToInt (Get-JsonValue $pendingManifest "localProgressMailRemainingActionCount" 0)) -eq 1 -and
        (Convert-ToInt (Get-JsonValue $pendingManifest "trackedRemainingWorkItemCount" 0)) -eq 4) `
    "Default CI action queue must keep local progress mail in remaining work when no post-dispatch snapshot is supplied."
Add-ProbeCheck "post_dispatch_queue_clears_progress_mail_action" `
    ($postDispatchResult.exitCode -eq 0 -and
        (Get-JsonValue $postDispatchManifest "status" "") -eq "PASS" -and
        (Get-JsonValue $postDispatchManifest "sourceKind" "") -eq "post_dispatch_snapshot" -and
        (Convert-ToBool (Get-JsonValue $postDispatchManifest "progressNotificationEmailSent" $false)) -and
        (Convert-ToInt (Get-JsonValue $postDispatchManifest "localProgressMailRemainingActionCount" 1)) -eq 0 -and
        (Convert-ToInt (Get-JsonValue $postDispatchManifest "trackedRemainingWorkItemCount" 0)) -eq 3) `
    "Post-dispatch action queue must clear only the local progress-mail action."
Add-ProbeCheck "action_queue_preserves_external_counts" `
    ((Convert-ToInt (Get-JsonValue $pendingManifest "externalRemainingWorkItemCount" 0)) -eq 3 -and
        (Convert-ToInt (Get-JsonValue $pendingManifest "externalRemainingMissingFileCount" 0)) -eq 9 -and
        (Convert-ToInt (Get-JsonValue $pendingManifest "externalRemainingBlockingReasonCount" 0)) -eq 11 -and
        (Convert-ToInt (Get-JsonValue $postDispatchManifest "externalRemainingWorkItemCount" 0)) -eq 3 -and
        (Convert-ToInt (Get-JsonValue $postDispatchManifest "externalRemainingMissingFileCount" 0)) -eq 9 -and
        (Convert-ToInt (Get-JsonValue $postDispatchManifest "externalRemainingBlockingReasonCount" 0)) -eq 11) `
    "Both pending and post-dispatch queues must preserve the three external areas, nine files, and eleven blockers."
Add-ProbeCheck "action_queue_exposes_owner_response_bundle_auto_acceptance" `
    (([string](Get-JsonValue $pendingManifest "ownerResponseBundleAutoAcceptanceCommand" "")).Contains("-OwnerResponseBundleDir") -and
        ([string](Get-JsonValue $pendingManifest "ownerResponseBundleZipAutoAcceptanceCommand" "")).Contains("-OwnerResponseBundleZipPath") -and
        ([string](Get-JsonValue $pendingManifest "ownerResponseBundleZipAutoAcceptanceCommand" "")).Contains("-RequireAllEvidence") -and
        (Get-JsonValue $pendingManifest "ownerResponseBundleZipEnvironmentVariable" "") -eq "AITESTPILOT_OWNER_RESPONSE_BUNDLE_ZIP_PATH" -and
        ([string](Get-JsonValue $postDispatchManifest "ownerResponseBundleAutoAcceptanceCommand" "")).Contains("-OwnerResponseBundleDir") -and
        ([string](Get-JsonValue $postDispatchManifest "ownerResponseBundleZipAutoAcceptanceCommand" "")).Contains("-OwnerResponseBundleZipPath") -and
        ([string](Get-JsonValue $postDispatchManifest "ownerResponseBundleZipAutoAcceptanceCommand" "")).Contains("-RequireAllEvidence") -and
        (Get-JsonValue $postDispatchManifest "ownerResponseBundleZipEnvironmentVariable" "") -eq "AITESTPILOT_OWNER_RESPONSE_BUNDLE_ZIP_PATH") `
    "Pending and post-dispatch action queues must expose one-command owner response bundle directory and zip auto-acceptance paths."
Add-ProbeCheck "missing_post_dispatch_rejected_when_required" `
    ($missingPostDispatchResult.exitCode -ne 0 -and $null -eq $missingPostDispatchManifest) `
    "RequirePostDispatch must reject a missing post-dispatch snapshot instead of falling back silently."
Add-ProbeCheck "action_queue_boundaries_preserved" `
    (-not (Convert-ToBool (Get-JsonValue $pendingManifest "releasePipelineSendsEmail" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $pendingManifest "externalEvidenceAccepted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $pendingManifest "fixtureEvidencePromoted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $postDispatchManifest "releasePipelineSendsEmail" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $postDispatchManifest "externalEvidenceAccepted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $postDispatchManifest "fixtureEvidencePromoted" $true))) `
    "Action queues must preserve no-send, no-real-evidence, and no-fixture-promotion boundaries."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestFullPath),
    (Convert-ToEvidenceRelativePath $reportFullPath),
    (Convert-ToEvidenceRelativePath $contractPostDispatchPath),
    (Convert-ToEvidenceRelativePath $pendingResult.outputPath),
    (Convert-ToEvidenceRelativePath $pendingResult.manifestPath),
    (Convert-ToEvidenceRelativePath $pendingResult.reportPath),
    (Convert-ToEvidenceRelativePath $postDispatchResult.outputPath),
    (Convert-ToEvidenceRelativePath $postDispatchResult.manifestPath),
    (Convert-ToEvidenceRelativePath $postDispatchResult.reportPath),
    (Convert-ToEvidenceRelativePath $missingPostDispatchResult.outputPath)
)
$sourceFiles = @(
    "release-progress-notification-outbox/remaining-work-snapshot.json",
    "production-handoff-owner-input-request-pack-manifest.json",
    "production-handoff-owner-response-bundle-kit-manifest.json",
    "production-external-evidence-inbox-manifest.json"
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_external_evidence_action_queue_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    probeDir = $probePath
    pendingQueueAccepted = (Get-JsonValue $pendingManifest "status" "") -eq "PASS"
    pendingQueueLocalMailRemainingActionCount = Convert-ToInt (Get-JsonValue $pendingManifest "localProgressMailRemainingActionCount" 0)
    pendingQueueTrackedRemainingWorkItemCount = Convert-ToInt (Get-JsonValue $pendingManifest "trackedRemainingWorkItemCount" 0)
    postDispatchQueueAccepted = (Get-JsonValue $postDispatchManifest "status" "") -eq "PASS"
    postDispatchQueueLocalMailRemainingActionCount = Convert-ToInt (Get-JsonValue $postDispatchManifest "localProgressMailRemainingActionCount" 1)
    postDispatchQueueTrackedRemainingWorkItemCount = Convert-ToInt (Get-JsonValue $postDispatchManifest "trackedRemainingWorkItemCount" 0)
    externalRemainingWorkItemCount = Convert-ToInt (Get-JsonValue $postDispatchManifest "externalRemainingWorkItemCount" 0)
    externalRemainingMissingFileCount = Convert-ToInt (Get-JsonValue $postDispatchManifest "externalRemainingMissingFileCount" 0)
    externalRemainingBlockingReasonCount = Convert-ToInt (Get-JsonValue $postDispatchManifest "externalRemainingBlockingReasonCount" 0)
    pendingQueueOwnerResponseBundleAutoAcceptanceCommand = [string](Get-JsonValue $pendingManifest "ownerResponseBundleAutoAcceptanceCommand" "")
    pendingQueueOwnerResponseBundleZipAutoAcceptanceCommand = [string](Get-JsonValue $pendingManifest "ownerResponseBundleZipAutoAcceptanceCommand" "")
    postDispatchQueueOwnerResponseBundleAutoAcceptanceCommand = [string](Get-JsonValue $postDispatchManifest "ownerResponseBundleAutoAcceptanceCommand" "")
    postDispatchQueueOwnerResponseBundleZipAutoAcceptanceCommand = [string](Get-JsonValue $postDispatchManifest "ownerResponseBundleZipAutoAcceptanceCommand" "")
    ownerResponseBundleZipEnvironmentVariable = [string](Get-JsonValue $postDispatchManifest "ownerResponseBundleZipEnvironmentVariable" "")
    missingPostDispatchRejected = [bool]($missingPostDispatchResult.exitCode -ne 0)
    releasePipelineSendsEmail = $false
    externalEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "production_external_evidence_action_queue_probe_only"
    sourceFiles = @($sourceFiles)
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles + $sourceFiles)
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
}

$reportLines = @(
    "# AI TestPilot Production External Evidence Action Queue Probe",
    "",
    "- Status: $status",
    "- Pending queue local mail remaining actions: $($manifest.pendingQueueLocalMailRemainingActionCount)",
    "- Post-dispatch queue local mail remaining actions: $($manifest.postDispatchQueueLocalMailRemainingActionCount)",
    "- External missing files: $($manifest.externalRemainingMissingFileCount)",
    "- Owner response bundle zip auto acceptance: $($manifest.postDispatchQueueOwnerResponseBundleZipAutoAcceptanceCommand)",
    "- Missing post-dispatch rejected: $($manifest.missingPostDispatchRejected)",
    "",
    "## Boundary",
    "",
    "- Default CI queue keeps progress mail pending.",
    "- Post-dispatch queue clears only the local progress-mail action.",
    "- No queue sends mail or accepts real host-project evidence.",
    "",
    "## Checks",
    "",
    "| Check | Passed | Message |",
    "| --- | --- | --- |"
)
foreach ($check in $checks) {
    $reportLines += "| $(Format-MarkdownCell $check.name) | $($check.passed) | $(Format-MarkdownCell $check.message) |"
}

$reportLines | Set-Content -Path $reportFullPath -Encoding UTF8
$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestFullPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Production external evidence action queue probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production external evidence action queue probe manifest: $manifestFullPath"
Write-Output "Production external evidence action queue probe report: $reportFullPath"
Write-Output "PASS AI TestPilot production external evidence action queue probe"
