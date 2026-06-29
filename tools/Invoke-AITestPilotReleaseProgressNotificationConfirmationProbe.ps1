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
    $ProbeDir = Join-Path $EvidenceBundleDir "release-progress-notification-confirmation-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "release-progress-notification-confirmation-probe-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "release-progress-notification-confirmation-probe.md"
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
        [string]$Name,
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
        name = $Name
        exitCode = [int]$exitCode
        outputPath = $OutputPath
        callLogPath = $CallLogPath
        outputText = $outputText
        tokenReturned = [bool]($outputText -match "ctk_fake_progress_[0-9]+")
        confirmationRequiredOutput = [bool]($outputText.Contains("CONFIRMATION_REQUIRED") -or $outputText.Contains("confirmation required"))
        fakeSendSucceededOutput = [bool]($outputText.Contains("fake progress notification accepted"))
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
$authStatusProbeManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-mail-helper-auth-status-probe-manifest.json") "Production handoff mail helper auth-status probe manifest"
$progressNotificationHelperPath = Join-Path $evidenceBundlePath "release-progress-notification-outbox\send-progress-notification.ps1"

$fakeCliDir = Join-Path $probePath "fake-agently-cli"
New-Item -ItemType Directory -Force $fakeCliDir | Out-Null
$fakeCliPath = Join-Path $fakeCliDir "agently-cli.ps1"
$fakeCliLines = @(
    "param([Parameter(ValueFromRemainingArguments=`$true)][string[]]`$Args)",
    "`$line = `$Args -join ' '",
    "if (-not [string]::IsNullOrWhiteSpace(`$env:AITESTPILOT_FAKE_AGENTLY_LOG)) { Add-Content -Path `$env:AITESTPILOT_FAKE_AGENTLY_LOG -Value `$line -Encoding UTF8 }",
    "if (`$Args.Count -ge 2 -and `$Args[0] -eq 'auth' -and `$Args[1] -eq 'status') {",
    "    Write-Output '{ ""ok"": true, ""data"": { ""logged_in"": true, ""status"": ""logged_in"", ""message"": ""Logged in as fake progress sender."" } }'",
    "    exit 0",
    "}",
    "if (`$Args.Count -ge 1 -and `$Args[0] -eq '+me') {",
    "    Write-Output '{ ""ok"": true, ""data"": { ""email"": ""kibernet@agent.qq.com"", ""aliases"": [""kibernet@agent.qq.com""] } }'",
    "    exit 0",
    "}",
    "if (`$Args.Count -ge 2 -and `$Args[0] -eq 'message' -and `$Args[1] -eq '+send') {",
    "    if (`$Args -contains '--confirmation-token') {",
    "        Write-Output '{ ""ok"": true, ""data"": { ""message_id"": ""msg_fake_progress_001"", ""summary"": ""fake progress notification accepted"" } }'",
    "        exit 0",
    "    }",
    "    Write-Output '{ ""ok"": false, ""error"": { ""code"": ""CONFIRMATION_REQUIRED"", ""message"": ""confirmation required"", ""confirmation_token"": ""ctk_fake_progress_001"", ""summary"": ""Send progress notification to kibernet@sina.com."" } }'",
    "    exit 8",
    "}",
    "Write-Output '{ ""ok"": false, ""error"": { ""message"": ""unexpected fake agently-cli args"" } }'",
    "exit 2"
)
$fakeCliLines | Set-Content -Path $fakeCliPath -Encoding UTF8

$prepareResult = Invoke-ProgressHelperWithFakeAgently `
    -Name "prepare_confirmation" `
    -Arguments @("-EvidenceBundleDir", $evidenceBundlePath, "-PrepareConfirmation") `
    -CallLogPath (Join-Path $probePath "prepare-confirmation-agently-calls.log") `
    -OutputPath (Join-Path $probePath "prepare-confirmation-output.txt")

$confirmResult = Invoke-ProgressHelperWithFakeAgently `
    -Name "confirm_with_token" `
    -Arguments @("-EvidenceBundleDir", $evidenceBundlePath, "-ConfirmationToken", "ctk_fake_progress_001") `
    -CallLogPath (Join-Path $probePath "confirm-with-token-agently-calls.log") `
    -OutputPath (Join-Path $probePath "confirm-with-token-output.txt")

$checks = @()
Add-ProbeCheck "progress_confirmation_sources_available" `
    ($outboxManifest.status -eq "PASS" -and
        $authStatusProbeManifest.status -eq "PASS" -and
        (Test-Path $progressNotificationHelperPath) -and
        (Get-Content -Path $progressNotificationHelperPath -Encoding UTF8 -Raw).Contains("sendExitCode")) `
    "Progress notification confirmation probe must use passing outbox/auth-status evidence and a helper that propagates agently-cli exit codes."
Add-ProbeCheck "fake_logged_in_agently_generated" `
    ((Test-Path $fakeCliPath) -and (Get-Content -Path $fakeCliPath -Encoding UTF8 -Raw).Contains("logged_in")) `
    "Probe fake agently-cli must model a logged-in local sender."
Add-ProbeCheck "prepare_confirmation_requests_token" `
    ($prepareResult.exitCode -eq 8 -and
        $prepareResult.tokenReturned -and
        $prepareResult.confirmationRequiredOutput -and
        $prepareResult.authStatusCallCount -eq 1 -and
        $prepareResult.meCallCount -eq 1 -and
        $prepareResult.messageSendCallCount -eq 1 -and
        -not $prepareResult.messageCallHasConfirmationToken -and
        $prepareResult.messageCallHasRecipient -and
        $prepareResult.messageCallHasSubject) `
    "Prepare phase must request a confirmation token for the progress notification without supplying a token."
Add-ProbeCheck "confirm_with_token_sends_fake_message" `
    ($confirmResult.exitCode -eq 0 -and
        $confirmResult.fakeSendSucceededOutput -and
        $confirmResult.authStatusCallCount -eq 1 -and
        $confirmResult.meCallCount -eq 1 -and
        $confirmResult.messageSendCallCount -eq 1 -and
        $confirmResult.messageCallHasConfirmationToken -and
        $confirmResult.messageCallHasRecipient -and
        $confirmResult.messageCallHasSubject) `
    "Confirmation phase must include the provided token and reach only the fake CLI success path."
Add-ProbeCheck "confirmation_probe_boundary_preserved" `
    ((Get-JsonValue $outboxManifest "emailSent" $false) -eq $false -and
        -not (Get-JsonValue $outboxManifest "releasePipelineSendsEmail" $true) -and
        -not (Get-JsonValue $outboxManifest "confirmationTokenCreated" $true)) `
    "Canonical outbox evidence must remain pending and not claim real email or token creation."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$sourceFiles = @(
    "release-progress-notification-outbox-manifest.json",
    "production-handoff-mail-helper-auth-status-probe-manifest.json"
)

$reportLines = @(
    "# AI TestPilot Release Progress Notification Confirmation Probe",
    "",
    "- Status: $status",
    "- Prepare exit code: $($prepareResult.exitCode)",
    "- Prepare token returned: $($prepareResult.tokenReturned)",
    "- Confirm exit code: $($confirmResult.exitCode)",
    "- Confirm fake send succeeded: $($confirmResult.fakeSendSucceededOutput)",
    "",
    "## Boundary",
    "",
    "- The probe uses a fake logged-in agently-cli.",
    "- The probe does not run OAuth login.",
    "- The probe does not send real email.",
    "- The canonical outbox stays PENDING_LOCAL_MAIL_AUTH_AND_CONFIRMATION.",
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
    (Convert-ToEvidenceRelativePath $prepareResult.outputPath),
    (Convert-ToEvidenceRelativePath $prepareResult.callLogPath),
    (Convert-ToEvidenceRelativePath $confirmResult.outputPath),
    (Convert-ToEvidenceRelativePath $confirmResult.callLogPath)
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.release_progress_notification_confirmation_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    probeDir = $probePath
    progressNotificationHelperScript = Convert-ToEvidenceRelativePath $progressNotificationHelperPath
    fakeAgentlyCliGenerated = Test-Path $fakeCliPath
    fakeLoggedInAuthReturned = (Get-Content -Path $fakeCliPath -Encoding UTF8 -Raw).Contains("logged_in")
    prepareExitCode = [int]$prepareResult.exitCode
    prepareConfirmationTokenReturned = [bool]$prepareResult.tokenReturned
    prepareConfirmationRequiredOutput = [bool]$prepareResult.confirmationRequiredOutput
    prepareMessageSendCallCount = [int]$prepareResult.messageSendCallCount
    prepareMessageCallHasConfirmationToken = [bool]$prepareResult.messageCallHasConfirmationToken
    confirmationExitCode = [int]$confirmResult.exitCode
    confirmationFakeSendSucceeded = [bool]$confirmResult.fakeSendSucceededOutput
    confirmationMessageSendCallCount = [int]$confirmResult.messageSendCallCount
    confirmationMessageCallHasConfirmationToken = [bool]$confirmResult.messageCallHasConfirmationToken
    releasePipelineSendsEmail = $false
    realEmailSent = $false
    emailSent = $false
    mailAuthorizationCheckedByPipeline = $false
    canonicalOutboxDispatchStatus = (Get-JsonValue $outboxManifest "notificationDispatchStatus" "")
    canonicalOutboxEmailSent = (Get-JsonValue $outboxManifest "emailSent" $false)
    releasePipelineUsesFixture = $false
    realHostProjectEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "progress_notification_confirmation_probe_fake_cli_only"
    sourceFiles = @($sourceFiles)
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles + $sourceFiles)
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
}

$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestFullPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Release progress notification confirmation probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Release progress notification confirmation probe manifest: $manifestFullPath"
Write-Output "Release progress notification confirmation probe report: $reportFullPath"
Write-Output "PASS AI TestPilot release progress notification confirmation probe"
