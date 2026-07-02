[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ManifestPath,
    [string]$ReportPath,
    [string]$AcceptanceManifestPath
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
    $ManifestPath = Join-Path $EvidenceBundleDir "production-handoff-status-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-handoff-status.md"
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

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) {
        return $null
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

function Join-MarkdownList {
    param([object[]]$Values)

    $items = @($Values | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($items.Count -eq 0) {
        return "(none)"
    }

    return [string]::Join(", ", $items)
}

function Get-AreaAcceptance {
    param(
        [object]$AcceptanceManifest,
        [string]$Area
    )

    $hasRealAcceptanceManifest = $null -ne $AcceptanceManifest -and
        (Get-JsonValue $AcceptanceManifest "schemaVersion" "") -eq "aitestpilot.production_external_evidence_acceptance.v1" -and
        -not (Convert-ToBool (Get-JsonValue $AcceptanceManifest "contractFixtureMode" $true))

    if (-not $hasRealAcceptanceManifest) {
        return [ordered]@{
            accepted = $false
            filesPresent = $false
            missingFileCount = -1
            missingFiles = @()
            evidencePath = ""
        }
    }

    $acceptedProperty = switch ($Area) {
        "production_driver_binding" { "productionDriverEvidenceAccepted" }
        "production_lua_patch_evidence" { "productionLuaEvidenceAccepted" }
        "live_model_endpoint_smoke" { "liveModelSmokeEvidenceAccepted" }
        default { "" }
    }
    $evidenceProperty = switch ($Area) {
        "production_driver_binding" { "productionDriverEvidence" }
        "production_lua_patch_evidence" { "productionLuaEvidence" }
        "live_model_endpoint_smoke" { "liveModelEndpointEvidence" }
        default { "" }
    }

    $evidence = if ([string]::IsNullOrWhiteSpace($evidenceProperty)) { $null } else { Get-JsonValue $AcceptanceManifest $evidenceProperty $null }

    return [ordered]@{
        accepted = (Convert-ToBool (Get-JsonValue $AcceptanceManifest $acceptedProperty $false))
        filesPresent = (Convert-ToBool (Get-JsonValue $evidence "allPresent" $false))
        missingFileCount = (Convert-ToInt (Get-JsonValue $evidence "missingFileCount" -1))
        missingFiles = @(Convert-ToArray (Get-JsonValue $evidence "missingFiles" @()) | ForEach-Object { [string]$_ })
        evidencePath = [string](Get-JsonValue $evidence "path" "")
    }
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

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

$handoffManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-package-manifest.json") "Production handoff package manifest"
$ownerPacketIndex = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-package\owner-packets\owner-packet-index.json") "Production handoff owner packet index"
$blockerResolutionMap = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-package\blocker-resolution-map.json") "Production handoff blocker-resolution map"
$requiredEvidence = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-package\required-external-evidence.json") "Production handoff required evidence"
$handoffExportManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-export-manifest.json") "Production handoff export manifest"
$contractProbeManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-external-evidence-acceptance-contract-probe-manifest.json") "Production external evidence acceptance contract probe manifest"
$failureProbeManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-external-evidence-acceptance-failure-probe-manifest.json") "Production external evidence acceptance failure probe manifest"

if ([string]::IsNullOrWhiteSpace($AcceptanceManifestPath)) {
    $candidateAcceptancePath = Join-Path $evidenceBundlePath "production-external-evidence-acceptance-manifest.json"
    if (Test-Path $candidateAcceptancePath) {
        $AcceptanceManifestPath = $candidateAcceptancePath
    }
}

$acceptanceManifest = Read-OptionalJsonFile $AcceptanceManifestPath
$hasAcceptanceManifest = $null -ne $acceptanceManifest
$usesRealAcceptanceManifest = $hasAcceptanceManifest -and
    (Get-JsonValue $acceptanceManifest "schemaVersion" "") -eq "aitestpilot.production_external_evidence_acceptance.v1" -and
    -not (Convert-ToBool (Get-JsonValue $acceptanceManifest "contractFixtureMode" $true))

$ownerStatuses = @()
foreach ($packet in @(Convert-ToArray $ownerPacketIndex.packets)) {
    $area = [string](Get-JsonValue $packet "area" "")
    $acceptance = Get-AreaAcceptance $acceptanceManifest $area
    $accepted = Convert-ToBool (Get-JsonValue $acceptance "accepted" $false)
    $remainingReasons = @(Convert-ToArray (Get-JsonValue $packet "remainingBlockingReasons" @()) | ForEach-Object { [string]$_ })
    $remainingReasonCount = if ($accepted) { 0 } else { [int]$remainingReasons.Count }
    $status = if ($accepted) {
        "ACCEPTED_EXTERNAL_EVIDENCE"
    } elseif (Convert-ToBool (Get-JsonValue $acceptance "filesPresent" $false)) {
        "EVIDENCE_FILES_PRESENT_NOT_ACCEPTED"
    } else {
        [string](Get-JsonValue $packet "status" "PENDING_EXTERNAL_EVIDENCE")
    }

    $ownerStatuses += [ordered]@{
        owner = [string](Get-JsonValue $packet "owner" "")
        area = $area
        status = $status
        packetPath = [string](Get-JsonValue $packet "packetPath" "")
        evidencePath = [string](Get-JsonValue $acceptance "evidencePath" "")
        requiredEvidenceFiles = @(Convert-ToArray (Get-JsonValue $packet "requiredEvidenceFiles" @()) | ForEach-Object { [string]$_ })
        evidenceFilesPresent = (Convert-ToBool (Get-JsonValue $acceptance "filesPresent" $false))
        missingFileCount = (Convert-ToInt (Get-JsonValue $acceptance "missingFileCount" -1))
        missingFiles = @(Convert-ToArray (Get-JsonValue $acceptance "missingFiles" @()) | ForEach-Object { [string]$_ })
        acceptedExternalEvidence = [bool]$accepted
        remainingBlockingReasonCount = [int]$remainingReasonCount
        remainingBlockingReasons = if ($accepted) { @() } else { @($remainingReasons) }
        preflightCommand = [string](Get-JsonValue $packet "preflightCommand" "")
        acceptanceWrapperCommand = [string](Get-JsonValue $packet "acceptanceWrapperCommand" "")
        hardValidationCommand = [string](Get-JsonValue $packet "hardValidationCommand" "")
    }
}

$acceptedOwnerPacketCount = @($ownerStatuses | Where-Object { Convert-ToBool (Get-JsonValue $_ "acceptedExternalEvidence" $false) }).Count
$pendingOwnerPacketCount = @($ownerStatuses | Where-Object { -not (Convert-ToBool (Get-JsonValue $_ "acceptedExternalEvidence" $false)) }).Count
$remainingBlockingReasonCountMeasure = @($ownerStatuses | ForEach-Object { Convert-ToInt (Get-JsonValue $_ "remainingBlockingReasonCount" 0) } | Measure-Object -Sum)
$remainingBlockingReasonCount = if ($null -eq $remainingBlockingReasonCountMeasure.Sum) { 0 } else { [int]$remainingBlockingReasonCountMeasure.Sum }
$externalEvidenceCollectionComplete = $ownerStatuses.Count -gt 0 -and $acceptedOwnerPacketCount -eq $ownerStatuses.Count
$realHostProjectEvidenceAccepted = $usesRealAcceptanceManifest -and (Convert-ToBool (Get-JsonValue $acceptanceManifest "realHostProjectEvidenceAccepted" $false))

$checks = @()
Add-StatusCheck "handoff_package_source" `
    ($handoffManifest.status -eq "PASS" -and (Convert-ToBool (Get-JsonValue $handoffManifest "ownerPacketsContentValidated" $false))) `
    "Source handoff package must be PASS and include validated owner packets."
Add-StatusCheck "owner_packet_index" `
    ($ownerPacketIndex.status -eq "PASS" -and (Get-JsonValue $ownerPacketIndex "schemaVersion" "") -eq "aitestpilot.production_handoff_owner_packets.v1") `
    "Owner packet index must be PASS and parseable."
Add-StatusCheck "blocker_resolution_coverage" `
    ($blockerResolutionMap.status -eq "PASS" -and
        (Convert-ToInt (Get-JsonValue $blockerResolutionMap "mappedBlockingReasonCount" -1)) -eq (Convert-ToInt (Get-JsonValue $blockerResolutionMap "totalBlockingReasonCount" -2)) -and
        (Convert-ToInt (Get-JsonValue $blockerResolutionMap "unmappedBlockingReasonCount" 1)) -eq 0) `
    "Blocker-resolution map must cover every remaining production blocker."
Add-StatusCheck "handoff_export_source" `
    ($handoffExportManifest.status -eq "PASS" -and (Convert-ToBool (Get-JsonValue $handoffExportManifest "zipGenerated" $false))) `
    "Production handoff export must be available for owner distribution."
Add-StatusCheck "acceptance_contract_boundary" `
    ($contractProbeManifest.status -eq "PASS" -and
        (Convert-ToBool (Get-JsonValue $contractProbeManifest "acceptedAllExternalEvidenceAccepted" $false)) -and
        -not (Convert-ToBool (Get-JsonValue $contractProbeManifest "realHostProjectEvidenceAccepted" $true)) -and
        $failureProbeManifest.status -eq "PASS") `
    "Acceptance contract and failure probes must be available without promoting fixture evidence."
Add-StatusCheck "owner_status_math" `
    ($ownerStatuses.Count -eq (Convert-ToInt (Get-JsonValue $ownerPacketIndex "ownerPacketCount" -1)) -and
        $acceptedOwnerPacketCount + $pendingOwnerPacketCount -eq $ownerStatuses.Count -and
        $remainingBlockingReasonCount -le (Convert-ToInt (Get-JsonValue $ownerPacketIndex "totalBlockingReasonCount" 0))) `
    "Owner status counts must match the owner packet index and blocker totals."
Add-StatusCheck "fixture_boundary_preserved" `
    ((-not $hasAcceptanceManifest) -or $usesRealAcceptanceManifest -or (-not (Convert-ToBool (Get-JsonValue $acceptanceManifest "realHostProjectEvidenceAccepted" $true)))) `
    "Fixture acceptance manifests must not claim real host-project evidence."

$reportLines = @(
    "# AI TestPilot Production Handoff Status",
    "",
    "Schema: ``aitestpilot.production_handoff_status.v1``",
    "Generated at UTC: $((Get-Date).ToUniversalTime().ToString("O"))",
    "",
    "## Summary",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Owner packets | $($ownerStatuses.Count) |",
    "| Accepted owner packets | $acceptedOwnerPacketCount |",
    "| Pending owner packets | $pendingOwnerPacketCount |",
    "| Remaining blocker reasons | $remainingBlockingReasonCount |",
    "| External evidence collection complete | $externalEvidenceCollectionComplete |",
    "| Real host-project evidence accepted | $realHostProjectEvidenceAccepted |",
    "| Real acceptance manifest used | $usesRealAcceptanceManifest |",
    "",
    "## Owner Status",
    "",
    "| Owner | Area | Status | Accepted | Remaining blockers | Required evidence | Next command |",
    "| --- | --- | --- | --- | --- | --- | --- |"
)

foreach ($ownerStatus in $ownerStatuses) {
    $owner = Format-MarkdownCell (Get-JsonValue $ownerStatus "owner" "")
    $area = Format-MarkdownCell (Get-JsonValue $ownerStatus "area" "")
    $statusText = Format-MarkdownCell (Get-JsonValue $ownerStatus "status" "")
    $acceptedText = Format-MarkdownCell (Get-JsonValue $ownerStatus "acceptedExternalEvidence" $false)
    $blockers = Format-MarkdownCell (Join-MarkdownList @(Get-JsonValue $ownerStatus "remainingBlockingReasons" @()))
    $requiredFiles = Format-MarkdownCell (Join-MarkdownList @(Get-JsonValue $ownerStatus "requiredEvidenceFiles" @()))
    $nextCommand = Format-MarkdownCell (Get-JsonValue $ownerStatus "acceptanceWrapperCommand" "")
    $reportLines += "| $owner | $area | $statusText | $acceptedText | $blockers | $requiredFiles | $nextCommand |"
}

$reportLines += @(
    "",
    "## Boundary",
    "",
    "- This status report is an external evidence collection tracker.",
    "- Contract fixtures prove schemas only and are not counted as real host-project acceptance.",
    "- Production completion requires all owner packets to be accepted by a non-fixture external evidence manifest and hard validation to pass."
)

$reportText = [string]::Join([Environment]::NewLine, $reportLines) + [Environment]::NewLine
$reportContentValidated = $reportText.Contains("AI TestPilot Production Handoff Status") -and
    $reportText.Contains("host_project_gameplay_qa") -and
    $reportText.Contains("host_project_lua_owner") -and
    $reportText.Contains("host_project_ai_platform") -and
    $reportText.Contains("Real host-project evidence accepted") -and
    $reportText.Contains("Production completion requires") -and
    -not $reportText.Contains("System.Collections") -and
    -not $reportText.Contains("@{")

New-Item -ItemType Directory -Force (Split-Path $reportFullPath -Parent) | Out-Null
$reportText | Set-Content -Path $reportFullPath -Encoding UTF8
Add-StatusCheck "status_report_content" ([bool]$reportContentValidated) "Status report must summarize owner status, blockers, commands, and evidence boundary."

$failedChecks = @($checks | Where-Object { -not (Convert-ToBool (Get-JsonValue $_ "passed" $false)) })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$generatedFiles = @(
    (Split-Path $manifestFullPath -Leaf),
    (Split-Path $reportFullPath -Leaf)
)
$sourceFiles = @(
    "production-handoff-package-manifest.json",
    "production-handoff-package/owner-packets/owner-packet-index.json",
    "production-handoff-package/blocker-resolution-map.json",
    "production-handoff-package/required-external-evidence.json",
    "production-handoff-export-manifest.json",
    "production-external-evidence-acceptance-contract-probe-manifest.json",
    "production-external-evidence-acceptance-failure-probe-manifest.json"
)
if ($usesRealAcceptanceManifest -and -not [string]::IsNullOrWhiteSpace($AcceptanceManifestPath)) {
    $sourceFiles += (Resolve-FullPath $AcceptanceManifestPath)
}

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_status.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    reportPath = $reportFullPath
    reportGenerated = (Test-Path $reportFullPath)
    reportContentValidated = [bool]$reportContentValidated
    ownerPacketCount = [int]$ownerStatuses.Count
    acceptedOwnerPacketCount = [int]$acceptedOwnerPacketCount
    pendingOwnerPacketCount = [int]$pendingOwnerPacketCount
    hostProjectActionItemCount = (Convert-ToInt (Get-JsonValue $ownerPacketIndex "hostProjectActionItemCount" 0))
    totalBlockingReasonCount = (Convert-ToInt (Get-JsonValue $ownerPacketIndex "totalBlockingReasonCount" 0))
    remainingBlockingReasonCount = [int]$remainingBlockingReasonCount
    externalEvidenceCollectionComplete = [bool]$externalEvidenceCollectionComplete
    realAcceptanceManifestUsed = [bool]$usesRealAcceptanceManifest
    realHostProjectEvidenceAccepted = [bool]$realHostProjectEvidenceAccepted
    releasePipelineUsesFixture = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "host_project_external_evidence_collection_status_only"
    ownerStatuses = @($ownerStatuses)
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
    throw "Production handoff status failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production handoff status manifest: $manifestFullPath"
Write-Output "Production handoff status report: $reportFullPath"
Write-Output "PASS AI TestPilot production handoff status"
