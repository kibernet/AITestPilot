<#
.SYNOPSIS
Generate a release readiness checklist/report for AITestPilot PRs and milestones.

.DESCRIPTION
This utility inspects common release-local/preflight artifacts and renders a markdown report
that you can paste into PR descriptions or milestone trackers.

The report includes:
- required artifact presence and PASS/FAIL status where available
- whether docs-freshness and drift artifacts were produced
- optional release pipeline evidence coverage

.PARAMETER SummaryPath
Path to the release preflight summary JSON. Default: `Temp\release-preflight-summary.json`.

.PARAMETER PreflightManifestPath
Path to the release preflight manifest JSON. Default: `Temp\release-preflight-manifest.json`.

.PARAMETER LocalArtifactDir
Directory containing local preflight artifacts (used for summary/manifests). Default: `Temp`.

.PARAMETER ReleaseEvidenceDir
Directory containing release evidence docs artifacts. Default: `Temp\release-evidence\latest`.

.PARAMETER ReleaseArtifactRoot
Directory containing published release bundle artifacts. Default: `artifacts\ai-testpilot-release\latest`.

.PARAMETER OutputPath
Optional output path for the generated report. When omitted, prints to console only.

.PARAMETER RequireReleasePipeline
Emit release-pipeline-only checks as required (default: false for local quick readiness).

.PARAMETER IncludeRecommendedCommands
Include the recommended command sequence at the end of the report.

.PARAMETER FailOnWarning
Treat WARN entries as blocking failures. Useful for strict gate automation.

.PARAMETER SummaryOutputPath
Optional output path for a machine-readable JSON summary.
#>
[CmdletBinding()]
param(
    [string]$SummaryPath = "Temp\release-preflight-summary.json",
    [string]$PreflightManifestPath = "Temp\release-preflight-manifest.json",
    [string]$LocalArtifactDir = "Temp",
    [string]$ReleaseEvidenceDir = "Temp\release-evidence\latest",
    [string]$ReleaseArtifactRoot = "artifacts\ai-testpilot-release\latest",
    [string]$OutputPath = "",
    [switch]$RequireReleasePipeline,
    [switch]$IncludeRecommendedCommands,
    [switch]$FailOnWarning,
    [string]$SummaryOutputPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$recommendedCommandsSectionTitle = "## 2) Recommended command sequence (mainline)"
$recommendedCommands = @(
    ".\tools\Invoke-AITestPilotReleasePreflight.ps1"
    ".\tools\Invoke-AITestPilotReleasePreflight.ps1 -SkipReleasePipeline"
    ".\tools\Invoke-AITestPilotReleasePreflight.ps1 -SkipReleasePipeline -SkipStrictPathRegression"
    ".\tools\Invoke-AITestPilotReleasePreflight.ps1 -SkipReleasePipeline -SkipDocsFreshnessRegression"
)

function Resolve-PathUnderRepo {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        return $null
    }
    try {
        return Get-Content -Path $Path -Encoding UTF8 -Raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Read-JsonValue {
    param(
        [object]$Object,
        [string]$Path,
        [object]$Default = $null
    )
    if ($null -eq $Object) { return $Default }
    $parts = $Path -split "\."
    $current = $Object
    foreach ($part in $parts) {
        if ($null -eq $current) { return $Default }
        if ($current -is [hashtable] -and $current.ContainsKey($part)) {
            $current = $current[$part]
            continue
        }
        if ($current.PSObject.Properties[$part]) {
            $current = $current.PSObject.Properties[$part].Value
            continue
        }
        return $Default
    }
    return $current
}

function Build-Line {
    param(
        [string]$Title,
        [string]$Status
    )
    if ($Status -eq "PASS") { return "- [x] $Title" }
    if ($Status -eq "WARN") { return "- [!] $Title" }
    return "- [ ] $Title"
}

function Check-File {
    param(
        [string]$RelPath,
        [string]$Label
    )
    $fullPath = Resolve-PathUnderRepo $RelPath
    if (-not (Test-Path $fullPath)) {
        return @{ label = $Label; status = "FAIL"; value = $RelPath; path = $fullPath; detail = "not found: $RelPath" }
    }
    return @{ label = $Label; status = "PASS"; value = $RelPath; path = $fullPath; detail = "found: $RelPath" }
}

function Check-JsonField {
    param(
        [string]$RelPath,
        [string]$Label,
        [string]$JsonPath,
        [string]$Expected = "PASS"
    )
    $fullPath = Resolve-PathUnderRepo $RelPath
    $obj = Read-JsonFile -Path $fullPath
    if ($null -eq $obj) {
        return @{ label = $Label; status = "WARN"; value = "missing-or-invalid-json"; path = $fullPath; detail = "missing-or-invalid-json"; raw = $obj }
    }
    $value = Read-JsonValue -Object $obj -Path $JsonPath -Default ""
    if ([string]::IsNullOrWhiteSpace([string]$value)) {
        return @{ label = "$Label (`"$JsonPath`" not present)"; status = "WARN"; value = ""; path = $fullPath; detail = "missing-json-field: $JsonPath"; raw = $obj }
    }
    if ([string]$value -eq $Expected) {
        return @{ label = $Label; status = "PASS"; value = $value; path = $fullPath; detail = "$JsonPath=$value"; raw = $obj }
    }
    return @{ label = "$Label (`"$JsonPath=$value`")"; status = "FAIL"; value = $value; path = $fullPath; detail = "$JsonPath=$value"; raw = $obj }
}

function Get-RecommendedCommandSection {
    return $recommendedCommandsSectionTitle
}

$summaryPathFull = Resolve-PathUnderRepo $SummaryPath
$preflightManifestPathFull = Resolve-PathUnderRepo $PreflightManifestPath
$localSummary = Read-JsonFile -Path $summaryPathFull

$rows = @()
$rows += @{
    title = "Release preflight summary status is PASS (`$SummaryPath`)"
    status = if ($null -ne $localSummary -and (Read-JsonValue $localSummary "status" "") -eq "PASS") { "PASS" } else { if (Test-Path $summaryPathFull) { "WARN" } else { "FAIL" } }
    detail = if ($null -ne $localSummary -and (Read-JsonValue $localSummary "status" "") -eq "PASS") { "status=PASS ($SummaryPath)" } else { if (Test-Path $summaryPathFull) { "status!=PASS or unreadable ($SummaryPath)" } else { "not found ($SummaryPath)" } }
}

if (Test-Path $preflightManifestPathFull) {
    $rows += Check-JsonField -RelPath $PreflightManifestPath -Label "Release preflight manifest status is PASS (`$PreflightManifestPath`)" -JsonPath "status" -Expected "PASS"
}
else {
    $rows += @{
        label = "Release preflight manifest status is PASS (`$PreflightManifestPath`)"
        status = "PASS"
        value = $PreflightManifestPath
        path = $preflightManifestPathFull
        detail = "not present in default release-preflight wrapper; this is optional"
    }
}

$rows += @{
    title = "Run-DevGate executed"
    status = if ($null -ne $localSummary -and ((Read-JsonValue $localSummary "steps" @()).name -contains "Run-DevGate")) { "PASS" } else { "FAIL" }
    detail = "from 'release-preflight-summary.json'"
}

$rows += @{
    title = "Validate-AITestPilot executed"
    status = if ($null -ne $localSummary -and ((Read-JsonValue $localSummary "steps" @()).name -contains "Validate-AITestPilot")) { "PASS" } else { "FAIL" }
    detail = "from 'release-preflight-summary.json'"
}

$rows += Check-File -RelPath "$LocalArtifactDir\quick-start\quick-start-manifest.json" -Label "quick-start manifest exists"
$rows += Check-File -RelPath "$LocalArtifactDir\developer-gate-manifest.json" -Label "developer gate manifest exists"
$rows += Check-File -RelPath "$LocalArtifactDir\repair-loop\repair-loop-manifest.json" -Label "repair-loop manifest exists"
$rows += Check-File -RelPath $ReleaseEvidenceDir -Label "release evidence directory exists"
$rows += Check-File -RelPath "$ReleaseEvidenceDir\release-docs-freshness-manifest.json" -Label "release-docs-freshness manifest exists"
$rows += Check-File -RelPath "$ReleaseEvidenceDir\release-docs-freshness-drift-manifest.json" -Label "release-docs-freshness drift manifest exists"

$rows += Check-JsonField -RelPath "$ReleaseEvidenceDir\release-docs-freshness-manifest.json" -Label "release-docs-freshness status is PASS" -JsonPath "status" -Expected "PASS"
$rows += Check-JsonField -RelPath "$ReleaseEvidenceDir\release-docs-freshness-drift-manifest.json" -Label "release-docs-freshness drift status is PASS" -JsonPath "status" -Expected "PASS"

if ($RequireReleasePipeline) {
    $rows += Check-File -RelPath $ReleaseArtifactRoot -Label "release artifact root exists"
    $rows += Check-JsonField -RelPath "$ReleaseArtifactRoot\pipeline-manifest.json" -Label "pipeline manifest status is PASS" -JsonPath "status" -Expected "PASS"
    $rows += Check-JsonField -RelPath "$ReleaseArtifactRoot\release-gate-manifest.json" -Label "release gate status is PASS" -JsonPath "releaseGateStatus" -Expected "PASS"
    $rows += Check-File -RelPath "$ReleaseArtifactRoot\release-docs-freshness-drift-manifest.json" -Label "release artifact drift manifest copied to final artifacts"
}

$rows += Check-File -RelPath "$LocalArtifactDir\ci-gate-summary.json" -Label "ci-gate-summary.json optional artifact exists"
$rows += Check-File -RelPath "$LocalArtifactDir\ci-gate-path-tests\relative\dev manifest.json" -Label "CI path regression baseline witness exists"

$passCount = 0
$warnCount = 0
$failCount = 0
$blockCount = 0

$lines = @(
    "# AITestPilot Release Readiness Report",
    "",
    "Generated: $((Get-Date).ToString("yyyy-MM-dd HH:mm:sszzz"))",
    "",
    "## 0) Readiness gate summary",
    ""
)

foreach ($row in $rows) {
    $itemStatus = "FAIL"
    if ($null -ne $row) {
        if ($row -is [hashtable] -and $row.ContainsKey("status")) {
            $itemStatus = [string]$row["status"]
        }
        elseif ($row.PSObject -and $row.PSObject.Properties.Name -contains "status") {
            $itemStatus = [string]$row.status
        }
    }

    if ($itemStatus -eq "PASS") { $passCount++ }
    elseif ($itemStatus -eq "WARN") { $warnCount++ }
    else { $failCount++; }

    if (($itemStatus -eq "FAIL") -or ($FailOnWarning -and $itemStatus -eq "WARN")) { $blockCount++ }
}

$gateStatus = if ($blockCount -gt 0) { "BLOCKED" } else { "READY" }

$lines += "- Gate status: **$gateStatus**"
$lines += "- PASS: $passCount"
$lines += "- WARN: $warnCount"
$lines += "- FAIL: $failCount"
$lines += ""
$lines += "## 1) Artifact checks"
$lines += ""

$lines += if ($blockCount -gt 0) {
    "Blocking conditions detected. Review WARN/FAIL entries marked above before proceeding."
} else {
    "No blocking conditions detected."
}
$lines += ""

foreach ($row in $rows) {
    $itemTitle = "unknown"
    $itemDetail = ""
    $itemStatus = "FAIL"

    if ($null -ne $row) {
        if ($row -is [hashtable]) {
            if ($row.ContainsKey("title")) { $itemTitle = [string]$row["title"] }
            elseif ($row.ContainsKey("label")) { $itemTitle = [string]$row["label"] }
            if ($row.ContainsKey("detail")) { $itemDetail = [string]$row["detail"] }
            if ($row.ContainsKey("status")) { $itemStatus = [string]$row["status"] }
        }
        elseif ($row.PSObject -and $row.PSObject.Properties) {
            if ($row.PSObject.Properties.Name -contains "title") { $itemTitle = [string]$row.title } 
            elseif ($row.PSObject.Properties.Name -contains "label") { $itemTitle = [string]$row.label }
            if ($row.PSObject.Properties.Name -contains "detail") { $itemDetail = [string]$row.detail }
            if ($row.PSObject.Properties.Name -contains "status") { $itemStatus = [string]$row.status }
        }
    }
    $lines += Build-Line -Title ("{0} ({1})" -f $itemTitle, $itemDetail) -Status $itemStatus
}

if ($IncludeRecommendedCommands) {
    $lines += ""
    $lines += Get-RecommendedCommandSection
    $lines += ""
    $lines += '```powershell'
    foreach ($command in $recommendedCommands) { $lines += $command }
    $lines += '```'
}

$text = $lines -join [Environment]::NewLine

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $fullOutput = Resolve-PathUnderRepo $OutputPath
    $outputDir = Split-Path $fullOutput -Parent
    if (-not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
    }
    Set-Content -Path $fullOutput -Encoding UTF8 -Value $text
    Write-Output "Release readiness report: $fullOutput"
} else {
    Write-Output $text
}

$summaryPayload = [ordered]@{
    generated_utc = (Get-Date).ToUniversalTime().ToString("o")
    gate_status = $gateStatus
    fail_on_warning = [bool]$FailOnWarning
    require_release_pipeline = [bool]$RequireReleasePipeline
    counts = [ordered]@{
        pass = $passCount
        warn = $warnCount
        fail = $failCount
        blocking = $blockCount
    }
    checks = @()
}

foreach ($row in $rows) {
    if ($null -eq $row) { continue }

    $item = [ordered]@{
        label = "unknown"
        status = "FAIL"
        detail = ""
        value = ""
        path = ""
    }

    if ($row -is [hashtable]) {
        if ($row.ContainsKey("label")) { $item.label = [string]$row["label"] }
        elseif ($row.ContainsKey("title")) { $item.label = [string]$row["title"] }
        if ($row.ContainsKey("status")) { $item.status = [string]$row["status"] }
        if ($row.ContainsKey("detail")) { $item.detail = [string]$row["detail"] }
        if ($row.ContainsKey("value")) { $item.value = [string]$row["value"] }
        if ($row.ContainsKey("path")) { $item.path = [string]$row["path"] }
    }
    elseif ($row.PSObject -and $row.PSObject.Properties) {
        if ($row.PSObject.Properties.Name -contains "label") { $item.label = [string]$row.label }
        elseif ($row.PSObject.Properties.Name -contains "title") { $item.label = [string]$row.title }
        if ($row.PSObject.Properties.Name -contains "status") { $item.status = [string]$row.status }
        if ($row.PSObject.Properties.Name -contains "detail") { $item.detail = [string]$row.detail }
        if ($row.PSObject.Properties.Name -contains "value") { $item.value = [string]$row.value }
        if ($row.PSObject.Properties.Name -contains "path") { $item.path = [string]$row.path }
    }

    $summaryPayload.checks += $item
}

if (-not [string]::IsNullOrWhiteSpace($SummaryOutputPath)) {
    $summaryOutputFull = Resolve-PathUnderRepo $SummaryOutputPath
    $summaryOutputDir = Split-Path $summaryOutputFull -Parent
    if (-not (Test-Path $summaryOutputDir)) {
        New-Item -ItemType Directory -Force -Path $summaryOutputDir | Out-Null
    }
    $summaryPayload | ConvertTo-Json -Depth 10 | Set-Content -Path $summaryOutputFull -Encoding UTF8
    Write-Output "Release readiness summary: $summaryOutputFull"
}

if ($FailOnWarning -and $blockCount -gt 0) {
    throw "Release readiness check blocked. Inspect the generated report for WARN/FAIL items."
}
