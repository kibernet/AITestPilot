[CmdletBinding()]
param(
    [string]$OutputDir,
    [switch]$SkipUnityImport,
    [switch]$SkipModelEndpointTrace
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$quickStartDir = if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    Join-Path $repoRoot "Temp\quick-start"
} else {
    $OutputDir
}

function Assert-Tool {
    param([string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing required command: $Name"
    }
}

function New-ManagedDir {
    param([string]$Path)
    New-Item -ItemType Directory -Force $Path | Out-Null
}

function Invoke-CheckedScript {
    param(
        [string]$ScriptName,
        [hashtable]$Arguments
    )

    $scriptPath = Join-Path $repoRoot ("tools\" + $ScriptName)
    if ($null -eq $Arguments) {
        $Arguments = @{}
    }
    & $scriptPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$ScriptName failed with exit code $LASTEXITCODE"
    }
}

New-ManagedDir $quickStartDir

Assert-Tool dotnet

$evidence = [ordered]@{
    startTime = (Get-Date).ToString("o")
    repository = $repoRoot
    outputDirectory = $quickStartDir
    steps = @()
}

Write-Host "==> AI TestPilot quick start baseline validation"
try {
    $start = Get-Date
    Invoke-CheckedScript -ScriptName "Validate-AITestPilot.ps1" -Arguments @{}
    $evidence.steps += [ordered]@{
        name = "Validate-AITestPilot"
        status = "PASS"
        elapsedSeconds = [math]::Round(((Get-Date) - $start).TotalSeconds, 2)
    }
}
catch {
    $evidence.steps += [ordered]@{
        name = "Validate-AITestPilot"
        status = "FAIL"
        error = $_.Exception.Message
    }
    $evidence.endTime = (Get-Date).ToString("o")
    $evidence.status = "FAILED"
    $manifestPath = Join-Path $quickStartDir "quick-start-manifest.json"
    $evidence | ConvertTo-Json -Depth 6 | Set-Content -Path $manifestPath -Encoding utf8
    throw
}

if (-not $SkipUnityImport) {
    Write-Host "==> Unity package import and sample scene validation"
    try {
        $start = Get-Date
        Invoke-CheckedScript -ScriptName "Validate-UnityPackageImport.ps1" -Arguments @{}
        $evidence.steps += [ordered]@{
            name = "Validate-UnityPackageImport"
            status = "PASS"
            elapsedSeconds = [math]::Round(((Get-Date) - $start).TotalSeconds, 2)
        }
    }
    catch {
        $evidence.steps += [ordered]@{
            name = "Validate-UnityPackageImport"
            status = "FAIL"
            error = $_.Exception.Message
        }
    }
}
else {
    $evidence.steps += [ordered]@{
        name = "Validate-UnityPackageImport"
        status = "SKIPPED"
        reason = "SkipUnityImport was set"
    }
}

if (-not $SkipModelEndpointTrace) {
    Write-Host "==> model endpoint trace probe (offline contract demo)"
    try {
        $start = Get-Date
        Invoke-CheckedScript -ScriptName "Invoke-AITestPilotModelEndpointTraceProbe.ps1" -Arguments @{ EvidenceBundleDir = $quickStartDir }
        $evidence.steps += [ordered]@{
            name = "Invoke-AITestPilotModelEndpointTraceProbe"
            status = "PASS"
            elapsedSeconds = [math]::Round(((Get-Date) - $start).TotalSeconds, 2)
        }
    }
    catch {
        $evidence.steps += [ordered]@{
            name = "Invoke-AITestPilotModelEndpointTraceProbe"
            status = "FAIL"
            error = $_.Exception.Message
        }
    }
}
else {
    $evidence.steps += [ordered]@{
        name = "Invoke-AITestPilotModelEndpointTraceProbe"
        status = "SKIPPED"
        reason = "SkipModelEndpointTrace was set"
    }
}

$allPass = $evidence.steps | Where-Object { $_.status -ne "PASS" -and $_.status -ne "SKIPPED" } | Measure-Object | Select-Object -ExpandProperty Count
$evidence.endTime = (Get-Date).ToString("o")
if ($allPass -eq 0) {
    $evidence.status = "PASS"
} else {
    $evidence.status = "PARTIAL_FAIL"
}

$manifestPath = Join-Path $quickStartDir "quick-start-manifest.json"
$evidence | ConvertTo-Json -Depth 6 | Set-Content -Path $manifestPath -Encoding utf8

Write-Host "Quick start manifest:"
Write-Host $manifestPath
Write-Host "Quick start status: $($evidence.status)"
if ($allPass -ne 0) {
    throw "Quick start completed with non-blocking failures. Check manifest for details: $manifestPath"
}
