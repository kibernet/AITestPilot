[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ExportDir,
    [string]$ManifestPath,
    [string]$ZipPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ExportDir)) {
    $ExportDir = Join-Path $EvidenceBundleDir "production-handoff-export"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-handoff-export-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ZipPath)) {
    $ZipPath = Join-Path $EvidenceBundleDir "production-handoff-export.zip"
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
    if (-not $fullPath.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must stay under repo root: $fullPath"
    }

    return $fullPath
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

function Get-ObjectProperty {
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

function Copy-ExportFile {
    param(
        [string]$RelativePath,
        [string]$DestinationRelativePath = ""
    )

    if ([string]::IsNullOrWhiteSpace($DestinationRelativePath)) {
        $DestinationRelativePath = $RelativePath
    }

    $sourcePath = Join-Path $script:evidenceBundlePath $RelativePath
    if (-not (Test-Path $sourcePath)) {
        throw "Export source file is missing: $sourcePath"
    }

    $destinationPath = Join-Path $script:exportPath $DestinationRelativePath
    New-Item -ItemType Directory -Force (Split-Path $destinationPath -Parent) | Out-Null
    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
}

function Copy-ExportDirectory {
    param(
        [string]$RelativePath,
        [string]$DestinationRelativePath = ""
    )

    if ([string]::IsNullOrWhiteSpace($DestinationRelativePath)) {
        $DestinationRelativePath = $RelativePath
    }

    $sourcePath = Join-Path $script:evidenceBundlePath $RelativePath
    if (-not (Test-Path $sourcePath)) {
        throw "Export source directory is missing: $sourcePath"
    }

    $destinationPath = Join-Path $script:exportPath $DestinationRelativePath
    if (Test-Path $destinationPath) {
        Remove-Item -LiteralPath $destinationPath -Recurse -Force
    }

    New-Item -ItemType Directory -Force (Split-Path $destinationPath -Parent) | Out-Null
    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Recurse -Force
}

function Convert-ToRelativePath {
    param(
        [string]$Root,
        [string]$Path
    )

    $rootUri = [System.Uri](([System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'))
    $pathUri = [System.Uri]([System.IO.Path]::GetFullPath($Path))
    return [System.Uri]::UnescapeDataString($rootUri.MakeRelativeUri($pathUri).ToString()).Replace("/", "\")
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$exportPath = Assert-PathUnderRepo $ExportDir "ExportDir"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$zipFullPath = Assert-PathUnderRepo $ZipPath "ZipPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if (Test-Path $exportPath) {
    Remove-Item -LiteralPath $exportPath -Recurse -Force
}
if (Test-Path $zipFullPath) {
    Remove-Item -LiteralPath $zipFullPath -Force
}

New-Item -ItemType Directory -Force $exportPath | Out-Null

$handoffManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-package-manifest.json") "Production handoff package manifest"
$preflightProbeManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-external-evidence-preflight-probe-manifest.json") "Production handoff external evidence preflight probe manifest"
$acceptanceContractProbeManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-external-evidence-acceptance-contract-probe-manifest.json") "Production external evidence acceptance contract probe manifest"
$acceptanceFailureProbeManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-external-evidence-acceptance-failure-probe-manifest.json") "Production external evidence acceptance failure probe manifest"
$inboxContractProbeManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-external-evidence-inbox-contract-probe-manifest.json") "Production external evidence inbox contract probe manifest"
$semanticPreflightProbeManifestPath = Join-Path $evidenceBundlePath "production-external-evidence-semantic-preflight-probe-manifest.json"
$semanticPreflightProbeReportPath = Join-Path $evidenceBundlePath "production-external-evidence-semantic-preflight-probe.md"
$semanticPreflightProbeAvailable = (Test-Path $semanticPreflightProbeManifestPath) -and (Test-Path $semanticPreflightProbeReportPath)
$semanticPreflightProbeManifest = $null
if ($semanticPreflightProbeAvailable) {
    $semanticPreflightProbeManifest = Read-JsonFile $semanticPreflightProbeManifestPath "Production external evidence semantic preflight probe manifest"
    if ((Get-ObjectProperty $semanticPreflightProbeManifest "status" "") -ne "PASS") {
        $semanticPreflightProbeAvailable = $false
        $semanticPreflightProbeManifest = $null
    }
}
$ownerResponseBundleKitManifestPath = Join-Path $evidenceBundlePath "production-handoff-owner-response-bundle-kit-manifest.json"
$ownerResponseBundleKitWorkflowProbeManifestPath = Join-Path $evidenceBundlePath "production-handoff-owner-response-bundle-kit-workflow-probe-manifest.json"
$ownerResponseBundleKitDirPath = Join-Path $evidenceBundlePath "production-handoff-owner-response-bundle-kit"
$ownerResponseBundleKitAvailable = (Test-Path $ownerResponseBundleKitManifestPath) -and (Test-Path $ownerResponseBundleKitWorkflowProbeManifestPath) -and (Test-Path $ownerResponseBundleKitDirPath)
$ownerResponseBundleKitManifest = $null
$ownerResponseBundleKitWorkflowProbeManifest = $null
if ($ownerResponseBundleKitAvailable) {
    $ownerResponseBundleKitManifest = Read-JsonFile $ownerResponseBundleKitManifestPath "Production handoff owner response bundle kit manifest"
    $ownerResponseBundleKitWorkflowProbeManifest = Read-JsonFile $ownerResponseBundleKitWorkflowProbeManifestPath "Production handoff owner response bundle kit workflow probe manifest"
    if ((Get-ObjectProperty $ownerResponseBundleKitManifest "status" "") -ne "PASS" -or
        (Get-ObjectProperty $ownerResponseBundleKitWorkflowProbeManifest "status" "") -ne "PASS") {
        $ownerResponseBundleKitAvailable = $false
        $ownerResponseBundleKitManifest = $null
        $ownerResponseBundleKitWorkflowProbeManifest = $null
    }
}
$canonicalOperatorActionQueueFileMap = @(
    [ordered]@{ source = "production-external-evidence-action-queue-manifest.json"; destination = "operator-actions\production-external-evidence-action-queue-manifest.json" },
    [ordered]@{ source = "production-external-evidence-action-queue.md"; destination = "operator-actions\production-external-evidence-action-queue.md" },
    [ordered]@{ source = "production-external-evidence-action-queue-probe-manifest.json"; destination = "operator-actions\production-external-evidence-action-queue-probe-manifest.json" },
    [ordered]@{ source = "production-external-evidence-action-queue-probe.md"; destination = "operator-actions\production-external-evidence-action-queue-probe.md" },
    [ordered]@{ source = "release-progress-notification-post-dispatch-snapshot-manifest.json"; destination = "operator-actions\release-progress-notification-post-dispatch-snapshot-manifest.json" },
    [ordered]@{ source = "release-progress-notification-post-dispatch-snapshot.md"; destination = "operator-actions\release-progress-notification-post-dispatch-snapshot.md" }
)
$probeOperatorActionQueueFileMap = @(
    [ordered]@{ source = "production-external-evidence-action-queue-probe\post-dispatch-action-queue-manifest.json"; destination = "operator-actions\production-external-evidence-action-queue-manifest.json" },
    [ordered]@{ source = "production-external-evidence-action-queue-probe\post-dispatch-action-queue.md"; destination = "operator-actions\production-external-evidence-action-queue.md" },
    [ordered]@{ source = "production-external-evidence-action-queue-probe-manifest.json"; destination = "operator-actions\production-external-evidence-action-queue-probe-manifest.json" },
    [ordered]@{ source = "production-external-evidence-action-queue-probe.md"; destination = "operator-actions\production-external-evidence-action-queue-probe.md" },
    [ordered]@{ source = "production-external-evidence-action-queue-probe\contract-post-dispatch-snapshot-manifest.json"; destination = "operator-actions\release-progress-notification-post-dispatch-snapshot-manifest.json" },
    [ordered]@{ source = "production-external-evidence-action-queue-probe\post-dispatch-action-queue-output.txt"; destination = "operator-actions\production-external-evidence-action-queue-output.txt" }
)
$canonicalOperatorActionQueueAvailable = (@($canonicalOperatorActionQueueFileMap | Where-Object { -not (Test-Path (Join-Path $evidenceBundlePath $_["source"])) }).Count -eq 0)
$probeOperatorActionQueueAvailable = (@($probeOperatorActionQueueFileMap | Where-Object { -not (Test-Path (Join-Path $evidenceBundlePath $_["source"])) }).Count -eq 0)
$operatorActionQueueFiles = @()
$operatorActionQueueSourceKind = ""
if ($canonicalOperatorActionQueueAvailable) {
    $operatorActionQueueFiles = @($canonicalOperatorActionQueueFileMap)
    $operatorActionQueueSourceKind = "canonical_post_dispatch_action_queue"
}
elseif ($probeOperatorActionQueueAvailable) {
    $operatorActionQueueFiles = @($probeOperatorActionQueueFileMap)
    $operatorActionQueueSourceKind = "probe_post_dispatch_action_queue"
}
$operatorActionQueueAvailable = @($operatorActionQueueFiles).Count -gt 0
$operatorActionQueueManifest = $null
$operatorActionQueueProbeManifest = $null
if ($operatorActionQueueAvailable) {
    $operatorActionQueueManifest = Read-JsonFile (Join-Path $evidenceBundlePath $operatorActionQueueFiles[0]["source"]) "Production external evidence action queue manifest"
    $operatorActionQueueProbeManifest = Read-JsonFile (Join-Path $evidenceBundlePath $operatorActionQueueFiles[2]["source"]) "Production external evidence action queue probe manifest"
    if ((Get-ObjectProperty $operatorActionQueueManifest "status" "") -ne "PASS" -or
        (Get-ObjectProperty $operatorActionQueueProbeManifest "status" "") -ne "PASS") {
        $operatorActionQueueAvailable = $false
        $operatorActionQueueFiles = @()
        $operatorActionQueueSourceKind = ""
        $operatorActionQueueManifest = $null
        $operatorActionQueueProbeManifest = $null
    }
}

$requiredDirectories = @(
    "production-handoff-package",
    "production-driver-binding-kit",
    "production-lua-patch-evidence-kit",
    "live-model-endpoint-config-kit"
)
if ($ownerResponseBundleKitAvailable) {
    $requiredDirectories += "production-handoff-owner-response-bundle-kit"
}

foreach ($directory in $requiredDirectories) {
    Copy-ExportDirectory $directory
}

Copy-ExportDirectory "production-external-evidence-inbox"

$requiredFiles = @(
    "production-handoff-package-manifest.json",
    "production-handoff-external-evidence-preflight-probe-manifest.json",
    "production-handoff-external-evidence-preflight-accepted-manifest.json",
    "production-handoff-external-evidence-acceptance-wrapper-manifest.json",
    "production-handoff-external-evidence-acceptance-manifest.json",
    "production-handoff-external-evidence-acceptance.md",
    "production-external-evidence-acceptance-contract-probe-manifest.json",
    "production-external-evidence-acceptance-contract-manifest.json",
    "production-external-evidence-acceptance-contract.md",
    "production-external-evidence-acceptance-failure-probe-manifest.json",
    "production-external-evidence-acceptance-missing-all-manifest.json",
    "production-external-evidence-acceptance-missing-all.md",
    "production-external-evidence-acceptance-driver-only-manifest.json",
    "production-external-evidence-acceptance-driver-only.md",
    "production-external-evidence-inbox-manifest.json",
    "production-external-evidence-inbox.md",
    "production-external-evidence-inbox-contract-probe-manifest.json",
    "production-external-evidence-inbox-acceptance-wrapper-manifest.json",
    "production-external-evidence-inbox-acceptance-manifest.json",
    "production-external-evidence-inbox-acceptance.md"
)
if ($semanticPreflightProbeAvailable) {
    $requiredFiles += @(
        "production-external-evidence-semantic-preflight-probe-manifest.json",
        "production-external-evidence-semantic-preflight-probe.md"
    )
}
if ($ownerResponseBundleKitAvailable) {
    $requiredFiles += @(
        "production-handoff-owner-response-bundle-kit-manifest.json",
        "production-handoff-owner-response-bundle-kit.md",
        "production-handoff-owner-response-bundle-kit-workflow-probe-manifest.json",
        "production-handoff-owner-response-bundle-kit-workflow-probe.md"
    )
}

foreach ($fileName in $requiredFiles) {
    Copy-ExportFile $fileName ("contract-evidence\" + $fileName)
}
if ($operatorActionQueueAvailable) {
    foreach ($fileSpec in $operatorActionQueueFiles) {
        Copy-ExportFile $fileSpec["source"] $fileSpec["destination"]
    }
}

$ownerPacketCount = [int]$handoffManifest.ownerPacketCount
$ownerPacketBlockingReasonCount = [int]$handoffManifest.ownerPacketBlockingReasonCount
$hostProjectActionItemCount = [int]$handoffManifest.hostProjectActionItemCount
$hostProjectBlockingReasonCount = [int]$handoffManifest.hostProjectBlockingReasonCount

$exportReadmeLines = @(
    "# AI TestPilot Production Handoff Export",
    "",
    "This export is the small handoff bundle for host-project owners. It does not promote fixture evidence as real production evidence.",
    "",
    "## Start Here",
    "",
    "1. Open `production-handoff-package\\owner-packets\\owner-packet-index.json`.",
    "2. Send each `production-handoff-package\\owner-packets\\*.md` packet to the listed owner.",
    "3. Production driver owners can run `production-driver-binding-kit\\Export-ProductionDriverEvidenceBundle.ps1` after production-bound readiness passes; it creates `production-driver-evidence-export\\production-driver-evidence` and `production-driver-evidence-export\\production-driver-evidence.zip`.",
    "4. Production Lua owners can run `production-lua-patch-evidence-kit\\Export-ProductionLuaPatchEvidenceBundle.ps1` after real Lua patch readiness passes; it creates `production-lua-evidence-export\\production-lua-evidence` and `production-lua-evidence-export\\production-lua-evidence.zip`.",
    "5. Live model owners can run `live-model-endpoint-config-kit\\Export-LiveModelEndpointSmokeEvidenceBundle.ps1` after direct live provider smoke passes; it creates `live-model-endpoint-smoke-evidence-export\\live-smoke-evidence` and `live-model-endpoint-smoke-evidence-export\\live-smoke-evidence.zip`.",
    "6. Owners copy returned evidence into `production-external-evidence-inbox\\production-driver-evidence`, `production-external-evidence-inbox\\production-lua-evidence`, and `production-external-evidence-inbox\\live-smoke-evidence`.",
    "7. Run Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1 with -OwnerResponseBundleDir or -OwnerResponseBundleZipPath before auto acceptance; confirm readyForAcceptanceCandidate=true, semanticPreflightStatus=READY_FOR_AUTO_ACCEPTANCE_CANDIDATE or WARN_READY_FOR_OPERATOR_ACCEPTANCE, and semanticFailCount=0.",
    "8. Run `production-external-evidence-inbox\\accept-returned-evidence.ps1` to generate the Markdown acceptance report.",
    "9. Run the hard validation command from the owner packet or `production-handoff-package\\ci-commands.ps1`."
)
if ($operatorActionQueueAvailable) {
    $exportReadmeLines += "10. Use `operator-actions\\production-external-evidence-action-queue.md` as the post-dispatch operator checklist for returned folder/zip semantic preflight and auto acceptance."
}
$exportReadmeLines += @(
    "",
    "## Contents",
    "",
    "- `production-handoff-package/`: owner packets, preflight script, acceptance wrapper, CI commands, and blocker maps.",
    "- `production-handoff-package/verify-external-evidence.ps1`: optional preflight for explicit evidence directories.",
    "- `production-handoff-package/accept-external-evidence.ps1`: optional wrapper for explicit evidence directories.",
    "- `production-external-evidence-inbox/`: returned-evidence directory layout and wrapper for accepting owner evidence.",
    "- `production-driver-binding-kit/`: host-project production replay driver binding kit, including `Export-ProductionDriverEvidenceBundle.ps1` for production-bound driver evidence folder/zip export.",
    "- `production-lua-patch-evidence-kit/`: host-project production Lua evidence template kit, including `Export-ProductionLuaPatchEvidenceBundle.ps1` for real Lua evidence folder/zip export.",
    "- `live-model-endpoint-config-kit/`: host-project live endpoint smoke configuration kit, including `Export-LiveModelEndpointSmokeEvidenceBundle.ps1` for direct live provider smoke evidence folder/zip export."
)
if ($ownerResponseBundleKitAvailable) {
    $exportReadmeLines += "- `production-handoff-owner-response-bundle-kit/`: fillable owner response bundle template with verifier, import helper, semantic preflight, and returned folder/zip auto-acceptance commands."
}
if ($operatorActionQueueAvailable) {
    $exportReadmeLines += "- `operator-actions/`: post-dispatch action queue, action-queue probe, and progress-mail snapshot for the remaining external evidence work."
}
if ($semanticPreflightProbeAvailable) {
    $exportReadmeLines += "- `contract-evidence/production-external-evidence-semantic-preflight-probe.md`: read-only semantic preflight probe for returned owner bundles before auto acceptance."
}
$exportReadmeLines += @(
    "- `contract-evidence/`: accepted-fixture and rejection reports proving the intake path without claiming real production evidence.",
    "- `contract-evidence/production-external-evidence-inbox-acceptance.md`: accepted returned-evidence inbox wrapper contract report.",
    "",
    "## Current External Work",
    "",
    "- Owner packets: $ownerPacketCount",
    "- Remaining blockers covered by owner packets: $ownerPacketBlockingReasonCount",
    "- Real host-project evidence accepted: False",
    "",
    "## Boundary",
    "",
    "- Fixture contracts prove schemas only.",
    "- This export is complete only when real host-project evidence is returned and the hard validation command passes."
)
$exportReadmePath = Join-Path $exportPath "README.md"
$exportReadmeLines | Set-Content -Path $exportReadmePath -Encoding UTF8

$manifestFileName = Split-Path $manifestFullPath -Leaf
$zipFileName = Split-Path $zipFullPath -Leaf
$manifestCopyRelativePath = "production-handoff-export\$manifestFileName"
$exportFiles = @(
    Get-ChildItem -LiteralPath $exportPath -Recurse -File |
        ForEach-Object { "production-handoff-export\" + (Convert-ToRelativePath $exportPath $_.FullName) }
)
$exportFiles = @($exportFiles + $manifestCopyRelativePath | Sort-Object -Unique)

$requiredExportSnippets = @(
    "AI TestPilot Production Handoff Export",
    "owner-packets",
    "verify-external-evidence.ps1",
    "accept-external-evidence.ps1",
    "production-driver-binding-kit",
    "Export-ProductionDriverEvidenceBundle.ps1",
    "production-driver-evidence.zip",
    "production-lua-patch-evidence-kit",
    "Export-ProductionLuaPatchEvidenceBundle.ps1",
    "production-lua-evidence.zip",
    "live-model-endpoint-config-kit",
    "Export-LiveModelEndpointSmokeEvidenceBundle.ps1",
    "live-smoke-evidence.zip",
    "production-external-evidence-inbox",
    "accept-returned-evidence.ps1",
    "Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1",
    "readyForAcceptanceCandidate=true",
    "semanticPreflightStatus=READY_FOR_AUTO_ACCEPTANCE_CANDIDATE",
    "WARN_READY_FOR_OPERATOR_ACCEPTANCE",
    "semanticFailCount=0",
    "before auto acceptance",
    "production-external-evidence-inbox-acceptance.md",
    "contract-evidence",
    "Real host-project evidence accepted: False"
)
if ($ownerResponseBundleKitAvailable) {
    $requiredExportSnippets += @(
        "production-handoff-owner-response-bundle-kit",
        "owner response bundle template",
        "semantic preflight",
        "readyForAcceptanceCandidate",
        "semanticPreflightStatus",
        "semanticFailCount",
        "auto-acceptance commands"
    )
}
if ($operatorActionQueueAvailable) {
    $requiredExportSnippets += @(
        "operator-actions",
        "production-external-evidence-action-queue.md",
        "post-dispatch operator checklist",
        "semantic preflight"
    )
}
if ($semanticPreflightProbeAvailable) {
    $requiredExportSnippets += "production-external-evidence-semantic-preflight-probe.md"
}
$exportReadmeText = Get-Content -Path $exportReadmePath -Encoding UTF8 -Raw
$missingExportSnippetCount = @($requiredExportSnippets | Where-Object { -not $exportReadmeText.Contains($_) }).Count

$requiredExportPaths = @(
    "production-handoff-export\README.md",
    "production-handoff-export\production-handoff-package\owner-packets\owner-packet-index.json",
    "production-handoff-export\production-handoff-package\verify-external-evidence.ps1",
    "production-handoff-export\production-handoff-package\accept-external-evidence.ps1",
    "production-handoff-export\production-driver-binding-kit\README.md",
    "production-handoff-export\production-driver-binding-kit\Export-ProductionDriverEvidenceBundle.ps1",
    "production-handoff-export\production-lua-patch-evidence-kit\README.md",
    "production-handoff-export\production-lua-patch-evidence-kit\Export-ProductionLuaPatchEvidenceBundle.ps1",
    "production-handoff-export\live-model-endpoint-config-kit\Export-LiveModelEndpointSmokeEvidenceBundle.ps1",
    "production-handoff-export\production-external-evidence-inbox\README.md",
    "production-handoff-export\production-external-evidence-inbox\accept-returned-evidence.ps1",
    "production-handoff-export\production-external-evidence-inbox\production-driver-evidence\README.md",
    "production-handoff-export\production-external-evidence-inbox\production-lua-evidence\README.md",
    "production-handoff-export\production-external-evidence-inbox\live-smoke-evidence\README.md",
    "production-handoff-export\live-model-endpoint-config-kit\README.md",
    "production-handoff-export\contract-evidence\production-external-evidence-acceptance-contract.md",
    "production-handoff-export\contract-evidence\production-external-evidence-acceptance-missing-all.md",
    "production-handoff-export\contract-evidence\production-external-evidence-acceptance-driver-only.md",
    "production-handoff-export\contract-evidence\production-external-evidence-inbox-acceptance.md"
)
if ($ownerResponseBundleKitAvailable) {
    $requiredExportPaths += @(
        "production-handoff-export\production-handoff-owner-response-bundle-kit\README.md",
        "production-handoff-export\production-handoff-owner-response-bundle-kit\owner-response-bundle-request-draft.md",
        "production-handoff-export\production-handoff-owner-response-bundle-kit\verify-owner-response-bundle.ps1",
        "production-handoff-export\production-handoff-owner-response-bundle-kit\import-owner-response-bundle.ps1",
        "production-handoff-export\production-handoff-owner-response-bundle-kit\owner-response-bundle-template\README.md",
        "production-handoff-export\contract-evidence\production-handoff-owner-response-bundle-kit-manifest.json",
        "production-handoff-export\contract-evidence\production-handoff-owner-response-bundle-kit.md",
        "production-handoff-export\contract-evidence\production-handoff-owner-response-bundle-kit-workflow-probe-manifest.json",
        "production-handoff-export\contract-evidence\production-handoff-owner-response-bundle-kit-workflow-probe.md"
    )
}
if ($operatorActionQueueAvailable) {
    $requiredExportPaths += @($operatorActionQueueFiles | ForEach-Object { "production-handoff-export\" + $_["destination"] })
}
$missingExportPathCount = @($requiredExportPaths | Where-Object { $exportFiles -notcontains $_ }).Count
$productionDriverEvidenceExportHelperRelativePath = "production-handoff-export\production-driver-binding-kit\Export-ProductionDriverEvidenceBundle.ps1"
$productionDriverEvidenceExportHelperIncluded = $exportFiles -contains $productionDriverEvidenceExportHelperRelativePath
$productionLuaEvidenceExportHelperRelativePath = "production-handoff-export\production-lua-patch-evidence-kit\Export-ProductionLuaPatchEvidenceBundle.ps1"
$productionLuaEvidenceExportHelperIncluded = $exportFiles -contains $productionLuaEvidenceExportHelperRelativePath
$liveModelSmokeEvidenceExportHelperRelativePath = "production-handoff-export\live-model-endpoint-config-kit\Export-LiveModelEndpointSmokeEvidenceBundle.ps1"
$liveModelSmokeEvidenceExportHelperIncluded = $exportFiles -contains $liveModelSmokeEvidenceExportHelperRelativePath

$ownerResponseBundleKitExportContentText = ""
if ($ownerResponseBundleKitAvailable) {
    $ownerResponseBundleKitReadmePath = Join-Path $exportPath "production-handoff-owner-response-bundle-kit\README.md"
    $ownerResponseBundleKitRequestDraftPath = Join-Path $exportPath "production-handoff-owner-response-bundle-kit\owner-response-bundle-request-draft.md"
    $ownerResponseBundleKitExportContentText = [string]::Join([Environment]::NewLine, @(
            if (Test-Path $ownerResponseBundleKitReadmePath) { Get-Content -Path $ownerResponseBundleKitReadmePath -Encoding UTF8 -Raw }
            if (Test-Path $ownerResponseBundleKitRequestDraftPath) { Get-Content -Path $ownerResponseBundleKitRequestDraftPath -Encoding UTF8 -Raw }
        ))
}
$ownerResponseBundleKitAutoAcceptanceCommandsDocumented = (
    $ownerResponseBundleKitAvailable -and
    [bool]$ownerResponseBundleKitManifest.autoAcceptanceCommandsContentValidated -and
    [bool]$ownerResponseBundleKitWorkflowProbeManifest.autoAcceptanceCommandsDocumented -and
    $ownerResponseBundleKitExportContentText.Contains("-OwnerResponseBundleDir") -and
    $ownerResponseBundleKitExportContentText.Contains("-OwnerResponseBundleZipPath") -and
    $ownerResponseBundleKitExportContentText.Contains("AITESTPILOT_OWNER_RESPONSE_BUNDLE_ZIP_PATH")
)
$ownerResponseBundleKitSemanticPreflightCommandsDocumented = (
    $ownerResponseBundleKitAvailable -and
    [bool](Get-ObjectProperty $ownerResponseBundleKitManifest "semanticPreflightCommandsContentValidated" $false) -and
    [bool](Get-ObjectProperty $ownerResponseBundleKitWorkflowProbeManifest "semanticPreflightCommandsDocumented" $false) -and
    [bool](Get-ObjectProperty $ownerResponseBundleKitWorkflowProbeManifest "verifyHelperSemanticNextStepDocumented" $false) -and
    $ownerResponseBundleKitExportContentText.Contains("Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1") -and
    $ownerResponseBundleKitExportContentText.Contains("-OwnerResponseBundleDir") -and
    $ownerResponseBundleKitExportContentText.Contains("-OwnerResponseBundleZipPath") -and
    $ownerResponseBundleKitExportContentText.Contains("readyForAcceptanceCandidate") -and
    $ownerResponseBundleKitExportContentText.Contains("semanticPreflightStatus") -and
    $ownerResponseBundleKitExportContentText.Contains("semanticFailCount")
)
$ownerResponseBundleKitExportContentValidated = (
    $ownerResponseBundleKitAutoAcceptanceCommandsDocumented -and
    $ownerResponseBundleKitSemanticPreflightCommandsDocumented -and
    $ownerResponseBundleKitExportContentText.Contains("Export-LiveModelEndpointSmokeEvidenceBundle.ps1")
)
$operatorActionQueueReportText = ""
$operatorActionQueueItemBundleCommandCount = 0
$operatorActionQueueItemSemanticPreflightCommandCount = 0
if ($operatorActionQueueAvailable) {
    $operatorActionQueueReportPath = Join-Path $exportPath "operator-actions\production-external-evidence-action-queue.md"
    if (Test-Path $operatorActionQueueReportPath) {
        $operatorActionQueueReportText = Get-Content -Path $operatorActionQueueReportPath -Encoding UTF8 -Raw
    }
    $operatorActionQueueItems = @(Get-ObjectProperty $operatorActionQueueManifest "actionQueue" @())
    $operatorActionQueueItemBundleCommandCount = @($operatorActionQueueItems | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string](Get-ObjectProperty $_ "ownerResponseBundleAreaPath" "")) -and
            ([string](Get-ObjectProperty $_ "ownerResponseBundleAreaPath" "")).Contains([string](Get-ObjectProperty $_ "inboxDirectory" "")) -and
            ([string](Get-ObjectProperty $_ "ownerResponseBundleRequiredFilesPath" "")).Contains("required-files.json") -and
            ([string](Get-ObjectProperty $_ "ownerResponseBundleAutoAcceptanceCommand" "")).Contains("-OwnerResponseBundleDir") -and
            ([string](Get-ObjectProperty $_ "ownerResponseBundleZipAutoAcceptanceCommand" "")).Contains("-OwnerResponseBundleZipPath") -and
            ([string](Get-ObjectProperty $_ "ownerResponseBundleZipEnvironmentVariable" "")) -eq "AITESTPILOT_OWNER_RESPONSE_BUNDLE_ZIP_PATH"
        }).Count
    $operatorActionQueueItemSemanticPreflightCommandCount = @($operatorActionQueueItems | Where-Object {
            ([string](Get-ObjectProperty $_ "ownerResponseBundleSemanticPreflightCommand" "")).Contains("Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1") -and
            ([string](Get-ObjectProperty $_ "ownerResponseBundleSemanticPreflightCommand" "")).Contains("-OwnerResponseBundleDir") -and
            ([string](Get-ObjectProperty $_ "ownerResponseBundleZipSemanticPreflightCommand" "")).Contains("Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1") -and
            ([string](Get-ObjectProperty $_ "ownerResponseBundleZipSemanticPreflightCommand" "")).Contains("-OwnerResponseBundleZipPath")
        }).Count
}
$productionDriverEvidenceExportHelperDocumented = (
    $productionDriverEvidenceExportHelperIncluded -and
    $exportReadmeText.Contains("Export-ProductionDriverEvidenceBundle.ps1") -and
    $exportReadmeText.Contains("production-driver-evidence.zip")
)
$productionLuaEvidenceExportHelperDocumented = (
    $productionLuaEvidenceExportHelperIncluded -and
    $exportReadmeText.Contains("Export-ProductionLuaPatchEvidenceBundle.ps1") -and
    $exportReadmeText.Contains("production-lua-evidence.zip")
)
$liveModelSmokeEvidenceExportHelperDocumented = (
    $liveModelSmokeEvidenceExportHelperIncluded -and
    $exportReadmeText.Contains("Export-LiveModelEndpointSmokeEvidenceBundle.ps1") -and
    $exportReadmeText.Contains("live-smoke-evidence.zip")
)
$operatorActionQueueExportContentValidated = (
    $operatorActionQueueAvailable -and
    $operatorActionQueueManifest.status -eq "PASS" -and
    $operatorActionQueueProbeManifest.status -eq "PASS" -and
    [int](Get-ObjectProperty $operatorActionQueueManifest "checkCount" 0) -eq 9 -and
    $operatorActionQueueItemBundleCommandCount -eq 3 -and
    $operatorActionQueueItemSemanticPreflightCommandCount -eq 3 -and
    $operatorActionQueueManifest.sourceKind -eq "post_dispatch_snapshot" -and
    [bool]$operatorActionQueueManifest.progressNotificationEmailSent -and
    [int]$operatorActionQueueManifest.localProgressMailRemainingActionCount -eq 0 -and
    [int]$operatorActionQueueManifest.externalRemainingWorkItemCount -eq 3 -and
    [int]$operatorActionQueueManifest.externalRemainingMissingFileCount -eq 9 -and
    [int]$operatorActionQueueManifest.externalRemainingBlockingReasonCount -eq 11 -and
    ([string]$operatorActionQueueManifest.ownerResponseBundleAutoAcceptanceCommand).Contains("-OwnerResponseBundleDir") -and
    ([string]$operatorActionQueueManifest.ownerResponseBundleZipAutoAcceptanceCommand).Contains("-OwnerResponseBundleZipPath") -and
    ([string](Get-ObjectProperty $operatorActionQueueManifest "ownerResponseBundleSemanticPreflightCommand" "")).Contains("-OwnerResponseBundleDir") -and
    ([string](Get-ObjectProperty $operatorActionQueueManifest "ownerResponseBundleZipSemanticPreflightCommand" "")).Contains("-OwnerResponseBundleZipPath") -and
    $operatorActionQueueManifest.ownerResponseBundleZipEnvironmentVariable -eq "AITESTPILOT_OWNER_RESPONSE_BUNDLE_ZIP_PATH" -and
    [int](Get-ObjectProperty $operatorActionQueueManifest "productionLuaEvidenceExportHelperItemCount" 0) -eq 1 -and
    ([string](Get-ObjectProperty $operatorActionQueueManifest "productionLuaEvidenceExportHelperCommand" "")).Contains("Export-ProductionLuaPatchEvidenceBundle.ps1") -and
    [int](Get-ObjectProperty $operatorActionQueueManifest "liveModelSmokeEvidenceExportHelperItemCount" 0) -eq 1 -and
    ([string](Get-ObjectProperty $operatorActionQueueManifest "liveModelSmokeEvidenceExportHelperCommand" "")).Contains("Export-LiveModelEndpointSmokeEvidenceBundle.ps1") -and
    $operatorActionQueueReportText.Contains("-OwnerResponseBundleZipPath") -and
    $operatorActionQueueReportText.Contains("Export-ProductionDriverEvidenceBundle.ps1") -and
    $operatorActionQueueReportText.Contains("Export-ProductionLuaPatchEvidenceBundle.ps1") -and
    $operatorActionQueueReportText.Contains("Export-LiveModelEndpointSmokeEvidenceBundle.ps1") -and
    $operatorActionQueueReportText.Contains("Owner response bundle zip semantic preflight") -and
    $operatorActionQueueReportText.Contains("Owner response bundle zip auto acceptance") -and
    $operatorActionQueueReportText.Contains("Bundle Area") -and
    $operatorActionQueueReportText.Contains("Bundle Semantic Preflight") -and
    $operatorActionQueueReportText.Contains("Bundle Acceptance")
)
$exportReadmeSemanticPreflightIndex = $exportReadmeText.IndexOf("Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1", [System.StringComparison]::OrdinalIgnoreCase)
$exportReadmeAutoAcceptanceIndex = $exportReadmeText.IndexOf("before auto acceptance", [System.StringComparison]::OrdinalIgnoreCase)
$semanticPreflightProbeIncluded = ($semanticPreflightProbeAvailable -and
    $exportFiles -contains "production-handoff-export\contract-evidence\production-external-evidence-semantic-preflight-probe-manifest.json" -and
    $exportFiles -contains "production-handoff-export\contract-evidence\production-external-evidence-semantic-preflight-probe.md")
$semanticPreflightProbeReadOnly = (
    (Get-ObjectProperty $semanticPreflightProbeManifest "status" "") -eq "PASS" -and
    (Get-ObjectProperty $semanticPreflightProbeManifest "schemaVersion" "") -eq "aitestpilot.production_external_evidence_semantic_preflight_probe.v1" -and
    [bool](Get-ObjectProperty $semanticPreflightProbeManifest "readOnly" $false) -and
    -not [bool](Get-ObjectProperty $semanticPreflightProbeManifest "acceptanceRun" $true) -and
    -not [bool](Get-ObjectProperty $semanticPreflightProbeManifest "hardValidationRun" $true) -and
    -not [bool](Get-ObjectProperty $semanticPreflightProbeManifest "realHostProjectEvidenceAccepted" $true) -and
    -not [bool](Get-ObjectProperty $semanticPreflightProbeManifest "fixtureEvidencePromoted" $true)
)
$semanticPreflightDocumentedBeforeAutoAcceptance = (
    $exportReadmeSemanticPreflightIndex -ge 0 -and
    $exportReadmeAutoAcceptanceIndex -gt $exportReadmeSemanticPreflightIndex -and
    $exportReadmeText.Contains("-OwnerResponseBundleDir") -and
    $exportReadmeText.Contains("-OwnerResponseBundleZipPath") -and
    $exportReadmeText.Contains("readyForAcceptanceCandidate=true") -and
    $exportReadmeText.Contains("semanticPreflightStatus=READY_FOR_AUTO_ACCEPTANCE_CANDIDATE") -and
    $exportReadmeText.Contains("WARN_READY_FOR_OPERATOR_ACCEPTANCE") -and
    $exportReadmeText.Contains("semanticFailCount=0")
)
$operatorActionQueueSemanticPreflightBeforeAutoAcceptanceDocumented = (
    $operatorActionQueueExportContentValidated -and
    $operatorActionQueueItemSemanticPreflightCommandCount -eq 3 -and
    $operatorActionQueueItemBundleCommandCount -eq 3
)
$semanticPreflightBeforeAutoAcceptanceCheckPassed = (
    $semanticPreflightDocumentedBeforeAutoAcceptance -and
    ((-not $semanticPreflightProbeAvailable) -or ($semanticPreflightProbeIncluded -and
            $semanticPreflightProbeReadOnly -and
            [bool](Get-ObjectProperty $semanticPreflightProbeManifest "ownerResponseBundleReady" $false) -and
            [bool](Get-ObjectProperty $semanticPreflightProbeManifest "partialBundleRejected" $false) -and
            [bool](Get-ObjectProperty $semanticPreflightProbeManifest "semanticBadBundleRejected" $false))) -and
    ((-not $ownerResponseBundleKitAvailable) -or ($ownerResponseBundleKitSemanticPreflightCommandsDocumented -and $ownerResponseBundleKitAutoAcceptanceCommandsDocumented)) -and
    ((-not $operatorActionQueueAvailable) -or $operatorActionQueueSemanticPreflightBeforeAutoAcceptanceDocumented)
)

$checks = @(
    [ordered]@{
        name = "handoff_package_source"
        passed = ($handoffManifest.status -eq "PASS" -and [bool]$handoffManifest.hostProjectHandoffReady -and [bool]$handoffManifest.ownerPacketsContentValidated)
        message = "Source handoff package must be PASS and include validated owner packets."
    },
    [ordered]@{
        name = "contract_boundary_preserved"
        passed = (-not [bool]$handoffManifest.fixtureEvidencePromoted -and -not [bool]$preflightProbeManifest.realHostProjectEvidenceAccepted -and -not [bool]$acceptanceContractProbeManifest.realHostProjectEvidenceAccepted -and -not [bool]$inboxContractProbeManifest.realHostProjectEvidenceAccepted)
        message = "Exported fixture contract evidence must not be promoted as real host-project evidence."
    },
    [ordered]@{
        name = "owner_packet_coverage"
        passed = ($ownerPacketCount -eq $hostProjectActionItemCount -and $ownerPacketBlockingReasonCount -eq $hostProjectBlockingReasonCount)
        message = "Owner packets must cover every remaining action item and blocker."
    },
    [ordered]@{
        name = "export_content"
        passed = ($missingExportSnippetCount -eq 0 -and $missingExportPathCount -eq 0)
        message = "Export must include README, owner packets, handoff scripts, kits, and contract reports."
    },
    [ordered]@{
        name = "production_driver_evidence_export_helper"
        passed = ($productionDriverEvidenceExportHelperIncluded -and $productionDriverEvidenceExportHelperDocumented)
        message = "Final export must include and document the production driver evidence export helper."
    },
    [ordered]@{
        name = "production_lua_evidence_export_helper"
        passed = ($productionLuaEvidenceExportHelperIncluded -and $productionLuaEvidenceExportHelperDocumented)
        message = "Final export must include and document the production Lua evidence export helper."
    },
    [ordered]@{
        name = "live_model_smoke_evidence_export_helper"
        passed = ($liveModelSmokeEvidenceExportHelperIncluded -and $liveModelSmokeEvidenceExportHelperDocumented)
        message = "Final export must include and document the live model smoke evidence export helper."
    },
    [ordered]@{
        name = "failure_contract_reports"
        passed = ($acceptanceFailureProbeManifest.status -eq "PASS" -and [bool]$acceptanceFailureProbeManifest.missingAllReportContentValidated -and [bool]$acceptanceFailureProbeManifest.driverOnlyReportContentValidated)
        message = "Export must include validated rejection reports for missing and partial evidence."
    },
    [ordered]@{
        name = "external_evidence_inbox"
        passed = ($missingExportPathCount -eq 0 -and $exportFiles -contains "production-handoff-export\production-external-evidence-inbox\accept-returned-evidence.ps1" -and $inboxContractProbeManifest.status -eq "PASS" -and [bool]$inboxContractProbeManifest.acceptedWrapperPassed)
        message = "Export must include the returned external evidence inbox, acceptance wrapper, and accepted inbox contract proof."
    },
    [ordered]@{
        name = "owner_response_bundle_kit_export"
        passed = ((-not $ownerResponseBundleKitAvailable) -or ($exportFiles -contains "production-handoff-export\production-handoff-owner-response-bundle-kit\README.md" -and $exportFiles -contains "production-handoff-export\production-handoff-owner-response-bundle-kit\owner-response-bundle-request-draft.md" -and $ownerResponseBundleKitManifest.status -eq "PASS" -and $ownerResponseBundleKitWorkflowProbeManifest.status -eq "PASS" -and $ownerResponseBundleKitExportContentValidated))
        message = "Final export must include the owner response bundle kit and its returned folder/zip semantic preflight plus auto-acceptance handoff text once the kit is available."
    },
    [ordered]@{
        name = "operator_action_queue_export"
        passed = ((-not $operatorActionQueueAvailable) -or ($exportFiles -contains "production-handoff-export\operator-actions\production-external-evidence-action-queue.md" -and $exportFiles -contains "production-handoff-export\operator-actions\production-external-evidence-action-queue-probe-manifest.json" -and $operatorActionQueueExportContentValidated))
        message = "Final export must include the post-dispatch operator action queue, source snapshot, probe proof, and returned folder/zip semantic preflight plus auto-acceptance commands once the action queue is available."
    },
    [ordered]@{
        name = "semantic_preflight_before_auto_acceptance_documented"
        passed = $semanticPreflightBeforeAutoAcceptanceCheckPassed
        message = "Final export must document read-only semantic preflight before returned bundle auto acceptance and include the semantic preflight probe evidence."
    }
)

$failedChecks = @($checks | Where-Object { -not [bool]$_["passed"] })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$files = @($manifestFileName, $zipFileName) + $exportFiles

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_export.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    exportDir = $exportPath
    zipPath = $zipFullPath
    handoffPackageIncluded = $true
    ownerPacketCount = [int]$ownerPacketCount
    ownerPacketBlockingReasonCount = [int]$ownerPacketBlockingReasonCount
    hostProjectActionItemCount = [int]$hostProjectActionItemCount
    hostProjectBlockingReasonCount = [int]$hostProjectBlockingReasonCount
    ownerPacketsContentValidated = [bool]$handoffManifest.ownerPacketsContentValidated
    kitDirectoryCount = [int]$requiredDirectories.Count
    ownerResponseBundleKitAvailable = [bool]$ownerResponseBundleKitAvailable
    ownerResponseBundleKitIncluded = [bool]$ownerResponseBundleKitAvailable
    ownerResponseBundleKitWorkflowProbeIncluded = [bool]$ownerResponseBundleKitAvailable
    ownerResponseBundleKitExportContentValidated = [bool]$ownerResponseBundleKitExportContentValidated
    ownerResponseBundleKitAutoAcceptanceCommandsDocumented = [bool]$ownerResponseBundleKitAutoAcceptanceCommandsDocumented
    ownerResponseBundleKitSemanticPreflightCommandsDocumented = [bool]$ownerResponseBundleKitSemanticPreflightCommandsDocumented
    ownerResponseBundleKitVerifyHelperSemanticNextStepDocumented = [bool](($ownerResponseBundleKitAvailable) -and (Get-ObjectProperty $ownerResponseBundleKitWorkflowProbeManifest "verifyHelperSemanticNextStepDocumented" $false))
    ownerResponseBundleKitSemanticPreflightCandidateField = $(if ($ownerResponseBundleKitAvailable) { [string](Get-ObjectProperty $ownerResponseBundleKitManifest "semanticPreflightCandidateField" "") } else { "" })
    ownerResponseBundleKitSemanticPreflightStatusField = $(if ($ownerResponseBundleKitAvailable) { [string](Get-ObjectProperty $ownerResponseBundleKitManifest "semanticPreflightStatusField" "") } else { "" })
    ownerResponseBundleKitSemanticPreflightFailCountField = $(if ($ownerResponseBundleKitAvailable) { [string](Get-ObjectProperty $ownerResponseBundleKitManifest "semanticPreflightFailCountField" "") } else { "" })
    semanticPreflightProbeAvailable = [bool]$semanticPreflightProbeAvailable
    semanticPreflightProbeIncluded = [bool]$semanticPreflightProbeIncluded
    semanticPreflightProbeReadOnly = [bool]$semanticPreflightProbeReadOnly
    semanticPreflightProbeAcceptanceRun = [bool](Get-ObjectProperty $semanticPreflightProbeManifest "acceptanceRun" $true)
    semanticPreflightProbeOwnerResponseBundleReady = [bool](Get-ObjectProperty $semanticPreflightProbeManifest "ownerResponseBundleReady" $false)
    semanticPreflightProbePartialBundleRejected = [bool](Get-ObjectProperty $semanticPreflightProbeManifest "partialBundleRejected" $false)
    semanticPreflightProbeSemanticBadBundleRejected = [bool](Get-ObjectProperty $semanticPreflightProbeManifest "semanticBadBundleRejected" $false)
    operatorActionQueueSemanticPreflightBeforeAutoAcceptanceDocumented = [bool]$operatorActionQueueSemanticPreflightBeforeAutoAcceptanceDocumented
    semanticPreflightDocumentedBeforeAutoAcceptance = [bool]$semanticPreflightDocumentedBeforeAutoAcceptance
    autoAcceptanceRequiresSemanticPreflightCandidate = [bool]$ownerResponseBundleKitSemanticPreflightCommandsDocumented
    semanticPreflightCandidateField = "readyForAcceptanceCandidate"
    semanticPreflightStatusField = "semanticPreflightStatus"
    semanticPreflightFailCountField = "semanticFailCount"
    operatorActionQueueAvailable = [bool]$operatorActionQueueAvailable
    operatorActionQueueIncluded = [bool]$operatorActionQueueAvailable
    operatorActionQueueSourceKind = $operatorActionQueueSourceKind
    operatorActionQueueProbeIncluded = [bool]$operatorActionQueueAvailable
    operatorActionQueuePostDispatchSnapshotIncluded = [bool]$operatorActionQueueAvailable
    operatorActionQueueContentValidated = [bool]$operatorActionQueueExportContentValidated
    operatorActionFileCount = $(if ($operatorActionQueueAvailable) { [int]@($operatorActionQueueFiles).Count } else { 0 })
    operatorActionQueueItemAutoAcceptanceCommandCount = [int]$operatorActionQueueItemBundleCommandCount
    operatorActionQueueItemSemanticPreflightCommandCount = [int]$operatorActionQueueItemSemanticPreflightCommandCount
    productionDriverEvidenceExportHelperIncluded = [bool]$productionDriverEvidenceExportHelperIncluded
    productionDriverEvidenceExportHelperDocumented = [bool]$productionDriverEvidenceExportHelperDocumented
    productionDriverEvidenceExportHelperPath = $productionDriverEvidenceExportHelperRelativePath
    productionLuaEvidenceExportHelperIncluded = [bool]$productionLuaEvidenceExportHelperIncluded
    productionLuaEvidenceExportHelperDocumented = [bool]$productionLuaEvidenceExportHelperDocumented
    productionLuaEvidenceExportHelperPath = $productionLuaEvidenceExportHelperRelativePath
    liveModelSmokeEvidenceExportHelperIncluded = [bool]$liveModelSmokeEvidenceExportHelperIncluded
    liveModelSmokeEvidenceExportHelperDocumented = [bool]$liveModelSmokeEvidenceExportHelperDocumented
    liveModelSmokeEvidenceExportHelperPath = $liveModelSmokeEvidenceExportHelperRelativePath
    operatorActionQueueTrackedRemainingWorkItemCount = $(if ($operatorActionQueueAvailable) { [int]$operatorActionQueueManifest.trackedRemainingWorkItemCount } else { 0 })
    operatorActionQueueExternalRemainingWorkItemCount = $(if ($operatorActionQueueAvailable) { [int]$operatorActionQueueManifest.externalRemainingWorkItemCount } else { 0 })
    operatorActionQueueExternalRemainingMissingFileCount = $(if ($operatorActionQueueAvailable) { [int]$operatorActionQueueManifest.externalRemainingMissingFileCount } else { 0 })
    operatorActionQueueExternalRemainingBlockingReasonCount = $(if ($operatorActionQueueAvailable) { [int]$operatorActionQueueManifest.externalRemainingBlockingReasonCount } else { 0 })
    externalEvidenceInboxIncluded = $true
    contractEvidenceFileCount = [int]$requiredFiles.Count
    exportFileCount = [int]$exportFiles.Count
    zipGenerated = $true
    releasePipelineUsesFixture = $false
    realHostProjectEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "host_project_external_handoff_export_only"
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
    files = @($files)
    exportFiles = @($exportFiles)
}

New-Item -ItemType Directory -Force (Split-Path $manifestFullPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestFullPath -Encoding UTF8
$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path (Join-Path $exportPath $manifestFileName) -Encoding UTF8

Compress-Archive -Path (Join-Path $exportPath "*") -DestinationPath $zipFullPath -Force
if (-not (Test-Path $zipFullPath)) {
    throw "Production handoff export zip was not produced: $zipFullPath"
}

if ($failedChecks.Count -gt 0) {
    throw "Production handoff export failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production handoff export: $exportPath"
Write-Output "Production handoff export zip: $zipFullPath"
Write-Output "Production handoff export manifest: $manifestFullPath"
Write-Output "PASS AI TestPilot production handoff export"
