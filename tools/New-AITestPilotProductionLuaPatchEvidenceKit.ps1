[CmdletBinding()]
param(
    [string]$OutputDir,
    [string]$ManifestPath,
    [switch]$GenerateAcceptedFixture
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $repoRoot "Temp\production-lua-patch-evidence-kit\latest"
}

$outputPath = [System.IO.Path]::GetFullPath($OutputDir)
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $outputPath "production-lua-patch-evidence-kit-generated-manifest.json"
}

$manifestPath = [System.IO.Path]::GetFullPath($ManifestPath)

if (Test-Path $outputPath) {
    Remove-Item -LiteralPath $outputPath -Recurse -Force
}

New-Item -ItemType Directory -Force $outputPath | Out-Null

$expectedBlockingReasons = @(
    "real_production_lua_bundle_missing",
    "real_production_lua_not_analyzed",
    "real_production_lua_not_patched",
    "production_lua_retest_evidence_missing",
    "real_production_patch_rollback_missing"
)

$blockingReasons = @()
if (-not [bool]$GenerateAcceptedFixture) {
    $blockingReasons = @($expectedBlockingReasons)
}
$evidenceStatus = if ($GenerateAcceptedFixture) { "PASS" } else { "PENDING_PRODUCTION_EVIDENCE" }
$fixtureBoundary = if ($GenerateAcceptedFixture) { "contract_fixture_only_not_real_host_project" } else { "template_only_not_real_host_project" }

$evidence = [ordered]@{
    schemaVersion = "aitestpilot.production_lua_patch_evidence.v1"
    status = $evidenceStatus
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceType = if ($GenerateAcceptedFixture) { "accepted_readiness_contract_fixture" } else { "host_project_template" }
    fixtureOnly = [bool]$GenerateAcceptedFixture
    realHostProjectEvidence = $false
    fixtureBoundary = $fixtureBoundary
    realProductionLuaAnalyzed = [bool]$GenerateAcceptedFixture
    realProductionLuaPatched = [bool]$GenerateAcceptedFixture
    productionPatchApplied = [bool]$GenerateAcceptedFixture
    productionPatchValidated = [bool]$GenerateAcceptedFixture
    productionRetestPassed = [bool]$GenerateAcceptedFixture
    rollbackPlanGenerated = [bool]$GenerateAcceptedFixture
    rollbackVerified = [bool]$GenerateAcceptedFixture
    packageRepositoryMutated = $false
    sourceControlCleanAfterValidation = [bool]$GenerateAcceptedFixture
    changedFileCount = if ($GenerateAcceptedFixture) { 2 } else { 0 }
    beforeFindingCount = if ($GenerateAcceptedFixture) { 5 } else { 0 }
    afterFindingCount = 0
    afterHighRiskFindingCount = 0
    blockingReasonCount = [int]$blockingReasons.Count
    blockingReasons = @($blockingReasons)
    analyzedLuaRoot = if ($GenerateAcceptedFixture) { "fixture://accepted-production-lua" } else { "" }
    patchArtifact = if ($GenerateAcceptedFixture) { "production-lua.patch" } else { "" }
    retestEvidence = if ($GenerateAcceptedFixture) { "production-lua-patch-retest-template.md" } else { "" }
    rollbackEvidence = if ($GenerateAcceptedFixture) { "production-lua-patch-rollback-plan-template.md" } else { "" }
    instructions = @(
        "Replace this template with host-project evidence produced from the real production Lua tree.",
        "Keep packageRepositoryMutated=false; this evidence belongs to the host project or release evidence bundle, not the AI TestPilot package repository.",
        "Run Invoke-AITestPilotProductionLuaPatchReadiness.ps1 with -ProductionLuaEvidenceDir and -RequireProductionLuaPatched before claiming production Lua patch readiness."
    )
}

$readme = @'
# AI TestPilot Production Lua Patch Evidence Kit

This kit defines the host-project evidence required before `-RequireProductionLuaPatched` can pass. The default template is not accepted as production evidence.

## Files

- `production-lua-patch-evidence.json`: machine-readable acceptance evidence consumed by `Invoke-AITestPilotProductionLuaPatchReadiness.ps1`.
- `production-lua-patch-evidence-schema.md`: required fields and acceptance rules.
- `production-lua-patch-retest-template.md`: retest evidence checklist for the patched Lua bundle.
- `production-lua-patch-rollback-plan-template.md`: rollback evidence checklist.
- `Invoke-ProductionLuaPatchEvidence.ps1`: owner-side helper that validates filled real Lua evidence and exports the return bundle.
- `Export-ProductionLuaPatchEvidenceBundle.ps1`: packages the three required Lua evidence files only after hard readiness passes with real host-project evidence.

## Required command

After filling the JSON from the real host-project Lua patch run, validate it with:

```powershell
.\tools\Invoke-AITestPilotProductionLuaPatchReadiness.ps1 -EvidenceBundleDir "path\to\release-evidence" -ProductionLuaEvidenceDir "path\to\production-lua-evidence" -RequireProductionLuaPatched
```

For a full release pipeline run, pass the same directory:

```powershell
.\tools\Invoke-AITestPilotReleasePipeline.ps1 -ProductionLuaEvidenceDir "path\to\production-lua-evidence" -RequireProductionLuaPatched
```

To package the owner response after real evidence passes readiness, run:

```powershell
.\Export-ProductionLuaPatchEvidenceBundle.ps1 -EvidenceBundleDir "path\to\release-evidence" -ProductionLuaEvidenceDir "path\to\production-lua-evidence"
```

Do not mark `realHostProjectEvidence=true` or remove the blocking reasons until the real production Lua tree has been analyzed, patched, retested, rolled back, and source-control cleanliness has been verified.
'@

$schema = @'
# Production Lua Patch Evidence Schema

The file name must be `production-lua-patch-evidence.json`.

Required accepted values:

- `schemaVersion`: `aitestpilot.production_lua_patch_evidence.v1`
- `status`: `PASS`
- `fixtureOnly`: `false`
- `realHostProjectEvidence`: `true`
- `realProductionLuaAnalyzed`: `true`
- `realProductionLuaPatched`: `true`
- `productionPatchApplied`: `true`
- `productionPatchValidated`: `true`
- `productionRetestPassed`: `true`
- `rollbackPlanGenerated`: `true`
- `rollbackVerified`: `true`
- `packageRepositoryMutated`: `false`
- `sourceControlCleanAfterValidation`: `true`
- `changedFileCount`: greater than `0`
- `beforeFindingCount`: greater than `0`
- `afterFindingCount`: `0`
- `afterHighRiskFindingCount`: `0`
- `blockingReasonCount`: `0`

Optional bookkeeping fields such as `analyzedLuaRoot`, `patchArtifact`, `retestEvidence`, and `rollbackEvidence` should point to host-project evidence paths or artifact names.
'@

$retest = @'
# Production Lua Patch Retest Evidence

- Host project:
- Lua root analyzed:
- Patch artifact:
- Retest command:
- Retest environment:
- Retest result:
- High-risk findings before patch:
- Findings after patch:
- Owner:
- Timestamp:

Attach command output or CI links in the host evidence bundle. The JSON is accepted only when `productionPatchValidated=true`, `productionRetestPassed=true`, and both post-patch finding counts are zero.
'@

$rollback = @'
# Production Lua Patch Rollback Plan

- Patch artifact:
- Rollback artifact:
- Rollback command:
- Rollback verification command:
- Source-control status command:
- Rollback verified:
- Source-control clean after validation:
- Owner:
- Timestamp:

The JSON is accepted only when `rollbackPlanGenerated=true`, `rollbackVerified=true`, `packageRepositoryMutated=false`, and `sourceControlCleanAfterValidation=true`.
'@

$invokeScriptTemplate = @'
[CmdletBinding()]
param(
    [string]$AITestPilotRepoRoot = "__REPO_ROOT__",
    [string]$EvidenceBundleDir,
    [string]$ProductionLuaEvidenceDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $AITestPilotRepoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ProductionLuaEvidenceDir)) {
    $ProductionLuaEvidenceDir = $PSScriptRoot
}

& (Join-Path $AITestPilotRepoRoot "tools\Invoke-AITestPilotProductionLuaPatchReadiness.ps1") `
    -EvidenceBundleDir $EvidenceBundleDir `
    -ProductionLuaEvidenceDir $ProductionLuaEvidenceDir `
    -RequireProductionLuaPatched

& (Join-Path $PSScriptRoot "Export-ProductionLuaPatchEvidenceBundle.ps1") `
    -AITestPilotRepoRoot $AITestPilotRepoRoot `
    -EvidenceBundleDir $EvidenceBundleDir `
    -ProductionLuaEvidenceDir $ProductionLuaEvidenceDir
'@

$exportScriptTemplate = @'
[CmdletBinding()]
param(
    [string]$AITestPilotRepoRoot = "__REPO_ROOT__",
    [string]$EvidenceBundleDir,
    [string]$ProductionLuaEvidenceDir,
    [string]$OutputDir,
    [string]$ZipPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    throw "EvidenceBundleDir is required."
}

if ([string]::IsNullOrWhiteSpace($ProductionLuaEvidenceDir)) {
    $ProductionLuaEvidenceDir = $PSScriptRoot
}

$evidenceBundlePath = [System.IO.Path]::GetFullPath($EvidenceBundleDir)
$productionLuaEvidencePath = [System.IO.Path]::GetFullPath($ProductionLuaEvidenceDir)

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if (-not (Test-Path $productionLuaEvidencePath)) {
    throw "Production Lua evidence directory does not exist: $productionLuaEvidencePath"
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path (Join-Path $evidenceBundlePath "production-lua-evidence-export") "production-lua-evidence"
}
$outputPath = [System.IO.Path]::GetFullPath($OutputDir)

if ([string]::IsNullOrWhiteSpace($ZipPath)) {
    $ZipPath = Join-Path (Split-Path $outputPath -Parent) "production-lua-evidence.zip"
}
$zipFullPath = [System.IO.Path]::GetFullPath($ZipPath)

$requiredFiles = @(
    "production-lua-patch-evidence.json",
    "production-lua-patch-retest-template.md",
    "production-lua-patch-rollback-plan-template.md"
)

$missingFiles = @()
foreach ($fileName in $requiredFiles) {
    if (-not (Test-Path (Join-Path $productionLuaEvidencePath $fileName))) {
        $missingFiles += $fileName
    }
}
if ($missingFiles.Count -gt 0) {
    throw "Production Lua evidence export is missing required files: $($missingFiles -join ', ')"
}

$readinessManifestPath = Join-Path (Split-Path $outputPath -Parent) "production-lua-patch-readiness-for-export.json"
New-Item -ItemType Directory -Force (Split-Path $readinessManifestPath -Parent) | Out-Null

& (Join-Path $AITestPilotRepoRoot "tools\Invoke-AITestPilotProductionLuaPatchReadiness.ps1") `
    -EvidenceBundleDir $evidenceBundlePath `
    -ManifestPath $readinessManifestPath `
    -ProductionLuaEvidenceDir $productionLuaEvidencePath `
    -RequireProductionLuaPatched

$readiness = Read-JsonFile $readinessManifestPath "Production Lua patch readiness manifest"
$productionEvidence = Read-JsonFile (Join-Path $productionLuaEvidencePath "production-lua-patch-evidence.json") "Production Lua patch evidence"

$fixtureOnly = [bool](Get-JsonValue $productionEvidence "fixtureOnly" $false)
$realHostProjectEvidence = [bool](Get-JsonValue $productionEvidence "realHostProjectEvidence" $false)
$readyForExport = $readiness.status -eq "PASS" -and
    [bool](Get-JsonValue $readiness "readyForProductionLuaPatchRelease" $false) -and
    [bool](Get-JsonValue $readiness "productionLuaEvidenceAccepted" $false) -and
    [bool](Get-JsonValue $readiness "realProductionLuaAnalyzed" $false) -and
    [bool](Get-JsonValue $readiness "realProductionLuaPatched" $false) -and
    [bool](Get-JsonValue $readiness "productionPatchApplied" $false) -and
    [bool](Get-JsonValue $readiness "productionPatchValidated" $false) -and
    [bool](Get-JsonValue $readiness "productionRetestPassed" $false) -and
    [bool](Get-JsonValue $readiness "rollbackPlanGenerated" $false) -and
    [bool](Get-JsonValue $readiness "rollbackVerified" $false) -and
    -not [bool](Get-JsonValue $readiness "packageRepositoryMutated" $true) -and
    [bool](Get-JsonValue $readiness "sourceControlCleanAfterValidation" $false) -and
    [int](Get-JsonValue $readiness "productionChangedFileCount" 0) -gt 0 -and
    [int](Get-JsonValue $readiness "productionBeforeFindingCount" 0) -gt 0 -and
    [int](Get-JsonValue $readiness "productionAfterFindingCount" 1) -eq 0 -and
    [int](Get-JsonValue $readiness "productionAfterHighRiskFindingCount" 1) -eq 0 -and
    [int](Get-JsonValue $readiness "blockingReasonCount" 1) -eq 0 -and
    (Get-JsonValue $readiness "productionOutputBoundary" "") -eq "real_production_lua_patch_evidence_accepted" -and
    -not $fixtureOnly -and
    $realHostProjectEvidence

if (-not $readyForExport) {
    throw "Production Lua evidence export requires accepted real host-project evidence with fixtureOnly=false, realHostProjectEvidence=true, and zero readiness blockers. Current readiness: ready=$($readiness.readyForProductionLuaPatchRelease), accepted=$($readiness.productionLuaEvidenceAccepted), fixtureOnly=$fixtureOnly, realHostProjectEvidence=$realHostProjectEvidence, blockers=$($readiness.blockingReasonCount)."
}

if (Test-Path $outputPath) {
    Remove-Item -LiteralPath $outputPath -Recurse -Force
}
New-Item -ItemType Directory -Force $outputPath | Out-Null

foreach ($fileName in $requiredFiles) {
    Copy-Item -LiteralPath (Join-Path $productionLuaEvidencePath $fileName) -Destination (Join-Path $outputPath $fileName) -Force
}

New-Item -ItemType Directory -Force (Split-Path $zipFullPath -Parent) | Out-Null
if (Test-Path $zipFullPath) {
    Remove-Item -LiteralPath $zipFullPath -Force
}
Compress-Archive -LiteralPath $outputPath -DestinationPath $zipFullPath -Force

$manifestPath = Join-Path (Split-Path $outputPath -Parent) "production-lua-evidence-export-manifest.json"
$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_lua_patch_evidence_export.v1"
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    productionLuaEvidenceDir = $productionLuaEvidencePath
    outputDir = $outputPath
    zipPath = $zipFullPath
    readinessManifestPath = $readinessManifestPath
    readyForProductionLuaPatchRelease = [bool](Get-JsonValue $readiness "readyForProductionLuaPatchRelease" $false)
    productionLuaEvidenceAccepted = [bool](Get-JsonValue $readiness "productionLuaEvidenceAccepted" $false)
    realHostProjectEvidence = [bool]$realHostProjectEvidence
    fixtureOnly = [bool]$fixtureOnly
    realProductionLuaAnalyzed = [bool](Get-JsonValue $readiness "realProductionLuaAnalyzed" $false)
    realProductionLuaPatched = [bool](Get-JsonValue $readiness "realProductionLuaPatched" $false)
    productionPatchApplied = [bool](Get-JsonValue $readiness "productionPatchApplied" $false)
    productionPatchValidated = [bool](Get-JsonValue $readiness "productionPatchValidated" $false)
    productionRetestPassed = [bool](Get-JsonValue $readiness "productionRetestPassed" $false)
    rollbackPlanGenerated = [bool](Get-JsonValue $readiness "rollbackPlanGenerated" $false)
    rollbackVerified = [bool](Get-JsonValue $readiness "rollbackVerified" $false)
    packageRepositoryMutated = [bool](Get-JsonValue $readiness "packageRepositoryMutated" $false)
    sourceControlCleanAfterValidation = [bool](Get-JsonValue $readiness "sourceControlCleanAfterValidation" $false)
    productionChangedFileCount = [int](Get-JsonValue $readiness "productionChangedFileCount" 0)
    productionBeforeFindingCount = [int](Get-JsonValue $readiness "productionBeforeFindingCount" 0)
    productionAfterFindingCount = [int](Get-JsonValue $readiness "productionAfterFindingCount" 0)
    productionAfterHighRiskFindingCount = [int](Get-JsonValue $readiness "productionAfterHighRiskFindingCount" 0)
    blockingReasonCount = [int](Get-JsonValue $readiness "blockingReasonCount" 0)
    productionOutputBoundary = "real_production_lua_patch_evidence_exported"
    requiredFiles = @($requiredFiles)
    exportedFileCount = [int]$requiredFiles.Count
    productionEvidenceExported = $true
    productionEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
}
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

Write-Output "Production Lua evidence export: $outputPath"
Write-Output "Production Lua evidence export zip: $zipFullPath"
Write-Output "Production Lua evidence export manifest: $manifestPath"
Write-Output "PASS AI TestPilot production Lua evidence export"
'@

$evidencePath = Join-Path $outputPath "production-lua-patch-evidence.json"
$readmePath = Join-Path $outputPath "README.md"
$schemaPath = Join-Path $outputPath "production-lua-patch-evidence-schema.md"
$retestPath = Join-Path $outputPath "production-lua-patch-retest-template.md"
$rollbackPath = Join-Path $outputPath "production-lua-patch-rollback-plan-template.md"
$invokeScriptPath = Join-Path $outputPath "Invoke-ProductionLuaPatchEvidence.ps1"
$exportScriptPath = Join-Path $outputPath "Export-ProductionLuaPatchEvidenceBundle.ps1"

$invokeScript = $invokeScriptTemplate.Replace("__REPO_ROOT__", ($repoRoot -replace "\\", "\\"))
$exportScript = $exportScriptTemplate.Replace("__REPO_ROOT__", ($repoRoot -replace "\\", "\\"))

$evidence | ConvertTo-Json -Depth 10 | Set-Content -Path $evidencePath -Encoding UTF8
$readme | Set-Content -Path $readmePath -Encoding UTF8
$schema | Set-Content -Path $schemaPath -Encoding UTF8
$retest | Set-Content -Path $retestPath -Encoding UTF8
$rollback | Set-Content -Path $rollbackPath -Encoding UTF8
$invokeScript | Set-Content -Path $invokeScriptPath -Encoding UTF8
$exportScript | Set-Content -Path $exportScriptPath -Encoding UTF8

$generatedFiles = @(
    "README.md",
    "production-lua-patch-evidence.json",
    "production-lua-patch-evidence-schema.md",
    "production-lua-patch-retest-template.md",
    "production-lua-patch-rollback-plan-template.md",
    "Invoke-ProductionLuaPatchEvidence.ps1",
    "Export-ProductionLuaPatchEvidenceBundle.ps1",
    "production-lua-patch-evidence-kit-generated-manifest.json"
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_lua_patch_evidence_kit_generated.v1"
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    outputDir = $outputPath
    templateOnly = -not [bool]$GenerateAcceptedFixture
    acceptedFixtureGenerated = [bool]$GenerateAcceptedFixture
    acceptedFixtureBoundary = $fixtureBoundary
    realHostProjectEvidence = $false
    realProductionLuaPatchEvidenceAccepted = $false
    productionEvidenceAccepted = $false
    readyForProductionLuaPatchRelease = $false
    invokeHelperGenerated = $true
    exportHelperGenerated = $true
    exportHelperRequiresProductionLuaPatchedReadiness = $true
    exportHelperRequiresRealHostProjectEvidence = $true
    exportHelperRejectsTemplateEvidence = $true
    exportHelperRejectsFixtureEvidence = $true
    evidenceExportHelperPath = "Export-ProductionLuaPatchEvidenceBundle.ps1"
    evidenceExportHelperCommand = '.\Export-ProductionLuaPatchEvidenceBundle.ps1 -EvidenceBundleDir "path\to\release-evidence" -ProductionLuaEvidenceDir "path\to\production-lua-evidence"'
    evidenceExportOutputDir = "production-lua-evidence-export/production-lua-evidence"
    evidenceExportZipPath = "production-lua-evidence-export/production-lua-evidence.zip"
    evidenceExportManifestPath = "production-lua-evidence-export/production-lua-evidence-export-manifest.json"
    evidenceStatus = $evidenceStatus
    expectedBlockingReasonCount = [int]$expectedBlockingReasons.Count
    expectedBlockingReasons = @($expectedBlockingReasons)
    generatedFileCount = [int]$generatedFiles.Count
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles)
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

Write-Output "Production Lua patch evidence kit: $outputPath"
Write-Output "Production Lua patch evidence kit manifest: $manifestPath"
Write-Output "PASS AI TestPilot production Lua patch evidence kit"
