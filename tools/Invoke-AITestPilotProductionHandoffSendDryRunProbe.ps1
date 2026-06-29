[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ProbeDir,
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
    $ProbeDir = Join-Path $EvidenceBundleDir "production-handoff-send-dry-run-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-handoff-send-dry-run-probe-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-handoff-send-dry-run-probe.md"
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

function Invoke-DryRun {
    param(
        [string]$ScriptPath,
        [string]$BundlePath,
        [string]$OutputPath
    )

    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -EvidenceBundleDir $BundlePath 2>&1
    $exitCode = $LASTEXITCODE
    $text = [string]::Join([Environment]::NewLine, @($output | ForEach-Object { [string]$_ }))
    $text | Set-Content -Path $OutputPath -Encoding UTF8

    return [ordered]@{
        exitCode = [int]$exitCode
        outputPath = $OutputPath
        outputText = $text
    }
}

function Count-TextMatches {
    param(
        [string]$Text,
        [string]$Pattern
    )

    return [regex]::Matches($Text, [regex]::Escape($Pattern)).Count
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
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if (Test-Path $probePath) {
    Remove-Item -LiteralPath $probePath -Recurse -Force
}
New-Item -ItemType Directory -Force $probePath | Out-Null

$sendReadinessManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-send-readiness-manifest.json") "Production handoff send readiness manifest"
$ownerContactExternalIntakeProbeManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-owner-contact-external-intake-probe-manifest.json") "Production handoff owner contact external intake probe manifest"

$defaultSendScriptPath = Join-Path $evidenceBundlePath "production-handoff-send\send-owner-packets.ps1"
$acceptedIntakeBundlePath = Join-Path $evidenceBundlePath "production-handoff-owner-contact-external-intake-probe\intake-bundle"
$acceptedSendScriptPath = Join-Path $acceptedIntakeBundlePath "production-handoff-send\send-owner-packets.ps1"

$defaultOutputPath = Join-Path $probePath "default-send-dry-run-output.txt"
$acceptedOutputPath = Join-Path $probePath "accepted-contact-send-dry-run-output.txt"

$defaultDryRun = Invoke-DryRun -ScriptPath $defaultSendScriptPath -BundlePath $evidenceBundlePath -OutputPath $defaultOutputPath
$acceptedDryRun = Invoke-DryRun -ScriptPath $acceptedSendScriptPath -BundlePath $acceptedIntakeBundlePath -OutputPath $acceptedOutputPath

$defaultText = [string](Get-JsonValue $defaultDryRun "outputText" "")
$acceptedText = [string](Get-JsonValue $acceptedDryRun "outputText" "")
$ownerContactCount = Convert-ToInt (Get-JsonValue $sendReadinessManifest "ownerContactCount" 0)
$defaultBlockedPreviewCount = Count-TextMatches $defaultText "Blocked send command for"
$acceptedPreparedPreviewCount = Count-TextMatches $acceptedText "Prepared send command for"
$defaultDryRunSucceeded = (Convert-ToInt (Get-JsonValue $defaultDryRun "exitCode" -1)) -eq 0
$acceptedDryRunSucceeded = (Convert-ToInt (Get-JsonValue $acceptedDryRun "exitCode" -1)) -eq 0
$authorizationNotRequiredForDryRun = -not $defaultText.Contains("authorization required") -and
    -not $acceptedText.Contains("authorization required") -and
    -not $defaultText.Contains("agently-cli is not logged in") -and
    -not $acceptedText.Contains("agently-cli is not logged in")
$dryRunDoesNotCreateConfirmationToken = -not $defaultText.Contains("ctk_") -and
    -not $acceptedText.Contains("ctk_")

$reportLines = @(
    "# AI TestPilot Production Handoff Send Dry Run Probe",
    "",
    "Schema: ``aitestpilot.production_handoff_send_dry_run_probe.v1``",
    "Generated at UTC: $((Get-Date).ToUniversalTime().ToString("O"))",
    "",
    "## Summary",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Default dry run succeeded | $defaultDryRunSucceeded |",
    "| Default blocked preview count | $defaultBlockedPreviewCount |",
    "| Accepted-contact dry run succeeded | $acceptedDryRunSucceeded |",
    "| Accepted-contact prepared preview count | $acceptedPreparedPreviewCount |",
    "| Authorization not required for dry run | $authorizationNotRequiredForDryRun |",
    "| Confirmation token created | False |",
    "| Email sent | False |",
    "",
    "## Outputs",
    "",
    "| Output | Path |",
    "| --- | --- |",
    "| Default missing-contact dry run | $(Format-MarkdownCell (Convert-ToEvidenceRelativePath $defaultOutputPath)) |",
    "| Accepted-contact dry run | $(Format-MarkdownCell (Convert-ToEvidenceRelativePath $acceptedOutputPath)) |",
    "",
    "## Boundary",
    "",
    "- Dry run previews the queue only.",
    "- Dry run does not require agently-cli authorization.",
    "- Dry run does not request confirmation tokens.",
    "- Dry run does not send email."
)
$reportLines | Set-Content -Path $reportFullPath -Encoding UTF8
$reportContent = Get-Content -Path $reportFullPath -Encoding UTF8 -Raw
$reportContentValidated = $reportContent.Contains("Send Dry Run Probe") -and
    $reportContent.Contains("Authorization not required for dry run") -and
    $reportContent.Contains("Dry run does not send email") -and
    -not $reportContent.Contains("System.Collections") -and
    -not $reportContent.Contains("@{")

$checks = @()
Add-ProbeCheck "send_dry_run_sources_available" `
    ($sendReadinessManifest.status -eq "PASS" -and
        (Convert-ToBool (Get-JsonValue $sendReadinessManifest "sendScriptContentValidated" $false)) -and
        $ownerContactExternalIntakeProbeManifest.status -eq "PASS" -and
        (Convert-ToBool (Get-JsonValue $ownerContactExternalIntakeProbeManifest "externalSendReadyForConfirmation" $false))) `
    "Send dry-run probe must be based on passing send readiness and owner contact external intake evidence."
Add-ProbeCheck "default_missing_contact_dry_run_preview" `
    ($defaultDryRunSucceeded -and $defaultBlockedPreviewCount -eq $ownerContactCount -and $defaultText.Contains("Dry run only")) `
    "Default dry run must complete without auth and show one blocked preview per missing owner contact."
Add-ProbeCheck "accepted_contact_dry_run_preview" `
    ($acceptedDryRunSucceeded -and $acceptedPreparedPreviewCount -eq $ownerContactCount -and $acceptedText.Contains("Dry run only")) `
    "Accepted-contact dry run must complete without auth and show one prepared preview per configured owner contact."
Add-ProbeCheck "dry_run_auth_boundary" `
    $authorizationNotRequiredForDryRun `
    "Dry run must not require local agently-cli authorization."
Add-ProbeCheck "dry_run_send_boundary" `
    ($dryRunDoesNotCreateConfirmationToken -and -not $defaultText.Contains("message id") -and -not $acceptedText.Contains("message id")) `
    "Dry run must not create confirmation tokens or send email."
Add-ProbeCheck "dry_run_report_content" `
    $reportContentValidated `
    "Send dry-run probe report must summarize dry-run previews and no-auth/no-send boundaries."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestFullPath),
    (Convert-ToEvidenceRelativePath $reportFullPath),
    (Convert-ToEvidenceRelativePath $defaultOutputPath),
    (Convert-ToEvidenceRelativePath $acceptedOutputPath)
)
$sourceFiles = @(
    "production-handoff-send-readiness-manifest.json",
    "production-handoff-send/production-handoff-send-queue.json",
    "production-handoff-send/send-owner-packets.ps1",
    "production-handoff-owner-contact-external-intake-probe-manifest.json",
    "production-handoff-owner-contact-external-intake-probe/intake-bundle/production-handoff-send-readiness-manifest.json",
    "production-handoff-owner-contact-external-intake-probe/intake-bundle/production-handoff-send/send-owner-packets.ps1"
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_send_dry_run_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    probeDir = $probePath
    reportPath = $reportFullPath
    ownerContactCount = [int]$ownerContactCount
    defaultDryRunSucceeded = [bool]$defaultDryRunSucceeded
    defaultDryRunExitCode = Convert-ToInt (Get-JsonValue $defaultDryRun "exitCode" -1)
    defaultBlockedPreviewCount = [int]$defaultBlockedPreviewCount
    acceptedContactDryRunSucceeded = [bool]$acceptedDryRunSucceeded
    acceptedContactDryRunExitCode = Convert-ToInt (Get-JsonValue $acceptedDryRun "exitCode" -1)
    acceptedContactPreparedPreviewCount = [int]$acceptedPreparedPreviewCount
    authorizationNotRequiredForDryRun = [bool]$authorizationNotRequiredForDryRun
    dryRunDoesNotCreateConfirmationToken = [bool]$dryRunDoesNotCreateConfirmationToken
    releasePipelineSendsEmail = $false
    emailSent = $false
    confirmationTokenCreated = $false
    realHostProjectEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "owner_send_dry_run_preview_only"
    sourceFiles = @($sourceFiles)
    generatedFiles = @($generatedFiles)
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
    files = @($generatedFiles + $sourceFiles)
}

New-Item -ItemType Directory -Force (Split-Path $manifestFullPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFullPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Production handoff send dry run probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production handoff send dry run probe manifest: $manifestFullPath"
Write-Output "Production handoff send dry run probe report: $reportFullPath"
Write-Output "PASS AI TestPilot production handoff send dry run probe"
