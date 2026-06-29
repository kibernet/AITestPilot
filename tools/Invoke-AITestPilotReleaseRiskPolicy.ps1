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
$productionHandoffExternalEvidencePreflightProbeManifest = Read-PolicyJson "production-handoff-external-evidence-preflight-probe-manifest.json" "Production handoff external evidence preflight probe manifest"
$productionHandoffExportManifest = Read-PolicyJson "production-handoff-export-manifest.json" "Production handoff export manifest"
$productionHandoffStatusManifest = Read-PolicyJson "production-handoff-status-manifest.json" "Production handoff status manifest"
$productionHandoffDispatchPlanManifest = Read-PolicyJson "production-handoff-dispatch-manifest.json" "Production handoff dispatch plan manifest"
$productionHandoffContactReadinessManifest = Read-PolicyJson "production-handoff-contact-readiness-manifest.json" "Production handoff contact readiness manifest"
$productionHandoffContactReadinessContractProbeManifest = Read-PolicyJson "production-handoff-contact-readiness-contract-probe-manifest.json" "Production handoff contact readiness contract probe manifest"
$productionHandoffSendReadinessManifest = Read-PolicyJson "production-handoff-send-readiness-manifest.json" "Production handoff send readiness manifest"
$productionHandoffMailAuthReadinessManifest = Read-PolicyJson "production-handoff-mail-auth-readiness-manifest.json" "Production handoff mail auth readiness manifest"
$productionHandoffOwnerUnblockPackManifest = Read-PolicyJson "production-handoff-owner-unblock-pack-manifest.json" "Production handoff owner unblock pack manifest"
$productionHandoffOwnerUnblockPackContractProbeManifest = Read-PolicyJson "production-handoff-owner-unblock-pack-contract-probe-manifest.json" "Production handoff owner unblock pack contract probe manifest"
$productionExternalEvidenceAcceptanceContractProbeManifest = Read-PolicyJson "production-external-evidence-acceptance-contract-probe-manifest.json" "Production external evidence acceptance contract probe manifest"
$productionExternalEvidenceAcceptanceFailureProbeManifest = Read-PolicyJson "production-external-evidence-acceptance-failure-probe-manifest.json" "Production external evidence acceptance failure probe manifest"
$productionExternalEvidenceInboxManifest = Read-PolicyJson "production-external-evidence-inbox-manifest.json" "Production external evidence inbox manifest"
$productionExternalEvidenceInboxContractProbeManifest = Read-PolicyJson "production-external-evidence-inbox-contract-probe-manifest.json" "Production external evidence inbox contract probe manifest"
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
    (Convert-ToBool (Get-JsonValue $productionHandoffPackageManifest "blockerResolutionMapGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffPackageManifest "blockerResolutionMapContentValidated" $false)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffPackageManifest "blockerResolutionMappedReasonCount" -1)) -eq
        (Convert-ToInt (Get-JsonValue $productionHandoffPackageManifest "hostProjectBlockingReasonCount" -2)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffPackageManifest "blockerResolutionUnmappedReasonCount" 1)) -eq 0 -and
    (Convert-ToBool (Get-JsonValue $productionHandoffPackageManifest "ownerPacketsGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffPackageManifest "ownerPacketsContentValidated" $false)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffPackageManifest "ownerPacketCount" -1)) -eq
        (Convert-ToInt (Get-JsonValue $productionHandoffPackageManifest "hostProjectActionItemCount" -2)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffPackageManifest "ownerPacketBlockingReasonCount" -1)) -eq
        (Convert-ToInt (Get-JsonValue $productionHandoffPackageManifest "hostProjectBlockingReasonCount" -2)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffPackageManifest "externalEvidencePreflightAccepted" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffPackageManifest "acceptanceWrapperScriptContentValidated" $false)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffPackageManifest "sourceManifestCount" 0)) -ge 12 -and
    (Convert-ToInt (Get-JsonValue $productionHandoffPackageManifest "generatedFileCount" 0)) -ge 13 -and
    (Convert-ToInt (Get-JsonValue $productionHandoffPackageManifest "checkCount" 0)) -eq 10 -and
    (Convert-ToInt (Get-JsonValue $productionHandoffPackageManifest "failedCheckCount" 1)) -eq 0
)

Add-PolicyCheck "production_handoff_package_policy" $productionHandoffPackageAccepted `
    "Release evidence must include a production handoff package that consolidates driver, Lua, live-model, CI host-project next steps, and owner packets without promoting fixture evidence." `
    "production_handoff_package_not_accepted"

$productionHandoffExternalEvidencePreflightAccepted = (
    $null -ne $productionHandoffExternalEvidencePreflightProbeManifest -and
    $productionHandoffExternalEvidencePreflightProbeManifest.status -eq "PASS" -and
    (Get-JsonValue $productionHandoffExternalEvidencePreflightProbeManifest "schemaVersion" "") -eq "aitestpilot.production_handoff_external_evidence_preflight_probe.v1" -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffExternalEvidencePreflightProbeManifest "externalBundleUnderRepo" $true)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffExternalEvidencePreflightProbeManifest "acceptedFixtureDirsGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffExternalEvidencePreflightProbeManifest "acceptedPreflightPassed" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffExternalEvidencePreflightProbeManifest "acceptedPreflightRunIntake" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffExternalEvidencePreflightProbeManifest "acceptedPreflightRequireAllEvidence" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffExternalEvidencePreflightProbeManifest "acceptedPreflightAllRequiredFilesPresent" $false)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffExternalEvidencePreflightProbeManifest "acceptedPreflightMissingAreaCount" 1)) -eq 0 -and
    (Convert-ToInt (Get-JsonValue $productionHandoffExternalEvidencePreflightProbeManifest "acceptedPreflightIntakeResultCount" 0)) -eq 3 -and
    (Convert-ToInt (Get-JsonValue $productionHandoffExternalEvidencePreflightProbeManifest "acceptedPreflightFailedIntakeCount" 1)) -eq 0 -and
    (Convert-ToBool (Get-JsonValue $productionHandoffExternalEvidencePreflightProbeManifest "acceptedPreflightIntakePassed" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffExternalEvidencePreflightProbeManifest "acceptedPreflightRequiredFilesPassed" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffExternalEvidencePreflightProbeManifest "acceptedWrapperPassed" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffExternalEvidencePreflightProbeManifest "acceptedWrapperReportGenerated" $false)) -and
    (Get-JsonValue $productionHandoffExternalEvidencePreflightProbeManifest "acceptedWrapperAcceptanceStatus" "") -eq "PASS" -and
    (Convert-ToBool (Get-JsonValue $productionHandoffExternalEvidencePreflightProbeManifest "acceptedWrapperAllExternalEvidenceAccepted" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffExternalEvidencePreflightProbeManifest "releasePipelineUsesFixture" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffExternalEvidencePreflightProbeManifest "realHostProjectEvidenceAccepted" $true)) -and
    (Get-JsonValue $productionHandoffExternalEvidencePreflightProbeManifest "productionOutputBoundary" "") -eq "accepted_fixture_preflight_contract_only" -and
    (Convert-ToInt (Get-JsonValue $productionHandoffExternalEvidencePreflightProbeManifest "checkCount" 0)) -eq 6 -and
    (Convert-ToInt (Get-JsonValue $productionHandoffExternalEvidencePreflightProbeManifest "failedCheckCount" 1)) -eq 0
)

Add-PolicyCheck "production_handoff_external_evidence_preflight_policy" $productionHandoffExternalEvidencePreflightAccepted `
    "Production handoff evidence must prove the generated external evidence preflight and acceptance wrapper accept complete host-project-shaped fixture evidence without promoting fixture data." `
    "production_handoff_external_evidence_preflight_not_accepted"

$productionHandoffExportAccepted = (
    $null -ne $productionHandoffExportManifest -and
    $productionHandoffExportManifest.status -eq "PASS" -and
    (Get-JsonValue $productionHandoffExportManifest "schemaVersion" "") -eq "aitestpilot.production_handoff_export.v1" -and
    (Convert-ToBool (Get-JsonValue $productionHandoffExportManifest "handoffPackageIncluded" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffExportManifest "ownerPacketsContentValidated" $false)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffExportManifest "ownerPacketCount" -1)) -eq
        (Convert-ToInt (Get-JsonValue $productionHandoffExportManifest "hostProjectActionItemCount" -2)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffExportManifest "ownerPacketBlockingReasonCount" -1)) -eq
        (Convert-ToInt (Get-JsonValue $productionHandoffExportManifest "hostProjectBlockingReasonCount" -2)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffExportManifest "kitDirectoryCount" 0)) -eq 4 -and
    (Convert-ToBool (Get-JsonValue $productionHandoffExportManifest "externalEvidenceInboxIncluded" $false)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffExportManifest "contractEvidenceFileCount" 0)) -ge 14 -and
    (Convert-ToInt (Get-JsonValue $productionHandoffExportManifest "exportFileCount" 0)) -ge 40 -and
    (Convert-ToBool (Get-JsonValue $productionHandoffExportManifest "zipGenerated" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffExportManifest "releasePipelineUsesFixture" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffExportManifest "realHostProjectEvidenceAccepted" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffExportManifest "fixtureEvidencePromoted" $true)) -and
    (Get-JsonValue $productionHandoffExportManifest "productionOutputBoundary" "") -eq "host_project_external_handoff_export_only" -and
    (Convert-ToInt (Get-JsonValue $productionHandoffExportManifest "checkCount" 0)) -eq 6 -and
    (Convert-ToInt (Get-JsonValue $productionHandoffExportManifest "failedCheckCount" 1)) -eq 0
)

Add-PolicyCheck "production_handoff_export_policy" $productionHandoffExportAccepted `
    "Production handoff evidence must include a compact owner-facing export zip with handoff package, owner packets, kits, and contract reports without promoting fixture data." `
    "production_handoff_export_not_accepted"

$productionHandoffStatusAccepted = (
    $null -ne $productionHandoffStatusManifest -and
    $productionHandoffStatusManifest.status -eq "PASS" -and
    (Get-JsonValue $productionHandoffStatusManifest "schemaVersion" "") -eq "aitestpilot.production_handoff_status.v1" -and
    (Convert-ToBool (Get-JsonValue $productionHandoffStatusManifest "reportGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffStatusManifest "reportContentValidated" $false)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffStatusManifest "ownerPacketCount" -1)) -eq
        (Convert-ToInt (Get-JsonValue $productionHandoffStatusManifest "hostProjectActionItemCount" -2)) -and
    ((Convert-ToInt (Get-JsonValue $productionHandoffStatusManifest "acceptedOwnerPacketCount" -1)) +
        (Convert-ToInt (Get-JsonValue $productionHandoffStatusManifest "pendingOwnerPacketCount" -1))) -eq
        (Convert-ToInt (Get-JsonValue $productionHandoffStatusManifest "ownerPacketCount" -2)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffStatusManifest "totalBlockingReasonCount" 0)) -eq
        (Convert-ToInt (Get-JsonValue $productionHandoffExportManifest "ownerPacketBlockingReasonCount" -1)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffStatusManifest "remainingBlockingReasonCount" -1)) -le
        (Convert-ToInt (Get-JsonValue $productionHandoffStatusManifest "totalBlockingReasonCount" 0)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffStatusManifest "releasePipelineUsesFixture" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffStatusManifest "fixtureEvidencePromoted" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffStatusManifest "realHostProjectEvidenceAccepted" $true)) -and
    (Get-JsonValue $productionHandoffStatusManifest "productionOutputBoundary" "") -eq "host_project_external_evidence_collection_status_only" -and
    (Convert-ToInt (Get-JsonValue $productionHandoffStatusManifest "checkCount" 0)) -eq 8 -and
    (Convert-ToInt (Get-JsonValue $productionHandoffStatusManifest "failedCheckCount" 1)) -eq 0
)

Add-PolicyCheck "production_handoff_status_policy" $productionHandoffStatusAccepted `
    "Production handoff evidence must include an owner-level external evidence collection status report without promoting fixture data." `
    "production_handoff_status_not_accepted"

$productionHandoffDispatchPlanAccepted = (
    $null -ne $productionHandoffDispatchPlanManifest -and
    $productionHandoffDispatchPlanManifest.status -eq "PASS" -and
    (Get-JsonValue $productionHandoffDispatchPlanManifest "schemaVersion" "") -eq "aitestpilot.production_handoff_dispatch_plan.v1" -and
    (Convert-ToBool (Get-JsonValue $productionHandoffDispatchPlanManifest "dispatchQueueGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffDispatchPlanManifest "dispatchReportGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffDispatchPlanManifest "dispatchReportContentValidated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffDispatchPlanManifest "dispatchDraftsContentValidated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffDispatchPlanManifest "allOwnerPacketsMapped" $false)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffDispatchPlanManifest "ownerPacketCount" -1)) -eq
        (Convert-ToInt (Get-JsonValue $productionHandoffDispatchPlanManifest "hostProjectActionItemCount" -2)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffDispatchPlanManifest "dispatchDraftCount" -1)) -eq
        (Convert-ToInt (Get-JsonValue $productionHandoffDispatchPlanManifest "ownerPacketCount" -2)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffDispatchPlanManifest "pendingDispatchCount" -1)) -eq
        (Convert-ToInt (Get-JsonValue $productionHandoffDispatchPlanManifest "ownerPacketCount" -2)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffDispatchPlanManifest "sentDispatchCount" -1)) -eq 0 -and
    (Convert-ToInt (Get-JsonValue $productionHandoffDispatchPlanManifest "pendingExternalEvidenceFileCount" 0)) -eq 9 -and
    (Convert-ToInt (Get-JsonValue $productionHandoffDispatchPlanManifest "remainingBlockingReasonCount" -1)) -eq
        (Convert-ToInt (Get-JsonValue $productionHandoffStatusManifest "remainingBlockingReasonCount" -2)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffDispatchPlanManifest "exportZipAvailable" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffDispatchPlanManifest "contactPlaceholdersExplicit" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffDispatchPlanManifest "realOwnerEmailAddressesConfigured" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffDispatchPlanManifest "automaticEmailSendReady" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffDispatchPlanManifest "externalEvidenceCollectionComplete" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffDispatchPlanManifest "releasePipelineUsesFixture" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffDispatchPlanManifest "realHostProjectEvidenceAccepted" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffDispatchPlanManifest "fixtureEvidencePromoted" $true)) -and
    (Get-JsonValue $productionHandoffDispatchPlanManifest "productionOutputBoundary" "") -eq "host_project_owner_dispatch_plan_only" -and
    (Convert-ToInt (Get-JsonValue $productionHandoffDispatchPlanManifest "checkCount" 0)) -eq 7 -and
    (Convert-ToInt (Get-JsonValue $productionHandoffDispatchPlanManifest "failedCheckCount" 1)) -eq 0
)

Add-PolicyCheck "production_handoff_dispatch_plan_policy" $productionHandoffDispatchPlanAccepted `
    "Production handoff evidence must include a dispatch queue and owner email drafts while keeping real recipient and evidence boundaries explicit." `
    "production_handoff_dispatch_plan_not_accepted"

$productionHandoffContactReadinessAccepted = (
    $null -ne $productionHandoffContactReadinessManifest -and
    $productionHandoffContactReadinessManifest.status -eq "PASS" -and
    (Get-JsonValue $productionHandoffContactReadinessManifest "schemaVersion" "") -eq "aitestpilot.production_handoff_contact_readiness.v1" -and
    (Convert-ToBool (Get-JsonValue $productionHandoffContactReadinessManifest "contactRosterGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffContactReadinessManifest "contactReportGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffContactReadinessManifest "contactReportContentValidated" $false)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffContactReadinessManifest "ownerContactCount" -1)) -eq
        (Convert-ToInt (Get-JsonValue $productionHandoffDispatchPlanManifest "ownerPacketCount" -2)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffContactReadinessManifest "mappedOwnerContactCount" -1)) -eq
        (Convert-ToInt (Get-JsonValue $productionHandoffContactReadinessManifest "ownerContactCount" -2)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffContactReadinessManifest "configuredOwnerContactCount" -1)) -eq 0 -and
    (Convert-ToInt (Get-JsonValue $productionHandoffContactReadinessManifest "missingOwnerContactCount" -1)) -eq
        (Convert-ToInt (Get-JsonValue $productionHandoffContactReadinessManifest "ownerContactCount" -2)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffContactReadinessManifest "invalidOwnerContactCount" -1)) -eq 0 -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffContactReadinessManifest "contactRosterComplete" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffContactReadinessManifest "realOwnerEmailAddressesConfigured" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffContactReadinessManifest "automaticEmailSendReady" $true)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffContactReadinessManifest "pendingDispatchCount" -1)) -eq
        (Convert-ToInt (Get-JsonValue $productionHandoffDispatchPlanManifest "pendingDispatchCount" -2)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffContactReadinessManifest "pendingExternalEvidenceFileCount" 0)) -eq 9 -and
    (Convert-ToInt (Get-JsonValue $productionHandoffContactReadinessManifest "remainingBlockingReasonCount" -1)) -eq
        (Convert-ToInt (Get-JsonValue $productionHandoffStatusManifest "remainingBlockingReasonCount" -2)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffContactReadinessManifest "externalEvidenceCollectionComplete" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffContactReadinessManifest "releasePipelineUsesFixture" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffContactReadinessManifest "realHostProjectEvidenceAccepted" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffContactReadinessManifest "fixtureEvidencePromoted" $true)) -and
    (Get-JsonValue $productionHandoffContactReadinessManifest "productionOutputBoundary" "") -eq "host_project_owner_contact_readiness_only" -and
    (Convert-ToInt (Get-JsonValue $productionHandoffContactReadinessManifest "checkCount" 0)) -eq 7 -and
    (Convert-ToInt (Get-JsonValue $productionHandoffContactReadinessManifest "failedCheckCount" 1)) -eq 0
)

Add-PolicyCheck "production_handoff_contact_readiness_policy" $productionHandoffContactReadinessAccepted `
    "Production handoff evidence must include a contact roster readiness report that keeps missing real owner email addresses explicit." `
    "production_handoff_contact_readiness_not_accepted"

$productionHandoffContactReadinessContractAccepted = (
    $null -ne $productionHandoffContactReadinessContractProbeManifest -and
    $productionHandoffContactReadinessContractProbeManifest.status -eq "PASS" -and
    (Get-JsonValue $productionHandoffContactReadinessContractProbeManifest "schemaVersion" "") -eq "aitestpilot.production_handoff_contact_readiness_contract_probe.v1" -and
    (Convert-ToBool (Get-JsonValue $productionHandoffContactReadinessContractProbeManifest "acceptedFixtureContactRosterGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffContactReadinessContractProbeManifest "acceptedFixtureContactRosterUnderProbeBundle" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffContactReadinessContractProbeManifest "defaultPackageContactReadinessStillBlocked" $false)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffContactReadinessContractProbeManifest "defaultMissingOwnerContactCount" 0)) -eq
        (Convert-ToInt (Get-JsonValue $productionHandoffContactReadinessManifest "ownerContactCount" -1)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffContactReadinessContractProbeManifest "defaultAutomaticEmailSendReady" $true)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffContactReadinessContractProbeManifest "acceptedContactReadinessPassed" $false)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffContactReadinessContractProbeManifest "acceptedConfiguredOwnerContactCount" -1)) -eq
        (Convert-ToInt (Get-JsonValue $productionHandoffContactReadinessManifest "ownerContactCount" -2)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffContactReadinessContractProbeManifest "acceptedMissingOwnerContactCount" -1)) -eq 0 -and
    (Convert-ToInt (Get-JsonValue $productionHandoffContactReadinessContractProbeManifest "acceptedInvalidOwnerContactCount" -1)) -eq 0 -and
    (Convert-ToBool (Get-JsonValue $productionHandoffContactReadinessContractProbeManifest "acceptedContactRosterComplete" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffContactReadinessContractProbeManifest "acceptedConfiguredContactsAccepted" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffContactReadinessContractProbeManifest "acceptedRealOwnerEmailAddressesConfigured" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffContactReadinessContractProbeManifest "acceptedAutomaticEmailSendReady" $true)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffContactReadinessContractProbeManifest "acceptedSendBoundaryPreserved" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffContactReadinessContractProbeManifest "releasePipelineUsesFixture" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffContactReadinessContractProbeManifest "realHostProjectEvidenceAccepted" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffContactReadinessContractProbeManifest "fixtureEvidencePromoted" $true)) -and
    (Get-JsonValue $productionHandoffContactReadinessContractProbeManifest "productionOutputBoundary" "") -eq "accepted_fixture_owner_contact_readiness_contract_only" -and
    (Convert-ToInt (Get-JsonValue $productionHandoffContactReadinessContractProbeManifest "checkCount" 0)) -eq 5 -and
    (Convert-ToInt (Get-JsonValue $productionHandoffContactReadinessContractProbeManifest "failedCheckCount" 1)) -eq 0
)

Add-PolicyCheck "production_handoff_contact_readiness_contract_policy" $productionHandoffContactReadinessContractAccepted `
    "Production handoff evidence must prove a complete configured owner-contact roster can pass readiness without claiming emails were sent." `
    "production_handoff_contact_readiness_contract_not_accepted"

$productionHandoffSendReadinessAccepted = (
    $null -ne $productionHandoffSendReadinessManifest -and
    $productionHandoffSendReadinessManifest.status -eq "PASS" -and
    (Get-JsonValue $productionHandoffSendReadinessManifest "schemaVersion" "") -eq "aitestpilot.production_handoff_send_readiness.v1" -and
    (Get-JsonValue $productionHandoffSendReadinessManifest "sendReadinessStatus" "") -eq "BLOCKED_MISSING_OWNER_EMAILS" -and
    (Convert-ToBool (Get-JsonValue $productionHandoffSendReadinessManifest "sendKitGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffSendReadinessManifest "sendQueueGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffSendReadinessManifest "sendScriptGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffSendReadinessManifest "sendScriptContentValidated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffSendReadinessManifest "sendReportGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffSendReadinessManifest "sendReportContentValidated" $false)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffSendReadinessManifest "ownerContactCount" -1)) -eq
        (Convert-ToInt (Get-JsonValue $productionHandoffContactReadinessManifest "ownerContactCount" -2)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffSendReadinessManifest "sendQueueEntryCount" -1)) -eq
        (Convert-ToInt (Get-JsonValue $productionHandoffContactReadinessManifest "ownerContactCount" -2)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffSendReadinessManifest "readySendCount" -1)) -eq 0 -and
    (Convert-ToInt (Get-JsonValue $productionHandoffSendReadinessManifest "blockedSendCount" -1)) -eq
        (Convert-ToInt (Get-JsonValue $productionHandoffContactReadinessManifest "ownerContactCount" -2)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffSendReadinessManifest "missingOwnerContactCount" -1)) -eq
        (Convert-ToInt (Get-JsonValue $productionHandoffContactReadinessManifest "missingOwnerContactCount" -2)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffSendReadinessManifest "mailAuthorizationRequired" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffSendReadinessManifest "mailAuthorizationCheckedByPipeline" $true)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffSendReadinessManifest "twoStageConfirmationRequired" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffSendReadinessManifest "automaticEmailSendReady" $true)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffSendReadinessManifest "defaultContactBoundaryPreserved" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffSendReadinessManifest "contactReadinessContractAccepted" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffSendReadinessManifest "handoffExportZipAvailable" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffSendReadinessManifest "releasePipelineUsesFixture" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffSendReadinessManifest "realHostProjectEvidenceAccepted" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffSendReadinessManifest "fixtureEvidencePromoted" $true)) -and
    (Get-JsonValue $productionHandoffSendReadinessManifest "productionOutputBoundary" "") -eq "host_project_owner_send_readiness_only" -and
    (Convert-ToInt (Get-JsonValue $productionHandoffSendReadinessManifest "checkCount" 0)) -eq 8 -and
    (Convert-ToInt (Get-JsonValue $productionHandoffSendReadinessManifest "failedCheckCount" 1)) -eq 0
)

Add-PolicyCheck "production_handoff_send_readiness_policy" $productionHandoffSendReadinessAccepted `
    "Production handoff evidence must include a guarded owner-packet send queue and agently-cli helper while keeping contacts, mail authorization, and confirmation boundaries explicit." `
    "production_handoff_send_readiness_not_accepted"

$productionHandoffMailAuthReadinessAccepted = (
    $null -ne $productionHandoffMailAuthReadinessManifest -and
    $productionHandoffMailAuthReadinessManifest.status -eq "PASS" -and
    (Get-JsonValue $productionHandoffMailAuthReadinessManifest "schemaVersion" "") -eq "aitestpilot.production_handoff_mail_auth_readiness.v1" -and
    (Get-JsonValue $productionHandoffMailAuthReadinessManifest "mailAuthReadinessStatus" "") -eq "BLOCKED_NOT_CHECKED_BY_RELEASE_PIPELINE" -and
    (Convert-ToBool (Get-JsonValue $productionHandoffMailAuthReadinessManifest "mailAuthKitGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffMailAuthReadinessManifest "authCheckScriptGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffMailAuthReadinessManifest "oauthLoginHelperGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffMailAuthReadinessManifest "readmeGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffMailAuthReadinessManifest "authCheckScriptContentValidated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffMailAuthReadinessManifest "oauthLoginHelperContentValidated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffMailAuthReadinessManifest "readmeContentValidated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffMailAuthReadinessManifest "reportGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffMailAuthReadinessManifest "reportContentValidated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffMailAuthReadinessManifest "sendReadinessAccepted" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffMailAuthReadinessManifest "defaultContactBoundaryPreserved" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffMailAuthReadinessManifest "mailAuthorizationRequired" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffMailAuthReadinessManifest "mailAuthorizationCheckedByPipeline" $true)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffMailAuthReadinessManifest "pipelineDoesNotRunOAuthLogin" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffMailAuthReadinessManifest "twoStageConfirmationRequired" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffMailAuthReadinessManifest "automaticEmailSendReady" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffMailAuthReadinessManifest "releasePipelineUsesFixture" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffMailAuthReadinessManifest "realHostProjectEvidenceAccepted" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffMailAuthReadinessManifest "fixtureEvidencePromoted" $true)) -and
    (Get-JsonValue $productionHandoffMailAuthReadinessManifest "productionOutputBoundary" "") -eq "host_project_owner_mail_auth_readiness_only" -and
    (Convert-ToInt (Get-JsonValue $productionHandoffMailAuthReadinessManifest "checkCount" 0)) -eq 7 -and
    (Convert-ToInt (Get-JsonValue $productionHandoffMailAuthReadinessManifest "failedCheckCount" 1)) -eq 0
)

Add-PolicyCheck "production_handoff_mail_auth_readiness_policy" $productionHandoffMailAuthReadinessAccepted `
    "Production handoff evidence must include local agently-cli authorization readiness helpers while keeping OAuth login and email send outside CI." `
    "production_handoff_mail_auth_readiness_not_accepted"

$productionHandoffOwnerUnblockPackAccepted = (
    $null -ne $productionHandoffOwnerUnblockPackManifest -and
    $productionHandoffOwnerUnblockPackManifest.status -eq "PASS" -and
    (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "schemaVersion" "") -eq "aitestpilot.production_handoff_owner_unblock_pack.v1" -and
    (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "ownerUnblockStatus" "") -eq "BLOCKED_EXTERNAL_OWNER_INPUT" -and
    (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "unblockPackGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "summaryGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "matrixGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "operatorNextStepsGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "progressEmailDraftGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "readmeGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "reportGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "summaryContentValidated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "matrixContentValidated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "operatorNextStepsContentValidated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "progressEmailDraftContentValidated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "readmeContentValidated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "reportContentValidated" $false)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "ownerPacketCount" -1)) -eq
        (Convert-ToInt (Get-JsonValue $productionHandoffStatusManifest "ownerPacketCount" -2)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "pendingOwnerPacketCount" -1)) -eq
        (Convert-ToInt (Get-JsonValue $productionHandoffStatusManifest "pendingOwnerPacketCount" -2)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "pendingDispatchCount" -1)) -eq
        (Convert-ToInt (Get-JsonValue $productionHandoffContactReadinessManifest "pendingDispatchCount" -2)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "missingOwnerContactCount" -1)) -eq
        (Convert-ToInt (Get-JsonValue $productionHandoffContactReadinessManifest "missingOwnerContactCount" -2)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "missingRequiredFileCount" -1)) -eq
        (Convert-ToInt (Get-JsonValue $productionExternalEvidenceInboxManifest "missingRequiredFileCount" -2)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "remainingBlockingReasonCount" -1)) -eq
        (Convert-ToInt (Get-JsonValue $productionHandoffStatusManifest "remainingBlockingReasonCount" -2)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "blockedSendCount" -1)) -eq
        (Convert-ToInt (Get-JsonValue $productionHandoffSendReadinessManifest "blockedSendCount" -2)) -and
    (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "sendReadinessStatus" "") -eq "BLOCKED_MISSING_OWNER_EMAILS" -and
    (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "mailAuthReadinessStatus" "") -eq "BLOCKED_NOT_CHECKED_BY_RELEASE_PIPELINE" -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "automaticEmailSendReady" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "mailAuthorizationCheckedByPipeline" $true)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "handoffExportZipAvailable" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "externalEvidenceCollectionComplete" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "realHostProjectEvidenceAccepted" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "externalEvidenceAccepted" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "releasePipelineUsesFixture" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "fixtureEvidencePromoted" $true)) -and
    (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "productionOutputBoundary" "") -eq "host_project_owner_unblock_pack_only" -and
    (Convert-ToInt (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "checkCount" 0)) -eq 8 -and
    (Convert-ToInt (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "failedCheckCount" 1)) -eq 0
)

Add-PolicyCheck "production_handoff_owner_unblock_pack_policy" $productionHandoffOwnerUnblockPackAccepted `
    "Production handoff evidence must include an owner unblock pack that consolidates remaining contact, send, mail-auth, and returned-evidence actions without claiming completion." `
    "production_handoff_owner_unblock_pack_not_accepted"

$productionHandoffOwnerUnblockPackContractAccepted = (
    $null -ne $productionHandoffOwnerUnblockPackContractProbeManifest -and
    $productionHandoffOwnerUnblockPackContractProbeManifest.status -eq "PASS" -and
    (Get-JsonValue $productionHandoffOwnerUnblockPackContractProbeManifest "schemaVersion" "") -eq "aitestpilot.production_handoff_owner_unblock_pack_contract_probe.v1" -and
    (Get-JsonValue $productionHandoffOwnerUnblockPackContractProbeManifest "defaultOwnerUnblockStatus" "") -eq "BLOCKED_EXTERNAL_OWNER_INPUT" -and
    (Get-JsonValue $productionHandoffOwnerUnblockPackContractProbeManifest "acceptedOwnerUnblockStatus" "") -eq "READY_FOR_CONFIRMATION_PENDING_REAL_ACCEPTANCE" -and
    (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackContractProbeManifest "acceptedOwnerUnblockPackPassed" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackContractProbeManifest "acceptedContactsReady" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackContractProbeManifest "acceptedSendReadyForConfirmation" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackContractProbeManifest "acceptedInboxComplete" $false)) -and
    (Convert-ToInt (Get-JsonValue $productionHandoffOwnerUnblockPackContractProbeManifest "acceptedMissingOwnerContactCount" -1)) -eq 0 -and
    (Convert-ToInt (Get-JsonValue $productionHandoffOwnerUnblockPackContractProbeManifest "acceptedMissingRequiredFileCount" -1)) -eq 0 -and
    (Convert-ToInt (Get-JsonValue $productionHandoffOwnerUnblockPackContractProbeManifest "acceptedBlockedSendCount" -1)) -eq 0 -and
    (Convert-ToInt (Get-JsonValue $productionHandoffOwnerUnblockPackContractProbeManifest "acceptedReadySendCount" -1)) -eq
        (Convert-ToInt (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "ownerPacketCount" -2)) -and
    (Get-JsonValue $productionHandoffOwnerUnblockPackContractProbeManifest "acceptedSendReadinessStatus" "") -eq "READY_FOR_CONFIRMATION" -and
    (Get-JsonValue $productionHandoffOwnerUnblockPackContractProbeManifest "acceptedMailAuthReadinessStatus" "") -eq "BLOCKED_NOT_CHECKED_BY_RELEASE_PIPELINE" -and
    (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackContractProbeManifest "acceptedExternalEvidenceCollectionComplete" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackContractProbeManifest "acceptedRealHostProjectEvidenceAccepted" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackContractProbeManifest "acceptedExternalEvidenceAccepted" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackContractProbeManifest "acceptedAutomaticEmailSendReady" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackContractProbeManifest "acceptedMailAuthorizationCheckedByPipeline" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackContractProbeManifest "acceptedReleasePipelineUsesFixture" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackContractProbeManifest "acceptedFixtureEvidencePromoted" $true)) -and
    (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackContractProbeManifest "mailAuthBoundaryPreserved" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackContractProbeManifest "releasePipelineUsesFixture" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackContractProbeManifest "realHostProjectEvidenceAccepted" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionHandoffOwnerUnblockPackContractProbeManifest "fixtureEvidencePromoted" $true)) -and
    (Get-JsonValue $productionHandoffOwnerUnblockPackContractProbeManifest "productionOutputBoundary" "") -eq "accepted_fixture_owner_unblock_pack_contract_only" -and
    (Convert-ToInt (Get-JsonValue $productionHandoffOwnerUnblockPackContractProbeManifest "checkCount" 0)) -eq 7 -and
    (Convert-ToInt (Get-JsonValue $productionHandoffOwnerUnblockPackContractProbeManifest "failedCheckCount" 1)) -eq 0
)

Add-PolicyCheck "production_handoff_owner_unblock_pack_contract_policy" $productionHandoffOwnerUnblockPackContractAccepted `
    "Production handoff evidence must prove the owner unblock pack handles complete fixture contacts and returned evidence while preserving mail-auth and real-evidence boundaries." `
    "production_handoff_owner_unblock_pack_contract_not_accepted"

$productionExternalEvidenceInboxAccepted = (
    $null -ne $productionExternalEvidenceInboxManifest -and
    $productionExternalEvidenceInboxManifest.status -eq "PASS" -and
    (Get-JsonValue $productionExternalEvidenceInboxManifest "schemaVersion" "") -eq "aitestpilot.production_external_evidence_inbox.v1" -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceInboxManifest "inboxTemplateGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceInboxManifest "acceptanceWrapperGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceInboxManifest "reportGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceInboxManifest "reportContentValidated" $false)) -and
    (Convert-ToInt (Get-JsonValue $productionExternalEvidenceInboxManifest "ownerPacketCount" 0)) -eq 3 -and
    (Convert-ToInt (Get-JsonValue $productionExternalEvidenceInboxManifest "evidenceAreaCount" 0)) -eq 3 -and
    (Convert-ToInt (Get-JsonValue $productionExternalEvidenceInboxManifest "requiredEvidenceFileCount" 0)) -eq 9 -and
    (Convert-ToInt (Get-JsonValue $productionExternalEvidenceInboxManifest "missingRequiredFileCount" -1)) -le
        (Convert-ToInt (Get-JsonValue $productionExternalEvidenceInboxManifest "requiredEvidenceFileCount" 0)) -and
    -not (Convert-ToBool (Get-JsonValue $productionExternalEvidenceInboxManifest "realHostProjectEvidenceAccepted" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionExternalEvidenceInboxManifest "externalEvidenceAccepted" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionExternalEvidenceInboxManifest "releasePipelineUsesFixture" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionExternalEvidenceInboxManifest "fixtureEvidencePromoted" $true)) -and
    (Get-JsonValue $productionExternalEvidenceInboxManifest "productionOutputBoundary" "") -eq "host_project_external_evidence_inbox_inspection_only" -and
    (Convert-ToInt (Get-JsonValue $productionExternalEvidenceInboxManifest "checkCount" 0)) -eq 6 -and
    (Convert-ToInt (Get-JsonValue $productionExternalEvidenceInboxManifest "failedCheckCount" 1)) -eq 0
)

Add-PolicyCheck "production_external_evidence_inbox_policy" $productionExternalEvidenceInboxAccepted `
    "Production evidence handoff must include a returned-evidence inbox layout and acceptance wrapper without promoting fixture data." `
    "production_external_evidence_inbox_not_accepted"

$productionExternalEvidenceInboxContractAccepted = (
    $null -ne $productionExternalEvidenceInboxContractProbeManifest -and
    $productionExternalEvidenceInboxContractProbeManifest.status -eq "PASS" -and
    (Get-JsonValue $productionExternalEvidenceInboxContractProbeManifest "schemaVersion" "") -eq "aitestpilot.production_external_evidence_inbox_contract_probe.v1" -and
    -not (Convert-ToBool (Get-JsonValue $productionExternalEvidenceInboxContractProbeManifest "externalBundleUnderRepo" $true)) -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceInboxContractProbeManifest "inboxTemplateGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceInboxContractProbeManifest "filledInboxComplete" $false)) -and
    (Convert-ToInt (Get-JsonValue $productionExternalEvidenceInboxContractProbeManifest "filledInboxEvidenceAreaCount" 0)) -eq 3 -and
    (Convert-ToInt (Get-JsonValue $productionExternalEvidenceInboxContractProbeManifest "filledInboxCompleteAreaCount" 0)) -eq 3 -and
    (Convert-ToInt (Get-JsonValue $productionExternalEvidenceInboxContractProbeManifest "filledInboxMissingRequiredFileCount" 1)) -eq 0 -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceInboxContractProbeManifest "acceptedWrapperPassed" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceInboxContractProbeManifest "acceptedWrapperReportGenerated" $false)) -and
    (Get-JsonValue $productionExternalEvidenceInboxContractProbeManifest "acceptedWrapperAcceptanceStatus" "") -eq "PASS" -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceInboxContractProbeManifest "acceptedWrapperAllExternalEvidenceAccepted" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceInboxContractProbeManifest "acceptedWrapperContractFixtureMode" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceInboxContractProbeManifest "acceptedProductionDriverEvidenceAccepted" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceInboxContractProbeManifest "acceptedProductionLuaEvidenceAccepted" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceInboxContractProbeManifest "acceptedLiveModelSmokeEvidenceAccepted" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceInboxContractProbeManifest "acceptedAllExternalEvidenceAccepted" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $productionExternalEvidenceInboxContractProbeManifest "realHostProjectEvidenceAccepted" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionExternalEvidenceInboxContractProbeManifest "releasePipelineUsesFixture" $true)) -and
    (Get-JsonValue $productionExternalEvidenceInboxContractProbeManifest "productionOutputBoundary" "") -eq "accepted_fixture_external_evidence_inbox_contract_only" -and
    (Convert-ToInt (Get-JsonValue $productionExternalEvidenceInboxContractProbeManifest "checkCount" 0)) -eq 6 -and
    (Convert-ToInt (Get-JsonValue $productionExternalEvidenceInboxContractProbeManifest "failedCheckCount" 1)) -eq 0
)

Add-PolicyCheck "production_external_evidence_inbox_contract_policy" $productionExternalEvidenceInboxContractAccepted `
    "Production evidence handoff must prove the returned-evidence inbox wrapper can accept complete host-project-shaped evidence without promoting fixture data." `
    "production_external_evidence_inbox_contract_not_accepted"

$productionExternalEvidenceAcceptanceContractAccepted = (
    $null -ne $productionExternalEvidenceAcceptanceContractProbeManifest -and
    $productionExternalEvidenceAcceptanceContractProbeManifest.status -eq "PASS" -and
    (Get-JsonValue $productionExternalEvidenceAcceptanceContractProbeManifest "schemaVersion" "") -eq "aitestpilot.production_external_evidence_acceptance_contract_probe.v1" -and
    -not (Convert-ToBool (Get-JsonValue $productionExternalEvidenceAcceptanceContractProbeManifest "externalBundleUnderRepo" $true)) -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceAcceptanceContractProbeManifest "acceptedFixtureDirsGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceAcceptanceContractProbeManifest "acceptedAcceptancePassed" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceAcceptanceContractProbeManifest "acceptedAcceptanceReportGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceAcceptanceContractProbeManifest "acceptedAcceptanceReportContentValidated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceAcceptanceContractProbeManifest "acceptedAcceptanceRequireAllEvidence" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceAcceptanceContractProbeManifest "acceptedAcceptanceContractFixtureMode" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceAcceptanceContractProbeManifest "acceptedAcceptanceAllRequiredFilesPresent" $false)) -and
    (Convert-ToInt (Get-JsonValue $productionExternalEvidenceAcceptanceContractProbeManifest "acceptedAcceptanceMissingAreaCount" 1)) -eq 0 -and
    (Convert-ToInt (Get-JsonValue $productionExternalEvidenceAcceptanceContractProbeManifest "acceptedAcceptanceFailedCount" 1)) -eq 0 -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceAcceptanceContractProbeManifest "acceptedProductionDriverEvidenceAccepted" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceAcceptanceContractProbeManifest "acceptedProductionLuaEvidenceAccepted" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceAcceptanceContractProbeManifest "acceptedLiveModelSmokeEvidenceAccepted" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceAcceptanceContractProbeManifest "acceptedAllExternalEvidenceAccepted" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $productionExternalEvidenceAcceptanceContractProbeManifest "realHostProjectEvidenceAccepted" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionExternalEvidenceAcceptanceContractProbeManifest "releasePipelineUsesFixture" $true)) -and
    (Get-JsonValue $productionExternalEvidenceAcceptanceContractProbeManifest "productionOutputBoundary" "") -eq "accepted_fixture_external_evidence_acceptance_contract_only" -and
    (Convert-ToInt (Get-JsonValue $productionExternalEvidenceAcceptanceContractProbeManifest "checkCount" 0)) -eq 5 -and
    (Convert-ToInt (Get-JsonValue $productionExternalEvidenceAcceptanceContractProbeManifest "failedCheckCount" 1)) -eq 0
)

Add-PolicyCheck "production_external_evidence_acceptance_contract_policy" $productionExternalEvidenceAcceptanceContractAccepted `
    "Production evidence must include a stable repo-side acceptance command contract for driver, Lua, and live model evidence without promoting fixture data." `
    "production_external_evidence_acceptance_contract_not_accepted"

$productionExternalEvidenceAcceptanceFailureAccepted = (
    $null -ne $productionExternalEvidenceAcceptanceFailureProbeManifest -and
    $productionExternalEvidenceAcceptanceFailureProbeManifest.status -eq "PASS" -and
    (Get-JsonValue $productionExternalEvidenceAcceptanceFailureProbeManifest "schemaVersion" "") -eq "aitestpilot.production_external_evidence_acceptance_failure_probe.v1" -and
    -not (Convert-ToBool (Get-JsonValue $productionExternalEvidenceAcceptanceFailureProbeManifest "externalBundleUnderRepo" $true)) -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceAcceptanceFailureProbeManifest "requireAllEvidence" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceAcceptanceFailureProbeManifest "contractFixtureMode" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceAcceptanceFailureProbeManifest "missingAllAcceptanceRejected" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceAcceptanceFailureProbeManifest "missingAllCommandFailed" $false)) -and
    (Get-JsonValue $productionExternalEvidenceAcceptanceFailureProbeManifest "missingAllStatus" "") -eq "FAIL" -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceAcceptanceFailureProbeManifest "missingAllReportGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceAcceptanceFailureProbeManifest "missingAllReportContentValidated" $false)) -and
    (Convert-ToInt (Get-JsonValue $productionExternalEvidenceAcceptanceFailureProbeManifest "missingAllMissingAreaCount" 0)) -eq 3 -and
    -not (Convert-ToBool (Get-JsonValue $productionExternalEvidenceAcceptanceFailureProbeManifest "missingAllExternalEvidenceAccepted" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionExternalEvidenceAcceptanceFailureProbeManifest "missingAllRealHostProjectEvidenceAccepted" $true)) -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceAcceptanceFailureProbeManifest "driverOnlyAcceptanceRejected" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceAcceptanceFailureProbeManifest "driverOnlyCommandFailed" $false)) -and
    (Get-JsonValue $productionExternalEvidenceAcceptanceFailureProbeManifest "driverOnlyStatus" "") -eq "FAIL" -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceAcceptanceFailureProbeManifest "driverOnlyReportGenerated" $false)) -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceAcceptanceFailureProbeManifest "driverOnlyReportContentValidated" $false)) -and
    (Convert-ToInt (Get-JsonValue $productionExternalEvidenceAcceptanceFailureProbeManifest "driverOnlyMissingAreaCount" 0)) -eq 2 -and
    (Convert-ToBool (Get-JsonValue $productionExternalEvidenceAcceptanceFailureProbeManifest "driverOnlyProductionDriverEvidenceAccepted" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $productionExternalEvidenceAcceptanceFailureProbeManifest "driverOnlyProductionLuaEvidenceAccepted" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionExternalEvidenceAcceptanceFailureProbeManifest "driverOnlyLiveModelSmokeEvidenceAccepted" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionExternalEvidenceAcceptanceFailureProbeManifest "driverOnlyExternalEvidenceAccepted" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $productionExternalEvidenceAcceptanceFailureProbeManifest "driverOnlyRealHostProjectEvidenceAccepted" $true)) -and
    (Get-JsonValue $productionExternalEvidenceAcceptanceFailureProbeManifest "productionOutputBoundary" "") -eq "external_evidence_acceptance_failure_probe_only" -and
    (Convert-ToInt (Get-JsonValue $productionExternalEvidenceAcceptanceFailureProbeManifest "checkCount" 0)) -eq 5 -and
    (Convert-ToInt (Get-JsonValue $productionExternalEvidenceAcceptanceFailureProbeManifest "failedCheckCount" 1)) -eq 0
)

Add-PolicyCheck "production_external_evidence_acceptance_failure_policy" $productionExternalEvidenceAcceptanceFailureAccepted `
    "Production evidence acceptance must prove missing and partial external evidence are rejected under RequireAllEvidence." `
    "production_external_evidence_acceptance_failure_not_accepted"

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
    "production-handoff-external-evidence-preflight-probe-manifest.json",
    "production-handoff-export-manifest.json",
    "production-handoff-status-manifest.json",
    "production-handoff-dispatch-manifest.json",
    "production-handoff-contact-readiness-manifest.json",
    "production-handoff-contact-readiness-contract-probe-manifest.json",
    "production-handoff-send-readiness-manifest.json",
    "production-handoff-mail-auth-readiness-manifest.json",
    "production-handoff-owner-unblock-pack-manifest.json",
    "production-handoff-owner-unblock-pack-contract-probe-manifest.json",
    "production-external-evidence-acceptance-contract-probe-manifest.json",
    "production-external-evidence-acceptance-failure-probe-manifest.json",
    "production-external-evidence-inbox-manifest.json",
    "production-external-evidence-inbox-contract-probe-manifest.json",
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
    productionHandoffExternalEvidencePreflightAccepted = [bool]$productionHandoffExternalEvidencePreflightAccepted
    productionHandoffExportAccepted = [bool]$productionHandoffExportAccepted
    productionHandoffStatusAccepted = [bool]$productionHandoffStatusAccepted
    productionHandoffDispatchPlanAccepted = [bool]$productionHandoffDispatchPlanAccepted
    productionHandoffPendingDispatchCount = (Convert-ToInt (Get-JsonValue $productionHandoffDispatchPlanManifest "pendingDispatchCount" 0))
    productionHandoffContactReadinessAccepted = [bool]$productionHandoffContactReadinessAccepted
    productionHandoffContactReadinessContractAccepted = [bool]$productionHandoffContactReadinessContractAccepted
    productionHandoffSendReadinessAccepted = [bool]$productionHandoffSendReadinessAccepted
    productionHandoffMailAuthReadinessAccepted = [bool]$productionHandoffMailAuthReadinessAccepted
    productionHandoffMailAuthReadinessStatus = (Get-JsonValue $productionHandoffMailAuthReadinessManifest "mailAuthReadinessStatus" "")
    productionHandoffOwnerUnblockPackAccepted = [bool]$productionHandoffOwnerUnblockPackAccepted
    productionHandoffOwnerUnblockStatus = (Get-JsonValue $productionHandoffOwnerUnblockPackManifest "ownerUnblockStatus" "")
    productionHandoffOwnerUnblockPackContractAccepted = [bool]$productionHandoffOwnerUnblockPackContractAccepted
    productionHandoffOwnerUnblockContractStatus = (Get-JsonValue $productionHandoffOwnerUnblockPackContractProbeManifest "acceptedOwnerUnblockStatus" "")
    productionHandoffBlockedSendCount = (Convert-ToInt (Get-JsonValue $productionHandoffSendReadinessManifest "blockedSendCount" 0))
    productionHandoffMissingOwnerContactCount = (Convert-ToInt (Get-JsonValue $productionHandoffContactReadinessManifest "missingOwnerContactCount" 0))
    productionHandoffRemainingBlockingReasonCount = (Convert-ToInt (Get-JsonValue $productionHandoffStatusManifest "remainingBlockingReasonCount" 0))
    productionHandoffPendingOwnerPacketCount = (Convert-ToInt (Get-JsonValue $productionHandoffStatusManifest "pendingOwnerPacketCount" 0))
    productionExternalEvidenceInboxAccepted = [bool]$productionExternalEvidenceInboxAccepted
    productionExternalEvidenceInboxMissingFileCount = (Convert-ToInt (Get-JsonValue $productionExternalEvidenceInboxManifest "missingRequiredFileCount" 0))
    productionExternalEvidenceInboxContractAccepted = [bool]$productionExternalEvidenceInboxContractAccepted
    productionExternalEvidenceAcceptanceContractAccepted = [bool]$productionExternalEvidenceAcceptanceContractAccepted
    productionExternalEvidenceAcceptanceFailureAccepted = [bool]$productionExternalEvidenceAcceptanceFailureAccepted
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
    "- Production handoff external evidence preflight accepted: $($manifest.productionHandoffExternalEvidencePreflightAccepted)",
    "- Production handoff export accepted: $($manifest.productionHandoffExportAccepted)",
    "- Production handoff status accepted: $($manifest.productionHandoffStatusAccepted)",
    "- Production handoff dispatch plan accepted: $($manifest.productionHandoffDispatchPlanAccepted)",
    "- Production handoff pending dispatches: $($manifest.productionHandoffPendingDispatchCount)",
    "- Production handoff contact readiness accepted: $($manifest.productionHandoffContactReadinessAccepted)",
    "- Production handoff contact readiness contract accepted: $($manifest.productionHandoffContactReadinessContractAccepted)",
    "- Production handoff send readiness accepted: $($manifest.productionHandoffSendReadinessAccepted)",
    "- Production handoff mail auth readiness accepted: $($manifest.productionHandoffMailAuthReadinessAccepted)",
    "- Production handoff mail auth readiness status: $($manifest.productionHandoffMailAuthReadinessStatus)",
    "- Production handoff owner unblock pack accepted: $($manifest.productionHandoffOwnerUnblockPackAccepted)",
    "- Production handoff owner unblock status: $($manifest.productionHandoffOwnerUnblockStatus)",
    "- Production handoff owner unblock contract accepted: $($manifest.productionHandoffOwnerUnblockPackContractAccepted)",
    "- Production handoff owner unblock contract status: $($manifest.productionHandoffOwnerUnblockContractStatus)",
    "- Production handoff blocked sends: $($manifest.productionHandoffBlockedSendCount)",
    "- Production handoff missing owner contacts: $($manifest.productionHandoffMissingOwnerContactCount)",
    "- Production handoff pending owner packets: $($manifest.productionHandoffPendingOwnerPacketCount)",
    "- Production handoff remaining blockers: $($manifest.productionHandoffRemainingBlockingReasonCount)",
    "- Production external evidence inbox accepted: $($manifest.productionExternalEvidenceInboxAccepted)",
    "- Production external evidence inbox missing files: $($manifest.productionExternalEvidenceInboxMissingFileCount)",
    "- Production external evidence inbox contract accepted: $($manifest.productionExternalEvidenceInboxContractAccepted)",
    "- Production external evidence acceptance contract accepted: $($manifest.productionExternalEvidenceAcceptanceContractAccepted)",
    "- Production external evidence acceptance failure accepted: $($manifest.productionExternalEvidenceAcceptanceFailureAccepted)",
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
