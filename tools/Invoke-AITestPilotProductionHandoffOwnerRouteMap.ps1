[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
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

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-handoff-owner-route-map-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-handoff-owner-route-map.md"
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

    return $fullPath.Substring($evidenceBundlePath.Length).TrimStart([char[]]@("\", "/")).Replace("\", "/")
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

function Join-TextList {
    param([object[]]$Values)

    $items = @($Values | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($items.Count -eq 0) {
        return "(none)"
    }

    return [string]::Join(", ", $items)
}

function Get-RouteKey {
    param(
        [string]$Owner,
        [string]$Area
    )

    return "$Owner|$Area"
}

function Add-RouteCheck {
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

function Test-StringSetEqual {
    param(
        [string[]]$Left,
        [string[]]$Right
    )

    $leftItems = @($Left | Sort-Object)
    $rightItems = @($Right | Sort-Object)
    if ($leftItems.Count -ne $rightItems.Count) {
        return $false
    }

    for ($i = 0; $i -lt $leftItems.Count; $i++) {
        if ($leftItems[$i] -ne $rightItems[$i]) {
            return $false
        }
    }

    return $true
}

function New-RouteMap {
    param(
        [object[]]$ActionItems,
        [object[]]$GapItems,
        [object[]]$ContactStatuses,
        [object[]]$SendEntries,
        [object[]]$InboxAreas
    )

    $gapByKey = @{}
    foreach ($gap in $GapItems) {
        $gapByKey[(Get-RouteKey ([string](Get-JsonValue $gap "owner" "")) ([string](Get-JsonValue $gap "area" "")))] = $gap
    }

    $contactByKey = @{}
    foreach ($contact in $ContactStatuses) {
        $contactByKey[(Get-RouteKey ([string](Get-JsonValue $contact "owner" "")) ([string](Get-JsonValue $contact "area" "")))] = $contact
    }

    $sendByKey = @{}
    foreach ($send in $SendEntries) {
        $sendByKey[(Get-RouteKey ([string](Get-JsonValue $send "owner" "")) ([string](Get-JsonValue $send "area" "")))] = $send
    }

    $inboxByKey = @{}
    foreach ($inbox in $InboxAreas) {
        $inboxByKey[(Get-RouteKey ([string](Get-JsonValue $inbox "owner" "")) ([string](Get-JsonValue $inbox "area" "")))] = $inbox
    }

    $routes = @()
    foreach ($item in $ActionItems) {
        $owner = [string](Get-JsonValue $item "owner" "")
        $area = [string](Get-JsonValue $item "area" "")
        $key = Get-RouteKey $owner $area
        $gap = if ($gapByKey.ContainsKey($key)) { $gapByKey[$key] } else { $null }
        $contact = if ($contactByKey.ContainsKey($key)) { $contactByKey[$key] } else { $null }
        $send = if ($sendByKey.ContainsKey($key)) { $sendByKey[$key] } else { $null }
        $inbox = if ($inboxByKey.ContainsKey($key)) { $inboxByKey[$key] } else { $null }

        $requiredFiles = @(Convert-ToArray (Get-JsonValue $item "requiredEvidenceFiles" @()) | ForEach-Object { [string]$_ })
        $missingFiles = @(Convert-ToArray (Get-JsonValue $item "missingFiles" @()) | ForEach-Object { [string]$_ })
        $blockingReasons = @(Convert-ToArray (Get-JsonValue $item "remainingBlockingReasons" @()) | ForEach-Object { [string]$_ })
        $requiredFilesPath = [string](Get-JsonValue $item "ownerResponseBundleRequiredFilesPath" "")
        $requiredFilesFullPath = if ([string]::IsNullOrWhiteSpace($requiredFilesPath)) { "" } else { Join-Path $evidenceBundlePath $requiredFilesPath }
        $requiredFilesJson = $null
        if (-not [string]::IsNullOrWhiteSpace($requiredFilesFullPath) -and (Test-Path $requiredFilesFullPath)) {
            $requiredFilesJson = Read-JsonFile $requiredFilesFullPath "Owner response bundle required-files.json"
        }
        $requiredJsonFiles = @(Convert-ToArray (Get-JsonValue $requiredFilesJson "requiredEvidenceFiles" @()) | ForEach-Object { [string]$_ })

        $exportHelperCommand = ""
        if ($area -eq "production_driver_binding") {
            $exportHelperCommand = [string](Get-JsonValue $item "productionDriverEvidenceExportHelperCommand" "")
        }
        elseif ($area -eq "production_lua_patch_evidence") {
            $exportHelperCommand = [string](Get-JsonValue $item "productionLuaEvidenceExportHelperCommand" "")
        }
        elseif ($area -eq "live_model_endpoint_smoke") {
            $exportHelperCommand = [string](Get-JsonValue $item "liveModelSmokeEvidenceExportHelperCommand" "")
        }

        $semanticPreflightCommand = [string](Get-JsonValue $item "ownerResponseBundleZipSemanticPreflightCommand" "")
        $autoAcceptanceCommand = [string](Get-JsonValue $item "ownerResponseBundleZipAutoAcceptanceCommand" "")
        $hardValidationCommand = [string](Get-JsonValue $item "hardValidationCommand" "")
        $routeChecks = @()
        $routeChecks += [ordered]@{
            name = "gap_matches_action_queue"
            passed = ($null -ne $gap -and
                (Test-StringSetEqual $missingFiles @(Convert-ToArray (Get-JsonValue $gap "missingFiles" @()) | ForEach-Object { [string]$_ })) -and
                (Test-StringSetEqual $blockingReasons @(Convert-ToArray (Get-JsonValue $gap "blockingReasons" @()) | ForEach-Object { [string]$_ })))
        }
        $routeChecks += [ordered]@{
            name = "contact_matches_action_queue"
            passed = ($null -ne $contact -and
                [string](Get-JsonValue $contact "ownerPacketPath" "") -eq [string](Get-JsonValue $item "ownerPacketPath" "") -and
                [string](Get-JsonValue $contact "dispatchDraftPath" "") -eq [string](Get-JsonValue $item "dispatchDraftPath" "") -and
                [string](Get-JsonValue $contact "status" "") -eq [string](Get-JsonValue $item "contactStatus" ""))
        }
        $routeChecks += [ordered]@{
            name = "send_matches_action_queue"
            passed = ($null -ne $send -and
                [string](Get-JsonValue $send "ownerPacketPath" "") -eq [string](Get-JsonValue $item "ownerPacketPath" "") -and
                [string](Get-JsonValue $send "bodyFile" "") -eq [string](Get-JsonValue $item "dispatchDraftPath" "") -and
                [string](Get-JsonValue $send "sendStatus" "") -eq [string](Get-JsonValue $item "sendStatus" "") -and
                (Test-StringSetEqual $requiredFiles @(Convert-ToArray (Get-JsonValue $send "requiredEvidenceFiles" @()) | ForEach-Object { [string]$_ })))
        }
        $routeChecks += [ordered]@{
            name = "inbox_matches_action_queue"
            passed = ($null -ne $inbox -and
                [string](Get-JsonValue $inbox "inboxDirectory" "") -eq [string](Get-JsonValue $item "inboxDirectory" "") -and
                [string](Get-JsonValue $inbox "packetPath" "") -eq [string](Get-JsonValue $item "ownerPacketPath" "") -and
                [string](Get-JsonValue $inbox "hardValidationCommand" "") -eq $hardValidationCommand -and
                (Test-StringSetEqual $requiredFiles @(Convert-ToArray (Get-JsonValue $inbox "requiredEvidenceFiles" @()) | ForEach-Object { [string]$_ })))
        }
        $routeChecks += [ordered]@{
            name = "required_files_json_matches_action_queue"
            passed = ($null -ne $requiredFilesJson -and
                [string](Get-JsonValue $requiredFilesJson "owner" "") -eq $owner -and
                [string](Get-JsonValue $requiredFilesJson "area" "") -eq $area -and
                [string](Get-JsonValue $requiredFilesJson "hardValidationCommand" "") -eq $hardValidationCommand -and
                (Test-StringSetEqual $requiredFiles $requiredJsonFiles))
        }
        $routeChecks += [ordered]@{
            name = "route_commands_present"
            passed = (-not [string]::IsNullOrWhiteSpace($exportHelperCommand) -and
                $semanticPreflightCommand.Contains("Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1") -and
                $semanticPreflightCommand.Contains("-OwnerResponseBundleZipPath") -and
                $autoAcceptanceCommand.Contains("Invoke-AITestPilotProductionExternalEvidenceAutoAcceptance.ps1") -and
                $autoAcceptanceCommand.Contains("-OwnerResponseBundleZipPath") -and
                $hardValidationCommand.Contains("Invoke-AITestPilotReleasePipeline.ps1"))
        }
        $routeChecks += [ordered]@{
            name = "semantic_preflight_before_auto_acceptance"
            passed = ($semanticPreflightCommand.Contains("SemanticPreflight") -and
                $autoAcceptanceCommand.Contains("AutoAcceptance") -and
                -not [string]::IsNullOrWhiteSpace($hardValidationCommand))
        }

        $routes += [ordered]@{
            owner = $owner
            area = $area
            status = [string](Get-JsonValue $item "status" "")
            contactStatus = [string](Get-JsonValue $item "contactStatus" "")
            sendStatus = [string](Get-JsonValue $item "sendStatus" "")
            dispatchStatus = [string](Get-JsonValue $item "dispatchStatus" "")
            ownerPacketPath = [string](Get-JsonValue $item "ownerPacketPath" "")
            dispatchDraftPath = [string](Get-JsonValue $item "dispatchDraftPath" "")
            ownerResponseBundleAreaPath = [string](Get-JsonValue $item "ownerResponseBundleAreaPath" "")
            ownerResponseBundleRequiredFilesPath = $requiredFilesPath
            inboxDirectory = [string](Get-JsonValue $item "inboxDirectory" "")
            missingFiles = @($missingFiles)
            missingFileCount = [int](Get-JsonValue $item "missingFileCount" $missingFiles.Count)
            blockingReasons = @($blockingReasons)
            blockingReasonCount = [int](Get-JsonValue $item "remainingBlockingReasonCount" $blockingReasons.Count)
            exportHelperCommand = $exportHelperCommand
            semanticPreflightCommand = $semanticPreflightCommand
            autoAcceptanceCommand = $autoAcceptanceCommand
            hardValidationCommand = $hardValidationCommand
            routeCheckCount = [int]$routeChecks.Count
            routeFailedCheckCount = [int]@($routeChecks | Where-Object { -not [bool]$_["passed"] }).Count
            checks = @($routeChecks)
        }
    }

    return @($routes)
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

$actionQueuePath = Join-Path $evidenceBundlePath "production-external-evidence-action-queue-manifest.json"
$gapAnalysisPath = Join-Path $evidenceBundlePath "production-external-evidence-gap-analysis-manifest.json"
$handoffPackagePath = Join-Path $evidenceBundlePath "production-handoff-package-manifest.json"
$contactReadinessPath = Join-Path $evidenceBundlePath "production-handoff-contact-readiness-manifest.json"
$sendReadinessPath = Join-Path $evidenceBundlePath "production-handoff-send-readiness-manifest.json"
$ownerResponseBundleKitPath = Join-Path $evidenceBundlePath "production-handoff-owner-response-bundle-kit-manifest.json"
$externalEvidenceInboxPath = Join-Path $evidenceBundlePath "production-external-evidence-inbox-manifest.json"
$remainingWorkSnapshotPath = Join-Path $evidenceBundlePath "release-progress-notification-outbox\remaining-work-snapshot.json"

$actionQueue = Read-JsonFile $actionQueuePath "Production external evidence action queue manifest"
$gapAnalysis = Read-JsonFile $gapAnalysisPath "Production external evidence gap analysis manifest"
$handoffPackage = Read-JsonFile $handoffPackagePath "Production handoff package manifest"
$contactReadiness = Read-JsonFile $contactReadinessPath "Production handoff contact readiness manifest"
$sendReadiness = Read-JsonFile $sendReadinessPath "Production handoff send readiness manifest"
$ownerResponseBundleKit = Read-JsonFile $ownerResponseBundleKitPath "Production handoff owner response bundle kit manifest"
$externalEvidenceInbox = Read-JsonFile $externalEvidenceInboxPath "Production external evidence inbox manifest"
$remainingWorkSnapshot = Read-JsonFile $remainingWorkSnapshotPath "Release progress notification remaining-work snapshot"

$actionItems = @(Convert-ToArray (Get-JsonValue $actionQueue "actionQueue" @()))
$gapItems = @(Convert-ToArray (Get-JsonValue $gapAnalysis "gapItems" @()))
$contactStatuses = @(Convert-ToArray (Get-JsonValue $contactReadiness "contactStatuses" @()))
$sendEntries = @(Convert-ToArray (Get-JsonValue $sendReadiness "sendEntries" @()))
$inboxAreas = @(Convert-ToArray (Get-JsonValue $externalEvidenceInbox "areaStatuses" @()))
$routes = @(New-RouteMap $actionItems $gapItems $contactStatuses $sendEntries $inboxAreas)

$checks = @()
$sourceStatusPassed = (Get-JsonValue $actionQueue "status" "") -eq "PASS" -and
    (Get-JsonValue $gapAnalysis "status" "") -eq "PASS" -and
    (Get-JsonValue $handoffPackage "status" "") -eq "PASS" -and
    (Get-JsonValue $contactReadiness "status" "") -eq "PASS" -and
    (Get-JsonValue $sendReadiness "status" "") -eq "PASS" -and
    (Get-JsonValue $ownerResponseBundleKit "status" "") -eq "PASS" -and
    (Get-JsonValue $externalEvidenceInbox "status" "") -eq "PASS"
Add-RouteCheck "owner_route_sources_passed" $sourceStatusPassed "Owner route map must read passing action queue, gap, handoff, contact, send, bundle kit, and inbox sources."

$externalWorkItemCount = Convert-ToInt (Get-JsonValue $gapAnalysis "externalRemainingWorkItemCount" 0)
$externalMissingFileCount = Convert-ToInt (Get-JsonValue $gapAnalysis "externalRemainingMissingFileCount" 0)
$externalBlockingReasonCount = Convert-ToInt (Get-JsonValue $gapAnalysis "externalRemainingBlockingReasonCount" 0)
$repoSideClosableGapCount = Convert-ToInt (Get-JsonValue $gapAnalysis "repoSideClosableGapCount" 0)
Add-RouteCheck "owner_route_remaining_counts" `
    ($routes.Count -eq 3 -and $externalWorkItemCount -eq 3 -and $externalMissingFileCount -eq 9 -and $externalBlockingReasonCount -eq 11 -and $repoSideClosableGapCount -eq 0) `
    "Owner route map must preserve the current three external work items, nine missing files, eleven blockers, and zero repo-side-closable gaps."

$routeFailedChecks = @($routes | Where-Object { [int](Get-JsonValue $_ "routeFailedCheckCount" 0) -ne 0 })
Add-RouteCheck "owner_route_cross_artifact_links" `
    ($routeFailedChecks.Count -eq 0) `
    "Every route must connect action queue, gap analysis, contact/send readiness, inbox, and required-files.json with matching owner/area, packet, required files, and commands."

$routeOwners = @($routes | ForEach-Object { [string](Get-JsonValue $_ "owner" "") })
$routeAreas = @($routes | ForEach-Object { [string](Get-JsonValue $_ "area" "") })
Add-RouteCheck "owner_route_area_coverage" `
    (($routeOwners | Sort-Object -Unique).Count -eq 3 -and
        ($routeAreas -contains "production_driver_binding") -and
        ($routeAreas -contains "production_lua_patch_evidence") -and
        ($routeAreas -contains "live_model_endpoint_smoke")) `
    "Owner route map must cover gameplay QA, Lua owner, and AI platform external-evidence areas exactly once."

$semanticPreflightCount = @($routes | Where-Object { ([string](Get-JsonValue $_ "semanticPreflightCommand" "")).Contains("Invoke-AITestPilotProductionExternalEvidenceSemanticPreflight.ps1") }).Count
$autoAcceptanceCount = @($routes | Where-Object { ([string](Get-JsonValue $_ "autoAcceptanceCommand" "")).Contains("Invoke-AITestPilotProductionExternalEvidenceAutoAcceptance.ps1") }).Count
$hardValidationCount = @($routes | Where-Object { ([string](Get-JsonValue $_ "hardValidationCommand" "")).Contains("Invoke-AITestPilotReleasePipeline.ps1") }).Count
$exportHelperCount = @($routes | Where-Object { -not [string]::IsNullOrWhiteSpace([string](Get-JsonValue $_ "exportHelperCommand" "")) }).Count
Add-RouteCheck "owner_route_command_coverage" `
    ($semanticPreflightCount -eq 3 -and $autoAcceptanceCount -eq 3 -and $hardValidationCount -eq 3 -and $exportHelperCount -eq 3) `
    "Every route must expose owner export helper, semantic preflight, auto acceptance, and hard validation commands."

$routeMissingFileCount = [int](($routes | ForEach-Object { Convert-ToInt (Get-JsonValue $_ "missingFileCount" 0) } | Measure-Object -Sum).Sum)
$routeBlockingReasonCount = [int](($routes | ForEach-Object { Convert-ToInt (Get-JsonValue $_ "blockingReasonCount" 0) } | Measure-Object -Sum).Sum)
Add-RouteCheck "owner_route_missing_blocker_totals" `
    ($routeMissingFileCount -eq $externalMissingFileCount -and $routeBlockingReasonCount -eq $externalBlockingReasonCount) `
    "Route-level missing file and blocker totals must match gap analysis."

Add-RouteCheck "owner_route_boundary_preserved" `
    (-not (Convert-ToBool (Get-JsonValue $actionQueue "releasePipelineSendsEmail" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $sendReadiness "automaticEmailSendReady" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $ownerResponseBundleKit "releasePipelineSendsEmail" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $externalEvidenceInbox "realHostProjectEvidenceAccepted" $true)) -and
        -not (Convert-ToBool (Get-JsonValue $gapAnalysis "fixtureEvidencePromoted" $true))) `
    "Owner route map must preserve no-send, no-real-host-evidence, and no-fixture-promotion boundaries."

$generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
$reportLines = @(
    "# AI TestPilot Production Handoff Owner Route Map",
    "",
    "Schema: ``aitestpilot.production_handoff_owner_route_map.v1``",
    "Generated at UTC: $generatedAtUtc",
    "",
    "## Summary",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Status | PREVIEW |",
    "| Owner routes | $($routes.Count) |",
    "| External work items | $externalWorkItemCount |",
    "| Missing files | $externalMissingFileCount |",
    "| Blocking reasons | $externalBlockingReasonCount |",
    "| Repo-side closable gaps | $repoSideClosableGapCount |",
    "| Command order | semantic preflight, auto acceptance after preflight passes, hard validation |",
    "",
    "## Routes",
    "",
    "| Owner | Area | Packet | Contact | Send | Missing | Blockers | Required Files | Semantic Preflight | Auto Acceptance | Hard Validation |",
    "| --- | --- | --- | --- | --- | ---: | ---: | --- | --- | --- | --- |"
)

foreach ($route in $routes) {
    $owner = Format-MarkdownCell (Get-JsonValue $route "owner" "")
    $area = Format-MarkdownCell (Get-JsonValue $route "area" "")
    $ownerPacketPath = Format-MarkdownCell (Get-JsonValue $route "ownerPacketPath" "")
    $contactStatus = Format-MarkdownCell (Get-JsonValue $route "contactStatus" "")
    $sendStatus = Format-MarkdownCell (Get-JsonValue $route "sendStatus" "")
    $missingFileCount = Get-JsonValue $route "missingFileCount" 0
    $blockingReasonCount = Get-JsonValue $route "blockingReasonCount" 0
    $missingFiles = Format-MarkdownCell (Join-TextList @(Get-JsonValue $route "missingFiles" @()))
    $semanticPreflightCommand = Format-MarkdownCell (Get-JsonValue $route "semanticPreflightCommand" "")
    $autoAcceptanceCommand = Format-MarkdownCell (Get-JsonValue $route "autoAcceptanceCommand" "")
    $hardValidationCommand = Format-MarkdownCell (Get-JsonValue $route "hardValidationCommand" "")
    $reportLines += "| $owner | $area | $ownerPacketPath | $contactStatus | $sendStatus | $missingFileCount | $blockingReasonCount | $missingFiles | $semanticPreflightCommand | $autoAcceptanceCommand | $hardValidationCommand |"
}

$reportLines += @(
    "",
    "## Checks",
    "",
    "| Check | Result | Message |",
    "| --- | --- | --- |"
)
foreach ($check in $checks) {
    $result = if ([bool]$check.passed) { "PASS" } else { "FAIL" }
    $reportLines += "| $(Format-MarkdownCell $check.name) | $result | $(Format-MarkdownCell $check.message) |"
}

$reportText = $reportLines -join [Environment]::NewLine
$reportContentValidated = $reportText.Contains("host_project_gameplay_qa") -and
    $reportText.Contains("host_project_lua_owner") -and
    $reportText.Contains("host_project_ai_platform") -and
    $reportText.Contains("semantic preflight, auto acceptance after preflight passes, hard validation") -and
    $reportText.Contains("Repo-side closable gaps") -and
    -not $reportText.Contains("System.Collections") -and
    -not $reportText.Contains("@{")
Add-RouteCheck "owner_route_report_content" $reportContentValidated "Owner route map Markdown must be readable and include every owner route."

$reportContentCheck = $checks[-1]
$reportContentResult = if ([bool]$reportContentCheck.passed) { "PASS" } else { "FAIL" }
$reportLines += "| $(Format-MarkdownCell $reportContentCheck.name) | $reportContentResult | $(Format-MarkdownCell $reportContentCheck.message) |"

$failedChecks = @($checks | Where-Object { -not [bool]$_["passed"] })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }
$reportLines[9] = "| Status | $(Format-MarkdownCell $status) |"

New-Item -ItemType Directory -Force (Split-Path $manifestFullPath -Parent) | Out-Null
New-Item -ItemType Directory -Force (Split-Path $reportFullPath -Parent) | Out-Null
$reportLines | Set-Content -Path $reportFullPath -Encoding UTF8

$sourceFiles = @(
    "production-external-evidence-action-queue-manifest.json",
    "production-external-evidence-gap-analysis-manifest.json",
    "production-handoff-package-manifest.json",
    "production-handoff-contact-readiness-manifest.json",
    "production-handoff-send-readiness-manifest.json",
    "production-handoff-owner-response-bundle-kit-manifest.json",
    "production-external-evidence-inbox-manifest.json",
    "release-progress-notification-outbox/remaining-work-snapshot.json"
)
$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestFullPath),
    (Convert-ToEvidenceRelativePath $reportFullPath)
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_owner_route_map.v1"
    status = $status
    generatedAtUtc = $generatedAtUtc
    evidenceBundleDir = $evidenceBundlePath
    ownerRouteCount = [int]$routes.Count
    externalRemainingWorkItemCount = [int]$externalWorkItemCount
    externalRemainingMissingFileCount = [int]$externalMissingFileCount
    externalRemainingBlockingReasonCount = [int]$externalBlockingReasonCount
    repoSideClosableGapCount = [int]$repoSideClosableGapCount
    matchedOwnerPacketCount = [int]@($routes | Where-Object { -not [string]::IsNullOrWhiteSpace([string](Get-JsonValue $_ "ownerPacketPath" "")) }).Count
    matchedDispatchDraftCount = [int]@($routes | Where-Object { -not [string]::IsNullOrWhiteSpace([string](Get-JsonValue $_ "dispatchDraftPath" "")) }).Count
    matchedContactRosterCount = [int]$contactStatuses.Count
    matchedSendReadinessCount = [int]$sendEntries.Count
    matchedOwnerResponseBundleAreaCount = [int]@($routes | Where-Object { -not [string]::IsNullOrWhiteSpace([string](Get-JsonValue $_ "ownerResponseBundleAreaPath" "")) }).Count
    matchedRequiredFilesJsonCount = [int]@($routes | Where-Object { -not [string]::IsNullOrWhiteSpace([string](Get-JsonValue $_ "ownerResponseBundleRequiredFilesPath" "")) }).Count
    semanticPreflightCommandCount = [int]$semanticPreflightCount
    autoAcceptanceCommandCount = [int]$autoAcceptanceCount
    hardValidationCommandCount = [int]$hardValidationCount
    exportHelperCommandCoverageCount = [int]$exportHelperCount
    routeMismatchCount = [int]$routeFailedChecks.Count
    requiredFileMismatchCount = [int]@($routes | Where-Object {
            @((Get-JsonValue $_ "checks" @()) | Where-Object { [string](Get-JsonValue $_ "name" "") -eq "required_files_json_matches_action_queue" -and -not [bool](Get-JsonValue $_ "passed" $false) }).Count -gt 0
        }).Count
    missingCommandCount = [int](3 - [Math]::Min($semanticPreflightCount, [Math]::Min($autoAcceptanceCount, $hardValidationCount)))
    routes = @($routes)
    releasePipelineSendsEmail = $false
    automaticEmailSendReady = $false
    realHostProjectEvidenceAccepted = $false
    externalEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "production_handoff_owner_route_map_only"
    reportGenerated = (Test-Path $reportFullPath)
    reportContentValidated = [bool]$reportContentValidated
    sourceFiles = @($sourceFiles)
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles + $sourceFiles)
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
}

$manifest | ConvertTo-Json -Depth 14 | Set-Content -Path $manifestFullPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Production handoff owner route map failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production handoff owner route map manifest: $manifestFullPath"
Write-Output "Production handoff owner route map report: $reportFullPath"
Write-Output "PASS AI TestPilot production handoff owner route map"
