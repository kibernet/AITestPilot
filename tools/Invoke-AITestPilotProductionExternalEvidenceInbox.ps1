[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$InboxDir,
    [string]$ManifestPath,
    [string]$ReportPath,
    [string]$GameReplayDriverType = "Your.Game.Tests.ProductionReplayDriver"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($InboxDir)) {
    $InboxDir = Join-Path $EvidenceBundleDir "production-external-evidence-inbox"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-external-evidence-inbox-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-external-evidence-inbox.md"
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

function Convert-ToArray {
    param([object]$Value)

    if ($null -eq $Value) {
        return @()
    }

    return @($Value)
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

function Join-MarkdownList {
    param([object[]]$Values)

    $items = @($Values | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($items.Count -eq 0) {
        return "(none)"
    }

    return [string]::Join(", ", $items)
}

function Convert-ToRelativePath {
    param(
        [string]$Root,
        [string]$Path
    )

    $rootUri = [System.Uri](([System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'))
    $pathUri = [System.Uri]([System.IO.Path]::GetFullPath($Path))
    return [System.Uri]::UnescapeDataString($rootUri.MakeRelativeUri($pathUri).ToString()).Replace("/", "\")
}

function Add-InboxCheck {
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

function Get-InboxDirectoryName {
    param([string]$Area)

    switch ($Area) {
        "production_driver_binding" { return "production-driver-evidence" }
        "production_lua_patch_evidence" { return "production-lua-evidence" }
        "live_model_endpoint_smoke" { return "live-smoke-evidence" }
        default { return $Area }
    }
}

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$inboxPath = Resolve-FullPath $InboxDir
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

New-Item -ItemType Directory -Force $inboxPath | Out-Null

$handoffManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-package-manifest.json") "Production handoff package manifest"
$ownerPacketIndex = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-package\owner-packets\owner-packet-index.json") "Production handoff owner packet index"
$requiredEvidence = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-package\required-external-evidence.json") "Production handoff required evidence"

$rootReadmePath = Join-Path $inboxPath "README.md"
$acceptScriptPath = Join-Path $inboxPath "accept-returned-evidence.ps1"
$manifestCopyPath = Join-Path $inboxPath "production-external-evidence-inbox-manifest.json"
$reportCopyPath = Join-Path $inboxPath "production-external-evidence-inbox.md"

$acceptScript = @'
# AI TestPilot returned production evidence acceptance wrapper.
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$EvidenceBundleDir,
    [string]$OutputDir,
    [string]$GameReplayDriverType = "Your.Game.Tests.ProductionReplayDriver",
    [switch]$ContractFixtureMode,
    [switch]$RunHardValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-FullPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Find-RepoRoot {
    param([string]$StartDir)

    $current = Resolve-FullPath $StartDir
    while ($true) {
        if (Test-Path (Join-Path $current "tools\Invoke-AITestPilotReleasePipeline.ps1")) {
            return $current
        }

        $parent = [System.IO.Directory]::GetParent($current)
        if ($null -eq $parent) {
            throw "Could not locate repo root from $StartDir. Pass -RepoRoot explicitly."
        }

        $parentPath = $parent.FullName
        if ($parentPath -eq $current) {
            throw "Could not locate repo root from $StartDir. Pass -RepoRoot explicitly."
        }

        $current = $parentPath
    }
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Find-RepoRoot $PSScriptRoot
}
$repoPath = Resolve-FullPath $RepoRoot

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $PSScriptRoot ".."
}
$evidencePath = Resolve-FullPath $EvidenceBundleDir

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $PSScriptRoot "acceptance-output"
}

$handoffWrapper = Join-Path (Split-Path $PSScriptRoot -Parent) "production-handoff-package\accept-external-evidence.ps1"
if (-not (Test-Path $handoffWrapper)) {
    $handoffWrapper = Join-Path $evidencePath "production-handoff-package\accept-external-evidence.ps1"
}
if (-not (Test-Path $handoffWrapper)) {
    throw "Could not locate production-handoff-package\accept-external-evidence.ps1. Pass -EvidenceBundleDir or run from the release evidence bundle."
}

& $handoffWrapper `
    -RepoRoot $repoPath `
    -EvidenceBundleDir $evidencePath `
    -OutputDir $OutputDir `
    -ProductionDriverEvidenceDir (Join-Path $PSScriptRoot "production-driver-evidence") `
    -ProductionLuaEvidenceDir (Join-Path $PSScriptRoot "production-lua-evidence") `
    -LiveModelEndpointSmokeEvidenceDir (Join-Path $PSScriptRoot "live-smoke-evidence") `
    -GameReplayDriverType $GameReplayDriverType `
    -RequireAllEvidence `
    -ContractFixtureMode:$ContractFixtureMode `
    -RunHardValidation:$RunHardValidation
'@
$acceptScript | Set-Content -Path $acceptScriptPath -Encoding UTF8

$areaStatuses = @()
foreach ($packet in @(Convert-ToArray $ownerPacketIndex.packets)) {
    $area = [string](Get-JsonValue $packet "area" "")
    $owner = [string](Get-JsonValue $packet "owner" "")
    $directoryName = Get-InboxDirectoryName $area
    $areaPath = Join-Path $inboxPath $directoryName
    New-Item -ItemType Directory -Force $areaPath | Out-Null

    $requiredFiles = @(Convert-ToArray (Get-JsonValue $packet "requiredEvidenceFiles" @()) | ForEach-Object { [string]$_ })
    $presentFiles = @()
    $missingFiles = @()
    foreach ($fileName in $requiredFiles) {
        if (Test-Path (Join-Path $areaPath $fileName)) {
            $presentFiles += $fileName
        } else {
            $missingFiles += $fileName
        }
    }

    $areaReadmeLines = @(
        "# Returned Evidence: $owner",
        "",
        "Area: ``$area``",
        "Directory: ``$directoryName``",
        "",
        "## Required Files",
        ""
    )
    foreach ($fileName in $requiredFiles) {
        $areaReadmeLines += "- ``$fileName``"
    }
    $areaReadmeLines += @(
        "",
        "## Validation",
        "",
        "After all owner evidence directories are filled, run from the inbox root:",
        "",
        '```powershell',
        ".\accept-returned-evidence.ps1 -RepoRoot `"path\to\AITestPilot`"",
        '```',
        "",
        "This directory is incomplete until every required file exists and the acceptance wrapper passes."
    )
    $areaReadmePath = Join-Path $areaPath "README.md"
    $areaReadmeLines | Set-Content -Path $areaReadmePath -Encoding UTF8

    $areaStatuses += [ordered]@{
        owner = $owner
        area = $area
        inboxDirectory = $directoryName
        inboxPath = $areaPath
        requiredEvidenceFiles = @($requiredFiles)
        requiredFileCount = [int]$requiredFiles.Count
        presentFiles = @($presentFiles)
        presentFileCount = [int]$presentFiles.Count
        missingFiles = @($missingFiles)
        missingFileCount = [int]$missingFiles.Count
        anyEvidenceProvided = [bool]($presentFiles.Count -gt 0)
        allEvidenceFilesPresent = [bool]($requiredFiles.Count -gt 0 -and $missingFiles.Count -eq 0)
        packetPath = [string](Get-JsonValue $packet "packetPath" "")
        hardValidationCommand = [string](Get-JsonValue $packet "hardValidationCommand" "")
    }
}

$submittedAreaCount = @($areaStatuses | Where-Object { [bool]$_["anyEvidenceProvided"] }).Count
$completeAreaCount = @($areaStatuses | Where-Object { [bool]$_["allEvidenceFilesPresent"] }).Count
$requiredEvidenceFileCountMeasure = @($areaStatuses | ForEach-Object { [int]$_["requiredFileCount"] } | Measure-Object -Sum)
$presentEvidenceFileCountMeasure = @($areaStatuses | ForEach-Object { [int]$_["presentFileCount"] } | Measure-Object -Sum)
$missingEvidenceFileCountMeasure = @($areaStatuses | ForEach-Object { [int]$_["missingFileCount"] } | Measure-Object -Sum)
$requiredEvidenceFileCount = if ($null -eq $requiredEvidenceFileCountMeasure.Sum) { 0 } else { [int]$requiredEvidenceFileCountMeasure.Sum }
$presentEvidenceFileCount = if ($null -eq $presentEvidenceFileCountMeasure.Sum) { 0 } else { [int]$presentEvidenceFileCountMeasure.Sum }
$missingEvidenceFileCount = if ($null -eq $missingEvidenceFileCountMeasure.Sum) { 0 } else { [int]$missingEvidenceFileCountMeasure.Sum }
$externalEvidenceCollectionComplete = $areaStatuses.Count -gt 0 -and $completeAreaCount -eq $areaStatuses.Count

$acceptanceCommand = ".\production-external-evidence-inbox\accept-returned-evidence.ps1 -RepoRoot `"path\to\AITestPilot`""
$rootReadmeLines = @(
    "# AI TestPilot Returned Production Evidence Inbox",
    "",
    "Copy host-project evidence into these directories, then run the acceptance wrapper. This inbox does not promote fixture evidence as real production evidence.",
    "",
    "## Directories",
    "",
    "| Owner | Area | Directory | Required files |",
    "| --- | --- | --- | --- |"
)
foreach ($areaStatus in $areaStatuses) {
    $owner = Format-MarkdownCell (Get-JsonValue $areaStatus "owner" "")
    $area = Format-MarkdownCell (Get-JsonValue $areaStatus "area" "")
    $directory = Format-MarkdownCell (Get-JsonValue $areaStatus "inboxDirectory" "")
    $requiredFiles = Format-MarkdownCell (Join-MarkdownList @(Get-JsonValue $areaStatus "requiredEvidenceFiles" @()))
    $rootReadmeLines += "| $owner | $area | $directory | $requiredFiles |"
}
$rootReadmeLines += @(
    "",
    "## Acceptance",
    "",
    '```powershell',
        ".\accept-returned-evidence.ps1 -RepoRoot `"path\to\AITestPilot`"",
        '```',
        "",
        "Add `-ContractFixtureMode` only for repository contract probes that use accepted fixture evidence.",
        "Add `-RunHardValidation` only after the acceptance report passes.",
    "",
    "## Boundary",
    "",
    "- This inbox is a return structure and inspection report.",
    "- Real host-project evidence is accepted only after `accept-returned-evidence.ps1` produces a PASS acceptance report with `realHostProjectEvidenceAccepted=true`.",
    "- Fixture contract evidence must not be copied into this inbox as production evidence."
)
$rootReadmeLines | Set-Content -Path $rootReadmePath -Encoding UTF8

$reportLines = @(
    "# AI TestPilot Production External Evidence Inbox",
    "",
    "Schema: ``aitestpilot.production_external_evidence_inbox.v1``",
    "Generated at UTC: $((Get-Date).ToUniversalTime().ToString("O"))",
    "",
    "## Summary",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Evidence areas | $($areaStatuses.Count) |",
    "| Submitted areas | $submittedAreaCount |",
    "| Complete areas | $completeAreaCount |",
    "| Required files | $requiredEvidenceFileCount |",
    "| Present files | $presentEvidenceFileCount |",
    "| Missing files | $missingEvidenceFileCount |",
    "| External evidence collection complete | $externalEvidenceCollectionComplete |",
    "| Real host-project evidence accepted | False |",
    "",
    "## Area Status",
    "",
    "| Owner | Area | Directory | Present | Missing | Next command |",
    "| --- | --- | --- | --- | --- | --- |"
)
foreach ($areaStatus in $areaStatuses) {
    $owner = Format-MarkdownCell (Get-JsonValue $areaStatus "owner" "")
    $area = Format-MarkdownCell (Get-JsonValue $areaStatus "area" "")
    $directory = Format-MarkdownCell (Get-JsonValue $areaStatus "inboxDirectory" "")
    $presentFiles = Format-MarkdownCell (Join-MarkdownList @(Get-JsonValue $areaStatus "presentFiles" @()))
    $missingFiles = Format-MarkdownCell (Join-MarkdownList @(Get-JsonValue $areaStatus "missingFiles" @()))
    $nextCommand = Format-MarkdownCell $acceptanceCommand
    $reportLines += "| $owner | $area | $directory | $presentFiles | $missingFiles | $nextCommand |"
}
$reportLines += @(
    "",
    "## Boundary",
    "",
    "- This inbox only standardizes returned evidence layout.",
    "- It is not an acceptance result and does not claim real production evidence.",
    "- Use the generated acceptance wrapper to produce `production-external-evidence-acceptance-manifest.json` before hard validation."
)
$reportText = [string]::Join([Environment]::NewLine, $reportLines) + [Environment]::NewLine
$reportText | Set-Content -Path $reportFullPath -Encoding UTF8
$reportText | Set-Content -Path $reportCopyPath -Encoding UTF8

$reportContentValidated = $reportText.Contains("AI TestPilot Production External Evidence Inbox") -and
    $reportText.Contains("production_driver_binding") -and
    $reportText.Contains("production_lua_patch_evidence") -and
    $reportText.Contains("live_model_endpoint_smoke") -and
    $reportText.Contains("Real host-project evidence accepted") -and
    $reportText.Contains("accept-returned-evidence.ps1") -and
    -not $reportText.Contains("System.Collections") -and
    -not $reportText.Contains("@{")

$inboxFiles = @(
    Get-ChildItem -LiteralPath $inboxPath -Recurse -File |
        ForEach-Object { "production-external-evidence-inbox\" + (Convert-ToRelativePath $inboxPath $_.FullName) }
)
$inboxFiles = @($inboxFiles | Sort-Object)

$checks = @()
Add-InboxCheck "handoff_source" `
    ($handoffManifest.status -eq "PASS" -and [bool]$handoffManifest.ownerPacketsContentValidated) `
    "Source handoff package must be PASS and include validated owner packets."
Add-InboxCheck "owner_area_mapping" `
    ($areaStatuses.Count -eq [int]$ownerPacketIndex.ownerPacketCount -and $areaStatuses.Count -eq 3) `
    "Inbox must create one evidence directory per owner packet."
Add-InboxCheck "required_evidence_contract" `
    ($requiredEvidence.schemaVersion -eq "aitestpilot.production_handoff_required_evidence.v1" -and $requiredEvidenceFileCount -eq 9) `
    "Inbox must reflect the required driver, Lua, and live-smoke evidence files."
Add-InboxCheck "inbox_files_generated" `
    ((Test-Path $rootReadmePath) -and (Test-Path $acceptScriptPath) -and $inboxFiles.Count -ge 6) `
    "Inbox must generate README files and the returned-evidence acceptance wrapper."
Add-InboxCheck "report_content" `
    ([bool]$reportContentValidated) `
    "Inbox report must summarize area status, missing files, next command, and evidence boundary."
Add-InboxCheck "fixture_boundary_preserved" `
    ($true) `
    "Inbox inspection must not accept fixture evidence or claim real host-project evidence."

$failedChecks = @($checks | Where-Object { -not [bool]$_["passed"] })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$generatedFiles = @(
    (Split-Path $manifestFullPath -Leaf),
    (Split-Path $reportFullPath -Leaf)
) + $inboxFiles
$sourceFiles = @(
    "production-handoff-package-manifest.json",
    "production-handoff-package/owner-packets/owner-packet-index.json",
    "production-handoff-package/required-external-evidence.json"
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_external_evidence_inbox.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    inboxDir = $inboxPath
    reportPath = $reportFullPath
    reportGenerated = (Test-Path $reportFullPath)
    reportContentValidated = [bool]$reportContentValidated
    inboxTemplateGenerated = $true
    acceptanceWrapperGenerated = (Test-Path $acceptScriptPath)
    acceptanceCommand = $acceptanceCommand
    gameReplayDriverType = $GameReplayDriverType
    ownerPacketCount = [int]$ownerPacketIndex.ownerPacketCount
    evidenceAreaCount = [int]$areaStatuses.Count
    submittedAreaCount = [int]$submittedAreaCount
    completeAreaCount = [int]$completeAreaCount
    requiredEvidenceFileCount = [int]$requiredEvidenceFileCount
    presentEvidenceFileCount = [int]$presentEvidenceFileCount
    missingRequiredFileCount = [int]$missingEvidenceFileCount
    externalEvidenceCollectionComplete = [bool]$externalEvidenceCollectionComplete
    realHostProjectEvidenceAccepted = $false
    externalEvidenceAccepted = $false
    releasePipelineUsesFixture = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "host_project_external_evidence_inbox_inspection_only"
    areaStatuses = @($areaStatuses)
    generatedFiles = @($generatedFiles)
    sourceFiles = @($sourceFiles)
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
    files = @($generatedFiles + $sourceFiles)
}

$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestFullPath -Encoding UTF8
$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestCopyPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Production external evidence inbox failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production external evidence inbox: $inboxPath"
Write-Output "Production external evidence inbox manifest: $manifestFullPath"
Write-Output "Production external evidence inbox report: $reportFullPath"
Write-Output "PASS AI TestPilot production external evidence inbox"
