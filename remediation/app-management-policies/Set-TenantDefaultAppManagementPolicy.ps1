<#
.SYNOPSIS
    Configures the tenant-default appManagementPolicy to enforce
    secret/cert hygiene at the directory level.

.DESCRIPTION
    Drives the same eight controls visible in the Entra portal:
    Enterprise applications -> Application policies -> Default app
    management policy. All controls are off by default.

    Supports a "soft launch" mode that only applies the rules to apps
    created after a given date — existing apps are unaffected.

    REQUIRES Microsoft.Graph PowerShell SDK and the
    Policy.ReadWrite.ApplicationConfiguration delegated scope.

    THIS SCRIPT MODIFIES TENANT STATE. Review the parameters before
    running and prefer -WhatIf for the first invocation.

.PARAMETER BlockPasswordAddition
    Block adding any new client secret to applications. Existing
    secrets keep working until expiry.

.PARAMETER MaxPasswordLifetimeDays
    Cap the lifetime of newly-added client secrets. 0 = unset.

.PARAMETER BlockCustomPasswords
    Block app-supplied (BYO) secret values. Force Entra to generate
    the secret.

.PARAMETER MaxCertificateLifetimeDays
    Cap the lifetime of newly-added asymmetric (cert) credentials.
    0 = unset.

.PARAMETER BlockCustomIdentifierUris
    Block app owners from setting arbitrary identifier URIs.

.PARAMETER BlockNonUniqueTenantIdentifierUris
    Block identifier URIs that don't include a unique tenant
    identifier. (Default On in modern tenants — keep on.)

.PARAMETER BlockMultiTenantApps
    Block creating new apps with multitenant sign-in audience.

.PARAMETER BlockConsumerApps
    Block creating new apps with personal-MSA sign-in audience.

.PARAMETER RestrictForAppsCreatedAfter
    Soft-launch date. If set, restrictions only apply to apps
    created after this UTC date — existing apps are exempt.
    Recommended: pass (Get-Date).ToUniversalTime() for "starting now".

.PARAMETER WhatIf
    Show the JSON body that would be sent without applying it.

.EXAMPLE
    # Soft launch: lock down only NEW apps from now on
    ./Set-TenantDefaultAppManagementPolicy.ps1 `
        -BlockPasswordAddition `
        -MaxCertificateLifetimeDays 365 `
        -BlockCustomPasswords `
        -BlockMultiTenantApps `
        -BlockConsumerApps `
        -RestrictForAppsCreatedAfter (Get-Date).ToUniversalTime()

.EXAMPLE
    # Hard enforcement: applies to all existing apps too
    ./Set-TenantDefaultAppManagementPolicy.ps1 `
        -BlockPasswordAddition `
        -MaxPasswordLifetimeDays 180 `
        -BlockCustomPasswords `
        -MaxCertificateLifetimeDays 365 `
        -BlockCustomIdentifierUris `
        -BlockMultiTenantApps `
        -BlockConsumerApps
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$BlockPasswordAddition,
    [int]$MaxPasswordLifetimeDays = 0,
    [switch]$BlockCustomPasswords,
    [int]$MaxCertificateLifetimeDays = 0,
    [switch]$BlockCustomIdentifierUris,
    [switch]$BlockNonUniqueTenantIdentifierUris,
    [switch]$BlockMultiTenantApps,
    [switch]$BlockConsumerApps,
    [datetime]$RestrictForAppsCreatedAfter
)

$ErrorActionPreference = 'Stop'

if (-not (Get-MgContext)) {
    Write-Error "Not connected to Microsoft Graph. Run: Connect-MgGraph -Scopes 'Policy.ReadWrite.ApplicationConfiguration','Application.Read.All'"
    return
}

function Add-Restriction($collection, $type, $extra = @{}) {
    $r = @{ restrictionType = $type; state = 'enabled' } + $extra
    if ($RestrictForAppsCreatedAfter) {
        $r.restrictForAppsCreatedAfterDateTime = $RestrictForAppsCreatedAfter.ToUniversalTime().ToString('o')
    }
    [void]$collection.Add($r)
}

$pwd  = New-Object System.Collections.Generic.List[hashtable]
$key  = New-Object System.Collections.Generic.List[hashtable]
$idu  = New-Object System.Collections.Generic.List[hashtable]
$aud  = New-Object System.Collections.Generic.List[hashtable]

if ($BlockPasswordAddition)             { Add-Restriction $pwd 'passwordAddition' }
if ($MaxPasswordLifetimeDays -gt 0)     { Add-Restriction $pwd 'passwordLifetime' @{ maxLifetime = "P$($MaxPasswordLifetimeDays)D" } }
if ($BlockCustomPasswords)              { Add-Restriction $pwd 'customPasswordAddition' }

if ($MaxCertificateLifetimeDays -gt 0)  { Add-Restriction $key 'asymmetricKeyLifetime' @{ maxLifetime = "P$($MaxCertificateLifetimeDays)D" } }

if ($BlockCustomIdentifierUris)         { Add-Restriction $idu 'customAppIdentifier' }
if ($BlockNonUniqueTenantIdentifierUris){ Add-Restriction $idu 'nonDefaultUriAddition' }

if ($BlockMultiTenantApps)              { Add-Restriction $aud 'azureADMultipleOrgs' }
if ($BlockConsumerApps)                 { Add-Restriction $aud 'personalMicrosoftAccount' }

$body = @{
    isEnabled = $true
    applicationRestrictions = @{
        passwordCredentials       = @($pwd)
        keyCredentials            = @($key)
        identifierUris            = @{ nonDefaultUriAddition = @($idu | Where-Object restrictionType -eq 'nonDefaultUriAddition'); customAppIdentifier = @($idu | Where-Object restrictionType -eq 'customAppIdentifier') }
    }
    servicePrincipalRestrictions = @{
        passwordCredentials = @($pwd)
        keyCredentials      = @($key)
    }
}

# Sign-in audience controls live on the application object only
if ($aud.Count -gt 0) {
    $body.applicationRestrictions.audiences = @($aud)
}

$json = $body | ConvertTo-Json -Depth 10

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════"
Write-Host "  Default app management policy — proposed body"
Write-Host "═══════════════════════════════════════════════════════════════"
Write-Host $json
Write-Host ""

if ($PSCmdlet.ShouldProcess('Tenant default app management policy', 'Update')) {
    Invoke-MgGraphRequest `
        -Method PATCH `
        -Uri 'https://graph.microsoft.com/v1.0/policies/defaultAppManagementPolicy' `
        -Body $json `
        -ContentType 'application/json' | Out-Null
    Write-Host "  Applied." -ForegroundColor Green
} else {
    Write-Host "  -WhatIf: no changes made." -ForegroundColor Yellow
}
