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

$kitReadmePath = Join-Path $kitPath "README.md"
$kitReadmeLines = @(
    "# AI TestPilot Owner Response Bundle Kit",
    "",
    "This kit is the fillable owner response package for contacts and returned production evidence.",
    "",
    "Workflow:",
    "",
    "1. Copy owner-response-bundle-template to a working folder.",
    "2. Fill owner-contact-roster.json with real owner mailboxes.",
    "3. Copy required evidence files into production-driver-evidence, production-lua-evidence, and live-smoke-evidence.",
    "4. Run verify-owner-response-bundle.ps1 against the filled bundle.",
    "5. Run import-owner-response-bundle.ps1 -ResponseBundleDir path\\to\\filled-bundle -RunReadiness.",
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
    "",
    "Required steps:",
    "",
    "1. Fill owner-contact-roster.json.",
    "2. Add the required files listed under each evidence directory.",
    "3. Run ../verify-owner-response-bundle.ps1 -BundleDir .",
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
    "",
    "Use verify-owner-response-bundle.ps1 before returning the filled bundle.",
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
    $contactRosterPath,
    $responseManifestPath,
    $requestDraftPath,
    $reportFullPath
)
$contentText = [string]::Join([Environment]::NewLine, @($contentFiles | ForEach-Object { Get-Content -Path $_ -Encoding UTF8 -Raw }))
$noObjectLeakage = -not $contentText.Contains("System.Collections") -and -not $contentText.Contains("@{")

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
    ((Test-Path $verifyScriptPath) -and (Test-Path $importScriptPath) -and (Get-Content -Raw $verifyScriptPath).Contains("READY_FOR_IMPORT") -and (Get-Content -Raw $importScriptPath).Contains("Invoke-AITestPilotProductionHandoffOwnerUnblockPack.ps1")) `
    "Owner response bundle kit must include verify and import helpers."
Add-KitCheck "owner_response_bundle_counts_match" `
    ($ownerContactCount -eq (Convert-ToInt (Get-JsonValue $ownerResponseBundleProbe "ownerContactCount" -1)) -and $requiredEvidenceFileCount -eq (Convert-ToInt (Get-JsonValue $ownerResponseBundleProbe "responseBundleRequiredEvidenceFileCount" -1))) `
    "Owner response bundle kit counts must match the accepted response bundle probe."
Add-KitCheck "owner_response_bundle_content_validated" `
    ($contentText.Contains("Owner Response Bundle Kit") -and $contentText.Contains("host_project_gameplay_qa") -and $contentText.Contains("production-driver-evidence") -and $contentText.Contains("live-smoke-evidence") -and $contentText.Contains("does not send email") -and $noObjectLeakage) `
    "Owner response bundle kit content must include concrete owners, directories, validation flow, and boundary text."
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
    requestDraftGenerated = (Test-Path $requestDraftPath)
    reportGenerated = (Test-Path $reportFullPath)
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
