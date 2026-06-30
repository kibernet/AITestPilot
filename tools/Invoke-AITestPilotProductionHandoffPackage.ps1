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

function Convert-ToSafeFileName {
    param([string]$Value)

    $fileName = if ([string]::IsNullOrWhiteSpace($Value)) { "unknown" } else { $Value.ToLowerInvariant() }
    foreach ($invalidChar in [System.IO.Path]::GetInvalidFileNameChars()) {
        $fileName = $fileName.Replace([string]$invalidChar, "_")
    }

    return ($fileName -replace "[^a-z0-9_.-]", "_")
}

function New-BlockerResolution {
    param(
        [object]$ActionItem,
        [string]$BlockingReason
    )

    $area = [string]$ActionItem["id"]
    $owner = [string]$ActionItem["owner"]
    $requiredFiles = @(Convert-ToArray $ActionItem["requiredEvidenceFiles"] | ForEach-Object { [string]$_ })
    $validationCommand = [string]$ActionItem["validationCommand"]
    $evidenceFiles = @($requiredFiles)
    $acceptanceCriteria = @("Run the hard validation command and replace this blocker with PASS evidence.")
    $remediation = "Produce the required host-project evidence files and rerun the hard validation command."
    $mapped = $true

    switch ($BlockingReason) {
        "production_replay_integration_not_bound" {
            $evidenceFiles = @("production-replay-integration-checklist.json")
            $acceptanceCriteria = @("Checklist status is BOUND.", "realProjectBound is true.")
            $remediation = "Wire the production replay integration checklist to real host-game APIs."
        }
        "required_hooks_not_all_bound" {
            $evidenceFiles = @("production-replay-integration-checklist.json")
            $acceptanceCriteria = @("Every required hook is marked bound.", "boundHookCount equals requiredHookCount.")
            $remediation = "Implement each generated hook in the production driver binding kit."
        }
        "unresolved_required_hooks" {
            $evidenceFiles = @("production-replay-integration-checklist.json")
            $acceptanceCriteria = @("unresolvedRequiredHookCount is 0.", "No unresolved hook names remain.")
            $remediation = "Close every unresolved hook listed by the production replay checklist."
        }
        "sample_game_replay_driver_used" {
            $evidenceFiles = @("repair-retest-manifest.json", "repair-driver-failure-manifest.json", "replay-profile-import-manifest.json")
            $acceptanceCriteria = @("GameReplayDriverType is a host-project production driver.", "Sample driver evidence is not used for the hard release run.")
            $remediation = "Run the release pipeline with a non-sample production replay driver type."
        }
        "external_production_driver_not_selected" {
            $evidenceFiles = @("production-replay-integration-checklist.json", "repair-retest-manifest.json")
            $acceptanceCriteria = @("The release command includes the host production GameReplayDriverType.", "Production driver readiness is evaluated against that driver.")
            $remediation = "Select the external host-project production driver in the hard release command."
        }
        "real_production_lua_bundle_missing" {
            $evidenceFiles = @("production-lua-patch-evidence.json")
            $acceptanceCriteria = @("ProductionLuaEvidenceDir points to the host-project Lua evidence directory.", "production-lua-patch-evidence.json exists in that directory.")
            $remediation = "Export the real host-project Lua patch evidence bundle."
        }
        "real_production_lua_not_analyzed" {
            $evidenceFiles = @("production-lua-patch-evidence.json")
            $acceptanceCriteria = @("Real production Lua analysis is recorded.", "Analysis results are tied to the production Lua bundle.")
            $remediation = "Run Lua static analysis over the real production Lua sources and record the result."
        }
        "real_production_lua_not_patched" {
            $evidenceFiles = @("production-lua-patch-evidence.json")
            $acceptanceCriteria = @("Real production Lua patch application is recorded.", "Remaining production findings are 0.")
            $remediation = "Apply the validated patch to the real production Lua bundle and capture the evidence."
        }
        "production_lua_retest_evidence_missing" {
            $evidenceFiles = @("production-lua-patch-retest-template.md", "production-lua-patch-evidence.json")
            $acceptanceCriteria = @("Host retest command and result are recorded.", "Retest evidence passes after the Lua patch.")
            $remediation = "Run the host-project Lua retest and record the command, result, and evidence path."
        }
        "real_production_patch_rollback_missing" {
            $evidenceFiles = @("production-lua-patch-rollback-plan-template.md", "production-lua-patch-evidence.json")
            $acceptanceCriteria = @("Rollback command or plan is recorded.", "Source-control cleanup after validation is recorded.")
            $remediation = "Capture a production rollback plan and source-control cleanup evidence for the Lua patch."
        }
        "real_live_model_endpoint_smoke_missing" {
            $evidenceFiles = @("live-model-endpoint-smoke-manifest.json", "live-model-endpoint-decision-trace.json")
            $acceptanceCriteria = @("Live smoke manifest status is PASS.", "Decision trace is from the selected real provider endpoint.")
            $remediation = "Run a real live model endpoint smoke test or import a passing host-project live-smoke evidence directory."
        }
        default {
            $mapped = $false
        }
    }

    return [ordered]@{
        area = $area
        owner = $owner
        blockerReason = $BlockingReason
        status = [string]$ActionItem["status"]
        mapped = [bool]$mapped
        remediation = $remediation
        evidenceFiles = @($evidenceFiles)
        acceptanceCriteria = @($acceptanceCriteria)
        validationCommand = $validationCommand
    }
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

$productionDriverEvidenceExportHelperPath = "production-driver-binding-kit/Export-ProductionDriverEvidenceBundle.ps1"
$productionDriverEvidenceExportHelperCommand = '.\production-driver-binding-kit\Export-ProductionDriverEvidenceBundle.ps1 -EvidenceBundleDir "path\to\release-evidence"'
$productionDriverEvidenceExportOutputDir = "production-driver-evidence-export/production-driver-evidence"
$productionDriverEvidenceExportZipPath = "production-driver-evidence-export/production-driver-evidence.zip"
$productionDriverEvidenceExportManifestPath = "production-driver-evidence-export/production-driver-evidence-export-manifest.json"

$driverHandoffReady = $driverKit.status -eq "PASS" -and
    [bool](Get-JsonValue $driverKit "kitGenerated" $false) -and
    [bool](Get-JsonValue $driverKit "hostValidationScriptIncludesProductionBoundIntake" $false) -and
    [bool](Get-JsonValue $driverKit "exportHelperGenerated" $false) -and
    [bool](Get-JsonValue $driverKit "exportHelperRequiresProductionBoundReadiness" $false) -and
    [bool](Get-JsonValue $driverKit "exportHelperRejectedSampleUnboundEvidence" $false) -and
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
        evidenceExportHelperPath = $productionDriverEvidenceExportHelperPath
        evidenceExportHelperCommand = $productionDriverEvidenceExportHelperCommand
        evidenceExportOutputDir = $productionDriverEvidenceExportOutputDir
        evidenceExportZipPath = $productionDriverEvidenceExportZipPath
        evidenceExportManifestPath = $productionDriverEvidenceExportManifestPath
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

$blockerResolutions = @()
foreach ($item in $actionItems) {
    foreach ($reason in @(Convert-ToArray $item["remainingBlockingReasons"])) {
        $blockerResolutions += New-BlockerResolution $item ([string]$reason)
    }
}
$unmappedBlockerCount = @($blockerResolutions | Where-Object { -not [bool]$_["mapped"] }).Count
$hostProjectBlockingReasonCount = [int]$blockerResolutions.Count

$requiredEvidence = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_required_evidence.v1"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    productionDriver = [ordered]@{
        ready = [bool]$productionDriverReady
        handoffPathReady = [bool]$driverHandoffReady
        requiredFiles = @($driverRequiredEvidence)
        kitPath = "production-driver-binding-kit"
        evidenceExportHelperPath = $productionDriverEvidenceExportHelperPath
        evidenceExportHelperCommand = $productionDriverEvidenceExportHelperCommand
        evidenceExportOutputDir = $productionDriverEvidenceExportOutputDir
        evidenceExportZipPath = $productionDriverEvidenceExportZipPath
        evidenceExportManifestPath = $productionDriverEvidenceExportManifestPath
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

$blockerResolutionMap = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_blocker_resolution_map.v1"
    status = if ($unmappedBlockerCount -eq 0) { "PASS" } else { "FAIL" }
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    hostProjectActionItemCount = [int]$actionItems.Count
    totalBlockingReasonCount = [int]$hostProjectBlockingReasonCount
    mappedBlockingReasonCount = [int]($hostProjectBlockingReasonCount - $unmappedBlockerCount)
    unmappedBlockingReasonCount = [int]$unmappedBlockerCount
    ownerCount = [int](@($actionItems | ForEach-Object { [string]$_["owner"] } | Sort-Object -Unique).Count)
    releasePipelineUsesFixture = $false
    realHostProjectEvidenceAccepted = $false
    productionOutputBoundary = "host_project_blocker_resolution_only"
    resolutions = @($blockerResolutions)
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
- ``blocker-resolution-map.json`` and ``blocker-resolution-map.md``: owner, evidence, acceptance, and validation mapping for every remaining production blocker.
- ``owner-packets/``: one executable packet per host-project owner, plus ``owner-packet-index.json``.
- ``ci-commands.ps1``: copyable release-pipeline commands for hard production enforcement.
- ``verify-external-evidence.ps1``: host-project preflight for checking required external evidence paths before hard validation.
- ``accept-external-evidence.ps1``: host-project wrapper for running unified acceptance and writing the Markdown acceptance report before hard validation.

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
    "- Production driver owners can run ``$productionDriverEvidenceExportHelperCommand`` after production-bound readiness passes to package the four required driver files into ``$productionDriverEvidenceExportOutputDir`` and ``$productionDriverEvidenceExportZipPath``.",
    "- Production Lua completion requires real Lua analysis, patch, validation, retest, rollback, and clean source-control evidence.",
    "- Live model completion requires a real PASS smoke manifest and decision trace from the selected provider."
)

$blockerResolutionLines = @(
    "# Production Blocker Resolution Map",
    "",
    "Schema: aitestpilot.production_handoff_blocker_resolution_map.v1",
    "",
    "Each row maps one current blocker to the owner, evidence file, acceptance condition, and hard validation command that clears it.",
    "",
    "| Area | Blocker | Owner | Evidence files | Acceptance criteria | Validation command |",
    "| --- | --- | --- | --- | --- | --- |"
)

foreach ($resolution in $blockerResolutions) {
    $criteria = Join-MarkdownList @(Convert-ToArray $resolution["acceptanceCriteria"])
    $evidenceFiles = Join-MarkdownList @(Convert-ToArray $resolution["evidenceFiles"])
    $area = [string]$resolution["area"]
    $reason = [string]$resolution["blockerReason"]
    $owner = [string]$resolution["owner"]
    $validationCommand = [string]$resolution["validationCommand"]
    $blockerResolutionLines += "| $area | $reason | $owner | $evidenceFiles | $criteria | " + '`' + $validationCommand + '`' + " |"
}

if ($blockerResolutions.Count -eq 0) {
    $blockerResolutionLines += "| production_handoff | none | n/a | n/a | No blockers remain. | n/a |"
}

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

$preflightScript = @'
# AI TestPilot production handoff external evidence preflight.
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$EvidenceBundleDir,
    [string]$ProductionDriverEvidenceDir,
    [string]$ProductionLuaEvidenceDir,
    [string]$LiveModelEndpointSmokeEvidenceDir,
    [string]$GameReplayDriverType = "Your.Game.Tests.ProductionReplayDriver",
    [string]$OutputPath,
    [switch]$RequireAllEvidence,
    [switch]$RunIntake
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-FullPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Find-RepoRoot {
    param([string]$StartDir)

    $current = Resolve-FullPath $StartDir
    while ($true) {
        if (Test-Path (Join-Path $current "tools\Invoke-AITestPilotReleasePipeline.ps1")) {
            return $current
        }

        $parent = [System.IO.Directory]::GetParent($current)
        if ($null -eq $parent) {
            throw "Could not locate repo root from $StartDir. Pass -RepoRoot explicitly."
        }

        $parentPath = $parent.FullName
        if ($parentPath -eq $current) {
            throw "Could not locate repo root from $StartDir. Pass -RepoRoot explicitly."
        }

        $current = $parentPath
    }
}

function Test-RequiredFiles {
    param(
        [string]$BaseDir,
        [string[]]$RequiredFiles
    )

    $provided = -not [string]::IsNullOrWhiteSpace($BaseDir)
    $path = ""
    $missingFiles = @()

    if (-not $provided) {
        $missingFiles = @($RequiredFiles)
    } else {
        $path = Resolve-FullPath $BaseDir
        if (-not (Test-Path $path)) {
            $missingFiles = @($RequiredFiles)
        } else {
            foreach ($fileName in $RequiredFiles) {
                if (-not (Test-Path (Join-Path $path $fileName))) {
                    $missingFiles += $fileName
                }
            }
        }
    }

    return [ordered]@{
        provided = [bool]$provided
        path = $path
        requiredFiles = @($RequiredFiles)
        missingFiles = @($missingFiles)
        missingFileCount = [int]$missingFiles.Count
        allPresent = ($provided -and $missingFiles.Count -eq 0)
    }
}

function Add-PreflightCheck {
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

function Invoke-PreflightCommand {
    param(
        [string]$Name,
        [scriptblock]$Command
    )

    $passed = $true
    $message = "PASS"
    try {
        & $Command | Out-Null
    } catch {
        $passed = $false
        $message = $_.Exception.Message
    }

    return [ordered]@{
        name = $Name
        passed = [bool]$passed
        message = $message
    }
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Find-RepoRoot $PSScriptRoot
}
$repoPath = Resolve-FullPath $RepoRoot

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $PSScriptRoot ".."
}
$evidencePath = Resolve-FullPath $EvidenceBundleDir

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $PSScriptRoot "external-evidence-preflight.json"
}
$outputFullPath = Resolve-FullPath $OutputPath

$driverRequiredFiles = @(
    "production-replay-integration-checklist.json",
    "repair-retest-manifest.json",
    "repair-driver-failure-manifest.json",
    "replay-profile-import-manifest.json"
)
$luaRequiredFiles = @(
    "production-lua-patch-evidence.json",
    "production-lua-patch-retest-template.md",
    "production-lua-patch-rollback-plan-template.md"
)
$liveModelRequiredFiles = @(
    "live-model-endpoint-smoke-manifest.json",
    "live-model-endpoint-decision-trace.json"
)

$driverEvidence = Test-RequiredFiles $ProductionDriverEvidenceDir $driverRequiredFiles
$luaEvidence = Test-RequiredFiles $ProductionLuaEvidenceDir $luaRequiredFiles
$liveModelEvidence = Test-RequiredFiles $LiveModelEndpointSmokeEvidenceDir $liveModelRequiredFiles

$checks = @()
Add-PreflightCheck "production_driver_required_files" ([bool]$driverEvidence.allPresent) "Production driver evidence must include checklist, retest, failure-probe, and replay profile import files."
Add-PreflightCheck "production_lua_required_files" ([bool]$luaEvidence.allPresent) "Production Lua evidence must include evidence JSON, retest template, and rollback plan template."
Add-PreflightCheck "live_model_required_files" ([bool]$liveModelEvidence.allPresent) "Live model evidence must include smoke manifest and decision trace."

$actionItems = @()
if (-not [bool]$driverEvidence.allPresent) {
    $actionItems += [ordered]@{
        id = "production_driver_binding"
        owner = "host_project_gameplay_qa"
        missingFileCount = [int]$driverEvidence.missingFileCount
        missingFiles = @($driverEvidence.missingFiles)
    }
}
if (-not [bool]$luaEvidence.allPresent) {
    $actionItems += [ordered]@{
        id = "production_lua_patch_evidence"
        owner = "host_project_lua_owner"
        missingFileCount = [int]$luaEvidence.missingFileCount
        missingFiles = @($luaEvidence.missingFiles)
    }
}
if (-not [bool]$liveModelEvidence.allPresent) {
    $actionItems += [ordered]@{
        id = "live_model_endpoint_smoke"
        owner = "host_project_ai_platform"
        missingFileCount = [int]$liveModelEvidence.missingFileCount
        missingFiles = @($liveModelEvidence.missingFiles)
    }
}

$intakeResults = @()
if ([bool]$RunIntake) {
    if ([bool]$driverEvidence.allPresent) {
        $intakeResults += Invoke-PreflightCommand "production_driver_intake" {
            & (Join-Path $repoPath "tools\Invoke-AITestPilotProductionDriverEvidenceIntake.ps1") -EvidenceBundleDir $driverEvidence.path
        }
    }

    if ([bool]$luaEvidence.allPresent) {
        $intakeResults += Invoke-PreflightCommand "production_lua_readiness" {
            & (Join-Path $repoPath "tools\Invoke-AITestPilotProductionLuaPatchReadiness.ps1") -EvidenceBundleDir $evidencePath -ProductionLuaEvidenceDir $luaEvidence.path -RequireProductionLuaPatched
        }
    }

    if ([bool]$liveModelEvidence.allPresent) {
        $intakeResults += Invoke-PreflightCommand "live_model_smoke_intake" {
            & (Join-Path $repoPath "tools\Invoke-AITestPilotLiveModelEndpointSmokeEvidenceIntake.ps1") -EvidenceBundleDir $evidencePath -SmokeEvidenceDir $liveModelEvidence.path -RequireLiveModelEndpointSmoke
        }
    }
}

$failedIntakeCount = @($intakeResults | Where-Object { -not [bool]$_.passed }).Count
$allRequiredExternalEvidenceFilesPresent = [bool]$driverEvidence.allPresent -and [bool]$luaEvidence.allPresent -and [bool]$liveModelEvidence.allPresent
$status = if ($failedIntakeCount -gt 0) {
    "FAIL"
} elseif ($allRequiredExternalEvidenceFilesPresent) {
    "PASS"
} else {
    "PENDING_EXTERNAL_EVIDENCE"
}

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_external_evidence_preflight.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    repoRoot = $repoPath
    evidenceBundleDir = $evidencePath
    requireAllEvidence = [bool]$RequireAllEvidence
    runIntake = [bool]$RunIntake
    allRequiredExternalEvidenceFilesPresent = [bool]$allRequiredExternalEvidenceFilesPresent
    missingExternalEvidenceAreaCount = [int]$actionItems.Count
    productionDriverEvidence = $driverEvidence
    productionLuaEvidence = $luaEvidence
    liveModelEndpointEvidence = $liveModelEvidence
    gameReplayDriverType = $GameReplayDriverType
    actionItems = @($actionItems)
    intakeResults = @($intakeResults)
    failedIntakeCount = [int]$failedIntakeCount
    checks = @($checks)
    hardValidationCommand = ".\tools\Invoke-AITestPilotReleasePipeline.ps1 -GameReplayDriverType `"$GameReplayDriverType`" -ProductionLuaEvidenceDir `"$ProductionLuaEvidenceDir`" -RequireProductionReplayDriverBound -RequireProductionLuaPatched -RequireLiveModelEndpointSmoke -LiveModelEndpointSmokeEvidenceDir `"$LiveModelEndpointSmokeEvidenceDir`""
}

New-Item -ItemType Directory -Force (Split-Path $outputFullPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $outputFullPath -Encoding UTF8

if ([bool]$RequireAllEvidence -and $status -ne "PASS") {
    throw "External evidence preflight did not pass. Manifest: $outputFullPath"
}

Write-Output "External evidence preflight manifest: $outputFullPath"
Write-Output "AI TestPilot production handoff external evidence preflight status: $status"
'@

$acceptanceWrapperScript = @'
# AI TestPilot production handoff external evidence acceptance wrapper.
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$EvidenceBundleDir,
    [string]$OutputDir,
    [string]$ProductionDriverEvidenceDir,
    [string]$ProductionLuaEvidenceDir,
    [string]$LiveModelEndpointSmokeEvidenceDir,
    [string]$GameReplayDriverType = "Your.Game.Tests.ProductionReplayDriver",
    [switch]$RequireAllEvidence,
    [switch]$ContractFixtureMode,
    [switch]$RunHardValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-FullPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Find-RepoRoot {
    param([string]$StartDir)

    $current = Resolve-FullPath $StartDir
    while ($true) {
        if (Test-Path (Join-Path $current "tools\Invoke-AITestPilotReleasePipeline.ps1")) {
            return $current
        }

        $parent = [System.IO.Directory]::GetParent($current)
        if ($null -eq $parent) {
            throw "Could not locate repo root from $StartDir. Pass -RepoRoot explicitly."
        }

        $parentPath = $parent.FullName
        if ($parentPath -eq $current) {
            throw "Could not locate repo root from $StartDir. Pass -RepoRoot explicitly."
        }

        $current = $parentPath
    }
}

function Invoke-WrapperCommand {
    param(
        [string]$Name,
        [scriptblock]$Command
    )

    $passed = $true
    $message = "PASS"
    try {
        & $Command | Out-Null
    } catch {
        $passed = $false
        $message = $_.Exception.Message
    }

    return [ordered]@{
        name = $Name
        passed = [bool]$passed
        message = $message
    }
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Find-RepoRoot $PSScriptRoot
}
$repoPath = Resolve-FullPath $RepoRoot

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $PSScriptRoot ".."
}
$evidencePath = Resolve-FullPath $EvidenceBundleDir

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $PSScriptRoot "external-evidence-acceptance"
}
$outputPath = Resolve-FullPath $OutputDir
$acceptanceBundlePath = Join-Path $outputPath "acceptance-bundle"
$acceptanceManifestPath = Join-Path $outputPath "production-external-evidence-acceptance-manifest.json"
$acceptanceReportPath = Join-Path $outputPath "production-external-evidence-acceptance.md"
$wrapperManifestPath = Join-Path $outputPath "external-evidence-acceptance-wrapper-manifest.json"
$pipelineManifestPath = Join-Path $repoPath "artifacts\ai-testpilot-release\latest\pipeline-manifest.json"

New-Item -ItemType Directory -Force $outputPath | Out-Null

$acceptanceResult = Invoke-WrapperCommand "production_external_evidence_acceptance" {
    & (Join-Path $repoPath "tools\Invoke-AITestPilotProductionExternalEvidenceAcceptance.ps1") `
        -EvidenceBundleDir $evidencePath `
        -AcceptanceBundleDir $acceptanceBundlePath `
        -ManifestPath $acceptanceManifestPath `
        -ReportPath $acceptanceReportPath `
        -ProductionDriverEvidenceDir $ProductionDriverEvidenceDir `
        -ProductionLuaEvidenceDir $ProductionLuaEvidenceDir `
        -LiveModelEndpointSmokeEvidenceDir $LiveModelEndpointSmokeEvidenceDir `
        -GameReplayDriverType $GameReplayDriverType `
        -RequireAllEvidence:$RequireAllEvidence `
        -ContractFixtureMode:$ContractFixtureMode
}

if (-not (Test-Path $acceptanceManifestPath)) {
    throw "Production external evidence acceptance manifest was not produced: $acceptanceManifestPath"
}

$acceptanceManifest = Get-Content -Path $acceptanceManifestPath -Encoding UTF8 -Raw | ConvertFrom-Json
$acceptanceReportGenerated = (Test-Path $acceptanceReportPath) -and
    [bool]$acceptanceManifest.reportGenerated -and
    [bool]$acceptanceManifest.reportContentValidated

$hardValidationResult = $null
if ([bool]$RunHardValidation) {
    $hardValidationResult = Invoke-WrapperCommand "hard_production_release_pipeline" {
        & (Join-Path $repoPath "tools\Invoke-AITestPilotReleasePipeline.ps1") `
            -GameReplayDriverType $GameReplayDriverType `
            -ProductionLuaEvidenceDir $ProductionLuaEvidenceDir `
            -RequireProductionReplayDriverBound `
            -RequireProductionLuaPatched `
            -RequireLiveModelEndpointSmoke `
            -LiveModelEndpointSmokeEvidenceDir $LiveModelEndpointSmokeEvidenceDir
    }
}

$wrapperStatus = if (-not [bool]$acceptanceResult.passed) {
    "FAIL"
} elseif ([bool]$RunHardValidation -and $null -ne $hardValidationResult -and -not [bool]$hardValidationResult.passed) {
    "FAIL"
} elseif ([string]$acceptanceManifest.status -eq "PASS" -and (-not [bool]$RunHardValidation -or ($null -ne $hardValidationResult -and [bool]$hardValidationResult.passed))) {
    "PASS"
} else {
    [string]$acceptanceManifest.status
}

$wrapperCommandResults = @($acceptanceResult)
if ($null -ne $hardValidationResult) {
    $wrapperCommandResults += $hardValidationResult
}

$wrapperManifest = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_external_evidence_acceptance_wrapper.v1"
    status = $wrapperStatus
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    repoRoot = $repoPath
    evidenceBundleDir = $evidencePath
    outputDir = $outputPath
    requireAllEvidence = [bool]$RequireAllEvidence
    contractFixtureMode = [bool]$ContractFixtureMode
    runHardValidation = [bool]$RunHardValidation
    gameReplayDriverType = $GameReplayDriverType
    productionDriverEvidenceDir = $ProductionDriverEvidenceDir
    productionLuaEvidenceDir = $ProductionLuaEvidenceDir
    liveModelEndpointSmokeEvidenceDir = $LiveModelEndpointSmokeEvidenceDir
    acceptanceCommandPassed = [bool]$acceptanceResult.passed
    acceptanceManifestPath = $acceptanceManifestPath
    acceptanceReportPath = $acceptanceReportPath
    acceptanceReportGenerated = [bool]$acceptanceReportGenerated
    acceptanceStatus = [string]$acceptanceManifest.status
    allExternalEvidenceAccepted = [bool]$acceptanceManifest.allExternalEvidenceAccepted
    realHostProjectEvidenceAccepted = [bool]$acceptanceManifest.realHostProjectEvidenceAccepted
    missingExternalEvidenceAreaCount = [int]$acceptanceManifest.missingExternalEvidenceAreaCount
    hardValidationCommand = ".\tools\Invoke-AITestPilotReleasePipeline.ps1 -GameReplayDriverType `"$GameReplayDriverType`" -ProductionLuaEvidenceDir `"$ProductionLuaEvidenceDir`" -RequireProductionReplayDriverBound -RequireProductionLuaPatched -RequireLiveModelEndpointSmoke -LiveModelEndpointSmokeEvidenceDir `"$LiveModelEndpointSmokeEvidenceDir`""
    hardValidationRun = [bool]$RunHardValidation
    hardValidationPassed = ($null -ne $hardValidationResult -and [bool]$hardValidationResult.passed)
    pipelineManifestPath = if ([bool]$RunHardValidation) { $pipelineManifestPath } else { "" }
    commandResults = @($wrapperCommandResults)
    productionOutputBoundary = if ([bool]$acceptanceManifest.realHostProjectEvidenceAccepted) {
        "real_host_project_external_evidence_accepted"
    } elseif ([bool]$ContractFixtureMode) {
        "accepted_fixture_external_evidence_acceptance_wrapper_contract_only"
    } else {
        "external_evidence_acceptance_wrapper_only"
    }
    files = @(
        "external-evidence-acceptance-wrapper-manifest.json",
        "production-external-evidence-acceptance-manifest.json",
        "production-external-evidence-acceptance.md"
    )
}

$wrapperManifest | ConvertTo-Json -Depth 12 | Set-Content -Path $wrapperManifestPath -Encoding UTF8

if ([bool]$RequireAllEvidence -and $wrapperStatus -ne "PASS") {
    throw "Production external evidence acceptance wrapper failed. Manifest: $wrapperManifestPath"
}

Write-Output "Production external evidence acceptance wrapper manifest: $wrapperManifestPath"
Write-Output "Production external evidence acceptance report: $acceptanceReportPath"
Write-Output "AI TestPilot production external evidence acceptance wrapper status: $wrapperStatus"
'@

$readmePath = Join-Path $packagePath "README.md"
$actionPlanPath = Join-Path $packagePath "action-plan.md"
$requiredEvidencePath = Join-Path $packagePath "required-external-evidence.json"
$blockerResolutionJsonPath = Join-Path $packagePath "blocker-resolution-map.json"
$blockerResolutionMarkdownPath = Join-Path $packagePath "blocker-resolution-map.md"
$ciCommandsPath = Join-Path $packagePath "ci-commands.ps1"
$preflightScriptPath = Join-Path $packagePath "verify-external-evidence.ps1"
$acceptanceWrapperScriptPath = Join-Path $packagePath "accept-external-evidence.ps1"
$preflightSelfCheckPath = Join-Path $packagePath "external-evidence-preflight-self-check.json"
$ownerPacketsDir = Join-Path $packagePath "owner-packets"
$ownerPacketIndexPath = Join-Path $ownerPacketsDir "owner-packet-index.json"

$readme | Set-Content -Path $readmePath -Encoding UTF8
$actionPlanLines | Set-Content -Path $actionPlanPath -Encoding UTF8
$requiredEvidence | ConvertTo-Json -Depth 10 | Set-Content -Path $requiredEvidencePath -Encoding UTF8
$blockerResolutionMap | ConvertTo-Json -Depth 12 | Set-Content -Path $blockerResolutionJsonPath -Encoding UTF8
$blockerResolutionLines | Set-Content -Path $blockerResolutionMarkdownPath -Encoding UTF8
$ciCommands | Set-Content -Path $ciCommandsPath -Encoding UTF8
$preflightScript | Set-Content -Path $preflightScriptPath -Encoding UTF8
$acceptanceWrapperScript | Set-Content -Path $acceptanceWrapperScriptPath -Encoding UTF8

New-Item -ItemType Directory -Force $ownerPacketsDir | Out-Null
$ownerPackets = @()
$ownerPacketFullPaths = @()
foreach ($item in $actionItems) {
    $area = [string]$item["id"]
    $owner = [string]$item["owner"]
    $packetFileName = "$(Convert-ToSafeFileName $owner).md"
    $packetRelativePath = "production-handoff-package/owner-packets/$packetFileName"
    $packetFullPath = Join-Path $ownerPacketsDir $packetFileName
    $ownerPacketFullPaths += $packetFullPath
    $requiredFiles = @(Convert-ToArray $item["requiredEvidenceFiles"] | ForEach-Object { [string]$_ })
    $blockingReasons = @(Convert-ToArray $item["remainingBlockingReasons"] | ForEach-Object { [string]$_ })
    $areaResolutions = @($blockerResolutions | Where-Object { [string]$_["area"] -eq $area })
    $ownerEvidenceDirPlaceholder = switch ($area) {
        "production_driver_binding" { "path\to\production-driver-evidence" }
        "production_lua_patch_evidence" { "path\to\production-lua-evidence" }
        "live_model_endpoint_smoke" { "path\to\live-smoke-evidence" }
        default { "path\to\external-evidence" }
    }
    $itemStatus = [string]$item["status"]
    $preflightCommand = ".\production-handoff-package\verify-external-evidence.ps1 -ProductionDriverEvidenceDir `"path\to\production-driver-evidence`" -ProductionLuaEvidenceDir `"path\to\production-lua-evidence`" -LiveModelEndpointSmokeEvidenceDir `"path\to\live-smoke-evidence`" -RequireAllEvidence -RunIntake"
    $acceptanceWrapperCommand = ".\production-handoff-package\accept-external-evidence.ps1 -ProductionDriverEvidenceDir `"path\to\production-driver-evidence`" -ProductionLuaEvidenceDir `"path\to\production-lua-evidence`" -LiveModelEndpointSmokeEvidenceDir `"path\to\live-smoke-evidence`" -RequireAllEvidence"
    $hardValidationCommand = [string]$item["validationCommand"]
    $driverEvidenceExportHelperCommand = if ($area -eq "production_driver_binding") { [string]$item["evidenceExportHelperCommand"] } else { "" }

    $packetLines = @(
        "# Production Evidence Owner Packet: $owner",
        "",
        "Area: ``$area``",
        "Status: ``$itemStatus``",
        "Owner evidence directory: ``$ownerEvidenceDirPlaceholder``",
        "",
        "## Required Evidence",
        ""
    )

    foreach ($fileName in $requiredFiles) {
        $packetLines += "- ``$fileName``"
    }

    if ($area -eq "production_driver_binding") {
        $packetLines += @(
            "",
            "## Driver Evidence Export",
            "",
            "Run this helper in the host-project release evidence bundle after production-bound readiness passes with zero blockers:",
            "",
            '```powershell',
            $driverEvidenceExportHelperCommand,
            '```',
            "",
            "It creates ``$productionDriverEvidenceExportOutputDir`` and ``$productionDriverEvidenceExportZipPath`` for owner response bundle return. It rejects sample or unbound evidence."
        )
    }

    $packetLines += @(
        "",
        "## Remaining Blockers",
        ""
    )

    foreach ($reason in $blockingReasons) {
        $packetLines += "- ``$reason``"
    }

    $packetLines += @(
        "",
        "## Blocker Resolution",
        "",
        "| Blocker | Evidence files | Acceptance criteria | Remediation |",
        "| --- | --- | --- | --- |"
    )

    foreach ($resolution in $areaResolutions) {
        $resolutionBlockerReason = [string]$resolution["blockerReason"]
        $resolutionEvidenceFiles = Join-MarkdownList @(Convert-ToArray $resolution["evidenceFiles"])
        $resolutionAcceptanceCriteria = Join-MarkdownList @(Convert-ToArray $resolution["acceptanceCriteria"])
        $resolutionRemediation = [string]$resolution["remediation"]
        $packetLines += "| $resolutionBlockerReason | $resolutionEvidenceFiles | $resolutionAcceptanceCriteria | $resolutionRemediation |"
    }

    $packetLines += @(
        "",
        "## Validation Commands",
        "",
        '```powershell',
        $preflightCommand,
        "",
        $acceptanceWrapperCommand,
        "",
        $hardValidationCommand,
        '```',
        "",
        "## Evidence Boundary",
        "",
        "- Fixture contracts prove schemas only and must not be submitted as real host-project evidence.",
        "- This packet is complete only after the owner evidence directory contains every required file and the validation commands pass.",
        "- Use ``accept-external-evidence.ps1`` to generate the Markdown acceptance report before hard production validation."
    )

    $packetLines | Set-Content -Path $packetFullPath -Encoding UTF8
    $ownerPackets += [ordered]@{
        owner = $owner
        area = $area
        status = $itemStatus
        packetPath = $packetRelativePath
        ownerEvidenceDirPlaceholder = $ownerEvidenceDirPlaceholder
        remainingBlockingReasonCount = [int]$blockingReasons.Count
        remainingBlockingReasons = @($blockingReasons)
        requiredEvidenceFiles = @($requiredFiles)
        blockerResolutionCount = [int]$areaResolutions.Count
        preflightCommand = $preflightCommand
        acceptanceWrapperCommand = $acceptanceWrapperCommand
        driverEvidenceExportHelperCommand = $driverEvidenceExportHelperCommand
        hardValidationCommand = $hardValidationCommand
    }
}

$ownerPacketBlockingReasonCountMeasure = @($ownerPackets | ForEach-Object { [int]$_["remainingBlockingReasonCount"] } | Measure-Object -Sum)
$ownerPacketBlockingReasonCount = if ($null -eq $ownerPacketBlockingReasonCountMeasure.Sum) { 0 } else { [int]$ownerPacketBlockingReasonCountMeasure.Sum }
$ownerPacketIndex = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_owner_packets.v1"
    status = if ($ownerPackets.Count -eq $actionItems.Count -and $ownerPacketBlockingReasonCount -eq $hostProjectBlockingReasonCount) { "PASS" } else { "FAIL" }
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    ownerPacketCount = [int]$ownerPackets.Count
    hostProjectActionItemCount = [int]$actionItems.Count
    totalBlockingReasonCount = [int]$ownerPacketBlockingReasonCount
    expectedBlockingReasonCount = [int]$hostProjectBlockingReasonCount
    releasePipelineUsesFixture = $false
    realHostProjectEvidenceAccepted = $false
    productionOutputBoundary = "host_project_owner_packet_handoff_only"
    packets = @($ownerPackets)
}
$ownerPacketIndex | ConvertTo-Json -Depth 12 | Set-Content -Path $ownerPacketIndexPath -Encoding UTF8

& $preflightScriptPath -RepoRoot $repoRoot -EvidenceBundleDir $evidenceBundlePath -OutputPath $preflightSelfCheckPath | Out-Null

$actionPlanText = Get-Content -Path $actionPlanPath -Encoding UTF8 -Raw
$requiredEvidenceText = Get-Content -Path $requiredEvidencePath -Encoding UTF8 -Raw
$blockerResolutionText = Get-Content -Path $blockerResolutionJsonPath -Encoding UTF8 -Raw
$blockerResolutionMarkdownText = Get-Content -Path $blockerResolutionMarkdownPath -Encoding UTF8 -Raw
$blockerResolutionSelfCheck = $blockerResolutionText | ConvertFrom-Json
$ciCommandsText = Get-Content -Path $ciCommandsPath -Encoding UTF8 -Raw
$preflightScriptText = Get-Content -Path $preflightScriptPath -Encoding UTF8 -Raw
$acceptanceWrapperScriptText = Get-Content -Path $acceptanceWrapperScriptPath -Encoding UTF8 -Raw
$preflightSelfCheck = Get-Content -Path $preflightSelfCheckPath -Encoding UTF8 -Raw | ConvertFrom-Json
$ownerPacketIndexText = Get-Content -Path $ownerPacketIndexPath -Encoding UTF8 -Raw
$ownerPacketIndexSelfCheck = $ownerPacketIndexText | ConvertFrom-Json
$ownerPacketMarkdownText = [string]::Join([Environment]::NewLine, @($ownerPacketFullPaths | ForEach-Object { Get-Content -Path $_ -Encoding UTF8 -Raw }))

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
    $requiredEvidenceText.Contains("Export-ProductionDriverEvidenceBundle.ps1") -and
    $requiredEvidenceText.Contains("production-driver-evidence.zip") -and
    $requiredEvidenceText.Contains("production-lua-patch-evidence.json") -and
    $requiredEvidenceText.Contains("live-model-endpoint-smoke-manifest.json") -and
    -not ($requiredEvidenceText -match "System\.Collections|OrderedDictionary")

$expectedBlockerResolutionSnippets = @(
    "aitestpilot.production_handoff_blocker_resolution_map.v1",
    "host_project_gameplay_qa",
    "host_project_lua_owner",
    "host_project_ai_platform",
    "production-replay-integration-checklist.json",
    "production-lua-patch-evidence.json",
    "live-model-endpoint-smoke-manifest.json",
    "-RequireProductionReplayDriverBound",
    "-RequireProductionLuaPatched",
    "-RequireLiveModelEndpointSmoke"
)
$expectedBlockerResolutionSnippets += @($blockerResolutions | ForEach-Object { [string]$_["blockerReason"] })

$missingBlockerResolutionSnippetCount = @($expectedBlockerResolutionSnippets | Where-Object {
    -not $blockerResolutionText.Contains($_) -or -not $blockerResolutionMarkdownText.Contains($_)
}).Count

$blockerResolutionMapContentValid = $blockerResolutionSelfCheck.schemaVersion -eq "aitestpilot.production_handoff_blocker_resolution_map.v1" -and
    $blockerResolutionSelfCheck.status -eq "PASS" -and
    [int]$blockerResolutionSelfCheck.totalBlockingReasonCount -eq [int]$hostProjectBlockingReasonCount -and
    [int]$blockerResolutionSelfCheck.mappedBlockingReasonCount -eq [int]$hostProjectBlockingReasonCount -and
    [int]$blockerResolutionSelfCheck.unmappedBlockingReasonCount -eq 0 -and
    -not [bool]$blockerResolutionSelfCheck.releasePipelineUsesFixture -and
    -not [bool]$blockerResolutionSelfCheck.realHostProjectEvidenceAccepted -and
    $blockerResolutionSelfCheck.productionOutputBoundary -eq "host_project_blocker_resolution_only" -and
    $missingBlockerResolutionSnippetCount -eq 0 -and
    -not ($blockerResolutionText -match "System\.Collections|OrderedDictionary") -and
    -not ($blockerResolutionMarkdownText -match "System\.Collections|OrderedDictionary")

$ciCommandsContentValid = $ciCommandsText.Contains("-RequireProductionReplayDriverBound") -and
    $ciCommandsText.Contains("-RequireProductionLuaPatched") -and
    $ciCommandsText.Contains("-RequireLiveModelEndpointSmoke") -and
    $ciCommandsText.Contains("-LiveModelEndpointSmokeEvidenceDir") -and
    -not ($ciCommandsText -match "System\.Collections|OrderedDictionary")

$preflightScriptContentValid = $preflightScriptText.Contains("aitestpilot.production_handoff_external_evidence_preflight.v1") -and
    $preflightScriptText.Contains("ProductionDriverEvidenceDir") -and
    $preflightScriptText.Contains("ProductionLuaEvidenceDir") -and
    $preflightScriptText.Contains("LiveModelEndpointSmokeEvidenceDir") -and
    $preflightScriptText.Contains("RequireAllEvidence") -and
    $preflightScriptText.Contains("RunIntake") -and
    -not ($preflightScriptText -match "System\.Collections|OrderedDictionary")

$preflightSelfCheckValid = $preflightSelfCheck.schemaVersion -eq "aitestpilot.production_handoff_external_evidence_preflight.v1" -and
    $preflightSelfCheck.status -eq "PENDING_EXTERNAL_EVIDENCE" -and
    [int]$preflightSelfCheck.missingExternalEvidenceAreaCount -eq 3 -and
    -not [bool]$preflightSelfCheck.allRequiredExternalEvidenceFilesPresent

$acceptanceWrapperScriptContentValid = $acceptanceWrapperScriptText.Contains("aitestpilot.production_handoff_external_evidence_acceptance_wrapper.v1") -and
    $acceptanceWrapperScriptText.Contains("Invoke-AITestPilotProductionExternalEvidenceAcceptance.ps1") -and
    $acceptanceWrapperScriptText.Contains("production-external-evidence-acceptance.md") -and
    $acceptanceWrapperScriptText.Contains("RunHardValidation") -and
    $acceptanceWrapperScriptText.Contains("-RequireProductionReplayDriverBound") -and
    $acceptanceWrapperScriptText.Contains("-RequireProductionLuaPatched") -and
    $acceptanceWrapperScriptText.Contains("-RequireLiveModelEndpointSmoke") -and
    -not ($acceptanceWrapperScriptText -match "System\.Collections|OrderedDictionary")

$expectedOwnerPacketSnippets = @(
    "aitestpilot.production_handoff_owner_packets.v1",
    "verify-external-evidence.ps1",
    "accept-external-evidence.ps1",
    "Invoke-AITestPilotReleasePipeline.ps1",
    "```powershell",
    "host_project_owner_packet_handoff_only"
)
foreach ($item in $actionItems) {
    $expectedOwnerPacketSnippets += @(
        [string]$item["id"],
        [string]$item["owner"],
        [string]$item["status"],
        [string]$item["validationCommand"]
    )
    if ($item.Contains("evidenceExportHelperCommand")) {
        $expectedOwnerPacketSnippets += [string]$item["evidenceExportHelperCommand"]
    }
    $expectedOwnerPacketSnippets += @(Convert-ToArray $item["remainingBlockingReasons"] | ForEach-Object { [string]$_ })
    $expectedOwnerPacketSnippets += @(Convert-ToArray $item["requiredEvidenceFiles"] | ForEach-Object { [string]$_ })
}

$missingOwnerPacketSnippetCount = @($expectedOwnerPacketSnippets | Where-Object {
    -not $ownerPacketIndexText.Contains($_) -and -not $ownerPacketMarkdownText.Contains($_)
}).Count
$ownerPacketsContentValid = $ownerPacketIndexSelfCheck.schemaVersion -eq "aitestpilot.production_handoff_owner_packets.v1" -and
    $ownerPacketIndexSelfCheck.status -eq "PASS" -and
    [int]$ownerPacketIndexSelfCheck.ownerPacketCount -eq [int]$actionItems.Count -and
    [int]$ownerPacketIndexSelfCheck.hostProjectActionItemCount -eq [int]$actionItems.Count -and
    [int]$ownerPacketIndexSelfCheck.totalBlockingReasonCount -eq [int]$hostProjectBlockingReasonCount -and
    [int]$ownerPacketIndexSelfCheck.expectedBlockingReasonCount -eq [int]$hostProjectBlockingReasonCount -and
    -not [bool]$ownerPacketIndexSelfCheck.releasePipelineUsesFixture -and
    -not [bool]$ownerPacketIndexSelfCheck.realHostProjectEvidenceAccepted -and
    $ownerPacketIndexSelfCheck.productionOutputBoundary -eq "host_project_owner_packet_handoff_only" -and
    $missingOwnerPacketSnippetCount -eq 0 -and
    -not ($ownerPacketIndexText -match "System\.Collections|OrderedDictionary") -and
    -not ($ownerPacketMarkdownText -match "System\.Collections|OrderedDictionary")

$generatedHandoffContentQualityAccepted = $actionPlanContentValid -and $requiredEvidenceContentValid -and $blockerResolutionMapContentValid -and $ciCommandsContentValid -and $ownerPacketsContentValid
$externalEvidencePreflightAccepted = $preflightScriptContentValid -and $preflightSelfCheckValid

$ownerPacketGeneratedFiles = @("production-handoff-package/owner-packets/owner-packet-index.json")
$ownerPacketGeneratedFiles += @($ownerPackets | ForEach-Object { [string]$_["packetPath"] })

$generatedFiles = @(
    "production-handoff-package/README.md",
    "production-handoff-package/action-plan.md",
    "production-handoff-package/required-external-evidence.json",
    "production-handoff-package/blocker-resolution-map.json",
    "production-handoff-package/blocker-resolution-map.md",
    "production-handoff-package/ci-commands.ps1",
    "production-handoff-package/verify-external-evidence.ps1",
    "production-handoff-package/accept-external-evidence.ps1",
    "production-handoff-package/external-evidence-preflight-self-check.json"
)
$generatedFiles += @($ownerPacketGeneratedFiles)

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
Add-HandoffCheck "blocker_resolution_map" `
    $blockerResolutionMapContentValid `
    "Generated handoff package must map every remaining production blocker to owner, evidence files, acceptance criteria, and validation commands."
Add-HandoffCheck "external_evidence_preflight_script" `
    $externalEvidencePreflightAccepted `
    "Generated handoff package must include a runnable external evidence preflight script with a pending self-check."
Add-HandoffCheck "external_evidence_acceptance_wrapper" `
    $acceptanceWrapperScriptContentValid `
    "Generated handoff package must include a runnable external evidence acceptance wrapper that writes a Markdown report and can launch hard validation."
Add-HandoffCheck "owner_action_packets" `
    $ownerPacketsContentValid `
    "Generated handoff package must include one owner packet per remaining action item with required evidence, blocker, preflight, acceptance, and hard-validation commands."

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
    productionDriverEvidenceExportHelperPath = $productionDriverEvidenceExportHelperPath
    productionDriverEvidenceExportHelperCommand = $productionDriverEvidenceExportHelperCommand
    productionDriverEvidenceExportHelperDocumented = [bool]($requiredEvidenceContentValid -and $ownerPacketMarkdownText.Contains($productionDriverEvidenceExportHelperCommand))
    productionDriverEvidenceExportOutputDir = $productionDriverEvidenceExportOutputDir
    productionDriverEvidenceExportZipPath = $productionDriverEvidenceExportZipPath
    productionDriverEvidenceExportManifestPath = $productionDriverEvidenceExportManifestPath
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
    ownerPacketsGenerated = [bool](Test-Path $ownerPacketIndexPath)
    ownerPacketsContentValidated = [bool]$ownerPacketsContentValid
    ownerPacketCount = [int]$ownerPackets.Count
    ownerPacketBlockingReasonCount = [int]$ownerPacketBlockingReasonCount
    ownerPacketGeneratedFiles = @($ownerPacketGeneratedFiles)
    ciCommandsContentValidated = [bool]$ciCommandsContentValid
    externalEvidencePreflightAccepted = [bool]$externalEvidencePreflightAccepted
    preflightScriptContentValidated = [bool]$preflightScriptContentValid
    acceptanceWrapperScriptContentValidated = [bool]$acceptanceWrapperScriptContentValid
    preflightSelfCheckValidated = [bool]$preflightSelfCheckValid
    preflightSelfCheckStatus = [string]$preflightSelfCheck.status
    preflightSelfCheckMissingAreaCount = [int]$preflightSelfCheck.missingExternalEvidenceAreaCount
    hostProjectActionItemCount = [int]$actionItems.Count
    hostProjectBlockingReasonCount = [int]$hostProjectBlockingReasonCount
    blockerResolutionMapGenerated = [bool]((Test-Path $blockerResolutionJsonPath) -and (Test-Path $blockerResolutionMarkdownPath))
    blockerResolutionMapContentValidated = [bool]$blockerResolutionMapContentValid
    blockerResolutionMappedReasonCount = [int]$blockerResolutionSelfCheck.mappedBlockingReasonCount
    blockerResolutionUnmappedReasonCount = [int]$blockerResolutionSelfCheck.unmappedBlockingReasonCount
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
