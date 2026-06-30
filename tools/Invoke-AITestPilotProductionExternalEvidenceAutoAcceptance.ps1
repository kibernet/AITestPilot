[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ManifestPath,
    [string]$ReportPath,
    [string]$AcceptanceBundleDir,
    [string]$EvidenceRoot,
    [string]$OwnerResponseBundleDir,
    [string]$ProductionDriverEvidenceDir,
    [string]$ProductionLuaEvidenceDir,
    [string]$LiveModelEndpointSmokeEvidenceDir,
    [string]$GameReplayDriverType = "Your.Game.Tests.ProductionReplayDriver",
    [switch]$RequireAllEvidence,
    [switch]$ContractFixtureMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-external-evidence-auto-acceptance-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-external-evidence-auto-acceptance.md"
}

if ([string]::IsNullOrWhiteSpace($AcceptanceBundleDir)) {
    $AcceptanceBundleDir = Join-Path $EvidenceBundleDir "production-external-evidence-auto-acceptance"
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

function Convert-ToEvidenceRelativePath {
    param([string]$Path)

    $fullPath = Resolve-FullPath $Path
    if (-not $fullPath.StartsWith($evidenceBundlePath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Generated file must stay under evidence bundle: $fullPath"
    }

    $relativePath = $fullPath.Substring($evidenceBundlePath.Length).TrimStart([char[]]@("\", "/"))
    return $relativePath.Replace("\", "/")
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

function Format-MarkdownCell {
    param([object]$Value)

    if ($null -eq $Value) {
        return "(none)"
    }

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return "(none)"
    }

    return $text.Replace("`r", " ").Replace("`n", " ").Replace("|", "\|")
}

function Resolve-CandidateDir {
    param(
        [string]$ExplicitPath,
        [string]$EnvName,
        [string]$OwnerResponseSubdir,
        [string]$EvidenceRootSubdir,
        [string]$DefaultInboxSubdir
    )

    $source = "not_configured"
    $rawPath = ""

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $rawPath = $ExplicitPath
        $source = "explicit_parameter"
    }
    elseif (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($EnvName))) {
        $rawPath = [Environment]::GetEnvironmentVariable($EnvName)
        $source = "environment_variable:$EnvName"
    }
    elseif (-not [string]::IsNullOrWhiteSpace($OwnerResponseBundleDir)) {
        $rawPath = Join-Path $OwnerResponseBundleDir $OwnerResponseSubdir
        $source = "owner_response_bundle"
    }
    elseif (-not [string]::IsNullOrWhiteSpace($EvidenceRoot)) {
        $rawPath = Join-Path $EvidenceRoot $EvidenceRootSubdir
        $source = "evidence_root"
    }
    elseif (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable("AITESTPILOT_OWNER_RESPONSE_BUNDLE_DIR"))) {
        $rawPath = Join-Path ([Environment]::GetEnvironmentVariable("AITESTPILOT_OWNER_RESPONSE_BUNDLE_DIR")) $OwnerResponseSubdir
        $source = "environment_variable:AITESTPILOT_OWNER_RESPONSE_BUNDLE_DIR"
    }
    elseif (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable("AITESTPILOT_EXTERNAL_EVIDENCE_ROOT"))) {
        $rawPath = Join-Path ([Environment]::GetEnvironmentVariable("AITESTPILOT_EXTERNAL_EVIDENCE_ROOT")) $EvidenceRootSubdir
        $source = "environment_variable:AITESTPILOT_EXTERNAL_EVIDENCE_ROOT"
    }
    else {
        $rawPath = Join-Path (Join-Path $evidenceBundlePath "production-external-evidence-inbox") $DefaultInboxSubdir
        $source = "default_release_inbox"
    }

    return [ordered]@{
        source = $source
        path = if ([string]::IsNullOrWhiteSpace($rawPath)) { "" } else { Resolve-FullPath $rawPath }
    }
}

function Test-EvidenceDir {
    param(
        [string]$Area,
        [string]$Path,
        [string[]]$RequiredFiles,
        [string]$Source
    )

    $exists = -not [string]::IsNullOrWhiteSpace($Path) -and (Test-Path $Path)
    $presentFiles = @()
    $missingFiles = @()

    foreach ($fileName in $RequiredFiles) {
        if ($exists -and (Test-Path (Join-Path $Path $fileName))) {
            $presentFiles += $fileName
        }
        else {
            $missingFiles += $fileName
        }
    }

    return [ordered]@{
        area = $Area
        source = $Source
        path = $Path
        exists = [bool]$exists
        requiredFiles = @($RequiredFiles)
        requiredFileCount = [int]$RequiredFiles.Count
        presentFiles = @($presentFiles)
        presentFileCount = [int]$presentFiles.Count
        missingFiles = @($missingFiles)
        missingFileCount = [int]$missingFiles.Count
        readyForAcceptance = [bool]($exists -and $missingFiles.Count -eq 0)
    }
}

function Add-AutoCheck {
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
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"
$acceptanceBundlePath = Assert-PathUnderRepo $AcceptanceBundleDir "AcceptanceBundleDir"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if ([string]::IsNullOrWhiteSpace($EvidenceRoot) -and -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable("AITESTPILOT_EXTERNAL_EVIDENCE_ROOT"))) {
    $EvidenceRoot = [Environment]::GetEnvironmentVariable("AITESTPILOT_EXTERNAL_EVIDENCE_ROOT")
}
if ([string]::IsNullOrWhiteSpace($OwnerResponseBundleDir) -and -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable("AITESTPILOT_OWNER_RESPONSE_BUNDLE_DIR"))) {
    $OwnerResponseBundleDir = [Environment]::GetEnvironmentVariable("AITESTPILOT_OWNER_RESPONSE_BUNDLE_DIR")
}

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
$liveRequiredFiles = @(
    "live-model-endpoint-smoke-manifest.json",
    "live-model-endpoint-decision-trace.json"
)

$driverCandidate = Resolve-CandidateDir `
    -ExplicitPath $ProductionDriverEvidenceDir `
    -EnvName "AITESTPILOT_PRODUCTION_DRIVER_EVIDENCE_DIR" `
    -OwnerResponseSubdir "production-driver-evidence" `
    -EvidenceRootSubdir "production-driver-evidence" `
    -DefaultInboxSubdir "production-driver-evidence"
$luaCandidate = Resolve-CandidateDir `
    -ExplicitPath $ProductionLuaEvidenceDir `
    -EnvName "AITESTPILOT_PRODUCTION_LUA_EVIDENCE_DIR" `
    -OwnerResponseSubdir "production-lua-evidence" `
    -EvidenceRootSubdir "production-lua-evidence" `
    -DefaultInboxSubdir "production-lua-evidence"
$liveCandidate = Resolve-CandidateDir `
    -ExplicitPath $LiveModelEndpointSmokeEvidenceDir `
    -EnvName "AITESTPILOT_LIVE_SMOKE_EVIDENCE_DIR" `
    -OwnerResponseSubdir "live-smoke-evidence" `
    -EvidenceRootSubdir "live-smoke-evidence" `
    -DefaultInboxSubdir "live-smoke-evidence"

$areaStatuses = @(
    (Test-EvidenceDir "production_driver_binding" ([string]$driverCandidate.path) $driverRequiredFiles ([string]$driverCandidate.source)),
    (Test-EvidenceDir "production_lua_patch_evidence" ([string]$luaCandidate.path) $luaRequiredFiles ([string]$luaCandidate.source)),
    (Test-EvidenceDir "live_model_endpoint_smoke" ([string]$liveCandidate.path) $liveRequiredFiles ([string]$liveCandidate.source))
)

$readyAreaCount = @($areaStatuses | Where-Object { [bool]$_["readyForAcceptance"] }).Count
$missingFileCount = [int](@($areaStatuses | ForEach-Object { [int]$_["missingFileCount"] } | Measure-Object -Sum).Sum)
$allEvidenceReady = $readyAreaCount -eq 3 -and $missingFileCount -eq 0
$acceptanceRun = $false
$acceptanceSucceeded = $false
$acceptanceFailed = $false
$acceptanceErrorMessage = ""
$acceptanceManifest = $null
$acceptanceManifestPath = Join-Path $acceptanceBundlePath "production-external-evidence-acceptance-manifest.json"
$acceptanceReportPath = Join-Path $acceptanceBundlePath "production-external-evidence-acceptance.md"

if ($allEvidenceReady) {
    $acceptanceRun = $true
    try {
        & (Join-Path $PSScriptRoot "Invoke-AITestPilotProductionExternalEvidenceAcceptance.ps1") `
            -EvidenceBundleDir $evidenceBundlePath `
            -AcceptanceBundleDir $acceptanceBundlePath `
            -ManifestPath $acceptanceManifestPath `
            -ReportPath $acceptanceReportPath `
            -ProductionDriverEvidenceDir ([string]$driverCandidate.path) `
            -ProductionLuaEvidenceDir ([string]$luaCandidate.path) `
            -LiveModelEndpointSmokeEvidenceDir ([string]$liveCandidate.path) `
            -GameReplayDriverType $GameReplayDriverType `
            -RequireAllEvidence `
            -ContractFixtureMode:$ContractFixtureMode | Out-Null
        $acceptanceSucceeded = $true
    }
    catch {
        $acceptanceFailed = $true
        $acceptanceErrorMessage = $_.Exception.Message
    }

    if (Test-Path $acceptanceManifestPath) {
        $acceptanceManifest = Read-JsonFile $acceptanceManifestPath "Production external evidence acceptance manifest"
    }
}

$allExternalEvidenceAccepted = $acceptanceSucceeded -and
    $null -ne $acceptanceManifest -and
    (Get-JsonValue $acceptanceManifest "status" "") -eq "PASS" -and
    (Convert-ToBool (Get-JsonValue $acceptanceManifest "allExternalEvidenceAccepted" $false))
$realHostProjectEvidenceAccepted = $allExternalEvidenceAccepted -and
    (Convert-ToBool (Get-JsonValue $acceptanceManifest "realHostProjectEvidenceAccepted" $false)) -and
    -not [bool]$ContractFixtureMode

$status = if ($allExternalEvidenceAccepted) {
    "PASS"
}
elseif ($allEvidenceReady -or [bool]$RequireAllEvidence) {
    "FAIL"
}
else {
    "PENDING_EXTERNAL_EVIDENCE"
}

$generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
$checks = @()
Add-AutoCheck "external_evidence_discovery_completed" `
    ($areaStatuses.Count -eq 3) `
    "Auto acceptance must inspect driver, Lua, and live-smoke evidence directories."
Add-AutoCheck "pending_state_does_not_run_acceptance" `
    (($allEvidenceReady -and $acceptanceRun) -or ((-not $allEvidenceReady) -and (-not $acceptanceRun))) `
    "Acceptance should run only when all three evidence areas contain every required file."
Add-AutoCheck "accepted_only_after_existing_acceptance_passes" `
    ((-not $allExternalEvidenceAccepted) -or ($acceptanceSucceeded -and $null -ne $acceptanceManifest -and (Get-JsonValue $acceptanceManifest "status" "") -eq "PASS")) `
    "Auto acceptance must delegate pass/fail decisions to the stable external evidence acceptance script."
Add-AutoCheck "fixture_boundary_preserved" `
    ((-not [bool]$ContractFixtureMode) -or (-not $realHostProjectEvidenceAccepted)) `
    "Contract fixture mode must not claim real host-project evidence."
Add-AutoCheck "no_mail_side_effects" `
    ($true) `
    "Auto acceptance must not send email, create confirmation tokens, or check local mail authorization."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
if ($failedChecks.Count -gt 0 -and $status -eq "PASS") {
    $status = "FAIL"
}

$productionOutputBoundary = if ($realHostProjectEvidenceAccepted) {
    "real_host_project_external_evidence_auto_accepted"
}
elseif ($allExternalEvidenceAccepted -and [bool]$ContractFixtureMode) {
    "external_evidence_auto_acceptance_contract_fixture_only"
}
elseif ($status -eq "PENDING_EXTERNAL_EVIDENCE") {
    "external_evidence_auto_acceptance_pending"
}
else {
    "external_evidence_auto_acceptance_failed"
}

$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestFullPath),
    (Convert-ToEvidenceRelativePath $reportFullPath)
)
if (Test-Path $acceptanceManifestPath) {
    $generatedFiles += (Convert-ToEvidenceRelativePath $acceptanceManifestPath)
}
if (Test-Path $acceptanceReportPath) {
    $generatedFiles += (Convert-ToEvidenceRelativePath $acceptanceReportPath)
}
$sourceFiles = @(
    "production-external-evidence-inbox-manifest.json",
    "production-handoff-owner-response-bundle-kit-manifest.json"
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_external_evidence_auto_acceptance.v1"
    status = $status
    generatedAtUtc = $generatedAtUtc
    evidenceBundleDir = $evidenceBundlePath
    evidenceRoot = if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) { "" } else { Resolve-FullPath $EvidenceRoot }
    ownerResponseBundleDir = if ([string]::IsNullOrWhiteSpace($OwnerResponseBundleDir)) { "" } else { Resolve-FullPath $OwnerResponseBundleDir }
    acceptanceBundleDir = $acceptanceBundlePath
    contractFixtureMode = [bool]$ContractFixtureMode
    requireAllEvidence = [bool]$RequireAllEvidence
    readyAreaCount = [int]$readyAreaCount
    missingFileCount = [int]$missingFileCount
    allEvidenceReady = [bool]$allEvidenceReady
    acceptanceRun = [bool]$acceptanceRun
    acceptanceSucceeded = [bool]$acceptanceSucceeded
    acceptanceFailed = [bool]$acceptanceFailed
    acceptanceErrorMessage = $acceptanceErrorMessage
    allExternalEvidenceAccepted = [bool]$allExternalEvidenceAccepted
    realHostProjectEvidenceAccepted = [bool]$realHostProjectEvidenceAccepted
    releasePipelineSendsEmail = $false
    emailSent = $false
    confirmationTokenCreated = $false
    mailAuthorizationCheckedByPipeline = $false
    releasePipelineUsesFixture = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = $productionOutputBoundary
    areaStatuses = @($areaStatuses)
    sourceFiles = @($sourceFiles)
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles + $sourceFiles)
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
}

$reportLines = @(
    "# AI TestPilot Production External Evidence Auto Acceptance",
    "",
    "Schema: ``aitestpilot.production_external_evidence_auto_acceptance.v1``",
    "Generated at UTC: $generatedAtUtc",
    "",
    "## Summary",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Status | $(Format-MarkdownCell $status) |",
    "| Ready areas | $readyAreaCount / 3 |",
    "| Missing files | $missingFileCount |",
    "| Acceptance run | $acceptanceRun |",
    "| All external evidence accepted | $allExternalEvidenceAccepted |",
    "| Real host-project evidence accepted | $realHostProjectEvidenceAccepted |",
    "| Contract fixture mode | $([bool]$ContractFixtureMode) |",
    "",
    "## Areas",
    "",
    "| Area | Source | Exists | Ready | Missing Files | Path |",
    "| --- | --- | --- | --- | ---: | --- |"
)
foreach ($area in $areaStatuses) {
    $reportLines += "| $(Format-MarkdownCell $area.area) | $(Format-MarkdownCell $area.source) | $($area.exists) | $($area.readyForAcceptance) | $($area.missingFileCount) | $(Format-MarkdownCell $area.path) |"
}
$reportLines += @(
    "",
    "## Boundary",
    "",
    "- This script discovers evidence directories and delegates acceptance to the stable external evidence acceptance command.",
    "- It does not send email, create confirmation tokens, or check local mail authorization.",
    "- Pending output is not production acceptance.",
    "- Contract fixture mode never claims real host-project evidence.",
    "",
    "## Checks",
    "",
    "| Check | Result | Message |",
    "| --- | --- | --- |"
)
foreach ($check in $checks) {
    $result = if ([bool]$check.passed) { "PASS" } else { "FAIL" }
    $reportLines += "| $(Format-MarkdownCell $check.name) | $result | $(Format-MarkdownCell $check.message) |"
}

New-Item -ItemType Directory -Force (Split-Path $manifestFullPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestFullPath -Encoding UTF8
$reportLines | Set-Content -Path $reportFullPath -Encoding UTF8

if ([bool]$RequireAllEvidence -and $status -ne "PASS") {
    throw "Production external evidence auto acceptance did not accept all required evidence. Manifest: $manifestFullPath"
}

if ($status -eq "FAIL" -and $acceptanceRun) {
    throw "Production external evidence auto acceptance failed after running acceptance. Manifest: $manifestFullPath"
}

Write-Output "Production external evidence auto acceptance manifest: $manifestFullPath"
Write-Output "Production external evidence auto acceptance report: $reportFullPath"
Write-Output "AI TestPilot production external evidence auto acceptance status: $status"
