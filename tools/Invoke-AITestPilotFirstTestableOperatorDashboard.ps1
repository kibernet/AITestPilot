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
    $ManifestPath = Join-Path $ArtifactDir "first-testable-operator-dashboard-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $ArtifactDir "first-testable-operator-dashboard.md"
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

function Convert-ToArray {
    param([object]$Value)

    if ($null -eq $Value) {
        return @()
    }

    return @($Value)
}

function Convert-ToBool {
    param([object]$Value)

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    if ($null -eq $Value) {
        return $false
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

function Join-TextList {
    param([object[]]$Values)

    $items = @($Values | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($items.Count -eq 0) {
        return "(none)"
    }

    return [string]::Join(", ", $items)
}

$artifactPath = Assert-PathUnderRepo $ArtifactDir "ArtifactDir"
$manifestFullPath = Assert-PathUnderArtifact $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderArtifact $ReportPath "ReportPath"

if (-not (Test-Path $artifactPath)) {
    throw "ArtifactDir is missing: $artifactPath"
}

$pipelineManifest = Read-JsonFile (Join-Path $artifactPath "pipeline-manifest.json") "Pipeline manifest"
$firstTestableManifest = Read-JsonFile (Join-Path $artifactPath "first-testable-release-manifest.json") "First testable release manifest"
$releaseGateManifest = Read-JsonFile (Join-Path $artifactPath "release-gate-manifest.json") "Release gate manifest"
$releaseRiskPolicyManifest = Read-JsonFile (Join-Path $artifactPath "release-risk-policy-manifest.json") "Release risk policy manifest"
$releaseEvidenceIndexManifest = Read-JsonFile (Join-Path $artifactPath "release-evidence-index-manifest.json") "Release evidence index manifest"
$actionQueueManifest = Read-JsonFile (Join-Path $artifactPath "production-external-evidence-action-queue-manifest.json") "Production external evidence action queue manifest"
$gapAnalysisManifest = Read-JsonFile (Join-Path $artifactPath "production-external-evidence-gap-analysis-manifest.json") "Production external evidence gap analysis manifest"
$ownerRouteMapManifest = Read-JsonFile (Join-Path $artifactPath "production-handoff-owner-route-map-manifest.json") "Production handoff owner route map manifest"
$ownerReturnStatusManifest = Read-JsonFile (Join-Path $artifactPath "production-external-evidence-owner-return-bundle-status-manifest.json") "Owner return bundle status manifest"
$handoffExportManifest = Read-JsonFile (Join-Path $artifactPath "production-handoff-export-manifest.json") "Production handoff export manifest"
$ownerInputRequestManifest = Read-JsonFile (Join-Path $artifactPath "production-handoff-owner-input-request-pack-manifest.json") "Owner input request manifest"
$sendReadinessManifest = Read-JsonFile (Join-Path $artifactPath "production-handoff-send-readiness-manifest.json") "Owner send readiness manifest"

$actionQueueItems = @(Convert-ToArray (Get-JsonValue $actionQueueManifest "actionQueue" @()))
$ownerRoutes = @()
foreach ($item in $actionQueueItems) {
    $ownerRoutes += [ordered]@{
        owner = [string](Get-JsonValue $item "owner" "")
        area = [string](Get-JsonValue $item "area" "")
        status = [string](Get-JsonValue $item "status" "")
        contactStatus = [string](Get-JsonValue $item "contactStatus" "")
        sendStatus = [string](Get-JsonValue $item "sendStatus" "")
        dispatchStatus = [string](Get-JsonValue $item "dispatchStatus" "")
        ownerPacketPath = [string](Get-JsonValue $item "ownerPacketPath" "")
        bundleAreaPath = [string](Get-JsonValue $item "ownerResponseBundleAreaPath" "")
        missingFiles = @(Convert-ToArray (Get-JsonValue $item "missingFiles" @()) | ForEach-Object { [string]$_ })
        missingFileCount = Convert-ToInt (Get-JsonValue $item "missingFileCount" 0)
        blockingReasons = @(Convert-ToArray (Get-JsonValue $item "remainingBlockingReasons" @()) | ForEach-Object { [string]$_ })
        blockingReasonCount = Convert-ToInt (Get-JsonValue $item "remainingBlockingReasonCount" 0)
        ownerReturnStatusCommand = [string](Get-JsonValue $item "ownerResponseBundleZipStatusCommand" "")
        semanticPreflightCommand = [string](Get-JsonValue $item "ownerResponseBundleZipSemanticPreflightCommand" "")
        autoAcceptanceCommand = [string](Get-JsonValue $item "ownerResponseBundleZipAutoAcceptanceCommand" "")
        hardValidationCommand = [string](Get-JsonValue $item "hardValidationCommand" "")
        exportHelperCommand = [string](Get-JsonValue $item "productionDriverEvidenceExportHelperCommand" "")
        luaExportHelperCommand = [string](Get-JsonValue $item "productionLuaEvidenceExportHelperCommand" "")
        liveSmokeExportHelperCommand = [string](Get-JsonValue $item "liveModelSmokeEvidenceExportHelperCommand" "")
    }
}

$operatorPreflightMatrix = @()
foreach ($route in $ownerRoutes) {
    $owner = [string]$route.owner
    $area = [string]$route.area
    $contactStatus = [string]$route.contactStatus
    $sendStatus = [string]$route.sendStatus
    $bundleAreaPath = [string]$route.bundleAreaPath
    $missingFileCount = [int]$route.missingFileCount
    $missingFiles = @($route.missingFiles | ForEach-Object { [string]$_ })
    $contactAction = if ($contactStatus -eq "MISSING_OWNER_EMAIL" -or $sendStatus -eq "BLOCKED_MISSING_OWNER_EMAIL") {
        "Fill production-handoff-owner-input-request-pack/owner-contact-roster-template.json for $owner before sending."
    }
    else {
        "Contact configured; keep two-stage send confirmation enabled."
    }
    $evidenceAction = if ($missingFileCount -gt 0) {
        "Fill $bundleAreaPath with $missingFileCount required files: $(Join-TextList $missingFiles)."
    }
    else {
        "No missing files reported for $area."
    }

    $operatorPreflightMatrix += [ordered]@{
        owner = $owner
        area = $area
        safeNextStep = "collect_owner_response_bundle_zip"
        contactStatus = $contactStatus
        sendStatus = $sendStatus
        contactNextAction = $contactAction
        evidenceNextAction = $evidenceAction
        ownerResponseBundleAreaPath = $bundleAreaPath
        ownerPacketPath = [string]$route.ownerPacketPath
        missingFileCount = $missingFileCount
        missingFiles = @($missingFiles)
        blockingReasonCount = [int]$route.blockingReasonCount
        blockingReasons = @($route.blockingReasons | ForEach-Object { [string]$_ })
        ownerReturnStatusWorkingDirectory = "artifact_root"
        semanticPreflightWorkingDirectory = "artifact_root"
        acceptanceWorkingDirectory = "artifact_root_after_status_and_preflight"
        hardValidationWorkingDirectory = "repo_root"
        ownerReturnStatusCommand = [string]$route.ownerReturnStatusCommand
        semanticPreflightCommand = [string]$route.semanticPreflightCommand
        acceptanceCommand = [string]$route.autoAcceptanceCommand
        hardValidationCommand = [string]$route.hardValidationCommand
        acceptanceGate = "Run acceptance only after owner-return status is READY_FOR_AUTO_ACCEPTANCE_CANDIDATE and semanticFailCount is 0."
        operatorCanRunAcceptanceNow = $false
    }
}

$routesWithStatusCommand = @($ownerRoutes | Where-Object { ([string]$_["ownerReturnStatusCommand"]).Contains("OwnerReturnBundleStatus") -and ([string]$_["ownerReturnStatusCommand"]).Contains("-OwnerResponseBundleZipPath") }).Count
$routesWithSemanticPreflight = @($ownerRoutes | Where-Object { ([string]$_["semanticPreflightCommand"]).Contains("SemanticPreflight") -and ([string]$_["semanticPreflightCommand"]).Contains("-OwnerResponseBundleZipPath") }).Count
$routesWithAutoAcceptance = @($ownerRoutes | Where-Object { ([string]$_["autoAcceptanceCommand"]).Contains("AutoAcceptance") -and ([string]$_["autoAcceptanceCommand"]).Contains("-RequireAllEvidence") }).Count
$routesWithHardValidation = @($ownerRoutes | Where-Object { ([string]$_["hardValidationCommand"]).Contains("Invoke-AITestPilotReleasePipeline.ps1") }).Count
$preflightRowsWithContactAction = @($operatorPreflightMatrix | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_["contactNextAction"]) }).Count
$preflightRowsWithEvidenceAction = @($operatorPreflightMatrix | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_["evidenceNextAction"]) }).Count
$preflightRowsWithAcceptanceGate = @($operatorPreflightMatrix | Where-Object {
        ([string]$_["acceptanceGate"]).Contains("READY_FOR_AUTO_ACCEPTANCE_CANDIDATE") -and
        -not [bool]$_["operatorCanRunAcceptanceNow"]
    }).Count

$nextZipLocalStatusCommand = '.\production-handoff-export\run-owner-return-status.ps1 -OwnerResponseBundleZipPath "path\to\filled-owner-response-bundle.zip"'
$nextZipLocalSemanticPreflightCommand = '.\production-handoff-export\run-semantic-preflight.ps1 -OwnerResponseBundleZipPath "path\to\filled-owner-response-bundle.zip"'
$nextBundledAcceptanceCommand = '.\production-handoff-export\production-external-evidence-inbox\accept-returned-evidence.ps1 -RepoRoot "path\to\AITestPilot" -EvidenceBundleDir "path\to\AITestPilot\artifacts\ai-testpilot-release\latest" -OwnerResponseBundleZipPath "path\to\filled-owner-response-bundle.zip"'

$checks = @()
function Add-DashboardCheck {
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

Add-DashboardCheck "first_testable_artifact_passed" `
    ((Get-JsonValue $firstTestableManifest "status" "") -eq "PASS" -and
        (Convert-ToBool (Get-JsonValue $firstTestableManifest "readyForOperatorTesting" $false)) -and
        (Get-JsonValue $pipelineManifest "status" "") -eq "PASS" -and
        (Get-JsonValue $releaseGateManifest "status" "") -eq "PASS" -and
        (Get-JsonValue $releaseRiskPolicyManifest "status" "") -eq "PASS") `
    "Dashboard must be based on a passing first-testable artifact, pipeline, gate, and risk policy."

Add-DashboardCheck "release_index_semantic_coverage_preserved" `
    ((Get-JsonValue $releaseEvidenceIndexManifest "status" "") -eq "PASS" -and
        (Convert-ToInt (Get-JsonValue $releaseEvidenceIndexManifest "semanticFieldCheckCount" 0)) -eq 133 -and
        (Convert-ToInt (Get-JsonValue $releaseEvidenceIndexManifest "semanticFieldCheckFailedCount" 1)) -eq 0) `
    "Dashboard must preserve the 133-field release evidence semantic coverage boundary."

Add-DashboardCheck "external_owner_boundary_explicit" `
    ((Get-JsonValue $actionQueueManifest "status" "") -eq "PASS" -and
        (Get-JsonValue $gapAnalysisManifest "status" "") -eq "PASS" -and
        (Convert-ToInt (Get-JsonValue $gapAnalysisManifest "externalRemainingWorkItemCount" 0)) -eq 3 -and
        (Convert-ToInt (Get-JsonValue $gapAnalysisManifest "externalRemainingMissingFileCount" 0)) -eq 9 -and
        (Convert-ToInt (Get-JsonValue $gapAnalysisManifest "externalRemainingBlockingReasonCount" 0)) -eq 11 -and
        (Convert-ToInt (Get-JsonValue $gapAnalysisManifest "repoSideClosableGapCount" 1)) -eq 0) `
    "Dashboard must make the three external owner areas, nine missing files, eleven blockers, and zero repo-side closable gaps explicit."

Add-DashboardCheck "owner_routes_and_commands_exposed" `
    ((Get-JsonValue $ownerRouteMapManifest "status" "") -eq "PASS" -and
        $ownerRoutes.Count -eq 3 -and
        $routesWithStatusCommand -eq 3 -and
        $routesWithSemanticPreflight -eq 3 -and
        $routesWithAutoAcceptance -eq 3 -and
        $routesWithHardValidation -eq 3) `
    "Dashboard must expose owner-return status, semantic preflight, auto acceptance, and hard validation commands for all owner routes."

Add-DashboardCheck "operator_preflight_matrix_actionable" `
    ($operatorPreflightMatrix.Count -eq 3 -and
        $preflightRowsWithContactAction -eq 3 -and
        $preflightRowsWithEvidenceAction -eq 3 -and
        $preflightRowsWithAcceptanceGate -eq 3) `
    "Dashboard must include a per-owner operator preflight matrix with contact, evidence, and gated acceptance actions."

Add-DashboardCheck "owner_contact_and_send_boundary_visible" `
    ((Get-JsonValue $sendReadinessManifest "status" "") -eq "PASS" -and
        (Get-JsonValue $sendReadinessManifest "sendReadinessStatus" "") -eq "BLOCKED_MISSING_OWNER_EMAILS" -and
        (Convert-ToInt (Get-JsonValue $sendReadinessManifest "missingOwnerContactCount" 0)) -eq 3 -and
        (Get-JsonValue $ownerInputRequestManifest "ownerInputRequestStatus" "") -eq "AWAITING_EXTERNAL_OWNER_INPUT") `
    "Dashboard must keep missing owner contacts, blocked sends, and awaiting-owner-input state visible."

Add-DashboardCheck "owner_return_status_still_read_only" `
    ((Get-JsonValue $ownerReturnStatusManifest "status" "") -eq "PASS" -and
        (Convert-ToBool (Get-JsonValue $ownerReturnStatusManifest "readOnly" $false)) -and
        (Get-JsonValue $ownerReturnStatusManifest "ownerReturnReadinessStatus" "") -eq "PENDING_EXTERNAL_EVIDENCE" -and
        (Get-JsonValue $ownerReturnStatusManifest "nextRequiredAction" "") -eq "collect_owner_response_bundle_zip" -and
        -not (Convert-ToBool (Get-JsonValue $ownerReturnStatusManifest "acceptanceRun" $true))) `
    "Dashboard must start with owner-return status and must not run acceptance."

Add-DashboardCheck "no_mail_no_acceptance_no_fixture_promotion" `
    (-not (Convert-ToBool (Get-JsonValue $firstTestableManifest "releasePipelineSendsEmail" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $firstTestableManifest "realHostProjectEvidenceAccepted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $firstTestableManifest "fixtureEvidencePromoted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $actionQueueManifest "progressNotificationEmailSent" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $actionQueueManifest "externalEvidenceAccepted" $true))) `
    "Dashboard generation must not send email, accept real evidence, or promote fixture evidence."

$failedChecks = @($checks | Where-Object { -not [bool]$_["passed"] })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$generatedFiles = @(
    (Convert-ToArtifactRelativePath $manifestFullPath),
    (Convert-ToArtifactRelativePath $reportFullPath)
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.first_testable_operator_dashboard.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    artifactDir = $artifactPath
    currentPhase = "first_testable_waiting_for_external_owner_evidence"
    pipelineStatus = [string](Get-JsonValue $pipelineManifest "status" "")
    pipelineStepCount = Convert-ToInt (Get-JsonValue $pipelineManifest "stepCount" 0)
    releaseGateStatus = [string](Get-JsonValue $releaseGateManifest "status" "")
    releaseRiskPolicyStatus = [string](Get-JsonValue $releaseRiskPolicyManifest "status" "")
    releaseEvidenceIndexStatus = [string](Get-JsonValue $releaseEvidenceIndexManifest "status" "")
    semanticFieldCheckCount = Convert-ToInt (Get-JsonValue $releaseEvidenceIndexManifest "semanticFieldCheckCount" 0)
    firstTestableStatus = [string](Get-JsonValue $firstTestableManifest "status" "")
    readyForOperatorTesting = Convert-ToBool (Get-JsonValue $firstTestableManifest "readyForOperatorTesting" $false)
    readyForCommercialCompletion = $false
    completionBoundary = "external_owner_evidence_required"
    ownerReturnReadinessStatus = [string](Get-JsonValue $ownerReturnStatusManifest "ownerReturnReadinessStatus" "")
    nextRequiredAction = [string](Get-JsonValue $ownerReturnStatusManifest "nextRequiredAction" "")
    nextSafeCommand = $nextZipLocalStatusCommand
    nextSemanticPreflightCommand = $nextZipLocalSemanticPreflightCommand
    nextAcceptanceCommandAfterStatusAndPreflight = $nextBundledAcceptanceCommand
    externalOwnerAreaCount = Convert-ToInt (Get-JsonValue $gapAnalysisManifest "externalRemainingWorkItemCount" 0)
    externalMissingFileCount = Convert-ToInt (Get-JsonValue $gapAnalysisManifest "externalRemainingMissingFileCount" 0)
    externalBlockingReasonCount = Convert-ToInt (Get-JsonValue $gapAnalysisManifest "externalRemainingBlockingReasonCount" 0)
    repoSideClosableGapCount = Convert-ToInt (Get-JsonValue $gapAnalysisManifest "repoSideClosableGapCount" 0)
    localProgressMailRemainingActionCount = Convert-ToInt (Get-JsonValue $actionQueueManifest "localProgressMailRemainingActionCount" 0)
    missingOwnerContactCount = Convert-ToInt (Get-JsonValue $sendReadinessManifest "missingOwnerContactCount" 0)
    sendReadinessStatus = [string](Get-JsonValue $sendReadinessManifest "sendReadinessStatus" "")
    ownerInputRequestStatus = [string](Get-JsonValue $ownerInputRequestManifest "ownerInputRequestStatus" "")
    ownerRoutes = @($ownerRoutes)
    operatorPreflightMatrixCount = [int]$operatorPreflightMatrix.Count
    operatorAcceptanceReadyCount = 0
    operatorBlockedBeforeAcceptanceCount = [int]$operatorPreflightMatrix.Count
    operatorPreflightMatrix = @($operatorPreflightMatrix)
    releasePipelineSendsEmail = $false
    realHostProjectEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "first_testable_operator_dashboard_only"
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles)
}

New-Item -ItemType Directory -Force (Split-Path $manifestFullPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 14 | Set-Content -Path $manifestFullPath -Encoding UTF8

$reportLines = @(
    "# AI TestPilot First Testable Operator Dashboard",
    "",
    "## Status",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Status | $status |",
    "| Current phase | first_testable_waiting_for_external_owner_evidence |",
    "| Ready for operator testing | $($manifest.readyForOperatorTesting) |",
    "| Ready for commercial completion | False |",
    "| Owner return readiness | $(Format-MarkdownCell $manifest.ownerReturnReadinessStatus) |",
    "| Next required action | $(Format-MarkdownCell $manifest.nextRequiredAction) |",
    "| External owner areas | $($manifest.externalOwnerAreaCount) |",
    "| Missing files | $($manifest.externalMissingFileCount) |",
    "| Blocking reasons | $($manifest.externalBlockingReasonCount) |",
    "| Repo-side closable gaps | $($manifest.repoSideClosableGapCount) |",
    "| Missing owner contacts | $($manifest.missingOwnerContactCount) |",
    "| Send readiness | $(Format-MarkdownCell $manifest.sendReadinessStatus) |",
    "| Local progress-mail action | $($manifest.localProgressMailRemainingActionCount) |",
    "",
    "## Start Here",
    "",
    "Run steps 3-5 from the artifact root directory that contains `production-handoff-export`. Run route-specific hard validation from the AITestPilot repo root.",
    "",
    "1. Send or route each owner packet listed below once the real owner contact is known.",
    "2. Collect a filled owner response bundle folder or zip.",
    "3. Run owner-return status first:",
    "",
    '```powershell',
    $nextZipLocalStatusCommand,
    '```',
    "",
    "4. If owner-return status reports a ready candidate, run semantic preflight:",
    "",
    '```powershell',
    $nextZipLocalSemanticPreflightCommand,
    '```',
    "",
    "5. Run bundled auto acceptance only after status and semantic preflight are ready with zero semantic failures:",
    "",
    '```powershell',
    $nextBundledAcceptanceCommand,
    '```',
    "",
    "6. Run the route-specific hard validation command from the AITestPilot repo root.",
    "",
    "## Owner Routes",
    "",
    "| Owner | Area | Contact | Send | Missing | Blockers | Bundle Area | Next Status Command | Hard Validation |",
    "| --- | --- | --- | --- | ---: | ---: | --- | --- | --- |"
)

foreach ($route in $ownerRoutes) {
    $reportLines += "| $(Format-MarkdownCell $route.owner) | $(Format-MarkdownCell $route.area) | $(Format-MarkdownCell $route.contactStatus) | $(Format-MarkdownCell $route.sendStatus) | $($route.missingFileCount) | $($route.blockingReasonCount) | $(Format-MarkdownCell $route.bundleAreaPath) | $(Format-MarkdownCell $route.ownerReturnStatusCommand) | $(Format-MarkdownCell $route.hardValidationCommand) |"
}

$reportLines += @(
    "",
    "## Operator Preflight Matrix",
    "",
    "| Owner | Contact Action | Evidence Action | Status Dir | Acceptance Gate | Hard Validation Dir |",
    "| --- | --- | --- | --- | --- | --- |"
)

foreach ($row in $operatorPreflightMatrix) {
    $reportLines += "| $(Format-MarkdownCell $row.owner) | $(Format-MarkdownCell $row.contactNextAction) | $(Format-MarkdownCell $row.evidenceNextAction) | $(Format-MarkdownCell $row.ownerReturnStatusWorkingDirectory) | $(Format-MarkdownCell $row.acceptanceGate) | $(Format-MarkdownCell $row.hardValidationWorkingDirectory) |"
}

$reportLines += @(
    "",
    "## Missing Evidence",
    "",
    "| Owner | Area | Missing Files | Blocking Reasons |",
    "| --- | --- | --- | --- |"
)

foreach ($route in $ownerRoutes) {
    $reportLines += "| $(Format-MarkdownCell $route.owner) | $(Format-MarkdownCell $route.area) | $(Format-MarkdownCell (Join-TextList $route.missingFiles)) | $(Format-MarkdownCell (Join-TextList $route.blockingReasons)) |"
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
    "- This dashboard is read-only.",
    "- It does not send email, accept returned evidence, or promote fixture evidence.",
    "- It does not reduce the three external owner areas, nine missing files, or eleven blockers.",
    "- The next real big node requires returned owner response bundle evidence."
)

$reportLines | Set-Content -Path $reportFullPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "First testable operator dashboard failed: $($failedChecks.name -join ', ')"
}

Write-Output "First testable operator dashboard manifest: $manifestFullPath"
Write-Output "First testable operator dashboard report: $reportFullPath"
Write-Output "PASS AI TestPilot first testable operator dashboard"
