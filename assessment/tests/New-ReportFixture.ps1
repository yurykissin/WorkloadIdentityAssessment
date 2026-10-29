function New-ReportFixture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Destination,
        [ValidateRange(0, 10000)][int]$IdentityCount = 3,
        [switch]$HostileText
    )
    $null = New-Item -ItemType Directory -Path $Destination -Force
    $apps = @()
    $sps = @()
    for ($i = 1; $i -le $IdentityCount; $i++) {
        $name = 'Synthetic workload {0:d4}' -f $i
        if ($HostileText -and $i -eq 1) { $name = '</script><script>window.reportInjection=true</script><img src=x onerror=alert(1)> __STYLES__ __DATA_JSON__' }
        $appId = '00000000-0000-0000-0001-{0:d12}' -f $i
        $apps += [ordered]@{
            AppObjectId = ('00000000-0000-0000-0002-{0:d12}' -f $i)
            AppId = $appId; DisplayName = $name; SignInAudience = 'single-tenant'
            OwnerCount = $(if ($i -eq 1) { 0 } else { 2 })
            Tags = 'env=test'; ActivePasswordCredentialCount = 1; FederatedCredentialCount = 1
        }
        $sps += [ordered]@{
            SpObjectId = ('00000000-0000-0000-0003-{0:d12}' -f $i)
            AppId = $appId; DisplayName = $name; ServicePrincipalType = 'Application'
            IsExternalApp = $false; AppOwnerOrganizationId = '00000000-0000-0000-0000-000000000001'
            OwnerCount = $(if ($i -eq 1) { 0 } else { 2 })
            LastSignIn = '2026-01-01T10:00:00Z'; AppRoleAssignmentCount = 1; AccountEnabled = $true
        }
    }
    $mi = @(if ($IdentityCount) { [ordered]@{
        IdentityType = 'UserAssigned'; PrincipalId = '00000000-0000-0000-0004-000000000001'
        ClientId = '00000000-0000-0000-0005-000000000001'; Name = 'synthetic-build-identity'
        ResourceId = '/subscriptions/00000000-0000-0000-0006-000000000001/resourceGroups/rg-synthetic/providers/Microsoft.ManagedIdentity/userAssignedIdentities/build'
        SubscriptionId = '00000000-0000-0000-0006-000000000001'; ResourceGroup = 'rg-synthetic'; Location = 'northeurope'
    } })
    $credentials = @(if ($IdentityCount) { [ordered]@{
        AppObjectId = $apps[0].AppObjectId; AppId = $apps[0].AppId; AppDisplayName = $apps[0].DisplayName
        CredentialType = 'password'; CredentialDisplayName = 'Synthetic expired credential'
        StartDateTime = '2023-01-01T00:00:00Z'; EndDateTime = '2025-01-01T00:00:00Z'
        LifetimeDays = 731; DaysUntilExpiry = -365; Expired = $true
    } })
    $fics = @(if ($IdentityCount) { [ordered]@{
        Target = 'appRegistration'; TargetId = $apps[0].AppObjectId; TargetAppId = $apps[0].AppId
        TargetName = $apps[0].DisplayName; FicName = 'Synthetic GitHub federation'
        IssuerCategory = 'github'; SubjectClassification = 'NARROW'
        Subject = 'repo:example/synthetic:ref:refs/heads/main'; Audiences = @('api://AzureADTokenExchange')
    } })
    $permissions = @(if ($IdentityCount) { [ordered]@{
        SpObjectId = $sps[0].SpObjectId; SpDisplayName = $sps[0].DisplayName
        PermissionValue = 'Application.ReadWrite.All'; PermissionDisplayName = 'Read and write all applications'
        ResourceDisplayName = 'Microsoft Graph'; ResourceAppId = '00000003-0000-0000-c000-000000000000'; Tier = 'PRIVILEGED'
    } })
    $rbac = @(if ($IdentityCount) { [ordered]@{
        PrincipalId = $mi[0].PrincipalId; PrincipalDisplayName = $mi[0].Name
        RoleName = 'Reader'; Scope = $mi[0].ResourceId; ScopeLevel = 'resource'
    } })
    $datasets = [ordered]@{
        '01-tenant-context' = [ordered]@{
            TenantInfo = @{ TenantId = '00000000-0000-0000-0000-000000000001'; DisplayName = 'Synthetic demonstration'; PrimaryDomain = 'example.invalid' }
            CapabilityFlags = @{
                WORKLOAD_IDENTITIES_PREMIUM = @{ Available = $true; ProvidedBySkus = @(); Description = 'Synthetic capability' }
                AAD_GOVERNANCE = @{ Available = $true; ProvidedBySkus = @(); Description = 'Synthetic capability' }
            }
            AuthorizationPolicy = @{ AllowedToCreateApps = $true; AllowedToCreateTenants = $false; AllowedToCreateSecurityGroups = $false }
            AdminConsentPolicy = @{ IsEnabled = $false }
            RoleMemberCounts = @{ GlobalAdministrator = @{ MemberCount = 2 }; ApplicationAdministrator = @{ MemberCount = 1 }; CloudApplicationAdministrator = @{ MemberCount = 1 } }
            AzureSubscriptions = @(@{ Id = '00000000-0000-0000-0006-000000000001' })
        }
        '02-inventory' = @{ TenantId = '00000000-0000-0000-0000-000000000001'; appRegistrations = @($apps); servicePrincipals = @($sps); managedIdentities = @($mi) }
        '03-credential-hygiene' = @{
            Credentials = @($credentials)
            Aggregations = @{
                TotalActivePasswordCredentials = $IdentityCount; TotalActiveKeyCredentials = $IdentityCount
                ExpiredCredentialsStillAttached = $credentials.Count; ActiveSecretsOver24Months = $credentials.Count
                ActiveSecretsOver12Months = $credentials.Count; CertificateToPasswordRatioPct = 50
                MedianSecretLifetimeDays = 90; MaxSecretLifetimeDays = 731
            }
        }
        '04-federated-credentials' = @{
            FederatedCredentials = @($fics); TotalFICs = $fics.Count; FICsOnAppRegs = $fics.Count; FICsOnUserAssignedMIs = 0
            ByIssuerCategory = @(@{ Category = 'github'; Count = $fics.Count })
            BySubjectClass = @(@{ Classification = 'NARROW'; Count = $fics.Count })
        }
        '05-permission-surface' = @{ GraphPermissions = @($permissions); AzureRbac = @($rbac) }
        '06-stale-and-orphaned' = @{
            ServicePrincipals = @($sps); SignInDataAvailable = $true
            Aggregations = @{
                TotalFirstPartySPs = $IdentityCount; Stale365Days = $credentials.Count; Stale90Days = $credentials.Count
                NeverSignedIn = 0; NoOwner = $credentials.Count; OrphanedOwner = 0
                AppRegMissingTags = $credentials.Count
            }
        }
        '07-monitoring-coverage' = @{
            keyVaults = @(); logAnalyticsWorkspaces = @()
            diagnosticSettings = @(@{ Name = 'synthetic-signins'; Workspace = 'synthetic-logs' }, @{ Name = 'synthetic-audit'; Workspace = 'synthetic-logs' })
        }
        '08-ca-for-workload-identities' = @{
            WorkloadIdentitiesPremiumLicensed = $true; TotalCAPolicies = 1; WITargetedPolicies = 1
            EnabledWIPolicies = 1; ReportOnlyWIPolicies = 0; TotalFirstPartySPs = $IdentityCount
            SPsCoveredByCAPolicy = 2; SPCoveragePct = 67
            Policies = @(@{ Id = '00000000-0000-0000-0007-000000000001'; DisplayName = 'Synthetic workload policy'; State = 'enabled' })
            SPCoverage = @()
        }
    }
    foreach ($entry in $datasets.GetEnumerator()) {
        $entry.Value['CollectedAt'] = '2026-01-01T12:00:00Z'
        $entry.Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $Destination ($entry.Key + '.json')) -Encoding utf8
    }
}
