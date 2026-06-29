[CmdletBinding()]
param(
    [string]$UnityPath = "F:\Unity\2021_3_45_f2\Editor\Unity.exe",
    [string]$ProjectPath,
    [string]$RepairTaskJsonPath,
    [string]$RetestLogPath,
    [string]$ImportLogPath,
    [string]$ReplayProfileJsonPath,
    [string]$EvidenceBundleDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptPath = Join-Path $PSScriptRoot "Invoke-AITestPilotRepairRetest.ps1"
$arguments = @{
    UnityPath = $UnityPath
    GameReplayDriverType = "Kibernet.AITestPilot.Unity.Editor.FailingGameActionReplayDriver"
    ExpectFailure = $true
}

if (-not [string]::IsNullOrWhiteSpace($ProjectPath)) {
    $arguments.ProjectPath = $ProjectPath
}

if (-not [string]::IsNullOrWhiteSpace($RepairTaskJsonPath)) {
    $arguments.RepairTaskJsonPath = $RepairTaskJsonPath
}

if (-not [string]::IsNullOrWhiteSpace($RetestLogPath)) {
    $arguments.RetestLogPath = $RetestLogPath
}

if (-not [string]::IsNullOrWhiteSpace($ImportLogPath)) {
    $arguments.ImportLogPath = $ImportLogPath
}

if (-not [string]::IsNullOrWhiteSpace($ReplayProfileJsonPath)) {
    $arguments.ReplayProfileJsonPath = $ReplayProfileJsonPath
}

if (-not [string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $arguments.EvidenceBundleDir = $EvidenceBundleDir
}

& $scriptPath @arguments
