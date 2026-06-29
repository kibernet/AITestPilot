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
    $ProbeDir = Join-Path $EvidenceBundleDir "production-handoff-mail-helper-auth-status-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-handoff-mail-helper-auth-status-probe-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-handoff-mail-helper-auth-status-probe.md"
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

function Invoke-HelperWithFakeAgently {
    param(
        [string]$Name,
        [string]$ScriptPath,
        [string[]]$Arguments,
        [string]$ExpectedError,
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
        $powerShellArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $ScriptPath) + @($Arguments)
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

    $authStatusCallCount = @($calls | Where-Object { $_ -eq "auth status" }).Count
    $messageSendCallCount = @($calls | Where-Object { $_ -like "message +send*" }).Count
    $meCallCount = @($calls | Where-Object { $_ -eq "+me" }).Count

    return [ordered]@{
        name = $Name
        exitCode = [int]$exitCode
        outputPath = $OutputPath
        callLogPath = $CallLogPath
        outputText = $outputText
        outputContainsExpectedAuthError = $outputText.Contains($ExpectedError)
        outputContainsJsonParseError = ($outputText.Contains("ConvertFrom-Json") -or $outputText.Contains("Invalid JSON primitive") -or $outputText.Contains("Unexpected character"))
        authStatusCallCount = [int]$authStatusCallCount
        messageSendCallCount = [int]$messageSendCallCount
        meCallCount = [int]$meCallCount
        confirmationTokenCreated = [bool]($outputText -match "ctk_[A-Za-z0-9_]+")
    }
}

$evidenceBundlePath = Resolve-FullPath $EvidenceBundleDir
$probePath = Resolve-FullPath $ProbeDir
$manifestFullPath = Resolve-FullPath $ManifestPath
$reportFullPath = Resolve-FullPath $ReportPath

New-Item -ItemType Directory -Force $probePath | Out-Null
New-Item -ItemType Directory -Force (Split-Path $manifestFullPath -Parent) | Out-Null
New-Item -ItemType Directory -Force (Split-Path $reportFullPath -Parent) | Out-Null

$sendReadinessManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-send-readiness-manifest.json") "Production handoff send readiness manifest"
$outboxManifest = Read-JsonFile (Join-Path $evidenceBundlePath "release-progress-notification-outbox-manifest.json") "Release progress notification outbox manifest"

$ownerPacketHelperPath = Join-Path $evidenceBundlePath "production-handoff-send\send-owner-packets.ps1"
$progressNotificationHelperPath = Join-Path $evidenceBundlePath "release-progress-notification-outbox\send-progress-notification.ps1"

$fakeCliDir = Join-Path $probePath "fake-agently-cli"
New-Item -ItemType Directory -Force $fakeCliDir | Out-Null
$fakeCliPath = Join-Path $fakeCliDir "agently-cli.cmd"
$fakeCliLines = @(
    "@echo off",
    "if not ""%AITESTPILOT_FAKE_AGENTLY_LOG%""=="""" echo %*>>""%AITESTPILOT_FAKE_AGENTLY_LOG%""",
    "if ""%1""==""auth"" if ""%2""==""status"" (",
    "  echo { ""ok"": true, ""data"": { ""logged_in"": false, ""status"": ""not_logged_in"", ""message"": ""Not logged in."" } }",
    "  echo tip: Authorization required; follow the agently mail skill OAuth login flow.",
    "  exit /b 0",
    ")",
    "if ""%1""==""+me"" (",
    "  echo { ""ok"": false, ""error"": { ""message"": ""fake +me should not be called"" } }",
    "  exit /b 3",
    ")",
    "if ""%1""==""message"" (",
    "  echo { ""ok"": false, ""error"": { ""message"": ""fake send should not be called"" } }",
    "  exit /b 8",
    ")",
    "echo { ""ok"": false, ""error"": { ""message"": ""unexpected fake agently-cli args"" } }",
    "exit /b 2"
)
$fakeCliLines | Set-Content -Path $fakeCliPath -Encoding ASCII

$ownerPacketResult = Invoke-HelperWithFakeAgently `
    -Name "owner_packet_send_helper" `
    -ScriptPath $ownerPacketHelperPath `
    -Arguments @("-EvidenceBundleDir", $evidenceBundlePath, "-PrepareConfirmation") `
    -ExpectedError "agently-cli is not logged in. Run agently-cli auth login before preparing owner packet sends." `
    -CallLogPath (Join-Path $probePath "owner-packet-helper-agently-calls.log") `
    -OutputPath (Join-Path $probePath "owner-packet-helper-output.txt")

$progressNotificationResult = Invoke-HelperWithFakeAgently `
    -Name "progress_notification_send_helper" `
    -ScriptPath $progressNotificationHelperPath `
    -Arguments @("-EvidenceBundleDir", $evidenceBundlePath, "-PrepareConfirmation") `
    -ExpectedError "agently-cli is not logged in. Run agently-cli auth login before preparing progress notification sends." `
    -CallLogPath (Join-Path $probePath "progress-notification-helper-agently-calls.log") `
    -OutputPath (Join-Path $probePath "progress-notification-helper-output.txt")

$checks = @()
Add-ProbeCheck "mail_helper_sources_available" `
    ($sendReadinessManifest.status -eq "PASS" -and
        $outboxManifest.status -eq "PASS" -and
        (Test-Path $ownerPacketHelperPath) -and
        (Test-Path $progressNotificationHelperPath) -and
        (Get-Content -Path $ownerPacketHelperPath -Encoding UTF8 -Raw).Contains("Read-JsonOutput") -and
        (Get-Content -Path $progressNotificationHelperPath -Encoding UTF8 -Raw).Contains("Read-JsonOutput")) `
    "Mail helper auth-status probe must use passing send-readiness and progress-notification outbox helpers with robust JSON extraction."
Add-ProbeCheck "fake_agently_auth_status_tip_output" `
    ((Test-Path $fakeCliPath) -and (Get-Content -Path $fakeCliPath -Encoding ASCII -Raw).Contains("tip: Authorization required")) `
    "Probe fake agently-cli must model the real unauthenticated JSON-plus-tip output."
Add-ProbeCheck "owner_packet_helper_auth_boundary" `
    ($ownerPacketResult.exitCode -ne 0 -and
        $ownerPacketResult.outputContainsExpectedAuthError -and
        -not $ownerPacketResult.outputContainsJsonParseError -and
        $ownerPacketResult.authStatusCallCount -eq 1) `
    "Owner packet send helper must parse auth status and stop at the explicit not-logged-in boundary."
Add-ProbeCheck "progress_notification_helper_auth_boundary" `
    ($progressNotificationResult.exitCode -ne 0 -and
        $progressNotificationResult.outputContainsExpectedAuthError -and
        -not $progressNotificationResult.outputContainsJsonParseError -and
        $progressNotificationResult.authStatusCallCount -eq 1) `
    "Progress notification send helper must parse auth status and stop at the explicit not-logged-in boundary."
Add-ProbeCheck "mail_helper_no_send_side_effects" `
    ($ownerPacketResult.messageSendCallCount -eq 0 -and
        $progressNotificationResult.messageSendCallCount -eq 0 -and
        $ownerPacketResult.meCallCount -eq 0 -and
        $progressNotificationResult.meCallCount -eq 0 -and
        -not $ownerPacketResult.confirmationTokenCreated -and
        -not $progressNotificationResult.confirmationTokenCreated) `
    "Auth-status probe must not call +me, request confirmation tokens, or invoke message +send when auth is missing."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$sourceFiles = @(
    "production-handoff-send-readiness-manifest.json",
    "release-progress-notification-outbox-manifest.json"
)

$reportLines = @(
    "# AI TestPilot Production Handoff Mail Helper Auth Status Probe",
    "",
    "- Status: $status",
    "- Owner packet helper exit code: $($ownerPacketResult.exitCode)",
    "- Progress notification helper exit code: $($progressNotificationResult.exitCode)",
    "- Owner packet auth status calls: $($ownerPacketResult.authStatusCallCount)",
    "- Progress notification auth status calls: $($progressNotificationResult.authStatusCallCount)",
    "- Owner packet send calls: $($ownerPacketResult.messageSendCallCount)",
    "- Progress notification send calls: $($progressNotificationResult.messageSendCallCount)",
    "- Confirmation token created: $($ownerPacketResult.confirmationTokenCreated -or $progressNotificationResult.confirmationTokenCreated)",
    "",
    "## Boundary",
    "",
    "- The probe uses a fake agently-cli that returns unauthenticated JSON followed by a tip line.",
    "- The probe does not run OAuth login.",
    "- The probe does not send email.",
    "- The probe does not create confirmation tokens.",
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
    (Convert-ToEvidenceRelativePath $ownerPacketResult.outputPath),
    (Convert-ToEvidenceRelativePath $ownerPacketResult.callLogPath),
    (Convert-ToEvidenceRelativePath $progressNotificationResult.outputPath),
    (Convert-ToEvidenceRelativePath $progressNotificationResult.callLogPath)
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_mail_helper_auth_status_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    probeDir = $probePath
    ownerPacketHelperScript = Convert-ToEvidenceRelativePath $ownerPacketHelperPath
    progressNotificationHelperScript = Convert-ToEvidenceRelativePath $progressNotificationHelperPath
    fakeAgentlyCliGenerated = Test-Path $fakeCliPath
    fakeAgentlyCliReturnsTipOutput = (Get-Content -Path $fakeCliPath -Encoding ASCII -Raw).Contains("tip: Authorization required")
    ownerPacketHelperAuthBoundaryPassed = [bool]($ownerPacketResult.exitCode -ne 0 -and $ownerPacketResult.outputContainsExpectedAuthError -and -not $ownerPacketResult.outputContainsJsonParseError)
    progressNotificationHelperAuthBoundaryPassed = [bool]($progressNotificationResult.exitCode -ne 0 -and $progressNotificationResult.outputContainsExpectedAuthError -and -not $progressNotificationResult.outputContainsJsonParseError)
    ownerPacketHelperExitCode = [int]$ownerPacketResult.exitCode
    progressNotificationHelperExitCode = [int]$progressNotificationResult.exitCode
    ownerPacketHelperAuthStatusCallCount = [int]$ownerPacketResult.authStatusCallCount
    progressNotificationHelperAuthStatusCallCount = [int]$progressNotificationResult.authStatusCallCount
    ownerPacketHelperMessageSendCallCount = [int]$ownerPacketResult.messageSendCallCount
    progressNotificationHelperMessageSendCallCount = [int]$progressNotificationResult.messageSendCallCount
    ownerPacketHelperMeCallCount = [int]$ownerPacketResult.meCallCount
    progressNotificationHelperMeCallCount = [int]$progressNotificationResult.meCallCount
    confirmationTokenCreated = [bool]($ownerPacketResult.confirmationTokenCreated -or $progressNotificationResult.confirmationTokenCreated)
    releasePipelineSendsEmail = $false
    emailSent = $false
    mailAuthorizationCheckedByPipeline = $false
    releasePipelineUsesFixture = $false
    realHostProjectEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "mail_helper_auth_status_probe_only"
    sourceFiles = @($sourceFiles)
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles + $sourceFiles)
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
}

$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestFullPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Production handoff mail helper auth-status probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production handoff mail helper auth-status probe manifest: $manifestFullPath"
Write-Output "Production handoff mail helper auth-status probe report: $reportFullPath"
Write-Output "PASS AI TestPilot production handoff mail helper auth-status probe"
