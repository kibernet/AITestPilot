[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$RequestDir,
    [string]$ManifestPath,
    [string]$ReportPath,
    [string]$ProgressRecipient = "kibernet@sina.com"
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

if ([string]::IsNullOrWhiteSpace($RequestDir)) {
    $RequestDir = Join-Path $EvidenceBundleDir "production-handoff-owner-input-request-pack"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-handoff-owner-input-request-pack-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-handoff-owner-input-request-pack.md"
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

function Add-RequestCheck {
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
$requestPath = Assert-PathUnderRepo $RequestDir "RequestDir"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if (Test-Path $requestPath) {
    Remove-Item -LiteralPath $requestPath -Recurse -Force
}
New-Item -ItemType Directory -Force $requestPath | Out-Null

$ownerUnblockManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-owner-unblock-pack-manifest.json") "Production handoff owner unblock pack manifest"
$handoffStatusManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-status-manifest.json") "Production handoff status manifest"
$dispatchManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-dispatch-manifest.json") "Production handoff dispatch manifest"
$contactReadinessManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-contact-readiness-manifest.json") "Production handoff contact readiness manifest"
$sendReadinessManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-send-readiness-manifest.json") "Production handoff send readiness manifest"
$mailAuthReadinessManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-mail-auth-readiness-manifest.json") "Production handoff mail auth readiness manifest"
$inboxManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-external-evidence-inbox-manifest.json") "Production external evidence inbox manifest"
$handoffExportManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-export-manifest.json") "Production handoff export manifest"

$ownerActions = @(Convert-ToArray (Get-JsonValue $ownerUnblockManifest "ownerActions" @()))
$ownerUnblockStatus = [string](Get-JsonValue $ownerUnblockManifest "ownerUnblockStatus" "")
$ownerInputRequestStatus = if ($ownerUnblockStatus -eq "BLOCKED_EXTERNAL_OWNER_INPUT") {
    "AWAITING_EXTERNAL_OWNER_INPUT"
}
elseif ($ownerUnblockStatus -eq "READY_FOR_CONFIRMATION_PENDING_REAL_ACCEPTANCE") {
    "READY_FOR_CONFIRMATION_PENDING_REAL_ACCEPTANCE"
}
else {
    "UNKNOWN_OWNER_INPUT_STATE"
}

$ownerPacketCount = Convert-ToInt (Get-JsonValue $ownerUnblockManifest "ownerPacketCount" 0)
$ownerActionCount = [int]$ownerActions.Count
$pendingOwnerPacketCount = Convert-ToInt (Get-JsonValue $ownerUnblockManifest "pendingOwnerPacketCount" 0)
$pendingDispatchCount = Convert-ToInt (Get-JsonValue $ownerUnblockManifest "pendingDispatchCount" 0)
$missingOwnerContactCount = Convert-ToInt (Get-JsonValue $ownerUnblockManifest "missingOwnerContactCount" 0)
$missingRequiredFileCount = Convert-ToInt (Get-JsonValue $ownerUnblockManifest "missingRequiredFileCount" 0)
$remainingBlockingReasonCount = Convert-ToInt (Get-JsonValue $ownerUnblockManifest "remainingBlockingReasonCount" 0)
$blockedSendCount = Convert-ToInt (Get-JsonValue $ownerUnblockManifest "blockedSendCount" 0)
$readySendCount = Convert-ToInt (Get-JsonValue $ownerUnblockManifest "readySendCount" 0)
$sendReadinessStatus = [string](Get-JsonValue $ownerUnblockManifest "sendReadinessStatus" "")
$mailAuthReadinessStatus = [string](Get-JsonValue $ownerUnblockManifest "mailAuthReadinessStatus" "")
$contactRosterPath = [string](Get-JsonValue $contactReadinessManifest "contactRosterPath" "")
$authCheckScriptPath = [string](Get-JsonValue $mailAuthReadinessManifest "authCheckScriptPath" "")
$inboxAcceptanceCommand = [string](Get-JsonValue $inboxManifest "acceptanceCommand" "")
$handoffExportZipAvailable = Convert-ToBool (Get-JsonValue $ownerUnblockManifest "handoffExportZipAvailable" $false)
$externalEvidenceCollectionComplete = Convert-ToBool (Get-JsonValue $ownerUnblockManifest "externalEvidenceCollectionComplete" $false)
$realHostProjectEvidenceAccepted = Convert-ToBool (Get-JsonValue $ownerUnblockManifest "realHostProjectEvidenceAccepted" $false)
$externalEvidenceAccepted = Convert-ToBool (Get-JsonValue $ownerUnblockManifest "externalEvidenceAccepted" $false)
$ownerResponseBundleTemplatePath = "production-handoff-owner-response-bundle-kit/owner-response-bundle-template"
$ownerResponseBundleStatusCommand = ".\tools\Invoke-AITestPilotProductionExternalEvidenceOwnerReturnBundleStatus.ps1 -OwnerResponseBundleDir `"path\to\filled-owner-response-bundle`""
$ownerResponseBundleZipStatusCommand = ".\tools\Invoke-AITestPilotProductionExternalEvidenceOwnerReturnBundleStatus.ps1 -OwnerResponseBundleZipPath `"path\to\filled-owner-response-bundle.zip`""
$ownerResponseBundleAutoAcceptanceCommand = ".\tools\Invoke-AITestPilotProductionExternalEvidenceAutoAcceptance.ps1 -OwnerResponseBundleDir `"path\to\filled-owner-response-bundle`" -RequireAllEvidence"
$ownerResponseBundleZipAutoAcceptanceCommand = ".\tools\Invoke-AITestPilotProductionExternalEvidenceAutoAcceptance.ps1 -OwnerResponseBundleZipPath `"path\to\filled-owner-response-bundle.zip`" -RequireAllEvidence"
$ownerResponseBundleSemanticPreflightCommand = ".\tools\Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1 -OwnerResponseBundleDir `"path\to\filled-owner-response-bundle`""
$ownerResponseBundleZipSemanticPreflightCommand = ".\tools\Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1 -OwnerResponseBundleZipPath `"path\to\filled-owner-response-bundle.zip`""
$ownerResponseBundleZipEnvironmentVariable = "AITESTPILOT_OWNER_RESPONSE_BUNDLE_ZIP_PATH"
$directoryByArea = @{
    production_driver_binding = "production-driver-evidence"
    production_lua_patch_evidence = "production-lua-evidence"
    live_model_endpoint_smoke = "live-smoke-evidence"
}
$exportHelperCommandByArea = @{
    production_driver_binding = ".\production-driver-binding-kit\Export-ProductionDriverEvidenceBundle.ps1 -EvidenceBundleDir `"path\to\release-evidence`""
    production_lua_patch_evidence = ".\production-lua-patch-evidence-kit\Export-ProductionLuaPatchEvidenceBundle.ps1 -EvidenceBundleDir `"path\to\release-evidence`" -ProductionLuaEvidenceDir `"path\to\production-lua-evidence`""
    live_model_endpoint_smoke = ".\live-model-endpoint-config-kit\Export-LiveModelEndpointSmokeEvidenceBundle.ps1 -EvidenceBundleDir `"path\to\release-evidence`" -LiveModelEndpointSmokeEvidenceDir `"path\to\live-smoke-evidence`""
}

$summaryPath = Join-Path $requestPath "owner-input-summary.json"
$contactRosterTemplatePath = Join-Path $requestPath "owner-contact-roster-template.json"
$ownerInputChecklistPath = Join-Path $requestPath "owner-input-checklist.md"
$externalEvidenceReturnChecklistPath = Join-Path $requestPath "external-evidence-return-checklist.md"
$operatorRequestEmailDraftPath = Join-Path $requestPath "operator-request-email-draft.md"
$readmePath = Join-Path $requestPath "README.md"

$ownerInputItems = @()
foreach ($action in $ownerActions) {
    $area = [string](Get-JsonValue $action "area" "")
    $inboxDirectory = [string](Get-JsonValue $action "inboxDirectory" "")
    if ([string]::IsNullOrWhiteSpace($inboxDirectory) -and $directoryByArea.ContainsKey($area)) {
        $inboxDirectory = [string]$directoryByArea[$area]
    }

    $ownerResponseBundleAreaPath = if ([string]::IsNullOrWhiteSpace($inboxDirectory)) {
        ""
    }
    else {
        "$ownerResponseBundleTemplatePath/$inboxDirectory"
    }
    $ownerResponseBundleRequiredFilesPath = if ([string]::IsNullOrWhiteSpace($ownerResponseBundleAreaPath)) {
        ""
    }
    else {
        "$ownerResponseBundleAreaPath/required-files.json"
    }
    $exportHelperCommand = if ($exportHelperCommandByArea.ContainsKey($area)) {
        [string]$exportHelperCommandByArea[$area]
    }
    else {
        ""
    }

    $missingFiles = @(Convert-ToArray (Get-JsonValue $action "missingFiles" @()) | ForEach-Object { [string]$_ })
    $requiredEvidenceFiles = @(Convert-ToArray (Get-JsonValue $action "requiredEvidenceFiles" @()) | ForEach-Object { [string]$_ })
    $remainingBlockingReasons = @(Convert-ToArray (Get-JsonValue $action "remainingBlockingReasons" @()) | ForEach-Object { [string]$_ })
    $ownerInputItems += [ordered]@{
        owner = [string](Get-JsonValue $action "owner" "")
        area = $area
        ownerStatus = [string](Get-JsonValue $action "ownerStatus" "")
        contactStatus = [string](Get-JsonValue $action "contactStatus" "")
        sendStatus = [string](Get-JsonValue $action "sendStatus" "")
        dispatchStatus = [string](Get-JsonValue $action "dispatchStatus" "")
        emailConfigured = Convert-ToBool (Get-JsonValue $action "emailConfigured" $false)
        emailAddress = [string](Get-JsonValue $action "emailAddress" "")
        missingFileCount = Convert-ToInt (Get-JsonValue $action "missingFileCount" 0)
        missingFiles = @($missingFiles)
        requiredEvidenceFiles = @($requiredEvidenceFiles)
        remainingBlockingReasonCount = Convert-ToInt (Get-JsonValue $action "remainingBlockingReasonCount" 0)
        remainingBlockingReasons = @($remainingBlockingReasons)
        inboxDirectory = $inboxDirectory
        ownerPacketPath = [string](Get-JsonValue $action "ownerPacketPath" "")
        dispatchDraftPath = [string](Get-JsonValue $action "dispatchDraftPath" "")
        preflightCommand = [string](Get-JsonValue $action "preflightCommand" "")
        acceptanceWrapperCommand = [string](Get-JsonValue $action "acceptanceWrapperCommand" "")
        hardValidationCommand = [string](Get-JsonValue $action "hardValidationCommand" "")
        ownerResponseBundleTemplatePath = $ownerResponseBundleTemplatePath
        ownerResponseBundleAreaPath = $ownerResponseBundleAreaPath
        ownerResponseBundleRequiredFilesPath = $ownerResponseBundleRequiredFilesPath
        ownerResponseBundleStatusCommand = $ownerResponseBundleStatusCommand
        ownerResponseBundleZipStatusCommand = $ownerResponseBundleZipStatusCommand
        ownerResponseBundleSemanticPreflightCommand = $ownerResponseBundleSemanticPreflightCommand
        ownerResponseBundleZipSemanticPreflightCommand = $ownerResponseBundleZipSemanticPreflightCommand
        ownerResponseBundleAutoAcceptanceCommand = $ownerResponseBundleAutoAcceptanceCommand
        ownerResponseBundleZipAutoAcceptanceCommand = $ownerResponseBundleZipAutoAcceptanceCommand
        ownerResponseBundleZipEnvironmentVariable = $ownerResponseBundleZipEnvironmentVariable
        exportHelperCommand = $exportHelperCommand
    }
}

$ownerResponseBundleRouteCount = @($ownerInputItems | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string](Get-JsonValue $_ "ownerResponseBundleAreaPath" "")) -and
        -not [string]::IsNullOrWhiteSpace([string](Get-JsonValue $_ "ownerResponseBundleRequiredFilesPath" ""))
    }).Count
$ownerResponseBundleAreaPathCount = @($ownerInputItems | Where-Object { -not [string]::IsNullOrWhiteSpace([string](Get-JsonValue $_ "ownerResponseBundleAreaPath" "")) }).Count
$ownerResponseBundleRequiredFilesPathCount = @($ownerInputItems | Where-Object { -not [string]::IsNullOrWhiteSpace([string](Get-JsonValue $_ "ownerResponseBundleRequiredFilesPath" "")) }).Count
$ownerResponseBundleZipStatusCommandCount = @($ownerInputItems | Where-Object { ([string](Get-JsonValue $_ "ownerResponseBundleZipStatusCommand" "")).Contains("-OwnerResponseBundleZipPath") }).Count
$ownerResponseBundleZipSemanticPreflightCommandCount = @($ownerInputItems | Where-Object { ([string](Get-JsonValue $_ "ownerResponseBundleZipSemanticPreflightCommand" "")).Contains("-OwnerResponseBundleZipPath") }).Count
$ownerResponseBundleZipAutoAcceptanceCommandCount = @($ownerInputItems | Where-Object { ([string](Get-JsonValue $_ "ownerResponseBundleZipAutoAcceptanceCommand" "")).Contains("-OwnerResponseBundleZipPath") }).Count
$ownerResponseBundleExportHelperCommandCount = @($ownerInputItems | Where-Object { -not [string]::IsNullOrWhiteSpace([string](Get-JsonValue $_ "exportHelperCommand" "")) }).Count

$contactRosterTemplate = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_owner_contact_roster_request.v1"
    status = "PENDING_OWNER_EMAILS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    sourceContactRosterPath = $contactRosterPath
    ownerContactCount = [int]$ownerActionCount
    configuredContactCount = 0
    entries = @($ownerInputItems | ForEach-Object {
            [ordered]@{
                owner = [string](Get-JsonValue $_ "owner" "")
                area = [string](Get-JsonValue $_ "area" "")
                contactSlug = [string](Get-JsonValue $_ "owner" "")
                emailAddress = ""
                configured = $false
                notes = "Fill with the real owner mailbox before dispatch. Copy the completed entries to production-handoff-contact-roster.json."
            }
        })
}
$contactRosterTemplate | ConvertTo-Json -Depth 8 | Set-Content -Path $contactRosterTemplatePath -Encoding UTF8

$summary = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_owner_input_request_summary.v1"
    ownerInputRequestStatus = $ownerInputRequestStatus
    ownerUnblockStatus = $ownerUnblockStatus
    operatorProgressRecipient = $ProgressRecipient
    ownerPacketCount = [int]$ownerPacketCount
    ownerActionCount = [int]$ownerActionCount
    pendingOwnerPacketCount = [int]$pendingOwnerPacketCount
    pendingDispatchCount = [int]$pendingDispatchCount
    missingOwnerContactCount = [int]$missingOwnerContactCount
    missingRequiredFileCount = [int]$missingRequiredFileCount
    remainingBlockingReasonCount = [int]$remainingBlockingReasonCount
    blockedSendCount = [int]$blockedSendCount
    readySendCount = [int]$readySendCount
    sendReadinessStatus = $sendReadinessStatus
    mailAuthReadinessStatus = $mailAuthReadinessStatus
    automaticEmailSendReady = $false
    mailAuthorizationCheckedByPipeline = $false
    releasePipelineUsesFixture = $false
    realHostProjectEvidenceAccepted = $false
    externalEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    sourceContactRosterPath = $contactRosterPath
    authCheckScriptPath = $authCheckScriptPath
    inboxAcceptanceCommand = $inboxAcceptanceCommand
    ownerResponseBundleRouteCount = [int]$ownerResponseBundleRouteCount
    ownerResponseBundleAreaPathCount = [int]$ownerResponseBundleAreaPathCount
    ownerResponseBundleRequiredFilesPathCount = [int]$ownerResponseBundleRequiredFilesPathCount
    ownerResponseBundleZipStatusCommandCount = [int]$ownerResponseBundleZipStatusCommandCount
    ownerResponseBundleZipSemanticPreflightCommandCount = [int]$ownerResponseBundleZipSemanticPreflightCommandCount
    ownerResponseBundleZipAutoAcceptanceCommandCount = [int]$ownerResponseBundleZipAutoAcceptanceCommandCount
    ownerResponseBundleExportHelperCommandCount = [int]$ownerResponseBundleExportHelperCommandCount
    ownerResponseBundleStatusCommand = $ownerResponseBundleStatusCommand
    ownerResponseBundleZipStatusCommand = $ownerResponseBundleZipStatusCommand
    ownerResponseBundleSemanticPreflightCommand = $ownerResponseBundleSemanticPreflightCommand
    ownerResponseBundleZipSemanticPreflightCommand = $ownerResponseBundleZipSemanticPreflightCommand
    ownerResponseBundleAutoAcceptanceCommand = $ownerResponseBundleAutoAcceptanceCommand
    ownerResponseBundleZipAutoAcceptanceCommand = $ownerResponseBundleZipAutoAcceptanceCommand
    ownerResponseBundleZipEnvironmentVariable = $ownerResponseBundleZipEnvironmentVariable
    ownerInputs = @($ownerInputItems)
}
$summary | ConvertTo-Json -Depth 12 | Set-Content -Path $summaryPath -Encoding UTF8

$ownerInputChecklistLines = @(
    "# AI TestPilot Owner Input Checklist",
    "",
    "| Owner | Area | Contact needed | Dispatch | Owner packet | Response bundle area | Zip status | Zip preflight | Zip auto acceptance | Missing files | Blockers | Hard validation |",
    "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"
)
foreach ($item in $ownerInputItems) {
    $contactNeeded = if (Convert-ToBool (Get-JsonValue $item "emailConfigured" $false)) {
        [string](Get-JsonValue $item "emailAddress" "")
    }
    else {
        "Fill production-handoff-contact-roster.json"
    }

    $ownerInputChecklistLines += ("| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} | {9} | {10} | {11} |" -f `
            (Format-MarkdownCell (Get-JsonValue $item "owner" "")),
        (Format-MarkdownCell (Get-JsonValue $item "area" "")),
        (Format-MarkdownCell $contactNeeded),
        (Format-MarkdownCell (Get-JsonValue $item "dispatchStatus" "")),
        (Format-MarkdownCell (Get-JsonValue $item "ownerPacketPath" "")),
        (Format-MarkdownCell (Get-JsonValue $item "ownerResponseBundleAreaPath" "")),
        (Format-MarkdownCell (Get-JsonValue $item "ownerResponseBundleZipStatusCommand" "")),
        (Format-MarkdownCell (Get-JsonValue $item "ownerResponseBundleZipSemanticPreflightCommand" "")),
        (Format-MarkdownCell (Get-JsonValue $item "ownerResponseBundleZipAutoAcceptanceCommand" "")),
        (Format-MarkdownCell (Join-TextList (Convert-ToArray (Get-JsonValue $item "missingFiles" @())))),
        (Format-MarkdownCell (Join-TextList (Convert-ToArray (Get-JsonValue $item "remainingBlockingReasons" @())))),
        (Format-MarkdownCell (Get-JsonValue $item "hardValidationCommand" "")))
}
$ownerInputChecklistLines += @(
    "",
    "Required operator commands:",
    "",
    "- Fill ``production-handoff-contact-roster.json`` with the real owner email addresses.",
    "- Run ``agently-cli auth status`` and ``production-handoff-mail-auth\check-agently-mail-auth.ps1`` locally before preparing sends.",
    "- Run ``production-handoff-send\send-owner-packets.ps1 -PrepareConfirmation`` only after contacts and local mail authorization are ready.",
    "- Put returned files into the owner response bundle area shown above and inspect its ``required-files.json``.",
    "- Run each owner response bundle zip owner-return status before semantic preflight before auto acceptance before hard validation.",
    "- Run each owner hard validation command only after returned evidence has been accepted."
)
$ownerInputChecklistLines | Set-Content -Path $ownerInputChecklistPath -Encoding UTF8

$externalEvidenceChecklistLines = @(
    "# AI TestPilot External Evidence Return Checklist",
    "",
    "| Owner | Area | Bundle area | Required-files | Required evidence | Missing now | Export helper | Zip owner-return status | Zip semantic preflight | Zip auto acceptance | Hard validation |",
    "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"
)
foreach ($item in $ownerInputItems) {
    $externalEvidenceChecklistLines += ("| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} | {9} | {10} |" -f `
            (Format-MarkdownCell (Get-JsonValue $item "owner" "")),
        (Format-MarkdownCell (Get-JsonValue $item "area" "")),
        (Format-MarkdownCell (Get-JsonValue $item "ownerResponseBundleAreaPath" "")),
        (Format-MarkdownCell (Get-JsonValue $item "ownerResponseBundleRequiredFilesPath" "")),
        (Format-MarkdownCell (Join-TextList (Convert-ToArray (Get-JsonValue $item "requiredEvidenceFiles" @())))),
        (Format-MarkdownCell (Join-TextList (Convert-ToArray (Get-JsonValue $item "missingFiles" @())))),
        (Format-MarkdownCell (Get-JsonValue $item "exportHelperCommand" "")),
        (Format-MarkdownCell (Get-JsonValue $item "ownerResponseBundleZipStatusCommand" "")),
        (Format-MarkdownCell (Get-JsonValue $item "ownerResponseBundleZipSemanticPreflightCommand" "")),
        (Format-MarkdownCell (Get-JsonValue $item "ownerResponseBundleZipAutoAcceptanceCommand" "")),
        (Format-MarkdownCell (Get-JsonValue $item "hardValidationCommand" "")))
}
$externalEvidenceChecklistLines += @(
    "",
    "Run owner-return status before semantic preflight before auto acceptance before hard validation for every returned owner response bundle zip.",
    "Zip path can also be supplied with ``$ownerResponseBundleZipEnvironmentVariable``.",
    "",
    "After returned files are placed in ``production-external-evidence-inbox``, run ``production-external-evidence-inbox\accept-returned-evidence.ps1`` or the source acceptance command recorded in the inbox manifest.",
    "",
    "Current accepted evidence boundary: real host-project evidence accepted = false; external evidence accepted = false; fixture evidence promoted = false."
)
$externalEvidenceChecklistLines | Set-Content -Path $externalEvidenceReturnChecklistPath -Encoding UTF8

$operatorRequestEmailDraftLines = @(
    "To: $ProgressRecipient",
    "Subject: AI TestPilot owner input request - contacts and returned evidence",
    "",
    "AI TestPilot needs owner input before production completion.",
    "",
    "Current remaining external items:",
    "",
    "- Owner input request status: $ownerInputRequestStatus",
    "- Missing owner contacts: $missingOwnerContactCount",
    "- Pending dispatches: $pendingDispatchCount",
    "- Pending owner packets: $pendingOwnerPacketCount",
    "- Missing external evidence files: $missingRequiredFileCount",
    "- Remaining blocking reasons: $remainingBlockingReasonCount",
    "- Blocked sends: $blockedSendCount",
    "- Ready sends: $readySendCount",
    "- Mail auth readiness: $mailAuthReadinessStatus",
    "",
    "Please provide or route:",
    "",
    "1. Real email addresses for the three owner contacts in ``production-handoff-contact-roster.json``.",
    "2. Returned production evidence files listed in ``production-handoff-owner-input-request-pack\external-evidence-return-checklist.md``.",
    "3. Confirmation that owner packets can be sent after local ``agently-cli`` authorization and two-stage send confirmation.",
    "",
    "Generated request pack:",
    "",
    "- ``production-handoff-owner-input-request-pack\README.md``",
    "- ``production-handoff-owner-input-request-pack\owner-contact-roster-template.json``",
    "- ``production-handoff-owner-input-request-pack\owner-input-checklist.md``",
    "- ``production-handoff-owner-input-request-pack\external-evidence-return-checklist.md``",
    "- Owner response bundle zip semantic preflight command: ``$ownerResponseBundleZipSemanticPreflightCommand``.",
    "- Owner response bundle zip auto acceptance command: ``$ownerResponseBundleZipAutoAcceptanceCommand``.",
    "",
    "Boundary:",
    "",
    "- No owner email has been sent by CI or this request-pack script.",
    "- Mail authorization has not been checked by the release pipeline.",
    "- Real host-project evidence has not been accepted.",
    "- Fixture evidence has not been promoted."
)
$operatorRequestEmailDraftLines | Set-Content -Path $operatorRequestEmailDraftPath -Encoding UTF8

$readmeLines = @(
    "# AI TestPilot Production Handoff Owner Input Request Pack",
    "",
    "This folder is the owner-facing request layer for the remaining production handoff inputs.",
    "",
    "Files:",
    "",
    "- ``owner-input-summary.json``: machine-readable owner input status and counts.",
    "- ``owner-contact-roster-template.json``: fill-in template for real owner email addresses.",
    "- ``owner-input-checklist.md``: owner packet, contact, dispatch, and validation checklist.",
    "- ``external-evidence-return-checklist.md``: required returned evidence files, owner response bundle routes, owner-return status, semantic preflight, auto acceptance, export helpers, and hard validation commands.",
    "- ``operator-request-email-draft.md``: progress-recipient request draft.",
    "",
    "Use the template to update ``production-handoff-contact-roster.json``. Then run ``agently-cli auth status`` and ``production-handoff-mail-auth\check-agently-mail-auth.ps1`` locally before preparing owner packet sends.",
    "For returned evidence, use each owner response bundle route and run owner-return status before semantic preflight before auto acceptance before hard validation.",
    "",
    "This pack does not send email, run OAuth login, accept real host-project evidence, or promote fixture evidence."
)
$readmeLines | Set-Content -Path $readmePath -Encoding UTF8

$reportLines = @(
    "# AI TestPilot Production Handoff Owner Input Request Pack",
    "",
    "Schema: ``aitestpilot.production_handoff_owner_input_request_pack.v1``",
    "Generated at UTC: $((Get-Date).ToUniversalTime().ToString("O"))",
    "",
    "## Summary",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Owner input request status | $ownerInputRequestStatus |",
    "| Owner unblock status | $ownerUnblockStatus |",
    "| Progress recipient | $ProgressRecipient |",
    "| Missing owner contacts | $missingOwnerContactCount |",
    "| Pending dispatches | $pendingDispatchCount |",
    "| Pending owner packets | $pendingOwnerPacketCount |",
    "| Missing required evidence files | $missingRequiredFileCount |",
    "| Remaining blocking reasons | $remainingBlockingReasonCount |",
    "| Blocked sends | $blockedSendCount |",
    "| Ready sends | $readySendCount |",
    "| Mail auth readiness | $mailAuthReadinessStatus |",
    "",
    "## Owner Requests",
    "",
    "| Owner | Area | Contact | Send | Missing files | Blockers |",
    "| --- | --- | --- | --- | --- | --- |"
)
foreach ($item in $ownerInputItems) {
    $contactLabel = if (Convert-ToBool (Get-JsonValue $item "emailConfigured" $false)) {
        [string](Get-JsonValue $item "emailAddress" "")
    }
    else {
        [string](Get-JsonValue $item "contactStatus" "MISSING_OWNER_EMAIL")
    }

    $reportLines += ("| {0} | {1} | {2} | {3} | {4} | {5} |" -f `
            (Format-MarkdownCell (Get-JsonValue $item "owner" "")),
        (Format-MarkdownCell (Get-JsonValue $item "area" "")),
        (Format-MarkdownCell $contactLabel),
        (Format-MarkdownCell (Get-JsonValue $item "sendStatus" "")),
        (Format-MarkdownCell (Join-TextList (Convert-ToArray (Get-JsonValue $item "missingFiles" @())))),
        (Format-MarkdownCell (Join-TextList (Convert-ToArray (Get-JsonValue $item "remainingBlockingReasons" @())))))
}
$reportLines += @(
    "",
    "## Operator Path",
    "",
    "1. Fill ``production-handoff-contact-roster.json`` from ``owner-contact-roster-template.json``.",
    "2. Run ``agently-cli auth status`` and ``production-handoff-mail-auth\check-agently-mail-auth.ps1`` locally.",
    "3. Use ``production-handoff-send\send-owner-packets.ps1 -PrepareConfirmation`` only after contacts and auth are ready.",
    "4. Place returned evidence in each owner response bundle area and run owner-return status before semantic preflight before auto acceptance before hard validation.",
    "5. The returned-evidence inbox wrapper remains available as ``production-external-evidence-inbox\accept-returned-evidence.ps1`` after semantic preflight succeeds.",
    "",
    "## Boundary",
    "",
    "- This request pack is owner-input routing only.",
    "- It does not send email or check local mail authorization.",
    "- It does not accept real host-project evidence.",
    "- It does not promote fixture evidence."
)
$reportLines | Set-Content -Path $reportFullPath -Encoding UTF8

$summaryContent = Get-Content -Path $summaryPath -Encoding UTF8 -Raw
$rosterContent = Get-Content -Path $contactRosterTemplatePath -Encoding UTF8 -Raw
$ownerChecklistContent = Get-Content -Path $ownerInputChecklistPath -Encoding UTF8 -Raw
$externalEvidenceChecklistContent = Get-Content -Path $externalEvidenceReturnChecklistPath -Encoding UTF8 -Raw
$emailDraftContent = Get-Content -Path $operatorRequestEmailDraftPath -Encoding UTF8 -Raw
$readmeContent = Get-Content -Path $readmePath -Encoding UTF8 -Raw
$reportContent = Get-Content -Path $reportFullPath -Encoding UTF8 -Raw

$ownerResponseBundleRoutesValidated = (
    $ownerResponseBundleRouteCount -eq $ownerActionCount -and
    $ownerResponseBundleAreaPathCount -eq $ownerActionCount -and
    $ownerResponseBundleRequiredFilesPathCount -eq $ownerActionCount -and
    $ownerResponseBundleZipStatusCommandCount -eq $ownerActionCount -and
    $ownerResponseBundleZipSemanticPreflightCommandCount -eq $ownerActionCount -and
    $ownerResponseBundleZipAutoAcceptanceCommandCount -eq $ownerActionCount -and
    $ownerResponseBundleExportHelperCommandCount -eq $ownerActionCount
)
$ownerResponseBundleContentValidated = (
    $summaryContent.Contains("ownerResponseBundleRouteCount") -and
    $summaryContent.Contains("ownerResponseBundleZipStatusCommand") -and
    $ownerChecklistContent.Contains("owner response bundle zip owner-return status before semantic preflight before auto acceptance before hard validation") -and
    $externalEvidenceChecklistContent.Contains("Run owner-return status before semantic preflight before auto acceptance before hard validation") -and
    $externalEvidenceChecklistContent.Contains($ownerResponseBundleZipEnvironmentVariable) -and
    $externalEvidenceChecklistContent.Contains("Export-ProductionDriverEvidenceBundle.ps1") -and
    $externalEvidenceChecklistContent.Contains("Export-ProductionLuaPatchEvidenceBundle.ps1") -and
    $externalEvidenceChecklistContent.Contains("Export-LiveModelEndpointSmokeEvidenceBundle.ps1") -and
    $reportContent.Contains("owner response bundle area") -and
    $readmeContent.Contains("owner response bundle routes")
)
$ownerNamesPresent = $reportContent.Contains("host_project_gameplay_qa") -and
    $reportContent.Contains("host_project_lua_owner") -and
    $reportContent.Contains("host_project_ai_platform")
$noObjectLeakage = -not $summaryContent.Contains("System.Collections") -and -not $summaryContent.Contains("@{") -and
    -not $rosterContent.Contains("System.Collections") -and -not $rosterContent.Contains("@{") -and
    -not $ownerChecklistContent.Contains("System.Collections") -and -not $ownerChecklistContent.Contains("@{") -and
    -not $externalEvidenceChecklistContent.Contains("System.Collections") -and -not $externalEvidenceChecklistContent.Contains("@{") -and
    -not $emailDraftContent.Contains("System.Collections") -and -not $emailDraftContent.Contains("@{") -and
    -not $readmeContent.Contains("System.Collections") -and -not $readmeContent.Contains("@{") -and
    -not $reportContent.Contains("System.Collections") -and -not $reportContent.Contains("@{")

$summaryContentValidated = $summaryContent.Contains("production_handoff_owner_input_request_summary.v1") -and
    $summaryContent.Contains($ownerInputRequestStatus) -and
    $summaryContent.Contains($ProgressRecipient) -and
    $summaryContent.Contains("production-handoff-contact-roster.json") -and
    $summaryContent.Contains("ownerResponseBundleZipStatusCommand") -and
    $summaryContent.Contains("ownerResponseBundleZipSemanticPreflightCommand") -and
    $noObjectLeakage
$rosterTemplateContentValidated = $rosterContent.Contains("production_handoff_owner_contact_roster_request.v1") -and
    $rosterContent.Contains("host_project_gameplay_qa") -and
    $rosterContent.Contains("host_project_lua_owner") -and
    $rosterContent.Contains("host_project_ai_platform") -and
    $rosterContent.Contains("Fill with the real owner mailbox") -and
    $noObjectLeakage
$ownerInputChecklistContentValidated = $ownerChecklistContent.Contains("production-handoff-contact-roster.json") -and
    $ownerChecklistContent.Contains("agently-cli auth status") -and
    $ownerChecklistContent.Contains("send-owner-packets.ps1") -and
    $ownerChecklistContent.Contains("owner response bundle") -and
    $ownerChecklistContent.Contains("host_project_gameplay_qa") -and
    $noObjectLeakage
$externalEvidenceReturnChecklistContentValidated = $externalEvidenceChecklistContent.Contains("accept-returned-evidence.ps1") -and
    $externalEvidenceChecklistContent.Contains("production-external-evidence-inbox") -and
    $externalEvidenceChecklistContent.Contains("Zip owner-return status") -and
    $externalEvidenceChecklistContent.Contains("Zip semantic preflight") -and
    $externalEvidenceChecklistContent.Contains("real host-project evidence accepted = false") -and
    $externalEvidenceChecklistContent.Contains("host_project_lua_owner") -and
    $noObjectLeakage
$requestEmailDraftContentValidated = $emailDraftContent.Contains($ProgressRecipient) -and
    $emailDraftContent.Contains("AI TestPilot needs owner input") -and
    $emailDraftContent.Contains("Missing owner contacts: $missingOwnerContactCount") -and
    $emailDraftContent.Contains("No owner email has been sent") -and
    $noObjectLeakage
$readmeContentValidated = $readmeContent.Contains("owner-facing request layer") -and
    $readmeContent.Contains("agently-cli auth status") -and
    $readmeContent.Contains("owner-return status before semantic preflight before auto acceptance before hard validation") -and
    $readmeContent.Contains("does not send email") -and
    $noObjectLeakage
$reportContentValidated = $reportContent.Contains("Production Handoff Owner Input Request Pack") -and
    $reportContent.Contains($ownerInputRequestStatus) -and
    $ownerNamesPresent -and
    $reportContent.Contains("accept-returned-evidence.ps1") -and
    $reportContent.Contains("does not send email") -and
    $noObjectLeakage

$checks = @()
Add-RequestCheck "owner_input_request_sources_available" `
    ($ownerUnblockManifest.status -eq "PASS" -and $handoffStatusManifest.status -eq "PASS" -and $dispatchManifest.status -eq "PASS" -and $contactReadinessManifest.status -eq "PASS" -and $sendReadinessManifest.status -eq "PASS" -and $mailAuthReadinessManifest.status -eq "PASS" -and $inboxManifest.status -eq "PASS" -and $handoffExportManifest.status -eq "PASS") `
    "Owner input request pack must be based on passing unblock, status, dispatch, contact, send, mail-auth, inbox, and export evidence."
Add-RequestCheck "owner_input_request_counts_match_sources" `
    ($ownerActionCount -eq $ownerPacketCount -and
        $ownerPacketCount -eq (Convert-ToInt (Get-JsonValue $handoffStatusManifest "ownerPacketCount" -1)) -and
        $pendingOwnerPacketCount -eq (Convert-ToInt (Get-JsonValue $handoffStatusManifest "pendingOwnerPacketCount" -1)) -and
        $pendingDispatchCount -eq (Convert-ToInt (Get-JsonValue $dispatchManifest "pendingDispatchCount" -1)) -and
        $pendingDispatchCount -eq (Convert-ToInt (Get-JsonValue $contactReadinessManifest "pendingDispatchCount" -1)) -and
        $missingOwnerContactCount -eq (Convert-ToInt (Get-JsonValue $contactReadinessManifest "missingOwnerContactCount" -1)) -and
        $missingRequiredFileCount -eq (Convert-ToInt (Get-JsonValue $inboxManifest "missingRequiredFileCount" -1)) -and
        $remainingBlockingReasonCount -eq (Convert-ToInt (Get-JsonValue $handoffStatusManifest "remainingBlockingReasonCount" -1)) -and
        $blockedSendCount -eq (Convert-ToInt (Get-JsonValue $sendReadinessManifest "blockedSendCount" -1)) -and
        $readySendCount -eq (Convert-ToInt (Get-JsonValue $sendReadinessManifest "readySendCount" -1))) `
    "Owner input request counts must match the owner unblock pack and source manifests."
Add-RequestCheck "owner_input_request_files_generated" `
    ((Test-Path $summaryPath) -and (Test-Path $contactRosterTemplatePath) -and (Test-Path $ownerInputChecklistPath) -and (Test-Path $externalEvidenceReturnChecklistPath) -and (Test-Path $operatorRequestEmailDraftPath) -and (Test-Path $readmePath) -and (Test-Path $reportFullPath)) `
    "Owner input request pack must generate summary, roster template, owner checklist, evidence checklist, request email draft, README, and report files."
Add-RequestCheck "owner_input_request_content_validated" `
    ($summaryContentValidated -and $rosterTemplateContentValidated -and $ownerInputChecklistContentValidated -and $externalEvidenceReturnChecklistContentValidated -and $requestEmailDraftContentValidated -and $readmeContentValidated -and $reportContentValidated) `
    "Generated owner input request files must include concrete owners, missing files, commands, recipient, and boundary text without object leakage."
Add-RequestCheck "owner_input_request_owner_response_bundle_routes" `
    ($ownerResponseBundleRoutesValidated -and $ownerResponseBundleContentValidated) `
    "Owner input request pack must expose one owner response bundle route, required-files path, zip owner-return status command, zip semantic-preflight command, zip auto-acceptance command, and export helper per owner before hard validation."
Add-RequestCheck "owner_input_request_mail_boundary_preserved" `
    ($mailAuthReadinessStatus -eq "BLOCKED_NOT_CHECKED_BY_RELEASE_PIPELINE" -and
        -not (Convert-ToBool (Get-JsonValue $ownerUnblockManifest "automaticEmailSendReady" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $ownerUnblockManifest "mailAuthorizationCheckedByPipeline" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $mailAuthReadinessManifest "mailAuthorizationCheckedByPipeline" $true))) `
    "Owner input request pack must not claim local mail authorization or automatic email send readiness."
Add-RequestCheck "owner_input_request_evidence_boundary_preserved" `
    (-not $realHostProjectEvidenceAccepted -and
        -not $externalEvidenceAccepted -and
        -not $externalEvidenceCollectionComplete -and
        -not (Convert-ToBool (Get-JsonValue $ownerUnblockManifest "releasePipelineUsesFixture" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $ownerUnblockManifest "fixtureEvidencePromoted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $inboxManifest "fixtureEvidencePromoted" $true))) `
    "Owner input request pack must not accept real host-project evidence, mark collection complete, or promote fixture evidence."
Add-RequestCheck "owner_input_request_status_boundary" `
    ($ownerInputRequestStatus -eq "AWAITING_EXTERNAL_OWNER_INPUT" -and
        $ownerUnblockStatus -eq "BLOCKED_EXTERNAL_OWNER_INPUT" -and
        $missingOwnerContactCount -gt 0 -and
        $pendingDispatchCount -gt 0 -and
        $missingRequiredFileCount -gt 0 -and
        $remainingBlockingReasonCount -gt 0) `
    "Default owner input request pack must remain awaiting external owner input while contacts and evidence are missing."
Add-RequestCheck "owner_input_request_export_available" `
    ([bool]$handoffExportZipAvailable) `
    "Owner input request pack must sit beside an available handoff export zip for owner distribution."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestFullPath),
    (Convert-ToEvidenceRelativePath $reportFullPath),
    (Convert-ToEvidenceRelativePath $summaryPath),
    (Convert-ToEvidenceRelativePath $contactRosterTemplatePath),
    (Convert-ToEvidenceRelativePath $ownerInputChecklistPath),
    (Convert-ToEvidenceRelativePath $externalEvidenceReturnChecklistPath),
    (Convert-ToEvidenceRelativePath $operatorRequestEmailDraftPath),
    (Convert-ToEvidenceRelativePath $readmePath)
)
$sourceFiles = @(
    "production-handoff-owner-unblock-pack-manifest.json",
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
    schemaVersion = "aitestpilot.production_handoff_owner_input_request_pack.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    requestDir = $requestPath
    reportPath = $reportFullPath
    ownerInputRequestStatus = $ownerInputRequestStatus
    ownerUnblockStatus = $ownerUnblockStatus
    operatorProgressRecipient = $ProgressRecipient
    requestPackGenerated = (Test-Path $requestPath)
    summaryGenerated = (Test-Path $summaryPath)
    contactRosterTemplateGenerated = (Test-Path $contactRosterTemplatePath)
    ownerInputChecklistGenerated = (Test-Path $ownerInputChecklistPath)
    externalEvidenceReturnChecklistGenerated = (Test-Path $externalEvidenceReturnChecklistPath)
    requestEmailDraftGenerated = (Test-Path $operatorRequestEmailDraftPath)
    readmeGenerated = (Test-Path $readmePath)
    reportGenerated = (Test-Path $reportFullPath)
    summaryContentValidated = [bool]$summaryContentValidated
    contactRosterTemplateContentValidated = [bool]$rosterTemplateContentValidated
    ownerInputChecklistContentValidated = [bool]$ownerInputChecklistContentValidated
    externalEvidenceReturnChecklistContentValidated = [bool]$externalEvidenceReturnChecklistContentValidated
    requestEmailDraftContentValidated = [bool]$requestEmailDraftContentValidated
    readmeContentValidated = [bool]$readmeContentValidated
    reportContentValidated = [bool]$reportContentValidated
    ownerPacketCount = [int]$ownerPacketCount
    ownerActionCount = [int]$ownerActionCount
    pendingOwnerPacketCount = [int]$pendingOwnerPacketCount
    pendingDispatchCount = [int]$pendingDispatchCount
    missingOwnerContactCount = [int]$missingOwnerContactCount
    missingRequiredFileCount = [int]$missingRequiredFileCount
    remainingBlockingReasonCount = [int]$remainingBlockingReasonCount
    blockedSendCount = [int]$blockedSendCount
    readySendCount = [int]$readySendCount
    sendReadinessStatus = $sendReadinessStatus
    mailAuthReadinessStatus = $mailAuthReadinessStatus
    ownerResponseBundleRouteCount = [int]$ownerResponseBundleRouteCount
    ownerResponseBundleAreaPathCount = [int]$ownerResponseBundleAreaPathCount
    ownerResponseBundleRequiredFilesPathCount = [int]$ownerResponseBundleRequiredFilesPathCount
    ownerResponseBundleZipStatusCommandCount = [int]$ownerResponseBundleZipStatusCommandCount
    ownerResponseBundleZipSemanticPreflightCommandCount = [int]$ownerResponseBundleZipSemanticPreflightCommandCount
    ownerResponseBundleZipAutoAcceptanceCommandCount = [int]$ownerResponseBundleZipAutoAcceptanceCommandCount
    ownerResponseBundleExportHelperCommandCount = [int]$ownerResponseBundleExportHelperCommandCount
    ownerResponseBundleRoutesValidated = [bool]$ownerResponseBundleRoutesValidated
    ownerResponseBundleContentValidated = [bool]$ownerResponseBundleContentValidated
    ownerResponseBundleOwnerReturnStatusBeforeSemanticPreflightBeforeAutoAcceptanceDocumented = [bool]$ownerResponseBundleContentValidated
    ownerResponseBundleSemanticPreflightBeforeAutoAcceptanceDocumented = [bool]$ownerResponseBundleContentValidated
    ownerResponseBundleStatusCommand = $ownerResponseBundleStatusCommand
    ownerResponseBundleZipStatusCommand = $ownerResponseBundleZipStatusCommand
    ownerResponseBundleSemanticPreflightCommand = $ownerResponseBundleSemanticPreflightCommand
    ownerResponseBundleZipSemanticPreflightCommand = $ownerResponseBundleZipSemanticPreflightCommand
    ownerResponseBundleAutoAcceptanceCommand = $ownerResponseBundleAutoAcceptanceCommand
    ownerResponseBundleZipAutoAcceptanceCommand = $ownerResponseBundleZipAutoAcceptanceCommand
    ownerResponseBundleZipEnvironmentVariable = $ownerResponseBundleZipEnvironmentVariable
    automaticEmailSendReady = $false
    mailAuthorizationCheckedByPipeline = $false
    handoffExportZipAvailable = [bool]$handoffExportZipAvailable
    externalEvidenceCollectionComplete = [bool]$externalEvidenceCollectionComplete
    releasePipelineUsesFixture = $false
    realHostProjectEvidenceAccepted = $false
    externalEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "host_project_owner_input_request_pack_only"
    ownerInputs = @($ownerInputItems)
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
    throw "Production handoff owner input request pack failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production handoff owner input request pack manifest: $manifestFullPath"
Write-Output "Production handoff owner input request pack report: $reportFullPath"
Write-Output "PASS AI TestPilot production handoff owner input request pack"
