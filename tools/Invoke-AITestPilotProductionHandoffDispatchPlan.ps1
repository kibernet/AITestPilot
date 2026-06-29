[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$DispatchDir,
    [string]$ManifestPath,
    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($DispatchDir)) {
    $DispatchDir = Join-Path $EvidenceBundleDir "production-handoff-dispatch"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-handoff-dispatch-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-handoff-dispatch.md"
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

function Join-MarkdownList {
    param([object[]]$Values)

    $items = @($Values | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($items.Count -eq 0) {
        return "(none)"
    }

    return [string]::Join(", ", $items)
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

function Add-DispatchCheck {
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
$dispatchPath = Assert-PathUnderRepo $DispatchDir "DispatchDir"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if (Test-Path $dispatchPath) {
    Remove-Item -LiteralPath $dispatchPath -Recurse -Force
}
New-Item -ItemType Directory -Force $dispatchPath | Out-Null

$handoffManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-package-manifest.json") "Production handoff package manifest"
$ownerPacketIndex = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-package\owner-packets\owner-packet-index.json") "Production handoff owner packet index"
$handoffExportManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-export-manifest.json") "Production handoff export manifest"
$handoffStatusManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-status-manifest.json") "Production handoff status manifest"
$inboxManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-external-evidence-inbox-manifest.json") "Production external evidence inbox manifest"

$exportZipPath = Join-Path $evidenceBundlePath "production-handoff-export.zip"
$queuePath = Join-Path $dispatchPath "production-handoff-dispatch-queue.json"
$draftDir = Join-Path $dispatchPath "email-drafts"
New-Item -ItemType Directory -Force $draftDir | Out-Null

$dispatchEntries = @()
foreach ($packet in @(Convert-ToArray $ownerPacketIndex.packets)) {
    $owner = [string](Get-JsonValue $packet "owner" "")
    $area = [string](Get-JsonValue $packet "area" "")
    $slug = Convert-ToSlug $owner
    $draftFileName = $slug + ".md"
    $draftPath = Join-Path $draftDir $draftFileName
    $packetPath = [string](Get-JsonValue $packet "packetPath" "")
    $requiredFiles = @(Convert-ToArray (Get-JsonValue $packet "requiredEvidenceFiles" @()) | ForEach-Object { [string]$_ })
    $blockingReasons = @(Convert-ToArray (Get-JsonValue $packet "remainingBlockingReasons" @()) | ForEach-Object { [string]$_ })
    $subject = "AI TestPilot production evidence request - $area"
    $recipientPlaceholder = "replace-with-$slug-email"
    $expectedReturnDir = [string](Get-JsonValue $packet "ownerEvidenceDirPlaceholder" "")
    $preflightCommand = [string](Get-JsonValue $packet "preflightCommand" "")
    $acceptanceWrapperCommand = [string](Get-JsonValue $packet "acceptanceWrapperCommand" "")
    $hardValidationCommand = [string](Get-JsonValue $packet "hardValidationCommand" "")

    $draftLines = @(
        "To: $recipientPlaceholder",
        "Subject: $subject",
        "",
        "Please complete the AI TestPilot production evidence packet for ``$area``.",
        "",
        "Owner packet: ``$packetPath``",
        "Handoff export: ``production-handoff-export.zip``",
        "Returned evidence directory: ``$expectedReturnDir``",
        "",
        "Required files:",
        ""
    )
    foreach ($fileName in $requiredFiles) {
        $draftLines += "- ``$fileName``"
    }

    $draftLines += @(
        "",
        "Remaining blockers covered by this packet:",
        ""
    )
    foreach ($reason in $blockingReasons) {
        $draftLines += "- ``$reason``"
    }

    $draftLines += @(
        "",
        "Validation commands:",
        "",
        '```powershell',
        $preflightCommand,
        $acceptanceWrapperCommand,
        $hardValidationCommand,
        '```',
        "",
        "Boundary: fixture contract reports in the export prove schemas only. Production completion requires returned host-project evidence and the hard validation command to pass."
    )

    $draftText = [string]::Join([Environment]::NewLine, $draftLines) + [Environment]::NewLine
    $draftText | Set-Content -Path $draftPath -Encoding UTF8

    $dispatchEntries += [ordered]@{
        owner = $owner
        area = $area
        dispatchStatus = "READY_FOR_OWNER_CONTACT"
        recipientPlaceholder = $recipientPlaceholder
        recipientConfigured = $false
        subject = $subject
        draftPath = "production-handoff-dispatch/email-drafts/$draftFileName"
        ownerPacketPath = $packetPath
        handoffExportZipPath = "production-handoff-export.zip"
        expectedReturnDir = $expectedReturnDir
        requiredEvidenceFiles = @($requiredFiles)
        remainingBlockingReasons = @($blockingReasons)
        preflightCommand = $preflightCommand
        acceptanceWrapperCommand = $acceptanceWrapperCommand
        hardValidationCommand = $hardValidationCommand
    }
}

$queue = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_dispatch_queue.v1"
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    ownerPacketCount = [int]@($dispatchEntries).Count
    dispatchEntryCount = [int]@($dispatchEntries).Count
    sentDispatchCount = 0
    pendingDispatchCount = [int]@($dispatchEntries).Count
    realOwnerEmailAddressesConfigured = $false
    automaticEmailSendReady = $false
    contactPlaceholdersExplicit = $true
    entries = @($dispatchEntries)
}
$queue | ConvertTo-Json -Depth 12 | Set-Content -Path $queuePath -Encoding UTF8

$draftFiles = @(Get-ChildItem -LiteralPath $draftDir -File | ForEach-Object { "production-handoff-dispatch/email-drafts/" + $_.Name } | Sort-Object)
$requiredDraftSnippets = @(
    "AI TestPilot production evidence request",
    "Required files:",
    "Remaining blockers covered by this packet:",
    "Validation commands:",
    "Boundary: fixture contract reports"
)
$draftsContentValidated = $true
foreach ($draftFile in $draftFiles) {
    $draftFullPath = Join-Path $evidenceBundlePath $draftFile.Replace("/", "\")
    $draftText = Get-Content -Path $draftFullPath -Encoding UTF8 -Raw
    foreach ($snippet in $requiredDraftSnippets) {
        if (-not $draftText.Contains($snippet)) {
            $draftsContentValidated = $false
        }
    }

    if ($draftText.Contains("System.Collections") -or $draftText.Contains("@{")) {
        $draftsContentValidated = $false
    }
}

$requiredFileCountMeasure = @($dispatchEntries | ForEach-Object { @(Convert-ToArray (Get-JsonValue $_ "requiredEvidenceFiles" @())).Count } | Measure-Object -Sum)
$requiredFileCount = if ($null -eq $requiredFileCountMeasure.Sum) { 0 } else { [int]$requiredFileCountMeasure.Sum }
$remainingBlockingReasonCount = [int](Get-JsonValue $handoffStatusManifest "remainingBlockingReasonCount" 0)
$pendingDispatchCount = [int]@($dispatchEntries | Where-Object { [string](Get-JsonValue $_ "dispatchStatus" "") -eq "READY_FOR_OWNER_CONTACT" }).Count
$allOwnerPacketsMapped = @($dispatchEntries).Count -eq [int](Get-JsonValue $ownerPacketIndex "ownerPacketCount" -1)
$exportZipAvailable = (Test-Path $exportZipPath) -and [bool](Get-JsonValue $handoffExportManifest "zipGenerated" $false)
$contactPlaceholdersExplicit = @($dispatchEntries | Where-Object {
        [string](Get-JsonValue $_ "recipientPlaceholder" "") -like "replace-with-*-email" -and
        -not [bool](Get-JsonValue $_ "recipientConfigured" $true)
    }).Count -eq @($dispatchEntries).Count
$queueContentValidated = (Test-Path $queuePath) -and
    $queue.status -eq "PASS" -and
    [int]$queue.dispatchEntryCount -eq [int](Get-JsonValue $ownerPacketIndex "ownerPacketCount" -1) -and
    [int]$queue.pendingDispatchCount -eq [int]$queue.dispatchEntryCount -and
    -not [bool]$queue.realOwnerEmailAddressesConfigured -and
    -not [bool]$queue.automaticEmailSendReady

$reportLines = @(
    "# AI TestPilot Production Handoff Dispatch Plan",
    "",
    "Schema: ``aitestpilot.production_handoff_dispatch_plan.v1``",
    "Generated at UTC: $((Get-Date).ToUniversalTime().ToString("O"))",
    "",
    "## Summary",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Owner packets | $($dispatchEntries.Count) |",
    "| Pending dispatches | $pendingDispatchCount |",
    "| Required external evidence files | $requiredFileCount |",
    "| Remaining blocker reasons | $remainingBlockingReasonCount |",
    "| Export zip available | $exportZipAvailable |",
    "| Real owner email addresses configured | False |",
    "| Automatic email send ready | False |",
    "",
    "## Dispatch Queue",
    "",
    "| Owner | Area | Status | Draft | Required evidence | Remaining blockers |",
    "| --- | --- | --- | --- | --- | --- |"
)

foreach ($entry in $dispatchEntries) {
    $owner = Format-MarkdownCell (Get-JsonValue $entry "owner" "")
    $area = Format-MarkdownCell (Get-JsonValue $entry "area" "")
    $statusText = Format-MarkdownCell (Get-JsonValue $entry "dispatchStatus" "")
    $draft = Format-MarkdownCell (Get-JsonValue $entry "draftPath" "")
    $required = Format-MarkdownCell (Join-MarkdownList @(Get-JsonValue $entry "requiredEvidenceFiles" @()))
    $blockers = Format-MarkdownCell (Join-MarkdownList @(Get-JsonValue $entry "remainingBlockingReasons" @()))
    $reportLines += "| $owner | $area | $statusText | $draft | $required | $blockers |"
}

$reportLines += @(
    "",
    "## Boundary",
    "",
    "- This plan prepares owner dispatch drafts and a queue only.",
    "- It does not send email and does not configure real owner addresses.",
    "- Completion still requires returned host-project evidence, acceptance, and hard validation."
)

$reportText = [string]::Join([Environment]::NewLine, $reportLines) + [Environment]::NewLine
New-Item -ItemType Directory -Force (Split-Path $reportFullPath -Parent) | Out-Null
$reportText | Set-Content -Path $reportFullPath -Encoding UTF8

$reportContentValidated = $reportText.Contains("AI TestPilot Production Handoff Dispatch Plan") -and
    $reportText.Contains("READY_FOR_OWNER_CONTACT") -and
    $reportText.Contains("Real owner email addresses configured") -and
    $reportText.Contains("does not send email") -and
    $reportText.Contains("Completion still requires returned host-project evidence") -and
    -not $reportText.Contains("System.Collections") -and
    -not $reportText.Contains("@{")

$checks = @()
Add-DispatchCheck "handoff_sources_available" `
    ($handoffManifest.status -eq "PASS" -and $ownerPacketIndex.status -eq "PASS" -and $handoffExportManifest.status -eq "PASS" -and $handoffStatusManifest.status -eq "PASS" -and $inboxManifest.status -eq "PASS") `
    "Dispatch plan must be based on passing handoff package, export, status, and inbox evidence."
Add-DispatchCheck "dispatch_queue_complete" `
    ($queueContentValidated -and $allOwnerPacketsMapped) `
    "Dispatch queue must map every owner packet exactly once."
Add-DispatchCheck "dispatch_drafts_content" `
    ($draftsContentValidated -and $draftFiles.Count -eq $dispatchEntries.Count) `
    "Each owner must have a concrete email draft with required files, blockers, and validation commands."
Add-DispatchCheck "export_attachment_available" `
    $exportZipAvailable `
    "The owner-facing handoff export zip must be available for dispatch."
Add-DispatchCheck "contact_boundary_preserved" `
    ($contactPlaceholdersExplicit -and -not [bool]$queue.realOwnerEmailAddressesConfigured -and -not [bool]$queue.automaticEmailSendReady) `
    "Dispatch plan must keep missing real owner email addresses explicit and avoid claiming automatic send readiness."
Add-DispatchCheck "fixture_boundary_preserved" `
    (-not [bool](Get-JsonValue $handoffStatusManifest "realHostProjectEvidenceAccepted" $true) -and -not [bool](Get-JsonValue $handoffStatusManifest "fixtureEvidencePromoted" $true)) `
    "Dispatch plan must not promote fixture evidence as real host-project evidence."
Add-DispatchCheck "dispatch_report_content" `
    $reportContentValidated `
    "Dispatch report must summarize queue status, owner drafts, and evidence boundary."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$generatedFiles = @(
    "production-handoff-dispatch-manifest.json",
    "production-handoff-dispatch.md",
    "production-handoff-dispatch/production-handoff-dispatch-queue.json"
) + $draftFiles
$sourceFiles = @(
    "production-handoff-package-manifest.json",
    "production-handoff-package/owner-packets/owner-packet-index.json",
    "production-handoff-export-manifest.json",
    "production-handoff-export.zip",
    "production-handoff-status-manifest.json",
    "production-external-evidence-inbox-manifest.json"
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_dispatch_plan.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    dispatchDir = $dispatchPath
    dispatchQueuePath = $queuePath
    reportPath = $reportFullPath
    ownerPacketCount = [int]$dispatchEntries.Count
    hostProjectActionItemCount = [int](Get-JsonValue $ownerPacketIndex "hostProjectActionItemCount" 0)
    dispatchDraftCount = [int]$draftFiles.Count
    dispatchQueueGenerated = (Test-Path $queuePath)
    dispatchReportGenerated = (Test-Path $reportFullPath)
    dispatchReportContentValidated = [bool]$reportContentValidated
    dispatchDraftsContentValidated = [bool]$draftsContentValidated
    allOwnerPacketsMapped = [bool]$allOwnerPacketsMapped
    exportZipAvailable = [bool]$exportZipAvailable
    contactPlaceholdersExplicit = [bool]$contactPlaceholdersExplicit
    realOwnerEmailAddressesConfigured = $false
    automaticEmailSendReady = $false
    pendingDispatchCount = [int]$pendingDispatchCount
    sentDispatchCount = 0
    pendingExternalEvidenceFileCount = [int]$requiredFileCount
    remainingBlockingReasonCount = [int]$remainingBlockingReasonCount
    externalEvidenceCollectionComplete = [bool](Get-JsonValue $handoffStatusManifest "externalEvidenceCollectionComplete" $false)
    releasePipelineUsesFixture = $false
    realHostProjectEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "host_project_owner_dispatch_plan_only"
    dispatchEntries = @($dispatchEntries)
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
    throw "Production handoff dispatch plan failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production handoff dispatch manifest: $manifestFullPath"
Write-Output "Production handoff dispatch report: $reportFullPath"
Write-Output "PASS AI TestPilot production handoff dispatch plan"
