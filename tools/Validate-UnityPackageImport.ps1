[CmdletBinding()]
param(
    [string]$UnityPath = "F:\Unity\2021_3_45_f2\Editor\Unity.exe",
    [string]$ProjectPath,
    [string]$LogPath,
    [string]$SceneValidationLogPath,
    [string]$SceneEvidencePath,
    [string]$BugPackageJsonPath,
    [string]$BugPackageMarkdownPath,
    [string]$BugKnowledgeGraphJsonPath,
    [string]$BugKnowledgeGraphMarkdownPath,
    [string]$RepairTaskJsonPath,
    [string]$RepairTaskMarkdownPath,
    [string]$RepairAgentHandoffJsonPath,
    [string]$RepairAgentHandoffMarkdownPath,
    [string]$RepairAgentRunJsonPath,
    [string]$RepairAgentRunMarkdownPath,
    [string]$ProductionIntegrationJsonPath,
    [string]$ProductionIntegrationMarkdownPath,
    [string]$EvidenceBundleDir,
    [switch]$SkipSceneValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-JsonProperty {
    param(
        [object]$Object,
        [string]$Name,
        [string]$Label
    )

    if ($null -eq $Object -or @($Object.PSObject.Properties.Name) -notcontains $Name) {
        throw "$Label is missing JSON property: $Name"
    }
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

if ([string]::IsNullOrWhiteSpace($ProjectPath)) {
    $ProjectPath = Join-Path $repoRoot "Temp\UnityImportProject"
}

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $repoRoot "Temp\unity-import.log"
}

if ([string]::IsNullOrWhiteSpace($SceneValidationLogPath)) {
    $SceneValidationLogPath = Join-Path $repoRoot "Temp\unity-sample-scene-validation.log"
}

if ([string]::IsNullOrWhiteSpace($SceneEvidencePath)) {
    $SceneEvidencePath = Join-Path $repoRoot "Temp\ai-testpilot-scene-validation.json"
}

if ([string]::IsNullOrWhiteSpace($BugPackageJsonPath)) {
    $BugPackageJsonPath = Join-Path $repoRoot "Temp\ai-testpilot-bug-package.json"
}

if ([string]::IsNullOrWhiteSpace($BugPackageMarkdownPath)) {
    $BugPackageMarkdownPath = Join-Path $repoRoot "Temp\ai-testpilot-bug-package.md"
}

if ([string]::IsNullOrWhiteSpace($BugKnowledgeGraphJsonPath)) {
    $BugKnowledgeGraphJsonPath = Join-Path $repoRoot "Temp\ai-testpilot-bug-knowledge-graph.json"
}

if ([string]::IsNullOrWhiteSpace($BugKnowledgeGraphMarkdownPath)) {
    $BugKnowledgeGraphMarkdownPath = Join-Path $repoRoot "Temp\ai-testpilot-bug-knowledge-graph.md"
}

if ([string]::IsNullOrWhiteSpace($RepairTaskJsonPath)) {
    $RepairTaskJsonPath = Join-Path $repoRoot "Temp\ai-testpilot-repair-task.json"
}

if ([string]::IsNullOrWhiteSpace($RepairTaskMarkdownPath)) {
    $RepairTaskMarkdownPath = Join-Path $repoRoot "Temp\ai-testpilot-repair-task.md"
}

if ([string]::IsNullOrWhiteSpace($RepairAgentHandoffJsonPath)) {
    $RepairAgentHandoffJsonPath = Join-Path $repoRoot "Temp\ai-testpilot-repair-agent-handoff.json"
}

if ([string]::IsNullOrWhiteSpace($RepairAgentHandoffMarkdownPath)) {
    $RepairAgentHandoffMarkdownPath = Join-Path $repoRoot "Temp\ai-testpilot-repair-agent-handoff.md"
}

if ([string]::IsNullOrWhiteSpace($RepairAgentRunJsonPath)) {
    $RepairAgentRunJsonPath = Join-Path $repoRoot "Temp\ai-testpilot-repair-agent-run.json"
}

if ([string]::IsNullOrWhiteSpace($RepairAgentRunMarkdownPath)) {
    $RepairAgentRunMarkdownPath = Join-Path $repoRoot "Temp\ai-testpilot-repair-agent-run.md"
}

if ([string]::IsNullOrWhiteSpace($ProductionIntegrationJsonPath)) {
    $ProductionIntegrationJsonPath = Join-Path $repoRoot "Temp\ai-testpilot-production-replay-integration-checklist.json"
}

if ([string]::IsNullOrWhiteSpace($ProductionIntegrationMarkdownPath)) {
    $ProductionIntegrationMarkdownPath = Join-Path $repoRoot "Temp\ai-testpilot-production-replay-integration-checklist.md"
}

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if (-not (Test-Path $UnityPath)) {
    throw "Unity executable not found: $UnityPath"
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
        -ArgumentList @("-batchmode", "-quit", "-createProject", $ProjectPath, "-logFile", (Join-Path $repoRoot "Temp\unity-create.log")) `
        -Wait `
        -PassThru `
        -WindowStyle Hidden
    $createExitCode = $createProcess.ExitCode
    if ($createExitCode -ne 0) {
        throw "Unity project creation failed with exit code $createExitCode"
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

Write-Output "==> Unity package import"
$importProcess = Start-Process `
    -FilePath $UnityPath `
    -ArgumentList @("-batchmode", "-quit", "-projectPath", $ProjectPath, "-logFile", $LogPath) `
    -Wait `
    -PassThru `
    -WindowStyle Hidden
$importExitCode = $importProcess.ExitCode
if ($importExitCode -ne 0) {
    throw "Unity import failed with exit code $importExitCode"
}

$errorPatterns = "error CS|Compilation failed|Package Manager.*Error|Asset import failed|Exception:"
$errors = Select-String -Path $LogPath -Pattern $errorPatterns -CaseSensitive:$false
if ($errors) {
    $errors | Select-Object -First 40 | ForEach-Object { Write-Output $_.Line }
    throw "Unity import log contains errors."
}

$runtimeDll = Join-Path $ProjectPath "Library\ScriptAssemblies\Kibernet.AITestPilot.Runtime.dll"
$editorDll = Join-Path $ProjectPath "Library\ScriptAssemblies\Kibernet.AITestPilot.Editor.dll"
if (-not (Test-Path $runtimeDll)) {
    throw "Runtime assembly was not produced: $runtimeDll"
}

if (-not (Test-Path $editorDll)) {
    throw "Editor assembly was not produced: $editorDll"
}

if (-not $SkipSceneValidation) {
    if (Test-Path $SceneEvidencePath) {
        Remove-Item -LiteralPath $SceneEvidencePath -Force
    }
    if (Test-Path $BugPackageJsonPath) {
        Remove-Item -LiteralPath $BugPackageJsonPath -Force
    }
    if (Test-Path $BugPackageMarkdownPath) {
        Remove-Item -LiteralPath $BugPackageMarkdownPath -Force
    }
    if (Test-Path $BugKnowledgeGraphJsonPath) {
        Remove-Item -LiteralPath $BugKnowledgeGraphJsonPath -Force
    }
    if (Test-Path $BugKnowledgeGraphMarkdownPath) {
        Remove-Item -LiteralPath $BugKnowledgeGraphMarkdownPath -Force
    }
    if (Test-Path $RepairTaskJsonPath) {
        Remove-Item -LiteralPath $RepairTaskJsonPath -Force
    }
    if (Test-Path $RepairTaskMarkdownPath) {
        Remove-Item -LiteralPath $RepairTaskMarkdownPath -Force
    }
    if (Test-Path $RepairAgentHandoffJsonPath) {
        Remove-Item -LiteralPath $RepairAgentHandoffJsonPath -Force
    }
    if (Test-Path $RepairAgentHandoffMarkdownPath) {
        Remove-Item -LiteralPath $RepairAgentHandoffMarkdownPath -Force
    }
    if (Test-Path $RepairAgentRunJsonPath) {
        Remove-Item -LiteralPath $RepairAgentRunJsonPath -Force
    }
    if (Test-Path $RepairAgentRunMarkdownPath) {
        Remove-Item -LiteralPath $RepairAgentRunMarkdownPath -Force
    }
    if (Test-Path $ProductionIntegrationJsonPath) {
        Remove-Item -LiteralPath $ProductionIntegrationJsonPath -Force
    }
    if (Test-Path $ProductionIntegrationMarkdownPath) {
        Remove-Item -LiteralPath $ProductionIntegrationMarkdownPath -Force
    }

    Write-Output "==> Unity sample scene validation"
    $sceneValidationProcess = Start-Process `
        -FilePath $UnityPath `
        -ArgumentList @(
            "-batchmode",
            "-quit",
            "-projectPath",
            $ProjectPath,
            "-logFile",
            $SceneValidationLogPath,
            "-executeMethod",
            "Kibernet.AITestPilot.Unity.Editor.AITestPilotBatchValidator.RunSampleSceneValidation",
            "-aiTestPilotEvidencePath",
            $SceneEvidencePath,
            "-aiTestPilotBugPackageJsonPath",
            $BugPackageJsonPath,
            "-aiTestPilotBugPackageMarkdownPath",
            $BugPackageMarkdownPath,
            "-aiTestPilotBugKnowledgeGraphJsonPath",
            $BugKnowledgeGraphJsonPath,
            "-aiTestPilotBugKnowledgeGraphMarkdownPath",
            $BugKnowledgeGraphMarkdownPath,
            "-aiTestPilotRepairTaskJsonPath",
            $RepairTaskJsonPath,
            "-aiTestPilotRepairTaskMarkdownPath",
            $RepairTaskMarkdownPath,
            "-aiTestPilotRepairAgentHandoffJsonPath",
            $RepairAgentHandoffJsonPath,
            "-aiTestPilotRepairAgentHandoffMarkdownPath",
            $RepairAgentHandoffMarkdownPath,
            "-aiTestPilotRepairAgentRunJsonPath",
            $RepairAgentRunJsonPath,
            "-aiTestPilotRepairAgentRunMarkdownPath",
            $RepairAgentRunMarkdownPath,
            "-aiTestPilotProductionIntegrationJsonPath",
            $ProductionIntegrationJsonPath,
            "-aiTestPilotProductionIntegrationMarkdownPath",
            $ProductionIntegrationMarkdownPath
        ) `
        -Wait `
        -PassThru `
        -WindowStyle Hidden
    $sceneValidationExitCode = $sceneValidationProcess.ExitCode
    if ($sceneValidationExitCode -ne 0) {
        throw "Unity sample scene validation failed with exit code $sceneValidationExitCode"
    }

    $sceneErrors = Select-String -Path $SceneValidationLogPath -Pattern $errorPatterns -CaseSensitive:$false
    if ($sceneErrors) {
        $sceneErrors | Select-Object -First 40 | ForEach-Object { Write-Output $_.Line }
        throw "Unity sample scene validation log contains errors."
    }

    if (-not (Test-Path $SceneEvidencePath)) {
        throw "Scene validation evidence was not produced: $SceneEvidencePath"
    }

    $evidence = Get-Content -Raw $SceneEvidencePath | ConvertFrom-Json
    if ($evidence.status -ne "PASS") {
        throw "Unexpected scene validation status: $($evidence.status)"
    }

    if ([string]::IsNullOrWhiteSpace($evidence.scene)) {
        throw "Scene validation evidence did not include a generated scene name."
    }

    if ($evidence.firstTarget -ne "Sample.Lobby.StartButton" -or $evidence.bugType -ne "NullReference") {
        throw "Scene validation evidence did not prove the expected target click and bug packaging."
    }

    if ($evidence.uiElementCount -lt 1 -or $evidence.clickCount -ne 1 -or -not $evidence.runnerPresent) {
        throw "Scene validation evidence did not prove snapshot, click, and runner behavior."
    }

    if ($null -eq $evidence.multiStepRunner -or
        $evidence.multiStepRunner.status -ne "PASS" -or
        [int]$evidence.multiStepRunner.maxSteps -ne 3 -or
        [int]$evidence.multiStepRunner.stepCount -ne 3 -or
        [int]$evidence.multiStepRunner.actionCount -ne 3 -or
        [int]$evidence.multiStepRunner.clickCount -ne 3 -or
        $evidence.multiStepRunner.exitReason -ne "max_steps") {
        throw "Scene validation evidence did not prove multi-step DecisionLoopRunner execution."
    }

    $multiStepRunnerSteps = @()
    if ($null -ne $evidence.multiStepRunner.steps) {
        $multiStepRunnerSteps = @($evidence.multiStepRunner.steps)
    }

    if ($multiStepRunnerSteps.Count -ne 3) {
        throw "Multi-step runner evidence did not include exactly three recorded steps."
    }

    foreach ($runnerStep in $multiStepRunnerSteps) {
        if ($runnerStep -ne "click:Sample.Lobby.StartButton") {
            throw "Multi-step runner evidence included an unexpected step: $runnerStep"
        }
    }

    if ($evidence.snapshotSchemaVersion -ne "aitestpilot.snapshot.v1" -or
        [string]::IsNullOrWhiteSpace($evidence.snapshotJson)) {
        throw "Scene validation evidence did not include the expected snapshot JSON schema marker."
    }

    $snapshotJson = $evidence.snapshotJson | ConvertFrom-Json
    foreach ($propertyName in @("scene", "stepIndex", "capturedAtUtc", "ui", "gameState", "logs")) {
        Assert-JsonProperty $snapshotJson $propertyName "snapshotJson"
    }

    $capturedAt = [datetime]::MinValue
    if (-not [datetime]::TryParse($snapshotJson.capturedAtUtc, [ref]$capturedAt)) {
        throw "Snapshot JSON capturedAtUtc is not parseable."
    }

    if ($snapshotJson.scene -ne $evidence.scene -or [int]$snapshotJson.stepIndex -ne 0) {
        throw "Snapshot JSON scene or stepIndex does not match the validation evidence."
    }

    $snapshotUi = @()
    if ($null -ne $snapshotJson.ui) {
        $snapshotUi = @($snapshotJson.ui)
    }
    if ($snapshotUi.Count -lt 1) {
        throw "Snapshot JSON did not include UI elements."
    }

    foreach ($propertyName in @("automationId", "name", "kind", "interactable", "active")) {
        Assert-JsonProperty $snapshotUi[0] $propertyName "snapshotJson.ui[0]"
    }

    $snapshotGameState = @()
    if ($null -ne $snapshotJson.gameState) {
        $snapshotGameState = @($snapshotJson.gameState)
    }
    if ($snapshotGameState.Count -lt 2) {
        throw "Snapshot JSON did not include game state entries."
    }

    foreach ($propertyName in @("key", "value")) {
        Assert-JsonProperty $snapshotGameState[0] $propertyName "snapshotJson.gameState[0]"
    }

    $snapshotLogs = @()
    if ($null -ne $snapshotJson.logs) {
        $snapshotLogs = @($snapshotJson.logs)
    }
    if ($snapshotLogs.Count -gt 0) {
        foreach ($propertyName in @("type", "message", "stackTrace", "timestampUtc")) {
            Assert-JsonProperty $snapshotLogs[0] $propertyName "snapshotJson.logs[0]"
        }
    }

    $runReports = @()
    if ($null -ne $evidence.runReports) {
        $runReports = @($evidence.runReports)
    }

    if ($runReports.Count -lt 4) {
        throw "Scene validation evidence did not include exploration, multi-step runner, bug, and retest run reports."
    }

    $multiStepRunnerRun = $runReports | Where-Object { $_.runId -eq "RUN-SAMPLE-MULTI-STEP-RUNNER" } | Select-Object -First 1
    if ($null -eq $multiStepRunnerRun -or
        $multiStepRunnerRun.outcome -ne "PASSED" -or
        $multiStepRunnerRun.exitReason -ne "max_steps" -or
        [int]$multiStepRunnerRun.stepCount -ne 3 -or
        [int]$multiStepRunnerRun.actionCount -ne 3) {
        throw "Scene validation evidence did not include a valid multi-step runner run report."
    }

    $bugRun = $runReports | Where-Object { $_.outcome -eq "BUG_DETECTED" } | Select-Object -First 1
    if ($null -eq $bugRun -or $bugRun.bugCount -ne 1 -or $bugRun.errorLogCount -ne 1) {
        throw "Scene validation evidence did not include a valid bug run report."
    }

    if ($null -eq $evidence.retestReport -or -not $evidence.retestReport.passed) {
        throw "Scene validation evidence did not include a passing retest report."
    }

    if ($null -eq $evidence.bugPackage -or
        [string]::IsNullOrWhiteSpace($evidence.bugPackage.bugId) -or
        $evidence.bugPackage.bugId -ne $evidence.retestReport.bugId -or
        $evidence.bugPackage.type -ne "NullReference" -or
        $evidence.bugPackage.risk -ne "HIGH" -or
        $evidence.bugPackage.module -ne "SampleModule" -or
        $evidence.bugPackage.function -ne "StartButton") {
        throw "Scene validation evidence did not include a complete structured bug package."
    }

    $evidenceBugPackageSteps = @()
    if ($null -ne $evidence.bugPackage.steps) {
        $evidenceBugPackageSteps = @($evidence.bugPackage.steps)
    }

    if ($evidenceBugPackageSteps.Count -lt 5 -or
        $evidenceBugPackageSteps -notcontains "prepare_account:qa_smoke_account" -or
        $evidenceBugPackageSteps -notcontains "login:qa_smoke_account" -or
        $evidenceBugPackageSteps -notcontains "enter_scene:Activity" -or
        $evidenceBugPackageSteps -notcontains "claim_reward:Activity.ClaimReward" -or
        $evidenceBugPackageSteps -notcontains "play_fishing:CastLine") {
        throw "Scene validation bug package does not include the expected business replay path."
    }

    if ($null -eq $evidence.bugKnowledgeGraph -or
        $evidence.bugKnowledgeGraph.schemaVersion -ne "aitestpilot.bug_knowledge_graph.v1" -or
        [int]$evidence.bugKnowledgeGraph.nodeCount -ne 1 -or
        [int]$evidence.bugKnowledgeGraph.highRiskCount -ne 1) {
        throw "Scene validation evidence did not include a complete bug knowledge graph export."
    }

    $evidenceGraphModuleRisks = @()
    if ($null -ne $evidence.bugKnowledgeGraph.moduleRisks) {
        $evidenceGraphModuleRisks = @($evidence.bugKnowledgeGraph.moduleRisks)
    }

    if ($evidenceGraphModuleRisks.Count -ne 1 -or
        $evidenceGraphModuleRisks[0].module -ne "SampleModule" -or
        [int]$evidenceGraphModuleRisks[0].bugCount -ne 1 -or
        [int]$evidenceGraphModuleRisks[0].highRiskCount -ne 1 -or
        [int]$evidenceGraphModuleRisks[0].score -ne 5) {
        throw "Scene validation bug knowledge graph did not rank the expected high-risk module."
    }

    $evidenceGraphModuleFailureTypeRisks = @()
    if ($null -ne $evidence.bugKnowledgeGraph.moduleFailureTypeRisks) {
        $evidenceGraphModuleFailureTypeRisks = @($evidence.bugKnowledgeGraph.moduleFailureTypeRisks)
    }

    if ($evidenceGraphModuleFailureTypeRisks.Count -ne 1 -or
        $evidenceGraphModuleFailureTypeRisks[0].module -ne "SampleModule" -or
        $evidenceGraphModuleFailureTypeRisks[0].type -ne "NullReference" -or
        [int]$evidenceGraphModuleFailureTypeRisks[0].bugCount -ne 1 -or
        [int]$evidenceGraphModuleFailureTypeRisks[0].highRiskCount -ne 1 -or
        [int]$evidenceGraphModuleFailureTypeRisks[0].score -ne 5) {
        throw "Scene validation bug knowledge graph did not rank the expected module/failure-type risk."
    }

    $evidenceGraphNodes = @()
    if ($null -ne $evidence.bugKnowledgeGraph.nodes) {
        $evidenceGraphNodes = @($evidence.bugKnowledgeGraph.nodes)
    }

    if ($evidenceGraphNodes.Count -ne 1 -or
        $evidenceGraphNodes[0].bugId -ne $evidence.bugPackage.bugId -or
        $evidenceGraphNodes[0].type -ne "NullReference" -or
        $evidenceGraphNodes[0].risk -ne "HIGH" -or
        $evidenceGraphNodes[0].module -ne "SampleModule" -or
        $evidenceGraphNodes[0].function -ne "StartButton" -or
        $evidenceGraphNodes[0].fix -ne "add null guard before reward access") {
        throw "Scene validation bug knowledge graph node does not match the packaged bug and fix hint."
    }

    if ($null -eq $evidence.repairTask -or [string]::IsNullOrWhiteSpace($evidence.repairTask.taskId)) {
        throw "Scene validation evidence did not include a structured repair task."
    }

    if ($evidence.repairTask.bugId -ne $evidence.retestReport.bugId) {
        throw "Repair task bug id does not match the retest report bug id."
    }

    if ($evidence.repairTask.sourceRunId -ne $bugRun.runId) {
        throw "Repair task source run id does not match the bug run."
    }

    if (-not (Test-Path $BugPackageJsonPath)) {
        throw "Bug package JSON was not produced: $BugPackageJsonPath"
    }

    if (-not (Test-Path $BugPackageMarkdownPath)) {
        throw "Bug package Markdown was not produced: $BugPackageMarkdownPath"
    }

    $bugPackage = Get-Content -Raw $BugPackageJsonPath | ConvertFrom-Json
    if ($bugPackage.bugId -ne $evidence.bugPackage.bugId -or
        $bugPackage.type -ne "NullReference" -or
        $bugPackage.risk -ne "HIGH" -or
        $bugPackage.module -ne "SampleModule" -or
        $bugPackage.function -ne "StartButton" -or
        $bugPackage.log -notmatch [regex]::Escape("validation reward is null")) {
        throw "Bug package JSON does not include the expected bug identity, risk, source, and log."
    }

    $bugPackageSteps = @()
    if ($null -ne $bugPackage.steps) {
        $bugPackageSteps = @($bugPackage.steps)
    }

    if ($bugPackageSteps.Count -lt 5 -or
        $bugPackageSteps -notcontains "prepare_account:qa_smoke_account" -or
        $bugPackageSteps -notcontains "login:qa_smoke_account" -or
        $bugPackageSteps -notcontains "enter_scene:Activity" -or
        $bugPackageSteps -notcontains "claim_reward:Activity.ClaimReward" -or
        $bugPackageSteps -notcontains "play_fishing:CastLine") {
        throw "Bug package JSON does not include the expected reproduction steps."
    }

    $bugPackageMarkdown = Get-Content -Raw $BugPackageMarkdownPath
    foreach ($snippet in @($bugPackage.bugId, "NullReference", "SampleModule", "StartButton", "validation reward is null", "Reproduction Steps")) {
        if ($bugPackageMarkdown -notmatch [regex]::Escape($snippet)) {
            throw "Bug package Markdown is missing expected snippet: $snippet"
        }
    }

    if (-not (Test-Path $BugKnowledgeGraphJsonPath)) {
        throw "Bug knowledge graph JSON was not produced: $BugKnowledgeGraphJsonPath"
    }

    if (-not (Test-Path $BugKnowledgeGraphMarkdownPath)) {
        throw "Bug knowledge graph Markdown was not produced: $BugKnowledgeGraphMarkdownPath"
    }

    $bugKnowledgeGraph = Get-Content -Raw $BugKnowledgeGraphJsonPath | ConvertFrom-Json
    if ($bugKnowledgeGraph.schemaVersion -ne "aitestpilot.bug_knowledge_graph.v1" -or
        [int]$bugKnowledgeGraph.nodeCount -ne 1 -or
        [int]$bugKnowledgeGraph.highRiskCount -ne 1) {
        throw "Bug knowledge graph JSON does not include the expected schema and risk counts."
    }

    $bugKnowledgeGraphModuleRisks = @()
    if ($null -ne $bugKnowledgeGraph.moduleRisks) {
        $bugKnowledgeGraphModuleRisks = @($bugKnowledgeGraph.moduleRisks)
    }

    $bugKnowledgeGraphNodes = @()
    if ($null -ne $bugKnowledgeGraph.nodes) {
        $bugKnowledgeGraphNodes = @($bugKnowledgeGraph.nodes)
    }

    $bugKnowledgeGraphModuleFailureTypeRisks = @()
    if ($null -ne $bugKnowledgeGraph.moduleFailureTypeRisks) {
        $bugKnowledgeGraphModuleFailureTypeRisks = @($bugKnowledgeGraph.moduleFailureTypeRisks)
    }

    if ($bugKnowledgeGraphModuleRisks.Count -ne 1 -or
        $bugKnowledgeGraphModuleRisks[0].module -ne "SampleModule" -or
        [int]$bugKnowledgeGraphModuleRisks[0].score -ne 5 -or
        $bugKnowledgeGraphModuleFailureTypeRisks.Count -ne 1 -or
        $bugKnowledgeGraphModuleFailureTypeRisks[0].module -ne "SampleModule" -or
        $bugKnowledgeGraphModuleFailureTypeRisks[0].type -ne "NullReference" -or
        [int]$bugKnowledgeGraphModuleFailureTypeRisks[0].score -ne 5 -or
        $bugKnowledgeGraphNodes.Count -ne 1 -or
        $bugKnowledgeGraphNodes[0].bugId -ne $bugPackage.bugId -or
        $bugKnowledgeGraphNodes[0].fix -ne "add null guard before reward access") {
        throw "Bug knowledge graph JSON does not include the expected module ranking and fix node."
    }

    $bugKnowledgeGraphMarkdown = Get-Content -Raw $BugKnowledgeGraphMarkdownPath
    foreach ($snippet in @("aitestpilot.bug_knowledge_graph.v1", "SampleModule", "NullReference", "score=5", $bugPackage.bugId, "add null guard before reward access")) {
        if ($bugKnowledgeGraphMarkdown -notmatch [regex]::Escape($snippet)) {
            throw "Bug knowledge graph Markdown is missing expected snippet: $snippet"
        }
    }

    if (-not (Test-Path $RepairTaskJsonPath)) {
        throw "Repair task JSON was not produced: $RepairTaskJsonPath"
    }

    if (-not (Test-Path $RepairTaskMarkdownPath)) {
        throw "Repair task Markdown was not produced: $RepairTaskMarkdownPath"
    }

    $repairTask = Get-Content -Raw $RepairTaskJsonPath | ConvertFrom-Json
    if ($repairTask.bugId -ne $evidence.repairTask.bugId -or [string]::IsNullOrWhiteSpace($repairTask.retestCommand)) {
        throw "Repair task JSON does not include the expected bug id and retest command."
    }

    $repairTaskReproductionSteps = @()
    if ($null -ne $repairTask.reproductionSteps) {
        $repairTaskReproductionSteps = @($repairTask.reproductionSteps)
    }

    if ($repairTaskReproductionSteps.Count -lt 5 -or
        $repairTask.reproductionSteps -notcontains "prepare_account:qa_smoke_account" -or
        $repairTask.reproductionSteps -notcontains "login:qa_smoke_account" -or
        $repairTask.reproductionSteps -notcontains "enter_scene:Activity" -or
        $repairTask.reproductionSteps -notcontains "claim_reward:Activity.ClaimReward" -or
        $repairTask.reproductionSteps -notcontains "play_fishing:CastLine") {
        throw "Repair task JSON does not include the expected multi-step business replay path."
    }

    if ($repairTask.retestCommand -ne ".\tools\Invoke-AITestPilotRepairRetest.ps1") {
        throw "Repair task retest command does not point to the targeted retest script."
    }

    $repairTaskMarkdown = Get-Content -Raw $RepairTaskMarkdownPath
    if ($repairTaskMarkdown -notmatch [regex]::Escape($repairTask.bugId) -or
        $repairTaskMarkdown -notmatch [regex]::Escape($repairTask.sourceRunId) -or
        $repairTaskMarkdown -notmatch "Acceptance Criteria") {
        throw "Repair task Markdown does not include bug id, source run id, and acceptance criteria."
    }

    if ($null -eq $evidence.repairAgentHandoff -or
        $evidence.repairAgentHandoff.schemaVersion -ne "aitestpilot.repair_agent_handoff.v1" -or
        $evidence.repairAgentHandoff.status -ne "READY" -or
        $evidence.repairAgentHandoff.agentName -ne "Cursor" -or
        $evidence.repairAgentHandoff.launchCommand -ne "cursor repair-agent-handoff.md" -or
        $evidence.repairAgentHandoff.taskId -ne $repairTask.taskId -or
        $evidence.repairAgentHandoff.bugId -ne $bugPackage.bugId -or
        $evidence.repairAgentHandoff.retestCommand -ne ".\tools\Invoke-AITestPilotRepairRetest.ps1") {
        throw "Scene validation evidence did not include a Cursor-ready repair agent handoff."
    }

    $evidenceHandoffContextFiles = @()
    if ($null -ne $evidence.repairAgentHandoff.contextFiles) {
        $evidenceHandoffContextFiles = @($evidence.repairAgentHandoff.contextFiles)
    }

    $evidenceHandoffContextFileNames = @($evidenceHandoffContextFiles | ForEach-Object { $_.path })
    foreach ($requiredContextFile in @(
        "repair-task.json",
        "repair-task.md",
        "bug-package.json",
        "bug-knowledge-graph.json",
        "scene-validation.json"
    )) {
        if ($evidenceHandoffContextFileNames -notcontains $requiredContextFile) {
            throw "Scene validation repair agent handoff is missing context file: $requiredContextFile"
        }
    }

    if (-not (Test-Path $RepairAgentHandoffJsonPath)) {
        throw "Repair agent handoff JSON was not produced: $RepairAgentHandoffJsonPath"
    }

    if (-not (Test-Path $RepairAgentHandoffMarkdownPath)) {
        throw "Repair agent handoff Markdown was not produced: $RepairAgentHandoffMarkdownPath"
    }

    $repairAgentHandoff = Get-Content -Raw $RepairAgentHandoffJsonPath | ConvertFrom-Json
    if ($repairAgentHandoff.schemaVersion -ne "aitestpilot.repair_agent_handoff.v1" -or
        $repairAgentHandoff.status -ne "READY" -or
        $repairAgentHandoff.agentName -ne "Cursor" -or
        $repairAgentHandoff.primaryContextFile -ne "repair-agent-handoff.md" -or
        $repairAgentHandoff.launchCommand -ne "cursor repair-agent-handoff.md" -or
        $repairAgentHandoff.taskId -ne $repairTask.taskId -or
        $repairAgentHandoff.bugId -ne $bugPackage.bugId -or
        $repairAgentHandoff.graphSchemaVersion -ne "aitestpilot.bug_knowledge_graph.v1") {
        throw "Repair agent handoff JSON does not include the expected launch, task, bug, and graph context."
    }

    $repairAgentHandoffContextFiles = @()
    if ($null -ne $repairAgentHandoff.contextFiles) {
        $repairAgentHandoffContextFiles = @($repairAgentHandoff.contextFiles)
    }

    $repairAgentHandoffContextFileNames = @($repairAgentHandoffContextFiles | ForEach-Object { $_.path })
    foreach ($requiredContextFile in @(
        "repair-task.json",
        "repair-task.md",
        "bug-package.json",
        "bug-knowledge-graph.json",
        "scene-validation.json"
    )) {
        if ($repairAgentHandoffContextFileNames -notcontains $requiredContextFile) {
            throw "Repair agent handoff JSON is missing context file: $requiredContextFile"
        }
    }

    $repairAgentHandoffMarkdown = Get-Content -Raw $RepairAgentHandoffMarkdownPath
    foreach ($snippet in @("AI TestPilot Repair Agent Handoff", "cursor repair-agent-handoff.md", $repairTask.taskId, $bugPackage.bugId, "repair-task.json", "bug-knowledge-graph.json", "Acceptance Criteria")) {
        if ($repairAgentHandoffMarkdown -notmatch [regex]::Escape($snippet)) {
            throw "Repair agent handoff Markdown is missing expected snippet: $snippet"
        }
    }

    if ($null -eq $evidence.repairAgentRun -or
        $evidence.repairAgentRun.schemaVersion -ne "aitestpilot.repair_agent_run.v1" -or
        $evidence.repairAgentRun.status -ne "AWAITING_EXTERNAL_AGENT" -or
        [bool]$evidence.repairAgentRun.agentLaunched -or
        -not [bool]$evidence.repairAgentRun.externalAgentRequired -or
        $evidence.repairAgentRun.patchOutputStatus -ne "PENDING_EXTERNAL_AGENT" -or
        [int]$evidence.repairAgentRun.patchOutputCount -ne 0 -or
        $evidence.repairAgentRun.postPatchRetestCommand -ne ".\tools\Invoke-AITestPilotRepairRetest.ps1") {
        throw "Scene validation evidence did not include a bounded repair-agent run tracker."
    }

    if (-not (Test-Path $RepairAgentRunJsonPath)) {
        throw "Repair agent run JSON was not produced: $RepairAgentRunJsonPath"
    }

    if (-not (Test-Path $RepairAgentRunMarkdownPath)) {
        throw "Repair agent run Markdown was not produced: $RepairAgentRunMarkdownPath"
    }

    $repairAgentRun = Get-Content -Raw $RepairAgentRunJsonPath | ConvertFrom-Json
    if ($repairAgentRun.schemaVersion -ne "aitestpilot.repair_agent_run.v1" -or
        $repairAgentRun.status -ne "AWAITING_EXTERNAL_AGENT" -or
        [bool]$repairAgentRun.agentLaunched -or
        -not [bool]$repairAgentRun.externalAgentRequired -or
        $repairAgentRun.patchOutputStatus -ne "PENDING_EXTERNAL_AGENT" -or
        [int]$repairAgentRun.patchOutputCount -ne 0 -or
        $repairAgentRun.taskId -ne $repairAgentHandoff.taskId -or
        $repairAgentRun.bugId -ne $repairAgentHandoff.bugId -or
        $repairAgentRun.postPatchRetestCommand -ne ".\tools\Invoke-AITestPilotRepairRetest.ps1") {
        throw "Repair agent run JSON does not include the expected execution state and patch-output boundary."
    }

    $repairAgentPatchOutputs = @()
    if ($null -ne $repairAgentRun.expectedPatchOutputs) {
        $repairAgentPatchOutputs = @($repairAgentRun.expectedPatchOutputs)
    }

    $repairAgentPatchOutputPaths = @($repairAgentPatchOutputs | ForEach-Object { $_.path })
    foreach ($expectedPatchOutputPath in @("repair-agent.patch", "repair-agent-summary.md")) {
        if ($repairAgentPatchOutputPaths -notcontains $expectedPatchOutputPath) {
            throw "Repair agent run JSON is missing expected patch output slot: $expectedPatchOutputPath"
        }
    }

    foreach ($patchOutput in $repairAgentPatchOutputs) {
        if ([bool]$patchOutput.produced) {
            throw "Repair agent run JSON must not claim patch output was produced before the external agent runs."
        }
    }

    $repairAgentRunMarkdown = Get-Content -Raw $RepairAgentRunMarkdownPath
    foreach ($snippet in @("AI TestPilot Repair Agent Run", "AWAITING_EXTERNAL_AGENT", "PENDING_EXTERNAL_AGENT", "repair-agent.patch", "repair-agent-summary.md", ".\tools\Invoke-AITestPilotRepairRetest.ps1")) {
        if ($repairAgentRunMarkdown -notmatch [regex]::Escape($snippet)) {
            throw "Repair agent run Markdown is missing expected snippet: $snippet"
        }
    }

    if ($null -eq $evidence.releaseEvidence -or -not $evidence.releaseEvidence.allowRelease) {
        throw "Scene validation evidence did not include passing release evidence."
    }

    if ($evidence.releaseEvidence.unverifiedHighRiskBugCount -ne 0) {
        throw "Scene validation release evidence still has unverified high-risk bugs."
    }

    if ($null -eq $evidence.modelEndpoint -or $evidence.modelEndpoint.status -ne "PASS") {
        throw "Scene validation evidence did not include passing model endpoint settings evidence."
    }

    if ($evidence.modelEndpoint.liveRequestsEnabled) {
        throw "Sample model endpoint settings should not enable live requests by default."
    }

    if ($evidence.modelEndpoint.actionSchemaVersion -ne "ai-testpilot.action.v1" -or
        -not [bool]$evidence.modelEndpoint.requestContainsSnapshot -or
        -not [bool]$evidence.modelEndpoint.requestContainsActionSchema -or
        -not [bool]$evidence.modelEndpoint.requestContainsFixHints -or
        [int]$evidence.modelEndpoint.fixHintCount -ne 1 -or
        -not [bool]$evidence.modelEndpoint.openAICompatibleChatRequestValid -or
        $evidence.modelEndpoint.parsedAction -ne "click" -or
        $evidence.modelEndpoint.parsedTarget -ne "Sample.Lobby.StartButton") {
        throw "Model endpoint settings evidence did not prove schema, provider wrapper, snapshot, fix hints, and action parsing."
    }

    if ($null -eq $evidence.productionReplayIntegration -or
        $evidence.productionReplayIntegration.status -ne "TEMPLATE_READY") {
        throw "Scene validation evidence did not include template-ready production replay integration evidence."
    }

    if ([bool]$evidence.productionReplayIntegration.realProjectBound -or
        [int]$evidence.productionReplayIntegration.requiredHookCount -ne 5 -or
        [int]$evidence.productionReplayIntegration.boundRequiredHookCount -ne 0 -or
        [int]$evidence.productionReplayIntegration.unresolvedRequiredHookCount -ne 5 -or
        -not [bool]$evidence.productionReplayIntegration.requiredHandlerKeysPresent) {
        throw "Production replay integration evidence does not clearly expose the unbound template state."
    }

    if (-not (Test-Path $ProductionIntegrationJsonPath)) {
        throw "Production replay integration JSON was not produced: $ProductionIntegrationJsonPath"
    }

    if (-not (Test-Path $ProductionIntegrationMarkdownPath)) {
        throw "Production replay integration Markdown was not produced: $ProductionIntegrationMarkdownPath"
    }

    $productionIntegration = Get-Content -Raw $ProductionIntegrationJsonPath | ConvertFrom-Json
    if ($productionIntegration.status -ne "TEMPLATE_READY" -or
        $productionIntegration.unresolvedRequiredHookCount -ne 5 -or
        -not $productionIntegration.requiredHandlerKeysPresent) {
        throw "Production replay integration JSON did not include the expected template-ready unresolved state."
    }

    $productionIntegrationMarkdown = Get-Content -Raw $ProductionIntegrationMarkdownPath
    foreach ($snippet in @("prepare_account", "login", "enter_scene", "claim_reward", "play_fishing", "Real project bound")) {
        if ($productionIntegrationMarkdown -notmatch [regex]::Escape($snippet)) {
            throw "Production replay integration Markdown is missing expected snippet: $snippet"
        }
    }

    Write-Output "==> release evidence bundle"
    New-Item -ItemType Directory -Force $EvidenceBundleDir | Out-Null

    $sceneEvidenceTarget = Join-Path $EvidenceBundleDir "scene-validation.json"
    $bugPackageJsonTarget = Join-Path $EvidenceBundleDir "bug-package.json"
    $bugPackageMarkdownTarget = Join-Path $EvidenceBundleDir "bug-package.md"
    $bugKnowledgeGraphJsonTarget = Join-Path $EvidenceBundleDir "bug-knowledge-graph.json"
    $bugKnowledgeGraphMarkdownTarget = Join-Path $EvidenceBundleDir "bug-knowledge-graph.md"
    $repairTaskJsonTarget = Join-Path $EvidenceBundleDir "repair-task.json"
    $repairTaskMarkdownTarget = Join-Path $EvidenceBundleDir "repair-task.md"
    $repairAgentHandoffJsonTarget = Join-Path $EvidenceBundleDir "repair-agent-handoff.json"
    $repairAgentHandoffMarkdownTarget = Join-Path $EvidenceBundleDir "repair-agent-handoff.md"
    $repairAgentRunJsonTarget = Join-Path $EvidenceBundleDir "repair-agent-run.json"
    $repairAgentRunMarkdownTarget = Join-Path $EvidenceBundleDir "repair-agent-run.md"
    $productionIntegrationJsonTarget = Join-Path $EvidenceBundleDir "production-replay-integration-checklist.json"
    $productionIntegrationMarkdownTarget = Join-Path $EvidenceBundleDir "production-replay-integration-checklist.md"
    $unityImportLogTarget = Join-Path $EvidenceBundleDir "unity-import.log"
    $sceneValidationLogTarget = Join-Path $EvidenceBundleDir "unity-sample-scene-validation.log"
    $manifestTarget = Join-Path $EvidenceBundleDir "manifest.json"

    Copy-Item -LiteralPath $SceneEvidencePath -Destination $sceneEvidenceTarget -Force
    Copy-Item -LiteralPath $BugPackageJsonPath -Destination $bugPackageJsonTarget -Force
    Copy-Item -LiteralPath $BugPackageMarkdownPath -Destination $bugPackageMarkdownTarget -Force
    Copy-Item -LiteralPath $BugKnowledgeGraphJsonPath -Destination $bugKnowledgeGraphJsonTarget -Force
    Copy-Item -LiteralPath $BugKnowledgeGraphMarkdownPath -Destination $bugKnowledgeGraphMarkdownTarget -Force
    Copy-Item -LiteralPath $RepairTaskJsonPath -Destination $repairTaskJsonTarget -Force
    Copy-Item -LiteralPath $RepairTaskMarkdownPath -Destination $repairTaskMarkdownTarget -Force
    Copy-Item -LiteralPath $RepairAgentHandoffJsonPath -Destination $repairAgentHandoffJsonTarget -Force
    Copy-Item -LiteralPath $RepairAgentHandoffMarkdownPath -Destination $repairAgentHandoffMarkdownTarget -Force
    Copy-Item -LiteralPath $RepairAgentRunJsonPath -Destination $repairAgentRunJsonTarget -Force
    Copy-Item -LiteralPath $RepairAgentRunMarkdownPath -Destination $repairAgentRunMarkdownTarget -Force
    Copy-Item -LiteralPath $ProductionIntegrationJsonPath -Destination $productionIntegrationJsonTarget -Force
    Copy-Item -LiteralPath $ProductionIntegrationMarkdownPath -Destination $productionIntegrationMarkdownTarget -Force
    Copy-Item -LiteralPath $LogPath -Destination $unityImportLogTarget -Force
    Copy-Item -LiteralPath $SceneValidationLogPath -Destination $sceneValidationLogTarget -Force

    $manifest = [ordered]@{
        status = "PASS"
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
        buildVersion = $evidence.releaseEvidence.buildVersion
        allowRelease = [bool]$evidence.releaseEvidence.allowRelease
        unverifiedHighRiskBugCount = [int]$evidence.releaseEvidence.unverifiedHighRiskBugCount
        runReportCount = [int]$runReports.Count
        retestPassed = [bool]$evidence.retestReport.passed
        files = @(
            "scene-validation.json",
            "bug-package.json",
            "bug-package.md",
            "bug-knowledge-graph.json",
            "bug-knowledge-graph.md",
            "repair-task.json",
            "repair-task.md",
            "repair-agent-handoff.json",
            "repair-agent-handoff.md",
            "repair-agent-run.json",
            "repair-agent-run.md",
            "production-replay-integration-checklist.json",
            "production-replay-integration-checklist.md",
            "unity-import.log",
            "unity-sample-scene-validation.log"
        )
        summary = [ordered]@{
            scene = $evidence.scene
            firstAction = $evidence.firstAction
            firstTarget = $evidence.firstTarget
            snapshotSchemaVersion = $evidence.snapshotSchemaVersion
            clickCount = [int]$evidence.clickCount
            multiStepRunnerStatus = $evidence.multiStepRunner.status
            multiStepRunnerStepCount = [int]$evidence.multiStepRunner.stepCount
            multiStepRunnerActionCount = [int]$evidence.multiStepRunner.actionCount
            multiStepRunnerClickCount = [int]$evidence.multiStepRunner.clickCount
            multiStepRunnerExitReason = $evidence.multiStepRunner.exitReason
            bugPackageId = $evidence.bugPackage.bugId
            bugPackageType = $evidence.bugPackage.type
            bugPackageRisk = $evidence.bugPackage.risk
            bugPackageModule = $evidence.bugPackage.module
            bugPackageFunction = $evidence.bugPackage.function
            bugPackageReproductionStepCount = [int]$bugPackageSteps.Count
            bugKnowledgeGraphSchemaVersion = $bugKnowledgeGraph.schemaVersion
            bugKnowledgeGraphNodeCount = [int]$bugKnowledgeGraph.nodeCount
            bugKnowledgeGraphHighRiskCount = [int]$bugKnowledgeGraph.highRiskCount
            bugKnowledgeGraphTopModule = $bugKnowledgeGraphModuleRisks[0].module
            bugKnowledgeGraphTopModuleScore = [int]$bugKnowledgeGraphModuleRisks[0].score
            bugKnowledgeGraphTopFailureModule = $bugKnowledgeGraphModuleFailureTypeRisks[0].module
            bugKnowledgeGraphTopFailureType = $bugKnowledgeGraphModuleFailureTypeRisks[0].type
            bugKnowledgeGraphTopFailureTypeScore = [int]$bugKnowledgeGraphModuleFailureTypeRisks[0].score
            bugType = $evidence.bugType
            suggestedFix = $evidence.suggestedFix
            repairTaskId = $evidence.repairTask.taskId
            retestCommand = $evidence.repairTask.retestCommand
            repairAgentHandoffSchemaVersion = $repairAgentHandoff.schemaVersion
            repairAgentHandoffStatus = $repairAgentHandoff.status
            repairAgentHandoffAgent = $repairAgentHandoff.agentName
            repairAgentHandoffLaunchCommand = $repairAgentHandoff.launchCommand
            repairAgentHandoffContextFileCount = [int]$repairAgentHandoffContextFiles.Count
            repairAgentRunSchemaVersion = $repairAgentRun.schemaVersion
            repairAgentRunStatus = $repairAgentRun.status
            repairAgentRunAgentLaunched = [bool]$repairAgentRun.agentLaunched
            repairAgentRunExternalAgentRequired = [bool]$repairAgentRun.externalAgentRequired
            repairAgentRunPatchOutputStatus = $repairAgentRun.patchOutputStatus
            repairAgentRunPatchOutputCount = [int]$repairAgentRun.patchOutputCount
            repairAgentRunExpectedPatchOutputCount = [int]$repairAgentPatchOutputs.Count
            modelEndpointContractPassed = $evidence.modelEndpoint.status -eq "PASS"
            modelEndpointSettingsAssetPath = $evidence.modelEndpoint.settingsAssetPath
            modelEndpointLiveRequestsEnabled = [bool]$evidence.modelEndpoint.liveRequestsEnabled
            modelEndpointActionSchemaVersion = $evidence.modelEndpoint.actionSchemaVersion
            modelEndpointRequestFormat = $evidence.modelEndpoint.requestFormat
            modelEndpointOpenAICompatibleChatRequestValid = [bool]$evidence.modelEndpoint.openAICompatibleChatRequestValid
            modelEndpointRequestContainsFixHints = [bool]$evidence.modelEndpoint.requestContainsFixHints
            modelEndpointFixHintCount = [int]$evidence.modelEndpoint.fixHintCount
            productionReplayIntegrationStatus = $evidence.productionReplayIntegration.status
            productionReplayRealProjectBound = [bool]$evidence.productionReplayIntegration.realProjectBound
            productionReplayRequiredHookCount = [int]$evidence.productionReplayIntegration.requiredHookCount
            productionReplayUnresolvedRequiredHookCount = [int]$evidence.productionReplayIntegration.unresolvedRequiredHookCount
        }
    }

    $manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $manifestTarget -Encoding UTF8
    Write-Output "Evidence bundle: $EvidenceBundleDir"
}

Write-Output "PASS Unity package import and sample scene validation"
exit 0
