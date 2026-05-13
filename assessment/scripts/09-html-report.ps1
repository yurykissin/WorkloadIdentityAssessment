<#
.SYNOPSIS
    Builds a single styled HTML report from the latest 01-08 JSON outputs.

.DESCRIPTION
    Scans assessment/output/<timestamp>/ folders, picks the most recent JSON
    per script (01-tenant-context ... 08-ca-for-workload-identities), and
    emits a single self-contained HTML report (no external CSS/JS) with:
      * summary tiles
      * findings & recommendations
      * per-section drill-down tables
      * raw JSON appendix (collapsed)

.PARAMETER OutputDir
    Folder containing per-run output subfolders. Defaults to ../output.

.PARAMETER ReportPath
    Destination HTML file. Defaults to ../output/report-<ts>.html.

.PARAMETER RunDir
    Optional specific run-folder name (e.g. 20260512-225715). When set, the
    report uses ONLY files from that run. Default = pick latest per script
    across all runs.

.EXAMPLE
    ./09-html-report.ps1
    ./09-html-report.ps1 -RunDir 20260512-225715
#>

[CmdletBinding()]
param(
    [string] $OutputDir,
    [string] $ReportPath,
    [string] $RunDir
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

if (-not $OutputDir) {
    $OutputDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'output'
}
if (-not (Test-Path $OutputDir)) {
    Write-Error "Output dir not found: $OutputDir"
    return
}

$ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
if (-not $ReportPath) {
    $ReportPath = Join-Path $OutputDir "report-$ts.html"
}

# ---------------------------------------------------------------------------
# Discover input files
# ---------------------------------------------------------------------------
$scriptIds = @('01','02','03','04','05','06','07','08')
$files = @{}
foreach ($id in $scriptIds) {
    if ($RunDir) {
        $candidate = Get-ChildItem -Path (Join-Path $OutputDir $RunDir) -Filter "$id-*.json" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    } else {
        $candidate = Get-ChildItem -Path $OutputDir -Recurse -Filter "$id-*.json" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
    if ($candidate) {
        $files[$id] = $candidate.FullName
    }
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════"
Write-Host "  09-html-report  |  Building HTML report..."
Write-Host "═══════════════════════════════════════════════════════════════"
Write-Host ""
foreach ($id in $scriptIds) {
    if ($files.ContainsKey($id)) {
        Write-Host ("  [{0}] {1}" -f $id, $files[$id])
    } else {
        Write-Host ("  [{0}] (no output found - section will be skipped)" -f $id) -ForegroundColor Yellow
    }
}
Write-Host ""

# ---------------------------------------------------------------------------
# Load JSON
# ---------------------------------------------------------------------------
function Read-Json($path) {
    if (-not $path -or -not (Test-Path $path)) { return $null }
    try { return Get-Content -Raw -Path $path | ConvertFrom-Json -Depth 50 }
    catch { Write-Warning "Failed to parse $path : $_"; return $null }
}

$data = @{
    '01' = Read-Json $files['01']
    '02' = Read-Json $files['02']
    '03' = Read-Json $files['03']
    '04' = Read-Json $files['04']
    '05' = Read-Json $files['05']
    '06' = Read-Json $files['06']
    '07' = Read-Json $files['07']
    '08' = Read-Json $files['08']
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function HE([string] $s) {
    if ($null -eq $s) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($s)
}

function Get-Prop($obj, [string] $name) {
    if ($null -eq $obj) { return $null }
    if ($obj -is [System.Collections.IDictionary]) {
        if ($obj.Contains($name)) { return $obj[$name] }
        return $null
    }
    if ($obj.PSObject.Properties.Name -contains $name) {
        return $obj.$name
    }
    return $null
}

function CountOf($v) {
    if ($null -eq $v) { return 0 }
    if ($v -is [array]) { return $v.Count }
    if ($v -is [System.Collections.ICollection]) { return $v.Count }
    return 1
}

function Tile([string] $label, $value, [string] $tone = 'neutral') {
    $valStr = if ($null -eq $value) { '—' } else { "$value" }
    return "<div class='tile tone-$tone'><div class='tile-value'>$(HE $valStr)</div><div class='tile-label'>$(HE $label)</div></div>"
}

function ToTable($rows, [string[]] $columns, [int] $maxRows = 200) {
    if (-not $rows) { return "<p class='muted'>No data.</p>" }
    $arr = @($rows)
    if ($arr.Count -eq 0) { return "<p class='muted'>No data.</p>" }
    $shown = $arr | Select-Object -First $maxRows
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("<table><thead><tr>")
    foreach ($c in $columns) { [void]$sb.Append("<th>$(HE $c)</th>") }
    [void]$sb.Append("</tr></thead><tbody>")
    foreach ($r in $shown) {
        [void]$sb.Append("<tr>")
        foreach ($c in $columns) {
            $v = Get-Prop $r $c
            if ($v -is [array]) { $v = ($v -join ', ') }
            [void]$sb.Append("<td>$(HE ([string]$v))</td>")
        }
        [void]$sb.Append("</tr>")
    }
    [void]$sb.Append("</tbody></table>")
    if ($arr.Count -gt $maxRows) {
        [void]$sb.Append("<p class='muted'>Showing $maxRows of $($arr.Count) rows. Full data in JSON.</p>")
    }
    return $sb.ToString()
}

function Section([string] $id, [string] $title, [string] $body) {
    return @"
<section id="$id">
  <h2>$(HE $title)</h2>
  $body
</section>
"@
}

# ---------------------------------------------------------------------------
# Findings logic (heuristic; conservative — favours flagging over silence)
# ---------------------------------------------------------------------------
$findings = New-Object System.Collections.Generic.List[object]
function Add-Finding([string] $sev, [string] $title, [string] $detail, [string] $rec) {
    $findings.Add([PSCustomObject]@{
        Severity = $sev; Title = $title; Detail = $detail; Recommendation = $rec
    })
}

# 01 — license & policy
$d1 = $data['01']
if ($d1) {
    $caps = Get-Prop $d1 'CapabilityFlags'
    if ($caps) {
        $wi = Get-Prop $caps 'WORKLOAD_IDENTITIES_PREMIUM'
        if ($wi -and -not (Get-Prop $wi 'Available')) {
            Add-Finding 'High' 'Workload Identities Premium not licensed' `
                'No SKU in the tenant provides the Workload Identities Premium service plan. CA-for-WI and Risky Workload Identities cannot be used.' `
                'Purchase Workload Identities Premium add-on (~$3 / workload identity / month) and license at minimum the privileged service principals & user-assigned MIs.'
        }
        $gov = Get-Prop $caps 'AAD_GOVERNANCE'
        if ($gov -and -not (Get-Prop $gov 'Available')) {
            Add-Finding 'Low' 'Entra ID Governance add-on not licensed' `
                'Lifecycle Workflows, Entitlement Management v2, ML recommendations and SoD checks unavailable.' `
                'Optional. Buy only if app-access lifecycle automation is in scope.'
        }
    }
    $auth = Get-Prop $d1 'AuthorizationPolicy'
    if ($auth -and (Get-Prop $auth 'AllowedToCreateApps') -eq $true) {
        Add-Finding 'High' 'All users can create app registrations' `
            'AuthorizationPolicy.AllowedToCreateApps = true. Any user can register an application and create OAuth secrets.' `
            'Set Users → User settings → Users can register applications = No. Restrict app creation to Application Administrator / Cloud Application Administrator.'
    }
    $consent = Get-Prop $d1 'AdminConsentPolicy'
    if ($consent -and (Get-Prop $consent 'IsEnabled') -ne $true) {
        Add-Finding 'Med' 'Admin consent workflow disabled' `
            'Users cannot request admin approval for app permissions; they will either consent themselves (if allowed) or be silently blocked.' `
            'Enable Enterprise applications → Consent and permissions → Admin consent settings, route requests to Cloud Application Administrators.'
    }
    $rmc = Get-Prop $d1 'RoleMemberCounts'
    if ($rmc) {
        $ga  = Get-Prop $rmc 'GlobalAdministrator';            $gaCount  = if ($ga)  { Get-Prop $ga  'MemberCount' } else { $null }
        $aa  = Get-Prop $rmc 'ApplicationAdministrator';       $aaCount  = if ($aa)  { Get-Prop $aa  'MemberCount' } else { $null }
        $caa = Get-Prop $rmc 'CloudApplicationAdministrator';  $caaCount = if ($caa) { Get-Prop $caa 'MemberCount' } else { $null }
        if (($aaCount -eq 0) -and ($caaCount -eq 0) -and ($gaCount -gt 0)) {
            Add-Finding 'Med' 'No tier separation for app administration' `
                "0 Application Administrators + 0 Cloud Application Administrators + $gaCount Global Administrators. App management is being done via GA, violating least privilege." `
                'Assign at least 2 Cloud Application Administrators (for non-Microsoft apps) and use PIM to make those eligible, not active.'
        }
    }
}

# 02 — inventory
$d2 = $data['02']
if ($d2) {
    $sps = @(Get-Prop $d2 'servicePrincipals')
    $custom = @($sps | Where-Object { -not (Get-Prop $_ 'IsExternalApp') })
    $noOwner = @($custom | Where-Object { (Get-Prop $_ 'OwnerCount') -eq 0 })
    if ($noOwner.Count -gt 0 -and $custom.Count -gt 0) {
        $pct = [math]::Round($noOwner.Count / $custom.Count * 100, 0)
        Add-Finding 'High' "$($noOwner.Count) of $($custom.Count) in-tenant SPs have no owner ($pct%)" `
            'Service principals without owners cannot be governed: nobody is accountable for credentials, redirect URIs, or removal.' `
            'Assign ≥2 owners per in-tenant SP. Block creation of new SPs without owners via deployment guardrails.'
    }
}

# 03 — credentials
$d3 = $data['03']
if ($d3) {
    $agg = Get-Prop $d3 'Aggregations'
    if ($agg) {
        $secrets = Get-Prop $agg 'TotalActivePasswordCredentials'
        $certs   = Get-Prop $agg 'TotalActiveKeyCredentials'
        if ($secrets -gt 0 -and $certs -eq 0) {
            Add-Finding 'High' 'No certificate credentials in use' `
                "Found $secrets active password (secret) credentials and $certs certificate credentials. Certificates are preferred for non-MI workloads." `
                'Migrate app-reg credentials to certificates (PKI- or Key Vault-issued) or to Federated Identity Credentials.'
        }
        $expired = Get-Prop $agg 'ExpiredCredentialsStillAttached'
        if ($expired -gt 0) {
            Add-Finding 'Med' "$expired expired credentials still attached" `
                'Expired credentials should be removed; their presence is a hygiene smell and may indicate orphaned automations.' `
                'Run a sweep to delete expired credentials. Alert on credentials approaching expiry via Graph API + Logic App.'
        }
        $vlong = Get-Prop $agg 'ActiveSecretsOver24Months'
        if ($vlong -gt 0) {
            Add-Finding 'Med' "$vlong secrets older than 24 months" `
                'Long-lived secrets enlarge the blast radius of a single leak.' `
                'Cap secret lifetime at 12 months. Rotate proactively; prefer certificates or FICs.'
        }
    }
}

# 04 — FICs
$d4 = $data['04']
if ($d4) {
    $totalFic = Get-Prop $d4 'TotalFICs'
    $byIssuer = @(Get-Prop $d4 'ByIssuerCategory')
    $bySubject = @(Get-Prop $d4 'BySubjectClass')
    $gh  = ($byIssuer | Where-Object { (Get-Prop $_ 'Category') -eq 'github' }      | Measure-Object).Count
    $ado = ($byIssuer | Where-Object { (Get-Prop $_ 'Category') -eq 'azuredevops' } | Measure-Object).Count
    if ($totalFic -gt 0 -and $gh -eq 0 -and $ado -eq 0) {
        Add-Finding 'Med' 'No CI/CD federated credentials' `
            "All $totalFic FICs are non-CI/CD (Entra-internal). No GitHub Actions or Azure DevOps federation detected." `
            'Migrate CI/CD pipelines from secrets to FICs (OIDC). Eliminates long-lived secrets in pipeline variables.'
    }
    $wild = @($bySubject | Where-Object { (Get-Prop $_ 'Classification') -in @('WILDCARD','BROAD') })
    if ($wild.Count -gt 0) {
        Add-Finding 'High' "Broad/wildcard FIC subjects detected" `
            'A wildcard subject ("repo:org/*:ref:*") allows ANY pipeline in the org to mint a token for the workload identity.' `
            'Constrain the subject to specific repo + branch / environment. Avoid * in repo, branch, or environment.'
    }
}

# 05 — permissions
$d5 = $data['05']
if ($d5) {
    $gp = @(Get-Prop $d5 'GraphPermissions')
    $priv = @($gp | Where-Object { (Get-Prop $_ 'Tier') -eq 'PRIVILEGED' })
    $privSpCount = (@($priv | Group-Object SpDisplayName).Count)
    if ($priv.Count -gt 0) {
        Add-Finding 'Info' "$($priv.Count) PRIVILEGED Graph app-role grants across $privSpCount SPs" `
            'Privileged Graph permissions (e.g. RoleManagement.ReadWrite.Directory, Mail.ReadWrite, Application.ReadWrite.All) on a service principal are equivalent to a high-privilege admin.' `
            'Review each privileged grant. For Microsoft first-party SPs, confirm the resource (Defender for Cloud, M365 Copilot, etc.) is in active use; remove consent for unused first-party apps.'
    }
}

# 06 — stale & orphaned
$d6 = $data['06']
if ($d6) {
    $agg6 = Get-Prop $d6 'Aggregations'
    if ($agg6) {
        $stale365 = Get-Prop $agg6 'Stale365Days'
        $never    = Get-Prop $agg6 'NeverSignedIn'
        $total    = Get-Prop $agg6 'TotalFirstPartySPs'
        if ($stale365 -gt 0 -and $total -gt 0) {
            Add-Finding 'Med' "$stale365 / $total in-tenant SPs stale > 365 days" `
                "$never of those have NEVER signed in. They may be abandoned demos or test apps." `
                'For each: confirm with owner; delete or disable. Add a quarterly access review on service principal sign-in activity.'
        }
        $tagless = Get-Prop $agg6 'AppRegMissingTags'
        if ($tagless -gt 0) {
            Add-Finding 'Low' "$tagless app registrations missing tags" `
                'Tags drive ownership-by-team, environment classification, and cost / governance reporting.' `
                'Apply WI Premium-style tagging: env=prod|nonprod, team=<team>, criticality=<low|med|high>.'
        }
    }
}

# 07 — monitoring
$d7 = $data['07']
if ($d7) {
    $diag = @(Get-Prop $d7 'diagnosticSettings')
    if ($diag.Count -eq 0) {
        Add-Finding 'High' 'No Entra diagnostic settings' `
            'Tenant-level Entra diagnostic settings are not configured. Sign-in / Audit / RiskyServicePrincipal logs are not flowing to Log Analytics or Sentinel.' `
            'Create a diagnostic setting forwarding SignInLogs, AuditLogs, RiskyUsers, RiskyServicePrincipals, ServicePrincipalSignInLogs, ManagedIdentitySignInLogs to LAW.'
    } elseif ($diag.Count -eq 1) {
        Add-Finding 'Med' 'Only 1 Entra diagnostic setting — verify category coverage' `
            'A single diag setting may not cover all required categories (SignIn, Audit, RiskySP, ManagedIdSignIn, etc.).' `
            'Review categories. Ensure SignInLogs, AuditLogs, NonInteractiveUserSignInLogs, ServicePrincipalSignInLogs, ManagedIdentitySignInLogs, RiskyServicePrincipals are all enabled.'
    }
}

# 08 — CA for WI
$d8 = $data['08']
if ($d8) {
    $wiLicensed = Get-Prop $d8 'WorkloadIdentitiesPremiumLicensed'
    $coverage   = Get-Prop $d8 'SPCoveragePct'
    $wiTargeted = Get-Prop $d8 'WITargetedPolicies'
    if (-not $wiLicensed) {
        # already flagged from 01; skip duplication
    } elseif ($wiTargeted -eq 0) {
        Add-Finding 'High' 'No CA policies target workload identities' `
            'WI Premium is licensed, but 0 Conditional Access policies are scoped to workload identities. SPs and MIs sign in unrestricted.' `
            'Create a baseline CA-for-WI policy: block sign-in from outside trusted IP ranges / require SP risk = none.'
    } elseif ($coverage -lt 80) {
        Add-Finding 'Med' "CA-for-WI coverage only $coverage%" `
            'Less than 80% of in-tenant service principals are scoped by any CA-for-WI policy.' `
            'Expand CA-for-WI scope to include all custom service principals; exclude only Microsoft-required system SPs.'
    }
}

# ---------------------------------------------------------------------------
# Build HTML
# ---------------------------------------------------------------------------
$css = @'
*{box-sizing:border-box}
body{font-family:-apple-system,Segoe UI,Roboto,sans-serif;line-height:1.5;color:#1a1a1a;background:#f6f7fb;margin:0;padding:0}
header{background:linear-gradient(135deg,#0078d4,#005a9e);color:#fff;padding:32px 48px}
header h1{margin:0;font-size:28px;font-weight:600}
header .meta{margin-top:6px;opacity:.85;font-size:13px}
nav{background:#fff;border-bottom:1px solid #e1e4e8;padding:12px 48px;position:sticky;top:0;z-index:10;box-shadow:0 1px 3px rgba(0,0,0,.04)}
nav a{color:#0078d4;text-decoration:none;margin-right:18px;font-size:13px;font-weight:500}
nav a:hover{text-decoration:underline}
main{max-width:1200px;margin:0 auto;padding:32px 48px 64px}
section{background:#fff;border:1px solid #e1e4e8;border-radius:8px;padding:24px 28px;margin-bottom:24px;box-shadow:0 1px 3px rgba(0,0,0,.04)}
h2{margin-top:0;font-size:20px;color:#0078d4;border-bottom:2px solid #f0f3f7;padding-bottom:10px}
h3{margin-top:24px;font-size:15px;color:#444;text-transform:uppercase;letter-spacing:.5px}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:12px;margin:16px 0}
.tile{background:#f6f7fb;border:1px solid #e1e4e8;border-radius:6px;padding:14px 16px;text-align:left}
.tile-value{font-size:24px;font-weight:600;color:#1a1a1a}
.tile-label{font-size:12px;color:#666;margin-top:4px;text-transform:uppercase;letter-spacing:.4px}
.tile.tone-good .tile-value{color:#107c10}
.tile.tone-warn .tile-value{color:#ca5010}
.tile.tone-bad .tile-value{color:#d13438}
table{width:100%;border-collapse:collapse;margin:12px 0;font-size:13px}
th,td{text-align:left;padding:8px 10px;border-bottom:1px solid #eef0f4;vertical-align:top}
th{background:#f6f7fb;font-weight:600;color:#444}
tbody tr:hover{background:#fafbfd}
.findings .finding{border-left:4px solid #ccc;padding:14px 18px;margin-bottom:12px;background:#fafbfd;border-radius:0 6px 6px 0}
.finding .sev{display:inline-block;font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:.5px;padding:2px 8px;border-radius:3px;margin-right:10px;vertical-align:middle}
.finding .ftitle{font-weight:600;font-size:15px;display:inline-block;vertical-align:middle}
.finding .fdetail{margin-top:8px;color:#444;font-size:13px}
.finding .frec{margin-top:8px;font-size:13px;background:#f0f7ff;border-left:3px solid #0078d4;padding:8px 10px;border-radius:0 4px 4px 0}
.finding.sev-high{border-left-color:#d13438}
.finding.sev-high .sev{background:#d13438;color:#fff}
.finding.sev-med{border-left-color:#ca5010}
.finding.sev-med .sev{background:#ca5010;color:#fff}
.finding.sev-low{border-left-color:#797775}
.finding.sev-low .sev{background:#797775;color:#fff}
.finding.sev-info{border-left-color:#0078d4}
.finding.sev-info .sev{background:#0078d4;color:#fff}
.muted{color:#888;font-size:12px}
details{margin-top:16px}
summary{cursor:pointer;color:#0078d4;font-size:13px;font-weight:500;padding:8px 0}
pre{background:#1e1e1e;color:#d4d4d4;padding:14px;border-radius:6px;overflow:auto;font-size:11px;max-height:400px}
.kv{display:grid;grid-template-columns:200px 1fr;gap:6px 12px;margin:12px 0;font-size:13px}
.kv .k{color:#666;font-weight:500}
.kv .v{color:#1a1a1a}
.badge{display:inline-block;padding:2px 8px;border-radius:3px;font-size:11px;font-weight:600;margin-right:4px}
.badge.ok{background:#dff6dd;color:#107c10}
.badge.no{background:#fed9cc;color:#a4262c}
'@

$sb = [System.Text.StringBuilder]::new()

# Header
$tenantName = if ($d1) { Get-Prop (Get-Prop $d1 'TenantInfo') 'DisplayName' } else { 'Unknown' }
$tenantId   = if ($d1) { Get-Prop (Get-Prop $d1 'TenantInfo') 'TenantId'    } else { '' }
$primary    = if ($d1) { Get-Prop (Get-Prop $d1 'TenantInfo') 'PrimaryDomain' } else { '' }

[void]$sb.Append(@"
<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Workload Identity Assessment — $(HE $tenantName)</title>
<style>$css</style>
</head><body>
<header>
  <h1>Workload Identity Assessment</h1>
  <div class="meta">
    <strong>$(HE $tenantName)</strong>
    $(if ($primary) { "&nbsp;·&nbsp;$(HE $primary)" })
    $(if ($tenantId) { "&nbsp;·&nbsp;$(HE $tenantId)" })
    &nbsp;·&nbsp;Report generated $(HE ((Get-Date).ToString('yyyy-MM-dd HH:mm')))
  </div>
</header>
<nav>
  <a href="#findings">Findings</a>
  <a href="#tenant">Tenant</a>
  <a href="#inventory">Inventory</a>
  <a href="#credentials">Credentials</a>
  <a href="#fic">FICs</a>
  <a href="#permissions">Permissions</a>
  <a href="#stale">Stale &amp; Orphaned</a>
  <a href="#monitoring">Monitoring</a>
  <a href="#ca">CA for WI</a>
  <a href="#raw">Raw JSON</a>
</nav>
<main>
"@)

# Findings
$findingsHtml = if ($findings.Count -eq 0) {
    "<p class='muted'>No findings raised by heuristics. Review per-section data manually.</p>"
} else {
    $sortOrder = @{ 'High'=0; 'Med'=1; 'Low'=2; 'Info'=3 }
    $sorted = $findings | Sort-Object @{ Expression = { $sortOrder[$_.Severity] } }
    $h = [System.Text.StringBuilder]::new()
    [void]$h.Append("<div class='findings'>")
    foreach ($f in $sorted) {
        $sevClass = "sev-$($f.Severity.ToLower())"
        [void]$h.Append("<div class='finding $sevClass'>")
        [void]$h.Append("<span class='sev'>$(HE $f.Severity)</span>")
        [void]$h.Append("<span class='ftitle'>$(HE $f.Title)</span>")
        [void]$h.Append("<div class='fdetail'>$(HE $f.Detail)</div>")
        [void]$h.Append("<div class='frec'><strong>Recommendation:</strong> $(HE $f.Recommendation)</div>")
        [void]$h.Append("</div>")
    }
    [void]$h.Append("</div>")
    $h.ToString()
}
[void]$sb.Append((Section 'findings' "Findings & Recommendations ($($findings.Count))" $findingsHtml))

# 01 Tenant
if ($d1) {
    $caps = Get-Prop $d1 'CapabilityFlags'
    $auth = Get-Prop $d1 'AuthorizationPolicy'
    $consent = Get-Prop $d1 'AdminConsentPolicy'
    $rmc = Get-Prop $d1 'RoleMemberCounts'
    $subs = @(Get-Prop $d1 'AzureSubscriptions')

    $body = [System.Text.StringBuilder]::new()
    [void]$body.Append("<div class='kv'>")
    [void]$body.Append("<div class='k'>Tenant ID</div><div class='v'>$(HE $tenantId)</div>")
    [void]$body.Append("<div class='k'>Display name</div><div class='v'>$(HE $tenantName)</div>")
    [void]$body.Append("<div class='k'>Primary domain</div><div class='v'>$(HE $primary)</div>")
    [void]$body.Append("<div class='k'>Azure subscriptions</div><div class='v'>$($subs.Count)</div>")
    [void]$body.Append("</div>")

    [void]$body.Append("<h3>Entra capabilities</h3>")
    if ($caps) {
        [void]$body.Append("<table><thead><tr><th>Capability</th><th>Available</th><th>Provided by</th><th>Description</th></tr></thead><tbody>")
        foreach ($p in $caps.PSObject.Properties) {
            $c = $p.Value
            $av = if ((Get-Prop $c 'Available')) { "<span class='badge ok'>YES</span>" } else { "<span class='badge no'>NO</span>" }
            $sks = @(Get-Prop $c 'ProvidedBySkus')
            $skuStr = if ($sks.Count -gt 0) { ($sks | ForEach-Object { "$($_.SkuPartNumber) ($($_.EnabledUnits) units)" }) -join ', ' } else { '—' }
            [void]$body.Append("<tr><td><code>$(HE $p.Name)</code></td><td>$av</td><td>$(HE $skuStr)</td><td>$(HE (Get-Prop $c 'Description'))</td></tr>")
        }
        [void]$body.Append("</tbody></table>")
    }

    if ($auth) {
        [void]$body.Append("<h3>Authorization policy</h3><div class='kv'>")
        [void]$body.Append("<div class='k'>Users can register apps</div><div class='v'>$(HE (Get-Prop $auth 'AllowedToCreateApps'))</div>")
        [void]$body.Append("<div class='k'>Users can create tenants</div><div class='v'>$(HE (Get-Prop $auth 'AllowedToCreateTenants'))</div>")
        [void]$body.Append("<div class='k'>Users can create security groups</div><div class='v'>$(HE (Get-Prop $auth 'AllowedToCreateSecurityGroups'))</div>")
        if ($consent) {
            [void]$body.Append("<div class='k'>Admin consent workflow enabled</div><div class='v'>$(HE (Get-Prop $consent 'IsEnabled'))</div>")
        }
        [void]$body.Append("</div>")
    }

    if ($rmc) {
        [void]$body.Append("<h3>Role member counts</h3><table><thead><tr><th>Role</th><th>Members</th></tr></thead><tbody>")
        foreach ($p in $rmc.PSObject.Properties) {
            $mc = Get-Prop $p.Value 'MemberCount'
            [void]$body.Append("<tr><td>$(HE $p.Name)</td><td>$(HE $mc)</td></tr>")
        }
        [void]$body.Append("</tbody></table>")
    }
    [void]$sb.Append((Section 'tenant' '01 — Tenant Context' $body.ToString()))
}

# 02 Inventory
if ($d2) {
    $sps = @(Get-Prop $d2 'servicePrincipals')
    $ar  = @(Get-Prop $d2 'appRegistrations')
    $mi  = @(Get-Prop $d2 'managedIdentities')
    $custom = @($sps | Where-Object { -not (Get-Prop $_ 'IsExternalApp') })
    $external = @($sps | Where-Object { Get-Prop $_ 'IsExternalApp' })
    $noOwn  = @($custom | Where-Object { (Get-Prop $_ 'OwnerCount') -eq 0 })
    $never  = @($sps | Where-Object { Get-Prop $_ 'NeverSignedIn' })

    $tiles = @(
        Tile 'Service principals (total)' $sps.Count
        Tile 'In-tenant SPs' $custom.Count 'warn'
        Tile 'Microsoft / external SPs' $external.Count
        Tile 'App registrations' $ar.Count
        Tile 'Managed identities (UA)' $mi.Count
        Tile 'In-tenant SPs without owner' $noOwn.Count $(if ($noOwn.Count -gt 0) { 'bad' } else { 'good' })
    ) -join ''
    $body = "<div class='tiles'>$tiles</div>"

    if ($mi.Count -gt 0) {
        $body += "<h3>Managed identities</h3>"
        $body += ToTable $mi @('Name','IdentityType','ResourceGroup','Location','SubscriptionId') 50
    }
    if ($ar.Count -gt 0) {
        $body += "<h3>App registrations</h3>"
        $body += ToTable $ar @('DisplayName','AppId','SignInAudience','OwnerCount') 50
    }
    $body += "<h3>In-tenant service principals</h3>"
    $body += ToTable ($custom | Sort-Object DisplayName) @('DisplayName','AppId','OwnerCount','LastSignIn','AppRoleAssignmentCount') 100
    [void]$sb.Append((Section 'inventory' '02 — Inventory' $body))
}

# 03 Credentials
if ($d3) {
    $agg = Get-Prop $d3 'Aggregations'
    $creds = @(Get-Prop $d3 'Credentials')
    $tiles = ''
    if ($agg) {
        $secrets = Get-Prop $agg 'TotalActivePasswordCredentials'
        $certs   = Get-Prop $agg 'TotalActiveKeyCredentials'
        $tiles = @(
            Tile 'Active secrets' $secrets $(if ($secrets -gt 0) { 'warn' } else { 'good' })
            Tile 'Active certificates' $certs $(if ($certs -eq 0 -and $secrets -gt 0) { 'bad' } else { 'good' })
            Tile 'Cert : secret ratio' "$(Get-Prop $agg 'CertificateToPasswordRatioPct')%"
            Tile 'Median lifetime (days)' (Get-Prop $agg 'MedianSecretLifetimeDays')
            Tile 'Max lifetime (days)' (Get-Prop $agg 'MaxSecretLifetimeDays')
            Tile 'Expired still attached' (Get-Prop $agg 'ExpiredCredentialsStillAttached') $(if ((Get-Prop $agg 'ExpiredCredentialsStillAttached') -gt 0) { 'bad' } else { 'good' })
            Tile 'Active > 12 months' (Get-Prop $agg 'ActiveSecretsOver12Months')
            Tile 'Active > 24 months' (Get-Prop $agg 'ActiveSecretsOver24Months') $(if ((Get-Prop $agg 'ActiveSecretsOver24Months') -gt 0) { 'bad' } else { 'good' })
        ) -join ''
    }
    $body = "<div class='tiles'>$tiles</div>"
    $body += "<h3>Credentials</h3>"
    $body += ToTable $creds @('AppDisplayName','CredentialType','CredentialDisplayName','StartDateTime','EndDateTime','LifetimeDays','DaysUntilExpiry','Expired') 200
    [void]$sb.Append((Section 'credentials' '03 — Credential Hygiene' $body))
}

# 04 FIC
if ($d4) {
    $fics = @(Get-Prop $d4 'FederatedCredentials')
    $tiles = @(
        Tile 'Total FICs'     (Get-Prop $d4 'TotalFICs')
        Tile 'On app regs'    (Get-Prop $d4 'FICsOnAppRegs')
        Tile 'On UA MIs'      (Get-Prop $d4 'FICsOnUserAssignedMIs')
    ) -join ''
    $body = "<div class='tiles'>$tiles</div>"
    $body += "<h3>By issuer</h3>"
    $body += ToTable (Get-Prop $d4 'ByIssuerCategory') @('Category','Count')
    $body += "<h3>By subject classification</h3>"
    $body += ToTable (Get-Prop $d4 'BySubjectClass') @('Classification','Count')
    $body += "<h3>All FICs</h3>"
    $body += ToTable $fics @('TargetName','FicName','IssuerCategory','SubjectClassification','Subject','Audiences') 200
    [void]$sb.Append((Section 'fic' '04 — Federated Identity Credentials' $body))
}

# 05 Permissions
if ($d5) {
    $gp = @(Get-Prop $d5 'GraphPermissions')
    $rb = @(Get-Prop $d5 'AzureRbac')
    $priv = @($gp | Where-Object { (Get-Prop $_ 'Tier') -eq 'PRIVILEGED' })
    $std  = @($gp | Where-Object { (Get-Prop $_ 'Tier') -eq 'STANDARD' })
    $tiles = @(
        Tile 'Graph app-role grants' $gp.Count
        Tile 'PRIVILEGED tier' $priv.Count $(if ($priv.Count -gt 0) { 'warn' } else { 'good' })
        Tile 'STANDARD tier' $std.Count
        Tile 'Azure RBAC assignments to SP/MI' $rb.Count
    ) -join ''
    $body = "<div class='tiles'>$tiles</div>"
    if ($priv.Count -gt 0) {
        $body += "<h3>Privileged Graph permissions</h3>"
        $body += ToTable $priv @('SpDisplayName','PermissionValue','PermissionDisplayName','ResourceDisplayName') 200
    }
    $body += "<h3>All Graph app-role grants</h3>"
    $body += ToTable $gp @('SpDisplayName','PermissionValue','Tier','ResourceDisplayName') 300
    if ($rb.Count -gt 0) {
        $body += "<h3>Azure RBAC on workload identities</h3>"
        $body += ToTable $rb @('PrincipalDisplayName','RoleDisplayName','Scope') 200
    }
    [void]$sb.Append((Section 'permissions' '05 — Permission Surface' $body))
}

# 06 Stale & orphaned
if ($d6) {
    $agg6 = Get-Prop $d6 'Aggregations'
    $sps6 = @(Get-Prop $d6 'ServicePrincipals')
    $tiles = ''
    if ($agg6) {
        $tiles = @(
            Tile 'In-tenant SPs (analysed)' (Get-Prop $agg6 'TotalFirstPartySPs')
            Tile 'Stale > 90 days' (Get-Prop $agg6 'Stale90Days')  'warn'
            Tile 'Stale > 365 days' (Get-Prop $agg6 'Stale365Days') $(if ((Get-Prop $agg6 'Stale365Days') -gt 0) { 'bad' } else { 'good' })
            Tile 'Never signed in' (Get-Prop $agg6 'NeverSignedIn') 'warn'
            Tile 'No owner' (Get-Prop $agg6 'NoOwner') $(if ((Get-Prop $agg6 'NoOwner') -gt 0) { 'bad' } else { 'good' })
            Tile 'Orphaned owner' (Get-Prop $agg6 'OrphanedOwner') $(if ((Get-Prop $agg6 'OrphanedOwner') -gt 0) { 'bad' } else { 'good' })
            Tile 'App regs missing tags' (Get-Prop $agg6 'AppRegMissingTags')
        ) -join ''
    }
    $body = "<div class='tiles'>$tiles</div>"
    $body += "<h3>Service principals</h3>"
    $body += ToTable $sps6 @('DisplayName','AppId','OwnerCount','LastSignIn','DaysSinceLastSignIn') 200
    [void]$sb.Append((Section 'stale' '06 — Stale & Orphaned' $body))
}

# 07 Monitoring
if ($d7) {
    $kv = @(Get-Prop $d7 'keyVaults')
    $la = @(Get-Prop $d7 'logAnalyticsWorkspaces')
    $ds = @(Get-Prop $d7 'diagnosticSettings')
    $tiles = @(
        Tile 'Key Vaults' $kv.Count
        Tile 'Log Analytics workspaces' $la.Count
        Tile 'Entra diagnostic settings' $ds.Count $(if ($ds.Count -eq 0) { 'bad' } elseif ($ds.Count -lt 2) { 'warn' } else { 'good' })
    ) -join ''
    $body = "<div class='tiles'>$tiles</div>"
    if ($ds.Count -gt 0) {
        $body += "<h3>Entra diagnostic settings</h3>"
        $cols = @($ds[0].PSObject.Properties.Name) | Select-Object -First 6
        $body += ToTable $ds $cols 50
    }
    if ($kv.Count -gt 0) {
        $body += "<h3>Key Vaults</h3>"
        $cols = @($kv[0].PSObject.Properties.Name) | Select-Object -First 6
        $body += ToTable $kv $cols 100
    }
    if ($la.Count -gt 0) {
        $body += "<h3>Log Analytics workspaces</h3>"
        $cols = @($la[0].PSObject.Properties.Name) | Select-Object -First 6
        $body += ToTable $la $cols 50
    }
    [void]$sb.Append((Section 'monitoring' '07 — Monitoring Coverage' $body))
}

# 08 CA for WI
if ($d8) {
    $tiles = @(
        Tile 'WI Premium licensed' (Get-Prop $d8 'WorkloadIdentitiesPremiumLicensed') $(if ((Get-Prop $d8 'WorkloadIdentitiesPremiumLicensed')) { 'good' } else { 'bad' })
        Tile 'CA policies (total)' (Get-Prop $d8 'TotalCAPolicies')
        Tile 'WI-targeted policies' (Get-Prop $d8 'WITargetedPolicies') $(if ((Get-Prop $d8 'WITargetedPolicies') -eq 0) { 'bad' } else { 'good' })
        Tile 'Enabled WI policies' (Get-Prop $d8 'EnabledWIPolicies')
        Tile 'Report-only WI policies' (Get-Prop $d8 'ReportOnlyWIPolicies')
        Tile 'In-tenant SPs (total)' (Get-Prop $d8 'TotalFirstPartySPs')
        Tile 'SPs covered by CA' (Get-Prop $d8 'SPsCoveredByCAPolicy')
        Tile 'SP coverage %' "$(Get-Prop $d8 'SPCoveragePct')%" $(if ((Get-Prop $d8 'SPCoveragePct') -lt 80) { 'bad' } else { 'good' })
    ) -join ''
    $body = "<div class='tiles'>$tiles</div>"
    $pol = @(Get-Prop $d8 'Policies')
    if ($pol.Count -gt 0) {
        $body += "<h3>CA policies (workload-identity-relevant)</h3>"
        $cols = @($pol[0].PSObject.Properties.Name) | Select-Object -First 8
        $body += ToTable $pol $cols 100
    }
    $cov = @(Get-Prop $d8 'SPCoverage')
    if ($cov.Count -gt 0) {
        $body += "<h3>SP coverage detail</h3>"
        $cols = @($cov[0].PSObject.Properties.Name) | Select-Object -First 6
        $body += ToTable $cov $cols 200
    }
    [void]$sb.Append((Section 'ca' '08 — Conditional Access for Workload Identities' $body))
}

# Raw JSON
$rawHtml = [System.Text.StringBuilder]::new()
foreach ($id in $scriptIds) {
    if ($files.ContainsKey($id)) {
        $name = Split-Path -Leaf $files[$id]
        $raw = Get-Content -Raw -Path $files[$id]
        if ($raw.Length -gt 200000) { $raw = $raw.Substring(0, 200000) + "`n... (truncated for HTML report)" }
        [void]$rawHtml.Append("<details><summary>$(HE $name) ($([math]::Round($raw.Length/1024, 1)) KB)</summary><pre>$(HE $raw)</pre></details>")
    }
}
[void]$sb.Append((Section 'raw' 'Raw JSON appendix' $rawHtml.ToString()))

[void]$sb.Append("</main></body></html>")

# ---------------------------------------------------------------------------
# Write
# ---------------------------------------------------------------------------
$sb.ToString() | Set-Content -Path $ReportPath -Encoding UTF8

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════"
Write-Host "  09-html-report  SUMMARY"
Write-Host "═══════════════════════════════════════════════════════════════"
Write-Host "  Tenant         : $tenantName"
Write-Host "  Findings       : $($findings.Count)"
$highCount = ($findings | Where-Object { $_.Severity -eq 'High' }).Count
$medCount  = ($findings | Where-Object { $_.Severity -eq 'Med' }).Count
$lowCount  = ($findings | Where-Object { $_.Severity -eq 'Low' }).Count
$infoCount = ($findings | Where-Object { $_.Severity -eq 'Info' }).Count
Write-Host "                   High=$highCount  Med=$medCount  Low=$lowCount  Info=$infoCount"
Write-Host "  Sections built : $($scriptIds.Where({ $files.ContainsKey($_) }).Count) / $($scriptIds.Count)"
Write-Host "  Report         : $ReportPath"
Write-Host "═══════════════════════════════════════════════════════════════"
Write-Host ""
