[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$ProbeWorkDir,
    [string]$ProbeOutputDir,
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

if ([string]::IsNullOrWhiteSpace($ProbeWorkDir)) {
    $ProbeWorkDir = Join-Path $repoRoot "Temp\release-evidence\production-handoff-owner-route-map-probe-work"
}

if ([string]::IsNullOrWhiteSpace($ProbeOutputDir)) {
    $ProbeOutputDir = Join-Path $EvidenceBundleDir "production-handoff-owner-route-map-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-handoff-owner-route-map-probe-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-handoff-owner-route-map-probe.md"
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

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $Value | ConvertTo-Json -Depth 14 | Set-Content -Path $Path -Encoding UTF8
}

function Set-JsonProperty {
    param(
        [object]$InputObject,
        [string]$Name,
        [object]$Value
    )

    $InputObject | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
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

function Invoke-RouteMapScenario {
    param(
        [string]$Name,
        [scriptblock]$Mutate,
        [bool]$ExpectPass,
        [string[]]$ExpectedFailedCheckNames = @()
    )

    $scenarioDir = Join-Path $workPath $Name
    if (Test-Path $scenarioDir) {
        Remove-Item -LiteralPath $scenarioDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force $scenarioDir | Out-Null
    Copy-Item -Path (Join-Path $evidenceBundlePath "*") -Destination $scenarioDir -Recurse -Force

    if ($null -ne $Mutate) {
        & $Mutate $scenarioDir
    }

    $scenarioManifestPath = Join-Path $scenarioDir "production-handoff-owner-route-map-manifest.json"
    $scenarioReportPath = Join-Path $scenarioDir "production-handoff-owner-route-map.md"
    $routeMapThrew = $false
    $routeMapError = ""
    $routeMapOutput = @()
    try {
        $routeMapOutput = & (Join-Path $repoRoot "tools\Invoke-AITestPilotProductionHandoffOwnerRouteMap.ps1") `
            -EvidenceBundleDir $scenarioDir `
            -ManifestPath $scenarioManifestPath `
            -ReportPath $scenarioReportPath
    }
    catch {
        $routeMapThrew = $true
        $routeMapError = $_.Exception.Message
    }

    $scenarioManifest = Read-JsonFile $scenarioManifestPath "$Name owner route map manifest"
    $failedCheckNames = @((Get-JsonValue $scenarioManifest "checks" @()) | Where-Object {
            -not [bool](Get-JsonValue $_ "passed" $false)
        } | ForEach-Object {
            [string](Get-JsonValue $_ "name" "")
        })
    $matchedExpectedFailedChecks = @($ExpectedFailedCheckNames | Where-Object { $failedCheckNames -contains $_ })

    $passed = if ($ExpectPass) {
        (-not $routeMapThrew -and [string](Get-JsonValue $scenarioManifest "status" "") -eq "PASS" -and [int](Get-JsonValue $scenarioManifest "failedCheckCount" 0) -eq 0)
    }
    else {
        ($routeMapThrew -and [string](Get-JsonValue $scenarioManifest "status" "") -eq "FAIL" -and $matchedExpectedFailedChecks.Count -eq $ExpectedFailedCheckNames.Count)
    }

    $result = [ordered]@{
        name = $Name
        expectPass = [bool]$ExpectPass
        passed = [bool]$passed
        routeMapThrew = [bool]$routeMapThrew
        routeMapError = $routeMapError
        routeMapStatus = [string](Get-JsonValue $scenarioManifest "status" "")
        failedCheckCount = [int](Get-JsonValue $scenarioManifest "failedCheckCount" 0)
        expectedFailedCheckNames = @($ExpectedFailedCheckNames)
        matchedExpectedFailedCheckNames = @($matchedExpectedFailedChecks)
        failedCheckNames = @($failedCheckNames)
        routeMapOutput = @($routeMapOutput | ForEach-Object { [string]$_ })
    }

    $resultPath = Join-Path $probeOutputPath "$Name-result.json"
    Write-JsonFile $resultPath $result
    return $result
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$workPath = Assert-PathUnderRepo $ProbeWorkDir "ProbeWorkDir"
$probeOutputPath = Assert-PathUnderRepo $ProbeOutputDir "ProbeOutputDir"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if (Test-Path $workPath) {
    Remove-Item -LiteralPath $workPath -Recurse -Force
}
if (Test-Path $probeOutputPath) {
    Remove-Item -LiteralPath $probeOutputPath -Recurse -Force
}
New-Item -ItemType Directory -Force $workPath | Out-Null
New-Item -ItemType Directory -Force $probeOutputPath | Out-Null
New-Item -ItemType Directory -Force (Split-Path $manifestFullPath -Parent) | Out-Null
New-Item -ItemType Directory -Force (Split-Path $reportFullPath -Parent) | Out-Null

$scenarioResults = @()
$scenarioResults += Invoke-RouteMapScenario `
    -Name "baseline-current-route-map-passes" `
    -Mutate $null `
    -ExpectPass $true

$scenarioResults += Invoke-RouteMapScenario `
    -Name "owner-route-mismatch-blocked" `
    -Mutate {
        param($ScenarioDir)
        $path = Join-Path $ScenarioDir "production-handoff-contact-readiness-manifest.json"
        $manifest = Read-JsonFile $path "Contact readiness manifest"
        $manifest.contactStatuses[0].ownerPacketPath = "production-handoff-package/owner-packets/wrong-owner.md"
        Write-JsonFile $path $manifest
    } `
    -ExpectPass $false `
    -ExpectedFailedCheckNames @("owner_route_cross_artifact_links")

$scenarioResults += Invoke-RouteMapScenario `
    -Name "missing-route-endpoint-blocked" `
    -Mutate {
        param($ScenarioDir)
        $path = Join-Path $ScenarioDir "production-external-evidence-action-queue-manifest.json"
        $manifest = Read-JsonFile $path "Action queue manifest"
        $manifest.actionQueue[0].ownerResponseBundleRequiredFilesPath = ""
        $manifest.actionQueue[0].hardValidationCommand = ""
        Write-JsonFile $path $manifest
    } `
    -ExpectPass $false `
    -ExpectedFailedCheckNames @("owner_route_cross_artifact_links", "owner_route_command_coverage")

$scenarioResults += Invoke-RouteMapScenario `
    -Name "auto-acceptance-without-semantic-preflight-blocked" `
    -Mutate {
        param($ScenarioDir)
        $path = Join-Path $ScenarioDir "production-external-evidence-action-queue-manifest.json"
        $manifest = Read-JsonFile $path "Action queue manifest"
        $manifest.actionQueue[0].ownerResponseBundleZipSemanticPreflightCommand = ""
        Write-JsonFile $path $manifest
    } `
    -ExpectPass $false `
    -ExpectedFailedCheckNames @("owner_route_cross_artifact_links", "owner_route_command_coverage")

$failedScenarios = @($scenarioResults | Where-Object { -not [bool]$_["passed"] })
$status = if ($failedScenarios.Count -eq 0) { "PASS" } else { "FAIL" }

$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestFullPath),
    (Convert-ToEvidenceRelativePath $reportFullPath),
    (Convert-ToEvidenceRelativePath $probeOutputPath)
)
$sourceFiles = @(
    "production-handoff-owner-route-map-manifest.json",
    "production-external-evidence-action-queue-manifest.json",
    "production-external-evidence-gap-analysis-manifest.json",
    "production-handoff-contact-readiness-manifest.json",
    "production-handoff-send-readiness-manifest.json",
    "production-handoff-owner-response-bundle-kit-manifest.json",
    "production-external-evidence-inbox-manifest.json"
)

$reportLines = @(
    "# AI TestPilot Production Handoff Owner Route Map Probe",
    "",
    "- Status: $status",
    "- Scenario count: $($scenarioResults.Count)",
    "- Failed scenario count: $($failedScenarios.Count)",
    "",
    "| Scenario | Expected pass | Passed | Route map status | Matched failed checks |",
    "| --- | --- | --- | --- | --- |"
)
foreach ($scenario in $scenarioResults) {
    $reportLines += "| $($scenario["name"]) | $($scenario["expectPass"]) | $($scenario["passed"]) | $($scenario["routeMapStatus"]) | $(([string]::Join(", ", @($scenario["matchedExpectedFailedCheckNames"]))).Replace("|", "\|")) |"
}

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_owner_route_map_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    probeWorkDir = $workPath
    probeOutputDir = $probeOutputPath
    scenarioCount = [int]$scenarioResults.Count
    failedScenarioCount = [int]$failedScenarios.Count
    baselineCurrentRouteMapPassed = [bool]($scenarioResults[0]["passed"])
    ownerRouteMismatchBlocked = [bool]($scenarioResults[1]["passed"])
    missingRouteEndpointBlocked = [bool]($scenarioResults[2]["passed"])
    autoAcceptanceWithoutSemanticPreflightBlocked = [bool]($scenarioResults[3]["passed"])
    scenarios = @($scenarioResults)
    releasePipelineSendsEmail = $false
    realHostProjectEvidenceAccepted = $false
    externalEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "production_handoff_owner_route_map_probe_only"
    sourceFiles = @($sourceFiles)
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles + $sourceFiles)
}

$reportLines | Set-Content -Path $reportFullPath -Encoding UTF8
Write-JsonFile $manifestFullPath $manifest

if ($status -ne "PASS") {
    throw "AI TestPilot production handoff owner route map probe failed. Manifest: $manifestFullPath"
}

Write-Output "Production handoff owner route map probe manifest: $manifestFullPath"
Write-Output "Production handoff owner route map probe report: $reportFullPath"
Write-Output "PASS AI TestPilot production handoff owner route map probe"
