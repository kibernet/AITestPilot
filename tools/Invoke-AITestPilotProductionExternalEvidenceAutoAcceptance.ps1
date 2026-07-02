[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ManifestPath,
    [string]$ReportPath,
    [string]$AcceptanceBundleDir,
    [string]$EvidenceRoot,
    [string]$OwnerResponseBundleDir,
    [string]$OwnerResponseBundleZipPath,
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
$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())

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
if ([string]::IsNullOrWhiteSpace($OwnerResponseBundleZipPath) -and -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable("AITESTPILOT_OWNER_RESPONSE_BUNDLE_ZIP_PATH"))) {
    $OwnerResponseBundleZipPath = [Environment]::GetEnvironmentVariable("AITESTPILOT_OWNER_RESPONSE_BUNDLE_ZIP_PATH")
}
if (-not [string]::IsNullOrWhiteSpace($OwnerResponseBundleDir) -and -not [string]::IsNullOrWhiteSpace($OwnerResponseBundleZipPath)) {
    throw "Pass either -OwnerResponseBundleDir or -OwnerResponseBundleZipPath, not both."
}

$expandedOwnerResponseBundleDir = ""
$ownerResponseBundleZipSafetyReport = [ordered]@{
    inspected = $false
    safe = $true
    zipOpenSucceeded = $false
    entryCount = 0
    directoryEntryCount = 0
    unsafeEntryCount = 0
    duplicateEntryCount = 0
    unsafeEntries = @()
    duplicateEntries = @()
    safetyErrors = @()
}
$ownerResponseBundleZipRejected = $false
if (-not [string]::IsNullOrWhiteSpace($OwnerResponseBundleZipPath)) {
    $ownerResponseBundleZipFullPath = Resolve-FullPath $OwnerResponseBundleZipPath
    if (-not (Test-Path $ownerResponseBundleZipFullPath)) {
        throw "Owner response bundle zip does not exist: $ownerResponseBundleZipFullPath"
    }

    $ownerResponseBundleZipSafetyReport = Get-OwnerResponseBundleZipSafetyReport $ownerResponseBundleZipFullPath
    if (-not [bool]$ownerResponseBundleZipSafetyReport.safe) {
        $ownerResponseBundleZipRejected = $true
    }
    else {
        $zipStem = [System.IO.Path]::GetFileNameWithoutExtension($ownerResponseBundleZipFullPath)
        if ([string]::IsNullOrWhiteSpace($zipStem)) {
            $zipStem = "owner-response-bundle"
        }
        $expandedOwnerResponseBundleDir = Join-Path $tempRoot (Join-Path "AITestPilot\production-external-evidence-auto-acceptance" $zipStem)
        if (Test-Path $expandedOwnerResponseBundleDir) {
            Remove-Item -LiteralPath $expandedOwnerResponseBundleDir -Recurse -Force
        }
        New-Item -ItemType Directory -Force $expandedOwnerResponseBundleDir | Out-Null
        Expand-Archive -LiteralPath $ownerResponseBundleZipFullPath -DestinationPath $expandedOwnerResponseBundleDir -Force
        $OwnerResponseBundleDir = $expandedOwnerResponseBundleDir
    }
}
if (-not [string]::IsNullOrWhiteSpace($OwnerResponseBundleDir)) {
    $OwnerResponseBundleDir = Resolve-OwnerResponseBundleRoot $OwnerResponseBundleDir
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
if ($ownerResponseBundleZipRejected) {
    $allEvidenceReady = $false
}
$semanticPreflightGateRun = $false
$semanticPreflightGatePassed = $false
$semanticPreflightGateBlockedAcceptance = $false
$semanticPreflightErrorMessage = ""
$semanticPreflightManifest = $null
$semanticPreflightArtifactPrefix = ([System.IO.Path]::GetFileNameWithoutExtension($manifestFullPath)) -replace "-manifest$", ""
$semanticPreflightArtifactDir = Split-Path $manifestFullPath -Parent
$semanticPreflightManifestPath = Join-Path $semanticPreflightArtifactDir "$semanticPreflightArtifactPrefix-semantic-preflight-manifest.json"
$semanticPreflightReportPath = Join-Path $semanticPreflightArtifactDir "$semanticPreflightArtifactPrefix-semantic-preflight.md"
$semanticPreflightSourceKind = ""
$semanticPreflightStatus = ""
$semanticPreflightReadyForAcceptanceCandidate = $false
$semanticPreflightFailCount = 0
$semanticPreflightWarnCount = 0
$semanticPreflightMissingRequiredFileCount = 0
$semanticPreflightFixtureSignalCount = 0
$semanticPreflightPlaceholderSignalCount = 0
$semanticPreflightGateAcceptableStatuses = @(
    "READY_FOR_AUTO_ACCEPTANCE_CANDIDATE",
    "WARN_READY_FOR_OPERATOR_ACCEPTANCE"
)

if (-not $ownerResponseBundleZipRejected) {
    New-Item -ItemType Directory -Force $semanticPreflightArtifactDir | Out-Null
    $semanticPreflightParams = @{
        EvidenceBundleDir = $evidenceBundlePath
        ManifestPath = $semanticPreflightManifestPath
        ReportPath = $semanticPreflightReportPath
    }

    if (-not [string]::IsNullOrWhiteSpace($OwnerResponseBundleZipPath)) {
        $semanticPreflightParams["OwnerResponseBundleZipPath"] = (Resolve-FullPath $OwnerResponseBundleZipPath)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($OwnerResponseBundleDir)) {
        $semanticPreflightParams["OwnerResponseBundleDir"] = (Resolve-FullPath $OwnerResponseBundleDir)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($EvidenceRoot)) {
        $semanticPreflightParams["EvidenceRoot"] = (Resolve-FullPath $EvidenceRoot)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ProductionDriverEvidenceDir) -or
        -not [string]::IsNullOrWhiteSpace($ProductionLuaEvidenceDir) -or
        -not [string]::IsNullOrWhiteSpace($LiveModelEndpointSmokeEvidenceDir)) {
        $semanticPreflightRoot = Join-Path $semanticPreflightArtifactDir "$semanticPreflightArtifactPrefix-semantic-preflight-evidence-root"
        if (Test-Path $semanticPreflightRoot) {
            Remove-Item -LiteralPath $semanticPreflightRoot -Recurse -Force
        }
        New-Item -ItemType Directory -Force $semanticPreflightRoot | Out-Null
        foreach ($copySpec in @(
                [ordered]@{ path = [string]$driverCandidate.path; destination = "production-driver-evidence" },
                [ordered]@{ path = [string]$luaCandidate.path; destination = "production-lua-evidence" },
                [ordered]@{ path = [string]$liveCandidate.path; destination = "live-smoke-evidence" }
            )) {
            $sourcePath = [string]$copySpec.path
            if (-not [string]::IsNullOrWhiteSpace($sourcePath) -and (Test-Path $sourcePath)) {
                Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $semanticPreflightRoot ([string]$copySpec.destination)) -Recurse -Force
            }
        }
        $semanticPreflightParams["EvidenceRoot"] = $semanticPreflightRoot
    }

    if ([bool]$ContractFixtureMode) {
        $semanticPreflightParams["ContractFixtureMode"] = $true
    }

    $semanticPreflightGateRun = $true
    try {
        & (Join-Path $PSScriptRoot "Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1") @semanticPreflightParams | Out-Null
    }
    catch {
        $semanticPreflightErrorMessage = $_.Exception.Message
    }

    if (Test-Path $semanticPreflightManifestPath) {
        $semanticPreflightManifest = Read-JsonFile $semanticPreflightManifestPath "Production external evidence semantic preflight manifest"
        $semanticPreflightSourceKind = [string](Get-JsonValue $semanticPreflightManifest "sourceKind" "")
        $semanticPreflightStatus = [string](Get-JsonValue $semanticPreflightManifest "semanticPreflightStatus" "")
        $semanticPreflightReadyForAcceptanceCandidate = Convert-ToBool (Get-JsonValue $semanticPreflightManifest "readyForAcceptanceCandidate" $false)
        $semanticPreflightFailCount = Convert-ToInt (Get-JsonValue $semanticPreflightManifest "semanticFailCount" 0)
        $semanticPreflightWarnCount = Convert-ToInt (Get-JsonValue $semanticPreflightManifest "semanticWarnCount" 0)
        $semanticPreflightMissingRequiredFileCount = Convert-ToInt (Get-JsonValue $semanticPreflightManifest "missingRequiredFileCount" 0)
        $semanticPreflightFixtureSignalCount = Convert-ToInt (Get-JsonValue $semanticPreflightManifest "fixtureSignalCount" 0)
        $semanticPreflightPlaceholderSignalCount = Convert-ToInt (Get-JsonValue $semanticPreflightManifest "placeholderSignalCount" 0)
        $semanticPreflightGatePassed = (
            (Get-JsonValue $semanticPreflightManifest "status" "") -eq "PASS" -and
            $semanticPreflightReadyForAcceptanceCandidate -and
            $semanticPreflightFailCount -eq 0 -and
            $semanticPreflightGateAcceptableStatuses -contains $semanticPreflightStatus
        )
    }
}

$acceptanceRun = $false
$acceptanceSucceeded = $false
$acceptanceFailed = $false
$acceptanceErrorMessage = ""
$acceptanceManifest = $null
$acceptanceManifestPath = Join-Path $acceptanceBundlePath "production-external-evidence-acceptance-manifest.json"
$acceptanceReportPath = Join-Path $acceptanceBundlePath "production-external-evidence-acceptance.md"

if ($allEvidenceReady -and $semanticPreflightGatePassed) {
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
$semanticPreflightGateBlockedAcceptance = $allEvidenceReady -and -not $semanticPreflightGatePassed -and -not $acceptanceRun

$allExternalEvidenceAccepted = $acceptanceSucceeded -and
    $null -ne $acceptanceManifest -and
    (Get-JsonValue $acceptanceManifest "status" "") -eq "PASS" -and
    (Convert-ToBool (Get-JsonValue $acceptanceManifest "allExternalEvidenceAccepted" $false))
$realHostProjectEvidenceAccepted = $allExternalEvidenceAccepted -and
    (Convert-ToBool (Get-JsonValue $acceptanceManifest "realHostProjectEvidenceAccepted" $false)) -and
    -not [bool]$ContractFixtureMode

$status = if ($ownerResponseBundleZipRejected) {
    "FAIL"
}
elseif ($allExternalEvidenceAccepted) {
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
    (($allEvidenceReady -and $semanticPreflightGatePassed -and $acceptanceRun) -or ((-not $allEvidenceReady) -and (-not $acceptanceRun)) -or ($semanticPreflightGateBlockedAcceptance -and -not $acceptanceRun)) `
    "Acceptance should run only when all three evidence areas contain every required file and semantic preflight has passed."
Add-AutoCheck "semantic_preflight_gate_runs_before_acceptance" `
    ($ownerResponseBundleZipRejected -or ($semanticPreflightGateRun -and (Test-Path $semanticPreflightManifestPath) -and (Test-Path $semanticPreflightReportPath))) `
    "Auto acceptance must run semantic preflight before invoking the stable acceptance script."
Add-AutoCheck "acceptance_requires_semantic_preflight_candidate" `
    ((-not $acceptanceRun) -or $semanticPreflightGatePassed) `
    "Acceptance may run only after semantic preflight reports a ready candidate with zero semantic failures."
Add-AutoCheck "accepted_only_after_existing_acceptance_passes" `
    ((-not $allExternalEvidenceAccepted) -or ($acceptanceSucceeded -and $null -ne $acceptanceManifest -and (Get-JsonValue $acceptanceManifest "status" "") -eq "PASS")) `
    "Auto acceptance must delegate pass/fail decisions to the stable external evidence acceptance script."
Add-AutoCheck "owner_response_bundle_zip_safe_before_expand" `
    (([string]::IsNullOrWhiteSpace($OwnerResponseBundleZipPath)) -or
        ([bool]$ownerResponseBundleZipSafetyReport.safe -and -not [bool]$ownerResponseBundleZipRejected)) `
    "Owner response bundle zip input must be inspected for unsafe paths and duplicate entries before expansion or acceptance."
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
elseif ($ownerResponseBundleZipRejected) {
    "owner_response_bundle_zip_rejected_before_acceptance"
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
if (Test-Path $semanticPreflightManifestPath) {
    $generatedFiles += (Convert-ToEvidenceRelativePath $semanticPreflightManifestPath)
}
if (Test-Path $semanticPreflightReportPath) {
    $generatedFiles += (Convert-ToEvidenceRelativePath $semanticPreflightReportPath)
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
    ownerResponseBundleZipPath = if ([string]::IsNullOrWhiteSpace($OwnerResponseBundleZipPath)) { "" } else { Resolve-FullPath $OwnerResponseBundleZipPath }
    expandedOwnerResponseBundleDir = if ([string]::IsNullOrWhiteSpace($expandedOwnerResponseBundleDir)) { "" } else { Resolve-FullPath $expandedOwnerResponseBundleDir }
    ownerResponseBundleZipInspected = [bool]$ownerResponseBundleZipSafetyReport.inspected
    ownerResponseBundleZipSafe = [bool]$ownerResponseBundleZipSafetyReport.safe
    ownerResponseBundleZipRejectedBeforeExpand = [bool]$ownerResponseBundleZipRejected
    ownerResponseBundleZipOpenSucceeded = [bool]$ownerResponseBundleZipSafetyReport.zipOpenSucceeded
    ownerResponseBundleZipEntryCount = [int]$ownerResponseBundleZipSafetyReport.entryCount
    ownerResponseBundleZipDirectoryEntryCount = [int]$ownerResponseBundleZipSafetyReport.directoryEntryCount
    ownerResponseBundleZipUnsafeEntryCount = [int]$ownerResponseBundleZipSafetyReport.unsafeEntryCount
    ownerResponseBundleZipDuplicateEntryCount = [int]$ownerResponseBundleZipSafetyReport.duplicateEntryCount
    ownerResponseBundleZipSafetyErrors = @($ownerResponseBundleZipSafetyReport.safetyErrors)
    ownerResponseBundleZipUnsafeEntries = @($ownerResponseBundleZipSafetyReport.unsafeEntries)
    ownerResponseBundleZipDuplicateEntries = @($ownerResponseBundleZipSafetyReport.duplicateEntries)
    acceptanceBundleDir = $acceptanceBundlePath
    contractFixtureMode = [bool]$ContractFixtureMode
    requireAllEvidence = [bool]$RequireAllEvidence
    readyAreaCount = [int]$readyAreaCount
    missingFileCount = [int]$missingFileCount
    allEvidenceReady = [bool]$allEvidenceReady
    semanticPreflightGateRun = [bool]$semanticPreflightGateRun
    semanticPreflightGatePassed = [bool]$semanticPreflightGatePassed
    semanticPreflightGateBlockedAcceptance = [bool]$semanticPreflightGateBlockedAcceptance
    semanticPreflightErrorMessage = $semanticPreflightErrorMessage
    semanticPreflightManifestPath = if (Test-Path $semanticPreflightManifestPath) { Convert-ToEvidenceRelativePath $semanticPreflightManifestPath } else { "" }
    semanticPreflightReportPath = if (Test-Path $semanticPreflightReportPath) { Convert-ToEvidenceRelativePath $semanticPreflightReportPath } else { "" }
    semanticPreflightSourceKind = $semanticPreflightSourceKind
    semanticPreflightStatus = $semanticPreflightStatus
    semanticPreflightReadyForAcceptanceCandidate = [bool]$semanticPreflightReadyForAcceptanceCandidate
    semanticPreflightFailCount = [int]$semanticPreflightFailCount
    semanticPreflightWarnCount = [int]$semanticPreflightWarnCount
    semanticPreflightMissingRequiredFileCount = [int]$semanticPreflightMissingRequiredFileCount
    semanticPreflightFixtureSignalCount = [int]$semanticPreflightFixtureSignalCount
    semanticPreflightPlaceholderSignalCount = [int]$semanticPreflightPlaceholderSignalCount
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
    "| Semantic preflight gate run | $semanticPreflightGateRun |",
    "| Semantic preflight gate passed | $semanticPreflightGatePassed |",
    "| Semantic preflight status | $(Format-MarkdownCell $semanticPreflightStatus) |",
    "| Semantic preflight fail count | $semanticPreflightFailCount |",
    "| Semantic preflight missing required files | $semanticPreflightMissingRequiredFileCount |",
    "| Semantic preflight blocked acceptance | $semanticPreflightGateBlockedAcceptance |",
    "| Acceptance run | $acceptanceRun |",
    "| All external evidence accepted | $allExternalEvidenceAccepted |",
    "| Real host-project evidence accepted | $realHostProjectEvidenceAccepted |",
    "| Contract fixture mode | $([bool]$ContractFixtureMode) |",
    "| Production output boundary | $(Format-MarkdownCell $productionOutputBoundary) |",
    "| Owner response bundle zip | $(Format-MarkdownCell $OwnerResponseBundleZipPath) |",
    "| Owner response bundle zip inspected | $($ownerResponseBundleZipSafetyReport.inspected) |",
    "| Owner response bundle zip safe | $($ownerResponseBundleZipSafetyReport.safe) |",
    "| Owner response bundle zip entries | $($ownerResponseBundleZipSafetyReport.entryCount) |",
    "| Owner response bundle zip unsafe entries | $($ownerResponseBundleZipSafetyReport.unsafeEntryCount) |",
    "| Owner response bundle zip duplicate entries | $($ownerResponseBundleZipSafetyReport.duplicateEntryCount) |",
    "| Expanded owner response bundle | $(Format-MarkdownCell $expandedOwnerResponseBundleDir) |",
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
