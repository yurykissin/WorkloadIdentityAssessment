<#
.SYNOPSIS
    Unified inventory of app registrations, service principals, and managed
    identities across Entra and Azure.

.DESCRIPTION
    Answers discovery questions:
      Q1/Q5 — Count of all service principals and app registrations
      Q13/Q14 — Workloads using managed identity
      Q25   — Multi-tenant app registrations
      Q26   — Third-party SaaS with admin-consented app permissions

    Prereq modules : Microsoft.Graph.Authentication,
                     Microsoft.Graph.Applications,
                     Microsoft.Graph.Identity.DirectoryManagement,
                     Microsoft.Graph.Reports,
                     Az.Accounts, Az.ResourceGraph

    Prereq Graph scopes : Application.Read.All, Directory.Read.All,
                          AuditLog.Read.All

    Prereq Azure roles  : Reader (subscription-level)

    Produces:
      <OutputDir>/02-inventory.json
      <OutputDir>/02-inventory-app-registrations.csv
      <OutputDir>/02-inventory-service-principals.csv
      <OutputDir>/02-inventory-managed-identities.csv

.PARAMETER EntraOnly
    Collect app registrations and service principals without Azure managed-identity resource discovery.

.EXAMPLE
    ./scripts/02-inventory.ps1 -OutputDir ./output/20260101-120000
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputDir = (Join-Path (Split-Path -Parent $PSScriptRoot) ('output/' + (Get-Date -Format 'yyyyMMdd-HHmmss'))),
    [switch]$EntraOnly
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Assessment.Common.psm1') -ErrorAction Stop

# ─── Module prerequisite check ────────────────────────────────────────────────
$requiredModules = @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Applications', 'Microsoft.Graph.Identity.DirectoryManagement', 'Az.Accounts', 'Az.ResourceGraph')
if ($EntraOnly) { $requiredModules = @($requiredModules | Where-Object { $_ -notlike 'Az.*' }) }
$missingModules = @($requiredModules | Where-Object { -not (Get-Module -ListAvailable -Name $_) })
if ($missingModules.Count -gt 0) {
    Write-Host ""
    Write-Host "  ✗ MISSING POWERSHELL MODULES:" -ForegroundColor Red
    foreach ($m in $missingModules) { Write-Host "      - $m" -ForegroundColor Red }
    Write-Host ""
    Write-Host "  Install all toolkit prerequisites by running:" -ForegroundColor Yellow
    Write-Host "      ./scripts/00-prereqs.ps1" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Or install just what this script needs:" -ForegroundColor Yellow
    Write-Host "      Install-Module $($missingModules -join ', ') -Scope CurrentUser -Force" -ForegroundColor Cyan
    Write-Host ""
    exit 2
}
foreach ($m in $requiredModules) {
    if (-not (Get-Module -Name $m)) {
        try { Import-Module $m -ErrorAction Stop } catch {
            Write-Verbose "Import-Module $m skipped: $($_.Exception.Message)"
        }
    }
}


# ─── Helpers ─────────────────────────────────────────────────────────────────
function Invoke-WithRetry {
    [CmdletBinding()]
    param(
        [scriptblock]$ScriptBlock,
        [int]$MaxAttempts = 3,
        [int]$BaseDelaySeconds = 2
    )
    $attempt = 0
    while ($true) {
        $attempt++
        try { return & $ScriptBlock }
        catch {
            $statusCode = $null
            $exc = $_.Exception
            if ($exc.PSObject.Properties.Name -contains 'Response' -and $exc.Response -and $exc.Response.PSObject.Properties.Name -contains 'StatusCode') {
                $statusCode = [int]$exc.Response.StatusCode
            } elseif ($exc.Message -match '(429|503|504)') { $statusCode = [int]($Matches[1]) }
            if ($attempt -ge $MaxAttempts -or $statusCode -notin @(429, 503, 504)) { throw }
            $delay = $BaseDelaySeconds * [Math]::Pow(2, $attempt - 1)
            Write-Verbose "Attempt $attempt failed (HTTP $statusCode). Retrying in ${delay}s..."
            Start-Sleep -Seconds $delay
        }
    }
}

function Assert-Contexts {
    Assert-AssessmentContexts -RequireAzure:(-not $EntraOnly)
    $required = @('Application.Read.All', 'Directory.Read.All')
    $mgCtx = Get-MgContext
    if ($null -eq $mgCtx) {
        Write-Error "No Microsoft Graph context. Run: Connect-MgGraph -Scopes 'Application.Read.All','Directory.Read.All','AuditLog.Read.All'"
        exit 2
    }
    $missing = @($required | Where-Object { $_ -notin $mgCtx.Scopes })
    if ($missing.Count -gt 0) {
        $allRequired = $required -join ','
        Write-Host ""
        Write-Host "  ✗ MISSING GRAPH SCOPES: $($missing -join ', ')" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Reconnect with all required scopes for this script:" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "    Disconnect-MgGraph -ErrorAction SilentlyContinue" -ForegroundColor Cyan
        Write-Host "    Connect-MgGraph -TenantId '<assessment-tenant-id>' -Scopes $allRequired" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  TIP: To cover all 10 toolkit scripts in one connect, use:" -ForegroundColor Yellow
        Write-Host "    Connect-MgGraph -TenantId '<assessment-tenant-id>' -Scopes Application.Read.All,Directory.Read.All,Policy.Read.All,RoleManagement.Read.Directory,AuditLog.Read.All,IdentityRiskEvent.Read.All,CrossTenantInformation.ReadBasic.All" -ForegroundColor Cyan
        Write-Host ""
        Write-Error "Missing Graph scopes: $($missing -join ', ')"
        exit 2
    }
}

function Get-SignInActivityMap {
    # Returns hashtable keyed by appId → @{ LastSignInDateTime; LastDelegatedSignInDateTime }
    $map = @{}
    try {
        Write-Host "  Fetching SP sign-in activity (beta)..." -NoNewline
        $evidence = Get-AssessmentSignInActivity
        if ($evidence.State -ne 'Available') { throw $evidence.Message }
        $activities = @($evidence.Records)
        foreach ($a in $activities) {
            if (-not $a.AppId) {
                Write-Warning 'A sign-in activity record has no application ID and cannot be joined to inventory.'
                continue
            }
            $map[$a.AppId] = Get-AssessmentActivitySummary $a
        }
        Write-Host " $($activities.Count) records." -ForegroundColor Green
    } catch {
        if ($_.Exception.Message -match '403|Forbidden') {
            Write-Host " not available (403 — AuditLog.Read.All scope or P1/P2 license required)." -ForegroundColor Yellow
        } else {
            Write-Host " failed: $_" -ForegroundColor Yellow
        }
    }
    return $map
}

function Get-AppRegistrations {
    [CmdletBinding()]
    param([string]$TenantId)

    Write-Host "  Fetching app registrations..." -NoNewline
    $apps = @(Get-AssessmentDirectoryData -Resource applications -Relationship owners)
    Write-Host " $($apps.Count) found." -ForegroundColor Green
    $ficsById = @{}
    foreach ($record in (Get-AssessmentDirectoryData -Resource applications -Relationship federatedIdentityCredentials)) {
        $ficsById[$record.Id] = $record.federatedIdentityCredentials
    }

    $today = [datetime]::UtcNow
    $rows = [System.Collections.Generic.List[PSObject]]::new()

    $i = 0
    foreach ($app in $apps) {
        $i++
        if ($apps.Count -gt 50) {
            Write-Progress -Activity 'Processing app registrations' -Status "$i / $($apps.Count)" -PercentComplete (($i / $apps.Count) * 100)
        }

        if (-not $ficsById.ContainsKey($app.Id)) { throw "Application $($app.Id) changed between directory reads. Start a new snapshot." }
        $ficCount = @($ficsById[$app.Id]).Count
        $ownerCount = @($app.owners).Count

        $activePwdCreds  = @($app.PasswordCredentials | Where-Object { $_.EndDateTime -and ([datetime]$_.EndDateTime).ToUniversalTime() -gt $today })
        $activeKeyCreds  = @($app.KeyCredentials      | Where-Object { $_.EndDateTime -and ([datetime]$_.EndDateTime).ToUniversalTime() -gt $today })

        $redirectUris = @()
        if ($app.Web.RedirectUris)        { $redirectUris += $app.Web.RedirectUris }
        if ($app.Spa.RedirectUris)        { $redirectUris += $app.Spa.RedirectUris }
        if ($app.PublicClient.RedirectUris) { $redirectUris += $app.PublicClient.RedirectUris }

        $implicitGrant = ($app.Web.ImplicitGrantSettings.EnableAccessTokenIssuance -eq $true -or
                          $app.Web.ImplicitGrantSettings.EnableIdTokenIssuance -eq $true)

        $requiredAppPerms       = 0
        $requiredDelegatedPerms = 0
        foreach ($rra in $app.RequiredResourceAccess) {
            $appPerms  = @($rra.ResourceAccess | Where-Object { $_.Type -eq 'Role' })
            $delPerms  = @($rra.ResourceAccess | Where-Object { $_.Type -eq 'Scope' })
            $requiredAppPerms       += $appPerms.Count
            $requiredDelegatedPerms += $delPerms.Count
        }

        $ageInDays = if ($app.CreatedDateTime) {
            [int]($today - ([datetime]$app.CreatedDateTime).ToUniversalTime()).TotalDays
        } else { -1 }

        $audienceBucket = switch ($app.SignInAudience) {
            'AzureADMyOrg'                        { 'single-tenant' }
            'AzureADMultipleOrgs'                 { 'multi-tenant' }
            'AzureADandPersonalMicrosoftAccount'  { 'multi-tenant+MSA' }
            'PersonalMicrosoftAccount'             { 'personal-MSA' }
            default                                { $app.SignInAudience }
        }

        $row = [PSCustomObject]@{
            AppObjectId                    = $app.Id
            AppId                          = $app.AppId
            DisplayName                    = $app.DisplayName
            SignInAudience                 = $audienceBucket
            CreatedDateTime                = $app.CreatedDateTime
            AgeInDays                      = $ageInDays
            PublisherDomain                = $app.PublisherDomain
            VerifiedPublisherDisplayName   = $app.VerifiedPublisher.DisplayName
            HasTags                        = ($app.Tags.Count -gt 0)
            TagCount                       = $app.Tags.Count
            Tags                           = ($app.Tags -join ';')
            OwnerCount                     = $ownerCount
            Owners                         = @($app.owners)
            RequiredResourceAccess         = @($app.RequiredResourceAccess)
            RedirectUris                   = @($redirectUris)
            ImplicitGrantSettings          = $app.Web.ImplicitGrantSettings
            InstancePropertyLock           = $app.ServicePrincipalLockConfiguration
            IdentifierUris                 = @($app.IdentifierUris)
            RequestedAccessTokenVersion    = $app.Api.RequestedAccessTokenVersion
            ServiceManagementReference     = $app.ServiceManagementReference
            PasswordCredentialCount        = $app.PasswordCredentials.Count
            ActivePasswordCredentialCount  = $activePwdCreds.Count
            KeyCredentialCount             = $app.KeyCredentials.Count
            ActiveKeyCredentialCount       = $activeKeyCreds.Count
            FederatedCredentialCount       = $ficCount
            RedirectUriCount               = $redirectUris.Count
            HasImplicitGrantEnabled        = $implicitGrant
            RequiredAppPermissionCount     = $requiredAppPerms
            RequiredDelegatedPermCount     = $requiredDelegatedPerms
        }
        $rows.Add($row)
    }
    if ($apps.Count -gt 50) { Write-Progress -Activity 'Processing app registrations' -Completed }
    return $rows
}

function Get-ServicePrincipals {
    [CmdletBinding()]
    param(
        [string]$TenantId,
        [hashtable]$SignInActivityMap
    )

    Write-Host "  Fetching service principals..." -NoNewline
    $sps = @(Get-AssessmentDirectoryData -Resource servicePrincipals -Relationship appRoleAssignments)
    Write-Host " $($sps.Count) found." -ForegroundColor Green
    $ownersById = @{}
    foreach ($record in (Get-AssessmentDirectoryData -Resource servicePrincipals -Relationship owners)) {
        $ownersById[$record.Id] = $record.owners
    }

    $missingAppIds = @($sps | Where-Object { -not $_.AppId }).Count
    if ($missingAppIds -gt 0) {
        Write-Warning "$missingAppIds service principal(s) have no application ID. They remain in inventory with unknown sign-in activity."
    }
    $rows = [System.Collections.Generic.List[PSObject]]::new()
    $today = [datetime]::UtcNow

    $i = 0
    foreach ($sp in $sps) {
        $i++
        if ($sps.Count -gt 50 -and ($i -eq 1 -or $i % 250 -eq 0)) {
            Write-Progress -Activity 'Processing service principals' -Status "$i / $($sps.Count)" -PercentComplete (($i / $sps.Count) * 100)
        }

        $isExternal = ($null -ne $sp.AppOwnerOrganizationId -and $sp.AppOwnerOrganizationId -ne $TenantId)

        # Sign-in activity from pre-fetched map
        $signinInfo = if ($sp.AppId) { $SignInActivityMap[$sp.AppId] } else { $null }
        $lastSignIn = $null
        if ($signinInfo) { $lastSignIn = $signinInfo.LastSignIn }

        # Owner count — only for Application type SPs owned by this tenant
        $ownerCount = $null
        if ($sp.ServicePrincipalType -eq 'Application' -and $sp.AppOwnerOrganizationId -eq $TenantId) {
            if (-not $ownersById.ContainsKey($sp.Id)) { throw "Service principal $($sp.Id) changed between directory reads. Start a new snapshot." }
            $ownerCount = @($ownersById[$sp.Id]).Count
        }

        $appRoleAssignmentCount = @($sp.appRoleAssignments | Where-Object { $null -ne $_ }).Count

        $row = [PSCustomObject]@{
            SpObjectId               = $sp.Id
            AppId                    = $sp.AppId
            DisplayName              = $sp.DisplayName
            ServicePrincipalType     = $sp.ServicePrincipalType
            AccountEnabled           = $sp.AccountEnabled
            AppOwnerOrganizationId   = $sp.AppOwnerOrganizationId
            IsExternalApp            = $isExternal
            HasTags                  = ($sp.Tags.Count -gt 0)
            TagCount                 = $sp.Tags.Count
            Tags                     = ($sp.Tags -join ';')
            OwnerCount               = $ownerCount
            Owners                   = if ($ownersById.ContainsKey($sp.Id)) { @($ownersById[$sp.Id]) } else { $null }
            CreatedDateTime          = $sp.CreatedDateTime
            SignInAudience           = $sp.SignInAudience
            PasswordCredentials      = @($sp.PasswordCredentials)
            KeyCredentials           = @($sp.KeyCredentials)
            LastSignIn               = $lastSignIn
            ActivityFlows            = $signinInfo.Flows
            DaysSinceLastSignIn      = if ($lastSignIn) { [int]($today - [datetime]$lastSignIn).TotalDays } else { $null }
            NeverSignedIn            = $null
            AppRoleAssignmentCount   = $appRoleAssignmentCount
            AppRoleCount             = $sp.AppRoles.Count
            OAuth2ScopeCount         = $sp.Oauth2PermissionScopes.Count
        }
        $rows.Add($row)
    }
    if ($sps.Count -gt 50) { Write-Progress -Activity 'Processing service principals' -Completed }
    return $rows
}

function Get-ManagedIdentities {
    Write-Host "  Fetching managed identities via Resource Graph..." -NoNewline

    $miRows = [System.Collections.Generic.List[PSObject]]::new()

    # User-assigned MIs
    try {
        $uaQuery = @"
Resources
| where type =~ 'microsoft.managedidentity/userassignedidentities'
| project
    principalId  = properties.principalId,
    clientId     = properties.clientId,
    name         = name,
    resourceId   = id,
    subscriptionId = subscriptionId,
    resourceGroup  = resourceGroup,
    location       = location
| order by subscriptionId asc, name asc
"@
        $uaMis = Invoke-WithRetry { Search-AzGraph -Query $uaQuery -First 1000 -ErrorAction Stop }
        foreach ($mi in $uaMis) {
            $miRows.Add([PSCustomObject]@{
                IdentityType   = 'UserAssigned'
                PrincipalId    = $mi.principalId
                ClientId       = $mi.clientId
                Name           = $mi.name
                ResourceId     = $mi.resourceId
                SubscriptionId = $mi.subscriptionId
                ResourceGroup  = $mi.resourceGroup
                Location       = $mi.location
                AttachedTo     = $null
            })
        }
    } catch {
        Write-Warning "Could not enumerate user-assigned MIs: $_"
    }

    # Resources with system-assigned or user-assigned identity attached
    try {
        $saQuery = @"
Resources
| where isnotnull(identity) and (
    identity.type =~ 'SystemAssigned' or
    identity.type =~ 'SystemAssigned, UserAssigned' or
    identity.type =~ 'UserAssigned'
  )
| project
    resourceId     = id,
    resourceType   = type,
    name           = name,
    subscriptionId = subscriptionId,
    resourceGroup  = resourceGroup,
    location       = location,
    identityType   = identity.type,
    systemPrincipalId = identity.principalId,
    userAssignedIds   = keys(identity.userAssignedIdentities)
| order by subscriptionId asc, name asc
"@
        $saResources = Invoke-WithRetry { Search-AzGraph -Query $saQuery -First 2000 -ErrorAction Stop }
        foreach ($r in $saResources) {
            if ($r.identityType -match 'SystemAssigned' -and $r.systemPrincipalId) {
                $miRows.Add([PSCustomObject]@{
                    IdentityType   = 'SystemAssigned'
                    PrincipalId    = $r.systemPrincipalId
                    ClientId       = $null
                    Name           = "system-$($r.name)"
                    ResourceId     = $r.resourceId
                    SubscriptionId = $r.subscriptionId
                    ResourceGroup  = $r.resourceGroup
                    Location       = $r.location
                    AttachedTo     = $r.resourceId
                })
            }
        }
    } catch {
        Write-Warning "Could not enumerate system-assigned MIs: $_"
    }

    Write-Host " $($miRows.Count) managed identities found." -ForegroundColor Green
    return $miRows
}

function Invoke-Inventory {
    [CmdletBinding()]
    param([string]$OutputDir)

    Assert-Contexts

    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  02-inventory  |  Unified workload identity inventory..." -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""

    $tenantId = (Get-MgContext).TenantId

    # Pre-fetch sign-in activity once
    $signInMap = Get-SignInActivityMap

    # Collect all three tables
    $appRegs  = @(Get-AppRegistrations -TenantId $tenantId)
    $sps      = @(Get-ServicePrincipals -TenantId $tenantId -SignInActivityMap $signInMap)
    $mis      = @(if (-not $EntraOnly) { Get-ManagedIdentities })
    $evidence = Get-AssessmentWorkloadEvidence
    foreach ($app in $appRegs) {
        $app | Add-Member -NotePropertyName CreationEvidence -NotePropertyValue (Get-AssessmentCreator $app.AppObjectId $evidence.CreationAudits)
    }
    foreach ($sp in $sps) {
        $sp | Add-Member -NotePropertyName CreationEvidence -NotePropertyValue (Get-AssessmentCreator $sp.SpObjectId $evidence.CreationAudits)
    }

    # ── Write CSVs ────────────────────────────────────────────────────────────
    $appCsvPath = Join-Path $OutputDir '02-inventory-app-registrations.csv'
    $spCsvPath  = Join-Path $OutputDir '02-inventory-service-principals.csv'
    $miCsvPath  = Join-Path $OutputDir '02-inventory-managed-identities.csv'

    $appRegs | Export-Csv -Path $appCsvPath -NoTypeInformation -Encoding UTF8
    $sps     | Export-Csv -Path $spCsvPath  -NoTypeInformation -Encoding UTF8
    if ($EntraOnly) {
        [pscustomobject]@{ Note = 'Not collected (Entra-only assessment)' } | Export-Csv -Path $miCsvPath -NoTypeInformation -Encoding UTF8
    } else {
        $mis | Export-Csv -Path $miCsvPath -NoTypeInformation -Encoding UTF8
    }

    # ── Write JSON ────────────────────────────────────────────────────────────
    $jsonResult = @{
        CollectedAt       = (Get-Date -Format 'o')
        SchemaVersion     = 2
        SignInActivity    = Get-AssessmentSignInActivity
        WorkloadEvidence  = $evidence
        AzureCollected    = -not $EntraOnly
        TenantId          = $tenantId
        appRegistrations  = @($appRegs)
        servicePrincipals = @($sps)
        managedIdentities = if ($EntraOnly) { $null } else { ,@($mis) }
    }
    $jsonPath = Join-Path $OutputDir '02-inventory.json'
    $jsonResult | ConvertTo-Json -Depth 30 | Out-File -FilePath $jsonPath -Encoding UTF8

    # ── Summary ───────────────────────────────────────────────────────────────
    $audienceCounts = $appRegs | Group-Object SignInAudience | Sort-Object Count -Descending
    $multiTenantApps = @($appRegs | Where-Object { $_.SignInAudience -notmatch '^single' }).Count
    $externalSPs = @($sps | Where-Object { $_.IsExternalApp }).Count
    $uaMiCount = @($mis | Where-Object { $_.IdentityType -eq 'UserAssigned' }).Count
    $saMiCount = @($mis | Where-Object { $_.IdentityType -eq 'SystemAssigned' }).Count
    $appsNoOwner = @($appRegs | Where-Object { $_.OwnerCount -eq 0 }).Count
    $appsSingleOwner = @($appRegs | Where-Object { $_.OwnerCount -eq 1 }).Count

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  02-inventory  SUMMARY" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  App registrations    : $($appRegs.Count)"
    Write-Host "  Service principals   : $($sps.Count)"
    Write-Host "    — Multi-tenant SPs (external apps) : $externalSPs"
    if ($EntraOnly) {
        Write-Host '  Managed identity resources: not collected (Entra only).'
    } else {
        Write-Host "  Managed identities   : $($mis.Count)"
        Write-Host "    — User-assigned    : $uaMiCount"
        Write-Host "    — System-assigned  : $saMiCount"
    }
    Write-Host ""
    Write-Host "  App reg sign-in audience breakdown:" -ForegroundColor White
    foreach ($g in $audienceCounts) {
        Write-Host "    $($g.Name.PadRight(25)) : $($g.Count)"
    }
    Write-Host ""
    Write-Host "  Multi-tenant app registrations : $multiTenantApps"
    Write-Host "  App regs with no owner         : $appsNoOwner"
    Write-Host "  App regs with single owner     : $appsSingleOwner"
    Write-Host ""
    Write-Host "  Output:"
    Write-Host "    $jsonPath"
    Write-Host "    $appCsvPath"
    Write-Host "    $spCsvPath"
    Write-Host "    $miCsvPath"
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
}

# ─── Entry point ─────────────────────────────────────────────────────────────
try {
    Invoke-Inventory -OutputDir $OutputDir
} catch {
    Write-Error "02-inventory failed: $_"
    exit 1
}
