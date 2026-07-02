[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ProbeWorkDir,
    [string]$ProbeOutputDir,
    [string]$ManifestPath,
    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ProbeWorkDir)) {
    $ProbeWorkDir = Join-Path $repoRoot "Temp\release-evidence\cursor-agent-external-output-binding-probe-work"
}

if ([string]::IsNullOrWhiteSpace($ProbeOutputDir)) {
    $ProbeOutputDir = Join-Path $EvidenceBundleDir "cursor-agent-external-output-binding-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "repair-agent-cursor-agent-external-output-binding-probe-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "repair-agent-cursor-agent-external-output-binding-probe.md"
}

function Resolve-FullPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Test-PathWithinRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    $fullPath = Resolve-FullPath $Path
    $rootPath = (Resolve-FullPath $Root).TrimEnd([char[]]@("\", "/"))
    return $fullPath.Equals($rootPath, [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($rootPath + "\", [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($rootPath + "/", [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-PathUnderRepo {
    param(
        [string]$Path,
        [string]$Label
    )

    $fullPath = Resolve-FullPath $Path
    if (-not (Test-PathWithinRoot $fullPath $repoRoot)) {
        throw "$Label must stay under repo root: $fullPath"
    }

    return $fullPath
}

function Convert-ToEvidenceRelativePath {
    param([string]$Path)

    $fullPath = Resolve-FullPath $Path
    if (-not (Test-PathWithinRoot $fullPath $evidenceBundlePath)) {
        throw "Generated file must stay under evidence bundle: $fullPath"
    }

    return $fullPath.Substring($evidenceBundlePath.Length).TrimStart([char[]]@("\", "/")).Replace("\", "/")
}

function Read-JsonFile {
    param(
        [string]$Path,
        [string]$Label
    )

    if (-not (Test-Path $Path)) {
        throw "$Label is missing: $Path"
    }

    return Get-Content -Path $Path -Encoding UTF8 -Raw | ConvertFrom-Json
}

function Set-JsonProperty {
    param(
        [object]$InputObject,
        [string]$Name,
        [object]$Value
    )

    $InputObject | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Get-JsonValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$DefaultValue = $null
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }

    return $property.Value
}

function Get-FileSha256OrEmpty {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return ""
    }

    return (Get-FileHash -Algorithm SHA256 -Path $Path).Hash
}

function Remove-CursorAgentOptionalEvidence {
    param([string]$BundleDir)

    foreach ($relativePath in @(
            "repair-agent-cursor-agent-external-output-manifest.json",
            "repair-agent-cursor-agent-output-run.json",
            "repair-agent-cursor-agent-output.patch",
            "repair-agent-cursor-agent-output-summary.md",
            "repair-agent-cursor-agent-output.log",
            "repair-agent-cursor-agent-output-patch-output-manifest.json",
            "repair-agent-cursor-agent-output-preflight-manifest.json"
        )) {
        $path = Join-Path $BundleDir $relativePath
        if (Test-Path $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }
}

function Remove-BindingProbeEvidence {
    param([string]$BundleDir)

    foreach ($relativePath in @(
            "repair-agent-cursor-agent-external-output-binding-probe-manifest.json",
            "repair-agent-cursor-agent-external-output-binding-probe.md",
            "cursor-agent-external-output-binding-probe"
        )) {
        $path = Join-Path $BundleDir $relativePath
        if (Test-Path $path) {
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }
}

function Add-CursorAgentProducerManifest {
    param(
        [string]$ScenarioDir,
        [bool]$BindAcceptance,
        [bool]$MismatchPatchHash
    )

    $acceptancePath = Join-Path $ScenarioDir "repair-agent-external-task-output-acceptance-manifest.json"
    $acceptance = Read-JsonFile $acceptancePath "External task output acceptance manifest"
    $taskId = [string](Get-JsonValue $acceptance "taskId" "")
    $bugId = [string](Get-JsonValue $acceptance "bugId" "")
    $suggestedFix = [string](Get-JsonValue $acceptance "suggestedFix" "")
    $retestCommand = [string](Get-JsonValue $acceptance "retestCommand" "")
    $outputDirectory = Join-Path $ScenarioDir "cursor-agent-external-output"
    New-Item -ItemType Directory -Force $outputDirectory | Out-Null

    $acceptedRunPath = Join-Path $ScenarioDir "repair-agent-external-task-output-run.json"
    $acceptedPatchPath = Join-Path $ScenarioDir "repair-agent-external-task-output.patch"
    $acceptedSummaryPath = Join-Path $ScenarioDir "repair-agent-external-task-output-summary.md"
    $externalRunPath = Join-Path $outputDirectory "repair-agent-run.json"
    $externalPatchPath = Join-Path $outputDirectory "repair-agent.patch"
    $externalSummaryPath = Join-Path $outputDirectory "repair-agent-summary.md"
    $cursorRunPath = Join-Path $ScenarioDir "repair-agent-cursor-agent-output-run.json"
    $cursorPatchPath = Join-Path $ScenarioDir "repair-agent-cursor-agent-output.patch"
    $cursorSummaryPath = Join-Path $ScenarioDir "repair-agent-cursor-agent-output-summary.md"
    $cursorLogPath = Join-Path $ScenarioDir "repair-agent-cursor-agent-output.log"
    $cursorPatchOutputManifestPath = Join-Path $ScenarioDir "repair-agent-cursor-agent-output-patch-output-manifest.json"
    $cursorPreflightManifestPath = Join-Path $ScenarioDir "repair-agent-cursor-agent-output-preflight-manifest.json"

    Copy-Item -LiteralPath $acceptedRunPath -Destination $externalRunPath -Force
    Copy-Item -LiteralPath $acceptedPatchPath -Destination $externalPatchPath -Force
    Copy-Item -LiteralPath $acceptedSummaryPath -Destination $externalSummaryPath -Force
    Copy-Item -LiteralPath $externalRunPath -Destination $cursorRunPath -Force
    Copy-Item -LiteralPath $externalPatchPath -Destination $cursorPatchPath -Force
    Copy-Item -LiteralPath $externalSummaryPath -Destination $cursorSummaryPath -Force
    "fake cursor agent binding probe log" | Set-Content -Path $cursorLogPath -Encoding UTF8
    Copy-Item -LiteralPath (Join-Path $ScenarioDir "repair-agent-patch-output-manifest.json") -Destination $cursorPatchOutputManifestPath -Force
    Copy-Item -LiteralPath (Join-Path $ScenarioDir "repair-agent-external-patch-preflight-manifest.json") -Destination $cursorPreflightManifestPath -Force

    $runSha256 = Get-FileSha256OrEmpty $externalRunPath
    $patchSha256 = Get-FileSha256OrEmpty $externalPatchPath
    $summarySha256 = Get-FileSha256OrEmpty $externalSummaryPath
    $producerPatchSha256 = if ($MismatchPatchHash) { "0000000000000000000000000000000000000000000000000000000000000000" } else { $patchSha256 }

    if ($BindAcceptance) {
        Set-JsonProperty $acceptance "fixtureGenerated" $false
        Set-JsonProperty $acceptance "externalOutputDirectoryInputProvided" $true
        Set-JsonProperty $acceptance "externalOutputDirectoryProvided" $true
        Set-JsonProperty $acceptance "externalOutputDirectory" $outputDirectory
        Set-JsonProperty $acceptance "externalOutputRunSha256" $runSha256
        Set-JsonProperty $acceptance "externalOutputPatchSha256" $patchSha256
        Set-JsonProperty $acceptance "externalOutputSummarySha256" $summarySha256
        Set-JsonProperty $acceptance "externalOutputProducerManifestPresent" $true
        Set-JsonProperty $acceptance "externalOutputProducerSource" "headless_cursor_agent"
        Set-JsonProperty $acceptance "externalOutputProducerTaskId" $taskId
        Set-JsonProperty $acceptance "externalOutputProducerBugId" $bugId
        Set-JsonProperty $acceptance "externalOutputProducerSuggestedFix" $suggestedFix
        Set-JsonProperty $acceptance "externalOutputProducerRetestCommand" $retestCommand
        Set-JsonProperty $acceptance "externalOutputProducerOutputDirectory" $outputDirectory
        Set-JsonProperty $acceptance "externalOutputProducerRunSha256" $runSha256
        Set-JsonProperty $acceptance "externalOutputProducerPatchSha256" $producerPatchSha256
        Set-JsonProperty $acceptance "externalOutputProducerSummarySha256" $summarySha256
        Set-JsonProperty $acceptance "externalOutputProducerBindingPassed" $true
        $acceptance | ConvertTo-Json -Depth 12 | Set-Content -Path $acceptancePath -Encoding UTF8
    }

    $producerManifest = [ordered]@{
        schemaVersion = "aitestpilot.repair_agent_cursor_agent_external_output.v1"
        status = "PASS"
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
        source = "headless_cursor_agent"
        fixtureGenerated = $false
        cursorAgentCommand = "fake-cursor-agent-binding-probe"
        cursorAgentRequestedModel = ""
        cursorAgentModel = ""
        cursorAgentRetriedWithoutModel = $false
        cursorAgentAttemptCount = 1
        cursorAgentTransientRetryCount = 0
        cursorAgentOutputContractRetryCount = 0
        cursorAgentMaxAttempts = 1
        cursorAgentExitCode = 0
        cursorAgentPatchApplyContractPassed = $true
        outputDirectory = $outputDirectory
        taskId = $taskId
        bugId = $bugId
        suggestedFix = $suggestedFix
        retestCommand = $retestCommand
        outputRunSha256 = $runSha256
        outputPatchSha256 = $producerPatchSha256
        outputSummarySha256 = $summarySha256
        repairAgentRunStatus = "EXTERNAL_AGENT_COMPLETED"
        repairAgentRunAgentLaunched = $true
        repairAgentPatchOutputStatus = "PRODUCED"
        repairAgentPatchOutputCount = 2
        producedRequiredPatchOutputCount = 2
        requiredPatchOutputCount = 2
        patchOutputImportStatus = "PASS"
        patchOutputSource = "external_agent"
        externalAgentCompletionVerified = $true
        preflightStatus = "PASS"
        preflightSafeToInspect = $true
        preflightRepositoryApplyAllowed = $true
        preflightUnsafePathCount = 0
        patchMentionsTaskId = $true
        patchMentionsBugId = $true
        patchMentionsSuggestedFix = $true
        summaryContainsTaskId = $true
        summaryContainsBugId = $true
        summaryContainsSuggestedFix = $true
        mainRepositoryPatchApplied = $false
        files = @(
            "repair-agent-cursor-agent-output-run.json",
            "repair-agent-cursor-agent-output.patch",
            "repair-agent-cursor-agent-output-summary.md",
            "repair-agent-cursor-agent-output.log",
            "repair-agent-cursor-agent-output-patch-output-manifest.json",
            "repair-agent-cursor-agent-output-preflight-manifest.json"
        )
    }

    $producerManifest | ConvertTo-Json -Depth 12 | Set-Content -Path (Join-Path $ScenarioDir "repair-agent-cursor-agent-external-output-manifest.json") -Encoding UTF8
}

function Invoke-BindingScenario {
    param(
        [string]$Name,
        [scriptblock]$Mutate,
        [bool]$ExpectPass,
        [string[]]$ExpectedFailedReasonSubstrings = @()
    )

    $scenarioDir = Join-Path $workPath $Name
    if (Test-Path $scenarioDir) {
        Remove-Item -LiteralPath $scenarioDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force $scenarioDir | Out-Null
    Copy-Item -Path (Join-Path $evidenceBundlePath "*") -Destination $scenarioDir -Recurse -Force
    Remove-BindingProbeEvidence $scenarioDir

    if ($null -ne $Mutate) {
        & $Mutate $scenarioDir
    }

    & (Join-Path $repoRoot "tools\Invoke-AITestPilotReleaseEvidenceIndex.ps1") `
        -EvidenceBundleDir $scenarioDir | Out-Null

    $gateManifestPath = Join-Path $scenarioDir "release-gate-manifest.json"
    $gateThrew = $false
    $gateError = ""
    $gateOutput = @()
    try {
        if ($ExpectPass) {
            $gateOutput = & (Join-Path $repoRoot "tools\Invoke-AITestPilotReleaseGate.ps1") `
                -EvidenceBundleDir $scenarioDir `
                -ReleaseGateManifestPath $gateManifestPath
        }
        else {
            $gateOutput = & (Join-Path $repoRoot "tools\Invoke-AITestPilotReleaseGate.ps1") `
                -EvidenceBundleDir $scenarioDir `
                -ReleaseGateManifestPath $gateManifestPath `
                -ExpectBlocked
        }
    }
    catch {
        $gateThrew = $true
        $gateError = $_.Exception.Message
    }

    $gateManifest = Read-JsonFile $gateManifestPath "$Name release gate manifest"
    $failedReasons = @($gateManifest.failedReasons | ForEach-Object { [string]$_ })
    $matchedExpectedFailedReasons = @($ExpectedFailedReasonSubstrings | Where-Object {
            $expected = [string]$_
            @($failedReasons | Where-Object { $_.Contains($expected) }).Count -gt 0
        })

    $passed = if ($ExpectPass) {
        (-not $gateThrew -and $gateManifest.status -eq "PASS" -and [int]$gateManifest.failedReasonCount -eq 0)
    }
    else {
        (-not $gateThrew -and $gateManifest.status -eq "BLOCKED" -and $matchedExpectedFailedReasons.Count -eq $ExpectedFailedReasonSubstrings.Count)
    }

    $result = [ordered]@{
        name = $Name
        expectPass = [bool]$ExpectPass
        passed = [bool]$passed
        gateThrew = [bool]$gateThrew
        gateError = $gateError
        releaseGateStatus = [string]$gateManifest.status
        failedReasonCount = [int]$gateManifest.failedReasonCount
        expectedFailedReasonSubstrings = @($ExpectedFailedReasonSubstrings)
        matchedExpectedFailedReasonSubstrings = @($matchedExpectedFailedReasons)
        failedReasons = @($failedReasons)
        releaseGateOutput = @($gateOutput | ForEach-Object { [string]$_ })
    }

    $resultPath = Join-Path $probeOutputPath "$Name-result.json"
    $result | ConvertTo-Json -Depth 12 | Set-Content -Path $resultPath -Encoding UTF8
    return $result
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$workPath = Assert-PathUnderRepo $ProbeWorkDir "ProbeWorkDir"
$probeOutputPath = Assert-PathUnderRepo $ProbeOutputDir "ProbeOutputDir"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if (Test-Path $workPath) {
    Remove-Item -LiteralPath $workPath -Recurse -Force
}
if (Test-Path $probeOutputPath) {
    Remove-Item -LiteralPath $probeOutputPath -Recurse -Force
}
New-Item -ItemType Directory -Force $workPath | Out-Null
New-Item -ItemType Directory -Force $probeOutputPath | Out-Null
New-Item -ItemType Directory -Force (Split-Path $manifestFullPath -Parent) | Out-Null
New-Item -ItemType Directory -Force (Split-Path $reportFullPath -Parent) | Out-Null

$scenarioResults = @()
$scenarioResults += Invoke-BindingScenario `
    -Name "baseline-no-cursor-manifest" `
    -Mutate {
        param($ScenarioDir)
        Remove-CursorAgentOptionalEvidence $ScenarioDir
    } `
    -ExpectPass $true

$scenarioResults += Invoke-BindingScenario `
    -Name "stale-cursor-with-fixture-acceptance-blocked" `
    -Mutate {
        param($ScenarioDir)
        Remove-CursorAgentOptionalEvidence $ScenarioDir
        Add-CursorAgentProducerManifest -ScenarioDir $ScenarioDir -BindAcceptance $false -MismatchPatchHash $false
    } `
    -ExpectPass $false `
    -ExpectedFailedReasonSubstrings @("repair_agent_cursor_agent_external_task_output")

$scenarioResults += Invoke-BindingScenario `
    -Name "mismatched-cursor-hash-blocked" `
    -Mutate {
        param($ScenarioDir)
        Remove-CursorAgentOptionalEvidence $ScenarioDir
        Add-CursorAgentProducerManifest -ScenarioDir $ScenarioDir -BindAcceptance $true -MismatchPatchHash $true
    } `
    -ExpectPass $false `
    -ExpectedFailedReasonSubstrings @("repair_agent_cursor_agent_external_task_output")

$scenarioResults += Invoke-BindingScenario `
    -Name "matched-cursor-binding-pass" `
    -Mutate {
        param($ScenarioDir)
        Remove-CursorAgentOptionalEvidence $ScenarioDir
        Add-CursorAgentProducerManifest -ScenarioDir $ScenarioDir -BindAcceptance $true -MismatchPatchHash $false
    } `
    -ExpectPass $true

$failedScenarios = @($scenarioResults | Where-Object { -not [bool]$_["passed"] })
$status = if ($failedScenarios.Count -eq 0) { "PASS" } else { "FAIL" }

$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestFullPath),
    (Convert-ToEvidenceRelativePath $reportFullPath),
    (Convert-ToEvidenceRelativePath $probeOutputPath)
)

$sourceFiles = @(
    "repair-agent-external-task-output-acceptance-manifest.json",
    "repair-agent-external-task-output-run.json",
    "repair-agent-external-task-output.patch",
    "repair-agent-external-task-output-summary.md",
    "repair-agent-main-worktree-apply-retest-rollback-manifest.json"
)

$reportLines = @(
    "# AI TestPilot Cursor Agent External Output Binding Probe",
    "",
    "- Status: $status",
    "- Scenario count: $($scenarioResults.Count)",
    "- Failed scenario count: $($failedScenarios.Count)",
    "",
    "| Scenario | Expected pass | Passed | Gate status | Failed reasons |",
    "| --- | --- | --- | --- | --- |"
)
foreach ($scenario in $scenarioResults) {
    $reportLines += "| $($scenario["name"]) | $($scenario["expectPass"]) | $($scenario["passed"]) | $($scenario["releaseGateStatus"]) | $(([string]::Join(", ", @($scenario["matchedExpectedFailedReasonSubstrings"]))).Replace("|", "\|")) |"
}

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.repair_agent_cursor_agent_external_output_binding_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    probeWorkDir = $workPath
    probeOutputDir = $probeOutputPath
    scenarioCount = [int]$scenarioResults.Count
    failedScenarioCount = [int]$failedScenarios.Count
    baselineNoCursorManifestPassed = [bool]($scenarioResults[0]["passed"])
    staleCursorWithFixtureAcceptanceBlocked = [bool]($scenarioResults[1]["passed"])
    mismatchedCursorHashBlocked = [bool]($scenarioResults[2]["passed"])
    matchedCursorBindingPassed = [bool]($scenarioResults[3]["passed"])
    scenarios = @($scenarioResults)
    releasePipelineSendsEmail = $false
    realHostProjectEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "cursor_agent_external_output_binding_probe_only"
    sourceFiles = @($sourceFiles)
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles + $sourceFiles)
}

$reportLines | Set-Content -Path $reportFullPath -Encoding UTF8
$manifest | ConvertTo-Json -Depth 14 | Set-Content -Path $manifestFullPath -Encoding UTF8

if ($status -ne "PASS") {
    throw "AI TestPilot Cursor Agent external output binding probe failed. Manifest: $manifestFullPath"
}

Write-Output "Cursor Agent external output binding probe manifest: $manifestFullPath"
Write-Output "Cursor Agent external output binding probe report: $reportFullPath"
Write-Output "PASS AI TestPilot Cursor Agent external output binding probe"
