[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ManifestPath,
    [string]$ReportPath,
    [string]$OwnerResponseBundleDir,
    [string]$OwnerResponseBundleZipPath,
    [string]$AutoAcceptanceManifestPath,
    [switch]$ContractFixtureMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$ownerResponseBundleZipEnvironmentVariableName = "AITESTPILOT_OWNER_RESPONSE_BUNDLE_ZIP_PATH"
$ownerResponseBundleDirEnvironmentVariableName = "AITESTPILOT_OWNER_RESPONSE_BUNDLE_DIR"

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-external-evidence-owner-return-bundle-status-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-external-evidence-owner-return-bundle-status.md"
}

function Resolve-FullPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Test-PathWithinRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    $fullPath = Resolve-FullPath $Path
    $rootPath = (Resolve-FullPath $Root).TrimEnd([char[]]@("\", "/"))
    return $fullPath.Equals($rootPath, [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($rootPath + "\", [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($rootPath + "/", [System.StringComparison]::OrdinalIgnoreCase)
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
    if (-not (Test-PathWithinRoot $fullPath $evidenceBundlePath)) {
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
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) {
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

function Join-MarkdownList {
    param([object[]]$Values)

    $items = @($Values | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($items.Count -eq 0) {
        return "(none)"
    }

    return [string]::Join(", ", $items)
}

function Add-StatusCheck {
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

function Get-OwnerAreaKey {
    param(
        [string]$Owner,
        [string]$Area
    )

    return "$Owner|$Area"
}

function Invoke-SemanticPreflight {
    param(
        [string]$PreflightManifestPath,
        [string]$PreflightReportPath,
        [string]$PreflightOutputPath
    )

    $preflightParams = @{
        EvidenceBundleDir = $evidenceBundlePath
        ManifestPath = $PreflightManifestPath
        ReportPath = $PreflightReportPath
    }
    if (-not [string]::IsNullOrWhiteSpace($OwnerResponseBundleDir)) {
        $preflightParams["OwnerResponseBundleDir"] = $OwnerResponseBundleDir
    }
    if (-not [string]::IsNullOrWhiteSpace($OwnerResponseBundleZipPath)) {
        $preflightParams["OwnerResponseBundleZipPath"] = $OwnerResponseBundleZipPath
    }
    if ([bool]$ContractFixtureMode) {
        $preflightParams["ContractFixtureMode"] = $true
    }

    $failed = $false
    $errorMessage = ""
    try {
        $output = & (Join-Path $PSScriptRoot "Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1") @preflightParams 2>&1
    }
    catch {
        $failed = $true
        $output = @($_)
        $errorMessage = $_.Exception.Message
    }

    @($output | ForEach-Object { [string]$_ }) | Set-Content -Path $PreflightOutputPath -Encoding UTF8

    return [ordered]@{
        failed = [bool]$failed
        errorMessage = $errorMessage
        manifestPath = $PreflightManifestPath
        reportPath = $PreflightReportPath
        outputPath = $PreflightOutputPath
        manifest = Read-OptionalJsonFile $PreflightManifestPath
    }
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if (-not (Test-PathWithinRoot $manifestFullPath $evidenceBundlePath)) {
    throw "ManifestPath must stay under evidence bundle: $manifestFullPath"
}
if (-not (Test-PathWithinRoot $reportFullPath $evidenceBundlePath)) {
    throw "ReportPath must stay under evidence bundle: $reportFullPath"
}
if (-not [string]::IsNullOrWhiteSpace($OwnerResponseBundleDir) -and
    -not [string]::IsNullOrWhiteSpace($OwnerResponseBundleZipPath)) {
    throw "Pass either -OwnerResponseBundleDir or -OwnerResponseBundleZipPath, not both."
}

$ownerReturnBundleExplicitInputProvided = -not [string]::IsNullOrWhiteSpace($OwnerResponseBundleDir) -or
    -not [string]::IsNullOrWhiteSpace($OwnerResponseBundleZipPath)
$ownerReturnBundleDiscoveredFromEnvironment = $false
$ownerReturnBundleSourceKind = "none"

if ($ownerReturnBundleExplicitInputProvided) {
    if (-not [string]::IsNullOrWhiteSpace($OwnerResponseBundleZipPath)) {
        $ownerReturnBundleSourceKind = "parameter:OwnerResponseBundleZipPath"
    }
    else {
        $ownerReturnBundleSourceKind = "parameter:OwnerResponseBundleDir"
    }
}
else {
    $ownerResponseBundleZipEnvironmentValue = [Environment]::GetEnvironmentVariable($ownerResponseBundleZipEnvironmentVariableName)
    $ownerResponseBundleDirEnvironmentValue = [Environment]::GetEnvironmentVariable($ownerResponseBundleDirEnvironmentVariableName)
    if (-not [string]::IsNullOrWhiteSpace($ownerResponseBundleZipEnvironmentValue)) {
        $OwnerResponseBundleZipPath = $ownerResponseBundleZipEnvironmentValue
        $ownerReturnBundleDiscoveredFromEnvironment = $true
        $ownerReturnBundleSourceKind = "environment_variable:$ownerResponseBundleZipEnvironmentVariableName"
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ownerResponseBundleDirEnvironmentValue)) {
        $OwnerResponseBundleDir = $ownerResponseBundleDirEnvironmentValue
        $ownerReturnBundleDiscoveredFromEnvironment = $true
        $ownerReturnBundleSourceKind = "environment_variable:$ownerResponseBundleDirEnvironmentVariableName"
    }
}

$handoffStatusManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-status-manifest.json") "Production handoff status manifest"
$inboxManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-external-evidence-inbox-manifest.json") "Production external evidence inbox manifest"
$ownerInputRequestPackManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-owner-input-request-pack-manifest.json") "Production handoff owner input request pack manifest"
$ownerUnblockPackManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-owner-unblock-pack-manifest.json") "Production handoff owner unblock pack manifest"
$ownerResponseBundleKitManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-owner-response-bundle-kit-manifest.json") "Production handoff owner response bundle kit manifest"
$actionQueueManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-external-evidence-action-queue-manifest.json") "Production external evidence action queue manifest"

if ([string]::IsNullOrWhiteSpace($AutoAcceptanceManifestPath)) {
    $candidateAutoAcceptancePath = Join-Path $evidenceBundlePath "production-external-evidence-auto-acceptance-manifest.json"
    if (Test-Path $candidateAutoAcceptancePath) {
        $AutoAcceptanceManifestPath = $candidateAutoAcceptancePath
    }
}
$autoAcceptanceManifest = Read-OptionalJsonFile $AutoAcceptanceManifestPath
$autoAcceptanceManifestUsed = $null -ne $autoAcceptanceManifest

$ownerReturnBundleInputKind = "none"
$ownerReturnBundlePath = ""
if (-not [string]::IsNullOrWhiteSpace($OwnerResponseBundleZipPath)) {
    $ownerReturnBundleInputKind = "owner_response_bundle_zip"
    $ownerReturnBundlePath = Resolve-FullPath $OwnerResponseBundleZipPath
}
elseif (-not [string]::IsNullOrWhiteSpace($OwnerResponseBundleDir)) {
    $ownerReturnBundleInputKind = "owner_response_bundle_dir"
    $ownerReturnBundlePath = Resolve-FullPath $OwnerResponseBundleDir
}
$ownerReturnBundleUnderRepo = -not [string]::IsNullOrWhiteSpace($ownerReturnBundlePath) -and (Test-PathWithinRoot $ownerReturnBundlePath $repoRoot)

$semanticPreflightRun = $ownerReturnBundleInputKind -ne "none"
$semanticPreflightResult = $null
$semanticPreflightManifest = $null
$statusArtifactDir = Join-Path $evidenceBundlePath "production-external-evidence-owner-return-bundle-status"
$semanticPreflightManifestPath = Join-Path $statusArtifactDir "semantic-preflight-manifest.json"
$semanticPreflightReportPath = Join-Path $statusArtifactDir "semantic-preflight.md"
$semanticPreflightOutputPath = Join-Path $statusArtifactDir "semantic-preflight-output.txt"
if ($semanticPreflightRun) {
    New-Item -ItemType Directory -Force $statusArtifactDir | Out-Null
    $semanticPreflightResult = Invoke-SemanticPreflight $semanticPreflightManifestPath $semanticPreflightReportPath $semanticPreflightOutputPath
    $semanticPreflightManifest = Get-JsonValue $semanticPreflightResult "manifest" $null
}

$semanticPreflightStatus = if ($semanticPreflightRun) {
    [string](Get-JsonValue $semanticPreflightManifest "semanticPreflightStatus" "OWNER_RETURN_STATUS_UNREADABLE")
}
else {
    "PENDING_EXTERNAL_EVIDENCE"
}
$readyForAcceptanceCandidate = if ($semanticPreflightRun) {
    Convert-ToBool (Get-JsonValue $semanticPreflightManifest "readyForAcceptanceCandidate" $false)
}
else {
    $false
}
$missingRequiredFileCount = if ($semanticPreflightRun) {
    Convert-ToInt (Get-JsonValue $semanticPreflightManifest "missingRequiredFileCount" 0)
}
else {
    Convert-ToInt (Get-JsonValue $handoffStatusManifest "remainingMissingFileCount" 0)
}
$presentRequiredFileCount = if ($semanticPreflightRun) {
    Convert-ToInt (Get-JsonValue $semanticPreflightManifest "presentRequiredFileCount" 0)
}
else {
    Convert-ToInt (Get-JsonValue $inboxManifest "presentEvidenceFileCount" 0)
}
$semanticFailCount = if ($semanticPreflightRun) { Convert-ToInt (Get-JsonValue $semanticPreflightManifest "semanticFailCount" 0) } else { 0 }
$semanticWarnCount = if ($semanticPreflightRun) { Convert-ToInt (Get-JsonValue $semanticPreflightManifest "semanticWarnCount" 0) } else { 0 }
$ownerResponseBundlePayloadShapeViolationCount = if ($semanticPreflightRun) { Convert-ToInt (Get-JsonValue $semanticPreflightManifest "ownerResponseBundlePayloadShapeViolationCount" 0) } else { 0 }
$ownerResponseBundleStrictPayloadShape = if ($semanticPreflightRun) { Convert-ToBool (Get-JsonValue $semanticPreflightManifest "ownerResponseBundleStrictPayloadShape" $false) } else { $false }
$ownerReturnBundleRootResolved = if ($semanticPreflightRun) { Convert-ToBool (Get-JsonValue $semanticPreflightManifest "ownerResponseBundleRootResolved" $false) } else { $false }
$ownerReturnBundleRootResolutionKind = if ($semanticPreflightRun) { [string](Get-JsonValue $semanticPreflightManifest "ownerResponseBundleRootResolutionKind" "") } else { "not_applicable" }
$ownerReturnBundleResolvedRoot = if ($semanticPreflightRun) { [string](Get-JsonValue $semanticPreflightManifest "ownerResponseBundleResolvedRoot" "") } else { "" }
$ownerReturnBundleZipInspected = if ($semanticPreflightRun) { Convert-ToBool (Get-JsonValue $semanticPreflightManifest "ownerResponseBundleZipInspected" $false) } else { $false }
$ownerReturnBundleZipSafe = if ($semanticPreflightRun) { Convert-ToBool (Get-JsonValue $semanticPreflightManifest "zipSafe" $true) } else { $true }
$ownerReturnBundleZipEntryCount = if ($semanticPreflightRun) { Convert-ToInt (Get-JsonValue $semanticPreflightManifest "zipEntryCount" 0) } else { 0 }
$ownerReturnBundleZipUnsafeEntryCount = if ($semanticPreflightRun) { Convert-ToInt (Get-JsonValue $semanticPreflightManifest "zipUnsafeEntryCount" 0) } else { 0 }
$ownerReturnBundleZipDuplicateEntryCount = if ($semanticPreflightRun) { Convert-ToInt (Get-JsonValue $semanticPreflightManifest "zipDuplicateEntryCount" 0) } else { 0 }

$ownerReturnReadinessStatus = "PENDING_EXTERNAL_EVIDENCE"
if ($semanticPreflightRun -and $readyForAcceptanceCandidate) {
    $ownerReturnReadinessStatus = "READY_FOR_AUTO_ACCEPTANCE_CANDIDATE"
}
elseif ($semanticPreflightRun -and (
        $semanticPreflightStatus -eq "NEEDS_OWNER_REPAIR" -or
        $semanticFailCount -gt 0 -or
        $ownerResponseBundlePayloadShapeViolationCount -gt 0 -or
        -not $ownerReturnBundleZipSafe)) {
    $ownerReturnReadinessStatus = "NEEDS_OWNER_REPAIR"
}
elseif ($semanticPreflightRun -and $semanticPreflightStatus -eq "OWNER_RETURN_STATUS_UNREADABLE") {
    $ownerReturnReadinessStatus = "OWNER_RETURN_STATUS_UNREADABLE"
}

$nextRequiredAction = switch ($ownerReturnReadinessStatus) {
    "READY_FOR_AUTO_ACCEPTANCE_CANDIDATE" { "run_auto_acceptance" }
    "NEEDS_OWNER_REPAIR" { "return_semantic_preflight_report_to_owner" }
    "OWNER_RETURN_STATUS_UNREADABLE" { "inspect_owner_return_status_artifact" }
    default { "collect_owner_response_bundle_zip" }
}

$inboxAreaStatusByKey = @{}
foreach ($areaStatus in @(Convert-ToArray (Get-JsonValue $inboxManifest "areaStatuses" @()))) {
    $key = Get-OwnerAreaKey ([string](Get-JsonValue $areaStatus "owner" "")) ([string](Get-JsonValue $areaStatus "area" ""))
    $inboxAreaStatusByKey[$key] = $areaStatus
}

$ownerReturnStatuses = @()
foreach ($ownerStatus in @(Convert-ToArray (Get-JsonValue $handoffStatusManifest "ownerStatuses" @()))) {
    $owner = [string](Get-JsonValue $ownerStatus "owner" "")
    $area = [string](Get-JsonValue $ownerStatus "area" "")
    $key = Get-OwnerAreaKey $owner $area
    $inboxAreaStatus = if ($inboxAreaStatusByKey.ContainsKey($key)) { $inboxAreaStatusByKey[$key] } else { $null }
    $ownerReturnStatuses += [ordered]@{
        owner = $owner
        area = $area
        status = [string](Get-JsonValue $ownerStatus "status" "")
        requiredEvidenceFiles = @(Convert-ToArray (Get-JsonValue $ownerStatus "requiredEvidenceFiles" @()) | ForEach-Object { [string]$_ })
        presentFiles = @(Convert-ToArray (Get-JsonValue $inboxAreaStatus "presentFiles" @()) | ForEach-Object { [string]$_ })
        missingFiles = @(Convert-ToArray (Get-JsonValue $ownerStatus "missingFiles" @()) | ForEach-Object { [string]$_ })
        missingFileCount = Convert-ToInt (Get-JsonValue $ownerStatus "missingFileCount" 0)
        remainingBlockingReasons = @(Convert-ToArray (Get-JsonValue $ownerStatus "remainingBlockingReasons" @()) | ForEach-Object { [string]$_ })
        remainingBlockingReasonCount = Convert-ToInt (Get-JsonValue $ownerStatus "remainingBlockingReasonCount" 0)
        preflightCommand = [string](Get-JsonValue $ownerStatus "preflightCommand" "")
        acceptanceWrapperCommand = [string](Get-JsonValue $ownerStatus "acceptanceWrapperCommand" "")
        hardValidationCommand = [string](Get-JsonValue $ownerStatus "hardValidationCommand" "")
    }
}

$autoAcceptanceStatus = if ($autoAcceptanceManifestUsed) { [string](Get-JsonValue $autoAcceptanceManifest "status" "") } else { "" }
$autoAcceptanceContractFixtureMode = $autoAcceptanceManifestUsed -and (Convert-ToBool (Get-JsonValue $autoAcceptanceManifest "contractFixtureMode" $false))
$acceptanceRun = $autoAcceptanceManifestUsed -and (Convert-ToBool (Get-JsonValue $autoAcceptanceManifest "acceptanceRun" $false))
$semanticPreflightGatePassed = $autoAcceptanceManifestUsed -and (Convert-ToBool (Get-JsonValue $autoAcceptanceManifest "semanticPreflightGatePassed" $false))
$allExternalEvidenceAccepted = $autoAcceptanceManifestUsed -and (Convert-ToBool (Get-JsonValue $autoAcceptanceManifest "allExternalEvidenceAccepted" $false))
$realHostProjectEvidenceAccepted = $autoAcceptanceManifestUsed -and -not $autoAcceptanceContractFixtureMode -and (Convert-ToBool (Get-JsonValue $autoAcceptanceManifest "realHostProjectEvidenceAccepted" $false))
$externalEvidenceAccepted = $allExternalEvidenceAccepted -and $realHostProjectEvidenceAccepted

$checks = @()
Add-StatusCheck "handoff_status_source" `
    ((Get-JsonValue $handoffStatusManifest "schemaVersion" "") -eq "aitestpilot.production_handoff_status.v1" -and
        (Get-JsonValue $handoffStatusManifest "status" "") -eq "PASS") `
    "Production handoff status must be available before owner-return readiness can be summarized."
Add-StatusCheck "owner_response_bundle_contract_sources" `
    ((Get-JsonValue $ownerInputRequestPackManifest "status" "") -eq "PASS" -and
        (Get-JsonValue $ownerUnblockPackManifest "status" "") -eq "PASS" -and
        (Get-JsonValue $ownerResponseBundleKitManifest "status" "") -eq "PASS" -and
        (Get-JsonValue $actionQueueManifest "status" "") -eq "PASS") `
    "Owner request, unblock, response bundle kit, and action queue manifests must be available."
Add-StatusCheck "owner_return_status_math" `
    ((Convert-ToInt (Get-JsonValue $handoffStatusManifest "ownerPacketCount" 0)) -eq $ownerReturnStatuses.Count -and
        (Convert-ToInt (Get-JsonValue $handoffStatusManifest "acceptedOwnerPacketCount" 0)) +
        (Convert-ToInt (Get-JsonValue $handoffStatusManifest "pendingOwnerPacketCount" 0)) -eq $ownerReturnStatuses.Count) `
    "Owner packet counts must remain aligned with production handoff status."
Add-StatusCheck "owner_return_readiness_state" `
    ($ownerReturnReadinessStatus -in @("PENDING_EXTERNAL_EVIDENCE", "READY_FOR_AUTO_ACCEPTANCE_CANDIDATE", "NEEDS_OWNER_REPAIR", "OWNER_RETURN_STATUS_UNREADABLE")) `
    "Owner return readiness must map to a concrete operator state."
Add-StatusCheck "semantic_preflight_result" `
    ((-not $semanticPreflightRun) -or
        ($null -ne $semanticPreflightManifest -and
            -not (Convert-ToBool (Get-JsonValue $semanticPreflightManifest "acceptanceRun" $true)) -and
            -not (Convert-ToBool (Get-JsonValue $semanticPreflightManifest "hardValidationRun" $true)) -and
            -not (Convert-ToBool (Get-JsonValue $semanticPreflightManifest "emailSent" $true)))) `
    "Optional semantic preflight must stay read-only and produce a parseable manifest."
Add-StatusCheck "owner_return_input_source" `
    (($ownerReturnBundleSourceKind -in @(
            "none",
            "parameter:OwnerResponseBundleDir",
            "parameter:OwnerResponseBundleZipPath",
            "environment_variable:$ownerResponseBundleDirEnvironmentVariableName",
            "environment_variable:$ownerResponseBundleZipEnvironmentVariableName"
        )) -and
        (($ownerReturnBundleExplicitInputProvided -ne $ownerReturnBundleDiscoveredFromEnvironment) -or
            (-not $ownerReturnBundleExplicitInputProvided -and -not $ownerReturnBundleDiscoveredFromEnvironment))) `
    "Owner return bundle input source must be explicit, environment-discovered, or absent."
Add-StatusCheck "read_only_boundary" `
    (-not $acceptanceRun -and
        -not $realHostProjectEvidenceAccepted -and
        -not $externalEvidenceAccepted) `
    "Owner return status must not run acceptance or claim real host-project evidence."

$generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
$acceptedOwnerPacketCount = Convert-ToInt (Get-JsonValue $handoffStatusManifest "acceptedOwnerPacketCount" 0)
$pendingOwnerPacketCount = Convert-ToInt (Get-JsonValue $handoffStatusManifest "pendingOwnerPacketCount" 0)
$remainingMissingFileCount = Convert-ToInt (Get-JsonValue $handoffStatusManifest "remainingMissingFileCount" 0)
$remainingBlockingReasonCount = Convert-ToInt (Get-JsonValue $handoffStatusManifest "remainingBlockingReasonCount" 0)
$semanticPreflightCommand = Format-MarkdownCell (Get-JsonValue $actionQueueManifest "ownerResponseBundleSemanticPreflightCommand" "")
$semanticPreflightZipCommand = Format-MarkdownCell (Get-JsonValue $actionQueueManifest "ownerResponseBundleZipSemanticPreflightCommand" "")
$autoAcceptanceCommand = Format-MarkdownCell (Get-JsonValue $actionQueueManifest "ownerResponseBundleAutoAcceptanceCommand" "")
$autoAcceptanceZipCommand = Format-MarkdownCell (Get-JsonValue $actionQueueManifest "ownerResponseBundleZipAutoAcceptanceCommand" "")
$ownerResponseBundleZipEnvironmentVariable = Format-MarkdownCell (Get-JsonValue $actionQueueManifest "ownerResponseBundleZipEnvironmentVariable" "")
$ownerResponseBundleDirEnvironmentVariable = Format-MarkdownCell $ownerResponseBundleDirEnvironmentVariableName

$reportLines = @(
    "# Production External Evidence Owner Return Bundle Status",
    "",
    "Schema: ``aitestpilot.production_external_evidence_owner_return_bundle_status.v1``",
    "Generated at UTC: $generatedAtUtc",
    "",
    "## Summary",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Owner return readiness | $(Format-MarkdownCell $ownerReturnReadinessStatus) |",
    "| Next required action | $(Format-MarkdownCell $nextRequiredAction) |",
    "| Input kind | $(Format-MarkdownCell $ownerReturnBundleInputKind) |",
    "| Input source | $(Format-MarkdownCell $ownerReturnBundleSourceKind) |",
    "| Explicit input provided | $ownerReturnBundleExplicitInputProvided |",
    "| Environment input discovered | $ownerReturnBundleDiscoveredFromEnvironment |",
    "| Semantic preflight run | $semanticPreflightRun |",
    "| Semantic preflight status | $(Format-MarkdownCell $semanticPreflightStatus) |",
    "| Ready for auto acceptance candidate | $readyForAcceptanceCandidate |",
    "| Missing required files | $missingRequiredFileCount |",
    "| Semantic fail count | $semanticFailCount |",
    "| Payload shape violations | $ownerResponseBundlePayloadShapeViolationCount |",
    "| Accepted owner packets | $acceptedOwnerPacketCount |",
    "| Pending owner packets | $pendingOwnerPacketCount |",
    "| Remaining missing files | $remainingMissingFileCount |",
    "| Remaining blockers | $remainingBlockingReasonCount |",
    "| Acceptance run | $acceptanceRun |",
    "| Real host-project evidence accepted | $realHostProjectEvidenceAccepted |",
    "",
    "## Owner Areas",
    "",
    "| Owner | Area | Missing | Present | Blockers | Next command |",
    "| --- | --- | --- | --- | --- | --- |"
)
foreach ($ownerReturnStatus in $ownerReturnStatuses) {
    $ownerCell = Format-MarkdownCell (Get-JsonValue $ownerReturnStatus "owner" "")
    $areaCell = Format-MarkdownCell (Get-JsonValue $ownerReturnStatus "area" "")
    $missingCell = Format-MarkdownCell (Join-MarkdownList @(Get-JsonValue $ownerReturnStatus "missingFiles" @()))
    $presentCell = Format-MarkdownCell (Join-MarkdownList @(Get-JsonValue $ownerReturnStatus "presentFiles" @()))
    $blockersCell = Format-MarkdownCell (Join-MarkdownList @(Get-JsonValue $ownerReturnStatus "remainingBlockingReasons" @()))
    $nextCommandCell = Format-MarkdownCell (Get-JsonValue $ownerReturnStatus "acceptanceWrapperCommand" "")
    $reportLines += "| $ownerCell | $areaCell | $missingCell | $presentCell | $blockersCell | $nextCommandCell |"
}
$reportLines += @(
    "",
    "## Commands",
    "",
    "- Semantic preflight: $semanticPreflightCommand",
    "- Semantic preflight zip: $semanticPreflightZipCommand",
    "- Auto acceptance: $autoAcceptanceCommand",
    "- Auto acceptance zip: $autoAcceptanceZipCommand",
    "- Zip env var: $ownerResponseBundleZipEnvironmentVariable",
    "- Dir env var: $ownerResponseBundleDirEnvironmentVariable",
    "",
    "## Boundary",
    "",
    "- This status artifact is read-only.",
    "- It may run semantic preflight for a supplied owner bundle, but it does not run auto acceptance or hard validation.",
    "- Real production completion still requires non-fixture external evidence acceptance and hard validation."
)
$reportText = [string]::Join([Environment]::NewLine, $reportLines) + [Environment]::NewLine
$reportContentValidated = $reportText.Contains("Production External Evidence Owner Return Bundle Status") -and
    $reportText.Contains("Owner return readiness") -and
    $reportText.Contains("Real production completion") -and
    -not $reportText.Contains("System.Collections") -and
    -not $reportText.Contains("@{")

New-Item -ItemType Directory -Force (Split-Path $reportFullPath -Parent) | Out-Null
$reportText | Set-Content -Path $reportFullPath -Encoding UTF8
Add-StatusCheck "status_report_content" ([bool]$reportContentValidated) "Owner return status report must be readable and preserve production boundaries."

$failedChecks = @($checks | Where-Object { -not (Convert-ToBool (Get-JsonValue $_ "passed" $false)) })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestFullPath),
    (Convert-ToEvidenceRelativePath $reportFullPath)
)
if ($semanticPreflightRun) {
    foreach ($generated in @($semanticPreflightManifestPath, $semanticPreflightReportPath, $semanticPreflightOutputPath)) {
        if (Test-Path $generated) {
            $generatedFiles += (Convert-ToEvidenceRelativePath $generated)
        }
    }
}
$generatedFiles = @($generatedFiles | Sort-Object -Unique)

$sourceFiles = @(
    "production-handoff-status-manifest.json",
    "production-external-evidence-inbox-manifest.json",
    "production-handoff-owner-input-request-pack-manifest.json",
    "production-handoff-owner-unblock-pack-manifest.json",
    "production-handoff-owner-response-bundle-kit-manifest.json",
    "production-external-evidence-action-queue-manifest.json"
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_external_evidence_owner_return_bundle_status.v1"
    status = $status
    generatedAtUtc = $generatedAtUtc
    evidenceBundleDir = $evidenceBundlePath
    readOnly = $true
    reportPath = $reportFullPath
    reportGenerated = (Test-Path $reportFullPath)
    reportContentValidated = [bool]$reportContentValidated
    ownerReturnReadinessStatus = $ownerReturnReadinessStatus
    nextRequiredAction = $nextRequiredAction
    ownerReturnBundleInputKind = $ownerReturnBundleInputKind
    ownerReturnBundleSourceKind = $ownerReturnBundleSourceKind
    ownerReturnBundleExplicitInputProvided = [bool]$ownerReturnBundleExplicitInputProvided
    ownerReturnBundleDiscoveredFromEnvironment = [bool]$ownerReturnBundleDiscoveredFromEnvironment
    ownerReturnBundlePath = $ownerReturnBundlePath
    ownerReturnBundleUnderRepo = [bool]$ownerReturnBundleUnderRepo
    ownerReturnBundleRootResolved = [bool]$ownerReturnBundleRootResolved
    ownerReturnBundleRootResolutionKind = $ownerReturnBundleRootResolutionKind
    ownerReturnBundleResolvedRoot = $ownerReturnBundleResolvedRoot
    ownerReturnBundleZipInspected = [bool]$ownerReturnBundleZipInspected
    ownerReturnBundleZipSafe = [bool]$ownerReturnBundleZipSafe
    ownerReturnBundleZipEntryCount = [int]$ownerReturnBundleZipEntryCount
    ownerReturnBundleZipUnsafeEntryCount = [int]$ownerReturnBundleZipUnsafeEntryCount
    ownerReturnBundleZipDuplicateEntryCount = [int]$ownerReturnBundleZipDuplicateEntryCount
    ownerResponseBundleStrictPayloadShape = [bool]$ownerResponseBundleStrictPayloadShape
    ownerResponseBundlePayloadShapeViolationCount = [int]$ownerResponseBundlePayloadShapeViolationCount
    semanticPreflightRun = [bool]$semanticPreflightRun
    semanticPreflightManifestPath = if ($semanticPreflightRun -and (Test-Path $semanticPreflightManifestPath)) { Convert-ToEvidenceRelativePath $semanticPreflightManifestPath } else { "" }
    semanticPreflightReportPath = if ($semanticPreflightRun -and (Test-Path $semanticPreflightReportPath)) { Convert-ToEvidenceRelativePath $semanticPreflightReportPath } else { "" }
    semanticPreflightStatus = $semanticPreflightStatus
    readyForAcceptanceCandidate = [bool]$readyForAcceptanceCandidate
    readyForAutoAcceptanceCandidate = [bool]$readyForAcceptanceCandidate
    requiredEvidenceFileCount = Convert-ToInt (Get-JsonValue $ownerResponseBundleKitManifest "requiredEvidenceFileCount" 0)
    presentRequiredFileCount = [int]$presentRequiredFileCount
    missingRequiredFileCount = [int]$missingRequiredFileCount
    semanticFailCount = [int]$semanticFailCount
    semanticWarnCount = [int]$semanticWarnCount
    autoAcceptanceManifestUsed = [bool]$autoAcceptanceManifestUsed
    autoAcceptanceStatus = $autoAcceptanceStatus
    acceptanceRun = [bool]$acceptanceRun
    hardValidationRun = $false
    semanticPreflightGatePassed = [bool]$semanticPreflightGatePassed
    allExternalEvidenceAccepted = [bool]$allExternalEvidenceAccepted
    externalEvidenceAccepted = [bool]$externalEvidenceAccepted
    realAcceptanceManifestUsed = $false
    realHostProjectEvidenceAccepted = [bool]$realHostProjectEvidenceAccepted
    releasePipelineSendsEmail = $false
    emailSent = $false
    confirmationTokenCreated = $false
    releasePipelineUsesFixture = $false
    fixtureEvidencePromoted = $false
    ownerInputRequestStatus = [string](Get-JsonValue $ownerInputRequestPackManifest "ownerInputRequestStatus" "")
    ownerUnblockStatus = [string](Get-JsonValue $ownerUnblockPackManifest "ownerUnblockStatus" "")
    ownerPacketCount = Convert-ToInt (Get-JsonValue $handoffStatusManifest "ownerPacketCount" 0)
    acceptedOwnerPacketCount = [int]$acceptedOwnerPacketCount
    pendingOwnerPacketCount = [int]$pendingOwnerPacketCount
    remainingMissingFileCount = [int]$remainingMissingFileCount
    remainingBlockingReasonCount = [int]$remainingBlockingReasonCount
    externalEvidenceCollectionComplete = Convert-ToBool (Get-JsonValue $handoffStatusManifest "externalEvidenceCollectionComplete" $false)
    ownerResponseBundleSemanticPreflightCommand = [string](Get-JsonValue $actionQueueManifest "ownerResponseBundleSemanticPreflightCommand" "")
    ownerResponseBundleZipSemanticPreflightCommand = [string](Get-JsonValue $actionQueueManifest "ownerResponseBundleZipSemanticPreflightCommand" "")
    ownerResponseBundleAutoAcceptanceCommand = [string](Get-JsonValue $actionQueueManifest "ownerResponseBundleAutoAcceptanceCommand" "")
    ownerResponseBundleZipAutoAcceptanceCommand = [string](Get-JsonValue $actionQueueManifest "ownerResponseBundleZipAutoAcceptanceCommand" "")
    ownerResponseBundleZipEnvironmentVariable = [string](Get-JsonValue $actionQueueManifest "ownerResponseBundleZipEnvironmentVariable" "")
    ownerResponseBundleDirEnvironmentVariable = $ownerResponseBundleDirEnvironmentVariableName
    ownerReturnStatuses = @($ownerReturnStatuses)
    productionOutputBoundary = "owner_return_bundle_status_only"
    sourceFiles = @($sourceFiles)
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles + $sourceFiles)
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
}

New-Item -ItemType Directory -Force (Split-Path $manifestFullPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 14 | Set-Content -Path $manifestFullPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Production external evidence owner return bundle status failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production external evidence owner return bundle status manifest: $manifestFullPath"
Write-Output "Production external evidence owner return bundle status report: $reportFullPath"
Write-Output "PASS AI TestPilot production external evidence owner return bundle status"
