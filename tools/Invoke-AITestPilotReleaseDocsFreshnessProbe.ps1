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
    $ManifestPath = Join-Path $EvidenceBundleDir "release-docs-freshness-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "release-docs-freshness.md"
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
        throw "File must stay under evidence bundle: $fullPath"
    }

    return $fullPath.Substring($evidenceBundlePath.Length).TrimStart([char[]]@("\", "/")).Replace("\", "/")
}

function Convert-ToRepoRelativePath {
    param([string]$Path)

    $fullPath = Resolve-FullPath $Path
    if (-not $fullPath.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
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

function Format-MarkdownCell {
    param([object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    return ([string]$Value).Replace("|", "\|").Replace("`r", " ").Replace("`n", "<br>")
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"

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
    "production-external-evidence-semantic-preflight-probe-manifest.json",
    "production-external-evidence-auto-acceptance-probe-manifest.json",
    "release-docs-freshness-manifest.json"
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
    [ordered]@{ file = "README.md"; pattern = "artifacts\ai-testpilot-release\latest"; label = "stable latest artifact path" },
    [ordered]@{ file = "README.md"; pattern = "production-handoff-export-zip-index-manifest.json"; label = "handoff zip index artifact" },
    [ordered]@{ file = "README.md"; pattern = "production-external-evidence-auto-acceptance-probe-manifest.json"; label = "auto acceptance probe artifact" },
    [ordered]@{ file = "README.md"; pattern = "complete owner response bundle zip, partial zip, semantic-bad zip, and arbitrary single top-level wrapper zip"; label = "owner response bundle zip case set" },
    [ordered]@{ file = "README.md"; pattern = "caseCount=9"; label = "semantic preflight case count target" },
    [ordered]@{ file = "README.md"; pattern = "completeCandidateCaseCount=4"; label = "semantic preflight candidate case count target" },
    [ordered]@{ file = "README.md"; pattern = "rejectedCaseCount=5"; label = "semantic preflight rejected case count target" },
    [ordered]@{ file = "README.md"; pattern = "checkCount=11"; label = "semantic preflight check count target" },
    [ordered]@{ file = "README.md"; pattern = "ownerResponseBundleZipCaseCount=4"; label = "owner response bundle zip case count target" },
    [ordered]@{ file = "README.md"; pattern = "ownerResponseBundleZipSafeCaseCount=4"; label = "owner response bundle zip safe case count target" },
    [ordered]@{ file = "README.md"; pattern = "ownerResponseBundleZipUnsafeCaseCount=0"; label = "owner response bundle zip unsafe case count target" },
    [ordered]@{ file = "README.md"; pattern = "ownerResponseBundleZipArbitraryWrapperReady=true"; label = "owner response bundle zip arbitrary wrapper readiness" },
    [ordered]@{ file = "README.md"; pattern = "production-handoff-send-local-workflow-probe-manifest.json"; label = "owner packet local workflow probe artifact" },
    [ordered]@{ file = "README.md"; pattern = "production-handoff-owner-packet-dispatch-receipt-intake-probe-manifest.json"; label = "owner packet dispatch receipt intake probe artifact" },
    [ordered]@{ file = "README.md"; pattern = "production-handoff-owner-packet-real-receipt-guard-probe-manifest.json"; label = "owner packet real receipt guard probe artifact" },
    [ordered]@{ file = "README.md"; pattern = "Invoke-AITestPilotProductionHandoffOwnerRouteMap.ps1"; label = "owner route map command" },
    [ordered]@{ file = "README.md"; pattern = "production-handoff-owner-route-map-manifest.json"; label = "owner route map artifact" },
    [ordered]@{ file = "README.md"; pattern = "Invoke-AITestPilotProductionHandoffOwnerRouteMapProbe.ps1"; label = "owner route map probe command" },
    [ordered]@{ file = "README.md"; pattern = "production-handoff-owner-route-map-probe-manifest.json"; label = "owner route map probe artifact" },
    [ordered]@{ file = "README.md"; pattern = "Invoke-AITestPilotReleaseEvidenceIndexFieldCoverageProbe.ps1"; label = "release evidence index field coverage probe command" },
    [ordered]@{ file = "README.md"; pattern = "release evidence index field coverage"; label = "release evidence index field coverage overview" },
    [ordered]@{ file = "README.md"; pattern = "Invoke-AITestPilotCursorAgentExternalOutputBindingProbe.ps1"; label = "Cursor Agent external output binding probe command" },
    [ordered]@{ file = "README.md"; pattern = "repair-agent-cursor-agent-external-output-binding-probe-manifest.json"; label = "Cursor Agent external output binding probe artifact" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "Release Pipeline Step Index"; label = "machine checked step index section" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "release_evidence_index_field_coverage_probe"; label = "field coverage pipeline step" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "repair_agent_cursor_agent_external_output_binding_probe"; label = "Cursor Agent external output binding pipeline step" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "release-evidence-index-field-coverage-probe-manifest.json"; label = "field coverage pipeline artifact" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "repair-agent-cursor-agent-external-output-binding-probe-manifest.json"; label = "Cursor Agent external output binding pipeline artifact" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "production-handoff-send-local-workflow-probe-manifest.json"; label = "owner packet local workflow pipeline artifact" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "production-handoff-owner-packet-dispatch-receipt-intake-probe-manifest.json"; label = "owner packet dispatch receipt intake pipeline artifact" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "production-handoff-owner-packet-real-receipt-guard-probe-manifest.json"; label = "owner packet real receipt guard pipeline artifact" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "production_handoff_owner_route_map"; label = "owner route map pipeline step" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "production_handoff_owner_route_map_probe"; label = "owner route map probe pipeline step" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "production-handoff-owner-route-map-manifest.json"; label = "owner route map pipeline artifact" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "production-handoff-owner-route-map-probe-manifest.json"; label = "owner route map probe pipeline artifact" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "release-docs-freshness-manifest.json"; label = "docs freshness artifact" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "OwnerResponseBundleZipPath"; label = "owner response bundle zip parameter" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "unsafe, duplicate, absolute, or traversal zip entries are rejected"; label = "owner response bundle zip safety rejection" },
    [ordered]@{ file = "docs/ci-release-pipeline.md"; pattern = "ownerResponseBundleZipSafeCaseCount=4"; label = "owner response bundle zip safe case count" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "Invoke-AITestPilotReleasePipeline.ps1"; label = "pipeline architecture reference" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "release risk policy"; label = "risk policy architecture reference" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "release evidence index"; label = "evidence index architecture reference" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "release evidence index field coverage"; label = "field coverage architecture reference" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "Cursor Agent external output binding"; label = "Cursor Agent external output binding architecture reference" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "release gate"; label = "gate architecture reference" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "production handoff"; label = "production handoff architecture reference" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "production-handoff-send-local-workflow-probe-manifest.json"; label = "owner packet local workflow architecture artifact" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "production-handoff-owner-packet-dispatch-receipt-intake-probe-manifest.json"; label = "owner packet dispatch receipt intake architecture artifact" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "production-handoff-owner-packet-real-receipt-guard-probe-manifest.json"; label = "owner packet real receipt guard architecture artifact" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "production handoff owner route map"; label = "owner route map architecture reference" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "production-handoff-owner-route-map-manifest.json"; label = "owner route map architecture artifact" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "production-handoff-owner-route-map-probe-manifest.json"; label = "owner route map probe architecture artifact" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "OwnerResponseBundleZipPath"; label = "owner response bundle zip architecture reference" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "unsafe/duplicate/absolute/traversal zip rejection"; label = "owner response bundle zip safety architecture reference" },
    [ordered]@{ file = "docs/architecture.md"; pattern = "ownerResponseBundleZipUnsafeCaseCount=0"; label = "owner response bundle zip unsafe case count" },
    [ordered]@{ file = "docs/roadmap.md"; pattern = "release docs freshness"; label = "roadmap freshness guard reference" },
    [ordered]@{ file = "docs/roadmap.md"; pattern = "release evidence index field coverage"; label = "roadmap field coverage reference" },
    [ordered]@{ file = "docs/roadmap.md"; pattern = "Cursor Agent external output binding"; label = "roadmap Cursor Agent external output binding reference" },
    [ordered]@{ file = "docs/roadmap.md"; pattern = "owner send local workflow proof"; label = "roadmap owner send local workflow proof" },
    [ordered]@{ file = "docs/roadmap.md"; pattern = "owner packet real receipt guard proof"; label = "roadmap owner packet real receipt guard proof" },
    [ordered]@{ file = "docs/roadmap.md"; pattern = "production handoff owner route map"; label = "roadmap owner route map reference" },
    [ordered]@{ file = "docs/roadmap.md"; pattern = "production handoff owner route map and probe"; label = "roadmap owner route map probe reference" }
)
$missingRequiredDocStrings = @()
foreach ($requiredDocString in $requiredDocStrings) {
    $file = [string]$requiredDocString.file
    $pattern = [string]$requiredDocString.pattern
    $text = [string]$docTexts[$file]
    if (-not $text.Contains($pattern)) {
        $missingRequiredDocStrings += [ordered]@{
            file = $file
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
    "tools/Invoke-AITestPilotReleaseGate.ps1",
    "tools/Invoke-AITestPilotProductionHardModeFailureProbe.ps1"
)
$requiredSourceManifestNames = @(
    "production-handoff-export-zip-index-manifest.json",
    "production-handoff-send-local-workflow-probe-manifest.json",
    "production-handoff-owner-packet-dispatch-receipt-intake-probe-manifest.json",
    "production-handoff-owner-packet-real-receipt-guard-probe-manifest.json",
    "production-external-evidence-action-queue-manifest.json",
    "production-external-evidence-action-queue-probe-manifest.json",
    "production-external-evidence-gap-analysis-manifest.json",
    "production-external-evidence-partial-matrix-probe-manifest.json",
    "production-external-evidence-semantic-preflight-probe-manifest.json",
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
    "Risk policy, evidence index, release gate, and hard-mode copied-bundle source manifest lists must reference current pre-risk manifests."

$latestPipelineManifestPath = Join-Path $repoRoot "artifacts\ai-testpilot-release\latest\pipeline-manifest.json"
$latestPipelineManifest = Read-JsonFile $latestPipelineManifestPath
$artifactPipelineStatus = [string](Get-JsonValue $latestPipelineManifest "status" "")
$artifactPipelineStepCount = [int](Get-JsonValue $latestPipelineManifest "stepCount" 0)
$artifactPipelineManifestPresent = $null -ne $latestPipelineManifest

Add-DocsCheck "latest_pipeline_manifest_readable_when_present" `
    ((-not $artifactPipelineManifestPresent) -or ($artifactPipelineStatus.Length -gt 0 -and $artifactPipelineStepCount -gt 0)) `
    "Latest copied artifact pipeline manifest is optional for the probe, but must be readable when present."

$reportPreviewLines = @(
    "# Release Docs Freshness",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Status | PREVIEW |",
    "| Pipeline source steps | $($pipelineSteps.Count) |",
    "| Missing Pipeline Step Docs | $($missingPipelineStepDocs.Count) |",
    "| Missing Source Manifest References | $($missingSourceManifestReferences.Count) |"
)
$reportPreviewText = $reportPreviewLines -join [Environment]::NewLine
$reportContentValidated = $reportPreviewText.Contains("Release Docs Freshness") -and
    $reportPreviewText.Contains("Pipeline source steps") -and
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
    "| Latest artifact pipeline status | $(Format-MarkdownCell $artifactPipelineStatus) |",
    "| Latest artifact pipeline step count | $artifactPipelineStepCount |",
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

$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestFullPath),
    (Convert-ToEvidenceRelativePath $reportFullPath)
)
$sourceFiles = @()
$documentedFiles = @(
    "README.md",
    "docs/ci-release-pipeline.md",
    "docs/architecture.md",
    "docs/roadmap.md",
    "tools/Invoke-AITestPilotReleasePipeline.ps1",
    "tools/Invoke-AITestPilotReleaseRiskPolicy.ps1",
    "tools/Invoke-AITestPilotReleaseEvidenceIndex.ps1",
    "tools/Invoke-AITestPilotReleaseGate.ps1",
    "tools/Invoke-AITestPilotProductionHardModeFailureProbe.ps1"
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
    blockingReasonCount = [int]$failedChecks.Count
    requiredSourceManifestNames = @($requiredSourceManifestNames)
    sourceManifestScripts = @($sourceManifestScripts)
    missingSourceManifestReferenceCount = [int]$missingSourceManifestReferences.Count
    missingSourceManifestReferences = @($missingSourceManifestReferences)
    latestPipelineManifestPresent = [bool]$artifactPipelineManifestPresent
    latestPipelineManifestPath = (Convert-ToRepoRelativePath $latestPipelineManifestPath)
    latestPipelineStatus = $artifactPipelineStatus
    latestPipelineStepCount = [int]$artifactPipelineStepCount
    reportGenerated = (Test-Path $reportFullPath)
    reportContentValidated = [bool]$reportContentValidated
    releasePipelineSendsEmail = $false
    realHostProjectEvidenceAccepted = $false
    externalEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "release_docs_freshness_only"
    sourceFiles = @($sourceFiles)
    generatedFiles = @($generatedFiles)
    documentedFiles = @($documentedFiles)
    files = @($generatedFiles + $sourceFiles)
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
Write-Output "PASS AI TestPilot release docs freshness probe"
