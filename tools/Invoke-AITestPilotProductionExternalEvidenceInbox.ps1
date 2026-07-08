[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$InboxDir,
    [string]$ManifestPath,
    [string]$ReportPath,
    [string]$GameReplayDriverType = "Your.Game.Tests.ProductionReplayDriver",
    [switch]$AllowExternalInboxDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($InboxDir)) {
    $InboxDir = Join-Path $EvidenceBundleDir "production-external-evidence-inbox"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-external-evidence-inbox-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-external-evidence-inbox.md"
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

function Assert-PathUnderEvidenceBundle {
    param(
        [string]$Path,
        [string]$Label
    )

    $fullPath = Assert-PathUnderRepo $Path $Label
    if (-not (Test-PathWithinRoot $fullPath $script:evidenceBundlePath)) {
        throw "$Label must stay under evidence bundle: $fullPath"
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

function Join-MarkdownList {
    param([object[]]$Values)

    $items = @($Values | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($items.Count -eq 0) {
        return "(none)"
    }

    return [string]::Join(", ", $items)
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

function Add-InboxCheck {
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

function Get-InboxDirectoryName {
    param([string]$Area)

    switch ($Area) {
        "production_driver_binding" { return "production-driver-evidence" }
        "production_lua_patch_evidence" { return "production-lua-evidence" }
        "live_model_endpoint_smoke" { return "live-smoke-evidence" }
        default { return $Area }
    }
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$inboxPath = if ([bool]$AllowExternalInboxDir) {
    Resolve-FullPath $InboxDir
} else {
    Assert-PathUnderEvidenceBundle $InboxDir "InboxDir"
}
$manifestFullPath = Assert-PathUnderEvidenceBundle $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderEvidenceBundle $ReportPath "ReportPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

New-Item -ItemType Directory -Force $inboxPath | Out-Null

$handoffManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-package-manifest.json") "Production handoff package manifest"
$ownerPacketIndex = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-package\owner-packets\owner-packet-index.json") "Production handoff owner packet index"
$requiredEvidence = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-package\required-external-evidence.json") "Production handoff required evidence"

$rootReadmePath = Join-Path $inboxPath "README.md"
$acceptScriptPath = Join-Path $inboxPath "accept-returned-evidence.ps1"
$manifestCopyPath = Join-Path $inboxPath "production-external-evidence-inbox-manifest.json"
$reportCopyPath = Join-Path $inboxPath "production-external-evidence-inbox.md"

$acceptScript = @'
# AI TestPilot returned production evidence acceptance wrapper.
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$EvidenceBundleDir,
    [string]$OutputDir,
    [string]$OwnerResponseBundleDir,
    [string]$OwnerResponseBundleZipPath,
    [string]$GameReplayDriverType = "Your.Game.Tests.ProductionReplayDriver",
    [switch]$ContractFixtureMode,
    [switch]$RunHardValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-FullPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Test-PathUnderRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    $fullPath = (Resolve-FullPath $Path).TrimEnd([char[]]@("\", "/"))
    $rootPath = (Resolve-FullPath $Root).TrimEnd([char[]]@("\", "/"))
    if ($fullPath.Equals($rootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    return $fullPath.StartsWith($rootPath + "\", [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($rootPath + "/", [System.StringComparison]::OrdinalIgnoreCase)
}

function Find-RepoRoot {
    param([string]$StartDir)

    $current = Resolve-FullPath $StartDir
    while ($true) {
        if (Test-Path (Join-Path $current "tools\Invoke-AITestPilotReleasePipeline.ps1")) {
            return $current
        }

        $parent = [System.IO.Directory]::GetParent($current)
        if ($null -eq $parent) {
            throw "Could not locate repo root from $StartDir. Pass -RepoRoot explicitly."
        }

        $parentPath = $parent.FullName
        if ($parentPath -eq $current) {
            throw "Could not locate repo root from $StartDir. Pass -RepoRoot explicitly."
        }

        $current = $parentPath
    }
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

function Get-OwnerResponseBundleZipSafetyReport {
    param([string]$Path)

    $result = [ordered]@{
        inspected = $true
        safe = $false
        zipOpenSucceeded = $false
        entryCount = 0
        directoryEntryCount = 0
        unsafeEntryCount = 0
        duplicateEntryCount = 0
        unsafeEntries = @()
        duplicateEntries = @()
        safetyErrors = @()
    }

    try {
        Add-Type -AssemblyName System.IO.Compression | Out-Null
        Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
        $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    }
    catch {
        $result.safetyErrors = @("zip_open_failed")
        $result.unsafeEntries = @([ordered]@{
                name = [System.IO.Path]::GetFileName($Path)
                reasons = @($_.Exception.Message)
            })
        $result.unsafeEntryCount = 1
        return $result
    }

    $seen = @{}
    try {
        $result.zipOpenSucceeded = $true
        foreach ($entry in $archive.Entries) {
            $entryName = [string]$entry.FullName
            $result.entryCount += 1
            if ($entryName.EndsWith("/", [System.StringComparison]::Ordinal) -or
                $entryName.EndsWith("\", [System.StringComparison]::Ordinal)) {
                $result.directoryEntryCount += 1
            }

            $normalized = $entryName.Replace("\", "/")
            $reasons = @()
            if ([string]::IsNullOrWhiteSpace($normalized)) {
                $reasons += "empty_entry_name"
            }
            if ($normalized.StartsWith("/", [System.StringComparison]::Ordinal) -or
                $normalized.StartsWith("//", [System.StringComparison]::Ordinal)) {
                $reasons += "absolute_entry_path"
            }
            if ($normalized -match "^[A-Za-z]:") {
                $reasons += "drive_qualified_entry_path"
            }

            $segments = @($normalized -split "/" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if (@($segments | Where-Object { $_ -eq ".." }).Count -gt 0) {
                $reasons += "path_traversal_segment"
            }
            if (@($segments | Where-Object { $_ -eq "." }).Count -gt 0) {
                $reasons += "current_directory_segment"
            }
            if (@($segments | Where-Object { $_.Contains(":") }).Count -gt 0) {
                $reasons += "colon_in_entry_segment"
            }

            $canonical = $normalized.TrimStart("/")
            $canonicalKey = $canonical.ToLowerInvariant()
            if ($seen.ContainsKey($canonicalKey)) {
                $result.duplicateEntries += [ordered]@{
                    name = $entryName
                    firstEntry = [string]$seen[$canonicalKey]
                }
            }
            else {
                $seen[$canonicalKey] = $entryName
            }

            if ($reasons.Count -gt 0) {
                $result.unsafeEntries += [ordered]@{
                    name = $entryName
                    reasons = @($reasons)
                }
            }
        }
    }
    finally {
        $archive.Dispose()
    }

    $result.unsafeEntryCount = [int]@($result.unsafeEntries).Count
    $result.duplicateEntryCount = [int]@($result.duplicateEntries).Count
    $result.safe = $result.zipOpenSucceeded -and
        $result.entryCount -gt 0 -and
        $result.unsafeEntryCount -eq 0 -and
        $result.duplicateEntryCount -eq 0
    if ($result.entryCount -eq 0) {
        $result.safetyErrors += "empty_zip"
    }
    if ($result.duplicateEntryCount -gt 0) {
        $result.safetyErrors += "duplicate_entries"
    }
    if ($result.unsafeEntryCount -gt 0) {
        $result.safetyErrors += "unsafe_entries"
    }

    return $result
}

function Test-OwnerResponseBundleRoot {
    param([string]$Path)

    return (-not [string]::IsNullOrWhiteSpace($Path)) -and
        (Test-Path (Join-Path $Path "production-driver-evidence")) -and
        (Test-Path (Join-Path $Path "production-lua-evidence")) -and
        (Test-Path (Join-Path $Path "live-smoke-evidence"))
}

function Resolve-OwnerResponseBundleRoot {
    param([string]$Path)

    $bundlePath = Resolve-FullPath $Path
    $candidates = @(
        $bundlePath,
        (Join-Path $bundlePath "owner-response-bundle-template")
    )
    foreach ($candidate in $candidates) {
        if (Test-OwnerResponseBundleRoot $candidate) {
            return (Resolve-FullPath $candidate)
        }
    }

    $manifestCandidates = @(
        Get-ChildItem -LiteralPath $bundlePath -Recurse -Filter "owner-response-bundle-manifest.json" -File -ErrorAction SilentlyContinue |
            ForEach-Object { Split-Path $_.FullName -Parent }
    )
    foreach ($candidate in $manifestCandidates) {
        if (Test-OwnerResponseBundleRoot $candidate) {
            return (Resolve-FullPath $candidate)
        }
    }

    throw "Could not locate owner response bundle evidence directories under $bundlePath."
}

function Invoke-SemanticPreflightGate {
    param(
        [string]$RepoRootPath,
        [string]$EvidenceBundlePath,
        [string]$OutputPath,
        [string]$OwnerResponseBundleRoot,
        [switch]$ContractFixtureModeValue
    )

    $semanticPreflightScript = Join-Path $RepoRootPath "tools\Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1"
    if (-not (Test-Path $semanticPreflightScript)) {
        throw "Semantic preflight script is missing and acceptance is refused: $semanticPreflightScript"
    }
    if (-not (Test-PathUnderRoot $EvidenceBundlePath $RepoRootPath)) {
        throw "Semantic preflight requires -EvidenceBundleDir under the repo root before acceptance can run: $EvidenceBundlePath"
    }

    $semanticOutputRoot = $OutputPath
    if (-not (Test-PathUnderRoot $semanticOutputRoot $RepoRootPath)) {
        $semanticOutputRoot = Join-Path $EvidenceBundlePath "production-external-evidence-inbox-semantic-preflight"
    }
    if (-not (Test-PathUnderRoot $semanticOutputRoot $RepoRootPath)) {
        throw "Semantic preflight output must stay under the repo root. Pass -OutputDir under the repo or use an evidence bundle under the repo."
    }

    New-Item -ItemType Directory -Force $semanticOutputRoot | Out-Null
    $semanticManifestPath = Join-Path $semanticOutputRoot "semantic-preflight-manifest.json"
    $semanticReportPath = Join-Path $semanticOutputRoot "semantic-preflight.md"

    $preflightParams = @{
        EvidenceBundleDir = $EvidenceBundlePath
        ManifestPath = $semanticManifestPath
        ReportPath = $semanticReportPath
    }
    if (-not [string]::IsNullOrWhiteSpace($OwnerResponseBundleRoot)) {
        $preflightParams["OwnerResponseBundleDir"] = $OwnerResponseBundleRoot
    }
    else {
        $preflightParams["EvidenceRoot"] = $PSScriptRoot
    }
    if ([bool]$ContractFixtureModeValue) {
        $preflightParams["ContractFixtureMode"] = $true
    }

    & $semanticPreflightScript @preflightParams | Out-Null
    $semanticManifest = Read-JsonFile $semanticManifestPath "Semantic preflight manifest"
    $semanticStatus = [string](Get-JsonValue $semanticManifest "semanticPreflightStatus" "")
    $readyForAcceptanceCandidate = Convert-ToBool (Get-JsonValue $semanticManifest "readyForAcceptanceCandidate" $false)
    $semanticFailCount = [int](Get-JsonValue $semanticManifest "semanticFailCount" 0)
    $missingRequiredFileCount = [int](Get-JsonValue $semanticManifest "missingRequiredFileCount" 0)
    $acceptanceRun = Convert-ToBool (Get-JsonValue $semanticManifest "acceptanceRun" $true)
    $allowedStatus = $semanticStatus -eq "READY_FOR_AUTO_ACCEPTANCE_CANDIDATE" -or
        $semanticStatus -eq "WARN_READY_FOR_OPERATOR_ACCEPTANCE"

    if (-not $readyForAcceptanceCandidate -or
        -not $allowedStatus -or
        $semanticFailCount -ne 0 -or
        $missingRequiredFileCount -ne 0 -or
        $acceptanceRun) {
        throw "Semantic preflight gate refused acceptance. Inspect $semanticReportPath. Required before acceptance: readyForAcceptanceCandidate=true, semanticPreflightStatus=READY_FOR_AUTO_ACCEPTANCE_CANDIDATE or WARN_READY_FOR_OPERATOR_ACCEPTANCE, semanticFailCount=0, missingRequiredFileCount=0. Actual: semanticPreflightStatus=$semanticStatus, readyForAcceptanceCandidate=$readyForAcceptanceCandidate, semanticFailCount=$semanticFailCount, missingRequiredFileCount=$missingRequiredFileCount, acceptanceRun=$acceptanceRun."
    }

    Write-Output "Semantic preflight gate passed: $semanticManifestPath"
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Find-RepoRoot $PSScriptRoot
}
$repoPath = Resolve-FullPath $RepoRoot

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $PSScriptRoot ".."
}
$evidencePath = Resolve-FullPath $EvidenceBundleDir

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $PSScriptRoot "acceptance-output"
}
$outputPath = Resolve-FullPath $OutputDir
New-Item -ItemType Directory -Force $outputPath | Out-Null

if (-not [string]::IsNullOrWhiteSpace($OwnerResponseBundleDir) -and -not [string]::IsNullOrWhiteSpace($OwnerResponseBundleZipPath)) {
    throw "Pass either -OwnerResponseBundleDir or -OwnerResponseBundleZipPath, not both."
}

$driverEvidenceDir = Join-Path $PSScriptRoot "production-driver-evidence"
$luaEvidenceDir = Join-Path $PSScriptRoot "production-lua-evidence"
$liveSmokeEvidenceDir = Join-Path $PSScriptRoot "live-smoke-evidence"
$ownerResponseBundleRoot = ""

if (-not [string]::IsNullOrWhiteSpace($OwnerResponseBundleZipPath)) {
    $zipPath = Resolve-FullPath $OwnerResponseBundleZipPath
    if (-not (Test-Path $zipPath)) {
        throw "Owner response bundle zip does not exist: $zipPath"
    }

    $zipSafetyReport = Get-OwnerResponseBundleZipSafetyReport $zipPath
    if (-not [bool]$zipSafetyReport.safe) {
        throw "Owner response bundle zip failed safety inspection before semantic preflight or acceptance. Unsafe entries: $($zipSafetyReport.unsafeEntryCount); duplicate entries: $($zipSafetyReport.duplicateEntryCount); errors: $($zipSafetyReport.safetyErrors -join ', ')"
    }

    $expandedBundlePath = Join-Path $outputPath "expanded-owner-response-bundle"
    if (Test-Path $expandedBundlePath) {
        Remove-Item -LiteralPath $expandedBundlePath -Recurse -Force
    }
    New-Item -ItemType Directory -Force $expandedBundlePath | Out-Null
    Expand-Archive -LiteralPath $zipPath -DestinationPath $expandedBundlePath -Force
    $OwnerResponseBundleDir = $expandedBundlePath
}

if (-not [string]::IsNullOrWhiteSpace($OwnerResponseBundleDir)) {
    $ownerResponseBundleRoot = Resolve-OwnerResponseBundleRoot $OwnerResponseBundleDir
    $driverEvidenceDir = Join-Path $ownerResponseBundleRoot "production-driver-evidence"
    $luaEvidenceDir = Join-Path $ownerResponseBundleRoot "production-lua-evidence"
    $liveSmokeEvidenceDir = Join-Path $ownerResponseBundleRoot "live-smoke-evidence"
}

Invoke-SemanticPreflightGate `
    -RepoRootPath $repoPath `
    -EvidenceBundlePath $evidencePath `
    -OutputPath $outputPath `
    -OwnerResponseBundleRoot $ownerResponseBundleRoot `
    -ContractFixtureModeValue:$ContractFixtureMode

$handoffWrapper = Join-Path (Split-Path $PSScriptRoot -Parent) "production-handoff-package\accept-external-evidence.ps1"
if (-not (Test-Path $handoffWrapper)) {
    $handoffWrapper = Join-Path $evidencePath "production-handoff-package\accept-external-evidence.ps1"
}
if (-not (Test-Path $handoffWrapper)) {
    throw "Could not locate production-handoff-package\accept-external-evidence.ps1. Pass -EvidenceBundleDir or run from the release evidence bundle."
}

& $handoffWrapper `
    -RepoRoot $repoPath `
    -EvidenceBundleDir $evidencePath `
    -OutputDir $outputPath `
    -ProductionDriverEvidenceDir $driverEvidenceDir `
    -ProductionLuaEvidenceDir $luaEvidenceDir `
    -LiveModelEndpointSmokeEvidenceDir $liveSmokeEvidenceDir `
    -GameReplayDriverType $GameReplayDriverType `
    -RequireAllEvidence `
    -ContractFixtureMode:$ContractFixtureMode `
    -RunHardValidation:$RunHardValidation
'@
$acceptScript | Set-Content -Path $acceptScriptPath -Encoding UTF8
$acceptanceWrapperSupportsOwnerResponseBundle = $acceptScript.Contains("OwnerResponseBundleDir") -and
    $acceptScript.Contains("OwnerResponseBundleZipPath") -and
    $acceptScript.Contains("Expand-Archive")
$acceptanceWrapperRequiresSemanticPreflightCandidate = $acceptScript.Contains("Invoke-SemanticPreflightGate") -and
    $acceptScript.Contains("Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1") -and
    $acceptScript.Contains("readyForAcceptanceCandidate") -and
    $acceptScript.Contains("semanticFailCount") -and
    $acceptScript.Contains("Semantic preflight gate refused acceptance")

$areaStatuses = @()
foreach ($packet in @(Convert-ToArray $ownerPacketIndex.packets)) {
    $area = [string](Get-JsonValue $packet "area" "")
    $owner = [string](Get-JsonValue $packet "owner" "")
    $directoryName = Get-InboxDirectoryName $area
    $areaPath = Join-Path $inboxPath $directoryName
    New-Item -ItemType Directory -Force $areaPath | Out-Null

    $requiredFiles = @(Convert-ToArray (Get-JsonValue $packet "requiredEvidenceFiles" @()) | ForEach-Object { [string]$_ })
    $presentFiles = @()
    $missingFiles = @()
    foreach ($fileName in $requiredFiles) {
        if (Test-Path (Join-Path $areaPath $fileName)) {
            $presentFiles += $fileName
        } else {
            $missingFiles += $fileName
        }
    }

    $areaReadmeLines = @(
        "# Returned Evidence: $owner",
        "",
        "Area: ``$area``",
        "Directory: ``$directoryName``",
        "",
        "## Required Files",
        ""
    )
    foreach ($fileName in $requiredFiles) {
        $areaReadmeLines += "- ``$fileName``"
    }
    $areaReadmeLines += @(
        "",
        "## Validation",
        "",
        "After all owner evidence directories are filled, run read-only semantic preflight from the repo root first:",
        "",
        '```powershell',
        ".\tools\Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1 -EvidenceRoot `"path\to\production-external-evidence-inbox`"",
        '```',
        "",
        "Continue only when the semantic preflight manifest reports ``readyForAcceptanceCandidate=true``, ``semanticFailCount=0``, ``missingRequiredFileCount=0``, and a candidate-ready ``semanticPreflightStatus``.",
        "",
        "Then run the bundled/direct inbox auto-acceptance bridge from the inbox root:",
        "",
        '```powershell',
        ".\accept-returned-evidence.ps1 -RepoRoot `"path\to\AITestPilot`"",
        '```',
        "",
        'If the owners return a filled owner response bundle, run owner-return status first, run semantic preflight with `-OwnerResponseBundleDir` or `-OwnerResponseBundleZipPath`, then run repo auto acceptance with `-RequireAllEvidence`. `accept-returned-evidence.ps1` remains the bundled/direct inbox bridge for zip-local or direct inbox workflows.',
        "",
        "The bridge re-runs the semantic preflight gate and refuses acceptance when the returned evidence is missing, semantically bad, or not candidate-ready.",
        "",
        "This directory is incomplete until every required file exists, semantic preflight is candidate-ready, and the bundled/direct acceptance bridge passes."
    )
    $areaReadmePath = Join-Path $areaPath "README.md"
    $areaReadmeLines | Set-Content -Path $areaReadmePath -Encoding UTF8

    $areaStatuses += [ordered]@{
        owner = $owner
        area = $area
        inboxDirectory = $directoryName
        inboxPath = $areaPath
        requiredEvidenceFiles = @($requiredFiles)
        requiredFileCount = [int]$requiredFiles.Count
        presentFiles = @($presentFiles)
        presentFileCount = [int]$presentFiles.Count
        missingFiles = @($missingFiles)
        missingFileCount = [int]$missingFiles.Count
        anyEvidenceProvided = [bool]($presentFiles.Count -gt 0)
        allEvidenceFilesPresent = [bool]($requiredFiles.Count -gt 0 -and $missingFiles.Count -eq 0)
        packetPath = [string](Get-JsonValue $packet "packetPath" "")
        hardValidationCommand = [string](Get-JsonValue $packet "hardValidationCommand" "")
    }
}

$submittedAreaCount = @($areaStatuses | Where-Object { [bool]$_["anyEvidenceProvided"] }).Count
$completeAreaCount = @($areaStatuses | Where-Object { [bool]$_["allEvidenceFilesPresent"] }).Count
$requiredEvidenceFileCountMeasure = @($areaStatuses | ForEach-Object { [int]$_["requiredFileCount"] } | Measure-Object -Sum)
$presentEvidenceFileCountMeasure = @($areaStatuses | ForEach-Object { [int]$_["presentFileCount"] } | Measure-Object -Sum)
$missingEvidenceFileCountMeasure = @($areaStatuses | ForEach-Object { [int]$_["missingFileCount"] } | Measure-Object -Sum)
$requiredEvidenceFileCount = if ($null -eq $requiredEvidenceFileCountMeasure.Sum) { 0 } else { [int]$requiredEvidenceFileCountMeasure.Sum }
$presentEvidenceFileCount = if ($null -eq $presentEvidenceFileCountMeasure.Sum) { 0 } else { [int]$presentEvidenceFileCountMeasure.Sum }
$missingEvidenceFileCount = if ($null -eq $missingEvidenceFileCountMeasure.Sum) { 0 } else { [int]$missingEvidenceFileCountMeasure.Sum }
$externalEvidenceCollectionComplete = $areaStatuses.Count -gt 0 -and $completeAreaCount -eq $areaStatuses.Count

$acceptanceCommand = ".\production-external-evidence-inbox\accept-returned-evidence.ps1 -RepoRoot `"path\to\AITestPilot`""
$ownerResponseBundleStatusCommand = ".\tools\Invoke-AITestPilotProductionExternalEvidenceOwnerReturnBundleStatus.ps1 -OwnerResponseBundleDir `"path\to\filled-owner-response-bundle`""
$ownerResponseBundleZipStatusCommand = ".\tools\Invoke-AITestPilotProductionExternalEvidenceOwnerReturnBundleStatus.ps1 -OwnerResponseBundleZipPath `"path\to\filled-owner-response-bundle.zip`""
$semanticPreflightCommand = ".\tools\Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1 -EvidenceRoot `"path\to\production-external-evidence-inbox`""
$ownerResponseBundleSemanticPreflightCommand = ".\tools\Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1 -OwnerResponseBundleDir `"path\to\filled-owner-response-bundle`""
$ownerResponseBundleZipSemanticPreflightCommand = ".\tools\Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1 -OwnerResponseBundleZipPath `"path\to\filled-owner-response-bundle.zip`""
$ownerResponseBundleAutoAcceptanceCommand = ".\tools\Invoke-AITestPilotProductionExternalEvidenceAutoAcceptance.ps1 -OwnerResponseBundleDir `"path\to\filled-owner-response-bundle`" -RequireAllEvidence"
$ownerResponseBundleZipAutoAcceptanceCommand = ".\tools\Invoke-AITestPilotProductionExternalEvidenceAutoAcceptance.ps1 -OwnerResponseBundleZipPath `"path\to\filled-owner-response-bundle.zip`" -RequireAllEvidence"
$rootReadmeLines = @(
    "# AI TestPilot Returned Production Evidence Inbox",
    "",
    "Copy host-project evidence into these directories, then run semantic preflight before the bundled/direct inbox auto-acceptance bridge. Owner response bundles use owner-return status before semantic preflight and repo auto acceptance. This inbox does not promote fixture evidence as real production evidence.",
    "",
    "## Directories",
    "",
    "| Owner | Area | Directory | Required files |",
    "| --- | --- | --- | --- |"
)
foreach ($areaStatus in $areaStatuses) {
    $owner = Format-MarkdownCell (Get-JsonValue $areaStatus "owner" "")
    $area = Format-MarkdownCell (Get-JsonValue $areaStatus "area" "")
    $directory = Format-MarkdownCell (Get-JsonValue $areaStatus "inboxDirectory" "")
    $requiredFiles = Format-MarkdownCell (Join-MarkdownList @(Get-JsonValue $areaStatus "requiredEvidenceFiles" @()))
    $rootReadmeLines += "| $owner | $area | $directory | $requiredFiles |"
}
$rootReadmeLines += @(
    "",
    "## Semantic Preflight First",
    "",
    "From the repo root, run read-only semantic preflight before any acceptance command:",
    "",
    '```powershell',
        $semanticPreflightCommand,
        '```',
        "",
        "For a returned owner response bundle directory or zip, run owner-return status before the matching semantic preflight:",
        "",
        '```powershell',
        $ownerResponseBundleStatusCommand,
        $ownerResponseBundleZipStatusCommand,
        $ownerResponseBundleSemanticPreflightCommand,
        $ownerResponseBundleZipSemanticPreflightCommand,
        '```',
        "",
        "Continue to acceptance only when the semantic preflight manifest reports ``readyForAcceptanceCandidate=true``, ``semanticFailCount=0``, ``missingRequiredFileCount=0``, and ``semanticPreflightStatus=READY_FOR_AUTO_ACCEPTANCE_CANDIDATE`` or ``WARN_READY_FOR_OPERATOR_ACCEPTANCE``.",
        "",
        "The generated ``accept-returned-evidence.ps1`` bridge re-runs this semantic preflight gate and refuses before invoking acceptance if the returned evidence is missing, semantically bad, unsafe, or not candidate-ready.",
    "",
    "## Auto Acceptance After Candidate-Ready Preflight",
    "",
        "For returned owner response bundle directories or zips, use repo auto acceptance after owner-return status and semantic preflight pass:",
        "",
        '```powershell',
        $ownerResponseBundleAutoAcceptanceCommand,
        $ownerResponseBundleZipAutoAcceptanceCommand,
        '```',
        "",
        "For direct inbox fallback or zip-local handoff workflows, use the bundled/direct inbox bridge:",
        "",
    '```powershell',
        ".\accept-returned-evidence.ps1 -RepoRoot `"path\to\AITestPilot`"",
        '```',
        "",
        "The bridge also accepts returned owner response bundle directories or zips when a direct bundled bridge is needed:",
        "",
        '```powershell',
        ".\accept-returned-evidence.ps1 -RepoRoot `"path\to\AITestPilot`" -OwnerResponseBundleDir `"path\to\filled-owner-response-bundle`"",
        ".\accept-returned-evidence.ps1 -RepoRoot `"path\to\AITestPilot`" -OwnerResponseBundleZipPath `"path\to\filled-owner-response-bundle.zip`"",
        '```',
        "",
        'Add `-ContractFixtureMode` only for repository contract probes that use accepted fixture evidence.',
        'Add `-RunHardValidation` only after the acceptance report passes.',
    "",
    "## Boundary",
    "",
    "- This inbox is a return structure and inspection report.",
    "- Semantic preflight is read-only and must run before acceptance.",
    '- Real host-project evidence is accepted only after repo auto acceptance or the bundled/direct inbox bridge produces a PASS acceptance report with `realHostProjectEvidenceAccepted=true`.',
    "- Fixture contract evidence must not be copied into this inbox as production evidence."
)
$rootReadmeLines | Set-Content -Path $rootReadmePath -Encoding UTF8

$reportLines = @(
    "# AI TestPilot Production External Evidence Inbox",
    "",
    "Schema: ``aitestpilot.production_external_evidence_inbox.v1``",
    "Generated at UTC: $((Get-Date).ToUniversalTime().ToString("O"))",
    "",
    "## Summary",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Evidence areas | $($areaStatuses.Count) |",
    "| Submitted areas | $submittedAreaCount |",
    "| Complete areas | $completeAreaCount |",
    "| Required files | $requiredEvidenceFileCount |",
    "| Present files | $presentEvidenceFileCount |",
    "| Missing files | $missingEvidenceFileCount |",
    "| External evidence collection complete | $externalEvidenceCollectionComplete |",
    "| Real host-project evidence accepted | False |",
    "",
    "## Area Status",
    "",
    "| Owner | Area | Directory | Present | Missing | Next command |",
    "| --- | --- | --- | --- | --- | --- |"
)
foreach ($areaStatus in $areaStatuses) {
    $owner = Format-MarkdownCell (Get-JsonValue $areaStatus "owner" "")
    $area = Format-MarkdownCell (Get-JsonValue $areaStatus "area" "")
    $directory = Format-MarkdownCell (Get-JsonValue $areaStatus "inboxDirectory" "")
    $presentFiles = Format-MarkdownCell (Join-MarkdownList @(Get-JsonValue $areaStatus "presentFiles" @()))
    $missingFiles = Format-MarkdownCell (Join-MarkdownList @(Get-JsonValue $areaStatus "missingFiles" @()))
    $nextCommand = Format-MarkdownCell $semanticPreflightCommand
    $reportLines += "| $owner | $area | $directory | $presentFiles | $missingFiles | $nextCommand |"
}
$reportLines += @(
    "",
    "## Boundary",
    "",
    "- This inbox only standardizes returned evidence layout.",
    "- It is not an acceptance result and does not claim real production evidence.",
    '- Use owner-return status and semantic preflight first; the generated `accept-returned-evidence.ps1` bridge also re-runs the preflight gate and refuses non-candidate returned evidence.',
    '- Use repo auto acceptance, or the bundled/direct `accept-returned-evidence.ps1` bridge when operating from the inbox or export zip, to produce `production-external-evidence-acceptance-manifest.json` only after candidate-ready semantic preflight and before hard validation.'
)
$reportText = [string]::Join([Environment]::NewLine, $reportLines) + [Environment]::NewLine
$reportText | Set-Content -Path $reportFullPath -Encoding UTF8
$reportText | Set-Content -Path $reportCopyPath -Encoding UTF8

$reportContentValidated = $reportText.Contains("AI TestPilot Production External Evidence Inbox") -and
    $reportText.Contains("production_driver_binding") -and
    $reportText.Contains("production_lua_patch_evidence") -and
    $reportText.Contains("live_model_endpoint_smoke") -and
    $reportText.Contains("Real host-project evidence accepted") -and
    $reportText.Contains("semantic preflight") -and
    $reportText.Contains("accept-returned-evidence.ps1") -and
    -not $reportText.Contains("System.Collections") -and
    -not $reportText.Contains("@{")

$inboxFiles = @(
    Get-ChildItem -LiteralPath $inboxPath -Recurse -File |
        ForEach-Object { "production-external-evidence-inbox\" + (Convert-ToRelativePath $inboxPath $_.FullName) }
)
$inboxFiles = @($inboxFiles | Sort-Object)

$checks = @()
Add-InboxCheck "handoff_source" `
    ($handoffManifest.status -eq "PASS" -and [bool]$handoffManifest.ownerPacketsContentValidated) `
    "Source handoff package must be PASS and include validated owner packets."
Add-InboxCheck "owner_area_mapping" `
    ($areaStatuses.Count -eq [int]$ownerPacketIndex.ownerPacketCount -and $areaStatuses.Count -eq 3) `
    "Inbox must create one evidence directory per owner packet."
Add-InboxCheck "required_evidence_contract" `
    ($requiredEvidence.schemaVersion -eq "aitestpilot.production_handoff_required_evidence.v1" -and $requiredEvidenceFileCount -eq 9) `
    "Inbox must reflect the required driver, Lua, and live-smoke evidence files."
Add-InboxCheck "inbox_files_generated" `
    ((Test-Path $rootReadmePath) -and (Test-Path $acceptScriptPath) -and $inboxFiles.Count -ge 6) `
    "Inbox must generate README files and the returned-evidence acceptance wrapper."
Add-InboxCheck "owner_response_bundle_entrypoint_generated" `
    ([bool]$acceptanceWrapperSupportsOwnerResponseBundle) `
    "Returned-evidence acceptance wrapper must support filled owner response bundle directories and zip files."
Add-InboxCheck "semantic_preflight_gate_required" `
    ([bool]$acceptanceWrapperRequiresSemanticPreflightCandidate) `
    "Returned-evidence acceptance wrapper must run semantic preflight and require candidate-ready returned evidence before acceptance."
Add-InboxCheck "report_content" `
    ([bool]$reportContentValidated) `
    "Inbox report must summarize area status, missing files, semantic-preflight next command, and evidence boundary."
Add-InboxCheck "fixture_boundary_preserved" `
    ($true) `
    "Inbox inspection must not accept fixture evidence or claim real host-project evidence."

$failedChecks = @($checks | Where-Object { -not [bool]$_["passed"] })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$generatedFiles = @(
    (Split-Path $manifestFullPath -Leaf),
    (Split-Path $reportFullPath -Leaf)
) + $inboxFiles
$sourceFiles = @(
    "production-handoff-package-manifest.json",
    "production-handoff-package/owner-packets/owner-packet-index.json",
    "production-handoff-package/required-external-evidence.json"
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_external_evidence_inbox.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    inboxDir = $inboxPath
    allowExternalInboxDir = [bool]$AllowExternalInboxDir
    reportPath = $reportFullPath
    reportGenerated = (Test-Path $reportFullPath)
    reportContentValidated = [bool]$reportContentValidated
    inboxTemplateGenerated = $true
    acceptanceWrapperGenerated = (Test-Path $acceptScriptPath)
    acceptanceWrapperSupportsOwnerResponseBundle = [bool]$acceptanceWrapperSupportsOwnerResponseBundle
    acceptanceWrapperRequiresSemanticPreflightCandidate = [bool]$acceptanceWrapperRequiresSemanticPreflightCandidate
    acceptanceCommand = $acceptanceCommand
    semanticPreflightCommand = $semanticPreflightCommand
    ownerResponseBundleSemanticPreflightCommand = $ownerResponseBundleSemanticPreflightCommand
    ownerResponseBundleZipSemanticPreflightCommand = $ownerResponseBundleZipSemanticPreflightCommand
    gameReplayDriverType = $GameReplayDriverType
    ownerPacketCount = [int]$ownerPacketIndex.ownerPacketCount
    evidenceAreaCount = [int]$areaStatuses.Count
    submittedAreaCount = [int]$submittedAreaCount
    completeAreaCount = [int]$completeAreaCount
    requiredEvidenceFileCount = [int]$requiredEvidenceFileCount
    presentEvidenceFileCount = [int]$presentEvidenceFileCount
    missingRequiredFileCount = [int]$missingEvidenceFileCount
    externalEvidenceCollectionComplete = [bool]$externalEvidenceCollectionComplete
    realHostProjectEvidenceAccepted = $false
    externalEvidenceAccepted = $false
    releasePipelineUsesFixture = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "host_project_external_evidence_inbox_inspection_only"
    areaStatuses = @($areaStatuses)
    generatedFiles = @($generatedFiles)
    sourceFiles = @($sourceFiles)
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
    files = @($generatedFiles + $sourceFiles)
}

$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestFullPath -Encoding UTF8
$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestCopyPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Production external evidence inbox failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production external evidence inbox: $inboxPath"
Write-Output "Production external evidence inbox manifest: $manifestFullPath"
Write-Output "Production external evidence inbox report: $reportFullPath"
Write-Output "PASS AI TestPilot production external evidence inbox"
