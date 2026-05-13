<#
.SYNOPSIS
    Analyses credential hygiene for all app registration password and key
    credentials (secrets and certificates).

.DESCRIPTION
    Answers discovery questions:
      Q36 — Long-lived unrotated secrets (>12 months)
      Q52 — Max/median secret lifetime
      Q58 — Cert vs password ratio
      Q18 — Presence of password creds on pipeline-tied SPs

    For every password and key credential on every app registration, computes:
      - lifetimeDays, ageDays, daysUntilExpiry, expired, longLived, veryLongLived

    Also produces aggregations:
      - Total active password/key credentials
      - Median + max secret lifetime
      - Count secrets > 12/24 months
      - Count expired (still attached but past endDateTime)
      - Count app regs with > 2 active credentials simultaneously

    Prereq modules  : Microsoft.Graph.Authentication,
                      Microsoft.Graph.Applications

    Prereq scopes   : Application.Read.All

    Prereq Az roles : none (Entra-only script)

    Produces:
      <OutputDir>/03-credential-hygiene.json
      <OutputDir>/03-credential-hygiene.csv

.EXAMPLE
    ./scripts/03-credential-hygiene.ps1 -OutputDir ./output/20260101-120000
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputDir = (Join-Path (Split-Path -Parent $PSScriptRoot) ('output/' + (Get-Date -Format 'yyyyMMdd-HHmmss')))
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# ─── Module prerequisite check ────────────────────────────────────────────────
$requiredModules = @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Applications')
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
    $ctx = Get-MgContext
    if ($null -eq $ctx) {
        Write-Error "No Microsoft Graph context. Run: Connect-MgGraph -Scopes 'Application.Read.All'"
        exit 2
    }
    if ('Application.Read.All' -notin $ctx.Scopes) {
        Write-Error "Missing Graph scope: Application.Read.All"
        exit 2
    }
}

function Get-Median {
    param([double[]]$Values)
    if ($Values.Count -eq 0) { return 0 }
    $sorted = $Values | Sort-Object
    $mid = [int]($sorted.Count / 2)
    if ($sorted.Count % 2 -eq 0) {
        return ($sorted[$mid - 1] + $sorted[$mid]) / 2.0
    }
    return $sorted[$mid]
}

function Invoke-CredentialHygiene {
    [CmdletBinding()]
    param([string]$OutputDir)

    Assert-GraphContext

    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  03-credential-hygiene  |  Analysing credentials..." -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "  Fetching app registrations with credential details..." -NoNewline
    $apps = Invoke-WithRetry {
        Get-MgApplication -All -Property 'id,appId,displayName,passwordCredentials,keyCredentials' -ErrorAction Stop
    }
    Write-Host " $($apps.Count) app registrations." -ForegroundColor Green

    $today = [datetime]::UtcNow
    $credRows = [System.Collections.Generic.List[PSObject]]::new()

    $i = 0
    foreach ($app in $apps) {
        $i++
        if ($apps.Count -gt 50) {
            Write-Progress -Activity 'Analysing credentials' -Status "$i / $($apps.Count): $($app.DisplayName)" -PercentComplete (($i / $apps.Count) * 100)
        }

        # Password credentials
        foreach ($cred in $app.PasswordCredentials) {
            $start  = $cred.StartDateTime
            $end    = $cred.EndDateTime
            $lifetimeDays  = if ($start -and $end)  { [int]($end - $start).TotalDays }     else { $null }
            $ageDays       = if ($start)             { [int]($today - $start.ToUniversalTime()).TotalDays } else { $null }
            $daysUntilExpiry = if ($end)             { [int]($end.ToUniversalTime() - $today).TotalDays }   else { $null }
            $expired       = ($end -and $end.ToUniversalTime() -lt $today)
            $longLived     = ($lifetimeDays -and $lifetimeDays -gt 365)
            $veryLongLived = ($lifetimeDays -and $lifetimeDays -gt 730)

            $credRows.Add([PSCustomObject]@{
                AppObjectId      = $app.Id
                AppId            = $app.AppId
                AppDisplayName   = $app.DisplayName
                CredentialType   = 'password'
                KeyId            = $cred.KeyId
                CredentialHint   = $cred.Hint
                CredentialDisplayName = $cred.DisplayName
                StartDateTime    = $start
                EndDateTime      = $end
                LifetimeDays     = $lifetimeDays
                AgeDays          = $ageDays
                DaysUntilExpiry  = $daysUntilExpiry
                Expired          = $expired
                LongLived        = $longLived
                VeryLongLived    = $veryLongLived
            })
        }

        # Key (certificate) credentials
        foreach ($cred in $app.KeyCredentials) {
            $start  = $cred.StartDateTime
            $end    = $cred.EndDateTime
            $lifetimeDays  = if ($start -and $end)  { [int]($end - $start).TotalDays }     else { $null }
            $ageDays       = if ($start)             { [int]($today - $start.ToUniversalTime()).TotalDays } else { $null }
            $daysUntilExpiry = if ($end)             { [int]($end.ToUniversalTime() - $today).TotalDays }   else { $null }
            $expired       = ($end -and $end.ToUniversalTime() -lt $today)
            $longLived     = ($lifetimeDays -and $lifetimeDays -gt 365)
            $veryLongLived = ($lifetimeDays -and $lifetimeDays -gt 730)

            $credRows.Add([PSCustomObject]@{
                AppObjectId      = $app.Id
                AppId            = $app.AppId
                AppDisplayName   = $app.DisplayName
                CredentialType   = 'key'
                KeyId            = $cred.KeyId
                CredentialHint   = $null
                CredentialDisplayName = $cred.DisplayName
                StartDateTime    = $start
                EndDateTime      = $end
                LifetimeDays     = $lifetimeDays
                AgeDays          = $ageDays
                DaysUntilExpiry  = $daysUntilExpiry
                Expired          = $expired
                LongLived        = $longLived
                VeryLongLived    = $veryLongLived
            })
        }
    }
    if ($apps.Count -gt 50) { Write-Progress -Activity 'Analysing credentials' -Completed }

    # ── Aggregations ──────────────────────────────────────────────────────────
    $activePwd     = @($credRows | Where-Object { $_.CredentialType -eq 'password' -and -not $_.Expired })
    $activeKey     = @($credRows | Where-Object { $_.CredentialType -eq 'key'      -and -not $_.Expired })
    $expiredCreds  = @($credRows | Where-Object { $_.Expired })
    $longLived12   = @($activePwd + $activeKey | Where-Object { $_.LongLived })
    $longLived24   = @($activePwd + $activeKey | Where-Object { $_.VeryLongLived })

    $allActiveCreds = $activePwd + $activeKey
    $lifetimeValues = @($allActiveCreds | Where-Object { $null -ne $_.LifetimeDays } | ForEach-Object { [double]$_.LifetimeDays })
    $medianLifetime = [int](Get-Median -Values $lifetimeValues)
    $maxLifetime    = if ($lifetimeValues.Count -gt 0) { [int]($lifetimeValues | Measure-Object -Maximum).Maximum } else { 0 }

    # Apps with > 2 active credentials simultaneously
    $credsByApp = $allActiveCreds | Group-Object AppObjectId
    $multiCredApps = @($credsByApp | Where-Object { $_.Count -gt 2 })

    $certRatio = if (($activePwd.Count + $activeKey.Count) -gt 0) {
        [math]::Round($activeKey.Count / ($activePwd.Count + $activeKey.Count) * 100, 1)
    } else { 0 }

    $aggregations = @{
        TotalActivePasswordCredentials  = $activePwd.Count
        TotalActiveKeyCredentials       = $activeKey.Count
        CertificateToPasswordRatioPct   = $certRatio
        MedianSecretLifetimeDays        = $medianLifetime
        MaxSecretLifetimeDays           = $maxLifetime
        ActiveSecretsOver12Months       = $longLived12.Count
        ActiveSecretsOver24Months       = $longLived24.Count
        ExpiredCredentialsStillAttached = $expiredCreds.Count
        AppRegsWithMoreThan2ActiveCreds = $multiCredApps.Count
    }

    # ── Write CSV ─────────────────────────────────────────────────────────────
    $csvPath = Join-Path $OutputDir '03-credential-hygiene.csv'
    $credRows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

    # ── Write JSON ────────────────────────────────────────────────────────────
    $jsonResult = @{
        CollectedAt  = (Get-Date -Format 'o')
        Aggregations = $aggregations
        Credentials  = @($credRows)
    }
    $jsonPath = Join-Path $OutputDir '03-credential-hygiene.json'
    $jsonResult | ConvertTo-Json -Depth 6 | Out-File -FilePath $jsonPath -Encoding UTF8

    # ── Summary ───────────────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  03-credential-hygiene  SUMMARY" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Total credential rows analysed    : $($credRows.Count)"
    Write-Host ""
    Write-Host "  Active password (secret) creds    : $($activePwd.Count)"
    Write-Host "  Active key (certificate) creds    : $($activeKey.Count)"
    $certColor = if ($certRatio -ge 50) { 'Green' } else { 'Yellow' }
    Write-Host "  Cert-to-total ratio               : $certRatio%" -ForegroundColor $certColor
    Write-Host ""
    Write-Host "  Median active cred lifetime       : $medianLifetime days ($([math]::Round($medianLifetime/30.4,1)) months)"
    Write-Host "  Max active cred lifetime          : $maxLifetime days ($([math]::Round($maxLifetime/30.4,1)) months)"
    Write-Host ""
    $color12 = if ($longLived12.Count -eq 0) { 'Green' } else { 'Red' }
    $color24 = if ($longLived24.Count -eq 0) { 'Green' } else { 'Red' }
    Write-Host "  Active secrets > 12 months old    : $($longLived12.Count)" -ForegroundColor $color12
    Write-Host "  Active secrets > 24 months old    : $($longLived24.Count)" -ForegroundColor $color24
    $expColor = if ($expiredCreds.Count -eq 0) { 'Green' } else { 'Yellow' }
    Write-Host "  Expired creds still attached      : $($expiredCreds.Count)" -ForegroundColor $expColor
    $multiColor = if ($multiCredApps.Count -eq 0) { 'Green' } else { 'Yellow' }
    Write-Host "  App regs with > 2 active creds    : $($multiCredApps.Count)" -ForegroundColor $multiColor
    Write-Host ""
    Write-Host "  Output:"
    Write-Host "    $jsonPath"
    Write-Host "    $csvPath"
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
}

# ─── Entry point ─────────────────────────────────────────────────────────────
try {
    Invoke-CredentialHygiene -OutputDir $OutputDir
} catch {
    Write-Error "03-credential-hygiene failed: $_"
    exit 1
}
