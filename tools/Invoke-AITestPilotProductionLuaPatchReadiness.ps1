[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ManifestPath,
    [string]$ProductionLuaEvidenceDir,
    [switch]$RequireProductionLuaPatched
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-lua-patch-readiness-manifest.json"
}

function Resolve-FullPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Read-RequiredJson {
    param(
        [string]$FileName,
        [string]$Label
    )

    $path = Join-Path $EvidenceBundleDir $FileName
    if (-not (Test-Path $path)) {
        throw "$Label is missing: $path"
    }

    return Get-Content -Path $path -Encoding UTF8 -Raw | ConvertFrom-Json
}

function Read-OptionalJsonFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) {
        return $null
    }

    return Get-Content -Path $Path -Encoding UTF8 -Raw | ConvertFrom-Json
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

function Add-BlockingReason {
    param([string]$Reason)

    if ($script:blockingReasons -notcontains $Reason) {
        $script:blockingReasons += $Reason
    }
}

$EvidenceBundleDir = Resolve-FullPath $EvidenceBundleDir
$manifestPath = Resolve-FullPath $ManifestPath

if (-not (Test-Path $EvidenceBundleDir)) {
    throw "Evidence bundle does not exist: $EvidenceBundleDir"
}

$luaStaticAnalysisManifest = Read-RequiredJson "lua-static-analysis-manifest.json" "Lua static analysis manifest"
$luaAutoPatchSandboxManifest = Read-RequiredJson "lua-auto-patch-sandbox-manifest.json" "Lua auto patch sandbox manifest"

$blockingReasons = @()

$staticAnalysisPassed = $luaStaticAnalysisManifest.status -eq "PASS" -and
    $luaStaticAnalysisManifest.schemaVersion -eq "aitestpilot.lua_static_analysis.v1" -and
    [bool]$luaStaticAnalysisManifest.patchPlanGenerated -and
    -not [bool]$luaStaticAnalysisManifest.realProductionLuaAnalyzed -and
    [int]$luaStaticAnalysisManifest.blockingReasonCount -eq 0
if (-not $staticAnalysisPassed) {
    Add-BlockingReason "lua_static_analysis_not_ready"
}

$sandboxAfterFindingsCleared = $luaAutoPatchSandboxManifest.status -eq "PASS" -and
    $luaAutoPatchSandboxManifest.schemaVersion -eq "aitestpilot.lua_auto_patch_sandbox.v1" -and
    [int]$luaAutoPatchSandboxManifest.beforeFindingCount -gt 0 -and
    [int]$luaAutoPatchSandboxManifest.patchOperationCount -gt 0 -and
    [int]$luaAutoPatchSandboxManifest.afterFindingCount -eq 0 -and
    [int]$luaAutoPatchSandboxManifest.afterHighRiskFindingCount -eq 0
if (-not $sandboxAfterFindingsCleared) {
    Add-BlockingReason "lua_auto_patch_sandbox_not_clean"
}

$sandboxBoundaryPreserved = [bool]$luaAutoPatchSandboxManifest.sandboxOnly -and
    -not [bool]$luaAutoPatchSandboxManifest.mainRepositoryMutated -and
    -not [bool]$luaAutoPatchSandboxManifest.realProductionLuaPatched -and
    $luaAutoPatchSandboxManifest.productionBoundary -eq "deterministic_lua_fixture_only"
if (-not $sandboxBoundaryPreserved) {
    Add-BlockingReason "lua_auto_patch_sandbox_boundary_violated"
}

$productionLuaBundleProvided = -not [string]::IsNullOrWhiteSpace($ProductionLuaEvidenceDir)
$productionLuaEvidence = $null
$productionLuaEvidencePath = ""
$productionLuaEvidenceCopied = $false
$copiedProductionLuaEvidenceName = "production-lua-patch-evidence.json"

if ($productionLuaBundleProvided) {
    $productionLuaEvidenceDirPath = Resolve-FullPath $ProductionLuaEvidenceDir
    $productionLuaEvidencePath = Join-Path $productionLuaEvidenceDirPath "production-lua-patch-evidence.json"
    $productionLuaEvidence = Read-OptionalJsonFile $productionLuaEvidencePath
    if ($null -eq $productionLuaEvidence) {
        Add-BlockingReason "real_production_lua_bundle_missing"
    }
    else {
        Copy-Item -LiteralPath $productionLuaEvidencePath -Destination (Join-Path $EvidenceBundleDir $copiedProductionLuaEvidenceName) -Force
        $productionLuaEvidenceCopied = $true
    }
}
else {
    Add-BlockingReason "real_production_lua_bundle_missing"
}

$productionLuaEvidenceAccepted = $false
$realProductionLuaAnalyzed = $false
$realProductionLuaPatched = $false
$productionPatchApplied = $false
$productionPatchValidated = $false
$productionRetestPassed = $false
$rollbackPlanGenerated = $false
$rollbackVerified = $false
$packageRepositoryMutated = $false
$sourceControlCleanAfterValidation = $false
$productionChangedFileCount = 0
$productionBeforeFindingCount = 0
$productionAfterFindingCount = 0
$productionAfterHighRiskFindingCount = 0
$productionEvidenceBlockingReasonCount = 0

if ($null -ne $productionLuaEvidence) {
    $realProductionLuaAnalyzed = [bool](Get-JsonValue $productionLuaEvidence "realProductionLuaAnalyzed" $false)
    $realProductionLuaPatched = [bool](Get-JsonValue $productionLuaEvidence "realProductionLuaPatched" $false)
    $productionPatchApplied = [bool](Get-JsonValue $productionLuaEvidence "productionPatchApplied" $false)
    $productionPatchValidated = [bool](Get-JsonValue $productionLuaEvidence "productionPatchValidated" $false)
    $productionRetestPassed = [bool](Get-JsonValue $productionLuaEvidence "productionRetestPassed" $false)
    $rollbackPlanGenerated = [bool](Get-JsonValue $productionLuaEvidence "rollbackPlanGenerated" $false)
    $rollbackVerified = [bool](Get-JsonValue $productionLuaEvidence "rollbackVerified" $false)
    $packageRepositoryMutated = [bool](Get-JsonValue $productionLuaEvidence "packageRepositoryMutated" $false)
    $sourceControlCleanAfterValidation = [bool](Get-JsonValue $productionLuaEvidence "sourceControlCleanAfterValidation" $false)
    $productionChangedFileCount = [int](Get-JsonValue $productionLuaEvidence "changedFileCount" 0)
    $productionBeforeFindingCount = [int](Get-JsonValue $productionLuaEvidence "beforeFindingCount" 0)
    $productionAfterFindingCount = [int](Get-JsonValue $productionLuaEvidence "afterFindingCount" 0)
    $productionAfterHighRiskFindingCount = [int](Get-JsonValue $productionLuaEvidence "afterHighRiskFindingCount" 0)
    $productionEvidenceBlockingReasonCount = [int](Get-JsonValue $productionLuaEvidence "blockingReasonCount" 0)

    $productionLuaEvidenceAccepted = $productionLuaEvidence.schemaVersion -eq "aitestpilot.production_lua_patch_evidence.v1" -and
        $productionLuaEvidence.status -eq "PASS" -and
        $realProductionLuaAnalyzed -and
        $realProductionLuaPatched -and
        $productionPatchApplied -and
        $productionPatchValidated -and
        $productionRetestPassed -and
        $rollbackPlanGenerated -and
        $rollbackVerified -and
        -not $packageRepositoryMutated -and
        $sourceControlCleanAfterValidation -and
        $productionChangedFileCount -gt 0 -and
        $productionBeforeFindingCount -gt 0 -and
        $productionAfterFindingCount -eq 0 -and
        $productionAfterHighRiskFindingCount -eq 0 -and
        $productionEvidenceBlockingReasonCount -eq 0
}

if (-not $realProductionLuaAnalyzed) {
    Add-BlockingReason "real_production_lua_not_analyzed"
}

if (-not $realProductionLuaPatched -or -not $productionPatchApplied) {
    Add-BlockingReason "real_production_lua_not_patched"
}

if (-not $productionPatchValidated -or -not $productionRetestPassed) {
    Add-BlockingReason "production_lua_retest_evidence_missing"
}

if (-not $rollbackPlanGenerated -or -not $rollbackVerified) {
    Add-BlockingReason "real_production_patch_rollback_missing"
}

if ($packageRepositoryMutated) {
    Add-BlockingReason "package_repository_unexpectedly_mutated"
}

$readyForProductionLuaPatchRelease = $staticAnalysisPassed -and
    $sandboxAfterFindingsCleared -and
    $sandboxBoundaryPreserved -and
    $productionLuaEvidenceAccepted

$files = @(
    "production-lua-patch-readiness-manifest.json",
    "lua-static-analysis-manifest.json",
    "lua-auto-patch-sandbox-manifest.json",
    "lua-auto-patch.patch",
    "lua-auto-patch-operations.json"
)

if ($productionLuaEvidenceCopied) {
    $files += $copiedProductionLuaEvidenceName
}

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_lua_patch_readiness.v1"
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    packageReleaseAllowedWithoutProductionLuaPatch = $true
    productionLuaPatchRequiredForPackageRelease = $false
    requireProductionLuaPatched = [bool]$RequireProductionLuaPatched
    readyForProductionLuaPatchRelease = [bool]$readyForProductionLuaPatchRelease
    productionLuaBundleProvided = [bool]$productionLuaBundleProvided
    productionLuaEvidenceAccepted = [bool]$productionLuaEvidenceAccepted
    productionLuaEvidenceCopied = [bool]$productionLuaEvidenceCopied
    productionLuaEvidencePath = $productionLuaEvidencePath
    staticAnalysisPassed = [bool]$staticAnalysisPassed
    sandboxAfterFindingsCleared = [bool]$sandboxAfterFindingsCleared
    sandboxBoundaryPreserved = [bool]$sandboxBoundaryPreserved
    sandboxPatchOperationCount = [int]$luaAutoPatchSandboxManifest.patchOperationCount
    sandboxChangedFileCount = [int]$luaAutoPatchSandboxManifest.changedFileCount
    sandboxAfterFindingCount = [int]$luaAutoPatchSandboxManifest.afterFindingCount
    realProductionLuaAnalyzed = [bool]$realProductionLuaAnalyzed
    realProductionLuaPatched = [bool]$realProductionLuaPatched
    productionPatchApplied = [bool]$productionPatchApplied
    productionPatchValidated = [bool]$productionPatchValidated
    productionRetestPassed = [bool]$productionRetestPassed
    rollbackPlanGenerated = [bool]$rollbackPlanGenerated
    rollbackVerified = [bool]$rollbackVerified
    packageRepositoryMutated = [bool]$packageRepositoryMutated
    sourceControlCleanAfterValidation = [bool]$sourceControlCleanAfterValidation
    productionChangedFileCount = [int]$productionChangedFileCount
    productionBeforeFindingCount = [int]$productionBeforeFindingCount
    productionAfterFindingCount = [int]$productionAfterFindingCount
    productionAfterHighRiskFindingCount = [int]$productionAfterHighRiskFindingCount
    productionEvidenceBlockingReasonCount = [int]$productionEvidenceBlockingReasonCount
    productionOutputBoundary = if ($productionLuaEvidenceAccepted) { "real_production_lua_patch_evidence_accepted" } else { "real_production_lua_patch_not_claimed" }
    blockingReasonCount = [int]$blockingReasons.Count
    blockingReasons = @($blockingReasons)
    files = @($files)
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

Write-Output "Production Lua patch readiness manifest: $manifestPath"

if ($RequireProductionLuaPatched -and -not $readyForProductionLuaPatchRelease) {
    throw "Production Lua patch evidence is not ready: $($blockingReasons -join ', ')"
}

Write-Output "PASS AI TestPilot production Lua patch readiness"
