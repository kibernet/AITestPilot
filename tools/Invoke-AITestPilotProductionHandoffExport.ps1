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

function Get-Sha256OrEmpty {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) {
        return ""
    }

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
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

function Get-DirectoryHashMap {
    param([string]$Root)

    $hashes = [ordered]@{}
    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path $Root)) {
        return $hashes
    }

    $rootPath = Resolve-FullPath $Root
    foreach ($file in @(Get-ChildItem -LiteralPath $rootPath -Recurse -File | Sort-Object FullName)) {
        $relativePath = Convert-ToRelativePath $rootPath $file.FullName
        $hashes[$relativePath] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }

    return $hashes
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$exportPath = Assert-PathUnderEvidenceBundle $ExportDir "ExportDir"
$manifestFullPath = Assert-PathUnderEvidenceBundle $ManifestPath "ManifestPath"
$zipFullPath = Assert-PathUnderEvidenceBundle $ZipPath "ZipPath"

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
    [ordered]@{ source = "release-progress-notification-outbox\remaining-work-snapshot.json"; destination = "operator-actions\release-progress-notification-remaining-work-snapshot.json" },
    [ordered]@{ source = "release-progress-notification-outbox\remaining-work-snapshot.md"; destination = "operator-actions\release-progress-notification-remaining-work-snapshot.md" }
)
$ownerReturnBundleStatusFileMap = @(
    [ordered]@{ source = "production-external-evidence-owner-return-bundle-status-manifest.json"; destination = "operator-actions\production-external-evidence-owner-return-bundle-status-manifest.json" },
    [ordered]@{ source = "production-external-evidence-owner-return-bundle-status.md"; destination = "operator-actions\production-external-evidence-owner-return-bundle-status.md" },
    [ordered]@{ source = "production-external-evidence-owner-return-bundle-status-probe-manifest.json"; destination = "operator-actions\production-external-evidence-owner-return-bundle-status-probe-manifest.json" },
    [ordered]@{ source = "production-external-evidence-owner-return-bundle-status-probe.md"; destination = "operator-actions\production-external-evidence-owner-return-bundle-status-probe.md" }
)
$ownerReturnStatusSourceFileMap = @(
    [ordered]@{ source = "production-handoff-status-manifest.json"; destination = "owner-return-status-source\production-handoff-status-manifest.json" },
    [ordered]@{ source = "production-external-evidence-inbox-manifest.json"; destination = "owner-return-status-source\production-external-evidence-inbox-manifest.json" },
    [ordered]@{ source = "production-handoff-owner-input-request-pack-manifest.json"; destination = "owner-return-status-source\production-handoff-owner-input-request-pack-manifest.json" },
    [ordered]@{ source = "production-handoff-owner-unblock-pack-manifest.json"; destination = "owner-return-status-source\production-handoff-owner-unblock-pack-manifest.json" },
    [ordered]@{ source = "production-handoff-owner-response-bundle-kit-manifest.json"; destination = "owner-return-status-source\production-handoff-owner-response-bundle-kit-manifest.json" },
    [ordered]@{ source = "production-external-evidence-action-queue-manifest.json"; destination = "owner-return-status-source\production-external-evidence-action-queue-manifest.json" }
)
$canonicalOperatorActionQueueAvailable = (@($canonicalOperatorActionQueueFileMap | Where-Object { -not (Test-Path (Join-Path $evidenceBundlePath $_["source"])) }).Count -eq 0)
$operatorActionQueueFiles = @()
$operatorActionQueueSourceKind = ""
if ($canonicalOperatorActionQueueAvailable) {
    $operatorActionQueueFiles = @($canonicalOperatorActionQueueFileMap)
    $operatorActionQueueSourceKind = "canonical_action_queue"
}
$operatorActionQueueAvailable = @($operatorActionQueueFiles).Count -gt 0
$operatorActionQueueManifest = $null
$operatorActionQueueProbeManifest = $null
if ($operatorActionQueueAvailable) {
    $operatorActionQueueManifestSpec = @($operatorActionQueueFiles | Where-Object {
            [string]$_["destination"] -eq "operator-actions\production-external-evidence-action-queue-manifest.json"
        } | Select-Object -First 1)
    $operatorActionQueueProbeManifestSpec = @($operatorActionQueueFiles | Where-Object {
            [string]$_["destination"] -eq "operator-actions\production-external-evidence-action-queue-probe-manifest.json"
        } | Select-Object -First 1)
    if ($operatorActionQueueManifestSpec.Count -eq 0 -or $operatorActionQueueProbeManifestSpec.Count -eq 0) {
        $operatorActionQueueAvailable = $false
        $operatorActionQueueFiles = @()
        $operatorActionQueueSourceKind = ""
    }
    else {
        $operatorActionQueueManifest = Read-JsonFile (Join-Path $evidenceBundlePath $operatorActionQueueManifestSpec[0]["source"]) "Production external evidence action queue manifest"
        $operatorActionQueueProbeManifest = Read-JsonFile (Join-Path $evidenceBundlePath $operatorActionQueueProbeManifestSpec[0]["source"]) "Production external evidence action queue probe manifest"
    }
    if ($operatorActionQueueAvailable -and ((Get-ObjectProperty $operatorActionQueueManifest "status" "") -ne "PASS" -or
            (Get-ObjectProperty $operatorActionQueueProbeManifest "status" "") -ne "PASS")) {
        $operatorActionQueueAvailable = $false
        $operatorActionQueueFiles = @()
        $operatorActionQueueSourceKind = ""
        $operatorActionQueueManifest = $null
        $operatorActionQueueProbeManifest = $null
    }
}

$ownerReturnBundleStatusAvailable = (@($ownerReturnBundleStatusFileMap | Where-Object { -not (Test-Path (Join-Path $evidenceBundlePath $_["source"])) }).Count -eq 0)
$ownerReturnBundleStatusFiles = @()
$ownerReturnBundleStatusManifest = $null
$ownerReturnBundleStatusProbeManifest = $null
if ($ownerReturnBundleStatusAvailable) {
    $ownerReturnBundleStatusManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-external-evidence-owner-return-bundle-status-manifest.json") "Production external evidence owner return status manifest"
    $ownerReturnBundleStatusProbeManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-external-evidence-owner-return-bundle-status-probe-manifest.json") "Production external evidence owner return status probe manifest"
    if ((Get-ObjectProperty $ownerReturnBundleStatusManifest "status" "") -eq "PASS" -and
        (Get-ObjectProperty $ownerReturnBundleStatusProbeManifest "status" "") -eq "PASS") {
        $ownerReturnBundleStatusFiles = @($ownerReturnBundleStatusFileMap)
    }
    else {
        $ownerReturnBundleStatusAvailable = $false
        $ownerReturnBundleStatusManifest = $null
        $ownerReturnBundleStatusProbeManifest = $null
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

if ($ownerReturnBundleStatusAvailable) {
    foreach ($fileSpec in $ownerReturnBundleStatusFiles) {
        Copy-ExportFile $fileSpec["source"] $fileSpec["destination"]
    }

    foreach ($fileSpec in $ownerReturnStatusSourceFileMap) {
        Copy-ExportFile $fileSpec["source"] $fileSpec["destination"]
    }
}

$semanticPreflightSelfContainedFolderCommand = '.\run-semantic-preflight.ps1 -OwnerResponseBundleDir "path\to\filled-owner-response-bundle"'
$semanticPreflightSelfContainedZipCommand = '.\run-semantic-preflight.ps1 -OwnerResponseBundleZipPath "path\to\filled-owner-response-bundle.zip"'
$ownerReturnStatusHelperRelativePath = "run-owner-return-status.ps1"
$ownerReturnStatusCoreRelativePath = "owner-return-status\Invoke-AITestPilotProductionExternalEvidenceOwnerReturnBundleStatus.ps1"
$ownerReturnStatusSemanticPreflightCoreRelativePath = "owner-return-status\Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1"
$ownerReturnStatusSourceRelativePath = "owner-return-status-source"
$ownerReturnStatusSelfContainedFolderCommand = '.\run-owner-return-status.ps1 -OwnerResponseBundleDir "path\to\filled-owner-response-bundle"'
$ownerReturnStatusSelfContainedZipCommand = '.\run-owner-return-status.ps1 -OwnerResponseBundleZipPath "path\to\filled-owner-response-bundle.zip"'
$ownerResponseBundleZipAutoAcceptanceExportCommand = '.\production-external-evidence-inbox\accept-returned-evidence.ps1 -RepoRoot "path\to\AITestPilot" -EvidenceBundleDir "path\to\AITestPilot\artifacts\ai-testpilot-release\latest" -OwnerResponseBundleZipPath "path\to\filled-owner-response-bundle.zip"'

if ($operatorActionQueueAvailable) {
    $operatorActionNextStepsPath = Join-Path $exportPath "operator-actions\NEXT-STEPS.md"
    $operatorActionNextStepsLines = @(
        "# AI TestPilot Operator Next Steps",
        "",
        "Use this short checklist before the full action queue. It does not send email, accept evidence, or promote fixtures.",
        "",
        "## Current State",
        "",
        "- External owner areas: $($operatorActionQueueManifest.externalRemainingWorkItemCount)",
        "- Missing files: $($operatorActionQueueManifest.externalRemainingMissingFileCount)",
        "- Blocking reasons: $($operatorActionQueueManifest.externalRemainingBlockingReasonCount)",
        "- Local progress-mail action still pending: $($operatorActionQueueManifest.localProgressMailRemainingActionCount)",
        "",
        "## Command Order",
        "",
        "1. Send the owner packet and collect a filled owner response bundle.",
        "2. Run owner-return status against the returned bundle directory or zip. If the status is NEEDS_OWNER_REPAIR, send the generated semantic preflight report back to the owner.",
        "3. Run semantic preflight against the returned bundle directory or zip.",
        "4. Run auto acceptance only after owner-return status and semantic preflight report a ready candidate with zero semantic failures.",
        "5. Run the owner area's hard validation command.",
        "",
        "## Routes",
        ""
    )

    foreach ($item in @(Get-ObjectProperty $operatorActionQueueManifest "actionQueue" @())) {
        $owner = [string](Get-ObjectProperty $item "owner" "")
        $area = [string](Get-ObjectProperty $item "area" "")
        $itemStatus = [string](Get-ObjectProperty $item "status" "")
        $contactStatus = [string](Get-ObjectProperty $item "contactStatus" "")
        $sendStatus = [string](Get-ObjectProperty $item "sendStatus" "")
        $ownerPacketPath = [string](Get-ObjectProperty $item "ownerPacketPath" "")
        $ownerResponseBundleAreaPath = [string](Get-ObjectProperty $item "ownerResponseBundleAreaPath" "")
        $missingFiles = @((Get-ObjectProperty $item "missingFiles" @()) | ForEach-Object { [string]$_ })
        $blockingReasons = @((Get-ObjectProperty $item "remainingBlockingReasons" @()) | ForEach-Object { [string]$_ })
        $ownerReturnStatusCommand = $ownerReturnStatusSelfContainedZipCommand
        $semanticPreflightCommand = $semanticPreflightSelfContainedZipCommand
        $autoAcceptanceCommand = $ownerResponseBundleZipAutoAcceptanceExportCommand
        $hardValidationCommand = [string](Get-ObjectProperty $item "hardValidationCommand" "")
        $operatorActionNextStepsLines += @(
            "### $owner / $area",
            "",
            "- Status: $itemStatus",
            "- Contact: $contactStatus",
            "- Send: $sendStatus",
            "- Missing files: $([string]::Join(", ", $missingFiles))",
            "- Blocking reasons: $([string]::Join(", ", $blockingReasons))",
            "- Owner packet: $ownerPacketPath",
            "- Bundle area: $ownerResponseBundleAreaPath",
            "",
            "Owner-return status:",
            "",
            '```powershell',
            $ownerReturnStatusCommand,
            '```',
            "",
            "Semantic preflight:",
            "",
            '```powershell',
            $semanticPreflightCommand,
            '```',
            "",
            "Auto acceptance after preflight:",
            "",
            '```powershell',
            $autoAcceptanceCommand,
            '```',
            "",
            "Hard validation:",
            "",
            '```powershell',
            $hardValidationCommand,
            '```',
            ""
        )

        foreach ($helperName in @("productionDriverEvidenceExportHelperCommand", "productionLuaEvidenceExportHelperCommand", "liveModelSmokeEvidenceExportHelperCommand")) {
            $helperCommand = [string](Get-ObjectProperty $item $helperName "")
            if (-not [string]::IsNullOrWhiteSpace($helperCommand)) {
                $operatorActionNextStepsLines += @(
                    "Owner export helper:",
                    "",
                    '```powershell',
                    $helperCommand,
                    '```',
                    ""
                )
            }
        }
    }

    $operatorActionNextStepsLines += @(
        "## Boundary",
        "",
        "- Release pipeline does not send email.",
        "- Real host-project evidence remains unaccepted until returned evidence passes semantic preflight, acceptance, and hard validation.",
        "- Fixture evidence remains unpromoted."
    )

    $operatorActionNextStepsLines | Set-Content -Path $operatorActionNextStepsPath -Encoding UTF8
}

$semanticPreflightHelperRelativePath = "run-semantic-preflight.ps1"
$semanticPreflightCoreRelativePath = "semantic-preflight\Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1"
$semanticPreflightSourcePath = Join-Path $repoRoot "tools\Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1"
$semanticPreflightHelperPath = Join-Path $exportPath $semanticPreflightHelperRelativePath
$semanticPreflightCorePath = Join-Path $exportPath $semanticPreflightCoreRelativePath
$semanticPreflightSelfContainedFolderCommand = '.\run-semantic-preflight.ps1 -OwnerResponseBundleDir "path\to\filled-owner-response-bundle"'
$semanticPreflightSelfContainedZipCommand = '.\run-semantic-preflight.ps1 -OwnerResponseBundleZipPath "path\to\filled-owner-response-bundle.zip"'

if (-not (Test-Path $semanticPreflightSourcePath)) {
    throw "Semantic preflight source script is missing: $semanticPreflightSourcePath"
}
New-Item -ItemType Directory -Force (Split-Path $semanticPreflightCorePath -Parent) | Out-Null
Copy-Item -LiteralPath $semanticPreflightSourcePath -Destination $semanticPreflightCorePath -Force

$semanticPreflightHelperScript = @'
[CmdletBinding()]
param(
    [string]$OwnerResponseBundleDir,
    [string]$OwnerResponseBundleZipPath,
    [string]$OutputDir = (Join-Path $PSScriptRoot "semantic-preflight-output"),
    [switch]$ContractFixtureMode,
    [switch]$AllowNonCandidate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not [string]::IsNullOrWhiteSpace($OwnerResponseBundleDir) -and
    -not [string]::IsNullOrWhiteSpace($OwnerResponseBundleZipPath)) {
    throw "Provide only one of -OwnerResponseBundleDir or -OwnerResponseBundleZipPath."
}

if ([string]::IsNullOrWhiteSpace($OwnerResponseBundleDir) -and
    [string]::IsNullOrWhiteSpace($OwnerResponseBundleZipPath) -and
    -not [string]::IsNullOrWhiteSpace($env:AITESTPILOT_OWNER_RESPONSE_BUNDLE_ZIP_PATH)) {
    $OwnerResponseBundleZipPath = $env:AITESTPILOT_OWNER_RESPONSE_BUNDLE_ZIP_PATH
}

if ([string]::IsNullOrWhiteSpace($OwnerResponseBundleDir) -and
    [string]::IsNullOrWhiteSpace($OwnerResponseBundleZipPath)) {
    throw "Provide -OwnerResponseBundleDir, -OwnerResponseBundleZipPath, or AITESTPILOT_OWNER_RESPONSE_BUNDLE_ZIP_PATH."
}

$preflightScript = Join-Path $PSScriptRoot "semantic-preflight\Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1"
if (-not (Test-Path $preflightScript)) {
    throw "Bundled semantic preflight script is missing: $preflightScript"
}

$outputPath = [System.IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Force $outputPath | Out-Null

$manifestPath = Join-Path $outputPath "production-external-evidence-semantic-preflight-manifest.json"
$reportPath = Join-Path $outputPath "production-external-evidence-semantic-preflight.md"
$preflightParams = @{
    EvidenceBundleDir = $outputPath
    ManifestPath = $manifestPath
    ReportPath = $reportPath
}
if (-not [string]::IsNullOrWhiteSpace($OwnerResponseBundleDir)) {
    $preflightParams["OwnerResponseBundleDir"] = $OwnerResponseBundleDir
}
if (-not [string]::IsNullOrWhiteSpace($OwnerResponseBundleZipPath)) {
    $preflightParams["OwnerResponseBundleZipPath"] = $OwnerResponseBundleZipPath
}
if ([bool]$ContractFixtureMode) {
    $preflightParams["ContractFixtureMode"] = $true
}

& $preflightScript @preflightParams | Out-Null

if (-not (Test-Path $manifestPath)) {
    throw "Semantic preflight manifest was not produced: $manifestPath"
}

$manifest = Get-Content -Path $manifestPath -Encoding UTF8 -Raw | ConvertFrom-Json
Write-Output "Semantic preflight manifest: $manifestPath"
Write-Output "Semantic preflight report: $reportPath"
Write-Output "Semantic preflight status: $($manifest.semanticPreflightStatus)"
Write-Output "Ready for acceptance candidate: $($manifest.readyForAcceptanceCandidate)"
Write-Output "Semantic FAIL count: $($manifest.semanticFailCount)"

if (-not [bool]$AllowNonCandidate -and
    (-not [bool]$manifest.readyForAcceptanceCandidate -or [int]$manifest.semanticFailCount -ne 0)) {
    throw "Semantic preflight did not produce an auto-acceptance candidate. Review $reportPath before running acceptance."
}

Write-Output "PASS AI TestPilot self-contained semantic preflight helper"
'@
$semanticPreflightHelperScript | Set-Content -Path $semanticPreflightHelperPath -Encoding UTF8

$ownerReturnStatusSourcePath = Join-Path $repoRoot "tools\Invoke-AITestPilotProductionExternalEvidenceOwnerReturnBundleStatus.ps1"
$ownerReturnStatusCorePath = Join-Path $exportPath $ownerReturnStatusCoreRelativePath
$ownerReturnStatusSemanticPreflightCorePath = Join-Path $exportPath $ownerReturnStatusSemanticPreflightCoreRelativePath
$ownerReturnStatusHelperPath = Join-Path $exportPath $ownerReturnStatusHelperRelativePath

if (-not (Test-Path $ownerReturnStatusSourcePath)) {
    throw "Owner-return status source script is missing: $ownerReturnStatusSourcePath"
}
New-Item -ItemType Directory -Force (Split-Path $ownerReturnStatusCorePath -Parent) | Out-Null
Copy-Item -LiteralPath $ownerReturnStatusSourcePath -Destination $ownerReturnStatusCorePath -Force
Copy-Item -LiteralPath $semanticPreflightSourcePath -Destination $ownerReturnStatusSemanticPreflightCorePath -Force

$ownerReturnStatusHelperScript = @'
[CmdletBinding()]
param(
    [string]$OwnerResponseBundleDir,
    [string]$OwnerResponseBundleZipPath,
    [string]$OutputDir = (Join-Path $PSScriptRoot "owner-return-status-output"),
    [switch]$ContractFixtureMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not [string]::IsNullOrWhiteSpace($OwnerResponseBundleDir) -and
    -not [string]::IsNullOrWhiteSpace($OwnerResponseBundleZipPath)) {
    throw "Provide only one of -OwnerResponseBundleDir or -OwnerResponseBundleZipPath."
}

if ([string]::IsNullOrWhiteSpace($OwnerResponseBundleDir) -and
    [string]::IsNullOrWhiteSpace($OwnerResponseBundleZipPath) -and
    -not [string]::IsNullOrWhiteSpace($env:AITESTPILOT_OWNER_RESPONSE_BUNDLE_ZIP_PATH)) {
    $OwnerResponseBundleZipPath = $env:AITESTPILOT_OWNER_RESPONSE_BUNDLE_ZIP_PATH
}

if ([string]::IsNullOrWhiteSpace($OwnerResponseBundleDir) -and
    [string]::IsNullOrWhiteSpace($OwnerResponseBundleZipPath) -and
    -not [string]::IsNullOrWhiteSpace($env:AITESTPILOT_OWNER_RESPONSE_BUNDLE_DIR)) {
    $OwnerResponseBundleDir = $env:AITESTPILOT_OWNER_RESPONSE_BUNDLE_DIR
}

function Copy-StatusSourceFile {
    param(
        [string]$FileName,
        [string]$SourceRoot,
        [string]$DestinationRoot
    )

    $sourcePath = Join-Path $SourceRoot $FileName
    if (-not (Test-Path $sourcePath)) {
        throw "Owner-return status source file is missing: $sourcePath"
    }

    $destinationPath = Join-Path $DestinationRoot $FileName
    New-Item -ItemType Directory -Force (Split-Path $destinationPath -Parent) | Out-Null
    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
}

$statusScript = Join-Path $PSScriptRoot "owner-return-status\Invoke-AITestPilotProductionExternalEvidenceOwnerReturnBundleStatus.ps1"
if (-not (Test-Path $statusScript)) {
    throw "Bundled owner-return status script is missing: $statusScript"
}

$sourceRoot = Join-Path $PSScriptRoot "owner-return-status-source"
if (-not (Test-Path $sourceRoot)) {
    throw "Bundled owner-return status source directory is missing: $sourceRoot"
}

$outputPath = [System.IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Force $outputPath | Out-Null

$requiredSourceFiles = @(
    "production-handoff-status-manifest.json",
    "production-external-evidence-inbox-manifest.json",
    "production-handoff-owner-input-request-pack-manifest.json",
    "production-handoff-owner-unblock-pack-manifest.json",
    "production-handoff-owner-response-bundle-kit-manifest.json",
    "production-external-evidence-action-queue-manifest.json"
)
foreach ($fileName in $requiredSourceFiles) {
    Copy-StatusSourceFile $fileName $sourceRoot $outputPath
}

$manifestPath = Join-Path $outputPath "production-external-evidence-owner-return-bundle-status-manifest.json"
$reportPath = Join-Path $outputPath "production-external-evidence-owner-return-bundle-status.md"
$statusParams = @{
    EvidenceBundleDir = $outputPath
    ManifestPath = $manifestPath
    ReportPath = $reportPath
}
if (-not [string]::IsNullOrWhiteSpace($OwnerResponseBundleDir)) {
    $statusParams["OwnerResponseBundleDir"] = $OwnerResponseBundleDir
}
if (-not [string]::IsNullOrWhiteSpace($OwnerResponseBundleZipPath)) {
    $statusParams["OwnerResponseBundleZipPath"] = $OwnerResponseBundleZipPath
}
if ([bool]$ContractFixtureMode) {
    $statusParams["ContractFixtureMode"] = $true
}

& $statusScript @statusParams | Out-Null

if (-not (Test-Path $manifestPath)) {
    throw "Owner-return status manifest was not produced: $manifestPath"
}

$manifest = Get-Content -Path $manifestPath -Encoding UTF8 -Raw | ConvertFrom-Json
Write-Output "Owner-return status manifest: $manifestPath"
Write-Output "Owner-return status report: $reportPath"
Write-Output "Owner-return readiness: $($manifest.ownerReturnReadinessStatus)"
Write-Output "Next required action: $($manifest.nextRequiredAction)"
Write-Output "Semantic preflight status: $($manifest.semanticPreflightStatus)"
Write-Output "Ready for acceptance candidate: $($manifest.readyForAcceptanceCandidate)"
Write-Output "Semantic FAIL count: $($manifest.semanticFailCount)"

if ($manifest.status -ne "PASS") {
    throw "Owner-return status failed. Review $reportPath."
}

Write-Output "PASS AI TestPilot self-contained owner-return status helper"
'@
$ownerReturnStatusHelperScript | Set-Content -Path $ownerReturnStatusHelperPath -Encoding UTF8

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
    '1. Open production-handoff-package\owner-packets\owner-packet-index.json.',
    '2. Send each production-handoff-package\owner-packets\*.md packet to the listed owner.',
    '3. Production driver owners can run production-driver-binding-kit\Export-ProductionDriverEvidenceBundle.ps1 after production-bound readiness passes; it creates production-driver-evidence-export\production-driver-evidence and production-driver-evidence-export\production-driver-evidence.zip.',
    '4. Production Lua owners can run production-lua-patch-evidence-kit\Export-ProductionLuaPatchEvidenceBundle.ps1 after real Lua patch readiness passes; it creates production-lua-evidence-export\production-lua-evidence and production-lua-evidence-export\production-lua-evidence.zip.',
    '5. Live model owners can run live-model-endpoint-config-kit\Export-LiveModelEndpointSmokeEvidenceBundle.ps1 after direct live provider smoke passes; it creates live-model-endpoint-smoke-evidence-export\live-smoke-evidence and live-model-endpoint-smoke-evidence-export\live-smoke-evidence.zip.',
    '6. Owners copy returned evidence into production-external-evidence-inbox\production-driver-evidence, production-external-evidence-inbox\production-lua-evidence, and production-external-evidence-inbox\live-smoke-evidence.',
    "7. Run the bundled self-contained owner-return status helper: $ownerReturnStatusSelfContainedFolderCommand or $ownerReturnStatusSelfContainedZipCommand as the first returned-bundle status check. Its manifest exposes ownerReturnReadinessStatus and nextRequiredAction, and NEEDS_OWNER_REPAIR means return the generated semantic preflight report to the owner.",
    "8. Run the bundled self-contained semantic preflight helper: $semanticPreflightSelfContainedFolderCommand or $semanticPreflightSelfContainedZipCommand before auto acceptance. It invokes semantic-preflight\Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1; confirm readyForAcceptanceCandidate=true, semanticPreflightStatus=READY_FOR_AUTO_ACCEPTANCE_CANDIDATE or WARN_READY_FOR_OPERATOR_ACCEPTANCE, and semanticFailCount=0. Zip inputs are checked for unsafe, duplicate, absolute, or traversal entries before extraction.",
    '9. Run production-external-evidence-inbox\accept-returned-evidence.ps1 to generate the Markdown acceptance report.',
    '10. Run the hard validation command from the owner packet or production-handoff-package\ci-commands.ps1.'
)
if ($operatorActionQueueAvailable) {
    $exportReadmeLines += '11. Start with operator-actions\NEXT-STEPS.md, then use operator-actions\production-external-evidence-owner-return-bundle-status.md and operator-actions\production-external-evidence-action-queue.md as the canonical detailed operator checklist for returned folder/zip status, semantic preflight, and auto acceptance. In CI it still includes the pending local progress-mail action; only a real accepted dispatch receipt may clear that local action.'
}
$exportReadmeLines += @(
    "",
    "## Contents",
    "",
    '- production-handoff-package/: owner packets, preflight script, acceptance wrapper, CI commands, and blocker maps.',
    '- production-handoff-package/verify-external-evidence.ps1: optional preflight for explicit evidence directories.',
    '- production-handoff-package/accept-external-evidence.ps1: optional wrapper for explicit evidence directories.',
    '- production-external-evidence-inbox/: returned-evidence directory layout and wrapper for accepting owner evidence.',
    '- run-owner-return-status.ps1: self-contained returned folder/zip owner-return status wrapper bundled with owner-return-status/Invoke-AITestPilotProductionExternalEvidenceOwnerReturnBundleStatus.ps1 and owner-return-status-source/.',
    '- run-semantic-preflight.ps1: self-contained returned folder/zip semantic preflight wrapper bundled with semantic-preflight/Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1.',
    '- production-driver-binding-kit/: host-project production replay driver binding kit, including Export-ProductionDriverEvidenceBundle.ps1 for production-bound driver evidence folder/zip export.',
    '- production-lua-patch-evidence-kit/: host-project production Lua evidence template kit, including Export-ProductionLuaPatchEvidenceBundle.ps1 for real Lua evidence folder/zip export.',
    '- live-model-endpoint-config-kit/: host-project live endpoint smoke configuration kit, including Export-LiveModelEndpointSmokeEvidenceBundle.ps1 for direct live provider smoke evidence folder/zip export.'
)
if ($ownerResponseBundleKitAvailable) {
    $exportReadmeLines += '- production-handoff-owner-response-bundle-kit/: fillable owner response bundle template with verifier, import helper, semantic preflight, and returned folder/zip auto-acceptance commands.'
}
if ($operatorActionQueueAvailable) {
    $exportReadmeLines += '- operator-actions/: short next-steps checklist, canonical owner-return status, action queue, remaining-work source snapshot, and probe proof for the remaining external evidence work.'
}
$exportReadmeLines += '- FIRST-TESTABLE.md: one-page operator-facing summary for the first testable handoff zip, including remaining external-owner work and the safe test command order.'
if ($semanticPreflightProbeAvailable) {
    $exportReadmeLines += '- contract-evidence/production-external-evidence-semantic-preflight-probe.md: read-only semantic preflight probe for returned owner bundle directories and zips before auto acceptance.'
}
$exportReadmeLines += @(
    '- contract-evidence/: accepted-fixture and rejection reports proving the intake path without claiming real production evidence.',
    '- contract-evidence/production-external-evidence-inbox-acceptance.md: accepted returned-evidence inbox wrapper contract report.',
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

$firstTestableSummaryRelativePath = "FIRST-TESTABLE.md"
$firstTestableSummaryPath = Join-Path $exportPath $firstTestableSummaryRelativePath
$firstTestableOwnerAreaCount = if ($operatorActionQueueAvailable) { [int](Get-ObjectProperty $operatorActionQueueManifest "externalRemainingWorkItemCount" 0) } else { [int]$hostProjectActionItemCount }
$firstTestableMissingFileCount = if ($operatorActionQueueAvailable) { [int](Get-ObjectProperty $operatorActionQueueManifest "externalRemainingMissingFileCount" 0) } else { 0 }
$firstTestableBlockingReasonCount = if ($operatorActionQueueAvailable) { [int](Get-ObjectProperty $operatorActionQueueManifest "externalRemainingBlockingReasonCount" 0) } else { [int]$hostProjectBlockingReasonCount }
$firstTestableLocalMailActionCount = if ($operatorActionQueueAvailable) { [int](Get-ObjectProperty $operatorActionQueueManifest "localProgressMailRemainingActionCount" 0) } else { 0 }
$firstTestableOwnerReturnReadiness = if ($ownerReturnBundleStatusAvailable) { [string](Get-ObjectProperty $ownerReturnBundleStatusManifest "ownerReturnReadinessStatus" "") } else { "PENDING_EXTERNAL_EVIDENCE" }
$firstTestableNextRequiredAction = if ($ownerReturnBundleStatusAvailable) { [string](Get-ObjectProperty $ownerReturnBundleStatusManifest "nextRequiredAction" "") } else { "collect_owner_response_bundle_zip" }
$firstTestableSummaryLines = @(
    "# AI TestPilot First Testable Handoff Summary",
    "",
    "This file is inside the handoff zip so an operator can identify the first testable package without relying on artifact-root reports.",
    "",
    "## Status",
    "",
    "- Ready for operator testing: True",
    "- Ready for commercial completion: False",
    "- Owner return readiness: $firstTestableOwnerReturnReadiness",
    "- Next required action: $firstTestableNextRequiredAction",
    "- External owner areas: $firstTestableOwnerAreaCount",
    "- Missing files: $firstTestableMissingFileCount",
    "- Blocking reasons: $firstTestableBlockingReasonCount",
    "- Local progress-mail action: $firstTestableLocalMailActionCount",
    "",
    "## Start Here",
    "",
    "1. Read operator-actions\NEXT-STEPS.md.",
    "2. Send the owner packets under production-handoff-package\owner-packets\.",
    "3. Collect a filled owner response bundle directory or zip.",
    "4. Run owner-return status, then semantic preflight.",
    "5. Run auto acceptance only after the returned bundle is a ready candidate with zero semantic failures.",
    "6. Run the matching hard validation command for the owner area.",
    "",
    "## Key Entry Points",
    "",
    "| Path | Purpose |",
    "| --- | --- |",
    "| README.md | Handoff package overview and boundaries. |",
    "| operator-actions\NEXT-STEPS.md | Short operator command order for all owner areas. |",
    "| operator-actions\production-external-evidence-owner-return-bundle-status.md | Read-only returned-bundle status before acceptance. |",
    "| operator-actions\production-external-evidence-action-queue.md | Canonical remaining external work and owner routes. |",
    "| production-handoff-owner-response-bundle-kit\README.md | Fillable owner response bundle workflow. |",
    "| run-owner-return-status.ps1 | Self-contained returned folder/zip owner-return status. |",
    "| run-semantic-preflight.ps1 | Self-contained returned folder/zip semantic preflight. |",
    "| production-external-evidence-inbox\accept-returned-evidence.ps1 | Acceptance wrapper after preflight passes. |",
    "",
    "## Boundary",
    "",
    "- This handoff zip does not send email.",
    "- It does not accept real host-project evidence by itself.",
    "- It does not promote fixture evidence.",
    "- Commercial completion still requires real external owner evidence and hard validation."
)

if ($operatorActionQueueAvailable) {
    $firstTestableSummaryLines += @(
        "",
        "## Owner Areas",
        "",
        "| Owner | Area | Status | Missing Files | Blockers |",
        "| --- | --- | --- | ---: | ---: |"
    )

    foreach ($item in @(Get-ObjectProperty $operatorActionQueueManifest "actionQueue" @())) {
        $owner = [string](Get-ObjectProperty $item "owner" "")
        $area = [string](Get-ObjectProperty $item "area" "")
        $itemStatus = [string](Get-ObjectProperty $item "status" "")
        $missingFileCount = [int](Get-ObjectProperty $item "missingFileCount" 0)
        $remainingBlockingReasonCount = [int](Get-ObjectProperty $item "remainingBlockingReasonCount" 0)
        $firstTestableSummaryLines += "| $owner | $area | $itemStatus | $missingFileCount | $remainingBlockingReasonCount |"
    }
}

$firstTestableSummaryLines | Set-Content -Path $firstTestableSummaryPath -Encoding UTF8

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
    "run-owner-return-status.ps1",
    "run-owner-return-status.ps1: self-contained returned folder/zip owner-return status wrapper",
    "owner-return-status-source",
    "run-semantic-preflight.ps1",
    "run-semantic-preflight.ps1: self-contained returned folder/zip semantic preflight wrapper",
    "semantic-preflight",
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
        "NEXT-STEPS.md",
        "production-external-evidence-action-queue.md",
        "short next-steps checklist",
        "canonical detailed operator checklist",
        "remaining-work source snapshot",
        "semantic preflight"
    )
}
if ($ownerReturnBundleStatusAvailable) {
    $requiredExportSnippets += @(
        "production-external-evidence-owner-return-bundle-status.md",
        "owner-return status",
        "run-owner-return-status.ps1",
        "self-contained returned folder/zip owner-return status wrapper",
        "ownerReturnReadinessStatus",
        "nextRequiredAction",
        "NEEDS_OWNER_REPAIR"
    )
}
if ($semanticPreflightProbeAvailable) {
    $requiredExportSnippets += "production-external-evidence-semantic-preflight-probe.md"
}
$exportReadmeText = Get-Content -Path $exportReadmePath -Encoding UTF8 -Raw
$missingExportSnippetCount = @($requiredExportSnippets | Where-Object { -not $exportReadmeText.Contains($_) }).Count

$requiredExportPaths = @(
    "production-handoff-export\README.md",
    "production-handoff-export\FIRST-TESTABLE.md",
    "production-handoff-export\run-owner-return-status.ps1",
    "production-handoff-export\owner-return-status\Invoke-AITestPilotProductionExternalEvidenceOwnerReturnBundleStatus.ps1",
    "production-handoff-export\owner-return-status\Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1",
    "production-handoff-export\run-semantic-preflight.ps1",
    "production-handoff-export\semantic-preflight\Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1",
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
        "production-handoff-export\production-handoff-owner-response-bundle-kit\merge-owner-mini-kits.ps1",
        "production-handoff-export\production-handoff-owner-response-bundle-kit\run-semantic-preflight.ps1",
        "production-handoff-export\production-handoff-owner-response-bundle-kit\semantic-preflight\Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1",
        "production-handoff-export\production-handoff-owner-response-bundle-kit\owner-response-bundle-template\README.md",
        "production-handoff-export\production-handoff-owner-response-bundle-kit\owner-response-mini-kits\README.md",
        "production-handoff-export\production-handoff-owner-response-bundle-kit\owner-response-mini-kits\host_project_gameplay_qa.zip",
        "production-handoff-export\production-handoff-owner-response-bundle-kit\owner-response-mini-kits\host_project_lua_owner.zip",
        "production-handoff-export\production-handoff-owner-response-bundle-kit\owner-response-mini-kits\host_project_ai_platform.zip",
        "production-handoff-export\contract-evidence\production-handoff-owner-response-bundle-kit-manifest.json",
        "production-handoff-export\contract-evidence\production-handoff-owner-response-bundle-kit.md",
        "production-handoff-export\contract-evidence\production-handoff-owner-response-bundle-kit-workflow-probe-manifest.json",
        "production-handoff-export\contract-evidence\production-handoff-owner-response-bundle-kit-workflow-probe.md"
    )
}
if ($operatorActionQueueAvailable) {
    $requiredExportPaths += @($operatorActionQueueFiles | ForEach-Object { "production-handoff-export\" + $_["destination"] })
    $requiredExportPaths += "production-handoff-export\operator-actions\NEXT-STEPS.md"
}
if ($ownerReturnBundleStatusAvailable) {
    $requiredExportPaths += @($ownerReturnBundleStatusFiles | ForEach-Object { "production-handoff-export\" + $_["destination"] })
    $requiredExportPaths += @($ownerReturnStatusSourceFileMap | ForEach-Object { "production-handoff-export\" + $_["destination"] })
}
$missingExportPathCount = @($requiredExportPaths | Where-Object { $exportFiles -notcontains $_ }).Count
$ownerResponseBundleKitSourceFileCount = 0
$ownerResponseBundleKitExportedFileCount = 0
$ownerResponseBundleKitMissingExportFileCount = 0
$ownerResponseBundleKitExtraExportFileCount = 0
$ownerResponseBundleKitHashMismatchCount = 0
$ownerResponseBundleKitHashMatchCount = 0
$ownerResponseBundleKitHashesMatchSource = $false
$ownerResponseBundleKitMissingExportFiles = @()
$ownerResponseBundleKitExtraExportFiles = @()
$ownerResponseBundleKitHashMismatchFiles = @()
$ownerResponseBundleKitFileHashes = @()
if ($ownerResponseBundleKitAvailable) {
    $ownerResponseBundleKitExportDirPath = Join-Path $exportPath "production-handoff-owner-response-bundle-kit"
    $ownerResponseBundleKitSourceHashes = Get-DirectoryHashMap $ownerResponseBundleKitDirPath
    $ownerResponseBundleKitExportHashes = Get-DirectoryHashMap $ownerResponseBundleKitExportDirPath
    $ownerResponseBundleKitSourceFiles = @($ownerResponseBundleKitSourceHashes.Keys | ForEach-Object { [string]$_ } | Sort-Object)
    $ownerResponseBundleKitExportedFiles = @($ownerResponseBundleKitExportHashes.Keys | ForEach-Object { [string]$_ } | Sort-Object)
    $ownerResponseBundleKitSourceFileCount = [int]$ownerResponseBundleKitSourceFiles.Count
    $ownerResponseBundleKitExportedFileCount = [int]$ownerResponseBundleKitExportedFiles.Count
    $ownerResponseBundleKitMissingExportFiles = @($ownerResponseBundleKitSourceFiles | Where-Object { $ownerResponseBundleKitExportedFiles -notcontains $_ })
    $ownerResponseBundleKitExtraExportFiles = @($ownerResponseBundleKitExportedFiles | Where-Object { $ownerResponseBundleKitSourceFiles -notcontains $_ })
    $ownerResponseBundleKitHashMismatchFiles = @($ownerResponseBundleKitSourceFiles | Where-Object {
            $ownerResponseBundleKitExportedFiles -contains $_ -and
            [string]$ownerResponseBundleKitSourceHashes[$_] -ne [string]$ownerResponseBundleKitExportHashes[$_]
        })
    $ownerResponseBundleKitHashFileSet = @($ownerResponseBundleKitSourceFiles + $ownerResponseBundleKitExportedFiles | Sort-Object -Unique)
    $ownerResponseBundleKitFileHashes = @($ownerResponseBundleKitHashFileSet | ForEach-Object {
            $relativePath = [string]$_
            $sourceExists = $ownerResponseBundleKitSourceFiles -contains $relativePath
            $exportExists = $ownerResponseBundleKitExportedFiles -contains $relativePath
            $sourceSha256 = if ($sourceExists) { [string]$ownerResponseBundleKitSourceHashes[$relativePath] } else { "" }
            $exportSha256 = if ($exportExists) { [string]$ownerResponseBundleKitExportHashes[$relativePath] } else { "" }
            [ordered]@{
                relativePath = $relativePath
                sourceRelativePath = "production-handoff-owner-response-bundle-kit\$relativePath"
                exportRelativePath = "production-handoff-export\production-handoff-owner-response-bundle-kit\$relativePath"
                sourceExists = [bool]$sourceExists
                exportExists = [bool]$exportExists
                sourceSha256 = $sourceSha256
                exportSha256 = $exportSha256
                hashMatches = [bool]($sourceExists -and $exportExists -and $sourceSha256 -eq $exportSha256)
            }
        })
    $ownerResponseBundleKitMissingExportFileCount = [int]$ownerResponseBundleKitMissingExportFiles.Count
    $ownerResponseBundleKitExtraExportFileCount = [int]$ownerResponseBundleKitExtraExportFiles.Count
    $ownerResponseBundleKitHashMismatchCount = [int]$ownerResponseBundleKitHashMismatchFiles.Count
    $ownerResponseBundleKitHashMatchCount = [int]($ownerResponseBundleKitSourceFileCount - $ownerResponseBundleKitMissingExportFileCount - $ownerResponseBundleKitHashMismatchCount)
    $ownerResponseBundleKitHashesMatchSource = (
        $ownerResponseBundleKitSourceFileCount -gt 0 -and
        $ownerResponseBundleKitSourceFileCount -eq $ownerResponseBundleKitExportedFileCount -and
        $ownerResponseBundleKitMissingExportFileCount -eq 0 -and
        $ownerResponseBundleKitExtraExportFileCount -eq 0 -and
        $ownerResponseBundleKitHashMismatchCount -eq 0
    )
}
$productionDriverEvidenceExportHelperRelativePath = "production-handoff-export\production-driver-binding-kit\Export-ProductionDriverEvidenceBundle.ps1"
$productionDriverEvidenceExportHelperIncluded = $exportFiles -contains $productionDriverEvidenceExportHelperRelativePath
$productionLuaEvidenceExportHelperRelativePath = "production-handoff-export\production-lua-patch-evidence-kit\Export-ProductionLuaPatchEvidenceBundle.ps1"
$productionLuaEvidenceExportHelperIncluded = $exportFiles -contains $productionLuaEvidenceExportHelperRelativePath
$liveModelSmokeEvidenceExportHelperRelativePath = "production-handoff-export\live-model-endpoint-config-kit\Export-LiveModelEndpointSmokeEvidenceBundle.ps1"
$liveModelSmokeEvidenceExportHelperIncluded = $exportFiles -contains $liveModelSmokeEvidenceExportHelperRelativePath
$semanticPreflightSelfContainedHelperRelativePath = "production-handoff-export\$semanticPreflightHelperRelativePath"
$semanticPreflightSelfContainedCoreRelativePath = "production-handoff-export\$semanticPreflightCoreRelativePath"
$semanticPreflightSelfContainedHelperIncluded = (
    $exportFiles -contains $semanticPreflightSelfContainedHelperRelativePath -and
    $exportFiles -contains $semanticPreflightSelfContainedCoreRelativePath
)
$semanticPreflightSelfContainedHelperText = if (Test-Path $semanticPreflightHelperPath) { Get-Content -Path $semanticPreflightHelperPath -Encoding UTF8 -Raw } else { "" }
$semanticPreflightSelfContainedCoreText = if (Test-Path $semanticPreflightCorePath) { Get-Content -Path $semanticPreflightCorePath -Encoding UTF8 -Raw } else { "" }
$ownerReturnStatusSelfContainedHelperRelativePath = "production-handoff-export\$ownerReturnStatusHelperRelativePath"
$ownerReturnStatusSelfContainedCoreRelativePath = "production-handoff-export\$ownerReturnStatusCoreRelativePath"
$ownerReturnStatusSelfContainedSemanticPreflightCoreRelativePath = "production-handoff-export\$ownerReturnStatusSemanticPreflightCoreRelativePath"
$ownerReturnStatusSelfContainedSourceRelativePaths = @($ownerReturnStatusSourceFileMap | ForEach-Object { "production-handoff-export\" + $_["destination"] })
$ownerReturnStatusSelfContainedSourceFileCount = [int]$ownerReturnStatusSelfContainedSourceRelativePaths.Count
$ownerReturnStatusSelfContainedMissingSourceFiles = @($ownerReturnStatusSelfContainedSourceRelativePaths | Where-Object { $exportFiles -notcontains $_ })
$ownerReturnStatusSelfContainedHelperIncluded = (
    $exportFiles -contains $ownerReturnStatusSelfContainedHelperRelativePath -and
    $exportFiles -contains $ownerReturnStatusSelfContainedCoreRelativePath -and
    $exportFiles -contains $ownerReturnStatusSelfContainedSemanticPreflightCoreRelativePath -and
    $ownerReturnStatusSelfContainedMissingSourceFiles.Count -eq 0
)
$ownerReturnStatusSelfContainedHelperText = if (Test-Path $ownerReturnStatusHelperPath) { Get-Content -Path $ownerReturnStatusHelperPath -Encoding UTF8 -Raw } else { "" }
$ownerReturnStatusSelfContainedCoreText = if (Test-Path $ownerReturnStatusCorePath) { Get-Content -Path $ownerReturnStatusCorePath -Encoding UTF8 -Raw } else { "" }
$ownerReturnStatusSelfContainedHelperDocumented = (
    $ownerReturnStatusSelfContainedHelperIncluded -and
    $exportReadmeText.Contains("run-owner-return-status.ps1") -and
    $exportReadmeText.Contains("owner-return-status-source") -and
    $exportReadmeText.Contains($ownerReturnStatusSelfContainedFolderCommand) -and
    $exportReadmeText.Contains($ownerReturnStatusSelfContainedZipCommand)
)
$ownerReturnStatusSelfContainedHelperContentValidated = (
    $ownerReturnStatusSelfContainedHelperIncluded -and
    $ownerReturnStatusSelfContainedHelperText.Contains("owner-return-status-source") -and
    $ownerReturnStatusSelfContainedHelperText.Contains("Invoke-AITestPilotProductionExternalEvidenceOwnerReturnBundleStatus.ps1") -and
    $ownerReturnStatusSelfContainedHelperText.Contains("production-handoff-status-manifest.json") -and
    $ownerReturnStatusSelfContainedHelperText.Contains("production-external-evidence-action-queue-manifest.json") -and
    $ownerReturnStatusSelfContainedHelperText.Contains("AITESTPILOT_OWNER_RESPONSE_BUNDLE_ZIP_PATH") -and
    $ownerReturnStatusSelfContainedHelperText.Contains("AITESTPILOT_OWNER_RESPONSE_BUNDLE_DIR") -and
    $ownerReturnStatusSelfContainedCoreText.Contains("aitestpilot.production_external_evidence_owner_return_bundle_status.v1")
)
$firstTestableSummaryExportRelativePath = "production-handoff-export\$firstTestableSummaryRelativePath"
$firstTestableSummaryIncluded = $exportFiles -contains $firstTestableSummaryExportRelativePath
$firstTestableSummaryText = if (Test-Path $firstTestableSummaryPath) { Get-Content -Path $firstTestableSummaryPath -Encoding UTF8 -Raw } else { "" }
$firstTestableSummaryContentValidated = (
    $firstTestableSummaryIncluded -and
    $firstTestableSummaryText.Contains("AI TestPilot First Testable Handoff Summary") -and
    $firstTestableSummaryText.Contains("Ready for operator testing: True") -and
    $firstTestableSummaryText.Contains("Ready for commercial completion: False") -and
    $firstTestableSummaryText.Contains("run-owner-return-status.ps1") -and
    $firstTestableSummaryText.Contains("run-semantic-preflight.ps1") -and
    $firstTestableSummaryText.Contains("fixture evidence") -and
    $firstTestableSummaryText.Contains("Commercial completion still requires real external owner evidence")
)
$firstTestableSummaryFinalBoundaryValidated = (
    $operatorActionQueueAvailable -and
    $firstTestableSummaryText.Contains("External owner areas: 3") -and
    $firstTestableSummaryText.Contains("Missing files: 9") -and
    $firstTestableSummaryText.Contains("Blocking reasons: 11") -and
    $firstTestableSummaryText.Contains("Local progress-mail action: 1")
)
$firstTestableSummaryCheckPassed = (
    $firstTestableSummaryContentValidated -and
    ((-not $operatorActionQueueAvailable) -or $firstTestableSummaryFinalBoundaryValidated)
)

$operatorActionQueueManifestRelativePath = "production-handoff-export\operator-actions\production-external-evidence-action-queue-manifest.json"
$operatorActionQueueReportRelativePath = "production-handoff-export\operator-actions\production-external-evidence-action-queue.md"
$operatorActionNextStepsRelativePath = "production-handoff-export\operator-actions\NEXT-STEPS.md"
$operatorActionQueueProbeManifestRelativePath = "production-handoff-export\operator-actions\production-external-evidence-action-queue-probe-manifest.json"
$operatorActionQueueRemainingWorkSnapshotRelativePath = "production-handoff-export\operator-actions\release-progress-notification-remaining-work-snapshot.json"
$operatorActionQueuePostDispatchSnapshotRelativePath = "production-handoff-export\operator-actions\release-progress-notification-post-dispatch-snapshot-manifest.json"
$operatorActionQueueManifestIncluded = $exportFiles -contains $operatorActionQueueManifestRelativePath
$operatorActionQueueReportIncluded = $exportFiles -contains $operatorActionQueueReportRelativePath
$operatorActionNextStepsIncluded = $exportFiles -contains $operatorActionNextStepsRelativePath
$operatorActionQueueProbeManifestIncluded = $exportFiles -contains $operatorActionQueueProbeManifestRelativePath
$operatorActionQueueRemainingWorkSnapshotIncluded = $exportFiles -contains $operatorActionQueueRemainingWorkSnapshotRelativePath
$operatorActionQueuePostDispatchSnapshotIncluded = $exportFiles -contains $operatorActionQueuePostDispatchSnapshotRelativePath
$operatorActionQueueSourceSnapshotIncluded = $operatorActionQueueSourceKind -eq "canonical_action_queue" -and $operatorActionQueueRemainingWorkSnapshotIncluded
$operatorActionQueueCanonicalSourcePath = Join-Path $evidenceBundlePath "production-external-evidence-action-queue-manifest.json"
$operatorActionQueueExportedPath = Join-Path $evidenceBundlePath $operatorActionQueueManifestRelativePath
$operatorActionQueueCanonicalSourceSha256 = Get-Sha256OrEmpty $operatorActionQueueCanonicalSourcePath
$operatorActionQueueExportedSha256 = Get-Sha256OrEmpty $operatorActionQueueExportedPath
$operatorActionQueueManifestHashMatchesCanonical = (
    $operatorActionQueueSourceKind -eq "canonical_action_queue" -and
    -not [string]::IsNullOrWhiteSpace($operatorActionQueueCanonicalSourceSha256) -and
    $operatorActionQueueCanonicalSourceSha256 -eq $operatorActionQueueExportedSha256
)
$ownerReturnBundleStatusManifestRelativePath = "production-handoff-export\operator-actions\production-external-evidence-owner-return-bundle-status-manifest.json"
$ownerReturnBundleStatusReportRelativePath = "production-handoff-export\operator-actions\production-external-evidence-owner-return-bundle-status.md"
$ownerReturnBundleStatusProbeManifestRelativePath = "production-handoff-export\operator-actions\production-external-evidence-owner-return-bundle-status-probe-manifest.json"
$ownerReturnBundleStatusProbeReportRelativePath = "production-handoff-export\operator-actions\production-external-evidence-owner-return-bundle-status-probe.md"
$ownerReturnBundleStatusManifestIncluded = $exportFiles -contains $ownerReturnBundleStatusManifestRelativePath
$ownerReturnBundleStatusReportIncluded = $exportFiles -contains $ownerReturnBundleStatusReportRelativePath
$ownerReturnBundleStatusProbeManifestIncluded = $exportFiles -contains $ownerReturnBundleStatusProbeManifestRelativePath
$ownerReturnBundleStatusProbeReportIncluded = $exportFiles -contains $ownerReturnBundleStatusProbeReportRelativePath
$ownerReturnBundleStatusCanonicalSourcePath = Join-Path $evidenceBundlePath "production-external-evidence-owner-return-bundle-status-manifest.json"
$ownerReturnBundleStatusExportedPath = Join-Path $evidenceBundlePath $ownerReturnBundleStatusManifestRelativePath
$ownerReturnBundleStatusCanonicalSourceSha256 = Get-Sha256OrEmpty $ownerReturnBundleStatusCanonicalSourcePath
$ownerReturnBundleStatusExportedSha256 = Get-Sha256OrEmpty $ownerReturnBundleStatusExportedPath
$ownerReturnBundleStatusManifestHashMatchesCanonical = (
    $ownerReturnBundleStatusAvailable -and
    -not [string]::IsNullOrWhiteSpace($ownerReturnBundleStatusCanonicalSourceSha256) -and
    $ownerReturnBundleStatusCanonicalSourceSha256 -eq $ownerReturnBundleStatusExportedSha256
)
$ownerReturnBundleStatusReportText = ""
if ($ownerReturnBundleStatusAvailable) {
    $ownerReturnBundleStatusReportPath = Join-Path $exportPath "operator-actions\production-external-evidence-owner-return-bundle-status.md"
    if (Test-Path $ownerReturnBundleStatusReportPath) {
        $ownerReturnBundleStatusReportText = Get-Content -Path $ownerReturnBundleStatusReportPath -Encoding UTF8 -Raw
    }
}
$ownerReturnBundleStatusReadinessStatus = if ($ownerReturnBundleStatusAvailable) { [string](Get-ObjectProperty $ownerReturnBundleStatusManifest "ownerReturnReadinessStatus" "") } else { "" }
$ownerReturnBundleStatusNextRequiredAction = if ($ownerReturnBundleStatusAvailable) { [string](Get-ObjectProperty $ownerReturnBundleStatusManifest "nextRequiredAction" "") } else { "" }
$ownerReturnBundleStatusSemanticPreflightRun = if ($ownerReturnBundleStatusAvailable) { [bool](Get-ObjectProperty $ownerReturnBundleStatusManifest "semanticPreflightRun" $true) } else { $true }
$ownerReturnBundleStatusReadyForAcceptanceCandidate = if ($ownerReturnBundleStatusAvailable) { [bool](Get-ObjectProperty $ownerReturnBundleStatusManifest "readyForAcceptanceCandidate" $true) } else { $true }
$ownerReturnBundleStatusPendingOwnerPacketCount = if ($ownerReturnBundleStatusAvailable) { [int](Get-ObjectProperty $ownerReturnBundleStatusManifest "pendingOwnerPacketCount" 0) } else { 0 }
$ownerReturnBundleStatusRemainingMissingFileCount = if ($ownerReturnBundleStatusAvailable) { [int](Get-ObjectProperty $ownerReturnBundleStatusManifest "remainingMissingFileCount" 0) } else { 0 }
$ownerReturnBundleStatusRemainingBlockingReasonCount = if ($ownerReturnBundleStatusAvailable) { [int](Get-ObjectProperty $ownerReturnBundleStatusManifest "remainingBlockingReasonCount" 0) } else { 0 }
$ownerReturnBundleStatusAcceptanceRun = if ($ownerReturnBundleStatusAvailable) { [bool](Get-ObjectProperty $ownerReturnBundleStatusManifest "acceptanceRun" $true) } else { $true }
$ownerReturnBundleStatusRealHostProjectEvidenceAccepted = if ($ownerReturnBundleStatusAvailable) { [bool](Get-ObjectProperty $ownerReturnBundleStatusManifest "realHostProjectEvidenceAccepted" $true) } else { $true }
$ownerReturnBundleStatusProbeCaseCount = if ($ownerReturnBundleStatusAvailable) { [int](Get-ObjectProperty $ownerReturnBundleStatusProbeManifest "caseCount" 0) } else { 0 }
$ownerReturnBundleStatusContentValidated = (
    $ownerReturnBundleStatusAvailable -and
    $ownerReturnBundleStatusManifestIncluded -and
    $ownerReturnBundleStatusReportIncluded -and
    $ownerReturnBundleStatusProbeManifestIncluded -and
    $ownerReturnBundleStatusProbeReportIncluded -and
    $ownerReturnBundleStatusManifestHashMatchesCanonical -and
    (Get-ObjectProperty $ownerReturnBundleStatusManifest "schemaVersion" "") -eq "aitestpilot.production_external_evidence_owner_return_bundle_status.v1" -and
    (Get-ObjectProperty $ownerReturnBundleStatusManifest "status" "") -eq "PASS" -and
    [bool](Get-ObjectProperty $ownerReturnBundleStatusManifest "readOnly" $false) -and
    $ownerReturnBundleStatusReadinessStatus -eq "PENDING_EXTERNAL_EVIDENCE" -and
    $ownerReturnBundleStatusNextRequiredAction -eq "collect_owner_response_bundle_zip" -and
    -not $ownerReturnBundleStatusSemanticPreflightRun -and
    -not $ownerReturnBundleStatusReadyForAcceptanceCandidate -and
    $ownerReturnBundleStatusPendingOwnerPacketCount -eq 3 -and
    $ownerReturnBundleStatusRemainingMissingFileCount -eq 9 -and
    $ownerReturnBundleStatusRemainingBlockingReasonCount -eq 11 -and
    -not $ownerReturnBundleStatusAcceptanceRun -and
    -not $ownerReturnBundleStatusRealHostProjectEvidenceAccepted -and
    (Get-ObjectProperty $ownerReturnBundleStatusManifest "ownerResponseBundleZipEnvironmentVariable" "") -eq "AITESTPILOT_OWNER_RESPONSE_BUNDLE_ZIP_PATH" -and
    (Get-ObjectProperty $ownerReturnBundleStatusManifest "ownerResponseBundleDirEnvironmentVariable" "") -eq "AITESTPILOT_OWNER_RESPONSE_BUNDLE_DIR" -and
    (Get-ObjectProperty $ownerReturnBundleStatusProbeManifest "schemaVersion" "") -eq "aitestpilot.production_external_evidence_owner_return_bundle_status_probe.v1" -and
    (Get-ObjectProperty $ownerReturnBundleStatusProbeManifest "status" "") -eq "PASS" -and
    [bool](Get-ObjectProperty $ownerReturnBundleStatusProbeManifest "readOnly" $false) -and
    -not [bool](Get-ObjectProperty $ownerReturnBundleStatusProbeManifest "acceptanceRun" $true) -and
    -not [bool](Get-ObjectProperty $ownerReturnBundleStatusProbeManifest "realHostProjectEvidenceAccepted" $true) -and
    [bool](Get-ObjectProperty $ownerReturnBundleStatusProbeManifest "envOwnerResponseBundleZipCandidateReady" $false) -and
    [bool](Get-ObjectProperty $ownerReturnBundleStatusProbeManifest "explicitOwnerResponseBundleZipOverridesEnvironment" $false) -and
    [bool](Get-ObjectProperty $ownerReturnBundleStatusProbeManifest "extraPayloadOwnerResponseBundleNeedsRepair" $false) -and
    $ownerReturnBundleStatusProbeCaseCount -eq 5 -and
    [int](Get-ObjectProperty $ownerReturnBundleStatusProbeManifest "checkCount" 0) -eq 8 -and
    $ownerReturnBundleStatusReportText.Contains("Production External Evidence Owner Return Bundle Status") -and
    $ownerReturnBundleStatusReportText.Contains("Owner return readiness") -and
    $ownerReturnBundleStatusReportText.Contains("Input source") -and
    $ownerReturnBundleStatusReportText.Contains("Dir env var")
)

$ownerResponseBundleKitExportContentText = ""
if ($ownerResponseBundleKitAvailable) {
    $ownerResponseBundleKitReadmePath = Join-Path $exportPath "production-handoff-owner-response-bundle-kit\README.md"
    $ownerResponseBundleKitRequestDraftPath = Join-Path $exportPath "production-handoff-owner-response-bundle-kit\owner-response-bundle-request-draft.md"
    $ownerResponseBundleKitMiniKitReadmePath = Join-Path $exportPath "production-handoff-owner-response-bundle-kit\owner-response-mini-kits\README.md"
    $ownerResponseBundleKitExportContentText = [string]::Join([Environment]::NewLine, @(
            if (Test-Path $ownerResponseBundleKitReadmePath) { Get-Content -Path $ownerResponseBundleKitReadmePath -Encoding UTF8 -Raw }
            if (Test-Path $ownerResponseBundleKitRequestDraftPath) { Get-Content -Path $ownerResponseBundleKitRequestDraftPath -Encoding UTF8 -Raw }
            if (Test-Path $ownerResponseBundleKitMiniKitReadmePath) { Get-Content -Path $ownerResponseBundleKitMiniKitReadmePath -Encoding UTF8 -Raw }
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
    [bool](Get-ObjectProperty $ownerResponseBundleKitManifest "selfContainedSemanticPreflightHelperGenerated" $false) -and
    [bool](Get-ObjectProperty $ownerResponseBundleKitWorkflowProbeManifest "semanticPreflightCommandsDocumented" $false) -and
    [bool](Get-ObjectProperty $ownerResponseBundleKitWorkflowProbeManifest "verifyHelperSemanticNextStepDocumented" $false) -and
    [bool](Get-ObjectProperty $ownerResponseBundleKitWorkflowProbeManifest "selfContainedSemanticPreflightHelperExecuted" $false) -and
    $ownerResponseBundleKitExportContentText.Contains("Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1") -and
    $ownerResponseBundleKitExportContentText.Contains("run-semantic-preflight.ps1") -and
    $ownerResponseBundleKitExportContentText.Contains("-OwnerResponseBundleDir") -and
    $ownerResponseBundleKitExportContentText.Contains("-OwnerResponseBundleZipPath") -and
    $ownerResponseBundleKitExportContentText.Contains("readyForAcceptanceCandidate") -and
    $ownerResponseBundleKitExportContentText.Contains("semanticPreflightStatus") -and
    $ownerResponseBundleKitExportContentText.Contains("semanticFailCount")
)
$ownerResponseBundleKitExportContentValidated = (
    $ownerResponseBundleKitAutoAcceptanceCommandsDocumented -and
    $ownerResponseBundleKitSemanticPreflightCommandsDocumented -and
    $ownerResponseBundleKitExportContentText.Contains("owner-response-mini-kits") -and
    $ownerResponseBundleKitExportContentText.Contains("merge-owner-mini-kits.ps1") -and
    $ownerResponseBundleKitExportContentText.Contains("Export-LiveModelEndpointSmokeEvidenceBundle.ps1")
)
$operatorActionQueueReportText = ""
$operatorActionNextStepsText = ""
$operatorActionQueueItemBundleCommandCount = 0
$operatorActionQueueItemSemanticPreflightCommandCount = 0
$operatorActionQueueItemStatusCommandCount = 0
if ($operatorActionQueueAvailable) {
    $operatorActionQueueReportPath = Join-Path $exportPath "operator-actions\production-external-evidence-action-queue.md"
    if (Test-Path $operatorActionQueueReportPath) {
        $operatorActionQueueReportText = Get-Content -Path $operatorActionQueueReportPath -Encoding UTF8 -Raw
    }
    $operatorActionNextStepsPath = Join-Path $exportPath "operator-actions\NEXT-STEPS.md"
    if (Test-Path $operatorActionNextStepsPath) {
        $operatorActionNextStepsText = Get-Content -Path $operatorActionNextStepsPath -Encoding UTF8 -Raw
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
    $operatorActionQueueItemStatusCommandCount = @($operatorActionQueueItems | Where-Object {
            ([string](Get-ObjectProperty $_ "ownerResponseBundleStatusCommand" "")).Contains("Invoke-AITestPilotProductionExternalEvidenceOwnerReturnBundleStatus.ps1") -and
            ([string](Get-ObjectProperty $_ "ownerResponseBundleStatusCommand" "")).Contains("-OwnerResponseBundleDir") -and
            ([string](Get-ObjectProperty $_ "ownerResponseBundleZipStatusCommand" "")).Contains("Invoke-AITestPilotProductionExternalEvidenceOwnerReturnBundleStatus.ps1") -and
            ([string](Get-ObjectProperty $_ "ownerResponseBundleZipStatusCommand" "")).Contains("-OwnerResponseBundleZipPath") -and
            ([string](Get-ObjectProperty $_ "ownerResponseBundleDirEnvironmentVariable" "")) -eq "AITESTPILOT_OWNER_RESPONSE_BUNDLE_DIR"
        }).Count
}
$operatorActionNextStepsContentValidated = (
    $operatorActionQueueAvailable -and
    $operatorActionNextStepsIncluded -and
    $operatorActionNextStepsText.Contains("AI TestPilot Operator Next Steps") -and
    $operatorActionNextStepsText.Contains("External owner areas: 3") -and
    $operatorActionNextStepsText.Contains("Missing files: 9") -and
    $operatorActionNextStepsText.Contains("Blocking reasons: 11") -and
    $operatorActionNextStepsText.Contains("Local progress-mail action still pending: 1") -and
    $operatorActionNextStepsText.Contains("host_project_gameplay_qa") -and
    $operatorActionNextStepsText.Contains("host_project_lua_owner") -and
    $operatorActionNextStepsText.Contains("host_project_ai_platform") -and
    $operatorActionNextStepsText.Contains("-OwnerResponseBundleZipPath") -and
    $operatorActionNextStepsText.Contains("Owner-return status") -and
    $operatorActionNextStepsText.Contains("run-owner-return-status.ps1") -and
    $operatorActionNextStepsText.Contains("NEEDS_OWNER_REPAIR") -and
    $operatorActionNextStepsText.Contains("owner-return status and semantic preflight") -and
    $operatorActionNextStepsText.Contains("run-semantic-preflight.ps1") -and
    $operatorActionNextStepsText.Contains("accept-returned-evidence.ps1") -and
    $operatorActionNextStepsText.Contains("Invoke-AITestPilotReleasePipeline.ps1") -and
    $operatorActionNextStepsText.Contains("Fixture evidence remains unpromoted") -and
    -not $operatorActionNextStepsText.Contains("System.Collections") -and
    -not $operatorActionNextStepsText.Contains("@{")
)
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
$semanticPreflightSelfContainedHelperDocumented = (
    $semanticPreflightSelfContainedHelperIncluded -and
    $exportReadmeText.Contains("run-semantic-preflight.ps1") -and
    $exportReadmeText.Contains("semantic-preflight") -and
    $exportReadmeText.Contains("Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1") -and
    $exportReadmeText.Contains($semanticPreflightSelfContainedFolderCommand) -and
    $exportReadmeText.Contains($semanticPreflightSelfContainedZipCommand)
)
$semanticPreflightSelfContainedHelperContentValidated = (
    $semanticPreflightSelfContainedHelperIncluded -and
    $semanticPreflightSelfContainedHelperText.Contains("semantic-preflight\Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1") -and
    $semanticPreflightSelfContainedHelperText.Contains("OwnerResponseBundleDir") -and
    $semanticPreflightSelfContainedHelperText.Contains("OwnerResponseBundleZipPath") -and
    $semanticPreflightSelfContainedHelperText.Contains("readyForAcceptanceCandidate") -and
    $semanticPreflightSelfContainedHelperText.Contains("AITESTPILOT_OWNER_RESPONSE_BUNDLE_ZIP_PATH") -and
    $semanticPreflightSelfContainedCoreText.Contains("aitestpilot.production_external_evidence_semantic_preflight.v1")
)
$operatorActionQueueExportContentValidated = (
    $operatorActionQueueAvailable -and
    $operatorActionQueueManifest.status -eq "PASS" -and
    $operatorActionQueueProbeManifest.status -eq "PASS" -and
    [int](Get-ObjectProperty $operatorActionQueueManifest "checkCount" 0) -eq 10 -and
    $operatorActionQueueItemBundleCommandCount -eq 3 -and
    $operatorActionQueueItemSemanticPreflightCommandCount -eq 3 -and
    $operatorActionQueueItemStatusCommandCount -eq 3 -and
    $operatorActionQueueManifestIncluded -and
    $operatorActionQueueReportIncluded -and
    $operatorActionNextStepsIncluded -and
    $operatorActionQueueProbeManifestIncluded -and
    $operatorActionQueueSourceSnapshotIncluded -and
    $operatorActionQueueManifestHashMatchesCanonical -and
    $operatorActionQueueSourceKind -eq "canonical_action_queue" -and
    $operatorActionQueueManifest.sourceKind -eq "remaining_work_snapshot" -and
    -not [bool]$operatorActionQueueManifest.progressNotificationEmailSent -and
    [int]$operatorActionQueueManifest.localProgressMailRemainingActionCount -eq 1 -and
    [int]$operatorActionQueueManifest.trackedRemainingWorkItemCount -eq 4 -and
    [int]$operatorActionQueueManifest.externalRemainingWorkItemCount -eq 3 -and
    [int]$operatorActionQueueManifest.externalRemainingMissingFileCount -eq 9 -and
    [int]$operatorActionQueueManifest.externalRemainingBlockingReasonCount -eq 11 -and
    ([string]$operatorActionQueueManifest.ownerResponseBundleAutoAcceptanceCommand).Contains("-OwnerResponseBundleDir") -and
    ([string]$operatorActionQueueManifest.ownerResponseBundleZipAutoAcceptanceCommand).Contains("-OwnerResponseBundleZipPath") -and
    ([string](Get-ObjectProperty $operatorActionQueueManifest "ownerResponseBundleSemanticPreflightCommand" "")).Contains("-OwnerResponseBundleDir") -and
    ([string](Get-ObjectProperty $operatorActionQueueManifest "ownerResponseBundleZipSemanticPreflightCommand" "")).Contains("-OwnerResponseBundleZipPath") -and
    ([string](Get-ObjectProperty $operatorActionQueueManifest "ownerResponseBundleStatusCommand" "")).Contains("Invoke-AITestPilotProductionExternalEvidenceOwnerReturnBundleStatus.ps1") -and
    ([string](Get-ObjectProperty $operatorActionQueueManifest "ownerResponseBundleStatusCommand" "")).Contains("-OwnerResponseBundleDir") -and
    ([string](Get-ObjectProperty $operatorActionQueueManifest "ownerResponseBundleZipStatusCommand" "")).Contains("Invoke-AITestPilotProductionExternalEvidenceOwnerReturnBundleStatus.ps1") -and
    ([string](Get-ObjectProperty $operatorActionQueueManifest "ownerResponseBundleZipStatusCommand" "")).Contains("-OwnerResponseBundleZipPath") -and
    $operatorActionQueueManifest.ownerResponseBundleZipEnvironmentVariable -eq "AITESTPILOT_OWNER_RESPONSE_BUNDLE_ZIP_PATH" -and
    (Get-ObjectProperty $operatorActionQueueManifest "ownerResponseBundleDirEnvironmentVariable" "") -eq "AITESTPILOT_OWNER_RESPONSE_BUNDLE_DIR" -and
    [int](Get-ObjectProperty $operatorActionQueueManifest "productionLuaEvidenceExportHelperItemCount" 0) -eq 1 -and
    ([string](Get-ObjectProperty $operatorActionQueueManifest "productionLuaEvidenceExportHelperCommand" "")).Contains("Export-ProductionLuaPatchEvidenceBundle.ps1") -and
    [int](Get-ObjectProperty $operatorActionQueueManifest "liveModelSmokeEvidenceExportHelperItemCount" 0) -eq 1 -and
    ([string](Get-ObjectProperty $operatorActionQueueManifest "liveModelSmokeEvidenceExportHelperCommand" "")).Contains("Export-LiveModelEndpointSmokeEvidenceBundle.ps1") -and
    $operatorActionQueueReportText.Contains("-OwnerResponseBundleZipPath") -and
    $operatorActionQueueReportText.Contains("Export-ProductionDriverEvidenceBundle.ps1") -and
    $operatorActionQueueReportText.Contains("Export-ProductionLuaPatchEvidenceBundle.ps1") -and
    $operatorActionQueueReportText.Contains("Export-LiveModelEndpointSmokeEvidenceBundle.ps1") -and
    $operatorActionQueueReportText.Contains("Owner response bundle status") -and
    $operatorActionQueueReportText.Contains("Owner response bundle zip status") -and
    $operatorActionQueueReportText.Contains("Owner response bundle zip semantic preflight") -and
    $operatorActionQueueReportText.Contains("Owner response bundle zip auto acceptance") -and
    $operatorActionQueueReportText.Contains("Bundle Area") -and
    $operatorActionQueueReportText.Contains("Bundle Status") -and
    $operatorActionQueueReportText.Contains("Bundle Semantic Preflight") -and
    $operatorActionQueueReportText.Contains("Bundle Acceptance") -and
    $operatorActionNextStepsContentValidated
)
$exportReadmeSemanticPreflightIndex = $exportReadmeText.IndexOf("run-semantic-preflight.ps1", [System.StringComparison]::OrdinalIgnoreCase)
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
    $exportReadmeText.Contains("unsafe, duplicate, absolute, or traversal entries") -and
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
    $semanticPreflightSelfContainedHelperDocumented -and
    $semanticPreflightSelfContainedHelperContentValidated -and
    ((-not $semanticPreflightProbeAvailable) -or ($semanticPreflightProbeIncluded -and
            $semanticPreflightProbeReadOnly -and
            [bool](Get-ObjectProperty $semanticPreflightProbeManifest "ownerResponseBundleReady" $false) -and
            [bool](Get-ObjectProperty $semanticPreflightProbeManifest "ownerResponseBundleZipReady" $false) -and
            [bool](Get-ObjectProperty $semanticPreflightProbeManifest "ownerResponseBundleZipArbitraryWrapperReady" $false) -and
            [bool](Get-ObjectProperty $semanticPreflightProbeManifest "unsafeOwnerResponseBundleZipRejected" $false) -and
            [bool](Get-ObjectProperty $semanticPreflightProbeManifest "partialBundleRejected" $false) -and
            [bool](Get-ObjectProperty $semanticPreflightProbeManifest "partialBundleZipRejected" $false) -and
            [bool](Get-ObjectProperty $semanticPreflightProbeManifest "semanticBadBundleRejected" $false) -and
            [bool](Get-ObjectProperty $semanticPreflightProbeManifest "semanticBadBundleZipRejected" $false) -and
            [bool](Get-ObjectProperty $semanticPreflightProbeManifest "extraPayloadBundleRejected" $false) -and
            [bool](Get-ObjectProperty $semanticPreflightProbeManifest "nestedPayloadBundleZipRejected" $false) -and
            [int](Get-ObjectProperty $semanticPreflightProbeManifest "ownerResponseBundleZipCaseCount" 0) -eq 6 -and
            [int](Get-ObjectProperty $semanticPreflightProbeManifest "ownerResponseBundleZipSafeCaseCount" 0) -eq 5 -and
            [int](Get-ObjectProperty $semanticPreflightProbeManifest "ownerResponseBundleZipUnsafeCaseCount" 0) -eq 1 -and
            [int](Get-ObjectProperty $semanticPreflightProbeManifest "payloadShapeRejectedCaseCount" 0) -eq 2)) -and
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
        name = "semantic_preflight_self_contained_helper"
        passed = ($semanticPreflightSelfContainedHelperIncluded -and $semanticPreflightSelfContainedHelperDocumented -and $semanticPreflightSelfContainedHelperContentValidated)
        message = "Final export must include a self-contained returned folder/zip semantic preflight helper and bundled core script."
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
        name = "owner_response_bundle_kit_export_hashes"
        passed = ((-not $ownerResponseBundleKitAvailable) -or $ownerResponseBundleKitHashesMatchSource)
        message = "Final export must prove the copied owner response bundle kit exactly matches the source kit file set and SHA256 hashes."
    },
    [ordered]@{
        name = "operator_action_queue_export"
        passed = ((-not $operatorActionQueueAvailable) -or ($operatorActionQueueManifestIncluded -and $operatorActionQueueReportIncluded -and $operatorActionQueueProbeManifestIncluded -and $operatorActionQueueSourceSnapshotIncluded -and $operatorActionQueueManifestHashMatchesCanonical -and $operatorActionQueueExportContentValidated))
        message = "Final export must include the canonical operator action queue, matching root manifest hash, source snapshot, probe proof, and returned folder/zip semantic preflight plus auto-acceptance commands once the action queue is available."
    },
    [ordered]@{
        name = "operator_action_next_steps_export"
        passed = ((-not $operatorActionQueueAvailable) -or $operatorActionNextStepsContentValidated)
        message = "Final export must include a short operator NEXT-STEPS checklist covering all three owner routes, semantic preflight, auto acceptance, hard validation, and evidence boundaries."
    },
    [ordered]@{
        name = "owner_return_status_export"
        passed = ((-not $ownerReturnBundleStatusAvailable) -or $ownerReturnBundleStatusContentValidated)
        message = "Final export must include the canonical owner-return bundle status report, probe proof, hash-matched manifest, and read-only pending external evidence boundary."
    },
    [ordered]@{
        name = "owner_return_status_self_contained_helper"
        passed = ((-not $ownerReturnBundleStatusAvailable) -or ($ownerReturnStatusSelfContainedHelperDocumented -and $ownerReturnStatusSelfContainedHelperContentValidated))
        message = "Final export must include a self-contained owner-return status helper, bundled core scripts, and the source manifests needed for returned folder/zip status checks."
    },
    [ordered]@{
        name = "first_testable_handoff_summary"
        passed = $firstTestableSummaryCheckPassed
        message = "Final export must include a zip-root FIRST-TESTABLE.md summary with operator-testing readiness and the remaining external evidence boundary."
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
    ownerResponseBundleKitHashesMatchSource = [bool]$ownerResponseBundleKitHashesMatchSource
    ownerResponseBundleKitSourceFileCount = [int]$ownerResponseBundleKitSourceFileCount
    ownerResponseBundleKitExportedFileCount = [int]$ownerResponseBundleKitExportedFileCount
    ownerResponseBundleKitHashMatchCount = [int]$ownerResponseBundleKitHashMatchCount
    ownerResponseBundleKitMissingExportFileCount = [int]$ownerResponseBundleKitMissingExportFileCount
    ownerResponseBundleKitExtraExportFileCount = [int]$ownerResponseBundleKitExtraExportFileCount
    ownerResponseBundleKitHashMismatchCount = [int]$ownerResponseBundleKitHashMismatchCount
    ownerResponseBundleKitMissingExportFiles = @($ownerResponseBundleKitMissingExportFiles)
    ownerResponseBundleKitExtraExportFiles = @($ownerResponseBundleKitExtraExportFiles)
    ownerResponseBundleKitHashMismatchFiles = @($ownerResponseBundleKitHashMismatchFiles)
    ownerResponseBundleKitFileHashes = @($ownerResponseBundleKitFileHashes)
    ownerResponseBundleKitSemanticPreflightCandidateField = $(if ($ownerResponseBundleKitAvailable) { [string](Get-ObjectProperty $ownerResponseBundleKitManifest "semanticPreflightCandidateField" "") } else { "" })
    ownerResponseBundleKitSemanticPreflightStatusField = $(if ($ownerResponseBundleKitAvailable) { [string](Get-ObjectProperty $ownerResponseBundleKitManifest "semanticPreflightStatusField" "") } else { "" })
    ownerResponseBundleKitSemanticPreflightFailCountField = $(if ($ownerResponseBundleKitAvailable) { [string](Get-ObjectProperty $ownerResponseBundleKitManifest "semanticPreflightFailCountField" "") } else { "" })
    ownerReturnBundleStatusAvailable = [bool]$ownerReturnBundleStatusAvailable
    ownerReturnBundleStatusIncluded = [bool]$ownerReturnBundleStatusAvailable
    ownerReturnBundleStatusContentValidated = [bool]$ownerReturnBundleStatusContentValidated
    ownerReturnBundleStatusPath = $ownerReturnBundleStatusReportRelativePath
    ownerReturnBundleStatusManifestPath = $ownerReturnBundleStatusManifestRelativePath
    ownerReturnBundleStatusProbeIncluded = [bool]$ownerReturnBundleStatusProbeManifestIncluded
    ownerReturnBundleStatusProbePath = $ownerReturnBundleStatusProbeReportRelativePath
    ownerReturnBundleStatusReadinessStatus = $ownerReturnBundleStatusReadinessStatus
    ownerReturnBundleStatusNextRequiredAction = $ownerReturnBundleStatusNextRequiredAction
    ownerReturnBundleStatusSemanticPreflightRun = [bool]$ownerReturnBundleStatusSemanticPreflightRun
    ownerReturnBundleStatusReadyForAcceptanceCandidate = [bool]$ownerReturnBundleStatusReadyForAcceptanceCandidate
    ownerReturnBundleStatusPendingOwnerPacketCount = [int]$ownerReturnBundleStatusPendingOwnerPacketCount
    ownerReturnBundleStatusRemainingMissingFileCount = [int]$ownerReturnBundleStatusRemainingMissingFileCount
    ownerReturnBundleStatusRemainingBlockingReasonCount = [int]$ownerReturnBundleStatusRemainingBlockingReasonCount
    ownerReturnBundleStatusAcceptanceRun = [bool]$ownerReturnBundleStatusAcceptanceRun
    ownerReturnBundleStatusRealHostProjectEvidenceAccepted = [bool]$ownerReturnBundleStatusRealHostProjectEvidenceAccepted
    ownerReturnBundleStatusManifestHashMatchesCanonical = [bool]$ownerReturnBundleStatusManifestHashMatchesCanonical
    ownerReturnBundleStatusCanonicalSourceSha256 = $ownerReturnBundleStatusCanonicalSourceSha256
    ownerReturnBundleStatusExportedSha256 = $ownerReturnBundleStatusExportedSha256
    ownerReturnBundleStatusProbeCaseCount = [int]$ownerReturnBundleStatusProbeCaseCount
    ownerReturnStatusSelfContainedHelperIncluded = [bool]$ownerReturnStatusSelfContainedHelperIncluded
    ownerReturnStatusSelfContainedHelperDocumented = [bool]$ownerReturnStatusSelfContainedHelperDocumented
    ownerReturnStatusSelfContainedHelperContentValidated = [bool]$ownerReturnStatusSelfContainedHelperContentValidated
    ownerReturnStatusSelfContainedHelperPath = $ownerReturnStatusSelfContainedHelperRelativePath
    ownerReturnStatusSelfContainedCorePath = $ownerReturnStatusSelfContainedCoreRelativePath
    ownerReturnStatusSelfContainedSemanticPreflightCorePath = $ownerReturnStatusSelfContainedSemanticPreflightCoreRelativePath
    ownerReturnStatusSelfContainedSourceDirectory = "production-handoff-export\$ownerReturnStatusSourceRelativePath"
    ownerReturnStatusSelfContainedSourceFileCount = [int]$ownerReturnStatusSelfContainedSourceFileCount
    ownerReturnStatusSelfContainedMissingSourceFiles = @($ownerReturnStatusSelfContainedMissingSourceFiles)
    ownerReturnStatusSelfContainedFolderCommand = $ownerReturnStatusSelfContainedFolderCommand
    ownerReturnStatusSelfContainedZipCommand = $ownerReturnStatusSelfContainedZipCommand
    semanticPreflightProbeAvailable = [bool]$semanticPreflightProbeAvailable
    semanticPreflightProbeIncluded = [bool]$semanticPreflightProbeIncluded
    semanticPreflightProbeReadOnly = [bool]$semanticPreflightProbeReadOnly
    semanticPreflightProbeAcceptanceRun = [bool](Get-ObjectProperty $semanticPreflightProbeManifest "acceptanceRun" $true)
    semanticPreflightProbeOwnerResponseBundleReady = [bool](Get-ObjectProperty $semanticPreflightProbeManifest "ownerResponseBundleReady" $false)
    semanticPreflightProbeOwnerResponseBundleZipReady = [bool](Get-ObjectProperty $semanticPreflightProbeManifest "ownerResponseBundleZipReady" $false)
    semanticPreflightProbeOwnerResponseBundleZipArbitraryWrapperReady = [bool](Get-ObjectProperty $semanticPreflightProbeManifest "ownerResponseBundleZipArbitraryWrapperReady" $false)
    semanticPreflightProbeUnsafeOwnerResponseBundleZipRejected = [bool](Get-ObjectProperty $semanticPreflightProbeManifest "unsafeOwnerResponseBundleZipRejected" $false)
    semanticPreflightProbePartialBundleRejected = [bool](Get-ObjectProperty $semanticPreflightProbeManifest "partialBundleRejected" $false)
    semanticPreflightProbePartialBundleZipRejected = [bool](Get-ObjectProperty $semanticPreflightProbeManifest "partialBundleZipRejected" $false)
    semanticPreflightProbeSemanticBadBundleRejected = [bool](Get-ObjectProperty $semanticPreflightProbeManifest "semanticBadBundleRejected" $false)
    semanticPreflightProbeSemanticBadBundleZipRejected = [bool](Get-ObjectProperty $semanticPreflightProbeManifest "semanticBadBundleZipRejected" $false)
    semanticPreflightProbeExtraPayloadBundleRejected = [bool](Get-ObjectProperty $semanticPreflightProbeManifest "extraPayloadBundleRejected" $false)
    semanticPreflightProbeNestedPayloadBundleZipRejected = [bool](Get-ObjectProperty $semanticPreflightProbeManifest "nestedPayloadBundleZipRejected" $false)
    semanticPreflightProbeOwnerResponseBundleZipCaseCount = [int](Get-ObjectProperty $semanticPreflightProbeManifest "ownerResponseBundleZipCaseCount" 0)
    semanticPreflightProbeOwnerResponseBundleZipSafeCaseCount = [int](Get-ObjectProperty $semanticPreflightProbeManifest "ownerResponseBundleZipSafeCaseCount" 0)
    semanticPreflightProbeOwnerResponseBundleZipUnsafeCaseCount = [int](Get-ObjectProperty $semanticPreflightProbeManifest "ownerResponseBundleZipUnsafeCaseCount" 1)
    semanticPreflightProbePayloadShapeRejectedCaseCount = [int](Get-ObjectProperty $semanticPreflightProbeManifest "payloadShapeRejectedCaseCount" 0)
    semanticPreflightSelfContainedHelperIncluded = [bool]$semanticPreflightSelfContainedHelperIncluded
    semanticPreflightSelfContainedHelperDocumented = [bool]$semanticPreflightSelfContainedHelperDocumented
    semanticPreflightSelfContainedHelperContentValidated = [bool]$semanticPreflightSelfContainedHelperContentValidated
    semanticPreflightSelfContainedHelperPath = $semanticPreflightSelfContainedHelperRelativePath
    semanticPreflightSelfContainedCorePath = $semanticPreflightSelfContainedCoreRelativePath
    semanticPreflightSelfContainedFolderCommand = $semanticPreflightSelfContainedFolderCommand
    semanticPreflightSelfContainedZipCommand = $semanticPreflightSelfContainedZipCommand
    operatorActionQueueSemanticPreflightBeforeAutoAcceptanceDocumented = [bool]$operatorActionQueueSemanticPreflightBeforeAutoAcceptanceDocumented
    semanticPreflightDocumentedBeforeAutoAcceptance = [bool]$semanticPreflightDocumentedBeforeAutoAcceptance
    autoAcceptanceRequiresSemanticPreflightCandidate = [bool]$ownerResponseBundleKitSemanticPreflightCommandsDocumented
    semanticPreflightCandidateField = "readyForAcceptanceCandidate"
    semanticPreflightStatusField = "semanticPreflightStatus"
    semanticPreflightFailCountField = "semanticFailCount"
    operatorActionQueueAvailable = [bool]$operatorActionQueueAvailable
    operatorActionQueueIncluded = [bool]$operatorActionQueueAvailable
    operatorActionQueueSourceKind = $operatorActionQueueSourceKind
    operatorActionQueueManifestSourceKind = $(if ($operatorActionQueueAvailable) { [string](Get-ObjectProperty $operatorActionQueueManifest "sourceKind" "") } else { "" })
    operatorActionQueueManifestIncluded = [bool]$operatorActionQueueManifestIncluded
    operatorActionQueueReportIncluded = [bool]$operatorActionQueueReportIncluded
    operatorActionNextStepsIncluded = [bool]$operatorActionNextStepsIncluded
    operatorActionNextStepsContentValidated = [bool]$operatorActionNextStepsContentValidated
    operatorActionNextStepsPath = $operatorActionNextStepsRelativePath
    operatorActionQueueProbeIncluded = [bool]$operatorActionQueueAvailable
    operatorActionQueueProbeManifestIncluded = [bool]$operatorActionQueueProbeManifestIncluded
    operatorActionQueueSourceSnapshotIncluded = [bool]$operatorActionQueueSourceSnapshotIncluded
    operatorActionQueueRemainingWorkSnapshotIncluded = [bool]$operatorActionQueueRemainingWorkSnapshotIncluded
    operatorActionQueuePostDispatchSnapshotIncluded = [bool]$operatorActionQueuePostDispatchSnapshotIncluded
    operatorActionQueueCanonicalSourcePath = "production-external-evidence-action-queue-manifest.json"
    operatorActionQueueExportedPath = $operatorActionQueueManifestRelativePath
    operatorActionQueueCanonicalSourceSha256 = $operatorActionQueueCanonicalSourceSha256
    operatorActionQueueExportedSha256 = $operatorActionQueueExportedSha256
    operatorActionQueueManifestHashMatchesCanonical = [bool]$operatorActionQueueManifestHashMatchesCanonical
    operatorActionQueueContentValidated = [bool]$operatorActionQueueExportContentValidated
    operatorActionFileCount = $(if ($operatorActionQueueAvailable) { [int]@($operatorActionQueueFiles).Count } else { 0 })
    operatorActionQueueItemAutoAcceptanceCommandCount = [int]$operatorActionQueueItemBundleCommandCount
    operatorActionQueueItemSemanticPreflightCommandCount = [int]$operatorActionQueueItemSemanticPreflightCommandCount
    operatorActionQueueItemStatusCommandCount = [int]$operatorActionQueueItemStatusCommandCount
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
    firstTestableSummaryIncluded = [bool]$firstTestableSummaryIncluded
    firstTestableSummaryContentValidated = [bool]$firstTestableSummaryContentValidated
    firstTestableSummaryFinalBoundaryValidated = [bool]$firstTestableSummaryFinalBoundaryValidated
    firstTestableSummaryCheckPassed = [bool]$firstTestableSummaryCheckPassed
    firstTestableSummaryPath = $firstTestableSummaryExportRelativePath
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
