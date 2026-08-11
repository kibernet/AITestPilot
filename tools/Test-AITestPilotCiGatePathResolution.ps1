[CmdletBinding()]
param(
    [string]$TestOutputRoot = "Temp\ci-gate-path-tests",
    [switch]$KeepArtifacts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$ciGateScript = Join-Path $PSScriptRoot "Invoke-AITestPilotCiGate.ps1"

if ([string]::IsNullOrWhiteSpace($TestOutputRoot)) {
    $resolvedTestRoot = Join-Path $repoRoot "Temp\ci-gate-path-tests"
}
elseif ([System.IO.Path]::IsPathRooted($TestOutputRoot)) {
    $resolvedTestRoot = $TestOutputRoot
} else {
    $resolvedTestRoot = Join-Path $repoRoot $TestOutputRoot
}

function Resolve-ExpectedPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    return Join-Path $repoRoot $Path
}

function Assert-Present([string]$Path, [string]$Label) {
    if (-not (Test-Path $Path)) {
        throw "Expected artifact not found for $Label : $Path"
    }
}

function Assert-Passed([string]$SummaryPath) {
    $summary = Get-Content -Raw $SummaryPath | ConvertFrom-Json
    if (-not $summary -or $summary.developer_gate_status -ne "PASS") {
        throw "Summary report does not indicate PASS: $SummaryPath"
    }
}

function Assert-SummaryManifest([string]$SummaryPath, [string]$ExpectedManifestPath) {
    $summary = Get-Content -Raw $SummaryPath | ConvertFrom-Json
    if ($summary.developer_gate_manifest -ne $ExpectedManifestPath) {
        throw "Manifest path mismatch. Expected: '$ExpectedManifestPath', got: '$($summary.developer_gate_manifest)'"
    }
}

function Run-CiGateCase {
    param(
        [string]$Name,
        [string]$SummaryPath,
        [string]$ManifestPath,
        [string]$QuickStartOutputDir = "",
        [string]$RepairLoopOutputDir = "",
        [string]$RepairLoopEvidenceBundleDir = "",
        [switch]$UseOutputAlias
    )

    Write-Host "==> $Name"

    $expectedSummaryPath = Resolve-ExpectedPath -Path $SummaryPath
    $expectedManifestPath = Resolve-ExpectedPath -Path $ManifestPath
    $expectedQuickStartOutputDir = if ([string]::IsNullOrWhiteSpace($QuickStartOutputDir)) { "" } else { Resolve-ExpectedPath -Path $QuickStartOutputDir }
    $expectedRepairLoopOutputDir = if ([string]::IsNullOrWhiteSpace($RepairLoopOutputDir)) { "" } else { Resolve-ExpectedPath -Path $RepairLoopOutputDir }
    $invokeArgs = @{
        SkipQuickStart   = $true
        SkipRepairLoop   = $true
        AllowPartialFail = $true
    }

    if ($UseOutputAlias.IsPresent) {
        $invokeArgs["OutputPath"] = $SummaryPath
    } else {
        $invokeArgs["SummaryPath"] = $SummaryPath
    }

    $invokeArgs["DeveloperGateManifestPath"] = $ManifestPath

    if ($expectedQuickStartOutputDir) { $invokeArgs["QuickStartOutputDir"] = $QuickStartOutputDir }
    if ($expectedRepairLoopOutputDir) { $invokeArgs["RepairLoopOutputDir"] = $RepairLoopOutputDir }
    if (-not [string]::IsNullOrWhiteSpace($RepairLoopEvidenceBundleDir)) { $invokeArgs["RepairLoopEvidenceBundleDir"] = $RepairLoopEvidenceBundleDir }

    & $ciGateScript @invokeArgs
    if ($LASTEXITCODE -ne 0) {
        throw "CI gate failed for case '$Name' with exit code $LASTEXITCODE"
    }

    Assert-Present -Path $expectedSummaryPath -Label "$Name summary"
    Assert-Present -Path $expectedManifestPath -Label "$Name manifest"
    if ($expectedQuickStartOutputDir) {
        Assert-Present -Path $expectedQuickStartOutputDir -Label "$Name quick start output dir"
    }
    if ($expectedRepairLoopOutputDir) {
        Assert-Present -Path $expectedRepairLoopOutputDir -Label "$Name repair loop output dir"
    }
    Assert-Passed -SummaryPath $expectedSummaryPath
    Assert-SummaryManifest -SummaryPath $expectedSummaryPath -ExpectedManifestPath $expectedManifestPath

    Write-Host "PASS $Name"
}

New-Item -ItemType Directory -Force -Path $resolvedTestRoot | Out-Null

$testCases = @(
    @{
        Name = "Relative paths with whitespace"
        SummaryPath = "Temp\ci-gate-path-tests\relative\ci summary.json"
        ManifestPath = "Temp\ci-gate-path-tests\relative\dev manifest.json"
        QuickStartOutputDir = "Temp\ci-gate-path-tests\relative\quick start"
        RepairLoopOutputDir = "Temp\ci-gate-path-tests\relative\repair loop"
        RepairLoopEvidenceBundleDir = "Temp\ci-gate-path-tests\relative\bundle with space"
    },
    @{
        Name = "Absolute paths with whitespace"
        SummaryPath = Join-Path $repoRoot "Temp\ci-gate-path-tests abs\ci summary.json"
        ManifestPath = Join-Path $repoRoot "Temp\ci-gate-path-tests abs\dev manifest.json"
        QuickStartOutputDir = Join-Path $repoRoot "Temp\ci-gate-path-tests abs\quick start"
        RepairLoopOutputDir = Join-Path $repoRoot "Temp\ci-gate-path-tests abs\repair loop"
        RepairLoopEvidenceBundleDir = Join-Path $repoRoot "Temp\ci-gate-path-tests abs\bundle with space"
    },
    @{
        Name = "OutputPath alias"
        SummaryPath = Join-Path $repoRoot "Temp\ci-gate-path-tests\alias\summary out.json"
        ManifestPath = Join-Path $repoRoot "Temp\ci-gate-path-tests\alias\manifest out.json"
        UseOutputAlias = $true
    }
)

$results = @()
try {
    foreach ($case in $testCases) {
        if ($case.ContainsKey("UseOutputAlias") -and $case.UseOutputAlias) {
            Run-CiGateCase -Name $case.Name -SummaryPath $case.SummaryPath -ManifestPath $case.ManifestPath -UseOutputAlias
        }
        else {
            Run-CiGateCase -Name $case.Name -SummaryPath $case.SummaryPath -ManifestPath $case.ManifestPath -QuickStartOutputDir $case.QuickStartOutputDir -RepairLoopOutputDir $case.RepairLoopOutputDir -RepairLoopEvidenceBundleDir $case.RepairLoopEvidenceBundleDir
        }
        $results += $case.Name
    }

    Write-Host ""
    Write-Host ("CI path regression checks passed: {0}" -f ($results -join ", "))
}
finally {
    if (-not $KeepArtifacts.IsPresent) {
        if (Test-Path $resolvedTestRoot) { Remove-Item -Recurse -Force $resolvedTestRoot -ErrorAction SilentlyContinue }
        $absoluteTestRoot = Join-Path $repoRoot "Temp\ci-gate-path-tests abs"
        if (Test-Path $absoluteTestRoot) { Remove-Item -Recurse -Force $absoluteTestRoot -ErrorAction SilentlyContinue }
    }
}

exit 0
