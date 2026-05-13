<#
.SYNOPSIS
    Identifies stale and orphaned workload identities based on sign-in activity
    and owner status.

.DESCRIPTION
    Answers discovery questions:
      Q6  — Active vs dormant service principals
      Q7  — App registrations with no owner
      Q46 — Credentials from departed contractors (orphaned owners)

    For every first-party Application-type SP:
      - Joins sign-in activity to classify stale90 / stale365 / neverSignedIn
      - Resolves owners and classifies: noOwner / singleOwner / orphanedOwner / ok
      - Orphaned = all owner user accounts return 404 from Get-MgUser

    Prereq modules  : Microsoft.Graph.Authentication,
                      Microsoft.Graph.Applications,
                      Microsoft.Graph.Identity.DirectoryManagement,
                      Microsoft.Graph.Reports

    Prereq scopes   : Application.Read.All, Directory.Read.All,
                      AuditLog.Read.All

    Prereq Az roles : none

    Produces:
      <OutputDir>/06-stale-and-orphaned.json
      <OutputDir>/06-stale-and-orphaned.csv

.EXAMPLE
    ./scripts/06-stale-and-orphaned.ps1 -OutputDir ./output/20260101-120000
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputDir = (Join-Path (Split-Path -Parent $PSScriptRoot) ('output/' + (Get-Date -Format 'yyyyMMdd-HHmmss')))
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# ─── Module prerequisite check ────────────────────────────────────────────────
$requiredModules = @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Applications', 'Microsoft.Graph.Reports', 'Az.Accounts', 'Az.ResourceGraph')
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
    $required = @('Application.Read.All', 'Directory.Read.All')
    $ctx = Get-MgContext
    if ($null -eq $ctx) {
        Write-Error "No Microsoft Graph context. Run: Connect-MgGraph -Scopes 'Application.Read.All','Directory.Read.All','AuditLog.Read.All'"
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

function Test-UserExists {
    [CmdletBinding()]
    param(
        [string]$UserId,
        [hashtable]$UserExistenceCache
    )
    if ($UserExistenceCache.ContainsKey($UserId)) {
        return $UserExistenceCache[$UserId]
    }
    try {
        $user = Invoke-WithRetry {
            Get-MgUser -UserId $UserId -Property 'id' -ErrorAction Stop
        }
        $exists = $null -ne $user
        $UserExistenceCache[$UserId] = $exists
        return $exists
    } catch {
        if ($_.Exception.Message -match '404|Request_ResourceNotFound|ObjectNotFound') {
            $UserExistenceCache[$UserId] = $false
            return $false
        }
        # Other error — assume exists to avoid false positives
        $UserExistenceCache[$UserId] = $true
        return $true
    }
}

function Invoke-StaleAndOrphaned {
    [CmdletBinding()]
    param([string]$OutputDir)

    Assert-GraphContext

    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    $tenantId = (Get-MgContext).TenantId

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  06-stale-and-orphaned  |  Analysing stale/orphaned WIs..." -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""

    # ── 1. Sign-in activity map ───────────────────────────────────────────────
    Write-Host "  Fetching SP sign-in activity (beta)..." -NoNewline
    $signInMap = @{}
    $signInAvailable = $false
    try {
        $activities = Invoke-WithRetry {
            Get-MgBetaReportServicePrincipalSignInActivity -All -ErrorAction Stop
        }
        $signInAvailable = $true
        foreach ($a in $activities) {
            $candidates = @(
                $a.LastSignInActivity.LastSignInDateTime
                $a.DelegatedClientSignInActivity.LastSignInDateTime
                $a.ApplicationAuthenticationClientSignInActivity.LastSignInDateTime
                $a.ManagedIdentitySignInActivity.LastSignInDateTime
            ) | Where-Object { $null -ne $_ }

            $lastSignIn = $null
            if ($candidates.Count -gt 0) {
                $lastSignIn = $candidates | Sort-Object -Descending | Select-Object -First 1
            }
            $signInMap[$a.AppId] = $lastSignIn
        }
        Write-Host " $($activities.Count) records loaded." -ForegroundColor Green
    } catch {
        if ($_.Exception.Message -match '403|Forbidden') {
            Write-Host " not available (403 — AuditLog.Read.All or P1/P2 license required). Staleness will be null." -ForegroundColor Yellow
        } else {
            Write-Host " failed: $_" -ForegroundColor Yellow
        }
    }

    # ── 2. App registrations — build tag lookup ───────────────────────────────
    Write-Host "  Fetching app registrations for tag/owner context..." -NoNewline
    $appsByAppId = @{}
    try {
        $allApps = Invoke-WithRetry {
            Get-MgApplication -All -Property 'id,appId,tags,displayName' -ErrorAction Stop
        }
        foreach ($app in $allApps) {
            $appsByAppId[$app.AppId] = $app
        }
        Write-Host " $($allApps.Count) app registrations indexed." -ForegroundColor Green
    } catch {
        Write-Host " failed: $_" -ForegroundColor Yellow
    }

    # ── 3. Service principals (Application type, first-party only) ────────────
    Write-Host "  Fetching service principals..." -NoNewline
    $allSps = Invoke-WithRetry {
        Get-MgServicePrincipal -All -Property 'id,appId,displayName,servicePrincipalType,appOwnerOrganizationId,accountEnabled' -ErrorAction Stop
    }

    # Filter: Application type, owned by this tenant (not external SaaS)
    $firstPartySps = @($allSps | Where-Object {
        $_.ServicePrincipalType -eq 'Application' -and
        ($null -eq $_.AppOwnerOrganizationId -or $_.AppOwnerOrganizationId -eq $tenantId)
    })
    Write-Host " $($firstPartySps.Count) first-party Application SPs." -ForegroundColor Green

    # ── 4. Process each SP ────────────────────────────────────────────────────
    $today = [datetime]::UtcNow
    $rows = [System.Collections.Generic.List[PSObject]]::new()
    $userExistenceCache = @{}

    $i = 0
    foreach ($sp in $firstPartySps) {
        $i++
        if ($firstPartySps.Count -gt 50) {
            Write-Progress -Activity 'Analysing SPs for staleness/orphan status' -Status "$i / $($firstPartySps.Count): $($sp.DisplayName)" -PercentComplete (($i / $firstPartySps.Count) * 100)
        }

        # Sign-in staleness
        $lastSignIn = $null
        $daysSince  = $null
        $neverSignedIn = $true

        if ($signInAvailable -and $signInMap.ContainsKey($sp.AppId) -and $null -ne $signInMap[$sp.AppId]) {
            $lastSignIn = [datetime]$signInMap[$sp.AppId]
            $daysSince  = [int]($today - $lastSignIn.ToUniversalTime()).TotalDays
            $neverSignedIn = $false
        }

        $stale90  = ($neverSignedIn -or ($daysSince -ne $null -and $daysSince -ge 90))
        $stale365 = ($neverSignedIn -or ($daysSince -ne $null -and $daysSince -ge 365))

        # Owner resolution
        $ownerCount    = 0
        $ownerCategory = 'ok'
        $ownerIds      = @()

        try {
            $owners = Invoke-WithRetry {
                Get-MgServicePrincipalOwner -ServicePrincipalId $sp.Id -All -ErrorAction Stop
            }
            $ownerCount = $owners.Count
            $ownerIds   = @($owners | ForEach-Object { $_.Id })

            if ($ownerCount -eq 0) {
                $ownerCategory = 'noOwner'
            } elseif ($ownerCount -eq 1) {
                # Check if the single owner exists
                $ownerType = $owners[0].AdditionalProperties.'@odata.type'
                if ($ownerType -match '#microsoft.graph.user') {
                    $exists = Test-UserExists -UserId $owners[0].Id -UserExistenceCache $userExistenceCache
                    $ownerCategory = if ($exists) { 'singleOwner' } else { 'orphanedOwner' }
                } else {
                    $ownerCategory = 'singleOwner'  # SP or group owner
                }
            } else {
                # Check if ALL user owners are still in directory
                $allOwnersOrphaned = $true
                foreach ($owner in $owners) {
                    $ownerType = $owner.AdditionalProperties.'@odata.type'
                    if ($ownerType -match '#microsoft.graph.user') {
                        $exists = Test-UserExists -UserId $owner.Id -UserExistenceCache $userExistenceCache
                        if ($exists) { $allOwnersOrphaned = $false; break }
                    } else {
                        $allOwnersOrphaned = $false; break
                    }
                }
                $ownerCategory = if ($allOwnersOrphaned) { 'orphanedOwner' } else { 'ok' }
            }
        } catch {
            Write-Verbose "Could not get owners for SP $($sp.Id): $_"
            $ownerCategory = 'unknown'
        }

        # App reg context
        $appRegHasTags = $false
        if ($appsByAppId.ContainsKey($sp.AppId)) {
            $appRegHasTags = ($appsByAppId[$sp.AppId].Tags.Count -gt 0)
        }

        $rows.Add([PSCustomObject]@{
            SpObjectId          = $sp.Id
            DisplayName         = $sp.DisplayName
            AppId               = $sp.AppId
            AccountEnabled      = $sp.AccountEnabled
            LastSignIn          = $lastSignIn
            DaysSinceLastSignIn = $daysSince
            NeverSignedIn       = $neverSignedIn
            SignInDataAvailable = $signInAvailable
            OwnerCount          = $ownerCount
            OwnerIds            = ($ownerIds -join ';')
            OwnerCategory       = $ownerCategory
            Stale90Days         = $stale90
            Stale365Days        = $stale365
            AppRegHasTags       = $appRegHasTags
        })
    }
    if ($firstPartySps.Count -gt 50) { Write-Progress -Activity 'Analysing SPs for staleness/orphan status' -Completed }

    # ── Write CSV ─────────────────────────────────────────────────────────────
    $csvPath = Join-Path $OutputDir '06-stale-and-orphaned.csv'
    if ($rows.Count -gt 0) {
        $rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    } else {
        [PSCustomObject]@{ Note = 'No first-party Application SPs found' } |
            Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    }

    # ── Write JSON ────────────────────────────────────────────────────────────
    $stale90Count   = @($rows | Where-Object { $_.Stale90Days  }).Count
    $stale365Count  = @($rows | Where-Object { $_.Stale365Days }).Count
    $neverCount     = @($rows | Where-Object { $_.NeverSignedIn }).Count
    $noOwnerCount   = @($rows | Where-Object { $_.OwnerCategory -eq 'noOwner' }).Count
    $orphanedCount  = @($rows | Where-Object { $_.OwnerCategory -eq 'orphanedOwner' }).Count
    $singleOwnerCount = @($rows | Where-Object { $_.OwnerCategory -eq 'singleOwner' }).Count
    $noTagsCount    = @($rows | Where-Object { -not $_.AppRegHasTags }).Count

    $jsonResult = @{
        CollectedAt         = (Get-Date -Format 'o')
        SignInDataAvailable = $signInAvailable
        Aggregations        = @{
            TotalFirstPartySPs        = $rows.Count
            Stale90Days               = $stale90Count
            Stale365Days              = $stale365Count
            NeverSignedIn             = $neverCount
            NoOwner                   = $noOwnerCount
            OrphanedOwner             = $orphanedCount
            SingleOwner               = $singleOwnerCount
            AppRegMissingTags         = $noTagsCount
        }
        ServicePrincipals   = @($rows)
    }
    $jsonPath = Join-Path $OutputDir '06-stale-and-orphaned.json'
    $jsonResult | ConvertTo-Json -Depth 6 | Out-File -FilePath $jsonPath -Encoding UTF8

    # ── Summary ───────────────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  06-stale-and-orphaned  SUMMARY" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  First-party Application SPs analysed : $($rows.Count)"
    Write-Host "  Sign-in data available               : $signInAvailable"
    Write-Host ""
    Write-Host "  Staleness (sign-in activity):" -ForegroundColor White
    $s90Color = if ($stale90Count -gt 0) { 'Yellow' } else { 'Green' }
    $s365Color = if ($stale365Count -gt 0) { 'Red' } else { 'Green' }
    Write-Host "    No sign-in in 90+ days   : $stale90Count"  -ForegroundColor $s90Color
    Write-Host "    No sign-in in 365+ days  : $stale365Count" -ForegroundColor $s365Color
    Write-Host "    Never signed in          : $neverCount"
    Write-Host ""
    Write-Host "  Ownership:" -ForegroundColor White
    $noOwColor = if ($noOwnerCount -gt 0) { 'Red'    } else { 'Green' }
    $orpColor  = if ($orphanedCount -gt 0) { 'Red'   } else { 'Green' }
    $sinColor  = if ($singleOwnerCount -gt 0) { 'Yellow' } else { 'Green' }
    Write-Host "    No owner (noOwner)       : $noOwnerCount"    -ForegroundColor $noOwColor
    Write-Host "    Orphaned owners          : $orphanedCount"   -ForegroundColor $orpColor
    Write-Host "    Single owner             : $singleOwnerCount" -ForegroundColor $sinColor
    Write-Host ""
    $tagColor = if ($noTagsCount -gt 0) { 'Yellow' } else { 'Green' }
    Write-Host "  App regs missing tags (CMDB gap) : $noTagsCount" -ForegroundColor $tagColor
    Write-Host ""
    Write-Host "  Output:"
    Write-Host "    $jsonPath"
    Write-Host "    $csvPath"
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
}

# ─── Entry point ─────────────────────────────────────────────────────────────
try {
    Invoke-StaleAndOrphaned -OutputDir $OutputDir
} catch {
    Write-Error "06-stale-and-orphaned failed: $_"
    exit 1
}
