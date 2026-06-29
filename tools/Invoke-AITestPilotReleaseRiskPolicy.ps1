[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ManifestPath,
    [string]$ReportPath,
    [switch]$RequireProductionReplayDriverBound,
    [switch]$RequireProductionLuaPatched,
    [switch]$RequireLiveModelEndpointSmoke
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "release-risk-policy-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "release-risk-policy.md"
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

function Convert-ToBool {
    param([object]$Value)

    if ($null -eq $Value) {
        return $false
    }

    return [bool]$Value
}

function Convert-ToInt {
    param([object]$Value)

    if ($null -eq $Value) {
        return 0
    }

    return [int]$Value
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

$riskPolicyChecks = @()
$releaseBlockers = @()
$missingOrInvalidSourceFiles = @()

function Add-PolicyCheck {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Message,
        [string]$BlockingReason = ""
    )

    $script:riskPolicyChecks += [ordered]@{
        name = $Name
        passed = [bool]$Passed
        message = $Message
    }

    if (-not $Passed) {
        if ([string]::IsNullOrWhiteSpace($BlockingReason)) {
            $BlockingReason = $Name
        }

        $script:releaseBlockers += $BlockingReason
    }
}

function Read-PolicyJson {
    param(
        [string]$FileName,
        [string]$Label
    )

    $path = Join-Path $evidenceBundlePath $FileName
    if (-not (Test-Path $path)) {
        $script:missingOrInvalidSourceFiles += $FileName
        Add-PolicyCheck ("source_file:" + $FileName) $false ($Label + " is missing.") "source_file_missing"
        return $null
    }

    try {
        Add-PolicyCheck ("source_file:" + $FileName) $true ($Label + " exists and is parseable.")
        return Get-Content -Path $path -Encoding UTF8 -Raw | ConvertFrom-Json
    }
    catch {
        $script:missingOrInvalidSourceFiles += $FileName
        Add-PolicyCheck ("source_file:" + $FileName) $false ($Label + " is not parseable: " + $_.Exception.Message) "source_file_unparseable"
        return $null
    }
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

$sceneManifest = Read-PolicyJson "manifest.json" "Release scene manifest"
$sceneValidation = Read-PolicyJson "scene-validation.json" "Scene validation report"
$bugKnowledgeGraph = Read-PolicyJson "bug-knowledge-graph.json" "Bug knowledge graph"
$patchApplyRetestManifest = Read-PolicyJson "repair-agent-patch-apply-retest-manifest.json" "Patch apply retest manifest"
$patchHistoryManifest = Read-PolicyJson "repair-agent-patch-result-history-manifest.json" "Patch result history manifest"
$productionDriverReadinessManifest = Read-PolicyJson "production-replay-driver-readiness-manifest.json" "Production replay driver readiness manifest"
$productionDriverEvidenceIntakeManifest = Read-PolicyJson "production-driver-evidence-intake-manifest.json" "Production driver evidence intake manifest"
$productionDriverEvidenceContractProbeManifest = Read-PolicyJson "production-driver-evidence-contract-probe-manifest.json" "Production driver evidence contract probe manifest"
$productionLuaPatchReadinessManifest = Read-PolicyJson "production-lua-patch-readiness-manifest.json" "Production Lua patch readiness manifest"
$productionLuaPatchEvidenceKitProbeManifest = Read-PolicyJson "production-lua-patch-evidence-kit-probe-manifest.json" "Production Lua patch evidence kit probe manifest"
$productionLuaPatchExternalBundleIntakeProbeManifest = Read-PolicyJson "production-lua-patch-external-bundle-intake-probe-manifest.json" "Production Lua patch external bundle intake probe manifest"
$liveModelFailureProbeManifest = Read-PolicyJson "live-model-endpoint-failure-probe-manifest.json" "Live model endpoint failure probe manifest"
$liveModelSmokeManifest = Read-PolicyJson "live-model-endpoint-smoke-manifest.json" "Live model endpoint smoke manifest"
$liveModelConfigKitProbeManifest = Read-PolicyJson "live-model-endpoint-config-kit-probe-manifest.json" "Live model endpoint config kit probe manifest"
$liveModelExternalSmokeIntakeProbeManifest = Read-PolicyJson "live-model-endpoint-external-smoke-intake-probe-manifest.json" "Live model endpoint external smoke intake probe manifest"
$liveModelSmokeEvidenceContractProbeManifest = Read-PolicyJson "live-model-endpoint-smoke-evidence-contract-probe-manifest.json" "Live model endpoint smoke evidence contract probe manifest"
$githubActionsProbeManifest = Read-PolicyJson "github-actions-release-workflow-probe-manifest.json" "GitHub Actions workflow probe manifest"
$azurePipelinesProbeManifest = Read-PolicyJson "azure-pipelines-release-workflow-probe-manifest.json" "Azure Pipelines workflow probe manifest"
$providerCiQualityProbeManifest = Read-PolicyJson "provider-ci-quality-probe-manifest.json" "Provider CI quality probe manifest"
$productionHandoffPackageManifest = Read-PolicyJson "production-handoff-package-manifest.json" "Production handoff package manifest"
$productionHardModeFailureProbeManifest = Read-PolicyJson "production-hard-mode-failure-probe-manifest.json" "Production hard-mode failure probe manifest"

$runReports = @()
if ($null -ne $sceneValidation) {
    $runReports = Convert-ToArray (Get-JsonValue $sceneValidation "runReports" $null)
}

$unexpectedFailedRunReports = @($runReports | Where-Object {
        $outcome = [string](Get-JsonValue $_ "outcome" "")
        -not [string]::IsNullOrWhiteSpace($outcome) -and
            $outcome -ne "PASSED" -and
            $outcome -ne "BUG_DETECTED"
    })
$bugDetectedRunReports = @($runReports | Where-Object { [string](Get-JsonValue $_ "outcome" "") -eq "BUG_DETECTED" })

$sceneStatusPassed = (
    $null -ne $sceneManifest -and
    $sceneManifest.status -eq "PASS" -and
    (Convert-ToBool (Get-JsonValue $sceneManifest "allowRelease" $false)) -and
    (Convert-ToBool (Get-JsonValue $sceneManifest "retestPassed" $false)) -and
    (Convert-ToInt (Get-JsonValue $sceneManifest "unverifiedHighRiskBugCount" 0)) -eq 0
)
$sceneValidationPassed = (
    $null -ne $sceneValidation -and
    $sceneValidation.status -eq "PASS" -and
    $null -ne (Get-JsonValue $sceneValidation "releaseEvidence" $null) -and
    (Convert-ToBool (Get-JsonValue $sceneValidation.releaseEvidence "allowRelease" $false)) -and
    @((Convert-ToArray (Get-JsonValue $sceneValidation.releaseEvidence "failedReasons" $null))).Count -eq 0
)
$retestReportPassed = (
    $null -ne $sceneValidation -and
    $null -ne (Get-JsonValue $sceneValidation "retestReport" $null) -and
    (Convert-ToBool (Get-JsonValue $sceneValidation.retestReport "passed" $false))
)
$patchRetestPassed = (
    $null -ne $patchApplyRetestManifest -and
    $patchApplyRetestManifest.status -eq "PASS" -and
    (Convert-ToBool (Get-JsonValue $patchApplyRetestManifest "postPatchRetestPassed" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $patchApplyRetestManifest "postPatchBugStillPresent" $true))
)
$aiExplorationAccepted = (
    $sceneStatusPassed -and
    $sceneValidationPassed -and
    $unexpectedFailedRunReports.Count -eq 0 -and
    ($bugDetectedRunReports.Count -eq 0 -or ($retestReportPassed -and $patchRetestPassed))
)

Add-PolicyCheck "ai_exploration_release_evidence" $aiExplorationAccepted `
    "AI exploration must have passing release evidence, no unexpected failed run reports, and any detected high-risk bug must have passing retest evidence." `
    "ai_exploration_not_release_ready"

$graphHighRiskCount = 0
if ($null -ne $bugKnowledgeGraph) {
    $graphHighRiskCount = Convert-ToInt (Get-JsonValue $bugKnowledgeGraph "highRiskCount" 0)
}
elseif ($null -ne $sceneManifest -and $null -ne (Get-JsonValue $sceneManifest "summary" $null)) {
    $graphHighRiskCount = Convert-ToInt (Get-JsonValue $sceneManifest.summary "bugKnowledgeGraphHighRiskCount" 0)
}

$unverifiedHighRiskBugCount = 0
if ($null -ne $sceneManifest) {
    $unverifiedHighRiskBugCount = Convert-ToInt (Get-JsonValue $sceneManifest "unverifiedHighRiskBugCount" 0)
}

$unresolvedHighRiskGraphNodeCount = 0
if ($null -ne $patchHistoryManifest) {
    $unresolvedHighRiskGraphNodeCount = Convert-ToInt (Get-JsonValue $patchHistoryManifest "unresolvedHighRiskCount" 0)
}

$highRiskPolicyAccepted = (
    $null -ne $patchHistoryManifest -and
    $patchHistoryManifest.status -eq "PASS" -and
    $unverifiedHighRiskBugCount -eq 0 -and
    $unresolvedHighRiskGraphNodeCount -eq 0 -and
    (Convert-ToBool (Get-JsonValue $patchHistoryManifest "currentAnalysisIncluded" $false)) -and
    (Convert-ToInt (Get-JsonValue $patchHistoryManifest "retestPassedCount" 0)) -ge 1 -and
    (Convert-ToInt (Get-JsonValue $patchHistoryManifest "rollbackVerifiedCount" 0)) -ge 1 -and
    (Convert-ToInt (Get-JsonValue $patchHistoryManifest "blockingReasonCount" 0)) -eq 0
)

Add-PolicyCheck "high_risk_graph_resolution" $highRiskPolicyAccepted `
    "High-risk graph nodes must be covered by retest/rollback history with zero unresolved or unverified high-risk nodes." `
    "high_risk_graph_not_resolved"

$driverEvidenceAccepted = $false
$driverEvidenceStatus = "BLOCKED"
$driverReadyForProduction = $false

if ($null -ne $productionDriverReadinessManifest -and $null -ne $productionDriverEvidenceIntakeManifest) {
    $driverReadyForProduction = Convert-ToBool (Get-JsonValue $productionDriverReadinessManifest "readyForProductionDriverRelease" $false)
    if ([bool]$RequireProductionReplayDriverBound) {
        $driverEvidenceAccepted = (
            $productionDriverReadinessManifest.status -eq "PASS" -and
            $productionDriverEvidenceIntakeManifest.status -eq "PASS" -and
            $driverReadyForProduction -and
            (Convert-ToBool (Get-JsonValue $productionDriverEvidenceIntakeManifest "intakeAccepted" $false)) -and
            (Convert-ToBool (Get-JsonValue $productionDriverReadinessManifest "realProjectBound" $false)) -and
            -not (Convert-ToBool (Get-JsonValue $productionDriverReadinessManifest "sampleGameReplayDriverUsed" $true)) -and
            (Convert-ToBool (Get-JsonValue $productionDriverReadinessManifest "externalProductionDriverSelected" $false)) -and
            (Convert-ToInt (Get-JsonValue $productionDriverReadinessManifest "unresolvedRequiredHookCount" 0)) -eq 0 -and
            (Convert-ToInt (Get-JsonValue $productionDriverReadinessManifest "blockingReasonCount" 0)) -eq 0
        )
        if ($driverEvidenceAccepted) {
            $driverEvidenceStatus = "PRODUCTION_BOUND_ACCEPTED"
        }
        else {
            $driverEvidenceStatus = "PRODUCTION_BOUND_REQUIRED_BUT_NOT_READY"
        }
    }
    else {
        $expectedSampleDriverReasons = @(
            "production_replay_integration_not_bound",
            "required_hooks_not_all_bound",
            "unresolved_required_hooks",
            "sample_game_replay_driver_used",
            "external_production_driver_not_selected"
        )
        $driverBlockingReasons = Convert-ToArray (Get-JsonValue $productionDriverReadinessManifest "blockingReasons" $null)
        $driverEvidenceAccepted = (
            $productionDriverReadinessManifest.status -eq "PASS" -and
            $productionDriverEvidenceIntakeManifest.status -eq "PASS" -and
            -not $driverReadyForProduction -and
            (Convert-ToBool (Get-JsonValue $productionDriverReadinessManifest "packageReleaseAllowedWithoutProductionBinding" $false)) -and
            -not (Convert-ToBool (Get-JsonValue $productionDriverReadinessManifest "productionBindingRequiredForPackageRelease" $true)) -and
            (Convert-ToBool (Get-JsonValue $productionDriverEvidenceIntakeManifest "expectedBlocked" $false)) -and
            (Convert-ToBool (Get-JsonValue $productionDriverEvidenceIntakeManifest "expectedBlockedPassed" $false)) -and
            (Convert-ToBool (Get-JsonValue $productionDriverEvidenceIntakeManifest "expectedSampleBlockingReasonsFound" $false)) -and
            (Test-ContainsAll -Actual $driverBlockingReasons -Required $expectedSampleDriverReasons)
        )
        if ($driverEvidenceAccepted) {
            $driverEvidenceStatus = "EXPLICIT_SAMPLE_BOUNDARY_ACCEPTED"
        }
        else {
            $driverEvidenceStatus = "SAMPLE_BOUNDARY_NOT_PROVEN"
        }
    }
}

Add-PolicyCheck "production_driver_evidence_policy" $driverEvidenceAccepted `
    "Driver evidence must either be production-bound when required or explicitly accepted as sample/unbound package-release evidence with a hard-bound failure probe." `
    "production_driver_evidence_not_accepted"

$productionDriverEvidenceContractAccepted = (
    $null -ne $productionDriverEvidenceContractProbeManifest -and
    $productionDriverEvidenceContractProbeManifest.status -eq "PASS" -and
    (Get-JsonValue $productionDriverEvidenceContractProbeManifest "schemaVersion" "") -eq "aitestpilot.production_driver_evidence_contract_probe.v1" -and
    (Convert-ToBool (Get-JsonValue $productionDriverEvidenceContractProbeManifest "acceptedFixtureGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionDriverEvidenceContractProbeManifest "acceptedFixtureIntakePassed" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionDriverEvidenceContractProbeManifest "acceptedFixtureReadinessPassed" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionDriverEvidenceContractProbeManifest "acceptedFixtureReadyForProductionDriverRelease" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionDriverEvidenceContractProbeManifest "acceptedFixtureRealProjectBound" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionDriverEvidenceContractProbeManifest "acceptedFixtureExternalProductionDriverSelected" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $productionDriverEvidenceContractProbeManifest "acceptedFixtureSampleGameReplayDriverUsed" $true)) -and
    (Convert-ToInt (Get-JsonValue $productionDriverEvidenceContractProbeManifest "acceptedFixtureBlockingReasonCount" 1)) -eq 0 -and
    -not (Convert-ToBool (Get-JsonValue $productionDriverEvidenceContractProbeManifest "releasePipelineUsesFixture" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionDriverEvidenceContractProbeManifest "realProductionDriverEvidenceAccepted" $true)) -and
    (Get-JsonValue $productionDriverEvidenceContractProbeManifest "productionOutputBoundary" "") -eq "accepted_fixture_contract_only" -and
    (Convert-ToInt (Get-JsonValue $productionDriverEvidenceContractProbeManifest "failedCheckCount" 1)) -eq 0
)

Add-PolicyCheck "production_driver_evidence_contract_policy" $productionDriverEvidenceContractAccepted `
    "Production driver evidence must include an isolated accepted-fixture contract proving BOUND host evidence can pass intake without promoting fixture data as production." `
    "production_driver_evidence_contract_not_accepted"

$productionLuaEvidenceAccepted = $false
$productionLuaEvidenceStatus = "BLOCKED"
$productionLuaReadyForProduction = $false

if ($null -ne $productionLuaPatchReadinessManifest) {
    $productionLuaReadyForProduction = Convert-ToBool (Get-JsonValue $productionLuaPatchReadinessManifest "readyForProductionLuaPatchRelease" $false)
    if ([bool]$RequireProductionLuaPatched) {
        $productionLuaEvidenceAccepted = (
            $productionLuaPatchReadinessManifest.status -eq "PASS" -and
            $productionLuaReadyForProduction -and
            (Convert-ToBool (Get-JsonValue $productionLuaPatchReadinessManifest "productionLuaEvidenceAccepted" $false)) -and
            (Convert-ToBool (Get-JsonValue $productionLuaPatchReadinessManifest "realProductionLuaAnalyzed" $false)) -and
            (Convert-ToBool (Get-JsonValue $productionLuaPatchReadinessManifest "realProductionLuaPatched" $false)) -and
            (Convert-ToBool (Get-JsonValue $productionLuaPatchReadinessManifest "productionRetestPassed" $false)) -and
            (Convert-ToBool (Get-JsonValue $productionLuaPatchReadinessManifest "rollbackVerified" $false)) -and
            (Convert-ToInt (Get-JsonValue $productionLuaPatchReadinessManifest "blockingReasonCount" 0)) -eq 0
        )
        if ($productionLuaEvidenceAccepted) {
            $productionLuaEvidenceStatus = "PRODUCTION_LUA_PATCH_ACCEPTED"
        }
        else {
            $productionLuaEvidenceStatus = "PRODUCTION_LUA_PATCH_REQUIRED_BUT_NOT_READY"
        }
    }
    else {
        $expectedLuaReasons = @(
            "real_production_lua_bundle_missing",
            "real_production_lua_not_analyzed",
            "real_production_lua_not_patched",
            "production_lua_retest_evidence_missing",
            "real_production_patch_rollback_missing"
        )
        $luaBlockingReasons = Convert-ToArray (Get-JsonValue $productionLuaPatchReadinessManifest "blockingReasons" $null)
        $productionLuaEvidenceAccepted = (
            $productionLuaPatchReadinessManifest.status -eq "PASS" -and
            -not $productionLuaReadyForProduction -and
            (Convert-ToBool (Get-JsonValue $productionLuaPatchReadinessManifest "packageReleaseAllowedWithoutProductionLuaPatch" $false)) -and
            -not (Convert-ToBool (Get-JsonValue $productionLuaPatchReadinessManifest "productionLuaPatchRequiredForPackageRelease" $true)) -and
            (Convert-ToBool (Get-JsonValue $productionLuaPatchReadinessManifest "staticAnalysisPassed" $false)) -and
            (Convert-ToBool (Get-JsonValue $productionLuaPatchReadinessManifest "sandboxAfterFindingsCleared" $false)) -and
            (Convert-ToBool (Get-JsonValue $productionLuaPatchReadinessManifest "sandboxBoundaryPreserved" $false)) -and
            (Get-JsonValue $productionLuaPatchReadinessManifest "productionOutputBoundary" "") -eq "real_production_lua_patch_not_claimed" -and
            (Test-ContainsAll -Actual $luaBlockingReasons -Required $expectedLuaReasons)
        )
        if ($productionLuaEvidenceAccepted) {
            $productionLuaEvidenceStatus = "EXPLICIT_NO_PRODUCTION_LUA_BOUNDARY_ACCEPTED"
        }
        else {
            $productionLuaEvidenceStatus = "NO_PRODUCTION_LUA_BOUNDARY_NOT_PROVEN"
        }
    }
}

Add-PolicyCheck "production_lua_patch_policy" $productionLuaEvidenceAccepted `
    "Lua patch evidence must either be real production patch evidence when required or explicit sandbox-only package-release evidence with production blockers recorded." `
    "production_lua_evidence_not_accepted"

$productionLuaEvidenceKitAccepted = (
    $null -ne $productionLuaPatchEvidenceKitProbeManifest -and
    $productionLuaPatchEvidenceKitProbeManifest.status -eq "PASS" -and
    (Get-JsonValue $productionLuaPatchEvidenceKitProbeManifest "schemaVersion" "") -eq "aitestpilot.production_lua_patch_evidence_kit_probe.v1" -and
    (Convert-ToBool (Get-JsonValue $productionLuaPatchEvidenceKitProbeManifest "templateKitGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionLuaPatchEvidenceKitProbeManifest "templateOnly" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $productionLuaPatchEvidenceKitProbeManifest "templateEvidenceAccepted" $true)) -and
    (Convert-ToBool (Get-JsonValue $productionLuaPatchEvidenceKitProbeManifest "acceptedFixtureGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionLuaPatchEvidenceKitProbeManifest "acceptedFixtureProbePassed" $false)) -and
    (Get-JsonValue $productionLuaPatchEvidenceKitProbeManifest "acceptedFixtureBoundary" "") -eq "contract_fixture_only_not_real_host_project" -and
    -not (Convert-ToBool (Get-JsonValue $productionLuaPatchEvidenceKitProbeManifest "releasePipelineUsesFixture" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionLuaPatchEvidenceKitProbeManifest "realProductionLuaPatchEvidenceAccepted" $true)) -and
    (Convert-ToBool (Get-JsonValue $productionLuaPatchEvidenceKitProbeManifest "productionLuaEvidenceDirRequiredForProduction" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionLuaPatchEvidenceKitProbeManifest "acceptedReadinessReady" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionLuaPatchEvidenceKitProbeManifest "acceptedReadinessEvidenceAccepted" $false)) -and
    (Convert-ToInt (Get-JsonValue $productionLuaPatchEvidenceKitProbeManifest "acceptedReadinessBlockingReasonCount" 1)) -eq 0 -and
    (Convert-ToInt (Get-JsonValue $productionLuaPatchEvidenceKitProbeManifest "failedCheckCount" 1)) -eq 0
)

Add-PolicyCheck "production_lua_evidence_kit_policy" $productionLuaEvidenceKitAccepted `
    "Production Lua patch evidence must include a host-project evidence kit and isolated accepted-fixture readiness contract without promoting fixture evidence as production." `
    "production_lua_evidence_kit_not_accepted"

$productionLuaExternalBundleIntakeAccepted = (
    $null -ne $productionLuaPatchExternalBundleIntakeProbeManifest -and
    $productionLuaPatchExternalBundleIntakeProbeManifest.status -eq "PASS" -and
    (Get-JsonValue $productionLuaPatchExternalBundleIntakeProbeManifest "schemaVersion" "") -eq "aitestpilot.production_lua_patch_external_bundle_intake_probe.v1" -and
    -not (Convert-ToBool (Get-JsonValue $productionLuaPatchExternalBundleIntakeProbeManifest "externalBundleUnderRepo" $true)) -and
    (Convert-ToBool (Get-JsonValue $productionLuaPatchExternalBundleIntakeProbeManifest "templateEvidenceGenerated" $false)) -and
    (Get-JsonValue $productionLuaPatchExternalBundleIntakeProbeManifest "templateEvidenceStatus" "") -eq "PENDING_PRODUCTION_EVIDENCE" -and
    (Convert-ToBool (Get-JsonValue $productionLuaPatchExternalBundleIntakeProbeManifest "templateEvidenceRead" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionLuaPatchExternalBundleIntakeProbeManifest "expectedBlockedPassed" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionLuaPatchExternalBundleIntakeProbeManifest "readinessCommandFailed" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $productionLuaPatchExternalBundleIntakeProbeManifest "readyForProductionLuaPatchRelease" $true)) -and
    (Convert-ToBool (Get-JsonValue $productionLuaPatchExternalBundleIntakeProbeManifest "productionLuaBundleProvided" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionLuaPatchExternalBundleIntakeProbeManifest "productionLuaEvidenceCopied" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $productionLuaPatchExternalBundleIntakeProbeManifest "productionLuaEvidenceAccepted" $true)) -and
    (Get-JsonValue $productionLuaPatchExternalBundleIntakeProbeManifest "productionOutputBoundary" "") -eq "real_production_lua_patch_not_claimed" -and
    (Convert-ToBool (Get-JsonValue $productionLuaPatchExternalBundleIntakeProbeManifest "expectedBlockingReasonsFound" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionLuaPatchExternalBundleIntakeProbeManifest "readinessRequireProductionLuaPatched" $false)) -and
    (Convert-ToInt (Get-JsonValue $productionLuaPatchExternalBundleIntakeProbeManifest "failedCheckCount" 1)) -eq 0
)

Add-PolicyCheck "production_lua_external_bundle_intake_policy" $productionLuaExternalBundleIntakeAccepted `
    "Production Lua patch evidence intake must prove repo-external evidence directories are inspected and incomplete template evidence is blocked under hard production mode." `
    "production_lua_external_bundle_intake_not_accepted"

$liveModelPolicyAccepted = $false
$liveModelPolicyStatus = "BLOCKED"

if ($null -ne $liveModelSmokeManifest -and $null -ne $liveModelFailureProbeManifest) {
    if ([bool]$RequireLiveModelEndpointSmoke) {
        $liveModelPolicyAccepted = (
            $liveModelSmokeManifest.status -eq "PASS" -and
            (Convert-ToBool (Get-JsonValue $liveModelSmokeManifest "endpointConfigured" $false)) -and
            (Convert-ToBool (Get-JsonValue $liveModelSmokeManifest "modelConfigured" $false)) -and
            (Convert-ToBool (Get-JsonValue $liveModelSmokeManifest "responseValidated" $false)) -and
            (Get-JsonValue $liveModelSmokeManifest "traceStatus" "") -eq "PASS"
        )
        if ($liveModelPolicyAccepted) {
            $liveModelPolicyStatus = "LIVE_MODEL_SMOKE_ACCEPTED"
        }
        else {
            $liveModelPolicyStatus = "LIVE_MODEL_SMOKE_REQUIRED_BUT_NOT_READY"
        }
    }
    elseif ($liveModelSmokeManifest.status -eq "PASS") {
        $liveModelPolicyAccepted = (
            (Convert-ToBool (Get-JsonValue $liveModelSmokeManifest "responseValidated" $false)) -and
            (Get-JsonValue $liveModelSmokeManifest "traceStatus" "") -eq "PASS"
        )
        if ($liveModelPolicyAccepted) {
            $liveModelPolicyStatus = "OPTIONAL_LIVE_MODEL_SMOKE_ACCEPTED"
        }
        else {
            $liveModelPolicyStatus = "OPTIONAL_LIVE_MODEL_SMOKE_NOT_VALID"
        }
    }
    elseif ($liveModelSmokeManifest.status -eq "SKIPPED") {
        $liveModelPolicyAccepted = (
            -not (Convert-ToBool (Get-JsonValue $liveModelSmokeManifest "required" $true)) -and
            $liveModelFailureProbeManifest.status -eq "PASS" -and
            (Convert-ToBool (Get-JsonValue $liveModelFailureProbeManifest "expectedFailure" $false)) -and
            (Get-JsonValue $liveModelFailureProbeManifest "failureCategory" "") -eq "auth" -and
            $null -ne (Get-JsonValue $liveModelFailureProbeManifest "failurePolicy" $null) -and
            (Get-JsonValue $liveModelFailureProbeManifest.failurePolicy "releaseGateAction" "") -eq "block"
        )
        if ($liveModelPolicyAccepted) {
            $liveModelPolicyStatus = "OPTIONAL_LIVE_MODEL_SKIP_ACCEPTED_WITH_FAILURE_POLICY"
        }
        else {
            $liveModelPolicyStatus = "OPTIONAL_LIVE_MODEL_SKIP_NOT_PROVEN"
        }
    }
    else {
        $liveModelPolicyStatus = "LIVE_MODEL_SMOKE_FAILED"
    }
}

Add-PolicyCheck "live_model_endpoint_policy" $liveModelPolicyAccepted `
    "Live model smoke must pass when required; otherwise the optional skip must be paired with deterministic failure-classification policy evidence." `
    "live_model_endpoint_policy_not_accepted"

$liveModelConfigKitAccepted = (
    $null -ne $liveModelConfigKitProbeManifest -and
    $liveModelConfigKitProbeManifest.status -eq "PASS" -and
    (Get-JsonValue $liveModelConfigKitProbeManifest "schemaVersion" "") -eq "aitestpilot.live_model_endpoint_config_kit_probe.v1" -and
    (Convert-ToBool (Get-JsonValue $liveModelConfigKitProbeManifest "templateKitGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $liveModelConfigKitProbeManifest "templateOnly" $false)) -and
    (Convert-ToBool (Get-JsonValue $liveModelConfigKitProbeManifest "acceptedFixtureGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $liveModelConfigKitProbeManifest "acceptedFixtureIntakePassed" $false)) -and
    (Convert-ToBool (Get-JsonValue $liveModelConfigKitProbeManifest "acceptedFixtureReadyForLiveEndpointSmoke" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $liveModelConfigKitProbeManifest "acceptedFixtureProductionLiveAccessProven" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $liveModelConfigKitProbeManifest "acceptedFixtureLiveSmokeExecuted" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $liveModelConfigKitProbeManifest "externalConfigUnderRepo" $true)) -and
    (Convert-ToBool (Get-JsonValue $liveModelConfigKitProbeManifest "externalTemplateRead" $false)) -and
    (Convert-ToBool (Get-JsonValue $liveModelConfigKitProbeManifest "externalTemplateBlocked" $false)) -and
    (Convert-ToBool (Get-JsonValue $liveModelConfigKitProbeManifest "externalTemplateCommandFailed" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $liveModelConfigKitProbeManifest "releasePipelineUsesFixture" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $liveModelConfigKitProbeManifest "productionLiveEndpointAccessProven" $true)) -and
    (Convert-ToBool (Get-JsonValue $liveModelConfigKitProbeManifest "liveSmokeRequiredForProduction" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $liveModelConfigKitProbeManifest "liveSmokeExecuted" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $liveModelConfigKitProbeManifest "secretsSerialized" $true)) -and
    (Convert-ToInt (Get-JsonValue $liveModelConfigKitProbeManifest "failedCheckCount" 1)) -eq 0
)

Add-PolicyCheck "live_model_endpoint_config_kit_policy" $liveModelConfigKitAccepted `
    "Live model endpoint evidence must include static config kit and external pending-config intake proof without serializing secrets or claiming provider access." `
    "live_model_endpoint_config_kit_not_accepted"

$liveModelExternalSmokeIntakeAccepted = (
    $null -ne $liveModelExternalSmokeIntakeProbeManifest -and
    $liveModelExternalSmokeIntakeProbeManifest.status -eq "PASS" -and
    (Get-JsonValue $liveModelExternalSmokeIntakeProbeManifest "schemaVersion" "") -eq "aitestpilot.live_model_endpoint_external_smoke_intake_probe.v1" -and
    -not (Convert-ToBool (Get-JsonValue $liveModelExternalSmokeIntakeProbeManifest "externalBundleUnderRepo" $true)) -and
    (Convert-ToBool (Get-JsonValue $liveModelExternalSmokeIntakeProbeManifest "expectedBlocked" $false)) -and
    (Convert-ToBool (Get-JsonValue $liveModelExternalSmokeIntakeProbeManifest "expectedBlockedPassed" $false)) -and
    (Convert-ToBool (Get-JsonValue $liveModelExternalSmokeIntakeProbeManifest "intakeCommandFailed" $false)) -and
    (Convert-ToBool (Get-JsonValue $liveModelExternalSmokeIntakeProbeManifest "externalSmokeRead" $false)) -and
    (Get-JsonValue $liveModelExternalSmokeIntakeProbeManifest "externalSmokeStatus" "") -eq "SKIPPED" -and
    -not (Convert-ToBool (Get-JsonValue $liveModelExternalSmokeIntakeProbeManifest "smokeEvidenceAccepted" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $liveModelExternalSmokeIntakeProbeManifest "productionLiveEndpointAccessProven" $true)) -and
    (Convert-ToBool (Get-JsonValue $liveModelExternalSmokeIntakeProbeManifest "requireLiveModelEndpointSmoke" $false)) -and
    (Convert-ToInt (Get-JsonValue $liveModelExternalSmokeIntakeProbeManifest "failedCheckCount" 1)) -eq 0
)

Add-PolicyCheck "live_model_endpoint_external_smoke_intake_policy" $liveModelExternalSmokeIntakeAccepted `
    "Live model endpoint smoke evidence intake must prove repo-external smoke evidence is inspected and skipped evidence is blocked when live smoke is required." `
    "live_model_endpoint_external_smoke_intake_not_accepted"

$liveModelSmokeEvidenceContractAccepted = (
    $null -ne $liveModelSmokeEvidenceContractProbeManifest -and
    $liveModelSmokeEvidenceContractProbeManifest.status -eq "PASS" -and
    (Get-JsonValue $liveModelSmokeEvidenceContractProbeManifest "schemaVersion" "") -eq "aitestpilot.live_model_endpoint_smoke_evidence_contract_probe.v1" -and
    -not (Convert-ToBool (Get-JsonValue $liveModelSmokeEvidenceContractProbeManifest "externalBundleUnderRepo" $true)) -and
    (Convert-ToBool (Get-JsonValue $liveModelSmokeEvidenceContractProbeManifest "acceptedFixtureGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $liveModelSmokeEvidenceContractProbeManifest "acceptedFixtureIntakePassed" $false)) -and
    (Convert-ToBool (Get-JsonValue $liveModelSmokeEvidenceContractProbeManifest "acceptedFixtureSmokeEvidenceAccepted" $false)) -and
    (Convert-ToBool (Get-JsonValue $liveModelSmokeEvidenceContractProbeManifest "acceptedFixtureProductionLiveEndpointAccessProven" $false)) -and
    (Convert-ToBool (Get-JsonValue $liveModelSmokeEvidenceContractProbeManifest "acceptedFixtureCanonicalSmokePromoted" $false)) -and
    (Convert-ToBool (Get-JsonValue $liveModelSmokeEvidenceContractProbeManifest "acceptedFixtureCanonicalTracePromoted" $false)) -and
    (Convert-ToBool (Get-JsonValue $liveModelSmokeEvidenceContractProbeManifest "acceptedFixtureSmokeContractPassed" $false)) -and
    (Convert-ToBool (Get-JsonValue $liveModelSmokeEvidenceContractProbeManifest "acceptedFixtureTraceContractPassed" $false)) -and
    (Convert-ToInt (Get-JsonValue $liveModelSmokeEvidenceContractProbeManifest "acceptedFixtureBlockingReasonCount" 1)) -eq 0 -and
    -not (Convert-ToBool (Get-JsonValue $liveModelSmokeEvidenceContractProbeManifest "releasePipelineUsesFixture" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $liveModelSmokeEvidenceContractProbeManifest "realProductionLiveEndpointAccessProven" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $liveModelSmokeEvidenceContractProbeManifest "realLiveSmokeExecuted" $true)) -and
    (Get-JsonValue $liveModelSmokeEvidenceContractProbeManifest "productionOutputBoundary" "") -eq "accepted_fixture_contract_only" -and
    (Convert-ToInt (Get-JsonValue $liveModelSmokeEvidenceContractProbeManifest "failedCheckCount" 1)) -eq 0
)

Add-PolicyCheck "live_model_endpoint_smoke_evidence_contract_policy" $liveModelSmokeEvidenceContractAccepted `
    "Live model endpoint smoke evidence must include an accepted-fixture contract proving PASS host-project smoke evidence can be accepted without promoting fixture access as real provider evidence." `
    "live_model_endpoint_smoke_evidence_contract_not_accepted"

$githubActionsAccepted = (
    $null -ne $githubActionsProbeManifest -and
    $githubActionsProbeManifest.status -eq "PASS" -and
    (Get-JsonValue $githubActionsProbeManifest "schemaVersion" "") -eq "aitestpilot.github_actions_release_workflow_probe.v1" -and
    (Convert-ToBool (Get-JsonValue $githubActionsProbeManifest "releasePipelineCommandFound" $false)) -and
    (Convert-ToBool (Get-JsonValue $githubActionsProbeManifest "manifestStatusCheckConfigured" $false)) -and
    (Convert-ToBool (Get-JsonValue $githubActionsProbeManifest "ciExitCodeCheckConfigured" $false)) -and
    (Convert-ToInt (Get-JsonValue $githubActionsProbeManifest "failedCheckCount" 0)) -eq 0
)
$azurePipelinesAccepted = (
    $null -ne $azurePipelinesProbeManifest -and
    $azurePipelinesProbeManifest.status -eq "PASS" -and
    (Get-JsonValue $azurePipelinesProbeManifest "schemaVersion" "") -eq "aitestpilot.azure_pipelines_release_workflow_probe.v1" -and
    (Convert-ToBool (Get-JsonValue $azurePipelinesProbeManifest "releasePipelineCommandFound" $false)) -and
    (Convert-ToBool (Get-JsonValue $azurePipelinesProbeManifest "manifestStatusCheckConfigured" $false)) -and
    (Convert-ToBool (Get-JsonValue $azurePipelinesProbeManifest "ciExitCodeCheckConfigured" $false)) -and
    (Convert-ToInt (Get-JsonValue $azurePipelinesProbeManifest "failedCheckCount" 0)) -eq 0
)
$providerCiQualityAccepted = (
    $null -ne $providerCiQualityProbeManifest -and
    $providerCiQualityProbeManifest.status -eq "PASS" -and
    (Get-JsonValue $providerCiQualityProbeManifest "schemaVersion" "") -eq "aitestpilot.provider_ci_quality_probe.v1" -and
    (Convert-ToBool (Get-JsonValue $providerCiQualityProbeManifest "providerQualityAccepted" $false)) -and
    (Convert-ToBool (Get-JsonValue $providerCiQualityProbeManifest "githubActionsQualityAccepted" $false)) -and
    (Convert-ToBool (Get-JsonValue $providerCiQualityProbeManifest "azurePipelinesQualityAccepted" $false)) -and
    (Convert-ToInt (Get-JsonValue $providerCiQualityProbeManifest "providerCount" 0)) -eq 2 -and
    (Convert-ToInt (Get-JsonValue $providerCiQualityProbeManifest "buildCheckProviderCount" 0)) -eq 2 -and
    (Convert-ToInt (Get-JsonValue $providerCiQualityProbeManifest "smokeTestProviderCount" 0)) -eq 2 -and
    (Convert-ToInt (Get-JsonValue $providerCiQualityProbeManifest "visionCheckProviderCount" 0)) -eq 2 -and
    (Convert-ToInt (Get-JsonValue $providerCiQualityProbeManifest "failedCheckCount" 0)) -eq 0
)
$ciProviderEvidenceAccepted = $githubActionsAccepted -and $azurePipelinesAccepted -and $providerCiQualityAccepted

Add-PolicyCheck "ci_provider_release_controls" $ciProviderEvidenceAccepted `
    "GitHub Actions and Azure Pipelines provider workflows must expose release controls, provider build/test/vision checks, manifest enforcement, and evidence publishing." `
    "ci_provider_release_controls_not_accepted"

$productionHandoffPackageAccepted = (
    $null -ne $productionHandoffPackageManifest -and
    $productionHandoffPackageManifest.status -eq "PASS" -and
    (Get-JsonValue $productionHandoffPackageManifest "schemaVersion" "") -eq "aitestpilot.production_handoff_package.v1" -and
    (Convert-ToBool (Get-JsonValue $productionHandoffPackageManifest "hostProjectHandoffReady" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffPackageManifest "externalEvidenceRequiredForProduction" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffPackageManifest "productionDriverHandoffReady" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffPackageManifest "productionLuaHandoffReady" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffPackageManifest "liveModelHandoffReady" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffPackageManifest "ciReleaseControlsReady" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffPackageManifest "fixtureEvidencePromoted" $true)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffPackageManifest "generatedHandoffContentQualityAccepted" $false)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffPackageManifest "sourceManifestCount" 0)) -ge 12 -and
    (Convert-ToInt (Get-JsonValue $productionHandoffPackageManifest "generatedFileCount" 0)) -ge 4 -and
    (Convert-ToInt (Get-JsonValue $productionHandoffPackageManifest "failedCheckCount" 1)) -eq 0
)

Add-PolicyCheck "production_handoff_package_policy" $productionHandoffPackageAccepted `
    "Release evidence must include a production handoff package that consolidates driver, Lua, live-model, and CI host-project next steps without promoting fixture evidence." `
    "production_handoff_package_not_accepted"

$productionHardModeFailureAccepted = (
    $null -ne $productionHardModeFailureProbeManifest -and
    $productionHardModeFailureProbeManifest.status -eq "PASS" -and
    (Get-JsonValue $productionHardModeFailureProbeManifest "schemaVersion" "") -eq "aitestpilot.production_hard_mode_failure_probe.v1" -and
    (Convert-ToBool (Get-JsonValue $productionHardModeFailureProbeManifest "requireProductionReplayDriverBound" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHardModeFailureProbeManifest "requireProductionLuaPatched" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHardModeFailureProbeManifest "requireLiveModelEndpointSmoke" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHardModeFailureProbeManifest "riskPolicyBlockedAsExpected" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHardModeFailureProbeManifest "evidenceIndexTrackedHardMode" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHardModeFailureProbeManifest "releaseGateBlockedAsExpected" $false)) -and
    (Get-JsonValue $productionHardModeFailureProbeManifest "riskPolicyStatus" "") -eq "BLOCKED" -and
    (Get-JsonValue $productionHardModeFailureProbeManifest "releaseGateStatus" "") -eq "BLOCKED" -and
    (Get-JsonValue $productionHardModeFailureProbeManifest "productionOutputBoundary" "") -eq "hard_mode_failure_probe_only" -and
    (Convert-ToInt (Get-JsonValue $productionHardModeFailureProbeManifest "failedCheckCount" 1)) -eq 0
)

Add-PolicyCheck "production_hard_mode_failure_policy" $productionHardModeFailureAccepted `
    "Release evidence must prove combined production driver, production Lua, and live-model hard-mode switches block the current sample or missing-evidence state." `
    "production_hard_mode_failure_probe_not_accepted"

$passedRiskPolicyCheckCount = @($riskPolicyChecks | Where-Object { [bool]$_.passed }).Count
$failedRiskPolicyCheckCount = @($riskPolicyChecks | Where-Object { -not [bool]$_.passed }).Count
$status = "PASS"
if ($failedRiskPolicyCheckCount -gt 0) {
    $status = "BLOCKED"
}

$driverBlockingReasons = @()
if ($null -ne $productionDriverReadinessManifest) {
    $driverBlockingReasons = Convert-ToArray (Get-JsonValue $productionDriverReadinessManifest "blockingReasons" $null)
}

$luaBlockingReasons = @()
if ($null -ne $productionLuaPatchReadinessManifest) {
    $luaBlockingReasons = Convert-ToArray (Get-JsonValue $productionLuaPatchReadinessManifest "blockingReasons" $null)
}

$generatedFiles = @(
    "release-risk-policy-manifest.json",
    "release-risk-policy.md"
)

$sourceFiles = @(
    "manifest.json",
    "scene-validation.json",
    "bug-knowledge-graph.json",
    "repair-agent-patch-apply-retest-manifest.json",
    "repair-agent-patch-result-history-manifest.json",
    "production-replay-driver-readiness-manifest.json",
    "production-driver-evidence-intake-manifest.json",
    "production-driver-evidence-contract-probe-manifest.json",
    "production-lua-patch-readiness-manifest.json",
    "production-lua-patch-evidence-kit-probe-manifest.json",
    "production-lua-patch-external-bundle-intake-probe-manifest.json",
    "live-model-endpoint-failure-probe-manifest.json",
    "live-model-endpoint-smoke-manifest.json",
    "live-model-endpoint-config-kit-probe-manifest.json",
    "live-model-endpoint-external-smoke-intake-probe-manifest.json",
    "live-model-endpoint-smoke-evidence-contract-probe-manifest.json",
    "github-actions-release-workflow-probe-manifest.json",
    "azure-pipelines-release-workflow-probe-manifest.json",
    "provider-ci-quality-probe-manifest.json",
    "production-handoff-package-manifest.json",
    "production-hard-mode-failure-probe-manifest.json"
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.release_risk_policy.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    allowPackageRelease = ($status -eq "PASS")
    releaseBlockerCount = [int]$failedRiskPolicyCheckCount
    releaseBlockers = @($releaseBlockers)
    requireProductionReplayDriverBound = [bool]$RequireProductionReplayDriverBound
    requireProductionLuaPatched = [bool]$RequireProductionLuaPatched
    requireLiveModelEndpointSmoke = [bool]$RequireLiveModelEndpointSmoke
    aiExplorationAccepted = [bool]$aiExplorationAccepted
    unexpectedFailedRunReportCount = [int]$unexpectedFailedRunReports.Count
    bugDetectedRunReportCount = [int]$bugDetectedRunReports.Count
    sceneRetestAccepted = [bool]($retestReportPassed -and $patchRetestPassed)
    highRiskPolicyAccepted = [bool]$highRiskPolicyAccepted
    graphHighRiskCount = [int]$graphHighRiskCount
    unverifiedHighRiskBugCount = [int]$unverifiedHighRiskBugCount
    unresolvedHighRiskGraphNodeCount = [int]$unresolvedHighRiskGraphNodeCount
    driverEvidenceAccepted = [bool]$driverEvidenceAccepted
    productionDriverEvidenceContractAccepted = [bool]$productionDriverEvidenceContractAccepted
    driverEvidenceStatus = $driverEvidenceStatus
    productionDriverReady = [bool]$driverReadyForProduction
    productionDriverBlockingReasonCount = [int]$driverBlockingReasons.Count
    productionDriverBlockingReasons = @($driverBlockingReasons)
    productionLuaEvidenceAccepted = [bool]$productionLuaEvidenceAccepted
    productionLuaEvidenceKitAccepted = [bool]$productionLuaEvidenceKitAccepted
    productionLuaExternalBundleIntakeAccepted = [bool]$productionLuaExternalBundleIntakeAccepted
    productionLuaEvidenceStatus = $productionLuaEvidenceStatus
    productionLuaReady = [bool]$productionLuaReadyForProduction
    productionLuaBlockingReasonCount = [int]$luaBlockingReasons.Count
    productionLuaBlockingReasons = @($luaBlockingReasons)
    liveModelPolicyAccepted = [bool]$liveModelPolicyAccepted
    liveModelPolicyStatus = $liveModelPolicyStatus
    liveModelConfigKitAccepted = [bool]$liveModelConfigKitAccepted
    liveModelExternalSmokeIntakeAccepted = [bool]$liveModelExternalSmokeIntakeAccepted
    liveModelSmokeEvidenceContractAccepted = [bool]$liveModelSmokeEvidenceContractAccepted
    ciProviderEvidenceAccepted = [bool]$ciProviderEvidenceAccepted
    githubActionsAccepted = [bool]$githubActionsAccepted
    azurePipelinesAccepted = [bool]$azurePipelinesAccepted
    providerCiQualityAccepted = [bool]$providerCiQualityAccepted
    productionHandoffPackageAccepted = [bool]$productionHandoffPackageAccepted
    productionHardModeFailureAccepted = [bool]$productionHardModeFailureAccepted
    riskPolicyCheckCount = [int]$riskPolicyChecks.Count
    passedRiskPolicyCheckCount = [int]$passedRiskPolicyCheckCount
    failedRiskPolicyCheckCount = [int]$failedRiskPolicyCheckCount
    missingOrInvalidSourceFileCount = [int]$missingOrInvalidSourceFiles.Count
    missingOrInvalidSourceFiles = @($missingOrInvalidSourceFiles)
    sourceFiles = @($sourceFiles)
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles + $sourceFiles)
    checks = @($riskPolicyChecks)
}

$reportLines = @(
    "# AI TestPilot Release Risk Policy",
    "",
    "- Status: $status",
    "- Package release allowed: $($manifest.allowPackageRelease)",
    "- Release blockers: $($manifest.releaseBlockerCount)",
    "- AI exploration accepted: $($manifest.aiExplorationAccepted)",
    "- High-risk policy accepted: $($manifest.highRiskPolicyAccepted)",
    "- Driver evidence: $($manifest.driverEvidenceStatus)",
    "- Production driver evidence contract accepted: $($manifest.productionDriverEvidenceContractAccepted)",
    "- Production Lua evidence: $($manifest.productionLuaEvidenceStatus)",
    "- Production Lua evidence kit accepted: $($manifest.productionLuaEvidenceKitAccepted)",
    "- Production Lua external bundle intake accepted: $($manifest.productionLuaExternalBundleIntakeAccepted)",
    "- Live model policy: $($manifest.liveModelPolicyStatus)",
    "- Live model config kit accepted: $($manifest.liveModelConfigKitAccepted)",
    "- Live model external smoke intake accepted: $($manifest.liveModelExternalSmokeIntakeAccepted)",
    "- Live model smoke evidence contract accepted: $($manifest.liveModelSmokeEvidenceContractAccepted)",
    "- CI provider evidence accepted: $($manifest.ciProviderEvidenceAccepted)",
    "- Production handoff package accepted: $($manifest.productionHandoffPackageAccepted)",
    "- Production hard-mode failure probe accepted: $($manifest.productionHardModeFailureAccepted)",
    "- Policy checks passed: $($manifest.passedRiskPolicyCheckCount) / $($manifest.riskPolicyCheckCount)",
    "",
    "## Boundary Summary",
    "",
    "- Graph high-risk nodes: $($manifest.graphHighRiskCount)",
    "- Unverified high-risk bugs: $($manifest.unverifiedHighRiskBugCount)",
    "- Unresolved high-risk graph nodes: $($manifest.unresolvedHighRiskGraphNodeCount)",
    "- Production driver ready: $($manifest.productionDriverReady)",
    "- Production driver blocking reasons: $($manifest.productionDriverBlockingReasonCount)",
    "- Production Lua ready: $($manifest.productionLuaReady)",
    "- Production Lua blocking reasons: $($manifest.productionLuaBlockingReasonCount)",
    "",
    "## Checks",
    "",
    "| Check | Passed | Message |",
    "| --- | --- | --- |"
)

foreach ($check in $riskPolicyChecks) {
    $reportLines += "| $($check.name) | $($check.passed) | $($check.message) |"
}

if ($releaseBlockers.Count -gt 0) {
    $reportLines += ""
    $reportLines += "## Release Blockers"
    $reportLines += ""
    foreach ($blocker in $releaseBlockers) {
        $reportLines += "- $blocker"
    }
}

New-Item -ItemType Directory -Force (Split-Path $manifestFullPath -Parent) | Out-Null
New-Item -ItemType Directory -Force (Split-Path $reportFullPath -Parent) | Out-Null

$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFullPath -Encoding UTF8
$reportLines | Set-Content -Path $reportFullPath -Encoding UTF8

Write-Output "Release risk policy manifest: $manifestFullPath"

if ($status -ne "PASS") {
    throw "AI TestPilot release risk policy blocked release. Manifest: $manifestFullPath"
}

Write-Output "PASS AI TestPilot release risk policy"
