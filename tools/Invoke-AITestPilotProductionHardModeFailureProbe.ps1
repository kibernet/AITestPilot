[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ProbeBundleDir,
    [string]$ManifestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ProbeBundleDir)) {
    $ProbeBundleDir = Join-Path $repoRoot "Temp\release-evidence\production-hard-mode-failure-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-hard-mode-failure-probe-manifest.json"
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
        [string]$Path,
        [string]$Label
    )

    if (-not (Test-Path $Path)) {
        throw "$Label is missing: $Path"
    }

    return Get-Content -Path $Path -Encoding UTF8 -Raw | ConvertFrom-Json
}

function Convert-ToArray {
    param([object]$Value)

    if ($null -eq $Value) {
        return @()
    }

    return @($Value)
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
$probeBundlePath = Assert-PathUnderRepo $ProbeBundleDir "ProbeBundleDir"
$manifestPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if ($probeBundlePath -eq $evidenceBundlePath) {
    throw "ProbeBundleDir must be separate from EvidenceBundleDir."
}

if (Test-Path $probeBundlePath) {
    Remove-Item -LiteralPath $probeBundlePath -Recurse -Force
}

New-Item -ItemType Directory -Force $probeBundlePath | Out-Null
Copy-Item -Path (Join-Path $evidenceBundlePath "*") -Destination $probeBundlePath -Recurse -Force

$selfPlaceholder = [ordered]@{
    schemaVersion = "aitestpilot.production_hard_mode_failure_probe.v1"
    status = "PENDING"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    placeholderFor = "production_hard_mode_failure_probe_self_reference"
    files = @("production-hard-mode-failure-probe-manifest.json")
}
$selfPlaceholder | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $probeBundlePath "production-hard-mode-failure-probe-manifest.json") -Encoding UTF8

$successContractPlaceholder = [ordered]@{
    schemaVersion = "aitestpilot.production_hard_mode_success_contract_probe.v1"
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    placeholderFor = "production_hard_mode_failure_probe_dependency"
    requireProductionReplayDriverBound = $true
    requireProductionLuaPatched = $true
    requireLiveModelEndpointSmoke = $true
    hardModeContractAccepted = $true
    acceptedFixtureSourcesCopied = $true
    riskPolicyStatus = "PASS"
    riskPolicyPassedAsExpected = $true
    evidenceIndexStatus = "PASS"
    evidenceIndexPassedAsExpected = $true
    releaseGateStatus = "PASS"
    releaseGatePassedAsExpected = $true
    contractFixtureMode = $true
    driverEvidenceStatus = "PRODUCTION_BOUND_ACCEPTED"
    productionLuaEvidenceStatus = "PRODUCTION_LUA_PATCH_ACCEPTED"
    liveModelPolicyStatus = "LIVE_MODEL_SMOKE_CONTRACT_FIXTURE_ACCEPTED"
    liveModelProductionEvidenceAccepted = $false
    liveModelContractFixtureEvidenceAccepted = $true
    sourceCanonicalEvidencePreserved = $true
    releasePipelineUsesFixture = $false
    realHostProjectEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "hard_mode_success_contract_probe_only"
    checkCount = 4
    failedCheckCount = 0
    files = @("production-hard-mode-success-contract-probe-manifest.json")
}
$successContractPlaceholder | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $probeBundlePath "production-hard-mode-success-contract-probe-manifest.json") -Encoding UTF8

$riskManifestPath = Join-Path $probeBundlePath "release-risk-policy-hard-mode-manifest.json"
$riskReportPath = Join-Path $probeBundlePath "release-risk-policy-hard-mode.md"
$indexManifestPath = Join-Path $probeBundlePath "release-evidence-index-hard-mode-manifest.json"
$indexJsonPath = Join-Path $probeBundlePath "release-evidence-index-hard-mode.json"
$indexReportPath = Join-Path $probeBundlePath "release-evidence-index-hard-mode.md"
$gateManifestPath = Join-Path $probeBundlePath "release-gate-hard-mode-manifest.json"
$hardModeSourceManifestNames = @(
    "manifest.json",
    "repair-agent-patch-output-manifest.json",
    "repair-agent-external-completion-failure-probe-manifest.json",
    "repair-agent-generic-patch-import-probe-manifest.json",
    "repair-agent-source-snapshot-apply-validate-manifest.json",
    "repair-agent-main-worktree-apply-readiness-manifest.json",
    "repair-agent-main-worktree-apply-retest-rollback-manifest.json",
    "repair-agent-external-task-output-acceptance-manifest.json",
    "repair-agent-patch-result-analysis-manifest.json",
    "repair-agent-patch-result-history-manifest.json",
    "repair-agent-external-patch-preflight-manifest.json",
    "repair-agent-external-patch-preflight-failure-probe-manifest.json",
    "repair-agent-repository-patch-apply-guard-manifest.json",
    "repair-agent-repository-patch-apply-clean-probe-manifest.json",
    "repair-agent-repository-patch-apply-clean-retest-manifest.json",
    "repair-agent-patch-apply-retest-manifest.json",
    "repair-retest-manifest.json",
    "repair-driver-failure-manifest.json",
    "replay-profile-import-manifest.json",
    "production-replay-integration-contract-probe-manifest.json",
    "production-driver-binding-kit-manifest.json",
    "production-driver-evidence-contract-probe-manifest.json",
    "production-replay-driver-readiness-manifest.json",
    "production-driver-evidence-intake-manifest.json",
    "production-driver-external-bundle-intake-probe-manifest.json",
    "model-endpoint-trace-manifest.json",
    "model-endpoint-provider-diagnostics-manifest.json",
    "model-endpoint-provider-retry-policy-manifest.json",
    "live-model-endpoint-config-kit-probe-manifest.json",
    "lua-static-analysis-manifest.json",
    "lua-auto-patch-sandbox-manifest.json",
    "production-lua-patch-readiness-manifest.json",
    "production-lua-patch-evidence-kit-probe-manifest.json",
    "production-lua-patch-external-bundle-intake-probe-manifest.json",
    "live-model-endpoint-failure-probe-manifest.json",
    "live-model-endpoint-smoke-manifest.json",
    "live-model-endpoint-external-smoke-intake-probe-manifest.json",
    "live-model-endpoint-smoke-evidence-contract-probe-manifest.json",
    "github-actions-release-workflow-probe-manifest.json",
    "azure-pipelines-release-workflow-probe-manifest.json",
    "provider-ci-quality-probe-manifest.json",
    "production-handoff-package-manifest.json",
    "production-handoff-external-evidence-preflight-probe-manifest.json",
    "production-handoff-export-manifest.json",
    "production-handoff-export-zip-index-manifest.json",
    "production-handoff-send-local-workflow-probe-manifest.json",
    "production-handoff-owner-packet-dispatch-receipt-intake-probe-manifest.json",
    "production-handoff-owner-packet-real-receipt-guard-probe-manifest.json",
    "production-external-evidence-action-queue-manifest.json",
    "production-external-evidence-action-queue-probe-manifest.json",
    "production-external-evidence-gap-analysis-manifest.json",
    "production-external-evidence-partial-matrix-probe-manifest.json",
    "production-external-evidence-semantic-preflight-probe-manifest.json",
    "production-external-evidence-auto-acceptance-probe-manifest.json",
    "release-docs-freshness-manifest.json",
    "production-external-evidence-acceptance-contract-probe-manifest.json",
    "production-external-evidence-acceptance-failure-probe-manifest.json",
    "release-risk-policy-hard-mode-manifest.json"
)

$riskCommandFailed = $false
$riskCommandError = ""
try {
    & (Join-Path $PSScriptRoot "Invoke-AITestPilotReleaseRiskPolicy.ps1") `
        -EvidenceBundleDir $probeBundlePath `
        -ManifestPath $riskManifestPath `
        -ReportPath $riskReportPath `
        -RequireProductionReplayDriverBound `
        -RequireProductionLuaPatched `
        -RequireLiveModelEndpointSmoke
}
catch {
    $riskCommandFailed = $true
    $riskCommandError = $_.Exception.Message
}

$indexCommandFailed = $false
$indexCommandError = ""
try {
    & (Join-Path $PSScriptRoot "Invoke-AITestPilotReleaseEvidenceIndex.ps1") `
        -EvidenceBundleDir $probeBundlePath `
        -ManifestPath $indexManifestPath `
        -IndexPath $indexJsonPath `
        -ReportPath $indexReportPath `
        -SourceManifestNames $hardModeSourceManifestNames `
        -RequireProductionReplayDriverBound `
        -RequireProductionLuaPatched `
        -RequireLiveModelEndpointSmoke
}
catch {
    $indexCommandFailed = $true
    $indexCommandError = $_.Exception.Message
}

& (Join-Path $PSScriptRoot "Invoke-AITestPilotReleaseGate.ps1") `
    -EvidenceBundleDir $probeBundlePath `
    -ReleaseGateManifestPath $gateManifestPath `
    -ExpectBlocked `
    -RequireProductionReplayDriverBound `
    -RequireProductionLuaPatched `
    -RequireLiveModelEndpointSmoke

$riskManifest = Read-JsonFile $riskManifestPath "Hard-mode risk policy manifest"
$indexManifest = Read-JsonFile $indexManifestPath "Hard-mode release evidence index manifest"
$gateManifest = Read-JsonFile $gateManifestPath "Hard-mode release gate manifest"

$expectedDriverReasons = @(
    "production_replay_integration_not_bound",
    "required_hooks_not_all_bound",
    "unresolved_required_hooks",
    "sample_game_replay_driver_used",
    "external_production_driver_not_selected"
)

$expectedLuaReasons = @(
    "real_production_lua_bundle_missing",
    "real_production_lua_not_analyzed",
    "real_production_lua_not_patched",
    "production_lua_retest_evidence_missing",
    "real_production_patch_rollback_missing"
)

$driverReasons = Convert-ToArray $riskManifest.productionDriverBlockingReasons
$luaReasons = Convert-ToArray $riskManifest.productionLuaBlockingReasons
$gateFailedReasons = Convert-ToArray $gateManifest.failedReasons

$riskBlockedAsExpected = $riskCommandFailed -and
    $riskManifest.status -eq "BLOCKED" -and
    -not [bool]$riskManifest.allowPackageRelease -and
    [bool]$riskManifest.requireProductionReplayDriverBound -and
    [bool]$riskManifest.requireProductionLuaPatched -and
    [bool]$riskManifest.requireLiveModelEndpointSmoke -and
    -not [bool]$riskManifest.driverEvidenceAccepted -and
    $riskManifest.driverEvidenceStatus -eq "PRODUCTION_BOUND_REQUIRED_BUT_NOT_READY" -and
    -not [bool]$riskManifest.productionDriverReady -and
    (Test-ContainsAll -Actual $driverReasons -Required $expectedDriverReasons) -and
    -not [bool]$riskManifest.productionLuaEvidenceAccepted -and
    $riskManifest.productionLuaEvidenceStatus -eq "PRODUCTION_LUA_PATCH_REQUIRED_BUT_NOT_READY" -and
    -not [bool]$riskManifest.productionLuaReady -and
    (Test-ContainsAll -Actual $luaReasons -Required $expectedLuaReasons) -and
    -not [bool]$riskManifest.liveModelPolicyAccepted -and
    $riskManifest.liveModelPolicyStatus -eq "LIVE_MODEL_SMOKE_REQUIRED_BUT_NOT_READY" -and
    [int]$riskManifest.failedRiskPolicyCheckCount -ge 3

$indexBlockingReasons = Convert-ToArray $indexManifest.blockingReasons
$indexTrackedHardMode = $indexCommandFailed -and
    $indexManifest.status -eq "BLOCKED" -and
    -not [bool]$indexManifest.portalHandoffReady -and
    [bool]$indexManifest.requireProductionReplayDriverBound -and
    [bool]$indexManifest.requireProductionLuaPatched -and
    [bool]$indexManifest.requireLiveModelEndpointSmoke -and
    [int]$indexManifest.missingSourceManifestCount -eq 0 -and
    [int]$indexManifest.unparseableSourceManifestCount -eq 0 -and
    [int]$indexManifest.missingListedFileCount -eq 0 -and
    [int]$indexManifest.unacceptedSourceManifestStatusCount -gt 0 -and
    (Test-ContainsAll -Actual $indexBlockingReasons -Required @("source_manifest_status_not_accepted"))

$gateBlockedAsExpected = $gateManifest.status -eq "BLOCKED" -and
    -not [bool]$gateManifest.allowRelease -and
    [bool]$gateManifest.requireProductionReplayDriverBound -and
    [bool]$gateManifest.requireProductionLuaPatched -and
    [int]$gateManifest.failedReasonCount -ge 3 -and
    ($gateFailedReasons -match "production_replay_driver_readiness").Count -gt 0 -and
    ($gateFailedReasons -match "production_lua_patch_readiness").Count -gt 0 -and
    ($gateFailedReasons -match "live_model_endpoint_smoke").Count -gt 0

$checks = @()
Add-ProbeCheck "hard_mode_risk_policy_blocked" $riskBlockedAsExpected "Risk policy must block when driver, Lua, and live-model hard modes are all required against current package evidence."
Add-ProbeCheck "hard_mode_index_tracked" $indexTrackedHardMode "Evidence index must stay parseable and file-complete while blocking unaccepted hard-mode source statuses."
Add-ProbeCheck "hard_mode_release_gate_blocked" $gateBlockedAsExpected "Release gate must block the current sample/no-production evidence under combined hard-mode switches."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$copiedRiskManifest = "production-hard-mode-failure-risk-policy-manifest.json"
$copiedRiskReport = "production-hard-mode-failure-risk-policy.md"
$copiedIndexManifest = "production-hard-mode-failure-index-manifest.json"
$copiedIndexJson = "production-hard-mode-failure-index.json"
$copiedIndexReport = "production-hard-mode-failure-index.md"
$copiedGateManifest = "production-hard-mode-failure-gate-manifest.json"

Copy-Item -LiteralPath $riskManifestPath -Destination (Join-Path $evidenceBundlePath $copiedRiskManifest) -Force
Copy-Item -LiteralPath $riskReportPath -Destination (Join-Path $evidenceBundlePath $copiedRiskReport) -Force
Copy-Item -LiteralPath $indexManifestPath -Destination (Join-Path $evidenceBundlePath $copiedIndexManifest) -Force
Copy-Item -LiteralPath $indexJsonPath -Destination (Join-Path $evidenceBundlePath $copiedIndexJson) -Force
Copy-Item -LiteralPath $indexReportPath -Destination (Join-Path $evidenceBundlePath $copiedIndexReport) -Force
Copy-Item -LiteralPath $gateManifestPath -Destination (Join-Path $evidenceBundlePath $copiedGateManifest) -Force

$files = @(
    "production-hard-mode-failure-probe-manifest.json",
    $copiedRiskManifest,
    $copiedRiskReport,
    $copiedIndexManifest,
    $copiedIndexJson,
    $copiedIndexReport,
    $copiedGateManifest
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_hard_mode_failure_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    probeBundleDir = $probeBundlePath
    requireProductionReplayDriverBound = $true
    requireProductionLuaPatched = $true
    requireLiveModelEndpointSmoke = $true
    riskCommandFailed = [bool]$riskCommandFailed
    riskCommandError = $riskCommandError
    indexCommandFailed = [bool]$indexCommandFailed
    indexCommandError = $indexCommandError
    selfPlaceholderUsed = $true
    riskPolicyStatus = $riskManifest.status
    riskPolicyBlockedAsExpected = [bool]$riskBlockedAsExpected
    riskPolicyFailedCheckCount = [int]$riskManifest.failedRiskPolicyCheckCount
    driverEvidenceStatus = $riskManifest.driverEvidenceStatus
    productionDriverReady = [bool]$riskManifest.productionDriverReady
    productionDriverBlockingReasonCount = [int]$riskManifest.productionDriverBlockingReasonCount
    productionDriverBlockingReasons = @($driverReasons)
    productionLuaEvidenceStatus = $riskManifest.productionLuaEvidenceStatus
    productionLuaReady = [bool]$riskManifest.productionLuaReady
    productionLuaBlockingReasonCount = [int]$riskManifest.productionLuaBlockingReasonCount
    productionLuaBlockingReasons = @($luaReasons)
    liveModelPolicyStatus = $riskManifest.liveModelPolicyStatus
    liveModelPolicyAccepted = [bool]$riskManifest.liveModelPolicyAccepted
    evidenceIndexStatus = $indexManifest.status
    evidenceIndexTrackedHardMode = [bool]$indexTrackedHardMode
    evidenceIndexBlockingReasonCount = [int]$indexManifest.blockingReasonCount
    evidenceIndexBlockingReasons = @($indexBlockingReasons)
    releaseGateStatus = $gateManifest.status
    releaseGateBlockedAsExpected = [bool]$gateBlockedAsExpected
    releaseGateFailedReasonCount = [int]$gateManifest.failedReasonCount
    releaseGateFailedReasons = @($gateFailedReasons)
    productionOutputBoundary = "hard_mode_failure_probe_only"
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
    files = @($files)
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Production hard-mode failure probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production hard-mode failure probe manifest: $manifestPath"
Write-Output "PASS AI TestPilot production hard-mode failure probe"
