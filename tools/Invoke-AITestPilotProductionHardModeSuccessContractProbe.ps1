[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ProbeBundleDir,
    [string]$ManifestPath,
    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Test-PathWithinRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root)
    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    if ($fullPath.Equals($fullRoot, $comparison)) {
        return $true
    }

    if (-not $fullRoot.EndsWith(([System.IO.Path]::DirectorySeparatorChar).ToString())) {
        $fullRoot = $fullRoot + [System.IO.Path]::DirectorySeparatorChar
    }

    return $fullPath.StartsWith($fullRoot, $comparison)
}

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ProbeBundleDir)) {
    $ProbeBundleDir = Join-Path $repoRoot "Temp\release-evidence\production-hard-mode-success-contract-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-hard-mode-success-contract-probe-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-hard-mode-success-contract-probe.md"
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

function Convert-ToArray {
    param([object]$Value)

    if ($null -eq $Value) {
        return @()
    }

    return @($Value)
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

    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) {
        return $Object[$Name]
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }

    return $property.Value
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

function Copy-RequiredFile {
    param(
        [string]$Source,
        [string]$Destination,
        [string]$Label
    )

    if (-not (Test-Path $Source)) {
        throw "$Label is missing: $Source"
    }

    New-Item -ItemType Directory -Force (Split-Path $Destination -Parent) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Get-EvidenceFileHash {
    param([string]$FileName)

    $path = Join-Path $evidenceBundlePath $FileName
    if (-not (Test-Path $path)) {
        return "MISSING"
    }

    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$probeBundlePath = Assert-PathUnderRepo $ProbeBundleDir "ProbeBundleDir"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if ($probeBundlePath -eq $evidenceBundlePath) {
    throw "ProbeBundleDir must be separate from EvidenceBundleDir."
}

$canonicalSourceFiles = @(
    "production-replay-driver-readiness-manifest.json",
    "production-driver-evidence-intake-manifest.json",
    "production-lua-patch-readiness-manifest.json",
    "production-lua-patch-evidence.json",
    "live-model-endpoint-smoke-manifest.json",
    "live-model-endpoint-decision-trace.json"
)

$sourceHashesBefore = [ordered]@{}
foreach ($fileName in $canonicalSourceFiles) {
    $sourceHashesBefore[$fileName] = Get-EvidenceFileHash $fileName
}

if (Test-Path $probeBundlePath) {
    Remove-Item -LiteralPath $probeBundlePath -Recurse -Force
}

New-Item -ItemType Directory -Force $probeBundlePath | Out-Null
Copy-Item -Path (Join-Path $evidenceBundlePath "*") -Destination $probeBundlePath -Recurse -Force

$selfManifestName = "production-hard-mode-success-contract-probe-manifest.json"
$selfPlaceholder = [ordered]@{
    schemaVersion = "aitestpilot.production_hard_mode_success_contract_probe.v1"
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    placeholderFor = "production_hard_mode_success_contract_probe_self_reference"
    requireProductionReplayDriverBound = $true
    requireProductionLuaPatched = $true
    requireLiveModelEndpointSmoke = $true
    hardModeContractAccepted = $true
    acceptedFixtureSourcesCopied = $true
    riskPolicyStatus = "PASS"
    riskPolicyPassedAsExpected = $true
    evidenceIndexStatus = "PASS"
    evidenceIndexPassedAsExpected = $true
    evidenceIndexFieldLevelCoveragePassedAsExpected = $true
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
    checkCount = 5
    failedCheckCount = 0
    files = @($selfManifestName)
}
$selfPlaceholder | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $probeBundlePath $selfManifestName) -Encoding UTF8

$driverReadinessSource = Join-Path $evidenceBundlePath "production-driver-evidence-contract-accepted-readiness-manifest.json"
$driverIntakeSource = Join-Path $evidenceBundlePath "production-driver-evidence-contract-accepted-intake-manifest.json"
$driverChecklistSource = Join-Path $evidenceBundlePath "production-driver-evidence-contract-accepted-checklist.json"
$driverRetestSource = Join-Path $evidenceBundlePath "production-driver-evidence-contract-accepted-retest-manifest.json"
$luaReadinessSource = Join-Path $evidenceBundlePath "production-lua-patch-evidence-kit-accepted-readiness-manifest.json"
$liveSmokeSource = Join-Path $evidenceBundlePath "live-model-endpoint-smoke-evidence-contract-accepted-smoke-manifest.json"
$liveTraceSource = Join-Path $evidenceBundlePath "live-model-endpoint-smoke-evidence-contract-accepted-decision-trace.json"

Copy-RequiredFile $driverReadinessSource (Join-Path $probeBundlePath "production-replay-driver-readiness-manifest.json") "Accepted production driver readiness manifest"
Copy-RequiredFile $driverReadinessSource (Join-Path $probeBundlePath "production-driver-evidence-intake-readiness-manifest.json") "Accepted production driver readiness manifest"
Copy-RequiredFile $driverIntakeSource (Join-Path $probeBundlePath "production-driver-evidence-intake-manifest.json") "Accepted production driver intake manifest"
Copy-RequiredFile $driverChecklistSource (Join-Path $probeBundlePath "production-replay-integration-checklist.json") "Accepted production driver checklist"
Copy-RequiredFile $driverRetestSource (Join-Path $probeBundlePath "repair-retest-manifest.json") "Accepted production driver retest manifest"
Copy-RequiredFile $luaReadinessSource (Join-Path $probeBundlePath "production-lua-patch-readiness-manifest.json") "Accepted production Lua readiness manifest"
Copy-RequiredFile $liveSmokeSource (Join-Path $probeBundlePath "live-model-endpoint-smoke-manifest.json") "Accepted live smoke manifest"
Copy-RequiredFile $liveTraceSource (Join-Path $probeBundlePath "live-model-endpoint-decision-trace.json") "Accepted live smoke trace"

$acceptedLuaEvidenceDir = Join-Path $probeBundlePath "production-hard-mode-success-accepted-lua-evidence"
$acceptedLuaGeneratedManifestPath = Join-Path $acceptedLuaEvidenceDir "production-lua-patch-evidence-kit-generated-manifest.json"
& (Join-Path $PSScriptRoot "New-AITestPilotProductionLuaPatchEvidenceKit.ps1") `
    -OutputDir $acceptedLuaEvidenceDir `
    -ManifestPath $acceptedLuaGeneratedManifestPath `
    -GenerateAcceptedFixture

Copy-RequiredFile (Join-Path $acceptedLuaEvidenceDir "production-lua-patch-evidence.json") `
    (Join-Path $probeBundlePath "production-lua-patch-evidence.json") `
    "Accepted production Lua evidence"

$probeDriverReadiness = Read-JsonFile (Join-Path $probeBundlePath "production-replay-driver-readiness-manifest.json") "Probe production driver readiness manifest"
$probeDriverIntake = Read-JsonFile (Join-Path $probeBundlePath "production-driver-evidence-intake-manifest.json") "Probe production driver intake manifest"
$probeLuaReadiness = Read-JsonFile (Join-Path $probeBundlePath "production-lua-patch-readiness-manifest.json") "Probe production Lua readiness manifest"
$probeLiveSmoke = Read-JsonFile (Join-Path $probeBundlePath "live-model-endpoint-smoke-manifest.json") "Probe live smoke manifest"
$probeLiveTrace = Read-JsonFile (Join-Path $probeBundlePath "live-model-endpoint-decision-trace.json") "Probe live smoke trace"

$acceptedFixtureSourcesCopied = $probeDriverReadiness.status -eq "PASS" -and
    (Convert-ToBool (Get-JsonValue $probeDriverReadiness "readyForProductionDriverRelease" $false)) -and
    (Convert-ToBool (Get-JsonValue $probeDriverIntake "intakeAccepted" $false)) -and
    (Convert-ToBool (Get-JsonValue $probeLuaReadiness "readyForProductionLuaPatchRelease" $false)) -and
    (Convert-ToBool (Get-JsonValue $probeLuaReadiness "productionLuaEvidenceAccepted" $false)) -and
    $probeLiveSmoke.status -eq "PASS" -and
    (Convert-ToBool (Get-JsonValue $probeLiveSmoke "responseValidated" $false)) -and
    (Get-JsonValue $probeLiveSmoke "traceStatus" "") -eq "PASS" -and
    $probeLiveTrace.status -eq "PASS"

$riskManifestPath = Join-Path $probeBundlePath "release-risk-policy-manifest.json"
$riskReportPath = Join-Path $probeBundlePath "release-risk-policy.md"
$indexManifestPath = Join-Path $probeBundlePath "release-evidence-index-manifest.json"
$indexJsonPath = Join-Path $probeBundlePath "release-evidence-index.json"
$indexReportPath = Join-Path $probeBundlePath "release-evidence-index.md"
$fieldCoverageProbeManifestPath = Join-Path $probeBundlePath "release-evidence-index-field-coverage-probe-manifest.json"
$fieldCoverageProbeReportPath = Join-Path $probeBundlePath "release-evidence-index-field-coverage-probe.md"
$gateManifestPath = Join-Path $probeBundlePath "release-gate-manifest.json"

& (Join-Path $PSScriptRoot "Invoke-AITestPilotReleaseRiskPolicy.ps1") `
    -EvidenceBundleDir $probeBundlePath `
    -ManifestPath $riskManifestPath `
    -ReportPath $riskReportPath `
    -RequireProductionReplayDriverBound `
    -RequireProductionLuaPatched `
    -RequireLiveModelEndpointSmoke `
    -ContractFixtureMode

& (Join-Path $PSScriptRoot "Invoke-AITestPilotReleaseEvidenceIndex.ps1") `
    -EvidenceBundleDir $probeBundlePath `
    -ManifestPath $indexManifestPath `
    -IndexPath $indexJsonPath `
    -ReportPath $indexReportPath `
    -RequireProductionReplayDriverBound `
    -RequireProductionLuaPatched `
    -RequireLiveModelEndpointSmoke `
    -ContractFixtureMode

& (Join-Path $PSScriptRoot "Invoke-AITestPilotReleaseEvidenceIndexFieldCoverageProbe.ps1") `
    -EvidenceBundleDir $probeBundlePath `
    -ManifestPath $fieldCoverageProbeManifestPath `
    -ReportPath $fieldCoverageProbeReportPath

& (Join-Path $PSScriptRoot "Invoke-AITestPilotReleaseGate.ps1") `
    -EvidenceBundleDir $probeBundlePath `
    -ReleaseGateManifestPath $gateManifestPath `
    -RequireProductionReplayDriverBound `
    -RequireProductionLuaPatched `
    -RequireLiveModelEndpointSmoke `
    -ContractFixtureMode

$riskManifest = Read-JsonFile $riskManifestPath "Hard-mode success risk policy manifest"
$indexManifest = Read-JsonFile $indexManifestPath "Hard-mode success release evidence index manifest"
$fieldCoverageProbeManifest = Read-JsonFile $fieldCoverageProbeManifestPath "Hard-mode success release evidence index field coverage probe manifest"
$gateManifest = Read-JsonFile $gateManifestPath "Hard-mode success release gate manifest"

$riskPolicyPassedAsExpected = $riskManifest.status -eq "PASS" -and
    (Convert-ToBool (Get-JsonValue $riskManifest "allowPackageRelease" $false)) -and
    (Convert-ToBool (Get-JsonValue $riskManifest "requireProductionReplayDriverBound" $false)) -and
    (Convert-ToBool (Get-JsonValue $riskManifest "requireProductionLuaPatched" $false)) -and
    (Convert-ToBool (Get-JsonValue $riskManifest "requireLiveModelEndpointSmoke" $false)) -and
    (Get-JsonValue $riskManifest "driverEvidenceStatus" "") -eq "PRODUCTION_BOUND_ACCEPTED" -and
    (Convert-ToBool (Get-JsonValue $riskManifest "productionDriverReady" $false)) -and
    (Get-JsonValue $riskManifest "productionLuaEvidenceStatus" "") -eq "PRODUCTION_LUA_PATCH_ACCEPTED" -and
    (Convert-ToBool (Get-JsonValue $riskManifest "productionLuaReady" $false)) -and
    (Convert-ToBool (Get-JsonValue $riskManifest "contractFixtureMode" $false)) -and
    (Get-JsonValue $riskManifest "liveModelPolicyStatus" "") -eq "LIVE_MODEL_SMOKE_CONTRACT_FIXTURE_ACCEPTED" -and
    (Convert-ToBool (Get-JsonValue $riskManifest "liveModelPolicyAccepted" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $riskManifest "liveModelProductionEvidenceAccepted" $true)) -and
    (Convert-ToBool (Get-JsonValue $riskManifest "liveModelContractFixtureEvidenceAccepted" $false)) -and
    (Convert-ToInt (Get-JsonValue $riskManifest "releaseBlockerCount" 1)) -eq 0 -and
    (Convert-ToInt (Get-JsonValue $riskManifest "failedRiskPolicyCheckCount" 1)) -eq 0

$fieldLevelRequiredManifestCount = Convert-ToInt (Get-JsonValue $indexManifest "fieldLevelRequiredManifestCount" 0)
$fieldLevelRequiredFieldCount = Convert-ToInt (Get-JsonValue $indexManifest "fieldLevelRequiredFieldCount" 0)
$semanticFieldCheckCount = Convert-ToInt (Get-JsonValue $indexManifest "semanticFieldCheckCount" 0)
$semanticFieldCheckPassedCount = Convert-ToInt (Get-JsonValue $indexManifest "semanticFieldCheckPassedCount" 0)
$semanticFieldCheckFailedCount = Convert-ToInt (Get-JsonValue $indexManifest "semanticFieldCheckFailedCount" 1)
$fieldLevelMissingManifestCount = Convert-ToInt (Get-JsonValue $indexManifest "fieldLevelMissingManifestCount" 1)
$fieldLevelMissingFieldCount = Convert-ToInt (Get-JsonValue $indexManifest "fieldLevelMissingFieldCount" 1)
$fieldLevelValueMismatchCount = Convert-ToInt (Get-JsonValue $indexManifest "fieldLevelValueMismatchCount" 1)
$fieldLevelCoverageSchemaVersion = [string](Get-JsonValue $indexManifest "fieldLevelCoverageSchemaVersion" "")
$fieldLevelCoverageStatus = [string](Get-JsonValue $indexManifest "fieldLevelCoverageStatus" "")

$evidenceIndexFieldLevelCoveragePassedAsExpected = $fieldLevelCoverageSchemaVersion -eq "aitestpilot.release_evidence_field_level_coverage.v1" -and
    $fieldLevelCoverageStatus -eq "PASS" -and
    $fieldLevelRequiredManifestCount -ge 14 -and
    $fieldLevelRequiredFieldCount -ge 74 -and
    $semanticFieldCheckCount -eq $fieldLevelRequiredFieldCount -and
    $semanticFieldCheckPassedCount -eq $semanticFieldCheckCount -and
    $semanticFieldCheckFailedCount -eq 0 -and
    $fieldLevelMissingManifestCount -eq 0 -and
    $fieldLevelMissingFieldCount -eq 0 -and
    $fieldLevelValueMismatchCount -eq 0

$evidenceIndexPassedAsExpected = $indexManifest.status -eq "PASS" -and
    (Convert-ToBool (Get-JsonValue $indexManifest "portalHandoffReady" $false)) -and
    (Convert-ToBool (Get-JsonValue $indexManifest "requireProductionReplayDriverBound" $false)) -and
    (Convert-ToBool (Get-JsonValue $indexManifest "requireProductionLuaPatched" $false)) -and
    (Convert-ToBool (Get-JsonValue $indexManifest "requireLiveModelEndpointSmoke" $false)) -and
    (Convert-ToBool (Get-JsonValue $indexManifest "contractFixtureMode" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $indexManifest "liveModelEndpointSmokeProvenanceAccepted" $true)) -and
    (Convert-ToBool (Get-JsonValue $indexManifest "liveModelEndpointSmokeContractFixtureAccepted" $false)) -and
    (Convert-ToInt (Get-JsonValue $indexManifest "missingSourceManifestCount" 1)) -eq 0 -and
    (Convert-ToInt (Get-JsonValue $indexManifest "unparseableSourceManifestCount" 1)) -eq 0 -and
    (Convert-ToInt (Get-JsonValue $indexManifest "failedSourceManifestCount" 1)) -eq 0 -and
    (Convert-ToInt (Get-JsonValue $indexManifest "blockedSourceManifestCount" 1)) -eq 0 -and
    (Convert-ToInt (Get-JsonValue $indexManifest "unacceptedSourceManifestStatusCount" 1)) -eq 0 -and
    (Convert-ToInt (Get-JsonValue $indexManifest "missingListedFileCount" 1)) -eq 0 -and
    (Convert-ToInt (Get-JsonValue $indexManifest "blockingReasonCount" 1)) -eq 0 -and
    $evidenceIndexFieldLevelCoveragePassedAsExpected

$fieldCoverageProbePassedAsExpected = $fieldCoverageProbeManifest.status -eq "PASS" -and
    (Get-JsonValue $fieldCoverageProbeManifest "schemaVersion" "") -eq "aitestpilot.release_evidence_index_field_coverage_probe.v1" -and
    (Convert-ToInt (Get-JsonValue $fieldCoverageProbeManifest "scenarioCount" 0)) -ge 3 -and
    (Convert-ToInt (Get-JsonValue $fieldCoverageProbeManifest "failedScenarioCount" 1)) -eq 0 -and
    (Get-JsonValue $fieldCoverageProbeManifest "productionOutputBoundary" "") -eq "release_evidence_index_field_coverage_probe_isolated_copies_only"

$releaseGatePassedAsExpected = $gateManifest.status -eq "PASS" -and
    (Convert-ToBool (Get-JsonValue $gateManifest "allowRelease" $false)) -and
    (Convert-ToBool (Get-JsonValue $gateManifest "requireProductionReplayDriverBound" $false)) -and
    (Convert-ToBool (Get-JsonValue $gateManifest "requireProductionLuaPatched" $false)) -and
    (Convert-ToBool (Get-JsonValue $gateManifest "requireLiveModelEndpointSmoke" $false)) -and
    (Convert-ToBool (Get-JsonValue $gateManifest "contractFixtureMode" $false)) -and
    (Convert-ToInt (Get-JsonValue $gateManifest "failedReasonCount" 1)) -eq 0

$sourceHashesAfter = [ordered]@{}
foreach ($fileName in $canonicalSourceFiles) {
    $sourceHashesAfter[$fileName] = Get-EvidenceFileHash $fileName
}

$sourceCanonicalEvidencePreserved = $true
foreach ($fileName in $canonicalSourceFiles) {
    if ($sourceHashesBefore[$fileName] -ne $sourceHashesAfter[$fileName]) {
        $sourceCanonicalEvidencePreserved = $false
    }
}

$checks = @()
Add-ProbeCheck "accepted_fixture_sources_copied" $acceptedFixtureSourcesCopied "Probe bundle must replace hard-mode source manifests only inside the isolated contract bundle."
Add-ProbeCheck "hard_mode_risk_policy_passed" $riskPolicyPassedAsExpected "Risk policy must pass when production driver, Lua, and live smoke accepted fixtures are canonical inside the isolated bundle."
Add-ProbeCheck "hard_mode_evidence_index_passed" $evidenceIndexPassedAsExpected "Evidence index must stay complete and accepted under combined hard-mode switches."
Add-ProbeCheck "hard_mode_evidence_index_field_coverage_passed" $evidenceIndexFieldLevelCoveragePassedAsExpected "Evidence index must report field-level coverage PASS with all semantic field checks passing in the hard-mode success bundle."
Add-ProbeCheck "hard_mode_evidence_index_field_coverage_probe_passed" $fieldCoverageProbePassedAsExpected "Evidence index field coverage probe must pass inside the hard-mode success bundle before release gate."
Add-ProbeCheck "hard_mode_release_gate_passed" $releaseGatePassedAsExpected "Release gate must pass the isolated hard-mode accepted-fixture bundle."
Add-ProbeCheck "source_canonical_evidence_preserved" $sourceCanonicalEvidencePreserved "Default release evidence canonical production manifests must not be replaced by the success contract probe."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$copiedRiskManifest = "production-hard-mode-success-risk-policy-manifest.json"
$copiedRiskReport = "production-hard-mode-success-risk-policy.md"
$copiedIndexManifest = "production-hard-mode-success-index-manifest.json"
$copiedIndexJson = "production-hard-mode-success-index.json"
$copiedIndexReport = "production-hard-mode-success-index.md"
$copiedFieldCoverageProbeManifest = "production-hard-mode-success-field-coverage-probe-manifest.json"
$copiedFieldCoverageProbeReport = "production-hard-mode-success-field-coverage-probe.md"
$copiedGateManifest = "production-hard-mode-success-gate-manifest.json"

Copy-Item -LiteralPath $riskManifestPath -Destination (Join-Path $evidenceBundlePath $copiedRiskManifest) -Force
Copy-Item -LiteralPath $riskReportPath -Destination (Join-Path $evidenceBundlePath $copiedRiskReport) -Force
Copy-Item -LiteralPath $indexManifestPath -Destination (Join-Path $evidenceBundlePath $copiedIndexManifest) -Force
Copy-Item -LiteralPath $indexJsonPath -Destination (Join-Path $evidenceBundlePath $copiedIndexJson) -Force
Copy-Item -LiteralPath $indexReportPath -Destination (Join-Path $evidenceBundlePath $copiedIndexReport) -Force
Copy-Item -LiteralPath $fieldCoverageProbeManifestPath -Destination (Join-Path $evidenceBundlePath $copiedFieldCoverageProbeManifest) -Force
Copy-Item -LiteralPath $fieldCoverageProbeReportPath -Destination (Join-Path $evidenceBundlePath $copiedFieldCoverageProbeReport) -Force
Copy-Item -LiteralPath $gateManifestPath -Destination (Join-Path $evidenceBundlePath $copiedGateManifest) -Force

$reportLines = @(
    "# AI TestPilot Production Hard-Mode Success Contract Probe",
    "",
    "Schema: ``aitestpilot.production_hard_mode_success_contract_probe.v1``",
    "Generated at UTC: $((Get-Date).ToUniversalTime().ToString("O"))",
    "",
    "## Summary",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Probe status | $status |",
    "| Accepted fixture sources copied | $acceptedFixtureSourcesCopied |",
    "| Hard-mode risk policy status | $($riskManifest.status) |",
    "| Hard-mode evidence index status | $($indexManifest.status) |",
    "| Hard-mode evidence index field coverage | $fieldLevelCoverageStatus |",
    "| Hard-mode semantic field checks | $semanticFieldCheckPassedCount / $semanticFieldCheckCount |",
    "| Hard-mode field coverage probe status | $($fieldCoverageProbeManifest.status) |",
    "| Hard-mode release gate status | $($gateManifest.status) |",
    "| Source canonical evidence preserved | $sourceCanonicalEvidencePreserved |",
    "| Release pipeline uses fixture | False |",
    "| Real host-project evidence accepted | False |",
    "",
    "## Boundary",
    "",
    "- This probe copies accepted fixture evidence into an isolated hard-mode bundle only.",
    "- It proves the combined hard-mode release path can pass when driver, Lua, and live-smoke evidence are complete.",
    "- It does not replace the default release evidence, send email, or accept fixture data as real host-project evidence."
)

$reportText = [string]::Join([Environment]::NewLine, $reportLines) + [Environment]::NewLine
New-Item -ItemType Directory -Force (Split-Path $reportFullPath -Parent) | Out-Null
$reportText | Set-Content -Path $reportFullPath -Encoding UTF8

$reportContentValidated = $reportText.Contains("Production Hard-Mode Success Contract Probe") -and
    $reportText.Contains("Source canonical evidence preserved") -and
    $reportText.Contains("does not replace the default release evidence") -and
    -not $reportText.Contains("System.Collections") -and
    -not $reportText.Contains("@{")

if (-not $reportContentValidated) {
    $failedChecks += [ordered]@{
        name = "hard_mode_success_report_content"
        passed = $false
        message = "Report must summarize hard-mode success and fixture boundary."
    }
    $status = "FAIL"
}

$files = @(
    "production-hard-mode-success-contract-probe-manifest.json",
    "production-hard-mode-success-contract-probe.md",
    $copiedRiskManifest,
    $copiedRiskReport,
    $copiedIndexManifest,
    $copiedIndexJson,
    $copiedIndexReport,
    $copiedFieldCoverageProbeManifest,
    $copiedFieldCoverageProbeReport,
    $copiedGateManifest
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_hard_mode_success_contract_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    probeBundleDir = $probeBundlePath
    requireProductionReplayDriverBound = $true
    requireProductionLuaPatched = $true
    requireLiveModelEndpointSmoke = $true
    contractFixtureMode = $true
    hardModeContractAccepted = [bool]($status -eq "PASS")
    acceptedFixtureSourcesCopied = [bool]$acceptedFixtureSourcesCopied
    riskPolicyStatus = $riskManifest.status
    riskPolicyPassedAsExpected = [bool]$riskPolicyPassedAsExpected
    riskPolicyCheckCount = Convert-ToInt (Get-JsonValue $riskManifest "riskPolicyCheckCount" 0)
    riskPolicyFailedCheckCount = Convert-ToInt (Get-JsonValue $riskManifest "failedRiskPolicyCheckCount" 0)
    driverEvidenceStatus = Get-JsonValue $riskManifest "driverEvidenceStatus" ""
    productionDriverReady = Convert-ToBool (Get-JsonValue $riskManifest "productionDriverReady" $false)
    productionLuaEvidenceStatus = Get-JsonValue $riskManifest "productionLuaEvidenceStatus" ""
    productionLuaReady = Convert-ToBool (Get-JsonValue $riskManifest "productionLuaReady" $false)
    liveModelPolicyStatus = Get-JsonValue $riskManifest "liveModelPolicyStatus" ""
    liveModelPolicyAccepted = Convert-ToBool (Get-JsonValue $riskManifest "liveModelPolicyAccepted" $false)
    liveModelProductionEvidenceAccepted = Convert-ToBool (Get-JsonValue $riskManifest "liveModelProductionEvidenceAccepted" $false)
    liveModelContractFixtureEvidenceAccepted = Convert-ToBool (Get-JsonValue $riskManifest "liveModelContractFixtureEvidenceAccepted" $false)
    evidenceIndexStatus = $indexManifest.status
    evidenceIndexPassedAsExpected = [bool]$evidenceIndexPassedAsExpected
    evidenceIndexFieldLevelCoverageStatus = $fieldLevelCoverageStatus
    evidenceIndexFieldLevelCoveragePassedAsExpected = [bool]$evidenceIndexFieldLevelCoveragePassedAsExpected
    evidenceIndexFieldCoverageProbeStatus = $fieldCoverageProbeManifest.status
    evidenceIndexFieldCoverageProbePassedAsExpected = [bool]$fieldCoverageProbePassedAsExpected
    evidenceIndexFieldLevelRequiredManifestCount = [int]$fieldLevelRequiredManifestCount
    evidenceIndexFieldLevelRequiredFieldCount = [int]$fieldLevelRequiredFieldCount
    evidenceIndexSemanticFieldCheckCount = [int]$semanticFieldCheckCount
    evidenceIndexSemanticFieldCheckPassedCount = [int]$semanticFieldCheckPassedCount
    evidenceIndexSemanticFieldCheckFailedCount = [int]$semanticFieldCheckFailedCount
    evidenceIndexFieldLevelMissingManifestCount = [int]$fieldLevelMissingManifestCount
    evidenceIndexFieldLevelMissingFieldCount = [int]$fieldLevelMissingFieldCount
    evidenceIndexFieldLevelValueMismatchCount = [int]$fieldLevelValueMismatchCount
    evidenceIndexRequiredSourceManifestCount = Convert-ToInt (Get-JsonValue $indexManifest "requiredSourceManifestCount" 0)
    evidenceIndexMissingSourceManifestCount = Convert-ToInt (Get-JsonValue $indexManifest "missingSourceManifestCount" 0)
    evidenceIndexUnacceptedSourceManifestStatusCount = Convert-ToInt (Get-JsonValue $indexManifest "unacceptedSourceManifestStatusCount" 0)
    releaseGateStatus = $gateManifest.status
    releaseGatePassedAsExpected = [bool]$releaseGatePassedAsExpected
    releaseGateCheckCount = Convert-ToInt (Get-JsonValue $gateManifest "checkCount" 0)
    releaseGateFailedReasonCount = Convert-ToInt (Get-JsonValue $gateManifest "failedReasonCount" 0)
    sourceCanonicalEvidencePreserved = [bool]$sourceCanonicalEvidencePreserved
    sourceCanonicalEvidenceHashesBefore = $sourceHashesBefore
    sourceCanonicalEvidenceHashesAfter = $sourceHashesAfter
    reportGenerated = (Test-Path $reportFullPath)
    reportContentValidated = [bool]$reportContentValidated
    selfPlaceholderUsed = $true
    releasePipelineUsesFixture = $false
    realHostProjectEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "hard_mode_success_contract_probe_only"
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
    files = @($files)
}

New-Item -ItemType Directory -Force (Split-Path $manifestFullPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestFullPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Production hard-mode success contract probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production hard-mode success contract probe manifest: $manifestFullPath"
Write-Output "Production hard-mode success contract probe report: $reportFullPath"
Write-Output "PASS AI TestPilot production hard-mode success contract probe"
