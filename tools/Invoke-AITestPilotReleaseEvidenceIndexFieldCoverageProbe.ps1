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

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($ProbeWorkDir)) {
    $ProbeWorkDir = Join-Path $repoRoot "Temp\release-evidence\release-evidence-index-field-coverage-probe-work"
}

if ([string]::IsNullOrWhiteSpace($ProbeOutputDir)) {
    $ProbeOutputDir = Join-Path $EvidenceBundleDir "release-evidence-index-field-coverage-probe"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "release-evidence-index-field-coverage-probe-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "release-evidence-index-field-coverage-probe.md"
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

function Convert-ToEvidenceRelativePath {
    param([string]$Path)

    $fullPath = Resolve-FullPath $Path
    if (-not (Test-PathWithinRoot $fullPath $evidenceBundlePath)) {
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

function Set-JsonField {
    param(
        [string]$Path,
        [string]$FieldName,
        [object]$Value
    )

    $json = Read-JsonFile $Path "Scenario JSON"
    $property = $json.PSObject.Properties[$FieldName]
    if ($null -eq $property) {
        $json | Add-Member -NotePropertyName $FieldName -NotePropertyValue $Value
    }
    else {
        $property.Value = $Value
    }
    $json | ConvertTo-Json -Depth 20 | Set-Content -Path $Path -Encoding UTF8
}

function Test-SnapshotPathExcluded {
    param(
        [string]$RelativePath,
        [string[]]$ExcludedRelativePaths
    )

    $normalizedPath = $RelativePath.Replace("\", "/").TrimStart([char[]]@("/", "\"))
    foreach ($excludedPath in @($ExcludedRelativePaths)) {
        $normalizedExcludedPath = ([string]$excludedPath).Replace("\", "/").TrimStart([char[]]@("/", "\")).TrimEnd([char[]]@("/", "\"))
        if ([string]::IsNullOrWhiteSpace($normalizedExcludedPath)) {
            continue
        }

        if ($normalizedPath -ieq $normalizedExcludedPath -or $normalizedPath.StartsWith($normalizedExcludedPath + "/", [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Get-Snapshot {
    param(
        [string]$BundleDir,
        [string[]]$ExcludedRelativePaths = @()
    )

    $bundleFullPath = Assert-PathUnderRepo $BundleDir "Snapshot bundle"
    $files = @()
    $hashes = [ordered]@{}
    foreach ($file in @(Get-ChildItem -Path $BundleDir -File -Recurse)) {
        $fileFullPath = Resolve-FullPath $file.FullName
        if (-not (Test-PathWithinRoot $fileFullPath $bundleFullPath)) {
            throw "Snapshot file must stay under bundle: $fileFullPath"
        }

        $relativePath = $fileFullPath.Substring($bundleFullPath.Length).TrimStart([char[]]@("\", "/")).Replace("\", "/")
        if (Test-SnapshotPathExcluded $relativePath $ExcludedRelativePaths) {
            continue
        }

        $files += $relativePath
        $hashes[$relativePath] = (Get-FileHash -Algorithm SHA256 -Path $file.FullName).Hash
    }

    return [ordered]@{
        fileCount = [int]$files.Count
        manifestFileCount = [int]@($files | Where-Object { $_ -like "*manifest.json" }).Count
        hashes = $hashes
    }
}

function Test-SnapshotUnchanged {
    param(
        [object]$Before,
        [object]$After
    )

    if ([int]$Before.manifestFileCount -ne [int]$After.manifestFileCount) {
        return $false
    }

    if ([int]$Before.fileCount -ne [int]$After.fileCount) {
        return $false
    }

    $beforeHashNames = @($Before.hashes.Keys | ForEach-Object { [string]$_ })
    $afterHashNames = @($After.hashes.Keys | ForEach-Object { [string]$_ })
    if ($beforeHashNames.Count -ne $afterHashNames.Count) {
        return $false
    }

    foreach ($name in $beforeHashNames) {
        if ($afterHashNames -notcontains $name) {
            return $false
        }

        if ([string]$Before.hashes[$name] -ne [string]$After.hashes[$name]) {
            return $false
        }
    }

    return $true
}

function Invoke-IndexScenario {
    param(
        [string]$Name,
        [scriptblock]$Mutate,
        [bool]$ExpectPass,
        [string[]]$ExpectedBlockingReasons,
        [string]$ExpectedFailedFieldName = "",
        [switch]$RequireLiveModelEndpointSmoke,
        [switch]$ContractFixtureMode
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

    $indexOutput = @()
    $indexThrew = $false
    $indexError = ""
    try {
        $indexOutput = & (Join-Path $repoRoot "tools\Invoke-AITestPilotReleaseEvidenceIndex.ps1") `
            -EvidenceBundleDir $scenarioDir `
            -IndexPath (Join-Path $scenarioDir "release-evidence-index.json") `
            -ReportPath (Join-Path $scenarioDir "release-evidence-index.md") `
            -ManifestPath (Join-Path $scenarioDir "release-evidence-index-manifest.json") `
            -RequireLiveModelEndpointSmoke:$RequireLiveModelEndpointSmoke `
            -ContractFixtureMode:$ContractFixtureMode
    }
    catch {
        $indexThrew = $true
        $indexError = $_.Exception.Message
    }

    $indexManifestPath = Join-Path $scenarioDir "release-evidence-index-manifest.json"
    $indexPath = Join-Path $scenarioDir "release-evidence-index.json"
    $indexManifestExists = Test-Path $indexManifestPath
    $indexExists = Test-Path $indexPath
    $indexManifest = $null
    $index = $null
    if ($indexManifestExists) {
        $indexManifest = Read-JsonFile $indexManifestPath "$Name index manifest"
    }
    if ($indexExists) {
        $index = Read-JsonFile $indexPath "$Name index"
    }

    $blockingReasons = @()
    if ($null -ne $indexManifest) {
        $blockingReasons = @($indexManifest.blockingReasons | ForEach-Object { [string]$_ })
    }

    $failedChecks = @()
    if ($null -ne $index -and $null -ne $index.fieldLevelCoverage) {
        $failedChecks = @($index.fieldLevelCoverage.failedChecks)
    }
    $failedFieldNames = @($failedChecks | ForEach-Object { [string]$_.fieldName })
    $expectedBlockingReasonSet = @($ExpectedBlockingReasons | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    $actualBlockingReasonSet = @($blockingReasons | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    $blockingReasonsMatchedExactly = $expectedBlockingReasonSet.Count -eq $actualBlockingReasonSet.Count
    if ($blockingReasonsMatchedExactly) {
        foreach ($expectedBlockingReason in $expectedBlockingReasonSet) {
            if ($actualBlockingReasonSet -notcontains $expectedBlockingReason) {
                $blockingReasonsMatchedExactly = $false
                break
            }
        }
    }
    $failedFieldMatched = [string]::IsNullOrWhiteSpace($ExpectedFailedFieldName) -or ($failedFieldNames -contains $ExpectedFailedFieldName)

    $passed = if ($ExpectPass) {
        (-not $indexThrew -and $null -ne $indexManifest -and $indexManifest.status -eq "PASS" -and $indexManifest.fieldLevelCoverageStatus -eq "PASS")
    }
    else {
        ($null -ne $indexManifest -and $indexManifest.status -eq "BLOCKED" -and
            $blockingReasonsMatchedExactly -and
            $failedFieldMatched)
    }

    $result = [ordered]@{
        name = $Name
        expectPass = [bool]$ExpectPass
        passed = [bool]$passed
        indexThrew = [bool]$indexThrew
        indexError = $indexError
        indexManifestExists = [bool]$indexManifestExists
        indexExists = [bool]$indexExists
        indexStatus = if ($null -ne $indexManifest) { [string]$indexManifest.status } else { "MISSING" }
        fieldLevelCoverageStatus = if ($null -ne $indexManifest) { [string]$indexManifest.fieldLevelCoverageStatus } else { "MISSING" }
        blockingReasonsMatchedExactly = [bool]$blockingReasonsMatchedExactly
        expectedBlockingReasons = @($ExpectedBlockingReasons)
        blockingReasons = @($blockingReasons)
        expectedFailedFieldName = $ExpectedFailedFieldName
        failedFieldNames = @($failedFieldNames)
        output = @($indexOutput | ForEach-Object { [string]$_ })
    }

    $resultPath = Join-Path $probeOutputPath "$Name-result.json"
    $result | ConvertTo-Json -Depth 12 | Set-Content -Path $resultPath -Encoding UTF8
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

$snapshotExcludedRelativePaths = @(
    (Convert-ToEvidenceRelativePath $manifestFullPath),
    (Convert-ToEvidenceRelativePath $reportFullPath),
    (Convert-ToEvidenceRelativePath $probeOutputPath)
)

$beforeSnapshot = Get-Snapshot $evidenceBundlePath -ExcludedRelativePaths $snapshotExcludedRelativePaths

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
$scenarioResults += Invoke-IndexScenario `
    -Name "baseline-pass-copy" `
    -Mutate {} `
    -ExpectPass $true `
    -ExpectedBlockingReasons @()

$scenarioResults += Invoke-IndexScenario `
    -Name "owner-send-auto-email-promoted" `
    -Mutate {
        param($ScenarioDir)
        Set-JsonField (Join-Path $ScenarioDir "production-handoff-send-readiness-manifest.json") "automaticEmailSendReady" $true
    } `
    -ExpectPass $false `
    -ExpectedBlockingReasons @("field_level_coverage_failed") `
    -ExpectedFailedFieldName "automaticEmailSendReady"

$scenarioResults += Invoke-IndexScenario `
    -Name "owner-packet-fake-receipt-promoted" `
    -Mutate {
        param($ScenarioDir)
        Set-JsonField (Join-Path $ScenarioDir "production-handoff-owner-packet-dispatch-receipt-intake-probe-manifest.json") "fakeReceiptAcceptedByIntake" $true
    } `
    -ExpectPass $false `
    -ExpectedBlockingReasons @("field_level_coverage_failed") `
    -ExpectedFailedFieldName "fakeReceiptAcceptedByIntake"

$scenarioResults += Invoke-IndexScenario `
    -Name "semantic-preflight-not-readonly" `
    -Mutate {
        param($ScenarioDir)
        Set-JsonField (Join-Path $ScenarioDir "production-external-evidence-semantic-preflight-probe-manifest.json") "readOnly" $false
    } `
    -ExpectPass $false `
    -ExpectedBlockingReasons @("field_level_coverage_failed") `
    -ExpectedFailedFieldName "readOnly"

$scenarioResults += Invoke-IndexScenario `
    -Name "handoff-export-next-steps-unvalidated" `
    -Mutate {
        param($ScenarioDir)
        Set-JsonField (Join-Path $ScenarioDir "production-handoff-export-manifest.json") "operatorActionNextStepsContentValidated" $false
    } `
    -ExpectPass $false `
    -ExpectedBlockingReasons @("field_level_coverage_failed") `
    -ExpectedFailedFieldName "operatorActionNextStepsContentValidated"

$scenarioResults += Invoke-IndexScenario `
    -Name "live-smoke-fixture-rejected-without-contract" `
    -Mutate {
        param($ScenarioDir)
        $liveSmokePath = Join-Path $ScenarioDir "live-model-endpoint-smoke-manifest.json"
        Set-JsonField $liveSmokePath "status" "PASS"
        Set-JsonField $liveSmokePath "fixtureOnly" $true
        Set-JsonField $liveSmokePath "contractFixtureMode" $true
        Set-JsonField $liveSmokePath "realProviderAccessProven" $false
        Set-JsonField $liveSmokePath "productionLiveEndpointAccessProven" $false
        Set-JsonField $liveSmokePath "liveSmokeExecuted" $false
    } `
    -ExpectPass $false `
    -ExpectedBlockingReasons @("source_manifest_status_not_accepted") `
    -RequireLiveModelEndpointSmoke

$afterSnapshot = Get-Snapshot $evidenceBundlePath -ExcludedRelativePaths $snapshotExcludedRelativePaths
$latestSnapshotUnchanged = Test-SnapshotUnchanged $beforeSnapshot $afterSnapshot
$failedScenarios = @($scenarioResults | Where-Object { -not [bool]$_["passed"] })
$status = if ($failedScenarios.Count -eq 0 -and $latestSnapshotUnchanged) { "PASS" } else { "FAIL" }

$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestFullPath),
    (Convert-ToEvidenceRelativePath $reportFullPath),
    (Convert-ToEvidenceRelativePath $probeOutputPath)
)
$sourceFiles = @(
    "release-evidence-index-manifest.json",
    "release-evidence-index.json",
    "release-evidence-index.md",
    "production-handoff-send-readiness-manifest.json",
    "production-handoff-owner-packet-dispatch-receipt-intake-probe-manifest.json",
    "production-external-evidence-semantic-preflight-probe-manifest.json",
    "live-model-endpoint-smoke-manifest.json"
)

$reportLines = @(
    "# AI TestPilot Release Evidence Index Field Coverage Probe",
    "",
    "- Status: $status",
    "- Scenario count: $($scenarioResults.Count)",
    "- Failed scenario count: $($failedScenarios.Count)",
    "- Latest snapshot unchanged: $latestSnapshotUnchanged",
    "",
    "## Scenarios",
    "",
    "| Scenario | Passed | Index status | Field coverage status | Blocking reasons | Failed fields |",
    "| --- | --- | --- | --- | --- | --- |"
)
foreach ($scenario in $scenarioResults) {
    $reportLines += "| $($scenario["name"]) | $($scenario["passed"]) | $($scenario["indexStatus"]) | $($scenario["fieldLevelCoverageStatus"]) | $(([string]::Join(", ", @($scenario["blockingReasons"]))).Replace("|", "\|")) | $(([string]::Join(", ", @($scenario["failedFieldNames"]))).Replace("|", "\|")) |"
}

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.release_evidence_index_field_coverage_probe.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    probeWorkDir = $workPath
    probeOutputDir = $probeOutputPath
    scenarioCount = [int]$scenarioResults.Count
    failedScenarioCount = [int]$failedScenarios.Count
    latestSnapshotUnchanged = [bool]$latestSnapshotUnchanged
    beforeManifestFileCount = [int]$beforeSnapshot.manifestFileCount
    afterManifestFileCount = [int]$afterSnapshot.manifestFileCount
    scenarios = @($scenarioResults)
    releasePipelineSendsEmail = $false
    realHostProjectEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "release_evidence_index_field_coverage_probe_isolated_copies_only"
    sourceFiles = @($sourceFiles)
    generatedFiles = @($generatedFiles)
    files = @($generatedFiles + $sourceFiles)
}

$reportLines | Set-Content -Path $reportFullPath -Encoding UTF8
$manifest | ConvertTo-Json -Depth 14 | Set-Content -Path $manifestFullPath -Encoding UTF8

if ($status -ne "PASS") {
    throw "AI TestPilot release evidence index field coverage probe failed. Manifest: $manifestFullPath"
}

Write-Output "Release evidence index field coverage probe manifest: $manifestFullPath"
Write-Output "Release evidence index field coverage probe report: $reportFullPath"
Write-Output "PASS AI TestPilot release evidence index field coverage probe"
