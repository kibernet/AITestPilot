[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$IndexPath,
    [string]$ReportPath,
    [string]$ManifestPath,
    [string[]]$SourceManifestNames,
    [switch]$RequireProductionReplayDriverBound,
    [switch]$RequireProductionLuaPatched,
    [switch]$RequireLiveModelEndpointSmoke,
    [switch]$ContractFixtureMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($IndexPath)) {
    $IndexPath = Join-Path $EvidenceBundleDir "release-evidence-index.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "release-evidence-index.md"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "release-evidence-index-manifest.json"
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

function Get-JsonValue {
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

function Convert-ToArray {
    param([object]$Value)

    if ($null -eq $Value) {
        return @()
    }

    return @($Value)
}

function Convert-ToBool {
    param(
        [object]$Value,
        [bool]$DefaultValue = $false
    )

    if ($null -eq $Value) {
        return $DefaultValue
    }

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    $text = [string]$Value
    if ($text -ieq "true" -or $text -eq "1") {
        return $true
    }

    if ($text -ieq "false" -or $text -eq "0") {
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

function Test-StrictBoolEquals {
    param(
        [object]$Value,
        [bool]$ExpectedValue
    )

    if ($Value -is [bool]) {
        return [bool]$Value -eq $ExpectedValue
    }

    $text = [string]$Value
    if ($text -ieq "true" -or $text -eq "1") {
        return $true -eq $ExpectedValue
    }

    if ($text -ieq "false" -or $text -eq "0") {
        return $false -eq $ExpectedValue
    }

    return $false
}

function Convert-FieldValueForReport {
    param([object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [string]) {
        return $Value
    }

    return [string]$Value
}

function Convert-FieldValueForDefinitionLine {
    param([object]$Value)

    if ($null -eq $Value) {
        return "<null>"
    }

    $typeName = if ($Value -is [bool]) {
        "bool"
    }
    elseif ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) {
        "number"
    }
    else {
        "string"
    }

    $text = [string](Convert-FieldValueForReport $Value)
    $escaped = $text.Replace("\", "\\").Replace("`t", "\t").Replace("`r", "\r").Replace("`n", "\n")
    return "${typeName}:$escaped"
}

function Get-StringSha256 {
    param([string]$Text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        return -join ($hash | ForEach-Object { $_.ToString("x2") })
    }
    finally {
        $sha.Dispose()
    }
}

function Get-ReleaseEvidenceIndexScriptSha256 {
    $scriptPath = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
        $PSCommandPath
    }
    else {
        $MyInvocation.MyCommand.Path
    }

    return (Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256).Hash
}

function Get-ManifestObject {
    param([string]$FileName)

    $path = Join-Path $evidenceBundlePath $FileName
    if (-not (Test-Path $path)) {
        return $null
    }

    try {
        return Get-Content -Path $path -Encoding UTF8 -Raw | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function New-FieldCoverageCheck {
    param(
        [string]$ManifestName,
        [string]$FieldName,
        [string]$Operator,
        [object]$ExpectedValue,
        [string]$Label
    )

    $manifest = Get-ManifestObject $ManifestName
    $manifestExists = $null -ne $manifest
    $fieldExists = $false
    $actualValue = $null
    if ($manifestExists) {
        $property = $manifest.PSObject.Properties[$FieldName]
        if ($null -ne $property) {
            $fieldExists = $true
            $actualValue = $property.Value
        }
    }

    $passed = $false
    $failureKind = ""
    if (-not $manifestExists) {
        $failureKind = "manifest_missing"
    }
    elseif (-not $fieldExists) {
        $failureKind = "field_missing"
    }
    else {
        switch ($Operator) {
            "bool-eq" {
                $passed = Test-StrictBoolEquals $actualValue ([bool]$ExpectedValue)
            }
            "int-eq" {
                $passed = (Convert-ToInt $actualValue) -eq [int]$ExpectedValue
            }
            "int-ge" {
                $passed = (Convert-ToInt $actualValue) -ge [int]$ExpectedValue
            }
            "string-eq" {
                $passed = [string]$actualValue -eq [string]$ExpectedValue
            }
            "contains" {
                $passed = ([string]$actualValue).Contains([string]$ExpectedValue)
            }
            default {
                throw "Unsupported field coverage operator: $Operator"
            }
        }

        if (-not $passed) {
            $failureKind = "value_mismatch"
        }
    }

    return [ordered]@{
        manifestName = $ManifestName
        fieldName = $FieldName
        operator = $Operator
        expectedValue = (Convert-FieldValueForReport $ExpectedValue)
        actualValue = (Convert-FieldValueForReport $actualValue)
        label = $Label
        manifestExists = [bool]$manifestExists
        fieldExists = [bool]$fieldExists
        passed = [bool]$passed
        failureKind = $failureKind
    }
}

function New-ReleaseEvidenceFieldCoverage {
    $checks = @()
    $checks += New-FieldCoverageCheck "production-handoff-send-readiness-manifest.json" "sendReadinessStatus" "string-eq" "BLOCKED_MISSING_OWNER_EMAILS" "owner packet send readiness remains blocked without owner contacts"
    $checks += New-FieldCoverageCheck "production-handoff-send-readiness-manifest.json" "automaticEmailSendReady" "bool-eq" $false "owner packet automatic email send remains disabled"
    $checks += New-FieldCoverageCheck "production-handoff-send-readiness-manifest.json" "mailAuthorizationCheckedByPipeline" "bool-eq" $false "release pipeline does not check local mail auth"
    $checks += New-FieldCoverageCheck "production-handoff-send-readiness-manifest.json" "missingOwnerContactCount" "int-eq" 3 "default owner contact gap count stays explicit"
    $checks += New-FieldCoverageCheck "production-handoff-send-readiness-manifest.json" "releasePipelineUsesFixture" "bool-eq" $false "send readiness does not promote fixtures"

    $checks += New-FieldCoverageCheck "production-handoff-send-local-workflow-probe-manifest.json" "fakeAgentlyCliGenerated" "bool-eq" $true "owner packet local workflow uses fake CLI only"
    $checks += New-FieldCoverageCheck "production-handoff-send-local-workflow-probe-manifest.json" "prepareConfirmationTokenReturnedCount" "int-eq" 3 "owner packet local workflow returns one token per owner"
    $checks += New-FieldCoverageCheck "production-handoff-send-local-workflow-probe-manifest.json" "ownerPacketReceiptGeneratedCount" "int-eq" 3 "owner packet local workflow writes one receipt per owner"
    $checks += New-FieldCoverageCheck "production-handoff-send-local-workflow-probe-manifest.json" "ownerPacketReceiptRealDeliveryVerifiedCount" "int-eq" 0 "fake owner packet receipts do not claim delivery"
    $checks += New-FieldCoverageCheck "production-handoff-send-local-workflow-probe-manifest.json" "releasePipelineSendsEmail" "bool-eq" $false "release pipeline does not send owner packet email"
    $checks += New-FieldCoverageCheck "production-handoff-send-local-workflow-probe-manifest.json" "realOwnerPacketEmailSent" "bool-eq" $false "owner packet local workflow remains not real sent"
    $checks += New-FieldCoverageCheck "production-handoff-send-local-workflow-probe-manifest.json" "productionOutputBoundary" "string-eq" "owner_packet_local_send_workflow_probe_fake_cli_only" "owner packet local workflow boundary is fake CLI only"

    $checks += New-FieldCoverageCheck "production-handoff-owner-packet-dispatch-receipt-intake-probe-manifest.json" "fakeReceiptsRejected" "bool-eq" $true "owner packet fake workflow receipts are rejected"
    $checks += New-FieldCoverageCheck "production-handoff-owner-packet-dispatch-receipt-intake-probe-manifest.json" "fakeReceiptRejectedByIntake" "bool-eq" $true "owner packet intake rejects fake receipts"
    $checks += New-FieldCoverageCheck "production-handoff-owner-packet-dispatch-receipt-intake-probe-manifest.json" "fakeReceiptAcceptedByIntake" "bool-eq" $false "owner packet intake never accepts fake receipts"
    $checks += New-FieldCoverageCheck "production-handoff-owner-packet-dispatch-receipt-intake-probe-manifest.json" "fakeReceiptDetectedCount" "int-eq" 3 "owner packet fake receipt count remains visible"
    $checks += New-FieldCoverageCheck "production-handoff-owner-packet-dispatch-receipt-intake-probe-manifest.json" "contractOwnerPacketDispatchStatus" "string-eq" "CONTRACT_RECEIPTS_ACCEPTED_NOT_REAL_SEND" "contract owner packet receipts stay non-real"
    $checks += New-FieldCoverageCheck "production-handoff-owner-packet-dispatch-receipt-intake-probe-manifest.json" "queuedReceiptQueuedCount" "int-eq" 3 "queued owner packet receipts count as dispatch evidence"
    $checks += New-FieldCoverageCheck "production-handoff-owner-packet-dispatch-receipt-intake-probe-manifest.json" "realOwnerPacketEmailSent" "bool-eq" $false "owner packet receipt intake does not claim real send"

    $checks += New-FieldCoverageCheck "production-handoff-owner-packet-real-receipt-guard-probe-manifest.json" "confirmLocalOwnerPacketReceiptsSwitchAvailable" "bool-eq" $true "owner packet receipt guard exposes operator confirmation switch"
    $checks += New-FieldCoverageCheck "production-handoff-owner-packet-real-receipt-guard-probe-manifest.json" "unconfirmedOwnerPacketDispatchStatus" "string-eq" "VALID_RECEIPTS_PENDING_OPERATOR_REAL_SEND_CONFIRMATION" "valid receipts remain pending operator confirmation"
    $checks += New-FieldCoverageCheck "production-handoff-owner-packet-real-receipt-guard-probe-manifest.json" "unconfirmedOperatorRealSendConfirmed" "bool-eq" $false "unconfirmed owner packet receipts do not set operator confirmation"
    $checks += New-FieldCoverageCheck "production-handoff-owner-packet-real-receipt-guard-probe-manifest.json" "contractConfirmedOwnerPacketDispatchStatus" "string-eq" "CONTRACT_RECEIPTS_ACCEPTED_NOT_REAL_SEND" "contract confirmed receipts still remain non-real"
    $checks += New-FieldCoverageCheck "production-handoff-owner-packet-real-receipt-guard-probe-manifest.json" "realOwnerPacketEmailSent" "bool-eq" $false "owner packet receipt guard does not claim real email sent"

    $checks += New-FieldCoverageCheck "production-handoff-owner-response-bundle-kit-workflow-probe-manifest.json" "requiredEvidenceFileCount" "int-eq" 9 "owner response bundle kit requires all production evidence files"
    $checks += New-FieldCoverageCheck "production-handoff-owner-response-bundle-kit-workflow-probe-manifest.json" "emptyTemplateRejected" "bool-eq" $true "empty owner response template is rejected"
    $checks += New-FieldCoverageCheck "production-handoff-owner-response-bundle-kit-workflow-probe-manifest.json" "completeTemplateAccepted" "bool-eq" $true "complete owner response template is accepted"
    $checks += New-FieldCoverageCheck "production-handoff-owner-response-bundle-kit-workflow-probe-manifest.json" "semanticPreflightCommandsGenerated" "bool-eq" $true "owner kit generates semantic preflight commands"
    $checks += New-FieldCoverageCheck "production-handoff-owner-response-bundle-kit-workflow-probe-manifest.json" "semanticPreflightZipCommandDocumented" "bool-eq" $true "owner kit documents zip semantic preflight"
    $checks += New-FieldCoverageCheck "production-handoff-owner-response-bundle-kit-workflow-probe-manifest.json" "selfContainedSemanticPreflightReadOnly" "bool-eq" $true "self-contained semantic preflight is read-only"
    $checks += New-FieldCoverageCheck "production-handoff-owner-response-bundle-kit-workflow-probe-manifest.json" "selfContainedSemanticPreflightAcceptanceRun" "bool-eq" $false "self-contained semantic preflight does not accept evidence"
    $checks += New-FieldCoverageCheck "production-handoff-owner-response-bundle-kit-workflow-probe-manifest.json" "ownerResponseBundleZipEnvironmentVariable" "string-eq" "AITESTPILOT_OWNER_RESPONSE_BUNDLE_ZIP_PATH" "owner kit documents zip environment variable"

    $checks += New-FieldCoverageCheck "production-handoff-owner-input-request-pack-manifest.json" "ownerResponseBundleRouteCount" "int-eq" 3 "owner input request pack exposes one owner response bundle route per owner"
    $checks += New-FieldCoverageCheck "production-handoff-owner-input-request-pack-manifest.json" "ownerResponseBundleRequiredFilesPathCount" "int-eq" 3 "owner input request pack exposes required-files path per owner"
    $checks += New-FieldCoverageCheck "production-handoff-owner-input-request-pack-manifest.json" "ownerResponseBundleZipSemanticPreflightCommandCount" "int-eq" 3 "owner input request pack exposes zip semantic preflight per owner"
    $checks += New-FieldCoverageCheck "production-handoff-owner-input-request-pack-manifest.json" "ownerResponseBundleZipAutoAcceptanceCommandCount" "int-eq" 3 "owner input request pack exposes zip auto acceptance per owner"
    $checks += New-FieldCoverageCheck "production-handoff-owner-input-request-pack-manifest.json" "ownerResponseBundleExportHelperCommandCount" "int-eq" 3 "owner input request pack exposes export helper per owner"
    $checks += New-FieldCoverageCheck "production-handoff-owner-input-request-pack-manifest.json" "ownerResponseBundleSemanticPreflightBeforeAutoAcceptanceDocumented" "bool-eq" $true "owner input request pack documents semantic preflight before auto acceptance"
    $checks += New-FieldCoverageCheck "production-handoff-owner-input-request-pack-manifest.json" "ownerResponseBundleZipEnvironmentVariable" "string-eq" "AITESTPILOT_OWNER_RESPONSE_BUNDLE_ZIP_PATH" "owner input request pack preserves zip environment variable"

    $checks += New-FieldCoverageCheck "production-external-evidence-action-queue-probe-manifest.json" "pendingQueueItemSemanticPreflightCommandCount" "int-eq" 3 "pending action queue includes semantic preflight per owner area"
    $checks += New-FieldCoverageCheck "production-external-evidence-action-queue-probe-manifest.json" "postDispatchQueueItemAutoAcceptanceCommandCount" "int-eq" 3 "post-dispatch action queue includes auto acceptance per owner area"
    $checks += New-FieldCoverageCheck "production-external-evidence-action-queue-probe-manifest.json" "postDispatchQueueDriverExportHelperItemCount" "int-eq" 1 "action queue keeps driver export helper"
    $checks += New-FieldCoverageCheck "production-external-evidence-action-queue-probe-manifest.json" "postDispatchQueueLuaExportHelperItemCount" "int-eq" 1 "action queue keeps Lua export helper"
    $checks += New-FieldCoverageCheck "production-external-evidence-action-queue-probe-manifest.json" "postDispatchQueueLiveSmokeExportHelperItemCount" "int-eq" 1 "action queue keeps live smoke export helper"
    $checks += New-FieldCoverageCheck "production-external-evidence-action-queue-probe-manifest.json" "ownerResponseBundleZipEnvironmentVariable" "string-eq" "AITESTPILOT_OWNER_RESPONSE_BUNDLE_ZIP_PATH" "action queue preserves owner response bundle zip variable"
    $checks += New-FieldCoverageCheck "production-external-evidence-action-queue-probe-manifest.json" "releasePipelineSendsEmail" "bool-eq" $false "action queue probe keeps mail boundary"

    $checks += New-FieldCoverageCheck "production-handoff-export-manifest.json" "operatorActionNextStepsIncluded" "bool-eq" $true "handoff export includes operator next-steps checklist"
    $checks += New-FieldCoverageCheck "production-handoff-export-manifest.json" "operatorActionNextStepsContentValidated" "bool-eq" $true "handoff export validates operator next-steps content"
    $checks += New-FieldCoverageCheck "production-handoff-export-manifest.json" "operatorActionNextStepsPath" "contains" "operator-actions\NEXT-STEPS.md" "handoff export exposes the operator next-steps path"

    $checks += New-FieldCoverageCheck "production-external-evidence-gap-analysis-manifest.json" "externalRemainingWorkItemCount" "int-eq" 3 "gap analysis preserves three external owner work items"
    $checks += New-FieldCoverageCheck "production-external-evidence-gap-analysis-manifest.json" "externalRemainingMissingFileCount" "int-eq" 9 "gap analysis preserves nine missing evidence files"
    $checks += New-FieldCoverageCheck "production-external-evidence-gap-analysis-manifest.json" "externalRemainingBlockingReasonCount" "int-eq" 11 "gap analysis preserves eleven blocking reasons"
    $checks += New-FieldCoverageCheck "production-external-evidence-gap-analysis-manifest.json" "repoSideClosableGapCount" "int-eq" 0 "gap analysis does not claim repo-side closure"
    $checks += New-FieldCoverageCheck "production-external-evidence-gap-analysis-manifest.json" "releasePipelineSendsEmail" "bool-eq" $false "gap analysis keeps no-mail boundary"
    $checks += New-FieldCoverageCheck "production-external-evidence-gap-analysis-manifest.json" "realHostProjectEvidenceAccepted" "bool-eq" $false "gap analysis does not accept host evidence"

    $checks += New-FieldCoverageCheck "production-handoff-owner-route-map-manifest.json" "ownerRouteCount" "int-eq" 3 "owner route map preserves three owner routes"
    $checks += New-FieldCoverageCheck "production-handoff-owner-route-map-manifest.json" "externalRemainingMissingFileCount" "int-eq" 9 "owner route map preserves nine missing evidence files"
    $checks += New-FieldCoverageCheck "production-handoff-owner-route-map-manifest.json" "externalRemainingBlockingReasonCount" "int-eq" 11 "owner route map preserves eleven blockers"
    $checks += New-FieldCoverageCheck "production-handoff-owner-route-map-manifest.json" "repoSideClosableGapCount" "int-eq" 0 "owner route map does not claim repo-side closure"
    $checks += New-FieldCoverageCheck "production-handoff-owner-route-map-manifest.json" "semanticPreflightCommandCount" "int-eq" 3 "owner route map has semantic preflight per route"
    $checks += New-FieldCoverageCheck "production-handoff-owner-route-map-manifest.json" "autoAcceptanceCommandCount" "int-eq" 3 "owner route map has auto acceptance per route"
    $checks += New-FieldCoverageCheck "production-handoff-owner-route-map-manifest.json" "releasePipelineSendsEmail" "bool-eq" $false "owner route map keeps no-mail boundary"
    $checks += New-FieldCoverageCheck "production-handoff-owner-route-map-manifest.json" "realHostProjectEvidenceAccepted" "bool-eq" $false "owner route map does not accept host evidence"

    $checks += New-FieldCoverageCheck "release-progress-notification-outbox-manifest.json" "latestBigNodeName" "string-eq" "production_external_evidence_strict_payload_shape" "progress notification final outbox targets strict payload shape"
    $checks += New-FieldCoverageCheck "release-progress-notification-outbox-manifest.json" "requireStrictPayloadShapeLatestBigNode" "bool-eq" $true "progress notification final outbox requires strict payload shape latest node"
    $checks += New-FieldCoverageCheck "release-progress-notification-outbox-manifest.json" "productionExternalEvidenceStrictPayloadShapeAccepted" "bool-eq" $true "progress notification final outbox accepts strict payload shape node"
    $checks += New-FieldCoverageCheck "release-progress-notification-outbox-manifest.json" "suppressedSmallNodeCount" "int-eq" 8 "progress notification final outbox suppresses semantic preflight as small probe"
    $checks += New-FieldCoverageCheck "release-progress-notification-outbox-manifest.json" "ownerRouteMapProbeAccepted" "bool-eq" $true "progress notification final outbox requires owner route map probe"
    $checks += New-FieldCoverageCheck "release-progress-notification-remaining-work-snapshot-probe-manifest.json" "latestBigNodeName" "string-eq" "production_external_evidence_strict_payload_shape" "remaining-work snapshot probe verifies strict payload shape final refresh"
    $checks += New-FieldCoverageCheck "release-progress-notification-remaining-work-snapshot-probe-manifest.json" "requireStrictPayloadShapeLatestBigNode" "bool-eq" $true "remaining-work snapshot probe requires strict payload shape final refresh"
    $checks += New-FieldCoverageCheck "release-progress-notification-post-dispatch-snapshot-probe-manifest.json" "contractFixtureRejected" "bool-eq" $true "post-dispatch snapshot probe rejects contract fixture receipts"

    $checks += New-FieldCoverageCheck "production-external-evidence-semantic-preflight-probe-manifest.json" "readOnly" "bool-eq" $true "semantic preflight remains read-only"
    $checks += New-FieldCoverageCheck "production-external-evidence-semantic-preflight-probe-manifest.json" "acceptanceRun" "bool-eq" $false "semantic preflight does not run acceptance"
    $checks += New-FieldCoverageCheck "production-external-evidence-semantic-preflight-probe-manifest.json" "caseCount" "int-eq" 12 "semantic preflight covers all expected cases"
    $checks += New-FieldCoverageCheck "production-external-evidence-semantic-preflight-probe-manifest.json" "completeCandidateCaseCount" "int-eq" 4 "semantic preflight keeps four candidate-ready cases"
    $checks += New-FieldCoverageCheck "production-external-evidence-semantic-preflight-probe-manifest.json" "rejectedCaseCount" "int-eq" 8 "semantic preflight keeps eight rejected cases"
    $checks += New-FieldCoverageCheck "production-external-evidence-semantic-preflight-probe-manifest.json" "ownerResponseBundleZipReady" "bool-eq" $true "semantic preflight accepts complete owner response bundle zip"
    $checks += New-FieldCoverageCheck "production-external-evidence-semantic-preflight-probe-manifest.json" "unsafeOwnerResponseBundleZipRejected" "bool-eq" $true "semantic preflight rejects unsafe zips"
    $checks += New-FieldCoverageCheck "production-external-evidence-semantic-preflight-probe-manifest.json" "ownerResponseBundleZipCaseCount" "int-eq" 6 "semantic preflight covers six zip cases"
    $checks += New-FieldCoverageCheck "production-external-evidence-semantic-preflight-probe-manifest.json" "ownerResponseBundleZipSafeCaseCount" "int-eq" 5 "semantic preflight covers five safe zip cases"
    $checks += New-FieldCoverageCheck "production-external-evidence-semantic-preflight-probe-manifest.json" "ownerResponseBundleZipUnsafeCaseCount" "int-eq" 1 "semantic preflight covers one unsafe zip case"
    $checks += New-FieldCoverageCheck "production-external-evidence-semantic-preflight-probe-manifest.json" "partialBundleZipRejected" "bool-eq" $true "semantic preflight rejects partial zips"
    $checks += New-FieldCoverageCheck "production-external-evidence-semantic-preflight-probe-manifest.json" "semanticBadBundleZipRejected" "bool-eq" $true "semantic preflight rejects semantic-bad zips"
    $checks += New-FieldCoverageCheck "production-external-evidence-semantic-preflight-probe-manifest.json" "extraPayloadBundleRejected" "bool-eq" $true "semantic preflight rejects extra-payload owner bundles"
    $checks += New-FieldCoverageCheck "production-external-evidence-semantic-preflight-probe-manifest.json" "nestedPayloadBundleZipRejected" "bool-eq" $true "semantic preflight rejects nested-payload owner bundle zips"
    $checks += New-FieldCoverageCheck "production-external-evidence-semantic-preflight-probe-manifest.json" "payloadShapeRejectedCaseCount" "int-eq" 2 "semantic preflight covers two payload-shape rejected cases"
    $checks += New-FieldCoverageCheck "production-external-evidence-semantic-preflight-probe-manifest.json" "fixtureSignalRejectedWithoutContractMode" "bool-eq" $true "semantic preflight rejects fixture signals without contract mode"

    $checks += New-FieldCoverageCheck "production-external-evidence-owner-return-bundle-status-manifest.json" "readOnly" "bool-eq" $true "owner return status remains read-only"
    $checks += New-FieldCoverageCheck "production-external-evidence-owner-return-bundle-status-manifest.json" "ownerReturnReadinessStatus" "string-eq" "PENDING_EXTERNAL_EVIDENCE" "owner return status preserves current pending external evidence state"
    $checks += New-FieldCoverageCheck "production-external-evidence-owner-return-bundle-status-manifest.json" "ownerReturnBundleSourceKind" "string-eq" "none" "owner return status default has no supplied bundle source"
    $checks += New-FieldCoverageCheck "production-external-evidence-owner-return-bundle-status-manifest.json" "ownerReturnBundleDiscoveredFromEnvironment" "bool-eq" $false "owner return status default ignores absent environment discovery"
    $checks += New-FieldCoverageCheck "production-external-evidence-owner-return-bundle-status-manifest.json" "ownerResponseBundleDirEnvironmentVariable" "string-eq" "AITESTPILOT_OWNER_RESPONSE_BUNDLE_DIR" "owner return status documents owner response bundle dir environment variable"
    $checks += New-FieldCoverageCheck "production-external-evidence-owner-return-bundle-status-manifest.json" "semanticPreflightRun" "bool-eq" $false "owner return status default does not run semantic preflight"
    $checks += New-FieldCoverageCheck "production-external-evidence-owner-return-bundle-status-manifest.json" "readyForAcceptanceCandidate" "bool-eq" $false "owner return status default is not acceptance candidate-ready"
    $checks += New-FieldCoverageCheck "production-external-evidence-owner-return-bundle-status-manifest.json" "pendingOwnerPacketCount" "int-eq" 3 "owner return status preserves three pending owner packets"
    $checks += New-FieldCoverageCheck "production-external-evidence-owner-return-bundle-status-manifest.json" "remainingMissingFileCount" "int-eq" 9 "owner return status preserves nine missing files"
    $checks += New-FieldCoverageCheck "production-external-evidence-owner-return-bundle-status-manifest.json" "remainingBlockingReasonCount" "int-eq" 11 "owner return status preserves eleven blockers"
    $checks += New-FieldCoverageCheck "production-external-evidence-owner-return-bundle-status-manifest.json" "acceptanceRun" "bool-eq" $false "owner return status does not run acceptance"
    $checks += New-FieldCoverageCheck "production-external-evidence-owner-return-bundle-status-manifest.json" "realHostProjectEvidenceAccepted" "bool-eq" $false "owner return status does not accept host evidence"
    $checks += New-FieldCoverageCheck "production-external-evidence-owner-return-bundle-status-manifest.json" "productionOutputBoundary" "string-eq" "owner_return_bundle_status_only" "owner return status keeps read-only boundary"

    $checks += New-FieldCoverageCheck "production-external-evidence-owner-return-bundle-status-probe-manifest.json" "caseCount" "int-eq" 5 "owner return status probe covers pending, explicit zip, env zip, explicit-over-env, and repair cases"
    $checks += New-FieldCoverageCheck "production-external-evidence-owner-return-bundle-status-probe-manifest.json" "defaultPendingOwnerReturnStatus" "bool-eq" $true "owner return status probe verifies default pending state"
    $checks += New-FieldCoverageCheck "production-external-evidence-owner-return-bundle-status-probe-manifest.json" "ownerResponseBundleZipCandidateReady" "bool-eq" $true "owner return status probe verifies complete zip candidate readiness"
    $checks += New-FieldCoverageCheck "production-external-evidence-owner-return-bundle-status-probe-manifest.json" "envOwnerResponseBundleZipCandidateReady" "bool-eq" $true "owner return status probe verifies environment zip candidate readiness"
    $checks += New-FieldCoverageCheck "production-external-evidence-owner-return-bundle-status-probe-manifest.json" "explicitOwnerResponseBundleZipOverridesEnvironment" "bool-eq" $true "owner return status probe verifies explicit zip overrides environment discovery"
    $checks += New-FieldCoverageCheck "production-external-evidence-owner-return-bundle-status-probe-manifest.json" "explicitZipOverEnvSourceKind" "string-eq" "parameter:OwnerResponseBundleZipPath" "owner return status probe preserves explicit source kind over environment"
    $checks += New-FieldCoverageCheck "production-external-evidence-owner-return-bundle-status-probe-manifest.json" "extraPayloadOwnerResponseBundleNeedsRepair" "bool-eq" $true "owner return status probe verifies strict-payload repair routing"
    $checks += New-FieldCoverageCheck "production-external-evidence-owner-return-bundle-status-probe-manifest.json" "acceptanceRun" "bool-eq" $false "owner return status probe does not run acceptance"
    $checks += New-FieldCoverageCheck "production-external-evidence-owner-return-bundle-status-probe-manifest.json" "realHostProjectEvidenceAccepted" "bool-eq" $false "owner return status probe does not accept host evidence"

    $checks += New-FieldCoverageCheck "production-external-evidence-auto-acceptance-probe-manifest.json" "extraPayloadOwnerResponseBundleRejected" "bool-eq" $true "auto acceptance rejects extra-payload owner bundles before acceptance"

    $checks += New-FieldCoverageCheck "release-risk-policy-manifest.json" "productionHandoffOwnerPacketDispatchReceiptIntakeProbeAccepted" "bool-eq" $true "risk policy accepts owner packet receipt intake"
    $checks += New-FieldCoverageCheck "release-risk-policy-manifest.json" "productionHandoffOwnerPacketRealReceiptGuardProbeAccepted" "bool-eq" $true "risk policy accepts owner packet real receipt guard"
    $checks += New-FieldCoverageCheck "release-risk-policy-manifest.json" "productionExternalEvidenceGapAnalysisRepoSideClosableGapCount" "int-eq" 0 "risk policy preserves repo-side closure count"

    return @($checks)
}

function Test-StatusAccepted {
    param(
        [string]$ManifestName,
        [string]$Status,
        [bool]$LiveModelEndpointSmokeProvenanceAccepted = $false,
        [bool]$LiveModelEndpointSmokeContractFixtureAccepted = $false
    )

    if ($ManifestName -eq "live-model-endpoint-smoke-manifest.json" -and
        [bool]$RequireLiveModelEndpointSmoke) {
        return ($Status -eq "PASS" -and (
            [bool]$LiveModelEndpointSmokeProvenanceAccepted -or
            ([bool]$ContractFixtureMode -and [bool]$LiveModelEndpointSmokeContractFixtureAccepted)
        ))
    }

    if ($Status -eq "PASS") {
        return $true
    }

    if ($ManifestName -eq "live-model-endpoint-smoke-manifest.json" -and
        $Status -eq "SKIPPED" -and
        -not [bool]$RequireLiveModelEndpointSmoke) {
        return $true
    }

    return $false
}

function Read-ManifestEntry {
    param(
        [string]$FileName,
        [bool]$SourceManifest
    )

    $path = Join-Path $evidenceBundlePath $FileName
    $exists = Test-Path $path
    $parseable = $false
    $manifest = $null
    $parseError = ""
    $sourceManifestSha256 = ""

    if ($exists) {
        $sourceManifestSha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        try {
            $manifest = Get-Content -Path $path -Encoding UTF8 -Raw | ConvertFrom-Json
            $parseable = $true
        }
        catch {
            $parseError = $_.Exception.Message
        }
    }

    $schemaVersion = ""
    $status = ""
    $allowRelease = $null
    $blockingReasonCount = 0
    $failedReasonCount = 0
    $listedFiles = @()
    $listedFileCount = 0
    $listedFilePresentCount = 0
    $missingListedFiles = @()
    $liveModelEndpointSmokeManifest = $FileName -eq "live-model-endpoint-smoke-manifest.json"
    $liveModelEndpointSmokeFixtureOnly = $null
    $liveModelEndpointSmokeContractFixtureMode = $null
    $liveModelEndpointSmokeRealProviderAccessProven = $null
    $liveModelEndpointSmokeProductionLiveEndpointAccessProven = $null
    $liveModelEndpointSmokeExecuted = $null
    $liveModelEndpointSmokeProvenanceAccepted = $false
    $liveModelEndpointSmokeContractFixtureAccepted = $false

    if ($parseable) {
        $schemaVersion = [string](Get-JsonValue $manifest "schemaVersion" "")
        $status = [string](Get-JsonValue $manifest "status" "")
        $allowRelease = Get-JsonValue $manifest "allowRelease" $null
        $blockingReasonCount = Convert-ToInt (Get-JsonValue $manifest "blockingReasonCount" 0)
        $failedReasonCount = Convert-ToInt (Get-JsonValue $manifest "failedReasonCount" 0)
        $listedFiles = @(Convert-ToArray (Get-JsonValue $manifest "files" $null))
        $listedFileCount = $listedFiles.Count

        foreach ($listedFile in $listedFiles) {
            $listedPath = Join-Path $evidenceBundlePath ([string]$listedFile)
            if (Test-Path $listedPath) {
                $listedFilePresentCount += 1
            }
            else {
                $missingListedFiles += [string]$listedFile
            }
        }

        if ($liveModelEndpointSmokeManifest) {
            $fixtureOnlyRaw = Get-JsonValue $manifest "fixtureOnly" $null
            $contractFixtureModeRaw = Get-JsonValue $manifest "contractFixtureMode" $null
            $realProviderAccessProvenRaw = Get-JsonValue $manifest "realProviderAccessProven" $null
            $productionLiveEndpointAccessProvenRaw = Get-JsonValue $manifest "productionLiveEndpointAccessProven" $null
            $liveSmokeExecutedRaw = Get-JsonValue $manifest "liveSmokeExecuted" $null
            $liveModelEndpointSmokeFixtureOnly = Convert-ToBool -Value $fixtureOnlyRaw -DefaultValue $true
            $liveModelEndpointSmokeContractFixtureMode = Convert-ToBool -Value $contractFixtureModeRaw -DefaultValue $true
            $liveModelEndpointSmokeRealProviderAccessProven = Convert-ToBool -Value $realProviderAccessProvenRaw -DefaultValue $false
            $liveModelEndpointSmokeProductionLiveEndpointAccessProven = Convert-ToBool -Value $productionLiveEndpointAccessProvenRaw -DefaultValue $false
            $liveModelEndpointSmokeExecuted = Convert-ToBool -Value $liveSmokeExecutedRaw -DefaultValue $false
            $liveModelEndpointSmokeProvenanceAccepted = (
                $status -eq "PASS" -and
                -not [bool]$liveModelEndpointSmokeFixtureOnly -and
                -not [bool]$liveModelEndpointSmokeContractFixtureMode -and
                [bool]$liveModelEndpointSmokeRealProviderAccessProven -and
                [bool]$liveModelEndpointSmokeProductionLiveEndpointAccessProven -and
                [bool]$liveModelEndpointSmokeExecuted
            )
            $liveModelEndpointSmokeContractFixtureAccepted = (
                $status -eq "PASS" -and
                $null -ne $fixtureOnlyRaw -and
                $null -ne $contractFixtureModeRaw -and
                $null -ne $realProviderAccessProvenRaw -and
                $null -ne $productionLiveEndpointAccessProvenRaw -and
                $null -ne $liveSmokeExecutedRaw -and
                [bool]$liveModelEndpointSmokeFixtureOnly -and
                [bool]$liveModelEndpointSmokeContractFixtureMode -and
                -not [bool]$liveModelEndpointSmokeRealProviderAccessProven -and
                -not [bool]$liveModelEndpointSmokeProductionLiveEndpointAccessProven -and
                -not [bool]$liveModelEndpointSmokeExecuted
            )
        }
    }

    $statusAccepted = $false
    if ($parseable) {
        $statusAccepted = Test-StatusAccepted `
            -ManifestName $FileName `
            -Status $status `
            -LiveModelEndpointSmokeProvenanceAccepted $liveModelEndpointSmokeProvenanceAccepted `
            -LiveModelEndpointSmokeContractFixtureAccepted $liveModelEndpointSmokeContractFixtureAccepted
    }

    return [pscustomobject][ordered]@{
        name = $FileName
        sourceManifest = [bool]$SourceManifest
        exists = [bool]$exists
        sourceManifestSha256 = $sourceManifestSha256
        parseable = [bool]$parseable
        status = $status
        statusAccepted = [bool]$statusAccepted
        schemaVersion = $schemaVersion
        allowRelease = $allowRelease
        blockingReasonCount = [int]$blockingReasonCount
        failedReasonCount = [int]$failedReasonCount
        listedFileCount = [int]$listedFileCount
        listedFilePresentCount = [int]$listedFilePresentCount
        missingListedFileCount = [int]$missingListedFiles.Count
        missingListedFiles = @($missingListedFiles)
        parseError = $parseError
        liveModelEndpointSmokeManifest = [bool]$liveModelEndpointSmokeManifest
        fixtureOnly = $liveModelEndpointSmokeFixtureOnly
        contractFixtureMode = $liveModelEndpointSmokeContractFixtureMode
        realProviderAccessProven = $liveModelEndpointSmokeRealProviderAccessProven
        productionLiveEndpointAccessProven = $liveModelEndpointSmokeProductionLiveEndpointAccessProven
        liveSmokeExecuted = $liveModelEndpointSmokeExecuted
        liveModelEndpointSmokeProvenanceAccepted = [bool]$liveModelEndpointSmokeProvenanceAccepted
        liveModelEndpointSmokeContractFixtureAccepted = [bool]$liveModelEndpointSmokeContractFixtureAccepted
    }
}

function Get-DefaultSourceManifestNames {
    $names = @(
        "manifest.json",
        "repair-agent-patch-output-manifest.json",
        "repair-agent-external-completion-failure-probe-manifest.json",
        "repair-agent-generic-patch-import-probe-manifest.json",
        "repair-agent-source-snapshot-apply-validate-manifest.json",
        "repair-agent-main-worktree-apply-readiness-manifest.json",
        "repair-agent-main-worktree-apply-retest-rollback-manifest.json",
        "repair-agent-external-task-output-acceptance-manifest.json",
        "repair-agent-patch-result-analysis-manifest.json",
        "repair-agent-patch-result-history-manifest.json",
        "repair-agent-external-patch-preflight-manifest.json",
        "repair-agent-external-patch-preflight-failure-probe-manifest.json",
        "repair-agent-repository-patch-apply-guard-manifest.json",
        "repair-agent-repository-patch-apply-clean-probe-manifest.json",
        "repair-agent-repository-patch-apply-clean-retest-manifest.json",
        "repair-agent-patch-apply-retest-manifest.json",
        "repair-retest-manifest.json",
        "repair-driver-failure-manifest.json",
        "replay-profile-import-manifest.json",
        "production-replay-integration-contract-probe-manifest.json",
        "production-driver-binding-kit-manifest.json",
        "production-driver-evidence-contract-probe-manifest.json",
        "production-replay-driver-readiness-manifest.json",
        "production-driver-evidence-intake-manifest.json",
        "production-driver-external-bundle-intake-probe-manifest.json",
        "model-endpoint-trace-manifest.json",
        "model-endpoint-provider-diagnostics-manifest.json",
        "model-endpoint-provider-retry-policy-manifest.json",
        "live-model-endpoint-config-kit-probe-manifest.json",
        "lua-static-analysis-manifest.json",
        "lua-auto-patch-sandbox-manifest.json",
        "production-lua-patch-readiness-manifest.json",
        "production-lua-patch-evidence-kit-probe-manifest.json",
        "production-lua-patch-external-bundle-intake-probe-manifest.json",
        "live-model-endpoint-failure-probe-manifest.json",
        "live-model-endpoint-smoke-manifest.json",
        "live-model-endpoint-external-smoke-intake-probe-manifest.json",
        "live-model-endpoint-smoke-evidence-contract-probe-manifest.json",
        "github-actions-release-workflow-probe-manifest.json",
        "azure-pipelines-release-workflow-probe-manifest.json",
        "provider-ci-quality-probe-manifest.json",
        "production-handoff-package-manifest.json",
        "production-handoff-external-evidence-preflight-probe-manifest.json",
        "production-handoff-export-manifest.json",
        "production-handoff-export-zip-index-manifest.json",
        "release-docs-freshness-manifest.json",
        "production-handoff-status-manifest.json",
        "production-handoff-dispatch-manifest.json",
        "production-handoff-contact-readiness-manifest.json",
        "production-handoff-contact-readiness-contract-probe-manifest.json",
        "production-handoff-send-readiness-manifest.json",
        "production-handoff-mail-auth-readiness-manifest.json",
        "production-handoff-owner-unblock-pack-manifest.json",
        "production-handoff-owner-unblock-pack-contract-probe-manifest.json",
        "production-handoff-owner-input-request-pack-manifest.json",
        "production-handoff-owner-contact-external-intake-probe-manifest.json",
        "production-handoff-send-dry-run-probe-manifest.json",
        "production-handoff-send-local-workflow-probe-manifest.json",
        "production-handoff-owner-packet-dispatch-receipt-intake-probe-manifest.json",
        "production-handoff-owner-packet-real-receipt-guard-probe-manifest.json",
        "production-handoff-owner-response-bundle-probe-manifest.json",
        "production-handoff-owner-response-bundle-kit-manifest.json",
        "production-handoff-owner-response-bundle-kit-workflow-probe-manifest.json",
        "release-progress-notification-outbox-manifest.json",
        "release-progress-notification-remaining-work-snapshot-probe-manifest.json",
        "release-progress-notification-post-dispatch-snapshot-probe-manifest.json",
        "production-handoff-mail-helper-auth-status-probe-manifest.json",
        "release-progress-notification-confirmation-probe-manifest.json",
        "release-progress-notification-receipt-probe-manifest.json",
        "release-progress-notification-dispatch-receipt-intake-probe-manifest.json",
        "release-progress-notification-local-send-workflow-probe-manifest.json",
        "release-progress-notification-real-receipt-guard-probe-manifest.json",
        "production-external-evidence-acceptance-contract-probe-manifest.json",
        "production-external-evidence-acceptance-failure-probe-manifest.json",
        "production-external-evidence-inbox-manifest.json",
        "production-external-evidence-inbox-contract-probe-manifest.json",
        "production-external-evidence-auto-acceptance-probe-manifest.json",
        "production-external-evidence-action-queue-manifest.json",
        "production-external-evidence-action-queue-probe-manifest.json",
        "production-external-evidence-gap-analysis-manifest.json",
        "production-handoff-owner-route-map-manifest.json",
        "production-handoff-owner-route-map-probe-manifest.json",
        "production-external-evidence-partial-matrix-probe-manifest.json",
        "production-external-evidence-semantic-preflight-probe-manifest.json",
        "production-external-evidence-owner-return-bundle-status-manifest.json",
        "production-external-evidence-owner-return-bundle-status-probe-manifest.json",
        "production-hard-mode-failure-probe-manifest.json",
        "production-hard-mode-success-contract-probe-manifest.json",
        "release-risk-policy-manifest.json"
    )

    $cursorAgentManifest = Join-Path $evidenceBundlePath "repair-agent-cursor-agent-external-output-manifest.json"
    if (Test-Path $cursorAgentManifest) {
        $names += "repair-agent-cursor-agent-external-output-manifest.json"
    }

    $cursorAgentBindingProbeManifest = Join-Path $evidenceBundlePath "repair-agent-cursor-agent-external-output-binding-probe-manifest.json"
    if (Test-Path $cursorAgentBindingProbeManifest) {
        $names += "repair-agent-cursor-agent-external-output-binding-probe-manifest.json"
    }

    if (-not [bool]$RequireProductionReplayDriverBound) {
        $names += "production-replay-driver-bound-failure-probe-manifest.json"
    }

    if (-not [bool]$RequireProductionLuaPatched) {
        $names += "production-lua-patch-bound-failure-probe-manifest.json"
    }

    return @($names)
}

function Get-DedupedNames {
    param([string[]]$Names)

    $seen = @{}
    $deduped = @()
    foreach ($name in $Names) {
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        if (-not $seen.ContainsKey($name)) {
            $seen[$name] = $true
            $deduped += $name
        }
    }

    return @($deduped)
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$indexFullPath = Assert-PathUnderRepo $IndexPath "IndexPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if ($null -eq $SourceManifestNames -or $SourceManifestNames.Count -eq 0) {
    $SourceManifestNames = @(Get-DefaultSourceManifestNames)
}

$SourceManifestNames = @(Get-DedupedNames $SourceManifestNames)
$sourceNameSet = @{}
foreach ($name in $SourceManifestNames) {
    $sourceNameSet[$name] = $true
}

$sourceEntries = @()
foreach ($name in $SourceManifestNames) {
    $sourceEntries += Read-ManifestEntry -FileName $name -SourceManifest $true
}
$sourceManifestHashLines = @($sourceEntries |
    Where-Object { [bool]$_.exists -and -not [string]::IsNullOrWhiteSpace([string]$_.sourceManifestSha256) } |
    ForEach-Object { "$($_.name)`t$($_.sourceManifestSha256)" } |
    Sort-Object)
$sourceManifestHashSetText = (@($sourceManifestHashLines) -join "`n") + "`n"
$sourceManifestHashSetSha256 = Get-StringSha256 $sourceManifestHashSetText

$allManifestEntries = @()
$manifestFiles = @(Get-ChildItem -Path $evidenceBundlePath -Filter "*manifest.json" -File | Sort-Object -Property Name)
foreach ($file in $manifestFiles) {
    $isSourceManifest = $sourceNameSet.ContainsKey($file.Name)
    $allManifestEntries += Read-ManifestEntry -FileName $file.Name -SourceManifest $isSourceManifest
}

$liveModelEndpointSmokeSourceEntry = $null
foreach ($entry in $sourceEntries) {
    if ([string]$entry.name -eq "live-model-endpoint-smoke-manifest.json") {
        $liveModelEndpointSmokeSourceEntry = $entry
        break
    }
}

$liveModelEndpointSmokeSourceManifestIncluded = $null -ne $liveModelEndpointSmokeSourceEntry
$liveModelEndpointSmokeSourceManifestExists = $false
$liveModelEndpointSmokeSourceManifestParseable = $false
$liveModelEndpointSmokeStatus = ""
$liveModelEndpointSmokeStatusAccepted = $false
$liveModelEndpointSmokeFixtureOnly = $null
$liveModelEndpointSmokeContractFixtureMode = $null
$liveModelEndpointSmokeRealProviderAccessProven = $null
$liveModelEndpointSmokeProductionLiveEndpointAccessProven = $null
$liveModelEndpointSmokeExecuted = $null
$liveModelEndpointSmokeProvenanceAccepted = $false
$liveModelEndpointSmokeContractFixtureAccepted = $false
if ($null -ne $liveModelEndpointSmokeSourceEntry) {
    $liveModelEndpointSmokeSourceManifestExists = [bool]$liveModelEndpointSmokeSourceEntry.exists
    $liveModelEndpointSmokeSourceManifestParseable = [bool]$liveModelEndpointSmokeSourceEntry.parseable
    $liveModelEndpointSmokeStatus = [string]$liveModelEndpointSmokeSourceEntry.status
    $liveModelEndpointSmokeStatusAccepted = [bool]$liveModelEndpointSmokeSourceEntry.statusAccepted
    $liveModelEndpointSmokeFixtureOnly = $liveModelEndpointSmokeSourceEntry.fixtureOnly
    $liveModelEndpointSmokeContractFixtureMode = $liveModelEndpointSmokeSourceEntry.contractFixtureMode
    $liveModelEndpointSmokeRealProviderAccessProven = $liveModelEndpointSmokeSourceEntry.realProviderAccessProven
    $liveModelEndpointSmokeProductionLiveEndpointAccessProven = $liveModelEndpointSmokeSourceEntry.productionLiveEndpointAccessProven
    $liveModelEndpointSmokeExecuted = $liveModelEndpointSmokeSourceEntry.liveSmokeExecuted
    $liveModelEndpointSmokeProvenanceAccepted = [bool]$liveModelEndpointSmokeSourceEntry.liveModelEndpointSmokeProvenanceAccepted
    $liveModelEndpointSmokeContractFixtureAccepted = [bool]$liveModelEndpointSmokeSourceEntry.liveModelEndpointSmokeContractFixtureAccepted
}

$missingSourceEntries = @($sourceEntries | Where-Object { -not [bool]$_.exists })
$unparseableSourceEntries = @($sourceEntries | Where-Object { [bool]$_.exists -and -not [bool]$_.parseable })
$failedSourceEntries = @($sourceEntries | Where-Object { [bool]$_.parseable -and [string]$_.status -eq "FAIL" })
$blockedSourceEntries = @($sourceEntries | Where-Object { [bool]$_.parseable -and [string]$_.status -eq "BLOCKED" })
$skippedSourceEntries = @($sourceEntries | Where-Object { [bool]$_.parseable -and [string]$_.status -eq "SKIPPED" })
$unacceptedSourceEntries = @($sourceEntries | Where-Object { [bool]$_.parseable -and -not [bool]$_.statusAccepted })
$missingListedFiles = @()
foreach ($entry in $sourceEntries) {
    foreach ($fileName in @($entry.missingListedFiles)) {
        $missingListedFiles += [string]$entry.name + ":" + [string]$fileName
    }
}

$fieldCoverageChecks = @(New-ReleaseEvidenceFieldCoverage)
$fieldCoverageFailedChecks = @($fieldCoverageChecks | Where-Object { -not [bool]$_["passed"] })
$fieldCoverageMissingManifestChecks = @($fieldCoverageChecks | Where-Object { [string]$_["failureKind"] -eq "manifest_missing" })
$fieldCoverageMissingFieldChecks = @($fieldCoverageChecks | Where-Object { [string]$_["failureKind"] -eq "field_missing" })
$fieldCoverageValueMismatchChecks = @($fieldCoverageChecks | Where-Object { [string]$_["failureKind"] -eq "value_mismatch" })
$fieldCoverageManifestNames = @($fieldCoverageChecks | ForEach-Object { [string]$_["manifestName"] } | Sort-Object -Unique)
$fieldCoverageDefinitionLines = @($fieldCoverageChecks | ForEach-Object {
        @(
            [string]$_["manifestName"],
            [string]$_["fieldName"],
            [string]$_["operator"],
            (Convert-FieldValueForDefinitionLine $_["expectedValue"]),
            [string]$_["label"]
        ) -join "`t"
    } | Sort-Object)
$fieldCoverageDefinitionText = (@($fieldCoverageDefinitionLines) -join "`n") + "`n"
$fieldCoverageDefinitionSha256 = Get-StringSha256 $fieldCoverageDefinitionText
$releaseEvidenceIndexScriptRelativePath = "tools\Invoke-AITestPilotReleaseEvidenceIndex.ps1"
$releaseEvidenceIndexScriptSha256 = Get-ReleaseEvidenceIndexScriptSha256
$fieldLevelCoverageStatus = if ($fieldCoverageFailedChecks.Count -eq 0) { "PASS" } else { "BLOCKED" }

$blockingReasons = @()
if ($missingSourceEntries.Count -gt 0) {
    $blockingReasons += "source_manifest_missing"
}
if ($unparseableSourceEntries.Count -gt 0) {
    $blockingReasons += "source_manifest_unparseable"
}
if ($failedSourceEntries.Count -gt 0) {
    $blockingReasons += "source_manifest_failed"
}
if ($blockedSourceEntries.Count -gt 0) {
    $blockingReasons += "source_manifest_blocked"
}
if ($unacceptedSourceEntries.Count -gt 0) {
    $blockingReasons += "source_manifest_status_not_accepted"
}
if ($missingListedFiles.Count -gt 0) {
    $blockingReasons += "source_manifest_listed_file_missing"
}
if ($fieldCoverageFailedChecks.Count -gt 0) {
    $blockingReasons += "field_level_coverage_failed"
}

$status = "PASS"
if ($blockingReasons.Count -gt 0) {
    $status = "BLOCKED"
}

$generatedFiles = @(
    "release-evidence-index-manifest.json",
    "release-evidence-index.json",
    "release-evidence-index.md"
)

$allAuxiliaryEntries = @($allManifestEntries | Where-Object { -not [bool]$_.sourceManifest })
$releaseGateManifestIncluded = Test-Path (Join-Path $evidenceBundlePath "release-gate-manifest.json")
$pipelineManifestIncluded = Test-Path (Join-Path $evidenceBundlePath "pipeline-manifest.json")

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.release_evidence_index.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    source = "release_evidence_bundle_source_manifest_index"
    machineReadable = $true
    portalHandoffReady = ($status -eq "PASS")
    requireProductionReplayDriverBound = [bool]$RequireProductionReplayDriverBound
    requireProductionLuaPatched = [bool]$RequireProductionLuaPatched
    requireLiveModelEndpointSmoke = [bool]$RequireLiveModelEndpointSmoke
    contractFixtureMode = [bool]$ContractFixtureMode
    liveModelEndpointSmokeSourceManifestIncluded = [bool]$liveModelEndpointSmokeSourceManifestIncluded
    liveModelEndpointSmokeSourceManifestExists = [bool]$liveModelEndpointSmokeSourceManifestExists
    liveModelEndpointSmokeSourceManifestParseable = [bool]$liveModelEndpointSmokeSourceManifestParseable
    liveModelEndpointSmokeStatus = $liveModelEndpointSmokeStatus
    liveModelEndpointSmokeStatusAccepted = [bool]$liveModelEndpointSmokeStatusAccepted
    liveModelEndpointSmokeFixtureOnly = $liveModelEndpointSmokeFixtureOnly
    liveModelEndpointSmokeContractFixtureMode = $liveModelEndpointSmokeContractFixtureMode
    liveModelEndpointSmokeRealProviderAccessProven = $liveModelEndpointSmokeRealProviderAccessProven
    liveModelEndpointSmokeProductionLiveEndpointAccessProven = $liveModelEndpointSmokeProductionLiveEndpointAccessProven
    liveModelEndpointSmokeExecuted = $liveModelEndpointSmokeExecuted
    liveModelEndpointSmokeProvenanceAccepted = [bool]$liveModelEndpointSmokeProvenanceAccepted
    liveModelEndpointSmokeContractFixtureAccepted = [bool]$liveModelEndpointSmokeContractFixtureAccepted
    fieldLevelCoverageStatus = $fieldLevelCoverageStatus
    fieldLevelCoverageSchemaVersion = "aitestpilot.release_evidence_field_level_coverage.v1"
    fieldLevelCoverageDefinitionSchemaVersion = "aitestpilot.release_evidence_field_level_coverage_definition.v1"
    fieldLevelCoverageDefinitionHashAlgorithm = "SHA256"
    fieldLevelCoverageDefinitionSha256 = $fieldCoverageDefinitionSha256
    fieldLevelCoverageDefinitionCount = [int]$fieldCoverageDefinitionLines.Count
    fieldLevelCoverageDefinitionLines = @($fieldCoverageDefinitionLines)
    fieldLevelCoverageSourceScriptPath = $releaseEvidenceIndexScriptRelativePath
    fieldLevelCoverageSourceScriptSha256 = $releaseEvidenceIndexScriptSha256
    fieldLevelRequiredManifestCount = [int]$fieldCoverageManifestNames.Count
    fieldLevelRequiredFieldCount = [int]$fieldCoverageChecks.Count
    fieldLevelCoveredFieldCount = [int]($fieldCoverageChecks.Count - $fieldCoverageMissingFieldChecks.Count)
    semanticFieldCheckCount = [int]$fieldCoverageChecks.Count
    semanticFieldCheckPassedCount = [int]($fieldCoverageChecks.Count - $fieldCoverageFailedChecks.Count)
    semanticFieldCheckFailedCount = [int]$fieldCoverageFailedChecks.Count
    fieldLevelMissingManifestCount = [int]$fieldCoverageMissingManifestChecks.Count
    fieldLevelMissingFieldCount = [int]$fieldCoverageMissingFieldChecks.Count
    fieldLevelValueMismatchCount = [int]$fieldCoverageValueMismatchChecks.Count
    fieldLevelCoverageManifestNames = @($fieldCoverageManifestNames)
    evidenceBundlePath = $evidenceBundlePath
    requiredSourceManifestCount = [int]$SourceManifestNames.Count
    indexedSourceManifestCount = [int]@($sourceEntries | Where-Object { [bool]$_.exists -and [bool]$_.parseable }).Count
    sourceManifestCoverageCount = [int]@($sourceEntries | Where-Object { [bool]$_.exists -and [bool]$_.parseable -and [bool]$_.statusAccepted }).Count
    sourceManifestHashAlgorithm = "SHA256"
    sourceManifestHashSetSha256 = $sourceManifestHashSetSha256
    sourceManifestHashEntryCount = [int]$sourceManifestHashLines.Count
    sourceManifestHashLines = @($sourceManifestHashLines)
    missingSourceManifestCount = [int]$missingSourceEntries.Count
    unparseableSourceManifestCount = [int]$unparseableSourceEntries.Count
    failedSourceManifestCount = [int]$failedSourceEntries.Count
    blockedSourceManifestCount = [int]$blockedSourceEntries.Count
    skippedSourceManifestCount = [int]$skippedSourceEntries.Count
    unacceptedSourceManifestStatusCount = [int]$unacceptedSourceEntries.Count
    sourceListedFileCount = [int](($sourceEntries | Measure-Object -Property listedFileCount -Sum).Sum)
    missingListedFileCount = [int]$missingListedFiles.Count
    allManifestFileCount = [int]$allManifestEntries.Count
    auxiliaryManifestCount = [int]$allAuxiliaryEntries.Count
    releaseGateManifestIncluded = [bool]$releaseGateManifestIncluded
    releaseGateManifestExpected = $true
    pipelineManifestIncluded = [bool]$pipelineManifestIncluded
    pipelineManifestExpected = $true
    sourceManifestNames = @($SourceManifestNames)
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles)
    blockingReasonCount = [int]$blockingReasons.Count
    blockingReasons = @($blockingReasons)
}

$index = [ordered]@{
    schemaVersion = "aitestpilot.release_evidence_index.v1"
    status = $status
    generatedAtUtc = $manifest.generatedAtUtc
    machineReadable = $true
    portalHandoffReady = ($status -eq "PASS")
    evidenceBundlePath = $evidenceBundlePath
    sourceManifestHashAlgorithm = "SHA256"
    sourceManifestHashSetSha256 = $sourceManifestHashSetSha256
    sourceManifestHashEntryCount = [int]$sourceManifestHashLines.Count
    sourceManifestHashLines = @($sourceManifestHashLines)
    summary = $manifest
    sourceManifests = @($sourceEntries)
    auxiliaryManifests = @($allAuxiliaryEntries)
    missingListedFiles = @($missingListedFiles)
    fieldLevelCoverage = [ordered]@{
        schemaVersion = "aitestpilot.release_evidence_field_level_coverage.v1"
        status = $fieldLevelCoverageStatus
        definitionSchemaVersion = "aitestpilot.release_evidence_field_level_coverage_definition.v1"
        definitionHashAlgorithm = "SHA256"
        definitionSha256 = $fieldCoverageDefinitionSha256
        definitionCount = [int]$fieldCoverageDefinitionLines.Count
        definitionLines = @($fieldCoverageDefinitionLines)
        sourceScriptPath = $releaseEvidenceIndexScriptRelativePath
        sourceScriptSha256 = $releaseEvidenceIndexScriptSha256
        requiredManifestCount = [int]$fieldCoverageManifestNames.Count
        requiredFieldCount = [int]$fieldCoverageChecks.Count
        coveredFieldCount = [int]($fieldCoverageChecks.Count - $fieldCoverageMissingFieldChecks.Count)
        semanticFieldCheckCount = [int]$fieldCoverageChecks.Count
        semanticFieldCheckPassedCount = [int]($fieldCoverageChecks.Count - $fieldCoverageFailedChecks.Count)
        semanticFieldCheckFailedCount = [int]$fieldCoverageFailedChecks.Count
        missingManifestCount = [int]$fieldCoverageMissingManifestChecks.Count
        missingFieldCount = [int]$fieldCoverageMissingFieldChecks.Count
        valueMismatchCount = [int]$fieldCoverageValueMismatchChecks.Count
        manifestNames = @($fieldCoverageManifestNames)
        checks = @($fieldCoverageChecks)
        failedChecks = @($fieldCoverageFailedChecks)
    }
}

$reportLines = @(
    "# AI TestPilot Release Evidence Index",
    "",
    "- Status: $status",
    "- Source manifests indexed: $($manifest.indexedSourceManifestCount) / $($manifest.requiredSourceManifestCount)",
    "- Source manifest coverage: $($manifest.sourceManifestCoverageCount) / $($manifest.requiredSourceManifestCount)",
    "- Source manifest hash set SHA256: $($manifest.sourceManifestHashSetSha256)",
    "- Source manifest hash entries: $($manifest.sourceManifestHashEntryCount) / $($manifest.requiredSourceManifestCount)",
    "- Missing source manifests: $($manifest.missingSourceManifestCount)",
    "- Unparseable source manifests: $($manifest.unparseableSourceManifestCount)",
    "- Failed source manifests: $($manifest.failedSourceManifestCount)",
    "- Blocked source manifests: $($manifest.blockedSourceManifestCount)",
    "- Skipped source manifests: $($manifest.skippedSourceManifestCount)",
    "- Missing listed files: $($manifest.missingListedFileCount)",
    "- Field-level coverage status: $($manifest.fieldLevelCoverageStatus)",
    "- Field-level definition SHA256: $($manifest.fieldLevelCoverageDefinitionSha256)",
    "- Field-level source script SHA256: $($manifest.fieldLevelCoverageSourceScriptSha256)",
    "- Field-level required manifests: $($manifest.fieldLevelRequiredManifestCount)",
    "- Field-level required fields: $($manifest.fieldLevelRequiredFieldCount)",
    "- Semantic field checks passed: $($manifest.semanticFieldCheckPassedCount) / $($manifest.semanticFieldCheckCount)",
    "- Field-level missing fields: $($manifest.fieldLevelMissingFieldCount)",
    "- Field-level value mismatches: $($manifest.fieldLevelValueMismatchCount)",
    "- All manifest files inventoried: $($manifest.allManifestFileCount)",
    "- Release gate manifest included at index time: $($manifest.releaseGateManifestIncluded)",
    "- Pipeline manifest included at index time: $($manifest.pipelineManifestIncluded)",
    "",
    "## Source Manifests",
    "",
    "| Manifest | SHA256 | Status | Accepted | Listed files | Missing listed files |",
    "| --- | --- | --- | --- | ---: | ---: |"
)

foreach ($entry in $sourceEntries) {
    $reportLines += "| $($entry.name) | $($entry.sourceManifestSha256) | $($entry.status) | $($entry.statusAccepted) | $($entry.listedFileCount) | $($entry.missingListedFileCount) |"
}

$reportLines += @(
    "",
    "## Field-Level Coverage",
    "",
    "| Manifest | Field | Expected | Actual | Passed | Label |",
    "| --- | --- | --- | --- | --- | --- |"
)
foreach ($check in $fieldCoverageChecks) {
    $expectedText = if ($null -eq $check["expectedValue"]) { "(null)" } else { [string]$check["expectedValue"] }
    $actualText = if ($null -eq $check["actualValue"]) { "(null)" } else { [string]$check["actualValue"] }
    $reportLines += "| $($check["manifestName"]) | $($check["fieldName"]) | $($expectedText.Replace("|", "\|")) | $($actualText.Replace("|", "\|")) | $($check["passed"]) | $(([string]$check["label"]).Replace("|", "\|")) |"
}

if ($blockingReasons.Count -gt 0) {
    $reportLines += ""
    $reportLines += "## Blocking Reasons"
    $reportLines += ""
    foreach ($reason in $blockingReasons) {
        $reportLines += "- $reason"
    }
}

New-Item -ItemType Directory -Force (Split-Path $indexFullPath -Parent) | Out-Null
New-Item -ItemType Directory -Force (Split-Path $reportFullPath -Parent) | Out-Null
New-Item -ItemType Directory -Force (Split-Path $manifestFullPath -Parent) | Out-Null

$index | ConvertTo-Json -Depth 10 | Set-Content -Path $indexFullPath -Encoding UTF8
$reportLines | Set-Content -Path $reportFullPath -Encoding UTF8
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestFullPath -Encoding UTF8

if ($status -ne "PASS") {
    throw "AI TestPilot release evidence index blocked. Manifest: $manifestFullPath"
}

Write-Output "Release evidence index: $indexFullPath"
Write-Output "Release evidence index manifest: $manifestFullPath"
Write-Output "PASS AI TestPilot release evidence index"
