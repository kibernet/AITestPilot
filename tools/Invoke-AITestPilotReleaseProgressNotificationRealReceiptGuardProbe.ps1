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
    $ProbeDir = Join-Path $EvidenceBundleDir "release-progress-notification-real-receipt-guard-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "release-progress-notification-real-receipt-guard-probe-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "release-progress-notification-real-receipt-guard-probe.md"
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

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }

    return $property.Value
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

function New-Receipt {
    param(
        [string]$Path,
        [string]$MessageId
    )

    $receipt = [ordered]@{
        schemaVersion = "aitestpilot.release_progress_notification_send_receipt.v1"
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
        recipient = [string](Get-JsonValue $outboxManifest "recipient" "")
        subject = [string](Get-JsonValue $outboxManifest "subject" "")
        bodyFile = ".\release-progress-notification-outbox\big-node-progress-email.md"
        confirmationTokenSupplied = $true
        prepareConfirmation = $false
        agentlyCliExitCode = 0
        messageId = $MessageId
        sendSucceeded = $true
        releasePipelineGenerated = $false
        realDeliveryVerified = $false
        cliOutput = @("{ ""ok"": true, ""data"": { ""message_id"": ""$MessageId"" } }")
    }

    New-Item -ItemType Directory -Force (Split-Path $Path -Parent) | Out-Null
    $receipt | ConvertTo-Json -Depth 8 | Set-Content -Path $Path -Encoding UTF8
}

function Invoke-ReceiptIntake {
    param(
        [string]$Name,
        [string]$ReceiptPath,
        [string]$ManifestPath,
        [string]$ReportPath,
        [switch]$ContractFixtureMode,
        [switch]$ConfirmLocalSendReceipt
    )

    $outputPath = Join-Path $probePath "$Name-output.txt"
    $powerShellArgs = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        (Join-Path $repoRoot "tools\Invoke-AITestPilotReleaseProgressNotificationDispatchReceiptIntake.ps1"),
        "-EvidenceBundleDir",
        $evidenceBundlePath,
        "-ReceiptPath",
        $ReceiptPath,
        "-ManifestPath",
        $ManifestPath,
        "-ReportPath",
        $ReportPath,
        "-RequireReceipt"
    )
    if ([bool]$ContractFixtureMode) {
        $powerShellArgs += "-ContractFixtureMode"
    }
    if ([bool]$ConfirmLocalSendReceipt) {
        $powerShellArgs += "-ConfirmLocalSendReceipt"
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
    Set-Content -Path $outputPath -Value @($output | ForEach-Object { [string]$_ }) -Encoding UTF8

    $manifest = $null
    if (Test-Path $ManifestPath) {
        $manifest = Read-JsonFile $ManifestPath "$Name receipt intake manifest"
    }

    return [ordered]@{
        name = $Name
        exitCode = [int]$exitCode
        outputPath = $outputPath
        manifestPath = $ManifestPath
        reportPath = $ReportPath
        manifest = $manifest
    }
}

$evidenceBundlePath = Resolve-FullPath $EvidenceBundleDir
$probePath = Resolve-FullPath $ProbeDir
$manifestFullPath = Resolve-FullPath $ManifestPath
$reportFullPath = Resolve-FullPath $ReportPath

New-Item -ItemType Directory -Force $probePath | Out-Null
New-Item -ItemType Directory -Force (Split-Path $manifestFullPath -Parent) | Out-Null
New-Item -ItemType Directory -Force (Split-Path $reportFullPath -Parent) | Out-Null

$outboxManifest = Read-JsonFile (Join-Path $evidenceBundlePath "release-progress-notification-outbox-manifest.json") "Release progress notification outbox manifest"
$dispatchReceiptIntakeProbeManifest = Read-JsonFile (Join-Path $evidenceBundlePath "release-progress-notification-dispatch-receipt-intake-probe-manifest.json") "Release progress notification dispatch receipt intake probe manifest"
$localSendWorkflowProbeManifest = Read-JsonFile (Join-Path $evidenceBundlePath "release-progress-notification-local-send-workflow-probe-manifest.json") "Release progress notification local send workflow probe manifest"
$dispatchReceiptIntakePath = Join-Path $repoRoot "tools\Invoke-AITestPilotReleaseProgressNotificationDispatchReceiptIntake.ps1"
$dispatchReceiptIntakeContent = Get-Content -Path $dispatchReceiptIntakePath -Encoding UTF8 -Raw

$receiptPath = Join-Path $probePath "guard-progress-notification-send-receipt.json"
New-Receipt -Path $receiptPath -MessageId "msg_contract_guard_001"

$unconfirmedResult = Invoke-ReceiptIntake `
    -Name "valid-receipt-without-operator-confirmation" `
    -ReceiptPath $receiptPath `
    -ManifestPath (Join-Path $probePath "valid-receipt-without-operator-confirmation-manifest.json") `
    -ReportPath (Join-Path $probePath "valid-receipt-without-operator-confirmation.md")

$contractConfirmedResult = Invoke-ReceiptIntake `
    -Name "contract-receipt-with-operator-confirmation" `
    -ReceiptPath $receiptPath `
    -ManifestPath (Join-Path $probePath "contract-receipt-with-operator-confirmation-manifest.json") `
    -ReportPath (Join-Path $probePath "contract-receipt-with-operator-confirmation.md") `
    -ContractFixtureMode `
    -ConfirmLocalSendReceipt

$unconfirmedManifest = $unconfirmedResult.manifest
$contractConfirmedManifest = $contractConfirmedResult.manifest
$confirmSwitchAvailable = $dispatchReceiptIntakeContent.Contains("ConfirmLocalSendReceipt")

$checks = @()
Add-ProbeCheck "real_receipt_guard_sources_available" `
    ($outboxManifest.status -eq "PASS" -and
        $dispatchReceiptIntakeProbeManifest.status -eq "PASS" -and
        $localSendWorkflowProbeManifest.status -eq "PASS" -and
        (Test-Path $dispatchReceiptIntakePath) -and
        $confirmSwitchAvailable) `
    "Real receipt guard probe must use passing progress-notification evidence and an intake script with ConfirmLocalSendReceipt."
Add-ProbeCheck "valid_receipt_without_operator_confirmation_not_sent" `
    ($unconfirmedResult.exitCode -eq 0 -and
        $unconfirmedManifest.status -eq "PASS" -and
        (Get-JsonValue $unconfirmedManifest "receiptAccepted" $false) -and
        (Get-JsonValue $unconfirmedManifest "messageId" "") -eq "msg_contract_guard_001" -and
        (Get-JsonValue $unconfirmedManifest "notificationDispatchStatus" "") -eq "VALID_RECEIPT_PENDING_OPERATOR_REAL_SEND_CONFIRMATION" -and
        (Get-JsonValue $unconfirmedManifest "operatorRealSendConfirmationRequired" $false) -and
        -not (Get-JsonValue $unconfirmedManifest "operatorRealSendConfirmed" $true) -and
        -not (Get-JsonValue $unconfirmedManifest "realEmailSentAccepted" $true) -and
        -not (Get-JsonValue $unconfirmedManifest "emailSent" $true)) `
    "A valid local receipt without explicit operator confirmation must not set emailSent."
Add-ProbeCheck "contract_mode_overrides_operator_confirmation" `
    ($contractConfirmedResult.exitCode -eq 0 -and
        $contractConfirmedManifest.status -eq "PASS" -and
        (Get-JsonValue $contractConfirmedManifest "receiptAccepted" $false) -and
        (Get-JsonValue $contractConfirmedManifest "contractFixtureMode" $false) -and
        (Get-JsonValue $contractConfirmedManifest "confirmLocalSendReceipt" $false) -and
        (Get-JsonValue $contractConfirmedManifest "notificationDispatchStatus" "") -eq "CONTRACT_RECEIPT_ACCEPTED_NOT_REAL_SEND" -and
        -not (Get-JsonValue $contractConfirmedManifest "operatorRealSendConfirmationRequired" $true) -and
        -not (Get-JsonValue $contractConfirmedManifest "operatorRealSendConfirmed" $true) -and
        -not (Get-JsonValue $contractConfirmedManifest "realEmailSentAccepted" $true) -and
        -not (Get-JsonValue $contractConfirmedManifest "emailSent" $true)) `
    "Contract fixture mode must not claim a real local send even if the confirmation switch is supplied."
Add-ProbeCheck "canonical_outbox_boundary_preserved" `
    ((Get-JsonValue $outboxManifest "notificationDispatchStatus" "") -eq "PENDING_LOCAL_MAIL_AUTH_AND_CONFIRMATION" -and
        -not (Get-JsonValue $outboxManifest "emailSent" $true)) `
    "Canonical outbox must stay pending until a real operator-confirmed local send receipt is accepted."
Add-ProbeCheck "pipeline_email_boundary_preserved" `
    (-not (Get-JsonValue $unconfirmedManifest "releasePipelineSendsEmail" $true) -and
        -not (Get-JsonValue $contractConfirmedManifest "releasePipelineSendsEmail" $true) -and
        (Get-JsonValue $unconfirmedManifest "productionOutputBoundary" "") -eq "progress_notification_dispatch_receipt_pending_operator_confirmation" -and
        (Get-JsonValue $contractConfirmedManifest "productionOutputBoundary" "") -eq "progress_notification_dispatch_receipt_contract_only") `
    "Guard probe must keep release-pipeline email sending false while proving receipt finalization boundaries."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }
$unconfirmedDispatchStatusForReport = Get-JsonValue $unconfirmedManifest "notificationDispatchStatus" ""
$unconfirmedEmailSentForReport = Get-JsonValue $unconfirmedManifest "emailSent" $true
$contractConfirmedDispatchStatusForReport = Get-JsonValue $contractConfirmedManifest "notificationDispatchStatus" ""
$contractConfirmedEmailSentForReport = Get-JsonValue $contractConfirmedManifest "emailSent" $true

$reportLines = @(
    "# AI TestPilot Release Progress Notification Real Receipt Guard Probe",
    "",
    "- Status: $status",
    "- Confirm switch available: $confirmSwitchAvailable",
    "- Unconfirmed receipt exit code: $($unconfirmedResult.exitCode)",
    "- Unconfirmed dispatch status: $unconfirmedDispatchStatusForReport",
    "- Unconfirmed email sent: $unconfirmedEmailSentForReport",
    "- Contract-confirmed receipt exit code: $($contractConfirmedResult.exitCode)",
    "- Contract-confirmed dispatch status: $contractConfirmedDispatchStatusForReport",
    "- Contract-confirmed email sent: $contractConfirmedEmailSentForReport",
    "",
    "## Boundary",
    "",
    "- The probe uses a contract-shaped receipt only.",
    "- A valid receipt cannot mark emailSent=true without explicit operator confirmation.",
    "- Contract fixture mode never marks emailSent=true.",
    "- The canonical outbox remains pending.",
    "",
    "## Checks",
    "",
    "| Check | Passed | Message |",
    "| --- | --- | --- |"
)
foreach ($check in $checks) {
    $reportLines += "| $($check.name) | $($check.passed) | $($check.message) |"
}
$reportLines | Set-Content -Path $reportFullPath -Encoding UTF8

$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestFullPath),
    (Convert-ToEvidenceRelativePath $reportFullPath),
    (Convert-ToEvidenceRelativePath $receiptPath),
    (Convert-ToEvidenceRelativePath $unconfirmedResult.outputPath),
    (Convert-ToEvidenceRelativePath $unconfirmedResult.manifestPath),
    (Convert-ToEvidenceRelativePath $unconfirmedResult.reportPath),
    (Convert-ToEvidenceRelativePath $contractConfirmedResult.outputPath),
    (Convert-ToEvidenceRelativePath $contractConfirmedResult.manifestPath),
    (Convert-ToEvidenceRelativePath $contractConfirmedResult.reportPath)
)

$sourceFiles = @(
    "release-progress-notification-outbox-manifest.json",
    "release-progress-notification-dispatch-receipt-intake-probe-manifest.json",
    "release-progress-notification-local-send-workflow-probe-manifest.json"
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.release_progress_notification_real_receipt_guard_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    probeDir = $probePath
    confirmLocalSendReceiptSwitchAvailable = [bool]$confirmSwitchAvailable
    unconfirmedReceiptAccepted = (Get-JsonValue $unconfirmedManifest "receiptAccepted" $false)
    unconfirmedReceiptMessageId = (Get-JsonValue $unconfirmedManifest "messageId" "")
    unconfirmedNotificationDispatchStatus = (Get-JsonValue $unconfirmedManifest "notificationDispatchStatus" "")
    unconfirmedOperatorRealSendConfirmationRequired = (Get-JsonValue $unconfirmedManifest "operatorRealSendConfirmationRequired" $false)
    unconfirmedOperatorRealSendConfirmed = (Get-JsonValue $unconfirmedManifest "operatorRealSendConfirmed" $true)
    unconfirmedRealEmailSentAccepted = (Get-JsonValue $unconfirmedManifest "realEmailSentAccepted" $true)
    unconfirmedEmailSent = (Get-JsonValue $unconfirmedManifest "emailSent" $true)
    contractConfirmedReceiptAccepted = (Get-JsonValue $contractConfirmedManifest "receiptAccepted" $false)
    contractConfirmedContractFixtureMode = (Get-JsonValue $contractConfirmedManifest "contractFixtureMode" $false)
    contractConfirmedConfirmLocalSendReceipt = (Get-JsonValue $contractConfirmedManifest "confirmLocalSendReceipt" $false)
    contractConfirmedNotificationDispatchStatus = (Get-JsonValue $contractConfirmedManifest "notificationDispatchStatus" "")
    contractConfirmedOperatorRealSendConfirmed = (Get-JsonValue $contractConfirmedManifest "operatorRealSendConfirmed" $true)
    contractConfirmedRealEmailSentAccepted = (Get-JsonValue $contractConfirmedManifest "realEmailSentAccepted" $true)
    contractConfirmedEmailSent = (Get-JsonValue $contractConfirmedManifest "emailSent" $true)
    releasePipelineSendsEmail = $false
    canonicalOutboxDispatchStatus = (Get-JsonValue $outboxManifest "notificationDispatchStatus" "")
    canonicalOutboxEmailSent = (Get-JsonValue $outboxManifest "emailSent" $false)
    productionOutputBoundary = "progress_notification_real_receipt_guard_probe_only"
    sourceFiles = @($sourceFiles)
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles + $sourceFiles)
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
}

$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestFullPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Release progress notification real receipt guard probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Release progress notification real receipt guard probe manifest: $manifestFullPath"
Write-Output "Release progress notification real receipt guard probe report: $reportFullPath"
Write-Output "PASS AI TestPilot release progress notification real receipt guard probe"
