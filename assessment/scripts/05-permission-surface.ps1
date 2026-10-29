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

.PARAMETER EntraOnly
    Collect directory permissions without Azure modules, authentication or RBAC discovery.

.EXAMPLE
    ./scripts/05-permission-surface.ps1 -OutputDir ./output/20260101-120000
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
Import-Module (Join-Path $PSScriptRoot 'Assessment.Controls.psm1') -Force -ErrorAction Stop

# ─── Module prerequisite check ────────────────────────────────────────────────
$requiredModules = @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Applications', 'Microsoft.Graph.Identity.DirectoryManagement', 'Az.Accounts', 'Az.Resources', 'Az.ResourceGraph')
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
    Assert-AssessmentContexts -RequireAzure:(-not $EntraOnly)
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
        Write-Host "    Connect-MgGraph -TenantId '<assessment-tenant-id>' -Scopes $allRequired" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  TIP: To cover all 10 toolkit scripts in one connect, use:" -ForegroundColor Yellow
        Write-Host "    Connect-MgGraph -TenantId '<assessment-tenant-id>' -Scopes Application.Read.All,Directory.Read.All,Policy.Read.All,RoleManagement.Read.Directory,AuditLog.Read.All,IdentityRiskEvent.Read.All,CrossTenantInformation.ReadBasic.All" -ForegroundColor Cyan
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
    $allSps = @(Get-AssessmentDirectoryData -Resource servicePrincipals -Relationship appRoleAssignments)

    # Fetch Microsoft Graph SP once for permission name resolution
    Write-Host "  Fetching Microsoft Graph service principal..." -NoNewline
    $graphSp = $allSps | Where-Object AppId -eq $graphAppId | Select-Object -First 1
    if (-not $graphSp) { throw 'Microsoft Graph service principal is missing from the directory export.' }
    Write-Host " done ($($graphSp.AppRoles.Count) app roles)." -ForegroundColor Green

    # Cache for all resource SP lookups
    $resourceSpCache = @{}

    # Fetch all service principals (for context)
    Write-Host "  Fetching all service principals for permission mapping..." -NoNewline
    foreach ($sp in $allSps) {
        if (-not $sp.Id) { throw 'A service principal has no object ID; permission mapping is incomplete.' }
        $resourceSpCache[$sp.Id] = $sp
    }
    Write-Host " $($allSps.Count) SPs." -ForegroundColor Green

    # Expanded assignments are already complete and paged by the shared reader.
    # servicePrincipalId is the principal that RECEIVED the permission
    Write-Host "  Fetching app role assignments (granted permissions)..." -NoNewline
    $allAssignments = [System.Collections.Generic.List[object]]::new()
    try {
        $i = 0
        $spList = @($allSps | Where-Object { $_.ServicePrincipalType -in @('Application','ManagedIdentity','ServiceIdentity') })
        foreach ($sp in $spList) {
            $i++
            if ($spList.Count -gt 50 -and ($i -eq 1 -or $i % 250 -eq 0)) {
                Write-Progress -Activity 'Fetching app role assignments' -Status "$i / $($spList.Count)" -PercentComplete (($i / $spList.Count) * 100)
            }
            try {
                $assignments = @($sp.appRoleAssignments | Where-Object { $null -ne $_ })
                foreach ($a in $assignments) {
                    $allAssignments.Add(@{
                        PrincipalId        = $sp.Id
                        PrincipalDisplayName = $sp.DisplayName
                        ResourceId         = $a.ResourceId
                        AppRoleId          = $a.AppRoleId
                        AssignmentId       = $a.Id
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
    $unresolvedCount = 0
    foreach ($a in $allAssignments) {
        $resourceSp = $null
        if ($a.ResourceId -and $resourceSpCache.ContainsKey($a.ResourceId)) {
            $resourceSp = $resourceSpCache[$a.ResourceId]
        } elseif ($a.ResourceId) {
            try {
                $resourceSp = Invoke-WithRetry {
                    Get-MgServicePrincipal -ServicePrincipalId $a.ResourceId -Property 'id,appId,displayName,appRoles' -ErrorAction Stop
                }
                $resourceSpCache[$a.ResourceId] = $resourceSp
            } catch {
                Write-Warning "Could not resolve resource SP $($a.ResourceId): $_"
            }
        }

        $permValue = $null
        $permDisplayName = $null
        $matchingRole = $null
        if ($resourceSp -and $a.AppRoleId) {
            $matchingRole = $resourceSp.AppRoles | Where-Object { $_.Id -eq $a.AppRoleId } | Select-Object -First 1
            if ($matchingRole) {
                $permValue = $matchingRole.Value
                $permDisplayName = $matchingRole.DisplayName
            }
        }

        if (-not $permValue) { $unresolvedCount++ }

        $graphRows.Add([PSCustomObject]@{
            SpObjectId           = $a.PrincipalId
            SpDisplayName        = $a.PrincipalDisplayName
            AssignmentId         = $a.AssignmentId
            ResourceObjectId     = $a.ResourceId
            AppRoleId            = $a.AppRoleId
            ResolutionStatus     = if ($permValue) { 'Resolved' } else { 'Unresolved' }
            ResourceAppId        = if ($resourceSp) { $resourceSp.AppId } else { $null }
            ResourceDisplayName  = if ($resourceSp) { $resourceSp.DisplayName } else { $null }
            PermissionValue      = $permValue
            PermissionDisplayName = $permDisplayName
            Description          = if ($matchingRole) { $matchingRole.Description } else { $null }
            PermissionType       = 'Application'
            AdminConsentRequired = $true
            ConsentStatus        = 'Granted application access'
            GrantState           = 'Granted'
        })
    }
    if ($unresolvedCount -gt 0) {
        Write-Warning "$unresolvedCount app role assignment(s) could not be resolved. They remain in the export with Tier=UNKNOWN and their available IDs."
    }

    Set-WorkloadPermissionRisk -Rows $graphRows.ToArray()
    return $graphRows
}

function Get-NormalizedPermissions {
    param([object[]]$ApplicationGrants)
    $apps = @(Get-AssessmentDirectoryData -Resource applications -Relationship owners)
    $sps = @(Get-AssessmentDirectoryData -Resource servicePrincipals -Relationship appRoleAssignments)
    $resources = @{}; $clients = @{}; $appByClient = @{}
    foreach ($sp in $sps) { if ($sp.Id) { $resources[$sp.Id] = $sp }; if ($sp.AppId) { $clients[$sp.AppId] = $sp } }
    foreach ($app in $apps) { if ($app.AppId) { $appByClient[$app.AppId] = $app } }
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($grant in $ApplicationGrants) { $result.Add($grant) }
    $delegated = Get-AssessmentEvidence -Path 'oauth2PermissionGrants'
    foreach ($grant in $delegated.Records) {
        $client = if ($grant.clientId) { $resources[$grant.clientId] } else { $null }
        $resource = if ($grant.resourceId) { $resources[$grant.resourceId] } else { $null }
        $scopes = @($grant.scope -split ' ' | Where-Object { $_ })
        if (-not $scopes.Count) { $scopes = @('Unresolved (empty scope)') }
        foreach ($scope in $scopes) {
            $definition = $resource.Oauth2PermissionScopes | Where-Object Value -eq $scope | Select-Object -First 1
            $result.Add([pscustomobject]@{
                SpObjectId = $grant.clientId; SpDisplayName = $client.DisplayName
                AssignmentId = $grant.id; ResourceObjectId = $grant.resourceId
                ResourceAppId = $resource.AppId; ResourceDisplayName = $resource.DisplayName
                AppRoleId = $definition.Id; PermissionValue = $scope
                Description = $definition.AdminConsentDescription; PermissionDisplayName = $definition.AdminConsentDisplayName
                PermissionType = 'Delegated'; AdminConsentRequired = if ($definition) { $definition.Type -eq 'Admin' } else { $null }
                ConsentStatus = switch ($grant.consentType) { 'AllPrincipals' { 'Granted tenant-wide admin consent' }; 'Principal' { 'Granted to a specific user' }; default { 'Unknown consent scope' } }
                ConsentScope = $grant.consentType; ConsentPrincipalId = $grant.principalId; GrantState = 'Granted'
                ResolutionStatus = if ($definition) { 'Resolved' } else { 'Unresolved' }
            })
        }
    }
    $configured = @{}
    foreach ($app in $apps) {
        foreach ($api in $app.RequiredResourceAccess) {
            $resource = $sps | Where-Object AppId -eq $api.ResourceAppId | Select-Object -First 1
            foreach ($permission in $api.ResourceAccess) {
                $type = if ($permission.Type -eq 'Role') { 'Application' } else { 'Delegated' }
                $key = "$($app.AppId)|$($api.ResourceAppId)|$type|$($permission.Id)"
                $configured[$key] = $true
                $client = if ($app.AppId) { $clients[$app.AppId] } else { $null }
                if ($client.Id -and @($result | Where-Object { $_.SpObjectId -eq $client.Id -and $_.ResourceAppId -eq $api.ResourceAppId -and $_.PermissionType -eq $type -and $_.AppRoleId -eq $permission.Id }).Count) { continue }
                $definition = if ($type -eq 'Application') { $resource.AppRoles | Where-Object Id -eq $permission.Id | Select-Object -First 1 } else {
                    $resource.Oauth2PermissionScopes | Where-Object Id -eq $permission.Id | Select-Object -First 1
                }
                $result.Add([pscustomobject]@{
                    SpObjectId = $client.Id; AppObjectId = $app.Id; AppId = $app.AppId; SpDisplayName = $app.DisplayName
                    ResourceAppId = $api.ResourceAppId; ResourceDisplayName = $resource.DisplayName; AppRoleId = $permission.Id
                    PermissionValue = $definition.Value; Description = if ($type -eq 'Application') { $definition.Description } else { $definition.AdminConsentDescription }
                    PermissionType = $type; AdminConsentRequired = if ($type -eq 'Application') { $true } elseif ($definition) { $definition.Type -eq 'Admin' } else { $null }
                    GrantState = if ($type -eq 'Delegated' -and $delegated.State -ne 'Available') { 'Unknown (grant collection unavailable)' } else { 'Not granted' }
                    ConsentStatus = if ($type -eq 'Delegated' -and $delegated.State -ne 'Available') { 'Unknown' } else { 'Not granted in snapshot' }
                    ConfiguredState = 'Configured'; Tier = 'Not a granted permission'
                })
            }
        }
    }
    foreach ($row in $result) {
        if ($row.PSObject.Properties['ConfiguredState']) { continue }
        $client = if ($row.SpObjectId) { $resources[$row.SpObjectId] } else { $null }
        $row | Add-Member -NotePropertyName AppId -NotePropertyValue $client.AppId -Force
        $key = "$($client.AppId)|$($row.ResourceAppId)|$($row.PermissionType)|$($row.AppRoleId)"
        $state = if (-not $client.AppId -or -not $appByClient.ContainsKey($client.AppId)) { 'Configuration unavailable' } elseif ($configured.ContainsKey($key)) { 'Configured' } else { 'Granted but not configured' }
        $row | Add-Member -NotePropertyName ConfiguredState -NotePropertyValue $state -Force
    }
    Set-WorkloadPermissionRisk -Rows $result.ToArray()
    return [pscustomobject]@{ Rows = $result.ToArray(); DelegatedEvidence = $delegated }
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
                ReviewRequired       = $isPrivileged
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

    $graphRows = @(Get-GraphPermissions)
    $normalized = Get-NormalizedPermissions -ApplicationGrants $graphRows
    $rbacRows  = @(if (-not $EntraOnly) { Get-AzureRbacAssignments })

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
        [PSCustomObject]@{ Note = $(if ($EntraOnly) { 'Not collected (Entra-only assessment)' } else { 'No RBAC assignments found' }) } | Export-Csv -Path $rbacCsvPath -NoTypeInformation -Encoding UTF8
    }

    # ── Write JSON ────────────────────────────────────────────────────────────
    $jsonResult = @{
        CollectedAt       = (Get-Date -Format 'o')
        AzureCollected    = -not $EntraOnly
        GraphPermissions  = @($graphRows)
        NormalizedPermissions = @($normalized.Rows)
        DelegatedGrantEvidence = $normalized.DelegatedEvidence
        SchemaVersion = 2
        AzureRbac         = if ($EntraOnly) { $null } else { ,@($rbacRows) }
    }
    $jsonPath = Join-Path $OutputDir '05-permission-surface.json'
    $jsonResult | ConvertTo-Json -Depth 6 | Out-File -FilePath $jsonPath -Encoding UTF8

    # ── Summary calculations ──────────────────────────────────────────────────
    $actualPermissions = @($normalized.Rows | Where-Object GrantState -eq 'Granted')
    $privilegedSps   = @($actualPermissions | Where-Object { $_.Tier -eq 'PRIVILEGED' }   | Select-Object -ExpandProperty SpObjectId -Unique)
    $privilegedReadSps = @($actualPermissions | Where-Object { $_.Tier -eq 'PRIVILEGED_READ' } | Select-Object -ExpandProperty SpObjectId -Unique)
    $unclassifiedGrants = @($actualPermissions | Where-Object { $_.Tier -in @('UNCLASSIFIED','UNKNOWN') })

    $perSpCounts = $actualPermissions | Group-Object SpObjectId | Sort-Object Count -Descending
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
    Write-Host "  API permissions (application and delegated):" -ForegroundColor White
    Write-Host "    Total granted permission rows : $($actualPermissions.Count)"
    $privColor = if ($privilegedSps.Count -gt 0) { 'Red' } else { 'Green' }
    Write-Host "    SPs with PRIVILEGED grants     : $($privilegedSps.Count)" -ForegroundColor $privColor
    Write-Host "    SPs with PRIVILEGED_READ grants: $($privilegedReadSps.Count)" -ForegroundColor Yellow
    Write-Host "    Unclassified/unresolved grants : $($unclassifiedGrants.Count) (review required)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Top 10 most-permissioned SPs (by grant count):" -ForegroundColor White
    foreach ($sp in $top10) {
        $spName = ($actualPermissions | Where-Object { $_.SpObjectId -eq $sp.Name } | Select-Object -First 1).SpDisplayName
        if (-not $spName) { $spName = "Unresolved principal ($($sp.Name))" }
        Write-Host "    $($spName.PadRight(45)) : $($sp.Count) grants"
    }
    Write-Host ""
    if ($EntraOnly) {
        Write-Host '  Azure RBAC: not collected (Entra only).' -ForegroundColor Gray
    } else {
        Write-Host "  Azure RBAC:" -ForegroundColor White
        Write-Host "    Total SP role assignments      : $($rbacRows.Count)"
        $privRbacColor = if ($rbacPrivileged.Count -gt 0) { 'Red' } else { 'Green' }
        Write-Host "    Privileged role assignments    : $($rbacPrivileged.Count)" -ForegroundColor $privRbacColor
        Write-Host "    Sub-scope Owner assignments    : $($subOwners.Count)"
        Write-Host "    Sub-scope Contributor          : $($subContributors.Count)"
        Write-Host "    User Access Administrator      : $($uaaAssignments.Count)"
        $mgmtColor = if ($mgmtGroupRbac.Count -gt 0) { 'Red' } else { 'Green' }
        Write-Host "    Management-group-scope roles   : $($mgmtGroupRbac.Count)" -ForegroundColor $mgmtColor
    }
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
