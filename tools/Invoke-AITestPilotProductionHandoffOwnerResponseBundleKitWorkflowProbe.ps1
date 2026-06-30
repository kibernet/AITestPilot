[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ProbeDir,
    [string]$WorkDir,
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
    $ProbeDir = Join-Path $EvidenceBundleDir "production-handoff-owner-response-bundle-kit-workflow-probe"
}

if ([string]::IsNullOrWhiteSpace($WorkDir)) {
    $WorkDir = Join-Path $repoRoot "Temp\release-evidence\owner-response-bundle-kit-workflow-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-handoff-owner-response-bundle-kit-workflow-probe-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-handoff-owner-response-bundle-kit-workflow-probe.md"
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

function Convert-ToArray {
    param([object]$Value)

    if ($null -eq $Value) {
        return @()
    }

    return @($Value)
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
        return "owner"
    }

    return $slug
}

function Invoke-OwnerBundleVerify {
    param(
        [string]$VerifyScriptPath,
        [string]$BundleDir,
        [string]$OutputPath,
        [string]$TranscriptPath
    )

    $output = @()
    $succeeded = $false
    $errorMessage = ""
    try {
        $output = & $VerifyScriptPath -BundleDir $BundleDir -OutputPath $OutputPath 2>&1
        $succeeded = $true
    }
    catch {
        $output += $_
        $errorMessage = $_.Exception.Message
    }

    @($output | ForEach-Object { [string]$_ }) | Set-Content -Path $TranscriptPath -Encoding UTF8

    $preflight = $null
    if (Test-Path $OutputPath) {
        $preflight = Read-JsonFile $OutputPath "Owner response bundle preflight"
    }

    return [ordered]@{
        succeeded = [bool]$succeeded
        errorMessage = $errorMessage
        outputPath = $OutputPath
        transcriptPath = $TranscriptPath
        preflight = $preflight
    }
}

function Write-PlaceholderRequiredFile {
    param(
        [string]$Path,
        [string]$Owner,
        [string]$Area,
        [string]$FileName
    )

    if ($Path.EndsWith(".json", [System.StringComparison]::OrdinalIgnoreCase)) {
        ([ordered]@{
            schemaVersion = "aitestpilot.owner_response_bundle_kit_workflow_probe.placeholder.v1"
            owner = $Owner
            area = $Area
            fileName = $FileName
            fixtureOnly = $true
            realHostProjectEvidenceAccepted = $false
            generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
        }) | ConvertTo-Json -Depth 6 | Set-Content -Path $Path -Encoding UTF8
        return
    }

    @(
        "# Owner Response Bundle Workflow Probe Placeholder",
        "",
        "Owner: $Owner",
        "Area: $Area",
        "File: $FileName",
        "",
        "This file is a contract fixture used only to prove kit workflow mechanics."
    ) | Set-Content -Path $Path -Encoding UTF8
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
$workPath = Assert-PathUnderRepo $WorkDir "WorkDir"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if (Test-Path $probePath) {
    Remove-Item -LiteralPath $probePath -Recurse -Force
}
if (Test-Path $workPath) {
    Remove-Item -LiteralPath $workPath -Recurse -Force
}

New-Item -ItemType Directory -Force $probePath | Out-Null
New-Item -ItemType Directory -Force $workPath | Out-Null

$kitManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-owner-response-bundle-kit-manifest.json") "Production handoff owner response bundle kit manifest"
$ownerInputRequest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-owner-input-request-pack-manifest.json") "Production handoff owner input request pack manifest"
$sourceKitPath = Resolve-FullPath (Join-Path $evidenceBundlePath "production-handoff-owner-response-bundle-kit")
if (-not (Test-Path $sourceKitPath)) {
    $sourceKitPath = Resolve-FullPath ([string](Get-JsonValue $kitManifest "kitDir" ""))
}
if (-not (Test-Path $sourceKitPath)) {
    throw "Owner response bundle kit directory is missing: $sourceKitPath"
}

$copiedKitPath = Join-Path $workPath "kit"
Copy-Item -LiteralPath $sourceKitPath -Destination $copiedKitPath -Recurse -Force

$verifyScriptPath = Join-Path $copiedKitPath "verify-owner-response-bundle.ps1"
$importScriptPath = Join-Path $copiedKitPath "import-owner-response-bundle.ps1"
$kitReadmePath = Join-Path $copiedKitPath "README.md"
$requestDraftPath = Join-Path $copiedKitPath "owner-response-bundle-request-draft.md"
$templatePath = Join-Path $copiedKitPath "owner-response-bundle-template"
if (-not (Test-Path $verifyScriptPath)) {
    throw "Copied kit is missing verify helper: $verifyScriptPath"
}
if (-not (Test-Path $importScriptPath)) {
    throw "Copied kit is missing import helper: $importScriptPath"
}
if (-not (Test-Path $templatePath)) {
    throw "Copied kit is missing owner response template: $templatePath"
}

$ownerResponseBundleAutoAcceptanceCommand = [string](Get-JsonValue $kitManifest "ownerResponseBundleAutoAcceptanceCommand" "")
$ownerResponseBundleZipAutoAcceptanceCommand = [string](Get-JsonValue $kitManifest "ownerResponseBundleZipAutoAcceptanceCommand" "")
$ownerResponseBundleZipEnvironmentVariable = [string](Get-JsonValue $kitManifest "ownerResponseBundleZipEnvironmentVariable" "")
$kitReadmeText = if (Test-Path $kitReadmePath) { Get-Content -Path $kitReadmePath -Encoding UTF8 -Raw } else { "" }
$requestDraftText = if (Test-Path $requestDraftPath) { Get-Content -Path $requestDraftPath -Encoding UTF8 -Raw } else { "" }
$kitDocsText = [string]::Join([Environment]::NewLine, @($kitReadmeText, $requestDraftText))
$autoAcceptanceZipCommandDocumented = (
    -not [string]::IsNullOrWhiteSpace($ownerResponseBundleZipAutoAcceptanceCommand) -and
    -not [string]::IsNullOrWhiteSpace($ownerResponseBundleZipEnvironmentVariable) -and
    $kitDocsText.Contains($ownerResponseBundleZipAutoAcceptanceCommand) -and
    $kitDocsText.Contains("-OwnerResponseBundleZipPath") -and
    $kitDocsText.Contains("-RequireAllEvidence") -and
    $kitDocsText.Contains($ownerResponseBundleZipEnvironmentVariable)
)
$autoAcceptanceCommandsDocumented = (
    (Convert-ToBool (Get-JsonValue $kitManifest "autoAcceptanceCommandsContentValidated" $false)) -and
    -not [string]::IsNullOrWhiteSpace($ownerResponseBundleAutoAcceptanceCommand) -and
    $kitDocsText.Contains($ownerResponseBundleAutoAcceptanceCommand) -and
    $kitDocsText.Contains("-OwnerResponseBundleDir") -and
    $autoAcceptanceZipCommandDocumented
)

$incompleteBundlePath = Join-Path $workPath "incomplete-owner-response-bundle"
$completeBundlePath = Join-Path $workPath "complete-owner-response-bundle"
Copy-Item -LiteralPath $templatePath -Destination $incompleteBundlePath -Recurse -Force
Copy-Item -LiteralPath $templatePath -Destination $completeBundlePath -Recurse -Force

$incompletePreflightPath = Join-Path $probePath "incomplete-owner-response-bundle-preflight.json"
$incompleteTranscriptPath = Join-Path $probePath "incomplete-owner-response-bundle-verify-output.txt"
$incompleteVerify = Invoke-OwnerBundleVerify `
    -VerifyScriptPath $verifyScriptPath `
    -BundleDir $incompleteBundlePath `
    -OutputPath $incompletePreflightPath `
    -TranscriptPath $incompleteTranscriptPath

$rosterPath = Join-Path $completeBundlePath "owner-contact-roster.json"
$roster = Read-JsonFile $rosterPath "Owner response bundle contact roster"
$configuredContacts = 0
foreach ($entry in @(Convert-ToArray (Get-JsonValue $roster "entries" @()))) {
    $owner = [string](Get-JsonValue $entry "owner" "")
    $slug = Convert-ToSlug $owner
    $entry.emailAddress = ($slug + "@example.invalid")
    $entry.configured = $true
    $entry.notes = "Workflow probe fixture address. Replace with the real owner mailbox before live dispatch."
    $configuredContacts += 1
}
$roster.status = "CONTACTS_CONFIGURED"
$roster.configuredContactCount = $configuredContacts
$roster.fixtureOnly = $true
$roster | ConvertTo-Json -Depth 12 | Set-Content -Path $rosterPath -Encoding UTF8

$responseManifestPath = Join-Path $completeBundlePath "owner-response-bundle-manifest.json"
$responseManifest = Read-JsonFile $responseManifestPath "Owner response bundle manifest"
$requiredFileSpecs = @(Get-ChildItem -Path $completeBundlePath -Recurse -Filter required-files.json)
$requiredEvidenceFileCount = 0
$writtenEvidenceFileCount = 0
foreach ($requiredFileSpec in $requiredFileSpecs) {
    $spec = Read-JsonFile $requiredFileSpec.FullName "Required files manifest"
    $areaDir = Split-Path $requiredFileSpec.FullName -Parent
    $owner = [string](Get-JsonValue $spec "owner" "")
    $area = [string](Get-JsonValue $spec "area" "")
    foreach ($fileName in @(Convert-ToArray (Get-JsonValue $spec "requiredEvidenceFiles" @()))) {
        $requiredEvidenceFileCount += 1
        Write-PlaceholderRequiredFile `
            -Path (Join-Path $areaDir ([string]$fileName)) `
            -Owner $owner `
            -Area $area `
            -FileName ([string]$fileName)
        $writtenEvidenceFileCount += 1
    }
}
$responseManifest.status = "COMPLETE_CONTRACT_FIXTURE"
$responseManifest.configuredContactCount = $configuredContacts
$responseManifest.presentEvidenceFileCount = $writtenEvidenceFileCount
$responseManifest.fixtureOnly = $true
$responseManifest.productionOutputBoundary = "owner_response_bundle_kit_workflow_probe_only"
$responseManifest | ConvertTo-Json -Depth 10 | Set-Content -Path $responseManifestPath -Encoding UTF8

$completePreflightPath = Join-Path $probePath "complete-owner-response-bundle-preflight.json"
$completeTranscriptPath = Join-Path $probePath "complete-owner-response-bundle-verify-output.txt"
$completeVerify = Invoke-OwnerBundleVerify `
    -VerifyScriptPath $verifyScriptPath `
    -BundleDir $completeBundlePath `
    -OutputPath $completePreflightPath `
    -TranscriptPath $completeTranscriptPath

$isolatedEvidencePath = Join-Path $workPath "isolated-import-evidence"
New-Item -ItemType Directory -Force (Join-Path $isolatedEvidencePath "production-external-evidence-inbox") | Out-Null
$importTranscriptPath = Join-Path $probePath "complete-owner-response-bundle-import-output.txt"
$importSucceeded = $false
$importErrorMessage = ""
try {
    $importOutput = & $importScriptPath `
        -ResponseBundleDir $completeBundlePath `
        -EvidenceBundleDir $isolatedEvidencePath `
        -RepoRoot $repoRoot 2>&1
    $importSucceeded = $true
}
catch {
    $importOutput = @($_)
    $importErrorMessage = $_.Exception.Message
}
@($importOutput | ForEach-Object { [string]$_ }) | Set-Content -Path $importTranscriptPath -Encoding UTF8

$importedRosterPath = Join-Path $isolatedEvidencePath "production-handoff-contact-roster.json"
$importedInboxPath = Join-Path $isolatedEvidencePath "production-external-evidence-inbox"
$importedEvidenceFiles = @()
foreach ($directoryName in @("production-driver-evidence", "production-lua-evidence", "live-smoke-evidence")) {
    $directoryPath = Join-Path $importedInboxPath $directoryName
    if (Test-Path $directoryPath) {
        $importedEvidenceFiles += @(
            Get-ChildItem -LiteralPath $directoryPath -File |
                Where-Object { $_.Name -ne "README.md" -and $_.Name -ne "required-files.json" } |
                ForEach-Object { $_.FullName }
        )
    }
}

$importSnapshotPath = Join-Path $probePath "isolated-import-snapshot"
New-Item -ItemType Directory -Force $importSnapshotPath | Out-Null
if (Test-Path $importedRosterPath) {
    Copy-Item -LiteralPath $importedRosterPath -Destination (Join-Path $importSnapshotPath "production-handoff-contact-roster.json") -Force
}
if (Test-Path $importedInboxPath) {
    Copy-Item -LiteralPath $importedInboxPath -Destination (Join-Path $importSnapshotPath "production-external-evidence-inbox") -Recurse -Force
}

$incompletePreflight = $incompleteVerify.preflight
$completePreflight = $completeVerify.preflight
$ownerContactCount = Convert-ToInt (Get-JsonValue $kitManifest "ownerContactCount" 0)
$kitRequiredEvidenceFileCount = Convert-ToInt (Get-JsonValue $kitManifest "requiredEvidenceFileCount" 0)

$emptyTemplateRejected = -not [bool]$incompleteVerify.succeeded -and
    (Get-JsonValue $incompletePreflight "status" "") -eq "INCOMPLETE_OWNER_RESPONSE" -and
    (Convert-ToInt (Get-JsonValue $incompletePreflight "ownerContactCount" 0)) -eq $ownerContactCount -and
    (Convert-ToInt (Get-JsonValue $incompletePreflight "invalidContactCount" -1)) -eq $ownerContactCount -and
    (Convert-ToInt (Get-JsonValue $incompletePreflight "missingEvidenceFileCount" -1)) -eq $kitRequiredEvidenceFileCount

$completeTemplateAccepted = [bool]$completeVerify.succeeded -and
    (Get-JsonValue $completePreflight "status" "") -eq "READY_FOR_IMPORT" -and
    (Convert-ToInt (Get-JsonValue $completePreflight "ownerContactCount" 0)) -eq $ownerContactCount -and
    (Convert-ToInt (Get-JsonValue $completePreflight "configuredContactCount" 0)) -eq $ownerContactCount -and
    (Convert-ToInt (Get-JsonValue $completePreflight "invalidContactCount" -1)) -eq 0 -and
    (Convert-ToInt (Get-JsonValue $completePreflight "requiredEvidenceFileCount" 0)) -eq $kitRequiredEvidenceFileCount -and
    (Convert-ToInt (Get-JsonValue $completePreflight "presentEvidenceFileCount" 0)) -eq $kitRequiredEvidenceFileCount -and
    (Convert-ToInt (Get-JsonValue $completePreflight "missingEvidenceFileCount" -1)) -eq 0

$importCopiedBundle = $importSucceeded -and
    (Test-Path $importedRosterPath) -and
    @($importedEvidenceFiles).Count -eq $kitRequiredEvidenceFileCount

$reportLines = @(
    "# AI TestPilot Production Handoff Owner Response Bundle Kit Workflow Probe",
    "",
    "Schema: ``aitestpilot.production_handoff_owner_response_bundle_kit_workflow_probe.v1``",
    "Generated at UTC: $((Get-Date).ToUniversalTime().ToString("O"))",
    "",
    "## Summary",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Empty template rejected | $emptyTemplateRejected |",
    "| Complete template accepted | $completeTemplateAccepted |",
    "| Import copied bundle | $importCopiedBundle |",
    "| Owner contacts | $ownerContactCount |",
    "| Required evidence files | $kitRequiredEvidenceFileCount |",
    "| Imported evidence files | $(@($importedEvidenceFiles).Count) |",
    "| Auto acceptance commands documented | $autoAcceptanceCommandsDocumented |",
    "| Auto acceptance zip command documented | $autoAcceptanceZipCommandDocumented |",
    "| Import error | $(Format-MarkdownCell $importErrorMessage) |",
    "",
    "## Boundary",
    "",
    "- This probe executes generated kit helper scripts in an isolated workflow.",
    "- It does not send email or create confirmation tokens.",
    "- It does not accept real host-project evidence.",
    "- The complete bundle uses local placeholders only to prove helper mechanics.",
    "",
    "## Checks",
    "",
    "| Check | Result | Message |",
    "| --- | --- | --- |"
)

$checks = @()
Add-ProbeCheck "owner_response_bundle_kit_source_available" `
    ((Get-JsonValue $kitManifest "status" "") -eq "PASS" -and
        (Get-JsonValue $kitManifest "schemaVersion" "") -eq "aitestpilot.production_handoff_owner_response_bundle_kit.v1" -and
        (Test-Path $verifyScriptPath) -and
        (Test-Path $importScriptPath) -and
        (Test-Path $templatePath)) `
    "Workflow probe must copy a passing owner response bundle kit with verify/import helpers."
Add-ProbeCheck "empty_template_rejected" `
    $emptyTemplateRejected `
    "Generated verify helper must reject the untouched template with missing contacts and evidence files."
Add-ProbeCheck "complete_template_ready_for_import" `
    $completeTemplateAccepted `
    "Generated verify helper must accept a filled contact roster and all nine required evidence files."
Add-ProbeCheck "import_helper_copies_bundle" `
    $importCopiedBundle `
    "Generated import helper must copy the filled roster and all required evidence files into an isolated evidence bundle."
Add-ProbeCheck "auto_acceptance_commands_documented" `
    $autoAcceptanceCommandsDocumented `
    "Generated owner response bundle kit must document operator-side auto acceptance commands for returned folders and zip archives."
Add-ProbeCheck "workflow_counts_match_kit_contract" `
    ($ownerContactCount -eq (Convert-ToInt (Get-JsonValue $ownerInputRequest "ownerActionCount" 0)) -and
        $kitRequiredEvidenceFileCount -eq (Convert-ToInt (Get-JsonValue $ownerInputRequest "missingRequiredFileCount" 0)) -and
        $requiredEvidenceFileCount -eq $kitRequiredEvidenceFileCount -and
        $writtenEvidenceFileCount -eq $kitRequiredEvidenceFileCount) `
    "Workflow probe counts must match the owner input request and kit manifest contract."
Add-ProbeCheck "workflow_boundary_preserved" `
    (-not (Convert-ToBool (Get-JsonValue $kitManifest "releasePipelineSendsEmail" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $kitManifest "emailSent" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $kitManifest "realHostProjectEvidenceAccepted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $kitManifest "externalEvidenceAccepted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $kitManifest "fixtureEvidencePromoted" $true))) `
    "Kit workflow probe must preserve no-send, no-real-evidence, and no-fixture-promotion boundaries."

foreach ($check in $checks) {
    $result = if ([bool]$check.passed) { "PASS" } else { "FAIL" }
    $reportLines += "| $(Format-MarkdownCell $check.name) | $result | $(Format-MarkdownCell $check.message) |"
}

$reportLines | Set-Content -Path $reportFullPath -Encoding UTF8

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestFullPath),
    (Convert-ToEvidenceRelativePath $reportFullPath),
    (Convert-ToEvidenceRelativePath $incompletePreflightPath),
    (Convert-ToEvidenceRelativePath $incompleteTranscriptPath),
    (Convert-ToEvidenceRelativePath $completePreflightPath),
    (Convert-ToEvidenceRelativePath $completeTranscriptPath),
    (Convert-ToEvidenceRelativePath $importTranscriptPath)
)
foreach ($file in @(Get-ChildItem -LiteralPath $importSnapshotPath -Recurse -File)) {
    $generatedFiles += (Convert-ToEvidenceRelativePath $file.FullName)
}

$sourceFiles = @(
    "production-handoff-owner-response-bundle-kit-manifest.json",
    "production-handoff-owner-response-bundle-kit/README.md",
    "production-handoff-owner-response-bundle-kit/owner-response-bundle-request-draft.md",
    "production-handoff-owner-response-bundle-kit/verify-owner-response-bundle.ps1",
    "production-handoff-owner-response-bundle-kit/import-owner-response-bundle.ps1",
    "production-handoff-owner-response-bundle-kit/owner-response-bundle-template/owner-contact-roster.json",
    "production-handoff-owner-response-bundle-kit/owner-response-bundle-template/owner-response-bundle-manifest.json",
    "production-handoff-owner-input-request-pack-manifest.json"
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_owner_response_bundle_kit_workflow_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    probeDir = $probePath
    workDir = $workPath
    copiedKitDir = $copiedKitPath
    isolatedEvidenceBundleDir = $isolatedEvidencePath
    ownerContactCount = [int]$ownerContactCount
    requiredEvidenceFileCount = [int]$kitRequiredEvidenceFileCount
    writtenEvidenceFileCount = [int]$writtenEvidenceFileCount
    importedEvidenceFileCount = [int]@($importedEvidenceFiles).Count
    emptyTemplateRejected = [bool]$emptyTemplateRejected
    emptyTemplateStatus = [string](Get-JsonValue $incompletePreflight "status" "")
    emptyTemplateInvalidContactCount = Convert-ToInt (Get-JsonValue $incompletePreflight "invalidContactCount" 0)
    emptyTemplateMissingEvidenceFileCount = Convert-ToInt (Get-JsonValue $incompletePreflight "missingEvidenceFileCount" 0)
    completeTemplateAccepted = [bool]$completeTemplateAccepted
    completeTemplateStatus = [string](Get-JsonValue $completePreflight "status" "")
    completeTemplateConfiguredContactCount = Convert-ToInt (Get-JsonValue $completePreflight "configuredContactCount" 0)
    completeTemplateMissingEvidenceFileCount = Convert-ToInt (Get-JsonValue $completePreflight "missingEvidenceFileCount" 0)
    importHelperSucceeded = [bool]$importSucceeded
    importCopiedBundle = [bool]$importCopiedBundle
    autoAcceptanceCommandsDocumented = [bool]$autoAcceptanceCommandsDocumented
    autoAcceptanceZipCommandDocumented = [bool]$autoAcceptanceZipCommandDocumented
    ownerResponseBundleAutoAcceptanceCommand = $ownerResponseBundleAutoAcceptanceCommand
    ownerResponseBundleZipAutoAcceptanceCommand = $ownerResponseBundleZipAutoAcceptanceCommand
    ownerResponseBundleZipEnvironmentVariable = $ownerResponseBundleZipEnvironmentVariable
    importedRosterPath = $importedRosterPath
    importedInboxPath = $importedInboxPath
    releasePipelineSendsEmail = $false
    emailSent = $false
    confirmationTokenCreated = $false
    mailAuthorizationCheckedByPipeline = $false
    realHostProjectEvidenceAccepted = $false
    externalEvidenceAccepted = $false
    releasePipelineUsesFixture = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "owner_response_bundle_kit_workflow_probe_only"
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
    throw "Production handoff owner response bundle kit workflow probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production handoff owner response bundle kit workflow probe manifest: $manifestFullPath"
Write-Output "Production handoff owner response bundle kit workflow probe report: $reportFullPath"
Write-Output "PASS AI TestPilot production handoff owner response bundle kit workflow probe"
