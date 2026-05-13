<#
.SYNOPSIS
    Reads the current tenant-default appManagementPolicy and prints it
    as a human-readable summary.

.DESCRIPTION
    Read-only. Calls GET /policies/defaultAppManagementPolicy.
    Useful before/after changes and for evidence collection.

    REQUIRES Microsoft.Graph PowerShell SDK and the
    Policy.Read.All delegated scope.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

if (-not (Get-MgContext)) {
    Write-Error "Not connected to Microsoft Graph. Run: Connect-MgGraph -Scopes 'Policy.Read.All'"
    return
}

$p = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/policies/defaultAppManagementPolicy'

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════"
Write-Host "  Default app management policy"
Write-Host "═══════════════════════════════════════════════════════════════"
Write-Host ("  Enabled       : {0}" -f $p.isEnabled)
Write-Host ("  DisplayName   : {0}" -f $p.displayName)
Write-Host ("  Id            : {0}" -f $p.id)
Write-Host ""

function Write-Restrictions($title, $list) {
    Write-Host "  $title"
    if (-not $list -or $list.Count -eq 0) { Write-Host "    (none)"; return }
    foreach ($r in $list) {
        $extras = @()
        if ($r.maxLifetime) { $extras += "max=$($r.maxLifetime)" }
        if ($r.restrictForAppsCreatedAfterDateTime) { $extras += "newOnly>=$($r.restrictForAppsCreatedAfterDateTime)" }
        $tail = if ($extras) { '  (' + ($extras -join ', ') + ')' } else { '' }
        Write-Host ("    [{0}] {1}{2}" -f $r.state, $r.restrictionType, $tail)
    }
}

if ($p.applicationRestrictions) {
    Write-Host "  applicationRestrictions:"
    Write-Restrictions "    passwordCredentials" $p.applicationRestrictions.passwordCredentials
    Write-Restrictions "    keyCredentials"      $p.applicationRestrictions.keyCredentials
    if ($p.applicationRestrictions.identifierUris) {
        Write-Host "    identifierUris:"
        Write-Restrictions "      customAppIdentifier"   $p.applicationRestrictions.identifierUris.customAppIdentifier
        Write-Restrictions "      nonDefaultUriAddition" $p.applicationRestrictions.identifierUris.nonDefaultUriAddition
    }
    Write-Restrictions "    audiences" $p.applicationRestrictions.audiences
}

if ($p.servicePrincipalRestrictions) {
    Write-Host ""
    Write-Host "  servicePrincipalRestrictions:"
    Write-Restrictions "    passwordCredentials" $p.servicePrincipalRestrictions.passwordCredentials
    Write-Restrictions "    keyCredentials"      $p.servicePrincipalRestrictions.keyCredentials
}

Write-Host ""
