[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$AcceptanceBundleDir,
    [string]$ManifestPath,
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

$evidenceBundlePath = Resolve-FullPath $EvidenceBundleDir
$acceptanceBundlePath = Assert-PathUnderRepo $AcceptanceBundleDir "AcceptanceBundleDir"
$manifestPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"

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

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($allExternalEvidenceAccepted) {
    "PASS"
} elseif ([bool]$RequireAllEvidence) {
    "FAIL"
} else {
    "PENDING_EXTERNAL_EVIDENCE"
}

$files = @("production-external-evidence-acceptance-manifest.json")
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
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    sourceEvidenceBundleDir = $evidenceBundlePath
    acceptanceBundleDir = $acceptanceBundlePath
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
