[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$TraceDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($TraceDir)) {
    $TraceDir = Join-Path $repoRoot "Temp\model-endpoint-trace-probe"
}

function Assert-PathUnderRepo {
    param(
        [string]$Path,
        [string]$Label
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
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
    --evidence-bundle-dir $evidencePath `
    --trace-dir $tracePath

if ($LASTEXITCODE -ne 0) {
    throw "Model endpoint trace probe failed with exit code $LASTEXITCODE"
}
