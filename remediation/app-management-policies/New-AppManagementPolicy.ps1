<#
.SYNOPSIS
    Creates a named appManagementPolicy and (optionally) assigns it to
    one or more applications or service principals.

.DESCRIPTION
    Use this for stricter rules on a subset of "privileged" apps when
    the tenant-default policy is intentionally permissive.

    THIS SCRIPT MODIFIES TENANT STATE.

    REQUIRES Microsoft.Graph PowerShell SDK and the
    Policy.ReadWrite.ApplicationConfiguration delegated scope.

.PARAMETER DisplayName
    Required. Name of the policy. Must be unique in the tenant.

.PARAMETER Description
    Optional. Free-text description.

.PARAMETER BlockPasswordAddition
.PARAMETER MaxPasswordLifetimeDays
.PARAMETER BlockCustomPasswords
.PARAMETER MaxCertificateLifetimeDays
.PARAMETER RestrictForAppsCreatedAfter
    See Set-TenantDefaultAppManagementPolicy.ps1 for semantics.

.PARAMETER ApplicationObjectIds
    Application object IDs to assign the policy to (the appReg's
    object ID, NOT the appId/clientId).

.PARAMETER ServicePrincipalObjectIds
    Service principal object IDs to assign the policy to.

.EXAMPLE
    ./New-AppManagementPolicy.ps1 `
        -DisplayName 'privileged-apps-no-secrets' `
        -Description 'Apps with sensitive Graph permissions' `
        -BlockPasswordAddition `
        -MaxCertificateLifetimeDays 365 `
        -ApplicationObjectIds 'aaaaaaaa-...','bbbbbbbb-...'
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)][string]$DisplayName,
    [string]$Description,
    [switch]$BlockPasswordAddition,
    [int]$MaxPasswordLifetimeDays = 0,
    [switch]$BlockCustomPasswords,
    [int]$MaxCertificateLifetimeDays = 0,
    [datetime]$RestrictForAppsCreatedAfter,
    [string[]]$ApplicationObjectIds = @(),
    [string[]]$ServicePrincipalObjectIds = @()
)

$ErrorActionPreference = 'Stop'

if (-not (Get-MgContext)) {
    Write-Error "Not connected to Microsoft Graph. Run: Connect-MgGraph -Scopes 'Policy.ReadWrite.ApplicationConfiguration'"
    return
}

function Add-Restriction($collection, $type, $extra = @{}) {
    $r = @{ restrictionType = $type; state = 'enabled' } + $extra
    if ($RestrictForAppsCreatedAfter) {
        $r.restrictForAppsCreatedAfterDateTime = $RestrictForAppsCreatedAfter.ToUniversalTime().ToString('o')
    }
    [void]$collection.Add($r)
}

$pwd = New-Object System.Collections.Generic.List[hashtable]
$key = New-Object System.Collections.Generic.List[hashtable]

if ($BlockPasswordAddition)            { Add-Restriction $pwd 'passwordAddition' }
if ($MaxPasswordLifetimeDays -gt 0)    { Add-Restriction $pwd 'passwordLifetime' @{ maxLifetime = "P$($MaxPasswordLifetimeDays)D" } }
if ($BlockCustomPasswords)             { Add-Restriction $pwd 'customPasswordAddition' }
if ($MaxCertificateLifetimeDays -gt 0) { Add-Restriction $key 'asymmetricKeyLifetime' @{ maxLifetime = "P$($MaxCertificateLifetimeDays)D" } }

$body = @{
    displayName  = $DisplayName
    description  = $Description
    isEnabled    = $true
    restrictions = @{
        passwordCredentials = @($pwd)
        keyCredentials      = @($key)
    }
}

$json = $body | ConvertTo-Json -Depth 10
Write-Host ""
Write-Host "  Creating named policy '$DisplayName'..."

if (-not $PSCmdlet.ShouldProcess("appManagementPolicy '$DisplayName'", 'Create')) {
    Write-Host $json
    Write-Host "  -WhatIf: no changes made." -ForegroundColor Yellow
    return
}

$created = Invoke-MgGraphRequest -Method POST `
    -Uri 'https://graph.microsoft.com/v1.0/policies/appManagementPolicies' `
    -Body $json -ContentType 'application/json'

Write-Host ("  Created. id={0}" -f $created.id) -ForegroundColor Green

$policyRef = "https://graph.microsoft.com/v1.0/policies/appManagementPolicies/$($created.id)"

foreach ($appId in $ApplicationObjectIds) {
    if ($PSCmdlet.ShouldProcess("application $appId", "Assign policy '$DisplayName'")) {
        Invoke-MgGraphRequest -Method POST `
            -Uri "https://graph.microsoft.com/v1.0/applications/$appId/appManagementPolicies/`$ref" `
            -Body (@{ '@odata.id' = $policyRef } | ConvertTo-Json) `
            -ContentType 'application/json' | Out-Null
        Write-Host "    + assigned to application $appId" -ForegroundColor Green
    }
}

foreach ($spId in $ServicePrincipalObjectIds) {
    if ($PSCmdlet.ShouldProcess("servicePrincipal $spId", "Assign policy '$DisplayName'")) {
        Invoke-MgGraphRequest -Method POST `
            -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/appManagementPolicies/`$ref" `
            -Body (@{ '@odata.id' = $policyRef } | ConvertTo-Json) `
            -ContentType 'application/json' | Out-Null
        Write-Host "    + assigned to servicePrincipal $spId" -ForegroundColor Green
    }
}

Write-Host ""
