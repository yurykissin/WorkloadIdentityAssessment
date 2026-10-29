[CmdletBinding()]
param([string]$OutputRoot = (Join-Path $PSScriptRoot '../output/report-tests'))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1.0
. (Join-Path $PSScriptRoot 'New-ReportFixture.ps1')
$renderer = Join-Path $PSScriptRoot '../scripts/09-html-report.ps1'
$null = New-Item -ItemType Directory -Path $OutputRoot -Force
$OutputRoot = (Resolve-Path -LiteralPath $OutputRoot).Path
$checks = 0
function Assert-Report([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Read-Payload([string]$Path) {
    $html = Get-Content -Raw -LiteralPath $Path
    $match = [regex]::Match($html, '(?s)<script id="report-data" type="application/json">(.*?)</script>')
    Assert-Report $match.Success 'Embedded report data exists'
    return $match.Groups[1].Value | ConvertFrom-Json -Depth 100
}
function Render-Fixture([string]$Name) {
    $folder = Join-Path $OutputRoot $Name
    $htmlPath = Join-Path $folder 'report.html'
    & $renderer -OutputDir $folder -ReportPath $htmlPath
    return Read-Payload $htmlPath
}
function Write-Dataset([string]$Folder, [string]$Name, $Data) {
    $Data | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath (Join-Path $Folder $Name) -Encoding utf8
}

foreach ($path in @($renderer, (Join-Path $PSScriptRoot 'New-ReportFixture.ps1'), $PSCommandPath)) {
    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    Assert-Report ($errors.Count -eq 0) "PowerShell parses: $path"
}
$arm = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '../deploy/azuredeploy.json') | ConvertFrom-Json -Depth 100
$deployment = @($arm.resources | Where-Object type -eq 'Microsoft.Resources/deploymentScripts')[0].properties.scriptContent
$tokens = $null
$errors = $null
$null = [System.Management.Automation.Language.Parser]::ParseInput($deployment, [ref]$tokens, [ref]$errors)
Assert-Report ($errors.Count -eq 0) 'Embedded deployment PowerShell parses'
foreach ($asset in @('template.html', 'styles.css', 'app.js')) {
    Assert-Report ($deployment.Contains($asset)) "Azure download includes $asset"
}

$normalFolder = Join-Path $OutputRoot 'normal'
New-ReportFixture -Destination $normalFolder
$normal = Render-Fixture 'normal'
Assert-Report (@($normal.Sources | Where-Object State -eq 'Loaded').Count -eq 8) 'All normal datasets loaded'
Assert-Report ($normal.Data.'02'.appRegistrations.Count -eq 3) 'App-registration count retained'
Assert-Report ($normal.Data.'02'.servicePrincipals.Count -eq 3) 'SP count retained'
Assert-Report ($normal.Data.'02'.managedIdentities.Count -eq 1) 'MI count retained'
$expectedControls = @('WI.REG.1','WI.REG.3','WI.OWN.1','WI.OWN.2','WI.CRED.1','WI.PERM.1')
Assert-Report (@(Compare-Object ($expectedControls | Sort-Object) ($normal.Findings.Id | Sort-Object)).Count -eq 0) 'Source-backed findings replace unsourced legacy hash baseline with explicit predicates'
Assert-Report (($normal.Findings | Where-Object Id -eq 'WI.PERM.1').Severity -eq 'High') 'Privileged API grants remain High review candidates'
Assert-Report (@($normal.Findings | Where-Object { -not $_.SourceUrl -or -not $_.AffectedRows.Count }).Count -eq 0) 'Every finding has a source and affected evidence'
$normalHtml = Get-Content -LiteralPath (Join-Path $normalFolder 'report.html') -Raw
Assert-Report ($normalHtml.Contains("aria-label='Assessment findings'") -and [regex]::Matches($normalHtml, "class='finding-details' id='finding-details-\d+' hidden").Count -eq $normal.Findings.Count) 'Every rendered finding has a summary-table row group and initially collapsed details'
Assert-Report ([regex]::Matches($normalHtml, "<details class='finding-sources'><summary>Sources and rationale \(\d+\)</summary>").Count -eq $normal.Findings.Count -and $normalHtml.Contains("<details class='finding-methodology'>")) 'Source references and the full methodology use native disclosures rather than always-expanded link paragraphs'
Assert-Report ($null -eq $normal.Data.'06'.Aggregations.NeverSignedIn -and $normal.RawData.'06'.Aggregations.NeverSignedIn -eq 0) 'Legacy never-used correction preserves original raw payload'

$unknownHygieneFolder = Join-Path $OutputRoot 'unknown-hygiene'
New-ReportFixture -Destination $unknownHygieneFolder
$hygiene = Get-Content -Raw (Join-Path $unknownHygieneFolder '06-stale-and-orphaned.json') | ConvertFrom-Json
$hygiene.SignInDataAvailable = $false
$hygiene.Aggregations.NeverSignedIn = $null
$hygiene.Aggregations.Stale90Days = $null
$hygiene.Aggregations.Stale365Days = $null
$hygiene.ServicePrincipals[0] | Add-Member -NotePropertyName OwnerCategory -NotePropertyValue 'singleOwner'
Write-Dataset $unknownHygieneFolder '06-stale-and-orphaned.json' $hygiene
$unknownHygiene = Render-Fixture 'unknown-hygiene'
Assert-Report (($unknownHygiene.Sources | Where-Object Id -eq '06').State -eq 'Loaded') 'Intentional null activity totals do not discard valid hygiene evidence'
Assert-Report ($null -eq $unknownHygiene.Data.'06'.Aggregations.NeverSignedIn -and $null -eq $unknownHygiene.Data.'06'.Aggregations.Stale90Days -and $null -eq $unknownHygiene.Data.'06'.Aggregations.Stale365Days) 'Unavailable activity totals remain unknown, not zero'
Assert-Report (($unknownHygiene.Assessment.Results | Where-Object Id -eq 'WI.OWN.3').Outcome -eq 'Review') 'Valid ownership continuity is assessed independently of unavailable activity'
$hygiene.Aggregations.PSObject.Properties.Remove('NoOwner')
Write-Dataset $unknownHygieneFolder '06-stale-and-orphaned.json' $hygiene
$missingHygiene = Render-Fixture 'unknown-hygiene'
Assert-Report (($missingHygiene.Sources | Where-Object Id -eq '06').State -eq 'Partial') 'Allowing explicit unknown activity does not accept missing ownership aggregation fields'
Write-Dataset $unknownHygieneFolder '06-stale-and-orphaned.json' $unknownHygiene.RawData.'06'
$null = Render-Fixture 'unknown-hygiene'

$pairedFolder = Join-Path $OutputRoot 'paired'
New-ReportFixture -Destination $pairedFolder
$pairedInventory = Get-Content -Raw (Join-Path $pairedFolder '02-inventory.json') | ConvertFrom-Json
$pairedInventory.appRegistrations[0].DisplayName = 'Same display name'
$pairedInventory.appRegistrations[1].DisplayName = 'Same display name'
$pairedInventory.servicePrincipals[0].DisplayName = 'Different SP display name'
$pairedInventory.appRegistrations[0] | Add-Member -NotePropertyMembers @{
    RequiredResourceAccess = @(@{ resourceAppId = 'synthetic-graph'; resourceAccess = @(@{ id = 'synthetic-read'; type = 'Role' }, @{ id = 'synthetic-write'; type = 'Role' }) })
    RedirectUris = @('https://example.invalid/callback')
    ImplicitGrantSettings = @{ EnableAccessTokenIssuance = $false; EnableIdTokenIssuance = $false }
    InstancePropertyLock = @{ isEnabled = $true; credentialsWithUsageSign = $true }
    CreationEvidence = @{ State = 'Unavailable'; Message = 'Synthetic audit history unavailable' }
}
$pairedInventory.appRegistrations[1] | Add-Member -NotePropertyName RequiredResourceAccess -NotePropertyValue @()
$orphanApp = [pscustomobject]@{
    AppObjectId = 'synthetic-app-no-sp'; AppId = 'synthetic-client-no-sp'; DisplayName = 'Registration without enterprise app'
    SignInAudience = 'multi-tenant'; OwnerCount = 2; RequiredResourceAccess = @(@{ resourceAppId = 'synthetic-graph'; resourceAccess = @(@{ id = 'synthetic-delegated'; type = 'Scope' }) })
}
$externalSp = [pscustomobject]@{
    SpObjectId = 'synthetic-external-sp'; AppId = 'synthetic-external-client'; DisplayName = 'External-only workload'
    ServicePrincipalType = 'Application'; AppOwnerOrganizationId = 'synthetic-external-tenant'; IsExternalApp = $true; AccountEnabled = $true
}
$managedSp = [pscustomobject]@{
    SpObjectId = $pairedInventory.managedIdentities[0].PrincipalId; AppId = $pairedInventory.managedIdentities[0].ClientId
    DisplayName = 'Managed identity directory object'; ServicePrincipalType = 'ManagedIdentity'; AccountEnabled = $true
}
$pairedInventory.appRegistrations += $orphanApp
$pairedInventory.servicePrincipals += @($externalSp, $managedSp)
$pairedInventory | Add-Member -NotePropertyName WorkloadEvidence -NotePropertyValue @{
    AgentIdentities = @{ State = 'Available'; Records = @(@{ id = 'synthetic-agent-sp'; appId = 'synthetic-agent-client'; displayName = 'Synthetic paired agent' }) }
    AgentBlueprints = @{ State = 'Available'; Records = @(@{ id = 'synthetic-agent-app'; appId = 'synthetic-agent-client'; displayName = 'Synthetic paired blueprint' }) }
}
Write-Dataset $pairedFolder '02-inventory.json' $pairedInventory
$pairedPermissions = Get-Content -Raw (Join-Path $pairedFolder '05-permission-surface.json') | ConvertFrom-Json
$grantBase = @{
    SpObjectId = $pairedInventory.servicePrincipals[0].SpObjectId; AppObjectId = $pairedInventory.appRegistrations[0].AppObjectId
    AppId = $pairedInventory.appRegistrations[0].AppId; SpDisplayName = 'Same display name'; ResourceAppId = 'synthetic-graph'; ResourceDisplayName = 'Microsoft Graph'
    PermissionType = 'Application'; AdminConsentRequired = $true; GrantState = 'Granted'; ConsentStatus = 'Granted application access'; ConfiguredState = 'Configured'; Tier = 'STANDARD'
}
$read = $grantBase.Clone()
$read.PermissionValue = 'Synthetic.Read'; $read.AssignmentId = 'synthetic-read-assignment'
$write = $grantBase.Clone()
$write.PermissionValue = 'Synthetic.Write'; $write.GrantState = 'Not granted'; $write.ConsentStatus = 'Not granted'
$other = $grantBase.Clone()
$other.PermissionValue = 'Exchange.ManageAsApp'; $other.ResourceAppId = '00000002-0000-0ff1-ce00-000000000000'; $other.ResourceDisplayName = 'Office 365 Exchange Online'
$other.ConfiguredState = 'Granted but not configured'; $other.Tier = 'PRIVILEGED'; $other.AssignmentId = 'synthetic-exchange-assignment'
$unavailable = @{
    SpObjectId = $externalSp.SpObjectId; AppId = $externalSp.AppId; SpDisplayName = $externalSp.DisplayName
    ResourceDisplayName = 'Microsoft Graph'; ResourceAppId = 'synthetic-graph'; PermissionValue = 'External.Read'
    PermissionType = 'Delegated'; GrantState = 'Granted'; ConsentStatus = 'Granted to a specific principal'; ConfiguredState = 'Configuration unavailable'; Tier = 'STANDARD'
}
$unknown = @{
    AppObjectId = $orphanApp.AppObjectId; AppId = $orphanApp.AppId; SpDisplayName = $orphanApp.DisplayName
    ResourceDisplayName = 'Microsoft Graph'; ResourceAppId = 'synthetic-graph'; PermissionValue = 'Synthetic.Delegated'
    PermissionType = 'Delegated'; GrantState = 'Unknown (grant collection unavailable)'; ConfiguredState = 'Configured'; Tier = 'STANDARD'
}
$pairedPermissions | Add-Member -NotePropertyName NormalizedPermissions -NotePropertyValue @($read, $write, $other, $unavailable, $unknown)
Write-Dataset $pairedFolder '05-permission-surface.json' $pairedPermissions
$paired = Render-Fixture 'paired'
Assert-Report ($paired.Data.'02'.appRegistrations.Count -eq 4 -and $paired.Data.'02'.servicePrincipals.Count -eq 5) 'Paired fixture preserves all app/SP objects including unpaired and managed counterparts'
Assert-Report ($paired.Data.'05'.NormalizedPermissions.Count -eq 5) 'Paired fixture retains configured, granted-only and unknown-configuration permission evidence'

$riskFolder = Join-Path $OutputRoot 'permission-risk'
New-ReportFixture -Destination $riskFolder
$riskData = Get-Content -Raw (Join-Path $riskFolder '05-permission-surface.json') | ConvertFrom-Json
$riskPermissions = @(
    foreach ($permission in @(
        'AgentIdentityBlueprint.ReadWrite.All','AgentIdentityBlueprintPrincipal.Create','AgentRegistration.ReadWrite.All',
        'AgentIdentity.Read.All','AgentIdentity.DeleteRestore.All','Application.Read.All','User.Read','Mail.Read','Mail.ReadBasic',
        'AuditLog.Read.All','IdentityRiskEvent.Read.All'
    )) {
        [pscustomobject]@{
            SpObjectId = $riskData.GraphPermissions[0].SpObjectId; SpDisplayName = 'Synthetic Agent CLI'
            ResourceAppId = '00000003-0000-0000-c000-000000000000'; ResourceDisplayName = 'Microsoft Graph'
            PermissionValue = $permission; PermissionType = 'Delegated'; GrantState = 'Granted'
            ResolutionStatus = 'Resolved'; ConfiguredState = 'Granted but not configured'
            AdminConsentRequired = $false; ConsentScope = 'AllPrincipals'; Tier = 'STANDARD'
            MicrosoftOwned = $true; VendorRequired = $true; OfficiallyRequired = $true; BusinessRequired = $true
        }
    }
)
$customRisk = $riskPermissions[7].PSObject.Copy()
$customRisk.ResourceAppId = 'synthetic-custom-api'; $customRisk.ResourceDisplayName = 'Custom API'
$notGrantedRisk = $riskPermissions[0].PSObject.Copy()
$notGrantedRisk.GrantState = 'Not granted'; $notGrantedRisk.ConfiguredState = 'Configured'
$applicationRisk = @(foreach ($permission in @('AppRoleAssignment.ReadWrite.All','Mail.Read','Application.Read.All','AgentIdentity.Read.All')) {
    $row = $riskPermissions[0].PSObject.Copy()
    $row.PermissionValue = $permission; $row.PermissionType = 'Application'
    $row
})
$riskData | Add-Member -NotePropertyName NormalizedPermissions -NotePropertyValue (@($riskPermissions) + @($customRisk, $notGrantedRisk) + $applicationRisk)
Write-Dataset $riskFolder '05-permission-surface.json' $riskData
$riskReport = Render-Fixture 'permission-risk'
Assert-Report (($riskReport.Findings | Where-Object Id -eq 'WI.PERM.1').AffectedCount -eq 6 -and ($riskReport.Findings | Where-Object Id -eq 'WI.PERM.4').AffectedCount -eq 3) 'Report retains High management/content warnings and Tier 0 without treating ordinary delegated reads as red; unrated access stays Low'
Assert-Report (($riskReport.Findings | Where-Object Id -eq 'WI.PERM.5').AffectedCount -eq 3 -and ($riskReport.Findings | Where-Object Id -eq 'WI.PERM.6').AffectedCount -eq 3) 'Security/audit reads join Medium and ordinary inventory joins Info without changing application AZTier ratings'
Assert-Report ($riskReport.Data.'05'.NormalizedPermissions[6].Tier -eq 'LOWER_IMPACT' -and $riskReport.RawData.'05'.NormalizedPermissions[0].Tier -eq 'STANDARD') 'Offline report reclassifies old tiers without rewriting raw evidence'
Assert-Report ($riskReport.Assessment.PermissionRisk.Version -eq '1.2' -and $riskReport.Assessment.PermissionRisk.AZTier.TieredPermissions.Count -eq 614 -and $riskReport.Assessment.PermissionRisk.AZTier.UntieredPermissions.Count -eq 158) 'Report embeds updated read policy and the unchanged complete pinned AZTier mappings offline'
Assert-Report ($riskReport.Assessment.PermissionRisk.AZTier.LicenseText -like '*GNU GENERAL PUBLIC LICENSE*' -and $riskReport.Assessment.PermissionRisk.Limitations -like '*Low is not a researched low-risk*') 'Redistributed data retains its license and explicit unrated-policy disclaimer'
$riskSources = ($riskReport.Findings | Where-Object Id -eq 'WI.PERM.1').PermissionSourceUrls
Assert-Report ($riskReport.Assessment.PermissionRisk.AZTier.TieredSourceUrl -in $riskSources -and $riskReport.Assessment.PermissionRisk.Sources.SpecterOps -in $riskSources -and $riskReport.Assessment.PermissionRisk.Sources.RiskyPermissions -in $riskSources) 'Mixed-source findings expose their actual AZTier, Microsoft and corroborating research URLs rather than attributing every rating to Microsoft'

$principalOnlyFolder = Join-Path $OutputRoot 'principal-only'
New-ReportFixture -Destination $principalOnlyFolder
$principalOnly = Get-Content -Raw (Join-Path $principalOnlyFolder '02-inventory.json') | ConvertFrom-Json
$principalOnly.managedIdentities[0].ClientId = $null
$principalOnly.managedIdentities[0].PrincipalId = 'SYNTHETIC-PRINCIPAL-ONLY'
$principalOnly.servicePrincipals += [pscustomobject]@{
    SpObjectId = 'synthetic-principal-only'; DisplayName = 'MI without collected client ID'; ServicePrincipalType = 'ManagedIdentity'
}
Write-Dataset $principalOnlyFolder '02-inventory.json' $principalOnly
$null = Render-Fixture 'principal-only'

$previewFolder = Join-Path $OutputRoot 'credential-preview'
New-ReportFixture -Destination $previewFolder
$credentialData = Get-Content -Raw (Join-Path $previewFolder '03-credential-hygiene.json') | ConvertFrom-Json
$credentialData | Add-Member -NotePropertyName CredentialActivity -NotePropertyValue @{
    State = 'Available'; Preview = $true; InactiveThresholdDays = 90; Message = 'Synthetic matched credential activity.'
}
$oldCredential = $credentialData.Credentials[0]
$oldCredential | Add-Member -NotePropertyMembers @{
    InactiveCredential = $true; UsageAssessment = 'Inactive >= 90 days (review)'
    ActivityMatchStatus = 'Matched'; LastCredentialSignInDateTime = '2026-01-01T00:00:00Z'; CredentialReviewRequired = $true
    ActivityEvidence = @(@{ ActivityId = 'synthetic-activity'; ResourceId = 'synthetic-resource'; LastSignInDateTime = '2026-01-01T00:00:00Z' })
}
$unknownCredential = $oldCredential.PSObject.Copy()
$unknownCredential.CredentialDisplayName = 'Synthetic unknown usage'
$unknownCredential.InactiveCredential = $null
$unknownCredential.UsageAssessment = 'Unknown'
$unknownCredential.ActivityMatchStatus = 'No matching activity'
$unknownCredential.LastCredentialSignInDateTime = $null
$unknownCredential.ActivityEvidence = @()
$credentialData.Credentials = @($oldCredential, $unknownCredential)
$credentialData.Aggregations | Add-Member -NotePropertyMembers @{ InactiveCredentials90Days = 1; CredentialsWithoutActivityEvidence = 1 }
Write-Dataset $previewFolder '03-credential-hygiene.json' $credentialData
$permissionData = Get-Content -Raw (Join-Path $previewFolder '05-permission-surface.json') | ConvertFrom-Json
$requiredGrant = $permissionData.GraphPermissions[0]
$requiredGrant | Add-Member -NotePropertyMembers @{ BusinessRequired = $true; ReviewRequired = $true; ReviewReason = 'Validate justification even when required.' }
$readGrant = $requiredGrant.PSObject.Copy()
$readGrant.Tier = 'PRIVILEGED_READ'
$readGrant.PermissionValue = 'Directory.Read.All'
$unknownGrant = $requiredGrant.PSObject.Copy()
$unknownGrant.Tier = 'UNKNOWN'
$unknownGrant.PermissionValue = $null
$permissionData.GraphPermissions = @($requiredGrant, $readGrant, $unknownGrant)
$permissionData.AzureRbac[0] | Add-Member -NotePropertyName IsPrivilegedRole -NotePropertyValue $true
$permissionData.AzureRbac[0].RoleName = 'Owner'
Write-Dataset $previewFolder '05-permission-surface.json' $permissionData
$previewReport = Render-Fixture 'credential-preview'
Assert-Report (($previewReport.Findings | Where-Object Id -eq 'WI.CRED.4').AffectedCount -eq 1 -and ($previewReport.Assessment.Results | Where-Object Id -eq 'WI.CRED.4').UnknownCount -eq 1) 'Matched inactivity triggers review while unknown usage is counted explicitly, never inactivity'
Assert-Report (($previewReport.Findings | Where-Object Id -eq 'WI.PERM.1').AffectedCount -eq 1 -and ($previewReport.Findings | Where-Object Id -eq 'WI.PERM.6').AffectedCount -eq 1 -and ($previewReport.Findings | Where-Object Id -eq 'WI.PERM.4').AffectedCount -eq 1) 'Required Tier 0 stays High, directory inventory reads are Info, and unresolved capability gets explicit Low / Unrated'
Assert-Report ($previewReport.RawData.'05'.GraphPermissions[0].BusinessRequired -eq $true -and $previewReport.Data.'05'.NormalizedPermissions[0].RiskRuleId -eq 'AZTIER.0' -and $previewReport.Data.'05'.NormalizedPermissions[0].CapabilityRuleId -eq 'MS.IR.HIGH') 'Offline grading ignores business-required exemptions, retains separate Microsoft rationale and preserves raw evidence'
Assert-Report (($previewReport.Findings | Where-Object Id -eq 'WI.PERM.3').AffectedCount -eq 1) 'Privileged Azure RBAC has independent affected evidence'
$deniedFolder = Join-Path $OutputRoot 'credential-preview-denied'
New-ReportFixture -Destination $deniedFolder
$credentialData.CredentialActivity.State = 'Unavailable'
$credentialData.CredentialActivity.Message = 'Synthetic preview access denied.'
$credentialData.Credentials = @()
Write-Dataset $deniedFolder '03-credential-hygiene.json' $credentialData
$deniedReport = Render-Fixture 'credential-preview-denied'
Assert-Report (@($deniedReport.Findings | Where-Object Id -eq 'WI.CRED.4').Count -eq 0) 'Unavailable preview activity does not generate unused-credential findings'

$exposureFolder = Join-Path $OutputRoot 'exposure-review'
New-ReportFixture -Destination $exposureFolder
$exposureTenant = Get-Content -Raw (Join-Path $exposureFolder '01-tenant-context.json') | ConvertFrom-Json
$exposureTenant.TenantInfo | Add-Member -NotePropertyName VerifiedDomains -NotePropertyValue @('example.invalid')
Write-Dataset $exposureFolder '01-tenant-context.json' $exposureTenant
$exposureInventory = Get-Content -Raw (Join-Path $exposureFolder '02-inventory.json') | ConvertFrom-Json
$exposureInventory | Add-Member -NotePropertyName SchemaVersion -NotePropertyValue 2
$exposureInventory.appRegistrations[0] | Add-Member -NotePropertyMembers @{
    RedirectUris = @('https://example.invalid/callback','https://retired-domain.invalid/callback','native-app://callback')
    RequiredResourceAccess = @()
}
$exposureInventory.appRegistrations[1] | Add-Member -NotePropertyName RedirectUris -NotePropertyValue @()
$exposureInventory.servicePrincipals[0] | Add-Member -NotePropertyName PasswordCredentials -NotePropertyValue @(
    @{ keyId = 'sp-long-secret'; displayName = 'SP long-lived secret'; startDateTime = '2020-01-01T00:00:00Z'; endDateTime = '2040-01-01T00:00:00Z' }
)
Write-Dataset $exposureFolder '02-inventory.json' $exposureInventory
$exposureCredentials = Get-Content -Raw (Join-Path $exposureFolder '03-credential-hygiene.json') | ConvertFrom-Json
$longSecret = $exposureCredentials.Credentials[0].PSObject.Copy()
$longSecret.CredentialDisplayName = 'Long-lived application secret'
$longSecret.StartDateTime = '2020-01-01T00:00:00Z'; $longSecret.EndDateTime = '9999-12-31T00:00:00Z'; $longSecret.Expired = $false
$longSecret.LifetimeDays = ([datetimeoffset]$longSecret.EndDateTime - [datetimeoffset]$longSecret.StartDateTime).TotalDays
$longSecret.DaysUntilExpiry = ([datetimeoffset]$longSecret.EndDateTime - [datetimeoffset]$exposureCredentials.CollectedAt).Days
$longSecret | Add-Member -NotePropertyName KeyId -NotePropertyValue 'long-secret'
$unknownSecret = $longSecret.PSObject.Copy()
$unknownSecret.CredentialDisplayName = 'Unknown expiry secret'; $unknownSecret.KeyId = 'unknown-secret'
$unknownSecret.EndDateTime = $null; $unknownSecret.Expired = $null
$unknownSecret.LifetimeDays = $null; $unknownSecret.DaysUntilExpiry = $null
$shortSecret = $longSecret.PSObject.Copy()
$shortSecret.CredentialDisplayName = 'Within-threshold secret'; $shortSecret.KeyId = 'short-secret'
$shortSecret.StartDateTime = '2026-01-01T00:00:00Z'; $shortSecret.EndDateTime = '2027-01-01T00:00:00Z'
$shortSecret.LifetimeDays = 365; $shortSecret.DaysUntilExpiry = 364
$certificate = $longSecret.PSObject.Copy()
$certificate.CredentialDisplayName = 'Long-lived certificate'; $certificate.KeyId = 'certificate'; $certificate.CredentialType = 'key'
$exposureCredentials.Credentials = @($longSecret,$unknownSecret,$shortSecret,$certificate)
$exposureCredentials.Aggregations.ExpiredCredentialsStillAttached = 0
$exposureCredentials.Aggregations.ActiveSecretsOver24Months = 1
$exposureCredentials.Aggregations.ActiveSecretsOver12Months = 1
Write-Dataset $exposureFolder '03-credential-hygiene.json' $exposureCredentials
$exposurePermissions = Get-Content -Raw (Join-Path $exposureFolder '05-permission-surface.json') | ConvertFrom-Json
$exposureRows = @(foreach ($case in @(
    @('User.Read','AllPrincipals',$null,'Granted'),
    @('Mail.Read','AllPrincipals',$null,'Granted'),
    @('User.Read','Principal','specific-user','Granted'),
    @('Mail.Read','AllPrincipals',$null,'Not granted')
)) { [pscustomobject]@{
    SpObjectId = $exposureInventory.servicePrincipals[0].SpObjectId
    AppId = $exposureInventory.appRegistrations[0].AppId; SpDisplayName = $exposureInventory.servicePrincipals[0].DisplayName
    ResourceAppId = '00000003-0000-0000-c000-000000000000'; ResourceDisplayName = 'Microsoft Graph'
    PermissionValue = $case[0]; PermissionType = 'Delegated'; ResolutionStatus = 'Resolved'
    ConsentScope = $case[1]; ConsentPrincipalId = $case[2]; GrantState = $case[3]
    ConfiguredState = $(if ($case[3] -eq 'Granted') { 'Granted but not configured' } else { 'Configured' })
    ConsentStatus = $(if ($case[3] -eq 'Granted') { 'Granted delegated consent' } else { 'Not granted' })
    AdminConsentRequired = $false; AssignmentId = "consent-$($case[0])-$($case[1])-$($case[3])"
} })
$exposurePermissions | Add-Member -NotePropertyMembers @{
    NormalizedPermissions = $exposureRows
    DelegatedGrantEvidence = @{ State = 'Available' }
}
Write-Dataset $exposureFolder '05-permission-surface.json' $exposurePermissions
$exposureHashes = @(Get-ChildItem $exposureFolder -Filter '*.json' | Get-FileHash | Select-Object Path,Hash)
$exposureReport = Render-Fixture 'exposure-review'
Assert-Report (@(Compare-Object $exposureHashes @(Get-ChildItem $exposureFolder -Filter '*.json' | Get-FileHash | Select-Object Path,Hash) -Property Path,Hash).Count -eq 0) 'Exposure review leaves every original export byte-for-byte unchanged'
Assert-Report (($exposureReport.Findings | Where-Object Id -eq 'WI.CRED.6').AffectedCount -eq 2 -and ($exposureReport.Findings | Where-Object Id -eq 'WI.CRED.7').AffectedCount -eq 1) 'HTML evaluates application and SP secret lifetime exposure independently, excluding certificates and the 365-day boundary'
Assert-Report (($exposureReport.Findings | Where-Object Id -eq 'WI.APP.4').AffectedCount -eq 2 -and ($exposureReport.Findings | Where-Object Id -eq 'WI.APP.4').Severity -eq 'Med') 'HTML retains exact network redirect URIs for manual review including verified-domain matches'
Assert-Report (($exposureReport.Findings | Where-Object Id -eq 'WI.CONSENT.1').AffectedCount -eq 2 -and ($exposureReport.Findings | Where-Object Id -eq 'WI.CONSENT.1').Severity -eq 'Info' -and ($exposureReport.Findings | Where-Object Id -eq 'WI.PERM.1').AffectedCount -eq 1) 'Organization-wide consent is informational while actual dangerous delegated capability remains independently High'
Assert-Report ($null -eq $exposureReport.RawData.'03'.Credentials[0].SecretLifetimeStatus -and $null -eq $exposureReport.RawData.'02'.RedirectUriReviews -and $null -eq $exposureReport.RawData.'05'.NormalizedPermissions[0].ConsentAudience) 'Derived lifetime, redirect and consent annotations never leak into retained raw evidence'
Assert-Report ($exposureReport.Data.'03'.Credentials[1].SecretLifetimeStatus -like 'Unknown expiry*' -and [datetimeoffset]$exposureReport.Data.'02'.SpCredentials[0].StartDateTime -eq [datetimeoffset]'2020-01-01T00:00:00Z') 'Readable lifetime uncertainty and SP-origin start dates survive the embedded report payload'
Assert-Report ($exposureReport.Data.'03'.Credentials[0].SecretLifetimeStatus -like 'Long-lived*' -and $exposureReport.Data.'03'.Credentials[0].SecretLifetimeDays -gt 1000000) 'Far-future JSON DateTime expiry is correctly long-lived, never downgraded to missing expiry by runtime culture'

$entraFolder = Join-Path $OutputRoot 'entra'
New-ReportFixture -Destination $entraFolder
foreach ($entry in @(
    @('01-tenant-context.json', 'AzureSubscriptions'),
    @('02-inventory.json', 'managedIdentities'),
    @('04-federated-credentials.json', 'FICsOnUserAssignedMIs'),
    @('05-permission-surface.json', 'AzureRbac')
)) {
    $record = Get-Content -Raw (Join-Path $entraFolder $entry[0]) | ConvertFrom-Json
    $record | Add-Member -NotePropertyName AzureCollected -NotePropertyValue $false
    $record.($entry[1]) = $null
    Write-Dataset $entraFolder $entry[0] $record
}
Remove-Item -LiteralPath (Join-Path $entraFolder '07-monitoring-coverage.json')
$entra = Render-Fixture 'entra'
Assert-Report ($entra.AssessmentScope -eq 'Entra' -and @($entra.Sources | Where-Object State -eq 'Loaded').Count -eq 7) 'Entra-only exports retain usable Graph data rather than becoming partial datasets'
Assert-Report (($entra.Sources | Where-Object Id -eq '07').State -eq 'Not collected' -and $null -eq $entra.Data.'07') 'Azure monitoring is explicitly not collected'
Assert-Report ($null -eq $entra.Data.'02'.managedIdentities -and $null -eq $entra.Data.'05'.AzureRbac) 'Excluded Azure collections remain null, not empty successful results'
Assert-Report (@($entra.Findings | Where-Object Title -eq 'No Entra diagnostic settings').Count -eq 0) 'An excluded monitoring check cannot produce a missing-configuration finding'
Assert-Report ($entra.Data.'02'.appRegistrations.Count -eq 3 -and $entra.Data.'05'.GraphPermissions.Count -gt 0) 'Graph inventory and permission evidence survives Entra-only rendering'

foreach ($scenario in @('empty', 'single')) {
    $count = if ($scenario -eq 'empty') { 0 } else { 1 }
    New-ReportFixture -Destination (Join-Path $OutputRoot $scenario) -IdentityCount $count
    $payload = Render-Fixture $scenario
    Assert-Report ($payload.Data.'02'.appRegistrations.Count -eq $count) "$scenario inventory count"
    Assert-Report ($payload.Data.'03'.Credentials.Count -eq $count) "$scenario credential count"
    Assert-Report (@($payload.Sources | Where-Object State -eq 'Loaded').Count -eq 8) "$scenario is present, not missing"
}

$largeFolder = Join-Path $OutputRoot 'large'
New-ReportFixture -Destination $largeFolder -IdentityCount 550
$largeCredentials = Get-Content -Raw -LiteralPath (Join-Path $largeFolder '03-credential-hygiene.json') | ConvertFrom-Json
$largeCredentials.Credentials = @(1..225 | ForEach-Object {
    $record = $largeCredentials.Credentials[0].PSObject.Copy()
    $record.CredentialDisplayName = 'Synthetic credential {0:d4}' -f $_
    $record
})
Write-Dataset $largeFolder '03-credential-hygiene.json' $largeCredentials
$large = Render-Fixture 'large'
Assert-Report ($large.Data.'02'.appRegistrations.Count -eq 550) 'All identities beyond legacy limits are embedded'
Assert-Report ($large.Tables[0].Rows.Count -eq 225) 'All credentials beyond legacy limits are embedded'
Assert-Report ((Get-Content -Raw -LiteralPath (Join-Path $largeFolder 'report.html')).Contains('Synthetic workload 0550')) 'Last inventory record retained'

$hostileFolder = Join-Path $OutputRoot 'hostile'
New-ReportFixture -Destination $hostileFolder -HostileText
$hostile = Render-Fixture 'hostile'
$html = Get-Content -Raw -LiteralPath (Join-Path $hostileFolder 'report.html')
Assert-Report ($hostile.Data.'02'.appRegistrations[0].DisplayName.Contains('</script>')) 'Hostile text survives JSON round-trip'
Assert-Report ($hostile.Data.'02'.appRegistrations[0].DisplayName.Contains('__STYLES__ __DATA_JSON__')) 'Token-like tenant text is not processed as template markup'
Assert-Report (-not $html.Contains('<script>window.reportInjection')) 'Hostile closing script tags cannot execute'

$partialFolder = Join-Path $OutputRoot 'partial'
New-ReportFixture -Destination $partialFolder
Remove-Item -LiteralPath (Join-Path $partialFolder '02-inventory.json')
'{"Credentials":[]}' | Set-Content -LiteralPath (Join-Path $partialFolder '03-credential-hygiene.json')
'{"broken":' | Set-Content -LiteralPath (Join-Path $partialFolder '04-federated-credentials.json')
$partial = Render-Fixture 'partial'
Assert-Report (($partial.Sources | Where-Object Id -eq '02').State -eq 'Missing') 'Missing inventory is not zero inventory'
Assert-Report (($partial.Sources | Where-Object Id -eq '03').State -eq 'Partial') 'Missing aggregation fields are explicit'
Assert-Report (($partial.Sources | Where-Object Id -eq '04').State -eq 'Unreadable') 'Malformed JSON is explicit'
Assert-Report ($null -eq $partial.Data.'03') 'Partial dataset is not evaluated as complete'
Assert-Report ($partial.RawData.'03'.Credentials.Count -eq 0) 'Partial raw data retained'

$failedFolder = Join-Path $OutputRoot 'failed-collectors'
New-ReportFixture -Destination $failedFolder
foreach ($name in @('02-inventory.json', '05-permission-surface.json')) { Remove-Item -LiteralPath (Join-Path $failedFolder $name) }
Write-Dataset $failedFolder 'run-summary.json' @{
    ScriptResults = @(
        @{ Number = '02'; Status = 'Failed'; ExitCode = 1; ErrorMessage = 'Synthetic inventory failure' },
        @{ Number = '05'; Status = 'Failed'; ExitCode = 1; ErrorMessage = 'Synthetic null resource failure' }
    )
}
$failed = Render-Fixture 'failed-collectors'
Assert-Report (($failed.Sources | Where-Object Id -eq '02').State -eq 'Failed' -and ($failed.Sources | Where-Object Id -eq '05').Message -like '*Synthetic null resource failure*') 'Missing exports from known failed collectors show the actual failure instead of unknown collection status'
Assert-Report ($null -eq $failed.Data.'02' -and $null -eq $failed.Data.'05') 'Failure diagnostics do not invent replacement inventory or permission data'
Copy-Item -LiteralPath (Join-Path $normalFolder '02-inventory.json') -Destination $failedFolder
$failedWithExport = Render-Fixture 'failed-collectors'
Assert-Report (($failedWithExport.Sources | Where-Object Id -eq '02').State -eq 'Partial' -and $null -eq $failedWithExport.Data.'02' -and $failedWithExport.RawData.'02'.appRegistrations.Count -eq 3) 'An export from a failed collector is retained as raw evidence but not evaluated as complete'
Remove-Item -LiteralPath (Join-Path $failedFolder '02-inventory.json')
$null = Render-Fixture 'failed-collectors'

$absentFolder = Join-Path $OutputRoot 'absent'
$null = New-Item -ItemType Directory -Path $absentFolder -Force
$absent = Render-Fixture 'absent'
Assert-Report ($absent.Findings.Count -eq 0) 'No findings invented from absent exports'
Assert-Report (@($absent.Sources | Where-Object State -eq 'Missing').Count -eq 8) 'All missing exports are explicit'

$singleObjectFolder = Join-Path $OutputRoot 'single-object'
New-ReportFixture -Destination $singleObjectFolder -IdentityCount 1
$singleObject = Get-Content -Raw -LiteralPath (Join-Path $singleObjectFolder '02-inventory.json') | ConvertFrom-Json
$singleObject.appRegistrations = $singleObject.appRegistrations[0]
$singleObject.servicePrincipals = $singleObject.servicePrincipals[0]
Write-Dataset $singleObjectFolder '02-inventory.json' $singleObject
$null = Render-Fixture 'single-object'

$invalidFolder = Join-Path $OutputRoot 'invalid-shape'
New-ReportFixture -Destination $invalidFolder
$invalidInventory = Get-Content -Raw -LiteralPath (Join-Path $invalidFolder '02-inventory.json') | ConvertFrom-Json
$invalidInventory.servicePrincipals = @('not an exported identity')
Write-Dataset $invalidFolder '02-inventory.json' $invalidInventory
$invalidCredentials = Get-Content -Raw -LiteralPath (Join-Path $invalidFolder '03-credential-hygiene.json') | ConvertFrom-Json
$invalidCredentials.Aggregations = @{}
Write-Dataset $invalidFolder '03-credential-hygiene.json' $invalidCredentials
'[{"NotAnExport":true}]' | Set-Content -LiteralPath (Join-Path $invalidFolder '04-federated-credentials.json')
'null' | Set-Content -LiteralPath (Join-Path $invalidFolder '05-permission-surface.json')
$invalid = Render-Fixture 'invalid-shape'
Assert-Report (($invalid.Sources | Where-Object Id -eq '02').State -eq 'Partial') 'Invalid inventory structure is explicit'
Assert-Report (($invalid.Sources | Where-Object Id -eq '03').State -eq 'Partial') 'Missing nested metrics are not zeros'
Assert-Report (($invalid.Sources | Where-Object Id -eq '04').State -eq 'Unreadable') 'Single-item root arrays cannot masquerade as export objects'
Assert-Report (($invalid.Sources | Where-Object Id -eq '05').State -eq 'Unreadable') 'JSON null is unavailable, not zero'

$signinsFolder = Join-Path $OutputRoot 'no-signins'
New-ReportFixture -Destination $signinsFolder
$hygiene = Get-Content -Raw -LiteralPath (Join-Path $signinsFolder '06-stale-and-orphaned.json') | ConvertFrom-Json
$hygiene.SignInDataAvailable = $false
Write-Dataset $signinsFolder '06-stale-and-orphaned.json' $hygiene
$null = Render-Fixture 'no-signins'

$wrongIdsFolder = Join-Path $OutputRoot 'distinct-ids'
New-ReportFixture -Destination $wrongIdsFolder
$permissions = Get-Content -Raw -LiteralPath (Join-Path $wrongIdsFolder '05-permission-surface.json') | ConvertFrom-Json
$permissions.GraphPermissions[0].SpObjectId = $normal.Data.'02'.appRegistrations[0].AppId
Write-Dataset $wrongIdsFolder '05-permission-surface.json' $permissions
$null = Render-Fixture 'distinct-ids'

$runsRoot = Join-Path $OutputRoot 'snapshots'
$older = Join-Path $runsRoot '20260101-120000'
$newer = Join-Path $runsRoot '20260102-120000'
New-ReportFixture -Destination $older -IdentityCount 1
New-ReportFixture -Destination $newer
Remove-Item -LiteralPath (Join-Path $newer '03-credential-hygiene.json')
$latestPath = Join-Path $runsRoot 'latest.html'
& $renderer -OutputDir $runsRoot -ReportPath $latestPath
$latest = Read-Payload $latestPath
Assert-Report ($latest.RunDirectory -eq $newer) 'Latest timestamped run selected as a whole'
Assert-Report (($latest.Sources | Where-Object Id -eq '03').State -eq 'Missing') 'Older run cannot fill missing newer dataset'
& $renderer -OutputDir $runsRoot -RunDir '20260101-120000' -ReportPath (Join-Path $runsRoot 'pinned.html')
Assert-Report ((Read-Payload (Join-Path $runsRoot 'pinned.html')).Data.'02'.appRegistrations.Count -eq 1) 'Relative RunDir pins snapshot'
& $renderer -OutputDir $OutputRoot -RunDir $newer -ReportPath (Join-Path $runsRoot 'absolute.html')
Assert-Report ((Read-Payload (Join-Path $runsRoot 'absolute.html')).RunDirectory -eq $newer) 'Absolute RunDir supported'

$ambiguousRoot = Join-Path $OutputRoot 'ambiguous'
New-ReportFixture -Destination (Join-Path $ambiguousRoot 'first')
New-ReportFixture -Destination (Join-Path $ambiguousRoot 'second')
$rejected = $false
try { & $renderer -OutputDir $ambiguousRoot -ReportPath (Join-Path $ambiguousRoot 'report.html') }
catch { $rejected = $_.Exception.Message -like '*Ambiguous*' }
Assert-Report $rejected 'Ambiguous unlabelled snapshots are rejected'
Copy-Item -LiteralPath (Join-Path $normalFolder '02-inventory.json') -Destination (Join-Path $normalFolder '02-duplicate.json')
try {
    $rejected = $false
    try { $null = Render-Fixture 'normal' } catch { $rejected = $_.Exception.Message -like '*Multiple 02 exports*' }
    Assert-Report $rejected 'Duplicate collector outputs are rejected'
} finally {
    Remove-Item -LiteralPath (Join-Path $normalFolder '02-duplicate.json')
}

$packageRoot = Join-Path $OutputRoot 'azure-package'
$tmp = New-Item -ItemType Directory -Path $packageRoot -Force
$scriptDir = New-Item -ItemType Directory -Path (Join-Path $packageRoot 'scripts') -Force
$packageOutput = Join-Path $packageRoot 'output'
New-ReportFixture -Destination $packageOutput
$downloadBlock = [regex]::Match($deployment, '(?s)# Download scripts.*?(?=# Run each collection script)')
Assert-Report $downloadBlock.Success 'Deployment artifact downloader located'
$allowedArtifacts = @(
    '01-tenant-context.ps1', '02-inventory.ps1', '09-html-report.ps1', 'Assessment.Common.psm1', 'Assessment.Controls.psm1', '../controls/catalog.json',
    'report-assets/template.html', 'report-assets/styles.css', 'report-assets/app.js'
)
$artifactRequests = [System.Collections.Generic.List[string]]::new()
$savedEnvironment = @{}
foreach ($key in @('ARTIFACTS_BASE', 'ARTIFACTS_SAS', 'SCRIPT_IDS')) {
    $savedEnvironment[$key] = [Environment]::GetEnvironmentVariable($key)
}
function Invoke-WebRequest {
    param([string]$Uri, [string]$OutFile, [switch]$UseBasicParsing)
    Assert-Report ($Uri.StartsWith($env:ARTIFACTS_BASE) -and $Uri.EndsWith($env:ARTIFACTS_SAS)) 'Artifact base URL and SAS preserved'
    $artifact = $Uri.Substring($env:ARTIFACTS_BASE.Length)
    $artifact = $artifact.Substring(0, $artifact.Length - $env:ARTIFACTS_SAS.Length)
    Assert-Report ($artifact -in $allowedArtifacts) 'Downloader requests an expected local artifact'
    $artifactRequests.Add($artifact)
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $renderer) $artifact) -Destination $OutFile
}
try {
    $env:ARTIFACTS_BASE = 'https://example.invalid/scripts/'
    $env:ARTIFACTS_SAS = '?synthetic=1'
    $env:SCRIPT_IDS = '01-tenant-context,02-inventory'
    & ([scriptblock]::Create($downloadBlock.Value))
    Assert-Report (@(Compare-Object $allowedArtifacts $artifactRequests.ToArray()).Count -eq 0) 'Deployment packages all selected scripts and report assets'
} finally {
    Remove-Item -LiteralPath Function:Invoke-WebRequest
    foreach ($key in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($key, $savedEnvironment[$key])
    }
}
$packageReport = Join-Path $packageRoot 'report.html'
& (Join-Path $scriptDir.FullName '09-html-report.ps1') -OutputDir $packageOutput -ReportPath $packageReport
Assert-Report ((Read-Payload $packageReport).Findings.Count -eq $expectedControls.Count) 'Packaged renderer evaluates the same controls against flat Azure-style outputs'

$portableRoot = Join-Path $OutputRoot 'portable'
$null = New-Item -ItemType Directory -Path $portableRoot -Force
Copy-Item -LiteralPath $scriptDir.FullName -Destination $portableRoot -Recurse -Force
Copy-Item -LiteralPath (Join-Path $packageRoot 'controls') -Destination $portableRoot -Recurse -Force
Assert-Report (-not (Test-Path -LiteralPath (Join-Path $portableRoot 'output'))) 'Portable renderer has no default output folder'
$portableReport = Join-Path $portableRoot 'report.html'
& (Join-Path $portableRoot 'scripts/09-html-report.ps1') -RunDir $normalFolder -ReportPath $portableReport
Assert-Report ((Read-Payload $portableReport).RunDirectory -eq $normalFolder) 'Absolute RunDir works without a default OutputDir'

Write-Host "PASS: $checks report checks. Synthetic reports: $OutputRoot" -ForegroundColor Green
