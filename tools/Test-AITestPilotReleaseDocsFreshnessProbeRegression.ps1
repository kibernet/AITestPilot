[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

<#
.SYNOPSIS
    Regression test script for Invoke-AITestPilotReleaseDocsFreshnessProbe.ps1.

.DESCRIPTION
    Runs a focused probe sanity matrix to validate behavior under:
      - baseline artifacts
      - missing previous manifest artifacts
      - missing required fields in previous manifest
      - null / array-typed previous manifests
      - malformed previous release-docs-freshness manifest
      - malformed previous pipeline manifest
      - dictionary-shaped historical fields instead of arrays

    This script restores all artifacts afterward so it is safe for repeated local use.
#>

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$probePath = Join-Path $repoRoot "tools\Invoke-AITestPilotReleaseDocsFreshnessProbe.ps1"

$artifactRoot = Join-Path $repoRoot "artifacts\ai-testpilot-release\latest"
$previousPipelineManifestPath = Join-Path $artifactRoot "pipeline-manifest.json"
$previousReleaseManifestPath = Join-Path $artifactRoot "release-docs-freshness-manifest.json"

$backupDir = Join-Path $artifactRoot "release-docs-freshness-regression-backup"
$backupPipeline = Join-Path $backupDir "pipeline-manifest.json"
$backupRelease = Join-Path $backupDir "release-docs-freshness-manifest.json"

if (Test-Path $backupDir) {
    Remove-Item $backupDir -Recurse -Force
}

New-Item -ItemType Directory -Force $backupDir | Out-Null
$results = New-Object System.Collections.Generic.List[object]

if (Test-Path $previousPipelineManifestPath) {
    Copy-Item $previousPipelineManifestPath $backupPipeline -Force
}
if (Test-Path $previousReleaseManifestPath) {
    Copy-Item $previousReleaseManifestPath $backupRelease -Force
}

function Restore-OriginalManifests {
    if (Test-Path $backupPipeline) {
        Move-Item $backupPipeline $previousPipelineManifestPath -Force
    } else {
        Remove-Item $previousPipelineManifestPath -ErrorAction SilentlyContinue -Force
    }

    if (Test-Path $backupRelease) {
        Move-Item $backupRelease $previousReleaseManifestPath -Force
    } else {
        Remove-Item $previousReleaseManifestPath -ErrorAction SilentlyContinue -Force
    }
}

function Run-Scenario {
    param(
        [string]$Name,
        [scriptblock]$Action,
        [bool]$ExpectSuccess
    )

    Write-Output "SCENARIO: $Name"
    $ok = $true
    $message = "OK"

    try {
        & $Action
    }
    catch {
        $ok = $false
        $message = $_.Exception.Message
    }

    if ($ok -ne $ExpectSuccess) {
        throw "Scenario '$Name' expectedSuccess=$ExpectSuccess but was $ok. Message: $message"
    }
    $result = [PSCustomObject]@{
        Scenario = $Name
        ExpectedSuccess = $ExpectSuccess
        ActualSuccess = $ok
        Message = $message
    }
    $results.Add($result)
    Write-Output ("RESULT: {0} => PASS (expectedSuccess={1}, actualSuccess={2}, message={3})" -f $Name, $ExpectSuccess, $ok, $message)
}

try {
    Run-Scenario "baseline" {
        & $probePath
    } $true

    Run-Scenario "missing_previous_manifests" {
        if (Test-Path $previousPipelineManifestPath) { Remove-Item $previousPipelineManifestPath -Force }
        if (Test-Path $previousReleaseManifestPath) { Remove-Item $previousReleaseManifestPath -Force }
        & $probePath
    } $true

    Run-Scenario "missing_required_fields_previous_release_manifest" {
        if (Test-Path $backupPipeline) {
            Copy-Item $backupPipeline $previousPipelineManifestPath -Force
        }
        if (Test-Path $backupRelease) {
            Copy-Item $backupRelease $previousReleaseManifestPath -Force
        }
        $payload = @{
            schemaVersion = "aitestpilot.release_docs_freshness.v1"
        } | ConvertTo-Json -Depth 3
        Set-Content -Path $previousReleaseManifestPath -Value $payload -Encoding UTF8
        & $probePath
    } $true

    Run-Scenario "null_previous_release_manifest" {
        if (Test-Path $backupPipeline) {
            Copy-Item $backupPipeline $previousPipelineManifestPath -Force
        }
        Set-Content -Path $previousReleaseManifestPath -Value "null" -Encoding UTF8
        & $probePath
    } $true

    Run-Scenario "array_previous_release_manifest" {
        if (Test-Path $backupPipeline) {
            Copy-Item $backupPipeline $previousPipelineManifestPath -Force
        }
        Set-Content -Path $previousReleaseManifestPath -Value "[1, 2, 3]" -Encoding UTF8
        & $probePath
    } $true

    Run-Scenario "invalid_previous_release_manifest" {
        if (Test-Path $backupPipeline) {
            Copy-Item $backupPipeline $previousPipelineManifestPath -Force
        }
        Set-Content -Path $previousReleaseManifestPath -Value "{ invalid json" -Encoding UTF8
        & $probePath
    } $false

    Run-Scenario "invalid_previous_pipeline_manifest" {
        if (Test-Path $backupRelease) {
            Copy-Item $backupRelease $previousReleaseManifestPath -Force
        }
        Set-Content -Path $previousPipelineManifestPath -Value "{ invalid json" -Encoding UTF8
        & $probePath
    } $false

    Run-Scenario "dictionary_previous_release_manifest" {
        if (Test-Path $backupPipeline) {
            Copy-Item $backupPipeline $previousPipelineManifestPath -Force
        }
        $payload = @{
            schemaVersion = "aitestpilot.release_docs_freshness.v1"
            status = "PASS"
            pipelineStepCount = 7
            requiredDocFiles = @{ one = "README.md"; two = "docs/ci-release-pipeline.md" }
            sourceFiles = @{ a = "docs/architecture.md"; b = "README.md" }
            missingPipelineStepDocs = @{ x = "single-step" }
        } | ConvertTo-Json -Depth 3
        Set-Content -Path $previousReleaseManifestPath -Value $payload -Encoding UTF8
        & $probePath
    } $true

    Write-Output "REGRESSION PASS: all scenarios matched expected outcomes."
    $results | ConvertTo-Csv -NoTypeInformation
}
finally {
    Restore-OriginalManifests
    if (Test-Path $backupDir) {
        Remove-Item $backupDir -Recurse -Force
    }
}
