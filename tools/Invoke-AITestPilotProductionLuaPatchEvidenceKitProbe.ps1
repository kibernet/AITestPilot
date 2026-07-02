[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$KitDir,
    [string]$ProbeBundleDir,
    [string]$ManifestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Resolve-Path (Join-Path $PSScriptRoot "..")).Path)
$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($KitDir)) {
    $KitDir = Join-Path $EvidenceBundleDir "production-lua-patch-evidence-kit"
}

if ([string]::IsNullOrWhiteSpace($ProbeBundleDir)) {
    $ProbeBundleDir = Join-Path $repoRoot "Temp\release-evidence\production-lua-patch-evidence-kit-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-lua-patch-evidence-kit-probe-manifest.json"
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
    $fullRoot = Resolve-FullPath $Root
    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    if ($fullPath.Equals($fullRoot, $comparison)) {
        return $true
    }

    if (-not $fullRoot.EndsWith(([System.IO.Path]::DirectorySeparatorChar).ToString())) {
        $fullRoot = $fullRoot + [System.IO.Path]::DirectorySeparatorChar
    }

    return $fullPath.StartsWith($fullRoot, $comparison)
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

function Invoke-ExpectedFailure {
    param(
        [scriptblock]$Command,
        [string]$ExpectedMessage
    )

    try {
        & $Command | Out-Null
        return [pscustomobject]@{
            rejected = $false
            message = ""
            expectedMessageFound = $false
        }
    }
    catch {
        $message = $_.Exception.Message
        return [pscustomobject]@{
            rejected = $true
            message = $message
            expectedMessageFound = $message.Contains($ExpectedMessage)
        }
    }
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$kitPath = Assert-PathUnderRepo $KitDir "KitDir"
$probeBundlePath = Assert-PathUnderRepo $ProbeBundleDir "ProbeBundleDir"
$manifestPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if ($probeBundlePath -eq $evidenceBundlePath -or $probeBundlePath -eq $kitPath) {
    throw "ProbeBundleDir must be separate from EvidenceBundleDir and KitDir."
}

$requiredReadinessInputs = @(
    "lua-static-analysis-manifest.json",
    "lua-auto-patch-sandbox-manifest.json",
    "lua-auto-patch.patch",
    "lua-auto-patch-operations.json"
)

foreach ($fileName in $requiredReadinessInputs) {
    $sourcePath = Join-Path $evidenceBundlePath $fileName
    if (-not (Test-Path $sourcePath)) {
        throw "Evidence bundle is missing required Lua readiness input: $fileName"
    }
}

New-Item -ItemType Directory -Force $evidenceBundlePath | Out-Null

$generatedKitManifestPath = Join-Path $kitPath "production-lua-patch-evidence-kit-generated-manifest.json"

& (Join-Path $PSScriptRoot "New-AITestPilotProductionLuaPatchEvidenceKit.ps1") `
    -OutputDir $kitPath `
    -ManifestPath $generatedKitManifestPath

if (Test-Path $probeBundlePath) {
    Remove-Item -LiteralPath $probeBundlePath -Recurse -Force
}

New-Item -ItemType Directory -Force $probeBundlePath | Out-Null

$acceptedEvidenceDir = Join-Path $probeBundlePath "accepted-fixture-evidence"
$acceptedGeneratedManifestPath = Join-Path $acceptedEvidenceDir "production-lua-patch-evidence-kit-generated-manifest.json"

& (Join-Path $PSScriptRoot "New-AITestPilotProductionLuaPatchEvidenceKit.ps1") `
    -OutputDir $acceptedEvidenceDir `
    -ManifestPath $acceptedGeneratedManifestPath `
    -GenerateAcceptedFixture

$acceptedReadinessBundleDir = Join-Path $probeBundlePath "accepted-readiness-bundle"
New-Item -ItemType Directory -Force $acceptedReadinessBundleDir | Out-Null
foreach ($fileName in $requiredReadinessInputs) {
    Copy-Item -LiteralPath (Join-Path $evidenceBundlePath $fileName) -Destination (Join-Path $acceptedReadinessBundleDir $fileName) -Force
}

$acceptedReadinessManifestPath = Join-Path $acceptedReadinessBundleDir "production-lua-patch-readiness-manifest.json"
& (Join-Path $PSScriptRoot "Invoke-AITestPilotProductionLuaPatchReadiness.ps1") `
    -EvidenceBundleDir $acceptedReadinessBundleDir `
    -ManifestPath $acceptedReadinessManifestPath `
    -ProductionLuaEvidenceDir $acceptedEvidenceDir `
    -RequireProductionLuaPatched

$generatedManifest = Read-JsonFile $generatedKitManifestPath "Generated production Lua patch evidence kit manifest"
$templateEvidence = Read-JsonFile (Join-Path $kitPath "production-lua-patch-evidence.json") "Template production Lua patch evidence"
$acceptedGeneratedManifest = Read-JsonFile $acceptedGeneratedManifestPath "Accepted fixture kit manifest"
$acceptedEvidence = Read-JsonFile (Join-Path $acceptedEvidenceDir "production-lua-patch-evidence.json") "Accepted fixture production Lua patch evidence"
$acceptedReadiness = Read-JsonFile $acceptedReadinessManifestPath "Accepted fixture production Lua readiness manifest"

$relativeKitDir = "production-lua-patch-evidence-kit"
$generatedFiles = @(
    "$relativeKitDir/README.md",
    "$relativeKitDir/production-lua-patch-evidence.json",
    "$relativeKitDir/production-lua-patch-evidence-schema.md",
    "$relativeKitDir/production-lua-patch-retest-template.md",
    "$relativeKitDir/production-lua-patch-rollback-plan-template.md",
    "$relativeKitDir/Invoke-ProductionLuaPatchEvidence.ps1",
    "$relativeKitDir/Export-ProductionLuaPatchEvidenceBundle.ps1",
    "$relativeKitDir/production-lua-patch-evidence-kit-generated-manifest.json"
)

foreach ($fileName in $generatedFiles) {
    $path = Join-Path $evidenceBundlePath ($fileName -replace "/", "\")
    if (-not (Test-Path $path)) {
        throw "Production Lua patch evidence kit file is missing: $fileName"
    }
}

$copiedAcceptedReadinessName = "production-lua-patch-evidence-kit-accepted-readiness-manifest.json"
Copy-Item -LiteralPath $acceptedReadinessManifestPath -Destination (Join-Path $evidenceBundlePath $copiedAcceptedReadinessName) -Force

$templateExportOutputDir = Join-Path $evidenceBundlePath "production-lua-evidence-export\template-rejection\production-lua-evidence"
$templateExportZipPath = Join-Path $evidenceBundlePath "production-lua-evidence-export\template-rejection\production-lua-evidence.zip"
$templateExportReadinessPath = Join-Path (Split-Path $templateExportOutputDir -Parent) "production-lua-patch-readiness-for-export.json"
$templateExportSucceeded = $false
$templateExportMessage = ""
try {
    & (Join-Path $kitPath "Export-ProductionLuaPatchEvidenceBundle.ps1") `
        -EvidenceBundleDir $evidenceBundlePath `
        -ProductionLuaEvidenceDir $kitPath `
        -OutputDir $templateExportOutputDir `
        -ZipPath $templateExportZipPath | Out-Null
    $templateExportSucceeded = $true
}
catch {
    $templateExportMessage = $_.Exception.Message
}

$acceptedFixtureExportOutputDir = Join-Path $acceptedReadinessBundleDir "production-lua-evidence-export\accepted-fixture-rejection\production-lua-evidence"
$acceptedFixtureExportZipPath = Join-Path $acceptedReadinessBundleDir "production-lua-evidence-export\accepted-fixture-rejection\production-lua-evidence.zip"
$acceptedFixtureExportSucceeded = $false
$acceptedFixtureExportMessage = ""
try {
    & (Join-Path $acceptedEvidenceDir "Export-ProductionLuaPatchEvidenceBundle.ps1") `
        -EvidenceBundleDir $acceptedReadinessBundleDir `
        -ProductionLuaEvidenceDir $acceptedEvidenceDir `
        -OutputDir $acceptedFixtureExportOutputDir `
        -ZipPath $acceptedFixtureExportZipPath | Out-Null
    $acceptedFixtureExportSucceeded = $true
}
catch {
    $acceptedFixtureExportMessage = $_.Exception.Message
}

$templateExportReadiness = if (Test-Path $templateExportReadinessPath) {
    Read-JsonFile $templateExportReadinessPath "Template export rejection readiness manifest"
} else {
    $null
}

$generatorOutputDirBoundary = Invoke-ExpectedFailure `
    -ExpectedMessage "OutputDir must stay under repo root unless -AllowExternalOutput" `
    -Command {
        & (Join-Path $PSScriptRoot "New-AITestPilotProductionLuaPatchEvidenceKit.ps1") `
            -OutputDir (Join-Path $tempRoot "AITestPilot\lua-kit-boundary-probe\external-output") `
            -ManifestPath (Join-Path $tempRoot "AITestPilot\lua-kit-boundary-probe\external-output\production-lua-patch-evidence-kit-generated-manifest.json")
    }
$generatorManifestPathBoundary = Invoke-ExpectedFailure `
    -ExpectedMessage "ManifestPath must stay under allowed root" `
    -Command {
        & (Join-Path $PSScriptRoot "New-AITestPilotProductionLuaPatchEvidenceKit.ps1") `
            -OutputDir (Join-Path $probeBundlePath "manifest-boundary-output") `
            -ManifestPath (Join-Path $probeBundlePath "manifest-escape.json")
    }
$exportHelperOutputDirBoundary = Invoke-ExpectedFailure `
    -ExpectedMessage "OutputDir must stay under" `
    -Command {
        & (Join-Path $kitPath "Export-ProductionLuaPatchEvidenceBundle.ps1") `
            -EvidenceBundleDir $evidenceBundlePath `
            -ProductionLuaEvidenceDir $kitPath `
            -OutputDir (Join-Path $probeBundlePath "export-output-escape\production-lua-evidence") `
            -ZipPath (Join-Path $evidenceBundlePath "production-lua-evidence-export\output-boundary\production-lua-evidence.zip")
    }
$exportHelperZipPathBoundary = Invoke-ExpectedFailure `
    -ExpectedMessage "ZipPath must stay under" `
    -Command {
        & (Join-Path $kitPath "Export-ProductionLuaPatchEvidenceBundle.ps1") `
            -EvidenceBundleDir $evidenceBundlePath `
            -ProductionLuaEvidenceDir $kitPath `
            -OutputDir (Join-Path $evidenceBundlePath "production-lua-evidence-export\zip-boundary\production-lua-evidence") `
            -ZipPath (Join-Path $probeBundlePath "zip-escape.zip")
    }

$checks = @()

$templateKitValid = $generatedManifest.status -eq "PASS" -and
    $generatedManifest.schemaVersion -eq "aitestpilot.production_lua_patch_evidence_kit_generated.v1" -and
    [bool]$generatedManifest.templateOnly -and
    -not [bool]$generatedManifest.acceptedFixtureGenerated -and
    -not [bool]$generatedManifest.realHostProjectEvidence -and
    -not [bool]$generatedManifest.productionEvidenceAccepted -and
    -not [bool]$generatedManifest.readyForProductionLuaPatchRelease -and
    [bool]$generatedManifest.invokeHelperGenerated -and
    [bool]$generatedManifest.exportHelperGenerated -and
    [bool]$generatedManifest.exportHelperRequiresProductionLuaPatchedReadiness -and
    [bool]$generatedManifest.exportHelperRequiresRealHostProjectEvidence -and
    [bool]$generatedManifest.exportHelperRejectsTemplateEvidence -and
    [bool]$generatedManifest.exportHelperRejectsFixtureEvidence

$templateEvidenceBoundaryValid = $templateEvidence.schemaVersion -eq "aitestpilot.production_lua_patch_evidence.v1" -and
    $templateEvidence.status -eq "PENDING_PRODUCTION_EVIDENCE" -and
    -not [bool]$templateEvidence.fixtureOnly -and
    -not [bool]$templateEvidence.realHostProjectEvidence -and
    -not [bool]$templateEvidence.realProductionLuaAnalyzed -and
    -not [bool]$templateEvidence.realProductionLuaPatched -and
    [int]$templateEvidence.blockingReasonCount -eq 5

$acceptedFixtureValid = $acceptedGeneratedManifest.status -eq "PASS" -and
    [bool]$acceptedGeneratedManifest.acceptedFixtureGenerated -and
    $acceptedEvidence.schemaVersion -eq "aitestpilot.production_lua_patch_evidence.v1" -and
    $acceptedEvidence.status -eq "PASS" -and
    [bool]$acceptedEvidence.fixtureOnly -and
    -not [bool]$acceptedEvidence.realHostProjectEvidence -and
    $acceptedEvidence.fixtureBoundary -eq "contract_fixture_only_not_real_host_project" -and
    [bool]$acceptedEvidence.realProductionLuaAnalyzed -and
    [bool]$acceptedEvidence.realProductionLuaPatched -and
    [bool]$acceptedEvidence.productionPatchApplied -and
    [bool]$acceptedEvidence.productionPatchValidated -and
    [bool]$acceptedEvidence.productionRetestPassed -and
    [bool]$acceptedEvidence.rollbackVerified -and
    [int]$acceptedEvidence.changedFileCount -gt 0 -and
    [int]$acceptedEvidence.beforeFindingCount -gt 0 -and
    [int]$acceptedEvidence.afterFindingCount -eq 0 -and
    [int]$acceptedEvidence.afterHighRiskFindingCount -eq 0 -and
    [int]$acceptedEvidence.blockingReasonCount -eq 0

$acceptedReadinessPassed = $acceptedReadiness.status -eq "PASS" -and
    $acceptedReadiness.schemaVersion -eq "aitestpilot.production_lua_patch_readiness.v1" -and
    [bool]$acceptedReadiness.requireProductionLuaPatched -and
    [bool]$acceptedReadiness.readyForProductionLuaPatchRelease -and
    [bool]$acceptedReadiness.productionLuaBundleProvided -and
    [bool]$acceptedReadiness.productionLuaEvidenceAccepted -and
    [bool]$acceptedReadiness.productionLuaEvidenceCopied -and
    [bool]$acceptedReadiness.staticAnalysisPassed -and
    [bool]$acceptedReadiness.sandboxAfterFindingsCleared -and
    [bool]$acceptedReadiness.sandboxBoundaryPreserved -and
    [bool]$acceptedReadiness.realProductionLuaAnalyzed -and
    [bool]$acceptedReadiness.realProductionLuaPatched -and
    [bool]$acceptedReadiness.productionPatchApplied -and
    [bool]$acceptedReadiness.productionPatchValidated -and
    [bool]$acceptedReadiness.productionRetestPassed -and
    [bool]$acceptedReadiness.rollbackPlanGenerated -and
    [bool]$acceptedReadiness.rollbackVerified -and
    -not [bool]$acceptedReadiness.packageRepositoryMutated -and
    [bool]$acceptedReadiness.sourceControlCleanAfterValidation -and
    [int]$acceptedReadiness.productionChangedFileCount -gt 0 -and
    [int]$acceptedReadiness.productionBeforeFindingCount -gt 0 -and
    [int]$acceptedReadiness.productionAfterFindingCount -eq 0 -and
    [int]$acceptedReadiness.productionAfterHighRiskFindingCount -eq 0 -and
    [int]$acceptedReadiness.blockingReasonCount -eq 0 -and
    $acceptedReadiness.productionOutputBoundary -eq "real_production_lua_patch_evidence_accepted"

$exportHelperBoundaryValid = [bool]$generatedManifest.exportHelperGenerated -and
    ([string]$generatedManifest.evidenceExportHelperCommand).Contains("Export-ProductionLuaPatchEvidenceBundle.ps1") -and
    -not [bool]$templateExportSucceeded -and
    $null -ne $templateExportReadiness -and
    -not [bool]$templateExportReadiness.readyForProductionLuaPatchRelease -and
    -not [bool]$templateExportReadiness.productionLuaEvidenceAccepted -and
    [int]$templateExportReadiness.blockingReasonCount -ge 4 -and
    [int]$templateExportReadiness.productionEvidenceBlockingReasonCount -ge 5 -and
    $templateExportReadiness.productionOutputBoundary -eq "real_production_lua_patch_not_claimed" -and
    -not [bool]$acceptedFixtureExportSucceeded -and
    $acceptedFixtureExportMessage.Contains("realHostProjectEvidence=true")

$pathBoundaryRejected = [bool]$generatorOutputDirBoundary.rejected -and
    [bool]$generatorOutputDirBoundary.expectedMessageFound -and
    [bool]$generatorManifestPathBoundary.rejected -and
    [bool]$generatorManifestPathBoundary.expectedMessageFound -and
    [bool]$exportHelperOutputDirBoundary.rejected -and
    [bool]$exportHelperOutputDirBoundary.expectedMessageFound -and
    [bool]$exportHelperZipPathBoundary.rejected -and
    [bool]$exportHelperZipPathBoundary.expectedMessageFound

Add-ProbeCheck "template_kit_generated" $templateKitValid "Template kit must generate without claiming real production evidence."
Add-ProbeCheck "template_evidence_boundary" $templateEvidenceBoundaryValid "Default evidence JSON must remain pending and blocked."
Add-ProbeCheck "accepted_fixture_generated" $acceptedFixtureValid "Accepted fixture must satisfy the readiness contract while marking itself as fixture-only."
Add-ProbeCheck "accepted_fixture_readiness" $acceptedReadinessPassed "Readiness must accept the isolated fixture only inside the contract probe bundle."
Add-ProbeCheck "export_helper_boundary" $exportHelperBoundaryValid "Export helper must reject template evidence and contract fixtures before packaging Lua evidence."
Add-ProbeCheck "path_boundary" $pathBoundaryRejected "Generator and export helper must reject unmanaged output, manifest, and zip paths before writing."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$files = @($generatedFiles + $copiedAcceptedReadinessName)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_lua_patch_evidence_kit_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    kitDir = $kitPath
    probeBundleDir = $probeBundlePath
    templateKitGenerated = [bool]$templateKitValid
    templateOnly = $true
    templateEvidenceStatus = $templateEvidence.status
    templateEvidenceAccepted = $false
    acceptedFixtureGenerated = [bool]$acceptedFixtureValid
    acceptedFixtureProbePassed = [bool]$acceptedReadinessPassed
    acceptedFixtureBoundary = "contract_fixture_only_not_real_host_project"
    releasePipelineUsesFixture = $false
    realHostProjectEvidence = $false
    realProductionLuaPatchEvidenceAccepted = $false
    productionLuaEvidenceDirRequiredForProduction = $true
    exportHelperGenerated = [bool]$generatedManifest.exportHelperGenerated
    exportHelperRequiresProductionLuaPatchedReadiness = [bool]$generatedManifest.exportHelperRequiresProductionLuaPatchedReadiness
    exportHelperRequiresRealHostProjectEvidence = [bool]$generatedManifest.exportHelperRequiresRealHostProjectEvidence
    exportHelperRejectedTemplateEvidence = -not [bool]$templateExportSucceeded
    exportHelperRejectedFixtureEvidence = -not [bool]$acceptedFixtureExportSucceeded
    exportRejectionReadinessRejectedCurrentTemplate = ($null -ne $templateExportReadiness -and -not [bool]$templateExportReadiness.readyForProductionLuaPatchRelease)
    exportRejectionBlockingReasonCount = if ($null -ne $templateExportReadiness) { [int]$templateExportReadiness.blockingReasonCount } else { 0 }
    exportRejectionProductionEvidenceBlockingReasonCount = if ($null -ne $templateExportReadiness) { [int]$templateExportReadiness.productionEvidenceBlockingReasonCount } else { 0 }
    exportRejectionMessage = $templateExportMessage
    exportFixtureRejectionMessage = $acceptedFixtureExportMessage
    generatorOutputDirBoundaryRejected = [bool]$generatorOutputDirBoundary.rejected
    generatorOutputDirBoundaryMessage = $generatorOutputDirBoundary.message
    generatorManifestPathBoundaryRejected = [bool]$generatorManifestPathBoundary.rejected
    generatorManifestPathBoundaryMessage = $generatorManifestPathBoundary.message
    exportHelperOutputDirBoundaryRejected = [bool]$exportHelperOutputDirBoundary.rejected
    exportHelperOutputDirBoundaryMessage = $exportHelperOutputDirBoundary.message
    exportHelperZipPathBoundaryRejected = [bool]$exportHelperZipPathBoundary.rejected
    exportHelperZipPathBoundaryMessage = $exportHelperZipPathBoundary.message
    pathBoundaryRejected = [bool]$pathBoundaryRejected
    productionOutputBoundary = "production_lua_patch_evidence_kit_probe_only"
    evidenceExportHelperCommand = [string]$generatedManifest.evidenceExportHelperCommand
    evidenceExportZipPath = [string]$generatedManifest.evidenceExportZipPath
    acceptedReadinessReady = [bool]$acceptedReadiness.readyForProductionLuaPatchRelease
    acceptedReadinessEvidenceAccepted = [bool]$acceptedReadiness.productionLuaEvidenceAccepted
    acceptedReadinessBlockingReasonCount = [int]$acceptedReadiness.blockingReasonCount
    acceptedReadinessManifest = $copiedAcceptedReadinessName
    generatedFileCount = [int]$generatedFiles.Count
    generatedFiles = @($generatedFiles)
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
    files = @($files)
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Production Lua patch evidence kit probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production Lua patch evidence kit probe manifest: $manifestPath"
Write-Output "PASS AI TestPilot production Lua patch evidence kit probe"
