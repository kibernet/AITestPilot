[CmdletBinding()]
param(
    [string]$ReplayProfileJsonPath,
    [string]$EvidenceBundleDir = "Temp\release-evidence\latest",
    [string]$ManifestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
. (Join-Path $PSScriptRoot "PathGuards.ps1")

function Resolve-OutputPath {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [string]::Empty
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return Join-Path $repoRoot $Path
}

function Get-JsonProperty {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Default = $null
    )

    if ($null -eq $Object -or $null -eq $Object.PSObject) {
        return $Default
    }

    foreach ($property in $Object.PSObject.Properties) {
        if ($property.Name -ieq $Name) {
            Write-Output -NoEnumerate $property.Value
            return
        }
    }

    return $Default
}

function Add-Issue {
    param(
        [ref]$IssueList,
        [string]$Path,
        [string]$Code,
        [string]$Message,
        [ValidateSet("FAIL","WARN")]
        [string]$Severity = "FAIL"
    )

    $IssueList.Value += [ordered]@{
        severity = $Severity
        path = $Path
        code = $Code
        message = $Message
    }
}

function Get-ActionTargetRequirement {
    param([string]$Action)

    if ([string]::IsNullOrWhiteSpace($Action)) {
        return $null
    }

    switch ($Action.ToLowerInvariant()) {
        "wait" { return $false }
        "finish" { return $false }
        default { return $true }
    }
}

function Is-ActionAllowed {
    param([string]$Action)

    if ([string]::IsNullOrWhiteSpace($Action)) {
        return $false
    }

    $allowed = @(
        "click",
        "wait",
        "prepare_account",
        "login",
        "enter_scene",
        "close_popup",
        "claim_reward",
        "play_fishing",
        "finish"
    )

    return $allowed -contains $Action.ToLowerInvariant()
}

if ([string]::IsNullOrWhiteSpace($ReplayProfileJsonPath)) {
    $ReplayProfileJsonPath = Join-Path $repoRoot "Temp\release-evidence\latest\sample-business-replay-profile.json"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "replay-profile-schema-check-manifest.json"
}

$evidenceBundleDir = Resolve-OutputPath -Path $EvidenceBundleDir
$replayProfilePath = Resolve-OutputPath -Path $ReplayProfileJsonPath
$manifestPath = Resolve-OutputPath -Path $ManifestPath

$EvidenceBundleDir = Assert-PathUnderRoot -Path $evidenceBundleDir -Label "EvidenceBundleDir" -RepoRoot $repoRoot
New-Item -ItemType Directory -Force $EvidenceBundleDir | Out-Null
$ReplayProfileJsonPath = Assert-PathUnderRoot -Path $replayProfilePath -Label "ReplayProfileJsonPath" -RepoRoot $repoRoot
$ManifestPath = Assert-PathUnderRoot -Path $manifestPath -Label "ManifestPath" -RepoRoot $repoRoot

if (-not (Test-Path $ReplayProfileJsonPath)) {
    throw "Replay profile JSON not found: $ReplayProfileJsonPath"
}

$issues = @()

Write-Host "==> Replay profile schema check input: $ReplayProfileJsonPath"
Write-Host "==> Replay profile schema manifest: $ManifestPath"

try {
    $rawContent = Get-Content -Raw -Encoding UTF8 -Path $ReplayProfileJsonPath
}
catch {
    Add-Issue -IssueList ([ref]$issues) -Path "replayProfile" -Code "FILE_READ_FAILED" -Message "Unable to read replay profile JSON: $($_.Exception.Message)" -Severity "FAIL"
    $rawContent = $null
}

$profile = $null
if ($issues.Count -eq 0) {
    try {
        $profile = $rawContent | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Add-Issue -IssueList ([ref]$issues) -Path "replayProfile" -Code "JSON_PARSE_FAILED" -Message "Invalid JSON syntax: $($_.Exception.Message)" -Severity "FAIL"
    }
}

if ($null -eq $profile) {
    if (-not ($issues | Where-Object { $_.severity -eq "FAIL" })) {
        Add-Issue -IssueList ([ref]$issues) -Path "replayProfile" -Code "JSON_EMPTY" -Message "Replay profile JSON is empty." -Severity "FAIL"
    }
}

$adapterId = Get-JsonProperty -Object $profile -Name "adapterId" $null
if ($null -eq $adapterId) {
    Add-Issue -IssueList ([ref]$issues) -Path "adapterId" -Code "REQUIRED_FIELD_MISSING" -Message "Top-level field 'adapterId' is required."
}
elseif (-not ($adapterId -is [string]) -or [string]::IsNullOrWhiteSpace($adapterId)) {
    Add-Issue -IssueList ([ref]$issues) -Path "adapterId" -Code "FIELD_INVALID_TYPE" -Message "'adapterId' must be a non-empty string."
}

$rules = Get-JsonProperty -Object $profile -Name "rules" $null
if ($null -eq $rules) {
    Add-Issue -IssueList ([ref]$issues) -Path "rules" -Code "REQUIRED_FIELD_MISSING" -Message "Top-level field 'rules' is required."
    $ruleCount = 0
}
elseif (-not ($rules -is [array])) {
    Add-Issue -IssueList ([ref]$issues) -Path "rules" -Code "FIELD_INVALID_TYPE" -Message "'rules' must be an array."
    $ruleCount = 0
}
elseif ($rules.Count -eq 0) {
    $ruleCount = 0
    Add-Issue -IssueList ([ref]$issues) -Path "rules" -Code "EMPTY_RULES" -Message "Replay profile has no rules. Consider adding at least one rule for useful playback coverage." -Severity "WARN"
}
else {
    $ruleCount = [int]$rules.Count
}

$requiredTargetActions = @("click", "prepare_account", "login", "enter_scene", "close_popup", "claim_reward", "play_fishing")
$seenRuleSignatures = @{}
$seenHandlers = @{}
$seenActions = @{}
$seenTargets = @{}

if ($rules -is [array]) {
    for ($i = 0; $i -lt $rules.Count; $i++) {
        $rule = $rules[$i]
        $rulePath = "rules[$i]"

        if ($null -eq $rule) {
            Add-Issue -IssueList ([ref]$issues) -Path $rulePath -Code "RULE_NOT_OBJECT" -Message "Each rule must be an object."
            continue
        }

        $ruleAction = Get-JsonProperty -Object $rule -Name "action" $null
        $ruleTarget = Get-JsonProperty -Object $rule -Name "target" $null
        $ruleHandlerKey = Get-JsonProperty -Object $rule -Name "handlerKey" $null
        $allowDefaultFallback = Get-JsonProperty -Object $rule -Name "allowDefaultFallback" $null
        $normalizedAction = if ($ruleAction -is [string]) { $ruleAction.Trim().ToLowerInvariant() } else { [string]::Empty }
        $normalizedTarget = if ($ruleTarget -is [string]) { $ruleTarget.Trim().ToLowerInvariant() } else { [string]::Empty }
        $normalizedHandlerKey = if ($ruleHandlerKey -is [string]) { $ruleHandlerKey.Trim().ToLowerInvariant() } else { [string]::Empty }

        if ($null -eq $ruleAction) {
            Add-Issue -IssueList ([ref]$issues) -Path "$rulePath.action" -Code "REQUIRED_FIELD_MISSING" -Message "Rule field 'action' is required."
            continue
        }
        if (-not ($ruleAction -is [string]) -or [string]::IsNullOrWhiteSpace($ruleAction)) {
            Add-Issue -IssueList ([ref]$issues) -Path "$rulePath.action" -Code "FIELD_INVALID_TYPE" -Message "'action' must be a non-empty string."
            continue
        }

        $seenActions[$normalizedAction] = $true
        if (-not (Is-ActionAllowed -Action $ruleAction.ToLowerInvariant())) {
            Add-Issue -IssueList ([ref]$issues) -Path "$rulePath.action" -Code "ACTION_UNKNOWN" -Message "Action '$ruleAction' is not in the built-in ActionWhitelist." -Severity "WARN"
        }

        if ((Get-ActionTargetRequirement -Action $normalizedAction) -and [string]::IsNullOrWhiteSpace($normalizedTarget)) {
            Add-Issue -IssueList ([ref]$issues) -Path "$rulePath.target" -Code "RULE_TARGET_REQUIRED" -Message "Action '$normalizedAction' requires a non-empty 'target'."
            continue
        }
        elseif (-not (Get-ActionTargetRequirement -Action $normalizedAction) -and -not [string]::IsNullOrWhiteSpace($normalizedTarget)) {
            Add-Issue -IssueList ([ref]$issues) -Path "$rulePath.target" -Code "TARGET_UNUSED" -Message "Action '$normalizedAction' normally does not need a target, but one was provided."
        }

        if (-not [string]::IsNullOrWhiteSpace($normalizedTarget)) {
            $seenTargets[$normalizedTarget] = $true
        }

        if ($null -eq $ruleHandlerKey) {
            Add-Issue -IssueList ([ref]$issues) -Path "$rulePath.handlerKey" -Code "REQUIRED_FIELD_MISSING" -Message "Rule field 'handlerKey' is required."
        }
        elseif (-not ($ruleHandlerKey -is [string]) -or [string]::IsNullOrWhiteSpace($ruleHandlerKey)) {
            Add-Issue -IssueList ([ref]$issues) -Path "$rulePath.handlerKey" -Code "FIELD_INVALID_TYPE" -Message "'handlerKey' must be a non-empty string."
        }
        else {
            $seenHandlers[$ruleHandlerKey] = $($seenHandlers[$ruleHandlerKey] + 1)
        }

        if ($null -ne $allowDefaultFallback -and (-not ($allowDefaultFallback -is [bool]))) {
            Add-Issue -IssueList ([ref]$issues) -Path "$rulePath.allowDefaultFallback" -Code "FIELD_INVALID_TYPE" -Message "'allowDefaultFallback' must be true/false when present."
        }

        $signature = "$normalizedAction|$normalizedTarget|$normalizedHandlerKey"
        if ($seenRuleSignatures.ContainsKey($signature)) {
            Add-Issue -IssueList ([ref]$issues) -Path $rulePath -Code "DUPLICATE_RULE" -Message "Duplicate rule signature (action,target,handlerKey): $signature."
        }
        else {
            $seenRuleSignatures[$signature] = $true
        }
    }
}

$severityCounts = @{
    FAIL = 0
    WARN = 0
}
foreach ($issue in $issues) {
    if ($issue.severity -eq "FAIL") {
        $severityCounts.FAIL++
    }
    else {
        $severityCounts.WARN++
    }
}

$status = if ($severityCounts.FAIL -eq 0) { "PASS" } else { "FAIL" }

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.replay_profile_schema_check.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    checkedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    profilePath = [string](Resolve-Path $ReplayProfileJsonPath).Path
    evidenceBundleDir = [string](Resolve-Path $EvidenceBundleDir).Path
    adapterId = if ($adapterId) { [string]$adapterId } else { $null }
    ruleCount = $ruleCount
    uniqueActionCount = $seenActions.Count
    uniqueTargetCount = $seenTargets.Count
    uniqueHandlerCount = $seenHandlers.Count
    requiredTargetActionCount = $requiredTargetActions.Count
    warnings = $severityCounts.WARN
    failures = $severityCounts.FAIL
    issueCount = $issues.Count
    issues = @($issues)
    files = @("replay-profile-schema-check-manifest.json")
}

$manifest | ConvertTo-Json -Depth 20 | Set-Content -Path $ManifestPath -Encoding UTF8

if ($status -eq "PASS") {
    if ($severityCounts.WARN -gt 0) {
        Write-Host "PASS (with warnings) replay profile schema check: $ReplayProfileJsonPath"
        foreach ($warning in @($issues | Where-Object { $_.severity -eq "WARN" })) {
            Write-Host "WARN [$($warning.code)] $($warning.path): $($warning.message)"
        }
    }
    else {
        Write-Host "PASS replay profile schema check: $ReplayProfileJsonPath"
    }
}
else {
    Write-Host "FAIL replay profile schema check: $ReplayProfileJsonPath"
    foreach ($fail in @($issues | Where-Object { $_.severity -eq "FAIL" })) {
        Write-Host "FAIL [$($fail.code)] $($fail.path): $($fail.message)"
    }
    exit 1
}
