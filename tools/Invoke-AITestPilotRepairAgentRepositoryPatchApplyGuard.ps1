[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$RepositoryRoot,
    [string]$PatchPath,
    [string]$PreflightManifestPath,
    [string]$ManifestPath,
    [switch]$ApplyToRepository
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$workspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = $workspaceRoot
}

$repoRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)
if (-not (Test-Path $repoRoot)) {
    throw "RepositoryRoot does not exist: $repoRoot"
}

$repoRoot = (Resolve-Path $repoRoot).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $workspaceRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($PatchPath)) {
    $PatchPath = Join-Path $EvidenceBundleDir "repair-agent.patch"
}

if ([string]::IsNullOrWhiteSpace($PreflightManifestPath)) {
    $PreflightManifestPath = Join-Path $EvidenceBundleDir "repair-agent-external-patch-preflight-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "repair-agent-repository-patch-apply-guard-manifest.json"
}

function Assert-PathUnderRepo {
    param(
        [string]$Path,
        [string]$Label
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith($workspaceRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must stay under workspace root: $fullPath"
    }

    return $fullPath
}

function Assert-RepositoryRootUnderWorkspace {
    param(
        [string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith($workspaceRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "RepositoryRoot must stay under workspace root: $fullPath"
    }

    return $fullPath
}

function Get-RepoStatusLines {
    $lines = @(& git -C $repoRoot status --porcelain=v1 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "git status failed: $($lines -join "`n")"
    }

    return @($lines)
}

function Select-SourceStatusLines {
    param(
        [string[]]$Lines
    )

    return @($Lines | Where-Object {
        $_ -notmatch " Temp/" -and
        $_ -notmatch " Temp\\" -and
        $_ -notmatch " artifacts/" -and
        $_ -notmatch " artifacts\\"
    })
}

function Test-StringArrayEqual {
    param(
        [string[]]$Left,
        [string[]]$Right
    )

    $difference = @(Compare-Object -ReferenceObject $Left -DifferenceObject $Right)
    return $difference.Count -eq 0
}

function Invoke-GitChecked {
    param(
        [string[]]$Arguments
    )

    $output = @(& git @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join "`n")"
    }

    return @($output)
}

function Get-RollbackDiff {
    $trackedDiff = @(& git -C $repoRoot diff --binary 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "git diff --binary failed: $($trackedDiff -join "`n")"
    }

    $untrackedFiles = @(& git -C $repoRoot ls-files --others --exclude-standard 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "git ls-files --others failed: $($untrackedFiles -join "`n")"
    }

    $diffLines = @($trackedDiff)
    foreach ($untrackedFile in @($untrackedFiles | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $untrackedDiff = @(& git -C $repoRoot diff --binary --no-index -- /dev/null $untrackedFile 2>&1)
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 1) {
            throw "git diff --no-index failed for $($untrackedFile): $($untrackedDiff -join "`n")"
        }

        $diffLines += $untrackedDiff
    }

    return [ordered]@{
        lines = @($diffLines)
        untrackedFiles = @($untrackedFiles | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
}

function Write-Utf8NoBomFile {
    param(
        [string]$Path,
        [string]$Content
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$repoRoot = Assert-RepositoryRootUnderWorkspace $repoRoot
$patchPath = Assert-PathUnderRepo $PatchPath "PatchPath"
$preflightManifestPath = Assert-PathUnderRepo $PreflightManifestPath "PreflightManifestPath"
$manifestPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"

if (-not (Test-Path $patchPath)) {
    throw "Patch file is missing: $patchPath"
}

if (-not (Test-Path $preflightManifestPath)) {
    throw "External patch preflight manifest is missing: $preflightManifestPath"
}

$preflightManifest = Get-Content -Raw $preflightManifestPath | ConvertFrom-Json
if ($preflightManifest.schemaVersion -ne "aitestpilot.repair_agent_external_patch_preflight.v1") {
    throw "Unexpected external patch preflight schema: $($preflightManifest.schemaVersion)"
}

$worktreeStatusBefore = @(Get-RepoStatusLines)
$sourceStatusBefore = @(Select-SourceStatusLines $worktreeStatusBefore)
$worktreeClean = $sourceStatusBefore.Count -eq 0

$explicitApplySwitchRequired = $true
$cleanWorktreeRequired = $true
$externalAgentSourceRequired = $true
$rollbackPlanPath = Join-Path $evidenceBundlePath "repair-agent-repository-patch-rollback-plan.md"
$rollbackPatchPath = Join-Path $evidenceBundlePath "repair-agent-repository-patch-rollback.patch"
$worktreeBeforePath = Join-Path $evidenceBundlePath "repair-agent-repository-worktree-before.txt"
$worktreeAfterPath = Join-Path $evidenceBundlePath "repair-agent-repository-worktree-after.txt"

New-Item -ItemType Directory -Force $evidenceBundlePath | Out-Null
$worktreeStatusBefore | Set-Content -Path $worktreeBeforePath -Encoding UTF8

$blockReasons = @()
if (-not [bool]$ApplyToRepository) {
    $blockReasons += "missing_explicit_apply_switch"
}

if (-not $worktreeClean) {
    $blockReasons += "dirty_worktree"
}

if ($preflightManifest.status -ne "PASS" -or -not [bool]$preflightManifest.safeToInspect) {
    $blockReasons += "preflight_not_safe"
}

if (-not [bool]$preflightManifest.repositoryApplyAllowed) {
    $blockReasons += "preflight_repository_apply_not_allowed"
}

if ($preflightManifest.patchOutputSource -ne "external_agent" -or -not [bool]$preflightManifest.externalAgentRun) {
    $blockReasons += "not_external_agent_patch_output"
}

$repositoryPatchApplied = $false
$gitApplyCheckPassed = $false
$rollbackPatchGenerated = $false
$rollbackPlanStatus = "NOT_REQUIRED"
$applyDecision = "BLOCKED"
$applyError = ""
$rollbackText = ""
$rollbackPatchUntrackedFileCount = 0
$rollbackPatchIncludesUntrackedFiles = $false

if ($blockReasons.Count -eq 0) {
    $applyDecision = "APPLY"

    try {
        Invoke-GitChecked @("-C", $repoRoot, "apply", "--check", "--whitespace=nowarn", $patchPath) | Out-Null
        $gitApplyCheckPassed = $true

        Invoke-GitChecked @("-C", $repoRoot, "apply", "--whitespace=nowarn", $patchPath) | Out-Null
        $repositoryPatchApplied = $true

        $rollbackDiff = Get-RollbackDiff
        $diff = @($rollbackDiff.lines)
        $rollbackPatchUntrackedFileCount = @($rollbackDiff.untrackedFiles).Count
        $rollbackPatchIncludesUntrackedFiles = $rollbackPatchUntrackedFileCount -gt 0

        Write-Utf8NoBomFile $rollbackPatchPath (($diff -join "`n") + "`n")
        $rollbackPatchGenerated = (Test-Path $rollbackPatchPath) -and ((Get-Item -LiteralPath $rollbackPatchPath).Length -gt 0)
        $rollbackPlanStatus = "READY"
    }
    catch {
        $applyDecision = "FAILED"
        $applyError = $_.Exception.Message
        throw
    }
}

$worktreeStatusAfter = @(Get-RepoStatusLines)
$sourceStatusAfter = @(Select-SourceStatusLines $worktreeStatusAfter)
$sourceStatusUnchanged = Test-StringArrayEqual $sourceStatusBefore $sourceStatusAfter
$repositoryChangedByScript = -not $sourceStatusUnchanged
$worktreeStatusAfter | Set-Content -Path $worktreeAfterPath -Encoding UTF8

if ([bool]$repositoryPatchApplied) {
    $rollbackText = @(
        "# AI TestPilot Repository Patch Rollback Plan",
        "",
        "Status: $rollbackPlanStatus",
        "",
        "The external repair-agent patch was applied to the repository worktree.",
        "",
        "Rollback command:",
        "",
        '```powershell',
        "git -C `"$repoRoot`" apply -R `"$rollbackPatchPath`"",
        '```',
        "",
        "After rollback, rerun:",
        "",
        '```powershell',
        ".\tools\Invoke-AITestPilotRepairRetest.ps1",
        ".\tools\Invoke-AITestPilotReleasePipeline.ps1",
        '```'
    ) -join [Environment]::NewLine
}
else {
    $blockedReasonLines = @($blockReasons | ForEach-Object { "- " + $_ })
    $rollbackText = @(
        "# AI TestPilot Repository Patch Rollback Plan",
        "",
        "Status: NOT_REQUIRED",
        "",
        "The repository patch was not applied.",
        "",
        "Blocked reasons:",
        ""
    ) + $blockedReasonLines + @(
        "",
        "No rollback command is required because the guard did not modify repository source files."
    )
    $rollbackText = $rollbackText -join [Environment]::NewLine
}

$rollbackText | Set-Content -Path $rollbackPlanPath -Encoding UTF8
$rollbackPlanHasContent = (Test-Path $rollbackPlanPath) -and ((Get-Item -LiteralPath $rollbackPlanPath).Length -gt 16)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.repair_agent_repository_patch_apply_guard.v1"
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    repositoryRoot = $repoRoot
    applyDecision = $applyDecision
    applyError = $applyError
    explicitApplySwitchRequired = [bool]$explicitApplySwitchRequired
    applySwitchProvided = [bool]$ApplyToRepository
    cleanWorktreeRequired = [bool]$cleanWorktreeRequired
    worktreeClean = [bool]$worktreeClean
    externalAgentSourceRequired = [bool]$externalAgentSourceRequired
    patchOutputSource = $preflightManifest.patchOutputSource
    externalAgentRun = [bool]$preflightManifest.externalAgentRun
    preflightStatus = $preflightManifest.status
    preflightSafeToInspect = [bool]$preflightManifest.safeToInspect
    preflightRepositoryApplyAllowed = [bool]$preflightManifest.repositoryApplyAllowed
    gitApplyCheckPassed = [bool]$gitApplyCheckPassed
    repositoryPatchApplied = [bool]$repositoryPatchApplied
    repositoryChangedByScript = [bool]$repositoryChangedByScript
    sourceStatusUnchanged = [bool]$sourceStatusUnchanged
    worktreeStatusBeforeCount = [int]$worktreeStatusBefore.Count
    sourceStatusBeforeCount = [int]$sourceStatusBefore.Count
    worktreeStatusAfterCount = [int]$worktreeStatusAfter.Count
    sourceStatusAfterCount = [int]$sourceStatusAfter.Count
    rollbackPlanStatus = $rollbackPlanStatus
    rollbackPlanGenerated = [bool](Test-Path $rollbackPlanPath)
    rollbackPlanHasContent = [bool]$rollbackPlanHasContent
    rollbackPatchGenerated = [bool]$rollbackPatchGenerated
    rollbackPatchIncludesUntrackedFiles = [bool]$rollbackPatchIncludesUntrackedFiles
    rollbackPatchUntrackedFileCount = [int]$rollbackPatchUntrackedFileCount
    blockedReasonCount = [int]$blockReasons.Count
    blockedReasons = @($blockReasons)
    files = @(
        "repair-agent-repository-patch-rollback-plan.md",
        "repair-agent-repository-worktree-before.txt",
        "repair-agent-repository-worktree-after.txt"
    )
}

if ($rollbackPatchGenerated) {
    $manifest.files += "repair-agent-repository-patch-rollback.patch"
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

Write-Output "Repair agent repository patch apply guard manifest: $manifestPath"
Write-Output "PASS AI TestPilot repair agent repository patch apply guard"
