<#
.SYNOPSIS
    Captures tenant context, licensing, authorization policy, and role membership
    for the Workload Identity Assessment.

.DESCRIPTION
    Answers discovery questions:
      Q9  — Application Admin / Cloud App Admin role member counts
      Q10 — "Users can register applications" authorization policy setting
      Q11 — Admin consent workflow enabled
      Q25 — Subscriptions in scope (from Az context)
      Q27 — Subscriptions in scope
      Q72 — Custom Entra roles count
      Q75 — Cross-tenant access settings
      Q83 — Workload Identities Premium license present
      Q84 — Identity Protection enabled for workload identities

    Prereq modules : Microsoft.Graph.Authentication,
                     Microsoft.Graph.Identity.DirectoryManagement,
                     Microsoft.Graph.Identity.SignIns,
                     Az.Accounts

    Prereq Graph scopes : Directory.Read.All, Policy.Read.All,
                          RoleManagement.Read.Directory,
                          IdentityRiskEvent.Read.All,
                          CrossTenantInformation.ReadBasic.All

    Prereq Azure roles  : Reader (subscription-level, for Get-AzSubscription)

    Produces:
      <OutputDir>/01-tenant-context.json
      <OutputDir>/01-tenant-context.csv

.EXAMPLE
    ./scripts/01-tenant-context.ps1 -OutputDir ./output/20260101-120000
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputDir = (Join-Path (Split-Path -Parent $PSScriptRoot) ('output/' + (Get-Date -Format 'yyyyMMdd-HHmmss')))
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# ─── Module prerequisite check ────────────────────────────────────────────────
$requiredModules = @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Identity.DirectoryManagement', 'Microsoft.Graph.Identity.SignIns', 'Microsoft.Graph.Identity.Governance', 'Az.Accounts', 'Az.Resources')
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


# ─── Role template IDs (stable across tenants) ───────────────────────────────
$roleTemplateIds = @{
    'GlobalAdministrator'             = '62e90394-69f5-4237-9190-012177145e10'
    'ApplicationAdministrator'        = '9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3'
    'CloudApplicationAdministrator'   = '158c047a-c907-4556-b7ef-446551a6b5f7'
    'ApplicationDeveloper'            = 'cf1c38e5-3621-4004-a7cb-879624dced7c'
}

# ─── SKU codes to check (direct SKU presence) ────────────────────────────────
$licensesOfInterest = @{
    'WORKLOAD_IDENTITIES_PREMIUM'   = 'Workload Identities Premium (CA for WI + Risky WI)'
    'AAD_PREMIUM_P2'                = 'Entra ID P2 (Identity Protection + PIM) — standalone SKU'
    'ENTRA_ID_GOVERNANCE'           = 'Entra ID Governance (Access Reviews + Lifecycle Workflows)'
    'AAD_PREMIUM'                   = 'Entra ID P1 (Conditional Access for users) — standalone SKU'
    'MICROSOFT_IDENTITY_PLATFORM'   = 'Microsoft Identity Platform'
}

# ─── Service-plan IDs (the actual feature flags — present inside bundles like M365 E5/E3, EMS, etc.) ──
$servicePlansOfInterest = @{
    'AAD_PREMIUM'                  = @{ Id = '41781fb2-bc02-4b7c-bd55-b576c07bb09d'; Description = 'Entra ID P1 (CA, group-based licensing, dynamic groups, SSPR with writeback)' }
    'AAD_PREMIUM_P2'               = @{ Id = 'eec0eb4f-6444-4f95-aba0-50c24d67f998'; Description = 'Entra ID P2 (PIM, Identity Protection, Access Reviews — basic, Entitlement Management v1)' }
    'AAD_GOVERNANCE'               = @{ Id = 'e866a266-3cff-43a3-acca-0c90a7e00c8b'; Description = 'Entra ID Governance ADD-ON (Lifecycle Workflows, Entitlement Management v2, ML recommendations, separation-of-duties)' }
    'WORKLOAD_IDENTITIES_PREMIUM'  = @{ Id = 'a9c6ed4c-d63f-4583-9bc4-cd60150e9d61'; Description = 'Workload Identities Premium ADD-ON (CA for workload identities, Risky Workload Identities)' }
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
        try {
            return & $ScriptBlock
        } catch {
            $statusCode = $null
            $exc = $_.Exception
            if ($exc.PSObject.Properties.Name -contains 'Response' -and $exc.Response -and $exc.Response.PSObject.Properties.Name -contains 'StatusCode') {
                $statusCode = [int]$exc.Response.StatusCode
            } elseif ($exc.Message -match '(429|503|504)') { $statusCode = [int]($Matches[1]) }

            if ($attempt -ge $MaxAttempts -or ($statusCode -notin @(429, 503, 504))) {
                throw
            }
            $delay = $BaseDelaySeconds * [Math]::Pow(2, $attempt - 1)
            Write-Verbose "Attempt $attempt failed (HTTP $statusCode). Retrying in ${delay}s..."
            Start-Sleep -Seconds $delay
        }
    }
}

function Assert-GraphContext {
    try {
        $required = @('Directory.Read.All', 'Policy.Read.All', 'RoleManagement.Read.Directory')
        $ctx = Get-MgContext
        if ($null -eq $ctx) {
            Write-Host ""
            Write-Host "  ✗ NOT CONNECTED TO MICROSOFT GRAPH" -ForegroundColor Red
            Write-Host ""
            Write-Host "  Connect with the required scopes for this script:" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "    Connect-MgGraph -Scopes $($required -join ',')" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "  TIP: To cover all 10 toolkit scripts in one connect, use:" -ForegroundColor Yellow
            Write-Host "    Connect-MgGraph -Scopes Application.Read.All,Directory.Read.All,Policy.Read.All,RoleManagement.Read.Directory,AuditLog.Read.All,IdentityRiskEvent.Read.All,CrossTenantInformation.ReadBasic.All" -ForegroundColor Cyan
            Write-Host ""
            Write-Error "Not connected to Microsoft Graph"
            exit 2
        }
        $missing = @($required | Where-Object { $_ -notin $ctx.Scopes })
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
        return $ctx
    } catch {
        Write-Error "Failed to verify Graph context: $_"
        exit 2
    }
}

function Get-RoleMemberCount {
    [CmdletBinding()]
    param([string]$TemplateId, [string]$RoleName)

    try {
        # Find the instantiated role by its template ID
        $role = Invoke-WithRetry { Get-MgDirectoryRole -Filter "roleTemplateId eq '$TemplateId'" -ErrorAction SilentlyContinue }
        if ($null -eq $role) {
            Write-Verbose "Role '$RoleName' (template $TemplateId) not instantiated in this tenant."
            return @{ RoleName = $RoleName; TemplateId = $TemplateId; MemberCount = 0; Members = @() }
        }

        $members = Invoke-WithRetry {
            Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id -All |
                Select-Object -Property Id, @{N='OdataType';E={$_.'AdditionalProperties'.'@odata.type'}}
        }

        return @{
            RoleName    = $RoleName
            TemplateId  = $TemplateId
            RoleId      = $role.Id
            MemberCount = $members.Count
            Members     = @($members | ForEach-Object { @{ Id = $_.Id; OdataType = $_.OdataType } })
        }
    } catch {
        Write-Warning "Could not fetch role members for '$RoleName': $_"
        return @{ RoleName = $RoleName; TemplateId = $TemplateId; MemberCount = -1; Members = @() }
    }
}

function Invoke-TenantContext {
    [CmdletBinding()]
    param([string]$OutputDir)

    # ── Validate contexts ─────────────────────────────────────────────────────
    $ctx = Assert-GraphContext

    # ── Prepare output dir ────────────────────────────────────────────────────
    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  01-tenant-context  |  Collecting tenant information..." -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""

    # ── 1. Organization / Tenant info ─────────────────────────────────────────
    Write-Host "  Fetching organization info..." -NoNewline
    $org = Invoke-WithRetry {
        Get-MgOrganization -Property 'id,displayName,verifiedDomains,createdDateTime,tenantType,onPremisesSyncEnabled' |
            Select-Object -First 1
    }
    $primaryDomain = ($org.VerifiedDomains | Where-Object { $_.IsDefault } | Select-Object -First 1).Name
    if (-not $primaryDomain) {
        $primaryDomain = ($org.VerifiedDomains | Select-Object -First 1).Name
    }
    Write-Host " done." -ForegroundColor Green

    $tenantInfo = @{
        TenantId            = $org.Id
        DisplayName         = $org.DisplayName
        PrimaryDomain       = $primaryDomain
        VerifiedDomains     = @($org.VerifiedDomains | ForEach-Object { $_.Name })
        CreatedDateTime     = $org.CreatedDateTime
        OnPremisesSyncEnabled = $org.OnPremisesSyncEnabled
    }

    # ── 2. Licenses ───────────────────────────────────────────────────────────
    Write-Host "  Fetching license SKUs..." -NoNewline
    $allSkus = Invoke-WithRetry { Get-MgSubscribedSku -All -Property 'skuPartNumber,skuId,capabilityStatus,consumedUnits,prepaidUnits,servicePlans' }

    $licenseInventory = @($allSkus | ForEach-Object {
        @{
            SkuPartNumber   = $_.SkuPartNumber
            SkuId           = $_.SkuId
            CapabilityStatus = $_.CapabilityStatus
            ConsumedUnits   = $_.ConsumedUnits
            EnabledUnits    = $_.PrepaidUnits.Enabled
        }
    })

    # Direct-SKU presence check (legacy)
    $licenseFlags = @{}
    foreach ($key in $licensesOfInterest.Keys) {
        $found = $allSkus | Where-Object { $_.SkuPartNumber -eq $key -and $_.CapabilityStatus -eq 'Enabled' }
        $licenseFlags[$key] = @{
            Description = $licensesOfInterest[$key]
            Present     = ($null -ne $found)
            Status      = if ($found) { $found.CapabilityStatus } else { 'NotPresent' }
        }
    }

    # Service-plan capability check (covers bundles: M365 E3/E5, EMS E3/E5, Business Premium, etc.)
    $capabilityFlags = @{}
    foreach ($capName in $servicePlansOfInterest.Keys) {
        $spId = $servicePlansOfInterest[$capName].Id
        $providingSkus = @()
        foreach ($sku in $allSkus) {
            if ($sku.CapabilityStatus -ne 'Enabled') { continue }
            $matchingPlan = $sku.ServicePlans | Where-Object { $_.ServicePlanId -eq $spId -and $_.ProvisioningStatus -eq 'Success' }
            if ($matchingPlan) {
                $providingSkus += [PSCustomObject]@{
                    SkuPartNumber = $sku.SkuPartNumber
                    ConsumedUnits = $sku.ConsumedUnits
                    EnabledUnits  = $sku.PrepaidUnits.Enabled
                }
            }
        }
        $capabilityFlags[$capName] = @{
            Description    = $servicePlansOfInterest[$capName].Description
            Available      = ($providingSkus.Count -gt 0)
            ProvidedBySkus = $providingSkus
            TotalUnits     = ($providingSkus | Measure-Object -Property EnabledUnits -Sum).Sum
        }
    }
    Write-Host " done." -ForegroundColor Green

    # ── 3. Authorization policy ───────────────────────────────────────────────
    Write-Host "  Fetching authorization policy..." -NoNewline
    $authPolicy = $null
    try {
        $authPolicy = Invoke-WithRetry { Get-MgPolicyAuthorizationPolicy }
    } catch {
        Write-Warning "Could not fetch authorization policy: $_"
    }

    $authPolicyResult = if ($authPolicy) {
        @{
            AllowedToCreateApps                    = $authPolicy.DefaultUserRolePermissions.AllowedToCreateApps
            AllowedToCreateSecurityGroups          = $authPolicy.DefaultUserRolePermissions.AllowedToCreateSecurityGroups
            AllowedToCreateTenants                 = $authPolicy.DefaultUserRolePermissions.AllowedToCreateTenants
            AllowedToReadBitlockerKeysForOwnedDevice = $authPolicy.DefaultUserRolePermissions.AllowedToReadBitlockerKeysForOwnedDevice
            GuestUserRoleId                        = $authPolicy.GuestUserRoleId
            PermissionGrantPolicyIdsAssignedToDefaultUserRole = @($authPolicy.PermissionGrantPolicyIdsAssignedToDefaultUserRole)
        }
    } else {
        @{ Error = 'CouldNotFetch' }
    }
    Write-Host " done." -ForegroundColor Green

    # ── 4. Admin consent request policy ──────────────────────────────────────
    Write-Host "  Fetching admin consent request policy..." -NoNewline
    $consentPolicy = $null
    try {
        $consentPolicy = Invoke-WithRetry { Get-MgPolicyAdminConsentRequestPolicy }
    } catch {
        Write-Warning "Could not fetch admin consent request policy: $_"
    }

    $consentPolicyResult = if ($consentPolicy) {
        @{
            IsEnabled   = $consentPolicy.IsEnabled
            NotifyReviewers = $consentPolicy.NotifyReviewers
            RemindersEnabled = $consentPolicy.RemindersEnabled
            RequestDurationInDays = $consentPolicy.RequestDurationInDays
        }
    } else {
        @{ Error = 'CouldNotFetch' }
    }
    Write-Host " done." -ForegroundColor Green

    # ── 5. Cross-tenant access policy defaults ────────────────────────────────
    Write-Host "  Fetching cross-tenant access policy defaults..." -NoNewline
    $crossTenantDefault = $null
    try {
        $crossTenantDefault = Invoke-WithRetry { Get-MgPolicyCrossTenantAccessPolicyDefault }
    } catch {
        Write-Warning "Could not fetch cross-tenant access policy defaults: $_"
    }

    $crossTenantResult = if ($crossTenantDefault) {
        @{
            B2bCollaborationInbound  = @{
                ApplicationsAllowedAccess  = $crossTenantDefault.B2bCollaborationInbound.ApplicationsAllowedAccess
                UsersAndGroupsAllowedAccess = $crossTenantDefault.B2bCollaborationInbound.UsersAndGroupsAllowedAccess
            }
            B2bCollaborationOutbound = @{
                ApplicationsAllowedAccess  = $crossTenantDefault.B2bCollaborationOutbound.ApplicationsAllowedAccess
                UsersAndGroupsAllowedAccess = $crossTenantDefault.B2bCollaborationOutbound.UsersAndGroupsAllowedAccess
            }
            B2bDirectConnectInbound  = $crossTenantDefault.B2bDirectConnectInbound
            B2bDirectConnectOutbound = $crossTenantDefault.B2bDirectConnectOutbound
        }
    } else {
        @{ Error = 'CouldNotFetch' }
    }
    Write-Host " done." -ForegroundColor Green

    # ── 6. Identity Protection — risky service principals ────────────────────
    Write-Host "  Checking Identity Protection for workload identities..." -NoNewline
    $ipResult = @{ Enabled = $false; RiskyServicePrincipalCount = 0; Error = $null }
    try {
        $riskySp = Invoke-WithRetry {
            Get-MgRiskyServicePrincipal -Top 1 -ErrorAction Stop
        }
        $ipResult.Enabled = $true
        # Get a count — may be slow on large tenants so just use Top 999 as proxy
        $allRisky = Invoke-WithRetry { Get-MgRiskyServicePrincipal -All -ErrorAction Stop }
        $ipResult.RiskyServicePrincipalCount = $allRisky.Count
        Write-Host " enabled ($($allRisky.Count) risky SPs found)." -ForegroundColor Green
    } catch {
        if ($_.Exception.Message -match '403|Forbidden|InsufficientPrivileges|Unauthorized') {
            $ipResult.Error = 'Access denied (403) — Workload Identities Premium not licensed or scope missing'
            Write-Host " not licensed/scoped (403)." -ForegroundColor Yellow
        } else {
            $ipResult.Error = $_.Exception.Message
            Write-Host " error: $_" -ForegroundColor Yellow
        }
    }

    # ── 7. Directory role member counts ──────────────────────────────────────
    Write-Host "  Fetching directory role member counts..." -NoNewline
    $roleResults = @{}
    foreach ($roleName in $roleTemplateIds.Keys) {
        $roleResults[$roleName] = Get-RoleMemberCount -TemplateId $roleTemplateIds[$roleName] -RoleName $roleName
    }
    Write-Host " done." -ForegroundColor Green

    # ── 8. Azure subscriptions ────────────────────────────────────────────────
    Write-Host "  Fetching Azure subscriptions..." -NoNewline
    $subscriptions = @()
    try {
        $subscriptions = @(Invoke-WithRetry {
            Get-AzSubscription -ErrorAction Stop |
                Select-Object Name, Id, TenantId, State
        })
        Write-Host " $($subscriptions.Count) subscription(s) found." -ForegroundColor Green
    } catch {
        Write-Warning "Could not enumerate Azure subscriptions: $_"
    }

    # ── 9. Custom Entra roles ─────────────────────────────────────────────────
    Write-Host "  Fetching custom Entra role definitions..." -NoNewline
    $customRoles = @()
    try {
        $customRoles = @(Invoke-WithRetry {
            Get-MgRoleManagementDirectoryRoleDefinition -Filter 'isBuiltIn eq false' -All -ErrorAction Stop |
                Select-Object Id, DisplayName, Description, IsEnabled, CreatedDateTime
        })
        Write-Host " $($customRoles.Count) custom role(s) found." -ForegroundColor Green
    } catch {
        Write-Warning "Could not fetch custom role definitions: $_"
    }

    # ── Assemble result ───────────────────────────────────────────────────────
    $result = @{
        CollectedAt           = (Get-Date -Format 'o')
        TenantInfo            = $tenantInfo
        LicenseFlags          = $licenseFlags
        AllLicenses           = $licenseInventory
        AuthorizationPolicy   = $authPolicyResult
        AdminConsentPolicy    = $consentPolicyResult
        CrossTenantAccessDefault = $crossTenantResult
        IdentityProtection    = $ipResult
        RoleMemberCounts      = $roleResults
        AzureSubscriptions    = @($subscriptions | ForEach-Object {
            @{ Name = $_.Name; Id = $_.Id; TenantId = $_.TenantId; State = $_.State }
        })
        CustomEntraRoles      = @($customRoles | ForEach-Object {
            @{ Id = $_.Id; DisplayName = $_.DisplayName; Description = $_.Description; IsEnabled = $_.IsEnabled; CreatedDateTime = $_.CreatedDateTime }
        })
        CustomEntraRoleCount  = $customRoles.Count
        CapabilityFlags       = $capabilityFlags
    }

    # ── Write JSON ────────────────────────────────────────────────────────────
    $jsonPath = Join-Path $OutputDir '01-tenant-context.json'
    $result | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
    Write-Verbose "JSON written: $jsonPath"

    # ── Write CSV (key/value flat) ────────────────────────────────────────────
    $csvRows = [System.Collections.Generic.List[PSObject]]::new()

    $csvRows.Add([PSCustomObject]@{ Key = 'TenantId';        Value = $tenantInfo.TenantId })
    $csvRows.Add([PSCustomObject]@{ Key = 'TenantName';      Value = $tenantInfo.DisplayName })
    $csvRows.Add([PSCustomObject]@{ Key = 'PrimaryDomain';   Value = $tenantInfo.PrimaryDomain })
    $csvRows.Add([PSCustomObject]@{ Key = 'OnPremSyncEnabled'; Value = $tenantInfo.OnPremisesSyncEnabled })
    $csvRows.Add([PSCustomObject]@{ Key = 'CollectedAt';     Value = $result.CollectedAt })

    foreach ($key in $licenseFlags.Keys) {
        $csvRows.Add([PSCustomObject]@{ Key = "License_$key"; Value = $licenseFlags[$key].Present })
    }

    foreach ($cap in $capabilityFlags.Keys) {
        $csvRows.Add([PSCustomObject]@{ Key = "Capability_$cap"; Value = $capabilityFlags[$cap].Available })
        $csvRows.Add([PSCustomObject]@{ Key = "Capability_${cap}_Units"; Value = $capabilityFlags[$cap].TotalUnits })
        $csvRows.Add([PSCustomObject]@{ Key = "Capability_${cap}_Source"; Value = ($capabilityFlags[$cap].ProvidedBySkus.SkuPartNumber -join ';') })
    }

    $csvRows.Add([PSCustomObject]@{ Key = 'UsersCanRegisterApps';       Value = $authPolicyResult.AllowedToCreateApps })
    $csvRows.Add([PSCustomObject]@{ Key = 'AdminConsentWorkflowEnabled'; Value = $consentPolicyResult.IsEnabled })

    foreach ($roleName in $roleResults.Keys) {
        $csvRows.Add([PSCustomObject]@{ Key = "RoleMemberCount_$roleName"; Value = $roleResults[$roleName].MemberCount })
    }

    $csvRows.Add([PSCustomObject]@{ Key = 'AzureSubscriptionCount';       Value = $subscriptions.Count })
    $csvRows.Add([PSCustomObject]@{ Key = 'CustomEntraRoleCount';          Value = $customRoles.Count })
    $csvRows.Add([PSCustomObject]@{ Key = 'IdentityProtectionEnabled';     Value = $ipResult.Enabled })
    $csvRows.Add([PSCustomObject]@{ Key = 'RiskyServicePrincipalCount';    Value = $ipResult.RiskyServicePrincipalCount })

    $csvPath = Join-Path $OutputDir '01-tenant-context.csv'
    $csvRows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    Write-Verbose "CSV written: $csvPath"

    # ── Summary ───────────────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  01-tenant-context  SUMMARY" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Tenant ID      : $($tenantInfo.TenantId)"
    Write-Host "  Tenant Name    : $($tenantInfo.DisplayName)"
    Write-Host "  Primary Domain : $($tenantInfo.PrimaryDomain)"
    Write-Host ""
    Write-Host "  Entra Capabilities (any SKU providing the feature):" -ForegroundColor White
    foreach ($cap in $capabilityFlags.Keys) {
        $f = $capabilityFlags[$cap]
        $color = if ($f.Available) { 'Green' } else { 'Red' }
        $status = if ($f.Available) { 'YES' } else { 'NO ' }
        $sourceTxt = if ($f.Available) { " via $($f.ProvidedBySkus.SkuPartNumber -join ', ') (~$($f.TotalUnits) units)" } else { '' }
        Write-Host "    [$status] $cap$sourceTxt" -ForegroundColor $color
        Write-Host "           $($f.Description)" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "  Direct SKUs (standalone purchases only — bundles like M365 E5 not shown here):" -ForegroundColor White
    foreach ($key in $licenseFlags.Keys) {
        $flag = $licenseFlags[$key]
        $color = if ($flag.Present) { 'Green' } else { 'DarkGray' }
        $status = if ($flag.Present) { 'YES' } else { 'no ' }
        Write-Host "    [$status] $key" -ForegroundColor $color
    }
    Write-Host ""
    Write-Host "  Authorization Policy:" -ForegroundColor White
    Write-Host "    Users can register apps  : $($authPolicyResult.AllowedToCreateApps)"
    Write-Host "    Admin consent workflow   : $($consentPolicyResult.IsEnabled)"
    Write-Host ""
    Write-Host "  Role Member Counts:" -ForegroundColor White
    foreach ($roleName in $roleResults.Keys) {
        $count = $roleResults[$roleName].MemberCount
        $color = if ($roleName -eq 'GlobalAdministrator' -and $count -gt 5) { 'Yellow' } else { 'White' }
        Write-Host "    $($roleName.PadRight(35)) : $count" -ForegroundColor $color
    }
    Write-Host ""
    Write-Host "  Identity Protection (WI) : $($ipResult.Enabled) | Risky SPs: $($ipResult.RiskyServicePrincipalCount)"
    Write-Host "  Custom Entra Roles       : $($customRoles.Count)"
    Write-Host "  Azure Subscriptions      : $($subscriptions.Count)"
    Write-Host ""
    Write-Host "  Output: $jsonPath"
    Write-Host "          $csvPath"
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
}

# ─── Entry point ─────────────────────────────────────────────────────────────
try {
    Invoke-TenantContext -OutputDir $OutputDir
} catch {
    Write-Error "01-tenant-context failed: $_"
    exit 1
}
