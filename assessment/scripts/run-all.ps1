<#
.SYNOPSIS
    Orchestrator — runs scripts 01–08 in order, captures exit codes, prints
    a consolidated summary matching the auto-generated HTML report (09-html-report.ps1).

.DESCRIPTION
    Uses standard Graph browser authentication and process-scoped Azure
    authentication, then executes
    each assessment script in sequence. Continues on individual script failures
    so partial results are still produced.

    At the end, writes run-summary.json, run-summary.md and report.html to OutputDir.
    Opens the HTML report unless -NoOpen is specified or Graph uses app-only authentication.
    The .md summary is a fill-in-able snapshot the assessor can attach to the
    the assessment record.

    Prereq modules  : All modules required by scripts 01–08
    Interactive authentication is handled by this entry point.
    Existing app-only contexts are reused without interactive sign-in.
    Normal interactive runs sign out of their selected SDKs on exit, including failures.

.PARAMETER TenantId
    Optional assessment tenant ID or domain for interactive sign-in.
    Otherwise, use the browser sign-in selection, not the previous Graph tenant.

.PARAMETER UseExistingContext
    Do not sign in. Validate caller-managed Graph and, if selected, Azure contexts instead.
    With this switch, TenantId must be a GUID.

.PARAMETER NoOpen
    Generate the HTML report without opening a browser.

.PARAMETER IncludeOptionalWorkloadEvidence
    Request additional read-only Agent ID and risky service principal scopes.
    Caller-managed contexts must already have these permissions and applicable roles.

.PARAMETER AssessmentScope
    Entra collects directory identities and policies without Azure authentication.
    EntraAndAzure also collects Azure resources, RBAC, Key Vault and monitoring.
    Interactive runs ask when omitted. Caller-managed/app-only runs default to EntraAndAzure.

.PARAMETER OutputDir
    Directory where all script outputs land.
    Default: ./output/<yyyyMMdd-HHmmss>

.PARAMETER SubscriptionIds
    Optional list of Azure subscription IDs to scope.
    If omitted, all subscriptions in the current Az context are used.

.PARAMETER Skip
    Script numbers to skip, e.g. @('06','08').

.EXAMPLE
    ./scripts/run-all.ps1 -OutputDir ./output -SubscriptionIds @('sub-id-1')
    ./scripts/run-all.ps1 -Skip @('06','08')
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputDir = (Join-Path (Split-Path -Parent $PSScriptRoot) ('output/' + (Get-Date -Format 'yyyyMMdd-HHmmss'))),

    [Parameter()]
    [string[]]$SubscriptionIds = @(),

    [Parameter()]
    [string[]]$Skip = @(),

    [Parameter()]
    [string]$TenantId,

    [Parameter()]
    [switch]$UseExistingContext,

    [Parameter()]
    [switch]$NoOpen,

    [Parameter()]
    [ValidateSet('Entra', 'EntraAndAzure')]
    [string]$AssessmentScope,

    [switch]$IncludeOptionalWorkloadEvidence
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
$commonModulePath = Join-Path $PSScriptRoot 'Assessment.Common.psm1'
# Refresh only at entry, before starting the shared per-run collection cache.
Import-Module $commonModulePath -Force -Global -ErrorAction Stop

$ScriptRoot = $PSScriptRoot

# ─── Helper: run a script and capture exit code ───────────────────────────────
function Invoke-AssessmentScript {
    [CmdletBinding()]
    param(
        [string]$Number,
        [string]$Name,
        [string]$ScriptPath,
        [hashtable]$ExtraArgs = @{}
    )

    if ($Number -in $Skip) {
        Write-Host "  [SKIP] $Number-$Name" -ForegroundColor Gray
        return @{ Number = $Number; Name = $Name; Status = 'Skipped'; ExitCode = 0; Duration = 0 }
    }

    if (-not (Test-Path $ScriptPath)) {
        Write-Host "  [MISSING] $ScriptPath" -ForegroundColor Red
        return @{ Number = $Number; Name = $Name; Status = 'Missing'; ExitCode = 99; Duration = 0 }
    }

    Write-Host ""
    Write-Host "  ── Running $Number-$Name ──────────────────────────" -ForegroundColor Cyan
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $errorMessage = $null
    $errorLocation = $null

    try {
        $global:LASTEXITCODE = 0
        & $ScriptPath -OutputDir $OutputDir @ExtraArgs
        $succeeded = $?
        $exitCode = $global:LASTEXITCODE
        if ($null -eq $exitCode) { $exitCode = 0 }
        if (-not $succeeded -and $exitCode -eq 0) { $exitCode = 1 }
    } catch {
        $errorMessage = $_.Exception.Message
        $errorLocation = $_.ScriptStackTrace
        Write-Host "  [ERROR] $Number-$Name threw: $_" -ForegroundColor Red
        $exitCode = 1
    }

    $sw.Stop()
    $status = if ($exitCode -eq 0) { 'OK' } else { 'Failed' }
    $color  = if ($exitCode -eq 0) { 'Green' } else { 'Red' }
    Write-Host "  ── $Number-$Name → $status (exit $exitCode) in $([int]$sw.Elapsed.TotalSeconds)s" -ForegroundColor $color

    return @{
        Number   = $Number
        Name     = $Name
        Status   = $status
        ExitCode = $exitCode
        Duration = [int]$sw.Elapsed.TotalSeconds
        ErrorMessage = $errorMessage
        ErrorLocation = $errorLocation
    }
}

function Assert-Contexts {
    param([bool]$IncludeAzure = $true)
    Write-Host "  Validating contexts..." -NoNewline
    Assert-AssessmentContexts -RequireAzure:$IncludeAzure
    $mgCtx = Get-MgContext
    if ($null -eq $mgCtx) {
        Write-Error "No Microsoft Graph context. Run: Connect-MgGraph -Scopes '...'"
        exit 2
    }
    if (-not $IncludeAzure) {
        Write-Host " Graph: $($mgCtx.Account) | Tenant: $($mgCtx.TenantId) | Entra only" -ForegroundColor Green
        return
    }
    $azCtx = Get-AzContext
    if ($null -eq $azCtx) {
        Write-Error "No Azure context. Run: Connect-AzAccount"
        exit 2
    }
    Write-Host " Graph: $($mgCtx.Account) | Az: $($azCtx.Account.Id) | Tenant: $($mgCtx.TenantId)" -ForegroundColor Green
}

function Set-AzSubscriptionScope {
    [CmdletBinding()]
    param([string[]]$SubscriptionIds)

    if ($SubscriptionIds.Count -eq 0) {
        $env:ASSESSMENT_SUBSCRIPTION_IDS = $null
        Write-Host "  No SubscriptionIds specified — using all subscriptions in Az context." -ForegroundColor Gray
        return
    }

    Write-Host "  Scoping Az context to $($SubscriptionIds.Count) subscription(s)..."
    # Set the first subscription as default; Resource Graph will use all passed subs via -Subscription parameter
    # For scripts using Search-AzGraph, we pass SubscriptionIds via environment convention.
    # Set-AzContext scopes Get-Az* cmdlets to a single sub — for cross-sub we rely on Resource Graph.
    $env:ASSESSMENT_SUBSCRIPTION_IDS = $SubscriptionIds -join ','
    try {
        Set-AzContext -TenantId (Get-MgContext).TenantId -SubscriptionId $SubscriptionIds[0] -Scope Process -ErrorAction Stop | Out-Null
        Write-Host "  Default subscription set to: $($SubscriptionIds[0])" -ForegroundColor Gray
    } catch {
        throw "Could not set Az context to $($SubscriptionIds[0]): $_"
    }
}

function Read-ScriptSummary {
    [CmdletBinding()]
    param([string]$OutputDir)

    $summary = @{}

    # 01-tenant-context
    $f = Join-Path $OutputDir '01-tenant-context.json'
    if (Test-Path $f) {
        try {
            $d = Get-Content $f -Raw | ConvertFrom-Json
            $summary['TenantId']                  = $d.TenantInfo.TenantId
            $summary['TenantName']                = $d.TenantInfo.DisplayName
            $summary['LicenseWIPremium']          = $d.LicenseFlags.WORKLOAD_IDENTITIES_PREMIUM.Present
            $summary['LicenseP2']                 = $d.LicenseFlags.AAD_PREMIUM_P2.Present
            $summary['LicenseGovernance']         = $d.LicenseFlags.ENTRA_ID_GOVERNANCE.Present
            $summary['UsersCanRegisterApps']      = $d.AuthorizationPolicy.AllowedToCreateApps
            $summary['AdminConsentWorkflow']      = $d.AdminConsentPolicy.IsEnabled
            $summary['AppAdminCount']             = $d.RoleMemberCounts.ApplicationAdministrator.MemberCount
            $summary['CloudAppAdminCount']        = $d.RoleMemberCounts.CloudApplicationAdministrator.MemberCount
            $summary['GlobalAdminCount']          = $d.RoleMemberCounts.GlobalAdministrator.MemberCount
            $summary['CustomRolesCount']          = $d.CustomEntraRoleCount
            $summary['SubscriptionCount']         = $d.AzureSubscriptions.Count
            $summary['IdentityProtectionEnabled'] = $d.IdentityProtection.Enabled
            $summary['RiskySpCount']              = $d.IdentityProtection.RiskyServicePrincipalCount
        } catch { Write-Verbose "Could not parse 01: $_" }
    }

    # 02-inventory
    $f = Join-Path $OutputDir '02-inventory.json'
    if (Test-Path $f) {
        try {
            $d = Get-Content $f -Raw | ConvertFrom-Json
            $summary['AppRegCount']    = $d.appRegistrations.Count
            $summary['SPCount']        = $d.servicePrincipals.Count
            $summary['UAMICount']      = ($d.managedIdentities | Where-Object { $_.IdentityType -eq 'UserAssigned' } | Measure-Object).Count
            $summary['SAMICount']      = ($d.managedIdentities | Where-Object { $_.IdentityType -eq 'SystemAssigned' } | Measure-Object).Count
            $summary['MultiTenantApps'] = ($d.appRegistrations | Where-Object { $_.SignInAudience -notmatch '^single' } | Measure-Object).Count
            $summary['AppsNoOwner']    = ($d.appRegistrations | Where-Object { $_.OwnerCount -eq 0 } | Measure-Object).Count
        } catch { Write-Verbose "Could not parse 02: $_" }
    }

    # 03-credential-hygiene
    $f = Join-Path $OutputDir '03-credential-hygiene.json'
    if (Test-Path $f) {
        try {
            $d = Get-Content $f -Raw | ConvertFrom-Json
            $agg = $d.Aggregations
            $summary['ActiveSecrets']         = $agg.TotalActivePasswordCredentials
            $summary['ActiveCerts']           = $agg.TotalActiveKeyCredentials
            $summary['CertRatioPct']          = $agg.CertificateToPasswordRatioPct
            $summary['MedianSecretLifeDays']  = $agg.MedianSecretLifetimeDays
            $summary['MaxSecretLifeDays']     = $agg.MaxSecretLifetimeDays
            $summary['Secrets12Mo']           = $agg.ActiveSecretsOver12Months
            $summary['Secrets24Mo']           = $agg.ActiveSecretsOver24Months
            $summary['ExpiredCreds']          = $agg.ExpiredCredentialsStillAttached
            $summary['MultiCredApps']         = $agg.AppRegsWithMoreThan2ActiveCreds
            $activityAvailable = $d.CredentialActivity.State -eq 'Available'
            $summary['CredentialActivityState'] = if ($d.CredentialActivity) { $d.CredentialActivity.State } else { 'Not collected' }
            $summary['InactiveCredentials90Days'] = if ($activityAvailable) { $agg.InactiveCredentials90Days } else { 'Not assessed' }
            $summary['UnknownCredentialUsage'] = if ($activityAvailable) { $agg.CredentialsWithoutActivityEvidence } else { 'Not assessed' }
        } catch { Write-Verbose "Could not parse 03: $_" }
    }

    # 04-federated-credentials
    $f = Join-Path $OutputDir '04-federated-credentials.json'
    if (Test-Path $f) {
        try {
            $d = Get-Content $f -Raw | ConvertFrom-Json
            $summary['TotalFICs']         = $d.TotalFICs
            $summary['FICsOnAppRegs']     = $d.FICsOnAppRegs
            $summary['FICsOnMIs']         = $d.FICsOnUserAssignedMIs
            $ghFIC = $d.ByIssuerCategory | Where-Object { $_.Category -eq 'github-actions' } | Select-Object -First 1
            $adoFIC = $d.ByIssuerCategory | Where-Object { $_.Category -eq 'azure-devops' } | Select-Object -First 1
            $summary['FICsGitHub']     = if ($ghFIC) { $ghFIC.Count } else { 0 }
            $summary['FICsADO']        = if ($adoFIC) { $adoFIC.Count } else { 0 }
            $wcFIC = $d.BySubjectClass | Where-Object { $_.Classification -eq 'WILDCARD' } | Select-Object -First 1
            $brFIC = $d.BySubjectClass | Where-Object { $_.Classification -eq 'BROAD' } | Select-Object -First 1
            $summary['FICsWildcard']   = if ($wcFIC) { $wcFIC.Count } else { 0 }
            $summary['FICsBroad']      = if ($brFIC) { $brFIC.Count } else { 0 }
        } catch { Write-Verbose "Could not parse 04: $_" }
    }

    # 05-permission-surface
    $gf = Join-Path $OutputDir '05-permission-surface-graph.csv'
    $rf = Join-Path $OutputDir '05-permission-surface-azure-rbac.csv'
    if (Test-Path $gf) {
        try {
            $gRows = Import-Csv -Path $gf
            $summary['PrivilegedSPs']     = ($gRows | Where-Object { $_.Tier -eq 'PRIVILEGED' } | Select-Object -ExpandProperty SpObjectId -Unique | Measure-Object).Count
            $summary['PrivReadSPs']       = ($gRows | Where-Object { $_.Tier -eq 'PRIVILEGED_READ' } | Select-Object -ExpandProperty SpObjectId -Unique | Measure-Object).Count
            $summary['TotalGraphGrants']  = $gRows.Count
        } catch { Write-Verbose "Could not parse 05 graph CSV: $_" }
    }
    if (Test-Path $rf) {
        try {
            $rRows = Import-Csv -Path $rf
            $summary['SubOwners']      = ($rRows | Where-Object { $_.RoleName -eq 'Owner' -and $_.ScopeLevel -eq 'subscription' } | Measure-Object).Count
            $summary['SubContributors'] = ($rRows | Where-Object { $_.RoleName -eq 'Contributor' -and $_.ScopeLevel -eq 'subscription' } | Measure-Object).Count
            $summary['UAAssignments']  = ($rRows | Where-Object { $_.RoleName -eq 'User Access Administrator' } | Measure-Object).Count
            $summary['MgmtGroupRBAC']  = ($rRows | Where-Object { $_.ScopeLevel -eq 'managementGroup' } | Measure-Object).Count
        } catch { Write-Verbose "Could not parse 05 RBAC CSV: $_" }
    }

    # 06-stale-and-orphaned
    $f = Join-Path $OutputDir '06-stale-and-orphaned.json'
    if (Test-Path $f) {
        try {
            $d = Get-Content $f -Raw | ConvertFrom-Json
            $agg = $d.Aggregations
            $summary['Stale90']        = $agg.Stale90Days
            $summary['Stale365']       = $agg.Stale365Days
            $summary['NeverSignedIn']  = $agg.NeverSignedIn
            $summary['NoOwner']        = $agg.NoOwner
            $summary['OrphanedOwner']  = $agg.OrphanedOwner
            $summary['SingleOwner']    = $agg.SingleOwner
            $summary['MissingTags']    = $agg.AppRegMissingTags
        } catch { Write-Verbose "Could not parse 06: $_" }
    }

    # 07-monitoring-coverage
    $f = Join-Path $OutputDir '07-monitoring-coverage.json'
    if (Test-Path $f) {
        try {
            $d = Get-Content $f -Raw | ConvertFrom-Json
            $ds = $d.diagnosticSettings
            $summary['DiagSettingsCount']   = $ds.Count
            $summary['SPSignInLogsRouted']  = ($ds | Where-Object { $_.ServicePrincipalSignInEnabled } | Measure-Object).Count -gt 0
            $summary['AuditLogsRouted']     = ($ds | Where-Object { $_.AuditLogsEnabled } | Measure-Object).Count -gt 0
            $summary['SentinelDeployed']    = ($d.logAnalyticsWorkspaces | Where-Object { $_.SentinelEnabled } | Measure-Object).Count -gt 0
            $summary['KVCount']             = $d.keyVaults.Count
            $summary['KVWithRBAC']          = ($d.keyVaults | Where-Object { $_.RbacEnabled } | Measure-Object).Count
            $summary['KVLegacyPolicy']      = ($d.keyVaults | Where-Object { $_.AccessPoliciesMode } | Measure-Object).Count
            $summary['KVNoPurgeProtect']    = ($d.keyVaults | Where-Object { -not $_.PurgeProtectionEnabled } | Measure-Object).Count
        } catch { Write-Verbose "Could not parse 07: $_" }
    }

    # 08-ca-for-workload-identities
    $f = Join-Path $OutputDir '08-ca-for-workload-identities.json'
    if (Test-Path $f) {
        try {
            $d = Get-Content $f -Raw | ConvertFrom-Json
            $summary['TotalCAPolicies']   = $d.TotalCAPolicies
            $summary['WICAPolicies']      = $d.WITargetedPolicies
            $summary['EnabledCAPolicies'] = $d.EnabledWIPolicies
            $summary['SPCoveredByCA']     = $d.SPsCoveredByCAPolicy
            $summary['SPCoveragePct']     = $d.SPCoveragePct
        } catch { Write-Verbose "Could not parse 08: $_" }
    }

    return $summary
}

function Write-ConsolidatedSummary {
    [CmdletBinding()]
    param(
        [hashtable]$Summary,
        [array]$ScriptResults,
        [string]$OutputDir,
        [int]$TotalDuration
    )

    function Val([string]$k) { if ($Summary.ContainsKey($k) -and $null -ne $Summary[$k]) { $Summary[$k] } else { '—' } }
    function YN([string]$k)  { if ($Summary[$k] -is [string] -and $Summary[$k] -eq 'Not collected') { 'Not collected' } elseif ($Summary.ContainsKey($k)) { if ($Summary[$k]) { 'YES' } else { 'NO' } } else { '—' } }

    $lines = [System.Collections.Generic.List[string]]::new()

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  WORKLOAD IDENTITY ASSESSMENT — CONSOLIDATED SUMMARY" -ForegroundColor Cyan
    Write-Host "  Tenant: $(Val 'TenantName')   ID: $(Val 'TenantId')" -ForegroundColor White
    Write-Host "  Output: $OutputDir" -ForegroundColor Gray
    Write-Host "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan

    Write-Host ""
    Write-Host "  §1. CURRENT STATE" -ForegroundColor White
    Write-Host "  ─────────────────────────────────────────────────────────────────"
    Write-Host "  App registrations               : $(Val 'AppRegCount')"
    Write-Host "  Service principals (all)        : $(Val 'SPCount')"
    Write-Host "  Managed identities (UA)         : $(Val 'UAMICount')"
    Write-Host "  Managed identities (SA)         : $(Val 'SAMICount')"
    Write-Host "  App regs with no owner          : $(Val 'AppsNoOwner')"
    Write-Host "  Application Admin role holders  : $(Val 'AppAdminCount')"
    Write-Host "  Cloud App Admin role holders    : $(Val 'CloudAppAdminCount')"
    Write-Host "  Global Admin role holders       : $(Val 'GlobalAdminCount')"
    Write-Host "  Users can register apps         : $(Val 'UsersCanRegisterApps')"
    Write-Host "  Admin consent workflow          : $(YN 'AdminConsentWorkflow')"
    Write-Host "  Multi-tenant app registrations  : $(Val 'MultiTenantApps')"
    Write-Host "  Custom Entra roles              : $(Val 'CustomRolesCount')"
    Write-Host "  Azure subscriptions in scope    : $(Val 'SubscriptionCount')"
    Write-Host ""
    Write-Host "  §2. WORKLOAD INVENTORY (FICs)" -ForegroundColor White
    Write-Host "  ─────────────────────────────────────────────────────────────────"
    Write-Host "  Total FICs                      : $(Val 'TotalFICs')"
    Write-Host "    On app registrations          : $(Val 'FICsOnAppRegs')"
    Write-Host "    On user-assigned MIs          : $(Val 'FICsOnMIs')"
    Write-Host "    GitHub Actions OIDC           : $(Val 'FICsGitHub')"
    Write-Host "    Azure DevOps OIDC             : $(Val 'FICsADO')"
    Write-Host ""
    Write-Host "  §3. SENSITIVITY & RISK" -ForegroundColor White
    Write-Host "  ─────────────────────────────────────────────────────────────────"
    Write-Host "  SPs with PRIVILEGED Graph perms : $(Val 'PrivilegedSPs')"
    Write-Host "  SPs with PRIVILEGED_READ perms  : $(Val 'PrivReadSPs')"
    Write-Host "  Sub-scope Owner assignments     : $(Val 'SubOwners')"
    Write-Host "  Sub-scope Contributor           : $(Val 'SubContributors')"
    Write-Host "  User Access Administrator       : $(Val 'UAAssignments')"
    Write-Host "  Mgmt-group-scope RBAC           : $(Val 'MgmtGroupRBAC')"
    Write-Host "  Secrets > 12 months             : $(Val 'Secrets12Mo')"
    Write-Host "  Secrets > 24 months             : $(Val 'Secrets24Mo')"
    Write-Host "  Expired creds still attached    : $(Val 'ExpiredCreds')"
    Write-Host "  FICs with WILDCARD subject      : $(Val 'FICsWildcard')"
    Write-Host "  FICs with BROAD subject         : $(Val 'FICsBroad')"
    Write-Host ""
    Write-Host "  §4. LIFECYCLE & OWNERSHIP" -ForegroundColor White
    Write-Host "  ─────────────────────────────────────────────────────────────────"
    Write-Host "  SPs stale (no sign-in 90d)      : $(Val 'Stale90')"
    Write-Host "  SPs stale (no sign-in 365d)     : $(Val 'Stale365')"
    Write-Host "  SPs never signed in             : $(Val 'NeverSignedIn')"
    Write-Host "  SPs with no owner               : $(Val 'NoOwner')"
    Write-Host "  SPs with orphaned owner         : $(Val 'OrphanedOwner')"
    Write-Host "  SPs with single owner           : $(Val 'SingleOwner')"
    Write-Host "  App regs missing tags           : $(Val 'MissingTags')"
    Write-Host ""
    Write-Host "  §5. SECRETS HYGIENE" -ForegroundColor White
    Write-Host "  ─────────────────────────────────────────────────────────────────"
    Write-Host "  Active secrets (password creds) : $(Val 'ActiveSecrets')"
    Write-Host "  Active cert credentials         : $(Val 'ActiveCerts')"
    Write-Host "  Cert-to-total ratio             : $(Val 'CertRatioPct')%"
    Write-Host "  Median secret lifetime          : $(Val 'MedianSecretLifeDays') days"
    Write-Host "  Max secret lifetime             : $(Val 'MaxSecretLifeDays') days"
    Write-Host "  App regs with > 2 active creds  : $(Val 'MultiCredApps')"
    Write-Host "  Credential activity (preview)  : $(Val 'CredentialActivityState')"
    Write-Host "  Inactive credentials >= 90 days : $(Val 'InactiveCredentials90Days') (review)"
    Write-Host "  Unknown credential usage       : $(Val 'UnknownCredentialUsage')"
    Write-Host ""
    Write-Host "  §6. KEY VAULT" -ForegroundColor White
    Write-Host "  ─────────────────────────────────────────────────────────────────"
    Write-Host "  Key Vaults in scope             : $(Val 'KVCount')"
    Write-Host "  KVs with RBAC authorization     : $(Val 'KVWithRBAC')"
    Write-Host "  KVs with legacy access policies : $(Val 'KVLegacyPolicy')"
    Write-Host "  KVs without purge protection    : $(Val 'KVNoPurgeProtect')"
    Write-Host ""
    Write-Host "  §7. MONITORING & DETECTION" -ForegroundColor White
    Write-Host "  ─────────────────────────────────────────────────────────────────"
    Write-Host "  Entra diagnostic settings       : $(Val 'DiagSettingsCount')"
    Write-Host "  SP sign-in logs routed          : $(YN 'SPSignInLogsRouted')"
    Write-Host "  Audit logs routed               : $(YN 'AuditLogsRouted')"
    Write-Host "  Microsoft Sentinel deployed     : $(YN 'SentinelDeployed')"
    Write-Host ""
    Write-Host "  §8. CONDITIONAL ACCESS FOR WORKLOAD IDENTITIES" -ForegroundColor White
    Write-Host "  ─────────────────────────────────────────────────────────────────"
    Write-Host "  Workload Identities Premium     : $(YN 'LicenseWIPremium')"
    Write-Host "  Total CA policies               : $(Val 'TotalCAPolicies')"
    Write-Host "  CA policies targeting WIs       : $(Val 'WICAPolicies')"
    Write-Host "  Enabled WI CA policies          : $(Val 'EnabledCAPolicies')"
    Write-Host "  SPs covered by CA policy        : $(Val 'SPCoveredByCA') ($(Val 'SPCoveragePct')%)"
    Write-Host ""
    Write-Host "  LICENSES" -ForegroundColor White
    Write-Host "  ─────────────────────────────────────────────────────────────────"
    Write-Host "  Workload Identities Premium     : $(YN 'LicenseWIPremium')"
    Write-Host "  Entra ID P2                     : $(YN 'LicenseP2')"
    Write-Host "  Entra ID Governance             : $(YN 'LicenseGovernance')"
    Write-Host "  Identity Protection (WI)        : $(YN 'IdentityProtectionEnabled') | Risky SPs: $(Val 'RiskySpCount')"

    Write-Host ""
    Write-Host "  SCRIPT RUN RESULTS" -ForegroundColor White
    Write-Host "  ─────────────────────────────────────────────────────────────────"
    foreach ($r in $ScriptResults) {
        $c = switch ($r.Status) { 'OK' { 'Green' } 'Skipped' { 'Gray' } 'Not collected' { 'Gray' } default { 'Red' } }
        Write-Host "    [$($r.Status.PadRight(7))] $($r.Number)-$($r.Name) ($($r.Duration)s)" -ForegroundColor $c
    }

    $failedCount = @($ScriptResults | Where-Object { $_.Status -eq 'Failed' }).Count
    Write-Host ""
    Write-Host "  Total run time: ${TotalDuration}s | Failed scripts: $failedCount" -ForegroundColor $(if ($failedCount -eq 0) { 'Green' } else { 'Yellow' })
    Write-Host "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""

    # ── run-summary.md ────────────────────────────────────────────────────────
    $mdContent = @"
# Workload Identity Assessment — Run Summary

| Field | Value |
|-------|-------|
| Tenant | $(Val 'TenantName') |
| Tenant ID | $(Val 'TenantId') |
| Assessment scope | $(Val 'AssessmentScope') |
| Run timestamp | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') |
| Output directory | $OutputDir |
| Total run time | ${TotalDuration}s |

## §1 Current State

| Metric | Value |
|--------|-------|
| App registrations | $(Val 'AppRegCount') |
| Service principals (all) | $(Val 'SPCount') |
| Managed identities (user-assigned) | $(Val 'UAMICount') |
| Managed identities (system-assigned) | $(Val 'SAMICount') |
| App regs with no owner | $(Val 'AppsNoOwner') |
| Application Administrator role holders | $(Val 'AppAdminCount') |
| Cloud Application Administrator role holders | $(Val 'CloudAppAdminCount') |
| Global Administrator role holders | $(Val 'GlobalAdminCount') |
| "Users can register applications" | $(Val 'UsersCanRegisterApps') |
| Admin consent workflow enabled | $(YN 'AdminConsentWorkflow') |
| Multi-tenant app registrations | $(Val 'MultiTenantApps') |
| Custom Entra roles | $(Val 'CustomRolesCount') |
| Azure subscriptions in scope | $(Val 'SubscriptionCount') |

## §2 Workload Inventory (Federated Credentials)

| Metric | Value |
|--------|-------|
| Total FICs | $(Val 'TotalFICs') |
| FICs on app registrations | $(Val 'FICsOnAppRegs') |
| FICs on user-assigned MIs | $(Val 'FICsOnMIs') |
| GitHub Actions OIDC issuers | $(Val 'FICsGitHub') |
| Azure DevOps OIDC issuers | $(Val 'FICsADO') |
| FICs with WILDCARD subject | $(Val 'FICsWildcard') |
| FICs with BROAD subject | $(Val 'FICsBroad') |

## §3 Sensitivity & Risk

| Metric | Value |
|--------|-------|
| SPs with PRIVILEGED Graph permissions | $(Val 'PrivilegedSPs') |
| SPs with PRIVILEGED_READ permissions | $(Val 'PrivReadSPs') |
| Sub-scope Owner assignments (workload IDs) | $(Val 'SubOwners') |
| Sub-scope Contributor assignments | $(Val 'SubContributors') |
| User Access Administrator assignments | $(Val 'UAAssignments') |
| Management-group-scope RBAC | $(Val 'MgmtGroupRBAC') |
| Active secrets > 12 months | $(Val 'Secrets12Mo') |
| Active secrets > 24 months | $(Val 'Secrets24Mo') |
| Expired credentials still attached | $(Val 'ExpiredCreds') |

## §4 Lifecycle & Ownership

| Metric | Value |
|--------|-------|
| SPs with no sign-in in 90 days | $(Val 'Stale90') |
| SPs with no sign-in in 365 days | $(Val 'Stale365') |
| SPs never signed in | $(Val 'NeverSignedIn') |
| SPs with no owner | $(Val 'NoOwner') |
| SPs with orphaned owners | $(Val 'OrphanedOwner') |
| App regs missing tags (CMDB gap) | $(Val 'MissingTags') |

## §5 Secrets Hygiene

| Metric | Value |
|--------|-------|
| Active password credentials | $(Val 'ActiveSecrets') |
| Active key (cert) credentials | $(Val 'ActiveCerts') |
| Cert-to-total ratio | $(Val 'CertRatioPct')% |
| Median secret lifetime | $(Val 'MedianSecretLifeDays') days |
| Max secret lifetime | $(Val 'MaxSecretLifeDays') days |
| App regs with > 2 active credentials | $(Val 'MultiCredApps') |
| Credential activity (preview) | $(Val 'CredentialActivityState') |
| Inactive credentials >= 90 days (review) | $(Val 'InactiveCredentials90Days') |
| Unknown credential usage | $(Val 'UnknownCredentialUsage') |

## §6 Key Vault

| Metric | Value |
|--------|-------|
| Key Vaults in scope | $(Val 'KVCount') |
| KVs with RBAC authorization | $(Val 'KVWithRBAC') |
| KVs with legacy access policies | $(Val 'KVLegacyPolicy') |
| KVs without purge protection | $(Val 'KVNoPurgeProtect') |

## §7 Monitoring & Detection

| Metric | Value |
|--------|-------|
| Entra diagnostic settings | $(Val 'DiagSettingsCount') |
| SP sign-in logs routed to LA | $(YN 'SPSignInLogsRouted') |
| Audit logs routed to LA | $(YN 'AuditLogsRouted') |
| Microsoft Sentinel deployed | $(YN 'SentinelDeployed') |

## §8 Conditional Access for Workload Identities

| Metric | Value |
|--------|-------|
| Workload Identities Premium licensed | $(YN 'LicenseWIPremium') |
| Total CA policies | $(Val 'TotalCAPolicies') |
| CA policies targeting workload identities | $(Val 'WICAPolicies') |
| Enabled WI CA policies | $(Val 'EnabledCAPolicies') |
| SPs covered by at least one CA policy | $(Val 'SPCoveredByCA') ($(Val 'SPCoveragePct')%) |

## Licenses

| License | Present |
|---------|---------|
| Workload Identities Premium | $(YN 'LicenseWIPremium') |
| Entra ID P2 (Identity Protection + PIM) | $(YN 'LicenseP2') |
| Entra ID Governance | $(YN 'LicenseGovernance') |
| Identity Protection for workload identities | $(YN 'IdentityProtectionEnabled') |

## Script Run Results

| Script | Status | Duration |
|--------|--------|----------|
$(($ScriptResults | ForEach-Object { "| $($_.Number)-$($_.Name) | $($_.Status) | $($_.Duration)s |" }) -join "`n")

---
*Generated by run-all.ps1 — read-only assessment. No changes were made to the tenant.*
"@

    $mdPath = Join-Path $OutputDir 'run-summary.md'
    $mdContent | Out-File -FilePath $mdPath -Encoding UTF8

    # ── run-summary.json ──────────────────────────────────────────────────────
    $jsonPath = Join-Path $OutputDir 'run-summary.json'
    @{
        CollectedAt    = (Get-Date -Format 'o')
        TenantId       = $Summary['TenantId']
        TenantName     = $Summary['TenantName']
        OutputDir      = $OutputDir
        TotalDuration  = $TotalDuration
        AssessmentScope = $Summary['AssessmentScope']
        ScriptResults  = $ScriptResults
        Metrics        = $Summary
    } | ConvertTo-Json -Depth 5 | Out-File -FilePath $jsonPath -Encoding UTF8

    Write-Host "  Run summary written:" -ForegroundColor Gray
    Write-Host "    $mdPath"
    Write-Host "    $jsonPath"
    Write-Host ""
}

function Invoke-RunAll {
    [CmdletBinding()]
    param(
        [string]$OutputDir,
        [string[]]$SubscriptionIds,
        [string[]]$Skip,
        [string]$TenantId,
        [switch]$UseExistingContext,
        [switch]$NoOpen,
        [string]$AssessmentScope
    )

    if (-not $AssessmentScope) {
        $appOnly = (Get-Command Get-MgContext -ErrorAction SilentlyContinue) -and (Get-MgContext).AuthType -eq 'AppOnly'
        if ($UseExistingContext -or $appOnly) {
            $AssessmentScope = 'EntraAndAzure'
        } else {
            Write-Host ''
            Write-Host '  1. Entra only - apps, service principals, credentials, permissions and policies. Graph sign-in only.'
            Write-Host '  2. Entra + Azure - also managed identity resources, Azure RBAC, Key Vault and monitoring. Adds Azure sign-in.'
            do {
                $choice = Read-Host 'Choose assessment scope [1]'
                if ($choice -notin @('', '1', '2')) { Write-Host '  Enter 1 or 2.' -ForegroundColor Yellow }
            } while ($choice -notin @('', '1', '2'))
            $AssessmentScope = if ($choice -eq '2') { 'EntraAndAzure' } else { 'Entra' }
        }
    }
    $includeAzure = $AssessmentScope -eq 'EntraAndAzure'
    if (-not $includeAzure -and $SubscriptionIds.Count -gt 0) {
        throw 'SubscriptionIds requires -AssessmentScope EntraAndAzure.'
    }
    if (-not $includeAzure -and (Test-Path -LiteralPath $OutputDir)) {
        $existing = @(Get-ChildItem -LiteralPath $OutputDir -File | Where-Object Name -match '^0[1-8]-.*\.json$')
        if ($existing.Count -gt 0) {
            throw 'Entra-only collection requires a fresh output folder to avoid including stale Azure exports. Use 09-html-report.ps1 to render existing exports.'
        }
    }

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  WORKLOAD IDENTITY ASSESSMENT — run-all.ps1" -ForegroundColor Cyan
    Write-Host "  Output: $OutputDir" -ForegroundColor Gray
    Write-Host "  Assessment scope: $AssessmentScope" -ForegroundColor Gray
    Write-Host "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""

    Connect-AssessmentContexts -TenantId $TenantId -UseExistingContext:$UseExistingContext -IncludeAzure:$includeAzure -IncludeOptionalWorkloadEvidence:$IncludeOptionalWorkloadEvidence
    Assert-Contexts -IncludeAzure:$includeAzure
    Start-AssessmentCollection -IncludeAzure:$includeAzure

    # Set subscription scope
    if ($includeAzure) {
        Set-AzSubscriptionScope -SubscriptionIds $SubscriptionIds
    } else {
        $env:ASSESSMENT_SUBSCRIPTION_IDS = $null
    }

    # Create output dir
    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    # ── Define script manifest ────────────────────────────────────────────────
    $scripts = @(
        @{ Number = '01'; Name = 'tenant-context';           Script = Join-Path $ScriptRoot '01-tenant-context.ps1';            ExtraArgs = @{} }
        @{ Number = '02'; Name = 'inventory';                Script = Join-Path $ScriptRoot '02-inventory.ps1';                  ExtraArgs = @{} }
        @{ Number = '03'; Name = 'credential-hygiene';       Script = Join-Path $ScriptRoot '03-credential-hygiene.ps1';         ExtraArgs = @{} }
        @{ Number = '04'; Name = 'federated-credentials';    Script = Join-Path $ScriptRoot '04-federated-credentials.ps1';      ExtraArgs = @{} }
        @{ Number = '05'; Name = 'permission-surface';       Script = Join-Path $ScriptRoot '05-permission-surface.ps1';         ExtraArgs = @{} }
        @{ Number = '06'; Name = 'stale-and-orphaned';       Script = Join-Path $ScriptRoot '06-stale-and-orphaned.ps1';         ExtraArgs = @{} }
        @{ Number = '07'; Name = 'monitoring-coverage';      Script = Join-Path $ScriptRoot '07-monitoring-coverage.ps1';        ExtraArgs = @{} }
        @{ Number = '08'; Name = 'ca-for-workload-identities'; Script = Join-Path $ScriptRoot '08-ca-for-workload-identities.ps1'; ExtraArgs = @{ InventoryOutputDir = $OutputDir } }
    )

    $runResults = [System.Collections.Generic.List[hashtable]]::new()
    $overallSw  = [System.Diagnostics.Stopwatch]::StartNew()

    foreach ($s in $scripts) {
        if (-not $includeAzure -and $s.Number -eq '07') {
            Write-Host '  [NOT COLLECTED] 07-monitoring-coverage - requires Azure access.' -ForegroundColor Gray
            $result = @{ Number = '07'; Name = $s.Name; Status = 'Not collected'; ExitCode = 0; Duration = 0 }
        } else {
            if (-not $includeAzure -and $s.Number -in @('01', '02', '04', '05')) {
                $s.ExtraArgs.EntraOnly = $true
            }
            $result = Invoke-AssessmentScript -Number $s.Number -Name $s.Name -ScriptPath $s.Script -ExtraArgs $s.ExtraArgs
        }
        $runResults.Add($result)
    }

    $overallSw.Stop()

    # Read all output and build consolidated summary
    $metrics = Read-ScriptSummary -OutputDir $OutputDir
    $metrics.AssessmentScope = $AssessmentScope
    if (-not $includeAzure) {
        foreach ($key in @('SubscriptionCount', 'UAMICount', 'SAMICount', 'FICsOnMIs', 'SubOwners', 'SubContributors',
            'UAAssignments', 'MgmtGroupRBAC', 'DiagSettingsCount', 'SPSignInLogsRouted', 'AuditLogsRouted',
            'SentinelDeployed', 'KVCount', 'KVWithRBAC', 'KVLegacyPolicy', 'KVNoPurgeProtect')) {
            $metrics[$key] = 'Not collected'
        }
    }
    Write-ConsolidatedSummary -Summary $metrics -ScriptResults $runResults -OutputDir $OutputDir -TotalDuration ([int]$overallSw.Elapsed.TotalSeconds)

    $failed = @($runResults | Where-Object { $_.Status -in @('Failed', 'Missing') })
    if ($failed.Count -gt 0) {
        Write-Warning "$($failed.Count) collector(s) failed or are missing. This is a partial assessment; inspect run-summary.json."
    }
    $datasets = @(Get-ChildItem -LiteralPath $OutputDir -File | Where-Object Name -match '^0[1-8]-.*\.json$')
    if ($datasets.Count -eq 0) {
        Write-Warning 'No collector JSON was produced. No HTML report was generated.'
        return
    }
    $reportPath = Join-Path $OutputDir 'report.html'
    & (Join-Path $ScriptRoot '09-html-report.ps1') -OutputDir $OutputDir -ReportPath $reportPath
    if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
        throw "Report generation did not produce $reportPath."
    }
    if (-not $NoOpen -and (Get-MgContext).AuthType -eq 'Delegated') {
        try {
            Invoke-Item -LiteralPath (Resolve-Path -LiteralPath $reportPath).Path -ErrorAction Stop
        } catch {
            Write-Warning "The report was generated at $reportPath but could not be opened: $_"
        }
    }
}

# ─── Entry point ─────────────────────────────────────────────────────────────
$previousSubscriptionScope = $env:ASSESSMENT_SUBSCRIPTION_IDS
$runError = $null
$transcriptStarted = $false
try {
    if (-not (Test-Path -LiteralPath $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }
    Start-Transcript -Path (Join-Path $OutputDir 'transcript.txt') -Append -ErrorAction Stop | Out-Null
    $transcriptStarted = $true
    try {
        Invoke-RunAll -OutputDir $OutputDir -SubscriptionIds $SubscriptionIds -Skip $Skip -TenantId $TenantId -UseExistingContext:$UseExistingContext -NoOpen:$NoOpen -AssessmentScope $AssessmentScope
    } catch {
        $runError = $_
    } finally {
        Stop-AssessmentCollection
        $env:ASSESSMENT_SUBSCRIPTION_IDS = $previousSubscriptionScope
        try {
            Disconnect-AssessmentContexts
        } catch {
            if ($runError) {
                Write-Warning "Authentication cleanup also failed: $_" -WarningAction Continue
            } else {
                $runError = $_
            }
        }
    }
    if ($runError) {
        Write-Error "run-all.ps1 failed: $runError"
        exit 1
    }
} finally {
    if ($transcriptStarted) {
        try {
            Stop-Transcript -ErrorAction Stop | Out-Null
        } catch {
            if ($runError) {
                Write-Warning "Transcript cleanup also failed: $_" -WarningAction Continue
            } else {
                throw
            }
        }
    }
}
