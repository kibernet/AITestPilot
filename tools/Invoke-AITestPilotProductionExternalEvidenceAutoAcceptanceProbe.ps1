[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ProbeDir,
    [string]$ExternalEvidenceRoot,
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
    $ProbeDir = Join-Path $EvidenceBundleDir "production-external-evidence-auto-acceptance-probe"
}

if ([string]::IsNullOrWhiteSpace($ExternalEvidenceRoot)) {
    $ExternalEvidenceRoot = Join-Path $tempRoot "AITestPilot\production-external-evidence-auto-acceptance-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-external-evidence-auto-acceptance-probe-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-external-evidence-auto-acceptance-probe.md"
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

function Invoke-AutoAcceptance {
    param(
        [string]$Name,
        [string]$EvidenceRoot = "",
        [switch]$RequireAllEvidence,
        [switch]$ContractFixtureMode
    )

    $manifestPath = Join-Path $probePath "$Name-manifest.json"
    $reportPath = Join-Path $probePath "$Name.md"
    $acceptanceDir = Join-Path $probePath $Name
    $outputPath = Join-Path $probePath "$Name-output.txt"

    $autoParams = @{
        EvidenceBundleDir = $evidenceBundlePath
        ManifestPath = $manifestPath
        ReportPath = $reportPath
        AcceptanceBundleDir = $acceptanceDir
    }
    if (-not [string]::IsNullOrWhiteSpace($EvidenceRoot)) {
        $autoParams["EvidenceRoot"] = $EvidenceRoot
    }
    if ([bool]$RequireAllEvidence) {
        $autoParams["RequireAllEvidence"] = $true
    }
    if ([bool]$ContractFixtureMode) {
        $autoParams["ContractFixtureMode"] = $true
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
    @($output | ForEach-Object { [string]$_ }) | Set-Content -Path $outputPath -Encoding UTF8

    return [ordered]@{
        name = $Name
        failed = [bool]$failed
        errorMessage = $errorMessage
        outputPath = $outputPath
        manifestPath = $manifestPath
        reportPath = $reportPath
        manifest = if (Test-Path $manifestPath) { Read-JsonFile $manifestPath "$Name auto acceptance manifest" } else { $null }
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

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$probePath = Assert-PathUnderRepo $ProbeDir "ProbeDir"
$externalEvidencePath = Assert-PathUnderTemp $ExternalEvidenceRoot "ExternalEvidenceRoot"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if (Test-Path $probePath) {
    Remove-Item -LiteralPath $probePath -Recurse -Force
}
if (Test-Path $externalEvidencePath) {
    Remove-Item -LiteralPath $externalEvidencePath -Recurse -Force
}

New-Item -ItemType Directory -Force $probePath | Out-Null
New-Item -ItemType Directory -Force $externalEvidencePath | Out-Null

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

Copy-RequiredFiles $driverSourceDir (Join-Path $externalEvidencePath "production-driver-evidence") $driverFiles "Production driver accepted fixture"
Copy-RequiredFiles $luaSourceDir (Join-Path $externalEvidencePath "production-lua-evidence") $luaFiles "Production Lua accepted fixture"
Copy-RequiredFiles $liveSourceDir (Join-Path $externalEvidencePath "live-smoke-evidence") $liveFiles "Live smoke accepted fixture"

$pendingRun = Invoke-AutoAcceptance -Name "pending-default-auto-acceptance"
$acceptedRun = Invoke-AutoAcceptance -Name "accepted-contract-auto-acceptance" -EvidenceRoot $externalEvidencePath -RequireAllEvidence -ContractFixtureMode

$pendingManifest = $pendingRun.manifest
$acceptedManifest = $acceptedRun.manifest
$externalBundleUnderRepo = $externalEvidencePath.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)
$externalFileCount = @(
    Get-ChildItem -LiteralPath $externalEvidencePath -Recurse -File |
        Where-Object { $_.Name -notin @("README.md", "required-files.json") }
).Count
$externalRequiredFileCount = 0
foreach ($spec in @(
        [ordered]@{ path = (Join-Path $externalEvidencePath "production-driver-evidence"); files = $driverFiles },
        [ordered]@{ path = (Join-Path $externalEvidencePath "production-lua-evidence"); files = $luaFiles },
        [ordered]@{ path = (Join-Path $externalEvidencePath "live-smoke-evidence"); files = $liveFiles }
    )) {
    foreach ($fileName in @($spec.files)) {
        if (Test-Path (Join-Path ([string]$spec.path) ([string]$fileName))) {
            $externalRequiredFileCount += 1
        }
    }
}

$pendingAccepted = $null -ne $pendingManifest -and
    (Get-JsonValue $pendingManifest "schemaVersion" "") -eq "aitestpilot.production_external_evidence_auto_acceptance.v1" -and
    (Get-JsonValue $pendingManifest "status" "") -eq "PENDING_EXTERNAL_EVIDENCE" -and
    -not (Convert-ToBool (Get-JsonValue $pendingManifest "acceptanceRun" $true)) -and
    (Convert-ToInt (Get-JsonValue $pendingManifest "missingFileCount" 0)) -eq 9 -and
    -not (Convert-ToBool (Get-JsonValue $pendingManifest "realHostProjectEvidenceAccepted" $true)) -and
    (Get-JsonValue $pendingManifest "productionOutputBoundary" "") -eq "external_evidence_auto_acceptance_pending"

$contractAccepted = $null -ne $acceptedManifest -and
    (Get-JsonValue $acceptedManifest "schemaVersion" "") -eq "aitestpilot.production_external_evidence_auto_acceptance.v1" -and
    (Get-JsonValue $acceptedManifest "status" "") -eq "PASS" -and
    (Convert-ToBool (Get-JsonValue $acceptedManifest "allEvidenceReady" $false)) -and
    (Convert-ToBool (Get-JsonValue $acceptedManifest "acceptanceRun" $false)) -and
    (Convert-ToBool (Get-JsonValue $acceptedManifest "acceptanceSucceeded" $false)) -and
    (Convert-ToBool (Get-JsonValue $acceptedManifest "allExternalEvidenceAccepted" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $acceptedManifest "realHostProjectEvidenceAccepted" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $acceptedManifest "releasePipelineSendsEmail" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $acceptedManifest "emailSent" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $acceptedManifest "fixtureEvidencePromoted" $true)) -and
    (Get-JsonValue $acceptedManifest "productionOutputBoundary" "") -eq "external_evidence_auto_acceptance_contract_fixture_only"

$pendingReportText = if (Test-Path $pendingRun.reportPath) { Get-Content -Raw -Path $pendingRun.reportPath -Encoding UTF8 } else { "" }
$acceptedReportText = if (Test-Path $acceptedRun.reportPath) { Get-Content -Raw -Path $acceptedRun.reportPath -Encoding UTF8 } else { "" }
$reportsValidated = $pendingReportText.Contains("PENDING_EXTERNAL_EVIDENCE") -and
    $acceptedReportText.Contains("All external evidence accepted") -and
    -not $pendingReportText.Contains("System.Collections") -and
    -not $acceptedReportText.Contains("System.Collections") -and
    -not $pendingReportText.Contains("@{") -and
    -not $acceptedReportText.Contains("@{")

$checks = @()
Add-ProbeCheck "auto_acceptance_script_available" `
    (Test-Path (Join-Path $PSScriptRoot "Invoke-AITestPilotProductionExternalEvidenceAutoAcceptance.ps1")) `
    "Auto acceptance probe must exercise the generated auto acceptance script."
Add-ProbeCheck "default_missing_evidence_stays_pending" `
    $pendingAccepted `
    "Default release inbox discovery must stay pending and must not run acceptance while nine external evidence files are missing."
Add-ProbeCheck "complete_external_root_accepts_contract_fixture" `
    $contractAccepted `
    "A complete external evidence root must run the stable acceptance command and pass only as a contract fixture."
Add-ProbeCheck "external_fixture_root_outside_repo" `
    (-not [bool]$externalBundleUnderRepo -and $externalRequiredFileCount -eq 9) `
    "Probe fixture root must stay outside the repository and contain the nine required evidence files."
Add-ProbeCheck "auto_acceptance_reports_validated" `
    $reportsValidated `
    "Auto acceptance probe must produce readable pending and accepted Markdown reports."
Add-ProbeCheck "auto_acceptance_boundaries_preserved" `
    (-not (Convert-ToBool (Get-JsonValue $acceptedManifest "realHostProjectEvidenceAccepted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $acceptedManifest "emailSent" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $acceptedManifest "fixtureEvidencePromoted" $true))) `
    "Auto acceptance probe must not send mail, accept real host-project evidence, or promote fixture data."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$reportLines = @(
    "# AI TestPilot Production External Evidence Auto Acceptance Probe",
    "",
    "Schema: ``aitestpilot.production_external_evidence_auto_acceptance_probe.v1``",
    "Generated at UTC: $((Get-Date).ToUniversalTime().ToString("O"))",
    "",
    "## Summary",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Status | $(Format-MarkdownCell $status) |",
    "| Pending run accepted | $pendingAccepted |",
    "| Contract run accepted | $contractAccepted |",
    "| External fixture files | $externalFileCount |",
    "| External required fixture files | $externalRequiredFileCount |",
    "| External fixture under repo | $externalBundleUnderRepo |",
    "",
    "## Boundary",
    "",
    "- Pending discovery does not run acceptance.",
    "- Complete fixture discovery runs acceptance only in contract fixture mode.",
    "- No mail is sent and no real host-project evidence is accepted.",
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
    "production-external-evidence-inbox-manifest.json",
    "production-driver-evidence-contract-probe-manifest.json",
    "production-lua-patch-evidence-kit-probe-manifest.json",
    "live-model-endpoint-smoke-evidence-contract-probe-manifest.json"
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_external_evidence_auto_acceptance_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    probeDir = $probePath
    externalEvidenceRoot = $externalEvidencePath
    externalBundleUnderRepo = [bool]$externalBundleUnderRepo
    externalFixtureFileCount = [int]$externalFileCount
    externalRequiredFixtureFileCount = [int]$externalRequiredFileCount
    pendingDefaultAccepted = [bool]$pendingAccepted
    pendingDefaultStatus = [string](Get-JsonValue $pendingManifest "status" "")
    pendingDefaultAcceptanceRun = Convert-ToBool (Get-JsonValue $pendingManifest "acceptanceRun" $false)
    pendingDefaultMissingFileCount = Convert-ToInt (Get-JsonValue $pendingManifest "missingFileCount" 0)
    acceptedContractAccepted = [bool]$contractAccepted
    acceptedContractStatus = [string](Get-JsonValue $acceptedManifest "status" "")
    acceptedContractAcceptanceRun = Convert-ToBool (Get-JsonValue $acceptedManifest "acceptanceRun" $false)
    acceptedContractAllExternalEvidenceAccepted = Convert-ToBool (Get-JsonValue $acceptedManifest "allExternalEvidenceAccepted" $false)
    acceptedContractRealHostProjectEvidenceAccepted = Convert-ToBool (Get-JsonValue $acceptedManifest "realHostProjectEvidenceAccepted" $true)
    acceptedContractEmailSent = Convert-ToBool (Get-JsonValue $acceptedManifest "emailSent" $true)
    acceptedContractFixtureEvidencePromoted = Convert-ToBool (Get-JsonValue $acceptedManifest "fixtureEvidencePromoted" $true)
    releasePipelineSendsEmail = $false
    emailSent = $false
    realHostProjectEvidenceAccepted = $false
    externalEvidenceAccepted = $false
    releasePipelineUsesFixture = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "production_external_evidence_auto_acceptance_probe_only"
    sourceFiles = @($sourceFiles)
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles + $sourceFiles)
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
}

New-Item -ItemType Directory -Force (Split-Path $manifestFullPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestFullPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Production external evidence auto acceptance probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production external evidence auto acceptance probe manifest: $manifestFullPath"
Write-Output "Production external evidence auto acceptance probe report: $reportFullPath"
Write-Output "PASS AI TestPilot production external evidence auto acceptance probe"
