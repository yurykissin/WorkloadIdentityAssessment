<#
.SYNOPSIS
    Grants the Microsoft Graph application permissions required by the
    Workload Identity Assessment to a managed identity (or any service
    principal).

.DESCRIPTION
    The assessment runs as a user-assigned managed identity inside the
    your tenant. That MI must be granted Microsoft Graph application
    permissions BEFORE the assessment deployment script is executed.

    Granting Graph app roles requires Application.ReadWrite.All or
    RoleManagement.ReadWrite.Directory in Microsoft Graph, which a
    Global Administrator already holds. Run this in Azure Cloud Shell or
    locally with Microsoft.Graph installed.

.PARAMETER PrincipalId
    Object ID of the managed identity service principal (the
    `uamiPrincipalId` output from 01-bootstrap.json).

.PARAMETER TenantId
    Tenant ID. Optional — defaults to the current Connect-MgGraph context.

.PARAMETER GraphAppRoles
    Override the list of Graph app role values. Default = the 7 roles the
    assessment scripts need.

.EXAMPLE
    Connect-MgGraph -Scopes 'AppRoleAssignment.ReadWrite.All','Application.Read.All'
    ./grant-graph-permissions.ps1 -PrincipalId 11111111-aaaa-bbbb-cccc-222222222222
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $PrincipalId,

    [string] $TenantId,

    [string[]] $GraphAppRoles = @(
        'Application.Read.All',
        'Directory.Read.All',
        'Policy.Read.All',
        'RoleManagement.Read.Directory',
        'AuditLog.Read.All',
        'IdentityRiskEvent.Read.All',
        'CrossTenantInformation.ReadBasic.All'
    )
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "  $msg" -ForegroundColor Cyan }
function Write-OK($msg)   { Write-Host "  ✓ $msg"  -ForegroundColor Green }
function Write-Skip($msg) { Write-Host "  · $msg"  -ForegroundColor DarkGray }

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════"
Write-Host "  grant-graph-permissions  |  Granting Graph app roles to MI..."
Write-Host "═══════════════════════════════════════════════════════════════"
Write-Host ""

# Ensure module + connection
foreach ($m in @('Microsoft.Graph.Applications','Microsoft.Graph.Authentication')) {
    if (-not (Get-Module -ListAvailable -Name $m)) {
        Write-Step "Installing $m..."
        Install-Module $m -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module $m -ErrorAction SilentlyContinue
}

$ctx = Get-MgContext
if (-not $ctx) {
    Write-Step "Not connected. Connecting to Microsoft Graph..."
    $connectArgs = @{ Scopes = @('AppRoleAssignment.ReadWrite.All','Application.Read.All') }
    if ($TenantId) { $connectArgs['TenantId'] = $TenantId }
    Connect-MgGraph @connectArgs
    $ctx = Get-MgContext
}
Write-OK "Connected as $($ctx.Account) in tenant $($ctx.TenantId)"

# Microsoft Graph SP — well-known AppId
$graphAppId = '00000003-0000-0000-c000-000000000000'
$graphSp = Get-MgServicePrincipal -Filter "appId eq '$graphAppId'" -ErrorAction Stop
if (-not $graphSp) { throw "Microsoft Graph service principal not found in this tenant." }

# Existing assignments on the target principal
$existing = @(Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $PrincipalId -All -ErrorAction Stop)
$existingByRoleId = @{}
foreach ($e in $existing) { $existingByRoleId[$e.AppRoleId.ToString()] = $true }

$granted = 0
$alreadyHad = 0
$failed = @()

foreach ($roleValue in $GraphAppRoles) {
    $role = $graphSp.AppRoles | Where-Object { $_.Value -eq $roleValue -and $_.AllowedMemberTypes -contains 'Application' } | Select-Object -First 1
    if (-not $role) {
        $failed += "$roleValue (not found on Graph SP)"
        continue
    }
    if ($existingByRoleId.ContainsKey($role.Id.ToString())) {
        Write-Skip "$roleValue already granted"
        $alreadyHad++
        continue
    }
    try {
        New-MgServicePrincipalAppRoleAssignment `
            -ServicePrincipalId $PrincipalId `
            -PrincipalId $PrincipalId `
            -ResourceId $graphSp.Id `
            -AppRoleId $role.Id `
            -ErrorAction Stop | Out-Null
        Write-OK "$roleValue"
        $granted++
    } catch {
        Write-Warning "Failed to grant $roleValue : $_"
        $failed += $roleValue
    }
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════"
Write-Host "  SUMMARY"
Write-Host "═══════════════════════════════════════════════════════════════"
Write-Host "  Newly granted   : $granted"
Write-Host "  Already had     : $alreadyHad"
Write-Host "  Failed          : $($failed.Count)"
if ($failed.Count -gt 0) {
    foreach ($f in $failed) { Write-Host "    - $f" -ForegroundColor Red }
}
Write-Host ""
Write-Host "  Next: deploy 02-assessment.json with this UAMI." -ForegroundColor Yellow
Write-Host "═══════════════════════════════════════════════════════════════"
Write-Host ""
