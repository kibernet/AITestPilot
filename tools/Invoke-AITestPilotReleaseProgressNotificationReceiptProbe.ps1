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
    $ProbeDir = Join-Path $EvidenceBundleDir "release-progress-notification-receipt-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "release-progress-notification-receipt-probe-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "release-progress-notification-receipt-probe.md"
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

function Add-ProbeCheck {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Message
    )

    $script:checks += [ordered]@{
        name = $Name
        passed = $Passed
        message = $Message
    }
}

function Invoke-ProgressHelperWithFakeAgently {
    param(
        [string[]]$Arguments,
        [string]$CallLogPath,
        [string]$OutputPath
    )

    if (Test-Path $CallLogPath) {
        Remove-Item -LiteralPath $CallLogPath -Force
    }

    $oldPath = $env:PATH
    $oldFakeLog = $env:AITESTPILOT_FAKE_AGENTLY_LOG
    $oldErrorActionPreference = $ErrorActionPreference
    $env:PATH = $fakeCliDir + [System.IO.Path]::PathSeparator + $oldPath
    $env:AITESTPILOT_FAKE_AGENTLY_LOG = $CallLogPath

    try {
        $powerShellArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $progressNotificationHelperPath) + @($Arguments)
        $ErrorActionPreference = "Continue"
        $output = & powershell.exe @powerShellArgs 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldErrorActionPreference
        $env:PATH = $oldPath
        if ([string]::IsNullOrWhiteSpace($oldFakeLog)) {
            Remove-Item Env:\AITESTPILOT_FAKE_AGENTLY_LOG -ErrorAction SilentlyContinue
        }
        else {
            $env:AITESTPILOT_FAKE_AGENTLY_LOG = $oldFakeLog
        }
    }

    $outputText = @($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    $outputText | Set-Content -Path $OutputPath -Encoding UTF8

    $calls = @()
    if (Test-Path $CallLogPath) {
        $calls = @(Get-Content -Path $CallLogPath -Encoding UTF8)
    }
    else {
        "" | Set-Content -Path $CallLogPath -Encoding UTF8
    }

    $messageCalls = @($calls | Where-Object { $_ -like "message +send*" })
    $messageCall = @($messageCalls | Select-Object -First 1)

    return [ordered]@{
        exitCode = [int]$exitCode
        outputPath = $OutputPath
        callLogPath = $CallLogPath
        outputText = $outputText
        fakeSendSucceededOutput = [bool]($outputText.Contains("fake progress receipt accepted"))
        authStatusCallCount = [int]@($calls | Where-Object { $_ -eq "auth status" }).Count
        meCallCount = [int]@($calls | Where-Object { $_ -eq "+me" }).Count
        messageSendCallCount = [int]$messageCalls.Count
        messageSendCall = [string]$messageCall
        messageCallHasConfirmationToken = [bool]($messageCall -like "*--confirmation-token*")
        messageCallHasRecipient = [bool]($messageCall -like "*--to kibernet@sina.com*")
        messageCallHasSubject = [bool]($messageCall -like "*AI TestPilot progress*")
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
$confirmationProbeManifest = Read-JsonFile (Join-Path $evidenceBundlePath "release-progress-notification-confirmation-probe-manifest.json") "Release progress notification confirmation probe manifest"
$progressNotificationHelperPath = Join-Path $evidenceBundlePath "release-progress-notification-outbox\send-progress-notification.ps1"
$progressNotificationHelperContent = if (Test-Path $progressNotificationHelperPath) {
    Get-Content -Path $progressNotificationHelperPath -Encoding UTF8 -Raw
}
else {
    ""
}

$fakeCliDir = Join-Path $probePath "fake-agently-cli"
New-Item -ItemType Directory -Force $fakeCliDir | Out-Null
$fakeCliPath = Join-Path $fakeCliDir "agently-cli.ps1"
$fakeCliLines = @(
    "param([Parameter(ValueFromRemainingArguments=`$true)][string[]]`$Args)",
    "`$line = `$Args -join ' '",
    "if (-not [string]::IsNullOrWhiteSpace(`$env:AITESTPILOT_FAKE_AGENTLY_LOG)) { Add-Content -Path `$env:AITESTPILOT_FAKE_AGENTLY_LOG -Value `$line -Encoding UTF8 }",
    "if (`$Args.Count -ge 2 -and `$Args[0] -eq 'auth' -and `$Args[1] -eq 'status') {",
    "    Write-Output '{ ""ok"": true, ""data"": { ""logged_in"": true, ""status"": ""logged_in"", ""message"": ""Logged in as fake progress receipt sender."" } }'",
    "    exit 0",
    "}",
    "if (`$Args.Count -ge 1 -and `$Args[0] -eq '+me') {",
    "    Write-Output '{ ""ok"": true, ""data"": { ""email"": ""kibernet@agent.qq.com"", ""aliases"": [""kibernet@agent.qq.com""] } }'",
    "    exit 0",
    "}",
    "if (`$Args.Count -ge 2 -and `$Args[0] -eq 'message' -and `$Args[1] -eq '+send') {",
    "    if (`$Args -contains '--confirmation-token') {",
    "        Write-Output '{ ""ok"": true, ""data"": { ""message_id"": ""msg_fake_receipt_001"", ""summary"": ""fake progress receipt accepted"" } }'",
    "        exit 0",
    "    }",
    "    Write-Output '{ ""ok"": false, ""error"": { ""code"": ""CONFIRMATION_REQUIRED"", ""message"": ""confirmation required"", ""confirmation_token"": ""ctk_fake_receipt_001"", ""summary"": ""Send progress notification to kibernet@sina.com."" } }'",
    "    exit 8",
    "}",
    "Write-Output '{ ""ok"": false, ""error"": { ""message"": ""unexpected fake agently-cli args"" } }'",
    "exit 2"
)
$fakeCliLines | Set-Content -Path $fakeCliPath -Encoding UTF8

$receiptPath = Join-Path $probePath "progress-notification-send-receipt.json"
if (Test-Path $receiptPath) {
    Remove-Item -LiteralPath $receiptPath -Force
}

$sendResult = Invoke-ProgressHelperWithFakeAgently `
    -Arguments @("-EvidenceBundleDir", $evidenceBundlePath, "-ConfirmationToken", "ctk_fake_receipt_001", "-ReceiptPath", $receiptPath) `
    -CallLogPath (Join-Path $probePath "confirm-with-receipt-agently-calls.log") `
    -OutputPath (Join-Path $probePath "confirm-with-receipt-output.txt")

$receipt = $null
$receiptParseError = ""
if (Test-Path $receiptPath) {
    try {
        $receipt = Get-Content -Path $receiptPath -Encoding UTF8 -Raw | ConvertFrom-Json
    }
    catch {
        $receiptParseError = $_.Exception.Message
    }
}

$helperSupportsReceipt = (
    (Test-Path $progressNotificationHelperPath) -and
    $progressNotificationHelperContent.Contains("ReceiptPath") -and
    $progressNotificationHelperContent.Contains("release_progress_notification_send_receipt.v1") -and
    $progressNotificationHelperContent.Contains("realDeliveryVerified")
)

$receiptGenerated = $null -ne $receipt
$receiptSchemaVersionAccepted = $receiptGenerated -and
    (Get-JsonValue $receipt "schemaVersion" "") -eq "aitestpilot.release_progress_notification_send_receipt.v1"

$checks = @()
Add-ProbeCheck "progress_receipt_sources_available" `
    ($outboxManifest.status -eq "PASS" -and
        $confirmationProbeManifest.status -eq "PASS" -and
        $helperSupportsReceipt) `
    "Progress notification receipt probe must use passing outbox/confirmation evidence and a helper that writes a machine-readable receipt."
Add-ProbeCheck "fake_logged_in_agently_generated" `
    ((Test-Path $fakeCliPath) -and (Get-Content -Path $fakeCliPath -Encoding UTF8 -Raw).Contains("logged_in")) `
    "Probe fake agently-cli must model a logged-in local sender."
Add-ProbeCheck "confirm_with_token_writes_receipt" `
    ($sendResult.exitCode -eq 0 -and
        $sendResult.fakeSendSucceededOutput -and
        $sendResult.authStatusCallCount -eq 1 -and
        $sendResult.meCallCount -eq 1 -and
        $sendResult.messageSendCallCount -eq 1 -and
        $sendResult.messageCallHasConfirmationToken -and
        $sendResult.messageCallHasRecipient -and
        $sendResult.messageCallHasSubject -and
        $receiptGenerated) `
    "Receipt probe must send only through the fake CLI with a provided token and write a receipt file."
Add-ProbeCheck "receipt_content_validated" `
    ($receiptSchemaVersionAccepted -and
        (Get-JsonValue $receipt "recipient" "") -eq "kibernet@sina.com" -and
        (Get-JsonValue $receipt "subject" "") -eq (Get-JsonValue $outboxManifest "subject" "") -and
        (Get-JsonValue $receipt "messageId" "") -eq "msg_fake_receipt_001" -and
        (Get-JsonValue $receipt "agentlyCliExitCode" -1) -eq 0 -and
        (Get-JsonValue $receipt "sendSucceeded" $false) -and
        (Get-JsonValue $receipt "confirmationTokenSupplied" $false) -and
        -not (Get-JsonValue $receipt "prepareConfirmation" $true) -and
        -not (Get-JsonValue $receipt "releasePipelineGenerated" $true) -and
        -not (Get-JsonValue $receipt "realDeliveryVerified" $true)) `
    "Receipt must capture recipient, subject, message id, token-supplied status, success exit code, and the not-real-delivery boundary."
Add-ProbeCheck "receipt_probe_boundary_preserved" `
    ((Get-JsonValue $outboxManifest "notificationDispatchStatus" "") -eq "PENDING_LOCAL_MAIL_AUTH_AND_CONFIRMATION" -and
        -not (Get-JsonValue $outboxManifest "emailSent" $true) -and
        -not (Get-JsonValue $outboxManifest "releasePipelineSendsEmail" $true) -and
        -not (Get-JsonValue $confirmationProbeManifest "emailSent" $true) -and
        -not (Get-JsonValue $confirmationProbeManifest "realEmailSent" $true) -and
        -not (Get-JsonValue $confirmationProbeManifest "releasePipelineUsesFixture" $true) -and
        -not (Get-JsonValue $confirmationProbeManifest "fixtureEvidencePromoted" $true)) `
    "Canonical outbox and confirmation evidence must stay pending, fake-only, and not sent."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$sourceFiles = @(
    "release-progress-notification-outbox-manifest.json",
    "release-progress-notification-confirmation-probe-manifest.json"
)

$receiptMessageIdForReport = Get-JsonValue $receipt "messageId" ""
$receiptRealDeliveryVerifiedForReport = Get-JsonValue $receipt "realDeliveryVerified" $false

$reportLines = @(
    "# AI TestPilot Release Progress Notification Receipt Probe",
    "",
    "- Status: $status",
    "- Helper exit code: $($sendResult.exitCode)",
    "- Receipt generated: $receiptGenerated",
    "- Receipt message id: $receiptMessageIdForReport",
    "- Receipt real delivery verified: $receiptRealDeliveryVerifiedForReport",
    "",
    "## Boundary",
    "",
    "- The probe uses a fake logged-in agently-cli.",
    "- The probe does not run OAuth login.",
    "- The probe does not send real email.",
    "- The canonical outbox stays PENDING_LOCAL_MAIL_AUTH_AND_CONFIRMATION.",
    "- The receipt marks realDeliveryVerified=false.",
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
    (Convert-ToEvidenceRelativePath $fakeCliPath),
    (Convert-ToEvidenceRelativePath $sendResult.outputPath),
    (Convert-ToEvidenceRelativePath $sendResult.callLogPath),
    (Convert-ToEvidenceRelativePath $receiptPath)
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.release_progress_notification_receipt_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    probeDir = $probePath
    progressNotificationHelperScript = Convert-ToEvidenceRelativePath $progressNotificationHelperPath
    helperSupportsReceiptPath = [bool]$helperSupportsReceipt
    fakeAgentlyCliGenerated = Test-Path $fakeCliPath
    fakeLoggedInAuthReturned = (Get-Content -Path $fakeCliPath -Encoding UTF8 -Raw).Contains("logged_in")
    helperExitCode = [int]$sendResult.exitCode
    messageSendCallCount = [int]$sendResult.messageSendCallCount
    messageCallHasConfirmationToken = [bool]$sendResult.messageCallHasConfirmationToken
    receiptGenerated = [bool]$receiptGenerated
    receiptParseError = $receiptParseError
    receiptSchemaVersionAccepted = [bool]$receiptSchemaVersionAccepted
    receiptRecipient = (Get-JsonValue $receipt "recipient" "")
    receiptSubject = (Get-JsonValue $receipt "subject" "")
    receiptMessageId = (Get-JsonValue $receipt "messageId" "")
    receiptConfirmationTokenSupplied = (Get-JsonValue $receipt "confirmationTokenSupplied" $false)
    receiptSendSucceeded = (Get-JsonValue $receipt "sendSucceeded" $false)
    receiptReleasePipelineGenerated = (Get-JsonValue $receipt "releasePipelineGenerated" $true)
    receiptRealDeliveryVerified = (Get-JsonValue $receipt "realDeliveryVerified" $true)
    releasePipelineSendsEmail = $false
    realEmailSent = $false
    emailSent = $false
    mailAuthorizationCheckedByPipeline = $false
    canonicalOutboxDispatchStatus = (Get-JsonValue $outboxManifest "notificationDispatchStatus" "")
    canonicalOutboxEmailSent = (Get-JsonValue $outboxManifest "emailSent" $false)
    releasePipelineUsesFixture = $false
    realHostProjectEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "progress_notification_receipt_probe_fake_cli_only"
    sourceFiles = @($sourceFiles)
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles + $sourceFiles)
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
}

$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestFullPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Release progress notification receipt probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Release progress notification receipt probe manifest: $manifestFullPath"
Write-Output "Release progress notification receipt probe report: $reportFullPath"
Write-Output "PASS AI TestPilot release progress notification receipt probe"
