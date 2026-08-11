[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ManifestPath,
    [string]$ReportPath,
    [string]$DriftManifestPath,
    [string]$DriftReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "release-docs-freshness-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "release-docs-freshness.md"
}

if ([string]::IsNullOrWhiteSpace($DriftManifestPath)) {
    $DriftManifestPath = Join-Path $EvidenceBundleDir "release-docs-freshness-drift-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($DriftReportPath)) {
    $DriftReportPath = Join-Path $EvidenceBundleDir "release-docs-freshness-drift.md"
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
        throw "File must stay under evidence bundle: $fullPath"
    }

    return $fullPath.Substring($evidenceBundlePath.Length).TrimStart([char[]]@("\", "/")).Replace("\", "/")
}

function Convert-ToRepoRelativePath {
    param([string]$Path)

    $fullPath = Resolve-FullPath $Path
    if (-not (Test-PathWithinRoot $fullPath $repoRoot)) {
        throw "File must stay under repo root: $fullPath"
    }

    return $fullPath.Substring($repoRoot.Length).TrimStart([char[]]@("\", "/")).Replace("\", "/")
}

function Read-TextFile {
    param([string]$RelativePath)

    $path = Assert-PathUnderRepo (Join-Path $repoRoot $RelativePath) $RelativePath
    if (-not (Test-Path $path)) {
        return ""
    }

    return Get-Content -Path $path -Encoding UTF8 -Raw
}

function Read-JsonFile {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return $null
    }

    return Get-Content -Path $Path -Encoding UTF8 -Raw | ConvertFrom-Json -ErrorAction Stop
}

function Read-JsonFileWithStatus {
    param(
        [string]$Path,
        [ref]$IsReadable
    )

    $IsReadable.Value = $false
    if (-not (Test-Path $Path)) {
        return $null
    }

    try {
        $json = Read-JsonFile $Path
        $IsReadable.Value = $true
        return $json
    }
    catch {
        Write-Verbose ("Failed to parse JSON manifest at {0}: {1}" -f $Path, $_.Exception.Message)
        return $null
    }
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
        return ""
    }

    return ([string]$Value).Replace("|", "\|").Replace("`r", " ").Replace("`n", "<br>")
}

function To-StringArray {
    param([object]$Value)

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.String]) {
        return @($Value)
    }

    if ($Value -is [System.Collections.IDictionary]) {
        return @($Value.Values | ForEach-Object { [string]$_ })
    }

    if ($Value -is [pscustomobject]) {
        return @($Value.PSObject.Properties | ForEach-Object { [string]$_.Value })
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        return @($Value | ForEach-Object { [string]$_ })
    }

    return @([string]$Value)
}

function Compare-StringSetDelta {
    param(
        [object]$Previous,
        [object]$Current,
        [string]$Name
    )

    $previousArray = @()
    foreach ($value in @($Previous)) {
        if ($null -ne $value) {
            $previousArray += [string]$value
        }
    }

    $currentArray = @()
    foreach ($value in @($Current)) {
        if ($null -ne $value) {
            $currentArray += [string]$value
        }
    }

    $prevSet = @{}
    $prevIndex = @{}
    for ($i = 0; $i -lt $previousArray.Count; $i++) {
        $value = [string]$previousArray[$i]
        $prevSet[$value] = $true
        $prevIndex[$value] = $i
    }

    $currentSet = @{}
    $currentIndex = @{}
    for ($i = 0; $i -lt $currentArray.Count; $i++) {
        $value = [string]$currentArray[$i]
        $currentSet[$value] = $true
        $currentIndex[$value] = $i
    }

    $added = @()
    foreach ($value in $currentArray) {
        if (-not $prevSet.ContainsKey([string]$value)) {
            $added += [string]$value
        }
    }

    $removed = @()
    foreach ($value in $previousArray) {
        if (-not $currentSet.ContainsKey([string]$value)) {
            $removed += [string]$value
        }
    }

    $changed = @()
    $stableCount = 0
    $union = @()
    $union = @($previousArray + $currentArray | Sort-Object -Unique)
    foreach ($value in $union) {
        $inPrevious = $prevSet.ContainsKey($value)
        $inCurrent = $currentSet.ContainsKey($value)
        if ($inPrevious -and $inCurrent) {
            $stableCount++
        }
        elseif (-not $inPrevious -and -not $inCurrent) {
            continue
        }

        $changeType = if (-not $inPrevious) { "Added" } elseif (-not $inCurrent) { "Removed" } else { "Stable" }
        $changed += [ordered]@{
            name = $value
            change = $changeType
            previousIndex = if ($inPrevious) { [int]$prevIndex[$value] } else { -1 }
            currentIndex = if ($inCurrent) { [int]$currentIndex[$value] } else { -1 }
        }
    }

    return [ordered]@{
        name = $Name
        previousCount = [int]$previousArray.Count
        currentCount = [int]$currentArray.Count
        added = @($added | Sort-Object -Unique)
        removed = @($removed | Sort-Object -Unique)
        stableCount = [int]$stableCount
        changedCount = [int]( @($changed | Where-Object { $_.change -ne "Stable" }).Count )
        addedCount = [int]$added.Count
        removedCount = [int]$removed.Count
        changedSourceFileList = @($changed | Where-Object { $_.change -ne "Stable" })
    }
}

function Get-SafeCount {
    param([object]$Value)

    return @(To-StringArray -Value $Value).Count
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"
$driftManifestFullPath = Assert-PathUnderRepo $DriftManifestPath "DriftManifestPath"
$driftReportFullPath = Assert-PathUnderRepo $DriftReportPath "DriftReportPath"

New-Item -ItemType Directory -Force $evidenceBundlePath | Out-Null

$checks = @()
function Add-DocsCheck {
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

$requiredDocFiles = @(
    "README.md",
    "docs/ci-release-pipeline.md",
    "docs/architecture.md",
    "docs/roadmap.md"
)

$docTexts = @{}
$missingDocFiles = @()
foreach ($relativeDocPath in $requiredDocFiles) {
    $docFullPath = Join-Path $repoRoot $relativeDocPath
    $exists = Test-Path $docFullPath
    if (-not $exists) {
        $missingDocFiles += $relativeDocPath
        $docTexts[$relativeDocPath] = ""
    }
    else {
        $docTexts[$relativeDocPath] = Read-TextFile $relativeDocPath
    }
}

Add-DocsCheck "required_doc_files_present" `
    ($missingDocFiles.Count -eq 0) `
    "Required release docs must exist: $($requiredDocFiles -join ', ')."

$pipelineSourcePath = Join-Path $repoRoot "tools\Invoke-AITestPilotReleasePipeline.ps1"
$pipelineSourceText = Read-TextFile "tools/Invoke-AITestPilotReleasePipeline.ps1"
$pipelineStepMatches = [regex]::Matches($pipelineSourceText, 'Invoke-PipelineStep\s+"([^"]+)"')
$pipelineSteps = @($pipelineStepMatches | ForEach-Object { $_.Groups[1].Value })
$duplicatePipelineSteps = @($pipelineSteps | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })

Add-DocsCheck "pipeline_steps_discovered" `
    ($pipelineSteps.Count -gt 0) `
    "Release pipeline source must expose Invoke-PipelineStep entries."

Add-DocsCheck "pipeline_steps_unique" `
    ($duplicatePipelineSteps.Count -eq 0) `
    "Release pipeline step IDs must stay unique."

$ciPipelineDocText = [string]$docTexts["docs/ci-release-pipeline.md"]
$missingPipelineStepDocs = @()
$pipelineStepDocCoverage = @()
foreach ($step in $pipelineSteps) {
    $needle = "``$step``"
    $documented = $ciPipelineDocText.Contains($needle)
    if (-not $documented) {
        $missingPipelineStepDocs += $step
    }

    $pipelineStepDocCoverage += [ordered]@{
        stepId = $step
        documented = [bool]$documented
    }
}

Add-DocsCheck "pipeline_step_index_complete" `
    ($missingPipelineStepDocs.Count -eq 0) `
    "docs/ci-release-pipeline.md must list every Invoke-PipelineStep ID in the machine-checked step index."

$requiredArtifactNames = @(
    "pipeline-manifest.json",
    "release-risk-policy-manifest.json",
    "release-evidence-index-manifest.json",
    "release-evidence-index-field-coverage-probe-manifest.json",
    "repair-agent-cursor-agent-external-output-binding-probe-manifest.json",
    "release-gate-manifest.json",
    "production-handoff-export-zip-index-manifest.json",
    "production-handoff-send-local-workflow-probe-manifest.json",
    "production-handoff-owner-packet-dispatch-receipt-intake-probe-manifest.json",
    "production-handoff-owner-packet-real-receipt-guard-probe-manifest.json",
    "production-handoff-owner-route-map-manifest.json",
    "production-handoff-owner-route-map.md",
    "production-handoff-owner-route-map-probe-manifest.json",
    "production-handoff-owner-route-map-probe.md",
    "production-handoff-owner-route-map-probe\",
    "release-progress-notification-outbox-manifest.json",
    "release-progress-notification-remaining-work-snapshot-probe-manifest.json",
    "release-progress-notification-post-dispatch-snapshot-probe-manifest.json",
    "production-external-evidence-semantic-preflight-probe-manifest.json",
    "production-external-evidence-owner-return-repair-pack-probe-manifest.json",
    "production-external-evidence-owner-return-bundle-status-manifest.json",
    "production-external-evidence-owner-return-bundle-status-probe-manifest.json",
    "production-external-evidence-auto-acceptance-probe-manifest.json",
    "production-handoff-export\FIRST-TESTABLE.md",
    "production-handoff-export\run-owner-return-status.ps1",
    "first-testable-release-manifest.json",
    "first-testable-release.md",
    "first-testable-operator-dashboard-manifest.json",
    "first-testable-operator-dashboard.md",
    "release-docs-freshness-manifest.json",
    "release-docs-freshness-drift-manifest.json",
    "release-docs-freshness-drift.md"
)
$combinedDocsText = [string]::Join([Environment]::NewLine, @(
        $docTexts["README.md"],
        $docTexts["docs/ci-release-pipeline.md"],
        $docTexts["docs/architecture.md"],
        $docTexts["docs/roadmap.md"]
    ))
$missingRequiredArtifactDocs = @($requiredArtifactNames | Where-Object { -not $combinedDocsText.Contains($_) })

Add-DocsCheck "required_artifacts_documented" `
    ($missingRequiredArtifactDocs.Count -eq 0) `
    "Core release artifact names must be documented for CI, gate, and handoff consumers."

$requiredDocStrings = @(
    [ordered]@{ file = "README.md"; pattern = "Invoke-AITestPilotReleasePipeline.ps1"; label = "release pipeline command" },
    [ordered]@{ file = "README.md"; pattern = "Invoke-AITestPilotFirstTestableReleaseProbe.ps1"; label = "first testable release probe command" },
    [ordered]@{ file = "README.md"; pattern = "Invoke-AITestPilotFirstTestableOperatorDashboard.ps1"; label = "first testable operator dashboard command" },
    [ordered]@{ file = "README.md"; pattern = "first-testable-release-manifest.json"; label = "first testable release manifest artifact" },
    [ordered]@{ file = "README.md"; pattern = "first-testable-operator-dashboard-manifest.json"; label = "first testable operator dashboard artifact" },
    [ordered]@{ file = "README.md"; pattern = 'production-handoff-export\FIRST-TESTABLE.md'; label = "first testable handoff summary artifact" },
    [ordered]@{ file = "README.md"; pattern = 'production-handoff-export\run-owner-return-status.ps1'; label = "self-contained owner return status helper artifact" },
    [ordered]@{ file = "README.md"; pattern = "artifacts\ai-testpilot-release\latest"; label = "stable latest artifact path" },
    [ordered]@{ file = "README.md"; pattern = "production-handoff-export-zip-index-manifest.json"; label = "handoff zip index artifact" },
    [ordered]@{ file = "README.md"; pattern = "production-external-evidence-auto-acceptance-probe-manifest.json"; label = "auto acceptance probe artifact" },
    [ordered]@{ file = "README.md"; pattern = "release-progress-notification-outbox-manifest.json"; label = "progress notification outbox artifact" },
    [ordered]@{ file = "README.md"; pattern = "release-progress-notification-remaining-work-snapshot-probe-manifest.json"; label = "progress notification snapshot probe artifact" },
    [ordered]@{ file = "README.md"; pattern = "release-progress-notification-post-dispatch-snapshot-probe-manifest.json"; label = "progress notification post-dispatch probe artifact" },
    [ordered]@{ file = "README.md"; pattern = 'latest big node is `production_external_evidence_strict_payload_shape`'; label = "progress notification final strict payload refresh" },
    [ordered]@{ file = "README.md"; pattern = "complete owner response bundle zip, partial zip, semantic-bad zip, arbitrary single top-level wrapper zip, unsafe zip, extra-payload owner response bundle, and nested-payload owner response bundle zip"; label = "owner response bundle zip case set" },
    [ordered]@{ file = "README.md"; pattern = "caseCount=12"; label = "semantic preflight case count target" },
    [ordered]@{ file = "README.md"; pattern = "completeCandidateCaseCount=4"; label = "semantic preflight candidate case count target" },
    [ordered]@{ file = "README.md"; pattern = "rejectedCaseCount=8"; label = "semantic preflight rejected case count target" },
    [ordered]@{ file = "README.md"; pattern = "checkCount=14"; label = "semantic preflight check count target" },
    [ordered]@{ file = "README.md"; pattern = "ownerResponseBundleZipCaseCount=6"; label = "owner response bundle zip case count target" },
    [ordered]@{ file = "README.md"; pattern = "ownerResponseBundleZipSafeCaseCount=5"; label = "owner response bundle zip safe case count target" },
    [ordered]@{ file = "README.md"; pattern = "ownerResponseBundleZipUnsafeCaseCount=1"; label = "owner response bundle zip unsafe case count target" },
    [ordered]@{ file = "README.md"; pattern = "ownerResponseBundleZipArbitraryWrapperReady=true"; label = "owner response bundle zip arbitrary wrapper readiness" },
    [ordered]@{ file = "README.md"; pattern = "payloadShapeRejectedCaseCount=2"; label = "owner response bundle payload shape rejected count" },
    [ordered]@{ file = "README.md"; pattern = "Invoke-AITestPilotProductionExternalEvidenceOwnerReturnRepairPack.ps1"; label = "owner return repair pack command" },
    [ordered]@{ file = "README.md"; pattern = "production-external-evidence-owner-return-repair-pack-probe-manifest.json"; label = "owner return repair pack probe artifact" },
    [ordered]@{ file = "README.md"; pattern = "production-external-evidence-owner-return-bundle-status-manifest.json"; label = "owner return bundle status artifact" },
    [ordered]@{ file = "README.md"; pattern = "production-external-evidence-owner-return-bundle-status-probe-manifest.json"; label = "owner return bundle status probe artifact" },
    [ordered]@{ file = "README.md"; pattern = "ownerReturnReadinessStatus=PENDING_EXTERNAL_EVIDENCE"; label = "owner return bundle default pending state" },
    [ordered]@{ file = "README.md"; pattern = "READY_FOR_AUTO_ACCEPTANCE_CANDIDATE"; label = "owner return bundle candidate-ready state" },
    [ordered]@{ file = "README.md"; pattern = "NEEDS_OWNER_REPAIR"; label = "owner return bundle repair-needed state" },
    [ordered]@{ file = "README.md"; pattern = "extraPayloadOwnerResponseBundleRejected=true"; label = "auto acceptance extra payload rejection" },
    [ordered]@{ file = "README.md"; pattern = "production-handoff-send-local-workflow-probe-manifest.json"; label = "owner packet local workflow probe artifact" },
    [ordered]@{ file = "README.md"; pattern = "production-handoff-owner-packet-dispatch-receipt-intake-probe-manifest.json"; label = "owner packet dispatch receipt intake probe artifact" },
    [ordered]@{ file = "README.md"; pattern = "production-handoff-owner-packet-real-receipt-guard-probe-manifest.json"; label = "owner packet real receipt guard probe artifact" },
    [ordered]@{ file = "README.md"; pattern = "Invoke-AITestPilotProductionHandoffOwnerRouteMap.ps1"; label = "owner route map command" },
    [ordered]@{ file = "README.md"; pattern = 'operator-actions\NEXT-STEPS.md'; label = "operator next steps export artifact" },
    [ordered]@{ file = "README.md"; pattern = "run-owner-return-status.ps1"; label = "self-contained owner return status helper" },
    [ordered]@{ file = "README.md"; pattern = "source-to-export SHA256 proof for every kit file"; label = "owner response bundle kit source hash proof" },
    [ordered]@{ file = "README.md"; pattern = "production-handoff-owner-route-map-manifest.json"; label = "owner route map artifact" },
    [ordered]@{ file = "README.md"; pattern = "Invoke-AITestPilotProductionHandoffOwnerRouteMapProbe.ps1"; label = "owner route map probe command" },
    [ordered]@{ file = "README.md"; pattern = "production-handoff-owner-route-map-probe-manifest.json"; label = "owner route map probe artifact" },
    [ordered]@{ file = "README.md"; pattern = "Invoke-AITestPilotReleaseEvidenceIndexFieldCoverageProbe.ps1"; label = "release evidence index field coverage probe command" },
    [ordered]@{ file = "README.md"; pattern = "Invoke-AITestPilotFinalArtifactFreshnessProbe.ps1"; label = "final artifact freshness probe command" },
    [ordered]@{ file = "README.md"; pattern = "release evidence index field coverage"; label = "release evidence index field coverage overview" },
    [ordered]@{ file = "README.md"; pattern = "core artifact names, source files, and source-manifest lists"; label = "docs freshness source files overview" },
    [ordered]@{ file = "README.md"; pattern = "133 semantic field checks"; label = "release evidence index 133-field coverage count" },
    [ordered]@{ file = "README.md"; pattern = "field-level definition SHA256 and source script SHA256"; label = "release evidence index definition hash binding" },
    [ordered]@{ file = "README.md"; pattern = "source manifest SHA256 hash set"; label = "release evidence index source manifest hash binding" },
    [ordered]@{ file = "README.md"; pattern = "release risk policy source script SHA256"; label = "release risk policy source hash binding" },
    [ordered]@{ file = "README.md"; pattern = 'nine missing evidence files from `production-external-evidence-inbox-manifest.json`'; label = "production handoff status missing evidence source" },
    [ordered]@{ file = "README.md"; pattern = "six isolated scenarios"; label = "release evidence index six-scenario probe count" },
    [ordered]@{ file = "README.md"; pattern = "handoff export NEXT-STEPS validation rejection"; label = "handoff export next steps field coverage scenario" },
    [ordered]@{ file = "README.md"; pattern = "Invoke-AITestPilotCursorAgentExternalOutputBindingProbe.ps1"; label = "Cursor Agent external output binding probe command" },
    [ordered]@{ file = "README.md"; pattern = "repair-agent-cursor-agent-external-output-binding-probe-manifest.json"; label = "Cursor Agent external output binding probe artifact" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "Release Pipeline Step Index"; label = "machine checked step index section" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "release_evidence_index_field_coverage_probe"; label = "field coverage pipeline step" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "repair_agent_cursor_agent_external_output_binding_probe"; label = "Cursor Agent external output binding pipeline step" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "release-evidence-index-field-coverage-probe-manifest.json"; label = "field coverage pipeline artifact" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "Invoke-AITestPilotFirstTestableReleaseProbe.ps1"; label = "first testable release pipeline probe command" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "Invoke-AITestPilotFirstTestableOperatorDashboard.ps1"; label = "first testable operator dashboard pipeline command" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "Invoke-AITestPilotFinalArtifactFreshnessProbe.ps1"; label = "final artifact freshness pipeline probe command" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "first-testable-release-manifest.json"; label = "first testable release pipeline artifact" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "first-testable-operator-dashboard-manifest.json"; label = "first testable operator dashboard pipeline artifact" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "133 semantic fields"; label = "field coverage pipeline count" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "field-level definition and source script SHA256 binding"; label = "field coverage pipeline definition hash binding" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "source manifest SHA256 hash set binding"; label = "field coverage pipeline source manifest hash binding" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "release risk policy source script SHA256"; label = "risk policy pipeline source hash binding" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "missingEvidenceSource=production_external_evidence_inbox_manifest"; label = "production handoff status inbox missing evidence source" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "six isolated scenarios"; label = "field coverage pipeline scenario count" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "handoff export NEXT-STEPS validation rejection"; label = "field coverage pipeline next steps scenario" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "repair-agent-cursor-agent-external-output-binding-probe-manifest.json"; label = "Cursor Agent external output binding pipeline artifact" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "production-handoff-send-local-workflow-probe-manifest.json"; label = "owner packet local workflow pipeline artifact" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "production-handoff-owner-packet-dispatch-receipt-intake-probe-manifest.json"; label = "owner packet dispatch receipt intake pipeline artifact" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "production-handoff-owner-packet-real-receipt-guard-probe-manifest.json"; label = "owner packet real receipt guard pipeline artifact" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "production_handoff_owner_route_map"; label = "owner route map pipeline step" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "production_handoff_owner_route_map_probe"; label = "owner route map probe pipeline step" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "release_progress_notification_outbox_strict_payload_shape_refresh"; label = "strict payload progress outbox refresh step" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "release_progress_notification_remaining_work_snapshot_strict_payload_shape_probe"; label = "strict payload remaining-work snapshot step" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "production_external_evidence_strict_payload_shape"; label = "strict payload latest big node" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "production_external_evidence_owner_return_bundle_status"; label = "owner return bundle status pipeline step" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "production_external_evidence_owner_return_repair_pack_probe"; label = "owner return repair pack pipeline step" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "production-external-evidence-owner-return-repair-pack-probe-manifest.json"; label = "owner return repair pack pipeline artifact" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "production_external_evidence_owner_return_bundle_status_probe"; label = "owner return bundle status probe pipeline step" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "production-external-evidence-owner-return-bundle-status-manifest.json"; label = "owner return bundle status pipeline artifact" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "production-external-evidence-owner-return-bundle-status-probe-manifest.json"; label = "owner return bundle status probe pipeline artifact" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "ownerReturnReadinessStatus=PENDING_EXTERNAL_EVIDENCE"; label = "owner return bundle pipeline default pending state" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "production-handoff-owner-route-map-manifest.json"; label = "owner route map pipeline artifact" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = 'operator-actions\NEXT-STEPS.md'; label = "operator next steps pipeline artifact" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = 'production-handoff-export\FIRST-TESTABLE.md'; label = "first testable handoff summary pipeline artifact" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = 'production-handoff-export\run-owner-return-status.ps1'; label = "self-contained owner return status helper pipeline artifact" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "source-to-export SHA256 proof for every kit file"; label = "owner response bundle kit pipeline source hash proof" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "production-handoff-owner-route-map-probe-manifest.json"; label = "owner route map probe pipeline artifact" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "release-docs-freshness-manifest.json"; label = "docs freshness artifact" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "required release artifact names, source files, and source-manifest coverage"; label = "docs freshness pipeline source files reference" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "OwnerResponseBundleZipPath"; label = "owner response bundle zip parameter" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "unsafe, duplicate, absolute, or traversal zip entries are rejected"; label = "owner response bundle zip safety rejection" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "ownerResponseBundleZipSafeCaseCount=5"; label = "owner response bundle zip safe case count" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "payloadShapeRejectedCaseCount=2"; label = "owner response bundle payload shape rejected count" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "extraPayloadOwnerResponseBundleRejected=true"; label = "auto acceptance extra payload rejection" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "Invoke-AITestPilotReleasePipeline.ps1"; label = "pipeline architecture reference" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "release risk policy"; label = "risk policy architecture reference" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "release evidence index"; label = "evidence index architecture reference" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "release pipeline step index, source files"; label = "docs freshness architecture source files reference" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "release evidence index field coverage"; label = "field coverage architecture reference" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "133 semantic fields"; label = "field coverage architecture count" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "field-level definition SHA256 and the source script SHA256"; label = "field coverage architecture definition hash binding" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "source manifest SHA256 hash set"; label = "field coverage architecture source manifest hash binding" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "release risk policy source script SHA256 binding"; label = "risk policy architecture source hash binding" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "six isolated field-contract scenarios"; label = "field coverage architecture scenario count" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "Cursor Agent external output binding"; label = "Cursor Agent external output binding architecture reference" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "release gate"; label = "gate architecture reference" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "production handoff"; label = "production handoff architecture reference" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "production-handoff-send-local-workflow-probe-manifest.json"; label = "owner packet local workflow architecture artifact" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "production-handoff-owner-packet-dispatch-receipt-intake-probe-manifest.json"; label = "owner packet dispatch receipt intake architecture artifact" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "production-handoff-owner-packet-real-receipt-guard-probe-manifest.json"; label = "owner packet real receipt guard architecture artifact" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "production handoff owner route map"; label = "owner route map architecture reference" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "production-handoff-owner-route-map-manifest.json"; label = "owner route map architecture artifact" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "operator-actions/NEXT-STEPS.md"; label = "operator next steps architecture artifact" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "source-to-export SHA256 proof for every kit file"; label = "owner response bundle kit architecture source hash proof" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "production-handoff-owner-route-map-probe-manifest.json"; label = "owner route map probe architecture artifact" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "OwnerResponseBundleZipPath"; label = "owner response bundle zip architecture reference" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "unsafe/duplicate/absolute/traversal zip rejection"; label = "owner response bundle zip safety architecture reference" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "ownerResponseBundleZipUnsafeCaseCount=1"; label = "owner response bundle zip unsafe case count" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "payloadShapeRejectedCaseCount=2"; label = "owner response bundle payload shape rejected count" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "production-external-evidence-owner-return-bundle-status-manifest.json"; label = "owner return bundle status architecture artifact" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "production-external-evidence-owner-return-bundle-status-probe-manifest.json"; label = "owner return bundle status probe architecture artifact" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "READY_FOR_AUTO_ACCEPTANCE_CANDIDATE"; label = "owner return bundle architecture candidate-ready state" },
    [ordered]@{ file = "docs/roadmap.md"; pattern = "release docs freshness"; label = "roadmap freshness guard reference" },
    [ordered]@{ file = "docs/roadmap.md"; pattern = "core artifact names, source files, and release source-manifest lists"; label = "roadmap freshness source files reference" },
    [ordered]@{ file = "docs/roadmap.md"; pattern = "release evidence index field coverage"; label = "roadmap field coverage reference" },
    [ordered]@{ file = "docs/roadmap.md"; pattern = "133 semantic fields"; label = "roadmap field coverage count" },
    [ordered]@{ file = "docs/roadmap.md"; pattern = "field-level definition/source-script SHA256 binding"; label = "roadmap field coverage definition hash binding" },
    [ordered]@{ file = "docs/roadmap.md"; pattern = "source manifest SHA256 hash set"; label = "roadmap source manifest hash binding" },
    [ordered]@{ file = "docs/roadmap.md"; pattern = "release risk policy source script SHA256 binding"; label = "roadmap risk policy source hash binding" },
    [ordered]@{ file = "docs/roadmap.md"; pattern = "six-scenario field coverage probe"; label = "roadmap field coverage scenario count" },
    [ordered]@{ file = "docs/roadmap.md"; pattern = "Cursor Agent external output binding"; label = "roadmap Cursor Agent external output binding reference" },
    [ordered]@{ file = "docs/roadmap.md"; pattern = "owner send local workflow proof"; label = "roadmap owner send local workflow proof" },
    [ordered]@{ file = "docs/roadmap.md"; pattern = "owner packet real receipt guard proof"; label = "roadmap owner packet real receipt guard proof" },
    [ordered]@{ file = "docs/roadmap.md"; pattern = "production handoff owner route map"; label = "roadmap owner route map reference" },
    [ordered]@{ file = "docs/roadmap.md"; pattern = 'operator-actions\NEXT-STEPS.md'; label = "roadmap operator next steps artifact" },
    [ordered]@{ file = "docs/roadmap.md"; pattern = "source-to-export SHA256 proof for every kit file"; label = "roadmap owner response bundle kit source hash proof" },
    [ordered]@{ file = "docs/roadmap.md"; pattern = "production handoff owner route map and probe"; label = "roadmap owner route map probe reference" },
    [ordered]@{ file = "docs/roadmap.md"; pattern = "Production external evidence owner return bundle status and probe"; label = "roadmap owner return bundle status reference" }
)
$missingRequiredDocStrings = @()
foreach ($requiredDocString in $requiredDocStrings) {
    $file = [string]$requiredDocString.file
    $pattern = [string]$requiredDocString.pattern
    # README is the public product overview. Detailed release-pipeline anchors may
    # live in any of the linked release documents instead of bloating the landing page.
    $text = if ($file -eq "README.md") {
        $combinedDocsText
    }
    else {
        [string]$docTexts[$file]
    }
    if (-not $text.Contains($pattern)) {
        $missingRequiredDocStrings += [ordered]@{
            file = if ($file -eq "README.md") { "linked release docs" } else { $file }
            pattern = $pattern
            label = [string]$requiredDocString.label
        }
    }
}

Add-DocsCheck "required_doc_strings_present" `
    ($missingRequiredDocStrings.Count -eq 0) `
    "Release docs must carry the pipeline, artifact, architecture, and roadmap anchors checked by this probe."

$sourceManifestScripts = @(
    "tools/Invoke-AITestPilotReleaseRiskPolicy.ps1",
    "tools/Invoke-AITestPilotReleaseEvidenceIndex.ps1",
    "tools/Invoke-AITestPilotReleaseGate.ps1"
)
$hardModeDefaultSourceProbeScripts = @(
    "tools/Invoke-AITestPilotProductionHardModeFailureProbe.ps1",
    "tools/Invoke-AITestPilotProductionHardModeSuccessContractProbe.ps1"
)
$requiredSourceManifestNames = @(
    "production-handoff-export-zip-index-manifest.json",
    "production-handoff-send-local-workflow-probe-manifest.json",
    "production-handoff-owner-packet-dispatch-receipt-intake-probe-manifest.json",
    "production-handoff-owner-packet-real-receipt-guard-probe-manifest.json",
    "production-external-evidence-action-queue-manifest.json",
    "production-external-evidence-action-queue-probe-manifest.json",
    "production-external-evidence-gap-analysis-manifest.json",
    "release-progress-notification-remaining-work-snapshot-probe-manifest.json",
    "release-progress-notification-post-dispatch-snapshot-probe-manifest.json",
    "production-external-evidence-partial-matrix-probe-manifest.json",
    "production-external-evidence-semantic-preflight-probe-manifest.json",
    "production-external-evidence-owner-return-bundle-status-manifest.json",
    "production-external-evidence-owner-return-bundle-status-probe-manifest.json",
    "production-external-evidence-auto-acceptance-probe-manifest.json",
    "release-docs-freshness-manifest.json"
)
$missingSourceManifestReferences = @()
foreach ($scriptRelativePath in $sourceManifestScripts) {
    $scriptText = Read-TextFile $scriptRelativePath
    foreach ($sourceManifestName in $requiredSourceManifestNames) {
        if (-not $scriptText.Contains($sourceManifestName)) {
            $missingSourceManifestReferences += [ordered]@{
                script = $scriptRelativePath
                manifest = $sourceManifestName
            }
        }
    }
}
$sourceManifestListAligned = $missingSourceManifestReferences.Count -eq 0

Add-DocsCheck "source_manifest_lists_aligned" `
    $sourceManifestListAligned `
    "Risk policy, evidence index, and release gate source manifest lists must reference current pre-risk manifests."

$hardModeDefaultSourceProbeCoverage = @()
$hardModeDefaultSourceProbeFailures = @()
foreach ($scriptRelativePath in $hardModeDefaultSourceProbeScripts) {
    $scriptText = Read-TextFile $scriptRelativePath
    $usesEvidenceIndex = $scriptText.Contains("Invoke-AITestPilotReleaseEvidenceIndex.ps1")
    $usesCanonicalIndexManifest = $scriptText.Contains("release-evidence-index-manifest.json")
    $usesCanonicalRiskManifest = $scriptText.Contains("release-risk-policy-manifest.json")
    $usesCustomSourceManifestNames = $scriptText.Contains("-SourceManifestNames")
    $passed = $usesEvidenceIndex -and $usesCanonicalIndexManifest -and $usesCanonicalRiskManifest -and -not $usesCustomSourceManifestNames
    $entry = [ordered]@{
        script = $scriptRelativePath
        usesEvidenceIndex = [bool]$usesEvidenceIndex
        usesCanonicalIndexManifest = [bool]$usesCanonicalIndexManifest
        usesCanonicalRiskManifest = [bool]$usesCanonicalRiskManifest
        usesCustomSourceManifestNames = [bool]$usesCustomSourceManifestNames
        passed = [bool]$passed
    }
    $hardModeDefaultSourceProbeCoverage += $entry
    if (-not $passed) {
        $hardModeDefaultSourceProbeFailures += $entry
    }
}

Add-DocsCheck "hard_mode_probes_use_default_source_manifests" `
    ($hardModeDefaultSourceProbeFailures.Count -eq 0) `
    "Hard-mode copied-bundle probes must delegate source manifest selection to the release evidence index default canonical list."

$previousArtifactPipelineManifestPath = Join-Path $repoRoot "artifacts\ai-testpilot-release\latest\pipeline-manifest.json"
$previousArtifactPipelineManifestPresent = Test-Path $previousArtifactPipelineManifestPath
$previousArtifactPipelineManifestReadable = $false
$previousArtifactPipelineManifest = Read-JsonFileWithStatus -Path $previousArtifactPipelineManifestPath -IsReadable ([ref]$previousArtifactPipelineManifestReadable)
$previousArtifactPipelineStatus = [string](Get-JsonValue $previousArtifactPipelineManifest "status" "")
$previousArtifactPipelineStepCount = [int](Get-JsonValue $previousArtifactPipelineManifest "stepCount" 0)

$previousReleaseDocsFreshnessManifestPath = Join-Path $repoRoot "artifacts\ai-testpilot-release\latest\release-docs-freshness-manifest.json"
$previousReleaseDocsFreshnessManifestPresent = Test-Path $previousReleaseDocsFreshnessManifestPath
$previousReleaseDocsFreshnessManifestReadable = $false
$previousReleaseDocsFreshnessManifest = Read-JsonFileWithStatus -Path $previousReleaseDocsFreshnessManifestPath -IsReadable ([ref]$previousReleaseDocsFreshnessManifestReadable)

$previousReleaseDocsFreshnessPipelineStepCount = [int](Get-JsonValue $previousReleaseDocsFreshnessManifest "pipelineStepCount" 0)
$previousReleaseDocsFreshnessSourceFiles = To-StringArray (Get-JsonValue $previousReleaseDocsFreshnessManifest "sourceFiles" @())
$previousReleaseDocsFreshnessRequiredDocFiles = To-StringArray (Get-JsonValue $previousReleaseDocsFreshnessManifest "requiredDocFiles" @())
$previousReleaseDocsFreshnessMissingStepDocs = To-StringArray (Get-JsonValue $previousReleaseDocsFreshnessManifest "missingPipelineStepDocs" @())
$previousReleaseDocsFreshnessSourceFilesCount = Get-SafeCount $previousReleaseDocsFreshnessSourceFiles
$previousReleaseDocsFreshnessRequiredDocFilesCount = Get-SafeCount $previousReleaseDocsFreshnessRequiredDocFiles

Add-DocsCheck "previous_artifact_pipeline_manifest_readable_when_present" `
    ((-not $previousArtifactPipelineManifestPresent) -or $previousArtifactPipelineManifestReadable) `
    "Previous copied artifact pipeline manifest is optional for the probe, but must be readable when present."

Add-DocsCheck "previous_release_docs_freshness_manifest_readable_when_present" `
    ((-not $previousReleaseDocsFreshnessManifestPresent) -or $previousReleaseDocsFreshnessManifestReadable) `
    "Previous release-docs-freshness manifest is optional for drift reporting and must be readable when present."

$documentedFiles = @(
    "README.md",
    "docs/ci-release-pipeline.md",
    "docs/architecture.md",
    "docs/roadmap.md",
    "tools/Invoke-AITestPilotReleasePipeline.ps1",
    "tools/Invoke-AITestPilotProductionHandoffExport.ps1",
    "tools/Invoke-AITestPilotFirstTestableReleaseProbe.ps1",
    "tools/Invoke-AITestPilotFirstTestableOperatorDashboard.ps1",
    "tools/Invoke-AITestPilotFinalArtifactFreshnessProbe.ps1",
    "tools/Invoke-AITestPilotProductionExternalEvidenceOwnerReturnRepairPack.ps1",
    "tools/Invoke-AITestPilotProductionExternalEvidenceOwnerReturnRepairPackProbe.ps1",
    "tools/Invoke-AITestPilotReleaseRiskPolicy.ps1",
    "tools/Invoke-AITestPilotReleaseEvidenceIndex.ps1",
    "tools/Invoke-AITestPilotReleaseGate.ps1",
    "tools/Invoke-AITestPilotProductionHardModeFailureProbe.ps1",
    "tools/Invoke-AITestPilotProductionHardModeSuccessContractProbe.ps1"
)
$sourceFiles = @($documentedFiles | Sort-Object -Unique)
$missingSourceFiles = @($sourceFiles | Where-Object { -not (Test-Path (Join-Path $repoRoot $_)) })

Add-DocsCheck "source_files_present" `
    ($missingSourceFiles.Count -eq 0) `
    "Docs freshness source files must exist and be listed in the manifest."

$reportPreviewLines = @(
    "# Release Docs Freshness",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Status | PREVIEW |",
    "| Pipeline source steps | $($pipelineSteps.Count) |",
    "| Source files checked | $($sourceFiles.Count) |",
    "| Missing Pipeline Step Docs | $($missingPipelineStepDocs.Count) |",
    "| Missing Source Manifest References | $($missingSourceManifestReferences.Count) |"
)
$reportPreviewText = $reportPreviewLines -join [Environment]::NewLine
$reportContentValidated = $reportPreviewText.Contains("Release Docs Freshness") -and
    $reportPreviewText.Contains("Pipeline source steps") -and
    $reportPreviewText.Contains("Source files checked") -and
    $reportPreviewText.Contains("Missing Pipeline Step Docs") -and
    $reportPreviewText.Contains("Missing Source Manifest References") -and
    -not $reportPreviewText.Contains("System.Collections") -and
    -not $reportPreviewText.Contains("@{")

Add-DocsCheck "release_docs_report_content" `
    $reportContentValidated `
    "Docs freshness Markdown must be readable and include pipeline coverage plus source-manifest reference coverage without object dumps."

$failedChecks = @($checks | Where-Object { -not [bool]$_["passed"] })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }
$docsFresh = $status -eq "PASS"

$changedSourceFileList = Compare-StringSetDelta -Previous $previousReleaseDocsFreshnessSourceFiles -Current $sourceFiles -Name "sourceFiles"
$requiredDocFilesDelta = Compare-StringSetDelta -Previous $previousReleaseDocsFreshnessRequiredDocFiles -Current $requiredDocFiles -Name "requiredDocFiles"
$missingStepDocsDelta = Compare-StringSetDelta -Previous $previousReleaseDocsFreshnessMissingStepDocs -Current $missingPipelineStepDocs -Name "missingStepDocs"

$changedPipelineStepCountDelta = [int]($pipelineSteps.Count - $previousReleaseDocsFreshnessPipelineStepCount)
$driftHasSourceChanges = (Get-SafeCount $changedSourceFileList.changedSourceFileList) -gt 0 -or `
    (Get-SafeCount $requiredDocFilesDelta.changedSourceFileList) -gt 0 -or `
    (Get-SafeCount $missingStepDocsDelta.changedSourceFileList) -gt 0
$driftHasAnyCountDelta = $driftHasSourceChanges -or ($changedPipelineStepCountDelta -ne 0)

$driftType = if (-not $previousReleaseDocsFreshnessManifestPresent) {
    "Stable"
}
elseif ($changedPipelineStepCountDelta -gt 0 -and (Get-SafeCount $requiredDocFilesDelta.added) -gt 0 -and (Get-SafeCount $requiredDocFilesDelta.removed) -eq 0 -and `
    -not $driftHasSourceChanges) {
    "Added"
}
elseif ($changedPipelineStepCountDelta -lt 0 -and (Get-SafeCount $requiredDocFilesDelta.removed) -gt 0 -and (Get-SafeCount $requiredDocFilesDelta.added) -eq 0 -and `
    -not $driftHasSourceChanges) {
    "Removed"
}
elseif ($driftHasAnyCountDelta) {
    "Changed"
}
else {
    "Stable"
}

$driftReportGeneratedAtUtc = (Get-Date).ToUniversalTime().ToString("O")

$driftReportLines = @(
    "# Release Docs Freshness Drift Report",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Drift type | $(Format-MarkdownCell $driftType) |",
    "| Report generated at (UTC) | $(Format-MarkdownCell $driftReportGeneratedAtUtc) |",
    "| Previous manifest path | $(Format-MarkdownCell (Convert-ToRepoRelativePath $previousReleaseDocsFreshnessManifestPath)) |",
    "| Changed pipeline step count delta | $(Format-MarkdownCell $changedPipelineStepCountDelta) |",
    "| Current pipeline step count | $(Format-MarkdownCell $pipelineSteps.Count) |",
    "| Previous pipeline step count | $(Format-MarkdownCell $previousReleaseDocsFreshnessPipelineStepCount) |",
    "| Current required doc file count | $(Format-MarkdownCell $requiredDocFiles.Count) |",
    "| Previous required doc file count | $(Format-MarkdownCell $previousReleaseDocsFreshnessRequiredDocFilesCount) |",
    "| Current source file count | $(Format-MarkdownCell $sourceFiles.Count) |",
    "| Previous source file count | $(Format-MarkdownCell $previousReleaseDocsFreshnessSourceFilesCount) |"
)

$driftReportLines += @(
    "",
    "## Changed source files",
    "",
    "| File | Change | Prev Index | Curr Index |",
    "| --- | --- | --- | --- |"
)
foreach ($entry in $changedSourceFileList.changedSourceFileList) {
    $driftReportLines += "| $(Format-MarkdownCell $entry.name) | $(Format-MarkdownCell $entry.change) | $($entry.previousIndex) | $($entry.currentIndex) |"
}
if ((Get-SafeCount $changedSourceFileList.changedSourceFileList) -eq 0) {
    $driftReportLines += "| None | None |  |  |"
}

$driftReportLines += @(
    "",
    "## Required doc file delta",
    "",
    "| File | Change | Prev Index | Curr Index |",
    "| --- | --- | --- | --- |"
)
foreach ($entry in $requiredDocFilesDelta.changedSourceFileList) {
    $driftReportLines += "| $(Format-MarkdownCell $entry.name) | $(Format-MarkdownCell $entry.change) | $($entry.previousIndex) | $($entry.currentIndex) |"
}
if ((Get-SafeCount $requiredDocFilesDelta.changedSourceFileList) -eq 0) {
    $driftReportLines += "| None | None |  |  |"
}

$driftReportLines += @(
    "",
    "## Missing pipeline step docs delta",
    "",
    "| Step | Change | Prev Index | Curr Index |",
    "| --- | --- | --- | --- |"
)
foreach ($entry in $missingStepDocsDelta.changedSourceFileList) {
    $driftReportLines += "| $(Format-MarkdownCell $entry.name) | $(Format-MarkdownCell $entry.change) | $($entry.previousIndex) | $($entry.currentIndex) |"
}
if ((Get-SafeCount $missingStepDocsDelta.changedSourceFileList) -eq 0) {
    $driftReportLines += "| None | None |  |  |"
}

$driftReportLines += ""
$driftReportLines += "## Pipeline step drift snapshot"
$driftReportLines += ""
$driftReportLines += "* Pipeline step count change: $changedPipelineStepCountDelta"
$driftReportLines += "* Missing pipeline step docs current: $($missingPipelineStepDocs.Count)"
$driftReportLines += "* Missing pipeline step docs previous: $(Get-SafeCount $previousReleaseDocsFreshnessMissingStepDocs)"
$driftReportLines += "* Previous manifest present: $previousReleaseDocsFreshnessManifestPresent"
$reportLines = @(
    "# Release Docs Freshness",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Status | $(Format-MarkdownCell $status) |",
    "| Pipeline source steps | $($pipelineSteps.Count) |",
    "| Documented pipeline steps | $($pipelineSteps.Count - $missingPipelineStepDocs.Count) |",
    "| Missing pipeline step docs | $($missingPipelineStepDocs.Count) |",
    "| Missing required artifact docs | $($missingRequiredArtifactDocs.Count) |",
    "| Missing required doc strings | $($missingRequiredDocStrings.Count) |",
    "| Missing source manifest references | $($missingSourceManifestReferences.Count) |",
    "| Source files checked | $($sourceFiles.Count) |",
    "| Missing source files | $($missingSourceFiles.Count) |",
    "| Hard-mode default source probe failures | $($hardModeDefaultSourceProbeFailures.Count) |",
    "| Previous artifact pipeline status | $(Format-MarkdownCell $previousArtifactPipelineStatus) |",
    "| Previous artifact pipeline step count | $previousArtifactPipelineStepCount |",
    "| Release docs drift type | $(Format-MarkdownCell $driftType) |",
    "| Release docs drift source file changes | $(Get-SafeCount $changedSourceFileList.changedSourceFileList) |",
    "| Release docs required doc file changes | $(Get-SafeCount $requiredDocFilesDelta.changedSourceFileList) |",
    "| Missing step docs delta changes | $(Get-SafeCount $missingStepDocsDelta.changedSourceFileList) |",
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

$reportLines += @(
    "",
    "## Missing Pipeline Step Docs",
    "",
    "| Step ID |",
    "| --- |"
)
foreach ($step in $missingPipelineStepDocs) {
    $reportLines += "| ``$(Format-MarkdownCell $step)`` |"
}
if ($missingPipelineStepDocs.Count -eq 0) {
    $reportLines += "| None |"
}

$reportLines += @(
    "",
    "## Missing Source Manifest References",
    "",
    "| Script | Manifest |",
    "| --- | --- |"
)
foreach ($missingReference in $missingSourceManifestReferences) {
    $reportLines += "| $(Format-MarkdownCell $missingReference.script) | $(Format-MarkdownCell $missingReference.manifest) |"
}
if ($missingSourceManifestReferences.Count -eq 0) {
    $reportLines += "| None | None |"
}

New-Item -ItemType Directory -Force (Split-Path $reportFullPath -Parent) | Out-Null
$reportLines | Set-Content -Path $reportFullPath -Encoding UTF8
$driftReportLines | Set-Content -Path $driftReportFullPath -Encoding UTF8

$driftManifest = [ordered]@{
    schemaVersion = "aitestpilot.release_docs_freshness_drift.v1"
    status = $status
    driftType = $driftType
    reportGeneratedAtUtc = $driftReportGeneratedAtUtc
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    previousManifestPath = (Convert-ToRepoRelativePath $previousReleaseDocsFreshnessManifestPath)
    previousManifestPresent = [bool]$previousReleaseDocsFreshnessManifestPresent
    changedPipelineStepCountDelta = [int]$changedPipelineStepCountDelta
    previousPipelineStepCount = [int]$previousReleaseDocsFreshnessPipelineStepCount
    currentPipelineStepCount = [int]$pipelineSteps.Count
    changedSourceFileList = @($changedSourceFileList.changedSourceFileList)
    requiredDocFilesDelta = @($requiredDocFilesDelta.changedSourceFileList)
    missingStepDocsDelta = @($missingStepDocsDelta.changedSourceFileList)
    sourceFilesCurrent = @($sourceFiles)
    sourceFilesPrevious = @($previousReleaseDocsFreshnessSourceFiles)
    requiredDocFilesCurrent = @($requiredDocFiles)
    requiredDocFilesPrevious = @($previousReleaseDocsFreshnessRequiredDocFiles)
    generatedFiles = @(
        (Convert-ToEvidenceRelativePath $driftManifestFullPath),
        (Convert-ToEvidenceRelativePath $driftReportFullPath)
    )
    previousManifestReadable = [bool]$previousReleaseDocsFreshnessManifestReadable
}

$driftManifest | ConvertTo-Json -Depth 12 | Set-Content -Path $driftManifestFullPath -Encoding UTF8

$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestFullPath),
    (Convert-ToEvidenceRelativePath $reportFullPath),
    (Convert-ToEvidenceRelativePath $driftManifestFullPath),
    (Convert-ToEvidenceRelativePath $driftReportFullPath)
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.release_docs_freshness.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    docsFresh = [bool]$docsFresh
    pipelineSourcePath = (Convert-ToRepoRelativePath $pipelineSourcePath)
    pipelineSourceStepCount = [int]$pipelineSteps.Count
    pipelineStepCount = [int]$pipelineSteps.Count
    documentedPipelineStepCount = [int]($pipelineSteps.Count - $missingPipelineStepDocs.Count)
    missingPipelineStepDocCount = [int]$missingPipelineStepDocs.Count
    missingPipelineStepDocs = @($missingPipelineStepDocs)
    pipelineStepDocCoverage = @($pipelineStepDocCoverage)
    requiredDocFiles = @($requiredDocFiles)
    requiredDocFileMissingCount = [int]$missingDocFiles.Count
    missingDocFiles = @($missingDocFiles)
    requiredArtifactNames = @($requiredArtifactNames)
    missingRequiredArtifactDocCount = [int]$missingRequiredArtifactDocs.Count
    missingRequiredArtifactDocs = @($missingRequiredArtifactDocs)
    requiredDocStringCount = [int]$requiredDocStrings.Count
    missingRequiredDocStringCount = [int]$missingRequiredDocStrings.Count
    missingRequiredDocStrings = @($missingRequiredDocStrings)
    sourceManifestListAligned = [bool]$sourceManifestListAligned
    sourceFilesPresent = [bool]($missingSourceFiles.Count -eq 0)
    sourceFileCount = [int]$sourceFiles.Count
    sourceFileMissingCount = [int]$missingSourceFiles.Count
    missingSourceFiles = @($missingSourceFiles)
    blockingReasonCount = [int]$failedChecks.Count
    requiredSourceManifestNames = @($requiredSourceManifestNames)
    sourceManifestScripts = @($sourceManifestScripts)
    missingSourceManifestReferenceCount = [int]$missingSourceManifestReferences.Count
    missingSourceManifestReferences = @($missingSourceManifestReferences)
    hardModeDefaultSourceProbeScripts = @($hardModeDefaultSourceProbeScripts)
    hardModeDefaultSourceProbeFailureCount = [int]$hardModeDefaultSourceProbeFailures.Count
    hardModeDefaultSourceProbeCoverage = @($hardModeDefaultSourceProbeCoverage)
    previousArtifactPipelineManifestPresent = [bool]$previousArtifactPipelineManifestPresent
    previousArtifactPipelineManifestPath = (Convert-ToRepoRelativePath $previousArtifactPipelineManifestPath)
    previousArtifactPipelineStatus = $previousArtifactPipelineStatus
    previousArtifactPipelineStepCount = [int]$previousArtifactPipelineStepCount
    previousArtifactPipelineManifestReadable = [bool]$previousArtifactPipelineManifestReadable
    reportGenerated = (Test-Path $reportFullPath)
    reportContentValidated = [bool]$reportContentValidated
    releasePipelineSendsEmail = $false
    realHostProjectEvidenceAccepted = $false
    externalEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "release_docs_freshness_only"
    sourceFiles = @($sourceFiles)
    driftType = $driftType
    changedPipelineStepCountDelta = [int]$changedPipelineStepCountDelta
    changedSourceFileList = @($changedSourceFileList.changedSourceFileList)
    requiredDocFilesDelta = @($requiredDocFilesDelta.changedSourceFileList)
    missingStepDocsDelta = @($missingStepDocsDelta.changedSourceFileList)
    previousReleaseDocsFreshnessManifestPresent = [bool]$previousReleaseDocsFreshnessManifestPresent
    previousReleaseDocsFreshnessManifestReadable = [bool]$previousReleaseDocsFreshnessManifestReadable
    previousReleaseDocsFreshnessManifestPath = (Convert-ToRepoRelativePath $previousReleaseDocsFreshnessManifestPath)
    generatedFiles = @($generatedFiles)
    documentedFiles = @($documentedFiles)
    files = @($generatedFiles)
    blockingReasons = @($failedChecks | ForEach-Object { $_.name })
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
}

$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestFullPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Release docs freshness failed: $($failedChecks.name -join ', ')"
}

Write-Output "Release docs freshness manifest: $manifestFullPath"
Write-Output "Release docs freshness report: $reportFullPath"
Write-Output "Release docs freshness drift manifest: $driftManifestFullPath"
Write-Output "Release docs freshness drift report: $driftReportFullPath"
Write-Output "PASS AI TestPilot release docs freshness probe"
