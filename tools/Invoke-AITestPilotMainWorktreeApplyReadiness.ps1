[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ManifestPath,
    [string]$StatusPath,
    [string]$SourceStatusPath
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

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

$statusFileName = "repair-agent-main-worktree-status.txt"
$sourceStatusFileName = "repair-agent-main-worktree-source-status.json"

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "repair-agent-main-worktree-apply-readiness-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($StatusPath)) {
    $StatusPath = Join-Path $EvidenceBundleDir $statusFileName
}

if ([string]::IsNullOrWhiteSpace($SourceStatusPath)) {
    $SourceStatusPath = Join-Path $EvidenceBundleDir $sourceStatusFileName
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

function Test-IsGeneratedEvidencePath {
    param(
        [string]$RelativePath
    )

    $normalized = $RelativePath.Replace("\", "/").TrimStart("/")
    foreach ($prefix in @("Temp", "artifacts")) {
        if ($normalized.Equals($prefix, [System.StringComparison]::OrdinalIgnoreCase) -or
            $normalized.StartsWith($prefix + "/", [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Convert-GitStatusLine {
    param(
        [string]$Line
    )

    if ([string]::IsNullOrWhiteSpace($Line) -or $Line.Length -lt 4) {
        return $null
    }

    $code = $Line.Substring(0, 2)
    $pathText = $Line.Substring(3).Replace("\", "/")
    if ($pathText -match " -> ") {
        $pathText = @($pathText -split " -> ")[-1]
    }

    $indexStatus = $code.Substring(0, 1)
    $worktreeStatus = $code.Substring(1, 1)

    return [pscustomobject][ordered]@{
        code = $code
        path = $pathText
        raw = $Line
        untracked = $code -eq "??"
        staged = $indexStatus -ne " " -and $indexStatus -ne "?"
        unstaged = $worktreeStatus -ne " " -and $worktreeStatus -ne "?"
        modified = $code.Contains("M")
        added = $code.Contains("A") -or $code -eq "??"
        deleted = $code.Contains("D")
    }
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$manifestPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$statusPath = Assert-PathUnderRepo $StatusPath "StatusPath"
$sourceStatusPath = Assert-PathUnderRepo $SourceStatusPath "SourceStatusPath"

New-Item -ItemType Directory -Force $evidenceBundlePath | Out-Null

$sourceSnapshotManifestPath = Join-Path $evidenceBundlePath "repair-agent-source-snapshot-apply-validate-manifest.json"
if (-not (Test-Path $sourceSnapshotManifestPath)) {
    throw "Source snapshot apply/validate manifest is missing: $sourceSnapshotManifestPath"
}

$sourceSnapshotManifest = Get-Content -Raw $sourceSnapshotManifestPath | ConvertFrom-Json
$sourceSnapshotCandidateValidated = (
    $sourceSnapshotManifest.status -eq "PASS" -and
    $sourceSnapshotManifest.schemaVersion -eq "aitestpilot.repair_agent_source_snapshot_apply_validate.v1" -and
    [bool]$sourceSnapshotManifest.sourceSnapshotValidationPassed -and
    [bool]$sourceSnapshotManifest.repositoryPatchApplied -and
    [bool]$sourceSnapshotManifest.rollbackApplied -and
    [bool]$sourceSnapshotManifest.worktreeCleanAfterRollback -and
    -not [bool]$sourceSnapshotManifest.mainRepositoryPatchApplied
)

if (-not $sourceSnapshotCandidateValidated) {
    throw "Source snapshot candidate evidence is not validated for main-worktree apply readiness."
}

$rawStatusLines = @(Invoke-GitChecked @("-C", $repoRoot, "status", "--porcelain=v1", "--untracked-files=all"))
$statusEntries = @($rawStatusLines | ForEach-Object { Convert-GitStatusLine $_ } | Where-Object { $null -ne $_ })
$sourceStatusEntries = @($statusEntries | Where-Object {
        $relativePath = $_.path
        -not (Test-IsGeneratedEvidencePath -RelativePath $relativePath)
    })

$rawUntrackedFiles = @(Invoke-GitChecked @("-C", $repoRoot, "ls-files", "--others", "--exclude-standard"))
$untrackedSourceFiles = @($rawUntrackedFiles | ForEach-Object { $_.Replace("\", "/") } | Where-Object {
        -not (Test-IsGeneratedEvidencePath -RelativePath $_)
    } | Sort-Object -Unique)

$generatedEvidenceStatusEntries = @($statusEntries | Where-Object {
        $relativePath = $_.path
        Test-IsGeneratedEvidencePath -RelativePath $relativePath
    })

$sourceStatusCount = $sourceStatusEntries.Count
$untrackedSourceStatusCount = @($sourceStatusEntries | Where-Object { $_.untracked }).Count
$untrackedSourceFileCount = $untrackedSourceFiles.Count
$modifiedSourceCount = @($sourceStatusEntries | Where-Object { $_.modified }).Count
$addedSourceCount = @($sourceStatusEntries | Where-Object { $_.added }).Count
$deletedSourceCount = @($sourceStatusEntries | Where-Object { $_.deleted }).Count
$trackedDirtyStatusCount = @($sourceStatusEntries | Where-Object { -not $_.untracked }).Count
$worktreeClean = $sourceStatusCount -eq 0
$readyForMainRepositoryApply = $worktreeClean -and $sourceSnapshotCandidateValidated

$blockingReasons = @()
if (-not $worktreeClean) {
    $blockingReasons += "dirty_worktree"
}

if ($untrackedSourceStatusCount -gt 0 -or $untrackedSourceFileCount -gt 0) {
    $blockingReasons += "untracked_source_files"
}

if ($trackedDirtyStatusCount -gt 0) {
    $blockingReasons += "tracked_source_changes"
}

if (-not $sourceSnapshotCandidateValidated) {
    $blockingReasons += "source_snapshot_candidate_not_validated"
}

if ($readyForMainRepositoryApply) {
    $nextRequiredActions = @(
        "Run a real external repair agent and import its completed patch output as external_agent.",
        "Run external patch preflight and require repositoryApplyAllowed=true.",
        "Run the repository patch apply guard with -ApplyToRepository.",
        "Run post-apply retest before rollback and preserve rollback evidence."
    )
}
else {
    $nextRequiredActions = @(
        "Create, stage, or commit the current AI TestPilot baseline so the main worktree is clean.",
        "Run a real external repair agent and import its completed patch output as external_agent.",
        "Run external patch preflight and require repositoryApplyAllowed=true.",
        "Run the repository patch apply guard with -ApplyToRepository, then run post-apply retest and keep rollback evidence."
    )
}

$statusLines = @(
    "# AI TestPilot Main Worktree Apply Readiness",
    "",
    "mainRepositoryRoot: $repoRoot",
    "worktreeClean: $worktreeClean",
    "readyForMainRepositoryApply: $readyForMainRepositoryApply",
    "mainRepositoryPatchApplied: False",
    "sourceStatusCount: $sourceStatusCount",
    "untrackedSourceStatusCount: $untrackedSourceStatusCount",
    "untrackedSourceFileCount: $untrackedSourceFileCount",
    "modifiedSourceCount: $modifiedSourceCount",
    "trackedDirtyStatusCount: $trackedDirtyStatusCount",
    "sourceSnapshotCandidateValidated: $sourceSnapshotCandidateValidated",
    "sourceSnapshotCandidateRollbackClean: $($sourceSnapshotManifest.worktreeCleanAfterRollback)",
    "blockingReasons: $($blockingReasons -join ', ')",
    "",
    "Source git status entries:"
)

if ($sourceStatusEntries.Count -eq 0) {
    $statusLines += "(none)"
}
else {
    $statusLines += @($sourceStatusEntries | ForEach-Object { $_.raw })
}

$statusLines += @(
    "",
    "Untracked source files:"
)

if ($untrackedSourceFiles.Count -eq 0) {
    $statusLines += "(none)"
}
else {
    $statusLines += $untrackedSourceFiles
}

$statusLines | Set-Content -Path $statusPath -Encoding UTF8

$sourceStatusDocument = [ordered]@{
    schemaVersion = "aitestpilot.main_worktree_source_status.v1"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    mainRepositoryRoot = $repoRoot
    sourceStatusCount = [int]$sourceStatusCount
    untrackedSourceStatusCount = [int]$untrackedSourceStatusCount
    untrackedSourceFileCount = [int]$untrackedSourceFileCount
    modifiedSourceCount = [int]$modifiedSourceCount
    addedSourceCount = [int]$addedSourceCount
    deletedSourceCount = [int]$deletedSourceCount
    trackedDirtyStatusCount = [int]$trackedDirtyStatusCount
    generatedEvidenceStatusCount = [int]$generatedEvidenceStatusEntries.Count
    statusEntries = @($sourceStatusEntries)
    untrackedSourceFiles = @($untrackedSourceFiles)
}

$sourceStatusDocument | ConvertTo-Json -Depth 10 | Set-Content -Path $sourceStatusPath -Encoding UTF8

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.repair_agent_main_worktree_apply_readiness.v1"
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    mainRepositoryRoot = $repoRoot
    worktreeClean = [bool]$worktreeClean
    readyForMainRepositoryApply = [bool]$readyForMainRepositoryApply
    mainRepositoryPatchApplied = $false
    repositoryApplyGuardPolicy = "main_repository_apply_requires_clean_source_worktree_verified_external_agent_preflight_explicit_apply_switch"
    sourceStatusCount = [int]$sourceStatusCount
    untrackedSourceStatusCount = [int]$untrackedSourceStatusCount
    untrackedSourceFileCount = [int]$untrackedSourceFileCount
    modifiedSourceCount = [int]$modifiedSourceCount
    addedSourceCount = [int]$addedSourceCount
    deletedSourceCount = [int]$deletedSourceCount
    trackedDirtyStatusCount = [int]$trackedDirtyStatusCount
    generatedEvidenceStatusCount = [int]$generatedEvidenceStatusEntries.Count
    blockingReasonCount = [int]$blockingReasons.Count
    blockingReasons = @($blockingReasons)
    sourceSnapshotCandidateManifestPresent = $true
    sourceSnapshotCandidateValidated = [bool]$sourceSnapshotCandidateValidated
    sourceSnapshotCandidateRollbackClean = [bool]$sourceSnapshotManifest.worktreeCleanAfterRollback
    sourceSnapshotCandidateRollbackRemovedPatchedFile = [bool]$sourceSnapshotManifest.rollbackRemovedPatchedFile
    sourceSnapshotCandidateMainRepositoryPatchApplied = [bool]$sourceSnapshotManifest.mainRepositoryPatchApplied
    sourceSnapshotCandidateManifest = "repair-agent-source-snapshot-apply-validate-manifest.json"
    nextRequiredActions = @($nextRequiredActions)
    files = @(
        $statusFileName,
        $sourceStatusFileName
    )
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

Write-Output "Repair agent main worktree apply readiness manifest: $manifestPath"
Write-Output "PASS AI TestPilot repair agent main worktree apply readiness"
