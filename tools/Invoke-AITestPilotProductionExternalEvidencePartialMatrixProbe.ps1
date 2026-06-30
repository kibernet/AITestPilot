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
    $ProbeDir = Join-Path $EvidenceBundleDir "production-external-evidence-partial-matrix-probe"
}

if ([string]::IsNullOrWhiteSpace($ExternalBundleRoot)) {
    $ExternalBundleRoot = Join-Path $tempRoot "AITestPilot\production-external-evidence-partial-matrix-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-external-evidence-partial-matrix-probe-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-external-evidence-partial-matrix-probe.md"
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

function New-OwnerResponseBundleVariant {
    param(
        [string]$Name,
        [string[]]$IncludedAreas,
        [string]$RemoveRelativePath = ""
    )

    $bundlePath = Join-Path $externalBundlePath $Name
    if (Test-Path $bundlePath) {
        Remove-Item -LiteralPath $bundlePath -Recurse -Force
    }
    New-Item -ItemType Directory -Force $bundlePath | Out-Null

    foreach ($spec in $areaSpecs) {
        $areaDir = Join-Path $bundlePath ([string]$spec.directory)
        New-Item -ItemType Directory -Force $areaDir | Out-Null
        if ($IncludedAreas -contains [string]$spec.area) {
            Copy-RequiredFiles ([string]$spec.sourceDir) $areaDir ([string[]]$spec.files) ([string]$spec.area)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($RemoveRelativePath)) {
        $removePath = Join-Path $bundlePath $RemoveRelativePath
        if (-not (Test-Path $removePath)) {
            throw "Variant removal target is missing: $removePath"
        }
        Remove-Item -LiteralPath $removePath -Force
    }

    return $bundlePath
}

function New-MalformedBundleZip {
    param([string]$Name)

    $malformedRoot = Join-Path $externalBundlePath "$Name-root"
    if (Test-Path $malformedRoot) {
        Remove-Item -LiteralPath $malformedRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force (Join-Path $malformedRoot "not-owner-response-bundle") | Out-Null
    "This zip intentionally omits the required owner response evidence directories." |
        Set-Content -Path (Join-Path $malformedRoot "not-owner-response-bundle\README.md") -Encoding UTF8

    $zipPath = Join-Path $probePath "$Name.zip"
    if (Test-Path $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    Compress-Archive -Path (Join-Path $malformedRoot "*") -DestinationPath $zipPath -Force
    return $zipPath
}

function Invoke-AutoAcceptanceCase {
    param(
        [string]$Name,
        [string]$OwnerResponseBundleDir = "",
        [string]$OwnerResponseBundleZipPath = ""
    )

    $caseManifestPath = Join-Path $probePath "$Name-manifest.json"
    $caseReportPath = Join-Path $probePath "$Name.md"
    $caseAcceptanceDir = Join-Path $probePath $Name
    $caseOutputPath = Join-Path $probePath "$Name-output.txt"

    $autoParams = @{
        EvidenceBundleDir = $evidenceBundlePath
        ManifestPath = $caseManifestPath
        ReportPath = $caseReportPath
        AcceptanceBundleDir = $caseAcceptanceDir
        RequireAllEvidence = $true
        ContractFixtureMode = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($OwnerResponseBundleDir)) {
        $autoParams["OwnerResponseBundleDir"] = $OwnerResponseBundleDir
    }
    if (-not [string]::IsNullOrWhiteSpace($OwnerResponseBundleZipPath)) {
        $autoParams["OwnerResponseBundleZipPath"] = $OwnerResponseBundleZipPath
    }

    $failed = $false
    $errorMessage = ""
    try {
        $output = & (Join-Path $PSScriptRoot "Invoke-AITestPilotProductionExternalEvidenceAutoAcceptance.ps1") @autoParams 2>&1
    }
    catch {
        $failed = $true
        $output = @($_)
        $errorMessage = $_.Exception.Message
    }
    @($output | ForEach-Object { [string]$_ }) | Set-Content -Path $caseOutputPath -Encoding UTF8

    return [ordered]@{
        name = $Name
        commandFailed = [bool]$failed
        errorMessage = $errorMessage
        outputPath = $caseOutputPath
        manifestPath = $caseManifestPath
        reportPath = $caseReportPath
        manifestGenerated = (Test-Path $caseManifestPath)
        reportGenerated = (Test-Path $caseReportPath)
        manifest = if (Test-Path $caseManifestPath) { Read-JsonFile $caseManifestPath "$Name auto acceptance manifest" } else { $null }
    }
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

function Test-RejectedManifestCase {
    param(
        [object]$Case,
        [int]$ExpectedReadyAreaCount,
        [int]$ExpectedMissingFileCount
    )

    $manifest = Get-JsonValue $Case "manifest" $null
    return (Convert-ToBool (Get-JsonValue $Case "commandFailed" $false)) -and
        (Convert-ToBool (Get-JsonValue $Case "manifestGenerated" $false)) -and
        (Convert-ToBool (Get-JsonValue $Case "reportGenerated" $false)) -and
        $null -ne $manifest -and
        (Get-JsonValue $manifest "schemaVersion" "") -eq "aitestpilot.production_external_evidence_auto_acceptance.v1" -and
        (Get-JsonValue $manifest "status" "") -eq "FAIL" -and
        (Convert-ToInt (Get-JsonValue $manifest "readyAreaCount" -1)) -eq $ExpectedReadyAreaCount -and
        (Convert-ToInt (Get-JsonValue $manifest "missingFileCount" -1)) -eq $ExpectedMissingFileCount -and
        -not (Convert-ToBool (Get-JsonValue $manifest "acceptanceRun" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $manifest "allExternalEvidenceAccepted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $manifest "realHostProjectEvidenceAccepted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $manifest "fixtureEvidencePromoted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $manifest "emailSent" $true))
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$probePath = Assert-PathUnderRepo $ProbeDir "ProbeDir"
$externalBundlePath = Assert-PathUnderTemp $ExternalBundleRoot "ExternalBundleRoot"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if (Test-Path $probePath) {
    Remove-Item -LiteralPath $probePath -Recurse -Force
}
if (Test-Path $externalBundlePath) {
    Remove-Item -LiteralPath $externalBundlePath -Recurse -Force
}
New-Item -ItemType Directory -Force $probePath | Out-Null
New-Item -ItemType Directory -Force $externalBundlePath | Out-Null

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

$driverContract = Read-JsonFile (Join-Path $evidenceBundlePath "production-driver-evidence-contract-probe-manifest.json") "Production driver evidence contract probe manifest"
$luaContract = Read-JsonFile (Join-Path $evidenceBundlePath "production-lua-patch-evidence-kit-probe-manifest.json") "Production Lua patch evidence kit probe manifest"
$liveContract = Read-JsonFile (Join-Path $evidenceBundlePath "live-model-endpoint-smoke-evidence-contract-probe-manifest.json") "Live model endpoint smoke evidence contract probe manifest"

$driverSourceDir = Resolve-FullPath ([string](Get-JsonValue $driverContract "acceptedFixtureBundleDir" ""))
$luaSourceDir = Join-Path (Resolve-FullPath ([string](Get-JsonValue $luaContract "probeBundleDir" ""))) "accepted-fixture-evidence"
$liveSourceDir = Resolve-FullPath ([string](Get-JsonValue $liveContract "externalBundleDir" ""))

$areaSpecs = @(
    [ordered]@{ area = "production_driver_binding"; directory = "production-driver-evidence"; files = [string[]]$driverFiles; sourceDir = $driverSourceDir },
    [ordered]@{ area = "production_lua_patch_evidence"; directory = "production-lua-evidence"; files = [string[]]$luaFiles; sourceDir = $luaSourceDir },
    [ordered]@{ area = "live_model_endpoint_smoke"; directory = "live-smoke-evidence"; files = [string[]]$liveFiles; sourceDir = $liveSourceDir }
)

$driverOnlyDir = New-OwnerResponseBundleVariant -Name "driver-only-owner-response-bundle" -IncludedAreas @("production_driver_binding")
$luaOnlyDir = New-OwnerResponseBundleVariant -Name "lua-only-owner-response-bundle" -IncludedAreas @("production_lua_patch_evidence")
$liveOnlyDir = New-OwnerResponseBundleVariant -Name "live-only-owner-response-bundle" -IncludedAreas @("live_model_endpoint_smoke")
$missingDriverFileDir = New-OwnerResponseBundleVariant `
    -Name "missing-driver-file-owner-response-bundle" `
    -IncludedAreas @("production_driver_binding", "production_lua_patch_evidence", "live_model_endpoint_smoke") `
    -RemoveRelativePath "production-driver-evidence\replay-profile-import-manifest.json"
$malformedZipPath = New-MalformedBundleZip -Name "malformed-owner-response-bundle"

$caseResults = @(
    (Invoke-AutoAcceptanceCase -Name "driver-only-owner-response-bundle" -OwnerResponseBundleDir $driverOnlyDir),
    (Invoke-AutoAcceptanceCase -Name "lua-only-owner-response-bundle" -OwnerResponseBundleDir $luaOnlyDir),
    (Invoke-AutoAcceptanceCase -Name "live-only-owner-response-bundle" -OwnerResponseBundleDir $liveOnlyDir),
    (Invoke-AutoAcceptanceCase -Name "missing-driver-file-owner-response-bundle" -OwnerResponseBundleDir $missingDriverFileDir),
    (Invoke-AutoAcceptanceCase -Name "malformed-owner-response-bundle-zip" -OwnerResponseBundleZipPath $malformedZipPath)
)

$driverOnlyCase = $caseResults[0]
$luaOnlyCase = $caseResults[1]
$liveOnlyCase = $caseResults[2]
$missingDriverFileCase = $caseResults[3]
$malformedZipCase = $caseResults[4]

$singleAreaCasesRejected = (Test-RejectedManifestCase $driverOnlyCase 1 5) -and
    (Test-RejectedManifestCase $luaOnlyCase 1 6) -and
    (Test-RejectedManifestCase $liveOnlyCase 1 7)
$singleFileMissingRejected = Test-RejectedManifestCase $missingDriverFileCase 2 1
$malformedZipRejected = (Convert-ToBool (Get-JsonValue $malformedZipCase "commandFailed" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $malformedZipCase "manifestGenerated" $true)) -and
    ([string](Get-JsonValue $malformedZipCase "errorMessage" "")).Contains("Could not locate owner response bundle evidence directories")

$manifestCaseResults = @($driverOnlyCase, $luaOnlyCase, $liveOnlyCase, $missingDriverFileCase)
$boundaryPreserved = $true
foreach ($case in $manifestCaseResults) {
    $caseManifest = Get-JsonValue $case "manifest" $null
    if ($null -eq $caseManifest -or
        (Convert-ToBool (Get-JsonValue $caseManifest "acceptanceRun" $true)) -or
        (Convert-ToBool (Get-JsonValue $caseManifest "realHostProjectEvidenceAccepted" $true)) -or
        (Convert-ToBool (Get-JsonValue $caseManifest "fixtureEvidencePromoted" $true)) -or
        (Convert-ToBool (Get-JsonValue $caseManifest "emailSent" $true))) {
        $boundaryPreserved = $false
    }
}

$externalBundleUnderRepo = $externalBundlePath.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)
$generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
$checks = @()
Add-ProbeCheck "partial_matrix_sources_available" `
    ((Get-JsonValue $driverContract "status" "") -eq "PASS" -and
        (Get-JsonValue $luaContract "status" "") -eq "PASS" -and
        (Get-JsonValue $liveContract "status" "") -eq "PASS" -and
        (Test-Path (Join-Path $PSScriptRoot "Invoke-AITestPilotProductionExternalEvidenceAutoAcceptance.ps1"))) `
    "Partial matrix probe must use passing accepted-contract source fixtures and the auto-acceptance script."
Add-ProbeCheck "single_area_bundles_rejected" `
    $singleAreaCasesRejected `
    "Driver-only, Lua-only, and live-only owner response bundles must be rejected before acceptance runs."
Add-ProbeCheck "single_missing_file_bundle_rejected" `
    $singleFileMissingRejected `
    "A nearly complete owner response bundle missing one required driver file must be rejected before acceptance runs."
Add-ProbeCheck "malformed_zip_rejected" `
    $malformedZipRejected `
    "A zip without owner response evidence directories must be rejected before manifest promotion."
Add-ProbeCheck "partial_matrix_boundary_preserved" `
    $boundaryPreserved `
    "Rejected partial evidence must not run acceptance, send mail, accept real evidence, or promote fixtures."
Add-ProbeCheck "partial_matrix_external_fixtures_outside_repo" `
    (-not [bool]$externalBundleUnderRepo) `
    "Partial matrix fixture bundles must stay outside the repository."

$failedChecks = @($checks | Where-Object { -not [bool]$_["passed"] })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$reportLines = @(
    "# AI TestPilot Production External Evidence Partial Matrix Probe",
    "",
    "Schema: ``aitestpilot.production_external_evidence_partial_matrix_probe.v1``",
    "Generated at UTC: $generatedAtUtc",
    "",
    "## Summary",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Status | $(Format-MarkdownCell $status) |",
    "| Case count | $($caseResults.Count) |",
    "| Single area cases rejected | $singleAreaCasesRejected |",
    "| Single missing file rejected | $singleFileMissingRejected |",
    "| Malformed zip rejected | $malformedZipRejected |",
    "| External fixture under repo | $externalBundleUnderRepo |",
    "",
    "## Cases",
    "",
    "| Case | Failed | Manifest | Status | Ready Areas | Missing Files | Acceptance Run |",
    "| --- | --- | --- | --- | ---: | ---: | --- |"
)
foreach ($case in $caseResults) {
    $caseManifest = Get-JsonValue $case "manifest" $null
    $caseName = Format-MarkdownCell (Get-JsonValue $case "name" "")
    $commandFailed = Get-JsonValue $case "commandFailed" $false
    $manifestGenerated = Get-JsonValue $case "manifestGenerated" $false
    $caseStatus = Format-MarkdownCell (Get-JsonValue $caseManifest "status" "pre_manifest_rejected")
    $readyAreaCount = Convert-ToInt (Get-JsonValue $caseManifest "readyAreaCount" 0)
    $missingFileCount = Convert-ToInt (Get-JsonValue $caseManifest "missingFileCount" 0)
    $acceptanceRun = Get-JsonValue $caseManifest "acceptanceRun" $false
    $reportLines += "| $caseName | $commandFailed | $manifestGenerated | $caseStatus | $readyAreaCount | $missingFileCount | $acceptanceRun |"
}
$reportLines += @(
    "",
    "## Boundary",
    "",
    "- These cases use accepted fixture evidence only to build intentionally incomplete return packages.",
    "- Rejected packages must not run acceptance or claim real host-project evidence.",
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
$reportLines | Set-Content -Path $reportFullPath -Encoding UTF8

$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestFullPath),
    (Convert-ToEvidenceRelativePath $reportFullPath)
)
foreach ($file in @(Get-ChildItem -LiteralPath $probePath -Recurse -File)) {
    $relative = Convert-ToEvidenceRelativePath $file.FullName
    if ($generatedFiles -notcontains $relative) {
        $generatedFiles += $relative
    }
}
$sourceFiles = @(
    "production-driver-evidence-contract-probe-manifest.json",
    "production-lua-patch-evidence-kit-probe-manifest.json",
    "live-model-endpoint-smoke-evidence-contract-probe-manifest.json"
)

$rejectedCaseCount = @($caseResults | Where-Object { Convert-ToBool (Get-JsonValue $_ "commandFailed" $false) }).Count
$manifestRejectedCaseCount = @($caseResults | Where-Object { Convert-ToBool (Get-JsonValue $_ "manifestGenerated" $false) }).Count
$preManifestRejectedCaseCount = @($caseResults | Where-Object { -not (Convert-ToBool (Get-JsonValue $_ "manifestGenerated" $false)) }).Count

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_external_evidence_partial_matrix_probe.v1"
    status = $status
    generatedAtUtc = $generatedAtUtc
    evidenceBundleDir = $evidenceBundlePath
    probeDir = $probePath
    externalBundleRoot = $externalBundlePath
    externalBundleUnderRepo = [bool]$externalBundleUnderRepo
    caseCount = [int]$caseResults.Count
    rejectedCaseCount = [int]$rejectedCaseCount
    manifestRejectedCaseCount = [int]$manifestRejectedCaseCount
    preManifestRejectedCaseCount = [int]$preManifestRejectedCaseCount
    singleAreaCasesRejected = [bool]$singleAreaCasesRejected
    singleFileMissingRejected = [bool]$singleFileMissingRejected
    malformedZipRejected = [bool]$malformedZipRejected
    driverOnlyReadyAreaCount = Convert-ToInt (Get-JsonValue (Get-JsonValue $driverOnlyCase "manifest" $null) "readyAreaCount" 0)
    driverOnlyMissingFileCount = Convert-ToInt (Get-JsonValue (Get-JsonValue $driverOnlyCase "manifest" $null) "missingFileCount" 0)
    luaOnlyReadyAreaCount = Convert-ToInt (Get-JsonValue (Get-JsonValue $luaOnlyCase "manifest" $null) "readyAreaCount" 0)
    luaOnlyMissingFileCount = Convert-ToInt (Get-JsonValue (Get-JsonValue $luaOnlyCase "manifest" $null) "missingFileCount" 0)
    liveOnlyReadyAreaCount = Convert-ToInt (Get-JsonValue (Get-JsonValue $liveOnlyCase "manifest" $null) "readyAreaCount" 0)
    liveOnlyMissingFileCount = Convert-ToInt (Get-JsonValue (Get-JsonValue $liveOnlyCase "manifest" $null) "missingFileCount" 0)
    missingDriverFileReadyAreaCount = Convert-ToInt (Get-JsonValue (Get-JsonValue $missingDriverFileCase "manifest" $null) "readyAreaCount" 0)
    missingDriverFileMissingFileCount = Convert-ToInt (Get-JsonValue (Get-JsonValue $missingDriverFileCase "manifest" $null) "missingFileCount" 0)
    malformedZipManifestGenerated = Convert-ToBool (Get-JsonValue $malformedZipCase "manifestGenerated" $true)
    releasePipelineSendsEmail = $false
    realHostProjectEvidenceAccepted = $false
    externalEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "production_external_evidence_partial_matrix_probe_only"
    cases = @($caseResults | ForEach-Object {
        $caseManifest = Get-JsonValue $_ "manifest" $null
        [ordered]@{
            name = Get-JsonValue $_ "name" ""
            commandFailed = Convert-ToBool (Get-JsonValue $_ "commandFailed" $false)
            manifestGenerated = Convert-ToBool (Get-JsonValue $_ "manifestGenerated" $false)
            reportGenerated = Convert-ToBool (Get-JsonValue $_ "reportGenerated" $false)
            status = [string](Get-JsonValue $caseManifest "status" "pre_manifest_rejected")
            readyAreaCount = Convert-ToInt (Get-JsonValue $caseManifest "readyAreaCount" 0)
            missingFileCount = Convert-ToInt (Get-JsonValue $caseManifest "missingFileCount" 0)
            acceptanceRun = Convert-ToBool (Get-JsonValue $caseManifest "acceptanceRun" $false)
            realHostProjectEvidenceAccepted = Convert-ToBool (Get-JsonValue $caseManifest "realHostProjectEvidenceAccepted" $false)
            fixtureEvidencePromoted = Convert-ToBool (Get-JsonValue $caseManifest "fixtureEvidencePromoted" $false)
        }
    })
    sourceFiles = @($sourceFiles)
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles + $sourceFiles)
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
}

$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestFullPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Production external evidence partial matrix probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production external evidence partial matrix probe manifest: $manifestFullPath"
Write-Output "Production external evidence partial matrix probe report: $reportFullPath"
Write-Output "PASS AI TestPilot production external evidence partial matrix probe"
