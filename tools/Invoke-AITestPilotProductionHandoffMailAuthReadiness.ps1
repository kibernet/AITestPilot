[CmdletBinding()]
param(
    [string]$EvidenceBundleDir,
    [string]$MailAuthDir,
    [string]$ManifestPath,
    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($EvidenceBundleDir)) {
    $EvidenceBundleDir = Join-Path $repoRoot "Temp\release-evidence\latest"
}

if ([string]::IsNullOrWhiteSpace($MailAuthDir)) {
    $MailAuthDir = Join-Path $EvidenceBundleDir "production-handoff-mail-auth"
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $EvidenceBundleDir "production-handoff-mail-auth-readiness-manifest.json"
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $EvidenceBundleDir "production-handoff-mail-auth-readiness.md"
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

function Add-MailAuthCheck {
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

$evidenceBundlePath = Assert-PathUnderRepo $EvidenceBundleDir "EvidenceBundleDir"
$mailAuthPath = Assert-PathUnderRepo $MailAuthDir "MailAuthDir"
$manifestFullPath = Assert-PathUnderRepo $ManifestPath "ManifestPath"
$reportFullPath = Assert-PathUnderRepo $ReportPath "ReportPath"

if (-not (Test-Path $evidenceBundlePath)) {
    throw "Evidence bundle does not exist: $evidenceBundlePath"
}

if (Test-Path $mailAuthPath) {
    Remove-Item -LiteralPath $mailAuthPath -Recurse -Force
}
New-Item -ItemType Directory -Force $mailAuthPath | Out-Null

$sendReadinessManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-send-readiness-manifest.json") "Production handoff send readiness manifest"
$contactReadinessManifest = Read-JsonFile (Join-Path $evidenceBundlePath "production-handoff-contact-readiness-manifest.json") "Production handoff contact readiness manifest"

$authCheckScriptPath = Join-Path $mailAuthPath "check-agently-mail-auth.ps1"
$oauthLoginScriptPath = Join-Path $mailAuthPath "start-agently-mail-login.ps1"
$readmePath = Join-Path $mailAuthPath "README.md"

$authCheckScriptText = @'
[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot "production-handoff-mail-auth-local-check.json")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-AgentlyCapture {
    param([string[]]$Arguments)

    $output = & agently-cli @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    return [ordered]@{
        exitCode = [int]$exitCode
        output = [string]($output -join [Environment]::NewLine)
    }
}

$authStatus = Invoke-AgentlyCapture @("auth", "status")
$me = Invoke-AgentlyCapture @("+me")
$loggedIn = $false

try {
    $authJson = $authStatus.output | ConvertFrom-Json
    $loggedIn = [bool]$authJson.data.logged_in
}
catch {
    $loggedIn = $false
}

$status = if ($loggedIn -and $me.exitCode -eq 0) { "PASS" } else { "BLOCKED" }
$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_mail_auth_local_check.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    loggedIn = [bool]$loggedIn
    authStatusExitCode = [int]$authStatus.exitCode
    meExitCode = [int]$me.exitCode
    authStatusOutput = [string]$authStatus.output
    meOutput = [string]$me.output
}

$manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $OutputPath -Encoding UTF8

if ($status -ne "PASS") {
    throw "agently-cli mail authorization is not ready. Run agently-cli auth login, then rerun this script."
}

Write-Output "PASS agently-cli mail authorization readiness"
'@

$oauthLoginScriptText = @'
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Output "Starting agently-cli OAuth login. Complete the browser authorization, then verify with agently-cli +me."
& agently-cli auth login
& agently-cli +me
'@

$readmeLines = @(
    "# AI TestPilot Production Handoff Mail Auth Readiness",
    "",
    "This folder contains local helper scripts for validating and starting Agent Mail authorization before owner packet dispatch.",
    "",
    "Release CI does not run OAuth login and does not claim that this machine is authorized.",
    "",
    "Workflow:",
    "",
    "1. Run ``.\production-handoff-mail-auth\start-agently-mail-login.ps1`` if ``agently-cli auth status`` is not logged in.",
    "2. Run ``.\production-handoff-mail-auth\check-agently-mail-auth.ps1`` to write a local authorization check manifest.",
    "3. After authorization and real owner contacts are ready, use ``.\production-handoff-send\send-owner-packets.ps1 -PrepareConfirmation``.",
    "",
    "The send helper still requires agently-cli two-stage confirmation tokens before ``-Send`` can complete."
)

$authCheckScriptText | Set-Content -Path $authCheckScriptPath -Encoding UTF8
$oauthLoginScriptText | Set-Content -Path $oauthLoginScriptPath -Encoding UTF8
$readmeLines | Set-Content -Path $readmePath -Encoding UTF8

$authCheckScriptContent = Get-Content -Path $authCheckScriptPath -Encoding UTF8 -Raw
$oauthLoginScriptContent = Get-Content -Path $oauthLoginScriptPath -Encoding UTF8 -Raw
$readmeContent = Get-Content -Path $readmePath -Encoding UTF8 -Raw

$authCheckScriptContentValidated = $authCheckScriptContent.Contains("agently-cli") -and
    $authCheckScriptContent.Contains("auth") -and
    $authCheckScriptContent.Contains("+me") -and
    $authCheckScriptContent.Contains("production_handoff_mail_auth_local_check.v1") -and
    $authCheckScriptContent.Contains("Run agently-cli auth login") -and
    -not $authCheckScriptContent.Contains("System.Collections")
$oauthLoginHelperContentValidated = $oauthLoginScriptContent.Contains("agently-cli auth login") -and
    $oauthLoginScriptContent.Contains("agently-cli +me") -and
    $oauthLoginScriptContent.Contains("Complete the browser authorization") -and
    -not $oauthLoginScriptContent.Contains("System.Collections")
$readmeContentValidated = $readmeContent.Contains("Agent Mail authorization") -and
    $readmeContent.Contains("Release CI does not run OAuth login") -and
    $readmeContent.Contains("two-stage confirmation") -and
    -not $readmeContent.Contains([char]7) -and
    -not $readmeContent.Contains("System.Collections")

$sendReadinessAccepted = $sendReadinessManifest.status -eq "PASS" -and
    [bool](Get-JsonValue $sendReadinessManifest "mailAuthorizationRequired" $false) -and
    -not [bool](Get-JsonValue $sendReadinessManifest "mailAuthorizationCheckedByPipeline" $true) -and
    [bool](Get-JsonValue $sendReadinessManifest "twoStageConfirmationRequired" $false)
$defaultContactBoundaryPreserved = $contactReadinessManifest.status -eq "PASS" -and
    [int](Get-JsonValue $contactReadinessManifest "missingOwnerContactCount" -1) -eq [int](Get-JsonValue $contactReadinessManifest "ownerContactCount" -2) -and
    -not [bool](Get-JsonValue $contactReadinessManifest "automaticEmailSendReady" $true)
$mailAuthReadinessStatus = "BLOCKED_NOT_CHECKED_BY_RELEASE_PIPELINE"
$mailAuthorizationRequired = $true
$mailAuthorizationCheckedByPipeline = $false
$pipelineDoesNotRunOAuthLogin = $true
$twoStageConfirmationRequired = [bool](Get-JsonValue $sendReadinessManifest "twoStageConfirmationRequired" $true)
$automaticEmailSendReady = $false

$reportLines = @(
    "# AI TestPilot Production Handoff Mail Auth Readiness",
    "",
    "Schema: ``aitestpilot.production_handoff_mail_auth_readiness.v1``",
    "Generated at UTC: $((Get-Date).ToUniversalTime().ToString("O"))",
    "",
    "## Summary",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Mail auth readiness status | $mailAuthReadinessStatus |",
    "| Mail authorization required | $mailAuthorizationRequired |",
    "| Mail authorization checked by pipeline | $mailAuthorizationCheckedByPipeline |",
    "| Pipeline runs OAuth login | False |",
    "| Two-stage confirmation required | $twoStageConfirmationRequired |",
    "| Automatic email send ready | $automaticEmailSendReady |",
    "",
    "## Local Commands",
    "",
    "```powershell",
    ".\production-handoff-mail-auth\start-agently-mail-login.ps1",
    ".\production-handoff-mail-auth\check-agently-mail-auth.ps1",
    "```",
    "",
    "## Boundary",
    "",
    "- This readiness report generates authorization helper scripts only.",
    "- The release pipeline does not run OAuth login and does not send email.",
    "- A local operator must prove agently-cli authorization before owner packet dispatch."
)

$reportText = [string]::Join([Environment]::NewLine, $reportLines) + [Environment]::NewLine
New-Item -ItemType Directory -Force (Split-Path $reportFullPath -Parent) | Out-Null
$reportText | Set-Content -Path $reportFullPath -Encoding UTF8

$reportContentValidated = $reportText.Contains("AI TestPilot Production Handoff Mail Auth Readiness") -and
    $reportText.Contains($mailAuthReadinessStatus) -and
    $reportText.Contains("does not run OAuth login") -and
    $reportText.Contains("check-agently-mail-auth.ps1") -and
    -not $reportText.Contains("System.Collections") -and
    -not $reportText.Contains([char]7)

$checks = @()
Add-MailAuthCheck "mail_auth_sources_available" `
    ($sendReadinessManifest.status -eq "PASS" -and $contactReadinessManifest.status -eq "PASS") `
    "Mail auth readiness must be based on passing send and contact readiness evidence."
Add-MailAuthCheck "mail_auth_kit_generated" `
    ((Test-Path $authCheckScriptPath) -and (Test-Path $oauthLoginScriptPath) -and (Test-Path $readmePath) -and $readmeContentValidated) `
    "Mail auth readiness kit must include validated check, login, and README files."
Add-MailAuthCheck "auth_check_script_content" `
    $authCheckScriptContentValidated `
    "Local auth check script must inspect agently-cli auth status and +me without sending mail."
Add-MailAuthCheck "oauth_login_helper_content" `
    $oauthLoginHelperContentValidated `
    "OAuth login helper must start agently-cli auth login and verify +me."
Add-MailAuthCheck "send_readiness_dependency" `
    ($sendReadinessAccepted -and $defaultContactBoundaryPreserved) `
    "Mail auth readiness must preserve send-readiness and default contact boundaries."
Add-MailAuthCheck "mail_auth_boundary_preserved" `
    ($mailAuthorizationRequired -and -not $mailAuthorizationCheckedByPipeline -and $pipelineDoesNotRunOAuthLogin -and $twoStageConfirmationRequired -and -not $automaticEmailSendReady) `
    "Release evidence must not claim local mail authorization, OAuth login, or automatic email send readiness."
Add-MailAuthCheck "mail_auth_report_content" `
    $reportContentValidated `
    "Mail auth report must summarize local auth commands and the OAuth boundary."

$failedChecks = @($checks | Where-Object { -not [bool]$_.passed })
$status = if ($failedChecks.Count -eq 0) { "PASS" } else { "FAIL" }

$generatedFiles = @(
    (Convert-ToEvidenceRelativePath $manifestFullPath),
    (Convert-ToEvidenceRelativePath $reportFullPath),
    (Convert-ToEvidenceRelativePath $authCheckScriptPath),
    (Convert-ToEvidenceRelativePath $oauthLoginScriptPath),
    (Convert-ToEvidenceRelativePath $readmePath)
)
$sourceFiles = @(
    "production-handoff-send-readiness-manifest.json",
    "production-handoff-contact-readiness-manifest.json"
)

$manifest = [ordered]@{
    schemaVersion = "aitestpilot.production_handoff_mail_auth_readiness.v1"
    status = $status
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    evidenceBundleDir = $evidenceBundlePath
    mailAuthDir = $mailAuthPath
    authCheckScriptPath = $authCheckScriptPath
    oauthLoginScriptPath = $oauthLoginScriptPath
    reportPath = $reportFullPath
    mailAuthReadinessStatus = $mailAuthReadinessStatus
    mailAuthKitGenerated = [bool]((Test-Path $authCheckScriptPath) -and (Test-Path $oauthLoginScriptPath) -and (Test-Path $readmePath))
    authCheckScriptGenerated = (Test-Path $authCheckScriptPath)
    oauthLoginHelperGenerated = (Test-Path $oauthLoginScriptPath)
    readmeGenerated = (Test-Path $readmePath)
    authCheckScriptContentValidated = [bool]$authCheckScriptContentValidated
    oauthLoginHelperContentValidated = [bool]$oauthLoginHelperContentValidated
    readmeContentValidated = [bool]$readmeContentValidated
    reportGenerated = (Test-Path $reportFullPath)
    reportContentValidated = [bool]$reportContentValidated
    sendReadinessAccepted = [bool]$sendReadinessAccepted
    defaultContactBoundaryPreserved = [bool]$defaultContactBoundaryPreserved
    mailAuthorizationRequired = [bool]$mailAuthorizationRequired
    mailAuthorizationCheckedByPipeline = [bool]$mailAuthorizationCheckedByPipeline
    pipelineDoesNotRunOAuthLogin = [bool]$pipelineDoesNotRunOAuthLogin
    twoStageConfirmationRequired = [bool]$twoStageConfirmationRequired
    automaticEmailSendReady = [bool]$automaticEmailSendReady
    releasePipelineUsesFixture = $false
    realHostProjectEvidenceAccepted = $false
    fixtureEvidencePromoted = $false
    productionOutputBoundary = "host_project_owner_mail_auth_readiness_only"
    sourceFiles = @($sourceFiles)
    generatedFiles = @($generatedFiles)
    checkCount = [int]$checks.Count
    failedCheckCount = [int]$failedChecks.Count
    checks = @($checks)
    files = @($generatedFiles + $sourceFiles)
}

New-Item -ItemType Directory -Force (Split-Path $manifestFullPath -Parent) | Out-Null
$manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $manifestFullPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "Production handoff mail auth readiness failed: $($failedChecks.name -join ', ')"
}

Write-Output "Production handoff mail auth readiness manifest: $manifestFullPath"
Write-Output "Production handoff mail auth readiness report: $reportFullPath"
Write-Output "PASS AI TestPilot production handoff mail auth readiness"
