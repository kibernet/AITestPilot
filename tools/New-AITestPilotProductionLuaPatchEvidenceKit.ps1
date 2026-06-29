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

## Required command

After filling the JSON from the real host-project Lua patch run, validate it with:

```powershell
.\tools\Invoke-AITestPilotProductionLuaPatchReadiness.ps1 -EvidenceBundleDir "path\to\release-evidence" -ProductionLuaEvidenceDir "path\to\production-lua-evidence" -RequireProductionLuaPatched
```

For a full release pipeline run, pass the same directory:

```powershell
.\tools\Invoke-AITestPilotReleasePipeline.ps1 -ProductionLuaEvidenceDir "path\to\production-lua-evidence" -RequireProductionLuaPatched
```

Do not mark `realHostProjectEvidence=true` or remove the blocking reasons until the real production Lua tree has been analyzed, patched, retested, rolled back, and source-control cleanliness has been verified.
'@

$schema = @'
# Production Lua Patch Evidence Schema

The file name must be `production-lua-patch-evidence.json`.

Required accepted values:

- `schemaVersion`: `aitestpilot.production_lua_patch_evidence.v1`
- `status`: `PASS`
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

$evidencePath = Join-Path $outputPath "production-lua-patch-evidence.json"
$readmePath = Join-Path $outputPath "README.md"
$schemaPath = Join-Path $outputPath "production-lua-patch-evidence-schema.md"
$retestPath = Join-Path $outputPath "production-lua-patch-retest-template.md"
$rollbackPath = Join-Path $outputPath "production-lua-patch-rollback-plan-template.md"

$evidence | ConvertTo-Json -Depth 10 | Set-Content -Path $evidencePath -Encoding UTF8
$readme | Set-Content -Path $readmePath -Encoding UTF8
$schema | Set-Content -Path $schemaPath -Encoding UTF8
$retest | Set-Content -Path $retestPath -Encoding UTF8
$rollback | Set-Content -Path $rollbackPath -Encoding UTF8

$generatedFiles = @(
    "README.md",
    "production-lua-patch-evidence.json",
    "production-lua-patch-evidence-schema.md",
    "production-lua-patch-retest-template.md",
    "production-lua-patch-rollback-plan-template.md",
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
