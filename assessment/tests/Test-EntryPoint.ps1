[CmdletBinding()]
param([string]$OutputRoot = (Join-Path $PSScriptRoot '../output/entry-tests'))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1.0
$scripts = (Resolve-Path (Join-Path $PSScriptRoot '../scripts')).Path
$null = New-Item -ItemType Directory -Path $OutputRoot -Force
$OutputRoot = (Resolve-Path $OutputRoot).Path
. (Join-Path $PSScriptRoot 'New-ReportFixture.ps1')
$checks = 0
$tenantA = '11111111-1111-4111-8111-111111111111'
$tenantB = '22222222-2222-4222-8222-222222222222'
$scopes = @(
    'Application.Read.All', 'Directory.Read.All', 'Policy.Read.All'
    'AuditLog.Read.All', 'IdentityRiskEvent.Read.All'
    'RoleManagement.Read.Directory', 'CrossTenantInformation.ReadBasic.All'
)
function Assert-Entry([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Assert-EntryRejected([scriptblock]$Action, [string]$Pattern, [string]$Message) {
    $messageReceived = $null
    try { & $Action | Out-Null } catch { $messageReceived = $_.Exception.Message }
    Assert-Entry ($messageReceived -like $Pattern) "$Message (received: $messageReceived)"
}
$global:AssessmentEntryTest = @{
    Graph = $null; Azure = $null
    AuthCalls = [System.Collections.Generic.List[object]]::new()
    AzureDiscovery = [System.Collections.Generic.List[object]]::new()
    Events = [System.Collections.Generic.List[string]]::new()
    AzureResets = [System.Collections.Generic.List[object]]::new()
    Opened = [System.Collections.Generic.List[string]]::new()
    Choices = [System.Collections.Generic.Queue[string]]::new()
    Prompts = [System.Collections.Generic.List[object]]::new()
    DefaultTenant = $tenantA; GraphError = $null; AzureError = $null; ReturnedTenant = $null
    AzureReturnedTenant = $null; BrowserError = $false; AzureCleanupError = $false
}
function global:Get-MgContext { $global:AssessmentEntryTest.Graph }
function global:Read-Host {
    param($Prompt)
    $state = $global:AssessmentEntryTest
    $state.Prompts.Add([pscustomobject]@{ Prompt = $Prompt; AuthCalls = $state.AuthCalls.Count })
    if ($state.Choices.Count -gt 0) { return $state.Choices.Dequeue() }
    return '2'
}
function global:Get-AzContext { [CmdletBinding()]param(); $global:AssessmentEntryTest.Azure }
function global:Connect-MgGraph {
    [CmdletBinding()]
    param($TenantId, $ContextScope = 'CurrentUser', $Scopes, [switch]$NoWelcome, $Environment, [switch]$UseDeviceAuthentication)
    $state = $global:AssessmentEntryTest
    if (-not (Get-Module Microsoft.Graph.Authentication -All)) { throw 'Graph must be imported before sign-in.' }
    $state.AuthCalls.Add([pscustomobject]@{
        Kind = 'Graph'; TenantId = $TenantId; Scope = $ContextScope; Scopes = $Scopes; Environment = $Environment
        CacheScopeSpecified = $PSBoundParameters.ContainsKey('ContextScope'); DeviceAuthentication = $UseDeviceAuthentication.IsPresent
    })
    if ($state.GraphError) { throw $state.GraphError }
    $actualTenant = if ($state.ReturnedTenant) { $state.ReturnedTenant } elseif ($TenantId) { $TenantId } else { $state.DefaultTenant }
    $state.Events.Add("GraphLogin:$actualTenant")
    $state.Graph = [pscustomobject]@{
        TenantId = $actualTenant; AuthType = 'Delegated'; ContextScope = $ContextScope
        Scopes = $Scopes; Environment = $Environment; Account = 'synthetic-graph-user'
    }
    function global:Disconnect-MgGraph {
        [CmdletBinding()]param()
        $state = $global:AssessmentEntryTest
        if (-not $state.Graph) { throw 'No Graph session to disconnect.' }
        $state.Events.Add("GraphLogout:$($state.Graph.TenantId)")
        $state.Graph = $null
    }
    function global:Clear-AzContext {
        [CmdletBinding()]param($Scope, [switch]$Force)
        $state = $global:AssessmentEntryTest
        $state.AzureResets.Add([pscustomobject]@{ Scope = $Scope; Force = $Force.IsPresent })
        if ($state.AzureCleanupError -and @($state.AuthCalls | Where-Object Kind -eq 'Azure').Count -gt 0) {
            throw 'Synthetic Azure cleanup failure'
        }
        $state.Events.Add('AzureClear')
        $state.Azure = $null
    }
}
function global:Disable-AzContextAutosave {
    [CmdletBinding()]param($Scope)
    $global:AssessmentEntryTest.AuthCalls.Add([pscustomobject]@{ Kind = 'Autosave'; Scope = $Scope })
}
function global:Connect-AzAccount {
    [CmdletBinding()]param($Tenant, $Scope, [switch]$SkipContextPopulation, $Environment)
    $state = $global:AssessmentEntryTest
    $state.AuthCalls.Add([pscustomobject]@{ Kind = 'Azure'; TenantId = $Tenant; Scope = $Scope; SkipContextPopulation = $SkipContextPopulation.IsPresent; Environment = $Environment })
    if ($state.AzureError) { throw $state.AzureError }
    $actualTenant = if ($state.AzureReturnedTenant) { $state.AzureReturnedTenant } else { $Tenant }
    $state.Events.Add("AzureLogin:$actualTenant")
    $state.Azure = [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $actualTenant }; Account = [pscustomobject]@{ Id = 'synthetic-azure-user' } }
}
function global:Invoke-Item {
    [CmdletBinding()]param($LiteralPath)
    if ($global:AssessmentEntryTest.BrowserError) { throw 'Synthetic browser unavailable' }
    $global:AssessmentEntryTest.Opened.Add($LiteralPath)
}
function global:Invoke-MgGraphRequest { throw 'No real Graph request is allowed in entry-point tests.' }
function Reset-Entry {
    $global:AssessmentEntryTest.AzureCleanupError = $false
    if (Get-Command Disconnect-AssessmentContexts -ErrorAction SilentlyContinue) {
        Disconnect-AssessmentContexts
    }
    Stop-AssessmentCollection
    $global:AssessmentEntryTest.Graph = $null
    $global:AssessmentEntryTest.Azure = $null
    $global:AssessmentEntryTest.AuthCalls.Clear()
    $global:AssessmentEntryTest.AzureDiscovery.Clear()
    $global:AssessmentEntryTest.Events.Clear()
    $global:AssessmentEntryTest.AzureResets.Clear()
    $global:AssessmentEntryTest.Opened.Clear()
    $global:AssessmentEntryTest.Choices.Clear()
    $global:AssessmentEntryTest.Prompts.Clear()
    $global:AssessmentEntryTest.GraphError = $null
    $global:AssessmentEntryTest.AzureError = $null
    $global:AssessmentEntryTest.ReturnedTenant = $null
    $global:AssessmentEntryTest.AzureReturnedTenant = $null
    $global:AssessmentEntryTest.BrowserError = $false
    $global:AssessmentEntryTest.DefaultTenant = $tenantA
}
function Set-EntryGraph([string]$Scope = 'Process', [string]$AuthType = 'Delegated', [string]$Tenant = $tenantA) {
    $global:AssessmentEntryTest.Graph = [pscustomobject]@{
        TenantId = $Tenant; AuthType = $AuthType; ContextScope = $Scope
        Scopes = $scopes; Environment = 'Global'; Account = 'synthetic-user'
    }
}
$savedModulePath = $env:PSModulePath
$mockModules = Join-Path $OutputRoot 'mock-modules'
$mockGraphModule = Join-Path $mockModules 'Microsoft.Graph.Authentication'
$null = New-Item -ItemType Directory -Path $mockGraphModule -Force
'Export-ModuleMember -Function @()' | Set-Content (Join-Path $mockGraphModule 'Microsoft.Graph.Authentication.psm1')
$env:PSModulePath = "$mockModules$([IO.Path]::PathSeparator)$savedModulePath"
$commonModule = Import-Module (Join-Path $scripts 'Assessment.Common.psm1') -PassThru
& $commonModule {
    function script:Get-Command {
        [CmdletBinding()]param([string]$Name)
        if ($Name -in @('Connect-AzAccount', 'Disable-AzContextAutosave', 'Clear-AzContext')) {
            $state = $global:AssessmentEntryTest
            $state.AzureDiscovery.Add([pscustomobject]@{
                Name = $Name
                GraphCalls = @($state.AuthCalls | Where-Object Kind -eq 'Graph').Count
            })
        }
        Microsoft.PowerShell.Core\Get-Command @PSBoundParameters
    }
}
$savedSubscriptionScope = $env:ASSESSMENT_SUBSCRIPTION_IDS
try {
    Reset-Entry
    Connect-AssessmentContexts
    $calls = $global:AssessmentEntryTest.AuthCalls
    Assert-Entry ($calls.Count -eq 3 -and $calls[0].Kind -eq 'Graph') 'A clean session signs in without manual setup'
    Assert-Entry (-not $calls[0].CacheScopeSpecified -and $calls[0].Scopes.Count -eq 7 -and -not $calls[0].DeviceAuthentication) 'Graph sign-in matches CAPVisualizer: assessment scopes, default cache scope and browser authentication'
    Assert-Entry ($global:AssessmentEntryTest.AzureDiscovery.Count -eq 3 -and @($global:AssessmentEntryTest.AzureDiscovery | Where-Object GraphCalls -ne 1).Count -eq 0) 'Azure command discovery cannot load its SDK before Graph sign-in'
    Assert-Entry ($calls[1].Kind -eq 'Autosave' -and $calls[1].Scope -eq 'Process') 'Azure autosave is disabled only for the current process'
    Assert-Entry ($calls[2].TenantId -eq $tenantA -and $calls[2].Scope -eq 'Process' -and $calls[2].SkipContextPopulation) 'Azure uses the signed-in Graph tenant without broad context population'
    Assert-Entry ($calls[0].Environment -eq 'Global' -and $calls[2].Environment -eq 'AzureCloud') 'Default sign-in keeps both SDKs in the public cloud'

    Reset-Entry
    Connect-AssessmentContexts -IncludeAzure:$false -IncludeOptionalWorkloadEvidence
    $optionalScopes = $global:AssessmentEntryTest.AuthCalls[0].Scopes
    Assert-Entry ($optionalScopes.Count -eq 10 -and 'AgentIdentity.Read.All' -in $optionalScopes -and 'AgentIdentityBlueprint.Read.All' -in $optionalScopes -and 'IdentityRiskyServicePrincipal.Read.All' -in $optionalScopes) 'Explicit optional-evidence opt-in adds the three documented read scopes'
    Assert-Entry (@($optionalScopes | Where-Object { $_ -like '*Write*' }).Count -eq 0) 'Optional evidence never requests write scopes'

    Reset-Entry
    Set-EntryGraph -Scope CurrentUser
    $global:AssessmentEntryTest.Azure = [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $tenantA } }
    $global:AssessmentEntryTest.ReturnedTenant = $tenantB
    Connect-AssessmentContexts
    Assert-Entry ($global:AssessmentEntryTest.Graph.ContextScope -eq 'CurrentUser' -and -not $global:AssessmentEntryTest.AuthCalls[0].CacheScopeSpecified) 'A persistent Graph context uses standard SDK sign-in instead of being rejected or forced to process scope'
    Assert-Entry (-not $global:AssessmentEntryTest.AuthCalls[0].TenantId) 'An old Graph tenant is not passed into the next sign-in'
    Assert-Entry ($global:AssessmentEntryTest.Azure.Tenant.Id -eq $tenantB) 'Azure follows the newly selected tenant rather than the previous account'
    Assert-Entry ($global:AssessmentEntryTest.Events[0] -eq "GraphLogout:$tenantA" -and $global:AssessmentEntryTest.Events[1] -eq "GraphLogin:$tenantB") 'The previous Graph session is disconnected before starting the next tenant'
    Assert-Entry ($global:AssessmentEntryTest.Events[2] -eq 'AzureClear' -and $global:AssessmentEntryTest.Events[3] -eq "AzureLogin:$tenantB") 'Previous Azure process contexts are cleared before Azure sign-in'

    Reset-Entry
    $oldAzure = [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $tenantB } }
    $global:AssessmentEntryTest.Azure = $oldAzure
    Connect-AssessmentContexts -IncludeAzure:$false
    Start-AssessmentCollection -IncludeAzure:$false
    Assert-Entry ($global:AssessmentEntryTest.AuthCalls.Count -eq 1 -and $global:AssessmentEntryTest.AzureDiscovery.Count -eq 0) 'Entra-only authentication and cache setup never discover or invoke Azure commands'
    Disconnect-AssessmentContexts
    Assert-Entry (-not $global:AssessmentEntryTest.Graph -and [object]::ReferenceEquals($oldAzure, $global:AssessmentEntryTest.Azure) -and $global:AssessmentEntryTest.AzureResets.Count -eq 0) 'Entra-only sign-out leaves unrelated Azure contexts untouched'

    Reset-Entry
    Set-EntryGraph
    Connect-AssessmentContexts
    Assert-Entry (@($global:AssessmentEntryTest.AuthCalls | Where-Object Kind -eq 'Graph').Count -eq 1) 'Standard Graph sign-in is invoked even when a delegated context already exists, matching CAPVisualizer'
    Assert-Entry (@($global:AssessmentEntryTest.AuthCalls | Where-Object Kind -eq 'Azure').Count -eq 1) 'Azure gets deliberate process-scoped authentication rather than assuming an old cache is safe'
    Reset-Entry
    Set-EntryGraph
    $global:AssessmentEntryTest.Graph.Scopes = @('Application.Read.All')
    Connect-AssessmentContexts
    Assert-Entry ($global:AssessmentEntryTest.AuthCalls[0].Kind -eq 'Graph') 'Missing delegated scopes trigger sign-in with the complete scope set'
    Reset-Entry
    Set-EntryGraph
    Connect-AssessmentContexts -TenantId $tenantB
    Assert-Entry ($global:AssessmentEntryTest.Graph.TenantId -eq $tenantB -and $global:AssessmentEntryTest.Azure.Tenant.Id -eq $tenantB) 'An explicit tenant overrides the previous Graph tenant'
    Reset-Entry
    Set-EntryGraph -Scope CurrentUser
    $global:AssessmentEntryTest.Graph.Environment = 'USGov'
    Connect-AssessmentContexts
    Assert-Entry ($global:AssessmentEntryTest.AuthCalls[0].Environment -eq 'USGov' -and $global:AssessmentEntryTest.AuthCalls[2].Environment -eq 'AzureUSGovernment') 'Reconnection preserves the selected sovereign cloud'

    Reset-Entry
    Set-EntryGraph -Scope CurrentUser
    $global:AssessmentEntryTest.GraphError = 'Synthetic canceled Graph sign-in'
    Assert-EntryRejected { Connect-AssessmentContexts } '*canceled Graph sign-in*' 'Canceled sign-in is not hidden by an old context'
    Assert-Entry ($global:AssessmentEntryTest.AuthCalls.Count -eq 1) 'Azure authentication does not start after Graph cancellation'
    Assert-Entry ($global:AssessmentEntryTest.AzureDiscovery.Count -eq 0) 'Failed Graph sign-in never discovers or imports Azure authentication commands'
    Reset-Entry
    $innerError = [System.Security.SecurityException]::new('Synthetic sensitive inner value')
    $cacheError = [System.InvalidOperationException]::new('Synthetic cache failure', $innerError)
    $cacheError.Data['token'] = 'Synthetic sensitive token'
    $global:AssessmentEntryTest.GraphError = $cacheError
    $caughtError = $null
    try { Connect-AssessmentContexts } catch { $caughtError = $_.Exception }
    Assert-Entry ([object]::ReferenceEquals($caughtError, $cacheError)) 'Standard sign-in preserves the original SDK exception and inner cause without custom recovery'
    Assert-Entry ($global:AssessmentEntryTest.AuthCalls.Count -eq 1) 'SDK failure neither retries authentication nor starts Azure sign-in'
    Reset-Entry
    $global:AssessmentEntryTest.ReturnedTenant = $tenantB
    Assert-EntryRejected { Connect-AssessmentContexts -TenantId $tenantA } '*Graph sign-in returned tenant*' 'An unexpected Graph tenant is rejected'
    Assert-Entry ($global:AssessmentEntryTest.AuthCalls.Count -eq 1) 'A wrong Graph tenant cannot start Azure authentication'
    Reset-Entry
    $global:AssessmentEntryTest.AzureError = 'Synthetic canceled Azure sign-in'
    Assert-EntryRejected { Connect-AssessmentContexts } '*canceled Azure sign-in*' 'Azure cancellation does not fall back to a cached account'
    Reset-Entry
    $global:AssessmentEntryTest.AzureReturnedTenant = $tenantB
    Assert-EntryRejected { Connect-AssessmentContexts } '*Tenant mismatch*' 'Final tenant alignment is checked after both connections'

    Reset-Entry
    Set-EntryGraph
    $global:AssessmentEntryTest.Azure = [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $tenantA } }
    Connect-AssessmentContexts -UseExistingContext
    Assert-Entry ($global:AssessmentEntryTest.AuthCalls.Count -eq 0) 'Explicit caller-managed mode never initiates sign-in'
    Set-EntryGraph -Scope CurrentUser
    Connect-AssessmentContexts -UseExistingContext
    Assert-Entry ($global:AssessmentEntryTest.AuthCalls.Count -eq 0) 'Caller-managed mode accepts the SDK default cache scope without reconnecting'
    Reset-Entry
    Set-EntryGraph -Scope CurrentUser -AuthType AppOnly
    $global:AssessmentEntryTest.Azure = [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $tenantA } }
    Connect-AssessmentContexts
    Assert-Entry ($global:AssessmentEntryTest.AuthCalls.Count -eq 0) 'An existing app-only setup remains unattended by default'
    Assert-EntryRejected { Connect-AssessmentContexts -TenantId $tenantB } '*Existing context targets*' 'App-only authentication cannot silently switch tenants'

    $skip = @('01', '02', '03', '04', '05', '06', '07', '08')
    $runner = Join-Path $scripts 'run-all.ps1'
    $flowOutput = Join-Path $OutputRoot 'one-command'
    New-ReportFixture -Destination $flowOutput
    Reset-Entry
    Set-EntryGraph -Scope CurrentUser
    & $runner -OutputDir $flowOutput -Skip $skip -NoOpen
    $report = Join-Path $flowOutput 'report.html'
    Assert-Entry ((Test-Path $report) -and -not $global:AssessmentEntryTest.Graph -and -not $global:AssessmentEntryTest.Azure) 'The real entry point generates the HTML report and signs out of both SDKs'
    Assert-Entry ($global:AssessmentEntryTest.AzureResets.Count -eq 2 -and @($global:AssessmentEntryTest.AzureResets | Where-Object { $_.Scope -ne 'Process' -or -not $_.Force }).Count -eq 0) 'Azure is reset before sign-in and at exit using only process scope'
    Assert-Entry ((Get-Content -Raw $report).Contains('Synthetic demonstration')) 'The automatically generated report contains the selected snapshot'
    Assert-Entry ($global:AssessmentEntryTest.Opened.Count -eq 0) '-NoOpen prevents browser launches'
    Assert-Entry (Test-Path (Join-Path $flowOutput 'run-summary.json')) 'The one-command flow still writes the run summary'
    & $runner -OutputDir $flowOutput -Skip $skip
    Assert-Entry ($global:AssessmentEntryTest.Opened.Count -eq 1 -and $global:AssessmentEntryTest.Opened[0] -eq $report) 'Interactive runs open the generated report by default'
    $global:AssessmentEntryTest.BrowserError = $true
    $warnings = @()
    & $runner -OutputDir $flowOutput -Skip $skip -WarningVariable warnings
    Assert-Entry ((Test-Path $report) -and @($warnings | Where-Object { $_ -like '*could not be opened*' }).Count -eq 1) 'Browser failure preserves the report and emits a visible warning'

    Reset-Entry
    & $runner -OutputDir (Join-Path $OutputRoot 'tenant-a') -Skip $skip -NoOpen -WarningAction SilentlyContinue
    Assert-Entry (-not $global:AssessmentEntryTest.Graph -and -not $global:AssessmentEntryTest.Azure) 'The first tenant leaves no active SDK context'
    $global:AssessmentEntryTest.DefaultTenant = $tenantB
    & $runner -OutputDir (Join-Path $OutputRoot 'tenant-b') -Skip $skip -NoOpen -WarningAction SilentlyContinue
    $graphCalls = @($global:AssessmentEntryTest.AuthCalls | Where-Object Kind -eq 'Graph')
    $azureCalls = @($global:AssessmentEntryTest.AuthCalls | Where-Object Kind -eq 'Azure')
    Assert-Entry ($graphCalls.Count -eq 2 -and @($graphCalls | Where-Object TenantId).Count -eq 0) 'Consecutive default runs never inherit a tenant argument'
    Assert-Entry ($azureCalls[0].TenantId -eq $tenantA -and $azureCalls[1].TenantId -eq $tenantB) 'Consecutive runs in one shell can assess two different tenants'
    Assert-Entry ($global:AssessmentEntryTest.Events -contains "GraphLogout:$tenantA" -and $global:AssessmentEntryTest.Events -contains "GraphLogout:$tenantB" -and -not $global:AssessmentEntryTest.Graph -and -not $global:AssessmentEntryTest.Azure) 'Both tenants are signed out after their respective runs'

    Reset-Entry
    Set-EntryGraph -Scope CurrentUser -AuthType AppOnly
    $global:AssessmentEntryTest.Azure = [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $tenantA }; Account = [pscustomobject]@{ Id = 'synthetic-app' } }
    & $runner -OutputDir $flowOutput -Skip $skip
    Assert-Entry ($global:AssessmentEntryTest.AuthCalls.Count -eq 0 -and $global:AssessmentEntryTest.Opened.Count -eq 0) 'The real unattended flow neither signs in interactively nor opens a browser'
    Assert-Entry ($global:AssessmentEntryTest.Graph.AuthType -eq 'AppOnly' -and $global:AssessmentEntryTest.Azure -and $global:AssessmentEntryTest.Events.Count -eq 0) 'App-only contexts are caller-owned and are not signed out'
    Reset-Entry
    Set-EntryGraph -Scope CurrentUser
    $global:AssessmentEntryTest.Azure = [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $tenantA } }
    & $runner -OutputDir $flowOutput -Skip $skip -UseExistingContext -NoOpen
    Assert-Entry ($global:AssessmentEntryTest.Graph -and $global:AssessmentEntryTest.Azure -and $global:AssessmentEntryTest.Events.Count -eq 0) 'Explicit caller-managed delegated contexts remain connected'
    Reset-Entry
    $emptyOutput = Join-Path $OutputRoot 'empty'
    $warnings = @()
    & $runner -OutputDir $emptyOutput -Skip $skip -NoOpen -WarningVariable warnings
    Assert-Entry (@($warnings | Where-Object { $_ -like '*No HTML report was generated*' }).Count -eq 1) 'An empty collection has an explicit no-report warning'
    Assert-Entry (-not (Test-Path (Join-Path $emptyOutput 'report.html'))) 'No success-shaped empty report is produced'
    Reset-Entry
    Set-EntryGraph -Scope CurrentUser
    $global:AssessmentEntryTest.Azure = [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $tenantA } }
    $global:AssessmentEntryTest.GraphError = 'Synthetic canceled entry-point sign-in'
    $canceledOutput = Join-Path $OutputRoot 'canceled'
    Assert-EntryRejected { & $runner -OutputDir $canceledOutput -Skip $skip -NoOpen } '*canceled entry-point sign-in*' 'The real entry point stops on canceled authentication'
    $canceledTranscript = Get-Content -Raw (Join-Path $canceledOutput 'transcript.txt')
    Assert-Entry ($canceledTranscript -like '*Synthetic canceled entry-point sign-in*' -and $canceledTranscript -like '*PowerShell transcript end*') 'Canceled authentication is captured in a closed transcript'
    Assert-Entry (@(Get-ChildItem -LiteralPath $canceledOutput -File | Where-Object Name -ne 'transcript.txt').Count -eq 0) 'Canceled authentication does not produce assessment exports'
    Assert-Entry (-not $global:AssessmentEntryTest.Graph -and -not $global:AssessmentEntryTest.Azure) 'Canceled startup does not retain the previous authenticated context'
    Reset-Entry
    $global:AssessmentEntryTest.AzureCleanupError = $true
    Assert-EntryRejected { & $runner -OutputDir $flowOutput -Skip $skip -NoOpen } '*Azure sign-out failed: Synthetic Azure cleanup failure*' 'Cleanup failures cannot be reported as a successful run'
    Assert-Entry (-not $global:AssessmentEntryTest.Graph) 'A failed Azure cleanup does not prevent Graph sign-out'
    Reset-Entry
    $global:AssessmentEntryTest.AzureError = 'Synthetic Azure sign-in failure'
    $global:AssessmentEntryTest.AzureCleanupError = $true
    $warnings = @()
    $messageReceived = $null
    try {
        & $runner -OutputDir $flowOutput -Skip $skip -NoOpen -WarningVariable warnings
    } catch {
        $messageReceived = $_.Exception.Message
    }
    Assert-Entry ($messageReceived -like '*Synthetic Azure sign-in failure*') 'Cleanup failure does not replace the original authentication failure'
    Assert-Entry (@($warnings | Where-Object { $_ -like '*Authentication cleanup also failed*' }).Count -eq 1) 'A secondary cleanup failure is reported explicitly'
    Reset-Entry

    $fixtureScripts = Join-Path $OutputRoot 'runner-fixture/scripts'
    $null = New-Item -ItemType Directory -Path $fixtureScripts -Force
    foreach ($name in @('run-all.ps1', 'Assessment.Common.psm1', 'Assessment.Controls.psm1', '09-html-report.ps1')) {
        Copy-Item -LiteralPath (Join-Path $scripts $name) -Destination $fixtureScripts -Force
    }
    Copy-Item -LiteralPath (Join-Path $scripts 'report-assets') -Destination $fixtureScripts -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $scripts '../controls') -Destination (Split-Path $fixtureScripts -Parent) -Recurse -Force
    $seed = (Join-Path $flowOutput '01-tenant-context.json').Replace("'", "''")
    @"
[CmdletBinding()]param(`$OutputDir)
Copy-Item -LiteralPath '$seed' -Destination (Join-Path `$OutputDir '01-tenant-context.json')
"@ | Set-Content (Join-Path $fixtureScripts '01-tenant-context.ps1')
    '[CmdletBinding()]param($OutputDir); exit 2' | Set-Content (Join-Path $fixtureScripts '02-inventory.ps1')
    Reset-Entry
    $partialOutput = Join-Path $OutputRoot 'partial'
    $warnings = @()
    & (Join-Path $fixtureScripts 'run-all.ps1') -OutputDir $partialOutput -Skip @('03', '04', '05', '06', '07', '08') -NoOpen -WarningVariable warnings
    $summary = Get-Content -Raw (Join-Path $partialOutput 'run-summary.json') | ConvertFrom-Json
    Assert-Entry ((Test-Path (Join-Path $partialOutput 'report.html')) -and @($warnings | Where-Object { $_ -like '*partial assessment*' }).Count -eq 1) 'A failed collector is explicitly reported while available data renders'
    $failure = @($summary.ScriptResults | Where-Object Number -eq '02')[0]
    Assert-Entry ($failure.Status -eq 'Failed' -and $failure.ExitCode -eq 2) 'Partial collection failure and its exact exit code remain in the persisted summary'
    Assert-Entry (-not $global:AssessmentEntryTest.Graph -and -not $global:AssessmentEntryTest.Azure) 'A partial collector run still signs out both SDKs'
    $partialTranscript = Get-Content -Raw (Join-Path $partialOutput 'transcript.txt')
    Assert-Entry ($partialTranscript -like '*02-inventory*Failed*' -and $partialTranscript -like '*Signing out of assessment sessions*' -and $partialTranscript -like '*PowerShell transcript end*') 'A partial-run transcript includes collection failures, report output and final sign-out'
    '[CmdletBinding()]param($OutputDir); throw "Synthetic null resource failure"' | Set-Content (Join-Path $fixtureScripts '05-permission-surface.ps1')
    Reset-Entry
    & (Join-Path $fixtureScripts 'run-all.ps1') -OutputDir $partialOutput -Skip @('03', '04', '06', '07', '08') -NoOpen -WarningAction SilentlyContinue
    $summary = Get-Content -Raw (Join-Path $partialOutput 'run-summary.json') | ConvertFrom-Json
    $permissionFailure = $summary.ScriptResults | Where-Object Number -eq '05'
    Assert-Entry ($permissionFailure.ErrorMessage -eq 'Synthetic null resource failure' -and $permissionFailure.ErrorLocation -like '*05-permission-surface.ps1*') 'A real collector exception persists its error and script stack in JSON'
    $appendedTranscript = Get-Content -Raw (Join-Path $partialOutput 'transcript.txt')
    Assert-Entry ($appendedTranscript.Length -gt $partialTranscript.Length -and $appendedTranscript -like '*Synthetic null resource failure*') 'Transcript reuse appends and retains real collector exception output'

    $legacyModule = Join-Path $fixtureScripts 'Assessment.Common.psm1'
    @'
function Assert-AssessmentContexts { throw 'Legacy module must be refreshed before authentication.' }
function Stop-AssessmentCollection { }
Export-ModuleMember -Function Assert-AssessmentContexts, Stop-AssessmentCollection
'@ | Set-Content $legacyModule
    Import-Module $legacyModule -Force
    Copy-Item -LiteralPath (Join-Path $scripts 'Assessment.Common.psm1') -Destination $legacyModule -Force
    Reset-Entry
    Set-EntryGraph -Scope CurrentUser
    & (Join-Path $fixtureScripts 'run-all.ps1') -OutputDir (Join-Path $OutputRoot 'legacy-module') -Skip $skip -NoOpen
    Assert-Entry (-not $global:AssessmentEntryTest.Graph -and $global:AssessmentEntryTest.AuthCalls[0].Kind -eq 'Graph') 'An older cached common module is refreshed without requiring a new shell'
    @'
function Connect-AssessmentContexts { throw 'Stale authentication bootstrap must be refreshed.' }
function Stop-AssessmentCollection { }
Export-ModuleMember -Function Connect-AssessmentContexts, Stop-AssessmentCollection
'@ | Set-Content $legacyModule
    Import-Module $legacyModule -Force
    Copy-Item -LiteralPath (Join-Path $scripts 'Assessment.Common.psm1') -Destination $legacyModule -Force
    Reset-Entry
    & (Join-Path $fixtureScripts 'run-all.ps1') -OutputDir (Join-Path $OutputRoot 'stale-bootstrap') -Skip $skip -NoOpen
    Assert-Entry ($global:AssessmentEntryTest.AuthCalls[0].Kind -eq 'Graph') 'Updated authentication code replaces a cached module even when its export names are unchanged'

    Reset-Entry
    $global:AssessmentEntryTest.Choices.Enqueue('invalid')
    $global:AssessmentEntryTest.Choices.Enqueue('')
    $entraOutput = Join-Path $OutputRoot ('entra-' + [guid]::NewGuid().ToString('N'))
    & $runner -OutputDir $entraOutput -Skip $skip -NoOpen -WarningAction SilentlyContinue
    Assert-Entry ($global:AssessmentEntryTest.Prompts.Count -eq 2 -and @($global:AssessmentEntryTest.Prompts | Where-Object AuthCalls -ne 0).Count -eq 0) 'Scope selection precedes authentication and invalid choices are retried'
    Assert-Entry ($global:AssessmentEntryTest.AuthCalls.Count -eq 1 -and $global:AssessmentEntryTest.AzureResets.Count -eq 0) 'The default menu choice runs Entra only without Azure sign-in or cleanup'
    $entraSummary = Get-Content -Raw (Join-Path $entraOutput 'run-summary.json') | ConvertFrom-Json
    Assert-Entry ($entraSummary.AssessmentScope -eq 'Entra' -and $entraSummary.Metrics.UAMICount -eq 'Not collected' -and $entraSummary.Metrics.SentinelDeployed -eq 'Not collected') 'Entra-only summaries label excluded Azure counts and booleans as not collected'
    Assert-Entry (($entraSummary.ScriptResults | Where-Object Number -eq '07').Status -eq 'Not collected') 'Monitoring is excluded explicitly, not reported as an empty successful collection'

    Reset-Entry
    & $runner -AssessmentScope EntraAndAzure -OutputDir $flowOutput -Skip $skip -NoOpen
    Assert-Entry ($global:AssessmentEntryTest.Prompts.Count -eq 0 -and @($global:AssessmentEntryTest.AuthCalls | Where-Object Kind -eq 'Azure').Count -eq 1) 'An explicit assessment scope bypasses the menu for automation'
    Reset-Entry
    Assert-EntryRejected { & $runner -AssessmentScope Entra -SubscriptionIds @('synthetic-subscription') -OutputDir $entraOutput -Skip $skip -NoOpen } '*SubscriptionIds requires*' 'Entra-only mode rejects Azure-specific subscription arguments'
    Assert-EntryRejected { & $runner -AssessmentScope Entra -OutputDir $flowOutput -Skip $skip -NoOpen } '*fresh output folder*' 'Entra-only mode cannot reuse stale Azure collector exports'
    Assert-Entry ($global:AssessmentEntryTest.AuthCalls.Count -eq 0) 'Invalid scope/output combinations fail before signing in'

    foreach ($entry in @(
        @('01-tenant-context', 'AzureSubscriptions'),
        @('02-inventory', 'managedIdentities'),
        @('04-federated-credentials', 'FICsOnUserAssignedMIs'),
        @('05-permission-surface', 'AzureRbac')
    )) {
        $fixtureSeed = (Join-Path $flowOutput "$($entry[0]).json").Replace("'", "''")
        @"
[CmdletBinding()]param(`$OutputDir, [switch]`$EntraOnly)
if (-not `$EntraOnly) { throw 'Mixed collector must receive EntraOnly.' }
`$data = Get-Content -Raw -LiteralPath '$fixtureSeed' | ConvertFrom-Json
`$data | Add-Member -NotePropertyName AzureCollected -NotePropertyValue `$false
`$data.('$($entry[1])') = `$null
`$data | ConvertTo-Json -Depth 50 | Set-Content (Join-Path `$OutputDir '$($entry[0]).json')
"@ | Set-Content (Join-Path $fixtureScripts "$($entry[0]).ps1")
    }
    Reset-Entry
    $scopedFixtureOutput = Join-Path $OutputRoot ('scope-fixture-' + [guid]::NewGuid().ToString('N'))
    & (Join-Path $fixtureScripts 'run-all.ps1') -AssessmentScope Entra -OutputDir $scopedFixtureOutput -Skip @('03', '06', '08') -NoOpen
    $scopedSummary = Get-Content -Raw (Join-Path $scopedFixtureOutput 'run-summary.json') | ConvertFrom-Json
    Assert-Entry (@($scopedSummary.ScriptResults | Where-Object Status -eq 'OK').Count -eq 4) 'The real orchestrator passes EntraOnly to every mixed collector'
    Assert-Entry ((Test-Path (Join-Path $scopedFixtureOutput 'report.html')) -and $global:AssessmentEntryTest.AuthCalls.Count -eq 1 -and $global:AssessmentEntryTest.AzureResets.Count -eq 0) 'Entra-only orchestration produces a real offline report without any Azure authentication'
    $scopeTranscript = Get-Content -Raw (Join-Path $entraOutput 'transcript.txt')
    Assert-Entry ($scopeTranscript -like '*1. Entra only*' -and $scopeTranscript -like '*Signing in to Microsoft Graph*' -and $scopeTranscript -like '*PowerShell transcript end*') 'Transcript capture starts before the scope menu and includes authentication'
    Write-Host "PASS: $checks entry-point checks. Authentication and browser opening were mocked; report generation was real." -ForegroundColor Green
} finally {
    Stop-AssessmentCollection
    Remove-Module Assessment.Common
    Remove-Module Microsoft.Graph.Authentication -ErrorAction SilentlyContinue
    $env:PSModulePath = $savedModulePath
    $env:ASSESSMENT_SUBSCRIPTION_IDS = $savedSubscriptionScope
    foreach ($name in @('Get-MgContext', 'Get-AzContext', 'Read-Host', 'Connect-MgGraph', 'Disconnect-MgGraph', 'Connect-AzAccount', 'Clear-AzContext', 'Disable-AzContextAutosave', 'Invoke-Item', 'Invoke-MgGraphRequest')) {
        Remove-Item -LiteralPath "Function:global:$name"
    }
    Remove-Variable -Name AssessmentEntryTest -Scope Global
}
