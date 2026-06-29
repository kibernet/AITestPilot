[CmdletBinding()]
param(
    [string]$UnityPath = "F:\Unity\2021_3_45_f2\Editor\Unity.exe",
    [string]$ProjectPath,
    [string]$ReplayProfileJsonPath,
    [string]$ReplayProfileAssetPath = "Assets/AITestPilotGenerated/ImportedReplayProfile.asset",
    [string]$ImportEvidencePath,
    [string]$NormalizedJsonPath,
    [string]$ImportLogPath,
    [string]$PackageImportLogPath,
    [string]$EvidenceBundleDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

if ([string]::IsNullOrWhiteSpace($ProjectPath)) {
    $ProjectPath = Join-Path $repoRoot "Temp\UnityImportProject"
}

if ([string]::IsNullOrWhiteSpace($ReplayProfileJsonPath)) {
    $ReplayProfileJsonPath = Join-Path $repoRoot "Temp\release-evidence\latest\sample-business-replay-profile.json"
}

if ([string]::IsNullOrWhiteSpace($ImportEvidencePath)) {
    $ImportEvidencePath = Join-Path $repoRoot "Temp\ai-testpilot-replay-profile-import.json"
}

if ([string]::IsNullOrWhiteSpace($NormalizedJsonPath)) {
    $NormalizedJsonPath = Join-Path $repoRoot "Temp\imported-replay-profile.normalized.json"
}

if ([string]::IsNullOrWhiteSpace($ImportLogPath)) {
    $ImportLogPath = Join-Path $repoRoot "Temp\unity-replay-profile-import.log"
}

if ([string]::IsNullOrWhiteSpace($PackageImportLogPath)) {
    $PackageImportLogPath = Join-Path $repoRoot "Temp\unity-replay-profile-import-package.log"
}

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if (-not (Test-Path $UnityPath)) {
    throw "Unity executable not found: $UnityPath"
}

if (-not (Test-Path $ReplayProfileJsonPath)) {
    throw "Replay profile JSON not found: $ReplayProfileJsonPath"
}

$packagePath = Join-Path $repoRoot "unity\com.kibernet.ai-testpilot"
if (-not (Test-Path $packagePath)) {
    throw "Package path not found: $packagePath"
}

$tempRoot = Split-Path $ProjectPath -Parent
New-Item -ItemType Directory -Force $tempRoot | Out-Null

if (-not (Test-Path (Join-Path $ProjectPath "ProjectSettings\ProjectVersion.txt"))) {
    Write-Output "==> create Unity validation project"
    $createProcess = Start-Process `
        -FilePath $UnityPath `
        -ArgumentList @("-batchmode", "-quit", "-createProject", $ProjectPath, "-logFile", (Join-Path $repoRoot "Temp\unity-replay-profile-import-create.log")) `
        -Wait `
        -PassThru `
        -WindowStyle Hidden
    if ($createProcess.ExitCode -ne 0) {
        throw "Unity project creation failed with exit code $($createProcess.ExitCode)"
    }
}

$manifestPath = Join-Path $ProjectPath "Packages\manifest.json"
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

Write-Output "==> Unity replay profile package import"
$packageImportProcess = Start-Process `
    -FilePath $UnityPath `
    -ArgumentList @("-batchmode", "-quit", "-projectPath", $ProjectPath, "-logFile", $PackageImportLogPath) `
    -Wait `
    -PassThru `
    -WindowStyle Hidden
if ($packageImportProcess.ExitCode -ne 0) {
    throw "Unity replay profile package import failed with exit code $($packageImportProcess.ExitCode)"
}

$errorPatterns = "error CS|Compilation failed|Package Manager.*Error|Asset import failed|Exception:"
$packageImportErrors = Select-String -Path $PackageImportLogPath -Pattern $errorPatterns -CaseSensitive:$false
if ($packageImportErrors) {
    $packageImportErrors | Select-Object -First 40 | ForEach-Object { Write-Output $_.Line }
    throw "Unity replay profile package import log contains errors."
}

$runtimeDll = Join-Path $ProjectPath "Library\ScriptAssemblies\Kibernet.AITestPilot.Runtime.dll"
$editorDll = Join-Path $ProjectPath "Library\ScriptAssemblies\Kibernet.AITestPilot.Editor.dll"
if (-not (Test-Path $runtimeDll)) {
    throw "Runtime assembly was not produced: $runtimeDll"
}

if (-not (Test-Path $editorDll)) {
    throw "Editor assembly was not produced: $editorDll"
}

foreach ($outputPath in @($ImportEvidencePath, $NormalizedJsonPath)) {
    if (Test-Path $outputPath) {
        Remove-Item -LiteralPath $outputPath -Force
    }
}

Write-Output "==> Unity replay profile JSON import"
$importProcess = Start-Process `
    -FilePath $UnityPath `
    -ArgumentList @(
        "-batchmode",
        "-quit",
        "-projectPath",
        $ProjectPath,
        "-logFile",
        $ImportLogPath,
        "-executeMethod",
        "Kibernet.AITestPilot.Unity.Editor.ActionReplayProfileBatchImporter.ImportReplayProfileFromJson",
        "-aiTestPilotReplayProfileJsonPath",
        $ReplayProfileJsonPath,
        "-aiTestPilotReplayProfileAssetPath",
        $ReplayProfileAssetPath,
        "-aiTestPilotReplayProfileImportEvidencePath",
        $ImportEvidencePath,
        "-aiTestPilotReplayProfileNormalizedJsonPath",
        $NormalizedJsonPath
    ) `
    -Wait `
    -PassThru `
    -WindowStyle Hidden
if ($importProcess.ExitCode -ne 0) {
    throw "Unity replay profile JSON import failed with exit code $($importProcess.ExitCode)"
}

$importErrors = Select-String -Path $ImportLogPath -Pattern $errorPatterns -CaseSensitive:$false
if ($importErrors) {
    $importErrors | Select-Object -First 40 | ForEach-Object { Write-Output $_.Line }
    throw "Unity replay profile JSON import log contains errors."
}

if (-not (Test-Path $ImportEvidencePath)) {
    throw "Replay profile import evidence was not produced: $ImportEvidencePath"
}

if (-not (Test-Path $NormalizedJsonPath)) {
    throw "Normalized replay profile JSON was not produced: $NormalizedJsonPath"
}

$sourceProfile = Get-Content -Raw $ReplayProfileJsonPath | ConvertFrom-Json
$normalizedProfile = Get-Content -Raw $NormalizedJsonPath | ConvertFrom-Json
$evidence = Get-Content -Raw $ImportEvidencePath | ConvertFrom-Json
$sourceRuleCount = @($sourceProfile.rules).Count

if ($evidence.status -ne "PASS") {
    throw "Unexpected replay profile import status: $($evidence.status)"
}

if ($evidence.adapterId -ne $sourceProfile.adapterId -or
    $normalizedProfile.adapterId -ne $sourceProfile.adapterId) {
    throw "Imported replay profile adapter id does not match the source JSON."
}

if ([int]$evidence.ruleCount -ne $sourceRuleCount -or
    [int]$evidence.sourceRuleCount -ne $sourceRuleCount -or
    @($normalizedProfile.rules).Count -ne $sourceRuleCount) {
    throw "Imported replay profile rule counts do not match the source JSON."
}

if (-not [bool]$evidence.assetPresent) {
    throw "Replay profile import evidence did not prove the asset exists."
}

$assetFilePath = Join-Path $ProjectPath (($evidence.assetPath -replace "/", "\"))
if (-not (Test-Path $assetFilePath)) {
    throw "Imported replay profile asset was not created: $assetFilePath"
}

$handlerKeys = @($evidence.handlerKeys)
foreach ($rule in @($sourceProfile.rules)) {
    if (-not [string]::IsNullOrWhiteSpace($rule.handlerKey) -and $handlerKeys -notcontains $rule.handlerKey) {
        throw "Replay profile import evidence is missing handler key: $($rule.handlerKey)"
    }
}

Write-Output "==> replay profile import evidence bundle"
New-Item -ItemType Directory -Force $EvidenceBundleDir | Out-Null

$evidenceTarget = Join-Path $EvidenceBundleDir "replay-profile-import.json"
$normalizedTarget = Join-Path $EvidenceBundleDir "imported-replay-profile.normalized.json"
$importLogTarget = Join-Path $EvidenceBundleDir "unity-replay-profile-import.log"
$packageImportLogTarget = Join-Path $EvidenceBundleDir "unity-replay-profile-import-package.log"
$manifestTarget = Join-Path $EvidenceBundleDir "replay-profile-import-manifest.json"

Copy-Item -LiteralPath $ImportEvidencePath -Destination $evidenceTarget -Force
Copy-Item -LiteralPath $NormalizedJsonPath -Destination $normalizedTarget -Force
Copy-Item -LiteralPath $ImportLogPath -Destination $importLogTarget -Force
Copy-Item -LiteralPath $PackageImportLogPath -Destination $packageImportLogTarget -Force

$manifest = [ordered]@{
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    sourceJsonPath = $ReplayProfileJsonPath
    importedAssetPath = $evidence.assetPath
    normalizedJsonPath = "imported-replay-profile.normalized.json"
    adapterId = $evidence.adapterId
    ruleCount = [int]$evidence.ruleCount
    handlerKeys = $handlerKeys
    actions = @($evidence.actions)
    targets = @($evidence.targets)
    assetPresent = [bool]$evidence.assetPresent
    files = @(
        "replay-profile-import.json",
        "imported-replay-profile.normalized.json",
        "unity-replay-profile-import.log",
        "unity-replay-profile-import-package.log"
    )
}

$manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $manifestTarget -Encoding UTF8

Write-Output "Replay profile import bundle: $EvidenceBundleDir"
Write-Output "PASS AI TestPilot replay profile JSON import"
