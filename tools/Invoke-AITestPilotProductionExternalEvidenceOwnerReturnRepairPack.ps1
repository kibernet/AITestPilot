[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$SemanticPreflightManifestPath,
    [string]$RepairPackDir,
    [string]$ManifestPath,
    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}
if ([string]::IsNullOrWhiteSpace($SemanticPreflightManifestPath)) {
    $SemanticPreflightManifestPath = Join-Path $EvidenceBundleDir "production-external-evidence-semantic-preflight-manifest.json"
}
if ([string]::IsNullOrWhiteSpace($RepairPackDir)) {
    $RepairPackDir = Join-Path $EvidenceBundleDir "production-external-evidence-owner-return-repair-pack"
}
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-external-evidence-owner-return-repair-pack-manifest.json"
}
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-external-evidence-owner-return-repair-pack.md"
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
    $fullRoot = (Resolve-FullPath $Root).TrimEnd([char[]]@("\", "/"))
    return $fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($fullRoot + "\", [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($fullRoot + "/", [System.StringComparison]::OrdinalIgnoreCase)
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

    return $fullPath.Substring($evidenceBundlePath.Length).TrimStart([char[]]@("\", "/")).Replace("\", "/")
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

function Get-RepairCategory {
    param([string]$Reason)

    if ($Reason -match "root_unresolved|zip") {
        return "zip_or_root_resolution"
    }
    if ($Reason -match "missing") {
        return "add_required_file"
    }
    if ($Reason -match "extra|nested|unsafe|duplicate|traversal|absolute") {
        return "remove_or_flatten_payload"
    }
    if ($Reason -match "fixture|template|placeholder|sample") {
        return "regenerate_real_host_project_evidence"
    }

    return "repair_manifest_field"
}

function Get-RepairPriority {
    param([string]$Category)

    switch ($Category) {
        "zip_or_root_resolution" { return 10 }
        "remove_or_flatten_payload" { return 20 }
        "add_required_file" { return 30 }
        "regenerate_real_host_project_evidence" { return 40 }
        default { return 50 }
    }
}

function Get-RepairInstruction {
    param(
        [string]$Reason,
        [string]$OwnerHint
    )

    if (-not [string]::IsNullOrWhiteSpace($OwnerHint)) {
        return $OwnerHint
    }
    if ($Reason -match "missing") {
        return "Add the required evidence file to the listed owner response bundle area and rerun semantic preflight."
    }
    if ($Reason -match "extra|nested") {
        return "Remove unknown payload or move required evidence files to the evidence area root, then rerun semantic preflight."
    }
    if ($Reason -match "unsafe|duplicate|traversal|absolute") {
        return "Regenerate the owner response bundle zip without unsafe, duplicate, absolute, or traversal entries."
    }

    return "Repair the listed file or field and rerun owner-return status, semantic preflight, then acceptance only if candidate-ready."
}

function Add-RepairCheck {
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
$semanticManifestFullPath = Assert-PathUnderRepo $SemanticPreflightManifestPath "SemanticPreflightManifestPath"
$repairPackPath = Assert-PathUnderRepo $RepairPackDir "RepairPackDir"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"

if (-not (Test-PathWithinRoot $repairPackPath $evidenceBundlePath)) {
    throw "RepairPackDir must stay under EvidenceBundleDir: $repairPackPath"
}
if (-not (Test-PathWithinRoot $manifestFullPath $evidenceBundlePath)) {
    throw "ManifestPath must stay under EvidenceBundleDir: $manifestFullPath"
}
if (-not (Test-PathWithinRoot $reportFullPath $evidenceBundlePath)) {
    throw "ReportPath must stay under EvidenceBundleDir: $reportFullPath"
}

if (Test-Path $repairPackPath) {
    Remove-Item -LiteralPath $repairPackPath -Recurse -Force
}
New-Item -ItemType Directory -Force $repairPackPath | Out-Null

$semanticManifest = Read-JsonFile $semanticManifestFullPath "Semantic preflight manifest"
$actionItems = @(Convert-ToArray (Get-JsonValue $semanticManifest "actionItems" @()))
$areaStatuses = @(Convert-ToArray (Get-JsonValue $semanticManifest "areaStatuses" @()))
$payloadShapeViolations = @(Convert-ToArray (Get-JsonValue $semanticManifest "ownerResponseBundlePayloadShapeViolations" @()))

$repairItems = @()
$seenRepairKeys = @{}
foreach ($item in $actionItems) {
    $severity = [string](Get-JsonValue $item "severity" "")
    if ($severity -ne "FAIL" -and $severity -ne "WARN") {
        continue
    }

    $area = [string](Get-JsonValue $item "area" "")
    $owner = [string](Get-JsonValue $item "owner" "")
    $file = [string](Get-JsonValue $item "file" "")
    $field = [string](Get-JsonValue $item "field" "")
    $reason = [string](Get-JsonValue $item "reason" "")
    $ownerHint = [string](Get-JsonValue $item "ownerHint" "")
    $category = Get-RepairCategory $reason
    $key = "$area|$owner|$file|$field|$reason"
    if ($seenRepairKeys.ContainsKey($key)) {
        continue
    }
    $seenRepairKeys[$key] = $true

    $repairItems += [ordered]@{
        area = $area
        owner = $owner
        file = $file
        field = $field
        severity = $severity
        reason = $reason
        category = $category
        priority = Get-RepairPriority $category
        ownerHint = $ownerHint
        repairInstruction = Get-RepairInstruction $reason $ownerHint
        rerunOrder = "owner_return_status_then_semantic_preflight_then_auto_acceptance_only_if_candidate_ready"
    }
}

foreach ($violation in $payloadShapeViolations) {
    $area = [string](Get-JsonValue $violation "area" "external_evidence_bundle")
    $owner = [string](Get-JsonValue $violation "owner" "operator")
    $path = [string](Get-JsonValue $violation "path" "")
    $reason = [string](Get-JsonValue $violation "reason" "")
    $category = Get-RepairCategory $reason
    $key = "$area|$owner|$path|OwnerResponseBundleDir|$reason"
    if ($seenRepairKeys.ContainsKey($key)) {
        continue
    }
    $seenRepairKeys[$key] = $true

    $instruction = Get-RepairInstruction $reason ""
    $repairItems += [ordered]@{
        area = $area
        owner = $owner
        file = $path
        field = "OwnerResponseBundleDir"
        severity = "FAIL"
        reason = $reason
        category = $category
        priority = Get-RepairPriority $category
        ownerHint = $instruction
        repairInstruction = $instruction
        rerunOrder = "owner_return_status_then_semantic_preflight_then_auto_acceptance_only_if_candidate_ready"
    }
}

$ownerRepairRoutes = @()
foreach ($areaStatus in $areaStatuses) {
    $missingFiles = @(Convert-ToArray (Get-JsonValue $areaStatus "missingFiles" @()) | ForEach-Object { [string]$_ })
    $extraFiles = @(Convert-ToArray (Get-JsonValue $areaStatus "extraFiles" @()) | ForEach-Object { [string]$_ })
    $failCount = Convert-ToInt (Get-JsonValue $areaStatus "failFindingCount" 0)
    $warnCount = Convert-ToInt (Get-JsonValue $areaStatus "warnFindingCount" 0)
    if ($missingFiles.Count -eq 0 -and $extraFiles.Count -eq 0 -and $failCount -eq 0 -and $warnCount -eq 0) {
        continue
    }

    $area = [string](Get-JsonValue $areaStatus "area" "")
    $owner = [string](Get-JsonValue $areaStatus "owner" "")
    $directory = [string](Get-JsonValue $areaStatus "directory" "")
    $routeItems = @($repairItems | Where-Object { [string](Get-JsonValue $_ "area" "") -eq $area -and [string](Get-JsonValue $_ "owner" "") -eq $owner })

    $ownerRepairRoutes += [ordered]@{
        owner = $owner
        area = $area
        directory = $directory
        semanticStatus = [string](Get-JsonValue $areaStatus "semanticStatus" "")
        missingFiles = @($missingFiles)
        extraFiles = @($extraFiles)
        failFindingCount = [int]$failCount
        warnFindingCount = [int]$warnCount
        repairItemCount = [int]$routeItems.Count
        ownerHint = [string](Get-JsonValue $areaStatus "ownerHint" "")
    }
}

$repairJsonPath = Join-Path $repairPackPath "owner-return-repair-items.json"
$repairReadmePath = Join-Path $repairPackPath "README.md"

$semanticPreflightStatus = [string](Get-JsonValue $semanticManifest "semanticPreflightStatus" "")
$readyForAcceptanceCandidate = Convert-ToBool (Get-JsonValue $semanticManifest "readyForAcceptanceCandidate" $false)
$semanticFailCount = Convert-ToInt (Get-JsonValue $semanticManifest "semanticFailCount" 0)
$semanticWarnCount = Convert-ToInt (Get-JsonValue $semanticManifest "semanticWarnCount" 0)
$missingRequiredFileCount = Convert-ToInt (Get-JsonValue $semanticManifest "missingRequiredFileCount" 0)
$payloadShapeViolationCount = Convert-ToInt (Get-JsonValue $semanticManifest "ownerResponseBundlePayloadShapeViolationCount" 0)
$readOnly = Convert-ToBool (Get-JsonValue $semanticManifest "readOnly" $false)
$acceptanceRun = Convert-ToBool (Get-JsonValue $semanticManifest "acceptanceRun" $true)
$hardValidationRun = Convert-ToBool (Get-JsonValue $semanticManifest "hardValidationRun" $true)
$emailSent = Convert-ToBool (Get-JsonValue $semanticManifest "emailSent" $true)
$realHostProjectEvidenceAccepted = Convert-ToBool (Get-JsonValue $semanticManifest "realHostProjectEvidenceAccepted" $true)
$externalEvidenceAccepted = Convert-ToBool (Get-JsonValue $semanticManifest "externalEvidenceAccepted" $true)
$fixtureEvidencePromoted = Convert-ToBool (Get-JsonValue $semanticManifest "fixtureEvidencePromoted" $true)
$releasePipelineSendsEmail = Convert-ToBool (Get-JsonValue $semanticManifest "releasePipelineSendsEmail" $true)

$zipOrRootRepairItemCount = @($repairItems | Where-Object { [string](Get-JsonValue $_ "category" "") -eq "zip_or_root_resolution" }).Count
$missingFileRepairItemCount = @($repairItems | Where-Object { [string](Get-JsonValue $_ "category" "") -eq "add_required_file" }).Count
$semanticRepairItemCount = @($repairItems | Where-Object { [string](Get-JsonValue $_ "category" "") -ne "add_required_file" -and [string](Get-JsonValue $_ "category" "") -ne "remove_or_flatten_payload" -and [string](Get-JsonValue $_ "category" "") -ne "zip_or_root_resolution" }).Count
$payloadShapeRepairItemCount = @($repairItems | Where-Object { [string](Get-JsonValue $_ "category" "") -eq "remove_or_flatten_payload" }).Count

$checks = @()
Add-RepairCheck "semantic_preflight_manifest_readable" `
    ((Get-JsonValue $semanticManifest "status" "") -eq "PASS" -and -not [string]::IsNullOrWhiteSpace($semanticPreflightStatus)) `
    "Repair pack must be based on a PASS semantic preflight manifest with an explicit semanticPreflightStatus."
Add-RepairCheck "repair_items_cover_non_ready_preflight" `
    (($readyForAcceptanceCandidate -and $repairItems.Count -eq 0) -or ((-not $readyForAcceptanceCandidate) -and $repairItems.Count -gt 0)) `
    "Non-candidate owner returns must produce owner-facing repair items."
Add-RepairCheck "repair_items_have_owner_hints" `
    (@($repairItems | Where-Object { [string]::IsNullOrWhiteSpace([string](Get-JsonValue $_ "repairInstruction" "")) }).Count -eq 0) `
    "Every repair item must include an owner-facing repair instruction."
Add-RepairCheck "read_only_boundaries_preserved" `
    ($readOnly -and -not $acceptanceRun -and -not $hardValidationRun -and -not $emailSent -and -not $realHostProjectEvidenceAccepted -and -not $externalEvidenceAccepted -and -not $fixtureEvidencePromoted -and -not $releasePipelineSendsEmail) `
    "Repair pack generation must preserve semantic preflight read-only/no-send/no-acceptance boundaries."
Add-RepairCheck "acceptance_still_gated" `
    ((-not $readyForAcceptanceCandidate) -or $repairItems.Count -eq 0) `
    "Repair pack must not produce repair items for candidate-ready owner returns."

$failedChecks = @($checks | Where-Object { -not [bool](Get-JsonValue $_ "passed" $false) })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }
$generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")

$repairJson = [ordered]@{
    schemaVersion = "aitestpilot.production_external_evidence_owner_return_repair_items.v1"
    status = $status
    generatedAtUtc = $generatedAtUtc
    semanticPreflightManifest = Convert-ToEvidenceRelativePath $semanticManifestFullPath
    semanticPreflightStatus = $semanticPreflightStatus
    readyForAcceptanceCandidate = [bool]$readyForAcceptanceCandidate
    repairItemCount = [int]$repairItems.Count
    ownerRepairRouteCount = [int]$ownerRepairRoutes.Count
    zipOrRootRepairItemCount = [int]$zipOrRootRepairItemCount
    missingFileRepairItemCount = [int]$missingFileRepairItemCount
    semanticRepairItemCount = [int]$semanticRepairItemCount
    payloadShapeRepairItemCount = [int]$payloadShapeRepairItemCount
    repairItems = @($repairItems)
    ownerRepairRoutes = @($ownerRepairRoutes)
}
$repairJson | ConvertTo-Json -Depth 14 | Set-Content -Path $repairJsonPath -Encoding UTF8

$repairReadmeLines = @(
    "# Owner Return Repair Pack",
    "",
    "Status: $status",
    "Semantic preflight status: $semanticPreflightStatus",
    "Ready for acceptance candidate: $readyForAcceptanceCandidate",
    "",
    "## Rerun Order",
    "",
    "1. Repair the listed files or payload shape issues.",
    "2. Rerun owner-return status.",
    "3. Rerun semantic preflight.",
    "4. Run auto acceptance only if semantic preflight reports candidate-ready with zero semantic failures.",
    "",
    "## Repair Items",
    "",
    "| Owner | Area | File | Field | Reason | Instruction |",
    "| --- | --- | --- | --- | --- | --- |"
)
foreach ($item in $repairItems) {
    $repairReadmeLines += "| $(Format-MarkdownCell (Get-JsonValue $item 'owner' '')) | $(Format-MarkdownCell (Get-JsonValue $item 'area' '')) | $(Format-MarkdownCell (Get-JsonValue $item 'file' '')) | $(Format-MarkdownCell (Get-JsonValue $item 'field' '')) | $(Format-MarkdownCell (Get-JsonValue $item 'reason' '')) | $(Format-MarkdownCell (Get-JsonValue $item 'repairInstruction' '')) |"
}
$repairReadmeLines | Set-Content -Path $repairReadmePath -Encoding UTF8

$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestFullPath),
    (Convert-ToEvidenceRelativePath $reportFullPath),
    (Convert-ToEvidenceRelativePath $repairJsonPath),
    (Convert-ToEvidenceRelativePath $repairReadmePath)
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_external_evidence_owner_return_repair_pack.v1"
    status = $status
    generatedAtUtc = $generatedAtUtc
    evidenceBundleDir = $evidenceBundlePath
    semanticPreflightManifest = Convert-ToEvidenceRelativePath $semanticManifestFullPath
    semanticPreflightStatus = $semanticPreflightStatus
    readyForAcceptanceCandidate = [bool]$readyForAcceptanceCandidate
    semanticFailCount = [int]$semanticFailCount
    semanticWarnCount = [int]$semanticWarnCount
    missingRequiredFileCount = [int]$missingRequiredFileCount
    ownerResponseBundlePayloadShapeViolationCount = [int]$payloadShapeViolationCount
    repairItemCount = [int]$repairItems.Count
    ownerRepairRouteCount = [int]$ownerRepairRoutes.Count
    zipOrRootRepairItemCount = [int]$zipOrRootRepairItemCount
    missingFileRepairItemCount = [int]$missingFileRepairItemCount
    semanticRepairItemCount = [int]$semanticRepairItemCount
    payloadShapeRepairItemCount = [int]$payloadShapeRepairItemCount
    readOnly = [bool]$readOnly
    acceptanceRun = [bool]$acceptanceRun
    hardValidationRun = [bool]$hardValidationRun
    emailSent = [bool]$emailSent
    releasePipelineSendsEmail = [bool]$releasePipelineSendsEmail
    realHostProjectEvidenceAccepted = [bool]$realHostProjectEvidenceAccepted
    externalEvidenceAccepted = [bool]$externalEvidenceAccepted
    fixtureEvidencePromoted = [bool]$fixtureEvidencePromoted
    nextRequiredAction = "repair_owner_response_bundle_then_rerun_status_and_semantic_preflight"
    productionOutputBoundary = "owner_return_repair_pack_read_only"
    repairPackDir = Convert-ToEvidenceRelativePath $repairPackPath
    repairItems = @($repairItems)
    ownerRepairRoutes = @($ownerRepairRoutes)
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
    sourceFiles = @((Convert-ToEvidenceRelativePath $semanticManifestFullPath))
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles)
}

$manifest | ConvertTo-Json -Depth 14 | Set-Content -Path $manifestFullPath -Encoding UTF8

$reportLines = @(
    "# Production External Evidence Owner Return Repair Pack",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Status | $(Format-MarkdownCell $status) |",
    "| Semantic preflight status | $(Format-MarkdownCell $semanticPreflightStatus) |",
    "| Ready for acceptance candidate | $readyForAcceptanceCandidate |",
    "| Repair items | $($repairItems.Count) |",
    "| Owner repair routes | $($ownerRepairRoutes.Count) |",
    "| Zip/root repairs | $zipOrRootRepairItemCount |",
    "| Missing-file repairs | $missingFileRepairItemCount |",
    "| Semantic repairs | $semanticRepairItemCount |",
    "| Payload-shape repairs | $payloadShapeRepairItemCount |",
    "",
    "## Owner Routes",
    "",
    "| Owner | Area | Directory | Missing | Fails | Warnings | Hint |",
    "| --- | --- | --- | --- | ---: | ---: | --- |"
)
foreach ($route in $ownerRepairRoutes) {
    $reportLines += "| $(Format-MarkdownCell (Get-JsonValue $route 'owner' '')) | $(Format-MarkdownCell (Get-JsonValue $route 'area' '')) | $(Format-MarkdownCell (Get-JsonValue $route 'directory' '')) | $(Format-MarkdownCell (Join-TextList @(Get-JsonValue $route 'missingFiles' @()))) | $(Get-JsonValue $route 'failFindingCount' 0) | $(Get-JsonValue $route 'warnFindingCount' 0) | $(Format-MarkdownCell (Get-JsonValue $route 'ownerHint' '')) |"
}
$reportLines += @(
    "",
    "## Repair Items",
    "",
    "| Owner | Area | File | Field | Reason | Instruction |",
    "| --- | --- | --- | --- | --- | --- |"
)
foreach ($item in $repairItems) {
    $reportLines += "| $(Format-MarkdownCell (Get-JsonValue $item 'owner' '')) | $(Format-MarkdownCell (Get-JsonValue $item 'area' '')) | $(Format-MarkdownCell (Get-JsonValue $item 'file' '')) | $(Format-MarkdownCell (Get-JsonValue $item 'field' '')) | $(Format-MarkdownCell (Get-JsonValue $item 'reason' '')) | $(Format-MarkdownCell (Get-JsonValue $item 'repairInstruction' '')) |"
}
$reportLines += @(
    "",
    "## Boundary",
    "",
    "- This repair pack is read-only.",
    "- It does not send email, accept returned evidence, run hard validation, or promote fixture evidence.",
    "- Auto acceptance remains gated on candidate-ready semantic preflight with zero semantic failures."
)
$reportLines | Set-Content -Path $reportFullPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Owner return repair pack failed: $($failedChecks.name -join ', ')"
}

Write-Output "Owner return repair pack manifest: $manifestFullPath"
Write-Output "Owner return repair pack report: $reportFullPath"
Write-Output "PASS AI TestPilot owner return repair pack"
