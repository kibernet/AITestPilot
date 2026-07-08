[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$KitDir,
    [string]$ManifestPath,
    [string]$ReportPath,
    [string]$ZipPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($KitDir)) {
    $KitDir = Join-Path $EvidenceBundleDir "production-handoff-owner-response-bundle-kit"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-handoff-owner-response-bundle-kit-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-handoff-owner-response-bundle-kit.md"
}

if ([string]::IsNullOrWhiteSpace($ZipPath)) {
    $ZipPath = Join-Path $EvidenceBundleDir "production-handoff-owner-response-bundle-kit.zip"
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

function Convert-ToRelativePath {
    param(
        [string]$Root,
        [string]$Path
    )

    $rootUri = [System.Uri](([System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'))
    $pathUri = [System.Uri]([System.IO.Path]::GetFullPath($Path))
    return [System.Uri]::UnescapeDataString($rootUri.MakeRelativeUri($pathUri).ToString()).Replace("/", "\")
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

function Join-TextList {
    param([object[]]$Values)

    $items = @($Values | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($items.Count -eq 0) {
        return "(none)"
    }

    return [string]::Join(", ", $items)
}

function Add-KitCheck {
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
$kitPath = Assert-PathUnderRepo $KitDir "KitDir"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"
$zipFullPath = Assert-PathUnderRepo $ZipPath "ZipPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if (Test-Path $kitPath) {
    Remove-Item -LiteralPath $kitPath -Recurse -Force
}
if (Test-Path $zipFullPath) {
    Remove-Item -LiteralPath $zipFullPath -Force
}

New-Item -ItemType Directory -Force $kitPath | Out-Null

$ownerInputRequest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-owner-input-request-pack-manifest.json") "Production handoff owner input request pack manifest"
$externalEvidenceInbox = Read-JsonFile (Join-Path $evidenceBundlePath "production-external-evidence-inbox-manifest.json") "Production external evidence inbox manifest"
$ownerResponseBundleProbe = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-owner-response-bundle-probe-manifest.json") "Production handoff owner response bundle probe manifest"
$handoffExport = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-export-manifest.json") "Production handoff export manifest"

$ownerInputs = @(Convert-ToArray (Get-JsonValue $ownerInputRequest "ownerInputs" @()))
$ownerContactCount = Convert-ToInt (Get-JsonValue $ownerInputRequest "ownerActionCount" 0)
$missingOwnerContactCount = Convert-ToInt (Get-JsonValue $ownerInputRequest "missingOwnerContactCount" 0)
$requiredEvidenceFileCount = Convert-ToInt (Get-JsonValue $externalEvidenceInbox "requiredEvidenceFileCount" 0)
$missingRequiredFileCount = Convert-ToInt (Get-JsonValue $ownerInputRequest "missingRequiredFileCount" 0)

$templatePath = Join-Path $kitPath "owner-response-bundle-template"
$ownerMiniKitRootPath = Join-Path $kitPath "owner-response-mini-kits"
$driverDir = Join-Path $templatePath "production-driver-evidence"
$luaDir = Join-Path $templatePath "production-lua-evidence"
$liveDir = Join-Path $templatePath "live-smoke-evidence"
New-Item -ItemType Directory -Force $driverDir, $luaDir, $liveDir | Out-Null

$directoryByArea = @{
    production_driver_binding = "production-driver-evidence"
    production_lua_patch_evidence = "production-lua-evidence"
    live_model_endpoint_smoke = "live-smoke-evidence"
}

$rosterEntries = @()
$areaSpecs = @()
foreach ($item in $ownerInputs) {
    $owner = [string](Get-JsonValue $item "owner" "")
    $area = [string](Get-JsonValue $item "area" "")
    $directory = if ($directoryByArea.ContainsKey($area)) { [string]$directoryByArea[$area] } else { [string](Get-JsonValue $item "inboxDirectory" "") }
    $requiredFiles = @(Convert-ToArray (Get-JsonValue $item "requiredEvidenceFiles" @()) | ForEach-Object { [string]$_ })

    $rosterEntries += [ordered]@{
        owner = $owner
        area = $area
        contactSlug = [string](Get-JsonValue $item "owner" "")
        emailAddress = ""
        configured = $false
        notes = "Fill with the real owner mailbox before dispatch."
    }

    $areaSpecs += [ordered]@{
        owner = $owner
        area = $area
        directory = $directory
        requiredEvidenceFiles = @($requiredFiles)
        requiredFileCount = [int]$requiredFiles.Count
        hardValidationCommand = [string](Get-JsonValue $item "hardValidationCommand" "")
        acceptanceWrapperCommand = [string](Get-JsonValue $item "acceptanceWrapperCommand" "")
    }
}

$contactRosterPath = Join-Path $templatePath "owner-contact-roster.json"
$contactRoster = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_contact_roster.v1"
    status = "PENDING_OWNER_EMAILS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    ownerContactCount = [int]$ownerContactCount
    configuredContactCount = 0
    fixtureOnly = $false
    entries = @($rosterEntries)
}
$contactRoster | ConvertTo-Json -Depth 12 | Set-Content -Path $contactRosterPath -Encoding UTF8

$responseManifestPath = Join-Path $templatePath "owner-response-bundle-manifest.json"
$responseManifest = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_owner_response_bundle.v1"
    status = "PENDING_OWNER_RESPONSE"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    ownerContactCount = [int]$ownerContactCount
    configuredContactCount = 0
    requiredEvidenceFileCount = [int]$requiredEvidenceFileCount
    presentEvidenceFileCount = 0
    fixtureOnly = $false
    productionOutputBoundary = "owner_response_bundle_template_only"
    directories = @($areaSpecs | ForEach-Object { [string]$_["directory"] })
}
$responseManifest | ConvertTo-Json -Depth 10 | Set-Content -Path $responseManifestPath -Encoding UTF8

foreach ($areaSpec in $areaSpecs) {
    $areaDir = Join-Path $templatePath ([string]$areaSpec["directory"])
    New-Item -ItemType Directory -Force $areaDir | Out-Null

    $requiredFilesPath = Join-Path $areaDir "required-files.json"
    ([ordered]@{
        schemaVersion = "aitestpilot.production_handoff_owner_response_bundle_required_files.v1"
        owner = [string]$areaSpec["owner"]
        area = [string]$areaSpec["area"]
        directory = [string]$areaSpec["directory"]
        requiredEvidenceFiles = @($areaSpec["requiredEvidenceFiles"])
        requiredFileCount = [int]$areaSpec["requiredFileCount"]
        hardValidationCommand = [string]$areaSpec["hardValidationCommand"]
    }) | ConvertTo-Json -Depth 8 | Set-Content -Path $requiredFilesPath -Encoding UTF8

    $areaReadmeLines = @(
        "# Owner Response Evidence Directory",
        "",
        "Owner: $($areaSpec["owner"])",
        "Area: $($areaSpec["area"])",
        "",
        "Copy these required files into this directory:",
        ""
    )
    foreach ($fileName in @($areaSpec["requiredEvidenceFiles"])) {
        $areaReadmeLines += "- $fileName"
    }
    $areaReadmeLines += @(
        "",
        "After filling all response directories, run verify-owner-response-bundle.ps1 from the kit root.",
        "Do not include fixture evidence in a production response bundle."
    )
    $areaReadmeLines | Set-Content -Path (Join-Path $areaDir "README.md") -Encoding UTF8
}

$verifyScriptPath = Join-Path $kitPath "verify-owner-response-bundle.ps1"
$verifyScript = @'
[CmdletBinding()]
param(
    [string]$BundleDir = (Join-Path $PSScriptRoot "owner-response-bundle-template"),
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "Missing file: $Path" }
    return Get-Content -Path $Path -Encoding UTF8 -Raw | ConvertFrom-Json
}

function Convert-ToArray {
    param([object]$Value)
    if ($null -eq $Value) { return @() }
    return @($Value)
}

function Get-JsonValue {
    param([object]$Object, [string]$Name, [object]$DefaultValue = $null)
    if ($null -eq $Object) { return $DefaultValue }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $DefaultValue }
    return $property.Value
}

function Test-EmailAddress {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return [bool]($Value.Trim() -match '^[^@\s]+@[^@\s]+\.[^@\s]+$')
}

$bundlePath = [System.IO.Path]::GetFullPath($BundleDir)
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $bundlePath "owner-response-bundle-preflight.json"
}

$roster = Read-JsonFile (Join-Path $bundlePath "owner-contact-roster.json")
$manifest = Read-JsonFile (Join-Path $bundlePath "owner-response-bundle-manifest.json")

$configuredContacts = 0
$invalidContacts = 0
foreach ($entry in @(Convert-ToArray $roster.entries)) {
    if ([bool](Get-JsonValue $entry "configured" $false) -and (Test-EmailAddress ([string](Get-JsonValue $entry "emailAddress" "")))) {
        $configuredContacts += 1
    } else {
        $invalidContacts += 1
    }
}

$areaStatuses = @()
$requiredFileCount = 0
$presentFileCount = 0
foreach ($requiredFileSpec in @(Get-ChildItem -Path $bundlePath -Recurse -Filter required-files.json)) {
    $spec = Read-JsonFile $requiredFileSpec.FullName
    $areaDir = Split-Path $requiredFileSpec.FullName -Parent
    $requiredFiles = @(Convert-ToArray (Get-JsonValue $spec "requiredEvidenceFiles" @()) | ForEach-Object { [string]$_ })
    $presentFiles = @()
    $missingFiles = @()
    foreach ($fileName in $requiredFiles) {
        $requiredFileCount += 1
        if (Test-Path (Join-Path $areaDir $fileName)) {
            $presentFiles += $fileName
            $presentFileCount += 1
        } else {
            $missingFiles += $fileName
        }
    }
    $areaStatuses += [ordered]@{
        owner = [string](Get-JsonValue $spec "owner" "")
        area = [string](Get-JsonValue $spec "area" "")
        directory = [string](Get-JsonValue $spec "directory" "")
        requiredFileCount = [int]$requiredFiles.Count
        presentFileCount = [int]$presentFiles.Count
        missingFileCount = [int]$missingFiles.Count
        presentFiles = @($presentFiles)
        missingFiles = @($missingFiles)
    }
}

$status = if ($invalidContacts -eq 0 -and $requiredFileCount -gt 0 -and $presentFileCount -eq $requiredFileCount) {
    "READY_FOR_IMPORT"
} else {
    "INCOMPLETE_OWNER_RESPONSE"
}

$result = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_owner_response_bundle_preflight.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    bundleDir = $bundlePath
    sourceManifestStatus = [string](Get-JsonValue $manifest "status" "")
    ownerContactCount = [int](Get-JsonValue $roster "ownerContactCount" 0)
    configuredContactCount = [int]$configuredContacts
    invalidContactCount = [int]$invalidContacts
    requiredEvidenceFileCount = [int]$requiredFileCount
    presentEvidenceFileCount = [int]$presentFileCount
    missingEvidenceFileCount = [int]($requiredFileCount - $presentFileCount)
    areaStatuses = @($areaStatuses)
    semanticPreflightRecommendedBeforeAutoAcceptance = $true
    selfContainedSemanticPreflightCommand = '.\run-semantic-preflight.ps1 -OwnerResponseBundleDir "path\to\filled-owner-response-bundle"'
    selfContainedSemanticPreflightZipCommand = '.\run-semantic-preflight.ps1 -OwnerResponseBundleZipPath "path\to\filled-owner-response-bundle.zip"'
    semanticPreflightCommand = '.\tools\Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1 -OwnerResponseBundleDir "path\to\filled-owner-response-bundle"'
    semanticPreflightZipCommand = '.\tools\Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1 -OwnerResponseBundleZipPath "path\to\filled-owner-response-bundle.zip"'
    autoAcceptanceRequiresSemanticPreflightCandidate = $true
    semanticPreflightCandidateField = "readyForAcceptanceCandidate"
    semanticPreflightStatusField = "semanticPreflightStatus"
    semanticPreflightFailCountField = "semanticFailCount"
}

$result | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputPath -Encoding UTF8
if ($status -ne "READY_FOR_IMPORT") {
    throw "Owner response bundle is incomplete. See $OutputPath"
}

Write-Output "PASS owner response bundle preflight: $OutputPath"
'@
$verifyScript | Set-Content -Path $verifyScriptPath -Encoding UTF8

$importScriptPath = Join-Path $kitPath "import-owner-response-bundle.ps1"
$importScript = @'
[CmdletBinding()]
param(
    [string]$ResponseBundleDir,
    [string]$EvidenceBundleDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$RepoRoot,
    [switch]$RunReadiness
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-FullPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

if ([string]::IsNullOrWhiteSpace($ResponseBundleDir)) {
    throw "-ResponseBundleDir is required."
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Resolve-FullPath (Join-Path $PSScriptRoot "..\..\..")
}

$responsePath = Resolve-FullPath $ResponseBundleDir
$evidencePath = Resolve-FullPath $EvidenceBundleDir
$repoPath = Resolve-FullPath $RepoRoot

Copy-Item -LiteralPath (Join-Path $responsePath "owner-contact-roster.json") -Destination (Join-Path $evidencePath "production-handoff-contact-roster.json") -Force

$inboxPath = Join-Path $evidencePath "production-external-evidence-inbox"
foreach ($directory in @("production-driver-evidence", "production-lua-evidence", "live-smoke-evidence")) {
    $source = Join-Path $responsePath $directory
    $destination = Join-Path $inboxPath $directory
    if (-not (Test-Path $source)) { throw "Missing response bundle directory: $source" }
    New-Item -ItemType Directory -Force $destination | Out-Null
    Get-ChildItem -LiteralPath $source -File | Where-Object { $_.Name -ne "README.md" -and $_.Name -ne "required-files.json" } | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $destination $_.Name) -Force
    }
}

if ($RunReadiness) {
    & (Join-Path $repoPath "tools\Invoke-AITestPilotProductionHandoffContactReadiness.ps1") -EvidenceBundleDir $evidencePath -ContactRosterPath (Join-Path $evidencePath "production-handoff-contact-roster.json")
    & (Join-Path $repoPath "tools\Invoke-AITestPilotProductionHandoffSendReadiness.ps1") -EvidenceBundleDir $evidencePath
    & (Join-Path $repoPath "tools\Invoke-AITestPilotProductionExternalEvidenceInbox.ps1") -EvidenceBundleDir $evidencePath -InboxDir $inboxPath
    & (Join-Path $repoPath "tools\Invoke-AITestPilotProductionHandoffOwnerUnblockPack.ps1") -EvidenceBundleDir $evidencePath
}

Write-Output "Imported owner response bundle into $evidencePath"
'@
$importScript | Set-Content -Path $importScriptPath -Encoding UTF8

$miniKitMergeScriptPath = Join-Path $kitPath "merge-owner-mini-kits.ps1"
$miniKitMergeScript = @'
[CmdletBinding()]
param(
    [string[]]$MiniKitDir,
    [string]$FullBundleDir = (Join-Path $PSScriptRoot "owner-response-bundle-template"),
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "Missing file: $Path" }
    return Get-Content -Path $Path -Encoding UTF8 -Raw | ConvertFrom-Json
}

function Convert-ToArray {
    param([object]$Value)
    if ($null -eq $Value) { return @() }
    return @($Value)
}

function Get-JsonValue {
    param([object]$Object, [string]$Name, [object]$DefaultValue = $null)
    if ($null -eq $Object) { return $DefaultValue }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $DefaultValue }
    return $property.Value
}

if ($null -eq $MiniKitDir -or $MiniKitDir.Count -eq 0) {
    throw "-MiniKitDir is required. Pass one or more returned owner mini kit directories."
}

$fullPath = [System.IO.Path]::GetFullPath($FullBundleDir)
if (-not (Test-Path $fullPath)) {
    throw "FullBundleDir is missing: $fullPath"
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $fullPath "owner-mini-kit-merge-manifest.json"
}

$fullRosterPath = Join-Path $fullPath "owner-contact-roster.json"
$fullRoster = Read-JsonFile $fullRosterPath
$fullEntries = @(Convert-ToArray (Get-JsonValue $fullRoster "entries" @()))
$mergedOwners = @()
$copiedFiles = @()

foreach ($miniKitDirValue in $MiniKitDir) {
    $miniPath = [System.IO.Path]::GetFullPath($miniKitDirValue)
    if (-not (Test-Path $miniPath)) {
        throw "Mini kit directory is missing: $miniPath"
    }

    $miniRoster = Read-JsonFile (Join-Path $miniPath "owner-contact-roster.json")
    foreach ($miniEntry in @(Convert-ToArray (Get-JsonValue $miniRoster "entries" @()))) {
        $owner = [string](Get-JsonValue $miniEntry "owner" "")
        $area = [string](Get-JsonValue $miniEntry "area" "")
        for ($i = 0; $i -lt $fullEntries.Count; $i += 1) {
            if ([string](Get-JsonValue $fullEntries[$i] "owner" "") -eq $owner -and
                [string](Get-JsonValue $fullEntries[$i] "area" "") -eq $area) {
                $fullEntries[$i] = $miniEntry
            }
        }
    }

    foreach ($requiredFileSpec in @(Get-ChildItem -LiteralPath $miniPath -Recurse -Filter required-files.json)) {
        $spec = Read-JsonFile $requiredFileSpec.FullName
        $directory = [string](Get-JsonValue $spec "directory" "")
        if ([string]::IsNullOrWhiteSpace($directory)) {
            throw "Required files manifest is missing directory: $($requiredFileSpec.FullName)"
        }

        $sourceDir = Split-Path $requiredFileSpec.FullName -Parent
        $destinationDir = Join-Path $fullPath $directory
        if (-not (Test-Path $destinationDir)) {
            throw "Full bundle directory is missing for mini kit area: $destinationDir"
        }

        Get-ChildItem -LiteralPath $sourceDir -File |
            Where-Object { $_.Name -ne "README.md" -and $_.Name -ne "required-files.json" } |
            ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $destinationDir $_.Name) -Force
                $copiedFiles += [ordered]@{
                    owner = [string](Get-JsonValue $spec "owner" "")
                    area = [string](Get-JsonValue $spec "area" "")
                    directory = $directory
                    fileName = $_.Name
                }
            }

        $mergedOwners += [ordered]@{
            owner = [string](Get-JsonValue $spec "owner" "")
            area = [string](Get-JsonValue $spec "area" "")
            directory = $directory
        }
    }
}

$fullRoster.entries = @($fullEntries)
$fullRoster | ConvertTo-Json -Depth 12 | Set-Content -Path $fullRosterPath -Encoding UTF8

$result = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_owner_response_bundle_mini_kit_merge.v1"
    status = "MERGED_OWNER_MINI_KITS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    fullBundleDir = $fullPath
    miniKitDirCount = [int]$MiniKitDir.Count
    mergedOwnerCount = [int]$mergedOwners.Count
    copiedFileCount = [int]$copiedFiles.Count
    mergedOwners = @($mergedOwners)
    copiedFiles = @($copiedFiles)
    nextVerificationCommand = '.\verify-owner-response-bundle.ps1 -BundleDir "path\to\owner-response-bundle-template"'
    semanticPreflightRecommendedBeforeAutoAcceptance = $true
}

$result | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputPath -Encoding UTF8
Write-Output "Merged owner mini kits into $fullPath"
Write-Output "Owner mini kit merge manifest: $OutputPath"
'@
$miniKitMergeScript | Set-Content -Path $miniKitMergeScriptPath -Encoding UTF8

$selfContainedSemanticPreflightHelperPath = "run-semantic-preflight.ps1"
$selfContainedSemanticPreflightCorePath = "semantic-preflight/Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1"
$selfContainedOwnerResponseBundleSemanticPreflightCommand = '.\run-semantic-preflight.ps1 -OwnerResponseBundleDir "path\to\filled-owner-response-bundle"'
$selfContainedOwnerResponseBundleZipSemanticPreflightCommand = '.\run-semantic-preflight.ps1 -OwnerResponseBundleZipPath "path\to\filled-owner-response-bundle.zip"'
$selfContainedSemanticPreflightHelperFullPath = Join-Path $kitPath $selfContainedSemanticPreflightHelperPath
$selfContainedSemanticPreflightCoreFullPath = Join-Path $kitPath ($selfContainedSemanticPreflightCorePath.Replace("/", "\"))
$semanticPreflightSourcePath = Join-Path $repoRoot "tools\Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1"
if (-not (Test-Path $semanticPreflightSourcePath)) {
    throw "Semantic preflight source script is missing: $semanticPreflightSourcePath"
}
New-Item -ItemType Directory -Force (Split-Path $selfContainedSemanticPreflightCoreFullPath -Parent) | Out-Null
Copy-Item -LiteralPath $semanticPreflightSourcePath -Destination $selfContainedSemanticPreflightCoreFullPath -Force

$selfContainedSemanticPreflightHelperScript = @'
[CmdletBinding()]
param(
    [string]$OwnerResponseBundleDir,
    [string]$OwnerResponseBundleZipPath,
    [string]$OutputDir = (Join-Path $PSScriptRoot "semantic-preflight-output"),
    [switch]$ContractFixtureMode,
    [switch]$AllowNonCandidate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not [string]::IsNullOrWhiteSpace($OwnerResponseBundleDir) -and
    -not [string]::IsNullOrWhiteSpace($OwnerResponseBundleZipPath)) {
    throw "Provide only one of -OwnerResponseBundleDir or -OwnerResponseBundleZipPath."
}

if ([string]::IsNullOrWhiteSpace($OwnerResponseBundleDir) -and
    [string]::IsNullOrWhiteSpace($OwnerResponseBundleZipPath) -and
    -not [string]::IsNullOrWhiteSpace($env:AITESTPILOT_OWNER_RESPONSE_BUNDLE_ZIP_PATH)) {
    $OwnerResponseBundleZipPath = $env:AITESTPILOT_OWNER_RESPONSE_BUNDLE_ZIP_PATH
}

if ([string]::IsNullOrWhiteSpace($OwnerResponseBundleDir) -and
    [string]::IsNullOrWhiteSpace($OwnerResponseBundleZipPath)) {
    throw "Provide -OwnerResponseBundleDir, -OwnerResponseBundleZipPath, or AITESTPILOT_OWNER_RESPONSE_BUNDLE_ZIP_PATH."
}

$preflightScript = Join-Path $PSScriptRoot "semantic-preflight\Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1"
if (-not (Test-Path $preflightScript)) {
    throw "Bundled semantic preflight script is missing: $preflightScript"
}

$outputPath = [System.IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Force $outputPath | Out-Null

$manifestPath = Join-Path $outputPath "production-external-evidence-semantic-preflight-manifest.json"
$reportPath = Join-Path $outputPath "production-external-evidence-semantic-preflight.md"
$preflightParams = @{
    EvidenceBundleDir = $outputPath
    ManifestPath = $manifestPath
    ReportPath = $reportPath
}
if (-not [string]::IsNullOrWhiteSpace($OwnerResponseBundleDir)) {
    $preflightParams["OwnerResponseBundleDir"] = $OwnerResponseBundleDir
}
if (-not [string]::IsNullOrWhiteSpace($OwnerResponseBundleZipPath)) {
    $preflightParams["OwnerResponseBundleZipPath"] = $OwnerResponseBundleZipPath
}
if ([bool]$ContractFixtureMode) {
    $preflightParams["ContractFixtureMode"] = $true
}

& $preflightScript @preflightParams | Out-Null

if (-not (Test-Path $manifestPath)) {
    throw "Semantic preflight manifest was not produced: $manifestPath"
}

$manifest = Get-Content -Path $manifestPath -Encoding UTF8 -Raw | ConvertFrom-Json
Write-Output "Semantic preflight manifest: $manifestPath"
Write-Output "Semantic preflight report: $reportPath"
Write-Output "Semantic preflight status: $($manifest.semanticPreflightStatus)"
Write-Output "Ready for acceptance candidate: $($manifest.readyForAcceptanceCandidate)"
Write-Output "Semantic FAIL count: $($manifest.semanticFailCount)"

if (-not [bool]$AllowNonCandidate -and
    (-not [bool]$manifest.readyForAcceptanceCandidate -or [int]$manifest.semanticFailCount -ne 0)) {
    throw "Semantic preflight did not produce an auto-acceptance candidate. Review $reportPath before running acceptance."
}

Write-Output "PASS AI TestPilot self-contained semantic preflight helper"
'@
$selfContainedSemanticPreflightHelperScript | Set-Content -Path $selfContainedSemanticPreflightHelperFullPath -Encoding UTF8

$ownerResponseBundleAutoAcceptanceCommand = '.\tools\Invoke-AITestPilotProductionExternalEvidenceAutoAcceptance.ps1 -OwnerResponseBundleDir "path\to\filled-owner-response-bundle" -RequireAllEvidence'
$ownerResponseBundleZipAutoAcceptanceCommand = '.\tools\Invoke-AITestPilotProductionExternalEvidenceAutoAcceptance.ps1 -OwnerResponseBundleZipPath "path\to\filled-owner-response-bundle.zip" -RequireAllEvidence'
$ownerResponseBundleSemanticPreflightCommand = '.\tools\Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1 -OwnerResponseBundleDir "path\to\filled-owner-response-bundle"'
$ownerResponseBundleZipSemanticPreflightCommand = '.\tools\Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1 -OwnerResponseBundleZipPath "path\to\filled-owner-response-bundle.zip"'
$ownerResponseBundleZipEnvironmentVariable = "AITESTPILOT_OWNER_RESPONSE_BUNDLE_ZIP_PATH"
$productionDriverEvidenceExportHelperPath = "production-driver-binding-kit/Export-ProductionDriverEvidenceBundle.ps1"
$productionDriverEvidenceExportHelperCommand = '.\production-driver-binding-kit\Export-ProductionDriverEvidenceBundle.ps1 -EvidenceBundleDir "path\to\release-evidence"'
$productionDriverEvidenceExportZipPath = "production-driver-evidence-export/production-driver-evidence.zip"
$productionLuaEvidenceExportHelperPath = "production-lua-patch-evidence-kit/Export-ProductionLuaPatchEvidenceBundle.ps1"
$productionLuaEvidenceExportHelperCommand = '.\production-lua-patch-evidence-kit\Export-ProductionLuaPatchEvidenceBundle.ps1 -EvidenceBundleDir "path\to\release-evidence" -ProductionLuaEvidenceDir "path\to\production-lua-evidence"'
$productionLuaEvidenceExportZipPath = "production-lua-evidence-export/production-lua-evidence.zip"
$liveModelSmokeEvidenceExportHelperPath = "live-model-endpoint-config-kit/Export-LiveModelEndpointSmokeEvidenceBundle.ps1"
$liveModelSmokeEvidenceExportHelperCommand = '.\live-model-endpoint-config-kit\Export-LiveModelEndpointSmokeEvidenceBundle.ps1 -EvidenceBundleDir "path\to\release-evidence" -LiveModelEndpointSmokeEvidenceDir "path\to\live-smoke-evidence"'
$liveModelSmokeEvidenceExportZipPath = "live-model-endpoint-smoke-evidence-export/live-smoke-evidence.zip"

New-Item -ItemType Directory -Force $ownerMiniKitRootPath | Out-Null
$ownerMiniKitRootReadmePath = Join-Path $ownerMiniKitRootPath "README.md"
$ownerMiniKitEntries = @()
foreach ($areaSpec in $areaSpecs) {
    $owner = [string]$areaSpec["owner"]
    $area = [string]$areaSpec["area"]
    $directory = [string]$areaSpec["directory"]
    $ownerMiniKitPath = Join-Path $ownerMiniKitRootPath $owner
    $ownerMiniKitEvidenceDir = Join-Path $ownerMiniKitPath $directory
    $ownerMiniKitZipPath = Join-Path $ownerMiniKitRootPath "$owner.zip"

    if (Test-Path $ownerMiniKitPath) {
        Remove-Item -LiteralPath $ownerMiniKitPath -Recurse -Force
    }
    if (Test-Path $ownerMiniKitZipPath) {
        Remove-Item -LiteralPath $ownerMiniKitZipPath -Force
    }

    New-Item -ItemType Directory -Force $ownerMiniKitEvidenceDir | Out-Null

    ([ordered]@{
        schemaVersion = "aitestpilot.production_handoff_contact_roster.v1"
        status = "PENDING_OWNER_EMAIL"
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
        ownerContactCount = 1
        configuredContactCount = 0
        fixtureOnly = $false
        entries = @([ordered]@{
                owner = $owner
                area = $area
                contactSlug = $owner
                emailAddress = ""
                configured = $false
                notes = "Fill with the real owner mailbox before returning this mini kit."
            })
    }) | ConvertTo-Json -Depth 12 | Set-Content -Path (Join-Path $ownerMiniKitPath "owner-contact-roster.json") -Encoding UTF8

    ([ordered]@{
        schemaVersion = "aitestpilot.production_handoff_owner_response_bundle.v1"
        status = "PENDING_OWNER_RESPONSE"
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
        ownerContactCount = 1
        configuredContactCount = 0
        requiredEvidenceFileCount = [int]$areaSpec["requiredFileCount"]
        presentEvidenceFileCount = 0
        fixtureOnly = $false
        productionOutputBoundary = "owner_response_mini_kit_template_only"
        directories = @($directory)
    }) | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $ownerMiniKitPath "owner-response-bundle-manifest.json") -Encoding UTF8

    ([ordered]@{
        schemaVersion = "aitestpilot.production_handoff_owner_response_bundle_required_files.v1"
        owner = $owner
        area = $area
        directory = $directory
        requiredEvidenceFiles = @($areaSpec["requiredEvidenceFiles"])
        requiredFileCount = [int]$areaSpec["requiredFileCount"]
        hardValidationCommand = [string]$areaSpec["hardValidationCommand"]
    }) | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $ownerMiniKitEvidenceDir "required-files.json") -Encoding UTF8

    $miniEvidenceReadmeLines = @(
        "# Owner Mini Kit Evidence Directory",
        "",
        "Owner: $owner",
        "Area: $area",
        "",
        "Copy only these required files into this directory:",
        ""
    )
    foreach ($fileName in @($areaSpec["requiredEvidenceFiles"])) {
        $miniEvidenceReadmeLines += "- $fileName"
    }
    $miniEvidenceReadmeLines += @(
        "",
        "Do not include fixture evidence in a production response."
    )
    $miniEvidenceReadmeLines | Set-Content -Path (Join-Path $ownerMiniKitEvidenceDir "README.md") -Encoding UTF8

    $miniReturnInstructionsLines = @(
        "# Owner Mini Kit Return Instructions",
        "",
        "Owner: $owner",
        "Area: $area",
        "",
        "1. Fill owner-contact-roster.json with the real owner mailbox.",
        "2. Copy the required files into $directory.",
        "3. Return this folder or $owner.zip to the operator.",
        "",
        "This mini kit does not include the verifier. Verification happens after the operator merges the returned mini kit into the full owner response bundle kit.",
        "",
        "Operator merge after return, from the full production-handoff-export\production-handoff-owner-response-bundle-kit directory:",
        "",
        '```powershell',
        ('.\merge-owner-mini-kits.ps1 -MiniKitDir ".\owner-response-mini-kits\{0}" -FullBundleDir ".\owner-response-bundle-template"' -f $owner),
        '.\verify-owner-response-bundle.ps1 -BundleDir ".\owner-response-bundle-template"',
        '```',
        "",
        "Semantic preflight must still run on the merged full owner response bundle before auto acceptance."
    )
    $miniReturnInstructionsLines | Set-Content -Path (Join-Path $ownerMiniKitPath "RETURN-INSTRUCTIONS.md") -Encoding UTF8

    Compress-Archive -Path (Join-Path $ownerMiniKitPath "*") -DestinationPath $ownerMiniKitZipPath -Force
    if (-not (Test-Path $ownerMiniKitZipPath)) {
        throw "Owner mini kit zip was not produced: $ownerMiniKitZipPath"
    }

    $ownerMiniKitEntries += [ordered]@{
        owner = $owner
        area = $area
        directory = $directory
        miniKitRelativePath = "owner-response-mini-kits/$owner"
        miniKitZipRelativePath = "owner-response-mini-kits/$owner.zip"
        requiredFileCount = [int]$areaSpec["requiredFileCount"]
        requiredEvidenceFiles = @($areaSpec["requiredEvidenceFiles"])
    }
}

$ownerMiniKitRootReadmeLines = @(
    "# Owner Response Mini Kits",
    "",
    "These per-owner mini kits split the combined owner-response-bundle-template into one return folder per external owner.",
    "",
    "Use them when owners should receive only their own required files. After returns arrive, merge them back into owner-response-bundle-template before semantic preflight and auto acceptance.",
    "",
    "Merge command:",
    "",
    '```powershell',
    '.\merge-owner-mini-kits.ps1 -MiniKitDir ".\owner-response-mini-kits\host_project_gameplay_qa", ".\owner-response-mini-kits\host_project_lua_owner", ".\owner-response-mini-kits\host_project_ai_platform" -FullBundleDir ".\owner-response-bundle-template"',
    '```',
    "",
    "| Owner | Area | Mini kit | Zip | Required files |",
    "| --- | --- | --- | --- | ---: |"
)
foreach ($entry in $ownerMiniKitEntries) {
    $ownerMiniKitRootReadmeLines += ("| {0} | {1} | {2} | {3} | {4} |" -f `
            (Format-MarkdownCell $entry["owner"]),
        (Format-MarkdownCell $entry["area"]),
        (Format-MarkdownCell $entry["miniKitRelativePath"]),
        (Format-MarkdownCell $entry["miniKitZipRelativePath"]),
        $entry["requiredFileCount"])
}
$ownerMiniKitRootReadmeLines += @(
    "",
    "Mini kits do not accept production evidence and do not send email. They only reduce the return packet each owner needs to fill."
)
$ownerMiniKitRootReadmeLines | Set-Content -Path $ownerMiniKitRootReadmePath -Encoding UTF8

$kitReadmePath = Join-Path $kitPath "README.md"
$kitReadmeLines = @(
    "# AI TestPilot Owner Response Bundle Kit",
    "",
    "This kit is the fillable owner response package for contacts and returned production evidence.",
    "Run sibling export-helper commands from the production-handoff-export root, not from this kit subdirectory.",
    "",
    "Workflow:",
    "",
    "1. Copy owner-response-bundle-template to a working folder.",
    "2. Fill owner-contact-roster.json with real owner mailboxes.",
    "3. Production driver owners can run $productionDriverEvidenceExportHelperPath after production-bound readiness passes: $productionDriverEvidenceExportHelperCommand",
    "4. Production Lua owners can run $productionLuaEvidenceExportHelperPath after real Lua patch readiness passes: $productionLuaEvidenceExportHelperCommand",
    "5. Live model owners can run $liveModelSmokeEvidenceExportHelperPath after direct live provider smoke passes: $liveModelSmokeEvidenceExportHelperCommand",
    "6. Copy required evidence files into production-driver-evidence, production-lua-evidence, and live-smoke-evidence.",
    "7. Run verify-owner-response-bundle.ps1 against the filled bundle.",
    "8. Operator-side semantic preflight from a returned folder with the bundled helper: $selfContainedOwnerResponseBundleSemanticPreflightCommand",
    "9. Operator-side semantic preflight from a returned zip with the bundled helper: $selfContainedOwnerResponseBundleZipSemanticPreflightCommand",
    "10. Confirm the semantic preflight manifest reports readyForAcceptanceCandidate=true, semanticPreflightStatus=READY_FOR_AUTO_ACCEPTANCE_CANDIDATE or WARN_READY_FOR_OPERATOR_ACCEPTANCE, and semanticFailCount=0 before auto acceptance.",
    "11. Repo-root semantic preflight remains available when running from the repository: $ownerResponseBundleSemanticPreflightCommand or $ownerResponseBundleZipSemanticPreflightCommand",
    "12. Run import-owner-response-bundle.ps1 -ResponseBundleDir path\\to\\filled-bundle -RunReadiness if operator inbox import is required.",
    "13. Operator-side auto acceptance from a returned folder: $ownerResponseBundleAutoAcceptanceCommand",
    "14. Operator-side auto acceptance from a returned zip: $ownerResponseBundleZipAutoAcceptanceCommand",
    "15. Optional per-owner mini kits live under owner-response-mini-kits/; use merge-owner-mini-kits.ps1 to merge returned mini kits back into owner-response-bundle-template before semantic preflight.",
    "16. Zip path can also be provided with $ownerResponseBundleZipEnvironmentVariable.",
    "",
    "Boundary:",
    "",
    "- This kit does not send email.",
    "- This kit does not run agently-cli OAuth.",
    "- This kit does not accept real host-project evidence by itself.",
    "- Fixture evidence is not included in the template."
)
$kitReadmeLines | Set-Content -Path $kitReadmePath -Encoding UTF8

$templateReadmePath = Join-Path $templatePath "README.md"
$templateReadmeLines = @(
    "# AI TestPilot Owner Response Bundle Template",
    "",
    "Fill this folder and return it as one owner response bundle.",
    "The sibling export-helper paths below are relative to the production-handoff-export root.",
    "",
    "Required steps:",
    "",
    "1. Fill owner-contact-roster.json.",
    "2. For production-driver-evidence, use $productionDriverEvidenceExportHelperPath when available to create $productionDriverEvidenceExportZipPath, then copy the four required driver files into this folder.",
    "3. For production-lua-evidence, use $productionLuaEvidenceExportHelperPath when real Lua evidence is available to create $productionLuaEvidenceExportZipPath, then copy the three required Lua files into this folder.",
    "4. For live-smoke-evidence, use $liveModelSmokeEvidenceExportHelperPath after direct live provider smoke passes to create $liveModelSmokeEvidenceExportZipPath, then copy the two required live smoke files into this folder.",
    "5. Add the required files listed under each evidence directory.",
    "6. Run ../verify-owner-response-bundle.ps1 -BundleDir .",
    "7. Return this folder, or a zip of this folder, to the operator for semantic preflight with ../run-semantic-preflight.ps1 before auto acceptance.",
    "",
    "The template is incomplete until every required file is present and every contact is configured."
)
$templateReadmeLines | Set-Content -Path $templateReadmePath -Encoding UTF8

$requestDraftPath = Join-Path $kitPath "owner-response-bundle-request-draft.md"
$requestDraftLines = @(
    "Subject: AI TestPilot owner response bundle request",
    "",
    "Please complete and return the attached owner response bundle template.",
    "",
    "Needed now:",
    "",
    "- Missing owner contacts: $missingOwnerContactCount",
    "- Missing required evidence files: $missingRequiredFileCount",
    "- Required evidence files total: $requiredEvidenceFileCount",
    "- Production driver evidence export helper: $productionDriverEvidenceExportHelperCommand",
    "- Production Lua evidence export helper: $productionLuaEvidenceExportHelperCommand",
    "- Live model smoke evidence export helper: $liveModelSmokeEvidenceExportHelperCommand",
    "- Per-owner mini kits are available under owner-response-mini-kits/ if you want to route each owner only their own files.",
    "- Merge returned mini kits with merge-owner-mini-kits.ps1 before semantic preflight and auto acceptance.",
    "",
    "Use verify-owner-response-bundle.ps1 before returning the filled bundle.",
    "Return either the filled folder or a zip of that folder.",
    "",
    "Operator-side semantic preflight and acceptance after return:",
    "",
    "- $selfContainedOwnerResponseBundleSemanticPreflightCommand",
    "- $selfContainedOwnerResponseBundleZipSemanticPreflightCommand",
    "- $ownerResponseBundleSemanticPreflightCommand",
    "- $ownerResponseBundleZipSemanticPreflightCommand",
    "- Auto acceptance requires readyForAcceptanceCandidate=true, semanticFailCount=0, and a semanticPreflightStatus ready or warn-ready state.",
    "- $ownerResponseBundleAutoAcceptanceCommand",
    "- $ownerResponseBundleZipAutoAcceptanceCommand",
    "- Zip path environment variable: $ownerResponseBundleZipEnvironmentVariable",
    "",
    "This request does not mean production evidence has been accepted yet."
)
$requestDraftLines | Set-Content -Path $requestDraftPath -Encoding UTF8

$reportLines = @(
    "# AI TestPilot Production Handoff Owner Response Bundle Kit",
    "",
    "Schema: aitestpilot.production_handoff_owner_response_bundle_kit.v1",
    "Generated at UTC: $((Get-Date).ToUniversalTime().ToString("O"))",
    "",
    "## Summary",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Owner contacts | $ownerContactCount |",
    "| Required evidence files | $requiredEvidenceFileCount |",
    "| Missing contacts in default bundle | $missingOwnerContactCount |",
    "| Missing evidence files in default bundle | $missingRequiredFileCount |",
    "| Response bundle probe ready | $(Convert-ToBool (Get-JsonValue $ownerResponseBundleProbe "ownerResponseReadyForConfirmation" $false)) |",
    "| Kit zip | $(Split-Path $zipFullPath -Leaf) |",
    "| Self-contained semantic preflight helper | $(Format-MarkdownCell $selfContainedOwnerResponseBundleSemanticPreflightCommand) |",
    "| Self-contained semantic preflight zip helper | $(Format-MarkdownCell $selfContainedOwnerResponseBundleZipSemanticPreflightCommand) |",
    "| Owner response bundle semantic preflight | $(Format-MarkdownCell $ownerResponseBundleSemanticPreflightCommand) |",
    "| Owner response bundle zip semantic preflight | $(Format-MarkdownCell $ownerResponseBundleZipSemanticPreflightCommand) |",
    "| Owner response bundle auto acceptance | $(Format-MarkdownCell $ownerResponseBundleAutoAcceptanceCommand) |",
    "| Owner response bundle zip auto acceptance | $(Format-MarkdownCell $ownerResponseBundleZipAutoAcceptanceCommand) |",
    "| Owner response bundle zip environment variable | $ownerResponseBundleZipEnvironmentVariable |",
    "| Owner mini kits | $($ownerMiniKitEntries.Count) |",
    "| Owner mini kit merge helper | merge-owner-mini-kits.ps1 |",
    "| Production driver evidence export helper | $(Format-MarkdownCell $productionDriverEvidenceExportHelperCommand) |",
    "| Production Lua evidence export helper | $(Format-MarkdownCell $productionLuaEvidenceExportHelperCommand) |",
    "| Live model smoke evidence export helper | $(Format-MarkdownCell $liveModelSmokeEvidenceExportHelperCommand) |",
    "",
    "## Directories",
    "",
    "| Owner | Area | Directory | Required files |",
    "| --- | --- | --- | --- |"
)
foreach ($areaSpec in $areaSpecs) {
    $reportLines += ("| {0} | {1} | {2} | {3} |" -f `
            (Format-MarkdownCell $areaSpec["owner"]),
        (Format-MarkdownCell $areaSpec["area"]),
        (Format-MarkdownCell $areaSpec["directory"]),
        (Format-MarkdownCell (Join-TextList @($areaSpec["requiredEvidenceFiles"]))))
}
$reportLines += @(
    "",
    "## Boundary",
    "",
    "- Kit generation does not send email.",
    "- Kit generation does not accept real host-project evidence.",
    "- Kit generation does not include accepted fixture files."
)
$reportLines | Set-Content -Path $reportFullPath -Encoding UTF8

$contentFiles = @(
    $kitReadmePath,
    $templateReadmePath,
    $ownerMiniKitRootReadmePath,
    $contactRosterPath,
    $responseManifestPath,
    $requestDraftPath,
    $reportFullPath
)
$contentFiles += @(Get-ChildItem -LiteralPath $ownerMiniKitRootPath -Recurse -Filter RETURN-INSTRUCTIONS.md -File | ForEach-Object { $_.FullName })
$contentText = [string]::Join([Environment]::NewLine, @($contentFiles | ForEach-Object { Get-Content -Path $_ -Encoding UTF8 -Raw }))
$selfContainedSemanticPreflightHelperText = if (Test-Path $selfContainedSemanticPreflightHelperFullPath) { Get-Content -Path $selfContainedSemanticPreflightHelperFullPath -Encoding UTF8 -Raw } else { "" }
$selfContainedSemanticPreflightCoreText = if (Test-Path $selfContainedSemanticPreflightCoreFullPath) { Get-Content -Path $selfContainedSemanticPreflightCoreFullPath -Encoding UTF8 -Raw } else { "" }
$miniKitMergeScriptText = if (Test-Path $miniKitMergeScriptPath) { Get-Content -Path $miniKitMergeScriptPath -Encoding UTF8 -Raw } else { "" }
$noObjectLeakage = -not $contentText.Contains("System.Collections") -and -not $contentText.Contains("@{")
$autoAcceptanceCommandsContentValidated = (
    $contentText.Contains($ownerResponseBundleAutoAcceptanceCommand) -and
    $contentText.Contains($ownerResponseBundleZipAutoAcceptanceCommand) -and
    $contentText.Contains("-OwnerResponseBundleDir") -and
    $contentText.Contains("-OwnerResponseBundleZipPath") -and
    $contentText.Contains("-RequireAllEvidence") -and
    $contentText.Contains($ownerResponseBundleZipEnvironmentVariable) -and
    $contentText.Contains($productionDriverEvidenceExportHelperPath) -and
    $contentText.Contains($productionDriverEvidenceExportHelperCommand) -and
    $contentText.Contains($productionLuaEvidenceExportHelperPath) -and
    $contentText.Contains($productionLuaEvidenceExportHelperCommand) -and
    $contentText.Contains($liveModelSmokeEvidenceExportHelperPath) -and
    $contentText.Contains($liveModelSmokeEvidenceExportHelperCommand)
)
$semanticPreflightCommandsContentValidated = (
    $contentText.Contains($ownerResponseBundleSemanticPreflightCommand) -and
    $contentText.Contains($ownerResponseBundleZipSemanticPreflightCommand) -and
    $contentText.Contains($selfContainedOwnerResponseBundleSemanticPreflightCommand) -and
    $contentText.Contains($selfContainedOwnerResponseBundleZipSemanticPreflightCommand) -and
    $contentText.Contains($selfContainedSemanticPreflightHelperPath) -and
    $contentText.Contains("Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1") -and
    $contentText.Contains("-OwnerResponseBundleDir") -and
    $contentText.Contains("-OwnerResponseBundleZipPath") -and
    $contentText.Contains("readyForAcceptanceCandidate") -and
    $contentText.Contains("semanticPreflightStatus") -and
    $contentText.Contains("semanticFailCount")
)
$selfContainedSemanticPreflightHelperContentValidated = (
    (Test-Path $selfContainedSemanticPreflightHelperFullPath) -and
    (Test-Path $selfContainedSemanticPreflightCoreFullPath) -and
    $selfContainedSemanticPreflightHelperText.Contains("semantic-preflight\Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1") -and
    $selfContainedSemanticPreflightHelperText.Contains("OwnerResponseBundleDir") -and
    $selfContainedSemanticPreflightHelperText.Contains("OwnerResponseBundleZipPath") -and
    $selfContainedSemanticPreflightHelperText.Contains("readyForAcceptanceCandidate") -and
    $selfContainedSemanticPreflightHelperText.Contains("AITESTPILOT_OWNER_RESPONSE_BUNDLE_ZIP_PATH") -and
    $selfContainedSemanticPreflightCoreText.Contains("aitestpilot.production_external_evidence_semantic_preflight.v1")
)
$ownerMiniKitDirectoryCount = @(Get-ChildItem -LiteralPath $ownerMiniKitRootPath -Directory | Where-Object { $_.Name -like "host_project_*" }).Count
$ownerMiniKitZipCount = @(Get-ChildItem -LiteralPath $ownerMiniKitRootPath -File -Filter "host_project_*.zip").Count
$ownerMiniKitRequiredFilesJsonCount = @(Get-ChildItem -LiteralPath $ownerMiniKitRootPath -Recurse -Filter required-files.json).Count
$ownerMiniKitReturnInstructionsCount = @(Get-ChildItem -LiteralPath $ownerMiniKitRootPath -Recurse -Filter RETURN-INSTRUCTIONS.md).Count
$ownerMiniKitsGenerated = (
    (Test-Path $ownerMiniKitRootPath) -and
    (Test-Path $ownerMiniKitRootReadmePath) -and
    (Test-Path $miniKitMergeScriptPath) -and
    $ownerMiniKitDirectoryCount -eq $ownerInputs.Count -and
    $ownerMiniKitZipCount -eq $ownerInputs.Count -and
    $ownerMiniKitRequiredFilesJsonCount -eq $ownerInputs.Count -and
    $ownerMiniKitReturnInstructionsCount -eq $ownerInputs.Count
)
$ownerMiniKitsContentValidated = (
    $contentText.Contains("Owner Response Mini Kits") -and
    $contentText.Contains("owner-response-mini-kits") -and
    $contentText.Contains("merge-owner-mini-kits.ps1") -and
    $contentText.Contains("This mini kit does not include the verifier") -and
    $contentText.Contains("host_project_gameplay_qa") -and
    $contentText.Contains("host_project_lua_owner") -and
    $contentText.Contains("host_project_ai_platform") -and
    $miniKitMergeScriptText.Contains("owner-mini-kit-merge-manifest.json") -and
    $miniKitMergeScriptText.Contains("owner-contact-roster.json") -and
    $miniKitMergeScriptText.Contains("required-files.json") -and
    $miniKitMergeScriptText.Contains("verify-owner-response-bundle.ps1")
)

$kitFiles = @(
    Get-ChildItem -LiteralPath $kitPath -Recurse -File |
        ForEach-Object { "production-handoff-owner-response-bundle-kit/" + (Convert-ToRelativePath $kitPath $_.FullName).Replace("\", "/") }
)
$kitFiles = @($kitFiles | Sort-Object)

$templateDirectoryCount = @($areaSpecs).Count
$requiredFilesJsonCount = @(Get-ChildItem -LiteralPath $templatePath -Recurse -Filter required-files.json).Count
$areaReadmeCount = @(Get-ChildItem -LiteralPath $templatePath -Recurse -Filter README.md).Count - 1

$checks = @()
Add-KitCheck "owner_response_bundle_kit_sources_available" `
    ($ownerInputRequest.status -eq "PASS" -and $externalEvidenceInbox.status -eq "PASS" -and $ownerResponseBundleProbe.status -eq "PASS" -and $handoffExport.status -eq "PASS") `
    "Owner response bundle kit must be based on passing owner input, inbox, response-bundle probe, and export evidence."
Add-KitCheck "owner_response_bundle_template_generated" `
    ((Test-Path $templatePath) -and (Test-Path $contactRosterPath) -and (Test-Path $responseManifestPath) -and $templateDirectoryCount -eq 3 -and $requiredFilesJsonCount -eq 3 -and $areaReadmeCount -eq 3) `
    "Owner response bundle kit must generate one fillable roster and three evidence directories with required-file manifests."
Add-KitCheck "owner_response_bundle_scripts_generated" `
    ((Test-Path $verifyScriptPath) -and (Test-Path $importScriptPath) -and (Test-Path $selfContainedSemanticPreflightHelperFullPath) -and (Test-Path $selfContainedSemanticPreflightCoreFullPath) -and (Get-Content -Raw $verifyScriptPath).Contains("READY_FOR_IMPORT") -and (Get-Content -Raw $importScriptPath).Contains("Invoke-AITestPilotProductionHandoffOwnerUnblockPack.ps1")) `
    "Owner response bundle kit must include verify, import, and self-contained semantic preflight helpers."
Add-KitCheck "owner_response_bundle_counts_match" `
    ($ownerContactCount -eq (Convert-ToInt (Get-JsonValue $ownerResponseBundleProbe "ownerContactCount" -1)) -and $requiredEvidenceFileCount -eq (Convert-ToInt (Get-JsonValue $ownerResponseBundleProbe "responseBundleRequiredEvidenceFileCount" -1))) `
    "Owner response bundle kit counts must match the accepted response bundle probe."
Add-KitCheck "owner_response_bundle_content_validated" `
    ($contentText.Contains("Owner Response Bundle Kit") -and $contentText.Contains("host_project_gameplay_qa") -and $contentText.Contains("production-driver-evidence") -and $contentText.Contains("production-lua-evidence") -and $contentText.Contains("live-smoke-evidence") -and $contentText.Contains("Export-ProductionDriverEvidenceBundle.ps1") -and $contentText.Contains("Export-ProductionLuaPatchEvidenceBundle.ps1") -and $contentText.Contains("Export-LiveModelEndpointSmokeEvidenceBundle.ps1") -and $contentText.Contains("production-handoff-export root") -and $contentText.Contains("does not send email") -and $noObjectLeakage) `
    "Owner response bundle kit content must include concrete owners, directories, validation flow, and boundary text."
Add-KitCheck "owner_response_bundle_auto_acceptance_commands_documented" `
    $autoAcceptanceCommandsContentValidated `
    "Owner response bundle kit must document operator-side auto acceptance commands for returned folders and zip archives."
Add-KitCheck "owner_response_bundle_semantic_preflight_commands_documented" `
    $semanticPreflightCommandsContentValidated `
    "Owner response bundle kit must document operator-side semantic preflight commands and manifest fields before auto acceptance."
Add-KitCheck "owner_response_bundle_self_contained_semantic_preflight_helper" `
    $selfContainedSemanticPreflightHelperContentValidated `
    "Owner response bundle kit must include a self-contained semantic preflight helper and bundled core script."
Add-KitCheck "owner_response_bundle_owner_mini_kits_generated" `
    ($ownerMiniKitsGenerated -and $ownerMiniKitsContentValidated) `
    "Owner response bundle kit must include per-owner mini kits, per-owner zips, and a merge helper for returned mini kits."
Add-KitCheck "owner_response_bundle_boundary_preserved" `
    (-not (Convert-ToBool (Get-JsonValue $ownerResponseBundleProbe "emailSent" $true)) -and -not (Convert-ToBool (Get-JsonValue $ownerResponseBundleProbe "realHostProjectEvidenceAccepted" $true)) -and -not (Convert-ToBool (Get-JsonValue $ownerResponseBundleProbe "fixtureEvidencePromoted" $true))) `
    "Owner response bundle kit must preserve not-sent, no-real-evidence, and no-fixture-promotion boundaries."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$sourceFiles = @(
    "production-handoff-owner-input-request-pack-manifest.json",
    "production-external-evidence-inbox-manifest.json",
    "production-handoff-owner-response-bundle-probe-manifest.json",
    "production-handoff-export-manifest.json"
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_owner_response_bundle_kit.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    kitDir = $kitPath
    templateDir = $templatePath
    zipPath = $zipFullPath
    reportPath = $reportFullPath
    ownerContactCount = [int]$ownerContactCount
    requiredEvidenceFileCount = [int]$requiredEvidenceFileCount
    missingOwnerContactCount = [int]$missingOwnerContactCount
    missingRequiredFileCount = [int]$missingRequiredFileCount
    responseBundleTemplateGenerated = (Test-Path $templatePath)
    contactRosterTemplateGenerated = (Test-Path $contactRosterPath)
    responseBundleManifestGenerated = (Test-Path $responseManifestPath)
    verifyScriptGenerated = (Test-Path $verifyScriptPath)
    importScriptGenerated = (Test-Path $importScriptPath)
    selfContainedSemanticPreflightHelperGenerated = (Test-Path $selfContainedSemanticPreflightHelperFullPath)
    selfContainedSemanticPreflightCoreGenerated = (Test-Path $selfContainedSemanticPreflightCoreFullPath)
    selfContainedSemanticPreflightHelperPath = $selfContainedSemanticPreflightHelperPath
    selfContainedSemanticPreflightCorePath = $selfContainedSemanticPreflightCorePath
    selfContainedSemanticPreflightHelperContentValidated = [bool]$selfContainedSemanticPreflightHelperContentValidated
    ownerMiniKitsGenerated = [bool]$ownerMiniKitsGenerated
    ownerMiniKitCount = [int]$ownerMiniKitEntries.Count
    ownerMiniKitDirectoryCount = [int]$ownerMiniKitDirectoryCount
    ownerMiniKitZipCount = [int]$ownerMiniKitZipCount
    ownerMiniKitRequiredFilesJsonCount = [int]$ownerMiniKitRequiredFilesJsonCount
    ownerMiniKitReturnInstructionsCount = [int]$ownerMiniKitReturnInstructionsCount
    ownerMiniKitsContentValidated = [bool]$ownerMiniKitsContentValidated
    ownerMiniKitMergeScriptGenerated = (Test-Path $miniKitMergeScriptPath)
    ownerMiniKitMergeScriptContentValidated = [bool]$ownerMiniKitsContentValidated
    ownerMiniKits = @($ownerMiniKitEntries)
    selfContainedOwnerResponseBundleSemanticPreflightCommand = $selfContainedOwnerResponseBundleSemanticPreflightCommand
    selfContainedOwnerResponseBundleZipSemanticPreflightCommand = $selfContainedOwnerResponseBundleZipSemanticPreflightCommand
    requestDraftGenerated = (Test-Path $requestDraftPath)
    reportGenerated = (Test-Path $reportFullPath)
    autoAcceptanceCommandsGenerated = $true
    autoAcceptanceCommandsContentValidated = [bool]$autoAcceptanceCommandsContentValidated
    semanticPreflightCommandsGenerated = $true
    semanticPreflightCommandsContentValidated = [bool]$semanticPreflightCommandsContentValidated
    ownerResponseBundleAutoAcceptanceCommand = $ownerResponseBundleAutoAcceptanceCommand
    ownerResponseBundleZipAutoAcceptanceCommand = $ownerResponseBundleZipAutoAcceptanceCommand
    ownerResponseBundleSemanticPreflightCommand = $ownerResponseBundleSemanticPreflightCommand
    ownerResponseBundleZipSemanticPreflightCommand = $ownerResponseBundleZipSemanticPreflightCommand
    semanticPreflightCandidateField = "readyForAcceptanceCandidate"
    semanticPreflightStatusField = "semanticPreflightStatus"
    semanticPreflightFailCountField = "semanticFailCount"
    ownerResponseBundleZipEnvironmentVariable = $ownerResponseBundleZipEnvironmentVariable
    productionDriverEvidenceExportHelperPath = $productionDriverEvidenceExportHelperPath
    productionDriverEvidenceExportHelperCommand = $productionDriverEvidenceExportHelperCommand
    productionDriverEvidenceExportHelperDocumented = [bool]$contentText.Contains($productionDriverEvidenceExportHelperCommand)
    productionDriverEvidenceExportZipPath = $productionDriverEvidenceExportZipPath
    productionLuaEvidenceExportHelperPath = $productionLuaEvidenceExportHelperPath
    productionLuaEvidenceExportHelperCommand = $productionLuaEvidenceExportHelperCommand
    productionLuaEvidenceExportHelperDocumented = [bool]$contentText.Contains($productionLuaEvidenceExportHelperCommand)
    productionLuaEvidenceExportZipPath = $productionLuaEvidenceExportZipPath
    liveModelSmokeEvidenceExportHelperPath = $liveModelSmokeEvidenceExportHelperPath
    liveModelSmokeEvidenceExportHelperCommand = $liveModelSmokeEvidenceExportHelperCommand
    liveModelSmokeEvidenceExportHelperDocumented = [bool]$contentText.Contains($liveModelSmokeEvidenceExportHelperCommand)
    liveModelSmokeEvidenceExportZipPath = $liveModelSmokeEvidenceExportZipPath
    templateDirectoryCount = [int]$templateDirectoryCount
    requiredFilesJsonCount = [int]$requiredFilesJsonCount
    areaReadmeCount = [int]$areaReadmeCount
    kitFileCount = [int]$kitFiles.Count
    zipGenerated = $false
    releasePipelineSendsEmail = $false
    emailSent = $false
    confirmationTokenCreated = $false
    automaticEmailSendReady = $false
    mailAuthorizationCheckedByPipeline = $false
    realHostProjectEvidenceAccepted = $false
    externalEvidenceAccepted = $false
    releasePipelineUsesFixture = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "owner_response_bundle_template_kit_only"
    sourceFiles = @($sourceFiles)
    generatedFiles = @()
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
}

New-Item -ItemType Directory -Force (Split-Path $manifestFullPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestFullPath -Encoding UTF8
$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path (Join-Path $kitPath (Split-Path $manifestFullPath -Leaf)) -Encoding UTF8

Compress-Archive -Path (Join-Path $kitPath "*") -DestinationPath $zipFullPath -Force
if (-not (Test-Path $zipFullPath)) {
    throw "Owner response bundle kit zip was not produced: $zipFullPath"
}

$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestFullPath),
    (Convert-ToEvidenceRelativePath $reportFullPath),
    (Convert-ToEvidenceRelativePath $zipFullPath)
) + @($kitFiles)
$manifest.generatedFiles = @($generatedFiles)
$manifest.files = @($generatedFiles + $sourceFiles)
$manifest.zipGenerated = $true
$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestFullPath -Encoding UTF8
$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path (Join-Path $kitPath (Split-Path $manifestFullPath -Leaf)) -Encoding UTF8
Compress-Archive -Path (Join-Path $kitPath "*") -DestinationPath $zipFullPath -Force

if ($failedChecks.Count -gt 0) {
    throw "Production handoff owner response bundle kit failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production handoff owner response bundle kit: $kitPath"
Write-Output "Production handoff owner response bundle kit zip: $zipFullPath"
Write-Output "Production handoff owner response bundle kit manifest: $manifestFullPath"
Write-Output "PASS AI TestPilot production handoff owner response bundle kit"
