[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$OutputDir,
    [string]$ManifestPath,
    [string]$CursorAgentCommand = "",
    [string]$CursorAgentModel = "",
    [string]$CursorAgentSandboxMode = "disabled",
    [int]$CursorAgentTimeoutSeconds = 300,
    [int]$CursorAgentMaxAttempts = 3,
    [int]$CursorAgentRetryDelaySeconds = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ($CursorAgentMaxAttempts -lt 1) {
    $CursorAgentMaxAttempts = 1
}

if ($CursorAgentRetryDelaySeconds -lt 0) {
    $CursorAgentRetryDelaySeconds = 0
}

if ($CursorAgentTimeoutSeconds -lt 0) {
    $CursorAgentTimeoutSeconds = 0
}

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $repoRoot "Temp\release-evidence\cursor-agent-external-output"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "repair-agent-cursor-agent-external-output-manifest.json"
}

function Assert-PathUnderRepo {
    param(
        [string]$Path,
        [string]$Label
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must stay under repo root: $fullPath"
    }

    return $fullPath
}

function Write-Utf8NoBomFile {
    param(
        [string]$Path,
        [string]$Content
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Get-FileSha256OrEmpty {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return ""
    }

    return (Get-FileHash -Algorithm SHA256 -Path $Path).Hash
}

function Resolve-CursorAgentCommand {
    param([string]$RequestedCommand)

    if (-not [string]::IsNullOrWhiteSpace($RequestedCommand)) {
        $explicitCommand = Get-Command -Name $RequestedCommand -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $explicitCommand -and -not [string]::IsNullOrWhiteSpace($explicitCommand.Source)) {
            return $explicitCommand.Source
        }

        if (Test-Path -LiteralPath $RequestedCommand) {
            return (Resolve-Path -LiteralPath $RequestedCommand).Path
        }

        return $RequestedCommand
    }

    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        foreach ($candidate in @("cursor-agent.cmd", "cursor-agent.exe")) {
            $command = Get-Command -Name $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace($command.Source)) {
                return $command.Source
            }
        }
    }

    return "cursor-agent"
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$outputPath = Assert-PathUnderRepo $OutputDir "OutputDir"
$manifestPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$resolvedCursorAgentCommand = Resolve-CursorAgentCommand -RequestedCommand $CursorAgentCommand

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

$handoffMarkdownPath = Join-Path $evidenceBundlePath "repair-agent-handoff.md"
$repairAgentRunSource = Join-Path $evidenceBundlePath "repair-agent-run.json"
$repairTaskSource = Join-Path $evidenceBundlePath "repair-task.json"
$bugPackagePath = Join-Path $evidenceBundlePath "bug-package.json"
$bugKnowledgeGraphPath = Join-Path $evidenceBundlePath "bug-knowledge-graph.json"

foreach ($requiredInput in @($handoffMarkdownPath, $repairAgentRunSource, $repairTaskSource, $bugPackagePath, $bugKnowledgeGraphPath)) {
    if (-not (Test-Path $requiredInput)) {
        throw "Cursor Agent external output input is missing: $requiredInput"
    }
}

$repairTask = Get-Content -Raw $repairTaskSource | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($repairTask.taskId) -or
    [string]::IsNullOrWhiteSpace($repairTask.bugId) -or
    [string]::IsNullOrWhiteSpace($repairTask.suggestedFix) -or
    [string]::IsNullOrWhiteSpace($repairTask.retestCommand)) {
    throw "Repair task must include taskId, bugId, suggestedFix, and retestCommand."
}

$taskId = [string]$repairTask.taskId
$bugId = [string]$repairTask.bugId
$suggestedFix = [string]$repairTask.suggestedFix
$retestCommand = [string]$repairTask.retestCommand

if (Test-Path $outputPath) {
    Remove-Item -LiteralPath $outputPath -Recurse -Force
}

New-Item -ItemType Directory -Force $outputPath | Out-Null

$cursorAgentLogPath = Join-Path $outputPath "cursor-agent-output.log"
$externalRunPath = Join-Path $outputPath "repair-agent-run.json"
$externalPatchPath = Join-Path $outputPath "repair-agent.patch"
$externalSummaryPath = Join-Path $outputPath "repair-agent-summary.md"
$contractCheckPath = Join-Path (Split-Path $outputPath -Parent) "cursor-agent-output-contract-check"

$prompt = @"
Execute this repair-agent output task now. Do not ask for another instruction, do not wait for clarification, and do not modify tracked repository files.

You are acting as the external Cursor repair agent for the AI TestPilot repo.

Strict output boundary:
- Write files only under $outputPath.
- Do not modify, create, delete, format, or stage any tracked source/docs files outside that output directory.
- Do not run repository tests or apply the patch. Produce output artifacts only.

Read these current handoff inputs from ${evidenceBundlePath}:
- repair-agent-handoff.md
- repair-agent-run.json
- repair-task.json
- bug-package.json
- bug-knowledge-graph.json

Produce exactly these three required output files in ${outputPath}:
1. repair-agent-run.json
   - Start from the current repair-agent-run.json fields.
   - Keep schemaVersion as aitestpilot.repair_agent_run.v1.
   - Preserve taskId=$taskId and bugId=$bugId.
   - Set status to EXTERNAL_AGENT_COMPLETED.
   - Set agentLaunched to true.
   - Set patchOutputStatus to PRODUCED.
   - Set patchOutputCount to 2.
   - Mark every required expectedPatchOutputs item as produced=true.
2. repair-agent.patch
   - A valid unified diff.
   - Add docs/repair-agent-main-worktree-apply-probe.md as a new file.
   - The added file must contain TaskId, BugId, SuggestedFix, and RetestCommand values from repair-task.json.
   - Include the suggested fix text exactly: $suggestedFix
   - Keep it safe: no path traversal, no absolute paths, no .git paths.
3. repair-agent-summary.md
   - Human-readable summary.
   - Include TaskId, BugId, suggested fix, patch file name, and retest command.
   - Write the retest command exactly as plain text, without escaping backslashes: $retestCommand

After writing files, respond with a concise confirmation and the exact files written.
"@

$previousErrorActionPreference = $ErrorActionPreference
function Invoke-CursorAgentPrint {
    param(
        [string]$Model
    )

    $arguments = @(
        "--print",
        "--trust",
        "--force"
    )

    if (-not [string]::IsNullOrWhiteSpace($Model)) {
        $arguments += @("--model", $Model)
    }

    if (-not [string]::IsNullOrWhiteSpace($CursorAgentSandboxMode)) {
        $arguments += @("--sandbox", $CursorAgentSandboxMode)
    }

    $arguments += @(
        "--workspace",
        $repoRoot,
        $prompt
    )

    try {
        $script:ErrorActionPreference = "Continue"
        if ($CursorAgentTimeoutSeconds -eq 0) {
            $script:cursorAgentOutput = @(& $resolvedCursorAgentCommand @arguments 2>&1)
            $script:cursorAgentExitCode = $LASTEXITCODE
            return
        }

        $job = Start-Job -ScriptBlock {
            param(
                [string]$Command,
                [string[]]$Arguments
            )

            $ErrorActionPreference = "Continue"
            $output = @(& $Command @Arguments 2>&1)
            $exitCode = if ($null -eq $LASTEXITCODE) { 1 } else { $LASTEXITCODE }
            [pscustomobject]@{
                ExitCode = $exitCode
                Output = @($output | ForEach-Object { [string]$_ })
            }
        } -ArgumentList $resolvedCursorAgentCommand, $arguments

        $completedJob = Wait-Job -Job $job -Timeout $CursorAgentTimeoutSeconds
        if ($null -eq $completedJob) {
            Stop-Job -Job $job
            Remove-Job -Job $job -Force
            $script:cursorAgentOutput = @("Cursor Agent timed out after $CursorAgentTimeoutSeconds seconds.")
            $script:cursorAgentExitCode = 124
            return
        }

        $result = Receive-Job -Job $job
        Remove-Job -Job $job -Force
        $script:cursorAgentOutput = @($result.Output)
        $script:cursorAgentExitCode = [int]$result.ExitCode
    }
    finally {
        $script:ErrorActionPreference = $previousErrorActionPreference
    }
}

function Test-TransientCursorAgentFailure {
    param(
        [object[]]$Output
    )

    $text = @($Output) -join "`n"
    foreach ($pattern in @(
        "Connection lost",
        "Client network socket disconnected",
        "Retry attempt",
        "Aborted",
        "ECONNRESET",
        "ETIMEDOUT",
        "EAI_AGAIN",
        "ENOTFOUND",
        "socket hang up",
        "TLS connection",
        "timed out"
    )) {
        if ($text -match [regex]::Escape($pattern)) {
            return $true
        }
    }

    return $false
}

function Clear-CursorAgentOutputFiles {
    foreach ($path in @($externalRunPath, $externalPatchPath, $externalSummaryPath)) {
        if (Test-Path $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }
}

function Test-CursorAgentRequiredOutputsPresent {
    foreach ($path in @($externalRunPath, $externalPatchPath, $externalSummaryPath)) {
        if (-not (Test-Path $path)) {
            return $false
        }
    }

    return $true
}

function Test-TextContainsLiteralOrMarkdownEscaped {
    param(
        [string]$Text,
        [string]$Value
    )

    if ($Text -match [regex]::Escape($Value)) {
        return $true
    }

    $markdownEscapedValue = $Value.Replace("\", "\\")
    return $Text -match [regex]::Escape($markdownEscapedValue)
}

function Invoke-GitQuiet {
    param(
        [string[]]$Arguments
    )

    $previous = $ErrorActionPreference
    try {
        $script:ErrorActionPreference = "Continue"
        $null = @(& git @Arguments 2>&1)
        return $LASTEXITCODE
    }
    finally {
        $script:ErrorActionPreference = $previous
    }
}

function Test-CursorAgentPatchAppliesWithRequiredContext {
    if (-not (Test-Path $externalPatchPath)) {
        return $false
    }

    if (Test-Path $contractCheckPath) {
        Remove-Item -LiteralPath $contractCheckPath -Recurse -Force
    }

    New-Item -ItemType Directory -Force $contractCheckPath | Out-Null
    if ((Invoke-GitQuiet @("-C", $contractCheckPath, "init", "-q")) -ne 0) {
        return $false
    }

    if ((Invoke-GitQuiet @("-C", $contractCheckPath, "apply", "--check", $externalPatchPath)) -ne 0) {
        return $false
    }

    if ((Invoke-GitQuiet @("-C", $contractCheckPath, "apply", $externalPatchPath)) -ne 0) {
        return $false
    }

    $probeFile = Join-Path $contractCheckPath "docs\repair-agent-main-worktree-apply-probe.md"
    if (-not (Test-Path $probeFile)) {
        return $false
    }

    $probeText = Get-Content -Path $probeFile -Raw
    return ($probeText -match [regex]::Escape($taskId)) -and
        ($probeText -match [regex]::Escape($bugId)) -and
        ($probeText -match [regex]::Escape($suggestedFix)) -and
        (Test-TextContainsLiteralOrMarkdownEscaped -Text $probeText -Value $retestCommand)
}

$cursorAgentRequestedModel = $CursorAgentModel
$cursorAgentModelUsed = $CursorAgentModel
$cursorAgentRetriedWithoutModel = $false
$cursorAgentOutput = @()
$cursorAgentExitCode = 1
$cursorAgentAttemptCount = 0
$cursorAgentTransientRetryCount = 0
$cursorAgentOutputContractRetryCount = 0
$cursorAgentPatchApplyContractPassed = $false
$cursorAgentOutputLog = @()

while ($cursorAgentAttemptCount -lt $CursorAgentMaxAttempts) {
    $cursorAgentAttemptCount++
    Clear-CursorAgentOutputFiles
    Invoke-CursorAgentPrint -Model $cursorAgentModelUsed
    $attemptOutput = @($cursorAgentOutput)
    $cursorAgentOutputLog += @(
        "--- Cursor Agent attempt $cursorAgentAttemptCount, model='$cursorAgentModelUsed', exit=$cursorAgentExitCode ---"
    ) + $attemptOutput

    if ($cursorAgentExitCode -eq 0) {
        if ((Test-CursorAgentRequiredOutputsPresent) -and
            (Test-CursorAgentPatchAppliesWithRequiredContext)) {
            $cursorAgentPatchApplyContractPassed = $true
            break
        }

        if (Test-CursorAgentRequiredOutputsPresent) {
            $cursorAgentOutputLog += "Cursor Agent attempt $cursorAgentAttemptCount exited 0 and produced files, but the patch did not apply with the required task context."
        }
        else {
            $cursorAgentOutputLog += "Cursor Agent attempt $cursorAgentAttemptCount exited 0 but did not produce the required three-file output contract."
        }

        if ($cursorAgentAttemptCount -lt $CursorAgentMaxAttempts) {
            $cursorAgentOutputContractRetryCount++
            Start-Sleep -Seconds $CursorAgentRetryDelaySeconds
            continue
        }

        break
    }

    $attemptText = $attemptOutput -join "`n"
    if (-not [string]::IsNullOrWhiteSpace($cursorAgentModelUsed) -and
        $attemptText -match "Cannot use this model") {
        $cursorAgentRetriedWithoutModel = $true
        $cursorAgentModelUsed = ""
        continue
    }

    if ((Test-TransientCursorAgentFailure -Output $attemptOutput) -and
        $cursorAgentAttemptCount -lt $CursorAgentMaxAttempts) {
        $cursorAgentTransientRetryCount++
        Start-Sleep -Seconds $CursorAgentRetryDelaySeconds
        continue
    }

    break
}

$cursorAgentOutput = @($cursorAgentOutputLog)
$cursorAgentOutput | Set-Content -Path $cursorAgentLogPath -Encoding UTF8

if ($cursorAgentExitCode -ne 0) {
    throw "Cursor Agent external output run failed with exit code $cursorAgentExitCode. Log: $cursorAgentLogPath"
}

foreach ($requiredOutput in @($externalRunPath, $externalPatchPath, $externalSummaryPath)) {
    if (-not (Test-Path $requiredOutput)) {
        throw "Cursor Agent did not produce required output: $requiredOutput"
    }
}

if (-not $cursorAgentPatchApplyContractPassed) {
    throw "Cursor Agent output patch did not apply with the required repair task context."
}

$externalRun = Get-Content -Raw $externalRunPath | ConvertFrom-Json
$patchText = Get-Content -Raw $externalPatchPath
$summaryText = Get-Content -Raw $externalSummaryPath

$requiredPatchOutputs = @($externalRun.expectedPatchOutputs | Where-Object { [bool]$_.required })
$producedRequiredPatchOutputs = @($requiredPatchOutputs | Where-Object { [bool]$_.produced })
$patchMentionsTaskId = $patchText -match [regex]::Escape($taskId)
$patchMentionsBugId = $patchText -match [regex]::Escape($bugId)
$patchMentionsSuggestedFix = $patchText -match [regex]::Escape($suggestedFix)
$summaryContainsTaskId = $summaryText -match [regex]::Escape($taskId)
$summaryContainsBugId = $summaryText -match [regex]::Escape($bugId)
$summaryContainsSuggestedFix = $summaryText -match [regex]::Escape($suggestedFix)

if ($externalRun.schemaVersion -ne "aitestpilot.repair_agent_run.v1" -or
    $externalRun.status -ne "EXTERNAL_AGENT_COMPLETED" -or
    $externalRun.taskId -ne $taskId -or
    $externalRun.bugId -ne $bugId -or
    -not [bool]$externalRun.agentLaunched -or
    $externalRun.patchOutputStatus -ne "PRODUCED" -or
    [int]$externalRun.patchOutputCount -lt 2 -or
    $requiredPatchOutputs.Count -lt 2 -or
    $producedRequiredPatchOutputs.Count -ne $requiredPatchOutputs.Count -or
    -not ($patchText -match [regex]::Escape("diff --git")) -or
    -not $patchMentionsTaskId -or
    -not $patchMentionsBugId -or
    -not $patchMentionsSuggestedFix -or
    -not $summaryContainsTaskId -or
    -not $summaryContainsBugId -or
    -not $summaryContainsSuggestedFix) {
    throw "Cursor Agent output did not satisfy the repair-agent output contract."
}

& (Join-Path $repoRoot "tools\Invoke-AITestPilotRepairAgentPatchOutputImport.ps1") `
    -EvidenceBundleDir $outputPath `
    -ConfirmExternalAgentCompleted

$patchOutputManifestPath = Join-Path $outputPath "repair-agent-patch-output-manifest.json"
if (-not (Test-Path $patchOutputManifestPath)) {
    throw "Cursor Agent patch output import manifest was not produced: $patchOutputManifestPath"
}

$patchOutputManifest = Get-Content -Raw $patchOutputManifestPath | ConvertFrom-Json
if ($patchOutputManifest.status -ne "PASS" -or
    $patchOutputManifest.source -ne "external_agent" -or
    -not [bool]$patchOutputManifest.externalAgentCompletionVerified -or
    -not [bool]$patchOutputManifest.externalAgentRun -or
    [bool]$patchOutputManifest.sampleFixSnippetRequired) {
    throw "Cursor Agent patch output import did not prove completed external-agent provenance."
}

& (Join-Path $repoRoot "tools\Invoke-AITestPilotRepairAgentExternalPatchPreflight.ps1") `
    -EvidenceBundleDir $outputPath

$preflightManifestPath = Join-Path $outputPath "repair-agent-external-patch-preflight-manifest.json"
if (-not (Test-Path $preflightManifestPath)) {
    throw "Cursor Agent preflight manifest was not produced: $preflightManifestPath"
}

$preflightManifest = Get-Content -Raw $preflightManifestPath | ConvertFrom-Json
if ($preflightManifest.status -ne "PASS" -or
    -not [bool]$preflightManifest.repositoryApplyAllowed -or
    -not [bool]$preflightManifest.safeToInspect -or
    [int]$preflightManifest.unsafePathCount -ne 0) {
    throw "Cursor Agent patch preflight did not allow repository apply for verified external-agent output."
}

$runTarget = Join-Path $evidenceBundlePath "repair-agent-cursor-agent-output-run.json"
$patchTarget = Join-Path $evidenceBundlePath "repair-agent-cursor-agent-output.patch"
$summaryTarget = Join-Path $evidenceBundlePath "repair-agent-cursor-agent-output-summary.md"
$logTarget = Join-Path $evidenceBundlePath "repair-agent-cursor-agent-output.log"
$patchOutputManifestTarget = Join-Path $evidenceBundlePath "repair-agent-cursor-agent-output-patch-output-manifest.json"
$preflightManifestTarget = Join-Path $evidenceBundlePath "repair-agent-cursor-agent-output-preflight-manifest.json"

Copy-Item -LiteralPath $externalRunPath -Destination $runTarget -Force
Copy-Item -LiteralPath $externalPatchPath -Destination $patchTarget -Force
Copy-Item -LiteralPath $externalSummaryPath -Destination $summaryTarget -Force
Copy-Item -LiteralPath $cursorAgentLogPath -Destination $logTarget -Force
Copy-Item -LiteralPath $patchOutputManifestPath -Destination $patchOutputManifestTarget -Force
Copy-Item -LiteralPath $preflightManifestPath -Destination $preflightManifestTarget -Force

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.repair_agent_cursor_agent_external_output.v1"
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    source = "headless_cursor_agent"
    fixtureGenerated = $false
    cursorAgentRequestedCommand = $CursorAgentCommand
    cursorAgentCommand = $resolvedCursorAgentCommand
    cursorAgentRequestedModel = $cursorAgentRequestedModel
    cursorAgentModel = $cursorAgentModelUsed
    cursorAgentSandboxMode = $CursorAgentSandboxMode
    cursorAgentRetriedWithoutModel = [bool]$cursorAgentRetriedWithoutModel
    cursorAgentAttemptCount = [int]$cursorAgentAttemptCount
    cursorAgentTransientRetryCount = [int]$cursorAgentTransientRetryCount
    cursorAgentOutputContractRetryCount = [int]$cursorAgentOutputContractRetryCount
    cursorAgentMaxAttempts = [int]$CursorAgentMaxAttempts
    cursorAgentTimeoutSeconds = [int]$CursorAgentTimeoutSeconds
    cursorAgentExitCode = [int]$cursorAgentExitCode
    cursorAgentPatchApplyContractPassed = [bool]$cursorAgentPatchApplyContractPassed
    outputDirectory = $outputPath
    taskId = $taskId
    bugId = $bugId
    suggestedFix = $suggestedFix
    retestCommand = $retestCommand
    handoffMarkdownSha256 = Get-FileSha256OrEmpty $handoffMarkdownPath
    repairAgentRunInputSha256 = Get-FileSha256OrEmpty $repairAgentRunSource
    repairTaskSha256 = Get-FileSha256OrEmpty $repairTaskSource
    bugPackageSha256 = Get-FileSha256OrEmpty $bugPackagePath
    bugKnowledgeGraphSha256 = Get-FileSha256OrEmpty $bugKnowledgeGraphPath
    outputRunSha256 = Get-FileSha256OrEmpty $externalRunPath
    outputPatchSha256 = Get-FileSha256OrEmpty $externalPatchPath
    outputSummarySha256 = Get-FileSha256OrEmpty $externalSummaryPath
    repairAgentRunStatus = $externalRun.status
    repairAgentRunAgentLaunched = [bool]$externalRun.agentLaunched
    repairAgentPatchOutputStatus = $externalRun.patchOutputStatus
    repairAgentPatchOutputCount = [int]$externalRun.patchOutputCount
    producedRequiredPatchOutputCount = [int]$producedRequiredPatchOutputs.Count
    requiredPatchOutputCount = [int]$requiredPatchOutputs.Count
    patchOutputImportStatus = $patchOutputManifest.status
    patchOutputSource = $patchOutputManifest.source
    externalAgentCompletionVerified = [bool]$patchOutputManifest.externalAgentCompletionVerified
    preflightStatus = $preflightManifest.status
    preflightSafeToInspect = [bool]$preflightManifest.safeToInspect
    preflightRepositoryApplyAllowed = [bool]$preflightManifest.repositoryApplyAllowed
    preflightUnsafePathCount = [int]$preflightManifest.unsafePathCount
    patchMentionsTaskId = [bool]$patchMentionsTaskId
    patchMentionsBugId = [bool]$patchMentionsBugId
    patchMentionsSuggestedFix = [bool]$patchMentionsSuggestedFix
    summaryContainsTaskId = [bool]$summaryContainsTaskId
    summaryContainsBugId = [bool]$summaryContainsBugId
    summaryContainsSuggestedFix = [bool]$summaryContainsSuggestedFix
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

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

Write-Output "Cursor Agent external task output manifest: $manifestPath"
Write-Output "Cursor Agent external task output directory: $outputPath"
Write-Output "PASS AI TestPilot Cursor Agent external task output"
