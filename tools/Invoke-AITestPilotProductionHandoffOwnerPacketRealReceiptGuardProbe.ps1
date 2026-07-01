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
    $ProbeDir = Join-Path $EvidenceBundleDir "production-handoff-owner-packet-real-receipt-guard-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-handoff-owner-packet-real-receipt-guard-probe-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-handoff-owner-packet-real-receipt-guard-probe.md"
}

function Resolve-FullPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
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

function Convert-ToSafeFileName {
    param([string]$Value)

    $safe = $Value -replace "[^A-Za-z0-9_.-]+", "-"
    $safe = $safe.Trim("-")
    if ([string]::IsNullOrWhiteSpace($safe)) {
        return "owner"
    }

    return $safe
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

function New-OwnerPacketReceiptSet {
    param(
        [string]$ReceiptDir,
        [string]$MessagePrefix
    )

    if (Test-Path $ReceiptDir) {
        Remove-Item -LiteralPath $ReceiptDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force $ReceiptDir | Out-Null

    $index = 1
    foreach ($entry in $queueEntries) {
        $owner = [string](Get-JsonValue $entry "owner" "")
        $area = [string](Get-JsonValue $entry "area" "")
        $contact = @($contactEntries | Where-Object {
                [string](Get-JsonValue $_ "owner" "") -eq $owner -and
                [string](Get-JsonValue $_ "area" "") -eq $area
            } | Select-Object -First 1)
        if ($contact.Count -gt 0) {
            $contact = $contact[0]
        }
        else {
            throw "Missing accepted contact for $owner / $area."
        }

        $messageId = "{0}_{1:000}" -f $MessagePrefix, $index
        $receipt = [ordered]@{
            schemaVersion = "aitestpilot.production_handoff_owner_packet_send_receipt.v1"
            generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
            owner = $owner
            area = $area
            recipient = [string](Get-JsonValue $contact "emailAddress" "")
            subject = [string](Get-JsonValue $entry "subject" "")
            bodyFile = [string](Get-JsonValue $entry "bodyFile" "")
            attachment = ".\production-handoff-export.zip"
            confirmationTokenSupplied = $true
            prepareConfirmation = $false
            agentlyCliExitCode = 0
            messageId = $messageId
            queued = $false
            sendSucceeded = $true
            releasePipelineGenerated = $false
            realDeliveryVerified = $false
            cliOutput = @("{ ""ok"": true, ""data"": { ""message_id"": ""$messageId"" } }")
        }
        $receiptPath = Join-Path $ReceiptDir ((Convert-ToSafeFileName $owner) + ".json")
        $receipt | ConvertTo-Json -Depth 8 | Set-Content -Path $receiptPath -Encoding UTF8
        $index += 1
    }
}

function Invoke-OwnerPacketReceiptIntake {
    param(
        [string]$Name,
        [string]$ReceiptDir,
        [switch]$ContractFixtureMode,
        [switch]$ConfirmLocalOwnerPacketReceipts
    )

    $outputPath = Join-Path $probePath "$Name-output.txt"
    $manifestPathForRun = Join-Path $probePath "$Name-manifest.json"
    $reportPathForRun = Join-Path $probePath "$Name.md"
    $powerShellArgs = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionHandoffOwnerPacketDispatchReceiptIntake.ps1"),
        "-EvidenceBundleDir",
        $acceptedIntakeBundlePath,
        "-ReceiptDir",
        $ReceiptDir,
        "-ContactRosterPath",
        (Join-Path $acceptedIntakeBundlePath "production-handoff-contact-roster.json"),
        "-ManifestPath",
        $manifestPathForRun,
        "-ReportPath",
        $reportPathForRun,
        "-RequireReceipts"
    )
    if ([bool]$ContractFixtureMode) {
        $powerShellArgs += "-ContractFixtureMode"
    }
    if ([bool]$ConfirmLocalOwnerPacketReceipts) {
        $powerShellArgs += "-ConfirmLocalOwnerPacketReceipts"
    }

    $oldErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & powershell.exe @powerShellArgs 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }
    @($output | ForEach-Object { [string]$_ }) | Set-Content -Path $outputPath -Encoding UTF8

    $manifest = $null
    if (Test-Path $manifestPathForRun) {
        $manifest = Read-JsonFile $manifestPathForRun "$Name owner packet receipt intake manifest"
    }

    return [ordered]@{
        name = $Name
        exitCode = [int]$exitCode
        outputPath = $outputPath
        manifestPath = $manifestPathForRun
        reportPath = $reportPathForRun
        manifest = $manifest
    }
}

$evidenceBundlePath = Resolve-FullPath $EvidenceBundleDir
$probePath = Resolve-FullPath $ProbeDir
$manifestFullPath = Resolve-FullPath $ManifestPath
$reportFullPath = Resolve-FullPath $ReportPath

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if (Test-Path $probePath) {
    Remove-Item -LiteralPath $probePath -Recurse -Force
}
New-Item -ItemType Directory -Force $probePath | Out-Null
New-Item -ItemType Directory -Force (Split-Path $manifestFullPath -Parent) | Out-Null
New-Item -ItemType Directory -Force (Split-Path $reportFullPath -Parent) | Out-Null

$sendReadinessManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-send-readiness-manifest.json") "Production handoff send readiness manifest"
$localWorkflowProbeManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-send-local-workflow-probe-manifest.json") "Production handoff send local workflow probe manifest"
$receiptIntakeProbeManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-owner-packet-dispatch-receipt-intake-probe-manifest.json") "Production handoff owner packet dispatch receipt intake probe manifest"
$acceptedIntakeBundlePath = Join-Path $evidenceBundlePath "production-handoff-owner-contact-external-intake-probe\intake-bundle"
$acceptedSendQueue = Read-JsonFile (Join-Path $acceptedIntakeBundlePath "production-handoff-send\production-handoff-send-queue.json") "Accepted contact send queue"
$acceptedContacts = Read-JsonFile (Join-Path $acceptedIntakeBundlePath "production-handoff-contact-roster.json") "Accepted contact roster"
$queueEntries = @(Convert-ToArray (Get-JsonValue $acceptedSendQueue "entries" @()))
$contactEntries = @(Convert-ToArray (Get-JsonValue $acceptedContacts "entries" @()))
$ownerContactCount = $queueEntries.Count
$intakeScriptPath = Join-Path $repoRoot "tools\Invoke-AITestPilotProductionHandoffOwnerPacketDispatchReceiptIntake.ps1"
$intakeScriptText = Get-Content -Path $intakeScriptPath -Encoding UTF8 -Raw

$unconfirmedReceiptDir = Join-Path $probePath "valid-owner-packet-receipts-without-operator-confirmation"
$contractConfirmedReceiptDir = Join-Path $probePath "contract-owner-packet-receipts-with-operator-confirmation"
New-OwnerPacketReceiptSet -ReceiptDir $unconfirmedReceiptDir -MessagePrefix "msg_owner_packet_guard"
New-OwnerPacketReceiptSet -ReceiptDir $contractConfirmedReceiptDir -MessagePrefix "msg_contract_owner_packet_guard"

$unconfirmedResult = Invoke-OwnerPacketReceiptIntake `
    -Name "valid-receipts-without-operator-confirmation" `
    -ReceiptDir $unconfirmedReceiptDir
$contractConfirmedResult = Invoke-OwnerPacketReceiptIntake `
    -Name "contract-receipts-with-operator-confirmation" `
    -ReceiptDir $contractConfirmedReceiptDir `
    -ContractFixtureMode `
    -ConfirmLocalOwnerPacketReceipts

$unconfirmedManifest = $unconfirmedResult.manifest
$contractConfirmedManifest = $contractConfirmedResult.manifest
$confirmSwitchAvailable = $intakeScriptText.Contains("ConfirmLocalOwnerPacketReceipts")

$checks = @()
Add-ProbeCheck "owner_packet_real_receipt_guard_sources_available" `
    ($sendReadinessManifest.status -eq "PASS" -and
        $localWorkflowProbeManifest.status -eq "PASS" -and
        $receiptIntakeProbeManifest.status -eq "PASS" -and
        (Test-Path $intakeScriptPath) -and
        $confirmSwitchAvailable) `
    "Real receipt guard probe must use passing owner-packet send evidence, receipt intake probe evidence, and an intake script with ConfirmLocalOwnerPacketReceipts."
Add-ProbeCheck "valid_receipts_without_operator_confirmation_not_sent" `
    ($unconfirmedResult.exitCode -eq 0 -and
        $unconfirmedManifest.status -eq "PASS" -and
        (Get-JsonValue $unconfirmedManifest "receiptAcceptedCount" 0) -eq $ownerContactCount -and
        (Get-JsonValue $unconfirmedManifest "ownerPacketDispatchStatus" "") -eq "VALID_RECEIPTS_PENDING_OPERATOR_REAL_SEND_CONFIRMATION" -and
        (Get-JsonValue $unconfirmedManifest "operatorRealSendConfirmationRequired" $false) -and
        -not (Get-JsonValue $unconfirmedManifest "operatorRealSendConfirmed" $true) -and
        -not (Get-JsonValue $unconfirmedManifest "realOwnerPacketEmailSent" $true) -and
        -not (Get-JsonValue $unconfirmedManifest "emailSent" $true)) `
    "Valid owner-packet receipts without explicit operator confirmation must not set realOwnerPacketEmailSent."
Add-ProbeCheck "contract_mode_overrides_operator_confirmation" `
    ($contractConfirmedResult.exitCode -eq 0 -and
        $contractConfirmedManifest.status -eq "PASS" -and
        (Get-JsonValue $contractConfirmedManifest "receiptAcceptedCount" 0) -eq $ownerContactCount -and
        (Get-JsonValue $contractConfirmedManifest "contractFixtureMode" $false) -and
        (Get-JsonValue $contractConfirmedManifest "confirmLocalOwnerPacketReceipts" $false) -and
        (Get-JsonValue $contractConfirmedManifest "ownerPacketDispatchStatus" "") -eq "CONTRACT_RECEIPTS_ACCEPTED_NOT_REAL_SEND" -and
        -not (Get-JsonValue $contractConfirmedManifest "operatorRealSendConfirmationRequired" $true) -and
        -not (Get-JsonValue $contractConfirmedManifest "operatorRealSendConfirmed" $true) -and
        -not (Get-JsonValue $contractConfirmedManifest "realOwnerPacketEmailSent" $true) -and
        -not (Get-JsonValue $contractConfirmedManifest "emailSent" $true)) `
    "Contract fixture mode must not claim a real owner-packet send even if the confirmation switch is supplied."
Add-ProbeCheck "canonical_owner_packet_boundary_preserved" `
    ((Get-JsonValue $sendReadinessManifest "sendReadinessStatus" "") -eq "BLOCKED_MISSING_OWNER_EMAILS" -and
        -not (Get-JsonValue $sendReadinessManifest "automaticEmailSendReady" $true) -and
        -not (Get-JsonValue $localWorkflowProbeManifest "realOwnerPacketEmailSent" $true)) `
    "Canonical owner-packet send readiness must stay blocked until real contacts, local auth, receipts, and operator confirmation exist."
Add-ProbeCheck "release_pipeline_owner_packet_email_boundary_preserved" `
    (-not (Get-JsonValue $unconfirmedManifest "releasePipelineSendsEmail" $true) -and
        -not (Get-JsonValue $contractConfirmedManifest "releasePipelineSendsEmail" $true) -and
        (Get-JsonValue $unconfirmedManifest "productionOutputBoundary" "") -eq "owner_packet_dispatch_receipts_pending_operator_confirmation" -and
        (Get-JsonValue $contractConfirmedManifest "productionOutputBoundary" "") -eq "owner_packet_dispatch_receipts_contract_only") `
    "Guard probe must keep release-pipeline owner-packet email sending false while proving finalization boundaries."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }
$unconfirmedDispatchStatusForReport = Get-JsonValue $unconfirmedManifest "ownerPacketDispatchStatus" ""
$unconfirmedRealOwnerPacketEmailSentForReport = Get-JsonValue $unconfirmedManifest "realOwnerPacketEmailSent" $true
$contractConfirmedDispatchStatusForReport = Get-JsonValue $contractConfirmedManifest "ownerPacketDispatchStatus" ""
$contractConfirmedRealOwnerPacketEmailSentForReport = Get-JsonValue $contractConfirmedManifest "realOwnerPacketEmailSent" $true

$reportLines = @(
    "# AI TestPilot Production Handoff Owner Packet Real Receipt Guard Probe",
    "",
    "- Status: $status",
    "- Owner contacts: $ownerContactCount",
    "- Unconfirmed dispatch status: $unconfirmedDispatchStatusForReport",
    "- Unconfirmed real owner packet email sent: $unconfirmedRealOwnerPacketEmailSentForReport",
    "- Contract confirmed dispatch status: $contractConfirmedDispatchStatusForReport",
    "- Contract confirmed real owner packet email sent: $contractConfirmedRealOwnerPacketEmailSentForReport",
    "",
    "## Boundary",
    "",
    "- Valid owner-packet receipts remain pending until operator real-send confirmation.",
    "- Contract mode does not claim a real send even when the confirmation switch is supplied.",
    "- Release pipeline does not send owner-packet email.",
    "",
    "## Checks",
    "",
    "| Check | Passed | Message |",
    "| --- | --- | --- |"
)
foreach ($check in $checks) {
    $reportLines += "| $(Format-MarkdownCell $check.name) | $($check.passed) | $(Format-MarkdownCell $check.message) |"
}
$reportLines | Set-Content -Path $reportFullPath -Encoding UTF8

$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestFullPath),
    (Convert-ToEvidenceRelativePath $reportFullPath),
    (Convert-ToEvidenceRelativePath $unconfirmedReceiptDir),
    (Convert-ToEvidenceRelativePath $contractConfirmedReceiptDir),
    (Convert-ToEvidenceRelativePath $unconfirmedResult.outputPath),
    (Convert-ToEvidenceRelativePath $unconfirmedResult.manifestPath),
    (Convert-ToEvidenceRelativePath $unconfirmedResult.reportPath),
    (Convert-ToEvidenceRelativePath $contractConfirmedResult.outputPath),
    (Convert-ToEvidenceRelativePath $contractConfirmedResult.manifestPath),
    (Convert-ToEvidenceRelativePath $contractConfirmedResult.reportPath)
)
$sourceFiles = @(
    "production-handoff-send-readiness-manifest.json",
    "production-handoff-send-local-workflow-probe-manifest.json",
    "production-handoff-owner-packet-dispatch-receipt-intake-probe-manifest.json",
    "production-handoff-owner-contact-external-intake-probe/intake-bundle/production-handoff-send/production-handoff-send-queue.json",
    "production-handoff-owner-contact-external-intake-probe/intake-bundle/production-handoff-contact-roster.json"
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_owner_packet_real_receipt_guard_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    probeDir = $probePath
    ownerContactCount = [int]$ownerContactCount
    confirmLocalOwnerPacketReceiptsSwitchAvailable = [bool]$confirmSwitchAvailable
    unconfirmedReceiptAcceptedCount = Convert-ToInt (Get-JsonValue $unconfirmedManifest "receiptAcceptedCount" 0)
    unconfirmedOwnerPacketDispatchStatus = Get-JsonValue $unconfirmedManifest "ownerPacketDispatchStatus" ""
    unconfirmedOperatorRealSendConfirmationRequired = Get-JsonValue $unconfirmedManifest "operatorRealSendConfirmationRequired" $false
    unconfirmedOperatorRealSendConfirmed = Get-JsonValue $unconfirmedManifest "operatorRealSendConfirmed" $true
    unconfirmedRealOwnerPacketEmailSent = Get-JsonValue $unconfirmedManifest "realOwnerPacketEmailSent" $true
    contractConfirmedReceiptAcceptedCount = Convert-ToInt (Get-JsonValue $contractConfirmedManifest "receiptAcceptedCount" 0)
    contractConfirmedOwnerPacketDispatchStatus = Get-JsonValue $contractConfirmedManifest "ownerPacketDispatchStatus" ""
    contractConfirmedRealOwnerPacketEmailSent = Get-JsonValue $contractConfirmedManifest "realOwnerPacketEmailSent" $true
    releasePipelineSendsEmail = $false
    realOwnerPacketEmailSent = $false
    emailSent = $false
    realHostProjectEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "owner_packet_real_receipt_guard_contract_probe_only"
    sourceFiles = @($sourceFiles)
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles + $sourceFiles)
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
}

$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestFullPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Production handoff owner packet real receipt guard probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production handoff owner packet real receipt guard probe manifest: $manifestFullPath"
Write-Output "Production handoff owner packet real receipt guard probe report: $reportFullPath"
Write-Output "PASS AI TestPilot production handoff owner packet real receipt guard probe"
