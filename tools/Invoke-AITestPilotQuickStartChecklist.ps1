[CmdletBinding()]
param(
    [string]$ManifestPath,
    [switch]$RequireAllChecks,
    [switch]$FailOnFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $repoRoot "Temp\quick-start\quick-start-manifest.json"
}

if (-not (Test-Path $ManifestPath)) {
    throw "Quick-start manifest not found: $ManifestPath"
}

$content = Get-Content -Raw $ManifestPath -Encoding UTF8 | ConvertFrom-Json

Write-Host "==> Quick start checklist"
Write-Host "Manifest: $ManifestPath"

$status = $content.status
$allOk = $status -eq "PASS"
$hasFail = $false

if ($null -eq $content.steps) {
    Write-Warning "Manifest has no step records."
    if ($FailOnFailure) {
        exit 2
    }
    exit 0
}

foreach ($step in $content.steps) {
    $name = $step.name
    $stepStatus = $step.status
    $statusIcon = switch ($stepStatus) {
        "PASS" { "[PASS]" }
        "SKIPPED" { "[SKIP]" }
        "FAIL" { "[FAIL]" }
        default { "[INFO]" }
    }

    Write-Host "$statusIcon $name => $stepStatus"

    if ($stepStatus -eq "FAIL") {
        $hasFail = $true
        if ($step.error) {
            Write-Host "      reason: $($step.error)"
        }
    }
}

if ($RequireAllChecks -and $hasFail) {
    throw "Required quick-start checks failed. Review the manifest and fix failing steps first."
}

if ($FailOnFailure -and $status -ne "PASS") {
    $code = if ($hasFail) { 2 } else { 1 }
    exit $code
}

if ($allOk) {
    Write-Host "Quick start checklist: PASS"
} else {
    Write-Host "Quick start checklist: NOT PASS (non-blocking items may exist)"
}
