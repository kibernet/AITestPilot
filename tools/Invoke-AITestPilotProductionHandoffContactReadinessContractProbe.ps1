[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ProbeBundleDir,
    [string]$ManifestPath,
    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Test-PathWithinRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root)
    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    if ($fullPath.Equals($fullRoot, $comparison)) {
        return $true
    }

    if (-not $fullRoot.EndsWith(([System.IO.Path]::DirectorySeparatorChar).ToString())) {
        $fullRoot = $fullRoot + [System.IO.Path]::DirectorySeparatorChar
    }

    return $fullPath.StartsWith($fullRoot, $comparison)
}

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ProbeBundleDir)) {
    $ProbeBundleDir = Join-Path $EvidenceBundleDir "production-handoff-contact-readiness-contract-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-handoff-contact-readiness-contract-probe-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-handoff-contact-readiness-contract-probe.md"
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
    if (-not (Test-PathWithinRoot $fullPath $repoRoot)) {
        throw "$Label must stay under repo root: $fullPath"
    }

    return $fullPath
}

function Convert-ToEvidenceRelativePath {
    param([string]$Path)

    $fullPath = Resolve-FullPath $Path
    if (-not $fullPath.StartsWith($evidenceBundlePath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Probe file must stay under evidence bundle: $fullPath"
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

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }

    return $property.Value
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
$probeBundlePath = Assert-PathUnderRepo $ProbeBundleDir "ProbeBundleDir"
$manifestPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportPath = Assert-PathUnderRepo $ReportPath "ReportPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if (Test-Path $probeBundlePath) {
    Remove-Item -LiteralPath $probeBundlePath -Recurse -Force
}

New-Item -ItemType Directory -Force $probeBundlePath | Out-Null

$defaultContactReadiness = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-contact-readiness-manifest.json") "Default production handoff contact readiness manifest"
$dispatchManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-dispatch-manifest.json") "Production handoff dispatch manifest"

$acceptedRosterEntries = @()
foreach ($entry in @(Convert-ToArray (Get-JsonValue $dispatchManifest "dispatchEntries" @()))) {
    $owner = [string](Get-JsonValue $entry "owner" "")
    $area = [string](Get-JsonValue $entry "area" "")
    $slug = Convert-ToSlug $owner
    $acceptedRosterEntries += [ordered]@{
        owner = $owner
        area = $area
        contactSlug = $slug
        emailAddress = ($slug + "@example.invalid")
        configured = $true
        notes = "Contract fixture address only. Replace with the real owner mailbox before live dispatch."
    }
}

$acceptedRosterPath = Join-Path $probeBundlePath "accepted-contact-roster.json"
$acceptedReadinessManifestPath = Join-Path $probeBundlePath "accepted-contact-readiness-manifest.json"
$acceptedReadinessReportPath = Join-Path $probeBundlePath "accepted-contact-readiness.md"

$acceptedRoster = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_contact_roster.v1"
    status = "CONTACTS_CONFIGURED"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    ownerContactCount = [int]$acceptedRosterEntries.Count
    configuredContactCount = [int]$acceptedRosterEntries.Count
    fixtureOnly = $true
    entries = @($acceptedRosterEntries)
}

$acceptedRoster | ConvertTo-Json -Depth 12 | Set-Content -Path $acceptedRosterPath -Encoding UTF8

& (Join-Path $PSScriptRoot "Invoke-AITestPilotProductionHandoffContactReadiness.ps1") `
    -EvidenceBundleDir $evidenceBundlePath `
    -ContactRosterPath $acceptedRosterPath `
    -ManifestPath $acceptedReadinessManifestPath `
    -ReportPath $acceptedReadinessReportPath | Out-Null

$acceptedContactReadiness = Read-JsonFile $acceptedReadinessManifestPath "Accepted production handoff contact readiness manifest"

$ownerContactCount = [int](Get-JsonValue $defaultContactReadiness "ownerContactCount" 0)
$defaultPackageContactReadinessStillBlocked = $defaultContactReadiness.status -eq "PASS" -and
    [int](Get-JsonValue $defaultContactReadiness "missingOwnerContactCount" -1) -eq $ownerContactCount -and
    [int](Get-JsonValue $defaultContactReadiness "configuredOwnerContactCount" -1) -eq 0 -and
    -not [bool](Get-JsonValue $defaultContactReadiness "contactRosterComplete" $true) -and
    -not [bool](Get-JsonValue $defaultContactReadiness "realOwnerEmailAddressesConfigured" $true) -and
    -not [bool](Get-JsonValue $defaultContactReadiness "automaticEmailSendReady" $true) -and
    -not [bool](Get-JsonValue $defaultContactReadiness "realHostProjectEvidenceAccepted" $true)

$acceptedContactReadinessPassed = $acceptedContactReadiness.status -eq "PASS" -and
    (Get-JsonValue $acceptedContactReadiness "schemaVersion" "") -eq "aitestpilot.production_handoff_contact_readiness.v1" -and
    [int](Get-JsonValue $acceptedContactReadiness "ownerContactCount" -1) -eq $ownerContactCount -and
    [int](Get-JsonValue $acceptedContactReadiness "configuredOwnerContactCount" -1) -eq $ownerContactCount -and
    [int](Get-JsonValue $acceptedContactReadiness "missingOwnerContactCount" -1) -eq 0 -and
    [int](Get-JsonValue $acceptedContactReadiness "invalidOwnerContactCount" -1) -eq 0 -and
    [bool](Get-JsonValue $acceptedContactReadiness "contactRosterComplete" $false) -and
    [bool](Get-JsonValue $acceptedContactReadiness "configuredContactsAccepted" $false) -and
    [bool](Get-JsonValue $acceptedContactReadiness "realOwnerEmailAddressesConfigured" $false) -and
    [bool](Get-JsonValue $acceptedContactReadiness "contactReportContentValidated" $false) -and
    [int](Get-JsonValue $acceptedContactReadiness "failedCheckCount" 1) -eq 0

$acceptedSendBoundaryPreserved = $acceptedContactReadinessPassed -and
    -not [bool](Get-JsonValue $acceptedContactReadiness "automaticEmailSendReady" $true) -and
    [int](Get-JsonValue $acceptedContactReadiness "pendingDispatchCount" -1) -eq [int](Get-JsonValue $dispatchManifest "pendingDispatchCount" -2) -and
    -not [bool](Get-JsonValue $acceptedContactReadiness "releasePipelineUsesFixture" $true) -and
    -not [bool](Get-JsonValue $acceptedContactReadiness "realHostProjectEvidenceAccepted" $true) -and
    -not [bool](Get-JsonValue $acceptedContactReadiness "fixtureEvidencePromoted" $true)

$reportGenerated = Test-Path $reportPath
$acceptedRosterUnderProbeBundle = (Resolve-FullPath $acceptedRosterPath).StartsWith($probeBundlePath, [System.StringComparison]::OrdinalIgnoreCase)

$checks = @()
Add-ProbeCheck "default_contact_boundary_preserved" `
    $defaultPackageContactReadinessStillBlocked `
    "Default package-release contact readiness must still show missing real owner email addresses."
Add-ProbeCheck "accepted_fixture_contact_roster_generated" `
    ((Test-Path $acceptedRosterPath) -and [int]$acceptedRoster.ownerContactCount -eq $ownerContactCount -and [int]$acceptedRoster.configuredContactCount -eq $ownerContactCount) `
    "Contract probe must generate one configured fixture contact for each owner packet."
Add-ProbeCheck "accepted_contact_readiness_passed" `
    $acceptedContactReadinessPassed `
    "Contact readiness must pass when a complete configured contact roster is supplied."
Add-ProbeCheck "send_boundary_preserved" `
    $acceptedSendBoundaryPreserved `
    "Configured contact readiness must not claim that emails were automatically sent or that fixture evidence is real."

$reportLines = @(
    "# AI TestPilot Production Handoff Contact Readiness Contract Probe",
    "",
    "Schema: ``aitestpilot.production_handoff_contact_readiness_contract_probe.v1``",
    "Generated at UTC: $((Get-Date).ToUniversalTime().ToString("O"))",
    "",
    "## Summary",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Default package contact readiness still blocked | $defaultPackageContactReadinessStillBlocked |",
    "| Accepted fixture contact readiness passed | $acceptedContactReadinessPassed |",
    "| Accepted configured owner contacts | $([int](Get-JsonValue $acceptedContactReadiness "configuredOwnerContactCount" 0)) |",
    "| Accepted missing owner contacts | $([int](Get-JsonValue $acceptedContactReadiness "missingOwnerContactCount" 0)) |",
    "| Accepted automatic email send ready | $([bool](Get-JsonValue $acceptedContactReadiness "automaticEmailSendReady" $false)) |",
    "",
    "## Boundary",
    "",
    "- Fixture contact addresses use ``example.invalid`` and are not real owner mailboxes.",
    "- This probe does not send email.",
    "- The default package-release contact readiness manifest remains the source of truth for current missing real contacts."
)

$reportLines | Set-Content -Path $reportPath -Encoding UTF8
$reportGenerated = Test-Path $reportPath
Add-ProbeCheck "probe_report_generated" `
    $reportGenerated `
    "Contact readiness contract probe must generate a Markdown report."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$files = @(
    (Convert-ToEvidenceRelativePath $manifestPath),
    (Convert-ToEvidenceRelativePath $reportPath),
    (Convert-ToEvidenceRelativePath $acceptedRosterPath),
    (Convert-ToEvidenceRelativePath $acceptedReadinessManifestPath),
    (Convert-ToEvidenceRelativePath $acceptedReadinessReportPath)
)

$sourceFiles = @(
    "production-handoff-contact-readiness-manifest.json",
    "production-handoff-dispatch-manifest.json"
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_contact_readiness_contract_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    probeBundleDir = $probeBundlePath
    reportPath = $reportPath
    acceptedContactRosterPath = $acceptedRosterPath
    acceptedContactReadinessManifestPath = $acceptedReadinessManifestPath
    acceptedContactReadinessReportPath = $acceptedReadinessReportPath
    acceptedFixtureContactRosterGenerated = (Test-Path $acceptedRosterPath)
    acceptedFixtureContactRosterUnderProbeBundle = [bool]$acceptedRosterUnderProbeBundle
    defaultPackageContactReadinessStillBlocked = [bool]$defaultPackageContactReadinessStillBlocked
    defaultMissingOwnerContactCount = [int](Get-JsonValue $defaultContactReadiness "missingOwnerContactCount" 0)
    defaultAutomaticEmailSendReady = [bool](Get-JsonValue $defaultContactReadiness "automaticEmailSendReady" $false)
    acceptedContactReadinessPassed = [bool]$acceptedContactReadinessPassed
    acceptedConfiguredOwnerContactCount = [int](Get-JsonValue $acceptedContactReadiness "configuredOwnerContactCount" 0)
    acceptedMissingOwnerContactCount = [int](Get-JsonValue $acceptedContactReadiness "missingOwnerContactCount" 0)
    acceptedInvalidOwnerContactCount = [int](Get-JsonValue $acceptedContactReadiness "invalidOwnerContactCount" 0)
    acceptedContactRosterComplete = [bool](Get-JsonValue $acceptedContactReadiness "contactRosterComplete" $false)
    acceptedConfiguredContactsAccepted = [bool](Get-JsonValue $acceptedContactReadiness "configuredContactsAccepted" $false)
    acceptedRealOwnerEmailAddressesConfigured = [bool](Get-JsonValue $acceptedContactReadiness "realOwnerEmailAddressesConfigured" $false)
    acceptedAutomaticEmailSendReady = [bool](Get-JsonValue $acceptedContactReadiness "automaticEmailSendReady" $false)
    acceptedSendBoundaryPreserved = [bool]$acceptedSendBoundaryPreserved
    releasePipelineUsesFixture = $false
    realHostProjectEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "accepted_fixture_owner_contact_readiness_contract_only"
    sourceFiles = @($sourceFiles)
    generatedFiles = @($files)
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
    files = @($files + $sourceFiles)
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Production handoff contact readiness contract probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production handoff contact readiness contract probe manifest: $manifestPath"
Write-Output "PASS AI TestPilot production handoff contact readiness contract probe"
