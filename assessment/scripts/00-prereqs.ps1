<#
.SYNOPSIS
    Validates prerequisites for the Workload Identity Assessment toolkit.

.DESCRIPTION
    Checks PowerShell version, installs/updates required modules, and prints
    the Graph delegated scopes and Azure roles the consultant must have before
    running assessment scripts 01–08.

    Does NOT call Connect-MgGraph — the consultant runs that interactively to
    consent the correct scopes.

.EXAMPLE
    ./scripts/00-prereqs.ps1

.NOTES
    Required modules (checked + installed if missing):
        Microsoft.Graph.Authentication, Microsoft.Graph.Applications,
        Microsoft.Graph.Identity.DirectoryManagement,
        Microsoft.Graph.Identity.SignIns,
        Microsoft.Graph.Identity.Governance,
        Microsoft.Graph.Reports,
        Az.Accounts, Az.Resources, Az.ResourceGraph,
        Az.KeyVault, Az.Monitor

    No Graph connection required — this script is pure local validation.
#>

[CmdletBinding()]
param(
    # Force a clean reinstall: uninstall ALL versions of Microsoft.Graph.* and Az.* then reinstall once.
    # Use this when you hit "Assembly with same name is already loaded" errors.
    [switch]$CleanInstall,

    # Skip interactive prompts; install/upgrade/clean automatically.
    [switch]$NonInteractive
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# ─── Required module catalogue ────────────────────────────────────────────────
$requiredModules = @(
    @{ Name = 'Microsoft.Graph.Authentication';                MinVersion = '2.15.0' }
    @{ Name = 'Microsoft.Graph.Applications';                  MinVersion = '2.15.0' }
    @{ Name = 'Microsoft.Graph.Identity.DirectoryManagement';  MinVersion = '2.15.0' }
    @{ Name = 'Microsoft.Graph.Identity.SignIns';              MinVersion = '2.15.0' }
    @{ Name = 'Microsoft.Graph.Identity.Governance';           MinVersion = '2.15.0' }
    @{ Name = 'Microsoft.Graph.Reports';                       MinVersion = '2.15.0' }
    @{ Name = 'Az.Accounts';                                   MinVersion = '3.0.0'  }
    @{ Name = 'Az.Resources';                                  MinVersion = '7.0.0'  }
    @{ Name = 'Az.ResourceGraph';                              MinVersion = '1.0.0'  }
    @{ Name = 'Az.KeyVault';                                   MinVersion = '6.0.0'  }
    @{ Name = 'Az.Monitor';                                    MinVersion = '5.0.0'  }
)

# ─── Required Graph delegated scopes ─────────────────────────────────────────
$requiredScopes = @(
    'Application.Read.All'
    'Directory.Read.All'
    'Policy.Read.All'
    'AuditLog.Read.All'
    'IdentityRiskEvent.Read.All'
    'RoleManagement.Read.Directory'
    'CrossTenantInformation.ReadBasic.All'
)

# ─── Required Azure roles ─────────────────────────────────────────────────────
$requiredAzureRoles = @(
    'Reader                  — on each in-scope subscription (covers Resource Graph, RBAC enumeration, KV config, diagnostic settings)'
    'Monitoring Reader        — on each in-scope subscription / resource group (for diagnostic settings read; Reader usually sufficient)'
    'Key Vault Reader         — on Key Vaults if RBAC-protected (to read KV configuration metadata)'
)

function Confirm-Action {
    param([string]$Prompt, [string]$Default = 'Y')
    if ($NonInteractive) { return ($Default -eq 'Y') }
    $resp = Read-Host "    $Prompt [Y/n]"
    if ([string]::IsNullOrWhiteSpace($resp)) { $resp = $Default }
    return ($resp -ne 'n' -and $resp -ne 'N')
}

function Test-ModuleHealth {
    <#
        Detects three problem patterns that cause assembly-load conflicts at runtime:
          1. Multiple side-by-side versions of the same Microsoft.Graph.* / Az.* module
          2. Version skew — Microsoft.Graph.Authentication present at a different version
             than its dependent submodules (and same check for Az.Accounts)
          3. Loaded-into-current-session DLLs (cleanup requires `exit` + new pwsh)
    #>
    param([string[]]$ModuleFamilies = @('Microsoft.Graph', 'Az'))

    Write-Host "▶ PowerShell Module Health (Graph + Az)" -ForegroundColor White

    $hasAnyProblem = $false
    $cleanupNeeded = @()

    foreach ($family in $ModuleFamilies) {
        $pattern = "$family*"
        $allInFamily = Get-Module $pattern -ListAvailable

        if (-not $allInFamily) {
            Write-Host "  [INFO] No $family modules installed yet." -ForegroundColor Gray
            continue
        }

        $coreModuleName = if ($family -eq 'Microsoft.Graph') { 'Microsoft.Graph.Authentication' }
                          elseif ($family -eq 'Az')          { 'Az.Accounts' }
                          else                                { $null }

        $sideBySide = $allInFamily | Group-Object Name | Where-Object Count -gt 1
        $coreVersions = if ($coreModuleName) {
            ($allInFamily | Where-Object Name -eq $coreModuleName |
             Select-Object -ExpandProperty Version | Sort-Object -Unique)
        } else { @() }
        $skewed = ($coreVersions.Count -gt 1)

        $loadedInSession = Get-Module $pattern | Select-Object Name, Version

        $hasProblem = ($sideBySide.Count -gt 0) -or $skewed
        if (-not $hasProblem) {
            Write-Host "  [OK] $family — $($allInFamily.Count) module(s), no version skew." -ForegroundColor Green
            continue
        }

        $hasAnyProblem = $true
        $cleanupNeeded += $family
        Write-Host ""
        Write-Host "  ⚠  $family MODULE VERSION CONFLICT DETECTED" -ForegroundColor Red
        if ($sideBySide.Count -gt 0) {
            Write-Host "  Side-by-side installs:" -ForegroundColor Yellow
            foreach ($g in $sideBySide) {
                $vers = ($g.Group | Sort-Object Version | Select-Object -ExpandProperty Version) -join ', '
                Write-Host "      $($g.Name) → $vers" -ForegroundColor White
            }
        }
        if ($skewed) {
            Write-Host "  $coreModuleName installed at multiple versions:" -ForegroundColor Yellow
            Write-Host "      $($coreVersions -join ', ')" -ForegroundColor White
            Write-Host "  Dependent submodules will fail with 'Assembly with same name is already loaded'." -ForegroundColor Yellow
        }
        if ($loadedInSession) {
            Write-Host "  ⚠  Some $family modules are LOADED in this pwsh session:" -ForegroundColor Yellow
            foreach ($m in $loadedInSession) {
                Write-Host "      $($m.Name) $($m.Version) (loaded)" -ForegroundColor White
            }
        }
    }

    Write-Host ""

    if (-not $hasAnyProblem) { return $true }

    $anyLoaded = (Get-Module Microsoft.Graph*) -or (Get-Module Az.*)

    if (-not $CleanInstall) {
        Write-Host "  Re-run with -CleanInstall to uninstall conflicting versions and reinstall fresh:" -ForegroundColor Cyan
        Write-Host "      ./scripts/00-prereqs.ps1 -CleanInstall" -ForegroundColor Cyan
        Write-Host ""
        if ($anyLoaded) {
            Write-Host "  ⚠  IMPORTANT: exit this pwsh first, then open a fresh one before -CleanInstall." -ForegroundColor Red
            Write-Host ""
        }
        return $false
    }

    # ── -CleanInstall path ─────────────────────────────────────────────────────
    if ($anyLoaded) {
        Write-Host "  ✗ Cannot clean install: modules are loaded in this session." -ForegroundColor Red
        Write-Host "    1. Run: Disconnect-MgGraph -ErrorAction SilentlyContinue" -ForegroundColor Cyan
        Write-Host "    2. Run: Disconnect-AzAccount -ErrorAction SilentlyContinue" -ForegroundColor Cyan
        Write-Host "    3. Run: exit" -ForegroundColor Cyan
        Write-Host "    4. Open a fresh pwsh and run: ./scripts/00-prereqs.ps1 -CleanInstall" -ForegroundColor Cyan
        Write-Host ""
        return $false
    }

    if (-not (Confirm-Action "Uninstall conflicting module versions and reinstall fresh?")) {
        Write-Host "  Skipped clean install." -ForegroundColor Yellow
        return $false
    }

    if ('Microsoft.Graph' -in $cleanupNeeded) {
        Write-Host "  Uninstalling all Microsoft.Graph* versions..." -NoNewline
        Get-Module Microsoft.Graph* -ListAvailable | ForEach-Object {
            Uninstall-Module $_.Name -RequiredVersion $_.Version -Force -ErrorAction SilentlyContinue
        }
        Write-Host " done." -ForegroundColor Green
        Write-Host "  Installing Microsoft.Graph (single version)..." -NoNewline
        Install-Module Microsoft.Graph      -Scope CurrentUser -Force -AllowClobber
        Write-Host " done." -ForegroundColor Green
        Write-Host "  Installing Microsoft.Graph.Beta (single version)..." -NoNewline
        Install-Module Microsoft.Graph.Beta -Scope CurrentUser -Force -AllowClobber
        Write-Host " done." -ForegroundColor Green
    }

    if ('Az' -in $cleanupNeeded) {
        Write-Host "  Uninstalling all Az.* versions..." -NoNewline
        Get-Module Az.* -ListAvailable | ForEach-Object {
            Uninstall-Module $_.Name -RequiredVersion $_.Version -Force -ErrorAction SilentlyContinue
        }
        Write-Host " done." -ForegroundColor Green
        Write-Host "  Installing Az (single version, this is large — ~5 min)..." -NoNewline
        Install-Module Az -Scope CurrentUser -Force -AllowClobber
        Write-Host " done." -ForegroundColor Green
    }

    Write-Host "  [OK] Clean install complete." -ForegroundColor Green
    Write-Host ""
    return $true
}



function Test-PowerShellVersion {
    $minMajor = 7; $minMinor = 2
    if ($PSVersionTable.PSVersion.Major -lt $minMajor -or
        ($PSVersionTable.PSVersion.Major -eq $minMajor -and $PSVersionTable.PSVersion.Minor -lt $minMinor)) {
        Write-Error "PowerShell $($PSVersionTable.PSVersion) detected. Version >= 7.2 is required. Download from https://github.com/PowerShell/PowerShell/releases"
        exit 2
    }
    Write-Host "  [OK] PowerShell $($PSVersionTable.PSVersion)" -ForegroundColor Green
}

function Test-AndInstallModules {
    [CmdletBinding()]
    param([array]$Modules)

    $allOk = $true
    foreach ($mod in $Modules) {
        $installed = Get-Module -ListAvailable -Name $mod.Name |
                     Sort-Object Version -Descending |
                     Select-Object -First 1

        $minVer = [Version]$mod.MinVersion

        if ($null -eq $installed) {
            Write-Host "  [MISSING] $($mod.Name) (min $($mod.MinVersion))" -ForegroundColor Yellow
            if (Confirm-Action "Install $($mod.Name) now?") {
                Write-Host "    Installing $($mod.Name)..." -NoNewline
                Install-Module -Name $mod.Name -MinimumVersion $mod.MinVersion -Scope CurrentUser -Force -AllowClobber
                Write-Host " done." -ForegroundColor Green
            } else {
                Write-Host "    Skipped. Assessment scripts may fail without this module." -ForegroundColor Red
                $allOk = $false
            }
        } elseif ($installed.Version -lt $minVer) {
            Write-Host "  [OUTDATED] $($mod.Name) $($installed.Version) (need >= $($mod.MinVersion))" -ForegroundColor Yellow
            if (Confirm-Action "Update $($mod.Name) now?") {
                Write-Host "    Updating $($mod.Name)..." -NoNewline
                Install-Module -Name $mod.Name -MinimumVersion $mod.MinVersion -Scope CurrentUser -Force -AllowClobber
                Write-Host " done." -ForegroundColor Green
            } else {
                Write-Host "    Skipped. Assessment scripts may fail with this older version." -ForegroundColor Red
                $allOk = $false
            }
        } else {
            Write-Host "  [OK] $($mod.Name) $($installed.Version)" -ForegroundColor Green
        }
    }
    return $allOk
}

function Invoke-PrereqCheck {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Workload Identity Assessment — Prerequisite Checker" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""

    # ── 1. PowerShell version ──────────────────────────────────────────────────
    Write-Host "▶ PowerShell Version" -ForegroundColor White
    Test-PowerShellVersion
    Write-Host ""

    # ── 2. Module health check (BEFORE module install loop) ─────────────────
    $healthOk = Test-ModuleHealth
    if (-not $healthOk -and -not $CleanInstall) {
        Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host "  STATUS: Module conflict — re-run with -CleanInstall." -ForegroundColor Red
        Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        exit 2
    }

    # ── 3. Required modules ────────────────────────────────────────────────────
    Write-Host "▶ Required Modules" -ForegroundColor White
    $modulesOk = Test-AndInstallModules -Modules $requiredModules
    Write-Host ""

    # ── 3. Graph scopes ────────────────────────────────────────────────────────
    Write-Host "▶ Required Microsoft Graph Delegated Scopes" -ForegroundColor White
    Write-Host "  Run this command before executing assessment scripts:" -ForegroundColor Gray
    Write-Host ""
    $scopeList = $requiredScopes -join '","'
    Write-Host "  Connect-MgGraph -Scopes `"$scopeList`"" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Individual scopes required:" -ForegroundColor Gray
    foreach ($scope in $requiredScopes) {
        Write-Host "    • $scope" -ForegroundColor White
    }
    Write-Host ""
    Write-Host "  Scope purposes:" -ForegroundColor Gray
    Write-Host "    Application.Read.All              → App registrations, service principals, FICs"
    Write-Host "    Directory.Read.All                → Org info, users, groups, roles"
    Write-Host "    Policy.Read.All                   → Authorization policy, consent policy, CA policies"
    Write-Host "    AuditLog.Read.All                 → Sign-in activity for service principals"
    Write-Host "    IdentityRiskEvent.Read.All        → Risky workload identities (requires WI Premium)"
    Write-Host "    RoleManagement.Read.Directory     → Directory role assignments"
    Write-Host "    CrossTenantInformation.ReadBasic.All → Cross-tenant access policy defaults"
    Write-Host ""

    # ── 4. Azure roles ─────────────────────────────────────────────────────────
    Write-Host "▶ Required Azure Roles" -ForegroundColor White
    Write-Host "  Run this command before executing assessment scripts:" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Connect-AzAccount" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Role assignments required:" -ForegroundColor Gray
    foreach ($role in $requiredAzureRoles) {
        Write-Host "    • $role" -ForegroundColor White
    }
    Write-Host ""

    # ── 5. Typical run instructions ───────────────────────────────────────────
    Write-Host "▶ Typical Run Sequence" -ForegroundColor White
    Write-Host ""
    Write-Host "  # 1. Connect (interactive — paste into your terminal):" -ForegroundColor Gray
    Write-Host "  Connect-MgGraph -Scopes `"Application.Read.All`",`"Directory.Read.All`",`"Policy.Read.All`",`"AuditLog.Read.All`",`"IdentityRiskEvent.Read.All`",`"RoleManagement.Read.Directory`",`"CrossTenantInformation.ReadBasic.All`"" -ForegroundColor Yellow
    Write-Host "  Connect-AzAccount" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  # 2. Run all assessment scripts:" -ForegroundColor Gray
    Write-Host "  ./scripts/run-all.ps1 -OutputDir ./output -SubscriptionIds @('sub-id-1','sub-id-2')" -ForegroundColor Yellow
    Write-Host ""

    # ── 6. Final status ───────────────────────────────────────────────────────
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    if ($modulesOk) {
        Write-Host "  STATUS: All module prerequisites satisfied." -ForegroundColor Green
        Write-Host "  Next: Connect-MgGraph + Connect-AzAccount, then run-all.ps1" -ForegroundColor Green
    } else {
        Write-Host "  STATUS: One or more modules are missing/outdated. Re-run this script." -ForegroundColor Yellow
    }
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
}

Invoke-PrereqCheck
exit 0
