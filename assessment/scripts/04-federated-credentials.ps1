<#
.SYNOPSIS
    Enumerates federated identity credentials (FICs) on both app registrations
    and user-assigned managed identities, and classifies issuer + subject.

.DESCRIPTION
    Answers discovery questions:
      Q16/Q17 — CI/CD pipelines, non-Azure cloud workloads identified by issuer
      Q19     — Federated credentials implemented
      Q39     — Broad federated credential subjects (WILDCARD / BROAD)

    Classifies each FIC:
      issuer  → github-actions | azure-devops | gitlab | aks | kubernetes |
                azure-mi | other
      subject → WILDCARD (contains '*') | BROAD (repo-level, no ref/env) |
                NARROW (fully qualified)

    Prereq modules  : Microsoft.Graph.Authentication,
                      Microsoft.Graph.Applications,
                      Az.Accounts, Az.ResourceGraph

    Prereq scopes   : Application.Read.All

    Prereq Az roles : Reader (subscription-level)

    Produces:
      <OutputDir>/04-federated-credentials.json
      <OutputDir>/04-federated-credentials.csv

.EXAMPLE
    ./scripts/04-federated-credentials.ps1 -OutputDir ./output/20260101-120000
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

function Assert-Contexts {
    $mgCtx = Get-MgContext
    if ($null -eq $mgCtx) {
        Write-Error "No Microsoft Graph context. Run: Connect-MgGraph -Scopes 'Application.Read.All'"
        exit 2
    }
    if ('Application.Read.All' -notin $mgCtx.Scopes) {
        Write-Error "Missing Graph scope: Application.Read.All"
        exit 2
    }
}

function Get-IssuerCategory {
    param([string]$Issuer)
    if (-not $Issuer) { return 'other' }
    if ($Issuer -match 'token\.actions\.githubusercontent\.com') { return 'github-actions' }
    if ($Issuer -match 'vstoken\.dev\.azure\.com|app\.vssps\.visualstudio\.com') { return 'azure-devops' }
    if ($Issuer -match 'gitlab\.com') { return 'gitlab' }
    if ($Issuer -match 'oidc\.prod-aks\.azure\.com|aks\.azure\.com') { return 'aks' }
    if ($Issuer -match 'kubernetes\.default\.svc|oidc\.eks\.' -or $Issuer -match 'container\.googleapis\.com') { return 'kubernetes' }
    if ($Issuer -match '\.identity\.azure\.net') { return 'azure-mi' }
    return 'other'
}

function Get-SubjectClassification {
    param([string]$Subject)
    if (-not $Subject) { return 'NARROW' }
    if ($Subject -match '\*') { return 'WILDCARD' }
    # GitHub Actions broad subject: "repo:owner/repo" without a trailing :ref: or :environment:
    if ($Subject -match '^repo:[^/]+/[^:]+$') { return 'BROAD' }
    # GitLab broad: project path without ref
    if ($Subject -match '^project_path:[^:]+:ref_type:branch$' -and $Subject -notmatch ':ref:') { return 'BROAD' }
    return 'NARROW'
}

function Get-AppRegFICs {
    [CmdletBinding()]
    param()

    Write-Host "  Fetching app registrations for FIC enumeration..." -NoNewline
    $apps = Invoke-WithRetry {
        Get-MgApplication -All -Property 'id,appId,displayName' -ErrorAction Stop
    }
    Write-Host " $($apps.Count) app registrations." -ForegroundColor Green

    $rows = [System.Collections.Generic.List[PSObject]]::new()
    $i = 0
    foreach ($app in $apps) {
        $i++
        if ($apps.Count -gt 50) {
            Write-Progress -Activity 'Enumerating app reg FICs' -Status "$i / $($apps.Count): $($app.DisplayName)" -PercentComplete (($i / $apps.Count) * 100)
        }

        try {
            $fics = Invoke-WithRetry {
                Get-MgApplicationFederatedIdentityCredential -ApplicationId $app.Id -All -ErrorAction Stop
            }
            foreach ($fic in $fics) {
                $issuerCat = Get-IssuerCategory -Issuer $fic.Issuer
                $subjectClass = Get-SubjectClassification -Subject $fic.Subject

                $rows.Add([PSCustomObject]@{
                    Target              = 'appRegistration'
                    TargetId            = $app.Id
                    TargetAppId         = $app.AppId
                    TargetName          = $app.DisplayName
                    FicId               = $fic.Id
                    FicName             = $fic.Name
                    Issuer              = $fic.Issuer
                    IssuerCategory      = $issuerCat
                    Subject             = $fic.Subject
                    SubjectClassification = $subjectClass
                    Audiences           = ($fic.Audiences -join ';')
                    Description         = $fic.Description
                })
            }
        } catch {
            Write-Verbose "Could not get FICs for app $($app.Id): $_"
        }
    }
    if ($apps.Count -gt 50) { Write-Progress -Activity 'Enumerating app reg FICs' -Completed }
    return $rows
}

function Get-UserAssignedMIFICs {
    [CmdletBinding()]
    param()

    Write-Host "  Fetching user-assigned MIs for FIC enumeration..." -NoNewline
    $rows = [System.Collections.Generic.List[PSObject]]::new()

    try {
        $uaQuery = @"
Resources
| where type =~ 'microsoft.managedidentity/userassignedidentities'
| project
    name        = name,
    resourceId  = id,
    principalId = properties.principalId,
    clientId    = properties.clientId,
    subscriptionId = subscriptionId,
    resourceGroup  = resourceGroup
"@
        $uaMIs = Invoke-WithRetry { Search-AzGraph -Query $uaQuery -First 1000 -ErrorAction Stop }
        Write-Host " $($uaMIs.Count) user-assigned MIs." -ForegroundColor Green

        $i = 0
        foreach ($mi in $uaMIs) {
            $i++
            if ($uaMIs.Count -gt 50) {
                Write-Progress -Activity 'Enumerating MI FICs' -Status "$i / $($uaMIs.Count): $($mi.name)" -PercentComplete (($i / $uaMIs.Count) * 100)
            }

            try {
                $apiVersion = '2023-01-31'
                $ficUri = "$($mi.resourceId)/federatedIdentityCredentials?api-version=$apiVersion"
                $response = Invoke-WithRetry {
                    Invoke-AzRestMethod -Method GET -Path $ficUri -ErrorAction Stop
                }

                if ($response.StatusCode -eq 200) {
                    $ficData = $response.Content | ConvertFrom-Json
                    foreach ($fic in $ficData.value) {
                        $issuerCat    = Get-IssuerCategory -Issuer $fic.properties.issuer
                        $subjectClass = Get-SubjectClassification -Subject $fic.properties.subject

                        $rows.Add([PSCustomObject]@{
                            Target              = 'userAssignedMI'
                            TargetId            = $mi.resourceId
                            TargetAppId         = $mi.clientId
                            TargetName          = $mi.name
                            FicId               = $fic.id
                            FicName             = $fic.name
                            Issuer              = $fic.properties.issuer
                            IssuerCategory      = $issuerCat
                            Subject             = $fic.properties.subject
                            SubjectClassification = $subjectClass
                            Audiences           = ($fic.properties.audiences -join ';')
                            Description         = $null
                        })
                    }
                } else {
                    Write-Verbose "Non-200 response for MI FICs $($mi.resourceId): $($response.StatusCode)"
                }
            } catch {
                Write-Verbose "Could not get FICs for MI $($mi.resourceId): $_"
            }
        }
        if ($uaMIs.Count -gt 50) { Write-Progress -Activity 'Enumerating MI FICs' -Completed }
    } catch {
        Write-Warning "Could not enumerate user-assigned MIs for FIC check: $_"
    }

    return $rows
}

function Invoke-FederatedCredentials {
    [CmdletBinding()]
    param([string]$OutputDir)

    Assert-Contexts

    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  04-federated-credentials  |  Enumerating FICs..." -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""

    $appRegFics = Get-AppRegFICs
    $miFics     = Get-UserAssignedMIFICs

    $allFics = [System.Collections.Generic.List[PSObject]]::new()
    foreach ($r in @($appRegFics)) { $allFics.Add([PSObject]$r) }
    foreach ($r in @($miFics))     { $allFics.Add([PSObject]$r) }

    # ── Write CSV ─────────────────────────────────────────────────────────────
    $csvPath = Join-Path $OutputDir '04-federated-credentials.csv'
    if ($allFics.Count -gt 0) {
        $allFics | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    } else {
        [PSCustomObject]@{ Note = 'No federated identity credentials found' } |
            Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    }

    # ── Write JSON ────────────────────────────────────────────────────────────
    $issuerStats   = $allFics | Group-Object IssuerCategory  | Sort-Object Count -Descending
    $subjectStats  = $allFics | Group-Object SubjectClassification | Sort-Object Count -Descending
    $targetStats   = $allFics | Group-Object Target | Sort-Object Count -Descending

    $jsonResult = @{
        CollectedAt        = (Get-Date -Format 'o')
        TotalFICs          = $allFics.Count
        FICsOnAppRegs      = $appRegFics.Count
        FICsOnUserAssignedMIs = $miFics.Count
        ByIssuerCategory   = @($issuerStats   | ForEach-Object { @{ Category = $_.Name; Count = $_.Count } })
        BySubjectClass     = @($subjectStats  | ForEach-Object { @{ Classification = $_.Name; Count = $_.Count } })
        FederatedCredentials = @($allFics)
    }
    $jsonPath = Join-Path $OutputDir '04-federated-credentials.json'
    $jsonResult | ConvertTo-Json -Depth 6 | Out-File -FilePath $jsonPath -Encoding UTF8

    # ── Summary ───────────────────────────────────────────────────────────────
    $wildcardCount = @($allFics | Where-Object { $_.SubjectClassification -eq 'WILDCARD' }).Count
    $broadCount    = @($allFics | Where-Object { $_.SubjectClassification -eq 'BROAD' }).Count
    $narrowCount   = @($allFics | Where-Object { $_.SubjectClassification -eq 'NARROW' }).Count

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  04-federated-credentials  SUMMARY" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Total FICs                    : $($allFics.Count)"
    Write-Host "    On app registrations        : $($appRegFics.Count)"
    Write-Host "    On user-assigned MIs        : $($miFics.Count)"
    Write-Host ""
    Write-Host "  By issuer category:" -ForegroundColor White
    foreach ($g in $issuerStats) {
        Write-Host "    $($g.Name.PadRight(20)) : $($g.Count)"
    }
    Write-Host ""
    Write-Host "  By subject classification:" -ForegroundColor White
    $wcColor = if ($wildcardCount -gt 0) { 'Red'    } else { 'Green' }
    $brColor = if ($broadCount -gt 0)    { 'Yellow' } else { 'Green' }
    Write-Host "    WILDCARD (*)              : $wildcardCount" -ForegroundColor $wcColor
    Write-Host "    BROAD (env/ref-less)      : $broadCount"   -ForegroundColor $brColor
    Write-Host "    NARROW (fully qualified)  : $narrowCount"  -ForegroundColor Green
    Write-Host ""
    Write-Host "  Output:"
    Write-Host "    $jsonPath"
    Write-Host "    $csvPath"
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
}

# ─── Entry point ─────────────────────────────────────────────────────────────
try {
    Invoke-FederatedCredentials -OutputDir $OutputDir
} catch {
    Write-Error "04-federated-credentials failed: $_"
    exit 1
}
