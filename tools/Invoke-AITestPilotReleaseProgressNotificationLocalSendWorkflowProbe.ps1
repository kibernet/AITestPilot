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
    $ProbeDir = Join-Path $EvidenceBundleDir "release-progress-notification-local-send-workflow-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "release-progress-notification-local-send-workflow-probe-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "release-progress-notification-local-send-workflow-probe.md"
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

function Invoke-ProgressHelperWithFakeAgently {
    param(
        [string]$Mode,
        [string[]]$Arguments,
        [string]$CallLogPath,
        [string]$OutputPath
    )

    if (Test-Path $CallLogPath) {
        Remove-Item -LiteralPath $CallLogPath -Force
    }

    $oldPath = $env:PATH
    $oldFakeLog = $env:AITESTPILOT_FAKE_AGENTLY_LOG
    $oldFakeMode = $env:AITESTPILOT_FAKE_AGENTLY_MODE
    $oldErrorActionPreference = $ErrorActionPreference
    $env:PATH = $fakeCliDir + [System.IO.Path]::PathSeparator + $oldPath
    $env:AITESTPILOT_FAKE_AGENTLY_LOG = $CallLogPath
    $env:AITESTPILOT_FAKE_AGENTLY_MODE = $Mode

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

        if ([string]::IsNullOrWhiteSpace($oldFakeMode)) {
            Remove-Item Env:\AITESTPILOT_FAKE_AGENTLY_MODE -ErrorAction SilentlyContinue
        }
        else {
            $env:AITESTPILOT_FAKE_AGENTLY_MODE = $oldFakeMode
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
        mode = $Mode
        exitCode = [int]$exitCode
        outputPath = $OutputPath
        callLogPath = $CallLogPath
        outputText = $outputText
        tokenReturned = [bool]($outputText -match "ctk_fake_workflow_[0-9]+")
        fakeSendSucceededOutput = [bool]($outputText.Contains("contract workflow progress notification accepted"))
        authStatusCallCount = [int]@($calls | Where-Object { $_ -eq "auth status" }).Count
        meCallCount = [int]@($calls | Where-Object { $_ -eq "+me" }).Count
        messageSendCallCount = [int]$messageCalls.Count
        messageSendCall = [string]$messageCall
        messageCallHasConfirmationToken = [bool]($messageCall -like "*--confirmation-token*")
        messageCallHasRecipient = [bool]($messageCall -like "*--to kibernet@sina.com*")
        messageCallHasSubject = [bool]($messageCall -like "*AI TestPilot progress*")
    }
}

function Invoke-ReceiptIntake {
    param(
        [string]$ReceiptPath,
        [string]$ManifestPath,
        [string]$ReportPath,
        [string]$OutputPath
    )

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

    @($output | ForEach-Object { [string]$_ }) | Set-Content -Path $OutputPath -Encoding UTF8
    $manifest = $null
    if (Test-Path $ManifestPath) {
        $manifest = Read-JsonFile $ManifestPath "Local workflow dispatch receipt intake manifest"
    }

    return [ordered]@{
        exitCode = [int]$exitCode
        outputPath = $OutputPath
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
$authStatusProbeManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-mail-helper-auth-status-probe-manifest.json") "Production handoff mail helper auth-status probe manifest"
$confirmationProbeManifest = Read-JsonFile (Join-Path $evidenceBundlePath "release-progress-notification-confirmation-probe-manifest.json") "Release progress notification confirmation probe manifest"
$receiptProbeManifest = Read-JsonFile (Join-Path $evidenceBundlePath "release-progress-notification-receipt-probe-manifest.json") "Release progress notification receipt probe manifest"
$dispatchReceiptIntakeProbeManifest = Read-JsonFile (Join-Path $evidenceBundlePath "release-progress-notification-dispatch-receipt-intake-probe-manifest.json") "Release progress notification dispatch receipt intake probe manifest"
$progressNotificationHelperPath = Join-Path $evidenceBundlePath "release-progress-notification-outbox\send-progress-notification.ps1"
$dispatchReceiptIntakePath = Join-Path $repoRoot "tools\Invoke-AITestPilotReleaseProgressNotificationDispatchReceiptIntake.ps1"

$fakeCliDir = Join-Path $probePath "fake-agently-cli"
New-Item -ItemType Directory -Force $fakeCliDir | Out-Null
$fakeCliPath = Join-Path $fakeCliDir "agently-cli.ps1"
$fakeCliLines = @(
    "param([Parameter(ValueFromRemainingArguments=`$true)][string[]]`$Args)",
    "`$line = `$Args -join ' '",
    "if (-not [string]::IsNullOrWhiteSpace(`$env:AITESTPILOT_FAKE_AGENTLY_LOG)) { Add-Content -Path `$env:AITESTPILOT_FAKE_AGENTLY_LOG -Value `$line -Encoding UTF8 }",
    "`$mode = `$env:AITESTPILOT_FAKE_AGENTLY_MODE",
    "if (`$Args.Count -ge 2 -and `$Args[0] -eq 'auth' -and `$Args[1] -eq 'status') {",
    "    if (`$mode -eq 'unauthenticated') {",
    "        Write-Output '{ ""ok"": true, ""data"": { ""logged_in"": false, ""status"": ""not_logged_in"", ""message"": ""Not logged in."" } }'",
    "        Write-Output 'tip: Authorization required; follow the agently mail skill OAuth login flow.'",
    "        exit 0",
    "    }",
    "    Write-Output '{ ""ok"": true, ""data"": { ""logged_in"": true, ""status"": ""logged_in"", ""message"": ""Logged in as fake workflow sender."" } }'",
    "    exit 0",
    "}",
    "if (`$Args.Count -ge 1 -and `$Args[0] -eq '+me') {",
    "    Write-Output '{ ""ok"": true, ""data"": { ""email"": ""kibernet@agent.qq.com"", ""aliases"": [""kibernet@agent.qq.com""] } }'",
    "    exit 0",
    "}",
    "if (`$Args.Count -ge 2 -and `$Args[0] -eq 'message' -and `$Args[1] -eq '+send') {",
    "    if (`$Args -contains '--confirmation-token') {",
    "        Write-Output '{ ""ok"": true, ""data"": { ""message_id"": ""msg_contract_workflow_001"", ""summary"": ""contract workflow progress notification accepted"" } }'",
    "        exit 0",
    "    }",
    "    Write-Output '{ ""ok"": false, ""error"": { ""code"": ""CONFIRMATION_REQUIRED"", ""message"": ""confirmation required"", ""confirmation_token"": ""ctk_fake_workflow_001"", ""summary"": ""Send progress notification to kibernet@sina.com."" } }'",
    "    exit 8",
    "}",
    "Write-Output '{ ""ok"": false, ""error"": { ""message"": ""unexpected fake agently-cli args"" } }'",
    "exit 2"
)
$fakeCliLines | Set-Content -Path $fakeCliPath -Encoding UTF8

$workflowReceiptPath = Join-Path $probePath "workflow-progress-notification-send-receipt.json"
if (Test-Path $workflowReceiptPath) {
    Remove-Item -LiteralPath $workflowReceiptPath -Force
}

$unauthResult = Invoke-ProgressHelperWithFakeAgently `
    -Mode "unauthenticated" `
    -Arguments @("-EvidenceBundleDir", $evidenceBundlePath, "-PrepareConfirmation") `
    -CallLogPath (Join-Path $probePath "unauthenticated-agently-calls.log") `
    -OutputPath (Join-Path $probePath "unauthenticated-output.txt")

$prepareResult = Invoke-ProgressHelperWithFakeAgently `
    -Mode "logged_in" `
    -Arguments @("-EvidenceBundleDir", $evidenceBundlePath, "-PrepareConfirmation") `
    -CallLogPath (Join-Path $probePath "prepare-confirmation-agently-calls.log") `
    -OutputPath (Join-Path $probePath "prepare-confirmation-output.txt")

$confirmResult = Invoke-ProgressHelperWithFakeAgently `
    -Mode "logged_in" `
    -Arguments @("-EvidenceBundleDir", $evidenceBundlePath, "-ConfirmationToken", "ctk_fake_workflow_001", "-ReceiptPath", $workflowReceiptPath) `
    -CallLogPath (Join-Path $probePath "confirm-with-receipt-agently-calls.log") `
    -OutputPath (Join-Path $probePath "confirm-with-receipt-output.txt")

$workflowReceipt = $null
if (Test-Path $workflowReceiptPath) {
    $workflowReceipt = Read-JsonFile $workflowReceiptPath "Workflow send receipt"
}

$intakeResult = Invoke-ReceiptIntake `
    -ReceiptPath $workflowReceiptPath `
    -ManifestPath (Join-Path $probePath "workflow-dispatch-receipt-intake-manifest.json") `
    -ReportPath (Join-Path $probePath "workflow-dispatch-receipt-intake.md") `
    -OutputPath (Join-Path $probePath "workflow-dispatch-receipt-intake-output.txt")
$intakeManifest = $intakeResult.manifest

$checks = @()
Add-ProbeCheck "local_send_workflow_sources_available" `
    ($outboxManifest.status -eq "PASS" -and
        $authStatusProbeManifest.status -eq "PASS" -and
        $confirmationProbeManifest.status -eq "PASS" -and
        $receiptProbeManifest.status -eq "PASS" -and
        $dispatchReceiptIntakeProbeManifest.status -eq "PASS" -and
        (Test-Path $progressNotificationHelperPath) -and
        (Test-Path $dispatchReceiptIntakePath)) `
    "Local send workflow probe must use passing outbox, auth-status, confirmation, receipt, and dispatch-receipt intake evidence."
Add-ProbeCheck "unauthenticated_stops_before_send" `
    ($unauthResult.exitCode -ne 0 -and
        $unauthResult.authStatusCallCount -eq 1 -and
        $unauthResult.meCallCount -eq 0 -and
        $unauthResult.messageSendCallCount -eq 0) `
    "Unauthenticated local workflow must stop at auth status before +me or message +send."
Add-ProbeCheck "prepare_requests_confirmation_token" `
    ($prepareResult.exitCode -eq 8 -and
        $prepareResult.tokenReturned -and
        $prepareResult.authStatusCallCount -eq 1 -and
        $prepareResult.meCallCount -eq 1 -and
        $prepareResult.messageSendCallCount -eq 1 -and
        -not $prepareResult.messageCallHasConfirmationToken -and
        $prepareResult.messageCallHasRecipient -and
        $prepareResult.messageCallHasSubject) `
    "Logged-in prepare phase must request a confirmation token before sending."
Add-ProbeCheck "confirm_with_token_writes_contract_receipt" `
    ($confirmResult.exitCode -eq 0 -and
        $confirmResult.fakeSendSucceededOutput -and
        $confirmResult.messageSendCallCount -eq 1 -and
        $confirmResult.messageCallHasConfirmationToken -and
        $null -ne $workflowReceipt -and
        (Get-JsonValue $workflowReceipt "messageId" "") -eq "msg_contract_workflow_001") `
    "Token-confirmed phase must write a machine-readable contract receipt."
Add-ProbeCheck "dispatch_receipt_intake_accepts_contract_only" `
    ($intakeResult.exitCode -eq 0 -and
        $intakeManifest.status -eq "PASS" -and
        (Get-JsonValue $intakeManifest "receiptAccepted" $false) -and
        (Get-JsonValue $intakeManifest "messageId" "") -eq "msg_contract_workflow_001" -and
        (Get-JsonValue $intakeManifest "notificationDispatchStatus" "") -eq "CONTRACT_RECEIPT_ACCEPTED_NOT_REAL_SEND" -and
        -not (Get-JsonValue $intakeManifest "emailSent" $true) -and
        -not (Get-JsonValue $intakeManifest "realEmailSentAccepted" $true)) `
    "Dispatch receipt intake must accept contract receipt shape without claiming real email."
Add-ProbeCheck "canonical_outbox_boundary_preserved" `
    ((Get-JsonValue $outboxManifest "notificationDispatchStatus" "") -eq "PENDING_LOCAL_MAIL_AUTH_AND_CONFIRMATION" -and
        -not (Get-JsonValue $outboxManifest "emailSent" $true)) `
    "Canonical outbox must remain pending until a real local send receipt is provided."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$workflowReceiptMessageId = Get-JsonValue $workflowReceipt "messageId" ""
$intakeDispatchStatus = Get-JsonValue $intakeManifest "notificationDispatchStatus" ""
$intakeEmailSent = Get-JsonValue $intakeManifest "emailSent" $true

$reportLines = @(
    "# AI TestPilot Release Progress Notification Local Send Workflow Probe",
    "",
    "- Status: $status",
    "- Unauthenticated exit code: $($unauthResult.exitCode)",
    "- Prepare exit code: $($prepareResult.exitCode)",
    "- Prepare token returned: $($prepareResult.tokenReturned)",
    "- Confirm exit code: $($confirmResult.exitCode)",
    "- Receipt message id: $workflowReceiptMessageId",
    "- Intake dispatch status: $intakeDispatchStatus",
    "- Intake email sent: $intakeEmailSent",
    "",
    "## Boundary",
    "",
    "- The probe uses a fake agently-cli.",
    "- The unauthenticated path stops before message +send.",
    "- The logged-in path proves the local two-stage flow and receipt intake shape only.",
    "- The canonical outbox remains pending and not sent.",
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
    (Convert-ToEvidenceRelativePath $unauthResult.outputPath),
    (Convert-ToEvidenceRelativePath $unauthResult.callLogPath),
    (Convert-ToEvidenceRelativePath $prepareResult.outputPath),
    (Convert-ToEvidenceRelativePath $prepareResult.callLogPath),
    (Convert-ToEvidenceRelativePath $confirmResult.outputPath),
    (Convert-ToEvidenceRelativePath $confirmResult.callLogPath),
    (Convert-ToEvidenceRelativePath $workflowReceiptPath),
    (Convert-ToEvidenceRelativePath $intakeResult.outputPath),
    (Convert-ToEvidenceRelativePath $intakeResult.manifestPath),
    (Convert-ToEvidenceRelativePath $intakeResult.reportPath)
)

$sourceFiles = @(
    "release-progress-notification-outbox-manifest.json",
    "production-handoff-mail-helper-auth-status-probe-manifest.json",
    "release-progress-notification-confirmation-probe-manifest.json",
    "release-progress-notification-receipt-probe-manifest.json",
    "release-progress-notification-dispatch-receipt-intake-probe-manifest.json"
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.release_progress_notification_local_send_workflow_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    probeDir = $probePath
    fakeAgentlyCliGenerated = Test-Path $fakeCliPath
    unauthenticatedExitCode = [int]$unauthResult.exitCode
    unauthenticatedAuthStatusCallCount = [int]$unauthResult.authStatusCallCount
    unauthenticatedMeCallCount = [int]$unauthResult.meCallCount
    unauthenticatedMessageSendCallCount = [int]$unauthResult.messageSendCallCount
    prepareExitCode = [int]$prepareResult.exitCode
    prepareConfirmationTokenReturned = [bool]$prepareResult.tokenReturned
    prepareMessageSendCallCount = [int]$prepareResult.messageSendCallCount
    prepareMessageCallHasConfirmationToken = [bool]$prepareResult.messageCallHasConfirmationToken
    confirmationExitCode = [int]$confirmResult.exitCode
    confirmationMessageSendCallCount = [int]$confirmResult.messageSendCallCount
    confirmationMessageCallHasConfirmationToken = [bool]$confirmResult.messageCallHasConfirmationToken
    workflowReceiptGenerated = Test-Path $workflowReceiptPath
    workflowReceiptMessageId = $workflowReceiptMessageId
    dispatchReceiptIntakePassed = ($intakeManifest.status -eq "PASS")
    dispatchReceiptIntakeNotificationStatus = $intakeDispatchStatus
    dispatchReceiptIntakeEmailSent = [bool]$intakeEmailSent
    releasePipelineSendsEmail = $false
    realEmailSent = $false
    emailSent = $false
    mailAuthorizationCheckedByPipeline = $false
    canonicalOutboxDispatchStatus = (Get-JsonValue $outboxManifest "notificationDispatchStatus" "")
    canonicalOutboxEmailSent = (Get-JsonValue $outboxManifest "emailSent" $false)
    releasePipelineUsesFixture = $false
    realHostProjectEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "progress_notification_local_send_workflow_probe_fake_cli_only"
    sourceFiles = @($sourceFiles)
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles + $sourceFiles)
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
}

$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestFullPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Release progress notification local send workflow probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Release progress notification local send workflow probe manifest: $manifestFullPath"
Write-Output "Release progress notification local send workflow probe report: $reportFullPath"
Write-Output "PASS AI TestPilot release progress notification local send workflow probe"
