[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ExternalBundleDir,
    [string]$ManifestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
if ([string]::IsNullOrWhiteSpace($ExternalBundleDir)) {
    $ExternalBundleDir = Join-Path $tempRoot "AITestPilot\production-lua-external-bundle-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-lua-patch-external-bundle-intake-probe-manifest.json"
}

$requiredReadinessInputs = @(
    "lua-static-analysis-manifest.json",
    "lua-auto-patch-sandbox-manifest.json",
    "lua-auto-patch.patch",
    "lua-auto-patch-operations.json"
)

$expectedBlockingReasons = @(
    "real_production_lua_not_analyzed",
    "real_production_lua_not_patched",
    "production_lua_retest_evidence_missing",
    "real_production_patch_rollback_missing"
)

function Resolve-FullPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Assert-PathUnderTemp {
    param(
        [string]$Path,
        [string]$Label
    )

    $fullPath = Resolve-FullPath $Path
    if (-not $fullPath.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must stay under system temp for this probe: $fullPath"
    }

    return $fullPath
}

function Assert-PathUnderRepo {
    param(
        [string]$Path,
        [string]$Label
    )

    $fullPath = Resolve-FullPath $Path
    if (-not $fullPath.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must stay under repo root: $fullPath"
    }

    return $fullPath
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

function Test-ContainsAll {
    param(
        [object[]]$Actual,
        [string[]]$Required
    )

    foreach ($item in $Required) {
        if ($Actual -notcontains $item) {
            return $false
        }
    }

    return $true
}

function Add-ProbeCheck {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Message
    )

    $script:checks += [ordered]@{
        name = $Name
        passed = [bool]$Passed
        message = $Message
    }
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$externalBundlePath = Assert-PathUnderTemp $ExternalBundleDir "ExternalBundleDir"
$manifestPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if (Test-Path $externalBundlePath) {
    Remove-Item -LiteralPath $externalBundlePath -Recurse -Force
}

$externalReadinessBundlePath = Join-Path $externalBundlePath "readiness-bundle"
$externalProductionLuaEvidencePath = Join-Path $externalBundlePath "production-lua-evidence"

New-Item -ItemType Directory -Force $externalReadinessBundlePath | Out-Null

$missingFiles = @()
foreach ($fileName in $requiredReadinessInputs) {
    $sourcePath = Join-Path $evidenceBundlePath $fileName
    if (-not (Test-Path $sourcePath)) {
        $missingFiles += $fileName
        continue
    }

    Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $externalReadinessBundlePath $fileName) -Force
}

if ($missingFiles.Count -gt 0) {
    throw "Source evidence bundle is missing required Lua readiness files for external bundle probe: $($missingFiles -join ', ')"
}

$externalKitManifestPath = Join-Path $externalProductionLuaEvidencePath "production-lua-patch-evidence-kit-generated-manifest.json"
& (Join-Path $PSScriptRoot "New-AITestPilotProductionLuaPatchEvidenceKit.ps1") `
    -OutputDir $externalProductionLuaEvidencePath `
    -ManifestPath $externalKitManifestPath

$externalReadinessManifestPath = Join-Path $externalReadinessBundlePath "production-lua-patch-readiness-manifest.json"
$readinessCommandFailed = $false
$readinessError = ""
try {
    & (Join-Path $PSScriptRoot "Invoke-AITestPilotProductionLuaPatchReadiness.ps1") `
        -EvidenceBundleDir $externalReadinessBundlePath `
        -ManifestPath $externalReadinessManifestPath `
        -ProductionLuaEvidenceDir $externalProductionLuaEvidencePath `
        -RequireProductionLuaPatched
}
catch {
    $readinessCommandFailed = $true
    $readinessError = $_.Exception.Message
}

$externalReadinessManifest = Read-JsonFile $externalReadinessManifestPath "External production Lua readiness manifest"
$externalEvidence = Read-JsonFile (Join-Path $externalProductionLuaEvidencePath "production-lua-patch-evidence.json") "External production Lua evidence template"
$externalKitManifest = Read-JsonFile $externalKitManifestPath "External production Lua evidence kit manifest"

$externalBundleUnderRepo = $externalBundlePath.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)
$blockingReasons = @($externalReadinessManifest.blockingReasons)
$expectedBlockingReasonsFound = Test-ContainsAll -Actual $blockingReasons -Required $expectedBlockingReasons

$templateEvidenceRead = [bool]$externalReadinessManifest.productionLuaBundleProvided -and
    [bool]$externalReadinessManifest.productionLuaEvidenceCopied -and
    -not [bool]$externalReadinessManifest.productionLuaEvidenceAccepted -and
    $externalReadinessManifest.productionLuaEvidencePath.StartsWith($externalProductionLuaEvidencePath, [System.StringComparison]::OrdinalIgnoreCase)

$expectedBlockedPassed = [bool]$readinessCommandFailed -and
    $externalReadinessManifest.status -eq "PASS" -and
    [bool]$externalReadinessManifest.requireProductionLuaPatched -and
    -not [bool]$externalReadinessManifest.readyForProductionLuaPatchRelease -and
    [bool]$externalReadinessManifest.staticAnalysisPassed -and
    [bool]$externalReadinessManifest.sandboxAfterFindingsCleared -and
    [bool]$externalReadinessManifest.sandboxBoundaryPreserved -and
    [bool]$templateEvidenceRead -and
    -not [bool]$externalReadinessManifest.realProductionLuaAnalyzed -and
    -not [bool]$externalReadinessManifest.realProductionLuaPatched -and
    $externalReadinessManifest.productionOutputBoundary -eq "real_production_lua_patch_not_claimed" -and
    $expectedBlockingReasonsFound -and
    ($blockingReasons -notcontains "real_production_lua_bundle_missing")

$templateKitValid = $externalKitManifest.status -eq "PASS" -and
    $externalKitManifest.schemaVersion -eq "aitestpilot.production_lua_patch_evidence_kit_generated.v1" -and
    [bool]$externalKitManifest.templateOnly -and
    -not [bool]$externalKitManifest.acceptedFixtureGenerated -and
    -not [bool]$externalKitManifest.productionEvidenceAccepted -and
    $externalEvidence.status -eq "PENDING_PRODUCTION_EVIDENCE"

if ($externalBundleUnderRepo) {
    throw "External production Lua bundle probe did not use a path outside the repo: $externalBundlePath"
}

$checks = @()
Add-ProbeCheck "external_bundle_outside_repo" (-not [bool]$externalBundleUnderRepo) "External production Lua evidence bundle must live outside the repository."
Add-ProbeCheck "template_evidence_generated" $templateKitValid "External template evidence must be generated and remain pending."
Add-ProbeCheck "template_evidence_read" $templateEvidenceRead "Readiness must read the external production-lua-patch-evidence.json file."
Add-ProbeCheck "expected_blocked" $expectedBlockedPassed "RequireProductionLuaPatched must reject the external template evidence."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$copiedReadinessManifestName = "production-lua-patch-external-bundle-readiness-manifest.json"
$copiedEvidenceName = "production-lua-patch-external-bundle-evidence.json"
$copiedKitManifestName = "production-lua-patch-external-bundle-kit-generated-manifest.json"

Copy-Item -LiteralPath $externalReadinessManifestPath -Destination (Join-Path $evidenceBundlePath $copiedReadinessManifestName) -Force
Copy-Item -LiteralPath (Join-Path $externalProductionLuaEvidencePath "production-lua-patch-evidence.json") -Destination (Join-Path $evidenceBundlePath $copiedEvidenceName) -Force
Copy-Item -LiteralPath $externalKitManifestPath -Destination (Join-Path $evidenceBundlePath $copiedKitManifestName) -Force

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_lua_patch_external_bundle_intake_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    sourceEvidenceBundleDir = $evidenceBundlePath
    externalBundleDir = $externalBundlePath
    externalReadinessBundleDir = $externalReadinessBundlePath
    externalProductionLuaEvidenceDir = $externalProductionLuaEvidencePath
    externalBundleUnderRepo = [bool]$externalBundleUnderRepo
    requiredFileCount = [int]$requiredReadinessInputs.Count
    requiredFilesCopied = @($requiredReadinessInputs)
    templateEvidenceGenerated = [bool]$templateKitValid
    templateEvidenceStatus = $externalEvidence.status
    templateEvidenceRead = [bool]$templateEvidenceRead
    expectedBlocked = $true
    expectedBlockedPassed = [bool]$expectedBlockedPassed
    readinessCommandFailed = [bool]$readinessCommandFailed
    readinessError = $readinessError
    readyForProductionLuaPatchRelease = [bool]$externalReadinessManifest.readyForProductionLuaPatchRelease
    productionLuaBundleProvided = [bool]$externalReadinessManifest.productionLuaBundleProvided
    productionLuaEvidenceCopied = [bool]$externalReadinessManifest.productionLuaEvidenceCopied
    productionLuaEvidenceAccepted = [bool]$externalReadinessManifest.productionLuaEvidenceAccepted
    productionOutputBoundary = $externalReadinessManifest.productionOutputBoundary
    expectedBlockingReasonsFound = [bool]$expectedBlockingReasonsFound
    blockingReasonCount = [int]$blockingReasons.Count
    blockingReasons = @($blockingReasons)
    readinessManifestStatus = $externalReadinessManifest.status
    readinessRequireProductionLuaPatched = [bool]$externalReadinessManifest.requireProductionLuaPatched
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
    files = @(
        $copiedReadinessManifestName,
        $copiedEvidenceName,
        $copiedKitManifestName
    )
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Production Lua patch external bundle intake probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production Lua patch external bundle intake probe manifest: $manifestPath"
Write-Output "PASS AI TestPilot production Lua patch external bundle intake probe"
