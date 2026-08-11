[CmdletBinding()]
param(
    [string]$UnityPath = "F:\Unity\2021_3_45_f2\Editor\Unity.exe",
    [string]$ProjectPath,
    [string]$RepairTaskJsonPath,
    [string]$RetestEvidencePath,
    [string]$RetestLogPath,
    [string]$ImportLogPath,
    [string]$ReplayProfileJsonPath,
    [string]$GameReplayDriverType,
    [string]$EvidenceBundleDir,
    [switch]$ExpectFailure,
    [string]$ExpectedFailureDriverId = "failing.game_project_driver",
    [string]$ExpectedFailureHandlerKey = "game.claim_reward",
    [string]$ExpectedFailureAction = "claim_reward",
    [string]$ExpectedFailureTarget = "Activity.ClaimReward"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
. (Join-Path $PSScriptRoot "PathGuards.ps1")

if ([string]::IsNullOrWhiteSpace($ProjectPath)) {
    $ProjectPath = Join-Path $repoRoot "Temp\UnityImportProject"
}

if ([string]::IsNullOrWhiteSpace($RepairTaskJsonPath)) {
    $RepairTaskJsonPath = Join-Path $repoRoot "Temp\release-evidence\latest\repair-task.json"
}

if ([string]::IsNullOrWhiteSpace($RetestEvidencePath)) {
    $RetestEvidencePath = Join-Path $repoRoot "Temp\ai-testpilot-repair-retest.json"
}

if ([string]::IsNullOrWhiteSpace($RetestLogPath)) {
    $RetestLogPath = Join-Path $repoRoot "Temp\unity-repair-retest.log"
}

if ([string]::IsNullOrWhiteSpace($ImportLogPath)) {
    $ImportLogPath = Join-Path $repoRoot "Temp\unity-repair-retest-import.log"
}

if ([string]::IsNullOrWhiteSpace($ReplayProfileJsonPath)) {
    $ReplayProfileJsonPath = Join-Path $repoRoot "Temp\sample-business-replay-profile.json"
}

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

$ReplayProfileJsonPath = Assert-PathUnderRoot -Path $ReplayProfileJsonPath -Label "ReplayProfileJsonPath" -RepoRoot $repoRoot

if (-not (Test-Path $UnityPath)) {
    throw "Unity executable not found: $UnityPath"
}

if (-not (Test-Path $RepairTaskJsonPath)) {
    throw "Repair task JSON not found: $RepairTaskJsonPath"
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
        -ArgumentList @("-batchmode", "-quit", "-createProject", $ProjectPath, "-logFile", (Join-Path $repoRoot "Temp\unity-repair-retest-create.log")) `
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

Write-Output "==> Unity repair retest import"
$importProcess = Start-Process `
    -FilePath $UnityPath `
    -ArgumentList @("-batchmode", "-quit", "-projectPath", $ProjectPath, "-logFile", $ImportLogPath) `
    -Wait `
    -PassThru `
    -WindowStyle Hidden
if ($importProcess.ExitCode -ne 0) {
    throw "Unity repair retest import failed with exit code $($importProcess.ExitCode)"
}

$errorPatterns = "error CS|Compilation failed|Package Manager.*Error|Asset import failed|Exception:"
$importErrors = Select-String -Path $ImportLogPath -Pattern $errorPatterns -CaseSensitive:$false
if ($importErrors) {
    $importErrors | Select-Object -First 40 | ForEach-Object { Write-Output $_.Line }
    throw "Unity repair retest import log contains errors."
}

$runtimeDll = Join-Path $ProjectPath "Library\ScriptAssemblies\Kibernet.AITestPilot.Runtime.dll"
$editorDll = Join-Path $ProjectPath "Library\ScriptAssemblies\Kibernet.AITestPilot.Editor.dll"
if (-not (Test-Path $runtimeDll)) {
    throw "Runtime assembly was not produced: $runtimeDll"
}

if (-not (Test-Path $editorDll)) {
    throw "Editor assembly was not produced: $editorDll"
}

if (Test-Path $RetestEvidencePath) {
    Remove-Item -LiteralPath $RetestEvidencePath -Force
}
if (Test-Path $ReplayProfileJsonPath) {
    Remove-Item -LiteralPath $ReplayProfileJsonPath -Force
}

$retestArguments = @(
    "-batchmode",
    "-quit",
    "-projectPath",
    $ProjectPath,
    "-logFile",
    $RetestLogPath,
    "-executeMethod",
    "Kibernet.AITestPilot.Unity.Editor.RepairTaskRetestRunner.RunRepairTaskRetest",
    "-aiTestPilotRepairTaskJsonPath",
    $RepairTaskJsonPath,
    "-aiTestPilotRepairRetestEvidencePath",
    $RetestEvidencePath,
    "-aiTestPilotReplayProfileJsonPath",
    $ReplayProfileJsonPath
)

if (-not [string]::IsNullOrWhiteSpace($GameReplayDriverType)) {
    $normalizedGameReplayDriverType = $GameReplayDriverType -replace ',\s+', ','
    $retestArguments += @("-aiTestPilotGameReplayDriverType", $normalizedGameReplayDriverType)
}

Write-Output "==> Unity repair task retest"
$retestProcess = Start-Process `
    -FilePath $UnityPath `
    -ArgumentList $retestArguments `
    -Wait `
    -PassThru `
    -WindowStyle Hidden
if ($retestProcess.ExitCode -ne 0) {
    if ($ExpectFailure) {
        if (-not (Test-Path $RetestLogPath)) {
            throw "Expected repair task retest failure, but the retest log was not produced: $RetestLogPath"
        }

        $failureLog = Get-Content -Raw $RetestLogPath
        foreach ($expectedSnippet in @(
            "FAIL AI TestPilot repair task retest",
            "Failed to replay repair task step",
            "driver=$ExpectedFailureDriverId",
            "handler=$ExpectedFailureHandlerKey",
            "action=$ExpectedFailureAction",
            "target=$ExpectedFailureTarget"
        )) {
            if ($failureLog -notmatch [regex]::Escape($expectedSnippet)) {
                throw "Expected repair task retest failure log to include: $expectedSnippet"
            }
        }

        Write-Output "==> repair driver failure evidence bundle"
        New-Item -ItemType Directory -Force $EvidenceBundleDir | Out-Null

        $failureLogTarget = Join-Path $EvidenceBundleDir "unity-repair-driver-failure.log"
        $failureImportLogTarget = Join-Path $EvidenceBundleDir "unity-repair-driver-failure-import.log"
        $failureProfileJsonTarget = Join-Path $EvidenceBundleDir "repair-driver-failure-replay-profile.json"
        $failureManifestTarget = Join-Path $EvidenceBundleDir "repair-driver-failure-manifest.json"

        Copy-Item -LiteralPath $RetestLogPath -Destination $failureLogTarget -Force
        Copy-Item -LiteralPath $ImportLogPath -Destination $failureImportLogTarget -Force
        if (Test-Path $ReplayProfileJsonPath) {
            Copy-Item -LiteralPath $ReplayProfileJsonPath -Destination $failureProfileJsonTarget -Force
        }

        $failureManifest = [ordered]@{
            status = "PASS"
            expectedFailure = $true
            generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
            retestExitCode = [int]$retestProcess.ExitCode
            gameReplayDriverType = $GameReplayDriverType
            expectedDriverId = $ExpectedFailureDriverId
            expectedHandlerKey = $ExpectedFailureHandlerKey
            expectedAction = $ExpectedFailureAction
            expectedTarget = $ExpectedFailureTarget
            files = @(
                "unity-repair-driver-failure.log",
                "unity-repair-driver-failure-import.log",
                "repair-driver-failure-replay-profile.json"
            )
        }

        $failureManifest | ConvertTo-Json -Depth 8 | Set-Content -Path $failureManifestTarget -Encoding UTF8

        Write-Output "Repair driver failure bundle: $EvidenceBundleDir"
        Write-Output "PASS AI TestPilot repair driver failure probe"
        exit 0
    }

    throw "Unity repair task retest failed with exit code $($retestProcess.ExitCode)"
}

if ($ExpectFailure) {
    throw "Expected repair task retest to fail, but it passed."
}

$retestErrors = Select-String -Path $RetestLogPath -Pattern $errorPatterns -CaseSensitive:$false
if ($retestErrors) {
    $retestErrors | Select-Object -First 40 | ForEach-Object { Write-Output $_.Line }
    throw "Unity repair task retest log contains errors."
}

if (-not (Test-Path $RetestEvidencePath)) {
    throw "Repair retest evidence was not produced: $RetestEvidencePath"
}

$repairTask = Get-Content -Raw $RepairTaskJsonPath | ConvertFrom-Json
$evidence = Get-Content -Raw $RetestEvidencePath | ConvertFrom-Json
if ($evidence.status -ne "PASS") {
    throw "Unexpected repair retest status: $($evidence.status)"
}

if ($evidence.taskId -ne $repairTask.taskId -or $evidence.bugId -ne $repairTask.bugId) {
    throw "Repair retest evidence does not match the repair task."
}

if ([string]::IsNullOrWhiteSpace($evidence.scene)) {
    throw "Repair retest evidence did not include a generated scene name."
}

if ($evidence.replayedStepCount -lt 1 -or $evidence.bugStillPresent) {
    throw "Repair retest did not replay steps successfully or still has the original bug."
}

$usedReplayAdapters = @($evidence.usedReplayAdapters)
if ($usedReplayAdapters -notcontains "profile.sample_business_flow") {
    throw "Repair retest did not use the configured sample business replay profile."
}

$registeredReplayAdapters = @($evidence.registeredReplayAdapters)
if ($registeredReplayAdapters -notcontains "default.action_executor") {
    throw "Repair retest did not expose the default replay adapter."
}

if ($registeredReplayAdapters -notcontains "sample.basic_automation") {
    throw "Repair retest did not register the sample UI replay adapter."
}

if ($registeredReplayAdapters -notcontains "profile.sample_business_flow") {
    throw "Repair retest did not register the configured sample business replay profile."
}

if ($evidence.replayProfileId -ne "profile.sample_business_flow" -or $evidence.replayProfileRuleCount -ne 5) {
    throw "Repair retest did not prove the configured replay profile id and rule count."
}

if ([string]::IsNullOrWhiteSpace($evidence.replayProfileAssetPath) -or
    [string]::IsNullOrWhiteSpace($evidence.replayProfileJsonPath)) {
    throw "Repair retest did not include replay profile asset/json paths."
}

if (-not (Test-Path (Join-Path $ProjectPath $evidence.replayProfileAssetPath))) {
    throw "Replay profile asset was not created in the Unity validation project."
}

if (-not (Test-Path $ReplayProfileJsonPath)) {
    throw "Replay profile JSON was not exported: $ReplayProfileJsonPath"
}

$replayProfileJson = Get-Content -Raw $ReplayProfileJsonPath | ConvertFrom-Json
if ($replayProfileJson.adapterId -ne "profile.sample_business_flow" -or $replayProfileJson.rules.Count -ne 5) {
    throw "Replay profile JSON did not include the expected adapter id and rules."
}

$handlerKeys = @($evidence.replayHandlerKeys)
foreach ($requiredHandlerKey in @("game.prepare_account", "game.login", "game.enter_scene", "game.claim_reward", "game.play_fishing")) {
    if ($handlerKeys -notcontains $requiredHandlerKey) {
        throw "Repair retest evidence is missing replay handler key: $requiredHandlerKey"
    }
}

$replayedActions = @($evidence.replayedActions)
foreach ($requiredHandlerKey in @("game.prepare_account", "game.login", "game.enter_scene", "game.claim_reward", "game.play_fishing")) {
    $matchingAction = $replayedActions |
        Where-Object { $_.message -match "driver=" -and $_.message -match ("handler=" + [regex]::Escape($requiredHandlerKey)) } |
        Select-Object -First 1
    if ($null -eq $matchingAction) {
        throw "Repair retest replayed action diagnostics are missing handler: $requiredHandlerKey"
    }
}

if ($null -eq $evidence.businessReplayState -or
    $evidence.businessReplayState.accountPreparationCount -ne 1 -or
    $evidence.businessReplayState.loginCount -ne 1 -or
    $evidence.businessReplayState.sceneEntryCount -ne 1 -or
    $evidence.businessReplayState.rewardClaimCount -ne 1 -or
    $evidence.businessReplayState.fishingCastCount -ne 1) {
    throw "Repair retest business replay state did not prove account, login, scene, reward, and fishing actions."
}

if ([string]::IsNullOrWhiteSpace($evidence.gameReplayDriverId) -or
    [string]::IsNullOrWhiteSpace($evidence.gameReplayDriverSource)) {
    throw "Repair retest did not include game replay driver id/source."
}

$driverDescriptor = $evidence.gameReplayDriverDescriptor
if ($null -eq $driverDescriptor) {
    throw "Repair retest did not include a game replay driver descriptor."
}

if ($driverDescriptor.driverId -ne $evidence.gameReplayDriverId -or
    $driverDescriptor.source -ne $evidence.gameReplayDriverSource) {
    throw "Game replay driver descriptor id/source does not match the retest driver."
}

$descriptorHandlerKeys = @($driverDescriptor.supportedHandlerKeys)
foreach ($requiredHandlerKey in @("game.prepare_account", "game.login", "game.enter_scene", "game.claim_reward", "game.play_fishing")) {
    if ($descriptorHandlerKeys -notcontains $requiredHandlerKey) {
        throw "Game replay driver descriptor is missing supported handler key: $requiredHandlerKey"
    }
}

$configurationRequirements = @($driverDescriptor.configurationRequirements)
if ($configurationRequirements.Count -lt 1) {
    throw "Game replay driver descriptor did not declare configuration requirements."
}

foreach ($requirement in $configurationRequirements) {
    if ([string]::IsNullOrWhiteSpace($requirement.key) -or
        [string]::IsNullOrWhiteSpace($requirement.source) -or
        [string]::IsNullOrWhiteSpace($requirement.description)) {
        throw "Game replay driver descriptor has an incomplete configuration requirement."
    }
}

if ([string]::IsNullOrWhiteSpace($GameReplayDriverType)) {
    if ($evidence.gameReplayDriverId -ne "sample.game_project_driver" -or
        $evidence.gameReplayDriverSource -ne "sample_fallback") {
        throw "Repair retest did not use the expected sample fallback game replay driver."
    }
}
else {
    if ($evidence.gameReplayDriverSource -notlike "type:*") {
        throw "Repair retest did not use the requested game replay driver type."
    }
}

if ($null -eq $evidence.retestReport -or -not $evidence.retestReport.passed) {
    throw "Repair retest evidence does not include a passing retest report."
}

Write-Output "==> repair retest evidence bundle"
New-Item -ItemType Directory -Force $EvidenceBundleDir | Out-Null

$retestEvidenceTarget = Join-Path $EvidenceBundleDir "repair-retest.json"
$replayProfileJsonTarget = Join-Path $EvidenceBundleDir "sample-business-replay-profile.json"
$retestLogTarget = Join-Path $EvidenceBundleDir "unity-repair-retest.log"
$importLogTarget = Join-Path $EvidenceBundleDir "unity-repair-retest-import.log"
$manifestTarget = Join-Path $EvidenceBundleDir "repair-retest-manifest.json"

Copy-Item -LiteralPath $RetestEvidencePath -Destination $retestEvidenceTarget -Force
Copy-Item -LiteralPath $ReplayProfileJsonPath -Destination $replayProfileJsonTarget -Force
Copy-Item -LiteralPath $RetestLogPath -Destination $retestLogTarget -Force
Copy-Item -LiteralPath $ImportLogPath -Destination $importLogTarget -Force

$manifest = [ordered]@{
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    taskId = $evidence.taskId
    bugId = $evidence.bugId
    sourceRunId = $evidence.sourceRunId
    retestId = $evidence.retestId
    retestGoal = $evidence.retestGoal
    scene = $evidence.scene
    generatedScenePath = $evidence.generatedScenePath
    replayedStepCount = [int]$evidence.replayedStepCount
    bugStillPresent = [bool]$evidence.bugStillPresent
    retestPassed = [bool]$evidence.retestReport.passed
    gameReplayDriverId = $evidence.gameReplayDriverId
    gameReplayDriverSource = $evidence.gameReplayDriverSource
    gameReplayDriverDescriptor = $driverDescriptor
    replayProfileId = $evidence.replayProfileId
    replayProfileAssetPath = $evidence.replayProfileAssetPath
    replayProfileJsonPath = "sample-business-replay-profile.json"
    replayProfileRuleCount = [int]$evidence.replayProfileRuleCount
    replayHandlerKeys = $handlerKeys
    businessReplayState = [ordered]@{
        preparedAccount = $evidence.businessReplayState.preparedAccount
        loggedInAccount = $evidence.businessReplayState.loggedInAccount
        currentScene = $evidence.businessReplayState.currentScene
        accountPreparationCount = [int]$evidence.businessReplayState.accountPreparationCount
        loginCount = [int]$evidence.businessReplayState.loginCount
        sceneEntryCount = [int]$evidence.businessReplayState.sceneEntryCount
        rewardClaimCount = [int]$evidence.businessReplayState.rewardClaimCount
        fishingCastCount = [int]$evidence.businessReplayState.fishingCastCount
    }
    registeredReplayAdapters = $registeredReplayAdapters
    usedReplayAdapters = $usedReplayAdapters
    files = @(
        "repair-retest.json",
        "sample-business-replay-profile.json",
        "unity-repair-retest.log",
        "unity-repair-retest-import.log"
    )
}

$manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $manifestTarget -Encoding UTF8

Write-Output "Repair retest bundle: $EvidenceBundleDir"
Write-Output "PASS AI TestPilot repair task retest"
