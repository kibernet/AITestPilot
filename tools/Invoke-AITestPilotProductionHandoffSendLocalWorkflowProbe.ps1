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
    $ProbeDir = Join-Path $EvidenceBundleDir "production-handoff-send-local-workflow-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-handoff-send-local-workflow-probe-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-handoff-send-local-workflow-probe.md"
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

function Invoke-OwnerPacketHelperWithFakeAgently {
    param(
        [string]$Mode,
        [string]$BundlePath,
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
        $scriptPath = Join-Path $BundlePath "production-handoff-send\send-owner-packets.ps1"
        $powerShellArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $scriptPath, "-EvidenceBundleDir", $BundlePath) + @($Arguments)
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
    $messageCallsWithToken = @($messageCalls | Where-Object { $_ -like "*--confirmation-token*" })
    $messageCallsWithoutToken = @($messageCalls | Where-Object { $_ -notlike "*--confirmation-token*" })

    return [ordered]@{
        mode = $Mode
        exitCode = [int]$exitCode
        outputPath = $OutputPath
        callLogPath = $CallLogPath
        outputText = $outputText
        tokenReturnedCount = [regex]::Matches($outputText, "ctk_owner_packet_[0-9]+").Count
        fakeSendSucceededCount = [regex]::Matches($outputText, "contract owner packet accepted").Count
        authStatusCallCount = [int]@($calls | Where-Object { $_ -eq "auth status" }).Count
        meCallCount = [int]@($calls | Where-Object { $_ -eq "+me" }).Count
        messageSendCallCount = [int]$messageCalls.Count
        messageSendWithTokenCount = [int]$messageCallsWithToken.Count
        messageSendWithoutTokenCount = [int]$messageCallsWithoutToken.Count
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
$dryRunProbeManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-send-dry-run-probe-manifest.json") "Production handoff send dry-run probe manifest"
$ownerContactExternalIntakeProbeManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-owner-contact-external-intake-probe-manifest.json") "Production handoff owner contact external intake probe manifest"
$mailHelperAuthStatusProbeManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-mail-helper-auth-status-probe-manifest.json") "Production handoff mail helper auth-status probe manifest"
$acceptedIntakeBundlePath = Join-Path $evidenceBundlePath "production-handoff-owner-contact-external-intake-probe\intake-bundle"
$acceptedSendScriptPath = Join-Path $acceptedIntakeBundlePath "production-handoff-send\send-owner-packets.ps1"
$defaultSendScriptPath = Join-Path $evidenceBundlePath "production-handoff-send\send-owner-packets.ps1"

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
    "    Write-Output '{ ""ok"": true, ""data"": { ""logged_in"": true, ""status"": ""logged_in"", ""message"": ""Logged in as fake owner packet sender."" } }'",
    "    exit 0",
    "}",
    "if (`$Args.Count -ge 1 -and `$Args[0] -eq '+me') {",
    "    Write-Output '{ ""ok"": true, ""data"": { ""email"": ""kibernet@agent.qq.com"", ""aliases"": [""kibernet@agent.qq.com""] } }'",
    "    exit 0",
    "}",
    "if (`$Args.Count -ge 2 -and `$Args[0] -eq 'message' -and `$Args[1] -eq '+send') {",
    "    if (`$Args -contains '--confirmation-token') {",
    "        Write-Output '{ ""ok"": true, ""data"": { ""message_id"": ""msg_owner_packet_workflow_001"", ""summary"": ""contract owner packet accepted"" } }'",
    "        exit 0",
    "    }",
    "    Write-Output '{ ""ok"": false, ""error"": { ""code"": ""CONFIRMATION_REQUIRED"", ""message"": ""confirmation required"", ""confirmation_token"": ""ctk_owner_packet_001"", ""summary"": ""Send owner packet."" } }'",
    "    exit 8",
    "}",
    "Write-Output '{ ""ok"": false, ""error"": { ""message"": ""unexpected fake agently-cli args"" } }'",
    "exit 2"
)
$fakeCliLines | Set-Content -Path $fakeCliPath -Encoding UTF8

$tokenMapPath = Join-Path $probePath "owner-packet-confirmation-token-map.json"
$acceptedContacts = Read-JsonFile (Join-Path $acceptedIntakeBundlePath "production-handoff-contact-roster.json") "Accepted contact roster"
$tokenEntries = @()
foreach ($entry in @($acceptedContacts.entries)) {
    $tokenEntries += [ordered]@{
        owner = [string]$entry.owner
        confirmationToken = "ctk_owner_packet_001"
    }
}
$tokenMap = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_owner_packet_confirmation_token_map.v1"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    entries = @($tokenEntries)
}
$tokenMap | ConvertTo-Json -Depth 8 | Set-Content -Path $tokenMapPath -Encoding UTF8

$receiptDir = Join-Path $probePath "owner-packet-send-receipts"
$unauthResult = Invoke-OwnerPacketHelperWithFakeAgently `
    -Mode "unauthenticated" `
    -BundlePath $acceptedIntakeBundlePath `
    -Arguments @("-PrepareConfirmation") `
    -CallLogPath (Join-Path $probePath "unauthenticated-agently-calls.log") `
    -OutputPath (Join-Path $probePath "unauthenticated-output.txt")

$defaultMissingContactPrepareResult = Invoke-OwnerPacketHelperWithFakeAgently `
    -Mode "logged_in" `
    -BundlePath $evidenceBundlePath `
    -Arguments @("-PrepareConfirmation") `
    -CallLogPath (Join-Path $probePath "default-missing-contact-prepare-agently-calls.log") `
    -OutputPath (Join-Path $probePath "default-missing-contact-prepare-output.txt")

$prepareResult = Invoke-OwnerPacketHelperWithFakeAgently `
    -Mode "logged_in" `
    -BundlePath $acceptedIntakeBundlePath `
    -Arguments @("-PrepareConfirmation") `
    -CallLogPath (Join-Path $probePath "prepare-confirmation-agently-calls.log") `
    -OutputPath (Join-Path $probePath "prepare-confirmation-output.txt")

$confirmResult = Invoke-OwnerPacketHelperWithFakeAgently `
    -Mode "logged_in" `
    -BundlePath $acceptedIntakeBundlePath `
    -Arguments @("-Send", "-ConfirmationTokenMapPath", $tokenMapPath, "-ReceiptDir", $receiptDir) `
    -CallLogPath (Join-Path $probePath "confirm-with-receipts-agently-calls.log") `
    -OutputPath (Join-Path $probePath "confirm-with-receipts-output.txt")

$receiptFiles = @()
if (Test-Path $receiptDir) {
    $receiptFiles = @(Get-ChildItem -LiteralPath $receiptDir -Filter "*.json" -File)
}
$receiptManifests = @($receiptFiles | ForEach-Object { Read-JsonFile $_.FullName "Owner packet send receipt" })
$ownerContactCount = Convert-ToInt (Get-JsonValue $sendReadinessManifest "ownerContactCount" 0)
$acceptedOwnerContactCount = Convert-ToInt (Get-JsonValue $ownerContactExternalIntakeProbeManifest "ownerContactCount" 0)
$receiptSchemaAcceptedCount = @($receiptManifests | Where-Object { (Get-JsonValue $_ "schemaVersion" "") -eq "aitestpilot.production_handoff_owner_packet_send_receipt.v1" }).Count
$receiptMessageIdCount = @($receiptManifests | Where-Object { (Get-JsonValue $_ "messageId" "") -eq "msg_owner_packet_workflow_001" }).Count
$receiptConfirmedCount = @($receiptManifests | Where-Object { Convert-ToBool (Get-JsonValue $_ "confirmationTokenSupplied" $false) }).Count
$receiptRealDeliveryVerifiedCount = @($receiptManifests | Where-Object { Convert-ToBool (Get-JsonValue $_ "realDeliveryVerified" $false) }).Count
$receiptReleasePipelineGeneratedCount = @($receiptManifests | Where-Object { Convert-ToBool (Get-JsonValue $_ "releasePipelineGenerated" $false) }).Count

$checks = @()
Add-ProbeCheck "owner_packet_local_workflow_sources_available" `
    ($sendReadinessManifest.status -eq "PASS" -and
        (Convert-ToBool (Get-JsonValue $sendReadinessManifest "sendScriptContentValidated" $false)) -and
        $dryRunProbeManifest.status -eq "PASS" -and
        $ownerContactExternalIntakeProbeManifest.status -eq "PASS" -and
        (Convert-ToBool (Get-JsonValue $ownerContactExternalIntakeProbeManifest "externalSendReadyForConfirmation" $false)) -and
        $mailHelperAuthStatusProbeManifest.status -eq "PASS" -and
        (Test-Path $acceptedSendScriptPath) -and
        (Test-Path $defaultSendScriptPath)) `
    "Owner-packet local workflow probe must use passing send readiness, dry-run, external-contact intake, and auth-status evidence."
Add-ProbeCheck "unauthenticated_stops_before_send" `
    ($unauthResult.exitCode -ne 0 -and
        $unauthResult.authStatusCallCount -eq 1 -and
        $unauthResult.meCallCount -eq 0 -and
        $unauthResult.messageSendCallCount -eq 0) `
    "Unauthenticated owner-packet workflow must stop at auth status before +me or message +send."
Add-ProbeCheck "default_missing_contacts_stop_before_send" `
    ($defaultMissingContactPrepareResult.exitCode -ne 0 -and
        $defaultMissingContactPrepareResult.authStatusCallCount -eq 1 -and
        $defaultMissingContactPrepareResult.meCallCount -eq 1 -and
        $defaultMissingContactPrepareResult.messageSendCallCount -eq 0) `
    "Default missing-contact owner-packet workflow must stop before message +send even when prepare is requested."
Add-ProbeCheck "prepare_requests_owner_confirmation_tokens" `
    ($prepareResult.exitCode -eq 8 -and
        $prepareResult.tokenReturnedCount -eq $acceptedOwnerContactCount -and
        $prepareResult.authStatusCallCount -eq 1 -and
        $prepareResult.meCallCount -eq 1 -and
        $prepareResult.messageSendCallCount -eq $acceptedOwnerContactCount -and
        $prepareResult.messageSendWithTokenCount -eq 0) `
    "Accepted-contact prepare phase must request one confirmation token per owner before sending."
Add-ProbeCheck "confirm_with_tokens_writes_owner_receipts" `
    ($confirmResult.exitCode -eq 0 -and
        $confirmResult.fakeSendSucceededCount -eq $acceptedOwnerContactCount -and
        $confirmResult.messageSendCallCount -eq $acceptedOwnerContactCount -and
        $confirmResult.messageSendWithTokenCount -eq $acceptedOwnerContactCount -and
        $receiptFiles.Count -eq $acceptedOwnerContactCount -and
        $receiptSchemaAcceptedCount -eq $acceptedOwnerContactCount -and
        $receiptMessageIdCount -eq $acceptedOwnerContactCount -and
        $receiptConfirmedCount -eq $acceptedOwnerContactCount) `
    "Token-confirmed owner-packet workflow must write one machine-readable receipt per owner."
Add-ProbeCheck "fake_receipts_preserve_real_send_boundary" `
    ($receiptRealDeliveryVerifiedCount -eq 0 -and
        $receiptReleasePipelineGeneratedCount -eq 0) `
    "Fake owner-packet receipts must not claim real delivery or pipeline generation."
Add-ProbeCheck "canonical_release_boundary_preserved" `
    (-not (Convert-ToBool (Get-JsonValue $sendReadinessManifest "releasePipelineSendsEmail" $false)) -and
        -not (Convert-ToBool (Get-JsonValue $sendReadinessManifest "emailSent" $false)) -and
        -not (Convert-ToBool (Get-JsonValue $sendReadinessManifest "automaticEmailSendReady" $false))) `
    "Canonical send readiness must remain not-sent and not automatically send-ready."

$failedChecks = @($checks | Where-Object { -not [bool]$_["passed"] })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$reportLines = @(
    "# AI TestPilot Production Handoff Send Local Workflow Probe",
    "",
    "- Status: $status",
    "- Owner contacts: $ownerContactCount",
    "- Accepted owner contacts: $acceptedOwnerContactCount",
    "- Unauthenticated exit code: $($unauthResult.exitCode)",
    "- Default missing-contact prepare exit code: $($defaultMissingContactPrepareResult.exitCode)",
    "- Prepare exit code: $($prepareResult.exitCode)",
    "- Prepare token count: $($prepareResult.tokenReturnedCount)",
    "- Confirm exit code: $($confirmResult.exitCode)",
    "- Receipt count: $($receiptFiles.Count)",
    "- Receipt real-delivery-verified count: $receiptRealDeliveryVerifiedCount",
    "",
    "## Boundary",
    "",
    "- The probe uses a fake agently-cli.",
    "- Missing-contact and unauthenticated paths stop before message +send.",
    "- The accepted-contact path proves the local two-stage flow and owner receipt shape only.",
    "- Fake receipts do not claim real delivery, pipeline generation, or canonical emailSent=true.",
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
    (Convert-ToEvidenceRelativePath $fakeCliPath),
    (Convert-ToEvidenceRelativePath $tokenMapPath),
    (Convert-ToEvidenceRelativePath $unauthResult.outputPath),
    (Convert-ToEvidenceRelativePath $unauthResult.callLogPath),
    (Convert-ToEvidenceRelativePath $defaultMissingContactPrepareResult.outputPath),
    (Convert-ToEvidenceRelativePath $defaultMissingContactPrepareResult.callLogPath),
    (Convert-ToEvidenceRelativePath $prepareResult.outputPath),
    (Convert-ToEvidenceRelativePath $prepareResult.callLogPath),
    (Convert-ToEvidenceRelativePath $confirmResult.outputPath),
    (Convert-ToEvidenceRelativePath $confirmResult.callLogPath)
) + @($receiptFiles | ForEach-Object { Convert-ToEvidenceRelativePath $_.FullName })

$sourceFiles = @(
    "production-handoff-send-readiness-manifest.json",
    "production-handoff-send-dry-run-probe-manifest.json",
    "production-handoff-owner-contact-external-intake-probe-manifest.json",
    "production-handoff-mail-helper-auth-status-probe-manifest.json",
    "production-handoff-send/send-owner-packets.ps1",
    "production-handoff-owner-contact-external-intake-probe/intake-bundle/production-handoff-send/send-owner-packets.ps1"
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_send_local_workflow_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    probeDir = $probePath
    fakeAgentlyCliGenerated = Test-Path $fakeCliPath
    ownerContactCount = [int]$ownerContactCount
    acceptedOwnerContactCount = [int]$acceptedOwnerContactCount
    unauthenticatedExitCode = [int]$unauthResult.exitCode
    unauthenticatedAuthStatusCallCount = [int]$unauthResult.authStatusCallCount
    unauthenticatedMeCallCount = [int]$unauthResult.meCallCount
    unauthenticatedMessageSendCallCount = [int]$unauthResult.messageSendCallCount
    defaultMissingContactPrepareExitCode = [int]$defaultMissingContactPrepareResult.exitCode
    defaultMissingContactPrepareMessageSendCallCount = [int]$defaultMissingContactPrepareResult.messageSendCallCount
    prepareExitCode = [int]$prepareResult.exitCode
    prepareConfirmationTokenReturnedCount = [int]$prepareResult.tokenReturnedCount
    prepareMessageSendCallCount = [int]$prepareResult.messageSendCallCount
    prepareMessageSendWithTokenCount = [int]$prepareResult.messageSendWithTokenCount
    confirmationExitCode = [int]$confirmResult.exitCode
    confirmationFakeSendSucceededCount = [int]$confirmResult.fakeSendSucceededCount
    confirmationMessageSendCallCount = [int]$confirmResult.messageSendCallCount
    confirmationMessageSendWithTokenCount = [int]$confirmResult.messageSendWithTokenCount
    ownerPacketReceiptGeneratedCount = [int]$receiptFiles.Count
    ownerPacketReceiptSchemaAcceptedCount = [int]$receiptSchemaAcceptedCount
    ownerPacketReceiptMessageIdCount = [int]$receiptMessageIdCount
    ownerPacketReceiptConfirmedCount = [int]$receiptConfirmedCount
    ownerPacketReceiptRealDeliveryVerifiedCount = [int]$receiptRealDeliveryVerifiedCount
    ownerPacketReceiptReleasePipelineGeneratedCount = [int]$receiptReleasePipelineGeneratedCount
    releasePipelineSendsEmail = $false
    realOwnerPacketEmailSent = $false
    emailSent = $false
    mailAuthorizationCheckedByPipeline = $false
    canonicalSendReadinessStatus = (Get-JsonValue $sendReadinessManifest "sendReadinessStatus" "")
    canonicalAutomaticEmailSendReady = (Get-JsonValue $sendReadinessManifest "automaticEmailSendReady" $false)
    releasePipelineUsesFixture = $false
    realHostProjectEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "owner_packet_local_send_workflow_probe_fake_cli_only"
    sourceFiles = @($sourceFiles)
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles + $sourceFiles)
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
}

$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestFullPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Production handoff send local workflow probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production handoff send local workflow probe manifest: $manifestFullPath"
Write-Output "Production handoff send local workflow probe report: $reportFullPath"
Write-Output "PASS AI TestPilot production handoff send local workflow probe"
