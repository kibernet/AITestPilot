[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ProbeDir,
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
    $ProbeDir = Join-Path $EvidenceBundleDir "production-external-evidence-owner-return-bundle-status-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-external-evidence-owner-return-bundle-status-probe-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-external-evidence-owner-return-bundle-status-probe.md"
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
    $rootPath = (Resolve-FullPath $Root).TrimEnd([char[]]@("\", "/"))
    return $fullPath.Equals($rootPath, [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($rootPath + "\", [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($rootPath + "/", [System.StringComparison]::OrdinalIgnoreCase)
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

function Convert-ToEvidenceRelativePath {
    param([string]$Path)

    $fullPath = Resolve-FullPath $Path
    if (-not (Test-PathWithinRoot $fullPath $evidenceBundlePath)) {
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

function Invoke-OwnerReturnStatusCase {
    param(
        [string]$Name,
        [string]$OwnerResponseBundleDir = "",
        [string]$OwnerResponseBundleZipPath = "",
        [switch]$ContractFixtureMode
    )

    $caseManifestPath = Join-Path $probePath "$Name-manifest.json"
    $caseReportPath = Join-Path $probePath "$Name.md"
    $caseOutputPath = Join-Path $probePath "$Name-output.txt"
    $statusParams = @{
        EvidenceBundleDir = $evidenceBundlePath
        ManifestPath = $caseManifestPath
        ReportPath = $caseReportPath
    }
    if (-not [string]::IsNullOrWhiteSpace($OwnerResponseBundleDir)) {
        $statusParams["OwnerResponseBundleDir"] = $OwnerResponseBundleDir
    }
    if (-not [string]::IsNullOrWhiteSpace($OwnerResponseBundleZipPath)) {
        $statusParams["OwnerResponseBundleZipPath"] = $OwnerResponseBundleZipPath
    }
    if ([bool]$ContractFixtureMode) {
        $statusParams["ContractFixtureMode"] = $true
    }

    $failed = $false
    $errorMessage = ""
    try {
        $output = & (Join-Path $PSScriptRoot "Invoke-AITestPilotProductionExternalEvidenceOwnerReturnBundleStatus.ps1") @statusParams 2>&1
    }
    catch {
        $failed = $true
        $output = @($_)
        $errorMessage = $_.Exception.Message
    }
    @($output | ForEach-Object { [string]$_ }) | Set-Content -Path $caseOutputPath -Encoding UTF8

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
        manifest = if (Test-Path $caseManifestPath) { Read-JsonFile $caseManifestPath "$Name owner return status manifest" } else { $null }
    }
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$probePath = Assert-PathUnderRepo $ProbeDir "ProbeDir"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}
if (Test-Path $probePath) {
    Remove-Item -LiteralPath $probePath -Recurse -Force
}
New-Item -ItemType Directory -Force $probePath | Out-Null
New-Item -ItemType Directory -Force (Split-Path $manifestFullPath -Parent) | Out-Null
New-Item -ItemType Directory -Force (Split-Path $reportFullPath -Parent) | Out-Null

$semanticPreflightProbeManifestPath = Join-Path $evidenceBundlePath "production-external-evidence-semantic-preflight-probe-manifest.json"
$semanticPreflightProbeDir = Join-Path $evidenceBundlePath "production-external-evidence-semantic-preflight-probe"
$semanticPreflightExternalRoot = Join-Path $tempRoot "AITestPilot\production-external-evidence-semantic-preflight-probe"
$completeOwnerResponseBundleDir = Join-Path $semanticPreflightExternalRoot "complete-owner-response-bundle"
$extraPayloadOwnerResponseBundleDir = Join-Path $semanticPreflightExternalRoot "extra-payload-owner-response-bundle"
$completeOwnerResponseBundleZipPath = Join-Path $semanticPreflightProbeDir "complete-owner-response-bundle.zip"

if (-not (Test-Path $semanticPreflightProbeManifestPath) -or
    -not (Test-Path $completeOwnerResponseBundleDir) -or
    -not (Test-Path $extraPayloadOwnerResponseBundleDir) -or
    -not (Test-Path $completeOwnerResponseBundleZipPath)) {
    & (Join-Path $PSScriptRoot "Invoke-AITestPilotProductionExternalEvidenceSemanticPreflightProbe.ps1") -EvidenceBundleDir $evidenceBundlePath | Out-Null
}

$semanticPreflightProbeManifest = Read-JsonFile $semanticPreflightProbeManifestPath "Production external evidence semantic preflight probe manifest"

$cases = @()
$cases += Invoke-OwnerReturnStatusCase "default-owner-return-status"
$cases += Invoke-OwnerReturnStatusCase "complete-owner-response-bundle-zip-status" -OwnerResponseBundleZipPath $completeOwnerResponseBundleZipPath -ContractFixtureMode
$cases += Invoke-OwnerReturnStatusCase "extra-payload-owner-response-bundle-status" -OwnerResponseBundleDir $extraPayloadOwnerResponseBundleDir -ContractFixtureMode

$defaultCase = $cases | Where-Object { (Get-JsonValue $_ "name" "") -eq "default-owner-return-status" } | Select-Object -First 1
$completeZipCase = $cases | Where-Object { (Get-JsonValue $_ "name" "") -eq "complete-owner-response-bundle-zip-status" } | Select-Object -First 1
$extraPayloadCase = $cases | Where-Object { (Get-JsonValue $_ "name" "") -eq "extra-payload-owner-response-bundle-status" } | Select-Object -First 1

$defaultManifest = Get-JsonValue $defaultCase "manifest" $null
$completeZipManifest = Get-JsonValue $completeZipCase "manifest" $null
$extraPayloadManifest = Get-JsonValue $extraPayloadCase "manifest" $null

$checks = @()
Add-ProbeCheck "semantic_preflight_probe_source_available" `
    ((Get-JsonValue $semanticPreflightProbeManifest "status" "") -eq "PASS" -and
        (Convert-ToBool (Get-JsonValue $semanticPreflightProbeManifest "ownerResponseBundleZipReady" $false)) -and
        (Convert-ToBool (Get-JsonValue $semanticPreflightProbeManifest "extraPayloadBundleRejected" $false))) `
    "Semantic preflight probe must provide complete and rejected owner bundle fixtures."
Add-ProbeCheck "default_owner_return_stays_pending" `
    (-not [bool](Get-JsonValue $defaultCase "failed" $true) -and
        (Get-JsonValue $defaultManifest "schemaVersion" "") -eq "aitestpilot.production_external_evidence_owner_return_bundle_status.v1" -and
        (Get-JsonValue $defaultManifest "status" "") -eq "PASS" -and
        (Get-JsonValue $defaultManifest "ownerReturnReadinessStatus" "") -eq "PENDING_EXTERNAL_EVIDENCE" -and
        -not (Convert-ToBool (Get-JsonValue $defaultManifest "semanticPreflightRun" $true)) -and
        (Convert-ToInt (Get-JsonValue $defaultManifest "pendingOwnerPacketCount" 0)) -eq 3 -and
        (Convert-ToInt (Get-JsonValue $defaultManifest "remainingMissingFileCount" 0)) -eq 9 -and
        (Convert-ToInt (Get-JsonValue $defaultManifest "remainingBlockingReasonCount" 0)) -eq 11 -and
        -not (Convert-ToBool (Get-JsonValue $defaultManifest "acceptanceRun" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $defaultManifest "realHostProjectEvidenceAccepted" $true))) `
    "Default owner return status must stay pending without running semantic preflight or acceptance."
Add-ProbeCheck "complete_owner_response_bundle_zip_candidate_ready" `
    (-not [bool](Get-JsonValue $completeZipCase "failed" $true) -and
        (Get-JsonValue $completeZipManifest "status" "") -eq "PASS" -and
        (Get-JsonValue $completeZipManifest "ownerReturnReadinessStatus" "") -eq "READY_FOR_AUTO_ACCEPTANCE_CANDIDATE" -and
        (Get-JsonValue $completeZipManifest "semanticPreflightStatus" "") -eq "READY_FOR_AUTO_ACCEPTANCE_CANDIDATE" -and
        (Convert-ToBool (Get-JsonValue $completeZipManifest "readyForAcceptanceCandidate" $false)) -and
        (Convert-ToBool (Get-JsonValue $completeZipManifest "ownerReturnBundleZipInspected" $false)) -and
        (Convert-ToBool (Get-JsonValue $completeZipManifest "ownerReturnBundleZipSafe" $false)) -and
        (Convert-ToInt (Get-JsonValue $completeZipManifest "missingRequiredFileCount" -1)) -eq 0 -and
        (Convert-ToInt (Get-JsonValue $completeZipManifest "semanticFailCount" -1)) -eq 0 -and
        (Convert-ToInt (Get-JsonValue $completeZipManifest "ownerResponseBundlePayloadShapeViolationCount" -1)) -eq 0 -and
        -not (Convert-ToBool (Get-JsonValue $completeZipManifest "acceptanceRun" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $completeZipManifest "realHostProjectEvidenceAccepted" $true))) `
    "A complete owner response bundle zip must become auto-acceptance candidate-ready without running acceptance."
Add-ProbeCheck "extra_payload_owner_response_bundle_needs_repair" `
    (-not [bool](Get-JsonValue $extraPayloadCase "failed" $true) -and
        (Get-JsonValue $extraPayloadManifest "status" "") -eq "PASS" -and
        (Get-JsonValue $extraPayloadManifest "ownerReturnReadinessStatus" "") -eq "NEEDS_OWNER_REPAIR" -and
        (Get-JsonValue $extraPayloadManifest "semanticPreflightStatus" "") -eq "NEEDS_OWNER_REPAIR" -and
        -not (Convert-ToBool (Get-JsonValue $extraPayloadManifest "readyForAcceptanceCandidate" $true)) -and
        (Convert-ToInt (Get-JsonValue $extraPayloadManifest "ownerResponseBundlePayloadShapeViolationCount" 0)) -gt 0 -and
        -not (Convert-ToBool (Get-JsonValue $extraPayloadManifest "acceptanceRun" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $extraPayloadManifest "realHostProjectEvidenceAccepted" $true))) `
    "A strict-payload violation must route to owner repair without running acceptance."
Add-ProbeCheck "owner_return_status_cases_are_read_only" `
    (@($cases | Where-Object {
            $caseManifest = Get-JsonValue $_ "manifest" $null
            (Convert-ToBool (Get-JsonValue $caseManifest "acceptanceRun" $true)) -or
            (Convert-ToBool (Get-JsonValue $caseManifest "hardValidationRun" $true)) -or
            (Convert-ToBool (Get-JsonValue $caseManifest "emailSent" $true)) -or
            (Convert-ToBool (Get-JsonValue $caseManifest "realHostProjectEvidenceAccepted" $true)) -or
            (Convert-ToBool (Get-JsonValue $caseManifest "fixtureEvidencePromoted" $true))
        }).Count -eq 0) `
    "Owner return status cases must never run acceptance, hard validation, send mail, or promote fixtures."

$reportTexts = @()
foreach ($case in $cases) {
    $caseReportPath = [string](Get-JsonValue $case "reportPath" "")
    if (Test-Path $caseReportPath) {
        $reportTexts += (Get-Content -Path $caseReportPath -Encoding UTF8 -Raw)
    }
}
$reportsValidated = $reportTexts.Count -eq $cases.Count -and
    @($reportTexts | Where-Object {
        $_.Contains("Production External Evidence Owner Return Bundle Status") -and
        -not $_.Contains("System.Collections") -and
        -not $_.Contains("@{")
    }).Count -eq $cases.Count
Add-ProbeCheck "owner_return_status_reports_validated" $reportsValidated "Owner return status case reports must be readable."

$failedChecks = @($checks | Where-Object { -not (Convert-ToBool (Get-JsonValue $_ "passed" $false)) })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$caseSummaries = @($cases | ForEach-Object {
        $caseManifest = Get-JsonValue $_ "manifest" $null
        [ordered]@{
            name = Get-JsonValue $_ "name" ""
            failed = Convert-ToBool (Get-JsonValue $_ "failed" $false)
            ownerReturnReadinessStatus = Get-JsonValue $caseManifest "ownerReturnReadinessStatus" ""
            semanticPreflightStatus = Get-JsonValue $caseManifest "semanticPreflightStatus" ""
            readyForAcceptanceCandidate = Convert-ToBool (Get-JsonValue $caseManifest "readyForAcceptanceCandidate" $false)
            missingRequiredFileCount = Convert-ToInt (Get-JsonValue $caseManifest "missingRequiredFileCount" 0)
            semanticFailCount = Convert-ToInt (Get-JsonValue $caseManifest "semanticFailCount" 0)
            payloadShapeViolationCount = Convert-ToInt (Get-JsonValue $caseManifest "ownerResponseBundlePayloadShapeViolationCount" 0)
            acceptanceRun = Convert-ToBool (Get-JsonValue $caseManifest "acceptanceRun" $false)
            realHostProjectEvidenceAccepted = Convert-ToBool (Get-JsonValue $caseManifest "realHostProjectEvidenceAccepted" $false)
            manifest = Get-JsonValue $_ "manifestRelativePath" ""
            report = Get-JsonValue $_ "reportRelativePath" ""
            output = Get-JsonValue $_ "outputRelativePath" ""
        }
    })

$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestFullPath),
    (Convert-ToEvidenceRelativePath $reportFullPath)
)
foreach ($file in @(Get-ChildItem -LiteralPath $probePath -Recurse -File)) {
    $generatedFiles += (Convert-ToEvidenceRelativePath $file.FullName)
}
$generatedFiles = @($generatedFiles | Sort-Object -Unique)

$sourceFiles = @(
    "production-external-evidence-semantic-preflight-probe-manifest.json"
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_external_evidence_owner_return_bundle_status_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    probeDir = $probePath
    readOnly = $true
    acceptanceRun = $false
    hardValidationRun = $false
    releasePipelineSendsEmail = $false
    emailSent = $false
    realHostProjectEvidenceAccepted = $false
    externalEvidenceAccepted = $false
    releasePipelineUsesFixture = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "owner_return_bundle_status_probe_only"
    semanticPreflightProbeSourceStatus = [string](Get-JsonValue $semanticPreflightProbeManifest "status" "")
    completeOwnerResponseBundleZipPath = $completeOwnerResponseBundleZipPath
    extraPayloadOwnerResponseBundleDir = $extraPayloadOwnerResponseBundleDir
    caseCount = [int]$cases.Count
    defaultPendingOwnerReturnStatus = Convert-ToBool (Get-JsonValue ($checks | Where-Object { (Get-JsonValue $_ "name" "") -eq "default_owner_return_stays_pending" } | Select-Object -First 1) "passed" $false)
    ownerResponseBundleZipCandidateReady = Convert-ToBool (Get-JsonValue ($checks | Where-Object { (Get-JsonValue $_ "name" "") -eq "complete_owner_response_bundle_zip_candidate_ready" } | Select-Object -First 1) "passed" $false)
    extraPayloadOwnerResponseBundleNeedsRepair = Convert-ToBool (Get-JsonValue ($checks | Where-Object { (Get-JsonValue $_ "name" "") -eq "extra_payload_owner_response_bundle_needs_repair" } | Select-Object -First 1) "passed" $false)
    defaultPendingOwnerPacketCount = Convert-ToInt (Get-JsonValue $defaultManifest "pendingOwnerPacketCount" 0)
    defaultRemainingMissingFileCount = Convert-ToInt (Get-JsonValue $defaultManifest "remainingMissingFileCount" 0)
    defaultRemainingBlockingReasonCount = Convert-ToInt (Get-JsonValue $defaultManifest "remainingBlockingReasonCount" 0)
    completeZipReadyForAcceptanceCandidate = Convert-ToBool (Get-JsonValue $completeZipManifest "readyForAcceptanceCandidate" $false)
    completeZipMissingRequiredFileCount = Convert-ToInt (Get-JsonValue $completeZipManifest "missingRequiredFileCount" 0)
    completeZipSemanticFailCount = Convert-ToInt (Get-JsonValue $completeZipManifest "semanticFailCount" 0)
    extraPayloadPayloadShapeViolationCount = Convert-ToInt (Get-JsonValue $extraPayloadManifest "ownerResponseBundlePayloadShapeViolationCount" 0)
    cases = @($caseSummaries)
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
    sourceFiles = @($sourceFiles)
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles + $sourceFiles)
}

$generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
$defaultPendingStatus = Get-JsonValue $manifest "defaultPendingOwnerReturnStatus" $false
$ownerBundleZipCandidateReady = Get-JsonValue $manifest "ownerResponseBundleZipCandidateReady" $false
$extraPayloadNeedsRepair = Get-JsonValue $manifest "extraPayloadOwnerResponseBundleNeedsRepair" $false
$probeAcceptanceRun = Get-JsonValue $manifest "acceptanceRun" $false
$probeRealHostProjectEvidenceAccepted = Get-JsonValue $manifest "realHostProjectEvidenceAccepted" $false

$reportLines = @(
    "# Production External Evidence Owner Return Bundle Status Probe",
    "",
    "Schema: ``aitestpilot.production_external_evidence_owner_return_bundle_status_probe.v1``",
    "Generated at UTC: $generatedAtUtc",
    "",
    "## Summary",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Status | $(Format-MarkdownCell $status) |",
    "| Cases | $($cases.Count) |",
    "| Default pending | $defaultPendingStatus |",
    "| Complete zip candidate ready | $ownerBundleZipCandidateReady |",
    "| Extra payload needs repair | $extraPayloadNeedsRepair |",
    "| Acceptance run | $probeAcceptanceRun |",
    "| Real host-project evidence accepted | $probeRealHostProjectEvidenceAccepted |",
    "",
    "## Cases",
    "",
    "| Case | Readiness | Semantic | Candidate | Missing | Semantic FAIL | Payload shape | Acceptance run |",
    "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |"
)
foreach ($caseSummary in $caseSummaries) {
    $nameCell = Format-MarkdownCell (Get-JsonValue $caseSummary "name" "")
    $readinessCell = Format-MarkdownCell (Get-JsonValue $caseSummary "ownerReturnReadinessStatus" "")
    $semanticCell = Format-MarkdownCell (Get-JsonValue $caseSummary "semanticPreflightStatus" "")
    $candidateCell = Format-MarkdownCell (Get-JsonValue $caseSummary "readyForAcceptanceCandidate" $false)
    $missingCell = Format-MarkdownCell (Get-JsonValue $caseSummary "missingRequiredFileCount" 0)
    $semanticFailCell = Format-MarkdownCell (Get-JsonValue $caseSummary "semanticFailCount" 0)
    $payloadShapeCell = Format-MarkdownCell (Get-JsonValue $caseSummary "payloadShapeViolationCount" 0)
    $acceptanceRunCell = Format-MarkdownCell (Get-JsonValue $caseSummary "acceptanceRun" $false)
    $reportLines += "| $nameCell | $readinessCell | $semanticCell | $candidateCell | $missingCell | $semanticFailCell | $payloadShapeCell | $acceptanceRunCell |"
}
$reportLines += @(
    "",
    "## Checks",
    "",
    "| Check | Result | Message |",
    "| --- | --- | --- |"
)
foreach ($check in $checks) {
    $result = if (Convert-ToBool (Get-JsonValue $check "passed" $false)) { "PASS" } else { "FAIL" }
    $checkNameCell = Format-MarkdownCell (Get-JsonValue $check "name" "")
    $checkMessageCell = Format-MarkdownCell (Get-JsonValue $check "message" "")
    $reportLines += "| $checkNameCell | $result | $checkMessageCell |"
}
$reportLines | Set-Content -Path $reportFullPath -Encoding UTF8
$manifest | ConvertTo-Json -Depth 14 | Set-Content -Path $manifestFullPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Production external evidence owner return bundle status probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production external evidence owner return bundle status probe manifest: $manifestFullPath"
Write-Output "Production external evidence owner return bundle status probe report: $reportFullPath"
Write-Output "PASS AI TestPilot production external evidence owner return bundle status probe"
