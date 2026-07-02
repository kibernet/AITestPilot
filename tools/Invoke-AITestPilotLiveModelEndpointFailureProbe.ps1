[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$TraceDir
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

if ([string]::IsNullOrWhiteSpace($TraceDir)) {
    $TraceDir = Join-Path $repoRoot "Temp\live-model-endpoint-failure-probe"
}

function Assert-PathUnderRepo {
    param(
        [string]$Path,
        [string]$Label
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-PathWithinRoot $fullPath $repoRoot)) {
        throw "$Label must stay under repo root. Path: $fullPath"
    }

    return $fullPath
}

$evidencePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$tracePath = Assert-PathUnderRepo $TraceDir "TraceDir"

New-Item -ItemType Directory -Force $evidencePath | Out-Null

if (Test-Path $tracePath) {
    Remove-Item -LiteralPath $tracePath -Recurse -Force
}

New-Item -ItemType Directory -Force $tracePath | Out-Null

$probeProject = Join-Path $repoRoot "tools\Kibernet.AITestPilot.ModelEndpointProbe\Kibernet.AITestPilot.ModelEndpointProbe.csproj"

dotnet run `
    --project $probeProject `
    -- `
    --mode live-failure `
    --evidence-bundle-dir $evidencePath `
    --trace-dir $tracePath

if ($LASTEXITCODE -ne 0) {
    throw "Live model endpoint failure probe failed with exit code $LASTEXITCODE"
}
