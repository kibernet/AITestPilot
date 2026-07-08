[CmdletBinding()]
param(
    [string]$ArtifactDir,
    [string]$ManifestPath,
    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($ArtifactDir)) {
    $ArtifactDir = Join-Path $repoRoot "artifacts\ai-testpilot-release\latest"
}

$defaultOutputDir = Join-Path $repoRoot "Temp\release-evidence\final-artifact-freshness-probe"
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $defaultOutputDir "final-artifact-freshness-probe-manifest.json"
}
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $defaultOutputDir "final-artifact-freshness-probe.md"
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

function Get-JsonValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$DefaultValue = $null
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }

        return $DefaultValue
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }

    return $property.Value
}

function Convert-ToBool {
    param([object]$Value)

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    if ($null -eq $Value) {
        return $false
    }

    $text = ([string]$Value).Trim()
    return $text -ieq "true"
}

function Convert-ToInt {
    param([object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return 0
    }

    return [int]$Value
}

function Convert-ToArray {
    param([object]$Value)

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Array]) {
        return @($Value)
    }

    return @($Value)
}

function Convert-UtcDateTime {
    param(
        [object]$Value,
        [string]$Label
    )

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw "$Label is missing generatedAtUtc."
    }

    return [datetime]::Parse(
        $text,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind
    ).ToUniversalTime()
}

function Read-JsonFile {
    param(
        [string]$Path,
        [string]$Label
    )

    if (-not (Test-Path $Path)) {
        throw "$Label is missing: $Path"
    }

    try {
        return Get-Content -Path $Path -Encoding UTF8 -Raw | ConvertFrom-Json
    }
    catch {
        throw "$Label is not parseable JSON: $Path. $($_.Exception.Message)"
    }
}

function Format-MarkdownCell {
    param([object]$Value)

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return "(none)"
    }

    return $text.Replace("|", "\|").Replace("`r", " ").Replace("`n", " ")
}

function Convert-ToArtifactRelativePath {
    param([string]$Path)

    $fullPath = Resolve-FullPath $Path
    if (-not (Test-PathWithinRoot $fullPath $artifactPath)) {
        return $fullPath
    }

    $rootUri = [System.Uri]((Resolve-FullPath $artifactPath).TrimEnd([char[]]@("\", "/")) + "\")
    $fileUri = [System.Uri]$fullPath
    $relative = [System.Uri]::UnescapeDataString($rootUri.MakeRelativeUri($fileUri).ToString())
    return $relative.Replace("/", "\")
}

function Add-ProbeCheck {
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

$artifactPath = Assert-PathUnderRepo $ArtifactDir "ArtifactDir"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"

if (Test-PathWithinRoot $manifestFullPath $artifactPath) {
    throw "ManifestPath must stay outside ArtifactDir so the probe remains read-only for the final artifact: $manifestFullPath"
}
if (Test-PathWithinRoot $reportFullPath $artifactPath) {
    throw "ReportPath must stay outside ArtifactDir so the probe remains read-only for the final artifact: $reportFullPath"
}

$pipelineManifestPath = Join-Path $artifactPath "pipeline-manifest.json"
$indexManifestPath = Join-Path $artifactPath "release-evidence-index-manifest.json"
$indexPath = Join-Path $artifactPath "release-evidence-index.json"
$firstTestableManifestPath = Join-Path $artifactPath "first-testable-release-manifest.json"
$firstTestableReportPath = Join-Path $artifactPath "first-testable-release.md"
$invalidatedManifestPath = Join-Path $artifactPath "release-artifact-invalidated-manifest.json"

$pipelineManifest = Read-JsonFile $pipelineManifestPath "Pipeline manifest"
$indexManifest = Read-JsonFile $indexManifestPath "Release evidence index manifest"
$index = Read-JsonFile $indexPath "Release evidence index"
$firstTestableManifest = Read-JsonFile $firstTestableManifestPath "First testable release manifest"

$indexGeneratedAtUtc = Convert-UtcDateTime (Get-JsonValue $indexManifest "generatedAtUtc" "") "Release evidence index manifest"
$firstTestableGeneratedAtUtc = Convert-UtcDateTime (Get-JsonValue $firstTestableManifest "generatedAtUtc" "") "First testable release manifest"
$indexGeneratedAfterFirstTestable = $indexGeneratedAtUtc -ge $firstTestableGeneratedAtUtc

$auxiliaryManifests = @(Convert-ToArray (Get-JsonValue $index "auxiliaryManifests" @()))
$firstTestableIndexEntry = $null
foreach ($entry in $auxiliaryManifests) {
    if ([string](Get-JsonValue $entry "name" "") -eq "first-testable-release-manifest.json") {
        $firstTestableIndexEntry = $entry
        break
    }
}

$firstTestableManifestIndexed = $null -ne $firstTestableIndexEntry
$firstTestableManifestSha256 = (Get-FileHash -LiteralPath $firstTestableManifestPath -Algorithm SHA256).Hash
$indexedFirstTestableManifestSha256 = if ($firstTestableManifestIndexed) { [string](Get-JsonValue $firstTestableIndexEntry "sourceManifestSha256" "") } else { "" }
$firstTestableManifestSha256MatchesCurrent = $firstTestableManifestIndexed -and ($indexedFirstTestableManifestSha256 -eq $firstTestableManifestSha256)
$firstTestableIndexListedFileCount = if ($firstTestableManifestIndexed) { Convert-ToInt (Get-JsonValue $firstTestableIndexEntry "listedFileCount" 0) } else { 0 }
$firstTestableIndexMissingListedFileCount = if ($firstTestableManifestIndexed) { Convert-ToInt (Get-JsonValue $firstTestableIndexEntry "missingListedFileCount" 0) } else { 0 }
$firstTestableFiles = @(Convert-ToArray (Get-JsonValue $firstTestableManifest "files" @()) | ForEach-Object { [string]$_ })
$firstTestableReportListed = $firstTestableFiles -contains "first-testable-release.md"
$firstTestableManifestListed = $firstTestableFiles -contains "first-testable-release-manifest.json"
$firstTestableReportExists = Test-Path $firstTestableReportPath
$artifactInvalidated = Test-Path $invalidatedManifestPath

$checks = @()
Add-ProbeCheck "artifact_not_invalidated" (-not $artifactInvalidated) "Final artifact must not contain release-artifact-invalidated-manifest.json."
Add-ProbeCheck "pipeline_manifest_passed" `
    ((Get-JsonValue $pipelineManifest "status" "") -eq "PASS" -and
        -not (Convert-ToBool (Get-JsonValue $pipelineManifest "finalReleaseArtifactsInvalidated" $true))) `
    "Pipeline manifest must be PASS and final artifacts must not be invalidated."
Add-ProbeCheck "release_evidence_index_passed" `
    ((Get-JsonValue $indexManifest "status" "") -eq "PASS" -and
        (Get-JsonValue $index "status" "") -eq "PASS" -and
        (Convert-ToBool (Get-JsonValue $indexManifest "pipelineManifestIncluded" $false))) `
    "Final release evidence index manifest and JSON must be PASS and include the pipeline manifest."
Add-ProbeCheck "first_testable_release_passed" `
    ((Get-JsonValue $firstTestableManifest "status" "") -eq "PASS" -and
        (Convert-ToBool (Get-JsonValue $firstTestableManifest "readyForOperatorTesting" $false)) -and
        $firstTestableReportExists) `
    "First testable release manifest and report must be present, PASS, and ready for operator testing."
Add-ProbeCheck "final_index_generated_after_first_testable" `
    ([bool]$indexGeneratedAfterFirstTestable) `
    "Final release evidence index must be generated after first-testable-release-manifest.json."
Add-ProbeCheck "first_testable_manifest_indexed" `
    ($firstTestableManifestIndexed -and
        (Convert-ToBool (Get-JsonValue $firstTestableIndexEntry "parseable" $false)) -and
        (Convert-ToBool (Get-JsonValue $firstTestableIndexEntry "statusAccepted" $false))) `
    "Final release evidence index must inventory first-testable-release-manifest.json as an accepted auxiliary manifest."
Add-ProbeCheck "first_testable_manifest_sha256_current" `
    ([bool]$firstTestableManifestSha256MatchesCurrent) `
    "Indexed SHA256 for first-testable-release-manifest.json must match the current artifact file."
Add-ProbeCheck "first_testable_listed_files_present" `
    ($firstTestableManifestListed -and
        $firstTestableReportListed -and
        $firstTestableIndexListedFileCount -ge 2 -and
        $firstTestableIndexMissingListedFileCount -eq 0) `
    "First-testable manifest must list its manifest/report files, and the index entry must have no missing listed files."

$failedChecks = @($checks | Where-Object { -not (Convert-ToBool (Get-JsonValue $_ "passed" $false)) })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }
$generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")

$generatedFiles = @(
    $manifestFullPath,
    $reportFullPath
)
$sourceFiles = @(
    $pipelineManifestPath,
    $indexManifestPath,
    $indexPath,
    $firstTestableManifestPath,
    $firstTestableReportPath
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.final_artifact_freshness_probe.v1"
    status = $status
    generatedAtUtc = $generatedAtUtc
    artifactDir = $artifactPath
    readOnlyArtifact = $true
    reportPath = $reportFullPath
    artifactInvalidated = [bool]$artifactInvalidated
    pipelineStatus = [string](Get-JsonValue $pipelineManifest "status" "")
    releaseEvidenceIndexStatus = [string](Get-JsonValue $indexManifest "status" "")
    releaseEvidenceIndexJsonStatus = [string](Get-JsonValue $index "status" "")
    firstTestableReleaseStatus = [string](Get-JsonValue $firstTestableManifest "status" "")
    readyForOperatorTesting = Convert-ToBool (Get-JsonValue $firstTestableManifest "readyForOperatorTesting" $false)
    indexGeneratedAtUtc = $indexGeneratedAtUtc.ToString("O")
    firstTestableGeneratedAtUtc = $firstTestableGeneratedAtUtc.ToString("O")
    indexGeneratedAfterFirstTestable = [bool]$indexGeneratedAfterFirstTestable
    firstTestableManifestIndexed = [bool]$firstTestableManifestIndexed
    firstTestableManifestSha256 = $firstTestableManifestSha256
    indexedFirstTestableManifestSha256 = $indexedFirstTestableManifestSha256
    firstTestableManifestSha256MatchesCurrent = [bool]$firstTestableManifestSha256MatchesCurrent
    firstTestableIndexListedFileCount = [int]$firstTestableIndexListedFileCount
    firstTestableIndexMissingListedFileCount = [int]$firstTestableIndexMissingListedFileCount
    firstTestableManifestListed = [bool]$firstTestableManifestListed
    firstTestableReportListed = [bool]$firstTestableReportListed
    firstTestableReportExists = [bool]$firstTestableReportExists
    productionOutputBoundary = "final_artifact_freshness_probe_read_only"
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
    sourceFiles = @($sourceFiles | ForEach-Object { Convert-ToArtifactRelativePath $_ })
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles)
}

$reportLines = @(
    "# AI TestPilot Final Artifact Freshness Probe",
    "",
    "Schema: ``aitestpilot.final_artifact_freshness_probe.v1``",
    "Generated at UTC: $generatedAtUtc",
    "",
    "## Summary",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Status | $(Format-MarkdownCell $status) |",
    "| Artifact | $(Format-MarkdownCell $artifactPath) |",
    "| Read-only artifact | True |",
    "| Pipeline status | $(Format-MarkdownCell $manifest.pipelineStatus) |",
    "| Index status | $(Format-MarkdownCell $manifest.releaseEvidenceIndexStatus) |",
    "| First testable status | $(Format-MarkdownCell $manifest.firstTestableReleaseStatus) |",
    "| Ready for operator testing | $($manifest.readyForOperatorTesting) |",
    "| Index generated at UTC | $(Format-MarkdownCell $manifest.indexGeneratedAtUtc) |",
    "| First-testable generated at UTC | $(Format-MarkdownCell $manifest.firstTestableGeneratedAtUtc) |",
    "| Index generated after first-testable | $($manifest.indexGeneratedAfterFirstTestable) |",
    "| First-testable manifest SHA matches current | $($manifest.firstTestableManifestSha256MatchesCurrent) |",
    "| Failed checks | $($manifest.failedCheckCount) |",
    "",
    "## Checks",
    "",
    "| Check | Passed | Message |",
    "| --- | --- | --- |"
)
foreach ($check in $checks) {
    $checkName = Format-MarkdownCell (Get-JsonValue $check "name" "")
    $checkPassed = Get-JsonValue $check "passed" $false
    $checkMessage = Format-MarkdownCell (Get-JsonValue $check "message" "")
    $reportLines += "| $checkName | $checkPassed | $checkMessage |"
}
$reportText = [string]::Join([Environment]::NewLine, $reportLines) + [Environment]::NewLine

New-Item -ItemType Directory -Force (Split-Path $manifestFullPath -Parent) | Out-Null
New-Item -ItemType Directory -Force (Split-Path $reportFullPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFullPath -Encoding UTF8
$reportText | Set-Content -Path $reportFullPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Final artifact freshness probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Final artifact freshness probe manifest: $manifestFullPath"
Write-Output "Final artifact freshness probe report: $reportFullPath"
Write-Output "PASS AI TestPilot final artifact freshness probe"
