[CmdletBinding()]
param(
    [string]$OutputDir,
    [string]$ManifestPath,
    [string]$DriverTypeName = "Your.Game.Tests.ProductionReplayDriver",
    [string]$DriverId = "your_game.production_replay",
    [string]$DisplayName = "Your Game Production Replay Driver",
    [string]$QaAccountEnvironmentVariable = "AITESTPILOT_QA_ACCOUNT",
    [string]$ServerEnvironmentVariable = "AITESTPILOT_SERVER"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $repoRoot "Temp\production-driver-binding-kit\latest"
}

$outputPath = [System.IO.Path]::GetFullPath($OutputDir)
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $outputPath "production-driver-binding-kit-generated-manifest.json"
}

$manifestPath = [System.IO.Path]::GetFullPath($ManifestPath)

function Assert-NotBlank {
    param(
        [string]$Value,
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "$Name is required."
    }
}

function ConvertTo-CSharpLiteral {
    param([string]$Value)
    if ($null -eq $Value) {
        return ""
    }

    return ($Value -replace "\\", "\\") -replace '"', '\"'
}

function ConvertTo-PowerShellSingleQuotedLiteral {
    param([string]$Value)
    if ($null -eq $Value) {
        return "''"
    }

    return "'" + ($Value -replace "'", "''") + "'"
}

Assert-NotBlank $DriverTypeName "DriverTypeName"
Assert-NotBlank $DriverId "DriverId"
Assert-NotBlank $DisplayName "DisplayName"
Assert-NotBlank $QaAccountEnvironmentVariable "QaAccountEnvironmentVariable"
Assert-NotBlank $ServerEnvironmentVariable "ServerEnvironmentVariable"

$driverTypeParts = $DriverTypeName.Split(".")
if ($driverTypeParts.Count -lt 2) {
    throw "DriverTypeName must include namespace and class name, for example Your.Game.Tests.ProductionReplayDriver."
}

$driverClassName = $driverTypeParts[$driverTypeParts.Count - 1]
$driverNamespace = ($driverTypeParts[0..($driverTypeParts.Count - 2)] -join ".")

if ($driverNamespace -notmatch '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$') {
    throw "DriverTypeName namespace contains unsupported characters: $driverNamespace"
}

if ($driverClassName -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
    throw "DriverTypeName class contains unsupported characters: $driverClassName"
}

if (Test-Path $outputPath) {
    Remove-Item -LiteralPath $outputPath -Recurse -Force
}

New-Item -ItemType Directory -Force $outputPath | Out-Null

$driverFileName = "$driverClassName.cs"
$driverPath = Join-Path $outputPath $driverFileName
$hostScriptPath = Join-Path $outputPath "Invoke-ProductionDriverEvidence.ps1"
$exportScriptPath = Join-Path $outputPath "Export-ProductionDriverEvidenceBundle.ps1"
$readmePath = Join-Path $outputPath "README.md"
$checklistPath = Join-Path $outputPath "production-replay-integration-checklist.authoring.json"

$driverTemplate = @'
using System.Collections.Generic;
using Kibernet.AITestPilot.Unity;

namespace __NAMESPACE__
{
    public sealed class __CLASS__ : HookedGameActionReplayDriver
    {
        public __CLASS__()
            : base(
                "__DRIVER_ID__",
                new ProductionReplayHooks(),
                new GameActionReplayState(),
                BuildDescriptor())
        {
        }

        private static GameActionReplayDriverDescriptor BuildDescriptor()
        {
            return new GameActionReplayDriverDescriptor
            {
                driverId = "__DRIVER_ID__",
                displayName = "__DISPLAY_NAME__",
                supportedHandlerKeys = GameActionReplayDriverDescriptorFactory.StandardHandlerKeys(),
                configurationRequirements = new List<GameActionReplayConfigurationRequirement>
                {
                    new GameActionReplayConfigurationRequirement
                    {
                        key = "__QA_ENV__",
                        source = "environment",
                        required = true,
                        description = "QA account alias used by prepare_account and login."
                    },
                    new GameActionReplayConfigurationRequirement
                    {
                        key = "__SERVER_ENV__",
                        source = "environment",
                        required = true,
                        description = "Server or shard used by login and scene navigation."
                    }
                },
                notes = new List<string>
                {
                    "Return Pass only after the real game API call has completed and the expected state has been verified."
                }
            };
        }
    }

    internal sealed class ProductionReplayHooks : GameActionReplayHooksBase
    {
        public override GameActionReplayHookResult PrepareAccount(GameActionReplayHookContext context)
        {
            return GameActionReplayHookResult.Fail("Bind prepare_account to the game's account setup API before marking the integration plan BOUND.");
        }

        public override GameActionReplayHookResult Login(GameActionReplayHookContext context)
        {
            return GameActionReplayHookResult.Fail("Bind login to the game's login/session API before marking the integration plan BOUND.");
        }

        public override GameActionReplayHookResult EnterScene(GameActionReplayHookContext context)
        {
            return GameActionReplayHookResult.Fail("Bind enter_scene to the game's navigation API before marking the integration plan BOUND.");
        }

        public override GameActionReplayHookResult ClaimReward(GameActionReplayHookContext context)
        {
            return GameActionReplayHookResult.Fail("Bind claim_reward to the game's activity/reward API before marking the integration plan BOUND.");
        }

        public override GameActionReplayHookResult PlayFishing(GameActionReplayHookContext context)
        {
            return GameActionReplayHookResult.Fail("Bind play_fishing to the game's fishing/gameplay API before marking the integration plan BOUND.");
        }
    }
}
'@

$driverSource = $driverTemplate.
    Replace("__NAMESPACE__", $driverNamespace).
    Replace("__CLASS__", $driverClassName).
    Replace("__DRIVER_ID__", (ConvertTo-CSharpLiteral $DriverId)).
    Replace("__DISPLAY_NAME__", (ConvertTo-CSharpLiteral $DisplayName)).
    Replace("__QA_ENV__", (ConvertTo-CSharpLiteral $QaAccountEnvironmentVariable)).
    Replace("__SERVER_ENV__", (ConvertTo-CSharpLiteral $ServerEnvironmentVariable))

$hostScriptTemplate = @'
[CmdletBinding()]
param(
    [string]$AITestPilotRepoRoot = "__REPO_ROOT__",
    [string]$UnityPath = "F:\Unity\2021_3_45_f2\Editor\Unity.exe",
    [string]$EvidenceBundleDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $AITestPilotRepoRoot "Temp\release-evidence\latest"
}

$driverTypeName = "__DRIVER_TYPE__"

& (Join-Path $AITestPilotRepoRoot "tools\Invoke-AITestPilotRepairRetest.ps1") `
    -UnityPath $UnityPath `
    -GameReplayDriverType $driverTypeName `
    -EvidenceBundleDir $EvidenceBundleDir

& (Join-Path $AITestPilotRepoRoot "tools\Invoke-AITestPilotReplayDriverFailureProbe.ps1") `
    -UnityPath $UnityPath `
    -EvidenceBundleDir $EvidenceBundleDir

& (Join-Path $AITestPilotRepoRoot "tools\Invoke-AITestPilotReplayProfileImport.ps1") `
    -UnityPath $UnityPath `
    -EvidenceBundleDir $EvidenceBundleDir

& (Join-Path $AITestPilotRepoRoot "tools\Invoke-AITestPilotProductionReplayDriverReadiness.ps1") `
    -EvidenceBundleDir $EvidenceBundleDir `
    -RequireProductionBound

& (Join-Path $AITestPilotRepoRoot "tools\Invoke-AITestPilotProductionDriverEvidenceIntake.ps1") `
    -EvidenceBundleDir $EvidenceBundleDir

& (Join-Path $PSScriptRoot "Export-ProductionDriverEvidenceBundle.ps1") `
    -EvidenceBundleDir $EvidenceBundleDir
'@

$hostScript = $hostScriptTemplate.
    Replace("__REPO_ROOT__", ($repoRoot -replace "\\", "\\")).
    Replace("__DRIVER_TYPE__", $DriverTypeName)

$exportScriptTemplate = @'
[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$OutputDir,
    [string]$ZipPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    throw "EvidenceBundleDir is required."
}

$evidenceBundlePath = [System.IO.Path]::GetFullPath($EvidenceBundleDir)
if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path (Join-Path $evidenceBundlePath "production-driver-evidence-export") "production-driver-evidence"
}
$outputPath = [System.IO.Path]::GetFullPath($OutputDir)

if ([string]::IsNullOrWhiteSpace($ZipPath)) {
    $ZipPath = Join-Path (Split-Path $outputPath -Parent) "production-driver-evidence.zip"
}
$zipFullPath = [System.IO.Path]::GetFullPath($ZipPath)

$requiredFiles = @(
    "production-replay-integration-checklist.json",
    "repair-retest-manifest.json",
    "repair-driver-failure-manifest.json",
    "replay-profile-import-manifest.json"
)

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

$readinessPath = Join-Path $evidenceBundlePath "production-replay-driver-readiness-manifest.json"
$readiness = Read-JsonFile $readinessPath "Production replay driver readiness manifest"

$readyForExport = $readiness.status -eq "PASS" -and
    [bool]$readiness.readyForProductionDriverRelease -and
    [bool]$readiness.requireProductionBound -and
    $readiness.integrationChecklistStatus -eq "BOUND" -and
    [bool]$readiness.realProjectBound -and
    [int]$readiness.unresolvedRequiredHookCount -eq 0 -and
    [bool]$readiness.productionChecklistAllRequiredHooksBound -and
    [bool]$readiness.productionChecklistRequiredBindingMetadataComplete -and
    -not [bool]$readiness.sampleGameReplayDriverUsed -and
    [bool]$readiness.externalProductionDriverSelected -and
    [bool]$readiness.retestPassed -and
    [bool]$readiness.driverFailureProbePassed -and
    [bool]$readiness.replayProfileImportPassed -and
    [int]$readiness.blockingReasonCount -eq 0

if (-not $readyForExport) {
    throw "Production driver evidence export requires production-bound readiness with zero blockers. Current readiness: ready=$($readiness.readyForProductionDriverRelease), bound=$($readiness.realProjectBound), sample=$($readiness.sampleGameReplayDriverUsed), blockers=$($readiness.blockingReasonCount)."
}

$missingFiles = @()
foreach ($fileName in $requiredFiles) {
    if (-not (Test-Path (Join-Path $evidenceBundlePath $fileName))) {
        $missingFiles += $fileName
    }
}
if ($missingFiles.Count -gt 0) {
    throw "Production driver evidence export is missing required files: $($missingFiles -join ', ')"
}

$productionChecklist = Read-JsonFile (Join-Path $evidenceBundlePath "production-replay-integration-checklist.json") "Production replay integration checklist"

if (Test-Path $outputPath) {
    Remove-Item -LiteralPath $outputPath -Recurse -Force
}
New-Item -ItemType Directory -Force $outputPath | Out-Null

foreach ($fileName in $requiredFiles) {
    Copy-Item -LiteralPath (Join-Path $evidenceBundlePath $fileName) -Destination (Join-Path $outputPath $fileName) -Force
}

New-Item -ItemType Directory -Force (Split-Path $zipFullPath -Parent) | Out-Null
if (Test-Path $zipFullPath) {
    Remove-Item -LiteralPath $zipFullPath -Force
}
Compress-Archive -LiteralPath $outputPath -DestinationPath $zipFullPath -Force

$manifestPath = Join-Path (Split-Path $outputPath -Parent) "production-driver-evidence-export-manifest.json"
$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_driver_evidence_export.v1"
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    outputDir = $outputPath
    zipPath = $zipFullPath
    driverTypeName = [string]$productionChecklist.driverTypeName
    gameReplayDriverId = [string]$readiness.gameReplayDriverId
    readyForProductionDriverRelease = [bool]$readiness.readyForProductionDriverRelease
    realProjectBound = [bool]$readiness.realProjectBound
    sampleGameReplayDriverUsed = [bool]$readiness.sampleGameReplayDriverUsed
    externalProductionDriverSelected = [bool]$readiness.externalProductionDriverSelected
    blockingReasonCount = [int]$readiness.blockingReasonCount
    requiredFiles = @($requiredFiles)
    exportedFileCount = [int]$requiredFiles.Count
    productionEvidenceExported = $true
    productionEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
}
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

Write-Output "Production driver evidence export: $outputPath"
Write-Output "Production driver evidence export zip: $zipFullPath"
Write-Output "Production driver evidence export manifest: $manifestPath"
Write-Output "PASS AI TestPilot production driver evidence export"
'@

$readmeTemplate = @'
# AI TestPilot Production Driver Binding Kit

This kit is a host-project starting point. It is not production-bound evidence.

## Files

- `__DRIVER_FILE__`: copy into the host Unity test assembly, then replace each failing hook with real game API calls and state verification.
- `production-replay-integration-checklist.authoring.json`: owner/API/verification checklist for the five required hooks.
- `Invoke-ProductionDriverEvidence.ps1`: host CI helper that runs retest, profile import, readiness, and evidence intake after the real hooks and BOUND checklist exist.
- `Export-ProductionDriverEvidenceBundle.ps1`: packages the four required production driver evidence files into a `production-driver-evidence` folder and zip, but only after production-bound readiness passes with zero blockers.

## Driver

- Driver type: `__DRIVER_TYPE__`
- Driver id: `__DRIVER_ID__`
- QA account env: `__QA_ENV__`
- Server env: `__SERVER_ENV__`

## Required acceptance boundary

Do not set `realProjectBound=true` until every generated hook returns `Pass` only after calling the host game's production API and verifying resulting state. The final evidence bundle must pass:

```powershell
.\tools\Invoke-AITestPilotProductionDriverEvidenceIntake.ps1 -EvidenceBundleDir "path\to\release-evidence"
```

The full production CI path is:

```powershell
.\tools\Invoke-AITestPilotReleasePipeline.ps1 -GameReplayDriverType "__DRIVER_TYPE__" -RequireProductionReplayDriverBound
```
'@

$readme = $readmeTemplate.
    Replace("__DRIVER_FILE__", $driverFileName).
    Replace("__DRIVER_TYPE__", $DriverTypeName).
    Replace("__DRIVER_ID__", $DriverId).
    Replace("__QA_ENV__", $QaAccountEnvironmentVariable).
    Replace("__SERVER_ENV__", $ServerEnvironmentVariable)

$checklist = [ordered]@{
    schemaVersion = "aitestpilot.production_driver_binding_kit.authoring.v1"
    status = "TEMPLATE_READY"
    realProjectBound = $false
    driverTypeName = $DriverTypeName
    driverId = $DriverId
    qaAccountEnvironmentVariable = $QaAccountEnvironmentVariable
    serverEnvironmentVariable = $ServerEnvironmentVariable
    requiredHookCount = 5
    boundRequiredHookCount = 0
    unresolvedRequiredHookCount = 5
    hooks = @(
        [ordered]@{ action = "prepare_account"; handlerKey = "game.prepare_account"; owner = ""; gameApiSurface = ""; verificationSignal = ""; boundToRealGameApi = $false },
        [ordered]@{ action = "login"; handlerKey = "game.login"; owner = ""; gameApiSurface = ""; verificationSignal = ""; boundToRealGameApi = $false },
        [ordered]@{ action = "enter_scene"; handlerKey = "game.enter_scene"; owner = ""; gameApiSurface = ""; verificationSignal = ""; boundToRealGameApi = $false },
        [ordered]@{ action = "claim_reward"; handlerKey = "game.claim_reward"; owner = ""; gameApiSurface = ""; verificationSignal = ""; boundToRealGameApi = $false },
        [ordered]@{ action = "play_fishing"; handlerKey = "game.play_fishing"; owner = ""; gameApiSurface = ""; verificationSignal = ""; boundToRealGameApi = $false }
    )
}

$driverSource | Set-Content -Path $driverPath -Encoding UTF8
$hostScript | Set-Content -Path $hostScriptPath -Encoding UTF8
$exportScriptTemplate | Set-Content -Path $exportScriptPath -Encoding UTF8
$readme | Set-Content -Path $readmePath -Encoding UTF8
$checklist | ConvertTo-Json -Depth 10 | Set-Content -Path $checklistPath -Encoding UTF8

$generatedFiles = @(
    $driverFileName,
    "Invoke-ProductionDriverEvidence.ps1",
    "Export-ProductionDriverEvidenceBundle.ps1",
    "README.md",
    "production-replay-integration-checklist.authoring.json"
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_driver_binding_kit.generated.v1"
    status = "PASS"
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    outputDir = $outputPath
    driverTypeName = $DriverTypeName
    driverNamespace = $driverNamespace
    driverClassName = $driverClassName
    driverId = $DriverId
    displayName = $DisplayName
    qaAccountEnvironmentVariable = $QaAccountEnvironmentVariable
    serverEnvironmentVariable = $ServerEnvironmentVariable
    requiredHookCount = 5
    generatedHookCount = 5
    generatedHooksFailUntilBound = $true
    exportHelperGenerated = $true
    exportHelperRequiresProductionBoundReadiness = $true
    readyForProductionDriverRelease = $false
    productionEvidenceAccepted = $false
    generatedKitOnly = $true
    nextRequiredEvidenceFiles = @(
        "production-replay-integration-checklist.json",
        "repair-retest-manifest.json",
        "repair-driver-failure-manifest.json",
        "replay-profile-import-manifest.json"
    )
    generatedFiles = @($generatedFiles)
}

New-Item -ItemType Directory -Force (Split-Path $manifestPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

Write-Output "Production driver binding kit: $outputPath"
Write-Output "Production driver binding kit manifest: $manifestPath"
Write-Output "PASS AI TestPilot production driver binding kit generation"
