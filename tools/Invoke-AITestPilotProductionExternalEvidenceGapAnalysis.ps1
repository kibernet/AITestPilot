[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
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

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-external-evidence-gap-analysis-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-external-evidence-gap-analysis.md"
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

function Add-GapCheck {
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

$canonicalActionQueuePath = Join-Path $evidenceBundlePath "production-external-evidence-action-queue-manifest.json"
$probePostDispatchActionQueuePath = Join-Path $evidenceBundlePath "production-external-evidence-action-queue-probe\post-dispatch-action-queue-manifest.json"

$actionQueueCandidates = @(
    [ordered]@{ path = $canonicalActionQueuePath; sourceKind = "canonical_action_queue" },
    [ordered]@{ path = $probePostDispatchActionQueuePath; sourceKind = "probe_post_dispatch_action_queue" }
)
$selectedActionQueue = $null
$fallbackActionQueue = $null
foreach ($candidate in $actionQueueCandidates) {
    if (-not (Test-Path $candidate["path"])) {
        continue
    }

    $candidateManifest = Read-JsonFile $candidate["path"] "Production external evidence action queue candidate"
    if ($null -eq $fallbackActionQueue) {
        $fallbackActionQueue = [ordered]@{
            path = $candidate["path"]
            sourceKind = $candidate["sourceKind"]
            manifest = $candidateManifest
        }
    }

    $candidateItems = @(Convert-ToArray (Get-JsonValue $candidateManifest "actionQueue" @()))
    $candidateSemanticPreflightCount = @($candidateItems | Where-Object {
            ([string](Get-JsonValue $_ "ownerResponseBundleZipSemanticPreflightCommand" "")).Contains("Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1") -and
            ([string](Get-JsonValue $_ "ownerResponseBundleZipSemanticPreflightCommand" "")).Contains("-OwnerResponseBundleZipPath")
        }).Count
    if ((Get-JsonValue $candidateManifest "status" "") -eq "PASS" -and $candidateSemanticPreflightCount -eq 3) {
        $selectedActionQueue = [ordered]@{
            path = $candidate["path"]
            sourceKind = $candidate["sourceKind"]
            manifest = $candidateManifest
        }
        break
    }
}

if ($null -eq $selectedActionQueue) {
    $selectedActionQueue = $fallbackActionQueue
}
if ($null -eq $selectedActionQueue) {
    throw "Production external evidence action queue manifest is missing. Expected canonical or probe post-dispatch action queue manifest."
}

$actionQueuePath = [string]$selectedActionQueue["path"]
$actionQueueSourceKind = [string]$selectedActionQueue["sourceKind"]
$actionQueue = $selectedActionQueue["manifest"]
$handoffStatus = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-status-manifest.json") "Production handoff status manifest"
$autoAcceptanceProbe = Read-JsonFile (Join-Path $evidenceBundlePath "production-external-evidence-auto-acceptance-probe-manifest.json") "Production external evidence auto acceptance probe manifest"
$actionQueueProbe = Read-JsonFile (Join-Path $evidenceBundlePath "production-external-evidence-action-queue-probe-manifest.json") "Production external evidence action queue probe manifest"

$queueItems = @(Convert-ToArray (Get-JsonValue $actionQueue "actionQueue" @()))
$gapItems = @()
$totalMissing = 0
$totalBlockers = 0
$areasWithExportHelpers = 0
$areasWithSemanticPreflight = 0
$areasWithAutoAcceptance = 0
$areasWithHardValidation = 0

foreach ($item in $queueItems) {
    $area = [string](Get-JsonValue $item "area" "")
    $missingFiles = @(Convert-ToArray (Get-JsonValue $item "missingFiles" @()) | ForEach-Object { [string]$_ })
    $requiredFiles = @(Convert-ToArray (Get-JsonValue $item "requiredEvidenceFiles" @()) | ForEach-Object { [string]$_ })
    $blockers = @(Convert-ToArray (Get-JsonValue $item "remainingBlockingReasons" @()) | ForEach-Object { [string]$_ })
    $missingFileCount = Convert-ToInt (Get-JsonValue $item "missingFileCount" $missingFiles.Count)
    $blockingReasonCount = Convert-ToInt (Get-JsonValue $item "remainingBlockingReasonCount" $blockers.Count)
    $totalMissing += $missingFileCount
    $totalBlockers += $blockingReasonCount

    $exportHelperCommand = ""
    if ($area -eq "production_driver_binding") {
        $exportHelperCommand = [string](Get-JsonValue $item "productionDriverEvidenceExportHelperCommand" "")
    }
    elseif ($area -eq "production_lua_patch_evidence") {
        $exportHelperCommand = [string](Get-JsonValue $item "productionLuaEvidenceExportHelperCommand" "")
    }
    elseif ($area -eq "live_model_endpoint_smoke") {
        $exportHelperCommand = [string](Get-JsonValue $item "liveModelSmokeEvidenceExportHelperCommand" "")
    }

    $ownerBundleZipCommand = [string](Get-JsonValue $item "ownerResponseBundleZipAutoAcceptanceCommand" "")
    $ownerBundleZipSemanticPreflightCommand = [string](Get-JsonValue $item "ownerResponseBundleZipSemanticPreflightCommand" "")
    $hardValidationCommand = [string](Get-JsonValue $item "hardValidationCommand" "")
    if (-not [string]::IsNullOrWhiteSpace($exportHelperCommand)) {
        $areasWithExportHelpers += 1
    }
    if ($ownerBundleZipSemanticPreflightCommand.Contains("Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1") -and
        $ownerBundleZipSemanticPreflightCommand.Contains("-OwnerResponseBundleZipPath")) {
        $areasWithSemanticPreflight += 1
    }
    if ($ownerBundleZipCommand.Contains("-OwnerResponseBundleZipPath")) {
        $areasWithAutoAcceptance += 1
    }
    if (-not [string]::IsNullOrWhiteSpace($hardValidationCommand)) {
        $areasWithHardValidation += 1
    }

    $gapItems += [ordered]@{
        area = $area
        owner = [string](Get-JsonValue $item "owner" "")
        status = [string](Get-JsonValue $item "status" "")
        missingFiles = @($missingFiles)
        missingFileCount = [int]$missingFileCount
        blockingReasons = @($blockers)
        blockingReasonCount = [int]$blockingReasonCount
        repoSideCovered = [ordered]@{
            ownerPacketPath = [string](Get-JsonValue $item "ownerPacketPath" "")
            ownerResponseBundleAreaPath = [string](Get-JsonValue $item "ownerResponseBundleAreaPath" "")
            ownerResponseBundleRequiredFilesPath = [string](Get-JsonValue $item "ownerResponseBundleRequiredFilesPath" "")
            preflightCommand = [string](Get-JsonValue $item "preflightCommand" "")
            acceptanceWrapperCommand = [string](Get-JsonValue $item "acceptanceWrapperCommand" "")
            ownerResponseBundleZipSemanticPreflightCommand = $ownerBundleZipSemanticPreflightCommand
            ownerResponseBundleZipAutoAcceptanceCommand = $ownerBundleZipCommand
            evidenceExportHelperCommand = $exportHelperCommand
            hardValidationCommand = $hardValidationCommand
        }
        externalEvidenceRequired = [bool]($missingFileCount -gt 0 -or $blockingReasonCount -gt 0)
        canBeClosedRepoSide = $false
        nextOwnerCommand = if (-not [string]::IsNullOrWhiteSpace($exportHelperCommand)) { $exportHelperCommand } else { $hardValidationCommand }
        nextOperatorSemanticPreflightCommand = $ownerBundleZipSemanticPreflightCommand
        nextOperatorAutoAcceptanceCommand = $ownerBundleZipCommand
        nextOperatorCommand = $ownerBundleZipSemanticPreflightCommand
        nextOperatorSteps = @(
            [ordered]@{
                order = 1
                name = "semantic_preflight"
                command = $ownerBundleZipSemanticPreflightCommand
            },
            [ordered]@{
                order = 2
                name = "auto_acceptance_after_preflight_passes"
                command = $ownerBundleZipCommand
            },
            [ordered]@{
                order = 3
                name = "hard_validation_after_acceptance"
                command = $hardValidationCommand
            }
        )
        requiredEvidenceFiles = @($requiredFiles)
    }
}

$externalRemainingWorkItemCount = Convert-ToInt (Get-JsonValue $actionQueue "externalRemainingWorkItemCount" $queueItems.Count)
$externalRemainingMissingFileCount = Convert-ToInt (Get-JsonValue $actionQueue "externalRemainingMissingFileCount" $totalMissing)
$externalRemainingBlockingReasonCount = Convert-ToInt (Get-JsonValue $actionQueue "externalRemainingBlockingReasonCount" $totalBlockers)
$pendingOwnerPacketCount = Convert-ToInt (Get-JsonValue $handoffStatus "pendingOwnerPacketCount" 0)

$checks = @()
Add-GapCheck "gap_analysis_sources_available" `
    ((Get-JsonValue $actionQueue "status" "") -eq "PASS" -and
        (Get-JsonValue $handoffStatus "status" "") -eq "PASS" -and
        (Get-JsonValue $autoAcceptanceProbe "status" "") -eq "PASS" -and
        (Get-JsonValue $actionQueueProbe "status" "") -eq "PASS") `
    "Gap analysis must read passing action queue, handoff status, auto-acceptance, and action-queue probe sources."
Add-GapCheck "gap_analysis_remaining_counts" `
    ($externalRemainingWorkItemCount -eq 3 -and $externalRemainingMissingFileCount -eq 9 -and $externalRemainingBlockingReasonCount -eq 11 -and $pendingOwnerPacketCount -eq 3) `
    "Gap analysis must preserve the current three external items, nine missing files, eleven blockers, and three pending owner packets."
Add-GapCheck "gap_analysis_area_classification" `
    ($gapItems.Count -eq 3 -and
        @($gapItems | Where-Object { [string](Get-JsonValue $_ "area" "") -eq "production_driver_binding" }).Count -eq 1 -and
        @($gapItems | Where-Object { [string](Get-JsonValue $_ "area" "") -eq "production_lua_patch_evidence" }).Count -eq 1 -and
        @($gapItems | Where-Object { [string](Get-JsonValue $_ "area" "") -eq "live_model_endpoint_smoke" }).Count -eq 1) `
    "Gap analysis must classify all three remaining production evidence areas."
Add-GapCheck "gap_analysis_commands_covered" `
    ($areasWithExportHelpers -eq 3 -and $areasWithSemanticPreflight -eq 3 -and $areasWithAutoAcceptance -eq 3 -and $areasWithHardValidation -eq 3) `
    "Every gap item must expose an owner export helper, returned-bundle semantic-preflight command, auto-acceptance command, and hard-validation command."
Add-GapCheck "gap_analysis_boundary_preserved" `
    (-not (Convert-ToBool (Get-JsonValue $actionQueue "realHostProjectEvidenceAccepted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $actionQueue "externalEvidenceAccepted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $actionQueue "fixtureEvidencePromoted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $actionQueue "releasePipelineSendsEmail" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $handoffStatus "realHostProjectEvidenceAccepted" $true))) `
    "Gap analysis must preserve no-send, no-real-evidence, and no-fixture-promotion boundaries."

$failedChecks = @($checks | Where-Object { -not [bool]$_["passed"] })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }
$generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")

$reportLines = @(
    "# AI TestPilot Production External Evidence Gap Analysis",
    "",
    "Schema: ``aitestpilot.production_external_evidence_gap_analysis.v1``",
    "Generated at UTC: $generatedAtUtc",
    "",
    "## Summary",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Status | $(Format-MarkdownCell $status) |",
    "| Action queue source | $(Format-MarkdownCell $actionQueueSourceKind) |",
    "| Next operator command order | semantic preflight, auto acceptance after preflight passes, hard validation |",
    "| External work items | $externalRemainingWorkItemCount |",
    "| External missing files | $externalRemainingMissingFileCount |",
    "| External blockers | $externalRemainingBlockingReasonCount |",
    "| Pending owner packets | $pendingOwnerPacketCount |",
    "| Can close repo-side | False |",
    "",
    "## Gaps",
    "",
    "| Area | Owner | Missing Files | Blockers | Owner Command | Operator Semantic Preflight | Operator Acceptance | Hard Validation |",
    "| --- | --- | ---: | ---: | --- | --- | --- | --- |"
)
foreach ($gap in $gapItems) {
    $repoSide = Get-JsonValue $gap "repoSideCovered" $null
    $area = Format-MarkdownCell (Get-JsonValue $gap "area" "")
    $owner = Format-MarkdownCell (Get-JsonValue $gap "owner" "")
    $missingFileCount = Get-JsonValue $gap "missingFileCount" 0
    $blockingReasonCount = Get-JsonValue $gap "blockingReasonCount" 0
    $exportHelperCommand = Format-MarkdownCell (Get-JsonValue $repoSide "evidenceExportHelperCommand" "")
    $operatorSemanticPreflightCommand = Format-MarkdownCell (Get-JsonValue $repoSide "ownerResponseBundleZipSemanticPreflightCommand" "")
    $operatorAcceptanceCommand = Format-MarkdownCell (Get-JsonValue $repoSide "ownerResponseBundleZipAutoAcceptanceCommand" "")
    $hardValidationCommand = Format-MarkdownCell (Get-JsonValue $repoSide "hardValidationCommand" "")
    $reportLines += "| $area | $owner | $missingFileCount | $blockingReasonCount | $exportHelperCommand | $operatorSemanticPreflightCommand | $operatorAcceptanceCommand | $hardValidationCommand |"
}
$reportLines += @(
    "",
    "## Required Evidence",
    "",
    "| Area | Required Files | Missing Files | Blocking Reasons |",
    "| --- | --- | --- | --- |"
)
foreach ($gap in $gapItems) {
    $area = Format-MarkdownCell (Get-JsonValue $gap "area" "")
    $requiredEvidenceFiles = Format-MarkdownCell (Join-TextList @(Get-JsonValue $gap "requiredEvidenceFiles" @()))
    $missingFiles = Format-MarkdownCell (Join-TextList @(Get-JsonValue $gap "missingFiles" @()))
    $blockingReasons = Format-MarkdownCell (Join-TextList @(Get-JsonValue $gap "blockingReasons" @()))
    $reportLines += "| $area | $requiredEvidenceFiles | $missingFiles | $blockingReasons |"
}
$reportLines += @(
    "",
    "## Boundary",
    "",
    "- This analysis does not send email.",
    "- This analysis does not accept real host-project evidence.",
    "- The remaining gaps require host-project or provider evidence.",
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

$reportText = $reportLines -join [Environment]::NewLine
$reportContentValidated = $reportText.Contains("production_driver_binding") -and
    $reportText.Contains("production_lua_patch_evidence") -and
    $reportText.Contains("live_model_endpoint_smoke") -and
    $reportText.Contains("Can close repo-side") -and
    $reportText.Contains("Operator Semantic Preflight") -and
    $reportText.Contains("Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1") -and
    -not $reportText.Contains("System.Collections") -and
    -not $reportText.Contains("@{")

Add-GapCheck "gap_analysis_report_content" `
    $reportContentValidated `
    "Gap analysis Markdown must be readable and summarize all three external gaps without object dumps."

$reportContentCheck = $checks[-1]
$reportContentResult = if ([bool]$reportContentCheck.passed) { "PASS" } else { "FAIL" }
$reportLines += "| $(Format-MarkdownCell $reportContentCheck.name) | $reportContentResult | $(Format-MarkdownCell $reportContentCheck.message) |"

$failedChecks = @($checks | Where-Object { -not [bool]$_["passed"] })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$reportLines[9] = "| Status | $(Format-MarkdownCell $status) |"
New-Item -ItemType Directory -Force (Split-Path $reportFullPath -Parent) | Out-Null
$reportLines | Set-Content -Path $reportFullPath -Encoding UTF8

$sourceFiles = @(
    (Convert-ToEvidenceRelativePath $actionQueuePath),
    "production-handoff-status-manifest.json",
    "production-external-evidence-auto-acceptance-probe-manifest.json",
    "production-external-evidence-action-queue-probe-manifest.json"
)
$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestFullPath),
    (Convert-ToEvidenceRelativePath $reportFullPath)
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_external_evidence_gap_analysis.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    actionQueueSourceKind = $actionQueueSourceKind
    actionQueueManifestPath = $actionQueuePath
    externalRemainingWorkItemCount = [int]$externalRemainingWorkItemCount
    externalRemainingMissingFileCount = [int]$externalRemainingMissingFileCount
    externalRemainingBlockingReasonCount = [int]$externalRemainingBlockingReasonCount
    pendingOwnerPacketCount = [int]$pendingOwnerPacketCount
    gapItems = @($gapItems)
    gapItemCount = [int]$gapItems.Count
    repoSideClosableGapCount = 0
    externalEvidenceRequiredGapCount = [int]@($gapItems | Where-Object { [bool](Get-JsonValue $_ "externalEvidenceRequired" $false) }).Count
    itemExportHelperCommandCount = [int]$areasWithExportHelpers
    itemSemanticPreflightCommandCount = [int]$areasWithSemanticPreflight
    itemAutoAcceptanceCommandCount = [int]$areasWithAutoAcceptance
    itemHardValidationCommandCount = [int]$areasWithHardValidation
    reportGenerated = (Test-Path $reportFullPath)
    reportContentValidated = [bool]$reportContentValidated
    releasePipelineSendsEmail = $false
    realHostProjectEvidenceAccepted = $false
    externalEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "production_external_evidence_gap_analysis_only"
    sourceFiles = @($sourceFiles)
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles + $sourceFiles)
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
}

$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestFullPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Production external evidence gap analysis failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production external evidence gap analysis manifest: $manifestFullPath"
Write-Output "Production external evidence gap analysis report: $reportFullPath"
Write-Output "PASS AI TestPilot production external evidence gap analysis"
