<#
.SYNOPSIS
    Inventories the permission surface of all workload identities — both
    Microsoft Graph (and other) application permissions and Azure RBAC roles.

.DESCRIPTION
    Answers discovery questions:
      Q29/Q30 — Graph application permissions, privileged tier
      Q31/Q35 — Sub-scope Owner/Contributor/UAA on workload identities
      Q67     — Over-permissioned SPs
      Q69     — Azure RBAC scope distribution
      Q70     — Sub-Owner/Contributor on workload identities
      Q74     — App role assignments granted to SPs

    Prereq modules  : Microsoft.Graph.Authentication,
                      Microsoft.Graph.Applications,
                      Az.Accounts, Az.ResourceGraph, Az.Resources

    Prereq scopes   : Application.Read.All, Directory.Read.All

    Prereq Az roles : Reader (subscription-level)

    Produces:
      <OutputDir>/05-permission-surface.json
      <OutputDir>/05-permission-surface-graph.csv
      <OutputDir>/05-permission-surface-azure-rbac.csv

.EXAMPLE
    ./scripts/05-permission-surface.ps1 -OutputDir ./output/20260101-120000
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputDir = (Join-Path (Split-Path -Parent $PSScriptRoot) ('output/' + (Get-Date -Format 'yyyyMMdd-HHmmss')))
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# ─── Module prerequisite check ────────────────────────────────────────────────
$requiredModules = @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Applications', 'Microsoft.Graph.Identity.DirectoryManagement', 'Az.Accounts', 'Az.Resources', 'Az.ResourceGraph')
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


# ─── Privilege tiers ──────────────────────────────────────────────────────────
# Keys are Graph permission display names; values are tier labels
$privilegedPermissions = @{
    'Directory.ReadWrite.All'                   = 'PRIVILEGED'
    'RoleManagement.ReadWrite.Directory'        = 'PRIVILEGED'
    'Application.ReadWrite.All'                 = 'PRIVILEGED'
    'Application.ReadWrite.OwnedBy'             = 'PRIVILEGED'
    'AppRoleAssignment.ReadWrite.All'           = 'PRIVILEGED'
    'Policy.ReadWrite.ConditionalAccess'        = 'PRIVILEGED'
    'Mail.ReadWrite'                            = 'PRIVILEGED'
    'Mail.Send'                                 = 'PRIVILEGED'
    'Files.ReadWrite.All'                       = 'PRIVILEGED'
    'Sites.FullControl.All'                     = 'PRIVILEGED'
    'User.ReadWrite.All'                        = 'PRIVILEGED'
    'Group.ReadWrite.All'                       = 'PRIVILEGED'
    'GroupMember.ReadWrite.All'                 = 'PRIVILEGED'
    'DelegatedPermissionGrant.ReadWrite.All'    = 'PRIVILEGED'
    'Domain.ReadWrite.All'                      = 'PRIVILEGED'
    # Read-only but high recon value
    'Directory.Read.All'                        = 'PRIVILEGED_READ'
    'Application.Read.All'                      = 'PRIVILEGED_READ'
    'AuditLog.Read.All'                         = 'PRIVILEGED_READ'
    'IdentityRiskEvent.Read.All'                = 'PRIVILEGED_READ'
    'RoleManagement.Read.Directory'             = 'PRIVILEGED_READ'
    'User.Read.All'                             = 'PRIVILEGED_READ'
    'Group.Read.All'                            = 'PRIVILEGED_READ'
    'Mail.Read'                                 = 'PRIVILEGED_READ'
    'Files.Read.All'                            = 'PRIVILEGED_READ'
    'MailboxSettings.ReadWrite'                 = 'PRIVILEGED_READ'
    'Calendars.ReadWrite'                       = 'PRIVILEGED_READ'
    'Contacts.ReadWrite'                        = 'PRIVILEGED_READ'
}

$privilegedAzureRoles = @(
    'Owner'
    'Contributor'
    'User Access Administrator'
    'Role Based Access Control Administrator'
    'Key Vault Administrator'
    'Storage Account Contributor'
    'Storage Blob Data Owner'
    'Storage Blob Data Contributor'
)

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
    $required = @('Application.Read.All', 'Directory.Read.All')
    $mgCtx = Get-MgContext
    if ($null -eq $mgCtx) {
        Write-Error "No Microsoft Graph context. Run: Connect-MgGraph -Scopes 'Application.Read.All','Directory.Read.All'"
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
        Write-Host "    Connect-MgGraph -Scopes $allRequired" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  TIP: To cover all 10 toolkit scripts in one connect, use:" -ForegroundColor Yellow
        Write-Host "    Connect-MgGraph -Scopes Application.Read.All,Directory.Read.All,Policy.Read.All,RoleManagement.Read.Directory,AuditLog.Read.All,IdentityRiskEvent.Read.All,CrossTenantInformation.ReadBasic.All" -ForegroundColor Cyan
        Write-Host ""
        Write-Error "Missing Graph scopes: $($missing -join ', ')"
        exit 2
    }
}

function Get-ScopeLevel {
    param([string]$Scope)
    if (-not $Scope -or $Scope -eq '/') { return 'tenant' }
    $parts = $Scope.TrimStart('/').Split('/')
    if ($parts.Count -le 2 -and $parts[0] -eq 'providers') { return 'managementGroup' }
    if ($parts.Count -eq 4 -and $parts[0] -eq 'subscriptions' -and $parts.Count -eq 4) {
        if ($parts[2] -eq 'resourceGroups') { return 'resourceGroup' }
    }
    if ($parts.Count -eq 2 -and $parts[0] -eq 'subscriptions') { return 'subscription' }
    if ($parts.Count -gt 4) { return 'resource' }
    return 'other'
}

function Get-GraphPermissions {
    [CmdletBinding()]
    param()

    $graphRows = [System.Collections.Generic.List[PSObject]]::new()
    $graphAppId = '00000003-0000-0000-c000-000000000000'

    # Fetch Microsoft Graph SP once for permission name resolution
    Write-Host "  Fetching Microsoft Graph service principal..." -NoNewline
    $graphSp = Invoke-WithRetry {
        Get-MgServicePrincipal -Filter "appId eq '$graphAppId'" -Property 'id,appId,displayName,appRoles' -ErrorAction Stop |
            Select-Object -First 1
    }
    $appRoleMap = @{}  # id → value (permission name)
    foreach ($role in $graphSp.AppRoles) {
        $appRoleMap[$role.Id] = $role.Value
    }
    Write-Host " done ($($graphSp.AppRoles.Count) app roles indexed)." -ForegroundColor Green

    # Cache for all resource SP lookups
    $resourceSpCache = @{ $graphSp.Id = $graphSp }

    # Fetch all service principals (for context)
    Write-Host "  Fetching all service principals for permission mapping..." -NoNewline
    $allSps = Invoke-WithRetry {
        Get-MgServicePrincipal -All -Property 'id,appId,displayName,servicePrincipalType,appOwnerOrganizationId' -ErrorAction Stop
    }
    $spById    = @{}
    $spByAppId = @{}
    foreach ($sp in $allSps) {
        $spById[$sp.Id]       = $sp
        $spByAppId[$sp.AppId] = $sp
    }
    Write-Host " $($allSps.Count) SPs." -ForegroundColor Green

    # Fetch ALL service principal app role assignments in batch via Graph
    # servicePrincipalId is the principal that RECEIVED the permission
    Write-Host "  Fetching app role assignments (granted permissions)..." -NoNewline
    $allAssignments = [System.Collections.Generic.List[object]]::new()
    try {
        # Get all service principals that have been granted permissions
        # We iterate over a sample; for large tenants, use the /appRoleAssignments endpoint scoped to servicePrincipals
        $i = 0
        $spList = @($allSps | Where-Object { $_.ServicePrincipalType -eq 'Application' })
        foreach ($sp in $spList) {
            $i++
            if ($spList.Count -gt 50) {
                Write-Progress -Activity 'Fetching app role assignments' -Status "$i / $($spList.Count)" -PercentComplete (($i / $spList.Count) * 100)
            }
            try {
                $assignments = Invoke-WithRetry {
                    Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -All -ErrorAction Stop
                }
                foreach ($a in $assignments) {
                    $allAssignments.Add(@{
                        PrincipalId        = $sp.Id
                        PrincipalDisplayName = $sp.DisplayName
                        ResourceId         = $a.ResourceId
                        AppRoleId          = $a.AppRoleId
                    })
                }
            } catch {
                Write-Verbose "Could not get assignments for SP $($sp.Id): $_"
            }
        }
        if ($spList.Count -gt 50) { Write-Progress -Activity 'Fetching app role assignments' -Completed }
        Write-Host " $($allAssignments.Count) grants found." -ForegroundColor Green
    } catch {
        Write-Warning "Failed to enumerate app role assignments: $_"
    }

    # Resolve each assignment
    foreach ($a in $allAssignments) {
        $resourceSp = $null
        if ($resourceSpCache.ContainsKey($a.ResourceId)) {
            $resourceSp = $resourceSpCache[$a.ResourceId]
        } else {
            try {
                $resourceSp = Invoke-WithRetry {
                    Get-MgServicePrincipal -ServicePrincipalId $a.ResourceId -Property 'id,appId,displayName,appRoles' -ErrorAction Stop
                }
                $resourceSpCache[$a.ResourceId] = $resourceSp
            } catch {
                Write-Verbose "Could not resolve resource SP $($a.ResourceId): $_"
            }
        }

        $permValue = $null
        $permDisplayName = $null
        if ($resourceSp) {
            $matchingRole = $resourceSp.AppRoles | Where-Object { $_.Id -eq $a.AppRoleId } | Select-Object -First 1
            if ($matchingRole) {
                $permValue = $matchingRole.Value
                $permDisplayName = $matchingRole.DisplayName
            }
        }

        # Determine tier
        $tier = 'STANDARD'
        if ($permValue -and $privilegedPermissions.ContainsKey($permValue)) {
            $tier = $privilegedPermissions[$permValue]
        }

        $graphRows.Add([PSCustomObject]@{
            SpObjectId           = $a.PrincipalId
            SpDisplayName        = $a.PrincipalDisplayName
            ResourceAppId        = if ($resourceSp) { $resourceSp.AppId } else { $null }
            ResourceDisplayName  = if ($resourceSp) { $resourceSp.DisplayName } else { $null }
            PermissionValue      = $permValue
            PermissionDisplayName = $permDisplayName
            Tier                 = $tier
        })
    }

    return $graphRows
}

function Get-AzureRbacAssignments {
    [CmdletBinding()]
    param()

    $rbacRows = [System.Collections.Generic.List[PSObject]]::new()

    Write-Host "  Fetching Azure RBAC assignments for service principals via Resource Graph..." -NoNewline
    try {
        # Resource Graph query for role assignments to service principals
        $query = @"
authorizationresources
| where type =~ 'microsoft.authorization/roleassignments'
| where properties.principalType =~ 'ServicePrincipal'
| project
    principalId     = properties.principalId,
    roleDefinitionId = properties.roleDefinitionId,
    scope           = properties.scope,
    createdOn       = properties.createdOn
| order by principalId asc
"@
        $assignments = Invoke-WithRetry { Search-AzGraph -Query $query -First 5000 -ErrorAction Stop }
        Write-Host " $($assignments.Count) RBAC assignments." -ForegroundColor Green

        # Cache role definitions
        $roleDefCache = @{}
        # Cache SP display names
        $spDisplayCache = @{}

        $i = 0
        foreach ($a in $assignments) {
            $i++
            if ($assignments.Count -gt 50) {
                Write-Progress -Activity 'Resolving RBAC assignments' -Status "$i / $($assignments.Count)" -PercentComplete (($i / $assignments.Count) * 100)
            }

            # Resolve role definition name
            $roleName = 'Unknown'
            $roleDefIdShort = $a.roleDefinitionId -replace '.*/roleDefinitions/', ''
            if ($roleDefCache.ContainsKey($roleDefIdShort)) {
                $roleName = $roleDefCache[$roleDefIdShort]
            } else {
                try {
                    $roleDef = Invoke-WithRetry { Get-AzRoleDefinition -Id $roleDefIdShort -ErrorAction Stop }
                    $roleName = $roleDef.Name
                    $roleDefCache[$roleDefIdShort] = $roleName
                } catch {
                    Write-Verbose "Could not resolve role def ${roleDefIdShort}: $_"
                }
            }

            # Resolve SP display name
            $spName = 'Unknown'
            if ($spDisplayCache.ContainsKey($a.principalId)) {
                $spName = $spDisplayCache[$a.principalId]
            } else {
                try {
                    $sp = Invoke-WithRetry { Get-MgServicePrincipal -ServicePrincipalId $a.principalId -Property 'id,displayName' -ErrorAction Stop }
                    $spName = $sp.DisplayName
                    $spDisplayCache[$a.principalId] = $spName
                } catch {
                    $spDisplayCache[$a.principalId] = 'Unknown'
                }
            }

            $scopeLevel = Get-ScopeLevel -Scope $a.scope
            $isPrivileged = ($roleName -in $privilegedAzureRoles)

            $rbacRows.Add([PSCustomObject]@{
                PrincipalId          = $a.principalId
                PrincipalDisplayName = $spName
                RoleName             = $roleName
                RoleDefinitionId     = $roleDefIdShort
                Scope                = $a.scope
                ScopeLevel           = $scopeLevel
                CreatedOn            = $a.createdOn
                IsPrivilegedRole     = $isPrivileged
            })
        }
        if ($assignments.Count -gt 50) { Write-Progress -Activity 'Resolving RBAC assignments' -Completed }
    } catch {
        Write-Warning "Could not enumerate Azure RBAC assignments: $_"
    }

    return $rbacRows
}

function Invoke-PermissionSurface {
    [CmdletBinding()]
    param([string]$OutputDir)

    Assert-Contexts

    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  05-permission-surface  |  Analysing permissions..." -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""

    $graphRows = Get-GraphPermissions
    $rbacRows  = Get-AzureRbacAssignments

    # ── Write CSVs ────────────────────────────────────────────────────────────
    $graphCsvPath = Join-Path $OutputDir '05-permission-surface-graph.csv'
    $rbacCsvPath  = Join-Path $OutputDir '05-permission-surface-azure-rbac.csv'

    if ($graphRows.Count -gt 0) {
        $graphRows | Export-Csv -Path $graphCsvPath -NoTypeInformation -Encoding UTF8
    } else {
        [PSCustomObject]@{ Note = 'No app role assignments found' } | Export-Csv -Path $graphCsvPath -NoTypeInformation -Encoding UTF8
    }

    if ($rbacRows.Count -gt 0) {
        $rbacRows | Export-Csv -Path $rbacCsvPath -NoTypeInformation -Encoding UTF8
    } else {
        [PSCustomObject]@{ Note = 'No RBAC assignments found' } | Export-Csv -Path $rbacCsvPath -NoTypeInformation -Encoding UTF8
    }

    # ── Write JSON ────────────────────────────────────────────────────────────
    $jsonResult = @{
        CollectedAt       = (Get-Date -Format 'o')
        GraphPermissions  = @($graphRows)
        AzureRbac         = @($rbacRows)
    }
    $jsonPath = Join-Path $OutputDir '05-permission-surface.json'
    $jsonResult | ConvertTo-Json -Depth 6 | Out-File -FilePath $jsonPath -Encoding UTF8

    # ── Summary calculations ──────────────────────────────────────────────────
    $privilegedSps   = @($graphRows | Where-Object { $_.Tier -eq 'PRIVILEGED' }   | Select-Object -ExpandProperty SpObjectId -Unique)
    $privilegedReadSps = @($graphRows | Where-Object { $_.Tier -eq 'PRIVILEGED_READ' } | Select-Object -ExpandProperty SpObjectId -Unique)

    $perSpCounts = $graphRows | Group-Object SpObjectId | Sort-Object Count -Descending
    $top10 = $perSpCounts | Select-Object -First 10

    $rbacPrivileged     = @($rbacRows | Where-Object { $_.IsPrivilegedRole })
    $mgmtGroupRbac      = @($rbacRows | Where-Object { $_.ScopeLevel -eq 'managementGroup' })
    $subOwners          = @($rbacRows | Where-Object { $_.RoleName -eq 'Owner' -and $_.ScopeLevel -eq 'subscription' })
    $subContributors    = @($rbacRows | Where-Object { $_.RoleName -eq 'Contributor' -and $_.ScopeLevel -eq 'subscription' })
    $uaaAssignments     = @($rbacRows | Where-Object { $_.RoleName -eq 'User Access Administrator' })

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  05-permission-surface  SUMMARY" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Graph Application Permissions:" -ForegroundColor White
    Write-Host "    Total app role grants          : $($graphRows.Count)"
    $privColor = if ($privilegedSps.Count -gt 0) { 'Red' } else { 'Green' }
    Write-Host "    SPs with PRIVILEGED grants     : $($privilegedSps.Count)" -ForegroundColor $privColor
    Write-Host "    SPs with PRIVILEGED_READ grants: $($privilegedReadSps.Count)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Top 10 most-permissioned SPs (by grant count):" -ForegroundColor White
    foreach ($sp in $top10) {
        $spName = ($graphRows | Where-Object { $_.SpObjectId -eq $sp.Name } | Select-Object -First 1).SpDisplayName
        Write-Host "    $($spName.PadRight(45)) : $($sp.Count) grants"
    }
    Write-Host ""
    Write-Host "  Azure RBAC:" -ForegroundColor White
    Write-Host "    Total SP role assignments      : $($rbacRows.Count)"
    $privRbacColor = if ($rbacPrivileged.Count -gt 0) { 'Red' } else { 'Green' }
    Write-Host "    Privileged role assignments    : $($rbacPrivileged.Count)" -ForegroundColor $privRbacColor
    Write-Host "    Sub-scope Owner assignments    : $($subOwners.Count)"
    Write-Host "    Sub-scope Contributor          : $($subContributors.Count)"
    Write-Host "    User Access Administrator      : $($uaaAssignments.Count)"
    $mgmtColor = if ($mgmtGroupRbac.Count -gt 0) { 'Red' } else { 'Green' }
    Write-Host "    Management-group-scope roles   : $($mgmtGroupRbac.Count)" -ForegroundColor $mgmtColor
    Write-Host ""
    Write-Host "  Output:"
    Write-Host "    $jsonPath"
    Write-Host "    $graphCsvPath"
    Write-Host "    $rbacCsvPath"
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
}

# ─── Entry point ─────────────────────────────────────────────────────────────
try {
    Invoke-PermissionSurface -OutputDir $OutputDir
} catch {
    Write-Error "05-permission-surface failed: $_"
    exit 1
}
