<#
.SYNOPSIS
    Inventories monitoring coverage — Entra diagnostic settings, Log Analytics
    workspaces (with Sentinel detection), and Key Vault configuration across
    in-scope Azure subscriptions.

.DESCRIPTION
    Answers discovery questions:
      Q55  — Key Vault RBAC vs access policies
      Q63  — KV soft-delete + purge protection
      Q77  — SP sign-in logs collected, destination
      Q78  — Log retention period
      Q80  — Sentinel deployed
      Q81  — Audit logs ingested into SIEM

    Prereq modules  : Microsoft.Graph.Authentication,
                      Az.Accounts, Az.ResourceGraph, Az.Monitor

    Prereq scopes   : Directory.Read.All (for tenant context only)

    Prereq Az roles : Reader (subscription-level)
                      Monitoring Reader (for diagnostic settings read)

    Produces:
      <OutputDir>/07-monitoring-coverage.json
      <OutputDir>/07-monitoring-coverage-diagnostic-settings.csv
      <OutputDir>/07-monitoring-coverage-log-analytics.csv
      <OutputDir>/07-monitoring-coverage-key-vaults.csv

.EXAMPLE
    ./scripts/07-monitoring-coverage.ps1 -OutputDir ./output/20260101-120000
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputDir = (Join-Path (Split-Path -Parent $PSScriptRoot) ('output/' + (Get-Date -Format 'yyyyMMdd-HHmmss')))
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# ─── Module prerequisite check ────────────────────────────────────────────────
$requiredModules = @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Identity.DirectoryManagement', 'Az.Accounts', 'Az.Monitor', 'Az.ResourceGraph')
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

function Assert-AzContext {
    $ctx = Get-AzContext
    if ($null -eq $ctx) {
        Write-Error "No Azure context. Run: Connect-AzAccount"
        exit 2
    }
}

function Get-EntraDiagnosticSettings {
    [CmdletBinding()]
    param()

    $diagSettings = [System.Collections.Generic.List[PSObject]]::new()

    Write-Host "  Fetching Entra diagnostic settings (tenant-level)..." -NoNewline
    try {
        $response = Invoke-WithRetry {
            Invoke-AzRestMethod -Method GET -Path '/providers/microsoft.aadiam/diagnosticSettings?api-version=2017-04-01-preview' -ErrorAction Stop
        }

        if ($response.StatusCode -ne 200) {
            Write-Host " HTTP $($response.StatusCode) — insufficient permissions or feature not available." -ForegroundColor Yellow
            return $diagSettings
        }

        $data = $response.Content | ConvertFrom-Json
        $settings = $data.value

        foreach ($s in $settings) {
            $categories = @($s.properties.logs | ForEach-Object {
                @{ Category = $_.category; Enabled = $_.enabled; RetentionDays = $_.retentionPolicy.days }
            })

            $enabledCategories = @($categories | Where-Object { $_.Enabled } | ForEach-Object { $_.Category })

            $ds = [PSCustomObject]@{
                Name                          = $s.name
                WorkspaceId                   = $s.properties.workspaceId
                StorageAccountId              = $s.properties.storageAccountId
                EventHubAuthorizationRuleId   = $s.properties.eventHubAuthorizationRuleId
                ServiceBusRuleId              = $s.properties.serviceBusRuleId
                EnabledCategories             = ($enabledCategories -join ';')
                SignInLogsEnabled             = ($enabledCategories -contains 'SignInLogs')
                NonInteractiveSignInEnabled   = ($enabledCategories -contains 'NonInteractiveUserSignInLogs')
                ServicePrincipalSignInEnabled = ($enabledCategories -contains 'ServicePrincipalSignInLogs')
                ManagedIdentitySignInEnabled  = ($enabledCategories -contains 'ManagedIdentitySignInLogs')
                AuditLogsEnabled              = ($enabledCategories -contains 'AuditLogs')
                ProvisioningLogsEnabled       = ($enabledCategories -contains 'ProvisioningLogs')
                RiskyUsersEnabled             = ($enabledCategories -contains 'RiskyUsers')
                UserRiskEventsEnabled         = ($enabledCategories -contains 'UserRiskEvents')
                AllCategories                 = ($categories | ConvertTo-Json -Compress)
            }
            $diagSettings.Add($ds)
        }
        Write-Host " $($diagSettings.Count) setting(s) found." -ForegroundColor Green
    } catch {
        Write-Host " failed: $_" -ForegroundColor Yellow
    }

    return $diagSettings
}

function Get-LogAnalyticsWorkspaces {
    [CmdletBinding()]
    param([string[]]$WorkspaceIds)

    $laRows = [System.Collections.Generic.List[PSObject]]::new()
    $uniqueIds = @($WorkspaceIds | Where-Object { $_ } | Select-Object -Unique)

    Write-Host "  Checking $($uniqueIds.Count) Log Analytics workspace(s)..." -NoNewline

    foreach ($wsId in $uniqueIds) {
        try {
            # Get workspace info via Az.Monitor / Az.OperationalInsights
            $ws = Invoke-WithRetry {
                Get-AzOperationalInsightsWorkspace -ErrorAction Stop |
                    Where-Object { $_.ResourceId -eq $wsId } |
                    Select-Object -First 1
            }

            if (-not $ws) {
                # Try by resource ID directly (cross-sub scenario)
                $wsName  = ($wsId -split '/')[-1]
                $ws = Invoke-WithRetry {
                    Get-AzOperationalInsightsWorkspace -ErrorAction Stop |
                        Where-Object { $_.Name -eq $wsName } |
                        Select-Object -First 1
                }
            }

            $sentinelEnabled = $false
            if ($ws) {
                # Detect Sentinel
                try {
                    $sentinelPath = "$($ws.ResourceId)/providers/Microsoft.SecurityInsights/onboardingStates/default?api-version=2024-03-01"
                    $sentinelResp = Invoke-WithRetry {
                        Invoke-AzRestMethod -Method GET -Path $sentinelPath -ErrorAction Stop
                    }
                    $sentinelEnabled = ($sentinelResp.StatusCode -eq 200)
                } catch {
                    Write-Verbose "Sentinel check failed for ${wsId}: $_"
                }

                $laRows.Add([PSCustomObject]@{
                    WorkspaceId         = $wsId
                    WorkspaceName       = $ws.Name
                    ResourceGroup       = $ws.ResourceGroupName
                    SubscriptionId      = ($wsId -split '/')[2]
                    Location            = $ws.Location
                    Sku                 = $ws.Sku
                    RetentionInDays     = $ws.retentionInDays
                    SentinelEnabled     = $sentinelEnabled
                })
            } else {
                $laRows.Add([PSCustomObject]@{
                    WorkspaceId         = $wsId
                    WorkspaceName       = 'NotFound'
                    ResourceGroup       = $null
                    SubscriptionId      = ($wsId -split '/')[2]
                    Location            = $null
                    Sku                 = $null
                    RetentionInDays     = $null
                    SentinelEnabled     = $false
                })
            }
        } catch {
            Write-Verbose "Could not check workspace ${wsId}: $_"
            $laRows.Add([PSCustomObject]@{
                WorkspaceId    = $wsId
                WorkspaceName  = 'Error'
                SentinelEnabled = $false
                Error          = $_.Exception.Message
            })
        }
    }
    Write-Host " done." -ForegroundColor Green
    return $laRows
}

function Get-KeyVaultInventory {
    [CmdletBinding()]
    param()

    $kvRows = [System.Collections.Generic.List[PSObject]]::new()

    Write-Host "  Fetching Key Vault inventory via Resource Graph..." -NoNewline
    try {
        $kvQuery = @"
resources
| where type =~ 'microsoft.keyvault/vaults'
| project
    id,
    name,
    resourceGroup,
    subscriptionId,
    location,
    rbacEnabled            = properties.enableRbacAuthorization,
    softDeleteEnabled      = properties.enableSoftDelete,
    purgeProtectionEnabled = properties.enablePurgeProtection,
    softDeleteRetentionDays = properties.softDeleteRetentionInDays,
    publicNetworkAccess    = properties.publicNetworkAccess,
    accessPoliciesCount    = array_length(properties.accessPolicies)
| order by subscriptionId asc, name asc
"@
        $kvs = Invoke-WithRetry { Search-AzGraph -Query $kvQuery -First 1000 -ErrorAction Stop }
        Write-Host " $($kvs.Count) Key Vault(s) found." -ForegroundColor Green

        foreach ($kv in $kvs) {
            $rbacEnabled = $kv.rbacEnabled -eq $true
            $kvRows.Add([PSCustomObject]@{
                KvName                  = $kv.name
                ResourceId              = $kv.id
                SubscriptionId          = $kv.subscriptionId
                ResourceGroup           = $kv.resourceGroup
                Location                = $kv.location
                RbacEnabled             = $rbacEnabled
                AccessPoliciesMode      = (-not $rbacEnabled)
                AccessPoliciesCount     = $kv.accessPoliciesCount
                SoftDeleteEnabled       = $kv.softDeleteEnabled -eq $true
                PurgeProtectionEnabled  = $kv.purgeProtectionEnabled -eq $true
                SoftDeleteRetentionDays = $kv.softDeleteRetentionDays
                PublicNetworkAccess     = $kv.publicNetworkAccess
            })
        }
    } catch {
        Write-Warning "Could not enumerate Key Vaults via Resource Graph: $_"
    }

    return $kvRows
}

function Invoke-MonitoringCoverage {
    [CmdletBinding()]
    param([string]$OutputDir)

    Assert-AzContext

    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  07-monitoring-coverage  |  Checking monitoring posture..." -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""

    $diagSettings = Get-EntraDiagnosticSettings

    # Collect unique workspace IDs from diagnostic settings
    $workspaceIds = @($diagSettings | Where-Object { $_.WorkspaceId } | ForEach-Object { $_.WorkspaceId } | Select-Object -Unique)
    $laWorkspaces = Get-LogAnalyticsWorkspaces -WorkspaceIds $workspaceIds

    $kvs = Get-KeyVaultInventory

    # ── Write CSVs ────────────────────────────────────────────────────────────
    $diagCsvPath = Join-Path $OutputDir '07-monitoring-coverage-diagnostic-settings.csv'
    $laCsvPath   = Join-Path $OutputDir '07-monitoring-coverage-log-analytics.csv'
    $kvCsvPath   = Join-Path $OutputDir '07-monitoring-coverage-key-vaults.csv'

    if ($diagSettings.Count -gt 0) {
        $diagSettings | Export-Csv -Path $diagCsvPath -NoTypeInformation -Encoding UTF8
    } else {
        [PSCustomObject]@{ Note = 'No Entra diagnostic settings found' } | Export-Csv -Path $diagCsvPath -NoTypeInformation -Encoding UTF8
    }

    if ($laWorkspaces.Count -gt 0) {
        $laWorkspaces | Export-Csv -Path $laCsvPath -NoTypeInformation -Encoding UTF8
    } else {
        [PSCustomObject]@{ Note = 'No Log Analytics workspaces found as destinations' } | Export-Csv -Path $laCsvPath -NoTypeInformation -Encoding UTF8
    }

    if ($kvs.Count -gt 0) {
        $kvs | Export-Csv -Path $kvCsvPath -NoTypeInformation -Encoding UTF8
    } else {
        [PSCustomObject]@{ Note = 'No Key Vaults found in scope' } | Export-Csv -Path $kvCsvPath -NoTypeInformation -Encoding UTF8
    }

    # ── Write JSON ────────────────────────────────────────────────────────────
    $jsonResult = @{
        CollectedAt         = (Get-Date -Format 'o')
        diagnosticSettings  = @($diagSettings)
        logAnalyticsWorkspaces = @($laWorkspaces)
        keyVaults           = @($kvs)
    }
    $jsonPath = Join-Path $OutputDir '07-monitoring-coverage.json'
    $jsonResult | ConvertTo-Json -Depth 8 | Out-File -FilePath $jsonPath -Encoding UTF8

    # ── Summary calculations ──────────────────────────────────────────────────
    $spSignInRouted       = @($diagSettings | Where-Object { $_.ServicePrincipalSignInEnabled }).Count -gt 0
    $miSignInRouted       = @($diagSettings | Where-Object { $_.ManagedIdentitySignInEnabled }).Count -gt 0
    $auditLogsRouted      = @($diagSettings | Where-Object { $_.AuditLogsEnabled }).Count -gt 0
    $signInLogsRouted     = @($diagSettings | Where-Object { $_.SignInLogsEnabled }).Count -gt 0
    $storageRouted        = @($diagSettings | Where-Object { $_.StorageAccountId }).Count -gt 0
    $eventHubRouted       = @($diagSettings | Where-Object { $_.EventHubAuthorizationRuleId }).Count -gt 0

    $sentinelDeployed     = @($laWorkspaces | Where-Object { $_.SentinelEnabled }).Count -gt 0
    $firstWs              = $laWorkspaces | Select-Object -First 1

    $kvWithRbac           = @($kvs | Where-Object { $_.RbacEnabled }).Count
    $kvWithLegacyPolicy   = @($kvs | Where-Object { $_.AccessPoliciesMode }).Count
    $kvNoPurgeProtection  = @($kvs | Where-Object { -not $_.PurgeProtectionEnabled }).Count
    $kvNoSoftDelete       = @($kvs | Where-Object { -not $_.SoftDeleteEnabled }).Count

    $maxRetention         = if ($laWorkspaces.Count -gt 0) {
        ($laWorkspaces | Where-Object { $_.RetentionInDays } | Measure-Object -Property RetentionInDays -Maximum).Maximum
    } else { $null }

    function Format-YesNo([bool]$val) { if ($val) { 'YES' } else { 'NO' } }

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  07-monitoring-coverage  SUMMARY" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Entra Diagnostic Settings     : $($diagSettings.Count)"
    Write-Host ""
    Write-Host "  Log routing:" -ForegroundColor White
    $c = if ($signInLogsRouted) { 'Green' } else { 'Red' }
    Write-Host "    Sign-in logs → LA            : $(Format-YesNo $signInLogsRouted)" -ForegroundColor $c
    $c = if ($spSignInRouted) { 'Green' } else { 'Red' }
    Write-Host "    SP sign-in logs → LA         : $(Format-YesNo $spSignInRouted)" -ForegroundColor $c
    $c = if ($miSignInRouted) { 'Green' } else { 'Yellow' }
    Write-Host "    MI sign-in logs → LA         : $(Format-YesNo $miSignInRouted)" -ForegroundColor $c
    $c = if ($auditLogsRouted) { 'Green' } else { 'Red' }
    Write-Host "    Audit logs → LA              : $(Format-YesNo $auditLogsRouted)" -ForegroundColor $c
    $c = if ($storageRouted) { 'Green' } else { 'Yellow' }
    Write-Host "    Logs → Storage               : $(Format-YesNo $storageRouted)" -ForegroundColor $c
    $c = if ($eventHubRouted) { 'Green' } else { 'Yellow' }
    Write-Host "    Logs → Event Hub/SIEM        : $(Format-YesNo $eventHubRouted)" -ForegroundColor $c
    Write-Host "    Max retention (days)         : $maxRetention"
    Write-Host ""
    $sc = if ($sentinelDeployed) { 'Green' } else { 'Yellow' }
    Write-Host "  Microsoft Sentinel deployed    : $(Format-YesNo $sentinelDeployed)" -ForegroundColor $sc
    Write-Host ""
    Write-Host "  Key Vaults (in scope)          : $($kvs.Count)"
    Write-Host "    RBAC authorization mode      : $kvWithRbac"
    $legColor = if ($kvWithLegacyPolicy -gt 0) { 'Yellow' } else { 'Green' }
    Write-Host "    Legacy access policies       : $kvWithLegacyPolicy" -ForegroundColor $legColor
    $noSdColor = if ($kvNoSoftDelete -gt 0) { 'Red' } else { 'Green' }
    Write-Host "    Without soft-delete          : $kvNoSoftDelete" -ForegroundColor $noSdColor
    $noPpColor = if ($kvNoPurgeProtection -gt 0) { 'Red' } else { 'Green' }
    Write-Host "    Without purge protection     : $kvNoPurgeProtection" -ForegroundColor $noPpColor
    Write-Host ""
    Write-Host "  Output:"
    Write-Host "    $jsonPath"
    Write-Host "    $diagCsvPath"
    Write-Host "    $laCsvPath"
    Write-Host "    $kvCsvPath"
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
}

# ─── Entry point ─────────────────────────────────────────────────────────────
try {
    Invoke-MonitoringCoverage -OutputDir $OutputDir
} catch {
    Write-Error "07-monitoring-coverage failed: $_"
    exit 1
}
