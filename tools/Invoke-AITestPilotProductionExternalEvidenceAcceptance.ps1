[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$AcceptanceBundleDir,
    [string]$ManifestPath,
    [string]$ReportPath,
    [string]$ProductionDriverEvidenceDir,
    [string]$ProductionLuaEvidenceDir,
    [string]$LiveModelEndpointSmokeEvidenceDir,
    [string]$GameReplayDriverType = "Your.Game.Tests.ProductionReplayDriver",
    [switch]$RequireAllEvidence,
    [switch]$ContractFixtureMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($AcceptanceBundleDir)) {
    $AcceptanceBundleDir = Join-Path $EvidenceBundleDir "production-external-evidence-acceptance"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-external-evidence-acceptance-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = [System.IO.Path]::ChangeExtension($ManifestPath, ".md")
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

function Test-RequiredFiles {
    param(
        [string]$BaseDir,
        [string[]]$RequiredFiles
    )

    $provided = -not [string]::IsNullOrWhiteSpace($BaseDir)
    $path = ""
    $missingFiles = @()

    if (-not $provided) {
        $missingFiles = @($RequiredFiles)
    } else {
        $path = Resolve-FullPath $BaseDir
        if (-not (Test-Path $path)) {
            $missingFiles = @($RequiredFiles)
        } else {
            foreach ($fileName in $RequiredFiles) {
                if (-not (Test-Path (Join-Path $path $fileName))) {
                    $missingFiles += $fileName
                }
            }
        }
    }

    return [ordered]@{
        provided = [bool]$provided
        path = $path
        requiredFiles = @($RequiredFiles)
        missingFiles = @($missingFiles)
        missingFileCount = [int]$missingFiles.Count
        allPresent = ($provided -and $missingFiles.Count -eq 0)
    }
}

function Invoke-AcceptanceCommand {
    param(
        [string]$Name,
        [scriptblock]$Command
    )

    $passed = $true
    $message = "PASS"
    try {
        & $Command | Out-Null
    } catch {
        $passed = $false
        $message = $_.Exception.Message
    }

    return [ordered]@{
        name = $Name
        passed = [bool]$passed
        message = $message
    }
}

function Add-AcceptanceCheck {
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

function Get-ReportValue {
    param(
        [object]$Map,
        [string]$Name,
        [object]$Default = $null
    )

    if ($null -eq $Map) {
        return $Default
    }

    if ($Map -is [System.Collections.IDictionary] -and $Map.Contains($Name)) {
        return $Map[$Name]
    }

    $property = $Map.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }

    return $Default
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

function Format-MissingFiles {
    param([object]$Evidence)

    $missingFiles = @(Get-ReportValue $Evidence "missingFiles" @())
    if ($missingFiles.Count -eq 0) {
        return "(none)"
    }

    return [string]::Join(", ", @($missingFiles | ForEach-Object { [string]$_ }))
}

function Get-CommandResultSummary {
    param(
        [object[]]$Results,
        [string]$Name
    )

    foreach ($result in @($Results)) {
        if (([string](Get-ReportValue $result "name" "")) -ne $Name) {
            continue
        }

        if ([bool](Get-ReportValue $result "passed" $false)) {
            return "PASS"
        }

        $message = [string](Get-ReportValue $result "message" "")
        return "FAIL: $message"
    }

    return "not_run"
}

$evidenceBundlePath = Resolve-FullPath $EvidenceBundleDir
$acceptanceBundlePath = Assert-PathUnderRepo $AcceptanceBundleDir "AcceptanceBundleDir"
$manifestPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportPath = Assert-PathUnderRepo $ReportPath "ReportPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if (Test-Path $acceptanceBundlePath) {
    Remove-Item -LiteralPath $acceptanceBundlePath -Recurse -Force
}
New-Item -ItemType Directory -Force $acceptanceBundlePath | Out-Null

$driverRequiredFiles = @(
    "production-replay-integration-checklist.json",
    "repair-retest-manifest.json",
    "repair-driver-failure-manifest.json",
    "replay-profile-import-manifest.json"
)
$luaRequiredFiles = @(
    "production-lua-patch-evidence.json",
    "production-lua-patch-retest-template.md",
    "production-lua-patch-rollback-plan-template.md"
)
$liveModelRequiredFiles = @(
    "live-model-endpoint-smoke-manifest.json",
    "live-model-endpoint-decision-trace.json"
)

$driverEvidence = Test-RequiredFiles $ProductionDriverEvidenceDir $driverRequiredFiles
$luaEvidence = Test-RequiredFiles $ProductionLuaEvidenceDir $luaRequiredFiles
$liveModelEvidence = Test-RequiredFiles $LiveModelEndpointSmokeEvidenceDir $liveModelRequiredFiles

foreach ($fileName in @("lua-static-analysis-manifest.json", "lua-auto-patch-sandbox-manifest.json", "lua-auto-patch.patch", "lua-auto-patch-operations.json")) {
    $sourcePath = Join-Path $evidenceBundlePath $fileName
    if (Test-Path $sourcePath) {
        Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $acceptanceBundlePath $fileName) -Force
    }
}

$driverIntakeManifestPath = Join-Path $acceptanceBundlePath "production-driver-evidence-intake-manifest.json"
$driverReadinessCopyPath = Join-Path $acceptanceBundlePath "production-driver-evidence-intake-readiness-manifest.json"
$luaReadinessManifestPath = Join-Path $acceptanceBundlePath "production-lua-patch-readiness-manifest.json"
$liveSmokeIntakeManifestPath = Join-Path $acceptanceBundlePath "live-model-endpoint-smoke-evidence-intake-manifest.json"

$commandResults = @()
$driverManifest = $null
$luaManifest = $null
$liveManifest = $null

if ([bool]$driverEvidence.allPresent) {
    $commandResults += Invoke-AcceptanceCommand "production_driver_evidence_intake" {
        & (Join-Path $PSScriptRoot "Invoke-AITestPilotProductionDriverEvidenceIntake.ps1") `
            -EvidenceBundleDir $driverEvidence.path `
            -ManifestPath $driverIntakeManifestPath
    }

    if (Test-Path $driverIntakeManifestPath) {
        $driverManifest = Read-JsonFile $driverIntakeManifestPath "Production driver evidence acceptance manifest"
    }

    $driverReadinessPath = Join-Path $driverEvidence.path "production-driver-evidence-intake-readiness-manifest.json"
    if (Test-Path $driverReadinessPath) {
        Copy-Item -LiteralPath $driverReadinessPath -Destination $driverReadinessCopyPath -Force
    }
}

if ([bool]$luaEvidence.allPresent) {
    $commandResults += Invoke-AcceptanceCommand "production_lua_patch_readiness" {
        & (Join-Path $PSScriptRoot "Invoke-AITestPilotProductionLuaPatchReadiness.ps1") `
            -EvidenceBundleDir $acceptanceBundlePath `
            -ManifestPath $luaReadinessManifestPath `
            -ProductionLuaEvidenceDir $luaEvidence.path `
            -RequireProductionLuaPatched
    }

    if (Test-Path $luaReadinessManifestPath) {
        $luaManifest = Read-JsonFile $luaReadinessManifestPath "Production Lua evidence acceptance manifest"
    }
}

if ([bool]$liveModelEvidence.allPresent) {
    $commandResults += Invoke-AcceptanceCommand "live_model_endpoint_smoke_evidence_intake" {
        & (Join-Path $PSScriptRoot "Invoke-AITestPilotLiveModelEndpointSmokeEvidenceIntake.ps1") `
            -EvidenceBundleDir $acceptanceBundlePath `
            -SmokeEvidenceDir $liveModelEvidence.path `
            -ManifestPath $liveSmokeIntakeManifestPath `
            -RequireLiveModelEndpointSmoke `
            -PromoteToCanonical
    }

    if (Test-Path $liveSmokeIntakeManifestPath) {
        $liveManifest = Read-JsonFile $liveSmokeIntakeManifestPath "Live model smoke evidence acceptance manifest"
    }
}

$driverAccepted = $null -ne $driverManifest -and
    $driverManifest.status -eq "PASS" -and
    [bool]$driverManifest.intakeAccepted -and
    [bool]$driverManifest.readyForProductionDriverRelease -and
    [int]$driverManifest.blockingReasonCount -eq 0
$luaAccepted = $null -ne $luaManifest -and
    $luaManifest.status -eq "PASS" -and
    [bool]$luaManifest.readyForProductionLuaPatchRelease -and
    [bool]$luaManifest.productionLuaEvidenceAccepted -and
    [int]$luaManifest.blockingReasonCount -eq 0
$liveAccepted = $null -ne $liveManifest -and
    $liveManifest.status -eq "PASS" -and
    [bool]$liveManifest.smokeEvidenceAccepted -and
    [bool]$liveManifest.productionLiveEndpointAccessProven -and
    [bool]$liveManifest.canonicalSmokePromoted -and
    [bool]$liveManifest.canonicalTracePromoted -and
    [int]$liveManifest.blockingReasonCount -eq 0

$allRequiredExternalEvidenceFilesPresent = [bool]$driverEvidence.allPresent -and [bool]$luaEvidence.allPresent -and [bool]$liveModelEvidence.allPresent
$missingExternalEvidenceAreaCount = @(@($driverEvidence, $luaEvidence, $liveModelEvidence) | Where-Object { -not [bool]$_["allPresent"] }).Count
$failedAcceptanceCount = @($commandResults | Where-Object { -not [bool]$_["passed"] }).Count
$allExternalEvidenceAccepted = [bool]$driverAccepted -and [bool]$luaAccepted -and [bool]$liveAccepted
$realHostProjectEvidenceAccepted = $allExternalEvidenceAccepted -and -not [bool]$ContractFixtureMode

$checks = @()
Add-AcceptanceCheck "all_required_external_evidence_files_present" $allRequiredExternalEvidenceFilesPresent "Driver, Lua, and live-smoke evidence directories must contain every required file."
Add-AcceptanceCheck "production_driver_evidence_accepted" $driverAccepted "Production driver evidence intake must accept a BOUND host-project driver bundle."
Add-AcceptanceCheck "production_lua_evidence_accepted" $luaAccepted "Production Lua readiness must accept a real patched Lua evidence bundle."
Add-AcceptanceCheck "live_model_smoke_evidence_accepted" $liveAccepted "Live model smoke intake must accept PASS smoke and trace evidence."
Add-AcceptanceCheck "fixture_boundary_preserved" ((-not [bool]$ContractFixtureMode) -or (-not [bool]$realHostProjectEvidenceAccepted)) "Contract fixture mode must not claim real host-project evidence."

$status = if ($allExternalEvidenceAccepted) {
    "PASS"
} elseif ([bool]$RequireAllEvidence) {
    "FAIL"
} else {
    "PENDING_EXTERNAL_EVIDENCE"
}

$generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
$reportLines = @(
    "# Production External Evidence Acceptance",
    "",
    "Schema: ``aitestpilot.production_external_evidence_acceptance.v1``",
    "Generated at UTC: $generatedAtUtc",
    "",
    "## Summary",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Status | $(Format-MarkdownCell $status) |",
    "| Require all evidence | $(Format-MarkdownCell ([bool]$RequireAllEvidence)) |",
    "| Contract fixture mode | $(Format-MarkdownCell ([bool]$ContractFixtureMode)) |",
    "| All external evidence accepted | $(Format-MarkdownCell $allExternalEvidenceAccepted) |",
    "| Real host-project evidence accepted | $(Format-MarkdownCell $realHostProjectEvidenceAccepted) |",
    "| Missing external evidence areas | $(Format-MarkdownCell $missingExternalEvidenceAreaCount) |",
    "| Failed acceptance commands | $(Format-MarkdownCell $failedAcceptanceCount) |",
    "",
    "## Evidence Areas",
    "",
    "| Area | Required files present | Accepted | Missing files | Command result |",
    "| --- | --- | --- | --- | --- |"
)

$reportAreas = @(
    [ordered]@{
        Area = "production_driver_binding"
        Evidence = $driverEvidence
        Accepted = $driverAccepted
        Command = "production_driver_evidence_intake"
    },
    [ordered]@{
        Area = "production_lua_patch_evidence"
        Evidence = $luaEvidence
        Accepted = $luaAccepted
        Command = "production_lua_patch_readiness"
    },
    [ordered]@{
        Area = "live_model_endpoint_smoke"
        Evidence = $liveModelEvidence
        Accepted = $liveAccepted
        Command = "live_model_endpoint_smoke_evidence_intake"
    }
)

foreach ($area in $reportAreas) {
    $evidence = $area["Evidence"]
    $areaName = $area["Area"]
    $areaAccepted = [bool]$area["Accepted"]
    $commandName = $area["Command"]
    $requiredFilesPresent = [bool](Get-ReportValue $evidence "allPresent" $false)
    $missingFiles = Format-MissingFiles $evidence
    $commandResult = Get-CommandResultSummary @($commandResults) $commandName
    $reportLines += "| $(Format-MarkdownCell $areaName) | $(Format-MarkdownCell $requiredFilesPresent) | $(Format-MarkdownCell $areaAccepted) | $(Format-MarkdownCell $missingFiles) | $(Format-MarkdownCell $commandResult) |"
}

$reportLines += @(
    "",
    "## Evidence Boundary",
    "",
    "- Contract fixture mode is acceptance-contract proof only and never claims real host-project evidence.",
    "- Real host-project evidence is accepted only when driver, Lua, and live-smoke evidence all pass with ContractFixtureMode=false.",
    "- Fixture evidence is not used by the release pipeline as production evidence."
)

$reportText = [string]::Join([Environment]::NewLine, $reportLines) + [Environment]::NewLine
$reportContentValidated = $reportText.Contains("# Production External Evidence Acceptance") -and
    $reportText.Contains("production_driver_binding") -and
    $reportText.Contains("production_lua_patch_evidence") -and
    $reportText.Contains("live_model_endpoint_smoke") -and
    $reportText.Contains("Real host-project evidence accepted") -and
    -not $reportText.Contains("System.Collections") -and
    -not $reportText.Contains("@{")

New-Item -ItemType Directory -Force (Split-Path $reportPath -Parent) | Out-Null
$reportText | Set-Content -Path $reportPath -Encoding UTF8
$reportGenerated = Test-Path $reportPath
Add-AcceptanceCheck "markdown_report_content" ([bool]$reportGenerated -and [bool]$reportContentValidated) "Markdown report must summarize status, evidence areas, and fixture boundary without serialized object dumps."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })

$manifestFileName = Split-Path $manifestPath -Leaf
$reportFileName = Split-Path $reportPath -Leaf
$files = @($manifestFileName, $reportFileName)
foreach ($fileName in @(
    "production-driver-evidence-intake-manifest.json",
    "production-driver-evidence-intake-readiness-manifest.json",
    "production-lua-patch-readiness-manifest.json",
    "live-model-endpoint-smoke-evidence-intake-manifest.json",
    "live-model-endpoint-smoke-manifest.json",
    "live-model-endpoint-decision-trace.json"
)) {
    $path = Join-Path $acceptanceBundlePath $fileName
    if (Test-Path $path) {
        $files += "production-external-evidence-acceptance/$fileName"
    }
}

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_external_evidence_acceptance.v1"
    status = $status
    generatedAtUtc = $generatedAtUtc
    sourceEvidenceBundleDir = $evidenceBundlePath
    acceptanceBundleDir = $acceptanceBundlePath
    reportPath = $reportPath
    reportGenerated = [bool]$reportGenerated
    reportContentValidated = [bool]$reportContentValidated
    requireAllEvidence = [bool]$RequireAllEvidence
    contractFixtureMode = [bool]$ContractFixtureMode
    gameReplayDriverType = $GameReplayDriverType
    allRequiredExternalEvidenceFilesPresent = [bool]$allRequiredExternalEvidenceFilesPresent
    missingExternalEvidenceAreaCount = [int]$missingExternalEvidenceAreaCount
    failedAcceptanceCount = [int]$failedAcceptanceCount
    productionDriverEvidence = $driverEvidence
    productionLuaEvidence = $luaEvidence
    liveModelEndpointEvidence = $liveModelEvidence
    productionDriverEvidenceAccepted = [bool]$driverAccepted
    productionLuaEvidenceAccepted = [bool]$luaAccepted
    liveModelSmokeEvidenceAccepted = [bool]$liveAccepted
    allExternalEvidenceAccepted = [bool]$allExternalEvidenceAccepted
    realHostProjectEvidenceAccepted = [bool]$realHostProjectEvidenceAccepted
    releasePipelineUsesFixture = $false
    productionOutputBoundary = if ([bool]$ContractFixtureMode) {
        "accepted_fixture_external_evidence_acceptance_contract_only"
    } elseif ($realHostProjectEvidenceAccepted) {
        "real_host_project_external_evidence_accepted"
    } else {
        "external_evidence_not_accepted"
    }
    commandResults = @($commandResults)
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
    files = @($files)
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestPath -Encoding UTF8

if ([bool]$RequireAllEvidence -and $status -ne "PASS") {
    throw "Production external evidence acceptance failed. Manifest: $manifestPath"
}

Write-Output "Production external evidence acceptance manifest: $manifestPath"
Write-Output "AI TestPilot production external evidence acceptance status: $status"
