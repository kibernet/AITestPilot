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
    $ProbeDir = Join-Path $EvidenceBundleDir "production-handoff-owner-packet-dispatch-receipt-intake-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-handoff-owner-packet-dispatch-receipt-intake-probe-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-handoff-owner-packet-dispatch-receipt-intake-probe.md"
}

function Resolve-FullPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Test-PathWithinRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    $fullPath = Resolve-FullPath $Path
    $rootPath = (Resolve-FullPath $Root).TrimEnd([char[]]@("\", "/"))
    return $fullPath.Equals($rootPath, [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($rootPath + "\", [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($rootPath + "/", [System.StringComparison]::OrdinalIgnoreCase)
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

function Assert-PathUnderEvidenceBundle {
    param(
        [string]$Path,
        [string]$Label
    )

    $fullPath = Assert-PathUnderRepo $Path $Label
    if (-not (Test-PathWithinRoot $fullPath $script:evidenceBundlePath)) {
        throw "$Label must stay under evidence bundle: $fullPath"
    }

    return $fullPath
}

function Convert-ToEvidenceRelativePath {
    param([string]$Path)

    $fullPath = Resolve-FullPath $Path
    if (-not (Test-PathWithinRoot $fullPath $evidenceBundlePath)) {
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
        [string]$MessagePrefix,
        [switch]$QueuedOnly
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

        $messageId = if ([bool]$QueuedOnly) { "" } else { "{0}_{1:000}" -f $MessagePrefix, $index }
        $cliOutput = if ([bool]$QueuedOnly) {
            '{ "ok": true, "data": { "queued": true } }'
        }
        else {
            "{ ""ok"": true, ""data"": { ""message_id"": ""$messageId"" } }"
        }
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
            queued = [bool]$QueuedOnly
            sendSucceeded = $true
            releasePipelineGenerated = $false
            realDeliveryVerified = $false
            cliOutput = @($cliOutput)
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
        [switch]$ContractFixtureMode
    )

    $outputPath = Join-Path $probePath "$Name-output.txt"
    $runOutputDir = Join-Path $acceptedIntakeBundlePath "owner-packet-dispatch-receipt-intake-probe"
    $manifestPathForRun = Join-Path $runOutputDir "$Name-manifest.json"
    $reportPathForRun = Join-Path $runOutputDir "$Name.md"
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

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$probePath = Assert-PathUnderEvidenceBundle $ProbeDir "ProbeDir"
$manifestFullPath = Assert-PathUnderEvidenceBundle $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderEvidenceBundle $ReportPath "ReportPath"

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
$ownerContactExternalIntakeProbeManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-owner-contact-external-intake-probe-manifest.json") "Production handoff owner contact external intake probe manifest"
$localWorkflowProbeManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-send-local-workflow-probe-manifest.json") "Production handoff send local workflow probe manifest"
$acceptedIntakeBundlePath = Join-Path $evidenceBundlePath "production-handoff-owner-contact-external-intake-probe\intake-bundle"
$acceptedSendQueue = Read-JsonFile (Join-Path $acceptedIntakeBundlePath "production-handoff-send\production-handoff-send-queue.json") "Accepted contact send queue"
$acceptedContacts = Read-JsonFile (Join-Path $acceptedIntakeBundlePath "production-handoff-contact-roster.json") "Accepted contact roster"
$queueEntries = @(Convert-ToArray (Get-JsonValue $acceptedSendQueue "entries" @()))
$contactEntries = @(Convert-ToArray (Get-JsonValue $acceptedContacts "entries" @()))
$ownerContactCount = Convert-ToInt (Get-JsonValue $ownerContactExternalIntakeProbeManifest "ownerContactCount" 0)
$acceptedIntakeProbePath = Join-Path $acceptedIntakeBundlePath "owner-packet-dispatch-receipt-intake-probe"
if (Test-Path $acceptedIntakeProbePath) {
    Remove-Item -LiteralPath $acceptedIntakeProbePath -Recurse -Force
}
New-Item -ItemType Directory -Force $acceptedIntakeProbePath | Out-Null

$fakeReceiptDir = Join-Path $acceptedIntakeBundlePath "owner-packet-dispatch-receipt-intake-probe\fake-owner-packet-send-receipts"
$contractReceiptDir = Join-Path $acceptedIntakeBundlePath "owner-packet-dispatch-receipt-intake-probe\contract-owner-packet-send-receipts"
$queuedReceiptDir = Join-Path $acceptedIntakeBundlePath "owner-packet-dispatch-receipt-intake-probe\queued-owner-packet-send-receipts"
New-OwnerPacketReceiptSet -ReceiptDir $fakeReceiptDir -MessagePrefix "msg_owner_packet_workflow"
New-OwnerPacketReceiptSet -ReceiptDir $contractReceiptDir -MessagePrefix "msg_contract_owner_packet_receipt"
New-OwnerPacketReceiptSet -ReceiptDir $queuedReceiptDir -MessagePrefix "msg_contract_owner_packet_queued" -QueuedOnly

$fakeResult = Invoke-OwnerPacketReceiptIntake `
    -Name "fake-workflow-receipts" `
    -ReceiptDir $fakeReceiptDir
$contractResult = Invoke-OwnerPacketReceiptIntake `
    -Name "contract-receipts" `
    -ReceiptDir $contractReceiptDir `
    -ContractFixtureMode
$queuedResult = Invoke-OwnerPacketReceiptIntake `
    -Name "queued-contract-receipts" `
    -ReceiptDir $queuedReceiptDir `
    -ContractFixtureMode

$outsideEvidenceReceiptDir = Join-Path ($acceptedIntakeBundlePath + "-sibling") "owner-packet-send-receipts"
$pathBoundaryResult = Invoke-OwnerPacketReceiptIntake `
    -Name "receipt-dir-boundary" `
    -ReceiptDir $outsideEvidenceReceiptDir `
    -ContractFixtureMode

$fakeManifest = $fakeResult.manifest
$contractManifest = $contractResult.manifest
$queuedManifest = $queuedResult.manifest
$pathBoundaryRejected = $pathBoundaryResult.exitCode -ne 0 -and
    $null -eq $pathBoundaryResult.manifest -and
    -not (Test-Path $pathBoundaryResult.manifestPath) -and
    -not (Test-Path $pathBoundaryResult.reportPath)

$checks = @()
Add-ProbeCheck "owner_packet_receipt_intake_sources_available" `
    ($sendReadinessManifest.status -eq "PASS" -and
        $ownerContactExternalIntakeProbeManifest.status -eq "PASS" -and
        $localWorkflowProbeManifest.status -eq "PASS" -and
        (Test-Path $acceptedIntakeBundlePath) -and
        (Test-Path $fakeReceiptDir) -and
        $queueEntries.Count -eq $ownerContactCount) `
    "Owner-packet dispatch receipt intake probe must use passing send readiness, external contact intake, local workflow, and fake receipt evidence."
Add-ProbeCheck "fake_local_workflow_receipts_rejected" `
    ($fakeResult.exitCode -ne 0 -and
        $fakeManifest.status -eq "FAIL" -and
        (Get-JsonValue $fakeManifest "receiptExpectedCount" 0) -eq $ownerContactCount -and
        (Get-JsonValue $fakeManifest "receiptAcceptedCount" -1) -eq 0 -and
        (Get-JsonValue $fakeManifest "fakeReceiptRejectedCount" -1) -eq 0 -and
        (Get-JsonValue $fakeManifest "fakeReceiptDetectedCount" -1) -eq $ownerContactCount -and
        -not (Get-JsonValue $fakeManifest "realOwnerPacketEmailSent" $true)) `
    "Fake owner-packet workflow receipts must be rejected and must not claim real sends."
Add-ProbeCheck "contract_receipts_accepted_not_real_send" `
    ($contractResult.exitCode -eq 0 -and
        $contractManifest.status -eq "PASS" -and
        (Get-JsonValue $contractManifest "receiptAcceptedCount" 0) -eq $ownerContactCount -and
        (Get-JsonValue $contractManifest "ownerPacketDispatchStatus" "") -eq "CONTRACT_RECEIPTS_ACCEPTED_NOT_REAL_SEND" -and
        (Get-JsonValue $contractManifest "contractFixtureMode" $false) -and
        -not (Get-JsonValue $contractManifest "realOwnerPacketEmailSent" $true) -and
        -not (Get-JsonValue $contractManifest "emailSent" $true)) `
    "Contract owner-packet receipts must prove shape only and must not claim real delivery."
Add-ProbeCheck "queued_contract_receipts_count_as_dispatch_evidence" `
    ($queuedResult.exitCode -eq 0 -and
        $queuedManifest.status -eq "PASS" -and
        (Get-JsonValue $queuedManifest "receiptAcceptedCount" 0) -eq $ownerContactCount -and
        (Get-JsonValue $queuedManifest "ownerPacketReceiptQueuedCount" 0) -eq $ownerContactCount -and
        (Get-JsonValue $queuedManifest "ownerPacketReceiptMessageIdCount" -1) -eq 0 -and
        -not (Get-JsonValue $queuedManifest "realOwnerPacketEmailSent" $true)) `
    "Queued owner-packet receipts must count as dispatch evidence without claiming real send completion."
Add-ProbeCheck "canonical_send_boundary_preserved" `
    ((Get-JsonValue $sendReadinessManifest "sendReadinessStatus" "") -eq "BLOCKED_MISSING_OWNER_EMAILS" -and
        -not (Get-JsonValue $sendReadinessManifest "automaticEmailSendReady" $true) -and
        -not (Get-JsonValue $localWorkflowProbeManifest "realOwnerPacketEmailSent" $true)) `
    "Canonical owner-packet send readiness and local workflow must remain not sent."
Add-ProbeCheck "release_pipeline_owner_packet_boundary_preserved" `
    (-not (Get-JsonValue $contractManifest "releasePipelineSendsEmail" $true) -and
        -not (Get-JsonValue $queuedManifest "releasePipelineSendsEmail" $true) -and
        -not (Get-JsonValue $contractManifest "realHostProjectEvidenceAccepted" $true) -and
        -not (Get-JsonValue $contractManifest "fixtureEvidencePromoted" $true)) `
    "Owner-packet receipt intake proof must not send email, accept host-project evidence, or promote fixtures."
Add-ProbeCheck "owner_packet_receipt_paths_reject_outside_evidence_bundle" `
    ([bool]$pathBoundaryRejected) `
    "Owner-packet receipt intake must reject receipt directories outside the current evidence bundle before writing output."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$reportLines = @(
    "# AI TestPilot Production Handoff Owner Packet Dispatch Receipt Intake Probe",
    "",
    "- Status: $status",
    "- Owner contacts: $ownerContactCount",
    "- Fake intake exit code: $($fakeResult.exitCode)",
    "- Contract receipt accepted count: $((Get-JsonValue $contractManifest "receiptAcceptedCount" 0))",
    "- Queued receipt accepted count: $((Get-JsonValue $queuedManifest "receiptAcceptedCount" 0))",
    "",
    "## Boundary",
    "",
    "- Fake local workflow receipts are rejected as real dispatch evidence.",
    "- Contract and queued receipts prove shape only.",
    "- Receipt directories outside the current evidence bundle are rejected before output is written.",
    "- The release pipeline does not send owner-packet email.",
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
    (Convert-ToEvidenceRelativePath $fakeReceiptDir),
    (Convert-ToEvidenceRelativePath $contractReceiptDir),
    (Convert-ToEvidenceRelativePath $queuedReceiptDir),
    (Convert-ToEvidenceRelativePath $fakeResult.outputPath),
    (Convert-ToEvidenceRelativePath $fakeResult.manifestPath),
    (Convert-ToEvidenceRelativePath $fakeResult.reportPath),
    (Convert-ToEvidenceRelativePath $contractResult.outputPath),
    (Convert-ToEvidenceRelativePath $contractResult.manifestPath),
    (Convert-ToEvidenceRelativePath $contractResult.reportPath),
    (Convert-ToEvidenceRelativePath $queuedResult.outputPath),
    (Convert-ToEvidenceRelativePath $queuedResult.manifestPath),
    (Convert-ToEvidenceRelativePath $queuedResult.reportPath),
    (Convert-ToEvidenceRelativePath $pathBoundaryResult.outputPath)
)
$sourceFiles = @(
    "production-handoff-send-readiness-manifest.json",
    "production-handoff-owner-contact-external-intake-probe-manifest.json",
    "production-handoff-send-local-workflow-probe-manifest.json",
    "production-handoff-owner-contact-external-intake-probe/intake-bundle/production-handoff-send/production-handoff-send-queue.json",
    "production-handoff-owner-contact-external-intake-probe/intake-bundle/production-handoff-contact-roster.json"
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_owner_packet_dispatch_receipt_intake_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    probeDir = $probePath
    ownerContactCount = [int]$ownerContactCount
    fakeReceiptsRejected = [bool](Get-JsonValue $checks[1] "passed" $false)
    fakeReceiptRejectedByIntake = [bool]($fakeResult.exitCode -ne 0 -and (Convert-ToInt (Get-JsonValue $fakeManifest "receiptAcceptedCount" 0)) -eq 0)
    fakeReceiptAcceptedByIntake = [bool]((Convert-ToInt (Get-JsonValue $fakeManifest "receiptAcceptedCount" 0)) -gt 0)
    fakeReceiptIntakeExitCode = [int]$fakeResult.exitCode
    fakeReceiptAcceptedCount = Convert-ToInt (Get-JsonValue $fakeManifest "receiptAcceptedCount" 0)
    fakeReceiptRejectedCount = Convert-ToInt (Get-JsonValue $fakeManifest "fakeReceiptRejectedCount" 0)
    fakeReceiptDetectedCount = Convert-ToInt (Get-JsonValue $fakeManifest "fakeReceiptDetectedCount" 0)
    contractReceiptIntakeAccepted = [bool](Get-JsonValue $checks[2] "passed" $false)
    contractReceiptAcceptedCount = Convert-ToInt (Get-JsonValue $contractManifest "receiptAcceptedCount" 0)
    contractOwnerPacketDispatchStatus = Get-JsonValue $contractManifest "ownerPacketDispatchStatus" ""
    contractRealOwnerPacketEmailSent = Get-JsonValue $contractManifest "realOwnerPacketEmailSent" $true
    queuedReceiptIntakeAccepted = [bool](Get-JsonValue $checks[3] "passed" $false)
    queuedReceiptAcceptedCount = Convert-ToInt (Get-JsonValue $queuedManifest "receiptAcceptedCount" 0)
    queuedReceiptQueuedCount = Convert-ToInt (Get-JsonValue $queuedManifest "ownerPacketReceiptQueuedCount" 0)
    queuedReceiptMessageIdCount = Convert-ToInt (Get-JsonValue $queuedManifest "ownerPacketReceiptMessageIdCount" 0)
    pathBoundaryRejected = [bool]$pathBoundaryRejected
    releasePipelineSendsEmail = $false
    realOwnerPacketEmailSent = $false
    emailSent = $false
    realHostProjectEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "owner_packet_dispatch_receipt_intake_contract_probe_only"
    sourceFiles = @($sourceFiles)
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles + $sourceFiles)
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
}

$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestFullPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Production handoff owner packet dispatch receipt intake probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production handoff owner packet dispatch receipt intake probe manifest: $manifestFullPath"
Write-Output "Production handoff owner packet dispatch receipt intake probe report: $reportFullPath"
Write-Output "PASS AI TestPilot production handoff owner packet dispatch receipt intake probe"
