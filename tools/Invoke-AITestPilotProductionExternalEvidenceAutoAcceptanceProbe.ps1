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

function New-UnsafeOwnerResponseBundleZip {
    param([string]$Path)

    if (Test-Path $Path) {
        Remove-Item -LiteralPath $Path -Force
    }

    Add-Type -AssemblyName System.IO.Compression | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    $archive = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        $unsafeEntry = $archive.CreateEntry("../outside.txt")
        $writer = [System.IO.StreamWriter]::new($unsafeEntry.Open())
        try {
            $writer.WriteLine("unsafe")
        }
        finally {
            $writer.Dispose()
        }

        $normalEntry = $archive.CreateEntry("production-driver-evidence/production-replay-integration-checklist.json")
        $writer = [System.IO.StreamWriter]::new($normalEntry.Open())
        try {
            $writer.WriteLine("{}")
        }
        finally {
            $writer.Dispose()
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Invoke-AutoAcceptance {
    param(
        [string]$Name,
        [string]$EvidenceRoot = "",
        [string]$OwnerResponseBundleDir = "",
        [string]$OwnerResponseBundleZipPath = "",
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
    if (-not [string]::IsNullOrWhiteSpace($OwnerResponseBundleDir)) {
        $autoParams["OwnerResponseBundleDir"] = $OwnerResponseBundleDir
    }
    if (-not [string]::IsNullOrWhiteSpace($OwnerResponseBundleZipPath)) {
        $autoParams["OwnerResponseBundleZipPath"] = $OwnerResponseBundleZipPath
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
$ownerResponseBundlePath = Assert-PathUnderTemp (Join-Path (Split-Path -Parent $externalEvidencePath) "owner-response-bundle-auto-acceptance-probe") "OwnerResponseBundlePath"
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
if (Test-Path $ownerResponseBundlePath) {
    Remove-Item -LiteralPath $ownerResponseBundlePath -Recurse -Force
}

New-Item -ItemType Directory -Force $probePath | Out-Null
New-Item -ItemType Directory -Force $externalEvidencePath | Out-Null
New-Item -ItemType Directory -Force $ownerResponseBundlePath | Out-Null
$ownerResponseBundleZipPath = Join-Path $probePath "owner-response-bundle-auto-acceptance.zip"
$unsafeOwnerResponseBundleZipPath = Join-Path $probePath "owner-response-bundle-unsafe-entry.zip"

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
Copy-RequiredFiles (Join-Path $externalEvidencePath "production-driver-evidence") (Join-Path $ownerResponseBundlePath "production-driver-evidence") $driverFiles "Owner response production driver fixture"
Copy-RequiredFiles (Join-Path $externalEvidencePath "production-lua-evidence") (Join-Path $ownerResponseBundlePath "production-lua-evidence") $luaFiles "Owner response production Lua fixture"
Copy-RequiredFiles (Join-Path $externalEvidencePath "live-smoke-evidence") (Join-Path $ownerResponseBundlePath "live-smoke-evidence") $liveFiles "Owner response live smoke fixture"
if (Test-Path $ownerResponseBundleZipPath) {
    Remove-Item -LiteralPath $ownerResponseBundleZipPath -Force
}
Compress-Archive -Path (Join-Path $ownerResponseBundlePath "*") -DestinationPath $ownerResponseBundleZipPath -Force
New-UnsafeOwnerResponseBundleZip $unsafeOwnerResponseBundleZipPath

$pendingRun = Invoke-AutoAcceptance -Name "pending-default-auto-acceptance"
$acceptedRun = Invoke-AutoAcceptance -Name "accepted-contract-auto-acceptance" -EvidenceRoot $externalEvidencePath -RequireAllEvidence -ContractFixtureMode
$ownerResponseBundleRun = Invoke-AutoAcceptance -Name "owner-response-bundle-auto-acceptance" -OwnerResponseBundleDir $ownerResponseBundlePath -RequireAllEvidence -ContractFixtureMode
$ownerResponseBundleZipRun = Invoke-AutoAcceptance -Name "owner-response-bundle-zip-auto-acceptance" -OwnerResponseBundleZipPath $ownerResponseBundleZipPath -RequireAllEvidence -ContractFixtureMode
$semanticBadOwnerResponseBundleRun = Invoke-AutoAcceptance -Name "owner-response-bundle-semantic-bad-auto-acceptance" -OwnerResponseBundleDir $ownerResponseBundlePath -RequireAllEvidence
$unsafeOwnerResponseBundleZipRun = Invoke-AutoAcceptance -Name "owner-response-bundle-unsafe-zip-auto-acceptance" -OwnerResponseBundleZipPath $unsafeOwnerResponseBundleZipPath -RequireAllEvidence -ContractFixtureMode

$pendingManifest = $pendingRun.manifest
$acceptedManifest = $acceptedRun.manifest
$ownerResponseBundleManifest = $ownerResponseBundleRun.manifest
$ownerResponseBundleZipManifest = $ownerResponseBundleZipRun.manifest
$semanticBadOwnerResponseBundleManifest = $semanticBadOwnerResponseBundleRun.manifest
$unsafeOwnerResponseBundleZipManifest = $unsafeOwnerResponseBundleZipRun.manifest
$externalBundleUnderRepo = $externalEvidencePath.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)
$ownerResponseBundleUnderRepo = $ownerResponseBundlePath.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)
$externalFileCount = @(
    Get-ChildItem -LiteralPath $externalEvidencePath -Recurse -File |
        Where-Object { $_.Name -notin @("README.md", "required-files.json") }
).Count
$ownerResponseBundleFileCount = @(
    Get-ChildItem -LiteralPath $ownerResponseBundlePath -Recurse -File |
        Where-Object { $_.Name -notin @("README.md", "required-files.json") }
).Count
$externalRequiredFileCount = 0
$ownerResponseBundleRequiredFileCount = 0
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
foreach ($spec in @(
        [ordered]@{ path = (Join-Path $ownerResponseBundlePath "production-driver-evidence"); files = $driverFiles },
        [ordered]@{ path = (Join-Path $ownerResponseBundlePath "production-lua-evidence"); files = $luaFiles },
        [ordered]@{ path = (Join-Path $ownerResponseBundlePath "live-smoke-evidence"); files = $liveFiles }
    )) {
    foreach ($fileName in @($spec.files)) {
        if (Test-Path (Join-Path ([string]$spec.path) ([string]$fileName))) {
            $ownerResponseBundleRequiredFileCount += 1
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
    (Convert-ToBool (Get-JsonValue $acceptedManifest "semanticPreflightGateRun" $false)) -and
    (Convert-ToBool (Get-JsonValue $acceptedManifest "semanticPreflightGatePassed" $false)) -and
    (Convert-ToBool (Get-JsonValue $acceptedManifest "semanticPreflightReadyForAcceptanceCandidate" $false)) -and
    (Convert-ToInt (Get-JsonValue $acceptedManifest "semanticPreflightFailCount" 1)) -eq 0 -and
    (Get-JsonValue $acceptedManifest "productionOutputBoundary" "") -eq "external_evidence_auto_acceptance_contract_fixture_only"

$ownerResponseBundleAreaStatuses = @()
if ($null -ne $ownerResponseBundleManifest) {
    $ownerResponseBundleAreaStatuses = @(Get-JsonValue $ownerResponseBundleManifest "areaStatuses" @())
}
$ownerResponseBundleSourceCount = @(
    $ownerResponseBundleAreaStatuses |
        Where-Object { (Get-JsonValue $_ "source" "") -eq "owner_response_bundle" }
).Count
$ownerResponseBundleAccepted = $null -ne $ownerResponseBundleManifest -and
    (Get-JsonValue $ownerResponseBundleManifest "schemaVersion" "") -eq "aitestpilot.production_external_evidence_auto_acceptance.v1" -and
    (Get-JsonValue $ownerResponseBundleManifest "status" "") -eq "PASS" -and
    (Convert-ToBool (Get-JsonValue $ownerResponseBundleManifest "allEvidenceReady" $false)) -and
    (Convert-ToBool (Get-JsonValue $ownerResponseBundleManifest "acceptanceRun" $false)) -and
    (Convert-ToBool (Get-JsonValue $ownerResponseBundleManifest "acceptanceSucceeded" $false)) -and
    (Convert-ToBool (Get-JsonValue $ownerResponseBundleManifest "allExternalEvidenceAccepted" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $ownerResponseBundleManifest "realHostProjectEvidenceAccepted" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $ownerResponseBundleManifest "releasePipelineSendsEmail" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $ownerResponseBundleManifest "emailSent" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $ownerResponseBundleManifest "fixtureEvidencePromoted" $true)) -and
    (Convert-ToBool (Get-JsonValue $ownerResponseBundleManifest "semanticPreflightGateRun" $false)) -and
    (Convert-ToBool (Get-JsonValue $ownerResponseBundleManifest "semanticPreflightGatePassed" $false)) -and
    (Convert-ToBool (Get-JsonValue $ownerResponseBundleManifest "semanticPreflightReadyForAcceptanceCandidate" $false)) -and
    (Convert-ToInt (Get-JsonValue $ownerResponseBundleManifest "semanticPreflightFailCount" 1)) -eq 0 -and
    (Get-JsonValue $ownerResponseBundleManifest "productionOutputBoundary" "") -eq "external_evidence_auto_acceptance_contract_fixture_only" -and
    $ownerResponseBundleSourceCount -eq 3

$ownerResponseBundleZipAreaStatuses = @()
if ($null -ne $ownerResponseBundleZipManifest) {
    $ownerResponseBundleZipAreaStatuses = @(Get-JsonValue $ownerResponseBundleZipManifest "areaStatuses" @())
}
$ownerResponseBundleZipSourceCount = @(
    $ownerResponseBundleZipAreaStatuses |
        Where-Object { (Get-JsonValue $_ "source" "") -eq "owner_response_bundle" }
).Count
$ownerResponseBundleZipAccepted = $null -ne $ownerResponseBundleZipManifest -and
    (Get-JsonValue $ownerResponseBundleZipManifest "schemaVersion" "") -eq "aitestpilot.production_external_evidence_auto_acceptance.v1" -and
    (Get-JsonValue $ownerResponseBundleZipManifest "status" "") -eq "PASS" -and
    (Convert-ToBool (Get-JsonValue $ownerResponseBundleZipManifest "ownerResponseBundleZipInspected" $false)) -and
    (Convert-ToBool (Get-JsonValue $ownerResponseBundleZipManifest "ownerResponseBundleZipSafe" $false)) -and
    (Convert-ToInt (Get-JsonValue $ownerResponseBundleZipManifest "ownerResponseBundleZipUnsafeEntryCount" 1)) -eq 0 -and
    (Convert-ToInt (Get-JsonValue $ownerResponseBundleZipManifest "ownerResponseBundleZipDuplicateEntryCount" 1)) -eq 0 -and
    (Convert-ToBool (Get-JsonValue $ownerResponseBundleZipManifest "allEvidenceReady" $false)) -and
    (Convert-ToBool (Get-JsonValue $ownerResponseBundleZipManifest "acceptanceRun" $false)) -and
    (Convert-ToBool (Get-JsonValue $ownerResponseBundleZipManifest "acceptanceSucceeded" $false)) -and
    (Convert-ToBool (Get-JsonValue $ownerResponseBundleZipManifest "allExternalEvidenceAccepted" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $ownerResponseBundleZipManifest "realHostProjectEvidenceAccepted" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $ownerResponseBundleZipManifest "releasePipelineSendsEmail" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $ownerResponseBundleZipManifest "emailSent" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $ownerResponseBundleZipManifest "fixtureEvidencePromoted" $true)) -and
    (Convert-ToBool (Get-JsonValue $ownerResponseBundleZipManifest "semanticPreflightGateRun" $false)) -and
    (Convert-ToBool (Get-JsonValue $ownerResponseBundleZipManifest "semanticPreflightGatePassed" $false)) -and
    (Convert-ToBool (Get-JsonValue $ownerResponseBundleZipManifest "semanticPreflightReadyForAcceptanceCandidate" $false)) -and
    (Convert-ToInt (Get-JsonValue $ownerResponseBundleZipManifest "semanticPreflightFailCount" 1)) -eq 0 -and
    -not [string]::IsNullOrWhiteSpace([string](Get-JsonValue $ownerResponseBundleZipManifest "ownerResponseBundleZipPath" "")) -and
    -not [string]::IsNullOrWhiteSpace([string](Get-JsonValue $ownerResponseBundleZipManifest "expandedOwnerResponseBundleDir" "")) -and
    (Get-JsonValue $ownerResponseBundleZipManifest "productionOutputBoundary" "") -eq "external_evidence_auto_acceptance_contract_fixture_only" -and
    $ownerResponseBundleZipSourceCount -eq 3

$semanticBadOwnerResponseBundleRejected = $null -ne $semanticBadOwnerResponseBundleManifest -and
    [bool]$semanticBadOwnerResponseBundleRun.failed -and
    (Get-JsonValue $semanticBadOwnerResponseBundleManifest "schemaVersion" "") -eq "aitestpilot.production_external_evidence_auto_acceptance.v1" -and
    (Get-JsonValue $semanticBadOwnerResponseBundleManifest "status" "") -eq "FAIL" -and
    (Convert-ToBool (Get-JsonValue $semanticBadOwnerResponseBundleManifest "allEvidenceReady" $false)) -and
    (Convert-ToBool (Get-JsonValue $semanticBadOwnerResponseBundleManifest "semanticPreflightGateRun" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $semanticBadOwnerResponseBundleManifest "semanticPreflightGatePassed" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $semanticBadOwnerResponseBundleManifest "semanticPreflightReadyForAcceptanceCandidate" $true)) -and
    (Convert-ToBool (Get-JsonValue $semanticBadOwnerResponseBundleManifest "semanticPreflightGateBlockedAcceptance" $false)) -and
    (Convert-ToInt (Get-JsonValue $semanticBadOwnerResponseBundleManifest "semanticPreflightFailCount" 0)) -gt 0 -and
    -not (Convert-ToBool (Get-JsonValue $semanticBadOwnerResponseBundleManifest "acceptanceRun" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $semanticBadOwnerResponseBundleManifest "allExternalEvidenceAccepted" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $semanticBadOwnerResponseBundleManifest "realHostProjectEvidenceAccepted" $true)) -and
    (Get-JsonValue $semanticBadOwnerResponseBundleManifest "productionOutputBoundary" "") -eq "external_evidence_auto_acceptance_failed"

$unsafeOwnerResponseBundleZipRejected = $null -ne $unsafeOwnerResponseBundleZipManifest -and
    [bool]$unsafeOwnerResponseBundleZipRun.failed -and
    (Get-JsonValue $unsafeOwnerResponseBundleZipManifest "schemaVersion" "") -eq "aitestpilot.production_external_evidence_auto_acceptance.v1" -and
    (Get-JsonValue $unsafeOwnerResponseBundleZipManifest "status" "") -eq "FAIL" -and
    (Convert-ToBool (Get-JsonValue $unsafeOwnerResponseBundleZipManifest "ownerResponseBundleZipInspected" $false)) -and
    -not (Convert-ToBool (Get-JsonValue $unsafeOwnerResponseBundleZipManifest "ownerResponseBundleZipSafe" $true)) -and
    (Convert-ToBool (Get-JsonValue $unsafeOwnerResponseBundleZipManifest "ownerResponseBundleZipRejectedBeforeExpand" $false)) -and
    (Convert-ToInt (Get-JsonValue $unsafeOwnerResponseBundleZipManifest "ownerResponseBundleZipUnsafeEntryCount" 0)) -gt 0 -and
    -not (Convert-ToBool (Get-JsonValue $unsafeOwnerResponseBundleZipManifest "acceptanceRun" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $unsafeOwnerResponseBundleZipManifest "allExternalEvidenceAccepted" $true)) -and
    -not (Convert-ToBool (Get-JsonValue $unsafeOwnerResponseBundleZipManifest "realHostProjectEvidenceAccepted" $true)) -and
    (Get-JsonValue $unsafeOwnerResponseBundleZipManifest "productionOutputBoundary" "") -eq "owner_response_bundle_zip_rejected_before_acceptance"

$pendingReportText = if (Test-Path $pendingRun.reportPath) { Get-Content -Raw -Path $pendingRun.reportPath -Encoding UTF8 } else { "" }
$acceptedReportText = if (Test-Path $acceptedRun.reportPath) { Get-Content -Raw -Path $acceptedRun.reportPath -Encoding UTF8 } else { "" }
$ownerResponseBundleReportText = if (Test-Path $ownerResponseBundleRun.reportPath) { Get-Content -Raw -Path $ownerResponseBundleRun.reportPath -Encoding UTF8 } else { "" }
$ownerResponseBundleZipReportText = if (Test-Path $ownerResponseBundleZipRun.reportPath) { Get-Content -Raw -Path $ownerResponseBundleZipRun.reportPath -Encoding UTF8 } else { "" }
$semanticBadOwnerResponseBundleReportText = if (Test-Path $semanticBadOwnerResponseBundleRun.reportPath) { Get-Content -Raw -Path $semanticBadOwnerResponseBundleRun.reportPath -Encoding UTF8 } else { "" }
$unsafeOwnerResponseBundleZipReportText = if (Test-Path $unsafeOwnerResponseBundleZipRun.reportPath) { Get-Content -Raw -Path $unsafeOwnerResponseBundleZipRun.reportPath -Encoding UTF8 } else { "" }
$reportsValidated = $pendingReportText.Contains("PENDING_EXTERNAL_EVIDENCE") -and
    $acceptedReportText.Contains("All external evidence accepted") -and
    $ownerResponseBundleReportText.Contains("All external evidence accepted") -and
    $ownerResponseBundleZipReportText.Contains("All external evidence accepted") -and
    $semanticBadOwnerResponseBundleReportText.Contains("Semantic preflight gate passed | False") -and
    $semanticBadOwnerResponseBundleReportText.Contains("Semantic preflight blocked acceptance | True") -and
    $semanticBadOwnerResponseBundleReportText.Contains("Acceptance run | False") -and
    $semanticBadOwnerResponseBundleReportText.Contains("external_evidence_auto_acceptance_failed") -and
    $unsafeOwnerResponseBundleZipReportText.Contains("owner_response_bundle_zip_rejected_before_acceptance") -and
    -not $pendingReportText.Contains("System.Collections") -and
    -not $acceptedReportText.Contains("System.Collections") -and
    -not $ownerResponseBundleReportText.Contains("System.Collections") -and
    -not $ownerResponseBundleZipReportText.Contains("System.Collections") -and
    -not $semanticBadOwnerResponseBundleReportText.Contains("System.Collections") -and
    -not $unsafeOwnerResponseBundleZipReportText.Contains("System.Collections") -and
    -not $pendingReportText.Contains("@{") -and
    -not $acceptedReportText.Contains("@{") -and
    -not $ownerResponseBundleReportText.Contains("@{") -and
    -not $ownerResponseBundleZipReportText.Contains("@{") -and
    -not $semanticBadOwnerResponseBundleReportText.Contains("@{") -and
    -not $unsafeOwnerResponseBundleZipReportText.Contains("@{")

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
Add-ProbeCheck "owner_response_bundle_accepts_contract_fixture" `
    ($ownerResponseBundleAccepted -and -not [bool]$ownerResponseBundleUnderRepo -and $ownerResponseBundleRequiredFileCount -eq 9) `
    "A complete owner response bundle must discover all three areas from the owner bundle and pass only as a contract fixture."
Add-ProbeCheck "owner_response_bundle_zip_accepts_contract_fixture" `
    ($ownerResponseBundleZipAccepted -and (Test-Path $ownerResponseBundleZipPath)) `
    "A complete owner response bundle zip must expand, discover all three areas, and pass only as a contract fixture."
Add-ProbeCheck "semantic_bad_complete_bundle_rejected_before_acceptance" `
    $semanticBadOwnerResponseBundleRejected `
    "A complete fixture/template owner response bundle without contract mode must be blocked by semantic preflight before acceptance can run."
Add-ProbeCheck "owner_response_bundle_unsafe_zip_rejected_before_acceptance" `
    ($unsafeOwnerResponseBundleZipRejected -and (Test-Path $unsafeOwnerResponseBundleZipPath)) `
    "An owner response bundle zip with unsafe entry paths must be rejected before expansion and before acceptance can run."
Add-ProbeCheck "external_fixture_root_outside_repo" `
    (-not [bool]$externalBundleUnderRepo -and $externalRequiredFileCount -eq 9) `
    "Probe fixture root must stay outside the repository and contain the nine required evidence files."
Add-ProbeCheck "auto_acceptance_reports_validated" `
    $reportsValidated `
    "Auto acceptance probe must produce readable pending and accepted Markdown reports."
Add-ProbeCheck "auto_acceptance_boundaries_preserved" `
    (-not (Convert-ToBool (Get-JsonValue $acceptedManifest "realHostProjectEvidenceAccepted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $acceptedManifest "emailSent" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $acceptedManifest "fixtureEvidencePromoted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $ownerResponseBundleManifest "realHostProjectEvidenceAccepted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $ownerResponseBundleManifest "emailSent" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $ownerResponseBundleManifest "fixtureEvidencePromoted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $ownerResponseBundleZipManifest "realHostProjectEvidenceAccepted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $ownerResponseBundleZipManifest "emailSent" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $ownerResponseBundleZipManifest "fixtureEvidencePromoted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $semanticBadOwnerResponseBundleManifest "acceptanceRun" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $semanticBadOwnerResponseBundleManifest "realHostProjectEvidenceAccepted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $semanticBadOwnerResponseBundleManifest "emailSent" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $semanticBadOwnerResponseBundleManifest "fixtureEvidencePromoted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $unsafeOwnerResponseBundleZipManifest "acceptanceRun" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $unsafeOwnerResponseBundleZipManifest "realHostProjectEvidenceAccepted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $unsafeOwnerResponseBundleZipManifest "emailSent" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $unsafeOwnerResponseBundleZipManifest "fixtureEvidencePromoted" $true))) `
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
    "| Owner response bundle run accepted | $ownerResponseBundleAccepted |",
    "| Owner response bundle source count | $ownerResponseBundleSourceCount |",
    "| Owner response bundle zip run accepted | $ownerResponseBundleZipAccepted |",
    "| Owner response bundle zip source count | $ownerResponseBundleZipSourceCount |",
    "| Semantic-bad owner response bundle rejected | $semanticBadOwnerResponseBundleRejected |",
    "| Semantic-bad owner response bundle fail count | $(Convert-ToInt (Get-JsonValue $semanticBadOwnerResponseBundleManifest "semanticPreflightFailCount" 0)) |",
    "| Unsafe owner response bundle zip rejected | $unsafeOwnerResponseBundleZipRejected |",
    "| Unsafe owner response bundle zip unsafe entries | $(Convert-ToInt (Get-JsonValue $unsafeOwnerResponseBundleZipManifest "ownerResponseBundleZipUnsafeEntryCount" 0)) |",
    "| External fixture files | $externalFileCount |",
    "| External required fixture files | $externalRequiredFileCount |",
    "| External fixture under repo | $externalBundleUnderRepo |",
    "| Owner response bundle fixture files | $ownerResponseBundleFileCount |",
    "| Owner response bundle required fixture files | $ownerResponseBundleRequiredFileCount |",
    "| Owner response bundle under repo | $ownerResponseBundleUnderRepo |",
    "| Owner response bundle zip | $(Format-MarkdownCell $ownerResponseBundleZipPath) |",
    "",
    "## Boundary",
    "",
    "- Pending discovery does not run acceptance.",
    "- Complete fixture discovery runs acceptance only in contract fixture mode.",
    "- Complete owner response bundle discovery runs acceptance only in contract fixture mode.",
    "- Complete owner response bundle zip discovery runs acceptance only in contract fixture mode.",
    "- Unsafe owner response bundle zips are rejected before expansion and before acceptance.",
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
    ownerResponseBundleDir = $ownerResponseBundlePath
    ownerResponseBundleZipPath = $ownerResponseBundleZipPath
    externalBundleUnderRepo = [bool]$externalBundleUnderRepo
    ownerResponseBundleUnderRepo = [bool]$ownerResponseBundleUnderRepo
    externalFixtureFileCount = [int]$externalFileCount
    ownerResponseBundleFixtureFileCount = [int]$ownerResponseBundleFileCount
    externalRequiredFixtureFileCount = [int]$externalRequiredFileCount
    ownerResponseBundleRequiredFixtureFileCount = [int]$ownerResponseBundleRequiredFileCount
    pendingDefaultAccepted = [bool]$pendingAccepted
    pendingDefaultStatus = [string](Get-JsonValue $pendingManifest "status" "")
    pendingDefaultAcceptanceRun = Convert-ToBool (Get-JsonValue $pendingManifest "acceptanceRun" $false)
    pendingDefaultMissingFileCount = Convert-ToInt (Get-JsonValue $pendingManifest "missingFileCount" 0)
    acceptedContractAccepted = [bool]$contractAccepted
    acceptedContractStatus = [string](Get-JsonValue $acceptedManifest "status" "")
    acceptedContractAcceptanceRun = Convert-ToBool (Get-JsonValue $acceptedManifest "acceptanceRun" $false)
    acceptedContractSemanticPreflightGateRun = Convert-ToBool (Get-JsonValue $acceptedManifest "semanticPreflightGateRun" $false)
    acceptedContractSemanticPreflightGatePassed = Convert-ToBool (Get-JsonValue $acceptedManifest "semanticPreflightGatePassed" $false)
    acceptedContractSemanticPreflightReadyForAcceptanceCandidate = Convert-ToBool (Get-JsonValue $acceptedManifest "semanticPreflightReadyForAcceptanceCandidate" $false)
    acceptedContractSemanticPreflightFailCount = Convert-ToInt (Get-JsonValue $acceptedManifest "semanticPreflightFailCount" 0)
    acceptedContractAllExternalEvidenceAccepted = Convert-ToBool (Get-JsonValue $acceptedManifest "allExternalEvidenceAccepted" $false)
    acceptedContractRealHostProjectEvidenceAccepted = Convert-ToBool (Get-JsonValue $acceptedManifest "realHostProjectEvidenceAccepted" $true)
    acceptedContractEmailSent = Convert-ToBool (Get-JsonValue $acceptedManifest "emailSent" $true)
    acceptedContractFixtureEvidencePromoted = Convert-ToBool (Get-JsonValue $acceptedManifest "fixtureEvidencePromoted" $true)
    ownerResponseBundleAccepted = [bool]$ownerResponseBundleAccepted
    ownerResponseBundleStatus = [string](Get-JsonValue $ownerResponseBundleManifest "status" "")
    ownerResponseBundleAcceptanceRun = Convert-ToBool (Get-JsonValue $ownerResponseBundleManifest "acceptanceRun" $false)
    ownerResponseBundleSemanticPreflightGateRun = Convert-ToBool (Get-JsonValue $ownerResponseBundleManifest "semanticPreflightGateRun" $false)
    ownerResponseBundleSemanticPreflightGatePassed = Convert-ToBool (Get-JsonValue $ownerResponseBundleManifest "semanticPreflightGatePassed" $false)
    ownerResponseBundleSemanticPreflightReadyForAcceptanceCandidate = Convert-ToBool (Get-JsonValue $ownerResponseBundleManifest "semanticPreflightReadyForAcceptanceCandidate" $false)
    ownerResponseBundleSemanticPreflightFailCount = Convert-ToInt (Get-JsonValue $ownerResponseBundleManifest "semanticPreflightFailCount" 0)
    ownerResponseBundleAllExternalEvidenceAccepted = Convert-ToBool (Get-JsonValue $ownerResponseBundleManifest "allExternalEvidenceAccepted" $false)
    ownerResponseBundleRealHostProjectEvidenceAccepted = Convert-ToBool (Get-JsonValue $ownerResponseBundleManifest "realHostProjectEvidenceAccepted" $true)
    ownerResponseBundleEmailSent = Convert-ToBool (Get-JsonValue $ownerResponseBundleManifest "emailSent" $true)
    ownerResponseBundleFixtureEvidencePromoted = Convert-ToBool (Get-JsonValue $ownerResponseBundleManifest "fixtureEvidencePromoted" $true)
    ownerResponseBundleSourceCount = [int]$ownerResponseBundleSourceCount
    ownerResponseBundleZipAccepted = [bool]$ownerResponseBundleZipAccepted
    ownerResponseBundleZipStatus = [string](Get-JsonValue $ownerResponseBundleZipManifest "status" "")
    ownerResponseBundleZipAcceptanceRun = Convert-ToBool (Get-JsonValue $ownerResponseBundleZipManifest "acceptanceRun" $false)
    ownerResponseBundleZipSemanticPreflightGateRun = Convert-ToBool (Get-JsonValue $ownerResponseBundleZipManifest "semanticPreflightGateRun" $false)
    ownerResponseBundleZipSemanticPreflightGatePassed = Convert-ToBool (Get-JsonValue $ownerResponseBundleZipManifest "semanticPreflightGatePassed" $false)
    ownerResponseBundleZipSemanticPreflightReadyForAcceptanceCandidate = Convert-ToBool (Get-JsonValue $ownerResponseBundleZipManifest "semanticPreflightReadyForAcceptanceCandidate" $false)
    ownerResponseBundleZipSemanticPreflightFailCount = Convert-ToInt (Get-JsonValue $ownerResponseBundleZipManifest "semanticPreflightFailCount" 0)
    ownerResponseBundleZipAllExternalEvidenceAccepted = Convert-ToBool (Get-JsonValue $ownerResponseBundleZipManifest "allExternalEvidenceAccepted" $false)
    ownerResponseBundleZipRealHostProjectEvidenceAccepted = Convert-ToBool (Get-JsonValue $ownerResponseBundleZipManifest "realHostProjectEvidenceAccepted" $true)
    ownerResponseBundleZipEmailSent = Convert-ToBool (Get-JsonValue $ownerResponseBundleZipManifest "emailSent" $true)
    ownerResponseBundleZipFixtureEvidencePromoted = Convert-ToBool (Get-JsonValue $ownerResponseBundleZipManifest "fixtureEvidencePromoted" $true)
    ownerResponseBundleZipSourceCount = [int]$ownerResponseBundleZipSourceCount
    ownerResponseBundleZipInspected = Convert-ToBool (Get-JsonValue $ownerResponseBundleZipManifest "ownerResponseBundleZipInspected" $false)
    ownerResponseBundleZipSafe = Convert-ToBool (Get-JsonValue $ownerResponseBundleZipManifest "ownerResponseBundleZipSafe" $false)
    ownerResponseBundleZipUnsafeEntryCount = Convert-ToInt (Get-JsonValue $ownerResponseBundleZipManifest "ownerResponseBundleZipUnsafeEntryCount" 0)
    ownerResponseBundleZipDuplicateEntryCount = Convert-ToInt (Get-JsonValue $ownerResponseBundleZipManifest "ownerResponseBundleZipDuplicateEntryCount" 0)
    semanticBadOwnerResponseBundleRejected = [bool]$semanticBadOwnerResponseBundleRejected
    semanticBadOwnerResponseBundleStatus = [string](Get-JsonValue $semanticBadOwnerResponseBundleManifest "status" "")
    semanticBadOwnerResponseBundleAllEvidenceReady = Convert-ToBool (Get-JsonValue $semanticBadOwnerResponseBundleManifest "allEvidenceReady" $false)
    semanticBadOwnerResponseBundleSemanticPreflightGateRun = Convert-ToBool (Get-JsonValue $semanticBadOwnerResponseBundleManifest "semanticPreflightGateRun" $false)
    semanticBadOwnerResponseBundleSemanticPreflightGatePassed = Convert-ToBool (Get-JsonValue $semanticBadOwnerResponseBundleManifest "semanticPreflightGatePassed" $true)
    semanticBadOwnerResponseBundleSemanticPreflightReadyForAcceptanceCandidate = Convert-ToBool (Get-JsonValue $semanticBadOwnerResponseBundleManifest "semanticPreflightReadyForAcceptanceCandidate" $true)
    semanticBadOwnerResponseBundleSemanticPreflightFailCount = Convert-ToInt (Get-JsonValue $semanticBadOwnerResponseBundleManifest "semanticPreflightFailCount" 0)
    semanticBadOwnerResponseBundleSemanticPreflightGateBlockedAcceptance = Convert-ToBool (Get-JsonValue $semanticBadOwnerResponseBundleManifest "semanticPreflightGateBlockedAcceptance" $false)
    semanticBadOwnerResponseBundleAcceptanceRun = Convert-ToBool (Get-JsonValue $semanticBadOwnerResponseBundleManifest "acceptanceRun" $true)
    semanticBadOwnerResponseBundleAllExternalEvidenceAccepted = Convert-ToBool (Get-JsonValue $semanticBadOwnerResponseBundleManifest "allExternalEvidenceAccepted" $true)
    semanticBadOwnerResponseBundleRealHostProjectEvidenceAccepted = Convert-ToBool (Get-JsonValue $semanticBadOwnerResponseBundleManifest "realHostProjectEvidenceAccepted" $true)
    semanticBadOwnerResponseBundleEmailSent = Convert-ToBool (Get-JsonValue $semanticBadOwnerResponseBundleManifest "emailSent" $true)
    semanticBadOwnerResponseBundleFixtureEvidencePromoted = Convert-ToBool (Get-JsonValue $semanticBadOwnerResponseBundleManifest "fixtureEvidencePromoted" $true)
    unsafeOwnerResponseBundleZipPath = $unsafeOwnerResponseBundleZipPath
    unsafeOwnerResponseBundleZipRejected = [bool]$unsafeOwnerResponseBundleZipRejected
    unsafeOwnerResponseBundleZipStatus = [string](Get-JsonValue $unsafeOwnerResponseBundleZipManifest "status" "")
    unsafeOwnerResponseBundleZipAcceptanceRun = Convert-ToBool (Get-JsonValue $unsafeOwnerResponseBundleZipManifest "acceptanceRun" $true)
    unsafeOwnerResponseBundleZipSafe = Convert-ToBool (Get-JsonValue $unsafeOwnerResponseBundleZipManifest "ownerResponseBundleZipSafe" $true)
    unsafeOwnerResponseBundleZipUnsafeEntryCount = Convert-ToInt (Get-JsonValue $unsafeOwnerResponseBundleZipManifest "ownerResponseBundleZipUnsafeEntryCount" 0)
    unsafeOwnerResponseBundleZipRealHostProjectEvidenceAccepted = Convert-ToBool (Get-JsonValue $unsafeOwnerResponseBundleZipManifest "realHostProjectEvidenceAccepted" $true)
    unsafeOwnerResponseBundleZipFixtureEvidencePromoted = Convert-ToBool (Get-JsonValue $unsafeOwnerResponseBundleZipManifest "fixtureEvidencePromoted" $true)
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
