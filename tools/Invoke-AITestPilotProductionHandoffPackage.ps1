[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$PackageDir,
    [string]$ManifestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($PackageDir)) {
    $PackageDir = Join-Path $EvidenceBundleDir "production-handoff-package"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-handoff-package-manifest.json"
}

function Resolve-FullPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
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
        [string]$FileName,
        [string]$Label
    )

    $path = Join-Path $script:evidenceBundlePath $FileName
    if (-not (Test-Path $path)) {
        throw "$Label is missing: $path"
    }

    return Get-Content -Path $path -Encoding UTF8 -Raw | ConvertFrom-Json
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

function Convert-ToArray {
    param([object]$Value)

    if ($null -eq $Value) {
        return @()
    }

    return @($Value)
}

function Add-HandoffCheck {
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

function Join-MarkdownList {
    param([object[]]$Items)

    if ($null -eq $Items -or $Items.Count -eq 0) {
        return "none"
    }

    return ($Items | ForEach-Object { [string]$_ }) -join ", "
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$packagePath = Assert-PathUnderRepo $PackageDir "PackageDir"
$manifestPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if (Test-Path $packagePath) {
    Remove-Item -LiteralPath $packagePath -Recurse -Force
}

New-Item -ItemType Directory -Force $packagePath | Out-Null

$sourceManifests = @(
    "production-replay-driver-readiness-manifest.json",
    "production-driver-binding-kit-manifest.json",
    "production-driver-evidence-contract-probe-manifest.json",
    "production-driver-external-bundle-intake-probe-manifest.json",
    "production-lua-patch-readiness-manifest.json",
    "production-lua-patch-evidence-kit-probe-manifest.json",
    "production-lua-patch-external-bundle-intake-probe-manifest.json",
    "live-model-endpoint-config-kit-probe-manifest.json",
    "live-model-endpoint-external-smoke-intake-probe-manifest.json",
    "live-model-endpoint-smoke-evidence-contract-probe-manifest.json",
    "github-actions-release-workflow-probe-manifest.json",
    "azure-pipelines-release-workflow-probe-manifest.json",
    "provider-ci-quality-probe-manifest.json"
)

$driverReadiness = Read-JsonFile "production-replay-driver-readiness-manifest.json" "Production driver readiness manifest"
$driverKit = Read-JsonFile "production-driver-binding-kit-manifest.json" "Production driver binding kit manifest"
$driverContract = Read-JsonFile "production-driver-evidence-contract-probe-manifest.json" "Production driver evidence contract probe manifest"
$driverExternalIntake = Read-JsonFile "production-driver-external-bundle-intake-probe-manifest.json" "Production driver external bundle intake probe manifest"
$luaReadiness = Read-JsonFile "production-lua-patch-readiness-manifest.json" "Production Lua patch readiness manifest"
$luaKit = Read-JsonFile "production-lua-patch-evidence-kit-probe-manifest.json" "Production Lua patch evidence kit probe manifest"
$luaExternalIntake = Read-JsonFile "production-lua-patch-external-bundle-intake-probe-manifest.json" "Production Lua external bundle intake probe manifest"
$liveConfigKit = Read-JsonFile "live-model-endpoint-config-kit-probe-manifest.json" "Live model endpoint config kit probe manifest"
$liveExternalSmoke = Read-JsonFile "live-model-endpoint-external-smoke-intake-probe-manifest.json" "Live model endpoint external smoke intake probe manifest"
$liveSmokeEvidenceContract = Read-JsonFile "live-model-endpoint-smoke-evidence-contract-probe-manifest.json" "Live model endpoint smoke evidence contract probe manifest"
$githubWorkflow = Read-JsonFile "github-actions-release-workflow-probe-manifest.json" "GitHub Actions release workflow probe manifest"
$azureWorkflow = Read-JsonFile "azure-pipelines-release-workflow-probe-manifest.json" "Azure Pipelines release workflow probe manifest"
$providerQuality = Read-JsonFile "provider-ci-quality-probe-manifest.json" "Provider CI quality probe manifest"

$driverBlockingReasons = Convert-ToArray (Get-JsonValue $driverReadiness "blockingReasons" $null)
$luaBlockingReasons = Convert-ToArray (Get-JsonValue $luaReadiness "blockingReasons" $null)
$liveBlockingReasons = @("real_live_model_endpoint_smoke_missing")

$productionDriverReady = [bool](Get-JsonValue $driverReadiness "readyForProductionDriverRelease" $false)
$productionLuaReady = [bool](Get-JsonValue $luaReadiness "readyForProductionLuaPatchRelease" $false)
$liveModelAccessProven = [bool](Get-JsonValue $liveExternalSmoke "productionLiveEndpointAccessProven" $false)

$driverHandoffReady = $driverKit.status -eq "PASS" -and
    [bool](Get-JsonValue $driverKit "kitGenerated" $false) -and
    [bool](Get-JsonValue $driverKit "hostValidationScriptIncludesProductionBoundIntake" $false) -and
    [bool](Get-JsonValue $driverKit "generatedKitOnly" $false) -and
    -not [bool](Get-JsonValue $driverKit "productionEvidenceAccepted" $true) -and
    $driverContract.status -eq "PASS" -and
    [bool](Get-JsonValue $driverContract "acceptedFixtureIntakePassed" $false) -and
    [bool](Get-JsonValue $driverContract "acceptedFixtureReadinessPassed" $false) -and
    -not [bool](Get-JsonValue $driverContract "releasePipelineUsesFixture" $true) -and
    -not [bool](Get-JsonValue $driverContract "realProductionDriverEvidenceAccepted" $true) -and
    $driverExternalIntake.status -eq "PASS" -and
    -not [bool](Get-JsonValue $driverExternalIntake "externalBundleUnderRepo" $true) -and
    [bool](Get-JsonValue $driverExternalIntake "expectedBlockedPassed" $false)

$luaHandoffReady = $luaKit.status -eq "PASS" -and
    [bool](Get-JsonValue $luaKit "templateKitGenerated" $false) -and
    [bool](Get-JsonValue $luaKit "acceptedFixtureProbePassed" $false) -and
    -not [bool](Get-JsonValue $luaKit "releasePipelineUsesFixture" $true) -and
    -not [bool](Get-JsonValue $luaKit "realProductionLuaPatchEvidenceAccepted" $true) -and
    [bool](Get-JsonValue $luaKit "productionLuaEvidenceDirRequiredForProduction" $false) -and
    $luaExternalIntake.status -eq "PASS" -and
    -not [bool](Get-JsonValue $luaExternalIntake "externalBundleUnderRepo" $true) -and
    [bool](Get-JsonValue $luaExternalIntake "expectedBlockedPassed" $false)

$liveModelHandoffReady = $liveConfigKit.status -eq "PASS" -and
    [bool](Get-JsonValue $liveConfigKit "templateKitGenerated" $false) -and
    [bool](Get-JsonValue $liveConfigKit "acceptedFixtureIntakePassed" $false) -and
    [bool](Get-JsonValue $liveConfigKit "acceptedFixtureReadyForLiveEndpointSmoke" $false) -and
    -not [bool](Get-JsonValue $liveConfigKit "productionLiveEndpointAccessProven" $true) -and
    -not [bool](Get-JsonValue $liveConfigKit "secretsSerialized" $true) -and
    $liveExternalSmoke.status -eq "PASS" -and
    -not [bool](Get-JsonValue $liveExternalSmoke "externalBundleUnderRepo" $true) -and
    [bool](Get-JsonValue $liveExternalSmoke "expectedBlockedPassed" $false) -and
    $liveSmokeEvidenceContract.status -eq "PASS" -and
    -not [bool](Get-JsonValue $liveSmokeEvidenceContract "externalBundleUnderRepo" $true) -and
    [bool](Get-JsonValue $liveSmokeEvidenceContract "acceptedFixtureIntakePassed" $false) -and
    [bool](Get-JsonValue $liveSmokeEvidenceContract "acceptedFixtureSmokeEvidenceAccepted" $false) -and
    [bool](Get-JsonValue $liveSmokeEvidenceContract "acceptedFixtureCanonicalSmokePromoted" $false) -and
    [bool](Get-JsonValue $liveSmokeEvidenceContract "acceptedFixtureCanonicalTracePromoted" $false) -and
    -not [bool](Get-JsonValue $liveSmokeEvidenceContract "releasePipelineUsesFixture" $true) -and
    -not [bool](Get-JsonValue $liveSmokeEvidenceContract "realProductionLiveEndpointAccessProven" $true)

$ciReleaseControlsReady = $githubWorkflow.status -eq "PASS" -and
    $azureWorkflow.status -eq "PASS" -and
    $providerQuality.status -eq "PASS" -and
    [bool](Get-JsonValue $providerQuality "providerQualityAccepted" $false) -and
    [bool](Get-JsonValue $providerQuality "githubActionsQualityAccepted" $false) -and
    [bool](Get-JsonValue $providerQuality "azurePipelinesQualityAccepted" $false)

$driverRequiredEvidence = @(
    "production-replay-integration-checklist.json",
    "repair-retest-manifest.json",
    "repair-driver-failure-manifest.json",
    "replay-profile-import-manifest.json"
)

$luaRequiredEvidence = @(
    "production-lua-patch-evidence.json",
    "production-lua-patch-retest-template.md",
    "production-lua-patch-rollback-plan-template.md"
)

$liveRequiredEvidence = @(
    "live-model-endpoint-smoke-manifest.json",
    "live-model-endpoint-decision-trace.json"
)

$actionItems = @()
if (-not $productionDriverReady) {
    $actionItems += [ordered]@{
        id = "production_driver_binding"
        status = "PENDING_HOST_PROJECT"
        owner = "host_project_gameplay_qa"
        remainingBlockingReasonCount = [int]$driverBlockingReasons.Count
        remainingBlockingReasons = @($driverBlockingReasons)
        kitPath = "production-driver-binding-kit"
        requiredEvidenceFiles = @($driverRequiredEvidence)
        validationCommand = '.\tools\Invoke-AITestPilotReleasePipeline.ps1 -GameReplayDriverType "Your.Game.Tests.ProductionReplayDriver" -RequireProductionReplayDriverBound'
    }
}

if (-not $productionLuaReady) {
    $actionItems += [ordered]@{
        id = "production_lua_patch_evidence"
        status = "PENDING_HOST_PROJECT"
        owner = "host_project_lua_owner"
        remainingBlockingReasonCount = [int]$luaBlockingReasons.Count
        remainingBlockingReasons = @($luaBlockingReasons)
        kitPath = "production-lua-patch-evidence-kit"
        requiredEvidenceFiles = @($luaRequiredEvidence)
        validationCommand = '.\tools\Invoke-AITestPilotReleasePipeline.ps1 -ProductionLuaEvidenceDir "path\to\production-lua-evidence" -RequireProductionLuaPatched'
    }
}

if (-not $liveModelAccessProven) {
    $actionItems += [ordered]@{
        id = "live_model_endpoint_smoke"
        status = "PENDING_PROVIDER_ACCESS"
        owner = "host_project_ai_platform"
        remainingBlockingReasonCount = [int]$liveBlockingReasons.Count
        remainingBlockingReasons = @($liveBlockingReasons)
        kitPath = "live-model-endpoint-config-kit"
        requiredEvidenceFiles = @($liveRequiredEvidence)
        validationCommand = '.\tools\Invoke-AITestPilotReleasePipeline.ps1 -RequireLiveModelEndpointSmoke -LiveModelEndpointSmokeEvidenceDir "path\to\live-smoke-evidence"'
    }
}

$requiredEvidence = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_required_evidence.v1"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    productionDriver = [ordered]@{
        ready = [bool]$productionDriverReady
        handoffPathReady = [bool]$driverHandoffReady
        requiredFiles = @($driverRequiredEvidence)
        kitPath = "production-driver-binding-kit"
        intakeCommand = '.\tools\Invoke-AITestPilotProductionDriverEvidenceIntake.ps1 -EvidenceBundleDir "path\to\release-evidence"'
        releaseCommand = '.\tools\Invoke-AITestPilotReleasePipeline.ps1 -GameReplayDriverType "Your.Game.Tests.ProductionReplayDriver" -RequireProductionReplayDriverBound'
    }
    productionLuaPatch = [ordered]@{
        ready = [bool]$productionLuaReady
        handoffPathReady = [bool]$luaHandoffReady
        requiredFiles = @($luaRequiredEvidence)
        kitPath = "production-lua-patch-evidence-kit"
        readinessCommand = '.\tools\Invoke-AITestPilotProductionLuaPatchReadiness.ps1 -ProductionLuaEvidenceDir "path\to\production-lua-evidence" -RequireProductionLuaPatched'
        releaseCommand = '.\tools\Invoke-AITestPilotReleasePipeline.ps1 -ProductionLuaEvidenceDir "path\to\production-lua-evidence" -RequireProductionLuaPatched'
    }
    liveModelEndpoint = [ordered]@{
        ready = [bool]$liveModelAccessProven
        handoffPathReady = [bool]$liveModelHandoffReady
        requiredFiles = @($liveRequiredEvidence)
        kitPath = "live-model-endpoint-config-kit"
        releaseCommand = '.\tools\Invoke-AITestPilotReleasePipeline.ps1 -RequireLiveModelEndpointSmoke -LiveModelEndpointSmokeEvidenceDir "path\to\live-smoke-evidence"'
    }
}

$readme = @"
# AI TestPilot Production Handoff Package

This package is the host-project handoff entry point generated from release evidence. It does not promote fixture evidence as production evidence.

## Current Status

- Production driver ready: $productionDriverReady
- Production driver blockers: $(Join-MarkdownList $driverBlockingReasons)
- Production Lua patch ready: $productionLuaReady
- Production Lua blockers: $(Join-MarkdownList $luaBlockingReasons)
- Live model endpoint access proven: $liveModelAccessProven
- CI release controls ready: $ciReleaseControlsReady

## Files

- ``action-plan.md``: owner-facing next steps for the remaining host-project work.
- ``required-external-evidence.json``: machine-readable evidence contract for driver, Lua, and live model completion.
- ``ci-commands.ps1``: copyable release-pipeline commands for hard production enforcement.

Keep this package with the release evidence bundle so external host-project owners can generate the missing evidence and feed it back through the same intake commands.
"@

$actionPlanLines = @(
    "# Production Handoff Action Plan",
    "",
    "| Area | Owner | Status | Remaining blockers | Kit | Required evidence | Hard validation command |",
    "| --- | --- | --- | --- | --- | --- | --- |"
)

foreach ($item in $actionItems) {
    $area = [string]$item["id"]
    $owner = [string]$item["owner"]
    $itemStatus = [string]$item["status"]
    $blockers = Join-MarkdownList @(Convert-ToArray $item["remainingBlockingReasons"])
    $kitPath = [string]$item["kitPath"]
    $requiredFiles = Join-MarkdownList @(Convert-ToArray $item["requiredEvidenceFiles"])
    $validationCommand = [string]$item["validationCommand"]
    $actionPlanLines += "| $area | $owner | $itemStatus | $blockers | " + '`' + $kitPath + '`' + " | $requiredFiles | " + '`' + $validationCommand + '`' + " |"
}

if ($actionItems.Count -eq 0) {
    $actionPlanLines += "| production_handoff | n/a | DONE | none | n/a | n/a | n/a |"
}

$actionPlanLines += @(
    "",
    "## Evidence Boundaries",
    "",
    "- Fixture contracts prove acceptance schemas only; they are not promoted as real host-project evidence.",
    "- Production driver completion requires a non-sample driver type, BOUND checklist, retest, failure-probe, and profile-import evidence.",
    "- Production Lua completion requires real Lua analysis, patch, validation, retest, rollback, and clean source-control evidence.",
    "- Live model completion requires a real PASS smoke manifest and decision trace from the selected provider."
)

$ciCommands = @'
# AI TestPilot hard production validation commands.
# Replace placeholder paths/types with host-project values before running.

.\tools\Invoke-AITestPilotReleasePipeline.ps1 `
    -GameReplayDriverType "Your.Game.Tests.ProductionReplayDriver" `
    -RequireProductionReplayDriverBound

.\tools\Invoke-AITestPilotReleasePipeline.ps1 `
    -ProductionLuaEvidenceDir "path\to\production-lua-evidence" `
    -RequireProductionLuaPatched

.\tools\Invoke-AITestPilotReleasePipeline.ps1 `
    -RequireLiveModelEndpointSmoke `
    -LiveModelEndpointSmokeEvidenceDir "path\to\live-smoke-evidence"

.\tools\Invoke-AITestPilotReleasePipeline.ps1 `
    -GameReplayDriverType "Your.Game.Tests.ProductionReplayDriver" `
    -ProductionLuaEvidenceDir "path\to\production-lua-evidence" `
    -RequireProductionReplayDriverBound `
    -RequireProductionLuaPatched `
    -RequireLiveModelEndpointSmoke `
    -LiveModelEndpointSmokeEvidenceDir "path\to\live-smoke-evidence"
'@

$readmePath = Join-Path $packagePath "README.md"
$actionPlanPath = Join-Path $packagePath "action-plan.md"
$requiredEvidencePath = Join-Path $packagePath "required-external-evidence.json"
$ciCommandsPath = Join-Path $packagePath "ci-commands.ps1"

$readme | Set-Content -Path $readmePath -Encoding UTF8
$actionPlanLines | Set-Content -Path $actionPlanPath -Encoding UTF8
$requiredEvidence | ConvertTo-Json -Depth 10 | Set-Content -Path $requiredEvidencePath -Encoding UTF8
$ciCommands | Set-Content -Path $ciCommandsPath -Encoding UTF8

$actionPlanText = Get-Content -Path $actionPlanPath -Encoding UTF8 -Raw
$requiredEvidenceText = Get-Content -Path $requiredEvidencePath -Encoding UTF8 -Raw
$ciCommandsText = Get-Content -Path $ciCommandsPath -Encoding UTF8 -Raw

$expectedActionPlanSnippets = @()
if ($actionItems.Count -eq 0) {
    $expectedActionPlanSnippets += @("production_handoff", "DONE")
} else {
    foreach ($item in $actionItems) {
        $expectedActionPlanSnippets += @(
            [string]$item["id"],
            [string]$item["owner"],
            [string]$item["status"],
            [string]$item["kitPath"],
            [string]$item["validationCommand"]
        )
        $expectedActionPlanSnippets += @(Convert-ToArray $item["remainingBlockingReasons"] | ForEach-Object { [string]$_ })
        $expectedActionPlanSnippets += @(Convert-ToArray $item["requiredEvidenceFiles"] | ForEach-Object { [string]$_ })
    }
}

$missingActionPlanSnippetCount = @($expectedActionPlanSnippets | Where-Object { -not $actionPlanText.Contains($_) }).Count
$actionPlanContentValid = $missingActionPlanSnippetCount -eq 0 -and
    -not ($actionPlanText -match "System\.Collections|OrderedDictionary")

$requiredEvidenceContentValid = $requiredEvidenceText.Contains("aitestpilot.production_handoff_required_evidence.v1") -and
    $requiredEvidenceText.Contains("production-replay-integration-checklist.json") -and
    $requiredEvidenceText.Contains("production-lua-patch-evidence.json") -and
    $requiredEvidenceText.Contains("live-model-endpoint-smoke-manifest.json") -and
    -not ($requiredEvidenceText -match "System\.Collections|OrderedDictionary")

$ciCommandsContentValid = $ciCommandsText.Contains("-RequireProductionReplayDriverBound") -and
    $ciCommandsText.Contains("-RequireProductionLuaPatched") -and
    $ciCommandsText.Contains("-RequireLiveModelEndpointSmoke") -and
    $ciCommandsText.Contains("-LiveModelEndpointSmokeEvidenceDir") -and
    -not ($ciCommandsText -match "System\.Collections|OrderedDictionary")

$generatedHandoffContentQualityAccepted = $actionPlanContentValid -and $requiredEvidenceContentValid -and $ciCommandsContentValid

$generatedFiles = @(
    "production-handoff-package/README.md",
    "production-handoff-package/action-plan.md",
    "production-handoff-package/required-external-evidence.json",
    "production-handoff-package/ci-commands.ps1"
)

$checks = @()
Add-HandoffCheck "production_driver_handoff_path" $driverHandoffReady "Production driver kit, accepted contract, and repo-external intake path must be ready."
Add-HandoffCheck "production_lua_handoff_path" $luaHandoffReady "Production Lua evidence kit, accepted contract, and repo-external intake path must be ready."
Add-HandoffCheck "live_model_handoff_path" $liveModelHandoffReady "Live model config kit and repo-external smoke intake path must be ready without secrets."
Add-HandoffCheck "ci_release_controls" $ciReleaseControlsReady "GitHub Actions, Azure Pipelines, and provider quality controls must be ready."
Add-HandoffCheck "generated_handoff_files" `
    ((Test-Path $readmePath) -and (Test-Path $actionPlanPath) -and (Test-Path $requiredEvidencePath) -and (Test-Path $ciCommandsPath)) `
    "Handoff package must generate README, action plan, required evidence JSON, and CI commands."
Add-HandoffCheck "generated_handoff_content_quality" `
    $generatedHandoffContentQualityAccepted `
    "Generated handoff files must contain concrete owner, kit, evidence, and command details without serialized PowerShell object names."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$files = @($generatedFiles + $sourceManifests)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_package.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    packageDir = $packagePath
    hostProjectHandoffReady = ($status -eq "PASS")
    externalEvidenceRequiredForProduction = $true
    productionDriverHandoffReady = [bool]$driverHandoffReady
    productionDriverReady = [bool]$productionDriverReady
    productionDriverBlockingReasonCount = [int]$driverBlockingReasons.Count
    productionDriverBlockingReasons = @($driverBlockingReasons)
    productionDriverRequiredEvidenceFiles = @($driverRequiredEvidence)
    productionDriverKitPath = "production-driver-binding-kit"
    realProductionDriverEvidenceAccepted = [bool]$productionDriverReady
    productionLuaHandoffReady = [bool]$luaHandoffReady
    productionLuaReady = [bool]$productionLuaReady
    productionLuaBlockingReasonCount = [int]$luaBlockingReasons.Count
    productionLuaBlockingReasons = @($luaBlockingReasons)
    productionLuaRequiredEvidenceFiles = @($luaRequiredEvidence)
    productionLuaKitPath = "production-lua-patch-evidence-kit"
    realProductionLuaPatchEvidenceAccepted = [bool]$productionLuaReady
    liveModelHandoffReady = [bool]$liveModelHandoffReady
    liveModelEndpointAccessProven = [bool]$liveModelAccessProven
    liveModelRequiredEvidenceFiles = @($liveRequiredEvidence)
    liveModelConfigKitPath = "live-model-endpoint-config-kit"
    ciReleaseControlsReady = [bool]$ciReleaseControlsReady
    fixtureEvidencePromoted = $false
    generatedHandoffContentQualityAccepted = [bool]$generatedHandoffContentQualityAccepted
    actionPlanContentValidated = [bool]$actionPlanContentValid
    requiredEvidenceContentValidated = [bool]$requiredEvidenceContentValid
    ciCommandsContentValidated = [bool]$ciCommandsContentValid
    hostProjectActionItemCount = [int]$actionItems.Count
    actionItems = @($actionItems)
    sourceManifestCount = [int]$sourceManifests.Count
    sourceManifests = @($sourceManifests)
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
    throw "Production handoff package failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production handoff package: $packagePath"
Write-Output "Production handoff package manifest: $manifestPath"
Write-Output "PASS AI TestPilot production handoff package"
