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

if ([string]::IsNullOrWhiteSpace($ProbeDir)) {
    $ProbeDir = Join-Path $EvidenceBundleDir "release-progress-notification-post-dispatch-snapshot-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "release-progress-notification-post-dispatch-snapshot-probe-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "release-progress-notification-post-dispatch-snapshot-probe.md"
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

function Invoke-PostDispatchSnapshot {
    param(
        [string]$Name,
        [string]$DispatchReceiptIntakePath,
        [string]$ManifestPath,
        [string]$ReportPath
    )

    $outputPath = Join-Path $probePath "$Name-output.txt"
    $powerShellArgs = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        (Join-Path $repoRoot "tools\Invoke-AITestPilotReleaseProgressNotificationPostDispatchSnapshot.ps1"),
        "-EvidenceBundleDir",
        $evidenceBundlePath,
        "-DispatchReceiptIntakePath",
        $DispatchReceiptIntakePath,
        "-ManifestPath",
        $ManifestPath,
        "-ReportPath",
        $ReportPath
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
    Set-Content -Path $outputPath -Value @($output | ForEach-Object { [string]$_ }) -Encoding UTF8

    $manifest = $null
    if (Test-Path $ManifestPath) {
        $manifest = Read-JsonFile $ManifestPath "$Name post-dispatch snapshot manifest"
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

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$probePath = Assert-PathUnderRepo $ProbeDir "ProbeDir"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

New-Item -ItemType Directory -Force $probePath | Out-Null
New-Item -ItemType Directory -Force (Split-Path $manifestFullPath -Parent) | Out-Null
New-Item -ItemType Directory -Force (Split-Path $reportFullPath -Parent) | Out-Null

$outboxManifest = Read-JsonFile (Join-Path $evidenceBundlePath "release-progress-notification-outbox-manifest.json") "Release progress notification outbox manifest"
$sourceSnapshot = Read-JsonFile (Join-Path $evidenceBundlePath "release-progress-notification-outbox\remaining-work-snapshot.json") "Release progress notification remaining-work snapshot"

$contractFixtureDispatchPath = Join-Path $probePath "contract-fixture-dispatch-receipt-intake-manifest.json"
$contractFixtureDispatch = [ordered]@{
    schemaVersion = "aitestpilot.release_progress_notification_dispatch_receipt_intake.v1"
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    recipient = [string](Get-JsonValue $outboxManifest "recipient" "")
    subject = [string](Get-JsonValue $outboxManifest "subject" "")
    receiptPath = Join-Path $probePath "contract-fixture-progress-notification-send-receipt.json"
    receiptAccepted = $true
    queued = $true
    messageId = ""
    dispatchEvidencePresent = $true
    confirmationTokenSupplied = $true
    agentlyCliExitCode = 0
    sendSucceeded = $true
    releasePipelineGenerated = $false
    realDeliveryVerified = $false
    contractFixtureMode = $true
    confirmLocalSendReceipt = $true
    operatorRealSendConfirmed = $false
    fakeReceiptRejected = $true
    releasePipelineSendsEmail = $false
    realEmailSentAccepted = $false
    emailSent = $false
    notificationDispatchStatus = "CONTRACT_RECEIPT_ACCEPTED_NOT_REAL_SEND"
    productionOutputBoundary = "progress_notification_dispatch_receipt_contract_only"
}
$contractFixtureDispatch | ConvertTo-Json -Depth 10 | Set-Content -Path $contractFixtureDispatchPath -Encoding UTF8

$contractRejectedResult = Invoke-PostDispatchSnapshot `
    -Name "contract-fixture-post-dispatch" `
    -DispatchReceiptIntakePath $contractFixtureDispatchPath `
    -ManifestPath (Join-Path $probePath "contract-fixture-post-dispatch-manifest.json") `
    -ReportPath (Join-Path $probePath "contract-fixture-post-dispatch.md")

$contractRejectedManifest = $contractRejectedResult.manifest

$checks = @()
Add-ProbeCheck "post_dispatch_probe_sources_available" `
    ((Get-JsonValue $outboxManifest "status" "") -eq "PASS" -and
        (Get-JsonValue $sourceSnapshot "status" "") -eq "PASS" -and
        (Test-Path (Join-Path $repoRoot "tools\Invoke-AITestPilotReleaseProgressNotificationPostDispatchSnapshot.ps1"))) `
    "Post-dispatch snapshot probe must use passing outbox evidence and the post-dispatch snapshot script."
Add-ProbeCheck "contract_fixture_dispatch_rejected" `
    ($contractRejectedResult.exitCode -ne 0 -and
        $null -ne $contractRejectedManifest -and
        (Get-JsonValue $contractRejectedManifest "status" "") -eq "FAIL" -and
        -not (Convert-ToBool (Get-JsonValue $contractRejectedManifest "realEmailSentAccepted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $contractRejectedManifest "emailSent" $true))) `
    "Contract fixture dispatch intake must not be accepted as a real post-dispatch send."
Add-ProbeCheck "contract_fixture_keeps_local_mail_remaining" `
    ((Convert-ToInt (Get-JsonValue $contractRejectedManifest "localProgressMailRemainingActionCount" 0)) -eq 1 -and
        (Convert-ToInt (Get-JsonValue $contractRejectedManifest "trackedRemainingWorkItemCount" 0)) -eq 4) `
    "Rejected contract fixture dispatch must keep the local progress-mail action in remaining work."
Add-ProbeCheck "contract_fixture_preserves_external_boundary" `
    ((Convert-ToInt (Get-JsonValue $contractRejectedManifest "externalRemainingWorkItemCount" 0)) -eq 3 -and
        (Convert-ToInt (Get-JsonValue $contractRejectedManifest "externalRemainingBlockingReasonCount" 0)) -eq 11 -and
        (Convert-ToInt (Get-JsonValue $contractRejectedManifest "externalRemainingMissingFileCount" 0)) -eq 9 -and
        -not (Convert-ToBool (Get-JsonValue $contractRejectedManifest "releasePipelineSendsEmail" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $contractRejectedManifest "externalEvidenceAccepted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $contractRejectedManifest "fixtureEvidencePromoted" $true))) `
    "Rejected contract fixture dispatch must preserve external blockers, no-send, and no-fixture-promotion boundaries."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestFullPath),
    (Convert-ToEvidenceRelativePath $reportFullPath),
    (Convert-ToEvidenceRelativePath $contractFixtureDispatchPath),
    (Convert-ToEvidenceRelativePath $contractRejectedResult.outputPath),
    (Convert-ToEvidenceRelativePath $contractRejectedResult.manifestPath),
    (Convert-ToEvidenceRelativePath $contractRejectedResult.reportPath)
)
$sourceFiles = @(
    "release-progress-notification-outbox-manifest.json",
    "release-progress-notification-outbox/remaining-work-snapshot.json"
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.release_progress_notification_post_dispatch_snapshot_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    probeDir = $probePath
    contractFixtureRejected = ($contractRejectedResult.exitCode -ne 0 -and (Get-JsonValue $contractRejectedManifest "status" "") -eq "FAIL")
    contractFixtureEmailSent = Convert-ToBool (Get-JsonValue $contractRejectedManifest "emailSent" $true)
    contractFixtureRealEmailSentAccepted = Convert-ToBool (Get-JsonValue $contractRejectedManifest "realEmailSentAccepted" $true)
    contractFixtureLocalMailRemainingActionCount = Convert-ToInt (Get-JsonValue $contractRejectedManifest "localProgressMailRemainingActionCount" 0)
    contractFixtureTrackedRemainingWorkItemCount = Convert-ToInt (Get-JsonValue $contractRejectedManifest "trackedRemainingWorkItemCount" 0)
    contractFixtureExternalRemainingWorkItemCount = Convert-ToInt (Get-JsonValue $contractRejectedManifest "externalRemainingWorkItemCount" 0)
    contractFixtureExternalRemainingBlockingReasonCount = Convert-ToInt (Get-JsonValue $contractRejectedManifest "externalRemainingBlockingReasonCount" 0)
    contractFixtureExternalRemainingMissingFileCount = Convert-ToInt (Get-JsonValue $contractRejectedManifest "externalRemainingMissingFileCount" 0)
    releasePipelineSendsEmail = $false
    canonicalOutboxDispatchStatus = [string](Get-JsonValue $outboxManifest "notificationDispatchStatus" "")
    canonicalOutboxEmailSent = Convert-ToBool (Get-JsonValue $outboxManifest "emailSent" $false)
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "progress_notification_post_dispatch_snapshot_probe_only"
    sourceFiles = @($sourceFiles)
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles + $sourceFiles)
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
}

$reportLines = @(
    "# AI TestPilot Release Progress Notification Post-Dispatch Snapshot Probe",
    "",
    "- Status: $status",
    "- Contract fixture rejected: $($manifest.contractFixtureRejected)",
    "- Contract fixture email sent: $($manifest.contractFixtureEmailSent)",
    "- Contract fixture local mail remaining actions: $($manifest.contractFixtureLocalMailRemainingActionCount)",
    "- Contract fixture tracked remaining work items: $($manifest.contractFixtureTrackedRemainingWorkItemCount)",
    "",
    "## Boundary",
    "",
    "- Contract fixture receipt intake is not enough to clear local progress-mail remaining work.",
    "- The release pipeline still does not send email.",
    "- External evidence and fixture promotion boundaries are preserved.",
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
$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestFullPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Release progress notification post-dispatch snapshot probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Release progress notification post-dispatch snapshot probe manifest: $manifestFullPath"
Write-Output "Release progress notification post-dispatch snapshot probe report: $reportFullPath"
Write-Output "PASS AI TestPilot release progress notification post-dispatch snapshot probe"
