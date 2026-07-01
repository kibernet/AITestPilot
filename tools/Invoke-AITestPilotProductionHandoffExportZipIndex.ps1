[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ManifestPath,
    [string]$ReportPath,
    [string]$IndexPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-handoff-export-zip-index-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-handoff-export-zip-index.md"
}

if ([string]::IsNullOrWhiteSpace($IndexPath)) {
    $IndexPath = Join-Path $EvidenceBundleDir "production-handoff-export-zip-index.json"
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
        throw "File must stay under evidence bundle: $fullPath"
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

function Normalize-ZipEntryPath {
    param([string]$Path)

    return ([string]$Path).Replace("/", "\").TrimStart([char[]]@("\", "/"))
}

function Convert-ExportPathToZipEntryPath {
    param([string]$ExportPath)

    $normalized = Normalize-ZipEntryPath $ExportPath
    $prefix = "production-handoff-export\"
    if ($normalized.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $normalized.Substring($prefix.Length)
    }

    return $normalized
}

function Format-MarkdownCell {
    param([object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    return ([string]$Value).Replace("|", "\|").Replace("`r", " ").Replace("`n", "<br>")
}

function Convert-BytesToHexString {
    param([byte[]]$Bytes)

    return ([System.BitConverter]::ToString($Bytes)).Replace("-", "").ToLowerInvariant()
}

function Get-StreamSha256Hex {
    param([System.IO.Stream]$Stream)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return Convert-BytesToHexString ($sha256.ComputeHash($Stream))
    }
    finally {
        $sha256.Dispose()
    }
}

function Add-ZipIndexCheck {
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
$indexFullPath = Assert-PathUnderRepo $IndexPath "IndexPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

$exportManifestPath = Join-Path $evidenceBundlePath "production-handoff-export-manifest.json"
$zipPath = Join-Path $evidenceBundlePath "production-handoff-export.zip"
$exportManifest = Read-JsonFile $exportManifestPath "Production handoff export manifest"
if (-not (Test-Path $zipPath)) {
    throw "Production handoff export zip is missing: $zipPath"
}

Add-Type -AssemblyName System.IO.Compression.FileSystem

$zipFile = Get-Item -LiteralPath $zipPath
$zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$zipArchive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $zipEntries = @()
    foreach ($entry in $zipArchive.Entries) {
        $entryPath = Normalize-ZipEntryPath $entry.FullName
        $isDirectory = [string]::IsNullOrEmpty($entry.Name)
        $sourceRelativePath = ""
        $sourceExists = $false
        $sourceSha256 = ""
        $entrySha256 = ""
        $hashMatches = $false

        if (-not $isDirectory) {
            $sourceRelativePath = "production-handoff-export\" + $entryPath
            $sourcePath = Join-Path $evidenceBundlePath $sourceRelativePath
            $sourceExists = Test-Path $sourcePath
            $entryStream = $entry.Open()
            try {
                $entrySha256 = Get-StreamSha256Hex $entryStream
            }
            finally {
                $entryStream.Dispose()
            }

            if ($sourceExists) {
                $sourceSha256 = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
                $hashMatches = ($entrySha256 -eq $sourceSha256)
            }
        }

        $zipEntries += [ordered]@{
            path = $entryPath
            sourceRelativePath = $sourceRelativePath
            length = [int64]$entry.Length
            compressedLength = [int64]$entry.CompressedLength
            isDirectory = [bool]$isDirectory
            zipSha256 = $entrySha256
            sourceSha256 = $sourceSha256
            sourceExists = [bool]$sourceExists
            hashMatches = [bool]$hashMatches
        }
    }
}
finally {
    $zipArchive.Dispose()
}

$zipFileEntries = @($zipEntries | Where-Object { -not [bool]$_["isDirectory"] })
$zipEntryPaths = @($zipFileEntries | ForEach-Object { [string]$_["path"] } | Sort-Object)
$directoryEntryCount = @($zipEntries | Where-Object { [bool]$_["isDirectory"] }).Count
$exportFiles = @(Get-JsonValue $exportManifest "exportFiles" @() | ForEach-Object { [string]$_ })
$expectedZipEntries = @($exportFiles | ForEach-Object { Convert-ExportPathToZipEntryPath $_ } | Sort-Object)

$zipEntrySet = @{}
foreach ($entryPath in $zipEntryPaths) {
    $zipEntrySet[$entryPath.ToLowerInvariant()] = $true
}

$expectedEntrySet = @{}
foreach ($entryPath in $expectedZipEntries) {
    $expectedEntrySet[$entryPath.ToLowerInvariant()] = $true
}

$missingZipEntries = @($expectedZipEntries | Where-Object { -not $zipEntrySet.ContainsKey($_.ToLowerInvariant()) })
$unexpectedZipEntries = @($zipEntryPaths | Where-Object { -not $expectedEntrySet.ContainsKey($_.ToLowerInvariant()) })
$duplicateZipEntryGroups = @($zipEntryPaths | Group-Object { $_.ToLowerInvariant() } | Where-Object { $_.Count -gt 1 })
$duplicateZipEntries = @($duplicateZipEntryGroups | ForEach-Object { [string]$_.Group[0] })
$emptyEntryNameCount = @($zipFileEntries | Where-Object { [string]::IsNullOrWhiteSpace([string]$_["path"]) }).Count
$missingSourceFileEntries = @($zipFileEntries | Where-Object { -not [bool]$_["sourceExists"] } | ForEach-Object { [string]$_["path"] })
$hashMismatchEntries = @($zipFileEntries | Where-Object { [bool]$_["sourceExists"] -and -not [bool]$_["hashMatches"] } | ForEach-Object { [string]$_["path"] })

$requiredZipEntries = @(
    "README.md",
    "run-semantic-preflight.ps1",
    "semantic-preflight\Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1",
    "production-handoff-package\owner-packets\owner-packet-index.json",
    "production-handoff-package\verify-external-evidence.ps1",
    "production-handoff-package\accept-external-evidence.ps1",
    "production-external-evidence-inbox\accept-returned-evidence.ps1",
    "production-handoff-owner-response-bundle-kit\README.md",
    "production-handoff-owner-response-bundle-kit\run-semantic-preflight.ps1",
    "production-handoff-owner-response-bundle-kit\semantic-preflight\Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1",
    "operator-actions\production-external-evidence-action-queue-manifest.json",
    "operator-actions\production-external-evidence-action-queue.md",
    "operator-actions\production-external-evidence-action-queue-probe-manifest.json",
    "operator-actions\production-external-evidence-action-queue-probe.md",
    "operator-actions\release-progress-notification-remaining-work-snapshot.json",
    "operator-actions\release-progress-notification-remaining-work-snapshot.md",
    "contract-evidence\production-external-evidence-acceptance-contract.md",
    "contract-evidence\production-external-evidence-inbox-acceptance.md",
    "contract-evidence\production-external-evidence-semantic-preflight-probe-manifest.json",
    "contract-evidence\production-external-evidence-semantic-preflight-probe.md",
    "production-driver-binding-kit\Export-ProductionDriverEvidenceBundle.ps1",
    "production-lua-patch-evidence-kit\Export-ProductionLuaPatchEvidenceBundle.ps1",
    "live-model-endpoint-config-kit\Export-LiveModelEndpointSmokeEvidenceBundle.ps1"
)
$missingRequiredZipEntries = @($requiredZipEntries | Where-Object { -not $zipEntrySet.ContainsKey($_.ToLowerInvariant()) })
$canonicalActionQueueManifestEntryName = "operator-actions\production-external-evidence-action-queue-manifest.json"
$canonicalActionQueueManifestEntries = @($zipFileEntries | Where-Object {
        [string]$_["path"] -eq $canonicalActionQueueManifestEntryName
    } | Select-Object -First 1)
$canonicalActionQueueManifestEntry = if ($canonicalActionQueueManifestEntries.Count -gt 0) { $canonicalActionQueueManifestEntries[0] } else { $null }
$canonicalActionQueueManifestRootSha256 = [string](Get-JsonValue $exportManifest "operatorActionQueueCanonicalSourceSha256" "")
$canonicalActionQueueManifestZipSha256 = if ($null -ne $canonicalActionQueueManifestEntry) { [string]$canonicalActionQueueManifestEntry["zipSha256"] } else { "" }
$canonicalActionQueueManifestZipMatchesRoot = (
    -not [string]::IsNullOrWhiteSpace($canonicalActionQueueManifestRootSha256) -and
    $canonicalActionQueueManifestZipSha256 -eq $canonicalActionQueueManifestRootSha256 -and
    (Convert-ToBool (Get-JsonValue $exportManifest "operatorActionQueueManifestHashMatchesCanonical" $false))
)

$pathTraversalEntries = @($zipEntryPaths | Where-Object {
        $_ -eq ".." -or
        $_.StartsWith("..\", [System.StringComparison]::OrdinalIgnoreCase) -or
        $_.Contains("\..\")
    })
$rootedPathEntries = @($zipEntryPaths | Where-Object {
        [System.IO.Path]::IsPathRooted($_) -or $_.Contains(":")
    })

$checks = @()
Add-ZipIndexCheck "zip_index_sources_available" `
    ((Get-JsonValue $exportManifest "status" "") -eq "PASS" -and
        (Convert-ToBool (Get-JsonValue $exportManifest "zipGenerated" $false)) -and
        (Test-Path $zipPath)) `
    "Zip index must read a passing production handoff export manifest and the generated zip."
Add-ZipIndexCheck "zip_index_hash_recorded" `
    (-not [string]::IsNullOrWhiteSpace($zipHash) -and $zipHash.Length -eq 64 -and $zipFile.Length -gt 0) `
    "Zip index must compute a SHA256 hash and nonzero zip size."
Add-ZipIndexCheck "zip_index_export_file_count_matches" `
    ($zipEntryPaths.Count -eq (Convert-ToInt (Get-JsonValue $exportManifest "exportFileCount" 0)) -and
        $zipEntryPaths.Count -eq $expectedZipEntries.Count) `
    "Zip file entry count must match the production handoff export manifest exportFileCount."
Add-ZipIndexCheck "zip_index_export_entries_match_manifest" `
    ($missingZipEntries.Count -eq 0 -and $unexpectedZipEntries.Count -eq 0) `
    "Zip file entries must exactly match the exportFiles listed by the production handoff export manifest."
Add-ZipIndexCheck "zip_index_required_entries_present" `
    ($missingRequiredZipEntries.Count -eq 0) `
    "Zip file must contain the owner packet index, preflight/acceptance scripts, inbox wrapper, self-contained semantic preflight helpers, owner response kit, operator actions, contract reports, and owner export helpers."
Add-ZipIndexCheck "zip_index_canonical_action_queue_manifest_hash" `
    $canonicalActionQueueManifestZipMatchesRoot `
    "Zip file must contain the canonical action queue manifest, and its entry hash must match the root canonical manifest hash recorded by the export manifest."
Add-ZipIndexCheck "zip_index_paths_safe" `
    ($emptyEntryNameCount -eq 0 -and $pathTraversalEntries.Count -eq 0 -and $rootedPathEntries.Count -eq 0) `
    "Zip entries must not contain empty names, rooted paths, drive-qualified paths, or parent traversal."
Add-ZipIndexCheck "zip_index_duplicate_entries_absent" `
    ($duplicateZipEntries.Count -eq 0) `
    "Zip entries must not contain duplicate names after case-insensitive normalization."
Add-ZipIndexCheck "zip_index_source_files_available" `
    ($missingSourceFileEntries.Count -eq 0) `
    "Every zip entry must map back to a source file in the production handoff export directory."
Add-ZipIndexCheck "zip_index_entry_hashes_match_source" `
    ($hashMismatchEntries.Count -eq 0) `
    "Every zip entry content hash must match the corresponding production handoff export source file."
Add-ZipIndexCheck "zip_index_boundary_preserved" `
    (-not (Convert-ToBool (Get-JsonValue $exportManifest "realHostProjectEvidenceAccepted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $exportManifest "fixtureEvidencePromoted" $true))) `
    "Zip index must preserve the export boundary: no real host-project evidence accepted and no fixture promotion."

$failedChecks = @($checks | Where-Object { -not [bool]$_["passed"] })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }
$generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")

$reportLines = @(
    "# AI TestPilot Production Handoff Export Zip Index",
    "",
    "Schema: ``aitestpilot.production_handoff_export_zip_index.v1``",
    "Generated at UTC: $generatedAtUtc",
    "",
    "## Summary",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Status | $(Format-MarkdownCell $status) |",
    "| Zip SHA256 | ``$zipHash`` |",
    "| Zip bytes | $($zipFile.Length) |",
    "| Zip file entries | $($zipEntryPaths.Count) |",
    "| Export manifest files | $($expectedZipEntries.Count) |",
    "| Missing zip entries | $($missingZipEntries.Count) |",
    "| Unexpected zip entries | $($unexpectedZipEntries.Count) |",
    "| Missing required entries | $($missingRequiredZipEntries.Count) |",
    "| Hash mismatches | $($hashMismatchEntries.Count) |",
    "| Missing source files | $($missingSourceFileEntries.Count) |",
    "| Duplicate entries | $($duplicateZipEntries.Count) |",
    "| Directory entries | $directoryEntryCount |",
    "",
    "## Required Entries",
    "",
    "| Entry | Present |",
    "| --- | --- |"
)
foreach ($entryPath in $requiredZipEntries) {
    $present = $zipEntrySet.ContainsKey($entryPath.ToLowerInvariant())
    $reportLines += "| $(Format-MarkdownCell $entryPath) | $present |"
}
$reportLines += @(
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

$reportText = $reportLines -join [Environment]::NewLine
$reportContentValidated = $reportText.Contains("Zip SHA256") -and
    $reportText.Contains("Hash mismatches") -and
    $reportText.Contains("run-semantic-preflight.ps1") -and
    $reportText.Contains("semantic-preflight") -and
    $reportText.Contains("operator-actions") -and
    $reportText.Contains("production-external-evidence-action-queue-manifest.json") -and
    $reportText.Contains("remaining-work-snapshot") -and
    $reportText.Contains("production-external-evidence-inbox") -and
    -not $reportText.Contains("System.Collections") -and
    -not $reportText.Contains("@{")
Add-ZipIndexCheck "zip_index_report_content" `
    $reportContentValidated `
    "Zip index Markdown must be readable and summarize hash, required entries, and checks without object dumps."

$reportContentCheck = $checks[-1]
$reportContentResult = if ([bool]$reportContentCheck.passed) { "PASS" } else { "FAIL" }
$reportLines += "| $(Format-MarkdownCell $reportContentCheck.name) | $reportContentResult | $(Format-MarkdownCell $reportContentCheck.message) |"

$failedChecks = @($checks | Where-Object { -not [bool]$_["passed"] })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }
$reportLines[9] = "| Status | $(Format-MarkdownCell $status) |"
New-Item -ItemType Directory -Force (Split-Path $reportFullPath -Parent) | Out-Null
$reportLines | Set-Content -Path $reportFullPath -Encoding UTF8

$index = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_export_zip_index.entries.v1"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    zipPath = $zipPath
    zipSha256 = $zipHash
    zipLengthBytes = [int64]$zipFile.Length
    zipEntryCount = [int]$zipEntryPaths.Count
    expectedZipEntryCount = [int]$expectedZipEntries.Count
    missingZipEntryCount = [int]$missingZipEntries.Count
    unexpectedZipEntryCount = [int]$unexpectedZipEntries.Count
    hashMismatchCount = [int]$hashMismatchEntries.Count
    missingSourceFileCount = [int]$missingSourceFileEntries.Count
    unsafeEntryNameCount = [int]($emptyEntryNameCount + $pathTraversalEntries.Count + $rootedPathEntries.Count)
    duplicateEntryCount = [int]$duplicateZipEntries.Count
    entries = @($zipFileEntries)
    expectedZipEntries = @($expectedZipEntries)
}
New-Item -ItemType Directory -Force (Split-Path $indexFullPath -Parent) | Out-Null
$index | ConvertTo-Json -Depth 12 | Set-Content -Path $indexFullPath -Encoding UTF8

$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestFullPath),
    (Convert-ToEvidenceRelativePath $reportFullPath),
    (Convert-ToEvidenceRelativePath $indexFullPath)
)
$sourceFiles = @(
    "production-handoff-export-manifest.json",
    "production-handoff-export.zip"
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_export_zip_index.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    zipPath = $zipPath
    zipSha256 = $zipHash
    zipLengthBytes = [int64]$zipFile.Length
    zipEntryCount = [int]$zipEntryPaths.Count
    directoryEntryCount = [int]$directoryEntryCount
    exportManifestFileCount = [int](Convert-ToInt (Get-JsonValue $exportManifest "exportFileCount" 0))
    expectedZipEntryCount = [int]$expectedZipEntries.Count
    missingZipEntryCount = [int]$missingZipEntries.Count
    unexpectedZipEntryCount = [int]$unexpectedZipEntries.Count
    hashMismatchCount = [int]$hashMismatchEntries.Count
    missingSourceFileCount = [int]$missingSourceFileEntries.Count
    unsafeEntryNameCount = [int]($emptyEntryNameCount + $pathTraversalEntries.Count + $rootedPathEntries.Count)
    duplicateEntryCount = [int]$duplicateZipEntries.Count
    requiredZipEntryCount = [int]$requiredZipEntries.Count
    missingRequiredZipEntryCount = [int]$missingRequiredZipEntries.Count
    canonicalActionQueueManifestEntryName = $canonicalActionQueueManifestEntryName
    canonicalActionQueueManifestRootSha256 = $canonicalActionQueueManifestRootSha256
    canonicalActionQueueManifestZipSha256 = $canonicalActionQueueManifestZipSha256
    canonicalActionQueueManifestZipMatchesRoot = [bool]$canonicalActionQueueManifestZipMatchesRoot
    emptyEntryNameCount = [int]$emptyEntryNameCount
    pathTraversalEntryCount = [int]$pathTraversalEntries.Count
    rootedPathEntryCount = [int]$rootedPathEntries.Count
    duplicateZipEntries = @($duplicateZipEntries)
    zipEntries = @($zipFileEntries)
    missingZipEntries = @($missingZipEntries)
    unexpectedZipEntries = @($unexpectedZipEntries)
    missingSourceFileEntries = @($missingSourceFileEntries)
    hashMismatchEntries = @($hashMismatchEntries)
    requiredZipEntries = @($requiredZipEntries)
    missingRequiredZipEntries = @($missingRequiredZipEntries)
    reportGenerated = (Test-Path $reportFullPath)
    indexGenerated = (Test-Path $indexFullPath)
    reportContentValidated = [bool]$reportContentValidated
    releasePipelineSendsEmail = $false
    realHostProjectEvidenceAccepted = $false
    externalEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "production_handoff_export_zip_index_only"
    sourceFiles = @($sourceFiles)
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles + $sourceFiles)
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
}

$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestFullPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Production handoff export zip index failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production handoff export zip index manifest: $manifestFullPath"
Write-Output "Production handoff export zip index report: $reportFullPath"
Write-Output "PASS AI TestPilot production handoff export zip index"
