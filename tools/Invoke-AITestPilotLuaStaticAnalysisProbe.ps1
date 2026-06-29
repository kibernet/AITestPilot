[CmdletBinding()]
param(
    [string]$EvidenceBundleDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

Push-Location $repoRoot
try {
    dotnet run --project ".\tools\Kibernet.AITestPilot.LuaStaticAnalysisProbe\Kibernet.AITestPilot.LuaStaticAnalysisProbe.csproj" -- `
        --evidenceBundleDir $EvidenceBundleDir
    if ($LASTEXITCODE -ne 0) {
        throw "Lua static analysis probe failed with exit code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}
