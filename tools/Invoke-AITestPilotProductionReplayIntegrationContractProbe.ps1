[CmdletBinding()]
param(
    [string]$UnityPath = "F:\Unity\2021_3_45_f2\Editor\Unity.exe",
    [string]$ProjectPath,
    [string]$ImportLogPath,
    [string]$ProbeLogPath,
    [string]$ProbeEvidencePath,
    [string]$EvidenceBundleDir
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

if ([string]::IsNullOrWhiteSpace($ProjectPath)) {
    $ProjectPath = Join-Path $repoRoot "Temp\UnityImportProject"
}

if ([string]::IsNullOrWhiteSpace($ImportLogPath)) {
    $ImportLogPath = Join-Path $repoRoot "Temp\unity-production-integration-contract-import.log"
}

if ([string]::IsNullOrWhiteSpace($ProbeLogPath)) {
    $ProbeLogPath = Join-Path $repoRoot "Temp\unity-production-integration-contract-probe.log"
}

if ([string]::IsNullOrWhiteSpace($ProbeEvidencePath)) {
    $ProbeEvidencePath = Join-Path $repoRoot "Temp\production-replay-integration-contract-probe.json"
}

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

function Assert-PathUnderRepo {
    param(
        [string]$Path,
        [string]$Label
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-PathWithinRoot $fullPath $repoRoot)) {
        throw "$Label must stay under repo root: $fullPath"
    }

    return $fullPath
}

$projectPath = Assert-PathUnderRepo $ProjectPath "ProjectPath"
$importLogPath = Assert-PathUnderRepo $ImportLogPath "ImportLogPath"
$probeLogPath = Assert-PathUnderRepo $ProbeLogPath "ProbeLogPath"
$probeEvidencePath = Assert-PathUnderRepo $ProbeEvidencePath "ProbeEvidencePath"
$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"

if (-not (Test-Path $UnityPath)) {
    throw "Unity executable not found: $UnityPath"
}

$packagePath = Join-Path $repoRoot "unity\com.kibernet.ai-testpilot"
if (-not (Test-Path $packagePath)) {
    throw "Package path not found: $packagePath"
}

New-Item -ItemType Directory -Force (Split-Path $projectPath -Parent) | Out-Null
if (-not (Test-Path (Join-Path $projectPath "ProjectSettings\ProjectVersion.txt"))) {
    Write-Output "==> create Unity production integration contract project"
    $createProcess = Start-Process `
        -FilePath $UnityPath `
        -ArgumentList @("-batchmode", "-quit", "-createProject", $projectPath, "-logFile", (Join-Path $repoRoot "Temp\unity-production-integration-contract-create.log")) `
        -Wait `
        -PassThru `
        -WindowStyle Hidden
    if ($createProcess.ExitCode -ne 0) {
        throw "Unity project creation failed with exit code $($createProcess.ExitCode)"
    }
}

$manifestPath = Join-Path $projectPath "Packages\manifest.json"
if (-not (Test-Path $manifestPath)) {
    throw "Unity manifest not found: $manifestPath"
}

$packageUri = "file:" + ($packagePath -replace "\\", "/")
$manifest = Get-Content -Raw $manifestPath
if ($manifest -notmatch '"com\.kibernet\.ai-testpilot"') {
    $dependencyLine = "    `"com.kibernet.ai-testpilot`": `"$packageUri`","
    $manifest = $manifest -replace '("dependencies"\s*:\s*\{)', "`$1`r`n$dependencyLine"
    Set-Content -Path $manifestPath -Value $manifest -Encoding UTF8
}

Write-Output "==> Unity production integration contract import"
$importProcess = Start-Process `
    -FilePath $UnityPath `
    -ArgumentList @("-batchmode", "-quit", "-projectPath", $projectPath, "-logFile", $importLogPath) `
    -Wait `
    -PassThru `
    -WindowStyle Hidden
if ($importProcess.ExitCode -ne 0) {
    throw "Unity import failed with exit code $($importProcess.ExitCode)"
}

$errorPatterns = "error CS|Compilation failed|Package Manager.*Error|Asset import failed|Exception:"
$importErrors = Select-String -Path $importLogPath -Pattern $errorPatterns -CaseSensitive:$false
if ($importErrors) {
    $importErrors | Select-Object -First 40 | ForEach-Object { Write-Output $_.Line }
    throw "Unity import log contains errors."
}

$runtimeDll = Join-Path $projectPath "Library\ScriptAssemblies\Kibernet.AITestPilot.Runtime.dll"
$editorDll = Join-Path $projectPath "Library\ScriptAssemblies\Kibernet.AITestPilot.Editor.dll"
if (-not (Test-Path $runtimeDll)) {
    throw "Runtime assembly was not produced: $runtimeDll"
}

if (-not (Test-Path $editorDll)) {
    throw "Editor assembly was not produced: $editorDll"
}

if (Test-Path $probeEvidencePath) {
    Remove-Item -LiteralPath $probeEvidencePath -Force
}

Write-Output "==> Unity production integration contract probe"
$probeProcess = Start-Process `
    -FilePath $UnityPath `
    -ArgumentList @(
        "-batchmode",
        "-quit",
        "-projectPath",
        $projectPath,
        "-logFile",
        $probeLogPath,
        "-executeMethod",
        "Kibernet.AITestPilot.Unity.Editor.ProductionReplayIntegrationPlanContractProbe.Run",
        "-aiTestPilotProductionIntegrationContractProbePath",
        $probeEvidencePath
    ) `
    -Wait `
    -PassThru `
    -WindowStyle Hidden
if ($probeProcess.ExitCode -ne 0) {
    throw "Unity production integration contract probe failed with exit code $($probeProcess.ExitCode)"
}

$probeErrors = Select-String -Path $probeLogPath -Pattern $errorPatterns -CaseSensitive:$false
if ($probeErrors) {
    $probeErrors | Select-Object -First 40 | ForEach-Object { Write-Output $_.Line }
    throw "Unity production integration contract probe log contains errors."
}

if (-not (Test-Path $probeEvidencePath)) {
    throw "Production integration contract probe evidence was not produced: $probeEvidencePath"
}

$evidence = Get-Content -Path $probeEvidencePath -Encoding UTF8 -Raw | ConvertFrom-Json
if ($evidence.status -ne "PASS" -or
    $evidence.schemaVersion -ne "aitestpilot.production_replay_integration_contract_probe.v1" -or
    -not [bool]$evidence.fixtureGenerated -or
    [bool]$evidence.realProjectApiCallsProven -or
    $evidence.templateStatus -ne "TEMPLATE_READY" -or
    $evidence.invalidFlipStatus -ne "INVALID" -or
    $evidence.boundStatus -ne "BOUND" -or
    -not [bool]$evidence.boundRealProjectBound -or
    [int]$evidence.boundRequiredHookCount -ne 5 -or
    [int]$evidence.boundRequiredHookBoundCount -ne 5 -or
    [int]$evidence.boundUnresolvedRequiredHookCount -ne 0 -or
    -not [bool]$evidence.boundRequiredHandlerKeysPresent -or
    -not [bool]$evidence.boundAllRequiredHooksBound -or
    -not [bool]$evidence.boundRequiredBindingMetadataComplete) {
    throw "Production integration contract probe evidence did not prove template, invalid, and bound plan states."
}

New-Item -ItemType Directory -Force $evidenceBundlePath | Out-Null
$manifestTarget = Join-Path $evidenceBundlePath "production-replay-integration-contract-probe-manifest.json"
$logTarget = Join-Path $evidenceBundlePath "unity-production-integration-contract-probe.log"
$importLogTarget = Join-Path $evidenceBundlePath "unity-production-integration-contract-import.log"

Copy-Item -LiteralPath $probeEvidencePath -Destination $manifestTarget -Force
Copy-Item -LiteralPath $probeLogPath -Destination $logTarget -Force
Copy-Item -LiteralPath $importLogPath -Destination $importLogTarget -Force

Write-Output "Production integration contract probe manifest: $manifestTarget"
Write-Output "PASS AI TestPilot production replay integration contract probe"
