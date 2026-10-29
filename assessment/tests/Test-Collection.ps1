[CmdletBinding()]
param([string]$OutputRoot = (Join-Path $PSScriptRoot '../output/collection-tests'))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1.0
$scripts = (Resolve-Path (Join-Path $PSScriptRoot '../scripts')).Path
$null = New-Item -ItemType Directory -Path $OutputRoot -Force
$OutputRoot = (Resolve-Path $OutputRoot).Path
$checks = 0
function Assert-Collection([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Assert-Rejected([scriptblock]$Action, [string]$Pattern, [string]$Message) {
    $errorMessage = $null
    try { & $Action | Out-Null } catch { $errorMessage = $_.Exception.Message }
    Assert-Collection ($errorMessage -like $Pattern) "$Message (received: $errorMessage)"
}
function Import-CollectorFunctions([string]$File, [string[]]$Names) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $scripts $File), [ref]$tokens, [ref]$errors)
    Assert-Collection ($errors.Count -eq 0) "$File parses"
    foreach ($node in $ast.EndBlock.Statements) {
        if ($node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $Names) {
            Set-Item -Path "Function:script:$($node.Name)" -Value $node.Body.GetScriptBlock()
        }
    }
}
Add-Type @'
public class AssessmentTestHttpException : System.Exception {
    public int ResponseStatusCode { get; set; }
    public object ResponseHeaders { get; set; }
    public object Response { get; set; }
    public AssessmentTestHttpException(int status) : base("Synthetic HTTP " + status) {
        ResponseStatusCode = status;
    }
}
'@
$global:AssessmentTestState = @{
    Graph = [pscustomobject]@{
        TenantId = 'synthetic-tenant'; Account = 'graph-test'; Environment = 'Global'
        AuthType = 'Delegated'; ContextScope = 'Process'
        Scopes = @('Application.Read.All', 'Directory.Read.All', 'AuditLog.Read.All')
    }
    Azure = [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = 'synthetic-tenant' }; Account = [pscustomobject]@{ Id = 'azure-test' } }
    Endpoint = 'https://graph.microsoft.com'
    Calls = [System.Collections.Generic.List[string]]::new()
    Sleeps = [System.Collections.Generic.List[int]]::new()
    Handler = { throw 'No synthetic request handler configured.' }
    SignInsAvailable = $true
    BlockAzure = $false
    AzureAttempts = 0
    Progress = [System.Collections.Generic.List[object]]::new()
}
function global:Write-Progress {
    param($Id, $Activity, $Status, $PercentComplete, [switch]$Completed)
    $global:AssessmentTestState.Progress.Add([pscustomobject]@{ Id = $Id; Activity = $Activity; Completed = $Completed.IsPresent })
}
function global:Get-MgContext { $global:AssessmentTestState.Graph }
function global:Get-AzContext {
    [CmdletBinding()]param()
    if ($global:AssessmentTestState.BlockAzure) {
        $global:AssessmentTestState.AzureAttempts++
        throw 'Azure context access is forbidden in Entra-only tests.'
    }
    $global:AssessmentTestState.Azure
}
function global:Get-MgEnvironment { param($Name); [pscustomobject]@{ GraphEndpoint = $global:AssessmentTestState.Endpoint } }
function global:Invoke-MgGraphRequest {
    [CmdletBinding()]
    param($Method, $Uri, $OutputType)
    if ($Method -ne 'GET') { throw 'Assessment must be read-only.' }
    $global:AssessmentTestState.Calls.Add($Uri)
    & $global:AssessmentTestState.Handler $Uri
}
function global:Start-Sleep { param([int]$Seconds); $global:AssessmentTestState.Sleeps.Add($Seconds) }
function global:Get-MgApplication { throw 'Unexpected SDK application enumeration.' }
function global:Get-MgServicePrincipal { throw 'Unexpected per-resource SDK request.' }
function global:Get-MgApplicationOwner { throw 'Unexpected per-application owner request.' }
function global:Get-MgApplicationFederatedIdentityCredential { throw 'Unexpected per-application FIC request.' }
function global:Get-MgServicePrincipalOwner { throw 'Unexpected per-SP owner request.' }
function global:Get-MgServicePrincipalAppRoleAssignment { throw 'Unexpected per-SP assignment request.' }
function global:Get-MgBetaReportServicePrincipalSignInActivity {
    [CmdletBinding()]param()
    if (-not $global:AssessmentTestState.SignInsAvailable) { throw 'Synthetic 403 Forbidden' }
}
function global:Get-MgUser { throw $global:AssessmentTestState.UserError }
function global:Get-AzSubscription {
    [CmdletBinding()]param($TenantId, $DefaultProfile)
    if ($global:AssessmentTestState.BlockAzure) {
        $global:AssessmentTestState.AzureAttempts++
        throw 'Azure subscription access is forbidden in Entra-only tests.'
    }
    $global:AssessmentTestState.SubscriptionTenant = $TenantId
    $global:AssessmentTestState.SubscriptionProfile = $DefaultProfile
}
Import-Module (Join-Path $scripts 'Assessment.Common.psm1')

function Reset-Transport([scriptblock]$Handler) {
    Stop-AssessmentCollection
    $global:AssessmentTestState.Calls.Clear()
    $global:AssessmentTestState.Sleeps.Clear()
    $global:AssessmentTestState.Progress.Clear()
    $global:AssessmentTestState.Handler = $Handler
}
try {
    Assert-AssessmentContexts -RequireAzure
    Assert-Collection $true 'Different accounts in the same tenant are supported'
    $global:AssessmentTestState.Azure.Tenant.Id = 'other-tenant'
    Assert-Rejected { Start-AssessmentCollection } '*Tenant mismatch*' 'Cross-tenant contexts fail before collection'
    Assert-Collection ($global:AssessmentTestState.Calls.Count -eq 0) 'Preflight makes no directory requests'
    $global:AssessmentTestState.Azure.Tenant.Id = 'synthetic-tenant'
    $global:AssessmentTestState.Graph.ContextScope = 'CurrentUser'
    Start-AssessmentCollection
    Assert-Collection $true 'Default delegated Graph caching is accepted without changing tenant validation'
    Stop-AssessmentCollection
    $global:AssessmentTestState.Graph.AuthType = 'AppOnly'
    Assert-AssessmentContexts -RequireAzure
    Assert-Collection $true 'Application authentication remains supported'
    $global:AssessmentTestState.Graph.AuthType = 'Delegated'
    $global:AssessmentTestState.Graph.ContextScope = 'Process'
    $savedAzure = $global:AssessmentTestState.Azure
    $global:AssessmentTestState.Azure = $null
    Assert-AssessmentContexts
    Assert-Rejected { Assert-AssessmentContexts -RequireAzure } '*No Azure context*' 'Azure is required only for Azure collectors'
    $global:AssessmentTestState.Azure = $savedAzure
    $tokens = $null
    $errors = $null
    $tenantAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $scripts '01-tenant-context.ps1'), [ref]$tokens, [ref]$errors)
    $subscriptionRead = $tenantAst.FindAll({
        param($Node)
        $Node -is [System.Management.Automation.Language.CommandAst] -and $Node.GetCommandName() -eq 'Get-AzSubscription'
    }, $true)
    & ([scriptblock]::Create($subscriptionRead[0].Extent.Text))
    Assert-Collection ($global:AssessmentTestState.SubscriptionTenant -eq 'synthetic-tenant') 'Subscription discovery specifies the assessment tenant'
    Assert-Collection ($global:AssessmentTestState.SubscriptionProfile -eq $savedAzure) 'Subscription discovery specifies the current Azure profile'

    foreach ($collector in @('01-tenant-context', '02-inventory', '03-credential-hygiene', '04-federated-credentials', '05-permission-surface', '06-stale-and-orphaned', '08-ca-for-workload-identities')) {
        $collectorAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $scripts "$collector.ps1"), [ref]$tokens, [ref]$errors)
        $modules = & {
            $EntraOnly = $true
            foreach ($statement in $collectorAst.EndBlock.Statements) {
                if (($statement -is [System.Management.Automation.Language.AssignmentStatementAst] -and $statement.Left.Extent.Text -eq '$requiredModules') -or
                    ($statement -is [System.Management.Automation.Language.IfStatementAst] -and $statement.Extent.Text.StartsWith('if ($EntraOnly)') -and $statement.Extent.Text.Contains('$requiredModules'))) {
                    . ([scriptblock]::Create($statement.Extent.Text))
                }
            }
            $requiredModules
        }
        Assert-Collection ($modules.Count -gt 0 -and @($modules | Where-Object { $_ -like 'Az.*' }).Count -eq 0) "$collector has no Az prerequisite in Entra-only mode"
    }

    Reset-Transport { [pscustomobject]@{ value = @() } }
    Assert-Collection (@(Get-AssessmentDirectoryData applications owners).Count -eq 0) 'An empty directory remains an empty array'
    Reset-Transport { [pscustomobject]@{ value = @([pscustomobject]@{ id = 'one'; owners = @() }) } }
    Start-AssessmentCollection
    $one = @(Get-AssessmentDirectoryData applications owners)
    $null = @(Get-AssessmentDirectoryData applications owners)
    Assert-Collection ($one.Count -eq 1 -and $one[0].owners.Count -eq 0) 'A single object with zero owners is retained'
    Assert-Collection ($global:AssessmentTestState.Calls.Count -eq 1) 'A run reuses complete relationship snapshots'
    $global:AssessmentTestState.Graph.TenantId = 'changed-tenant'
    Assert-Rejected { Get-AssessmentDirectoryData applications owners } '*tenant changed*' 'A tenant change cannot reuse cached data'
    $global:AssessmentTestState.Graph.TenantId = 'synthetic-tenant'
    Stop-AssessmentCollection
    $null = @(Get-AssessmentDirectoryData applications owners)
    $null = @(Get-AssessmentDirectoryData applications owners)
    Assert-Collection ($global:AssessmentTestState.Calls.Count -eq 3) 'No snapshot survives the run or caches standalone calls'

    Reset-Transport {
        param($Uri)
        if ($Uri -like '*/owners*') {
            if ($Uri -like '*part=2') {
                return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'owner-c' }) }
            }
            return [pscustomobject]@{
                value = @([pscustomobject]@{ id = 'owner-b' })
                '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/applications/one/owners?part=2'
            }
        }
        if ($Uri -like '*parent=2') { return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'two'; owners = @() }) } }
        [pscustomobject]@{
            value = @([pscustomobject]@{
                id = 'one'; owners = @([pscustomobject]@{ id = 'owner-a' })
                'owners@odata.nextLink' = 'https://graph.microsoft.com/v1.0/applications/one/owners'
            })
            '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/applications?parent=2'
        }
    }
    $pageMessages = @()
    $paged = @(Get-AssessmentDirectoryData applications owners -InformationVariable pageMessages)
    Assert-Collection ($paged.Count -eq 2 -and $paged[0].owners.Count -eq 3) 'Parent and multi-page expanded relationships are followed'
    Assert-Collection ($global:AssessmentTestState.Calls.Count -eq 4) 'Expanded continuation requests are counted once'
    Assert-Collection ($global:AssessmentTestState.Progress.Count -eq 3 -and $global:AssessmentTestState.Progress[2].Completed -and $pageMessages.Count -eq 1) 'Directory pages update progress and emit just one final console line'
    Reset-Transport {
        param($Uri)
        if ($Uri -like '*/one/owners') { return [pscustomobject]@{ value = @(1..23 | ForEach-Object { [pscustomobject]@{ id = "owner-$_" } }) } }
        [pscustomobject]@{ value = @([pscustomobject]@{ id = 'one'; owners = @(1..20 | ForEach-Object { [pscustomobject]@{ id = "owner-$_" } }) }) }
    }
    $bounded = @(Get-AssessmentDirectoryData applications owners)
    Assert-Collection ($bounded[0].owners.Count -eq 23 -and $global:AssessmentTestState.Calls.Count -eq 2) 'A full expansion is reread rather than silently truncated'
    Reset-Transport { [pscustomobject]@{ value = @([pscustomobject]@{ id = 'one' }) } }
    Assert-Rejected { Get-AssessmentDirectoryData applications owners } '*completeness is unknown*' 'A missing expansion is not reported as zero'
    Assert-Collection ($global:AssessmentTestState.Progress[-1].Completed) 'A failed directory read clears its progress display'
    Reset-Transport { [pscustomobject]@{} }
    Assert-Rejected { Get-AssessmentDirectoryData applications owners } '*value array*' 'Malformed directory responses fail visibly'
    Reset-Transport { param($Uri); [pscustomobject]@{ value = @(); '@odata.nextLink' = $Uri } }
    Assert-Rejected { Get-AssessmentDirectoryData applications owners } '*repeated directory pagination*' 'Repeated parent links are rejected'
    Reset-Transport { [pscustomobject]@{ value = @(); '@odata.nextLink' = 'https://example.invalid/v1.0/applications' } }
    Assert-Rejected { Get-AssessmentDirectoryData applications owners } '*Unexpected Graph pagination endpoint*' 'Continuation requests cannot leave the Graph endpoint'
    Assert-Collection ($global:AssessmentTestState.Calls.Count -eq 1) 'An invalid continuation is rejected before a request'
    Reset-Transport {
        [pscustomobject]@{
            value = @([pscustomobject]@{ id = 'one'; owners = @(); 'owners@odata.nextLink' = 'https://graph.microsoft.com/v1.0/applications/one/owners' })
        }
    }
    $global:AssessmentTestState.Handler = {
        param($Uri)
        if ($Uri -like '*/owners') { return [pscustomobject]@{ value = @(); '@odata.nextLink' = $Uri } }
        [pscustomobject]@{ value = @([pscustomobject]@{ id = 'one'; owners = @(); 'owners@odata.nextLink' = 'https://graph.microsoft.com/v1.0/applications/one/owners' }) }
    }
    Assert-Rejected { Get-AssessmentDirectoryData applications owners } '*repeated pagination*' 'Repeated relationship links are rejected'
    $global:AssessmentTestState.Endpoint = 'https://graph.microsoft.us'
    Reset-Transport { [pscustomobject]@{ value = @() } }
    $null = @(Get-AssessmentDirectoryData applications owners)
    Assert-Collection ($global:AssessmentTestState.Calls[0].StartsWith('https://graph.microsoft.us/v1.0/')) 'The authenticated Graph environment determines the endpoint'
    $global:AssessmentTestState.Endpoint = 'https://graph.microsoft.com'

    foreach ($headerKind in @('dictionary', 'http-headers', 'date', 'missing')) {
        Reset-Transport {
            if ($global:AssessmentTestState.Calls.Count -eq 1) { throw $global:AssessmentTestState.HttpError }
            [pscustomobject]@{ value = @() }
        }
        $httpError = [AssessmentTestHttpException]::new(429)
        switch ($headerKind) {
            dictionary {
                $headers = [System.Collections.Generic.Dictionary[string,object]]::new()
                $headers['Retry-After'] = @('7')
                $httpError.ResponseHeaders = $headers
            }
            http-headers {
                $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::TooManyRequests)
                $null = $response.Headers.TryAddWithoutValidation('Retry-After', '7')
                $httpError.Response = $response
            }
            date { $httpError.ResponseHeaders = @{ 'Retry-After' = [DateTimeOffset]::UtcNow.AddSeconds(30).ToString('r') } }
        }
        $global:AssessmentTestState.HttpError = $httpError
        $null = @(Get-AssessmentDirectoryData applications owners)
        Assert-Collection ($global:AssessmentTestState.Calls.Count -eq 2) "Transient failures retry the same page: $headerKind"
        $delay = $global:AssessmentTestState.Sleeps[0]
        $valid = switch ($headerKind) { date { $delay -ge 28 -and $delay -le 30 }; missing { $delay -eq 2 }; default { $delay -eq 7 } }
        Assert-Collection $valid "Retry-After/backoff is honored: $headerKind"
    }
    Reset-Transport { throw [AssessmentTestHttpException]::new(503) }
    Assert-Rejected { Get-AssessmentDirectoryData applications owners } '*Synthetic HTTP 503*' 'Retry exhaustion remains a failure'
    Assert-Collection ($global:AssessmentTestState.Calls.Count -eq 4 -and $global:AssessmentTestState.Sleeps.Count -eq 3) 'Retries are bounded'
    Reset-Transport { throw [AssessmentTestHttpException]::new(403) }
    Assert-Rejected { Get-AssessmentDirectoryData applications owners } '*Synthetic HTTP 403*' 'Permission failures do not become empty data'
    Assert-Collection ($global:AssessmentTestState.Calls.Count -eq 1) 'Non-transient failures are not retried'

    Import-CollectorFunctions '02-inventory.ps1' @('Get-AppRegistrations', 'Get-ServicePrincipals')
    $global:AssessmentTestState.Application = [pscustomobject]@{
        id = 'app-one'; appId = 'client-one'; displayName = 'Synthetic app'; signInAudience = 'AzureADMyOrg'
        createdDateTime = '2020-01-01T00:00:00Z'; tags = @('synthetic'); requiredResourceAccess = @()
        passwordCredentials = @([pscustomobject]@{ endDateTime = '2000-01-01T00:00:00Z' }, [pscustomobject]@{ endDateTime = '2099-01-01T00:00:00Z' })
        keyCredentials = @(); web = [pscustomobject]@{ redirectUris = @() }
        spa = [pscustomobject]@{ redirectUris = @() }; publicClient = [pscustomobject]@{ redirectUris = @() }
        api = [pscustomobject]@{ oauth2PermissionScopes = @() }
        owners = @([pscustomobject]@{ id = 'owner-one'; '@odata.type' = '#microsoft.graph.servicePrincipal' })
        federatedIdentityCredentials = @([pscustomobject]@{
            id = 'fic-one'; name = 'synthetic'; issuer = 'https://token.actions.githubusercontent.com'
            subject = 'repo:synthetic/project:ref:refs/heads/main'; audiences = @('api://AzureADTokenExchange'); description = 'Synthetic FIC'
        })
    }
    $global:AssessmentTestState.Principals = @(
        [pscustomobject]@{
            id = 'graph-sp'; appId = '00000003-0000-0000-c000-000000000000'; displayName = 'Microsoft Graph'
            servicePrincipalType = 'Application'; appOwnerOrganizationId = 'external-tenant'; tags = @(); accountEnabled = $true
            appRoles = @([pscustomobject]@{ id = 'role-one'; value = 'Directory.ReadWrite.All'; displayName = 'Directory read/write' })
            oauth2PermissionScopes = @(); owners = @(); appRoleAssignments = @()
        },
        [pscustomobject]@{
            id = 'sp-one'; appId = 'client-one'; displayName = 'Synthetic app'; servicePrincipalType = 'Application'
            appOwnerOrganizationId = 'synthetic-tenant'; tags = @(); accountEnabled = $true
            appRoles = @(); oauth2PermissionScopes = @()
            owners = @([pscustomobject]@{ id = 'owner-one'; '@odata.type' = '#microsoft.graph.servicePrincipal' })
            appRoleAssignments = @([pscustomobject]@{ id = 'grant-one'; resourceId = 'graph-sp'; appRoleId = 'role-one' })
        }
    )
    Reset-Transport {
        param($Uri)
        if ($Uri -like '*/reports/servicePrincipalSignInActivities*') { throw 'Synthetic 403 Forbidden' }
        if ($Uri -like '*/applications?*') { return [pscustomobject]@{ value = @($global:AssessmentTestState.Application.PSObject.Copy()) } }
        [pscustomobject]@{ value = $global:AssessmentTestState.Principals }
    }
    Start-AssessmentCollection
    $apps = @(Get-AppRegistrations -TenantId 'synthetic-tenant')
    $sps = @(Get-ServicePrincipals -TenantId 'synthetic-tenant' -SignInActivityMap @{})
    Assert-Collection ($apps.Count -eq 1 -and $apps[0].OwnerCount -eq 1 -and $apps[0].FederatedCredentialCount -eq 1) 'Inventory counts use complete expanded relationships'
    Assert-Collection ($apps[0].ActivePasswordCredentialCount -eq 1 -and $apps[0].AgeInDays -gt 0) 'REST date strings retain correct credential activity and age'
    Assert-Collection ($sps.Count -eq 2 -and $sps[1].OwnerCount -eq 1 -and $sps[1].AppRoleAssignmentCount -eq 1) 'SP inventory preserves IDs and counts without per-object requests'
    Assert-Collection ($global:AssessmentTestState.Calls.Count -eq 4) 'Inventory needs four paged directory passes'
    Import-CollectorFunctions '04-federated-credentials.ps1' @('Get-AppRegFICs', 'Get-IssuerCategory', 'Get-SubjectClassification')
    $fics = @(Get-AppRegFICs)
    Assert-Collection ($fics.Count -eq 1 -and $fics[0].TargetId -eq 'app-one') 'Federation reuses the inventory FIC snapshot'
    Import-CollectorFunctions '05-permission-surface.ps1' @('Get-GraphPermissions', 'Get-NormalizedPermissions')
    Import-Module (Join-Path $PSScriptRoot '../scripts/Assessment.Controls.psm1') -Force
    $grants = @(Get-GraphPermissions)
    Assert-Collection ($grants.Count -eq 1 -and $grants[0].PermissionValue -eq 'Directory.ReadWrite.All' -and $grants[0].Tier -eq 'PRIVILEGED' -and $grants[0].ReviewRequired) 'Permissions resolve resource roles and flag high-privilege access for review'
    Import-CollectorFunctions '06-stale-and-orphaned.ps1' @('Assert-GraphContext', 'Invoke-WithRetry', 'Test-UserExists', 'Invoke-StaleAndOrphaned')
    $global:AssessmentTestState.SignInsAvailable = $false
    Invoke-StaleAndOrphaned -OutputDir $OutputRoot
    $hygiene = Get-Content -Raw (Join-Path $OutputRoot '06-stale-and-orphaned.json') | ConvertFrom-Json
    Assert-Collection ($hygiene.ServicePrincipals.Count -eq 1 -and $hygiene.ServicePrincipals[0].OwnerCategory -eq 'singleOwner') 'Hygiene recognizes raw Graph owner types'
    Assert-Collection ($null -eq $hygiene.ServicePrincipals[0].Stale90Days -and $null -eq $hygiene.ServicePrincipals[0].NeverSignedIn) 'Unavailable sign-ins do not fabricate stale or never-used findings'
    Assert-Collection ($null -eq $hygiene.Aggregations.Stale90Days -and $null -eq $hygiene.Aggregations.NeverSignedIn) 'Unavailable sign-in aggregates remain unknown'
    Assert-Collection ($global:AssessmentTestState.Calls.Count -eq 5) 'Federation, permissions and hygiene reuse inventory and add one shared activity request'
    $global:AssessmentTestState.Principals[1].owners[0].'@odata.type' = '#microsoft.graph.user'
    $global:AssessmentTestState.UserError = 'Synthetic user lookup failure'
    Invoke-StaleAndOrphaned -OutputDir $OutputRoot
    $hygiene = Get-Content -Raw (Join-Path $OutputRoot '06-stale-and-orphaned.json') | ConvertFrom-Json
    Assert-Collection ($hygiene.ServicePrincipals[0].OwnerCategory -eq 'unknown') 'User lookup failures are not reported as confirmed ownership'
    $global:AssessmentTestState.UserError = 'Synthetic 404 Request_ResourceNotFound'
    Invoke-StaleAndOrphaned -OutputDir $OutputRoot
    $hygiene = Get-Content -Raw (Join-Path $OutputRoot '06-stale-and-orphaned.json') | ConvertFrom-Json
    Assert-Collection ($hygiene.ServicePrincipals[0].OwnerCategory -eq 'orphanedOwner') 'A confirmed missing user is still classified as orphaned'

    $normalPrincipals = $global:AssessmentTestState.Principals
    $permissionHandler = $global:AssessmentTestState.Handler
    $nullApp = $normalPrincipals[1].PSObject.Copy()
    $nullApp.id = 'legacy-sp'
    $nullApp.appId = $null
    $nullApp.servicePrincipalType = 'Legacy'
    $nullApp.appRoleAssignments = @()
    $partialPrincipal = $normalPrincipals[1].PSObject.Copy()
    $partialPrincipal.appRoleAssignments = @($partialPrincipal.appRoleAssignments) + @($null, [pscustomobject]@{
        id = 'unresolved-grant'; resourceId = $null; appRoleId = 'missing-role'
    })
    $global:AssessmentTestState.Principals = @($normalPrincipals[0], $partialPrincipal, $nullApp)
    Reset-Transport $permissionHandler
    Start-AssessmentCollection
    $nullIdInventory = @(Get-ServicePrincipals -TenantId 'synthetic-tenant' -SignInActivityMap @{})
    Assert-Collection ($nullIdInventory.Count -eq 3 -and $nullIdInventory[2].SpObjectId -eq 'legacy-sp' -and $null -eq $nullIdInventory[2].AppId -and $null -eq $nullIdInventory[2].NeverSignedIn) 'A service principal with no app ID remains in inventory with unknown sign-in activity'
    $permissionWarnings = @()
    $mixedGrants = @(Get-GraphPermissions -WarningVariable permissionWarnings -WarningAction SilentlyContinue)
    Assert-Collection ($mixedGrants.Count -eq 2 -and @($mixedGrants | Where-Object Tier -eq 'PRIVILEGED').Count -eq 1) 'Null assignment placeholders are not phantom grants and valid grants survive'
    $unknownGrant = $mixedGrants | Where-Object AssignmentId -eq 'unresolved-grant'
    Assert-Collection ($unknownGrant.Tier -eq 'UNKNOWN' -and $unknownGrant.ResolutionStatus -eq 'Unresolved' -and $unknownGrant.AppRoleId -eq 'missing-role' -and $unknownGrant.ReviewRequired -and $permissionWarnings.Count -eq 1) 'Missing resource IDs remain explicit unresolved review items without crashing or claiming standard privilege'
    $readResource = $normalPrincipals[0].PSObject.Copy()
    $readResource.appRoles = @([pscustomobject]@{ id = 'read-role'; value = 'Directory.Read.All'; displayName = 'Directory read' })
    $readPrincipal = $normalPrincipals[1].PSObject.Copy()
    $readPrincipal.appRoleAssignments = @([pscustomobject]@{ id = 'read-grant'; resourceId = 'graph-sp'; appRoleId = 'read-role' })
    $global:AssessmentTestState.Principals = @($readResource, $readPrincipal)
    Reset-Transport $permissionHandler
    $readGrants = @(Get-GraphPermissions)
    Assert-Collection ($readGrants.Count -eq 1 -and $readGrants[0].Tier -eq 'INFORMATIONAL' -and $readGrants[0].RiskSeverity -eq 'Info' -and $readGrants[0].RiskRuleId -eq 'AZTIER.2' -and $readGrants[0].ReviewRequired) 'Collected Graph application inventory reads use sourced AZTier 2 / Info rather than a blanket High warning'
    $global:AssessmentTestState.Principals = $normalPrincipals
    Reset-Transport $permissionHandler

    $EntraOnly = $true
    $global:AssessmentTestState.BlockAzure = $true
    Stop-AssessmentCollection
    Start-AssessmentCollection -IncludeAzure:$false
    $scopeOutput = Join-Path $OutputRoot 'entra-only'
    Import-CollectorFunctions '02-inventory.ps1' @('Assert-Contexts', 'Get-SignInActivityMap', 'Invoke-Inventory')
    function Get-ManagedIdentities { if ($EntraOnly) { throw 'Azure managed-identity collection must not run.' } }
    Invoke-Inventory -OutputDir $scopeOutput
    $scopeInventory = Get-Content -Raw (Join-Path $scopeOutput '02-inventory.json') | ConvertFrom-Json
    Assert-Collection ($scopeInventory.AzureCollected -eq $false -and $null -eq $scopeInventory.managedIdentities -and $scopeInventory.appRegistrations.Count -eq 1 -and $scopeInventory.servicePrincipals.Count -eq 2) 'Entra-only inventory retains directory records and marks Azure resource data uncollected'
    Assert-Collection ((Import-Csv (Join-Path $scopeOutput '02-inventory-managed-identities.csv')).Note -like '*Not collected*') 'Excluded managed-identity CSV is not a false zero-result inventory'
    Import-CollectorFunctions '04-federated-credentials.ps1' @('Assert-Contexts', 'Invoke-FederatedCredentials')
    function Get-UserAssignedMIFICs { if ($EntraOnly) { throw 'Azure managed-identity federation must not run.' } }
    Invoke-FederatedCredentials -OutputDir $scopeOutput
    $scopeFederation = Get-Content -Raw (Join-Path $scopeOutput '04-federated-credentials.json') | ConvertFrom-Json
    Assert-Collection ($scopeFederation.AzureCollected -eq $false -and $null -eq $scopeFederation.FICsOnUserAssignedMIs -and $scopeFederation.FICsOnAppRegs -eq 1) 'Entra-only federation collects app FICs without querying managed identities'
    Import-CollectorFunctions '05-permission-surface.ps1' @('Assert-Contexts', 'Invoke-PermissionSurface')
    function Get-AzureRbacAssignments { if ($EntraOnly) { throw 'Azure RBAC collection must not run.' } }
    Invoke-PermissionSurface -OutputDir $scopeOutput
    $scopePermissions = Get-Content -Raw (Join-Path $scopeOutput '05-permission-surface.json') | ConvertFrom-Json
    Assert-Collection ($scopePermissions.AzureCollected -eq $false -and $null -eq $scopePermissions.AzureRbac -and $scopePermissions.GraphPermissions.Count -eq 1) 'Entra-only permissions retain Graph grants without querying Azure RBAC'
    Assert-Collection ((Import-Csv (Join-Path $scopeOutput '05-permission-surface-azure-rbac.csv')).Note -like '*Not collected*') 'Excluded RBAC CSV is labelled not collected'
    $subscriptionGuard = $tenantAst.FindAll({
        param($Node)
        $Node -is [System.Management.Automation.Language.IfStatementAst] -and
            $Node.Extent.Text.StartsWith('if ($EntraOnly)') -and $Node.Extent.Text.Contains('Get-AzSubscription')
    }, $true)
    $subscriptions = @()
    & ([scriptblock]::Create($subscriptionGuard[0].Extent.Text))
    Assert-Collection ($global:AssessmentTestState.AzureAttempts -eq 0) 'All mixed collectors avoid Azure context and subscription access in Entra-only mode'
    $global:AssessmentTestState.BlockAzure = $false
    $EntraOnly = $false
    $subscriptionExport = $tenantAst.FindAll({
        param($Node)
        $Node -is [System.Management.Automation.Language.HashtableAst] -and
            @($Node.KeyValuePairs | Where-Object { $_.Item1.Extent.Text -eq 'AzureSubscriptions' }).Count -gt 0
    }, $true)
    $subscriptionValue = ($subscriptionExport[0].KeyValuePairs | Where-Object { $_.Item1.Extent.Text -eq 'AzureSubscriptions' }).Item2
    $emptySubscriptions = & ([scriptblock]::Create($subscriptionValue.Extent.Text))
    Assert-Collection ($emptySubscriptions -is [array] -and $emptySubscriptions.Count -eq 0) 'An empty full-scope subscription export remains an array'
    $syntheticHandler = $global:AssessmentTestState.Handler
    Reset-Transport {
        param($Uri)
        if ($Uri -like '*/applications?*') { return [pscustomobject]@{ value = @() } }
        [pscustomobject]@{ value = @($global:AssessmentTestState.Principals[0]) }
    }
    foreach ($EntraOnly in @($true, $false)) {
        Start-AssessmentCollection -IncludeAzure:(-not $EntraOnly)
        $emptyOutput = Join-Path $OutputRoot "empty-$EntraOnly"
        Invoke-Inventory -OutputDir $emptyOutput
        Invoke-FederatedCredentials -OutputDir $emptyOutput
        Invoke-PermissionSurface -OutputDir $emptyOutput
        $emptyInventory = Get-Content -Raw (Join-Path $emptyOutput '02-inventory.json') | ConvertFrom-Json
        $emptyFederation = Get-Content -Raw (Join-Path $emptyOutput '04-federated-credentials.json') | ConvertFrom-Json
        $emptyPermissions = Get-Content -Raw (Join-Path $emptyOutput '05-permission-surface.json') | ConvertFrom-Json
        Assert-Collection ($emptyInventory.appRegistrations -is [array] -and $emptyInventory.appRegistrations.Count -eq 0 -and $emptyFederation.FederatedCredentials -is [array] -and $emptyFederation.TotalFICs -eq 0 -and $emptyPermissions.GraphPermissions -is [array]) "Empty Graph exports preserve collection shapes (EntraOnly=$EntraOnly)"
        if ($EntraOnly) {
            Assert-Collection ($null -eq $emptyInventory.managedIdentities -and $null -eq $emptyPermissions.AzureRbac) 'Empty Entra assessment still distinguishes excluded Azure data'
        } else {
            Assert-Collection ($emptyInventory.managedIdentities -is [array] -and $emptyInventory.managedIdentities.Count -eq 0 -and $emptyPermissions.AzureRbac -is [array] -and $emptyPermissions.AzureRbac.Count -eq 0) 'Empty full-scope Azure exports remain arrays rather than null'
        }
    }
    Reset-Transport $syntheticHandler
    Stop-AssessmentCollection
    Start-AssessmentCollection
    $null = @(Get-AssessmentDirectoryData applications owners)

    Import-CollectorFunctions 'run-all.ps1' @('Invoke-AssessmentScript', 'Set-AzSubscriptionScope')
    $Skip = @()
    $OutputDir = $OutputRoot
    $successScript = Join-Path $OutputRoot 'success.ps1'
    $failureScript = Join-Path $OutputRoot 'failure.ps1'
    $throwScript = Join-Path $OutputRoot 'throw.ps1'
    $argumentScript = Join-Path $OutputRoot 'arguments.ps1'
    '[CmdletBinding()]param($OutputDir); $null = 1' | Set-Content $successScript
    '[CmdletBinding()]param($OutputDir); exit 2' | Set-Content $failureScript
    '[CmdletBinding()]param($OutputDir); throw "Synthetic collector failure"' | Set-Content $throwScript
    '[CmdletBinding()]param($OutputDir, $InventoryOutputDir); if ($OutputDir -ne $InventoryOutputDir) { throw "Incorrect argument binding" }' | Set-Content $argumentScript
    $LASTEXITCODE = 2
    $result = Invoke-AssessmentScript '01' 'success' $successScript
    Assert-Collection ($result.Status -eq 'OK' -and $result.ExitCode -eq 0) 'A successful collector does not inherit a stale exit code'
    $result = Invoke-AssessmentScript '02' 'failure' $failureScript
    Assert-Collection ($result.Status -eq 'Failed' -and $result.ExitCode -eq 2) 'An explicit collector failure is preserved'
    $result = Invoke-AssessmentScript '03' 'throw' $throwScript
    Assert-Collection ($result.Status -eq 'Failed') 'A terminating error remains a failure'
    Assert-Collection ($result.ErrorMessage -eq 'Synthetic collector failure' -and $result.ErrorLocation -like '*throw.ps1*') 'Collector failures preserve the error and source stack in the run result'
    $result = Invoke-AssessmentScript '08' 'arguments' $argumentScript @{ InventoryOutputDir = $OutputDir }
    Assert-Collection ($result.Status -eq 'OK') 'Collector parameters are named hashtable arguments'
    $importScript = Join-Path $OutputRoot 'import-common.ps1'
    @'
[CmdletBinding()]param($OutputDir, $ModulePath)
Import-Module $ModulePath
$null = @(Get-AssessmentDirectoryData applications owners)
'@ | Set-Content $importScript
    $requestCount = $global:AssessmentTestState.Calls.Count
    $result = Invoke-AssessmentScript '02' 'import-common' $importScript @{ ModulePath = (Join-Path $scripts 'Assessment.Common.psm1') }
    Assert-Collection ($result.Status -eq 'OK' -and $global:AssessmentTestState.Calls.Count -eq $requestCount) 'Child script module imports preserve the run cache'
    $env:ASSESSMENT_SUBSCRIPTION_IDS = 'previous-scope'
    Set-AzSubscriptionScope -SubscriptionIds @()
    Assert-Collection (-not $env:ASSESSMENT_SUBSCRIPTION_IDS) 'An unscoped run cannot inherit old subscription IDs'
    $env:ASSESSMENT_SUBSCRIPTION_IDS = 'previous-scope'
    $entryOutput = Join-Path $OutputRoot 'entry-point'
    & (Join-Path $scripts 'run-all.ps1') -OutputDir $entryOutput -Skip @('01', '02', '03', '04', '05', '06', '07', '08') -UseExistingContext -NoOpen
    Assert-Collection ($env:ASSESSMENT_SUBSCRIPTION_IDS -eq 'previous-scope') 'The real orchestrator entry point restores the prior environment scope'
    $requestCount = $global:AssessmentTestState.Calls.Count
    $null = @(Get-AssessmentDirectoryData applications owners)
    Assert-Collection ($global:AssessmentTestState.Calls.Count -eq $requestCount + 1) 'The real orchestrator clears the directory cache in finally'
    Assert-Collection (Test-Path (Join-Path $entryOutput 'run-summary.json')) 'The orchestrator persists a run summary'
    Start-AssessmentCollection
    $null = @(Get-AssessmentDirectoryData applications owners)
    $global:AssessmentTestState.Azure.Tenant.Id = 'other-tenant'
    $rejectedOutput = Join-Path $OutputRoot 'preflight-rejected'
    Assert-Rejected {
        & (Join-Path $scripts 'run-all.ps1') -OutputDir $rejectedOutput -Skip @('01', '02', '03', '04', '05', '06', '07', '08') -UseExistingContext -NoOpen
    } '*Tenant mismatch*' 'The real entry point fails on mismatched tenants'
    $global:AssessmentTestState.Azure.Tenant.Id = 'synthetic-tenant'
    Assert-Collection (@(Get-ChildItem -LiteralPath $rejectedOutput -File | Where-Object Name -ne 'transcript.txt').Count -eq 0) 'Failed preflight produces only its diagnostic transcript, not assessment data'
    $requestCount = $global:AssessmentTestState.Calls.Count
    $null = @(Get-AssessmentDirectoryData applications owners)
    Assert-Collection ($global:AssessmentTestState.Calls.Count -eq $requestCount + 1 -and $env:ASSESSMENT_SUBSCRIPTION_IDS -eq 'previous-scope') 'Failure cleanup clears the cache and preserves environment scope'

    Reset-Transport {
        param($Uri)
        $start = if ($Uri -match '[?&]offset=(\d+)') { [int]$Matches[1] } else { 0 }
        $relationship = if ($Uri -like '*expand=owners*') { 'owners' } else { 'appRoleAssignments' }
        $values = for ($index = $start; $index -lt [Math]::Min($start + 100, 53257); $index++) {
            [pscustomobject]@{ id = "sp-$index"; $relationship = @() }
        }
        $page = [pscustomobject]@{ value = @($values) }
        if ($start + 100 -lt 53257) {
            $page | Add-Member NoteProperty '@odata.nextLink' "https://graph.microsoft.com/v1.0/servicePrincipals?`$expand=$relationship&offset=$($start + 100)"
        }
        $page
    }
    Start-AssessmentCollection
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $largeAssignments = @(Get-AssessmentDirectoryData servicePrincipals appRoleAssignments 6>$null)
    $largeOwners = @(Get-AssessmentDirectoryData servicePrincipals owners 6>$null)
    $null = @(Get-AssessmentDirectoryData servicePrincipals appRoleAssignments 6>$null)
    $null = @(Get-AssessmentDirectoryData servicePrincipals owners 6>$null)
    Assert-Collection ($largeAssignments.Count -eq 53257 -and $largeOwners.Count -eq 53257) 'All 53,257 identities survive paging'
    Assert-Collection ($global:AssessmentTestState.Calls.Count -eq 1066) '53,257 SPs need 1,066 directory-page requests across both relationships, including reuse'
    Write-Host ("Scale fixture: 53,257 SPs; 1,066 mocked requests; {0:N1}s local processing (not a network benchmark)." -f $timer.Elapsed.TotalSeconds)

    Import-CollectorFunctions '03-credential-hygiene.ps1' @('Merge-CredentialActivity', 'Invoke-CredentialHygiene', 'Assert-GraphContext', 'Get-Median', 'Invoke-WithRetry')
    $now = [datetimeoffset]'2026-10-23T05:00:00Z'
    $activityRows = @(
        [pscustomobject]@{ id = 'older'; appId = 'client-a'; appObjectId = 'app-a'; keyId = 'shared'; credentialOrigin = 'application'; keyType = 'clientSecret'; resourceId = 'resource-a'; signInActivity = @{ lastSignInDateTime = '2026-01-01T00:00:00Z' } },
        [pscustomobject]@{ id = 'newer'; appId = 'client-a'; appObjectId = 'APP-A'; keyId = 'SHARED'; credentialOrigin = 'application'; keyType = 'clientSecret'; resourceId = 'resource-b'; signInActivity = @{ lastSignInDateTime = '2026-10-22T05:00:00Z' } },
        [pscustomobject]@{ id = 'certificate'; appId = 'client-a'; appObjectId = 'app-a'; keyId = 'shared'; credentialOrigin = 'application'; keyType = 'certificate'; resourceId = 'resource-a'; signInActivity = @{ lastSignInDateTime = '2026-07-25T05:00:00Z' } },
        [pscustomobject]@{ id = 'wrong-origin'; appId = 'client-a'; appObjectId = 'app-a'; keyId = 'shared'; credentialOrigin = 'servicePrincipal'; keyType = 'certificate'; signInActivity = @{ lastSignInDateTime = '2026-10-22T05:00:00Z' } },
        [pscustomobject]@{ id = 'wrong-client'; appId = 'other-client'; appObjectId = 'app-b'; keyId = 'shared'; credentialOrigin = 'application'; keyType = 'clientSecret'; signInActivity = @{ lastSignInDateTime = '2026-10-22T05:00:00Z' } },
        [pscustomobject]@{ id = 'no-date'; appId = 'client-a'; appObjectId = 'app-a'; keyId = 'unknown'; credentialOrigin = 'application'; keyType = 'clientSecret'; signInActivity = @{ lastSignInDateTime = $null } },
        [pscustomobject]@{ id = 'future'; appId = 'client-a'; appObjectId = 'app-a'; keyId = 'future'; credentialOrigin = 'application'; keyType = 'clientSecret'; signInActivity = @{ lastSignInDateTime = '2099-01-01T00:00:00Z' } }
    )
    $global:AssessmentTestState.CredentialActivityRows = $activityRows
    Reset-Transport {
        param($Uri)
        if ($Uri -notlike 'https://graph.microsoft.com/beta/reports/appCredentialSignInActivities*') { throw "Unexpected preview request: $Uri" }
        if ($Uri -like '*page=2') { return [pscustomobject]@{ value = @($global:AssessmentTestState.CredentialActivityRows[1..6]) } }
        [pscustomobject]@{ value = @($global:AssessmentTestState.CredentialActivityRows[0]); '@odata.nextLink' = 'https://graph.microsoft.com/beta/reports/appCredentialSignInActivities?page=2' }
    }
    $previewHandler = $global:AssessmentTestState.Handler
    $preview = Get-AssessmentCredentialActivity
    Assert-Collection ($preview.State -eq 'Available' -and $preview.RecordCount -eq 7 -and $global:AssessmentTestState.Calls.Count -eq 2) 'Preview credential activity is fetched once with all pages'
    $credentials = @(
        [pscustomobject]@{ AppObjectId = 'app-a'; AppId = 'client-a'; KeyId = 'shared'; CredentialType = 'password'; Expired = $false; StartDateTime = '2025-01-01T00:00:00Z' },
        [pscustomobject]@{ AppObjectId = 'app-a'; AppId = 'client-a'; KeyId = 'shared'; CredentialType = 'key'; Expired = $false; StartDateTime = '2025-01-01T00:00:00Z' },
        [pscustomobject]@{ AppObjectId = 'app-b'; AppId = 'client-b'; KeyId = 'shared'; CredentialType = 'password'; Expired = $true; StartDateTime = '2025-01-01T00:00:00Z' },
        [pscustomobject]@{ AppObjectId = 'app-a'; AppId = 'client-a'; KeyId = 'unknown'; CredentialType = 'password'; Expired = $false; StartDateTime = '2025-01-01T00:00:00Z' },
        [pscustomobject]@{ AppObjectId = 'app-a'; AppId = 'client-a'; KeyId = 'future'; CredentialType = 'password'; Expired = $false; StartDateTime = '2025-01-01T00:00:00Z' }
    )
    Merge-CredentialActivity -Credentials $credentials -Activity $preview -Now $now
    Assert-Collection ($credentials[0].DaysSinceCredentialSignIn -eq 1 -and $credentials[0].InactiveCredential -eq $false -and $credentials[0].ActivityEvidence.Count -eq 2) 'Matching chooses the latest activity across resources, not the oldest record'
    Assert-Collection ($credentials[1].InactiveCredential -eq $true -and $credentials[1].DaysSinceCredentialSignIn -eq 90 -and $credentials[1].CredentialReviewRequired) 'Credential type/origin are isolated and the 90-day review boundary is inclusive'
    Assert-Collection ($credentials[2].ActivityMatchStatus -eq 'No matching activity' -and $null -eq $credentials[2].InactiveCredential -and $credentials[2].CredentialReviewRequired) 'Reused key IDs or conflicting client IDs cannot cross-match applications; expiry still triggers review'
    Assert-Collection ($credentials[3].UsageAssessment -eq 'Unknown' -and $null -eq $credentials[3].InactiveCredential -and $credentials[4].UsageAssessment -eq 'Unknown') 'Missing and future activity timestamps do not establish inactivity'
    $missingKey = $credentials[0].PSObject.Copy()
    $missingKey.KeyId = $null
    $preCreation = $credentials[0].PSObject.Copy()
    $preCreation.StartDateTime = '2026-10-23T00:00:00Z'
    $mixedDates = $credentials[0].PSObject.Copy()
    $malformedRecord = $activityRows[0].PSObject.Copy()
    $malformedRecord.signInActivity = @{ lastSignInDateTime = 'not-a-timestamp' }
    $edgePreview = [pscustomobject]@{ State = 'Available'; Records = @($activityRows) + @($malformedRecord) }
    Merge-CredentialActivity -Credentials @($missingKey, $preCreation, $mixedDates) -Activity $edgePreview -Now $now
    Assert-Collection ($missingKey.ActivityMatchStatus -eq 'No matching activity' -and $missingKey.ActivityEvidence.Count -eq 0 -and $null -eq $missingKey.InactiveCredential) 'Missing credential key IDs cannot match otherwise valid activity'
    Assert-Collection ($preCreation.UsageAssessment -eq 'Unknown' -and $null -eq $preCreation.LastCredentialSignInDateTime) 'Activity preceding credential creation cannot establish credential use'
    Assert-Collection ($mixedDates.ActivityMatchStatus -eq 'Incomplete activity' -and $mixedDates.DaysSinceCredentialSignIn -eq 1 -and $null -eq $mixedDates.InactiveCredential -and $mixedDates.ActivityEvidence.Count -eq 3) 'Malformed matched timestamps preserve valid evidence without producing a complete inactivity assessment'
    Reset-Transport { [pscustomobject]@{ value = @(); '@odata.nextLink' = 'https://example.invalid/beta/reports/appCredentialSignInActivities' } }
    $failedPreview = Get-AssessmentCredentialActivity -WarningAction SilentlyContinue
    Assert-Collection ($failedPreview.State -eq 'Unavailable' -and $null -eq $failedPreview.Records -and $global:AssessmentTestState.Calls.Count -eq 1) 'A foreign preview continuation is rejected before sending an authenticated request'
    Reset-Transport { throw [AssessmentTestHttpException]::new(403) }
    $failedPreview = Get-AssessmentCredentialActivity -WarningAction SilentlyContinue
    Merge-CredentialActivity -Credentials $credentials -Activity $failedPreview -Now $now
    Assert-Collection ($failedPreview.State -eq 'Unavailable' -and $credentials[0].ActivityMatchStatus -eq 'Not assessed' -and $null -eq $credentials[0].InactiveCredential -and $null -eq $credentials[0].CredentialReviewRequired -and $credentials[2].CredentialReviewRequired) 'Denied preview access is not a zero-unused or no-review result; expiry still requires review'
    Reset-Transport { param($Uri); if ($Uri -like '*page=2') { throw [AssessmentTestHttpException]::new(503) }; [pscustomobject]@{ value = @($global:AssessmentTestState.CredentialActivityRows[0]); '@odata.nextLink' = 'https://graph.microsoft.com/beta/reports/appCredentialSignInActivities?page=2' } }
    $failedPreview = Get-AssessmentCredentialActivity -WarningAction SilentlyContinue
    Assert-Collection ($failedPreview.State -eq 'Unavailable' -and $null -eq $failedPreview.Records) 'A failed later preview page cannot be used as a complete activity snapshot'
    Reset-Transport { [pscustomobject]@{ value = @() } }
    $emptyPreview = Get-AssessmentCredentialActivity
    Merge-CredentialActivity -Credentials $credentials -Activity $emptyPreview -Now $now
    Assert-Collection ($emptyPreview.State -eq 'Available' -and $emptyPreview.RecordCount -eq 0 -and $credentials[0].UsageAssessment -eq 'Unknown') 'An empty successful activity query is distinct from unavailable data and never implies unused credentials'
    $global:AssessmentTestState.Endpoint = 'https://graph.microsoft.us'
    $unsupported = Get-AssessmentCredentialActivity -WarningAction SilentlyContinue
    Assert-Collection ($unsupported.State -eq 'Unsupported' -and $global:AssessmentTestState.Calls.Count -eq 1) 'Unsupported clouds do not call the global-only preview API'
    $global:AssessmentTestState.Endpoint = 'https://graph.microsoft.com'
    function global:Get-MgApplication {
        [CmdletBinding()]param([switch]$All, $Property)
        [pscustomobject]@{
            Id = 'app-a'; AppId = 'client-a'; DisplayName = 'Synthetic credential app'
            PasswordCredentials = @([pscustomobject]@{ KeyId = 'shared'; Hint = 'synthetic'; DisplayName = 'Test only'; StartDateTime = [datetime]'2025-01-01'; EndDateTime = [datetime]'2099-01-01' })
            KeyCredentials = @()
        }
    }
    Reset-Transport $previewHandler
    Invoke-CredentialHygiene -OutputDir (Join-Path $OutputRoot 'preview')
    $credentialExport = Get-Content -Raw (Join-Path $OutputRoot 'preview/03-credential-hygiene.json') | ConvertFrom-Json
    Assert-Collection ($credentialExport.CredentialActivity.State -eq 'Available' -and $credentialExport.Credentials[0].ActivityEvidence.Count -eq 2 -and $credentialExport.Credentials -is [array]) 'The real credential collector persists matched preview evidence and preserves collection shape'
    Reset-Transport { throw [AssessmentTestHttpException]::new(403) }
    Invoke-CredentialHygiene -OutputDir (Join-Path $OutputRoot 'preview-denied') -WarningAction SilentlyContinue
    $credentialExport = Get-Content -Raw (Join-Path $OutputRoot 'preview-denied/03-credential-hygiene.json') | ConvertFrom-Json
    Assert-Collection ($credentialExport.CredentialActivity.State -eq 'Unavailable' -and $credentialExport.Aggregations.TotalActivePasswordCredentials -eq 1 -and $null -eq $credentialExport.Aggregations.InactiveCredentials90Days) 'Expiry inventory survives denied preview access with explicit null usage totals'
    function global:Get-MgApplication { [CmdletBinding()]param([switch]$All, $Property) }
    Reset-Transport { [pscustomobject]@{ value = @() } }
    Invoke-CredentialHygiene -OutputDir (Join-Path $OutputRoot 'preview-empty')
    $credentialExport = Get-Content -Raw (Join-Path $OutputRoot 'preview-empty/03-credential-hygiene.json') | ConvertFrom-Json
    Assert-Collection ($credentialExport.Credentials -is [array] -and $credentialExport.Credentials.Count -eq 0 -and $credentialExport.Aggregations.InactiveCredentials90Days -eq 0 -and $credentialExport.CredentialActivity.State -eq 'Available') 'Empty credential inventory retains an empty array and successful preview coverage'
    Reset-Transport { [pscustomobject]@{ value = @([pscustomobject]@{ appId = 'activity-client' }) } }
    Start-AssessmentCollection
    $null = Get-AssessmentSignInActivity
    $null = Get-AssessmentSignInActivity
    Assert-Collection ($global:AssessmentTestState.Calls.Count -eq 1) 'Inventory and hygiene share one paged SP activity capability per run'
    $global:AssessmentTestState.Endpoint = 'https://graph.microsoft.us'
    Assert-Collection ((Get-AssessmentSignInActivity).State -eq 'Unsupported' -and $global:AssessmentTestState.Calls.Count -eq 1) 'SP activity does not call an unsupported national-cloud API'
    $global:AssessmentTestState.Endpoint = 'https://graph.microsoft.com'
    Reset-Transport {
        param($Uri)
        if ($Uri -like '*page=2') { throw [AssessmentTestHttpException]::new(403) }
        [pscustomobject]@{ value = @(@{ id = 'partial' }); '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants?page=2' }
    }
    $unavailable = Get-AssessmentEvidence -Path oauth2PermissionGrants -WarningAction SilentlyContinue
    Assert-Collection ($unavailable.State -eq 'Unavailable' -and $null -eq $unavailable.Records) 'Failed optional later pages never leak partial evidence as complete'

    $global:AssessmentTestState.ConsentApps = @(
        [pscustomobject]@{ id = 'configured-app'; appId = 'configured-client'; displayName = 'Configured app'; owners = @()
            requiredResourceAccess = @(@{ resourceAppId = '00000003-0000-0000-c000-000000000000'; resourceAccess = @(
                @{ id = 'role-one'; type = 'Role' }, @{ id = 'role-two'; type = 'Role' }, @{ id = 'scope-admin'; type = 'Scope' }
            ) })
        },
        [pscustomobject]@{ id = 'no-sp-app'; appId = 'no-sp-client'; displayName = 'Registration without SP'; owners = @()
            requiredResourceAccess = @(@{ resourceAppId = '00000003-0000-0000-c000-000000000000'; resourceAccess = @(@{ id = 'role-one'; type = 'Role' }) })
        }
    )
    $global:AssessmentTestState.ConsentPrincipals = @(
        [pscustomobject]@{ id = 'resource'; appId = '00000003-0000-0000-c000-000000000000'; displayName = 'Graph'; servicePrincipalType = 'Application'
            appRoleAssignments = @(); appRoles = @(@{ id = 'role-one'; value = 'Directory.ReadWrite.All' }, @{ id = 'role-two'; value = 'Application.Read.All' })
            oauth2PermissionScopes = @(@{ id = 'scope-admin'; value = 'Directory.Read.All'; type = 'Admin' }, @{ id = 'scope-user'; value = 'User.Read'; type = 'User' }, @{ id = 'scope-mail'; value = 'Mail.Read'; type = 'User' })
        },
        [pscustomobject]@{ id = 'client-sp'; appId = 'configured-client'; displayName = 'Configured app'; servicePrincipalType = 'Application'
            appRoleAssignments = @(@{ id = 'role-grant'; resourceId = 'resource'; appRoleId = 'role-one' }); appRoles = @(); oauth2PermissionScopes = @()
        },
        [pscustomobject]@{ id = 'exchange'; appId = '00000002-0000-0ff1-ce00-000000000000'; displayName = 'Exchange'; servicePrincipalType = 'Application'
            appRoleAssignments = @(); appRoles = @(@{ id = 'exchange-role'; value = 'Exchange.ManageAsApp' }); oauth2PermissionScopes = @()
        },
        [pscustomobject]@{ id = 'mi-client'; appId = 'mi-app'; displayName = 'Managed workload'; servicePrincipalType = 'ManagedIdentity'
            appRoleAssignments = @(@{ id = 'mi-grant'; resourceId = 'exchange'; appRoleId = 'exchange-role' }); appRoles = @(); oauth2PermissionScopes = @()
        }
    )
    Reset-Transport {
        param($Uri)
        if ($Uri -like '*/applications?*') { return [pscustomobject]@{ value = $global:AssessmentTestState.ConsentApps } }
        if ($Uri -like '*/oauth2PermissionGrants') { return [pscustomobject]@{ value = @(
            @{ id = 'tenant-consent'; clientId = 'client-sp'; resourceId = 'resource'; consentType = 'AllPrincipals'; scope = 'Directory.Read.All' },
            @{ id = 'user-consent'; clientId = 'client-sp'; resourceId = 'resource'; consentType = 'Principal'; principalId = 'consent-user'; scope = 'User.Read Mail.Read' }
        ) } }
        [pscustomobject]@{ value = $global:AssessmentTestState.ConsentPrincipals }
    }
    Start-AssessmentCollection
    $actualGrants = @(Get-GraphPermissions)
    $normalized = Get-NormalizedPermissions $actualGrants
    Assert-Collection (@($actualGrants | Where-Object { $_.SpObjectId -eq 'mi-client' -and $_.Tier -eq 'PRIVILEGED' }).Count -eq 1) 'Managed identities retain API grants and API-specific Exchange privilege'
    Assert-Collection (@($normalized.Rows | Where-Object { $_.PermissionValue -eq 'Directory.Read.All' -and $_.ConfiguredState -eq 'Configured' -and $_.ConsentStatus -eq 'Granted tenant-wide admin consent' }).Count -eq 1) 'Configured delegated permission joins tenant-wide consent by IDs'
    Assert-Collection (@($normalized.Rows | Where-Object { $_.PermissionValue -eq 'User.Read' -and $_.ConfiguredState -eq 'Granted but not configured' -and $_.ConsentPrincipalId -eq 'consent-user' }).Count -eq 1) 'Specific-user consent and granted-only permissions remain distinct'
    Assert-Collection (@($normalized.Rows | Where-Object { $_.PermissionValue -eq 'Mail.Read' -and $_.PermissionType -eq 'Delegated' -and $_.Tier -eq 'PRIVILEGED' -and $_.ReviewRequired -and $_.AdminConsentRequired -eq $false -and $_.RiskRuleId -eq 'MS.IR.SENSITIVE' }).Count -eq 1) 'Collection classifies dangerous delegated mail access even without admin consent'
    Assert-Collection (@($normalized.Rows | Where-Object { $_.AppObjectId -eq 'no-sp-app' -and $_.GrantState -eq 'Not granted' }).Count -eq 1) 'Configured application without a local SP is retained without null-key joins'
    Import-CollectorFunctions '08-ca-for-workload-identities.ps1' @('Get-SPCoverage')
    $global:AssessmentTestState.ConsentPrincipals[1] | Add-Member -NotePropertyMembers @{ appOwnerOrganizationId = 'synthetic-tenant'; signInAudience = 'AzureADMyOrg' }
    $policy = [pscustomobject]@{ State = 'enabled'; IncludeServicePrincipals = 'ServicePrincipalsInMyTenant'; ExcludeServicePrincipals = 'client-sp'; SpFilterRule = $null; GrantControls = 'OR: block' }
    $coverage = @(Get-SPCoverage -WIPolicies @($policy) -TenantId 'synthetic-tenant')
    Assert-Collection ($coverage.Count -eq 1 -and $coverage[0].CoveredByAnyCAPolicy -eq $false) 'Classic CA subtracts exclusions and excludes MI and external principals'
    $policy.ExcludeServicePrincipals = ''; $policy.SpFilterRule = 'unresolved filter'
    Assert-Collection ($null -eq @(Get-SPCoverage -WIPolicies @($policy) -TenantId 'synthetic-tenant')[0].CoveredByAnyCAPolicy) 'Unresolved CA filters are unknown rather than covered'

    $reloadRoot = Join-Path $OutputRoot 'permission-module-reload'
    $reloadScripts = Join-Path $reloadRoot 'scripts'
    $null = New-Item -ItemType Directory -Path $reloadScripts -Force
    foreach ($file in @('05-permission-surface.ps1', 'Assessment.Common.psm1')) {
        Copy-Item -LiteralPath (Join-Path $scripts $file) -Destination $reloadScripts -Force
    }
    $null = New-Item -ItemType Directory -Path (Join-Path $reloadRoot 'controls') -Force
    Copy-Item -LiteralPath (Join-Path $scripts '../controls/catalog.json') -Destination (Join-Path $reloadRoot 'controls/catalog.json') -Force
    $savedModulePath = $env:PSModulePath
    try {
        $mockModules = Join-Path $reloadRoot 'mock-modules'
        foreach ($name in @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Applications', 'Microsoft.Graph.Identity.DirectoryManagement')) {
            $folder = Join-Path $mockModules $name
            $null = New-Item -ItemType Directory -Path $folder -Force
            'Export-ModuleMember -Function @()' | Set-Content (Join-Path $folder "$name.psm1")
            Import-Module (Join-Path $folder "$name.psm1") -Force
        }
        $env:PSModulePath = "$mockModules$([IO.Path]::PathSeparator)$savedModulePath"
        Remove-Module Assessment.Controls
        $cachedControls = Join-Path $reloadScripts 'Assessment.Controls.psm1'
        @'
function Invoke-WorkloadControls { throw 'Cached pre-classifier module must be refreshed.' }
Export-ModuleMember -Function Invoke-WorkloadControls
'@ | Set-Content $cachedControls
        Import-Module $cachedControls -Force
        Copy-Item -LiteralPath (Join-Path $scripts 'Assessment.Controls.psm1') -Destination $cachedControls -Force
        Assert-Collection (-not (Get-Command Set-WorkloadPermissionRisk -ErrorAction SilentlyContinue)) 'Regression starts with a cached module that predates the permission classifier'
        Import-Module (Join-Path $reloadScripts 'Assessment.Common.psm1') -Force
        $global:AssessmentTestState.Calls.Clear()
        Start-AssessmentCollection -IncludeAzure:$false
        $null = Get-AssessmentDirectoryData -Resource servicePrincipals -Relationship appRoleAssignments
        foreach ($attempt in 1..2) {
            $reloadOutput = Join-Path $reloadRoot "run-$attempt"
            & (Join-Path $reloadScripts '05-permission-surface.ps1') -OutputDir $reloadOutput -EntraOnly
            $actualExport = Get-Content -Raw (Join-Path $reloadOutput '05-permission-surface.json') | ConvertFrom-Json
            Assert-Collection (@($actualExport.NormalizedPermissions | Where-Object {
                $_.PermissionValue -eq 'Mail.Read' -and $_.Tier -eq 'PRIVILEGED' -and $_.RiskRuleId -eq 'MS.IR.SENSITIVE'
            }).Count -eq 1) "Real collector entry point refreshes the classifier and exports dangerous delegated grants (run $attempt)"
        }
        Assert-Collection ($global:AssessmentTestState.Calls.Count -eq 3) 'Refreshing the classifier preserves the shared directory/evidence cache across collector invocations'
    } finally {
        $env:PSModulePath = $savedModulePath
        Get-Module -All | Where-Object { $_.Path -and $_.Path.StartsWith("$reloadRoot$([IO.Path]::DirectorySeparatorChar)") } | Remove-Module -Force
        Import-Module (Join-Path $scripts 'Assessment.Common.psm1') -Force
        Import-Module (Join-Path $scripts 'Assessment.Controls.psm1') -Force
    }
    Write-Host "PASS: $checks collection checks. No SDK authentication or tenant requests." -ForegroundColor Green
} finally {
    Stop-AssessmentCollection
    Remove-Module Assessment.Common
    foreach ($name in @(
        'Get-MgContext', 'Get-AzContext', 'Get-MgEnvironment', 'Invoke-MgGraphRequest', 'Start-Sleep',
        'Get-MgApplication', 'Get-MgServicePrincipal', 'Get-MgApplicationOwner',
        'Get-MgApplicationFederatedIdentityCredential', 'Get-MgServicePrincipalOwner',
        'Get-MgServicePrincipalAppRoleAssignment', 'Get-MgBetaReportServicePrincipalSignInActivity', 'Get-MgUser',
        'Get-AzSubscription', 'Write-Progress'
    )) { Remove-Item -LiteralPath "Function:global:$name" }
    Remove-Variable -Name AssessmentTestState -Scope Global
}
