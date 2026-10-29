<#
.SYNOPSIS
    Builds a self-contained offline HTML report from one assessment snapshot.

.DESCRIPTION
    Uses one run folder (or the latest timestamp-named run under OutputDir).
    Embeds the report assets and complete JSON data without tenant connections.
    Missing, partial and unreadable exports are identified in the report.

.PARAMETER OutputDir
    Folder containing per-run output subfolders, or one flat snapshot.
    Defaults to ../output, or an absolute RunDir when provided on its own.

.PARAMETER ReportPath
    Destination HTML file. Defaults to report-<ts>.html under OutputDir.

.PARAMETER RunDir
    Optional specific run-folder name (e.g. 20260512-225715). When set, the
    report uses ONLY files from that run. An absolute folder path is supported.
    Without RunDir, use flat outputs in OutputDir or its latest timestamped run.

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
    $OutputDir = if ($RunDir -and [IO.Path]::IsPathRooted($RunDir)) {
        $RunDir
    } else {
        Join-Path (Split-Path -Parent $PSScriptRoot) 'output'
    }
}
if (-not (Test-Path -LiteralPath $OutputDir -PathType Container)) {
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
$datasetNames = @{
    '01' = 'Tenant'; '02' = 'Identities'; '03' = 'Credentials'; '04' = 'Federation'
    '05' = 'Permissions'; '06' = 'Hygiene'; '07' = 'Monitoring'; '08' = 'Conditional Access'
}
if ($RunDir) {
    $selectedRun = if ([IO.Path]::IsPathRooted($RunDir)) { $RunDir } else { Join-Path $OutputDir $RunDir }
} else {
    $selectedRun = $OutputDir
    $flatFiles = @(Get-ChildItem -LiteralPath $OutputDir -File | Where-Object { $_.Name -match '^0[1-8]-.*\.json$' })
    if ($flatFiles.Count -eq 0) {
        $runs = @(Get-ChildItem -LiteralPath $OutputDir -Directory | Where-Object {
            @(Get-ChildItem -LiteralPath $_.FullName -File | Where-Object { $_.Name -match '^0[1-8]-.*\.json$' }).Count -gt 0
        })
        if ($runs.Count -gt 1 -and @($runs | Where-Object { $_.Name -notmatch '^\d{8}-\d{6}$' }).Count -gt 0) {
            throw 'Ambiguous assessment folders. Select one snapshot with -RunDir <folder> or -OutputDir <run-folder>.'
        }
        if ($runs.Count -gt 0) { $selectedRun = ($runs | Sort-Object Name -Descending | Select-Object -First 1).FullName }
    }
}
if (-not (Test-Path -LiteralPath $selectedRun -PathType Container)) {
    throw "Run directory not found: $selectedRun"
}
$selectedRun = (Resolve-Path -LiteralPath $selectedRun).Path
$files = @{}
foreach ($id in $scriptIds) {
    $candidates = @(Get-ChildItem -LiteralPath $selectedRun -Filter "$id-*.json" -File)
    if ($candidates.Count -gt 1) {
        throw "Multiple $id exports in '$selectedRun'. Keep one file per collector in a snapshot."
    }
    if ($candidates.Count -eq 1) {
        $files[$id] = $candidates[0].FullName
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
        Write-Host ("  [{0}] (no export - see source status in the report)" -f $id) -ForegroundColor Yellow
    }
}
Write-Host ""

# ---------------------------------------------------------------------------
# Load JSON
# ---------------------------------------------------------------------------
function Test-JsonObject($value) {
    return $null -ne $value -and $value.GetType().FullName -eq 'System.Management.Automation.PSCustomObject'
}

$requiredFields = @{
    '01' = @('TenantInfo','CapabilityFlags','AuthorizationPolicy','AdminConsentPolicy','RoleMemberCounts','AzureSubscriptions')
    '02' = @('appRegistrations','servicePrincipals','managedIdentities')
    '03' = @('Aggregations','Credentials')
    '04' = @('TotalFICs','FICsOnAppRegs','FICsOnUserAssignedMIs','ByIssuerCategory','BySubjectClass','FederatedCredentials')
    '05' = @('GraphPermissions','AzureRbac')
    '06' = @('Aggregations','ServicePrincipals')
    '07' = @('diagnosticSettings','keyVaults','logAnalyticsWorkspaces')
    '08' = @('WorkloadIdentitiesPremiumLicensed','TotalCAPolicies','WITargetedPolicies','EnabledWIPolicies','ReportOnlyWIPolicies','TotalFirstPartySPs','SPsCoveredByCAPolicy','SPCoveragePct','Policies','SPCoverage')
}
$collectionFields = @{
    '01' = @('AzureSubscriptions')
    '02' = @('appRegistrations','servicePrincipals','managedIdentities')
    '03' = @('Credentials')
    '04' = @('ByIssuerCategory','BySubjectClass','FederatedCredentials')
    '05' = @('GraphPermissions','AzureRbac')
    '06' = @('ServicePrincipals')
    '07' = @('diagnosticSettings','keyVaults','logAnalyticsWorkspaces')
    '08' = @('Policies','SPCoverage')
}
$objectFields = @{
    '01' = @('TenantInfo','CapabilityFlags','AuthorizationPolicy','AdminConsentPolicy','RoleMemberCounts')
    '03' = @('Aggregations')
    '06' = @('Aggregations')
}
$aggregationFields = @{
    '03' = @('TotalActivePasswordCredentials','TotalActiveKeyCredentials','CertificateToPasswordRatioPct','MedianSecretLifetimeDays','MaxSecretLifetimeDays','ExpiredCredentialsStillAttached','ActiveSecretsOver12Months','ActiveSecretsOver24Months')
    '06' = @('TotalFirstPartySPs','Stale90Days','Stale365Days','NeverSignedIn','NoOwner','OrphanedOwner','AppRegMissingTags')
}
$data = @{}
$rawData = @{}
$sourceText = @{}
$sources = @()
$runSummary = $null
$runSummaryPath = Join-Path $selectedRun 'run-summary.json'
if (Test-Path -LiteralPath $runSummaryPath) {
    try {
        $runSummary = Get-Content -Raw -LiteralPath $runSummaryPath | ConvertFrom-Json
    } catch {
        Write-Warning "Could not read run-summary.json: $_"
    }
}
foreach ($id in $scriptIds) {
    $source = [ordered]@{
        Id = $id; Name = $datasetNames[$id]; FileName = $null; State = 'Missing'
        CollectedAt = $null; Message = 'File not present. Collection status unknown.'
    }
    $data[$id] = $null
    $collectorResult = $runSummary.ScriptResults | Where-Object Number -eq $id | Select-Object -First 1
    if (-not $files.ContainsKey($id) -and $collectorResult) {
        switch ($collectorResult.Status) {
            'Failed' {
                $source.State = 'Failed'
                $source.Message = "Collector failed (exit $($collectorResult.ExitCode)). $($collectorResult.ErrorMessage) See run-summary.json and transcript.txt; rerun collection to populate this section."
            }
            'Skipped' { $source.State = 'Skipped'; $source.Message = 'Collector was skipped for this run.' }
            'Not collected' { $source.State = 'Not collected'; $source.Message = 'Collector was outside the selected assessment scope.' }
        }
    }
    if ($files.ContainsKey($id)) {
        $source.FileName = Split-Path -Leaf $files[$id]
        try {
            $sourceText[$id] = Get-Content -Raw -LiteralPath $files[$id]
            $parsed = $sourceText[$id] | ConvertFrom-Json -Depth 100 -NoEnumerate
            if (-not (Test-JsonObject $parsed)) { throw 'Expected a JSON object at the top level.' }
            $rawData[$id] = $parsed
            $source.CollectedAt = $parsed.PSObject.Properties['CollectedAt'].Value
            $azureExcluded = $parsed.PSObject.Properties['AzureCollected'].Value -is [bool] -and $parsed.AzureCollected -eq $false
            $excludedFields = if ($azureExcluded) {
                switch ($id) {
                    '01' { 'AzureSubscriptions' }
                    '02' { 'managedIdentities' }
                    '04' { 'FICsOnUserAssignedMIs' }
                    '05' { 'AzureRbac' }
                }
            } else { @() }
            $absent = @($requiredFields[$id] | Where-Object {
                $_ -notin $excludedFields -and ($null -eq $parsed.PSObject.Properties[$_] -or $null -eq $parsed.PSObject.Properties[$_].Value)
            })
            foreach ($field in $collectionFields[$id]) {
                $value = $parsed.PSObject.Properties[$field].Value
                if ($null -ne $value -and @($value | Where-Object { -not (Test-JsonObject $_) }).Count -gt 0) {
                    $absent += "$field (expected exported records)"
                }
            }
            foreach ($field in $objectFields[$id]) {
                $value = $parsed.PSObject.Properties[$field].Value
                if ($null -ne $value -and -not (Test-JsonObject $value)) { $absent += "$field (expected object)" }
            }
            if ($aggregationFields.ContainsKey($id)) {
                $aggregation = $parsed.PSObject.Properties['Aggregations'].Value
                foreach ($field in $aggregationFields[$id]) {
                    $property = if ($null -ne $aggregation) { $aggregation.PSObject.Properties[$field] } else { $null }
                    $allowsUnknown = $id -eq '06' -and $field -in @('Stale90Days','Stale365Days','NeverSignedIn')
                    if ($null -ne $aggregation -and ($null -eq $property -or ($null -eq $property.Value -and -not $allowsUnknown))) {
                        $absent += "Aggregations.$field"
                    }
                }
            }
            if ($absent.Count -gt 0) {
                $source.State = 'Partial'
                $source.Message = 'Required report fields unavailable or invalid: ' + ($absent -join ', ') + '. This dataset is not evaluated; inspect Raw data.'
                Write-Warning "$($source.FileName): $($source.Message)"
            } else {
                $source.State = 'Loaded'
                $source.Message = if ($azureExcluded) { 'Entra export loaded. Azure checks not collected (Entra-only assessment).' } else { 'Export loaded. File presence does not establish complete collection.' }
                $data[$id] = $parsed | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100
            }
            if ($source.State -eq 'Loaded' -and $collectorResult.Status -eq 'Failed') {
                $source.State = 'Partial'
                $source.Message = "Collector failed (exit $($collectorResult.ExitCode)) despite writing an export. $($collectorResult.ErrorMessage) This dataset is not evaluated; inspect Raw data and transcript.txt."
                $data[$id] = $null
            }
        } catch {
            $source.State = 'Unreadable'
            $source.Message = "Could not read this export: $($_.Exception.Message)"
            Write-Warning "$($source.FileName): $($source.Message)"
        }
    }
    $sources += [PSCustomObject]$source
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

function Get-Rows($obj, [string] $name) {
    Get-Prop $obj $name | Where-Object { $null -ne $_ }
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

$tables = [System.Collections.Generic.List[object]]::new()
function ToTable($rows, [string[]] $columns) {
    $arr = @($rows | Where-Object { $null -ne $_ })
    if ($arr.Count -eq 0) { return "<p class='empty'>0 exported rows.</p>" }
    $index = $tables.Count
    $tables.Add(@{ Rows = $arr; Columns = $columns })
    return "<div class='data-table' data-table='$index'></div>"
}

function Section([string] $id, [string] $title, [string] $body) {
    return @"
<section id="$id" class="view" role="tabpanel" aria-labelledby="tab-$id" hidden>
  <h2>$(HE $title)</h2>
  $body
</section>
"@
}

$assessmentScope = 'EntraAndAzure'
if ((Get-Prop $runSummary 'AssessmentScope') -eq 'Entra') { $assessmentScope = 'Entra' }
if (@($data.Values | Where-Object { (Get-Prop $_ 'AzureCollected') -eq $false }).Count -gt 0) {
    $assessmentScope = 'Entra'
}
if ($assessmentScope -eq 'Entra') {
    $monitoringSource = $sources | Where-Object Id -eq '07'
    $monitoringSource.State = 'Not collected'
    $monitoringSource.Message = 'Azure monitoring and Key Vault checks were not collected (Entra-only assessment).'
    $data['07'] = $null
    $rawData.Remove('07')
    $sourceText.Remove('07')
}
$azureScopeNotice = "<p class='notice'>Azure checks not collected (Entra-only assessment).</p>"

# ---------------------------------------------------------------------------
# Offline, source-backed workload control evaluation
# ---------------------------------------------------------------------------
Import-Module (Join-Path $PSScriptRoot 'Assessment.Controls.psm1') -Force -ErrorAction Stop
ConvertTo-WorkloadSnapshot -Data $data
$assessment = Invoke-WorkloadControls -Data $data
$findings = [System.Collections.Generic.List[object]]::new()
foreach ($result in $assessment.Results) {
    if ($result.Outcome -in @('Fail','Review')) { $findings.Add($result) }
}
$d1 = $data['01']; $d2 = $data['02']; $d3 = $data['03']; $d4 = $data['04']
$d5 = $data['05']; $d6 = $data['06']; $d7 = $data['07']; $d8 = $data['08']

# ---------------------------------------------------------------------------
# Build HTML
# ---------------------------------------------------------------------------
$sb = [System.Text.StringBuilder]::new()

# Header
$tenantName = if ($d1) { Get-Prop (Get-Prop $d1 'TenantInfo') 'DisplayName' } else { 'Unknown' }
$tenantId   = if ($d1) { Get-Prop (Get-Prop $d1 'TenantInfo') 'TenantId'    } else { '' }
$primary    = if ($d1) { Get-Prop (Get-Prop $d1 'TenantInfo') 'PrimaryDomain' } else { '' }

$riskCatalog = $assessment.PermissionRisk
$aztierSource = $riskCatalog.AZTier
$permissionMethodology = "<aside class='notice permission-methodology'><h3>Permission severity methodology and disclaimer</h3><p>$(HE $riskCatalog.Limitations)</p><p>Permission catalog $(HE $riskCatalog.Version), verified $(HE $riskCatalog.VerifiedOn). AZTier reviewed list last changed $(HE $aztierSource.TieredLastChanged); untiered discovery list last changed $(HE $aztierSource.UntieredLastChanged). These are separate dates, not a freshness guarantee.</p><p><a href='$(HE $aztierSource.TieredSourceUrl)' target='_blank' rel='noopener noreferrer'>Pinned AZTier reviewed mappings</a> | <a href='$(HE $aztierSource.UntieredSourceUrl)' target='_blank' rel='noopener noreferrer'>Pinned AZTier untiered detections</a> | <a href='$(HE $aztierSource.MethodologyUrl)' target='_blank' rel='noopener noreferrer'>Upstream methodology and maintenance disclaimer</a></p><p>$(HE $aztierSource.Attribution) Source-data license: <a href='$(HE $aztierSource.LicenseUrl)' target='_blank' rel='noopener noreferrer'>$(HE $aztierSource.License)</a>. The full source-data license and mapping are embedded under Control coverage &gt; Permission risk catalog and sources.</p></aside>"

# Findings
$findingsHtml = if ($findings.Count -eq 0) {
    "<p class='muted'>No Fail/Review results raised from available evidence. Check Control coverage for unknown or manual assessments; this is not an all-clear.</p>"
} else {
    $sortOrder = @{ 'High'=0; 'Med'=1; 'Low'=2; 'Info'=3 }
    $sorted = $findings | Sort-Object @{ Expression = { $sortOrder[$_.Severity] } }
    $h = [System.Text.StringBuilder]::new()
    [void]$h.Append("<div class='table-scroll findings-table-wrap'><table class='findings-table' aria-label='Assessment findings'><thead><tr><th scope='col'>Severity</th><th scope='col'>Finding</th><th scope='col'>Outcome</th><th scope='col'>Affected / eligible</th><th scope='col'>Details</th></tr></thead>")
    foreach ($f in $sorted) {
        $index = $findings.IndexOf($f)
        $sevClass = "sev-$($f.Severity.ToLower())"
        $severityLabel = if ($f.Severity -eq 'Med') { 'Medium' } else { $f.Severity }
        [void]$h.Append("<tbody class='finding $sevClass' data-severity='$(HE $f.Severity)' data-finding-index='$index' tabindex='-1'>")
        [void]$h.Append("<tr class='finding-summary'><td><span class='sev'>$(HE $severityLabel)</span></td>")
        [void]$h.Append("<td><strong class='ftitle'>$(HE $f.Title)</strong><span class='finding-control muted'>$(HE $f.Id) $(HE $f.ExternalId)</span></td>")
        [void]$h.Append("<td>$(HE $f.Outcome)</td><td><button type='button' data-finding-affected='$index' aria-label='View affected objects for $(HE $f.Id): $($f.AffectedCount) of $($f.EligibleCount) eligible' aria-expanded='false' aria-controls='finding-evidence-$index'>$($f.AffectedCount) / $($f.EligibleCount)</button></td>")
        [void]$h.Append("<td><button type='button' data-finding-toggle='$index' aria-label='Show details for $(HE $f.Id)' aria-expanded='false' aria-controls='finding-details-$index'>Details</button></td></tr>")
        [void]$h.Append("<tr class='finding-details' id='finding-details-$index' hidden><td colspan='5'><div class='finding-detail'>")
        [void]$h.Append("<div class='fdetail'>$(HE $f.Detail)</div>")
        [void]$h.Append("<p class='muted'>$(HE $f.Strength). $($f.AffectedCount) affected of $($f.EligibleCount) eligible exported records; $($f.UnknownCount) unknown. $(HE $f.Denominator)</p>")
        [void]$h.Append("<div class='frec'><strong>Recommendation:</strong> $(HE $f.Recommendation)</div>")
        $sourceCount = if ($f.PermissionSourceUrls.Count) { $f.PermissionSourceUrls.Count } else { 1 }
        if ($f.BaselineSourceUrl -and $f.BaselineSourceUrl -ne $f.SourceUrl) { $sourceCount++ }
        [void]$h.Append("<details class='finding-sources'><summary>Sources and rationale ($sourceCount)</summary><ul>")
        if ($f.PermissionSourceUrls.Count) {
            foreach ($sourceUrl in $f.PermissionSourceUrls) {
                [void]$h.Append("<li><a href='$(HE $sourceUrl)' target='_blank' rel='noopener noreferrer'>Permission source and rationale: $(HE ([uri]$sourceUrl).Host)</a></li>")
            }
        } else {
            [void]$h.Append("<li><a href='$(HE $f.SourceUrl)' target='_blank' rel='noopener noreferrer'>Source and rationale: $(HE $f.Source)</a></li>")
        }
        if ($f.BaselineSourceUrl -and $f.BaselineSourceUrl -ne $f.SourceUrl) {
            [void]$h.Append("<li><a href='$(HE $f.BaselineSourceUrl)' target='_blank' rel='noopener noreferrer'>Pinned baseline: $(HE $f.ExternalId)</a></li>")
        }
        [void]$h.Append("</ul></details>")
        [void]$h.Append("<button type='button' data-evidence='$index' aria-expanded='false' aria-controls='finding-evidence-$index'>View affected objects ($($f.AffectedCount))</button><div class='finding-evidence' id='finding-evidence-$index' hidden></div>")
        [void]$h.Append("</div></td></tr></tbody>")
    }
    [void]$h.Append("</table></div>")
    $h.ToString()
}
$findingMethodology = "<p class='muted finding-disclaimer'>Snapshot-only review. Severity is review priority, not proof of compromise. Low / Unrated is not proven low risk.</p><details class='finding-methodology'><summary>Permission severity methodology and sources</summary>$permissionMethodology</details>"
[void]$sb.Append((Section 'findings' "Findings & Recommendations ($($findings.Count))" ($findingMethodology + $findingsHtml)))
[void]$sb.Append((Section 'controls' 'Control coverage' "<p class='notice'>Non-human identities only. Review is not confirmed overprivilege; Not assessed is not a pass. Manual and partial controls remain explicit. No overall compliance score.</p>$permissionMethodology<div id='control-coverage'></div>"))

# 01 Tenant
if ($d1) {
    $caps = Get-Prop $d1 'CapabilityFlags'
    $auth = Get-Prop $d1 'AuthorizationPolicy'
    $consent = Get-Prop $d1 'AdminConsentPolicy'
    $rmc = Get-Prop $d1 'RoleMemberCounts'
    $subs = @(Get-Rows $d1 'AzureSubscriptions')

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
            $available = Get-Prop $c 'Available'
            $av = if ($null -eq $available) { "<span class='badge'>Not exported</span>" } elseif ($available) { "<span class='badge ok'>YES</span>" } else { "<span class='badge no'>NO</span>" }
            $sks = @(Get-Rows $c 'ProvidedBySkus')
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
    $sps = @(Get-Rows $d2 'servicePrincipals')
    $ar  = @(Get-Rows $d2 'appRegistrations')
    $mi  = @(Get-Rows $d2 'managedIdentities')
    $custom = @($sps | Where-Object { $_.Category -eq 'Tenant-managed' -and $_.ServicePrincipalType -eq 'Application' })
    $external = @($sps | Where-Object { Get-Prop $_ 'IsExternalApp' })
    $noOwn  = @($custom | Where-Object { (Get-Prop $_ 'OwnerCount') -eq 0 })
    $never  = @($sps | Where-Object { Get-Prop $_ 'NeverSignedIn' })

    $tiles = @(
        Tile 'Service principals (total)' $sps.Count
        Tile 'Tenant-managed Application SPs' $custom.Count
        Tile 'Microsoft / external SPs' $external.Count
        Tile 'App registrations' $ar.Count
        Tile 'Managed identities (Azure)' $(if ((Get-Prop $d2 'AzureCollected') -eq $false) { 'Not collected' } else { $mi.Count })
        Tile 'In-tenant SPs without owner' $noOwn.Count $(if ($noOwn.Count -gt 0) { 'warn' } else { 'good' })
    ) -join ''
    $body = "<div class='tiles'>$tiles</div>"
    if ((Get-Prop $d2 'AzureCollected') -eq $false) { $body += $azureScopeNotice }

    $body += "<div id='identity-browser'></div>"
    [void]$sb.Append((Section 'inventory' 'Identity inventory' $body))
}

# 03 Credentials
if ($d3) {
    $agg = Get-Prop $d3 'Aggregations'
    $creds = @(Get-Rows $d3 'Credentials')
    $tiles = ''
    if ($agg) {
        $secrets = Get-Prop $agg 'TotalActivePasswordCredentials'
        $certs   = Get-Prop $agg 'TotalActiveKeyCredentials'
        $tiles = @(
            Tile 'Active secrets' $secrets $(if ($secrets -gt 0) { 'warn' } else { 'good' })
            Tile 'Active certificates' $certs
            Tile 'Cert : secret ratio' "$(Get-Prop $agg 'CertificateToPasswordRatioPct')%"
            Tile 'Median lifetime (days)' (Get-Prop $agg 'MedianSecretLifetimeDays')
            Tile 'Max lifetime (days)' (Get-Prop $agg 'MaxSecretLifetimeDays')
            Tile 'Expired still attached' (Get-Prop $agg 'ExpiredCredentialsStillAttached') $(if ((Get-Prop $agg 'ExpiredCredentialsStillAttached') -gt 0) { 'warn' } else { 'good' })
            Tile 'Active > 12 months' (Get-Prop $agg 'ActiveSecretsOver12Months')
            Tile 'Active > 24 months' (Get-Prop $agg 'ActiveSecretsOver24Months') $(if ((Get-Prop $agg 'ActiveSecretsOver24Months') -gt 0) { 'warn' } else { 'good' })
        ) -join ''
    }
    $body = "<div class='tiles'>$tiles</div>"
    $activity = Get-Prop $d3 'CredentialActivity'
    if ($activity) {
        $activityState = Get-Prop $activity 'State'
        $body += "<p class='notice'>Credential activity (preview): $(HE $activityState). $(HE (Get-Prop $activity 'Message')) Application object ID, credential key ID, type and origin are matched; the latest observed activity across matched resources is used. Scope: app-registration credentials only. Missing activity is not proof of no use.</p>"
        $body += "<div class='tiles'>" + (Tile 'Inactive credentials >= 90 days (review)' $(if ($activityState -eq 'Available') { Get-Prop $agg 'InactiveCredentials90Days' } else { 'Not assessed' })) +
            (Tile 'Unknown credential usage' $(if ($activityState -eq 'Available') { Get-Prop $agg 'CredentialsWithoutActivityEvidence' } else { 'Not assessed' })) + "</div>"
    } else {
        $body += "<p class='notice'>Credential-level usage not assessed: this export predates preview activity collection. Expiry and credential lifetime are separate from usage.</p>"
    }
    $body += "<p class='notice'>Client-secret lifetime: more than 365 days or missing/invalid lifetime evidence requires review. The day threshold is toolkit policy, not a universal Microsoft maximum. Missing expiry is unknown, not proof of a never-expiring secret. SP-origin secrets are assessed separately in Identities and Findings.</p><h3>Credentials</h3>"
    $body += ToTable $creds @('AppDisplayName','CredentialType','CredentialDisplayName','StartDateTime','EndDateTime','LifetimeDays','SecretLifetimeDays','SecretLifetimeStatus','DaysUntilExpiry','Expired','LastCredentialSignInDateTime','ActivityMatchStatus','UsageAssessment','CredentialReviewRequired')
    [void]$sb.Append((Section 'credentials' '03 — Credential Hygiene' $body))
}

# 04 FIC
if ($d4) {
    $fics = @(Get-Rows $d4 'FederatedCredentials')
    $tiles = @(
        Tile 'Total FICs'     (Get-Prop $d4 'TotalFICs')
        Tile 'On app regs'    (Get-Prop $d4 'FICsOnAppRegs')
        Tile 'On UA MIs'      $(if ((Get-Prop $d4 'AzureCollected') -eq $false) { 'Not collected' } else { Get-Prop $d4 'FICsOnUserAssignedMIs' })
    ) -join ''
    $body = "<div class='tiles'>$tiles</div>"
    if ((Get-Prop $d4 'AzureCollected') -eq $false) { $body += $azureScopeNotice }
    $body += "<h3>By issuer</h3>"
    $body += ToTable (Get-Prop $d4 'ByIssuerCategory') @('Category','Count')
    $body += "<h3>By subject classification</h3>"
    $body += ToTable (Get-Prop $d4 'BySubjectClass') @('Classification','Count')
    $body += "<h3>All FICs</h3>"
    $body += ToTable $fics @('TargetName','FicName','IssuerCategory','SubjectClassification','Subject','Audiences')
    [void]$sb.Append((Section 'fic' '04 — Federated Identity Credentials' $body))
}

# 05 Permissions
if ($d5) {
    $gp = @(Get-Rows $d5 'NormalizedPermissions' | Where-Object GrantState -eq 'Granted')
    $rb = @(Get-Rows $d5 'AzureRbac')
    $tiles = @(
        Tile 'Granted API permissions (both types)' $gp.Count
        Tile 'High priority' @($gp | Where-Object RiskSeverity -eq 'High').Count 'warn'
        Tile 'Medium priority' @($gp | Where-Object RiskSeverity -eq 'Med').Count 'warn'
        Tile 'Info (not verified safe)' @($gp | Where-Object RiskSeverity -eq 'Info').Count
        Tile 'Low / Unrated (manual assessment)' @($gp | Where-Object RiskSeverity -eq 'Low').Count
        Tile 'Azure RBAC assignments to SP/MI' $(if ((Get-Prop $d5 'AzureCollected') -eq $false) { 'Not collected' } else { $rb.Count })
    ) -join ''
    $body = "<div class='tiles'>$tiles</div>"
    $body += $permissionMethodology
    $body += "<p class='muted'>Consent audience shows organization-wide delegated access (AllPrincipals) separately from a specific-user grant. WI.CONSENT.1 lists these grants as Info, independent of dangerous-permission ratings. This is the recorded grant outcome, not proof that someone clicked &quot;Consent on behalf of your organization&quot; or evidence of who approved it.</p>"
    if ((Get-Prop $d5 'AzureCollected') -eq $false) { $body += $azureScopeNotice }
    if ($rb.Count -gt 0) {
        $body += "<h3>Azure RBAC on workload identities</h3>"
        $body += ToTable $rb @('PrincipalDisplayName','RoleName','Scope')
    }
    [void]$sb.Append((Section 'permissions' '05 — Permission Surface' $body))
}

# 06 Stale & orphaned
if ($d6) {
    $agg6 = Get-Prop $d6 'Aggregations'
    $sps6 = @(Get-Rows $d6 'ServicePrincipals')
    $tiles = ''
    if ($agg6) {
        $stale90 = Get-Prop $agg6 'Stale90Days'
        $stale365 = Get-Prop $agg6 'Stale365Days'
        $tiles = @(
            Tile 'In-tenant SPs (analysed)' (Get-Prop $agg6 'TotalFirstPartySPs')
            Tile 'Observed activity age >= 90 days' $(if ($null -eq $stale90) { 'Unknown' } else { $stale90 }) $(if ($null -eq $stale90) { 'neutral' } elseif ($stale90 -gt 0) { 'warn' } else { 'good' })
            Tile 'Observed activity age >= 365 days' $(if ($null -eq $stale365) { 'Unknown' } else { $stale365 }) $(if ($null -eq $stale365) { 'neutral' } elseif ($stale365 -gt 0) { 'warn' } else { 'good' })
            Tile 'Never used (not established)' 'Unknown'
            Tile 'No owner' (Get-Prop $agg6 'NoOwner') $(if ((Get-Prop $agg6 'NoOwner') -gt 0) { 'warn' } else { 'good' })
            Tile 'Orphaned owner' (Get-Prop $agg6 'OrphanedOwner') $(if ((Get-Prop $agg6 'OrphanedOwner') -gt 0) { 'warn' } else { 'good' })
            Tile 'App regs missing tags' (Get-Prop $agg6 'AppRegMissingTags')
        ) -join ''
    }
    $body = "<div class='tiles'>$tiles</div>"
    $body += "<h3>Service principals</h3>"
    $body += ToTable $sps6 @('DisplayName','AppId','OwnerCount','LastSignIn','DaysSinceLastSignIn')
    [void]$sb.Append((Section 'stale' '06 — Stale & Orphaned' $body))
}

# 07 Monitoring
if ($d7) {
    $kv = @(Get-Rows $d7 'keyVaults')
    $la = @(Get-Rows $d7 'logAnalyticsWorkspaces')
    $ds = @(Get-Rows $d7 'diagnosticSettings')
    $tiles = @(
        Tile 'Key Vaults' $kv.Count
        Tile 'Log Analytics workspaces' $la.Count
        Tile 'Entra diagnostic settings' $ds.Count $(if ($ds.Count -eq 0) { 'bad' } elseif ($ds.Count -lt 2) { 'warn' } else { 'good' })
    ) -join ''
    $body = "<div class='tiles'>$tiles</div>"
    if ($ds.Count -gt 0) {
        $body += "<h3>Entra diagnostic settings</h3>"
        $cols = @($ds | ForEach-Object { $_.PSObject.Properties.Name } | Select-Object -Unique)
        $body += ToTable $ds $cols
    }
    if ($kv.Count -gt 0) {
        $body += "<h3>Key Vaults</h3>"
        $cols = @($kv | ForEach-Object { $_.PSObject.Properties.Name } | Select-Object -Unique)
        $body += ToTable $kv $cols
    }
    if ($la.Count -gt 0) {
        $body += "<h3>Log Analytics workspaces</h3>"
        $cols = @($la | ForEach-Object { $_.PSObject.Properties.Name } | Select-Object -Unique)
        $body += ToTable $la $cols
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
    $pol = @(Get-Rows $d8 'Policies')
    if ($pol.Count -gt 0) {
        $body += "<h3>CA policies (workload-identity-relevant)</h3>"
        $cols = @($pol | ForEach-Object { $_.PSObject.Properties.Name } | Select-Object -Unique)
        $body += ToTable $pol $cols
    }
    $cov = @(Get-Rows $d8 'SPCoverage')
    if ($cov.Count -gt 0) {
        $body += "<h3>SP coverage detail</h3>"
        $cols = @($cov | ForEach-Object { $_.PSObject.Properties.Name } | Select-Object -Unique)
        $body += ToTable $cov $cols
    }
    [void]$sb.Append((Section 'ca' '08 — Conditional Access for Workload Identities' $body))
}

# Raw JSON
$rawHtml = [System.Text.StringBuilder]::new()
foreach ($id in $scriptIds) {
    if ($sourceText.ContainsKey($id)) {
        $name = Split-Path -Leaf $files[$id]
        $raw = $sourceText[$id]
        [void]$rawHtml.Append("<details><summary>$(HE $name) ($([math]::Round($raw.Length/1024, 1)) KB)</summary><pre>$(HE $raw)</pre></details>")
    }
}
[void]$sb.Append((Section 'raw' 'Raw data' $rawHtml.ToString()))

$sectionIds = @('tenant','inventory','credentials','fic','permissions','stale','monitoring','ca')
foreach ($source in $sources) {
    if ($source.State -ne 'Loaded') {
        [void]$sb.Append((Section $sectionIds[[int]$source.Id - 1] $source.Name "<p class='notice'>$(HE $source.State): $(HE $source.Message)</p>"))
    }
}

$payload = @{
    GeneratedAt = (Get-Date).ToUniversalTime().ToString('o')
    AssessmentScope = $assessmentScope
    RunDirectory = $selectedRun
    Sources = @($sources)
    Data = $data
    RawData = $rawData
    Findings = $findings.ToArray()
    Assessment = $assessment
    Tables = $tables.ToArray()
}
# Escape all markup delimiters so JSON cannot close its script element.
$json = ($payload | ConvertTo-Json -Depth 100 -Compress).Replace('&', '\u0026').Replace('<', '\u003c').Replace('>', '\u003e')
$assetDir = Join-Path $PSScriptRoot 'report-assets'
$template = Get-Content -Raw -LiteralPath (Join-Path $assetDir 'template.html')
$replacements = @{
    '__STYLES__' = Get-Content -Raw -LiteralPath (Join-Path $assetDir 'styles.css')
    '__APP_JS__' = Get-Content -Raw -LiteralPath (Join-Path $assetDir 'app.js')
    '__DATA_JSON__' = $json
    '__PANELS__' = $sb.ToString()
}
# One replacement pass: tenant values containing token text remain literal.
$html = [regex]::Replace($template, '__(?:STYLES|APP_JS|DATA_JSON|PANELS)__', [System.Text.RegularExpressions.MatchEvaluator]{
    param($match)
    return $replacements[$match.Value]
})

# ---------------------------------------------------------------------------
# Write
# ---------------------------------------------------------------------------
$html | Set-Content -LiteralPath $ReportPath -Encoding UTF8

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
Write-Host "  Exports loaded : $(@($sources | Where-Object State -eq 'Loaded').Count) / $($scriptIds.Count)"
Write-Host "  Selected run   : $selectedRun"
Write-Host "  Report         : $ReportPath"
Write-Host "═══════════════════════════════════════════════════════════════"
Write-Host ""
