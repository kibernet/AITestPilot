[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ProbeDir,
    [string]$ExternalBundleRoot,
    [string]$ManifestPath,
    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ProbeDir)) {
    $ProbeDir = Join-Path $EvidenceBundleDir "production-external-evidence-semantic-preflight-probe"
}

if ([string]::IsNullOrWhiteSpace($ExternalBundleRoot)) {
    $ExternalBundleRoot = Join-Path $tempRoot "AITestPilot\production-external-evidence-semantic-preflight-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-external-evidence-semantic-preflight-probe-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-external-evidence-semantic-preflight-probe.md"
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

function Assert-PathUnderTemp {
    param(
        [string]$Path,
        [string]$Label
    )

    $fullPath = Resolve-FullPath $Path
    if (-not $fullPath.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must stay under system temp for this probe: $fullPath"
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

function Copy-RequiredFiles {
    param(
        [string]$SourceDir,
        [string]$DestinationDir,
        [string[]]$FileNames,
        [string]$Label
    )

    New-Item -ItemType Directory -Force $DestinationDir | Out-Null
    foreach ($fileName in $FileNames) {
        $sourcePath = Join-Path $SourceDir $fileName
        if (-not (Test-Path $sourcePath)) {
            throw "$Label source file is missing: $sourcePath"
        }

        Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $DestinationDir $fileName) -Force
    }
}

function Copy-CompleteBundle {
    param([string]$DestinationRoot)

    if (Test-Path $DestinationRoot) {
        Remove-Item -LiteralPath $DestinationRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force $DestinationRoot | Out-Null

    Copy-RequiredFiles $driverSourceDir (Join-Path $DestinationRoot "production-driver-evidence") $driverFiles "production driver"
    Copy-RequiredFiles $luaSourceDir (Join-Path $DestinationRoot "production-lua-evidence") $luaFiles "production lua"
    Copy-RequiredFiles $liveSourceDir (Join-Path $DestinationRoot "live-smoke-evidence") $liveFiles "live smoke"
}

function Invoke-PreflightCase {
    param(
        [string]$Name,
        [string]$EvidenceRoot = "",
        [string]$OwnerResponseBundleDir = "",
        [switch]$ContractFixtureMode
    )

    $caseManifestPath = Join-Path $probePath "$Name-manifest.json"
    $caseReportPath = Join-Path $probePath "$Name.md"
    $caseOutputPath = Join-Path $probePath "$Name-output.txt"

    $preflightParams = @{
        EvidenceBundleDir = $evidenceBundlePath
        ManifestPath = $caseManifestPath
        ReportPath = $caseReportPath
    }
    if (-not [string]::IsNullOrWhiteSpace($EvidenceRoot)) {
        $preflightParams["EvidenceRoot"] = $EvidenceRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($OwnerResponseBundleDir)) {
        $preflightParams["OwnerResponseBundleDir"] = $OwnerResponseBundleDir
    }
    if ([bool]$ContractFixtureMode) {
        $preflightParams["ContractFixtureMode"] = $true
    }

    $failed = $false
    $errorMessage = ""
    try {
        $output = & (Join-Path $PSScriptRoot "Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1") @preflightParams 2>&1
    }
    catch {
        $failed = $true
        $output = @($_)
        $errorMessage = $_.Exception.Message
    }
    @($output | ForEach-Object { [string]$_ }) | Set-Content -Path $caseOutputPath -Encoding UTF8

    $caseManifest = $null
    if (Test-Path $caseManifestPath) {
        $caseManifest = Read-JsonFile $caseManifestPath "$Name semantic preflight manifest"
    }

    return [ordered]@{
        name = $Name
        failed = [bool]$failed
        errorMessage = $errorMessage
        manifestPath = $caseManifestPath
        manifestRelativePath = Convert-ToEvidenceRelativePath $caseManifestPath
        reportPath = $caseReportPath
        reportRelativePath = Convert-ToEvidenceRelativePath $caseReportPath
        outputPath = $caseOutputPath
        outputRelativePath = Convert-ToEvidenceRelativePath $caseOutputPath
        manifest = $caseManifest
    }
}

function Add-Check {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Message
    )

    $script:checks += [ordered]@{
        name = $Name
        passed = $Passed
        message = $Message
    }
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$probePath = Assert-PathUnderRepo $ProbeDir "ProbeDir"
$externalBundlePath = Assert-PathUnderTemp $ExternalBundleRoot "ExternalBundleRoot"
$manifestOutputPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportOutputPath = Assert-PathUnderRepo $ReportPath "ReportPath"

if (Test-Path $probePath) {
    Remove-Item -LiteralPath $probePath -Recurse -Force
}
if (Test-Path $externalBundlePath) {
    Remove-Item -LiteralPath $externalBundlePath -Recurse -Force
}
New-Item -ItemType Directory -Force $probePath | Out-Null
New-Item -ItemType Directory -Force $externalBundlePath | Out-Null
New-Item -ItemType Directory -Force ([System.IO.Path]::GetDirectoryName($manifestOutputPath)) | Out-Null
New-Item -ItemType Directory -Force ([System.IO.Path]::GetDirectoryName($reportOutputPath)) | Out-Null

$driverProbeManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-driver-evidence-contract-probe-manifest.json") "Production driver evidence contract probe manifest"
$luaProbeManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-lua-patch-evidence-kit-probe-manifest.json") "Production Lua patch evidence kit probe manifest"
$liveProbeManifest = Read-JsonFile (Join-Path $evidenceBundlePath "live-model-endpoint-smoke-evidence-contract-probe-manifest.json") "Live model endpoint smoke evidence contract probe manifest"

$driverSourceDir = Resolve-FullPath ([string](Get-JsonValue $driverProbeManifest "acceptedFixtureBundleDir" ""))
$luaSourceDir = Resolve-FullPath (Join-Path ([string](Get-JsonValue $luaProbeManifest "probeBundleDir" "")) "accepted-fixture-evidence")
$liveSourceDir = Resolve-FullPath ([string](Get-JsonValue $liveProbeManifest "externalBundleDir" ""))

$driverFiles = @(
    "production-replay-integration-checklist.json",
    "repair-retest-manifest.json",
    "repair-driver-failure-manifest.json",
    "replay-profile-import-manifest.json"
)
$luaFiles = @(
    "production-lua-patch-evidence.json",
    "production-lua-patch-retest-template.md",
    "production-lua-patch-rollback-plan-template.md"
)
$liveFiles = @(
    "live-model-endpoint-smoke-manifest.json",
    "live-model-endpoint-decision-trace.json"
)

$completeExternalRoot = Join-Path $externalBundlePath "complete-external-root"
$ownerBundleRoot = Join-Path $externalBundlePath "complete-owner-response-bundle"
$partialBundleRoot = Join-Path $externalBundlePath "partial-owner-response-bundle"
$semanticBadBundleRoot = Join-Path $externalBundlePath "semantic-bad-owner-response-bundle"

Copy-CompleteBundle $completeExternalRoot
Copy-CompleteBundle $ownerBundleRoot
Copy-CompleteBundle $partialBundleRoot
Copy-CompleteBundle $semanticBadBundleRoot

$missingLiveTrace = Join-Path $partialBundleRoot "live-smoke-evidence\live-model-endpoint-decision-trace.json"
if (-not (Test-Path $missingLiveTrace)) {
    throw "Partial bundle removal target is missing: $missingLiveTrace"
}
Remove-Item -LiteralPath $missingLiveTrace -Force

$badLuaEvidencePath = Join-Path $semanticBadBundleRoot "production-lua-evidence\production-lua-patch-evidence.json"
$badLuaEvidence = Read-JsonFile $badLuaEvidencePath "semantic-bad Lua evidence"
$badLuaEvidence.fixtureOnly = $true
$badLuaEvidence.realHostProjectEvidence = $false
$badLuaEvidence.evidenceType = "host_project_template"
$badLuaEvidence.analyzedLuaRoot = "fixture://semantic-bad-production-lua"
$badLuaEvidence | ConvertTo-Json -Depth 100 | Set-Content -Path $badLuaEvidencePath -Encoding UTF8

$cases = @()
$cases += Invoke-PreflightCase "default-pending"
$cases += Invoke-PreflightCase "complete-external-root-contract" -EvidenceRoot $completeExternalRoot -ContractFixtureMode
$cases += Invoke-PreflightCase "complete-owner-response-bundle-contract" -OwnerResponseBundleDir $ownerBundleRoot -ContractFixtureMode
$cases += Invoke-PreflightCase "partial-owner-response-bundle" -OwnerResponseBundleDir $partialBundleRoot
$cases += Invoke-PreflightCase "semantic-bad-owner-response-bundle" -OwnerResponseBundleDir $semanticBadBundleRoot

$defaultCase = $cases | Where-Object { (Get-JsonValue $_ "name" "") -eq "default-pending" } | Select-Object -First 1
$completeRootCase = $cases | Where-Object { (Get-JsonValue $_ "name" "") -eq "complete-external-root-contract" } | Select-Object -First 1
$ownerBundleCase = $cases | Where-Object { (Get-JsonValue $_ "name" "") -eq "complete-owner-response-bundle-contract" } | Select-Object -First 1
$partialCase = $cases | Where-Object { (Get-JsonValue $_ "name" "") -eq "partial-owner-response-bundle" } | Select-Object -First 1
$semanticBadCase = $cases | Where-Object { (Get-JsonValue $_ "name" "") -eq "semantic-bad-owner-response-bundle" } | Select-Object -First 1

$checks = @()
Add-Check "default_missing_evidence_stays_pending" (
    -not [bool]$defaultCase.failed -and
    (Get-JsonValue $defaultCase.manifest "semanticPreflightStatus" "") -eq "PENDING_EXTERNAL_EVIDENCE" -and
    -not (Convert-ToBool (Get-JsonValue $defaultCase.manifest "readyForAcceptanceCandidate" $true)) -and
    (Get-JsonValue $defaultCase.manifest "missingRequiredFileCount" 0) -eq 9
) "Default pipeline state must remain pending with all nine required external evidence files missing."

Add-Check "complete_external_root_contract_ready" (
    -not [bool]$completeRootCase.failed -and
    (Get-JsonValue $completeRootCase.manifest "semanticPreflightStatus" "") -eq "READY_FOR_AUTO_ACCEPTANCE_CANDIDATE" -and
    (Convert-ToBool (Get-JsonValue $completeRootCase.manifest "readyForAcceptanceCandidate" $false)) -and
    (Get-JsonValue $completeRootCase.manifest "missingRequiredFileCount" 1) -eq 0 -and
    (Get-JsonValue $completeRootCase.manifest "semanticFailCount" 1) -eq 0
) "Complete contract fixture evidence root must be candidate-ready only inside contract fixture mode."

Add-Check "complete_owner_response_bundle_contract_ready" (
    -not [bool]$ownerBundleCase.failed -and
    (Get-JsonValue $ownerBundleCase.manifest "semanticPreflightStatus" "") -eq "READY_FOR_AUTO_ACCEPTANCE_CANDIDATE" -and
    (Convert-ToBool (Get-JsonValue $ownerBundleCase.manifest "readyForAcceptanceCandidate" $false)) -and
    (Get-JsonValue $ownerBundleCase.manifest "sourceKind" "") -eq "owner_response_bundle"
) "Complete owner response bundle must be candidate-ready only inside contract fixture mode."

Add-Check "partial_owner_response_bundle_rejected" (
    -not [bool]$partialCase.failed -and
    -not (Convert-ToBool (Get-JsonValue $partialCase.manifest "readyForAcceptanceCandidate" $true)) -and
    (Get-JsonValue $partialCase.manifest "missingRequiredFileCount" 0) -ge 1
) "Owner response bundle with one missing required file must not be candidate-ready."

Add-Check "semantic_bad_owner_response_bundle_rejected" (
    -not [bool]$semanticBadCase.failed -and
    -not (Convert-ToBool (Get-JsonValue $semanticBadCase.manifest "readyForAcceptanceCandidate" $true)) -and
    (Get-JsonValue $semanticBadCase.manifest "semanticFailCount" 0) -gt 0 -and
    (Get-JsonValue $semanticBadCase.manifest "fixtureSignalCount" 0) -gt 0
) "Owner response bundle with complete files but fixture/template semantic signals must not be candidate-ready."

Add-Check "preflight_cases_are_read_only" (
    @($cases | Where-Object {
            (Convert-ToBool (Get-JsonValue $_.manifest "acceptanceRun" $true)) -or
            (Convert-ToBool (Get-JsonValue $_.manifest "hardValidationRun" $true)) -or
            (Convert-ToBool (Get-JsonValue $_.manifest "emailSent" $true)) -or
            (Convert-ToBool (Get-JsonValue $_.manifest "realHostProjectEvidenceAccepted" $true)) -or
            (Convert-ToBool (Get-JsonValue $_.manifest "fixtureEvidencePromoted" $true))
        }).Count -eq 0
) "Semantic preflight cases must not accept evidence, run hard validation, send email, or promote fixtures."

Add-Check "all_case_reports_generated" (
    @($cases | Where-Object { -not (Test-Path $_.manifestPath) -or -not (Test-Path $_.reportPath) -or -not (Test-Path $_.outputPath) }).Count -eq 0
) "Every semantic preflight case must write a manifest, report, and captured output."

$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestOutputPath),
    (Convert-ToEvidenceRelativePath $reportOutputPath)
)
$generatedFiles += @(Get-ChildItem -LiteralPath $probePath -Recurse -File | ForEach-Object { Convert-ToEvidenceRelativePath $_.FullName })
$generatedFiles = @($generatedFiles | Sort-Object -Unique)

$sourceFiles = @()
foreach ($sourceManifestName in @(
        "production-driver-evidence-contract-probe-manifest.json",
        "production-lua-patch-evidence-kit-probe-manifest.json",
        "live-model-endpoint-smoke-evidence-contract-probe-manifest.json",
        "production-external-evidence-partial-matrix-probe-manifest.json",
        "production-external-evidence-gap-analysis-manifest.json"
    )) {
    $sourcePath = Join-Path $evidenceBundlePath $sourceManifestName
    if (Test-Path $sourcePath) {
        $sourceFiles += (Convert-ToEvidenceRelativePath $sourcePath)
    }
}

$caseSummaries = @($cases | ForEach-Object {
        $caseManifest = Get-JsonValue $_ "manifest" $null
        [ordered]@{
            name = Get-JsonValue $_ "name" ""
            failed = [bool](Get-JsonValue $_ "failed" $false)
            semanticPreflightStatus = Get-JsonValue $caseManifest "semanticPreflightStatus" ""
            readyForAcceptanceCandidate = Convert-ToBool (Get-JsonValue $caseManifest "readyForAcceptanceCandidate" $false)
            missingRequiredFileCount = Get-JsonValue $caseManifest "missingRequiredFileCount" 0
            semanticFailCount = Get-JsonValue $caseManifest "semanticFailCount" 0
            semanticWarnCount = Get-JsonValue $caseManifest "semanticWarnCount" 0
            fixtureSignalCount = Get-JsonValue $caseManifest "fixtureSignalCount" 0
            manifest = Get-JsonValue $_ "manifestRelativePath" ""
            report = Get-JsonValue $_ "reportRelativePath" ""
            output = Get-JsonValue $_ "outputRelativePath" ""
        }
    })

function Get-CheckPassed {
    param([string]$Name)

    $match = $checks | Where-Object { (Get-JsonValue $_ "name" "") -eq $Name } | Select-Object -First 1
    return (Convert-ToBool (Get-JsonValue $match "passed" $false))
}

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_external_evidence_semantic_preflight_probe.v1"
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    evidenceBundleDir = $evidenceBundlePath
    probeDir = $probePath
    externalBundleRoot = $externalBundlePath
    externalBundleUnderRepo = $externalBundlePath.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)
    readOnly = $true
    acceptanceRun = $false
    hardValidationRun = $false
    releasePipelineSendsEmail = $false
    emailSent = $false
    realHostProjectEvidenceAccepted = $false
    externalEvidenceAccepted = $false
    releasePipelineUsesFixture = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "production_external_evidence_semantic_preflight_probe_only"
    caseCount = $cases.Count
    completeCandidateCaseCount = @($caseSummaries | Where-Object { $_.readyForAcceptanceCandidate }).Count
    rejectedCaseCount = @($caseSummaries | Where-Object { -not $_.readyForAcceptanceCandidate }).Count
    defaultPendingAccepted = Get-CheckPassed "default_missing_evidence_stays_pending"
    completeExternalRootReady = Get-CheckPassed "complete_external_root_contract_ready"
    ownerResponseBundleReady = Get-CheckPassed "complete_owner_response_bundle_contract_ready"
    partialBundleRejected = Get-CheckPassed "partial_owner_response_bundle_rejected"
    semanticBadBundleRejected = Get-CheckPassed "semantic_bad_owner_response_bundle_rejected"
    semanticFailCaseCount = @($caseSummaries | Where-Object { $_.semanticFailCount -gt 0 }).Count
    fixtureSignalRejectedWithoutContractMode = [bool]($semanticBadCase.manifest.fixtureSignalCount -gt 0 -and -not (Convert-ToBool (Get-JsonValue $semanticBadCase.manifest "readyForAcceptanceCandidate" $true)))
    ownerRepairRouteCaseCount = @($caseSummaries | Where-Object { $_.semanticPreflightStatus -eq "NEEDS_OWNER_REPAIR" }).Count
    missingEvidenceCaseCount = @($caseSummaries | Where-Object { $_.semanticPreflightStatus -eq "PENDING_EXTERNAL_EVIDENCE" }).Count
    semanticPreflightCommand = ".\tools\Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1 -OwnerResponseBundleDir `"path\to\filled-owner-response-bundle`""
    semanticPreflightZipCommand = ".\tools\Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1 -OwnerResponseBundleZipPath `"path\to\filled-owner-response-bundle.zip`""
    cases = @($caseSummaries)
    checkCount = $checks.Count
    failedCheckCount = @($checks | Where-Object { -not (Convert-ToBool (Get-JsonValue $_ "passed" $false)) }).Count
    checks = @($checks)
    sourceFiles = @($sourceFiles)
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles)
}

if ((Get-JsonValue $manifest "failedCheckCount" 0) -ne 0) {
    $manifest.status = "FAIL"
}

$reportStatus = Get-JsonValue $manifest "status" ""
$reportCaseCount = Get-JsonValue $manifest "caseCount" 0
$reportCompleteCandidateCaseCount = Get-JsonValue $manifest "completeCandidateCaseCount" 0
$reportRejectedCaseCount = Get-JsonValue $manifest "rejectedCaseCount" 0
$reportAcceptanceRun = Get-JsonValue $manifest "acceptanceRun" $false
$reportRealHostProjectEvidenceAccepted = Get-JsonValue $manifest "realHostProjectEvidenceAccepted" $false
$reportFixtureEvidencePromoted = Get-JsonValue $manifest "fixtureEvidencePromoted" $false

$reportLines = @(
    "# Production External Evidence Semantic Preflight Probe",
    "",
    "- Status: $reportStatus",
    "- Cases: $reportCaseCount",
    "- Candidate-ready cases: $reportCompleteCandidateCaseCount",
    "- Rejected/pending cases: $reportRejectedCaseCount",
    "- Acceptance run: $reportAcceptanceRun",
    "- Real host-project evidence accepted: $reportRealHostProjectEvidenceAccepted",
    "- Fixture evidence promoted: $reportFixtureEvidencePromoted",
    "",
    "## Cases",
    "",
    "| Case | Status | Candidate | Missing | Semantic FAIL | Fixture signals |",
    "| --- | --- | ---: | ---: | ---: | ---: |"
)

foreach ($caseSummary in $caseSummaries) {
    $caseName = Get-JsonValue $caseSummary "name" ""
    $caseStatus = Get-JsonValue $caseSummary "semanticPreflightStatus" ""
    $caseCandidate = Get-JsonValue $caseSummary "readyForAcceptanceCandidate" $false
    $caseMissing = Get-JsonValue $caseSummary "missingRequiredFileCount" 0
    $caseSemanticFail = Get-JsonValue $caseSummary "semanticFailCount" 0
    $caseFixtureSignals = Get-JsonValue $caseSummary "fixtureSignalCount" 0
    $reportLines += "| $(Format-MarkdownCell $caseName) | $(Format-MarkdownCell $caseStatus) | $caseCandidate | $caseMissing | $caseSemanticFail | $caseFixtureSignals |"
}

$reportLines += @(
    "",
    "## Checks",
    "",
    "| Check | Passed | Message |",
    "| --- | ---: | --- |"
)

foreach ($check in $checks) {
    $checkName = Get-JsonValue $check "name" ""
    $checkPassed = Get-JsonValue $check "passed" $false
    $checkMessage = Get-JsonValue $check "message" ""
    $reportLines += "| $(Format-MarkdownCell $checkName) | $checkPassed | $(Format-MarkdownCell $checkMessage) |"
}

$manifest | ConvertTo-Json -Depth 100 | Set-Content -Path $manifestOutputPath -Encoding UTF8
$reportLines | Set-Content -Path $reportOutputPath -Encoding UTF8

Write-Output $manifestOutputPath
