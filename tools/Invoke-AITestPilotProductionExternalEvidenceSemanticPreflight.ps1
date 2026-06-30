[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ManifestPath,
    [string]$ReportPath,
    [string]$EvidenceRoot,
    [string]$OwnerResponseBundleDir,
    [string]$OwnerResponseBundleZipPath,
    [switch]$ContractFixtureMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-external-evidence-semantic-preflight-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-external-evidence-semantic-preflight.md"
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

function Assert-PathUnderTemp {
    param(
        [string]$Path,
        [string]$Label
    )

    $fullPath = Resolve-FullPath $Path
    if (-not $fullPath.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must stay under system temp for semantic preflight: $fullPath"
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

function Try-ReadJsonFile {
    param(
        [string]$Path,
        [string]$Label
    )

    try {
        return [ordered]@{
            ok = $true
            value = Read-JsonFile $Path $Label
            error = ""
        }
    }
    catch {
        return [ordered]@{
            ok = $false
            value = $null
            error = $_.Exception.Message
        }
    }
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

function Get-OwnerResponseBundleZipSafetyReport {
    param([string]$Path)

    $result = [ordered]@{
        inspected = $true
        safe = $false
        zipOpenSucceeded = $false
        entryCount = 0
        directoryEntryCount = 0
        unsafeEntryCount = 0
        duplicateEntryCount = 0
        unsafeEntries = @()
        duplicateEntries = @()
        safetyErrors = @()
    }

    try {
        Add-Type -AssemblyName System.IO.Compression | Out-Null
        Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
        $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    }
    catch {
        $result.safetyErrors = @("zip_open_failed")
        $result.unsafeEntries = @([ordered]@{
                name = [System.IO.Path]::GetFileName($Path)
                reasons = @($_.Exception.Message)
            })
        $result.unsafeEntryCount = 1
        return $result
    }

    $seen = @{}
    try {
        $result.zipOpenSucceeded = $true
        foreach ($entry in $archive.Entries) {
            $entryName = [string]$entry.FullName
            $result.entryCount += 1
            if ($entryName.EndsWith("/", [System.StringComparison]::Ordinal) -or
                $entryName.EndsWith("\", [System.StringComparison]::Ordinal)) {
                $result.directoryEntryCount += 1
            }

            $normalized = $entryName.Replace("\", "/")
            $reasons = @()
            if ([string]::IsNullOrWhiteSpace($normalized)) {
                $reasons += "empty_entry_name"
            }
            if ($normalized.StartsWith("/", [System.StringComparison]::Ordinal) -or
                $normalized.StartsWith("//", [System.StringComparison]::Ordinal)) {
                $reasons += "absolute_entry_path"
            }
            if ($normalized -match "^[A-Za-z]:") {
                $reasons += "drive_qualified_entry_path"
            }

            $segments = @($normalized -split "/" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if (@($segments | Where-Object { $_ -eq ".." }).Count -gt 0) {
                $reasons += "path_traversal_segment"
            }
            if (@($segments | Where-Object { $_ -eq "." }).Count -gt 0) {
                $reasons += "current_directory_segment"
            }
            if (@($segments | Where-Object { $_.Contains(":") }).Count -gt 0) {
                $reasons += "colon_in_entry_segment"
            }

            $canonical = $normalized.TrimStart("/")
            $canonicalKey = $canonical.ToLowerInvariant()
            if ($seen.ContainsKey($canonicalKey)) {
                $reasons += "duplicate_entry_path"
                $result.duplicateEntryCount += 1
                $result.duplicateEntries += $normalized
            }
            else {
                $seen[$canonicalKey] = $true
            }

            if ($reasons.Count -gt 0) {
                $result.unsafeEntryCount += 1
                $result.unsafeEntries += [ordered]@{
                    name = $entryName
                    reasons = @($reasons)
                }
            }
        }
    }
    finally {
        $archive.Dispose()
    }

    if ($result.entryCount -le 0) {
        $result.safetyErrors += "empty_zip"
    }
    if ($result.unsafeEntryCount -gt 0) {
        $result.safetyErrors += "unsafe_zip_entries"
    }
    if ($result.duplicateEntryCount -gt 0) {
        $result.safetyErrors += "duplicate_zip_entries"
    }

    $result.safe = ($result.safetyErrors.Count -eq 0)
    return $result
}

function Add-SemanticFinding {
    param(
        [string]$Area,
        [string]$Owner,
        [string]$FileName,
        [string]$Severity,
        [string]$Reason,
        [string]$Field = "",
        [string]$OwnerHint = ""
    )

    $script:semanticFindings.Add([ordered]@{
            area = $Area
            owner = $Owner
            file = $FileName
            severity = $Severity
            reason = $Reason
            field = $Field
            ownerHint = $OwnerHint
        }) | Out-Null
}

function Add-JsonBoolFailWhenFalse {
    param(
        [object]$Json,
        [string]$Area,
        [string]$Owner,
        [string]$FileName,
        [string]$Field,
        [string]$Reason
    )

    if (-not (Convert-ToBool (Get-JsonValue $Json $Field $false))) {
        Add-SemanticFinding $Area $Owner $FileName "FAIL" $Reason $Field "Return evidence generated from the real host project with this field true."
    }
}

function Add-JsonBoolFailWhenTrue {
    param(
        [object]$Json,
        [string]$Area,
        [string]$Owner,
        [string]$FileName,
        [string]$Field,
        [string]$Reason
    )

    if (Convert-ToBool (Get-JsonValue $Json $Field $false)) {
        Add-SemanticFinding $Area $Owner $FileName "FAIL" $Reason $Field "Return evidence generated from the real host project with this field false."
    }
}

function Test-FileContentSignals {
    param(
        [string]$Area,
        [string]$Owner,
        [string]$FileName,
        [string]$Path,
        [string]$Content
    )

    $jsonFile = $FileName.EndsWith(".json", [System.StringComparison]::OrdinalIgnoreCase)
    if ($jsonFile -and -not [bool]$ContractFixtureMode -and
        $Content -match "(?i)(fixture://|contract_fixture|accepted_readiness_contract_fixture|host_project_template|template_only)") {
        Add-SemanticFinding $Area $Owner $FileName "FAIL" "fixture_or_template_signal_detected" "content" "Export real host-project evidence instead of contract fixtures or template-only JSON."
    }

    if (-not [bool]$ContractFixtureMode -and
        $Content -match "(?i)(TODO|path\\to|example\.invalid|Replace this template|Your\.Game\.Tests|sample_fallback|SampleGameActionReplayDriver)") {
        Add-SemanticFinding $Area $Owner $FileName "FAIL" "placeholder_or_sample_signal_detected" "content" "Replace placeholders and sample driver references with concrete host-project values."
    }

    if ($Content -match "(?i)(Host project:\s*$|Owner:\s*$|Timestamp:\s*$)") {
        Add-SemanticFinding $Area $Owner $FileName "WARN" "fillable_markdown_field_appears_empty" "content" "Fill the owner, host project, and timestamp fields before final acceptance."
    }
}

function Test-ProductionDriverJson {
    param(
        [string]$Owner,
        [string]$FileName,
        [object]$Json
    )

    $area = "production_driver_binding"
    if ($FileName -eq "production-replay-integration-checklist.json") {
        if ((Get-JsonValue $Json "schemaVersion" "") -ne "ai-testpilot.production_replay_integration.v1") {
            Add-SemanticFinding $area $Owner $FileName "FAIL" "driver_checklist_schema_mismatch" "schemaVersion" "Return the production replay integration checklist generated by the current host-project kit."
        }
        if ((Get-JsonValue $Json "status" "") -ne "BOUND") {
            Add-SemanticFinding $area $Owner $FileName "FAIL" "driver_checklist_not_bound" "status" "Bind all required replay hooks before exporting evidence."
        }
        Add-JsonBoolFailWhenFalse $Json $area $Owner $FileName "realProjectBound" "production_driver_not_bound_to_real_project"
        Add-JsonBoolFailWhenFalse $Json $area $Owner $FileName "allRequiredHooksBound" "required_driver_hooks_not_bound"
        Add-JsonBoolFailWhenFalse $Json $area $Owner $FileName "requiredBindingMetadataComplete" "driver_binding_metadata_incomplete"
        if ((Convert-ToInt (Get-JsonValue $Json "requiredHookCount" 0)) -lt 5) {
            Add-SemanticFinding $area $Owner $FileName "FAIL" "required_driver_hook_count_too_low" "requiredHookCount" "Export the checklist after all five required handler hooks are configured."
        }
        if ((Convert-ToInt (Get-JsonValue $Json "boundRequiredHookCount" 0)) -lt 5) {
            Add-SemanticFinding $area $Owner $FileName "FAIL" "bound_driver_hook_count_too_low" "boundRequiredHookCount" "Bind all five required handler hooks."
        }
        if ((Convert-ToInt (Get-JsonValue $Json "unresolvedRequiredHookCount" 0)) -ne 0) {
            Add-SemanticFinding $area $Owner $FileName "FAIL" "unresolved_driver_hooks_present" "unresolvedRequiredHookCount" "Resolve every required replay hook before returning the bundle."
        }
    }
    elseif ($FileName -eq "repair-retest-manifest.json") {
        if ((Get-JsonValue $Json "status" "") -ne "PASS") {
            Add-SemanticFinding $area $Owner $FileName "FAIL" "repair_retest_not_pass" "status" "Run the host-project repair retest until the manifest reports PASS."
        }
        Add-JsonBoolFailWhenFalse $Json $area $Owner $FileName "retestPassed" "repair_retest_not_passed"
        Add-JsonBoolFailWhenTrue $Json $area $Owner $FileName "bugStillPresent" "bug_still_present_after_retest"
        if ((Convert-ToInt (Get-JsonValue $Json "replayedStepCount" 0)) -lt 5) {
            Add-SemanticFinding $area $Owner $FileName "FAIL" "replayed_step_count_too_low" "replayedStepCount" "Return a retest that replays the complete five-step business flow."
        }
        $state = Get-JsonValue $Json "businessReplayState" $null
        foreach ($counterName in @("accountPreparationCount", "loginCount", "sceneEntryCount", "rewardClaimCount", "fishingCastCount")) {
            if ((Convert-ToInt (Get-JsonValue $state $counterName 0)) -le 0) {
                Add-SemanticFinding $area $Owner $FileName "FAIL" "business_replay_counter_missing" $counterName "Run the full business replay flow against the host project."
            }
        }
        $driverSource = [string](Get-JsonValue $Json "gameReplayDriverSource" "")
        if (-not [bool]$ContractFixtureMode -and $driverSource -match "(?i)(sample|fallback)") {
            Add-SemanticFinding $area $Owner $FileName "FAIL" "sample_or_fallback_driver_source" "gameReplayDriverSource" "Use the host-project production replay driver, not a sample fallback."
        }
    }
    else {
        if ((Get-JsonValue $Json "status" "") -ne "PASS") {
            Add-SemanticFinding $area $Owner $FileName "FAIL" "driver_manifest_not_pass" "status" "Return PASS status for every driver evidence manifest."
        }
    }
}

function Test-ProductionLuaJson {
    param(
        [string]$Owner,
        [string]$FileName,
        [object]$Json
    )

    $area = "production_lua_patch_evidence"
    if ($FileName -ne "production-lua-patch-evidence.json") {
        return
    }

    if ((Get-JsonValue $Json "schemaVersion" "") -ne "aitestpilot.production_lua_patch_evidence.v1") {
        Add-SemanticFinding $area $Owner $FileName "FAIL" "lua_evidence_schema_mismatch" "schemaVersion" "Return production-lua-patch-evidence.json generated by the current owner kit."
    }
    if ((Get-JsonValue $Json "status" "") -ne "PASS") {
        Add-SemanticFinding $area $Owner $FileName "FAIL" "lua_evidence_not_pass" "status" "Run Lua analysis, patch, retest, and rollback verification until status is PASS."
    }
    if (-not [bool]$ContractFixtureMode) {
        Add-JsonBoolFailWhenTrue $Json $area $Owner $FileName "fixtureOnly" "lua_fixture_evidence_returned"
        Add-JsonBoolFailWhenFalse $Json $area $Owner $FileName "realHostProjectEvidence" "lua_real_host_project_evidence_missing"
        $evidenceType = [string](Get-JsonValue $Json "evidenceType" "")
        if ($evidenceType -match "(?i)(fixture|template)") {
            Add-SemanticFinding $area $Owner $FileName "FAIL" "lua_fixture_or_template_evidence_type" "evidenceType" "Export evidence from the real production Lua tree."
        }
        $analyzedLuaRoot = [string](Get-JsonValue $Json "analyzedLuaRoot" "")
        if ([string]::IsNullOrWhiteSpace($analyzedLuaRoot) -or $analyzedLuaRoot -match "(?i)(fixture://|path\\to|example|template)") {
            Add-SemanticFinding $area $Owner $FileName "FAIL" "lua_analyzed_root_not_real" "analyzedLuaRoot" "Point analyzedLuaRoot at the real production Lua root used for validation."
        }
    }

    foreach ($field in @(
            "realProductionLuaAnalyzed",
            "realProductionLuaPatched",
            "productionPatchApplied",
            "productionPatchValidated",
            "productionRetestPassed",
            "rollbackPlanGenerated",
            "rollbackVerified"
        )) {
        Add-JsonBoolFailWhenFalse $Json $area $Owner $FileName $field "lua_required_proof_false"
    }

    Add-JsonBoolFailWhenTrue $Json $area $Owner $FileName "packageRepositoryMutated" "package_repository_mutated_by_lua_evidence"
    Add-JsonBoolFailWhenFalse $Json $area $Owner $FileName "sourceControlCleanAfterValidation" "host_project_source_control_not_clean"
    if ((Convert-ToInt (Get-JsonValue $Json "changedFileCount" 0)) -le 0) {
        Add-SemanticFinding $area $Owner $FileName "FAIL" "lua_changed_file_count_missing" "changedFileCount" "Return evidence for at least one real production Lua change."
    }
    if ((Convert-ToInt (Get-JsonValue $Json "beforeFindingCount" 0)) -le 0) {
        Add-SemanticFinding $area $Owner $FileName "FAIL" "lua_before_finding_count_missing" "beforeFindingCount" "Return before/after evidence that proves the issue existed before patching."
    }
    if ((Convert-ToInt (Get-JsonValue $Json "afterFindingCount" 0)) -ne 0) {
        Add-SemanticFinding $area $Owner $FileName "FAIL" "lua_findings_remaining_after_patch" "afterFindingCount" "Resolve all findings before returning production Lua evidence."
    }
    if ((Convert-ToInt (Get-JsonValue $Json "afterHighRiskFindingCount" 0)) -ne 0) {
        Add-SemanticFinding $area $Owner $FileName "FAIL" "lua_high_risk_findings_remaining_after_patch" "afterHighRiskFindingCount" "Resolve all high-risk Lua findings before returning production Lua evidence."
    }
    if ((Convert-ToInt (Get-JsonValue $Json "blockingReasonCount" 0)) -ne 0) {
        Add-SemanticFinding $area $Owner $FileName "FAIL" "lua_blocking_reasons_present" "blockingReasonCount" "Clear Lua readiness blockers before returning the owner bundle."
    }
}

function Test-LiveModelJson {
    param(
        [string]$Owner,
        [string]$FileName,
        [object]$Json
    )

    $area = "live_model_endpoint_smoke"
    if ($FileName -eq "live-model-endpoint-smoke-manifest.json") {
        if ((Get-JsonValue $Json "schemaVersion" "") -ne "ai-testpilot.live_model_endpoint_smoke.v1") {
            Add-SemanticFinding $area $Owner $FileName "FAIL" "live_smoke_schema_mismatch" "schemaVersion" "Return the live model endpoint smoke manifest generated by the current kit."
        }
        if ((Get-JsonValue $Json "status" "") -ne "PASS") {
            Add-SemanticFinding $area $Owner $FileName "FAIL" "live_smoke_not_pass" "status" "Run the live endpoint smoke until the manifest reports PASS."
        }
        if ((Get-JsonValue $Json "endpointMode" "") -ne "live_http_endpoint") {
            Add-SemanticFinding $area $Owner $FileName "FAIL" "live_endpoint_mode_not_http" "endpointMode" "Use the real live HTTP model endpoint mode."
        }
        if ((Get-JsonValue $Json "clientType" "") -ne "ModelEndpointDecisionClient") {
            Add-SemanticFinding $area $Owner $FileName "FAIL" "live_client_type_mismatch" "clientType" "Use the production ModelEndpointDecisionClient path."
        }
        foreach ($field in @("endpointConfigured", "modelConfigured", "requestContainsActionSchema", "requestContainsAllowedActions", "responseValidated")) {
            Add-JsonBoolFailWhenFalse $Json $area $Owner $FileName $field "live_smoke_required_proof_false"
        }
        if (-not [bool]$ContractFixtureMode) {
            Add-JsonBoolFailWhenTrue $Json $area $Owner $FileName "fixtureOnly" "live_smoke_fixture_returned"
            Add-JsonBoolFailWhenTrue $Json $area $Owner $FileName "contractFixtureMode" "live_smoke_contract_fixture_returned"
            Add-JsonBoolFailWhenFalse $Json $area $Owner $FileName "realProviderAccessProven" "live_provider_access_not_proven"
            Add-JsonBoolFailWhenFalse $Json $area $Owner $FileName "liveSmokeExecuted" "live_smoke_not_executed"
            Add-JsonBoolFailWhenFalse $Json $area $Owner $FileName "productionLiveEndpointAccessProven" "production_live_endpoint_access_not_proven"
            if ((Get-JsonValue $Json "evidenceProvenance" "") -ne "direct_live_http_endpoint_pass") {
                Add-SemanticFinding $area $Owner $FileName "FAIL" "live_smoke_provenance_not_direct" "evidenceProvenance" "Return evidence from the direct live HTTP endpoint pass."
            }
        }
    }
    elseif ($FileName -eq "live-model-endpoint-decision-trace.json") {
        if ((Get-JsonValue $Json "schemaVersion" "") -ne "ai-testpilot.decision_trace.v1") {
            Add-SemanticFinding $area $Owner $FileName "FAIL" "live_trace_schema_mismatch" "schemaVersion" "Return the live model decision trace generated by the smoke run."
        }
        if ((Get-JsonValue $Json "status" "") -ne "PASS") {
            Add-SemanticFinding $area $Owner $FileName "FAIL" "live_trace_not_pass" "status" "Return a PASS decision trace from the live smoke."
        }
        if ((Get-JsonValue $Json "runId" "") -ne "LIVE-MODEL-ENDPOINT-SMOKE") {
            Add-SemanticFinding $area $Owner $FileName "FAIL" "live_trace_run_id_mismatch" "runId" "Return the trace from the LIVE-MODEL-ENDPOINT-SMOKE run."
        }
        if ([string]::IsNullOrWhiteSpace([string](Get-JsonValue $Json "requestJson" "")) -or
            [string]::IsNullOrWhiteSpace([string](Get-JsonValue $Json "responseJson" ""))) {
            Add-SemanticFinding $area $Owner $FileName "FAIL" "live_trace_request_or_response_missing" "requestJson/responseJson" "Return the request and response JSON captured by the live smoke."
        }
        if (-not [bool]$ContractFixtureMode) {
            Add-JsonBoolFailWhenTrue $Json $area $Owner $FileName "fixtureOnly" "live_trace_fixture_returned"
            Add-JsonBoolFailWhenTrue $Json $area $Owner $FileName "contractFixtureMode" "live_trace_contract_fixture_returned"
            Add-JsonBoolFailWhenFalse $Json $area $Owner $FileName "realProviderAccessProven" "live_trace_provider_access_not_proven"
            Add-JsonBoolFailWhenFalse $Json $area $Owner $FileName "liveSmokeExecuted" "live_trace_smoke_not_executed"
        }
    }
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$manifestOutputPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportOutputPath = Assert-PathUnderRepo $ReportPath "ReportPath"
New-Item -ItemType Directory -Force $evidenceBundlePath | Out-Null
New-Item -ItemType Directory -Force ([System.IO.Path]::GetDirectoryName($manifestOutputPath)) | Out-Null
New-Item -ItemType Directory -Force ([System.IO.Path]::GetDirectoryName($reportOutputPath)) | Out-Null

$semanticFindings = [System.Collections.Generic.List[object]]::new()
$zipSafetyReport = [ordered]@{
    inspected = $false
    safe = $true
    zipOpenSucceeded = $false
    entryCount = 0
    directoryEntryCount = 0
    unsafeEntryCount = 0
    duplicateEntryCount = 0
    unsafeEntries = @()
    duplicateEntries = @()
    safetyErrors = @()
}

if (-not [string]::IsNullOrWhiteSpace($OwnerResponseBundleZipPath)) {
    $ownerZipPath = Resolve-FullPath $OwnerResponseBundleZipPath
    if (-not (Test-Path $ownerZipPath)) {
        Add-SemanticFinding "external_evidence_bundle" "operator" ([System.IO.Path]::GetFileName($ownerZipPath)) "FAIL" "owner_response_bundle_zip_missing" "OwnerResponseBundleZipPath" "Provide an existing filled owner response bundle zip."
    }
    else {
        $zipSafetyReport = Get-OwnerResponseBundleZipSafetyReport $ownerZipPath
        if (-not [bool]$zipSafetyReport.safe) {
            Add-SemanticFinding "external_evidence_bundle" "operator" ([System.IO.Path]::GetFileName($ownerZipPath)) "FAIL" "owner_response_bundle_zip_unsafe" "OwnerResponseBundleZipPath" "Regenerate the owner response bundle zip without unsafe, duplicate, absolute, or traversal entries."
        }
        else {
            $zipHash = (Get-FileHash -LiteralPath $ownerZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $expandedZipRoot = Assert-PathUnderTemp (Join-Path $tempRoot "AITestPilot\production-external-evidence-semantic-preflight\owner-response-bundle-$zipHash") "OwnerResponseBundleZip extraction"
            if (Test-Path $expandedZipRoot) {
                Remove-Item -LiteralPath $expandedZipRoot -Recurse -Force
            }
            New-Item -ItemType Directory -Force $expandedZipRoot | Out-Null
            Expand-Archive -LiteralPath $ownerZipPath -DestinationPath $expandedZipRoot -Force
            $OwnerResponseBundleDir = $expandedZipRoot
        }
    }
}

$sourceKind = "default_inbox"
$sourceRootPath = Join-Path $evidenceBundlePath "production-external-evidence-inbox"
if (-not [string]::IsNullOrWhiteSpace($EvidenceRoot)) {
    $sourceKind = "external_evidence_root"
    $sourceRootPath = Resolve-FullPath $EvidenceRoot
}
if (-not [string]::IsNullOrWhiteSpace($OwnerResponseBundleDir)) {
    $sourceKind = "owner_response_bundle"
    $sourceRootPath = Resolve-FullPath $OwnerResponseBundleDir
}

$areaSpecs = @(
    [ordered]@{
        area = "production_driver_binding"
        owner = "host_project_gameplay_qa"
        directory = "production-driver-evidence"
        requiredFiles = @(
            "production-replay-integration-checklist.json",
            "repair-retest-manifest.json",
            "repair-driver-failure-manifest.json",
            "replay-profile-import-manifest.json"
        )
        ownerHint = ".\production-driver-binding-kit\Export-ProductionDriverEvidenceBundle.ps1 -EvidenceBundleDir `"path\to\release-evidence`""
    },
    [ordered]@{
        area = "production_lua_patch_evidence"
        owner = "host_project_lua_owner"
        directory = "production-lua-evidence"
        requiredFiles = @(
            "production-lua-patch-evidence.json",
            "production-lua-patch-retest-template.md",
            "production-lua-patch-rollback-plan-template.md"
        )
        ownerHint = ".\production-lua-patch-evidence-kit\Export-ProductionLuaPatchEvidenceBundle.ps1 -EvidenceBundleDir `"path\to\release-evidence`" -ProductionLuaEvidenceDir `"path\to\production-lua-evidence`""
    },
    [ordered]@{
        area = "live_model_endpoint_smoke"
        owner = "host_project_ai_platform"
        directory = "live-smoke-evidence"
        requiredFiles = @(
            "live-model-endpoint-smoke-manifest.json",
            "live-model-endpoint-decision-trace.json"
        )
        ownerHint = ".\live-model-endpoint-config-kit\Export-LiveModelEndpointSmokeEvidenceBundle.ps1 -EvidenceBundleDir `"path\to\release-evidence`" -LiveModelEndpointSmokeEvidenceDir `"path\to\live-smoke-evidence`""
    }
)

$areaStatuses = @()
$presentFileRecords = @()
$missingRequiredFileCount = 0
$extraFileCount = 0

foreach ($spec in $areaSpecs) {
    $area = [string]$spec.area
    $owner = [string]$spec.owner
    $areaDir = Join-Path $sourceRootPath ([string]$spec.directory)
    $presentFiles = @()
    $missingFiles = @()
    $areaExtraFiles = @()

    if (Test-Path $areaDir) {
        $requiredNames = @([string[]]$spec.requiredFiles)
        $areaExtraFiles = @(Get-ChildItem -LiteralPath $areaDir -File | Where-Object { $requiredNames -notcontains $_.Name } | ForEach-Object { $_.Name })
    }

    foreach ($fileName in @([string[]]$spec.requiredFiles)) {
        $filePath = Join-Path $areaDir $fileName
        if (-not (Test-Path $filePath)) {
            $missingFiles += $fileName
            $missingRequiredFileCount += 1
            Add-SemanticFinding $area $owner $fileName "FAIL" "required_external_evidence_file_missing" "file" ([string]$spec.ownerHint)
            continue
        }

        $presentFiles += $fileName
        $content = Get-Content -LiteralPath $filePath -Encoding UTF8 -Raw
        Test-FileContentSignals $area $owner $fileName $filePath $content

        $presentFileRecords += [ordered]@{
            area = $area
            owner = $owner
            file = $fileName
            path = $filePath
            byteLength = (Get-Item -LiteralPath $filePath).Length
            sha256 = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToLowerInvariant()
        }

        if ($fileName.EndsWith(".json", [System.StringComparison]::OrdinalIgnoreCase)) {
            $jsonResult = Try-ReadJsonFile $filePath "$area $fileName"
            if (-not [bool]$jsonResult.ok) {
                Add-SemanticFinding $area $owner $fileName "FAIL" "required_json_unreadable" "json" ([string]$jsonResult.error)
                continue
            }

            if ($area -eq "production_driver_binding") {
                Test-ProductionDriverJson $owner $fileName $jsonResult.value
            }
            elseif ($area -eq "production_lua_patch_evidence") {
                Test-ProductionLuaJson $owner $fileName $jsonResult.value
            }
            elseif ($area -eq "live_model_endpoint_smoke") {
                Test-LiveModelJson $owner $fileName $jsonResult.value
            }
        }
    }

    $areaFindings = @($semanticFindings | Where-Object { $_.area -eq $area })
    $areaFailCount = @($areaFindings | Where-Object { $_.severity -eq "FAIL" }).Count
    $areaWarnCount = @($areaFindings | Where-Object { $_.severity -eq "WARN" }).Count
    $areaStatus = "READY_FOR_ACCEPTANCE_CANDIDATE"
    if ($missingFiles.Count -gt 0) {
        $areaStatus = "PENDING_EXTERNAL_EVIDENCE"
    }
    elseif ($areaFailCount -gt 0) {
        $areaStatus = "NEEDS_OWNER_REPAIR"
    }
    elseif ($areaWarnCount -gt 0) {
        $areaStatus = "WARN_READY_FOR_OPERATOR_ACCEPTANCE"
    }

    $extraFileCount += $areaExtraFiles.Count
    $areaStatuses += [ordered]@{
        area = $area
        owner = $owner
        directory = [string]$spec.directory
        sourcePath = $areaDir
        requiredFiles = @([string[]]$spec.requiredFiles)
        presentFiles = @($presentFiles)
        missingFiles = @($missingFiles)
        extraFiles = @($areaExtraFiles)
        semanticStatus = $areaStatus
        failFindingCount = $areaFailCount
        warnFindingCount = $areaWarnCount
        ownerHint = [string]$spec.ownerHint
    }
}

$semanticFailCount = @($semanticFindings | Where-Object { $_.severity -eq "FAIL" }).Count
$semanticWarnCount = @($semanticFindings | Where-Object { $_.severity -eq "WARN" }).Count
$fixtureSignalCount = @($semanticFindings | Where-Object { $_.reason -match "(?i)fixture|template" }).Count
$placeholderSignalCount = @($semanticFindings | Where-Object { $_.reason -match "(?i)placeholder|sample" }).Count
$skippedStateCount = @($semanticFindings | Where-Object { $_.reason -match "(?i)skipped|pending|template_ready" }).Count
$missingExternalEvidenceAreaCount = @($areaStatuses | Where-Object { $_.missingFiles.Count -gt 0 }).Count
$ownerRepairRouteCount = @($areaStatuses | Where-Object { $_.failFindingCount -gt 0 -or $_.warnFindingCount -gt 0 }).Count
$allRequiredFilesPresent = ($missingRequiredFileCount -eq 0)
$readyForAcceptanceCandidate = ($allRequiredFilesPresent -and $semanticFailCount -eq 0 -and [bool]$zipSafetyReport.safe)

$semanticPreflightStatus = "READY_FOR_AUTO_ACCEPTANCE_CANDIDATE"
if (-not [bool]$zipSafetyReport.safe -or ($allRequiredFilesPresent -and $semanticFailCount -gt 0)) {
    $semanticPreflightStatus = "NEEDS_OWNER_REPAIR"
}
elseif (-not $allRequiredFilesPresent) {
    $semanticPreflightStatus = "PENDING_EXTERNAL_EVIDENCE"
}
elseif ($semanticWarnCount -gt 0) {
    $semanticPreflightStatus = "WARN_READY_FOR_OPERATOR_ACCEPTANCE"
}

$sourceFiles = @()
foreach ($sourceManifestName in @(
        "production-external-evidence-action-queue-probe-manifest.json",
        "production-external-evidence-gap-analysis-manifest.json",
        "production-external-evidence-inbox-manifest.json",
        "production-handoff-owner-response-bundle-kit-manifest.json"
    )) {
    $sourcePath = Join-Path $evidenceBundlePath $sourceManifestName
    if (Test-Path $sourcePath) {
        $sourceFiles += (Convert-ToEvidenceRelativePath $sourcePath)
    }
}

$checkList = @()
function Add-Check {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Message
    )

    $script:checkList += [ordered]@{
        name = $Name
        passed = $Passed
        message = $Message
    }
}

Add-Check "semantic_preflight_read_only" $true "Semantic preflight reads returned evidence only and does not run acceptance or hard validation."
Add-Check "area_contract_loaded" ($areaStatuses.Count -eq 3) "Semantic preflight must cover driver, Lua, and live-model external evidence areas."
Add-Check "required_file_contract_loaded" (@($areaSpecs | ForEach-Object { $_.requiredFiles }).Count -eq 9) "Semantic preflight must evaluate all nine required external evidence files."
Add-Check "missing_or_semantic_state_reported" (-not [string]::IsNullOrWhiteSpace($semanticPreflightStatus)) "Semantic preflight must report pending, repair, warn, or candidate-ready state."
Add-Check "no_acceptance_side_effects" $true "Semantic preflight must not accept evidence, promote fixtures, or send email."

$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestOutputPath),
    (Convert-ToEvidenceRelativePath $reportOutputPath)
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_external_evidence_semantic_preflight.v1"
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    evidenceBundleDir = $evidenceBundlePath
    sourceKind = $sourceKind
    sourcePath = $sourceRootPath
    contractFixtureMode = [bool]$ContractFixtureMode
    readOnly = $true
    acceptanceRun = $false
    hardValidationRun = $false
    releasePipelineSendsEmail = $false
    emailSent = $false
    realHostProjectEvidenceAccepted = $false
    externalEvidenceAccepted = $false
    releasePipelineUsesFixture = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "production_external_evidence_semantic_preflight_only"
    semanticPreflightStatus = $semanticPreflightStatus
    readyForAcceptanceCandidate = [bool]$readyForAcceptanceCandidate
    readyForAutoAcceptanceCandidate = [bool]$readyForAcceptanceCandidate
    allRequiredExternalEvidenceFilesPresent = [bool]$allRequiredFilesPresent
    missingExternalEvidenceAreaCount = $missingExternalEvidenceAreaCount
    missingRequiredFileCount = $missingRequiredFileCount
    presentRequiredFileCount = $presentFileRecords.Count
    extraFileCount = $extraFileCount
    semanticFailCount = $semanticFailCount
    semanticWarnCount = $semanticWarnCount
    fixtureSignalCount = $fixtureSignalCount
    placeholderSignalCount = $placeholderSignalCount
    skippedStateCount = $skippedStateCount
    ownerRepairRouteCount = $ownerRepairRouteCount
    ownerResponseBundleZipInspected = [bool]$zipSafetyReport.inspected
    zipSafe = [bool]$zipSafetyReport.safe
    zipOpenSucceeded = [bool]$zipSafetyReport.zipOpenSucceeded
    zipEntryCount = [int]$zipSafetyReport.entryCount
    zipUnsafeEntryCount = [int]$zipSafetyReport.unsafeEntryCount
    zipDuplicateEntryCount = [int]$zipSafetyReport.duplicateEntryCount
    zipSafetyErrors = @($zipSafetyReport.safetyErrors)
    zipUnsafeEntries = @($zipSafetyReport.unsafeEntries)
    areaStatuses = @($areaStatuses)
    presentFiles = @($presentFileRecords)
    actionItems = @($semanticFindings)
    checkCount = $checkList.Count
    failedCheckCount = @($checkList | Where-Object { -not (Convert-ToBool (Get-JsonValue $_ "passed" $false)) }).Count
    checks = @($checkList)
    sourceFiles = @($sourceFiles)
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles)
}

$reportStatus = Get-JsonValue $manifest "status" ""
$reportSemanticPreflightStatus = Get-JsonValue $manifest "semanticPreflightStatus" ""
$reportSourceKind = Get-JsonValue $manifest "sourceKind" ""
$reportContractFixtureMode = Get-JsonValue $manifest "contractFixtureMode" $false
$reportReadyForAcceptanceCandidate = Get-JsonValue $manifest "readyForAcceptanceCandidate" $false
$reportPresentRequiredFileCount = Get-JsonValue $manifest "presentRequiredFileCount" 0
$reportMissingRequiredFileCount = Get-JsonValue $manifest "missingRequiredFileCount" 0
$reportSemanticFailCount = Get-JsonValue $manifest "semanticFailCount" 0
$reportSemanticWarnCount = Get-JsonValue $manifest "semanticWarnCount" 0
$reportAcceptanceRun = Get-JsonValue $manifest "acceptanceRun" $false
$reportRealHostProjectEvidenceAccepted = Get-JsonValue $manifest "realHostProjectEvidenceAccepted" $false
$reportZipInspected = Get-JsonValue $manifest "ownerResponseBundleZipInspected" $false
$reportZipSafe = Get-JsonValue $manifest "zipSafe" $false
$reportZipEntryCount = Get-JsonValue $manifest "zipEntryCount" 0
$reportZipUnsafeEntryCount = Get-JsonValue $manifest "zipUnsafeEntryCount" 0
$reportZipDuplicateEntryCount = Get-JsonValue $manifest "zipDuplicateEntryCount" 0

$reportLines = @(
    "# Production External Evidence Semantic Preflight",
    "",
    "- Status: $reportStatus",
    "- Semantic preflight status: $reportSemanticPreflightStatus",
    "- Source kind: $reportSourceKind",
    "- Contract fixture mode: $reportContractFixtureMode",
    "- Ready for acceptance candidate: $reportReadyForAcceptanceCandidate",
    "- Required files present: $reportPresentRequiredFileCount / 9",
    "- Missing files: $reportMissingRequiredFileCount",
    "- Semantic FAIL/WARN: $reportSemanticFailCount / $reportSemanticWarnCount",
    "- Acceptance run: $reportAcceptanceRun",
    "- Real host-project evidence accepted: $reportRealHostProjectEvidenceAccepted",
    "",
    "## Area Status",
    "",
    "| Area | Owner | Status | Present | Missing | FAIL | WARN |",
    "| --- | --- | --- | ---: | ---: | ---: | ---: |"
)

foreach ($areaStatus in $areaStatuses) {
    $presentFiles = @(Get-JsonValue $areaStatus "presentFiles" @())
    $missingFiles = @(Get-JsonValue $areaStatus "missingFiles" @())
    $areaName = Get-JsonValue $areaStatus "area" ""
    $areaOwner = Get-JsonValue $areaStatus "owner" ""
    $areaSemanticStatus = Get-JsonValue $areaStatus "semanticStatus" ""
    $areaFailFindingCount = Get-JsonValue $areaStatus "failFindingCount" 0
    $areaWarnFindingCount = Get-JsonValue $areaStatus "warnFindingCount" 0
    $reportLines += "| $(Format-MarkdownCell $areaName) | $(Format-MarkdownCell $areaOwner) | $(Format-MarkdownCell $areaSemanticStatus) | $($presentFiles.Count) | $($missingFiles.Count) | $areaFailFindingCount | $areaWarnFindingCount |"
}

$reportLines += @(
    "",
    "## Action Items",
    "",
    "| Area | Owner | Severity | File | Reason | Field | Owner hint |",
    "| --- | --- | --- | --- | --- | --- | --- |"
)

foreach ($finding in $semanticFindings) {
    $findingArea = Get-JsonValue $finding "area" ""
    $findingOwner = Get-JsonValue $finding "owner" ""
    $findingSeverity = Get-JsonValue $finding "severity" ""
    $findingFile = Get-JsonValue $finding "file" ""
    $findingReason = Get-JsonValue $finding "reason" ""
    $findingField = Get-JsonValue $finding "field" ""
    $findingOwnerHint = Get-JsonValue $finding "ownerHint" ""
    $reportLines += "| $(Format-MarkdownCell $findingArea) | $(Format-MarkdownCell $findingOwner) | $(Format-MarkdownCell $findingSeverity) | $(Format-MarkdownCell $findingFile) | $(Format-MarkdownCell $findingReason) | $(Format-MarkdownCell $findingField) | $(Format-MarkdownCell $findingOwnerHint) |"
}

if ($semanticFindings.Count -eq 0) {
    $reportLines += "| (none) | (none) | (none) | (none) | (none) | (none) | (none) |"
}

$reportLines += @(
    "",
    "## Zip Safety",
    "",
    "- Inspected: $reportZipInspected",
    "- Safe: $reportZipSafe",
    "- Entry count: $reportZipEntryCount",
    "- Unsafe entries: $reportZipUnsafeEntryCount",
    "- Duplicate entries: $reportZipDuplicateEntryCount"
)

$manifest | ConvertTo-Json -Depth 100 | Set-Content -Path $manifestOutputPath -Encoding UTF8
$reportLines | Set-Content -Path $reportOutputPath -Encoding UTF8

Write-Output $manifestOutputPath
