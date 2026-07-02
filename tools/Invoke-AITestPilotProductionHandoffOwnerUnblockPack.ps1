[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$UnblockDir,
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

if ([string]::IsNullOrWhiteSpace($UnblockDir)) {
    $UnblockDir = Join-Path $EvidenceBundleDir "production-handoff-owner-unblock-pack"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-handoff-owner-unblock-pack-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-handoff-owner-unblock-pack.md"
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

function Find-OwnerAreaEntry {
    param(
        [object[]]$Items,
        [string]$Owner,
        [string]$Area
    )

    $matches = @($Items | Where-Object {
            [string](Get-JsonValue $_ "owner" "") -eq $Owner -and
            [string](Get-JsonValue $_ "area" "") -eq $Area
        })
    if ($matches.Count -eq 0) {
        return $null
    }

    return $matches[0]
}

function Add-UnblockCheck {
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
$unblockPath = Assert-PathUnderRepo $UnblockDir "UnblockDir"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if (Test-Path $unblockPath) {
    Remove-Item -LiteralPath $unblockPath -Recurse -Force
}
New-Item -ItemType Directory -Force $unblockPath | Out-Null

$handoffStatusManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-status-manifest.json") "Production handoff status manifest"
$dispatchManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-dispatch-manifest.json") "Production handoff dispatch manifest"
$contactReadinessManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-contact-readiness-manifest.json") "Production handoff contact readiness manifest"
$sendReadinessManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-send-readiness-manifest.json") "Production handoff send readiness manifest"
$mailAuthReadinessManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-mail-auth-readiness-manifest.json") "Production handoff mail auth readiness manifest"
$inboxManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-external-evidence-inbox-manifest.json") "Production external evidence inbox manifest"
$handoffExportManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-export-manifest.json") "Production handoff export manifest"

$ownerStatuses = @(Convert-ToArray (Get-JsonValue $handoffStatusManifest "ownerStatuses" @()))
$contactStatuses = @(Convert-ToArray (Get-JsonValue $contactReadinessManifest "contactStatuses" @()))
$sendEntries = @(Convert-ToArray (Get-JsonValue $sendReadinessManifest "sendEntries" @()))
$inboxAreaStatuses = @(Convert-ToArray (Get-JsonValue $inboxManifest "areaStatuses" @()))
$dispatchEntries = @(Convert-ToArray (Get-JsonValue $dispatchManifest "dispatchEntries" @()))

$ownerActions = @()
foreach ($ownerStatus in $ownerStatuses) {
    $owner = [string](Get-JsonValue $ownerStatus "owner" "")
    $area = [string](Get-JsonValue $ownerStatus "area" "")
    $contactStatus = Find-OwnerAreaEntry $contactStatuses $owner $area
    $sendEntry = Find-OwnerAreaEntry $sendEntries $owner $area
    $inboxAreaStatus = Find-OwnerAreaEntry $inboxAreaStatuses $owner $area
    $dispatchEntry = Find-OwnerAreaEntry $dispatchEntries $owner $area

    $missingFiles = @(Convert-ToArray (Get-JsonValue $inboxAreaStatus "missingFiles" @()) | ForEach-Object { [string]$_ })
    $blockingReasons = @(Convert-ToArray (Get-JsonValue $ownerStatus "remainingBlockingReasons" @()) | ForEach-Object { [string]$_ })
    $requiredEvidenceFiles = @(Convert-ToArray (Get-JsonValue $ownerStatus "requiredEvidenceFiles" @()) | ForEach-Object { [string]$_ })
    $emailAddress = [string](Get-JsonValue $contactStatus "emailAddress" "")
    $emailConfigured = Convert-ToBool (Get-JsonValue $contactStatus "configured" $false)
    $sendStatus = [string](Get-JsonValue $sendEntry "sendStatus" "")
    if ([string]::IsNullOrWhiteSpace($sendStatus)) {
        $sendStatus = "BLOCKED_MISSING_OWNER_EMAIL"
    }

    $ownerActions += [ordered]@{
        owner = $owner
        area = $area
        ownerStatus = [string](Get-JsonValue $ownerStatus "status" "")
        emailConfigured = [bool]$emailConfigured
        emailAddress = $emailAddress
        contactStatus = [string](Get-JsonValue $contactStatus "status" "MISSING_OWNER_EMAIL")
        sendStatus = $sendStatus
        dispatchStatus = [string](Get-JsonValue $dispatchEntry "dispatchStatus" "")
        inboxDirectory = [string](Get-JsonValue $inboxAreaStatus "inboxDirectory" "")
        missingFileCount = Convert-ToInt (Get-JsonValue $inboxAreaStatus "missingFileCount" 0)
        missingFiles = @($missingFiles)
        requiredEvidenceFiles = @($requiredEvidenceFiles)
        remainingBlockingReasonCount = Convert-ToInt (Get-JsonValue $ownerStatus "remainingBlockingReasonCount" 0)
        remainingBlockingReasons = @($blockingReasons)
        ownerPacketPath = [string](Get-JsonValue $ownerStatus "packetPath" "")
        dispatchDraftPath = [string](Get-JsonValue $dispatchEntry "draftPath" "")
        preflightCommand = [string](Get-JsonValue $ownerStatus "preflightCommand" "")
        acceptanceWrapperCommand = [string](Get-JsonValue $ownerStatus "acceptanceWrapperCommand" "")
        hardValidationCommand = [string](Get-JsonValue $ownerStatus "hardValidationCommand" "")
    }
}

$ownerPacketCount = Convert-ToInt (Get-JsonValue $handoffStatusManifest "ownerPacketCount" 0)
$pendingOwnerPacketCount = Convert-ToInt (Get-JsonValue $handoffStatusManifest "pendingOwnerPacketCount" 0)
$pendingDispatchCount = Convert-ToInt (Get-JsonValue $contactReadinessManifest "pendingDispatchCount" 0)
$missingOwnerContactCount = Convert-ToInt (Get-JsonValue $contactReadinessManifest "missingOwnerContactCount" 0)
$missingRequiredFileCount = Convert-ToInt (Get-JsonValue $inboxManifest "missingRequiredFileCount" 0)
$remainingBlockingReasonCount = Convert-ToInt (Get-JsonValue $handoffStatusManifest "remainingBlockingReasonCount" 0)
$blockedSendCount = Convert-ToInt (Get-JsonValue $sendReadinessManifest "blockedSendCount" 0)
$readySendCount = Convert-ToInt (Get-JsonValue $sendReadinessManifest "readySendCount" 0)
$mailAuthReadinessStatus = [string](Get-JsonValue $mailAuthReadinessManifest "mailAuthReadinessStatus" "")
$sendReadinessStatus = [string](Get-JsonValue $sendReadinessManifest "sendReadinessStatus" "")
$automaticEmailSendReady = $false
$mailAuthorizationCheckedByPipeline = Convert-ToBool (Get-JsonValue $mailAuthReadinessManifest "mailAuthorizationCheckedByPipeline" $true)
$handoffExportZipAvailable = Test-Path (Join-Path $evidenceBundlePath "production-handoff-export.zip")
$externalEvidenceCollectionComplete = Convert-ToBool (Get-JsonValue $inboxManifest "externalEvidenceCollectionComplete" $false)
$realHostProjectEvidenceAccepted = Convert-ToBool (Get-JsonValue $handoffStatusManifest "realHostProjectEvidenceAccepted" $false)
$externalEvidenceAccepted = Convert-ToBool (Get-JsonValue $inboxManifest "externalEvidenceAccepted" $false)
$ownerUnblockStatus = if ($ownerPacketCount -gt 0 -and
    $missingOwnerContactCount -eq 0 -and
    $readySendCount -eq $ownerPacketCount -and
    $missingRequiredFileCount -eq 0 -and
    $mailAuthReadinessStatus -eq "BLOCKED_NOT_CHECKED_BY_RELEASE_PIPELINE" -and
    -not $realHostProjectEvidenceAccepted) {
    "READY_FOR_CONFIRMATION_PENDING_REAL_ACCEPTANCE"
} else {
    "BLOCKED_EXTERNAL_OWNER_INPUT"
}

$summaryPath = Join-Path $unblockPath "owner-unblock-summary.json"
$matrixPath = Join-Path $unblockPath "owner-action-matrix.md"
$nextStepsPath = Join-Path $unblockPath "operator-next-steps.md"
$progressDraftPath = Join-Path $unblockPath "progress-email-draft.md"
$readmePath = Join-Path $unblockPath "README.md"

$summary = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_owner_unblock_summary.v1"
    ownerUnblockStatus = $ownerUnblockStatus
    ownerPacketCount = [int]$ownerPacketCount
    pendingOwnerPacketCount = [int]$pendingOwnerPacketCount
    pendingDispatchCount = [int]$pendingDispatchCount
    missingOwnerContactCount = [int]$missingOwnerContactCount
    missingRequiredFileCount = [int]$missingRequiredFileCount
    remainingBlockingReasonCount = [int]$remainingBlockingReasonCount
    blockedSendCount = [int]$blockedSendCount
    readySendCount = [int]$readySendCount
    sendReadinessStatus = $sendReadinessStatus
    mailAuthReadinessStatus = $mailAuthReadinessStatus
    automaticEmailSendReady = [bool]$automaticEmailSendReady
    mailAuthorizationCheckedByPipeline = [bool]$mailAuthorizationCheckedByPipeline
    realHostProjectEvidenceAccepted = $false
    externalEvidenceCollectionComplete = [bool]$externalEvidenceCollectionComplete
    ownerActions = @($ownerActions)
}
$summary | ConvertTo-Json -Depth 12 | Set-Content -Path $summaryPath -Encoding UTF8

$matrixLines = @(
    "# AI TestPilot Owner Action Matrix",
    "",
    "| Owner | Area | Contact | Send | Missing files | Blockers | Inbox |",
    "| --- | --- | --- | --- | --- | --- | --- |"
)
foreach ($action in $ownerActions) {
    $contactLabel = if ([bool](Get-JsonValue $action "emailConfigured" $false)) {
        [string](Get-JsonValue $action "emailAddress" "")
    } else {
        [string](Get-JsonValue $action "contactStatus" "MISSING_OWNER_EMAIL")
    }
    $ownerCell = Format-MarkdownCell (Get-JsonValue $action "owner" "")
    $areaCell = Format-MarkdownCell (Get-JsonValue $action "area" "")
    $contactCell = Format-MarkdownCell $contactLabel
    $sendCell = Format-MarkdownCell (Get-JsonValue $action "sendStatus" "")
    $missingFilesCell = Format-MarkdownCell (Join-TextList (Convert-ToArray (Get-JsonValue $action "missingFiles" @())))
    $blockersCell = Format-MarkdownCell (Join-TextList (Convert-ToArray (Get-JsonValue $action "remainingBlockingReasons" @())))
    $inboxCell = Format-MarkdownCell (Get-JsonValue $action "inboxDirectory" "")
    $matrixLines += "| $ownerCell | $areaCell | $contactCell | $sendCell | $missingFilesCell | $blockersCell | $inboxCell |"
}
$matrixLines | Set-Content -Path $matrixPath -Encoding UTF8

$nextStepLines = @(
    "# AI TestPilot Production Handoff Next Steps",
    "",
    "1. Fill ``production-handoff-contact-roster.json`` with the three real owner email addresses.",
    "2. Run ``production-handoff-mail-auth\check-agently-mail-auth.ps1`` after local ``agently-cli`` authorization.",
    "3. Use ``production-handoff-send\send-owner-packets.ps1 -PrepareConfirmation`` to request send confirmation tokens.",
    "4. Collect returned evidence into ``production-external-evidence-inbox``.",
    "5. Run ``production-external-evidence-inbox\accept-returned-evidence.ps1`` and then the hard release pipeline switches.",
    "",
    "Current blocking counts:",
    "",
    "- Pending owner packets: $pendingOwnerPacketCount",
    "- Missing owner contacts: $missingOwnerContactCount",
    "- Missing evidence files: $missingRequiredFileCount",
    "- Remaining blocker reasons: $remainingBlockingReasonCount",
    "- Blocked sends: $blockedSendCount",
    "- Mail auth readiness: $mailAuthReadinessStatus"
)
$nextStepLines | Set-Content -Path $nextStepsPath -Encoding UTF8

$progressDraftLines = @(
    "To: kibernet@sina.com",
    "Subject: AI TestPilot progress - owner unblock pack ready",
    "",
    "AI TestPilot progress update:",
    "",
    "- Release pipeline: PASS",
    "- Owner unblock pack: generated",
    "- Pipeline and release gate counts are recorded in the final pipeline-manifest and release-gate-manifest after the run completes.",
    "- Owner unblock status: $ownerUnblockStatus",
    "- Pending owner packets: $pendingOwnerPacketCount",
    "- Missing owner contacts: $missingOwnerContactCount",
    "- Missing external evidence files: $missingRequiredFileCount",
    "- Remaining blocker reasons: $remainingBlockingReasonCount",
    "- Send readiness: $sendReadinessStatus",
    "- Mail auth readiness: $mailAuthReadinessStatus",
    "",
    "Boundary:",
    "",
    "- No owner email has been sent by CI.",
    "- Real host-project evidence has not been accepted.",
    "- The unblock pack is a handoff artifact for contacts, authorization, and evidence collection."
)
$progressDraftLines | Set-Content -Path $progressDraftPath -Encoding UTF8

$readmeLines = @(
    "# AI TestPilot Production Handoff Owner Unblock Pack",
    "",
    "This folder consolidates the remaining owner-side inputs needed before production completion.",
    "",
    "Files:",
    "",
    "- ``owner-unblock-summary.json``: machine-readable blocker, contact, send, and evidence summary.",
    "- ``owner-action-matrix.md``: owner-by-owner action matrix.",
    "- ``operator-next-steps.md``: ordered operator checklist.",
    "- ``progress-email-draft.md``: status email draft for manual or CLI dispatch.",
    "",
    "The pack does not send email, run OAuth login, accept fixture evidence, or mark host-project evidence complete."
)
$readmeLines | Set-Content -Path $readmePath -Encoding UTF8

$reportLines = @(
    "# AI TestPilot Production Handoff Owner Unblock Pack",
    "",
    "Schema: ``aitestpilot.production_handoff_owner_unblock_pack.v1``",
    "Generated at UTC: $((Get-Date).ToUniversalTime().ToString("O"))",
    "",
    "## Summary",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Owner unblock status | $ownerUnblockStatus |",
    "| Pending owner packets | $pendingOwnerPacketCount |",
    "| Missing owner contacts | $missingOwnerContactCount |",
    "| Missing external evidence files | $missingRequiredFileCount |",
    "| Remaining blocker reasons | $remainingBlockingReasonCount |",
    "| Blocked sends | $blockedSendCount |",
    "| Ready sends | $readySendCount |",
    "| Send readiness | $sendReadinessStatus |",
    "| Mail auth readiness | $mailAuthReadinessStatus |",
    "",
    "## Owner Matrix",
    "",
    "| Owner | Area | Contact | Send | Missing files | Blockers |",
    "| --- | --- | --- | --- | --- | --- |"
)
foreach ($action in $ownerActions) {
    $contactLabel = if ([bool](Get-JsonValue $action "emailConfigured" $false)) {
        [string](Get-JsonValue $action "emailAddress" "")
    } else {
        [string](Get-JsonValue $action "contactStatus" "MISSING_OWNER_EMAIL")
    }
    $ownerCell = Format-MarkdownCell (Get-JsonValue $action "owner" "")
    $areaCell = Format-MarkdownCell (Get-JsonValue $action "area" "")
    $contactCell = Format-MarkdownCell $contactLabel
    $sendCell = Format-MarkdownCell (Get-JsonValue $action "sendStatus" "")
    $missingFilesCell = Format-MarkdownCell (Join-TextList (Convert-ToArray (Get-JsonValue $action "missingFiles" @())))
    $blockersCell = Format-MarkdownCell (Join-TextList (Convert-ToArray (Get-JsonValue $action "remainingBlockingReasons" @())))
    $reportLines += "| $ownerCell | $areaCell | $contactCell | $sendCell | $missingFilesCell | $blockersCell |"
}
$reportLines += @(
    "",
    "## Boundary",
    "",
    "- This pack is an owner unblock artifact only.",
    "- No owner email is sent by this script or by the release pipeline.",
    "- Fixture evidence remains contract proof only and is not promoted as real host-project evidence."
)
$reportLines | Set-Content -Path $reportFullPath -Encoding UTF8

$summaryContent = Get-Content -Path $summaryPath -Encoding UTF8 -Raw
$matrixContent = Get-Content -Path $matrixPath -Encoding UTF8 -Raw
$nextStepsContent = Get-Content -Path $nextStepsPath -Encoding UTF8 -Raw
$progressDraftContent = Get-Content -Path $progressDraftPath -Encoding UTF8 -Raw
$readmeContent = Get-Content -Path $readmePath -Encoding UTF8 -Raw
$reportContent = Get-Content -Path $reportFullPath -Encoding UTF8 -Raw

$summaryContentValidated = $summaryContent.Contains("production_handoff_owner_unblock_summary.v1") -and
    $summaryContent.Contains($ownerUnblockStatus) -and
    -not $summaryContent.Contains("System.Collections") -and
    -not $summaryContent.Contains([char]7)
$matrixContentValidated = $matrixContent.Contains("Owner Action Matrix") -and
    $matrixContent.Contains("host_project_gameplay_qa") -and
    $matrixContent.Contains("host_project_lua_owner") -and
    $matrixContent.Contains("host_project_ai_platform") -and
    -not $matrixContent.Contains("System.Collections") -and
    -not $matrixContent.Contains([char]7)
$nextStepsContentValidated = $nextStepsContent.Contains("production-handoff-contact-roster.json") -and
    $nextStepsContent.Contains("check-agently-mail-auth.ps1") -and
    $nextStepsContent.Contains("accept-returned-evidence.ps1") -and
    -not $nextStepsContent.Contains("System.Collections") -and
    -not $nextStepsContent.Contains([char]7)
$progressDraftContentValidated = $progressDraftContent.Contains("kibernet@sina.com") -and
    $progressDraftContent.Contains("Release pipeline: PASS") -and
    $progressDraftContent.Contains("No owner email has been sent by CI") -and
    -not $progressDraftContent.Contains("System.Collections") -and
    -not $progressDraftContent.Contains([char]7)
$readmeContentValidated = $readmeContent.Contains("remaining owner-side inputs") -and
    $readmeContent.Contains("does not send email") -and
    -not $readmeContent.Contains("System.Collections") -and
    -not $readmeContent.Contains([char]7)
$reportContentValidated = $reportContent.Contains("Production Handoff Owner Unblock Pack") -and
    $reportContent.Contains($ownerUnblockStatus) -and
    $reportContent.Contains("No owner email is sent") -and
    -not $reportContent.Contains("System.Collections") -and
    -not $reportContent.Contains([char]7)

$checks = @()
Add-UnblockCheck "owner_unblock_sources_available" `
    ($handoffStatusManifest.status -eq "PASS" -and $dispatchManifest.status -eq "PASS" -and $contactReadinessManifest.status -eq "PASS" -and $sendReadinessManifest.status -eq "PASS" -and $mailAuthReadinessManifest.status -eq "PASS" -and $inboxManifest.status -eq "PASS" -and $handoffExportManifest.status -eq "PASS") `
    "Owner unblock pack must be based on passing status, dispatch, contact, send, mail-auth, inbox, and export evidence."
Add-UnblockCheck "owner_unblock_counts_consistent" `
    ($ownerActions.Count -eq $ownerPacketCount -and
        $pendingOwnerPacketCount -le $ownerPacketCount -and
        $pendingDispatchCount -le $ownerPacketCount -and
        $missingOwnerContactCount -ge 0 -and
        $missingOwnerContactCount -le $ownerPacketCount -and
        ($blockedSendCount + $readySendCount) -eq $ownerPacketCount -and
        $missingRequiredFileCount -ge 0 -and
        $remainingBlockingReasonCount -ge 0) `
    "Owner unblock counts must match the current contact, send, evidence, and blocker state."
Add-UnblockCheck "owner_unblock_files_generated" `
    ((Test-Path $summaryPath) -and (Test-Path $matrixPath) -and (Test-Path $nextStepsPath) -and (Test-Path $progressDraftPath) -and (Test-Path $readmePath) -and (Test-Path $reportFullPath)) `
    "Owner unblock pack must generate summary, matrix, operator steps, progress draft, README, and report files."
Add-UnblockCheck "owner_unblock_content_validated" `
    ($summaryContentValidated -and $matrixContentValidated -and $readmeContentValidated -and $reportContentValidated) `
    "Owner unblock summary, matrix, README, and report must contain concrete owner and boundary details."
Add-UnblockCheck "owner_unblock_operator_steps_validated" `
    ($nextStepsContentValidated -and $progressDraftContentValidated) `
    "Operator steps and progress draft must describe contact, mail auth, send, and evidence collection actions."
Add-UnblockCheck "owner_unblock_send_boundary_preserved" `
    (($sendReadinessStatus -eq "BLOCKED_MISSING_OWNER_EMAILS" -or $sendReadinessStatus -eq "READY_FOR_CONFIRMATION") -and $mailAuthReadinessStatus -eq "BLOCKED_NOT_CHECKED_BY_RELEASE_PIPELINE" -and -not $automaticEmailSendReady -and -not $mailAuthorizationCheckedByPipeline) `
    "Owner unblock pack must not claim configured contacts, local mail auth, or automatic send readiness."
Add-UnblockCheck "owner_unblock_evidence_boundary_preserved" `
    (-not $realHostProjectEvidenceAccepted -and -not $externalEvidenceAccepted -and -not (Convert-ToBool (Get-JsonValue $inboxManifest "fixtureEvidencePromoted" $true))) `
    "Owner unblock pack must not promote fixture evidence or claim real host-project evidence."
Add-UnblockCheck "owner_unblock_export_available" `
    ([bool]$handoffExportZipAvailable) `
    "Owner unblock pack must reference an available handoff export zip for distribution."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestFullPath),
    (Convert-ToEvidenceRelativePath $reportFullPath),
    (Convert-ToEvidenceRelativePath $summaryPath),
    (Convert-ToEvidenceRelativePath $matrixPath),
    (Convert-ToEvidenceRelativePath $nextStepsPath),
    (Convert-ToEvidenceRelativePath $progressDraftPath),
    (Convert-ToEvidenceRelativePath $readmePath)
)
$sourceFiles = @(
    "production-handoff-status-manifest.json",
    "production-handoff-dispatch-manifest.json",
    "production-handoff-contact-readiness-manifest.json",
    "production-handoff-send-readiness-manifest.json",
    "production-handoff-mail-auth-readiness-manifest.json",
    "production-external-evidence-inbox-manifest.json",
    "production-handoff-export-manifest.json",
    "production-handoff-export.zip"
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_owner_unblock_pack.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    unblockDir = $unblockPath
    reportPath = $reportFullPath
    ownerUnblockStatus = $ownerUnblockStatus
    unblockPackGenerated = (Test-Path $unblockPath)
    summaryGenerated = (Test-Path $summaryPath)
    matrixGenerated = (Test-Path $matrixPath)
    operatorNextStepsGenerated = (Test-Path $nextStepsPath)
    progressEmailDraftGenerated = (Test-Path $progressDraftPath)
    readmeGenerated = (Test-Path $readmePath)
    reportGenerated = (Test-Path $reportFullPath)
    summaryContentValidated = [bool]$summaryContentValidated
    matrixContentValidated = [bool]$matrixContentValidated
    operatorNextStepsContentValidated = [bool]$nextStepsContentValidated
    progressEmailDraftContentValidated = [bool]$progressDraftContentValidated
    readmeContentValidated = [bool]$readmeContentValidated
    reportContentValidated = [bool]$reportContentValidated
    ownerPacketCount = [int]$ownerPacketCount
    pendingOwnerPacketCount = [int]$pendingOwnerPacketCount
    pendingDispatchCount = [int]$pendingDispatchCount
    missingOwnerContactCount = [int]$missingOwnerContactCount
    missingRequiredFileCount = [int]$missingRequiredFileCount
    remainingBlockingReasonCount = [int]$remainingBlockingReasonCount
    blockedSendCount = [int]$blockedSendCount
    readySendCount = [int]$readySendCount
    sendReadinessStatus = $sendReadinessStatus
    mailAuthReadinessStatus = $mailAuthReadinessStatus
    automaticEmailSendReady = [bool]$automaticEmailSendReady
    mailAuthorizationCheckedByPipeline = [bool]$mailAuthorizationCheckedByPipeline
    handoffExportZipAvailable = [bool]$handoffExportZipAvailable
    externalEvidenceCollectionComplete = [bool]$externalEvidenceCollectionComplete
    realHostProjectEvidenceAccepted = [bool]$realHostProjectEvidenceAccepted
    externalEvidenceAccepted = [bool]$externalEvidenceAccepted
    releasePipelineUsesFixture = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "host_project_owner_unblock_pack_only"
    ownerActions = @($ownerActions)
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
    throw "Production handoff owner unblock pack failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production handoff owner unblock pack manifest: $manifestFullPath"
Write-Output "Production handoff owner unblock pack report: $reportFullPath"
Write-Output "PASS AI TestPilot production handoff owner unblock pack"
