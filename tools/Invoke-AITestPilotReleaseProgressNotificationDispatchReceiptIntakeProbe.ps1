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
    $ProbeDir = Join-Path $EvidenceBundleDir "release-progress-notification-dispatch-receipt-intake-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "release-progress-notification-dispatch-receipt-intake-probe-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "release-progress-notification-dispatch-receipt-intake-probe.md"
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
        [string]$ReportPath
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
        "-RequireReceipt",
        "-ContractFixtureMode"
    )

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
$receiptProbeManifest = Read-JsonFile (Join-Path $evidenceBundlePath "release-progress-notification-receipt-probe-manifest.json") "Release progress notification receipt probe manifest"

$fakeReceiptPath = Join-Path $probePath "fake-progress-notification-send-receipt.json"
$contractReceiptPath = Join-Path $probePath "contract-progress-notification-send-receipt.json"
New-Receipt -Path $fakeReceiptPath -MessageId "msg_fake_receipt_001"
New-Receipt -Path $contractReceiptPath -MessageId "msg_contract_receipt_001"

$fakeResult = Invoke-ReceiptIntake `
    -Name "fake-receipt-intake" `
    -ReceiptPath $fakeReceiptPath `
    -ManifestPath (Join-Path $probePath "fake-receipt-intake-manifest.json") `
    -ReportPath (Join-Path $probePath "fake-receipt-intake.md")

$contractResult = Invoke-ReceiptIntake `
    -Name "contract-receipt-intake" `
    -ReceiptPath $contractReceiptPath `
    -ManifestPath (Join-Path $probePath "contract-receipt-intake-manifest.json") `
    -ReportPath (Join-Path $probePath "contract-receipt-intake.md")

$fakeManifest = $fakeResult.manifest
$contractManifest = $contractResult.manifest

$checks = @()
Add-ProbeCheck "dispatch_receipt_sources_available" `
    ($outboxManifest.status -eq "PASS" -and
        $receiptProbeManifest.status -eq "PASS" -and
        (Test-Path (Join-Path $repoRoot "tools\Invoke-AITestPilotReleaseProgressNotificationDispatchReceiptIntake.ps1"))) `
    "Dispatch receipt intake probe must use passing outbox/receipt evidence and the dispatch receipt intake script."
Add-ProbeCheck "fake_receipt_rejected" `
    ($fakeResult.exitCode -ne 0 -and
        $fakeManifest.status -eq "FAIL" -and
        -not (Get-JsonValue $fakeManifest "receiptAccepted" $true) -and
        -not (Get-JsonValue $fakeManifest "fakeReceiptRejected" $true) -and
        -not (Get-JsonValue $fakeManifest "emailSent" $true)) `
    "Fake CLI receipt ids must be rejected and must not set emailSent."
Add-ProbeCheck "contract_receipt_accepted" `
    ($contractResult.exitCode -eq 0 -and
        $contractManifest.status -eq "PASS" -and
        (Get-JsonValue $contractManifest "receiptAccepted" $false) -and
        (Get-JsonValue $contractManifest "messageId" "") -eq "msg_contract_receipt_001" -and
        (Get-JsonValue $contractManifest "notificationDispatchStatus" "") -eq "CONTRACT_RECEIPT_ACCEPTED_NOT_REAL_SEND") `
    "Contract receipt must be accepted as shape proof only."
Add-ProbeCheck "contract_boundary_preserved" `
    (-not (Get-JsonValue $contractManifest "realEmailSentAccepted" $true) -and
        -not (Get-JsonValue $contractManifest "emailSent" $true) -and
        -not (Get-JsonValue $contractManifest "releasePipelineSendsEmail" $true) -and
        -not (Get-JsonValue $contractManifest "fixtureEvidencePromoted" $true)) `
    "Contract receipt intake must not claim real email send or pipeline-side sending."
Add-ProbeCheck "canonical_outbox_boundary_preserved" `
    ((Get-JsonValue $outboxManifest "notificationDispatchStatus" "") -eq "PENDING_LOCAL_MAIL_AUTH_AND_CONFIRMATION" -and
        -not (Get-JsonValue $outboxManifest "emailSent" $true)) `
    "Canonical outbox must stay pending until a real local send receipt is provided."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }
$contractMessageIdForReport = Get-JsonValue $contractManifest "messageId" ""
$contractRealEmailSentAcceptedForReport = Get-JsonValue $contractManifest "realEmailSentAccepted" $false

$reportLines = @(
    "# AI TestPilot Release Progress Notification Dispatch Receipt Intake Probe",
    "",
    "- Status: $status",
    "- Fake receipt exit code: $($fakeResult.exitCode)",
    "- Contract receipt exit code: $($contractResult.exitCode)",
    "- Contract receipt message id: $contractMessageIdForReport",
    "- Contract real email sent accepted: $contractRealEmailSentAcceptedForReport",
    "",
    "## Boundary",
    "",
    "- Fake CLI receipt ids are rejected.",
    "- Contract receipt shape proof does not mark emailSent=true.",
    "- Real dispatch evidence still requires a real local agently-cli send receipt.",
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
    (Convert-ToEvidenceRelativePath $fakeReceiptPath),
    (Convert-ToEvidenceRelativePath $contractReceiptPath),
    (Convert-ToEvidenceRelativePath $fakeResult.outputPath),
    (Convert-ToEvidenceRelativePath $fakeResult.manifestPath),
    (Convert-ToEvidenceRelativePath $fakeResult.reportPath),
    (Convert-ToEvidenceRelativePath $contractResult.outputPath),
    (Convert-ToEvidenceRelativePath $contractResult.manifestPath),
    (Convert-ToEvidenceRelativePath $contractResult.reportPath)
)

$sourceFiles = @(
    "release-progress-notification-outbox-manifest.json",
    "release-progress-notification-receipt-probe-manifest.json"
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.release_progress_notification_dispatch_receipt_intake_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    probeDir = $probePath
    fakeReceiptRejected = ($fakeResult.exitCode -ne 0 -and -not (Get-JsonValue $fakeManifest "receiptAccepted" $true))
    fakeReceiptEmailSent = (Get-JsonValue $fakeManifest "emailSent" $true)
    contractReceiptAccepted = (Get-JsonValue $contractManifest "receiptAccepted" $false)
    contractReceiptMessageId = (Get-JsonValue $contractManifest "messageId" "")
    contractNotificationDispatchStatus = (Get-JsonValue $contractManifest "notificationDispatchStatus" "")
    contractRealEmailSentAccepted = (Get-JsonValue $contractManifest "realEmailSentAccepted" $true)
    contractEmailSent = (Get-JsonValue $contractManifest "emailSent" $true)
    releasePipelineSendsEmail = $false
    canonicalOutboxDispatchStatus = (Get-JsonValue $outboxManifest "notificationDispatchStatus" "")
    canonicalOutboxEmailSent = (Get-JsonValue $outboxManifest "emailSent" $false)
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "progress_notification_dispatch_receipt_intake_probe_only"
    sourceFiles = @($sourceFiles)
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles + $sourceFiles)
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
}

$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestFullPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Release progress notification dispatch receipt intake probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Release progress notification dispatch receipt intake probe manifest: $manifestFullPath"
Write-Output "Release progress notification dispatch receipt intake probe report: $reportFullPath"
Write-Output "PASS AI TestPilot release progress notification dispatch receipt intake probe"
