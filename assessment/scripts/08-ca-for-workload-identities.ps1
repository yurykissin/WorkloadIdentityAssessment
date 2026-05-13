<#
.SYNOPSIS
    Enumerates Conditional Access policies targeting workload identities and
    computes per-SP CA coverage.

.DESCRIPTION
    Answers discovery questions:
      Q85 — CA on workload identities (Workload Identities Premium feature)

    A policy is "workload-identity-targeted" if:
      conditions.clientApplications.includeServicePrincipals is non-empty, OR
      conditions.clientApplications.servicePrincipalFilter.rule is set.

    Also computes which SPs are covered by at least one enabled CA policy.

    License note: CA enforcement for workload identities requires Workload
    Identities Premium. This script reads policy definitions regardless; if
    license is absent, policies may exist in report-only or disabled state.

    Prereq modules  : Microsoft.Graph.Authentication,
                      Microsoft.Graph.Identity.SignIns,
                      Microsoft.Graph.Applications

    Prereq scopes   : Policy.Read.All, Application.Read.All

    Prereq Az roles : none

    Produces:
      <OutputDir>/08-ca-for-workload-identities.json
      <OutputDir>/08-ca-for-workload-identities-policies.csv
      <OutputDir>/08-ca-for-workload-identities-sp-coverage.csv

.EXAMPLE
    ./scripts/08-ca-for-workload-identities.ps1 -OutputDir ./output/20260101-120000
    ./scripts/08-ca-for-workload-identities.ps1 -OutputDir ./output/20260101-120000 -InventoryOutputDir ./output/20260101-120000
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputDir = (Join-Path (Split-Path -Parent $PSScriptRoot) ('output/' + (Get-Date -Format 'yyyyMMdd-HHmmss'))),

    [Parameter()]
    [string]$InventoryOutputDir = ''
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# ─── Module prerequisite check ────────────────────────────────────────────────
$requiredModules = @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Identity.SignIns', 'Microsoft.Graph.Identity.DirectoryManagement')
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

function Assert-GraphContext {
    $required = @('Policy.Read.All', 'Application.Read.All')
    $ctx = Get-MgContext
    if ($null -eq $ctx) {
        Write-Error "No Microsoft Graph context. Run: Connect-MgGraph -Scopes 'Policy.Read.All','Application.Read.All'"
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
}

function Test-PolicyTargetsWorkloadIdentities {
    param($Policy)
    $ca = $Policy.Conditions.ClientApplications
    if ($null -eq $ca) { return $false }

    $includeSPs = $ca.IncludeServicePrincipals
    $filterRule = $ca.ServicePrincipalFilter.Rule

    $hasIncludedSPs = ($null -ne $includeSPs -and $includeSPs.Count -gt 0)
    $hasFilter      = (-not [string]::IsNullOrWhiteSpace($filterRule))

    return ($hasIncludedSPs -or $hasFilter)
}

function Get-CAPolicies {
    [CmdletBinding()]
    param()

    Write-Host "  Fetching all Conditional Access policies..." -NoNewline
    $allPolicies = Invoke-WithRetry {
        Get-MgIdentityConditionalAccessPolicy -All -ErrorAction Stop
    }
    Write-Host " $($allPolicies.Count) policies." -ForegroundColor Green

    $wiPolicies = [System.Collections.Generic.List[PSObject]]::new()

    foreach ($policy in $allPolicies) {
        $isWITargeted = Test-PolicyTargetsWorkloadIdentities -Policy $policy
        if (-not $isWITargeted) { continue }

        $ca = if ($policy.Conditions) { $policy.Conditions.ClientApplications } else { $null }
        $includeSPs  = if ($ca -and $ca.IncludeServicePrincipals) { @($ca.IncludeServicePrincipals) } else { @() }
        $excludeSPs  = if ($ca -and $ca.ExcludeServicePrincipals) { @($ca.ExcludeServicePrincipals) } else { @() }
        $filterRule  = if ($ca -and $ca.ServicePrincipalFilter) { $ca.ServicePrincipalFilter.Rule } else { $null }

        $grantControls = $null
        if ($policy.GrantControls) {
            $grantControls = "$($policy.GrantControls.Operator): $($policy.GrantControls.BuiltInControls -join ',')"
        }

        $sessionControls = $null
        if ($policy.SessionControls) {
            $parts = @()
            if ($policy.SessionControls.SignInFrequency.IsEnabled) {
                $parts += "SignInFrequency=$($policy.SessionControls.SignInFrequency.Value)$($policy.SessionControls.SignInFrequency.Type)"
            }
            if ($policy.SessionControls.PersistentBrowser.IsEnabled) {
                $parts += "PersistentBrowser=$($policy.SessionControls.PersistentBrowser.Mode)"
            }
            $sessionControls = $parts -join ';'
        }

        $wiPolicies.Add([PSCustomObject]@{
            PolicyId              = $policy.Id
            DisplayName           = $policy.DisplayName
            State                 = $policy.State
            IncludeServicePrincipals = ($includeSPs -join ';')
            ExcludeServicePrincipals = ($excludeSPs -join ';')
            SpFilterRule          = $filterRule
            IncludeSPCount        = $includeSPs.Count
            ExcludeSPCount        = $excludeSPs.Count
            GrantControls         = $grantControls
            SessionControls       = $sessionControls
            CreatedDateTime       = $policy.CreatedDateTime
            ModifiedDateTime      = $policy.ModifiedDateTime
        })
    }

    return @{
        AllPolicies = $allPolicies
        WIPolicies  = $wiPolicies
    }
}

function Get-SPCoverage {
    [CmdletBinding()]
    param(
        [array]$WIPolicies,
        [string]$InventoryOutputDir,
        [string]$TenantId
    )

    # Try to load SP inventory from script 02 output first
    $sps = @()
    $fromFile = $false

    if ($InventoryOutputDir -and (Test-Path (Join-Path $InventoryOutputDir '02-inventory-service-principals.csv'))) {
        try {
            $sps = @(Import-Csv -Path (Join-Path $InventoryOutputDir '02-inventory-service-principals.csv'))
            $fromFile = $true
            Write-Host "  Loaded SP inventory from 02-inventory output ($($sps.Count) SPs)." -ForegroundColor Gray
        } catch {
            Write-Verbose "Could not load SP inventory file: $_"
        }
    }

    if (-not $fromFile -or $sps.Count -eq 0) {
        Write-Host "  Fetching service principals for coverage analysis..." -NoNewline
        $allSps = Invoke-WithRetry {
            Get-MgServicePrincipal -All -Property 'id,appId,displayName,servicePrincipalType,appOwnerOrganizationId' -ErrorAction Stop
        }
        $sps = @($allSps | Where-Object {
            $_.ServicePrincipalType -eq 'Application' -and
            ($null -eq $_.AppOwnerOrganizationId -or $_.AppOwnerOrganizationId -eq $TenantId)
        })
        Write-Host " $($sps.Count) first-party Application SPs." -ForegroundColor Green
    }

    # Build a set of SP IDs covered by enabled WI CA policies
    $enabledWIPolicies = @($WIPolicies | Where-Object { $_.State -eq 'enabled' })

    # Collect explicit SP IDs from enabled policies
    $coveredSpIds = [System.Collections.Generic.HashSet[string]]::new()
    $usesAllSPsPolicy = $false

    foreach ($policy in $enabledWIPolicies) {
        $includeSPs = @($policy.IncludeServicePrincipals -split ';' | Where-Object { $_ -ne '' })
        foreach ($spId in $includeSPs) {
            if ($spId -eq 'ServicePrincipalsInMyTenant') {
                $usesAllSPsPolicy = $true
            } else {
                $coveredSpIds.Add($spId) | Out-Null
            }
        }
    }

    $coverageRows = [System.Collections.Generic.List[PSObject]]::new()
    foreach ($sp in $sps) {
        $spId = if ($sp.PSObject.Properties['SpObjectId']) { $sp.SpObjectId } else { $sp.id }
        $spName = if ($sp.PSObject.Properties['DisplayName']) { $sp.DisplayName } else { $sp.displayName }
        $appId = if ($sp.PSObject.Properties['AppId']) { $sp.AppId } else { $sp.appId }

        $covered = $usesAllSPsPolicy -or $coveredSpIds.Contains($spId)

        $coverageRows.Add([PSCustomObject]@{
            SpObjectId            = $spId
            DisplayName           = $spName
            AppId                 = $appId
            CoveredByAnyCAPolicy  = $covered
        })
    }

    return $coverageRows
}

function Invoke-CAForWorkloadIdentities {
    [CmdletBinding()]
    param([string]$OutputDir, [string]$InventoryOutputDir)

    Assert-GraphContext

    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    $tenantId = (Get-MgContext).TenantId

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  08-ca-for-workload-identities  |  Analysing CA policies..." -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""

    # Check if Workload Identities Premium is licensed
    $wiPremiumPresent = $false
    $invDir = if ($InventoryOutputDir) { $InventoryOutputDir } else { $OutputDir }
    $tenantContextPath = Join-Path $invDir '01-tenant-context.json'
    if (Test-Path $tenantContextPath) {
        try {
            $tenantCtx = Get-Content $tenantContextPath -Raw | ConvertFrom-Json
            $wiPremiumPresent = $tenantCtx.LicenseFlags.WORKLOAD_IDENTITIES_PREMIUM.Present -eq $true
        } catch {
            Write-Verbose "Could not read tenant context for license check: $_"
        }
    }

    $policyResult = Get-CAPolicies
    $allPolicies  = $policyResult.AllPolicies
    $wiPolicies   = $policyResult.WIPolicies

    $coverageRows = Get-SPCoverage -WIPolicies $wiPolicies -InventoryOutputDir $InventoryOutputDir -TenantId $tenantId

    # ── Write CSVs ────────────────────────────────────────────────────────────
    $policyCsvPath   = Join-Path $OutputDir '08-ca-for-workload-identities-policies.csv'
    $coverageCsvPath = Join-Path $OutputDir '08-ca-for-workload-identities-sp-coverage.csv'

    if ($wiPolicies.Count -gt 0) {
        $wiPolicies | Export-Csv -Path $policyCsvPath -NoTypeInformation -Encoding UTF8
    } else {
        [PSCustomObject]@{ Note = 'No CA policies targeting workload identities found' } |
            Export-Csv -Path $policyCsvPath -NoTypeInformation -Encoding UTF8
    }

    if ($coverageRows.Count -gt 0) {
        $coverageRows | Export-Csv -Path $coverageCsvPath -NoTypeInformation -Encoding UTF8
    } else {
        [PSCustomObject]@{ Note = 'No service principals found for coverage analysis' } |
            Export-Csv -Path $coverageCsvPath -NoTypeInformation -Encoding UTF8
    }

    # ── Write JSON ────────────────────────────────────────────────────────────
    $enabledCount      = @($wiPolicies | Where-Object { $_.State -eq 'enabled' }).Count
    $reportOnlyCount   = @($wiPolicies | Where-Object { $_.State -eq 'enabledForReportingButNotEnforced' }).Count
    $disabledCount     = @($wiPolicies | Where-Object { $_.State -eq 'disabled' }).Count
    $coveredCount      = @($coverageRows | Where-Object { $_.CoveredByAnyCAPolicy }).Count
    $totalSPs          = $coverageRows.Count
    $coveragePct       = if ($totalSPs -gt 0) { [math]::Round($coveredCount / $totalSPs * 100, 1) } else { 0 }

    $jsonResult = @{
        CollectedAt              = (Get-Date -Format 'o')
        WorkloadIdentitiesPremiumLicensed = $wiPremiumPresent
        TotalCAPolicies          = $allPolicies.Count
        WITargetedPolicies       = $wiPolicies.Count
        EnabledWIPolicies        = $enabledCount
        ReportOnlyWIPolicies     = $reportOnlyCount
        DisabledWIPolicies       = $disabledCount
        TotalFirstPartySPs       = $totalSPs
        SPsCoveredByCAPolicy     = $coveredCount
        SPCoveragePct            = $coveragePct
        Policies                 = @($wiPolicies)
        SPCoverage               = @($coverageRows)
    }
    $jsonPath = Join-Path $OutputDir '08-ca-for-workload-identities.json'
    $jsonResult | ConvertTo-Json -Depth 8 | Out-File -FilePath $jsonPath -Encoding UTF8

    # ── Summary ───────────────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  08-ca-for-workload-identities  SUMMARY" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan

    $licColor = if ($wiPremiumPresent) { 'Green' } else { 'Yellow' }
    Write-Host "  Workload Identities Premium    : $(if ($wiPremiumPresent) {'Licensed'} else {'NOT licensed — CA enforcement will not work'})" -ForegroundColor $licColor
    Write-Host ""
    Write-Host "  Conditional Access Policies    : $($allPolicies.Count) total"
    $wiColor = if ($wiPolicies.Count -gt 0) { 'Green' } else { 'Yellow' }
    Write-Host "    Targeting workload identities: $($wiPolicies.Count)" -ForegroundColor $wiColor
    $enableColor = if ($enabledCount -gt 0) { 'Green' } else { 'Yellow' }
    Write-Host "    Enabled                      : $enabledCount" -ForegroundColor $enableColor
    Write-Host "    Report-only                  : $reportOnlyCount"
    Write-Host "    Disabled                     : $disabledCount"
    Write-Host ""
    Write-Host "  SP Coverage:" -ForegroundColor White
    Write-Host "    Total first-party SPs        : $totalSPs"
    $covColor = if ($coveragePct -ge 80) { 'Green' } elseif ($coveragePct -ge 20) { 'Yellow' } else { 'Red' }
    Write-Host "    Covered by CA policy         : $coveredCount ($coveragePct%)" -ForegroundColor $covColor
    Write-Host ""

    if ($wiPolicies.Count -gt 0) {
        Write-Host "  WI-targeted policy list:" -ForegroundColor White
        foreach ($p in $wiPolicies) {
            $stateColor = switch ($p.State) {
                'enabled'                           { 'Green'  }
                'enabledForReportingButNotEnforced' { 'Yellow' }
                default                              { 'Gray'   }
            }
            Write-Host "    [$($p.State)] $($p.DisplayName)" -ForegroundColor $stateColor
        }
    }

    Write-Host ""
    Write-Host "  Output:"
    Write-Host "    $jsonPath"
    Write-Host "    $policyCsvPath"
    Write-Host "    $coverageCsvPath"
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
}

# ─── Entry point ─────────────────────────────────────────────────────────────
try {
    Invoke-CAForWorkloadIdentities -OutputDir $OutputDir -InventoryOutputDir $InventoryOutputDir
} catch {
    Write-Error "08-ca-for-workload-identities failed: $_"
    exit 1
}
