[CmdletBinding()]
param(
    [string]$ArtifactDir,
    [string]$ManifestPath,
    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($ArtifactDir)) {
    $ArtifactDir = Join-Path $repoRoot "artifacts\ai-testpilot-release\latest"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $ArtifactDir "first-testable-release-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $ArtifactDir "first-testable-release.md"
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

function Assert-PathUnderArtifact {
    param(
        [string]$Path,
        [string]$Label
    )

    $fullPath = Assert-PathUnderRepo $Path $Label
    if (-not (Test-PathWithinRoot $fullPath $script:artifactPath)) {
        throw "$Label must stay under artifact dir: $fullPath"
    }

    return $fullPath
}

function Convert-ToArtifactRelativePath {
    param([string]$Path)

    $fullPath = Resolve-FullPath $Path
    if (-not (Test-PathWithinRoot $fullPath $artifactPath)) {
        throw "Path must stay under artifact dir: $fullPath"
    }

    return $fullPath.Substring($artifactPath.Length).TrimStart([char[]]@("\", "/")).Replace("/", "\")
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

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    return [System.Convert]::ToBoolean($Value)
}

function Convert-ToInt {
    param([object]$Value)

    if ($null -eq $Value) {
        return 0
    }

    return [System.Convert]::ToInt32($Value)
}

function Format-MarkdownCell {
    param([object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    return ([string]$Value).Replace("|", "\|").Replace("`r", " ").Replace("`n", "<br>")
}

$artifactPath = Assert-PathUnderRepo $ArtifactDir "ArtifactDir"
$manifestFullPath = Assert-PathUnderArtifact $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderArtifact $ReportPath "ReportPath"

if (-not (Test-Path $artifactPath)) {
    throw "ArtifactDir is missing: $artifactPath"
}

$pipelineManifest = Read-JsonFile (Join-Path $artifactPath "pipeline-manifest.json") "Pipeline manifest"
$releaseGateManifest = Read-JsonFile (Join-Path $artifactPath "release-gate-manifest.json") "Release gate manifest"
$releaseRiskPolicyManifest = Read-JsonFile (Join-Path $artifactPath "release-risk-policy-manifest.json") "Release risk policy manifest"
$releaseEvidenceIndexManifest = Read-JsonFile (Join-Path $artifactPath "release-evidence-index-manifest.json") "Release evidence index manifest"
$fieldCoverageProbeManifest = Read-JsonFile (Join-Path $artifactPath "release-evidence-index-field-coverage-probe-manifest.json") "Release evidence field coverage probe manifest"
$handoffExportManifest = Read-JsonFile (Join-Path $artifactPath "production-handoff-export-manifest.json") "Production handoff export manifest"
$handoffZipIndexManifest = Read-JsonFile (Join-Path $artifactPath "production-handoff-export-zip-index-manifest.json") "Production handoff export zip index manifest"
$actionQueueManifest = Read-JsonFile (Join-Path $artifactPath "production-external-evidence-action-queue-manifest.json") "Production external evidence action queue manifest"
$ownerReturnStatusManifest = Read-JsonFile (Join-Path $artifactPath "production-external-evidence-owner-return-bundle-status-manifest.json") "Owner return bundle status manifest"
$ownerResponseBundleKitManifest = Read-JsonFile (Join-Path $artifactPath "production-handoff-owner-response-bundle-kit-manifest.json") "Owner response bundle kit manifest"

$handoffZipPath = Join-Path $artifactPath "production-handoff-export.zip"
$handoffZipExists = Test-Path $handoffZipPath
$handoffZipSha256 = if ($handoffZipExists) { (Get-FileHash -Path $handoffZipPath -Algorithm SHA256).Hash.ToLowerInvariant() } else { "" }
$handoffZipIndexSha256 = ([string](Get-JsonValue $handoffZipIndexManifest "zipSha256" "")).ToLowerInvariant()

$testEntryPaths = @(
    "production-handoff-export.zip",
    "production-handoff-export\FIRST-TESTABLE.md",
    "production-handoff-export\README.md",
    "production-handoff-export\run-owner-return-status.ps1",
    "production-handoff-export\owner-return-status\Invoke-AITestPilotProductionExternalEvidenceOwnerReturnBundleStatus.ps1",
    "production-handoff-export\owner-return-status\Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1",
    "production-handoff-export\owner-return-status-source\production-handoff-status-manifest.json",
    "production-handoff-export\owner-return-status-source\production-external-evidence-inbox-manifest.json",
    "production-handoff-export\owner-return-status-source\production-handoff-owner-input-request-pack-manifest.json",
    "production-handoff-export\owner-return-status-source\production-handoff-owner-unblock-pack-manifest.json",
    "production-handoff-export\owner-return-status-source\production-handoff-owner-response-bundle-kit-manifest.json",
    "production-handoff-export\owner-return-status-source\production-external-evidence-action-queue-manifest.json",
    "production-handoff-export\operator-actions\NEXT-STEPS.md",
    "production-handoff-export\operator-actions\production-external-evidence-owner-return-bundle-status.md",
    "production-handoff-export\operator-actions\production-external-evidence-action-queue.md",
    "production-handoff-export\production-handoff-owner-response-bundle-kit\README.md",
    "production-handoff-export\production-handoff-owner-response-bundle-kit\verify-owner-response-bundle.ps1",
    "production-handoff-export\production-handoff-owner-response-bundle-kit\merge-owner-mini-kits.ps1",
    "production-handoff-export\production-handoff-owner-response-bundle-kit\owner-response-mini-kits\README.md",
    "production-handoff-export\production-handoff-owner-response-bundle-kit\owner-response-mini-kits\host_project_gameplay_qa.zip",
    "production-handoff-export\production-handoff-owner-response-bundle-kit\owner-response-mini-kits\host_project_lua_owner.zip",
    "production-handoff-export\production-handoff-owner-response-bundle-kit\owner-response-mini-kits\host_project_ai_platform.zip",
    "production-handoff-export\run-semantic-preflight.ps1",
    "production-handoff-export\production-external-evidence-inbox\accept-returned-evidence.ps1"
)

$missingTestEntryPaths = @($testEntryPaths | Where-Object { -not (Test-Path (Join-Path $artifactPath $_)) })
$zipEntryPaths = @((Get-JsonValue $handoffZipIndexManifest "zipEntries" @()) | ForEach-Object { [string](Get-JsonValue $_ "path" "") })
$handoffExportPrefix = "production-handoff-export\"
$testEntryZipPaths = @($testEntryPaths |
    Where-Object { $_.StartsWith($handoffExportPrefix, [System.StringComparison]::OrdinalIgnoreCase) } |
    ForEach-Object { $_.Substring($handoffExportPrefix.Length) })
$missingZipTestEntryPaths = @($testEntryZipPaths | Where-Object { $zipEntryPaths -notcontains $_ })

$actionQueueItems = @(Get-JsonValue $actionQueueManifest "actionQueue" @())
$ownerAreas = @($actionQueueItems | ForEach-Object {
        [ordered]@{
            owner = [string](Get-JsonValue $_ "owner" "")
            area = [string](Get-JsonValue $_ "area" "")
            status = [string](Get-JsonValue $_ "status" "")
            missingFileCount = Convert-ToInt (Get-JsonValue $_ "missingFileCount" 0)
            remainingBlockingReasonCount = Convert-ToInt (Get-JsonValue $_ "remainingBlockingReasonCount" 0)
            bundleArea = [string](Get-JsonValue $_ "ownerResponseBundleAreaPath" "")
        }
    })

$checks = @()
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

Add-ProbeCheck "pipeline_artifact_passed" `
    ((Get-JsonValue $pipelineManifest "status" "") -eq "PASS" -and
        (Convert-ToInt (Get-JsonValue $pipelineManifest "ciExitCode" 1)) -eq 0 -and
        -not (Convert-ToBool (Get-JsonValue $pipelineManifest "finalReleaseArtifactsInvalidated" $true))) `
    "The copied latest artifact must come from a passing pipeline and must not be invalidated."

Add-ProbeCheck "release_gate_and_policy_passed" `
    ((Get-JsonValue $releaseGateManifest "status" "") -eq "PASS" -and
        (Convert-ToInt (Get-JsonValue $releaseGateManifest "failedReasonCount" 1)) -eq 0 -and
        (Get-JsonValue $releaseRiskPolicyManifest "status" "") -eq "PASS") `
    "Release gate and release risk policy must pass for the testable artifact."

Add-ProbeCheck "release_evidence_index_covered" `
    ((Get-JsonValue $releaseEvidenceIndexManifest "status" "") -eq "PASS" -and
        (Convert-ToInt (Get-JsonValue $releaseEvidenceIndexManifest "semanticFieldCheckCount" 0)) -eq 133 -and
        (Convert-ToInt (Get-JsonValue $releaseEvidenceIndexManifest "semanticFieldCheckFailedCount" 1)) -eq 0 -and
        (Get-JsonValue $fieldCoverageProbeManifest "status" "") -eq "PASS") `
    "Release evidence index must pass all semantic field checks and the field coverage probe."

Add-ProbeCheck "handoff_export_zip_verified" `
    ((Get-JsonValue $handoffExportManifest "status" "") -eq "PASS" -and
        (Convert-ToBool (Get-JsonValue $handoffExportManifest "ownerReturnBundleStatusIncluded" $false)) -and
        (Convert-ToBool (Get-JsonValue $handoffExportManifest "ownerReturnBundleStatusContentValidated" $false)) -and
        (Get-JsonValue $handoffZipIndexManifest "status" "") -eq "PASS" -and
        $handoffZipExists -and
        -not [string]::IsNullOrWhiteSpace($handoffZipSha256) -and
        $handoffZipSha256 -eq $handoffZipIndexSha256) `
    "Owner-facing handoff export zip must pass hash/index validation and include owner-return status."

Add-ProbeCheck "operator_test_entrypoints_present" `
    ($missingTestEntryPaths.Count -eq 0) `
    "First-testable artifact must include README, operator next steps, owner-return status, action queue, bundle verifier, semantic preflight, and returned-evidence acceptance entry points."

Add-ProbeCheck "operator_test_entrypoints_zip_indexed" `
    ((Get-JsonValue $handoffZipIndexManifest "status" "") -eq "PASS" -and
        $missingZipTestEntryPaths.Count -eq 0) `
    "First-testable handoff zip index must include the operator entry points, FIRST-TESTABLE.md, owner mini kit zips, and self-contained returned-bundle status/preflight helpers."

Add-ProbeCheck "owner_mini_kits_first_testable_included" `
    ((Get-JsonValue $ownerResponseBundleKitManifest "status" "") -eq "PASS" -and
        (Convert-ToBool (Get-JsonValue $ownerResponseBundleKitManifest "ownerMiniKitsGenerated" $false)) -and
        (Convert-ToBool (Get-JsonValue $ownerResponseBundleKitManifest "ownerMiniKitsContentValidated" $false)) -and
        (Convert-ToBool (Get-JsonValue $ownerResponseBundleKitManifest "ownerMiniKitMergeScriptGenerated" $false)) -and
        (Convert-ToBool (Get-JsonValue $ownerResponseBundleKitManifest "ownerMiniKitMergeScriptContentValidated" $false)) -and
        (Convert-ToInt (Get-JsonValue $ownerResponseBundleKitManifest "ownerMiniKitCount" 0)) -eq 3 -and
        (Convert-ToInt (Get-JsonValue $ownerResponseBundleKitManifest "ownerMiniKitZipCount" 0)) -eq 3 -and
        (Convert-ToInt (Get-JsonValue $ownerResponseBundleKitManifest "ownerMiniKitRequiredFilesJsonCount" 0)) -eq 3 -and
        (Convert-ToInt (Get-JsonValue $ownerResponseBundleKitManifest "ownerMiniKitReturnInstructionsCount" 0)) -eq 3) `
    "First-testable artifact must carry three per-owner mini kit zips plus the merge helper as required owner-facing test entry points."

Add-ProbeCheck "handoff_first_testable_summary_and_status_helper" `
    ((Convert-ToBool (Get-JsonValue $handoffExportManifest "firstTestableSummaryContentValidated" $false)) -and
        (Convert-ToBool (Get-JsonValue $handoffExportManifest "ownerReturnStatusSelfContainedHelperContentValidated" $false))) `
    "Handoff export manifest must prove zip-root FIRST-TESTABLE.md and the self-contained owner-return status helper were generated and content-validated."

Add-ProbeCheck "remaining_work_boundary_explicit" `
    ((Get-JsonValue $actionQueueManifest "status" "") -eq "PASS" -and
        (Convert-ToInt (Get-JsonValue $actionQueueManifest "externalRemainingWorkItemCount" 0)) -eq 3 -and
        (Convert-ToInt (Get-JsonValue $actionQueueManifest "externalRemainingMissingFileCount" 0)) -eq 9 -and
        (Convert-ToInt (Get-JsonValue $actionQueueManifest "externalRemainingBlockingReasonCount" 0)) -eq 11 -and
        (Convert-ToInt (Get-JsonValue $actionQueueManifest "localProgressMailRemainingActionCount" 0)) -eq 1 -and
        $ownerAreas.Count -eq 3) `
    "Artifact must state the remaining external-owner boundary without hiding local mail state."

Add-ProbeCheck "owner_return_status_pending_and_read_only" `
    ((Get-JsonValue $ownerReturnStatusManifest "status" "") -eq "PASS" -and
        (Convert-ToBool (Get-JsonValue $ownerReturnStatusManifest "readOnly" $false)) -and
        (Get-JsonValue $ownerReturnStatusManifest "ownerReturnReadinessStatus" "") -eq "PENDING_EXTERNAL_EVIDENCE" -and
        (Get-JsonValue $ownerReturnStatusManifest "nextRequiredAction" "") -eq "collect_owner_response_bundle_zip" -and
        -not (Convert-ToBool (Get-JsonValue $ownerReturnStatusManifest "acceptanceRun" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $ownerReturnStatusManifest "realHostProjectEvidenceAccepted" $true))) `
    "Owner-return status must stay read-only and pending until real owner evidence is supplied."

Add-ProbeCheck "production_boundary_not_promoted" `
    (-not (Convert-ToBool (Get-JsonValue $handoffExportManifest "realHostProjectEvidenceAccepted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $handoffExportManifest "fixtureEvidencePromoted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $actionQueueManifest "externalEvidenceAccepted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $actionQueueManifest "fixtureEvidencePromoted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $ownerReturnStatusManifest "emailSent" $true))) `
    "Testable artifact must not claim real evidence, promote fixtures, or send email."

$failedChecks = @($checks | Where-Object { -not [bool]$_["passed"] })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$generatedFiles = @(
    (Convert-ToArtifactRelativePath $manifestFullPath),
    (Convert-ToArtifactRelativePath $reportFullPath)
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.first_testable_release_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    artifactDir = $artifactPath
    pipelineStatus = [string](Get-JsonValue $pipelineManifest "status" "")
    pipelineStepCount = Convert-ToInt (Get-JsonValue $pipelineManifest "stepCount" 0)
    releaseGateStatus = [string](Get-JsonValue $releaseGateManifest "status" "")
    releaseRiskPolicyStatus = [string](Get-JsonValue $releaseRiskPolicyManifest "status" "")
    semanticFieldCheckCount = Convert-ToInt (Get-JsonValue $releaseEvidenceIndexManifest "semanticFieldCheckCount" 0)
    semanticFieldCheckFailedCount = Convert-ToInt (Get-JsonValue $releaseEvidenceIndexManifest "semanticFieldCheckFailedCount" 0)
    handoffExportStatus = [string](Get-JsonValue $handoffExportManifest "status" "")
    handoffExportZipSha256 = $handoffZipSha256
    handoffExportZipIndexSha256 = $handoffZipIndexSha256
    handoffExportZipHashMatchesIndex = [bool]($handoffZipSha256 -eq $handoffZipIndexSha256 -and -not [string]::IsNullOrWhiteSpace($handoffZipSha256))
    ownerReturnStatusIncluded = Convert-ToBool (Get-JsonValue $handoffExportManifest "ownerReturnBundleStatusIncluded" $false)
    ownerReturnStatusContentValidated = Convert-ToBool (Get-JsonValue $handoffExportManifest "ownerReturnBundleStatusContentValidated" $false)
    ownerReturnReadinessStatus = [string](Get-JsonValue $ownerReturnStatusManifest "ownerReturnReadinessStatus" "")
    nextRequiredAction = [string](Get-JsonValue $ownerReturnStatusManifest "nextRequiredAction" "")
    ownerMiniKitsGenerated = Convert-ToBool (Get-JsonValue $ownerResponseBundleKitManifest "ownerMiniKitsGenerated" $false)
    ownerMiniKitCount = Convert-ToInt (Get-JsonValue $ownerResponseBundleKitManifest "ownerMiniKitCount" 0)
    ownerMiniKitZipCount = Convert-ToInt (Get-JsonValue $ownerResponseBundleKitManifest "ownerMiniKitZipCount" 0)
    ownerMiniKitMergeScriptGenerated = Convert-ToBool (Get-JsonValue $ownerResponseBundleKitManifest "ownerMiniKitMergeScriptGenerated" $false)
    externalOwnerAreaCount = Convert-ToInt (Get-JsonValue $actionQueueManifest "externalRemainingWorkItemCount" 0)
    externalMissingFileCount = Convert-ToInt (Get-JsonValue $actionQueueManifest "externalRemainingMissingFileCount" 0)
    externalBlockingReasonCount = Convert-ToInt (Get-JsonValue $actionQueueManifest "externalRemainingBlockingReasonCount" 0)
    localProgressMailRemainingActionCount = Convert-ToInt (Get-JsonValue $actionQueueManifest "localProgressMailRemainingActionCount" 0)
    testEntryPointCount = [int]$testEntryPaths.Count
    missingTestEntryPointCount = [int]$missingTestEntryPaths.Count
    zipTestEntryPointCount = [int]$testEntryZipPaths.Count
    missingZipTestEntryPointCount = [int]$missingZipTestEntryPaths.Count
    testEntryPoints = @($testEntryPaths)
    missingTestEntryPoints = @($missingTestEntryPaths)
    testEntryZipPaths = @($testEntryZipPaths)
    missingZipTestEntryPaths = @($missingZipTestEntryPaths)
    ownerAreas = @($ownerAreas)
    readyForOperatorTesting = [bool]($status -eq "PASS")
    readyForCommercialCompletion = $false
    completionBoundary = "external_owner_evidence_required"
    releasePipelineSendsEmail = $false
    realHostProjectEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "first_testable_release_probe_only"
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles)
}

New-Item -ItemType Directory -Force (Split-Path $manifestFullPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestFullPath -Encoding UTF8

$reportLines = @(
    "# AI TestPilot First Testable Release Probe",
    "",
    "- Status: $status",
    "- Artifact dir: $artifactPath",
    "- Pipeline status: $($manifest.pipelineStatus)",
    "- Pipeline steps: $($manifest.pipelineStepCount)",
    "- Release gate: $($manifest.releaseGateStatus)",
    "- Semantic field checks: $($manifest.semanticFieldCheckCount - $manifest.semanticFieldCheckFailedCount) / $($manifest.semanticFieldCheckCount)",
    "- Handoff export zip SHA256: $handoffZipSha256",
    "- Owner return readiness: $($manifest.ownerReturnReadinessStatus)",
    "- Next required action: $($manifest.nextRequiredAction)",
    "- Owner mini kits: $($manifest.ownerMiniKitZipCount) / $($manifest.ownerMiniKitCount)",
    "- Owner mini kit merge helper: $($manifest.ownerMiniKitMergeScriptGenerated)",
    "- External owner areas: $($manifest.externalOwnerAreaCount)",
    "- Missing files: $($manifest.externalMissingFileCount)",
    "- Blocking reasons: $($manifest.externalBlockingReasonCount)",
    "- Local progress-mail action: $($manifest.localProgressMailRemainingActionCount)",
    "- Ready for operator testing: $($manifest.readyForOperatorTesting)",
    "- Ready for commercial completion: $($manifest.readyForCommercialCompletion)",
    "",
    "## Test Entry Points",
    "",
    "| Path | Present |",
    "| --- | --- |"
)

foreach ($entryPath in $testEntryPaths) {
    $present = $missingTestEntryPaths -notcontains $entryPath
    $reportLines += "| $(Format-MarkdownCell $entryPath) | $present |"
}

$reportLines += @(
    "",
    "## Handoff Zip Entry Points",
    "",
    "| Zip Path | Present |",
    "| --- | --- |"
)

foreach ($zipEntryPath in $testEntryZipPaths) {
    $present = $missingZipTestEntryPaths -notcontains $zipEntryPath
    $reportLines += "| $(Format-MarkdownCell $zipEntryPath) | $present |"
}

$reportLines += @(
    "",
    "## Owner Areas",
    "",
    "| Owner | Area | Status | Missing Files | Blockers | Bundle Area |",
    "| --- | --- | --- | ---: | ---: | --- |"
)

foreach ($ownerArea in $ownerAreas) {
    $reportLines += "| $(Format-MarkdownCell $ownerArea.owner) | $(Format-MarkdownCell $ownerArea.area) | $(Format-MarkdownCell $ownerArea.status) | $($ownerArea.missingFileCount) | $($ownerArea.remainingBlockingReasonCount) | $(Format-MarkdownCell $ownerArea.bundleArea) |"
}

$reportLines += @(
    "",
    "## Checks",
    "",
    "| Check | Passed | Message |",
    "| --- | --- | --- |"
)

foreach ($check in $checks) {
    $reportLines += "| $(Format-MarkdownCell $check.name) | $($check.passed) | $(Format-MarkdownCell $check.message) |"
}

$reportLines += @(
    "",
    "## Boundary",
    "",
    "- This probe validates the first testable artifact shape.",
    "- It does not send email, accept returned evidence, or promote fixture evidence.",
    "- Commercial completion still requires real external owner evidence and hard validation."
)

$reportLines | Set-Content -Path $reportFullPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "First testable release probe failed: $($failedChecks.name -join ', ')"
}

Write-Output "First testable release probe manifest: $manifestFullPath"
Write-Output "First testable release probe report: $reportFullPath"
Write-Output "PASS AI TestPilot first testable release probe"
