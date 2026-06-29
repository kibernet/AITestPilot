[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ExportDir,
    [string]$ManifestPath,
    [string]$ZipPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ExportDir)) {
    $ExportDir = Join-Path $EvidenceBundleDir "production-handoff-export"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-handoff-export-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ZipPath)) {
    $ZipPath = Join-Path $EvidenceBundleDir "production-handoff-export.zip"
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

function Copy-ExportFile {
    param(
        [string]$RelativePath,
        [string]$DestinationRelativePath = ""
    )

    if ([string]::IsNullOrWhiteSpace($DestinationRelativePath)) {
        $DestinationRelativePath = $RelativePath
    }

    $sourcePath = Join-Path $script:evidenceBundlePath $RelativePath
    if (-not (Test-Path $sourcePath)) {
        throw "Export source file is missing: $sourcePath"
    }

    $destinationPath = Join-Path $script:exportPath $DestinationRelativePath
    New-Item -ItemType Directory -Force (Split-Path $destinationPath -Parent) | Out-Null
    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
}

function Copy-ExportDirectory {
    param(
        [string]$RelativePath,
        [string]$DestinationRelativePath = ""
    )

    if ([string]::IsNullOrWhiteSpace($DestinationRelativePath)) {
        $DestinationRelativePath = $RelativePath
    }

    $sourcePath = Join-Path $script:evidenceBundlePath $RelativePath
    if (-not (Test-Path $sourcePath)) {
        throw "Export source directory is missing: $sourcePath"
    }

    $destinationPath = Join-Path $script:exportPath $DestinationRelativePath
    if (Test-Path $destinationPath) {
        Remove-Item -LiteralPath $destinationPath -Recurse -Force
    }

    New-Item -ItemType Directory -Force (Split-Path $destinationPath -Parent) | Out-Null
    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Recurse -Force
}

function Convert-ToRelativePath {
    param(
        [string]$Root,
        [string]$Path
    )

    $rootUri = [System.Uri](([System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'))
    $pathUri = [System.Uri]([System.IO.Path]::GetFullPath($Path))
    return [System.Uri]::UnescapeDataString($rootUri.MakeRelativeUri($pathUri).ToString()).Replace("/", "\")
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$exportPath = Assert-PathUnderRepo $ExportDir "ExportDir"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$zipFullPath = Assert-PathUnderRepo $ZipPath "ZipPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if (Test-Path $exportPath) {
    Remove-Item -LiteralPath $exportPath -Recurse -Force
}
if (Test-Path $zipFullPath) {
    Remove-Item -LiteralPath $zipFullPath -Force
}

New-Item -ItemType Directory -Force $exportPath | Out-Null

$handoffManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-package-manifest.json") "Production handoff package manifest"
$preflightProbeManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-external-evidence-preflight-probe-manifest.json") "Production handoff external evidence preflight probe manifest"
$acceptanceContractProbeManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-external-evidence-acceptance-contract-probe-manifest.json") "Production external evidence acceptance contract probe manifest"
$acceptanceFailureProbeManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-external-evidence-acceptance-failure-probe-manifest.json") "Production external evidence acceptance failure probe manifest"

$requiredDirectories = @(
    "production-handoff-package",
    "production-driver-binding-kit",
    "production-lua-patch-evidence-kit",
    "live-model-endpoint-config-kit"
)

foreach ($directory in $requiredDirectories) {
    Copy-ExportDirectory $directory
}

$requiredFiles = @(
    "production-handoff-package-manifest.json",
    "production-handoff-external-evidence-preflight-probe-manifest.json",
    "production-handoff-external-evidence-preflight-accepted-manifest.json",
    "production-handoff-external-evidence-acceptance-wrapper-manifest.json",
    "production-handoff-external-evidence-acceptance-manifest.json",
    "production-handoff-external-evidence-acceptance.md",
    "production-external-evidence-acceptance-contract-probe-manifest.json",
    "production-external-evidence-acceptance-contract-manifest.json",
    "production-external-evidence-acceptance-contract.md",
    "production-external-evidence-acceptance-failure-probe-manifest.json",
    "production-external-evidence-acceptance-missing-all-manifest.json",
    "production-external-evidence-acceptance-missing-all.md",
    "production-external-evidence-acceptance-driver-only-manifest.json",
    "production-external-evidence-acceptance-driver-only.md"
)

foreach ($fileName in $requiredFiles) {
    Copy-ExportFile $fileName ("contract-evidence\" + $fileName)
}

$ownerPacketCount = [int]$handoffManifest.ownerPacketCount
$ownerPacketBlockingReasonCount = [int]$handoffManifest.ownerPacketBlockingReasonCount
$hostProjectActionItemCount = [int]$handoffManifest.hostProjectActionItemCount
$hostProjectBlockingReasonCount = [int]$handoffManifest.hostProjectBlockingReasonCount

$exportReadmeLines = @(
    "# AI TestPilot Production Handoff Export",
    "",
    "This export is the small handoff bundle for host-project owners. It does not promote fixture evidence as real production evidence.",
    "",
    "## Start Here",
    "",
    "1. Open `production-handoff-package\\owner-packets\\owner-packet-index.json`.",
    "2. Send each `production-handoff-package\\owner-packets\\*.md` packet to the listed owner.",
    "3. Owners fill the required evidence directories and run `production-handoff-package\\verify-external-evidence.ps1`.",
    "4. Run `production-handoff-package\\accept-external-evidence.ps1` to generate the Markdown acceptance report.",
    "5. Run the hard validation command from the owner packet or `production-handoff-package\\ci-commands.ps1`.",
    "",
    "## Contents",
    "",
    "- `production-handoff-package/`: owner packets, preflight script, acceptance wrapper, CI commands, and blocker maps.",
    "- `production-driver-binding-kit/`: host-project production replay driver binding kit.",
    "- `production-lua-patch-evidence-kit/`: host-project production Lua evidence template kit.",
    "- `live-model-endpoint-config-kit/`: host-project live endpoint smoke configuration kit.",
    "- `contract-evidence/`: accepted-fixture and rejection reports proving the intake path without claiming real production evidence.",
    "",
    "## Current External Work",
    "",
    "- Owner packets: $ownerPacketCount",
    "- Remaining blockers covered by owner packets: $ownerPacketBlockingReasonCount",
    "- Real host-project evidence accepted: False",
    "",
    "## Boundary",
    "",
    "- Fixture contracts prove schemas only.",
    "- This export is complete only when real host-project evidence is returned and the hard validation command passes."
)
$exportReadmePath = Join-Path $exportPath "README.md"
$exportReadmeLines | Set-Content -Path $exportReadmePath -Encoding UTF8

$exportFiles = @(
    Get-ChildItem -LiteralPath $exportPath -Recurse -File |
        ForEach-Object { "production-handoff-export\" + (Convert-ToRelativePath $exportPath $_.FullName) }
)
$exportFiles = @($exportFiles | Sort-Object)

$requiredExportSnippets = @(
    "AI TestPilot Production Handoff Export",
    "owner-packets",
    "verify-external-evidence.ps1",
    "accept-external-evidence.ps1",
    "production-driver-binding-kit",
    "production-lua-patch-evidence-kit",
    "live-model-endpoint-config-kit",
    "contract-evidence",
    "Real host-project evidence accepted: False"
)
$exportReadmeText = Get-Content -Path $exportReadmePath -Encoding UTF8 -Raw
$missingExportSnippetCount = @($requiredExportSnippets | Where-Object { -not $exportReadmeText.Contains($_) }).Count

$requiredExportPaths = @(
    "production-handoff-export\README.md",
    "production-handoff-export\production-handoff-package\owner-packets\owner-packet-index.json",
    "production-handoff-export\production-handoff-package\verify-external-evidence.ps1",
    "production-handoff-export\production-handoff-package\accept-external-evidence.ps1",
    "production-handoff-export\production-driver-binding-kit\README.md",
    "production-handoff-export\production-lua-patch-evidence-kit\README.md",
    "production-handoff-export\live-model-endpoint-config-kit\README.md",
    "production-handoff-export\contract-evidence\production-external-evidence-acceptance-contract.md",
    "production-handoff-export\contract-evidence\production-external-evidence-acceptance-missing-all.md",
    "production-handoff-export\contract-evidence\production-external-evidence-acceptance-driver-only.md"
)
$missingExportPathCount = @($requiredExportPaths | Where-Object { $exportFiles -notcontains $_ }).Count

$checks = @(
    [ordered]@{
        name = "handoff_package_source"
        passed = ($handoffManifest.status -eq "PASS" -and [bool]$handoffManifest.hostProjectHandoffReady -and [bool]$handoffManifest.ownerPacketsContentValidated)
        message = "Source handoff package must be PASS and include validated owner packets."
    },
    [ordered]@{
        name = "contract_boundary_preserved"
        passed = (-not [bool]$handoffManifest.fixtureEvidencePromoted -and -not [bool]$preflightProbeManifest.realHostProjectEvidenceAccepted -and -not [bool]$acceptanceContractProbeManifest.realHostProjectEvidenceAccepted)
        message = "Exported fixture contract evidence must not be promoted as real host-project evidence."
    },
    [ordered]@{
        name = "owner_packet_coverage"
        passed = ($ownerPacketCount -eq $hostProjectActionItemCount -and $ownerPacketBlockingReasonCount -eq $hostProjectBlockingReasonCount)
        message = "Owner packets must cover every remaining action item and blocker."
    },
    [ordered]@{
        name = "export_content"
        passed = ($missingExportSnippetCount -eq 0 -and $missingExportPathCount -eq 0)
        message = "Export must include README, owner packets, handoff scripts, kits, and contract reports."
    },
    [ordered]@{
        name = "failure_contract_reports"
        passed = ($acceptanceFailureProbeManifest.status -eq "PASS" -and [bool]$acceptanceFailureProbeManifest.missingAllReportContentValidated -and [bool]$acceptanceFailureProbeManifest.driverOnlyReportContentValidated)
        message = "Export must include validated rejection reports for missing and partial evidence."
    }
)

$failedChecks = @($checks | Where-Object { -not [bool]$_["passed"] })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$manifestFileName = Split-Path $manifestFullPath -Leaf
$zipFileName = Split-Path $zipFullPath -Leaf
$manifestCopyRelativePath = "production-handoff-export\$manifestFileName"
$files = @($manifestFileName, $zipFileName, $manifestCopyRelativePath) + $exportFiles

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_export.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    exportDir = $exportPath
    zipPath = $zipFullPath
    handoffPackageIncluded = $true
    ownerPacketCount = [int]$ownerPacketCount
    ownerPacketBlockingReasonCount = [int]$ownerPacketBlockingReasonCount
    hostProjectActionItemCount = [int]$hostProjectActionItemCount
    hostProjectBlockingReasonCount = [int]$hostProjectBlockingReasonCount
    ownerPacketsContentValidated = [bool]$handoffManifest.ownerPacketsContentValidated
    kitDirectoryCount = [int]$requiredDirectories.Count
    contractEvidenceFileCount = [int]$requiredFiles.Count
    exportFileCount = [int]$exportFiles.Count
    zipGenerated = $true
    releasePipelineUsesFixture = $false
    realHostProjectEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "host_project_external_handoff_export_only"
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
    files = @($files)
    exportFiles = @($exportFiles)
}

New-Item -ItemType Directory -Force (Split-Path $manifestFullPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestFullPath -Encoding UTF8
$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path (Join-Path $exportPath $manifestFileName) -Encoding UTF8

Compress-Archive -Path (Join-Path $exportPath "*") -DestinationPath $zipFullPath -Force
if (-not (Test-Path $zipFullPath)) {
    throw "Production handoff export zip was not produced: $zipFullPath"
}

if ($failedChecks.Count -gt 0) {
    throw "Production handoff export failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production handoff export: $exportPath"
Write-Output "Production handoff export zip: $zipFullPath"
Write-Output "Production handoff export manifest: $manifestFullPath"
Write-Output "PASS AI TestPilot production handoff export"
