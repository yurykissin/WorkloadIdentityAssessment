[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1.0
Import-Module (Join-Path $PSScriptRoot '../scripts/Assessment.Controls.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../scripts/Assessment.Common.psm1') -Force
$checks = 0
function Assert-Control([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Result([string]$Id) {
    (Invoke-WorkloadControls $data).Results | Where-Object Id -eq $Id
}
$principals = @(
    foreach ($i in 1..439) {
        $kind = if ($i -le 8 -or $i -gt 25) { 'Application' } elseif ($i -le 24) { 'ManagedIdentity' } else { 'SocialIdp' }
        $homeTenant = if ($i -le 25) { 'tenant' } elseif ($i -le 428) { '72f988bf-86f1-41af-91ab-2d7cd011db47' } else { 'vendor' }
        [pscustomobject]@{
            SpObjectId = "sp-$i"; AppId = "app-$i"; DisplayName = "Workload $i"
            ServicePrincipalType = $kind; AppOwnerOrganizationId = $homeTenant
            OwnerCount = if ($i -le 4 -or $i -gt 8) { 0 } else { 2 }
            LastSignIn = $null
            KeyCredentials = @(); PasswordCredentials = @()
        }
    }
)
$apps = @(foreach ($i in 1..8) { [pscustomobject]@{
    AppObjectId = "registration-$i"; AppId = "app-$i"; DisplayName = "Workload $i"
    SignInAudience = 'AzureADMyOrg'; OwnerCount = 2; HasImplicitGrantEnabled = $false
} })
$data = @{
    '01' = [pscustomobject]@{ AuthorizationPolicy = [pscustomobject]@{ AllowedToCreateApps = $false }; AdminConsentPolicy = [pscustomobject]@{ IsEnabled = $true; Reviewers = @(@{ Query = 'reviewer' }) } }
    '02' = [pscustomobject]@{
        TenantId = 'tenant'; SchemaVersion = 2; CollectedAt = '2026-10-24T09:16:44Z'
        appRegistrations = $apps; servicePrincipals = $principals; managedIdentities = $null
        WorkloadEvidence = [pscustomobject]@{}
    }
    '03' = [pscustomobject]@{ Credentials = @([pscustomobject]@{
        AppObjectId = 'registration-1'; AppId = 'app-1'; CredentialDisplayName = 'Expired automation certificate'
        CredentialType = 'key'; Expired = $true; EndDateTime = '2026-10-12T00:00:00Z'
        InactiveCredential = $null; ActivityMatchStatus = 'Incomplete activity'
    }) }
    '06' = [pscustomobject]@{
        CollectedAt = '2026-10-24T09:16:44Z'; SignInDataAvailable = $true
        ServicePrincipals = @([pscustomobject]@{ LastSignIn = $null; Stale90Days = $true; Stale365Days = $true })
        Aggregations = [pscustomobject]@{ Stale90Days = 1; Stale365Days = 1 }
    }
}
ConvertTo-WorkloadSnapshot $data
$owners = Result 'WI.OWN.1'
Assert-Control ($owners.EligibleCount -eq 8 -and $owners.AffectedCount -eq 4 -and $owners.ExcludedCount -eq 431) 'Owner denominator is 4 of 8 local Application SPs, never 21 of 25'
$groups = $data.'02'.servicePrincipals | Group-Object Category -AsHashTable
Assert-Control ($groups['Microsoft-owned'].Count -eq 403 -and $groups['External / third-party'].Count -eq 11 -and $groups['Managed identity'].Count -eq 16) '439 records reconcile by documented origin and object type'
Assert-Control ($data.'02'.servicePrincipals.Count -eq 439 -and $groups['Other / unknown'].Count -eq 1) 'Classification never drops SocialIdp or external records'
Assert-Control ($data.'02'.appRegistrations[0].SignInAudience -eq 'single-tenant' -and $data.'02'.servicePrincipals[0].SignInAudience -eq 'single-tenant') 'App and linked SP audience filters use the same readable authoritative audience'
Assert-Control ((Result 'WI.CRED.1').AffectedRows[0].AppObjectId -eq 'registration-1' -and (Result 'WI.CRED.4').UnknownCount -eq 1) 'Expired evidence is reachable without inventing credential inactivity'
Assert-Control ($data.'06'.Aggregations.Stale365Days -eq 0 -and $null -eq $data.'06'.Aggregations.NeverSignedIn) 'Legacy missing activity does not become stale or never-used'
Assert-Control ((Result 'WI.LIFE.1').Outcome -eq 'Not assessed' -and (Result 'WI.LIFE.1').UnknownCount -eq 8) 'Absent activity cannot pass an inactivity predicate'
$data.'02'.servicePrincipals[0].OwnerCount = $null
Assert-Control ((Result 'WI.OWN.1').UnknownCount -eq 1 -and (Result 'WI.OWN.1').AffectedCount -eq 3) 'Collected zero and unavailable owner count remain distinct'
$data.'02'.servicePrincipals[0].AppOwnerOrganizationId = $null
$data.'02'.servicePrincipals[0].DisplayName = 'Microsoft default application'
ConvertTo-WorkloadSnapshot $data
Assert-Control ($data.'02'.servicePrincipals[0].Category -eq 'Other / unknown') 'Names and absent home tenant never establish Microsoft or tenant ownership'
$data.'02'.servicePrincipals[1].LastSignIn = '2099-01-01T00:00:00Z'
$data.'02'.servicePrincipals[2].LastSignIn = '0001-01-01T00:00:00Z'
$data.'02'.servicePrincipals[3].LastSignIn = '2025-01-01T00:00:00Z'
ConvertTo-WorkloadSnapshot $data
Assert-Control ($null -eq $data.'02'.servicePrincipals[1].LastSignIn -and $null -eq $data.'02'.servicePrincipals[2].LastSignIn -and (Result 'WI.LIFE.1').AffectedCount -eq 1) 'Snapshot time, sentinel and future timestamps are enforced'
$summary = Get-AssessmentActivitySummary ([pscustomobject]@{
    lastSignInActivity = @{ lastSignInDateTime = '2026-01-01T00:00:00Z' }
    delegatedResourceSignInActivity = @{ lastSignInDateTime = '2026-03-01T00:00:00Z' }
    applicationAuthenticationResourceSignInActivity = @{ lastSignInDateTime = '2026-09-01T00:00:00Z' }
    applicationAuthenticationClientSignInActivity = @{ lastSignInDateTime = 'invalid' }
}) -AsOf '2026-10-24T00:00:00Z'
Assert-Control ($summary.LastSignIn -like '2026-09-01*' -and $summary.Flows.delegatedResourceSignInActivity -like '2026-03-01*') 'Supported client/resource flows are retained independently and dates are validated'
$policy = [pscustomobject]@{
    isEnabled = $true
    applicationRestrictions = [pscustomobject]@{
        passwordCredentials = @(
            [pscustomobject]@{ restrictionType = 'passwordAddition'; state = 'enabled' },
            [pscustomobject]@{ restrictionType = 'symmetricKeyAddition'; state = 'enabled' },
            [pscustomobject]@{ restrictionType = 'passwordLifetime'; state = 'enabled'; maxLifetime = 'P181D' },
            [pscustomobject]@{ restrictionType = 'symmetricKeyLifetime'; state = 'enabled'; maxLifetime = 'P181D' }
        )
        keyCredentials = @([pscustomobject]@{ restrictionType = 'asymmetricKeyLifetime'; state = 'enabled'; maxLifetime = 'P366D' })
    }
}
$policy | Add-Member -NotePropertyName servicePrincipalRestrictions -NotePropertyValue ($policy.applicationRestrictions | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
$evidence = $data.'02'.WorkloadEvidence
$evidence | Add-Member -NotePropertyMembers @{
    DefaultAppManagementPolicy = [pscustomobject]@{ State = 'Available'; Records = @($policy) }
    AppManagementPolicies = [pscustomobject]@{ State = 'Available'; Records = @() }
}
Assert-Control ((Result 'WI.POL.1').Outcome -eq 'Pass' -and (Result 'WI.POL.2').Outcome -eq 'Pass' -and (Result 'WI.POL.3').Outcome -eq 'Pass') 'Complete defaults use the pinned 181/366 exclusive thresholds and both object types'
$policy.applicationRestrictions.keyCredentials[0].maxLifetime = 'P367D'
Assert-Control ((Result 'WI.POL.3').Outcome -eq 'Fail') 'Overlong preventive certificate limit fails independently of inventory expiry'
$policy.applicationRestrictions.keyCredentials[0] | Add-Member -NotePropertyName excludeActors -NotePropertyValue @{ customSecurityAttributes = @(@{ id = 'exception' }) }
Assert-Control ((Result 'WI.POL.3').Outcome -eq 'Not assessed') 'Caller exclusions prevent an automatic tenant-wide pass or failure'
$evidence.AppManagementPolicies.Records = @([pscustomobject]@{ isEnabled = $true })
Assert-Control ((Result 'WI.POL.1').Outcome -eq 'Not assessed') 'Enabled per-object override inventory requires manual effective-policy review'
$evidence.AppManagementPolicies.State = 'Unavailable'
Assert-Control ((Result 'WI.POL.2').Outcome -eq 'Not assessed') 'An inaccessible override list cannot be an all-clear'
$evidence | Add-Member -NotePropertyName AgentIdentities -NotePropertyValue @{ State = 'Available'; Records = @(@{ id = 'sp-2' }) }
$evidence | Add-Member -NotePropertyName AgentBlueprints -NotePropertyValue @{ State = 'Available'; Records = @(@{ id = 'registration-2' }) }
$data.'02'.servicePrincipals[2].KeyCredentials = @(@{ keyId = 'sp-key'; displayName = 'SP certificate'; endDateTime = '2020-01-01T00:00:00Z' })
ConvertTo-WorkloadSnapshot $data
Assert-Control ($data.'02'.appRegistrations[1].Category -eq 'Agent ID' -and $data.'02'.servicePrincipals[1].Category -eq 'Agent ID') 'Already inventoried agents and blueprints have a distinct category'
Assert-Control ((Result 'WI.CRED.5').AffectedRows[0].SpObjectId -eq 'sp-3') 'SP-origin expiry is assessed separately without matching application-origin activity'
$audit = [pscustomobject]@{ State = 'Available'; Records = @(
    @{ id = 'failed'; result = 'failure'; activityDisplayName = 'Add application'; targetResources = @(@{ id = 'registration-1' }) },
    @{ id = 'created'; result = 'success'; activityDisplayName = 'Add application'; activityDateTime = '2026-10-01T00:00:00Z'; initiatedBy = @{ app = @{ displayName = 'Provisioner' } }; targetResources = @(@{ id = 'registration-1' }) }
) }
Assert-Control ((Get-AssessmentCreator 'registration-1' $audit).EventId -eq 'created' -and (Get-AssessmentCreator 'sp-1' $audit).State -eq 'Unavailable') 'Creator uses successful target-ID creation audits, never linked owners or app/SP conflation'
$assessment = Invoke-WorkloadControls $data
Assert-Control (@($assessment.BaselineApplicability.PSObject.Properties).Count -eq 34) 'Every pinned baseline control has an explicit applicability entry'
Assert-Control (@($assessment.Results | Where-Object { $_.Outcome -eq 'Not assessed' -and $_.EvaluatedCount -ne 0 }).Count -eq 0) 'Manual or unavailable assessments do not claim evaluated records'
Assert-Control (@($assessment.Results | Where-Object { -not $_.SourceUrl }).Count -eq 0) 'All controls include an authoritative source'
Assert-Control (@((Invoke-WorkloadControls @{}).Results | Where-Object Outcome -ne 'Not assessed').Count -eq 0) 'Missing datasets cannot pass any control'

function New-Permission([string]$Value, [string]$Type = 'Delegated', [string]$Api = '00000003-0000-0000-c000-000000000000') {
    [pscustomobject]@{
        SpObjectId = 'synthetic-risk-client'; PermissionValue = $Value; PermissionType = $Type
        ResourceAppId = $Api; ResolutionStatus = 'Resolved'; GrantState = 'Granted'
        ConsentScope = 'AllPrincipals'; ConsentPrincipalId = $null
        AdminConsentRequired = $false; Tier = 'STANDARD'
        MicrosoftOwned = $true; VendorRequired = $true; BusinessRequired = $true; OfficiallyRequired = $true
    }
}
$published = @(
    'Mail.Read','Mail.Send.Shared','Contacts.Read','MailboxSettings.ReadWrite','People.Read','Files.Read','Notes.Read',
    'Directory.AccessAsUser.All','Application.ReadWrite.All','Directory.ReadWrite.All','Domain.ReadWrite.All',
    'EduRoster.ReadWrite.All','Group.ReadWrite.All','Member.Read.Hidden','RoleManagement.ReadWrite.Directory',
    'User.ReadWrite.All','User.ManageCreds.All'
)
foreach ($type in @('Delegated','Application')) {
    $riskRows = @($published | ForEach-Object { New-Permission $_ $type })
    Set-WorkloadPermissionRisk $riskRows
    Assert-Control (@($riskRows | Where-Object { -not $_.ReviewRequired -or $_.CapabilityRuleId -notlike 'MS.IR.*' }).Count -eq 0) "All published categories retain $type capability warnings without publisher, required-permission or admin-consent exemptions"
    if ($type -eq 'Delegated') {
        Assert-Control (@($riskRows | Where-Object RiskSeverity -ne 'High').Count -eq 0) 'Application-only AZTier translations never downgrade published delegated warnings'
    }
}
$agentRows = @(
    'AgentIdentityBlueprint.ReadWrite.All','AgentIdentityBlueprintPrincipal.Create','AgentRegistration.ReadWrite.All',
    'AgentIdentity.Read.All','AgentIdentity.DeleteRestore.All','Application.Read.All','User.Read'
) | ForEach-Object { New-Permission $_ }
Set-WorkloadPermissionRisk $agentRows
Assert-Control (@($agentRows | Where-Object RiskSeverity -eq 'High').Count -eq 4 -and @($agentRows | Where-Object { $_.Tier -eq 'INFORMATIONAL' -and $_.RiskSeverity -eq 'Info' }).Count -eq 2 -and $agentRows[-1].Tier -eq 'LOWER_IMPACT') 'Agent CLI has four High management grants and two Info inventory reads, not six red warnings'
Assert-Control (@($agentRows | Where-Object { $_.ReviewRequired -and $_.RiskOrigin -ne 'Toolkit capability extension' }).Count -eq 0) 'New Agent ID and reconnaissance classifications are explicitly toolkit extensions'
Assert-Control ($agentRows[1].RiskRuleId -eq 'TK.AGENT.WRITE' -and $agentRows[3].Tier -eq 'INFORMATIONAL' -and $agentRows[4].Tier -eq 'PRIVILEGED') 'Create and delete/restore remain privileged while inventory reads are informational'
Assert-Control ($agentRows[1].AccessContext -like 'Delegated*' -and $agentRows[1].RiskSourceUrl -like '*graph/permissions-reference') 'Delegated risk retains signed-in-user context and official capability source'
$boundaryRows = @(
    (New-Permission 'Mail.ReadBasic'), (New-Permission 'Mail.ReadBasic.All' 'Application'),
    (New-Permission 'Mail.Read' 'Delegated' 'custom-api'), (New-Permission 'Mail.Read' 'Unknown'),
    (New-Permission 'Application.ReadWrite.All.Spoof'), (New-Permission 'Mailicious.Read'),
    (New-Permission 'User.Read' 'Application'), (New-Permission 'OpaquePermission')
)
Set-WorkloadPermissionRisk $boundaryRows
Assert-Control ($boundaryRows[1].Tier -eq 'RESTRICTED' -and $boundaryRows[1].AZTier -eq '1') 'Mail.ReadBasic.All application access gets its explicit AZTier 1 rating, not a fabricated safe rating from the Microsoft Mail-family exclusion'
Assert-Control (@($boundaryRows | Where-Object { $_ -ne $boundaryRows[1] -and $_.Tier -ne 'UNCLASSIFIED' }).Count -eq 0) 'Exclusions, API/type collisions, exact-name boundaries and unlisted names are unclassified, never silently safe or falsely matched'
$write = New-Permission 'Custom.Write.All' 'Application' 'custom-api'
$impersonation = New-Permission 'user_impersonation' 'Delegated' 'custom-sensitive-api'
$legacy = New-Permission 'Mail.Read' 'Delegated' '00000002-0000-0ff1-ce00-000000000000'
Set-WorkloadPermissionRisk @($write, $impersonation, $legacy)
Assert-Control ($write.RiskRuleId -eq 'MS.IR.APPWRITE' -and $write.RiskOrigin -like 'Toolkit capability matching*') 'Application-only write naming is a labelled capability interpretation of the published general category'
Assert-Control ($impersonation.RiskRuleId -eq 'MS.IR.IMPERSONATION' -and $legacy.RiskRuleId -eq 'MS.IR.SENSITIVE') 'Blanket user impersonation covers other APIs and known legacy APIs retain sensitive categories'
$configured = New-Permission 'Mail.Read'
$configured.GrantState = 'Not granted'
$unknown = New-Permission ''
$unknown.ResolutionStatus = 'Unresolved'
$mixed = @($agentRows) + @($boundaryRows[2], $unknown, $configured)
$permissionOnly = @{ '05' = [pscustomobject]@{ NormalizedPermissions = $mixed } }
ConvertTo-WorkloadSnapshot $permissionOnly
$exposure = (Invoke-WorkloadControls $permissionOnly).Results | Where-Object Id -eq 'WI.PERM.1'
$coverageGap = (Invoke-WorkloadControls $permissionOnly).Results | Where-Object Id -eq 'WI.PERM.4'
Assert-Control ($exposure.AffectedCount -eq 4 -and $coverageGap.AffectedCount -eq 2) 'High management versus unclassified/unresolved grants have separate findings; Info reads and configured-only requests do not inflate High'
Assert-Control (-not $configured.ReviewRequired -and $configured.Tier -eq 'PRIVILEGED') 'Configured requests show capability without pretending an existing dangerous grant'
$offline = New-Permission 'offline_access'
$low = New-Permission 'User.Read'
Set-WorkloadPermissionRisk @($offline, $low)
Assert-Control ($offline.Tier -eq 'LOWER_IMPACT') 'Offline access is lower impact only with an eligible companion'
$sensitive = New-Permission 'Mail.Read'
Set-WorkloadPermissionRisk @($offline, $low, $sensitive)
Assert-Control ($offline.Tier -eq 'UNCLASSIFIED' -and $offline.ReviewRequired) 'Offline access with sensitive companion scopes is not labelled lower impact'
$sensitive.ConsentScope = 'Principal'; $sensitive.ConsentPrincipalId = 'different-user'
Set-WorkloadPermissionRisk @($offline, $low, $sensitive)
Assert-Control ($offline.Tier -eq 'LOWER_IMPACT') 'Offline-access companion grouping preserves consent scope and subject'
Set-WorkloadPermissionRisk @($offline)
Assert-Control ($offline.Tier -eq 'UNCLASSIFIED') 'Offline access alone does not pass the conditional lower-impact rule'
$low.ConsentScope = 'Principal'; $low.ConsentPrincipalId = 'another-user'
Set-WorkloadPermissionRisk @($offline, $low)
Assert-Control ($offline.Tier -eq 'UNCLASSIFIED') 'Another consent subject cannot supply a missing lower-impact companion'
$low.ConsentScope = 'Unknown'; $offline.ConsentScope = 'Unknown'
Set-WorkloadPermissionRisk @($offline, $low)
Assert-Control ($offline.Tier -eq 'UNCLASSIFIED') 'Unknown consent scope cannot establish a lower-impact offline-access pairing'
$low.ConsentScope = 'Principal'; $offline.ConsentScope = 'Principal'; $low.ConsentPrincipalId = $null
Set-WorkloadPermissionRisk @($offline, $low)
Assert-Control ($offline.Tier -eq 'UNCLASSIFIED') 'Missing user subject cannot establish a lower-impact offline-access pairing'
$old = New-Permission 'AgentIdentityBlueprintPrincipal.Create'
$legacyData = @{ '05' = [pscustomobject]@{ GraphPermissions = @($old); NormalizedPermissions = @($old) } }
$raw = $legacyData | ConvertTo-Json -Depth 30
$derived = $raw | ConvertFrom-Json -AsHashtable
$derived.'05' = ($derived.'05' | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
ConvertTo-WorkloadSnapshot $derived
Assert-Control ($derived.'05'.NormalizedPermissions[0].Tier -eq 'PRIVILEGED' -and $old.Tier -eq 'STANDARD') 'Offline normalization replaces stale tiers even without inventory and does not mutate separately retained raw evidence'
Assert-Control ($derived.'05'.NormalizedPermissions[0].RiskCatalogVersion -and $derived.'05'.NormalizedPermissions[0].RiskRuleId) 'Each derived row records catalog provenance'
$unavailablePermissions = @{ '05' = [pscustomobject]@{ NormalizedPermissions = $null } }
ConvertTo-WorkloadSnapshot $unavailablePermissions
Assert-Control (@((Invoke-WorkloadControls $unavailablePermissions).Results | Where-Object { $_.Id -in @('WI.PERM.1','WI.PERM.4') -and $_.Outcome -ne 'Not assessed' }).Count -eq 0) 'Explicitly unavailable permission rows remain not assessed without breaking normalization'

$catalog = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../controls/catalog.json') -Raw | ConvertFrom-Json -Depth 50
$tierRows = @(foreach ($entry in $catalog.PermissionRisk.AZTier.TieredPermissions) {
    $row = New-Permission $entry.PermissionValue 'Application'
    $row | Add-Member -NotePropertyName AppRoleId -NotePropertyValue $entry.PermissionId
    $row
})
Set-WorkloadPermissionRisk $tierRows
foreach ($sourceTier in @('0','1','2')) {
    $expectedSeverity = @{ '0' = 'High'; '1' = 'Med'; '2' = 'Info' }[$sourceTier]
    $matches = @($tierRows | Where-Object AZTier -eq $sourceTier)
    Assert-Control ($matches.Count -gt 0 -and @($matches | Where-Object {
        $_.RiskSeverity -ne $expectedSeverity -or $_.RiskMappingState -ne 'Reviewed' -or
        $_.RiskSourceUrl -notlike "*/$($catalog.PermissionRisk.AZTier.Revision)/*" -or -not $_.ReviewRequired
    }).Count -eq 0) "Every imported AZTier $sourceTier entry maps to $expectedSeverity with pinned provenance and grant visibility"
}
$untieredRows = @(foreach ($entry in $catalog.PermissionRisk.AZTier.UntieredPermissions) {
    $row = New-Permission $entry.PermissionValue 'Application'
    $row | Add-Member -NotePropertyName AppRoleId -NotePropertyValue $entry.PermissionId
    $row
})
Set-WorkloadPermissionRisk $untieredRows
Assert-Control (@($untieredRows | Where-Object {
    $_.RiskSeverity -ne 'Low' -or $_.RiskMappingState -ne 'Untiered' -or $_.AZTier -or
    -not $_.AZTierDetectedOn -or $_.RiskSourceUrl -ne $catalog.PermissionRisk.AZTier.UntieredSourceUrl
}).Count -eq 0) 'Every detected-but-unreviewed application permission is Low / Unrated, not given a fabricated AZTier rating'
$agentUntiered = $untieredRows | Where-Object PermissionValue -eq 'AgentIdentityBlueprint.ReadWrite.All'
Assert-Control ($agentUntiered.CapabilityRuleId -eq 'TK.AGENT.WRITE' -and $agentUntiered.CapabilityReason -and $agentUntiered.ReviewReason -like '*not a researched low-risk*') 'Untiered Low policy retains known dangerous capability rationale rather than suppressing it'
$roleGrant = $tierRows | Where-Object PermissionValue -eq 'AppRoleAssignment.ReadWrite.All'
Assert-Control ($roleGrant.RiskReferences.Count -eq 2 -and @($roleGrant.RiskReferences | Where-Object { $_.Source -notin @('SpecterOps','Semperis') -or -not $_.Url }).Count -eq 0) 'Dangerous permission-grant capability includes concrete SpecterOps and Semperis corroboration alongside AZTier'
$contrast = @(
    (New-Permission 'Application.Read.All' 'Application'),
    (New-Permission 'Application.Read.All' 'Delegated'),
    (New-Permission 'Application.Read.All' 'Application' 'custom-api'),
    (New-Permission 'Mail.Read' 'Application'),
    (New-Permission 'OpaquePermission' 'Application')
)
Set-WorkloadPermissionRisk $contrast
Assert-Control ($contrast[0].RiskSeverity -eq 'Info' -and $contrast[0].RiskRuleId -eq 'AZTIER.2' -and $contrast[1].RiskSeverity -eq 'Info' -and $contrast[1].RiskRuleId -eq 'TK.GRAPH.READ' -and $contrast[2].RiskSeverity -eq 'Low') 'Application and delegated inventory reads can both be Info while retaining distinct sources and custom-API boundaries'
Assert-Control ($contrast[3].RiskSeverity -eq 'Med' -and $contrast[3].CapabilityRuleId -eq 'MS.IR.SENSITIVE') 'Sensitive app-only reads get Tier 1 / Medium while retaining Microsoft sensitive-data rationale'
Assert-Control ($contrast[4].RiskMappingState -eq 'Unclassified' -and $contrast[4].RiskSeverity -eq 'Low' -and $unknown.RiskSeverity -eq 'Low') 'Truly unlisted and unresolved permissions use the requested Low priority with explicit coverage states'
$idMismatch = New-Permission 'Application.Read.All' 'Application'
$idMismatch | Add-Member -NotePropertyName AppRoleId -NotePropertyValue '00000000-0000-0000-0000-000000000001'
Set-WorkloadPermissionRisk @($idMismatch)
Assert-Control ($idMismatch.RiskSeverity -eq 'Low' -and $idMismatch.Tier -eq 'UNKNOWN' -and $idMismatch.AZTierStatus -eq 'Permission ID/name mismatch') 'A conflicting exported permission GUID cannot inherit a researched tier solely by name'
$sourceMissing = New-Permission 'Application.Read.All' 'Application'
$sourceMissing.ResolutionStatus = 'Unresolved'
Set-WorkloadPermissionRisk @($sourceMissing)
Assert-Control ($sourceMissing.RiskMappingState -eq 'Unresolved' -and -not $sourceMissing.AZTier -and $sourceMissing.AZTierStatus -eq 'Not assessed (unresolved definition)') 'An unresolved definition cannot gain a rating or a false not-listed claim from a retained display value'
$configuredTier = New-Permission 'Mail.Read' 'Application'
$configuredTier.GrantState = 'Not granted'
Set-WorkloadPermissionRisk @($configuredTier)
$grading = @{ '05' = [pscustomobject]@{ NormalizedPermissions = @($tierRows[0], $contrast[3], $contrast[0], $agentUntiered, $configuredTier) } }
$gradedResults = (Invoke-WorkloadControls $grading).Results
foreach ($expectation in @(@('WI.PERM.1','High'), @('WI.PERM.5','Med'), @('WI.PERM.6','Info'), @('WI.PERM.4','Low'))) {
    $result = $gradedResults | Where-Object Id -eq $expectation[0]
    Assert-Control ($result.Severity -eq $expectation[1] -and $result.AffectedCount -eq 1) "Finding $($expectation[0]) contains only granted $($expectation[1]) evidence, never requested-only access"
}
$fullyMapped = (Invoke-WorkloadControls @{ '05' = [pscustomobject]@{ NormalizedPermissions = @($contrast[0]) } }).Results | Where-Object Id -eq 'WI.PERM.4'
Assert-Control ($fullyMapped.UnknownCount -eq 0 -and $fullyMapped.Outcome -eq 'Pass') 'A fully resolved researched grant does not become unknown merely because no unrated finding exists'
$inventoryReads = @(
    'AgentIdentity.Read.All','AgentIdentityBlueprint.Read.All','AgentIdentityBlueprintPrincipal.Read.All','AgentRegistration.Read.All',
    'Application.Read.All','Directory.Read.All','RoleManagement.Read.Directory','User.Read.All','Group.Read.All'
) | ForEach-Object { New-Permission $_ }
Set-WorkloadPermissionRisk $inventoryReads
Assert-Control (@($inventoryReads | Where-Object { $_.RiskSeverity -ne 'Info' -or $_.CapabilitySeverity -ne 'Info' -or $_.RiskLabel -ne 'Info - inventory read' }).Count -eq 0) 'Every ordinary delegated agent/app/directory inventory rule is Info with no elevated capability severity'
$securityReads = @('AuditLog.Read.All','IdentityRiskEvent.Read.All') | ForEach-Object { New-Permission $_ }
Set-WorkloadPermissionRisk $securityReads
Assert-Control (@($securityReads | Where-Object { $_.RiskSeverity -ne 'Med' -or $_.RiskRuleId -ne 'TK.GRAPH.SECURITY.READ' -or $_.CapabilitySeverity -ne 'Med' }).Count -eq 0) 'Security and audit read capabilities are distinct Medium review, not red management or Info inventory'
$readGrading = (Invoke-WorkloadControls @{ '05' = [pscustomobject]@{ NormalizedPermissions = @($inventoryReads) + @($securityReads) + @($agentRows[0], $sensitive) } }).Results
Assert-Control (($readGrading | Where-Object Id -eq 'WI.PERM.1').AffectedCount -eq 2 -and ($readGrading | Where-Object Id -eq 'WI.PERM.5').AffectedCount -eq 2 -and ($readGrading | Where-Object Id -eq 'WI.PERM.6').AffectedCount -eq 9) 'Read-priority change preserves High writes and sensitive-content reads while separating Medium security reads and Info inventory'
$secretData = @{
    '03' = [pscustomobject]@{
        CollectedAt = '2026-10-26T00:00:00Z'
        Credentials = @(foreach ($case in @(
            @('long','2026-01-01T00:00:00Z','2046-01-01T00:00:00Z','password'),
            @('far-future','2026-01-01T00:00:00Z','9999-12-31T00:00:00Z','password'),
            @('missing-end','2026-01-01T00:00:00Z',$null,'password'),
            @('invalid-end','2026-01-01T00:00:00Z','not-a-date','password'),
            @('missing-start',$null,'2027-01-01T00:00:00Z','password'),
            @('invalid-range','2028-01-01T00:00:00Z','2027-01-01T00:00:00Z','password'),
            @('boundary','2026-01-01T00:00:00Z','2027-01-01T00:00:00Z','password'),
            @('over-boundary','2026-01-01T00:00:00Z','2027-01-01T00:00:01Z','password'),
            @('expired','2023-01-01T00:00:00Z','2025-01-01T00:00:00Z','password'),
            @('certificate','2026-01-01T00:00:00Z','2046-01-01T00:00:00Z','key')
        )) { [pscustomobject]@{
            AppObjectId = 'registration'; KeyId = $case[0]; CredentialType = $case[3]
            StartDateTime = $case[1]; EndDateTime = $case[2]
        } })
    }
}
ConvertTo-WorkloadSnapshot $secretData
$secretResult = (Invoke-WorkloadControls $secretData).Results | Where-Object Id -eq 'WI.CRED.6'
Assert-Control ($secretResult.AffectedCount -eq 7 -and $secretResult.UnknownCount -eq 4 -and $secretResult.Outcome -eq 'Review') 'Long, far-future, malformed and incomplete secret lifetimes have exact affected evidence without hiding unknowns'
Assert-Control (@($secretResult.AffectedRows.KeyId | Where-Object { $_ -in @('expired','certificate','boundary') }).Count -eq 0) 'Expired secrets, certificates and exact 365-day boundary do not become long-lived active secret findings'
Assert-Control (($secretResult.AffectedRows | Where-Object KeyId -eq 'missing-end').SecretLifetimeStatus -like 'Unknown expiry*') 'Missing end date is explicitly unknown, never asserted to be infinite validity'
Assert-Control (($secretResult.AffectedRows | Where-Object KeyId -eq 'over-boundary').SecretLifetimeDays -gt 365) 'Fractional days are not rounded down at the lifetime threshold'
$spSecretData = @{ '02' = [pscustomobject]@{
    SchemaVersion = 2; CollectedAt = '2026-10-26T00:00:00Z'; appRegistrations = @()
    servicePrincipals = @([pscustomobject]@{
        SpObjectId = 'sp-secret'; ServicePrincipalType = 'Application'
        PasswordCredentials = @(@{ keyId = 'sp-secret-key'; startDateTime = '2026-01-01T00:00:00Z'; endDateTime = '2046-01-01T00:00:00Z' })
    })
} }
ConvertTo-WorkloadSnapshot $spSecretData
$spSecretResult = (Invoke-WorkloadControls $spSecretData).Results | Where-Object Id -eq 'WI.CRED.7'
Assert-Control ($spSecretResult.AffectedCount -eq 1 -and $spSecretResult.AffectedRows[0].SpObjectId -eq 'sp-secret' -and $spSecretResult.AffectedRows[0].StartDateTime) 'SP-origin secrets retain start/end and exact principal/key evidence independently of app registration credentials'
$missingSecret = (Invoke-WorkloadControls @{ '03' = [pscustomobject]@{ Credentials = $null } }).Results | Where-Object Id -eq 'WI.CRED.6'
Assert-Control ($missingSecret.Outcome -eq 'Not assessed') 'Unavailable credentials cannot pass secret-lifetime checks'
$undatedSecret = @{ '03' = [pscustomobject]@{
    CollectedAt = $null
    Credentials = @([pscustomobject]@{ CredentialType = 'password'; StartDateTime = '2026-01-01T00:00:00Z'; EndDateTime = '2027-01-01T00:00:00Z' })
} }
foreach ($snapshotTime in @($null,'0001-01-01T00:00:00Z')) {
    $undatedSecret.'03'.CollectedAt = $snapshotTime
    $undatedResult = (Invoke-WorkloadControls $undatedSecret).Results | Where-Object Id -eq 'WI.CRED.6'
    Assert-Control ($undatedResult.UnknownCount -eq 1 -and $undatedResult.AffectedCount -eq 1) 'Missing or sentinel snapshot time without an exported expiry state cannot establish an active secret within policy'
}

$redirectData = @{
    '01' = [pscustomobject]@{ TenantInfo = [pscustomobject]@{ VerifiedDomains = @('customer.invalid') } }
    '02' = [pscustomobject]@{ appRegistrations = @([pscustomobject]@{
        AppObjectId = 'redirect-app'; AppId = 'redirect-client'; DisplayName = 'Redirect application'
        RedirectUris = @('https://signin.customer.invalid/callback','https://customer.invalid.evil.invalid/callback',
            'https://retired-vendor.invalid/callback','http://localhost:1234/callback','http://127.0.0.1:1234',
            'http://[::1]:1234','native-app://callback','invalid uri')
    }) }
}
ConvertTo-WorkloadSnapshot $redirectData
$redirectResult = (Invoke-WorkloadControls $redirectData).Results | Where-Object Id -eq 'WI.APP.4'
Assert-Control ($redirectResult.AffectedCount -eq 4 -and $redirectResult.UnknownCount -eq 4 -and $redirectResult.EvaluatedCount -eq 0) 'Every network redirect and malformed URI requires explicit ownership/configuration review, not a fabricated successful ownership check'
Assert-Control ($redirectResult.AffectedRows[0].TenantDomainMatch -eq 'customer.invalid' -and -not $redirectResult.AffectedRows[1].TenantDomainMatch) 'Verified-domain hints use DNS label boundaries, never substring ownership matching'
Assert-Control (@($redirectResult.AffectedRows | Where-Object OwnershipStatus -like 'Ownership unverified*').Count -eq 3 -and $redirectResult.Outcome -eq 'Review') 'Even a tenant verified-domain match does not establish current domain or endpoint control'
Assert-Control ($redirectResult.ExcludedCount -eq 4 -and $redirectResult.AffectedRows[2].RedirectUri -eq 'https://retired-vendor.invalid/callback') 'Loopback IPv4/IPv6 and native schemes are excluded only from ownership review while exact remote redirect evidence is retained'
$redirectData.'02'.appRegistrations[0].RedirectUris = @()
ConvertTo-WorkloadSnapshot $redirectData
Assert-Control (((Invoke-WorkloadControls $redirectData).Results | Where-Object Id -eq 'WI.APP.4').Outcome -eq 'Not applicable') 'Known empty redirect arrays are not confused with uncollected redirect configuration'
$redirectData.'02'.appRegistrations[0].RedirectUris = $null
ConvertTo-WorkloadSnapshot $redirectData
$missingRedirect = (Invoke-WorkloadControls $redirectData).Results | Where-Object Id -eq 'WI.APP.4'
Assert-Control ($missingRedirect.Outcome -eq 'Not assessed' -and $missingRedirect.UnknownCount -eq 1 -and $missingRedirect.AffectedCount -eq 0) 'Missing redirect inventory stays not assessed without a fabricated configured URI'

$consentRows = @(
    (New-Permission 'User.Read'), (New-Permission 'Mail.Read'),
    (New-Permission 'User.Read'), (New-Permission 'Mail.Read' 'Application'),
    (New-Permission 'Mail.Read'), (New-Permission 'User.Read')
)
$consentRows[2].ConsentScope = 'Principal'; $consentRows[2].ConsentPrincipalId = 'user-subject'
$consentRows[4].GrantState = 'Not granted'
$consentRows[5].ConsentScope = 'Unknown'
$consentData = @{ '05' = [pscustomobject]@{
    NormalizedPermissions = $consentRows
    DelegatedGrantEvidence = [pscustomobject]@{ State = 'Available' }
} }
ConvertTo-WorkloadSnapshot $consentData
$consentResult = (Invoke-WorkloadControls $consentData).Results | Where-Object Id -eq 'WI.CONSENT.1'
Assert-Control ($consentResult.AffectedCount -eq 2 -and $consentResult.Severity -eq 'Info' -and $consentResult.UnknownCount -eq 1) 'Actual AllPrincipals delegated consent has a separate informational finding, including basic scopes, without suppressing dangerous capability warnings'
Assert-Control ($consentRows[0].OrganizationWideConsent -eq $true -and $consentRows[0].RiskSeverity -eq 'Info' -and $consentRows[1].RiskSeverity -eq 'High') 'Consent scope alone never raises User.Read to High or downgrades dangerous Mail.Read'
Assert-Control ($consentRows[2].OrganizationWideConsent -eq $false -and $null -eq $consentRows[3].OrganizationWideConsent -and $consentRows[4].ConsentAudience -eq 'Not granted') 'Specific-user grants, application permissions and configured-only requests cannot pretend to be checked organization-wide delegated consent'
$consentData.'05'.NormalizedPermissions = @()
$consentData.'05'.DelegatedGrantEvidence.State = 'Unavailable'
Assert-Control (((Invoke-WorkloadControls $consentData).Results | Where-Object Id -eq 'WI.CONSENT.1').Outcome -eq 'Not assessed') 'Denied delegated collection cannot establish absence of organization-wide consent'
$consentData.'05'.DelegatedGrantEvidence.State = 'Available'
Assert-Control (((Invoke-WorkloadControls $consentData).Results | Where-Object Id -eq 'WI.CONSENT.1').Outcome -eq 'Not applicable') 'A successfully collected empty grant array is distinct from unavailable consent evidence'
Write-Host "PASS: $checks workload-control checks. Synthetic evidence only." -ForegroundColor Green
