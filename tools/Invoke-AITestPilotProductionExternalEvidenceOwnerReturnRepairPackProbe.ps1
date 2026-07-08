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

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}
if ([string]::IsNullOrWhiteSpace($ProbeDir)) {
    $ProbeDir = Join-Path $EvidenceBundleDir "production-external-evidence-owner-return-repair-pack-probe"
}
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-external-evidence-owner-return-repair-pack-probe-manifest.json"
}
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-external-evidence-owner-return-repair-pack-probe.md"
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
    $fullRoot = (Resolve-FullPath $Root).TrimEnd([char[]]@("\", "/"))
    return $fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($fullRoot + "\", [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($fullRoot + "/", [System.StringComparison]::OrdinalIgnoreCase)
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

    return $fullPath.Substring($evidenceBundlePath.Length).TrimStart([char[]]@("\", "/")).Replace("\", "/")
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

function Convert-ToSlug {
    param([string]$Value)

    $slug = $Value.ToLowerInvariant() -replace "[^a-z0-9_-]+", "-"
    $slug = $slug.Trim("-")
    if ([string]::IsNullOrWhiteSpace($slug)) {
        return "case"
    }

    return $slug
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
$probePath = Assert-PathUnderRepo $ProbeDir "ProbeDir"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}
if (-not (Test-PathWithinRoot $probePath $evidenceBundlePath)) {
    throw "ProbeDir must stay under EvidenceBundleDir: $probePath"
}

if (Test-Path $probePath) {
    Remove-Item -LiteralPath $probePath -Recurse -Force
}
New-Item -ItemType Directory -Force $probePath | Out-Null

$semanticProbeManifestPath = Join-Path $evidenceBundlePath "production-external-evidence-semantic-preflight-probe-manifest.json"
$semanticProbeManifest = Read-JsonFile $semanticProbeManifestPath "Production external evidence semantic preflight probe manifest"
$repairPackScriptPath = Join-Path $repoRoot "tools\Invoke-AITestPilotProductionExternalEvidenceOwnerReturnRepairPack.ps1"

$cases = @(Convert-ToArray (Get-JsonValue $semanticProbeManifest "cases" @()))
$rejectedCases = @($cases | Where-Object { -not (Convert-ToBool (Get-JsonValue $_ "readyForAcceptanceCandidate" $false)) })
$caseSummaries = @()
foreach ($case in $rejectedCases) {
    $caseName = [string](Get-JsonValue $case "name" "")
    $caseSlug = Convert-ToSlug $caseName
    $caseManifestRelativePath = [string](Get-JsonValue $case "manifest" "")
    if ([string]::IsNullOrWhiteSpace($caseManifestRelativePath)) {
        throw "Semantic preflight probe case is missing manifest path: $caseName"
    }

    $caseManifestPath = Join-Path $evidenceBundlePath $caseManifestRelativePath
    $repairCaseDir = Join-Path $probePath $caseSlug
    $repairManifestPath = Join-Path $probePath "$caseSlug-repair-pack-manifest.json"
    $repairReportPath = Join-Path $probePath "$caseSlug-repair-pack.md"

    & $repairPackScriptPath `
        -EvidenceBundleDir $evidenceBundlePath `
        -SemanticPreflightManifestPath $caseManifestPath `
        -RepairPackDir $repairCaseDir `
        -ManifestPath $repairManifestPath `
        -ReportPath $repairReportPath | Out-Null

    $repairManifest = Read-JsonFile $repairManifestPath "$caseName repair pack manifest"
    $caseSummaries += [ordered]@{
        name = $caseName
        semanticPreflightStatus = [string](Get-JsonValue $repairManifest "semanticPreflightStatus" "")
        readyForAcceptanceCandidate = Convert-ToBool (Get-JsonValue $repairManifest "readyForAcceptanceCandidate" $true)
        repairItemCount = Convert-ToInt (Get-JsonValue $repairManifest "repairItemCount" 0)
        ownerRepairRouteCount = Convert-ToInt (Get-JsonValue $repairManifest "ownerRepairRouteCount" 0)
        zipOrRootRepairItemCount = Convert-ToInt (Get-JsonValue $repairManifest "zipOrRootRepairItemCount" 0)
        missingFileRepairItemCount = Convert-ToInt (Get-JsonValue $repairManifest "missingFileRepairItemCount" 0)
        semanticRepairItemCount = Convert-ToInt (Get-JsonValue $repairManifest "semanticRepairItemCount" 0)
        payloadShapeRepairItemCount = Convert-ToInt (Get-JsonValue $repairManifest "payloadShapeRepairItemCount" 0)
        readOnly = Convert-ToBool (Get-JsonValue $repairManifest "readOnly" $false)
        acceptanceRun = Convert-ToBool (Get-JsonValue $repairManifest "acceptanceRun" $true)
        hardValidationRun = Convert-ToBool (Get-JsonValue $repairManifest "hardValidationRun" $true)
        emailSent = Convert-ToBool (Get-JsonValue $repairManifest "emailSent" $true)
        realHostProjectEvidenceAccepted = Convert-ToBool (Get-JsonValue $repairManifest "realHostProjectEvidenceAccepted" $true)
        externalEvidenceAccepted = Convert-ToBool (Get-JsonValue $repairManifest "externalEvidenceAccepted" $true)
        fixtureEvidencePromoted = Convert-ToBool (Get-JsonValue $repairManifest "fixtureEvidencePromoted" $true)
        manifest = Convert-ToEvidenceRelativePath $repairManifestPath
        report = Convert-ToEvidenceRelativePath $repairReportPath
    }
}

function Get-CaseSummary {
    param([string]$Name)
    return $caseSummaries | Where-Object { [string](Get-JsonValue $_ "name" "") -eq $Name } | Select-Object -First 1
}

$partialCases = @($caseSummaries | Where-Object { [string](Get-JsonValue $_ "name" "") -match "partial-owner-response-bundle" })
$semanticBadCases = @($caseSummaries | Where-Object { [string](Get-JsonValue $_ "name" "") -match "semantic-bad-owner-response-bundle" })
$payloadShapeCases = @($caseSummaries | Where-Object { [string](Get-JsonValue $_ "name" "") -match "extra-payload|nested-payload" })
$unsafeZipCase = Get-CaseSummary "unsafe-owner-response-bundle-zip"
$defaultPendingCase = Get-CaseSummary "default-pending"

$boundaryFailures = @($caseSummaries | Where-Object {
        -not (Convert-ToBool (Get-JsonValue $_ "readOnly" $false)) -or
        (Convert-ToBool (Get-JsonValue $_ "acceptanceRun" $true)) -or
        (Convert-ToBool (Get-JsonValue $_ "hardValidationRun" $true)) -or
        (Convert-ToBool (Get-JsonValue $_ "emailSent" $true)) -or
        (Convert-ToBool (Get-JsonValue $_ "realHostProjectEvidenceAccepted" $true)) -or
        (Convert-ToBool (Get-JsonValue $_ "externalEvidenceAccepted" $true)) -or
        (Convert-ToBool (Get-JsonValue $_ "fixtureEvidencePromoted" $true))
    })
$casesWithoutRepairItems = @($caseSummaries | Where-Object { (Convert-ToInt (Get-JsonValue $_ "repairItemCount" 0)) -le 0 })

$checks = @()
Add-ProbeCheck "semantic_preflight_probe_passed" `
    ((Get-JsonValue $semanticProbeManifest "status" "") -eq "PASS" -and (Convert-ToInt (Get-JsonValue $semanticProbeManifest "rejectedCaseCount" 0)) -ge 8) `
    "Repair pack probe must be based on the passing semantic preflight probe with rejected owner-return cases."
Add-ProbeCheck "repair_pack_generated_for_rejected_cases" `
    ($caseSummaries.Count -eq (Convert-ToInt (Get-JsonValue $semanticProbeManifest "rejectedCaseCount" 0)) -and $casesWithoutRepairItems.Count -eq 0) `
    "Each rejected semantic preflight case must produce at least one owner-facing repair item."
Add-ProbeCheck "partial_cases_have_missing_file_repairs" `
    ($partialCases.Count -ge 2 -and @($partialCases | Where-Object { (Convert-ToInt (Get-JsonValue $_ "missingFileRepairItemCount" 0)) -gt 0 }).Count -eq $partialCases.Count) `
    "Partial owner response bundle cases must explain missing required files."
Add-ProbeCheck "semantic_bad_cases_have_semantic_repairs" `
    ($semanticBadCases.Count -ge 2 -and @($semanticBadCases | Where-Object { (Convert-ToInt (Get-JsonValue $_ "semanticRepairItemCount" 0)) -gt 0 }).Count -eq $semanticBadCases.Count) `
    "Semantic-bad owner response bundle cases must explain semantic field/content repairs."
Add-ProbeCheck "payload_shape_cases_have_payload_repairs" `
    ($payloadShapeCases.Count -ge 2 -and @($payloadShapeCases | Where-Object { (Convert-ToInt (Get-JsonValue $_ "payloadShapeRepairItemCount" 0)) -gt 0 }).Count -eq $payloadShapeCases.Count) `
    "Extra-payload and nested-payload cases must explain payload-shape repairs."
Add-ProbeCheck "unsafe_zip_case_prioritizes_zip_repair" `
    ($null -ne $unsafeZipCase -and (Convert-ToInt (Get-JsonValue $unsafeZipCase "zipOrRootRepairItemCount" 0)) -gt 0) `
    "Unsafe owner response bundle zips must surface zip/root repair items."
Add-ProbeCheck "default_pending_case_has_missing_file_repairs" `
    ($null -ne $defaultPendingCase -and (Convert-ToInt (Get-JsonValue $defaultPendingCase "missingFileRepairItemCount" 0)) -ge 9) `
    "Default pending evidence must surface all missing required evidence files."
Add-ProbeCheck "repair_pack_boundaries_preserved" `
    ($boundaryFailures.Count -eq 0) `
    "Repair pack generation must stay read-only and must not send mail, run hard validation, accept evidence, or promote fixtures."

$failedChecks = @($checks | Where-Object { -not [bool](Get-JsonValue $_ "passed" $false) })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }
$generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")

$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestFullPath),
    (Convert-ToEvidenceRelativePath $reportFullPath)
)
$generatedFiles += @(Get-ChildItem -LiteralPath $probePath -Recurse -File | ForEach-Object { Convert-ToEvidenceRelativePath $_.FullName })
$generatedFiles = @($generatedFiles | Sort-Object -Unique)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_external_evidence_owner_return_repair_pack_probe.v1"
    status = $status
    generatedAtUtc = $generatedAtUtc
    evidenceBundleDir = $evidenceBundlePath
    semanticPreflightProbeManifest = Convert-ToEvidenceRelativePath $semanticProbeManifestPath
    readOnly = $true
    acceptanceRun = $false
    hardValidationRun = $false
    emailSent = $false
    realHostProjectEvidenceAccepted = $false
    externalEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    releasePipelineSendsEmail = $false
    rejectedCaseCount = [int]$rejectedCases.Count
    repairPackCaseCount = [int]$caseSummaries.Count
    partialRepairCaseCount = [int]$partialCases.Count
    semanticBadRepairCaseCount = [int]$semanticBadCases.Count
    payloadShapeRepairCaseCount = [int]$payloadShapeCases.Count
    unsafeZipRepairPrioritized = Convert-ToBool (Get-JsonValue $unsafeZipCase "zipOrRootRepairItemCount" 0)
    defaultPendingMissingFileRepairCount = Convert-ToInt (Get-JsonValue $defaultPendingCase "missingFileRepairItemCount" 0)
    caseSummaries = @($caseSummaries)
    productionOutputBoundary = "owner_return_repair_pack_probe_only"
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
    sourceFiles = @((Convert-ToEvidenceRelativePath $semanticProbeManifestPath))
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles)
}
$manifest | ConvertTo-Json -Depth 14 | Set-Content -Path $manifestFullPath -Encoding UTF8

$reportLines = @(
    "# Production External Evidence Owner Return Repair Pack Probe",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Status | $(Format-MarkdownCell $status) |",
    "| Rejected cases | $($rejectedCases.Count) |",
    "| Repair pack cases | $($caseSummaries.Count) |",
    "| Failed checks | $($failedChecks.Count) |",
    "",
    "## Cases",
    "",
    "| Case | Status | Repair Items | Missing Repairs | Semantic Repairs | Payload Repairs | Zip/Root Repairs |",
    "| --- | --- | ---: | ---: | ---: | ---: | ---: |"
)
foreach ($caseSummary in $caseSummaries) {
    $reportLines += "| $(Format-MarkdownCell (Get-JsonValue $caseSummary 'name' '')) | $(Format-MarkdownCell (Get-JsonValue $caseSummary 'semanticPreflightStatus' '')) | $(Get-JsonValue $caseSummary 'repairItemCount' 0) | $(Get-JsonValue $caseSummary 'missingFileRepairItemCount' 0) | $(Get-JsonValue $caseSummary 'semanticRepairItemCount' 0) | $(Get-JsonValue $caseSummary 'payloadShapeRepairItemCount' 0) | $(Get-JsonValue $caseSummary 'zipOrRootRepairItemCount' 0) |"
}
$reportLines += @(
    "",
    "## Checks",
    "",
    "| Check | Passed | Message |",
    "| --- | --- | --- |"
)
foreach ($check in $checks) {
    $reportLines += "| $(Format-MarkdownCell (Get-JsonValue $check 'name' '')) | $(Get-JsonValue $check 'passed' $false) | $(Format-MarkdownCell (Get-JsonValue $check 'message' '')) |"
}
$reportLines | Set-Content -Path $reportFullPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Owner return repair pack probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Owner return repair pack probe manifest: $manifestFullPath"
Write-Output "Owner return repair pack probe report: $reportFullPath"
Write-Output "PASS AI TestPilot owner return repair pack probe"
