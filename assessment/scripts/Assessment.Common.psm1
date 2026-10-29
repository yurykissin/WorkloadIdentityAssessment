Set-StrictMode -Version 1.0

$script:RunTenant = $null
$script:DirectoryCache = @{}
$script:OwnGraphAuthentication = $false
$script:OwnAzureAuthentication = $false

function Connect-AssessmentContexts {
    [CmdletBinding()]
    param(
        [string]$TenantId,
        [switch]$UseExistingContext,
        [bool]$IncludeAzure = $true,
        [switch]$IncludeOptionalWorkloadEvidence
    )

    if (-not (Get-Command Get-MgContext -ErrorAction SilentlyContinue)) {
        throw 'Microsoft.Graph.Authentication is missing. Run ./00-prereqs.ps1 from the scripts directory first.'
    }
    $graph = Get-MgContext
    if ($UseExistingContext -or ($graph -and $graph.AuthType -eq 'AppOnly')) {
        Assert-AssessmentContexts -RequireAzure:$IncludeAzure
        if ($TenantId -and $graph.TenantId -ne $TenantId) {
            throw "Existing context targets $($graph.TenantId), not $TenantId. For caller-managed authentication, supply the tenant GUID and connect both SDKs to it."
        }
        Write-Host "  Using caller-managed authentication for tenant $($graph.TenantId)." -ForegroundColor Gray
        return
    }

    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $script:OwnGraphAuthentication = $true
    $script:OwnAzureAuthentication = $IncludeAzure
    if ($graph) {
        Write-Host '  Signing out of the previous Graph session...' -ForegroundColor Gray
        Disconnect-MgGraph -ErrorAction Stop | Out-Null
    }
    $scopes = @(
        'Application.Read.All', 'Directory.Read.All', 'Policy.Read.All'
        'AuditLog.Read.All', 'IdentityRiskEvent.Read.All'
        'RoleManagement.Read.Directory', 'CrossTenantInformation.ReadBasic.All'
    )
    if ($IncludeOptionalWorkloadEvidence) {
        $scopes += @('AgentIdentity.Read.All','AgentIdentityBlueprint.Read.All','IdentityRiskyServicePrincipal.Read.All')
    }
    $environment = if ($graph -and $graph.Environment) { $graph.Environment } else { 'Global' }
    $azureEnvironments = @{
        Global = 'AzureCloud'
        USGov = 'AzureUSGovernment'
        USGovDoD = 'AzureUSGovernment'
        China = 'AzureChinaCloud'
    }
    if ($IncludeAzure -and -not $azureEnvironments.ContainsKey($environment)) {
        throw "Automatic Azure sign-in is not configured for Graph environment $environment. Connect both SDKs explicitly and use -UseExistingContext."
    }
    $targetTenant = $TenantId
    $arguments = @{
        Scopes = $scopes
        NoWelcome = $true
        Environment = $environment
        ErrorAction = 'Stop'
    }
    if ($targetTenant) { $arguments.TenantId = $targetTenant }
    Write-Host '  Signing in to Microsoft Graph (browser authentication)...' -ForegroundColor Cyan
    Connect-MgGraph @arguments | Out-Null
    Assert-AssessmentContexts
    $graph = Get-MgContext
    $expectedTenant = [guid]::Empty
    if ($targetTenant -and [guid]::TryParse($targetTenant, [ref]$expectedTenant) -and $graph.TenantId -ne $expectedTenant.ToString()) {
        throw "Graph sign-in returned tenant $($graph.TenantId), not $targetTenant. Collection was not started."
    }
    if (-not $IncludeAzure) { return }

    foreach ($command in @('Connect-AzAccount', 'Disable-AzContextAutosave', 'Clear-AzContext')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "$command is unavailable. Run ./00-prereqs.ps1 from the scripts directory first."
        }
    }
    Disable-AzContextAutosave -Scope Process -ErrorAction Stop | Out-Null
    Clear-AzContext -Scope Process -Force -ErrorAction Stop | Out-Null
    Write-Host "  Signing in to Azure for tenant $($graph.TenantId) (process scope)..." -ForegroundColor Cyan
    Connect-AzAccount -Tenant $graph.TenantId -Environment $azureEnvironments[$environment] -Scope Process -SkipContextPopulation -ErrorAction Stop | Out-Null
    Assert-AssessmentContexts -RequireAzure
}

function Disconnect-AssessmentContexts {
    [CmdletBinding()]
    param()

    if (-not $script:OwnAzureAuthentication -and -not $script:OwnGraphAuthentication) { return }
    Write-Host '  Signing out of assessment sessions...' -ForegroundColor Gray
    $failures = [System.Collections.Generic.List[string]]::new()
    if ($script:OwnAzureAuthentication) {
        try {
            Clear-AzContext -Scope Process -Force -ErrorAction Stop | Out-Null
            $script:OwnAzureAuthentication = $false
        } catch {
            $failures.Add("Azure sign-out failed: $($_.Exception.Message)")
        }
    }
    if ($script:OwnGraphAuthentication) {
        try {
            if (Get-MgContext) {
                Disconnect-MgGraph -ErrorAction Stop | Out-Null
            }
            $script:OwnGraphAuthentication = $false
        } catch {
            $failures.Add("Graph sign-out failed: $($_.Exception.Message)")
        }
    }
    if ($failures.Count -gt 0) {
        throw ($failures -join '; ')
    }
}

function Assert-AssessmentContexts {
    [CmdletBinding()]
    param([switch]$RequireAzure)

    $graph = Get-MgContext
    if (-not $graph -or -not $graph.TenantId) {
        throw 'No Graph context. Run ./run-all.ps1 or connect with Connect-MgGraph to the assessment tenant.'
    }
    if ($RequireAzure) {
        $azure = Get-AzContext -ErrorAction Stop
        if (-not $azure -or -not $azure.Tenant.Id) {
            throw 'No Azure context. Connect-AzAccount to the assessment tenant with -Scope Process.'
        }
        if ($graph.TenantId -ne $azure.Tenant.Id) {
            throw "Tenant mismatch: Graph=$($graph.TenantId), Azure=$($azure.Tenant.Id). Reconnect both to the same assessment tenant; no collection was started."
        }
    }
    if ($script:RunTenant -and $graph.TenantId -ne $script:RunTenant) {
        throw 'The assessment tenant changed during collection. Start a new snapshot after reconnecting.'
    }
}

function Start-AssessmentCollection {
    param([bool]$IncludeAzure = $true)
    Assert-AssessmentContexts -RequireAzure:$IncludeAzure
    $script:DirectoryCache = @{}
    $script:RunTenant = (Get-MgContext).TenantId
}

function Stop-AssessmentCollection {
    $script:DirectoryCache = @{}
    $script:RunTenant = $null
}

function Get-AssessmentProperty($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Name -in $Object.Keys) { return ,$Object[$Name] }
    } else {
        $property = $Object.PSObject.Properties[$Name]
        if ($property) { return ,$property.Value }
    }
    return $null
}

function Get-AssessmentGraphRoot {
    $context = Get-MgContext
    if ($script:RunTenant -and $context.TenantId -ne $script:RunTenant) {
        throw 'The Graph tenant changed during collection. Start a new assessment.'
    }
    $environment = Get-MgEnvironment -Name $context.Environment
    if (-not $environment.GraphEndpoint) { throw 'Graph environment endpoint is unavailable.' }
    return $environment.GraphEndpoint.TrimEnd('/')
}

function Invoke-AssessmentGraphGet {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [ValidateSet('v1.0', 'beta')][string]$ApiVersion = 'v1.0'
    )

    $root = Get-AssessmentGraphRoot
    if (-not $Uri.StartsWith("$root/$ApiVersion/", [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unexpected Graph pagination endpoint: $Uri"
    }
    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        try {
            return Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType PSObject -ErrorAction Stop
        } catch {
            $exception = $_.Exception
            $response = Get-AssessmentProperty $exception 'Response'
            $status = Get-AssessmentProperty $exception 'ResponseStatusCode'
            if ($null -eq $status) { $status = Get-AssessmentProperty $response 'StatusCode' }
            if ($attempt -eq 3 -or $null -eq $status -or [int]$status -notin @(429, 503, 504)) { throw }
            $headers = Get-AssessmentProperty $exception 'ResponseHeaders'
            if (-not $headers) { $headers = Get-AssessmentProperty $response 'Headers' }
            $retryAfter = Get-AssessmentProperty $headers 'Retry-After'
            if ($headers -is [System.Net.Http.Headers.HttpHeaders] -and $headers.Contains('Retry-After')) {
                $retryAfter = @($headers.GetValues('Retry-After'))
            }
            $seconds = 0
            if (-not [int]::TryParse([string](@($retryAfter)[0]), [ref]$seconds) -or $seconds -lt 0) {
                $retryDate = [DateTimeOffset]::MinValue
                if ([DateTimeOffset]::TryParse([string](@($retryAfter)[0]), [ref]$retryDate)) {
                    $seconds = [int][Math]::Ceiling([Math]::Max(0, ($retryDate - [DateTimeOffset]::UtcNow).TotalSeconds))
                } else {
                    $seconds = [int][Math]::Pow(2, $attempt + 1)
                }
            }
            Write-Warning "Graph HTTP $status. Retrying this page in $seconds seconds ($($attempt + 1)/3)."
            Start-Sleep -Seconds $seconds
        }
    }
}

function Get-AssessmentGraphCollection {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [ValidateSet('v1.0', 'beta')][string]$ApiVersion = 'v1.0'
    )

    $visited = [System.Collections.Generic.HashSet[string]]::new()
    while ($Uri) {
        if (-not $visited.Add($Uri)) { throw 'Graph returned a repeated pagination link.' }
        $page = Invoke-AssessmentGraphGet -Uri $Uri -ApiVersion $ApiVersion
        $value = Get-AssessmentProperty $page 'value'
        if ($null -eq $value) { throw "Graph collection is missing its value array: $Uri" }
        foreach ($record in $value) { $record }
        $Uri = Get-AssessmentProperty $page '@odata.nextLink'
    }
}

function Get-AssessmentCredentialActivity {
    [CmdletBinding()]
    param()

    $root = Get-AssessmentGraphRoot
    $result = [ordered]@{
        State = 'Unavailable'; Preview = $true
        Source = "$root/beta/reports/appCredentialSignInActivities"
        CollectedAt = [datetime]::UtcNow.ToString('o')
        Message = $null; RecordCount = $null; Records = $null
    }
    if ($root -ne 'https://graph.microsoft.com') {
        $result.State = 'Unsupported'
        $result.Message = 'The preview credential activity API is documented for the global cloud only.'
        Write-Warning $result.Message
        return [pscustomobject]$result
    }
    Write-Host '  Fetching credential sign-in activity (preview)...' -ForegroundColor Cyan
    try {
        Write-Progress -Id 71 -Activity 'Credential activity (preview)' -Status 'Loading all activity pages' -PercentComplete -1
        $records = @(Get-AssessmentGraphCollection -Uri $result.Source -ApiVersion beta)
        $result.State = 'Available'
        $result.Records = $records
        $result.RecordCount = $records.Count
        $result.Message = 'Preview activity loaded. Missing activity is not proof a credential has never been used.'
        Write-Host "  Credential activity (preview): $($records.Count) records loaded." -ForegroundColor Gray
    } catch {
        $result.Message = "Preview credential activity unavailable: $($_.Exception.Message). Credential usage is not assessed; expiry inventory continues."
        Write-Warning $result.Message
    } finally {
        Write-Progress -Id 71 -Activity 'Credential activity (preview)' -Completed
    }
    return [pscustomobject]$result
}

function Get-AssessmentEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('v1.0','beta')][string]$ApiVersion = 'v1.0',
        [switch]$Single
    )
    $root = Get-AssessmentGraphRoot
    $key = "evidence/$ApiVersion/$Path"
    if ($script:RunTenant -and $script:DirectoryCache.ContainsKey($key)) { return $script:DirectoryCache[$key] }
    $result = [pscustomobject]@{
        State = 'Unavailable'; Source = "$root/$ApiVersion/$Path"; ApiVersion = $ApiVersion
        CollectedAt = [datetimeoffset]::UtcNow.ToString('o'); Message = $null; Records = $null
    }
    try {
        $result.Records = if ($Single) { @(Invoke-AssessmentGraphGet -Uri $result.Source -ApiVersion $ApiVersion) } else {
            @(Get-AssessmentGraphCollection -Uri $result.Source -ApiVersion $ApiVersion)
        }
        $result.State = 'Available'
        $result.Message = 'All returned pages loaded. Absence of a record is not proof of historical absence.'
    } catch {
        $result.Message = $_.Exception.Message
        Write-Warning "Optional evidence $Path unavailable: $($result.Message)"
    }
    if ($script:RunTenant) { $script:DirectoryCache[$key] = $result }
    return $result
}

function Get-AssessmentSignInActivity {
    if ((Get-AssessmentGraphRoot) -ne 'https://graph.microsoft.com') {
        return [pscustomobject]@{ State = 'Unsupported'; Records = $null; ApiVersion = 'beta'; Message = 'SP activity reports are supported in the global cloud only.' }
    }
    Get-AssessmentEvidence -Path 'reports/servicePrincipalSignInActivities' -ApiVersion beta
}

function Get-AssessmentActivitySummary {
    param($Record, [datetimeoffset]$AsOf = [datetimeoffset]::UtcNow)
    $flows = [ordered]@{}
    $dates = @(
        foreach ($field in @('lastSignInActivity','delegatedClientSignInActivity','delegatedResourceSignInActivity',
            'applicationAuthenticationClientSignInActivity','applicationAuthenticationResourceSignInActivity')) {
            $value = (Get-AssessmentProperty $Record $field).lastSignInDateTime
            $flows[$field] = $value
            $date = [datetimeoffset]::MinValue
            if ($value -and [datetimeoffset]::TryParse([string]$value, [ref]$date) -and
                $date.Year -gt 1900 -and $date -le $AsOf) { $date }
        }
    )
    $last = $dates | Sort-Object -Descending | Select-Object -First 1
    [pscustomobject]@{
        LastSignIn = if ($last) { $last.ToUniversalTime().ToString('o') } else { $null }
        DaysSinceLastSignIn = if ($last) { [math]::Floor(($AsOf - $last).TotalDays) } else { $null }
        Flows = [pscustomobject]$flows
    }
}

function Get-AssessmentWorkloadEvidence {
    $start = [datetimeoffset]::UtcNow.AddDays(-30).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $filter = [uri]::EscapeDataString("activityDateTime ge $start and result eq 'success' and (activityDisplayName eq 'Add application' or activityDisplayName eq 'Add service principal')")
    $audit = Get-AssessmentEvidence -Path "auditLogs/directoryAudits?`$filter=$filter"
    $audit | Add-Member -NotePropertyName RequestedSince -NotePropertyValue $start -Force
    $result = [ordered]@{
        CreationAudits = $audit
        DefaultAppManagementPolicy = Get-AssessmentEvidence -Path 'policies/defaultAppManagementPolicy' -ApiVersion beta -Single
        AppManagementPolicies = Get-AssessmentEvidence -Path 'policies/appManagementPolicies' -ApiVersion beta
        PermissionGrantPolicies = Get-AssessmentEvidence -Path 'policies/permissionGrantPolicies'
        DirectoryRoles = Get-AssessmentEvidence -Path 'roleManagement/directory/roleAssignments'
        RiskyServicePrincipals = Get-AssessmentEvidence -Path 'identityProtection/riskyServicePrincipals'
        AgentIdentities = Get-AssessmentEvidence -Path 'servicePrincipals/microsoft.graph.agentIdentity'
        AgentBlueprints = Get-AssessmentEvidence -Path 'applications/microsoft.graph.agentIdentityBlueprint'
    }
    foreach ($policy in $result.AppManagementPolicies.Records) {
        if (-not $policy.id) { continue }
        $assignment = Get-AssessmentEvidence -Path "policies/appManagementPolicies/$($policy.id)/appliesTo" -ApiVersion beta
        $policy | Add-Member -NotePropertyName AssignmentEvidence -NotePropertyValue $assignment -Force
    }
    return [pscustomobject]$result
}

function Get-AssessmentCreator {
    param([string]$ObjectId, $Audit)
    $match = @($Audit.Records | Where-Object { $Audit.State -eq 'Available' -and $ObjectId -and
        $_.result -eq 'success' -and $_.activityDisplayName -in @('Add application','Add service principal') -and
        $ObjectId -in $_.targetResources.id } | Sort-Object activityDateTime | Select-Object -First 1)
    if (-not $match.Count) {
        return [pscustomobject]@{ State = 'Unavailable'; Message = 'Creator unavailable from retained audit history.' }
    }
    [pscustomobject]@{ State = 'Observed creation event'; EventId = $match[0].id; CreatedAt = $match[0].activityDateTime; InitiatedBy = $match[0].initiatedBy }
}

function Get-AssessmentDirectoryData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('applications', 'servicePrincipals')][string]$Resource,
        [Parameter(Mandatory)][ValidateSet('owners', 'appRoleAssignments', 'federatedIdentityCredentials')][string]$Relationship
    )

    if (($Resource -eq 'applications' -and $Relationship -eq 'appRoleAssignments') -or
        ($Resource -eq 'servicePrincipals' -and $Relationship -eq 'federatedIdentityCredentials')) {
        throw "Unsupported directory relationship: $Resource/$Relationship"
    }
    $root = Get-AssessmentGraphRoot
    $key = "$Resource/$Relationship"
    if ($script:RunTenant -and $script:DirectoryCache.ContainsKey($key)) {
        Write-Host "  Reusing this run's $Resource / $Relationship snapshot." -ForegroundColor Gray
        return $script:DirectoryCache[$key]
    }
    $fields = if ($Resource -eq 'applications') {
        'id,appId,displayName,signInAudience,createdDateTime,tags,publisherDomain,verifiedPublisher,passwordCredentials,keyCredentials,api,requiredResourceAccess,web,spa,publicClient,info,identifierUris,servicePrincipalLockConfiguration,serviceManagementReference'
    } elseif ($Relationship -eq 'owners') {
        'id,appId,displayName,servicePrincipalType,appOwnerOrganizationId,accountEnabled,tags'
    } else {
        'id,appId,displayName,servicePrincipalType,appOwnerOrganizationId,accountEnabled,tags,appRoles,oauth2PermissionScopes,createdDateTime,signInAudience,passwordCredentials,keyCredentials'
    }
    $uri = "$root/v1.0/${Resource}?`$select=$fields&`$expand=$Relationship&`$top=100"
    $records = [System.Collections.Generic.List[object]]::new()
    $visited = [System.Collections.Generic.HashSet[string]]::new()
    $activity = "Reading $Resource / $Relationship"
    try {
        while ($uri) {
            if (-not $visited.Add($uri)) { throw 'Graph returned a repeated directory pagination link.' }
            $page = Invoke-AssessmentGraphGet -Uri $uri
            $value = Get-AssessmentProperty $page 'value'
            if ($null -eq $value) { throw "Graph did not return a directory value array for $Resource." }
            foreach ($record in $value) {
                $related = Get-AssessmentProperty $record $Relationship
                if ($null -eq $related) {
                    throw "Graph did not expand $Relationship for $Resource/$($record.id); completeness is unknown."
                }
                $continuation = Get-AssessmentProperty $record "$Relationship@odata.nextLink"
                # Conservatively reread a full expansion at the directory expansion boundary.
                if (@($related).Count -ge 20 -and -not $continuation) {
                    $related = @(Get-AssessmentGraphCollection -Uri "$root/v1.0/$Resource/$($record.id)/$Relationship")
                } elseif ($continuation) {
                    $related = @($related) + @(Get-AssessmentGraphCollection -Uri $continuation)
                }
                $record.PSObject.Properties[$Relationship].Value = @($related)
                $records.Add($record)
            }
            Write-Progress -Id 70 -Activity $activity -Status ("{0:N0} records loaded" -f $records.Count) -PercentComplete -1
            $uri = Get-AssessmentProperty $page '@odata.nextLink'
        }
    } finally {
        Write-Progress -Id 70 -Activity $activity -Completed
    }
    Write-Host ("  {0} / {1}: {2:N0} records loaded." -f $Resource, $Relationship, $records.Count) -ForegroundColor Gray
    $result = $records.ToArray()
    if ($script:RunTenant) { $script:DirectoryCache[$key] = $result }
    return $result
}

Export-ModuleMember -Function Connect-AssessmentContexts, Disconnect-AssessmentContexts, Assert-AssessmentContexts, Start-AssessmentCollection, Stop-AssessmentCollection, Get-AssessmentDirectoryData, Get-AssessmentCredentialActivity, Get-AssessmentEvidence, Get-AssessmentSignInActivity, Get-AssessmentActivitySummary, Get-AssessmentWorkloadEvidence, Get-AssessmentCreator
