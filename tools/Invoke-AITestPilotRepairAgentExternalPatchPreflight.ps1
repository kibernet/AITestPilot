[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$PatchOutputManifestPath,
    [string]$PatchPath,
    [string]$ManifestPath,
    [string[]]$AllowedPathPrefixes = @(
        "src/",
        "tests/",
        "tools/",
        "unity/",
        "docs/",
        "Assets/",
        "Packages/",
        "ProjectSettings/",
        "README.md",
        "Kibernet_AI_TestPilot_FULL_SPEC.md",
        "AITestPilot.sln",
        ".gitignore"
    ),
    [int]$MaxPatchBytes = 1048576,
    [int]$MaxTargetPathCount = 50
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($PatchOutputManifestPath)) {
    $PatchOutputManifestPath = Join-Path $EvidenceBundleDir "repair-agent-patch-output-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($PatchPath)) {
    $PatchPath = Join-Path $EvidenceBundleDir "repair-agent.patch"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "repair-agent-external-patch-preflight-manifest.json"
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

function Test-AllowedPrefix {
    param(
        [string]$Path,
        [string[]]$Prefixes
    )

    foreach ($prefix in $Prefixes) {
        if ($prefix.EndsWith("/")) {
            if ($Path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $prefix
            }
        }
        elseif ($Path.Equals($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $prefix
        }
    }

    return ""
}

function Test-SensitivePath {
    param(
        [string]$Path
    )

    $lower = $Path.ToLowerInvariant()
    $leaf = [System.IO.Path]::GetFileName($lower)
    $segments = @($lower -split "/")

    if ($segments -contains ".ssh" -or
        $segments -contains ".aws" -or
        $segments -contains ".azure" -or
        $segments -contains ".gnupg") {
        return $true
    }

    foreach ($pattern in @(
        "^\.env($|\.)",
        "\.pem$",
        "\.pfx$",
        "\.p12$",
        "\.key$",
        "^id_rsa$",
        "^id_dsa$",
        "secret",
        "credential",
        "password"
    )) {
        if ($leaf -match $pattern) {
            return $true
        }
    }

    return $false
}

function Test-PatchPath {
    param(
        [string]$RawPath,
        [string]$Usage,
        [string[]]$Prefixes
    )

    $originalPath = $RawPath.Trim()
    $candidate = ($originalPath -split "\s+", 2)[0]
    $reasons = @()
    $isNullDevice = $candidate -eq "/dev/null"

    if ($isNullDevice) {
        return [ordered]@{
            usage = $Usage
            originalPath = $originalPath
            normalizedPath = "/dev/null"
            isNullDevice = $true
            matchedAllowedPrefix = ""
            safetyStatus = "PASS"
            reasons = @()
        }
    }

    $normalized = $candidate -replace "\\", "/"
    if ($normalized -match "^[ab]/(.+)$") {
        $normalized = $Matches[1]
    }

    $normalized = $normalized.Trim()
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        $reasons += "empty_path"
    }

    if ($candidate -match "^[A-Za-z]:" -or $normalized -match "^[A-Za-z]:") {
        $reasons += "absolute_drive_path"
    }

    if ($candidate.StartsWith("/") -or
        $candidate.StartsWith("\") -or
        $normalized.StartsWith("/") -or
        $normalized.StartsWith("\")) {
        $reasons += "absolute_path"
    }

    if ($candidate -match "^[a-zA-Z][a-zA-Z0-9+.-]*://") {
        $reasons += "uri_path"
    }

    $segments = @($normalized -split "/")
    if ($segments -contains "..") {
        $reasons += "path_traversal"
    }

    if ($segments -contains ".git") {
        $reasons += "git_metadata_path"
    }

    if (Test-SensitivePath $normalized) {
        $reasons += "sensitive_path"
    }

    $matchedAllowedPrefix = Test-AllowedPrefix $normalized $Prefixes
    if ([string]::IsNullOrWhiteSpace($matchedAllowedPrefix)) {
        $reasons += "outside_allowed_prefixes"
    }

    if ($reasons.Count -eq 0) {
        $safetyStatus = "PASS"
    }
    else {
        $safetyStatus = "FAIL"
    }

    return [ordered]@{
        usage = $Usage
        originalPath = $originalPath
        normalizedPath = $normalized
        isNullDevice = $false
        matchedAllowedPrefix = $matchedAllowedPrefix
        safetyStatus = $safetyStatus
        reasons = @($reasons)
    }
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$patchOutputManifestPath = Assert-PathUnderRepo $PatchOutputManifestPath "PatchOutputManifestPath"
$patchPath = Assert-PathUnderRepo $PatchPath "PatchPath"
$manifestPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"

if (-not (Test-Path $patchOutputManifestPath)) {
    throw "Repair-agent patch output manifest is missing: $patchOutputManifestPath"
}

if (-not (Test-Path $patchPath)) {
    throw "Repair-agent patch file is missing: $patchPath"
}

$patchOutputManifest = Get-Content -Raw $patchOutputManifestPath | ConvertFrom-Json
if ($patchOutputManifest.schemaVersion -ne "aitestpilot.repair_agent_patch_output.v1") {
    throw "Unexpected patch output manifest schema: $($patchOutputManifest.schemaVersion)"
}

$patchItem = Get-Item -LiteralPath $patchPath
$patchText = Get-Content -Raw $patchPath
$patchLooksUnifiedDiff = ($patchText -match "(?m)^diff --git\s+" -and $patchText -match "(?m)^@@\s")
$patchSizeBytesWithinLimit = $patchItem.Length -le $MaxPatchBytes

$pathChecks = @()
foreach ($line in @($patchText -split "`r?`n")) {
    if ($line -match "^diff --git\s+(.+?)\s+(.+)$") {
        $pathChecks += Test-PatchPath $Matches[1] "diff_source" $AllowedPathPrefixes
        $pathChecks += Test-PatchPath $Matches[2] "diff_target" $AllowedPathPrefixes
    }
    elseif ($line -match "^---\s+(.+)$") {
        $pathChecks += Test-PatchPath $Matches[1] "old_file" $AllowedPathPrefixes
    }
    elseif ($line -match "^\+\+\+\s+(.+)$") {
        $pathChecks += Test-PatchPath $Matches[1] "new_file" $AllowedPathPrefixes
    }
}

$uniqueTargets = @()
foreach ($pathCheck in $pathChecks) {
    if (-not [bool]$pathCheck.isNullDevice -and $uniqueTargets -notcontains $pathCheck.normalizedPath) {
        $uniqueTargets += $pathCheck.normalizedPath
    }
}

$unsafePathChecks = @($pathChecks | Where-Object { $_.safetyStatus -ne "PASS" })
$failureReasons = @()
if (-not $patchLooksUnifiedDiff) {
    $failureReasons += "patch_not_unified_diff"
}

if (-not $patchSizeBytesWithinLimit) {
    $failureReasons += "patch_size_exceeds_limit"
}

if ($uniqueTargets.Count -lt 1) {
    $failureReasons += "no_target_paths"
}

if ($uniqueTargets.Count -gt $MaxTargetPathCount) {
    $failureReasons += "too_many_target_paths"
}

if ($unsafePathChecks.Count -gt 0) {
    $failureReasons += "unsafe_target_paths"
}

if ($failureReasons.Count -eq 0) {
    $status = "PASS"
}
else {
    $status = "FAIL"
}

$repositoryApplyAllowed = (
    $status -eq "PASS" -and
    [bool]$patchOutputManifest.externalAgentRun -and
    $patchOutputManifest.source -eq "external_agent"
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.repair_agent_external_patch_preflight.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    patchOutputSchemaVersion = $patchOutputManifest.schemaVersion
    patchOutputSource = $patchOutputManifest.source
    externalAgentRun = [bool]$patchOutputManifest.externalAgentRun
    patchFile = "repair-agent.patch"
    patchSizeBytes = [int64]$patchItem.Length
    maxPatchBytes = $MaxPatchBytes
    patchSizeBytesWithinLimit = [bool]$patchSizeBytesWithinLimit
    patchLooksUnifiedDiff = [bool]$patchLooksUnifiedDiff
    inspectedPathCount = [int]$pathChecks.Count
    uniqueTargetPathCount = [int]$uniqueTargets.Count
    maxTargetPathCount = $MaxTargetPathCount
    unsafePathCount = [int]$unsafePathChecks.Count
    safeToInspect = $status -eq "PASS"
    repositoryApplyAllowed = [bool]$repositoryApplyAllowed
    requiresHumanReviewForRepositoryApply = $true
    repositoryApplyPolicy = "requires_external_agent_source_safe_preflight_clean_worktree_explicit_apply_flag"
    allowedPathPrefixes = @($AllowedPathPrefixes)
    uniqueTargetPaths = @($uniqueTargets)
    pathChecks = @($pathChecks)
    failureReasonCount = [int]$failureReasons.Count
    failureReasons = @($failureReasons)
    files = @(
        "repair-agent.patch",
        "repair-agent-patch-output-manifest.json"
    )
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestPath -Encoding UTF8

Write-Output "Repair agent external patch preflight manifest: $manifestPath"
if ($status -ne "PASS") {
    throw "AI TestPilot repair agent external patch preflight failed. Manifest: $manifestPath"
}

Write-Output "PASS AI TestPilot repair agent external patch preflight"
