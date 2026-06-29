[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$IndexPath,
    [string]$ReportPath,
    [string]$ManifestPath,
    [string[]]$SourceManifestNames,
    [switch]$RequireProductionReplayDriverBound,
    [switch]$RequireProductionLuaPatched,
    [switch]$RequireLiveModelEndpointSmoke
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($IndexPath)) {
    $IndexPath = Join-Path $EvidenceBundleDir "release-evidence-index.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "release-evidence-index.md"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "release-evidence-index-manifest.json"
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

function Get-JsonValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$DefaultValue = $null
    )

    if ($null -eq $Object) {
        return $DefaultValue
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

function Convert-ToInt {
    param([object]$Value)

    if ($null -eq $Value) {
        return 0
    }

    return [int]$Value
}

function Test-StatusAccepted {
    param(
        [string]$ManifestName,
        [string]$Status
    )

    if ($Status -eq "PASS") {
        return $true
    }

    if ($ManifestName -eq "live-model-endpoint-smoke-manifest.json" -and
        $Status -eq "SKIPPED" -and
        -not [bool]$RequireLiveModelEndpointSmoke) {
        return $true
    }

    return $false
}

function Read-ManifestEntry {
    param(
        [string]$FileName,
        [bool]$SourceManifest
    )

    $path = Join-Path $evidenceBundlePath $FileName
    $exists = Test-Path $path
    $parseable = $false
    $manifest = $null
    $parseError = ""

    if ($exists) {
        try {
            $manifest = Get-Content -Path $path -Encoding UTF8 -Raw | ConvertFrom-Json
            $parseable = $true
        }
        catch {
            $parseError = $_.Exception.Message
        }
    }

    $schemaVersion = ""
    $status = ""
    $allowRelease = $null
    $blockingReasonCount = 0
    $failedReasonCount = 0
    $listedFiles = @()
    $listedFileCount = 0
    $listedFilePresentCount = 0
    $missingListedFiles = @()

    if ($parseable) {
        $schemaVersion = [string](Get-JsonValue $manifest "schemaVersion" "")
        $status = [string](Get-JsonValue $manifest "status" "")
        $allowRelease = Get-JsonValue $manifest "allowRelease" $null
        $blockingReasonCount = Convert-ToInt (Get-JsonValue $manifest "blockingReasonCount" 0)
        $failedReasonCount = Convert-ToInt (Get-JsonValue $manifest "failedReasonCount" 0)
        $listedFiles = @(Convert-ToArray (Get-JsonValue $manifest "files" $null))
        $listedFileCount = $listedFiles.Count

        foreach ($listedFile in $listedFiles) {
            $listedPath = Join-Path $evidenceBundlePath ([string]$listedFile)
            if (Test-Path $listedPath) {
                $listedFilePresentCount += 1
            }
            else {
                $missingListedFiles += [string]$listedFile
            }
        }
    }

    $statusAccepted = $false
    if ($parseable) {
        $statusAccepted = Test-StatusAccepted $FileName $status
    }

    return [pscustomobject][ordered]@{
        name = $FileName
        sourceManifest = [bool]$SourceManifest
        exists = [bool]$exists
        parseable = [bool]$parseable
        status = $status
        statusAccepted = [bool]$statusAccepted
        schemaVersion = $schemaVersion
        allowRelease = $allowRelease
        blockingReasonCount = [int]$blockingReasonCount
        failedReasonCount = [int]$failedReasonCount
        listedFileCount = [int]$listedFileCount
        listedFilePresentCount = [int]$listedFilePresentCount
        missingListedFileCount = [int]$missingListedFiles.Count
        missingListedFiles = @($missingListedFiles)
        parseError = $parseError
    }
}

function Get-DefaultSourceManifestNames {
    $names = @(
        "manifest.json",
        "repair-agent-patch-output-manifest.json",
        "repair-agent-external-completion-failure-probe-manifest.json",
        "repair-agent-generic-patch-import-probe-manifest.json",
        "repair-agent-source-snapshot-apply-validate-manifest.json",
        "repair-agent-main-worktree-apply-readiness-manifest.json",
        "repair-agent-main-worktree-apply-retest-rollback-manifest.json",
        "repair-agent-external-task-output-acceptance-manifest.json",
        "repair-agent-patch-result-analysis-manifest.json",
        "repair-agent-patch-result-history-manifest.json",
        "repair-agent-external-patch-preflight-manifest.json",
        "repair-agent-external-patch-preflight-failure-probe-manifest.json",
        "repair-agent-repository-patch-apply-guard-manifest.json",
        "repair-agent-repository-patch-apply-clean-probe-manifest.json",
        "repair-agent-repository-patch-apply-clean-retest-manifest.json",
        "repair-agent-patch-apply-retest-manifest.json",
        "repair-retest-manifest.json",
        "repair-driver-failure-manifest.json",
        "replay-profile-import-manifest.json",
        "production-replay-integration-contract-probe-manifest.json",
        "production-driver-binding-kit-manifest.json",
        "production-driver-evidence-contract-probe-manifest.json",
        "production-replay-driver-readiness-manifest.json",
        "production-driver-evidence-intake-manifest.json",
        "production-driver-external-bundle-intake-probe-manifest.json",
        "model-endpoint-trace-manifest.json",
        "model-endpoint-provider-diagnostics-manifest.json",
        "model-endpoint-provider-retry-policy-manifest.json",
        "live-model-endpoint-config-kit-probe-manifest.json",
        "lua-static-analysis-manifest.json",
        "lua-auto-patch-sandbox-manifest.json",
        "production-lua-patch-readiness-manifest.json",
        "production-lua-patch-evidence-kit-probe-manifest.json",
        "production-lua-patch-external-bundle-intake-probe-manifest.json",
        "live-model-endpoint-failure-probe-manifest.json",
        "live-model-endpoint-smoke-manifest.json",
        "live-model-endpoint-external-smoke-intake-probe-manifest.json",
        "live-model-endpoint-smoke-evidence-contract-probe-manifest.json",
        "github-actions-release-workflow-probe-manifest.json",
        "azure-pipelines-release-workflow-probe-manifest.json",
        "provider-ci-quality-probe-manifest.json",
        "production-handoff-package-manifest.json",
        "production-handoff-external-evidence-preflight-probe-manifest.json",
        "production-handoff-export-manifest.json",
        "production-handoff-status-manifest.json",
        "production-handoff-dispatch-manifest.json",
        "production-handoff-contact-readiness-manifest.json",
        "production-handoff-contact-readiness-contract-probe-manifest.json",
        "production-handoff-send-readiness-manifest.json",
        "production-handoff-mail-auth-readiness-manifest.json",
        "production-external-evidence-acceptance-contract-probe-manifest.json",
        "production-external-evidence-acceptance-failure-probe-manifest.json",
        "production-external-evidence-inbox-manifest.json",
        "production-external-evidence-inbox-contract-probe-manifest.json",
        "production-hard-mode-failure-probe-manifest.json",
        "release-risk-policy-manifest.json"
    )

    $cursorAgentManifest = Join-Path $evidenceBundlePath "repair-agent-cursor-agent-external-output-manifest.json"
    if (Test-Path $cursorAgentManifest) {
        $names += "repair-agent-cursor-agent-external-output-manifest.json"
    }

    if (-not [bool]$RequireProductionReplayDriverBound) {
        $names += "production-replay-driver-bound-failure-probe-manifest.json"
    }

    if (-not [bool]$RequireProductionLuaPatched) {
        $names += "production-lua-patch-bound-failure-probe-manifest.json"
    }

    return @($names)
}

function Get-DedupedNames {
    param([string[]]$Names)

    $seen = @{}
    $deduped = @()
    foreach ($name in $Names) {
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        if (-not $seen.ContainsKey($name)) {
            $seen[$name] = $true
            $deduped += $name
        }
    }

    return @($deduped)
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$indexFullPath = Assert-PathUnderRepo $IndexPath "IndexPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if ($null -eq $SourceManifestNames -or $SourceManifestNames.Count -eq 0) {
    $SourceManifestNames = @(Get-DefaultSourceManifestNames)
}

$SourceManifestNames = @(Get-DedupedNames $SourceManifestNames)
$sourceNameSet = @{}
foreach ($name in $SourceManifestNames) {
    $sourceNameSet[$name] = $true
}

$sourceEntries = @()
foreach ($name in $SourceManifestNames) {
    $sourceEntries += Read-ManifestEntry -FileName $name -SourceManifest $true
}

$allManifestEntries = @()
$manifestFiles = @(Get-ChildItem -Path $evidenceBundlePath -Filter "*manifest.json" -File | Sort-Object -Property Name)
foreach ($file in $manifestFiles) {
    $isSourceManifest = $sourceNameSet.ContainsKey($file.Name)
    $allManifestEntries += Read-ManifestEntry -FileName $file.Name -SourceManifest $isSourceManifest
}

$missingSourceEntries = @($sourceEntries | Where-Object { -not [bool]$_.exists })
$unparseableSourceEntries = @($sourceEntries | Where-Object { [bool]$_.exists -and -not [bool]$_.parseable })
$failedSourceEntries = @($sourceEntries | Where-Object { [bool]$_.parseable -and [string]$_.status -eq "FAIL" })
$blockedSourceEntries = @($sourceEntries | Where-Object { [bool]$_.parseable -and [string]$_.status -eq "BLOCKED" })
$skippedSourceEntries = @($sourceEntries | Where-Object { [bool]$_.parseable -and [string]$_.status -eq "SKIPPED" })
$unacceptedSourceEntries = @($sourceEntries | Where-Object { [bool]$_.parseable -and -not [bool]$_.statusAccepted })
$missingListedFiles = @()
foreach ($entry in $sourceEntries) {
    foreach ($fileName in @($entry.missingListedFiles)) {
        $missingListedFiles += [string]$entry.name + ":" + [string]$fileName
    }
}

$blockingReasons = @()
if ($missingSourceEntries.Count -gt 0) {
    $blockingReasons += "source_manifest_missing"
}
if ($unparseableSourceEntries.Count -gt 0) {
    $blockingReasons += "source_manifest_unparseable"
}
if ($failedSourceEntries.Count -gt 0) {
    $blockingReasons += "source_manifest_failed"
}
if ($blockedSourceEntries.Count -gt 0) {
    $blockingReasons += "source_manifest_blocked"
}
if ($unacceptedSourceEntries.Count -gt 0) {
    $blockingReasons += "source_manifest_status_not_accepted"
}
if ($missingListedFiles.Count -gt 0) {
    $blockingReasons += "source_manifest_listed_file_missing"
}

$status = "PASS"
if ($blockingReasons.Count -gt 0) {
    $status = "BLOCKED"
}

$generatedFiles = @(
    "release-evidence-index-manifest.json",
    "release-evidence-index.json",
    "release-evidence-index.md"
)

$allAuxiliaryEntries = @($allManifestEntries | Where-Object { -not [bool]$_.sourceManifest })
$releaseGateManifestIncluded = Test-Path (Join-Path $evidenceBundlePath "release-gate-manifest.json")
$pipelineManifestIncluded = Test-Path (Join-Path $evidenceBundlePath "pipeline-manifest.json")

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.release_evidence_index.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    source = "release_evidence_bundle_source_manifest_index"
    machineReadable = $true
    portalHandoffReady = ($status -eq "PASS")
    requireProductionReplayDriverBound = [bool]$RequireProductionReplayDriverBound
    requireProductionLuaPatched = [bool]$RequireProductionLuaPatched
    requireLiveModelEndpointSmoke = [bool]$RequireLiveModelEndpointSmoke
    evidenceBundlePath = $evidenceBundlePath
    requiredSourceManifestCount = [int]$SourceManifestNames.Count
    indexedSourceManifestCount = [int]@($sourceEntries | Where-Object { [bool]$_.exists -and [bool]$_.parseable }).Count
    sourceManifestCoverageCount = [int]@($sourceEntries | Where-Object { [bool]$_.exists -and [bool]$_.parseable -and [bool]$_.statusAccepted }).Count
    missingSourceManifestCount = [int]$missingSourceEntries.Count
    unparseableSourceManifestCount = [int]$unparseableSourceEntries.Count
    failedSourceManifestCount = [int]$failedSourceEntries.Count
    blockedSourceManifestCount = [int]$blockedSourceEntries.Count
    skippedSourceManifestCount = [int]$skippedSourceEntries.Count
    unacceptedSourceManifestStatusCount = [int]$unacceptedSourceEntries.Count
    sourceListedFileCount = [int](($sourceEntries | Measure-Object -Property listedFileCount -Sum).Sum)
    missingListedFileCount = [int]$missingListedFiles.Count
    allManifestFileCount = [int]$allManifestEntries.Count
    auxiliaryManifestCount = [int]$allAuxiliaryEntries.Count
    releaseGateManifestIncluded = [bool]$releaseGateManifestIncluded
    releaseGateManifestExpected = $true
    pipelineManifestIncluded = [bool]$pipelineManifestIncluded
    pipelineManifestExpected = $true
    sourceManifestNames = @($SourceManifestNames)
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles)
    blockingReasonCount = [int]$blockingReasons.Count
    blockingReasons = @($blockingReasons)
}

$index = [ordered]@{
    schemaVersion = "aitestpilot.release_evidence_index.v1"
    status = $status
    generatedAtUtc = $manifest.generatedAtUtc
    machineReadable = $true
    portalHandoffReady = ($status -eq "PASS")
    evidenceBundlePath = $evidenceBundlePath
    summary = $manifest
    sourceManifests = @($sourceEntries)
    auxiliaryManifests = @($allAuxiliaryEntries)
    missingListedFiles = @($missingListedFiles)
}

$reportLines = @(
    "# AI TestPilot Release Evidence Index",
    "",
    "- Status: $status",
    "- Source manifests indexed: $($manifest.indexedSourceManifestCount) / $($manifest.requiredSourceManifestCount)",
    "- Source manifest coverage: $($manifest.sourceManifestCoverageCount) / $($manifest.requiredSourceManifestCount)",
    "- Missing source manifests: $($manifest.missingSourceManifestCount)",
    "- Unparseable source manifests: $($manifest.unparseableSourceManifestCount)",
    "- Failed source manifests: $($manifest.failedSourceManifestCount)",
    "- Blocked source manifests: $($manifest.blockedSourceManifestCount)",
    "- Skipped source manifests: $($manifest.skippedSourceManifestCount)",
    "- Missing listed files: $($manifest.missingListedFileCount)",
    "- All manifest files inventoried: $($manifest.allManifestFileCount)",
    "- Release gate manifest included at index time: $($manifest.releaseGateManifestIncluded)",
    "- Pipeline manifest included at index time: $($manifest.pipelineManifestIncluded)",
    "",
    "## Source Manifests",
    "",
    "| Manifest | Status | Accepted | Listed files | Missing listed files |",
    "| --- | --- | --- | ---: | ---: |"
)

foreach ($entry in $sourceEntries) {
    $reportLines += "| $($entry.name) | $($entry.status) | $($entry.statusAccepted) | $($entry.listedFileCount) | $($entry.missingListedFileCount) |"
}

if ($blockingReasons.Count -gt 0) {
    $reportLines += ""
    $reportLines += "## Blocking Reasons"
    $reportLines += ""
    foreach ($reason in $blockingReasons) {
        $reportLines += "- $reason"
    }
}

New-Item -ItemType Directory -Force (Split-Path $indexFullPath -Parent) | Out-Null
New-Item -ItemType Directory -Force (Split-Path $reportFullPath -Parent) | Out-Null
New-Item -ItemType Directory -Force (Split-Path $manifestFullPath -Parent) | Out-Null

$index | ConvertTo-Json -Depth 10 | Set-Content -Path $indexFullPath -Encoding UTF8
$reportLines | Set-Content -Path $reportFullPath -Encoding UTF8
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFullPath -Encoding UTF8

if ($status -ne "PASS") {
    throw "AI TestPilot release evidence index blocked. Manifest: $manifestFullPath"
}

Write-Output "Release evidence index: $indexFullPath"
Write-Output "Release evidence index manifest: $manifestFullPath"
Write-Output "PASS AI TestPilot release evidence index"
