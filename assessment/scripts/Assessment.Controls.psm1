Set-StrictMode -Version 1.0
$script:WorkloadCatalog = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../controls/catalog.json') -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop

function Get-ControlProperty($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    return $Object.PSObject.Properties[$Name].Value
}

function Set-WorkloadSecretLifetime {
    param([object[]]$Rows, $CollectedAt, [int]$ThresholdDays = 365)
    $asOf = [datetimeoffset]::MinValue
    $culture = [cultureinfo]::InvariantCulture
    $styles = [System.Globalization.DateTimeStyles]::None
    # JSON dates may be DateTime values; round-trip formatting avoids culture-dependent string casts.
    $hasSnapshotTime = [datetimeoffset]::TryParse(('{0:o}' -f $CollectedAt), $culture, $styles, [ref]$asOf) -and $asOf.Year -gt 1900
    foreach ($row in $Rows) {
        $start = [datetimeoffset]::MinValue
        $end = [datetimeoffset]::MinValue
        $hasStart = [datetimeoffset]::TryParse(('{0:o}' -f $row.StartDateTime), $culture, $styles, [ref]$start) -and $start.Year -gt 1900
        $hasEnd = [datetimeoffset]::TryParse(('{0:o}' -f $row.EndDateTime), $culture, $styles, [ref]$end) -and $end.Year -gt 1900
        $days = if ($hasStart -and $hasEnd -and $end -gt $start) { ($end - $start).TotalDays } else { $null }
        $expired = if ($hasEnd -and $hasSnapshotTime) { $end -le $asOf } elseif ($hasEnd -and $row.Expired -is [bool]) { $row.Expired } else { $null }
        $status = if ($row.CredentialType -ne 'password') { 'Not applicable (not a client secret)' }
            elseif (-not $hasEnd) { 'Unknown expiry - missing or invalid end date' }
            elseif ($hasStart -and $end -le $start) { 'Unknown lifetime - invalid date range' }
            elseif ($expired -eq $true) { 'Expired' }
            elseif ($null -eq $days -or $null -eq $expired) { 'Unknown lifetime - incomplete dates or snapshot time' }
            elseif ($days -gt $ThresholdDays) { "Long-lived secret (> $ThresholdDays days)" }
            else { "Within $ThresholdDays-day review threshold (not a safety assurance)" }
        $row | Add-Member -NotePropertyMembers @{
            SecretLifetimeDays = $days
            SecretLifetimeStatus = $status
            SecretLifetimeReviewRequired = $status -like 'Unknown*' -or $status -like 'Long-lived*'
        } -Force
    }
}

function Get-WorkloadRedirectReviews {
    param($Inventory, $TenantInfo)
    $domains = @($TenantInfo.VerifiedDomains | Where-Object { $_ -is [string] -and $_ })
    foreach ($app in $Inventory.appRegistrations) {
        $uris = $app.RedirectUris
        $known = $null -ne $uris
        if ($known) { $values = @($uris) } else { $values = @($null) }
        foreach ($value in $values) {
            $uri = $null
            $valid = $null -ne $value -and [uri]::TryCreate([string]$value, [UriKind]::Absolute, [ref]$uri)
            $network = $valid -and $uri.Scheme -in @('http','https') -and -not $uri.IsLoopback
            $hostName = if ($network) { $uri.IdnHost.TrimEnd('.').ToLowerInvariant() } else { $null }
            $match = @($domains | Where-Object {
                $hostName -and ($hostName -eq $_.TrimEnd('.').ToLowerInvariant() -or $hostName.EndsWith('.' + $_.TrimEnd('.').ToLowerInvariant()))
            } | Select-Object -First 1)
            $applicable = if (-not $known -or -not $valid) { $null } else { $network }
            $status = if (-not $known) { 'Not assessed - redirect URI inventory not collected' }
                elseif (-not $valid) { 'Review - invalid redirect URI' }
                elseif ($uri.IsLoopback) { 'Not applicable - loopback URI; native-client behavior needs separate validation' }
                elseif (-not $network) { 'Not applicable - non-HTTP URI; native-app binding needs separate validation' }
                else { 'Ownership unverified - current domain and endpoint control require confirmation' }
            [pscustomobject]@{
                AppObjectId = $app.AppObjectId; AppId = $app.AppId; DisplayName = $app.DisplayName
                RedirectUri = $value; RedirectHost = $hostName
                TenantDomainMatch = if ($match.Count) { $match[0] } else { $null }
                OwnershipStatus = $status
                OwnershipReviewApplicable = $applicable
                OwnershipReviewRequired = $known -and ($network -or -not $valid)
                ReviewReason = if ($network) {
                    "Confirm current registration, DNS/hosting control and business need with the owner. A tenant verified-domain match is historical context, not proof of current ownership. No DNS, HTTP or registration lookup was performed.$(if ($uri.Scheme -eq 'http') { ' Non-loopback HTTP also requires transport-security review.' })"
                } elseif (-not $valid) { 'Missing or malformed evidence cannot establish an owned redirect endpoint.' }
                else { 'Excluded from domain-ownership assessment only; not a security approval of the redirect configuration.' }
            }
        }
    }
}

function Set-WorkloadPermissionRisk {
    param([object[]]$Rows, $Catalog = $script:WorkloadCatalog)
    $lowerRules = @($catalog.PermissionRisk.Rules | Where-Object { $_.Tier -eq 'LOWER_IMPACT' -and -not $_.RequiresLowerImpactCompanions })
    $aztier = Get-ControlProperty $Catalog.PermissionRisk 'AZTier'
    $tiered = @{}; $untiered = @{}
    foreach ($permission in $aztier.TieredPermissions) { $tiered[$permission.PermissionValue] = $permission }
    foreach ($permission in $aztier.UntieredPermissions) { $untiered[$permission.PermissionValue] = $permission }
    foreach ($row in $Rows) {
        $tier = 'UNCLASSIFIED'
        $reason = 'Unclassified: no matching sourced rule. Review the API capability; unlisted does not mean safe.'
        $matched = $null
        $context = if ($row.PermissionType -eq 'Application') {
            'Application-only access has no signed-in-user boundary; validate effective resource restrictions.'
        } elseif ($row.PermissionType -eq 'Delegated') {
            'Delegated access is bounded by the signed-in user and granted scopes, but can still expose or modify sensitive data.'
        } else { 'Permission type unavailable; access context cannot be established.' }
        if (-not $row.PermissionValue -or $row.ResolutionStatus -eq 'Unresolved') {
            $tier = 'UNKNOWN'
            $reason = 'Unresolved permission: capability cannot be assessed from the available evidence.'
        } else {
            foreach ($rule in $catalog.PermissionRisk.Rules) {
                $resources = Get-ControlProperty $catalog.PermissionRisk.Resources $rule.Resource
                if ($row.PermissionType -notin $rule.Types -or
                    ($rule.Resource -ne 'Any' -and $row.ResourceAppId -notin $resources) -or
                    $row.PermissionValue -notmatch $rule.Pattern) { continue }
                if ($rule.RequiresLowerImpactCompanions) {
                    $companions = @($Rows | Where-Object {
                        $_.GrantState -eq 'Granted' -and $_.PermissionType -eq 'Delegated' -and
                        $_.SpObjectId -eq $row.SpObjectId -and $_.ResourceAppId -eq $row.ResourceAppId -and
                        $_.ConsentScope -eq $row.ConsentScope -and $_.ConsentPrincipalId -eq $row.ConsentPrincipalId -and
                        $_.PermissionValue -ne 'offline_access'
                    })
                    if (-not $row.SpObjectId -or $row.ConsentScope -notin @('AllPrincipals','Principal') -or
                        ($row.ConsentScope -eq 'Principal' -and -not $row.ConsentPrincipalId) -or -not $companions.Count -or
                        @($companions | Where-Object {
                            $companion = $_
                            $companion.ResolutionStatus -eq 'Unresolved' -or -not @($lowerRules | Where-Object {
                                $companion.PermissionType -in $_.Types -and $companion.PermissionValue -match $_.Pattern -and
                                ($_.Resource -eq 'Any' -or $companion.ResourceAppId -in (Get-ControlProperty $catalog.PermissionRisk.Resources $_.Resource))
                            }).Count
                        }).Count) { continue }
                }
                $matched = $rule
                $tier = $rule.Tier
                $reason = $rule.Reason
                break
            }
        }
        $severity = switch ($tier) {
            { $_ -in @('PRIVILEGED','PRIVILEGED_READ') } { 'High' }
            'RESTRICTED' { 'Med' }
            { $_ -in @('LOWER_IMPACT','INFORMATIONAL') } { 'Info' }
            default { 'Low' }
        }
        $label = switch ($tier) {
            'PRIVILEGED' { 'Dangerous capability - review' }
            'PRIVILEGED_READ' { 'High-impact read - review' }
            'LOWER_IMPACT' { 'Lower impact - not a safety assurance' }
            'INFORMATIONAL' { 'Info - inventory read' }
            'RESTRICTED' { 'Medium - restricted capability' }
            'UNKNOWN' { 'Low / Unrated - unresolved, not proven low risk' }
            default { 'Low / Unrated - unclassified, not proven low risk' }
        }
        if ($matched.Label) { $label = $matched.Label }
        $capabilitySeverity = $severity
        $ruleId = $matched.Id
        $origin = if ($matched) { $matched.Origin } else { 'Toolkit coverage-gap priority; no researched severity' }
        $sourceUrl = if ($matched) { Get-ControlProperty $catalog.Sources $matched.Source } else { $catalog.Sources.RiskyPermissions }
        $mappingState = if ($matched) { 'Capability rule' } elseif ($tier -eq 'UNKNOWN') { 'Unresolved' } else { 'Unclassified' }
        $aztierStatus = 'Not applicable (application-only Graph catalog)'
        $aztierTier = $null; $detectedOn = $null
        if ($aztier -and $row.PermissionType -eq 'Application' -and $row.ResourceAppId -in $catalog.PermissionRisk.Resources.Graph) {
            $aztierStatus = if ($tier -eq 'UNKNOWN') { 'Not assessed (unresolved definition)' } else { 'Not listed in pinned AZTier snapshot' }
            if ($tier -ne 'UNKNOWN') {
                $entry = $tiered[[string]$row.PermissionValue]
                $isReviewed = $null -ne $entry
                if (-not $entry) { $entry = $untiered[[string]$row.PermissionValue] }
                if ($entry) {
                    $permissionId = [guid]::Empty
                    $hasId = [guid]::TryParse([string]$row.AppRoleId, [ref]$permissionId)
                    if ($hasId -and $permissionId -ne [guid]$entry.PermissionId) {
                        $tier = 'UNKNOWN'; $severity = 'Low'; $mappingState = 'Unresolved'
                        $label = 'Low / Unrated - permission ID mismatch'
                        $reason = 'The exported permission ID conflicts with the AZTier entry for this resolved name. Verify the definition; no researched tier is assigned.'
                        $aztierStatus = 'Permission ID/name mismatch'
                        $ruleId = $null; $origin = 'Toolkit evidence-conflict review'; $sourceUrl = $aztier.TieredSourceUrl
                    } elseif ($isReviewed) {
                        $aztierTier = $entry.Tier
                        $translation = Get-ControlProperty $aztier.SeverityMapping $entry.Tier
                        $tier = $translation.Tier; $severity = $translation.Severity; $label = $translation.Label
                        $reason = $translation.Reason
                        $ruleId = "AZTIER.$($entry.Tier)"; $mappingState = 'Reviewed'
                        $origin = $aztier.Origin; $sourceUrl = $aztier.TieredSourceUrl
                        $aztierStatus = "Reviewed Tier $($entry.Tier) (source last changed $($aztier.TieredLastChanged))"
                    } else {
                        $tier = 'UNCLASSIFIED'; $severity = $aztier.UntieredSeverity
                        $label = 'Low / Unrated - AZTier manual review pending'
                        $reason = 'AZTier detected this application permission but has not assigned a reviewed tier. Low is the selected review priority, not a researched low-risk conclusion. Any separate capability warning remains relevant.'
                        $ruleId = 'AZTIER.UNTIERED'; $mappingState = 'Untiered'; $detectedOn = $entry.DetectedOn
                        $origin = 'AZTier discovery only; Low priority is toolkit policy'
                        $sourceUrl = $aztier.UntieredSourceUrl
                        $aztierStatus = "Untiered (detected $detectedOn; manual research pending)"
                    }
                }
            }
        }
        $row | Add-Member -NotePropertyMembers @{
            Tier = $tier; RiskSeverity = $severity; RiskLabel = $label; RiskMappingState = $mappingState
            ReviewRequired = $row.GrantState -eq 'Granted' -and $tier -ne 'LOWER_IMPACT'
            ReviewReason = $reason
            AccessContext = $context
            RiskRuleId = $ruleId; RiskOrigin = $origin; RiskSourceUrl = $sourceUrl
            CapabilityRuleId = $matched.Id
            CapabilityReason = $matched.Reason
            CapabilitySeverity = if ($matched) { $capabilitySeverity } else { $null }
            CapabilitySourceUrl = if ($matched) { Get-ControlProperty $catalog.Sources $matched.Source } else { $null }
            RiskReferences = @(foreach ($reference in $catalog.PermissionRisk.CorroboratingReferences) {
                if ($row.PermissionType -in $reference.Types -and $row.PermissionValue -in $reference.Permissions -and
                    $row.ResourceAppId -in (Get-ControlProperty $catalog.PermissionRisk.Resources $reference.Resource)) {
                    foreach ($referenceSource in $reference.Sources) {
                        [pscustomobject]@{ Source = $referenceSource; Url = Get-ControlProperty $catalog.Sources $referenceSource; Reason = $reference.Reason }
                    }
                }
            })
            AZTierStatus = $aztierStatus; AZTier = $aztierTier; AZTierDetectedOn = $detectedOn
            AZTierRevision = if ($aztier -and $row.PermissionType -eq 'Application' -and $row.ResourceAppId -in $catalog.PermissionRisk.Resources.Graph) { $aztier.Revision } else { $null }
            RiskCatalogVersion = $catalog.PermissionRisk.Version
            OrganizationWideConsent = if ($row.PermissionType -eq 'Delegated' -and $row.GrantState -eq 'Granted' -and $row.ConsentScope -in @('AllPrincipals','Principal')) { $row.ConsentScope -eq 'AllPrincipals' } else { $null }
            ConsentAudience = if ($row.PermissionType -ne 'Delegated') { 'Not applicable (application permission)' }
                elseif ($row.GrantState -eq 'Not granted') { 'Not granted' }
                elseif ($row.GrantState -ne 'Granted') { 'Unknown / not collected' }
                elseif ($row.ConsentScope -eq 'AllPrincipals') { 'Organization-wide (all users)' }
                elseif ($row.ConsentScope -eq 'Principal' -and $row.ConsentPrincipalId) { 'Specific user' }
                else { 'Unknown / not collected' }
        } -Force
    }
}

function Get-WorkloadCategory($Row, [string]$TenantId) {
    if ($Row.ServicePrincipalType -eq 'ManagedIdentity') { return 'Managed identity' }
    if ($Row.ServicePrincipalType -ne 'Application') { return 'Other / unknown' }
    if ($Row.AppOwnerOrganizationId -in @('f8cdef31-a31e-4b4a-93e4-5f571e91255a', '72f988bf-86f1-41af-91ab-2d7cd011db47')) { return 'Microsoft-owned' }
    if ($TenantId -and $Row.AppOwnerOrganizationId -eq $TenantId) { return 'Tenant-managed' }
    if ($Row.AppOwnerOrganizationId) { return 'External / third-party' }
    return 'Other / unknown'
}

function ConvertTo-WorkloadSnapshot {
    param([hashtable]$Data)
    $permissions = $Data['05']
    if ($permissions -and -not $permissions.PSObject.Properties['NormalizedPermissions']) {
        $normalized = @(
            foreach ($grant in $permissions.GraphPermissions) {
                $row = $grant.PSObject.Copy()
                $row | Add-Member -NotePropertyMembers @{
                    PermissionType = 'Application'; GrantState = 'Granted'; AdminConsentRequired = $true
                    ConsentStatus = 'Granted application access'; ConfiguredState = 'Configuration not collected'
                } -Force
                $row
            }
        )
        $permissions | Add-Member -NotePropertyName NormalizedPermissions -NotePropertyValue $normalized -Force
        $permissions | Add-Member -NotePropertyName PermissionModel -NotePropertyValue 'Legacy: actual application grants only; delegated/configured evidence was not collected.' -Force
    }
    if ($permissions) { Set-WorkloadPermissionRisk -Rows @($permissions.NormalizedPermissions | Where-Object { $null -ne $_ }) }
    if ($Data['03']) { Set-WorkloadSecretLifetime -Rows @($Data['03'].Credentials | Where-Object { $null -ne $_ }) -CollectedAt $Data['03'].CollectedAt }
    $inventory = $Data['02']
    if (-not $inventory) { return }
    $redirects = $null
    if ($null -ne $inventory.appRegistrations) { $redirects = @(Get-WorkloadRedirectReviews $inventory $Data['01'].TenantInfo) }
    $inventory | Add-Member -NotePropertyName RedirectUriReviews -NotePropertyValue $redirects -Force
    $tenantId = $inventory.TenantId
    $apps = @{}
    foreach ($app in $inventory.appRegistrations) {
        if ($app.AppId) { $apps[$app.AppId] = $app }
        $category = if ($app.AppObjectId -in @($inventory.WorkloadEvidence.AgentBlueprints.Records.id)) { 'Agent ID' } else { 'Tenant-managed' }
        $app | Add-Member -NotePropertyName Category -NotePropertyValue $category -Force
    }
    foreach ($sp in $inventory.servicePrincipals) {
        $category = Get-WorkloadCategory $sp $tenantId
        if ($sp.SpObjectId -in @($inventory.WorkloadEvidence.AgentIdentities.Records.id)) { $category = 'Agent ID' }
        $sp | Add-Member -NotePropertyName Category -NotePropertyValue $category -Force
        if (-not $sp.SignInAudience) {
            $audience = if ($sp.AppId -and $apps.ContainsKey($sp.AppId)) { $apps[$sp.AppId].SignInAudience } else { 'Unknown' }
            $sp | Add-Member -NotePropertyName SignInAudience -NotePropertyValue $audience -Force
        }
        if ($category -notin @('Tenant-managed','Agent ID')) { $sp | Add-Member -NotePropertyName OwnerCount -NotePropertyValue $null -Force }
        $asOf = [datetimeoffset]::MinValue
        $observed = [datetimeoffset]::MinValue
        $valid = [datetimeoffset]::TryParse([string]$inventory.CollectedAt, [ref]$asOf) -and
            [datetimeoffset]::TryParse([string]$sp.LastSignIn, [ref]$observed) -and $observed.Year -gt 1900 -and $observed -le $asOf
        $sp | Add-Member -NotePropertyMembers @{
            LastSignIn = if ($valid) { $observed.ToUniversalTime().ToString('o') } else { $null }
            DaysSinceLastSignIn = if ($valid) { [math]::Floor(($asOf - $observed).TotalDays) } else { $null }
        } -Force
        $activity = if ($valid) { 'Observed activity (not necessarily successful)' } elseif ($inventory.SignInActivity.State -eq 'Available') { 'No reliable observed date' } else { 'Unknown / unavailable' }
        $sp | Add-Member -NotePropertyName ActivityStatus -NotePropertyValue $activity -Force
        $sp | Add-Member -NotePropertyName NeverSignedIn -NotePropertyValue $null -Force
    }
    foreach ($row in @($inventory.appRegistrations) + @($inventory.servicePrincipals)) {
        if ($null -eq $row) { continue }
        $audience = switch ($row.SignInAudience) {
            'AzureADMyOrg' { 'single-tenant' }
            'AzureADMultipleOrgs' { 'multi-tenant' }
            'AzureADandPersonalMicrosoftAccount' { 'multi-tenant+MSA' }
            'PersonalMicrosoftAccount' { 'personal-MSA' }
            default { if ($row.SignInAudience) { $row.SignInAudience } else { 'Unknown' } }
        }
        $row | Add-Member -NotePropertyName SignInAudience -NotePropertyValue $audience -Force
    }
    $spCredentials = @(
        foreach ($sp in $inventory.servicePrincipals) {
            foreach ($kind in @('PasswordCredentials','KeyCredentials')) {
                foreach ($credential in (Get-ControlProperty $sp $kind)) {
                    if ($null -eq $credential) { continue }
                    $end = [datetimeoffset]::MinValue
                    $asOf = [datetimeoffset]::MinValue
                    $valid = [datetimeoffset]::TryParse([string]$credential.endDateTime, [ref]$end) -and
                        [datetimeoffset]::TryParse([string]$inventory.CollectedAt, [ref]$asOf)
                    [pscustomobject]@{
                        SpObjectId = $sp.SpObjectId; AppId = $sp.AppId; AppDisplayName = $sp.DisplayName
                        CredentialOrigin = 'servicePrincipal'; KeyId = $credential.keyId
                        CredentialType = if ($kind -eq 'PasswordCredentials') { 'password' } else { 'key' }
                        CredentialDisplayName = $credential.displayName; StartDateTime = $credential.startDateTime; EndDateTime = $credential.endDateTime
                        Expired = if ($valid) { $end -lt $asOf } else { $null }
                        DaysUntilExpiry = if ($valid) { [math]::Floor(($end - $asOf).TotalDays) } else { $null }
                        UsageAssessment = 'SP-origin credential activity not assessed; expiry is independent of usage.'
                    }
                }
            }
        }
    )
    if ($inventory.SchemaVersion -ge 2) { $inventory | Add-Member -NotePropertyName SpCredentials -NotePropertyValue $spCredentials -Force }
    Set-WorkloadSecretLifetime -Rows $spCredentials -CollectedAt $inventory.CollectedAt
    foreach ($row in $Data['06'].ServicePrincipals) {
        $asOf = [datetimeoffset]::MinValue
        $observed = [datetimeoffset]::MinValue
        $valid = [datetimeoffset]::TryParse([string]$Data['06'].CollectedAt, [ref]$asOf) -and
            [datetimeoffset]::TryParse([string]$row.LastSignIn, [ref]$observed) -and $observed.Year -gt 1900 -and $observed -le $asOf
        $row | Add-Member -NotePropertyMembers @{
            LastSignIn = if ($valid) { $observed.ToUniversalTime().ToString('o') } else { $null }
            DaysSinceLastSignIn = if ($valid) { [math]::Floor(($asOf - $observed).TotalDays) } else { $null }
        } -Force
        if (-not $row.LastSignIn) {
            $row | Add-Member -NotePropertyMembers @{ Stale90Days = $null; Stale365Days = $null } -Force
        }
        $row | Add-Member -NotePropertyName NeverSignedIn -NotePropertyValue $null -Force
    }
    if ($Data['06']) {
        foreach ($threshold in @(90,365)) {
            $count = if ($Data['06'].SignInDataAvailable -eq $true) { @($Data['06'].ServicePrincipals | Where-Object {
                $_.LastSignIn -and $_.DaysSinceLastSignIn -ge $threshold
            }).Count } else { $null }
            $Data['06'].Aggregations | Add-Member -NotePropertyName "Stale${threshold}Days" -NotePropertyValue $count -Force
        }
        $Data['06'].Aggregations | Add-Member -NotePropertyName NeverSignedIn -NotePropertyValue $null -Force
    }
}

function Test-WorkloadPolicy {
    param($Evidence, [string]$Kind)
    if ($Evidence.DefaultAppManagementPolicy.State -ne 'Available' -or $Evidence.AppManagementPolicies.State -ne 'Available') { return 'Not assessed' }
    $policy = @($Evidence.DefaultAppManagementPolicy.Records)[0]
    if ($policy.isEnabled -isnot [bool]) { return 'Not assessed' }
    if ($policy.isEnabled -ne $true) { return 'Fail' }
    if (@($Evidence.AppManagementPolicies.Records | Where-Object { $_.isEnabled -eq $true }).Count) { return 'Not assessed' }
    foreach ($target in @('applicationRestrictions','servicePrincipalRestrictions')) {
        $restrictions = Get-ControlProperty $policy $target
        if ($null -eq $restrictions) { return 'Not assessed' }
        $required = switch ($Kind) {
            'PasswordPolicy' { @('passwordAddition','symmetricKeyAddition') }
            'PasswordLifetime' { @('passwordLifetime','symmetricKeyLifetime') }
            'CertificateLifetime' { @('asymmetricKeyLifetime') }
        }
        $values = if ($Kind -eq 'CertificateLifetime') { @($restrictions.keyCredentials) } else { @($restrictions.passwordCredentials) }
        foreach ($type in $required) {
            $entry = $values | Where-Object restrictionType -eq $type | Select-Object -First 1
            if (-not $entry) { return 'Fail' }
            if ($entry.restrictForAppsCreatedAfterDateTime -or $entry.excludeActors) { return 'Not assessed' }
            if (-not $entry.state) { return 'Not assessed' }
            if ($entry.state -ne 'enabled') { return 'Fail' }
            if ($Kind -ne 'PasswordPolicy') {
                try { $days = [System.Xml.XmlConvert]::ToTimeSpan([string]$entry.maxLifetime).TotalDays } catch { return 'Not assessed' }
                $limit = if ($Kind -eq 'PasswordLifetime') { 181 } else { 366 }
                if ($days -gt $limit -or $days -le 0) { return 'Fail' }
            }
        }
    }
    return 'Pass'
}

function Invoke-WorkloadControls {
    param([hashtable]$Data, [string]$CatalogPath = (Join-Path $PSScriptRoot '../controls/catalog.json'))
    $catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json -Depth 50
    $catalog.PermissionRisk | Add-Member -NotePropertyName Sources -NotePropertyValue $catalog.Sources -Force
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($control in $catalog.Controls) {
        $dataset = $Data[$control.Dataset]
        $rows = @(Get-ControlProperty $dataset $control.Field | Where-Object { $null -ne $_ })
        $affected = @()
        $outcome = 'Not assessed'
        $reason = 'Review the affected evidence against the linked source. This is a scoped observation, not proof of overall compliance.'
        $eligible = $rows
        $unknown = 0
        $failure = 'Review'
        switch ($control.Kind) {
            'Registration' {
                $value = Get-ControlProperty $dataset.AuthorizationPolicy 'AllowedToCreateApps'
                if ($value -is [bool]) {
                    if ($value) { $affected = @([pscustomobject]@{ DisplayName = 'Tenant application registration setting'; AllowedToCreateApps = $value; Policy = $dataset.AuthorizationPolicy }) }
                    $outcome = 'Pass'; $failure = 'Fail'
                }
            }
            'Workflow' {
                $value = Get-ControlProperty $dataset.AdminConsentPolicy 'IsEnabled'
                if ($value -is [bool]) {
                    if (-not $value) {
                        $affected = @([pscustomobject]@{ DisplayName = 'Tenant admin consent workflow'; IsEnabled = $value; Policy = $dataset.AdminConsentPolicy })
                        $failure = 'Fail'; $outcome = 'Pass'
                    }
                    elseif ($dataset.AdminConsentPolicy.Reviewers.Count -gt 0) { $outcome = 'Pass' }
                    else { $reason = 'Workflow enabled; configured reviewer evidence is unavailable. Verify actual reviewers.' }
                }
            }
            'Owners' {
                $eligible = @($rows | Where-Object { $_.Category -eq 'Tenant-managed' -and $_.ServicePrincipalType -eq 'Application' })
                $unknown = @($eligible | Where-Object { $null -eq $_.OwnerCount }).Count
                $affected = @($eligible | Where-Object { $null -ne $_.OwnerCount -and $_.OwnerCount -eq 0 })
                if ($dataset) { $outcome = if ($unknown) { 'Not assessed' } elseif ($eligible.Count) { 'Pass' } else { 'Not applicable' } }
            }
            'AppOwners' {
                $unknown = @($rows | Where-Object { $null -eq $_.OwnerCount }).Count
                $affected = @($rows | Where-Object { $null -ne $_.OwnerCount -and $_.OwnerCount -eq 0 })
                if ($dataset) { $outcome = if ($unknown) { 'Not assessed' } elseif ($rows.Count) { 'Pass' } else { 'Not applicable' } }
            }
            'OwnerContinuity' {
                $affected = @($rows | Where-Object { $_.OwnerCategory -in @('singleOwner','orphanedOwner') })
                $unknown = @($rows | Where-Object { $_.OwnerCategory -notin @('singleOwner','orphanedOwner','noOwner','ok') }).Count
                if ($dataset -and -not $unknown) { $outcome = 'Pass' }
                $reason = 'Review continuity and retained owner-resolution evidence. Ownership is administrative power; at least two owners is recommended where possible, not a universal platform rule.'
            }
            'Activity' {
                $eligible = @($rows | Where-Object { $_.Category -eq 'Tenant-managed' -and $_.ServicePrincipalType -eq 'Application' })
                $affected = @($eligible | Where-Object { $_.LastSignIn -and $_.DaysSinceLastSignIn -ge $control.ThresholdDays })
                $unknown = @($eligible | Where-Object { -not $_.LastSignIn }).Count
                if ($dataset) { $outcome = if ($unknown) { 'Not assessed' } elseif ($eligible.Count) { 'Pass' } else { 'Not applicable' } }
                $reason = 'Only exported observed dates establish activity age; absent records do not establish inactivity or never-used status.'
            }
            'Expired' { $affected = @($rows | Where-Object { $_.Expired -eq $true }); $unknown = @($rows | Where-Object { $null -eq $_.Expired }).Count; if ($dataset -and -not $unknown) { $outcome = 'Pass' } }
            'Secrets' { $affected = @($rows | Where-Object { $_.CredentialType -eq 'password' -and $_.Expired -eq $false }); if ($dataset) { $outcome = 'Pass' } }
            'SecretLifetime' {
                Set-WorkloadSecretLifetime -Rows $rows -CollectedAt $dataset.CollectedAt -ThresholdDays $control.ThresholdDays
                $eligible = @($rows | Where-Object { $_.CredentialType -eq 'password' -and $_.SecretLifetimeStatus -ne 'Expired' })
                $affected = @($eligible | Where-Object { $_.SecretLifetimeReviewRequired })
                $unknown = @($eligible | Where-Object { $_.SecretLifetimeStatus -like 'Unknown*' }).Count
                if ($dataset -and -not $unknown) { $outcome = if ($eligible.Count) { 'Pass' } else { 'Not applicable' } }
                $reason = "Client secrets with total lifetime > $($control.ThresholdDays) days, or missing/invalid expiry or lifetime evidence, require review. This is a toolkit day threshold, not a claim that Microsoft defines a universal maximum of exactly this many days. A missing end date is unknown, not proof that a credential never expires. Expired credentials are handled separately."
            }
            'Expiring' { $affected = @($rows | Where-Object { $null -ne $_.DaysUntilExpiry -and $_.DaysUntilExpiry -ge 0 -and $_.DaysUntilExpiry -le $control.ThresholdDays }); if ($dataset) { $outcome = 'Pass' } }
            'CredentialActivity' {
                $affected = @($rows | Where-Object { $_.InactiveCredential -eq $true })
                $unknown = @($rows | Where-Object { $null -eq $_.InactiveCredential }).Count
                $reason = 'Credential activity is preview; missing/incomplete activity remains unknown independently of expiry.'
            }
            'Audience' { $affected = @($rows | Where-Object { $_.SignInAudience -match 'multi|Multiple|Personal' }); $unknown = @($rows | Where-Object { -not $_.SignInAudience -or $_.SignInAudience -eq 'Unknown' }).Count; if ($dataset -and -not $unknown) { $outcome = 'Pass' } }
            'Implicit' { $affected = @($rows | Where-Object { $_.HasImplicitGrantEnabled -eq $true }); $unknown = @($rows | Where-Object { $_.HasImplicitGrantEnabled -isnot [bool] }).Count; if ($dataset -and -not $unknown) { $outcome = 'Pass' } }
            'RedirectOwnership' {
                $eligible = @($rows | Where-Object { $_.OwnershipReviewApplicable -ne $false })
                $affected = @($eligible | Where-Object { $_.OwnershipReviewRequired })
                $unknown = $eligible.Count
                if ($dataset -and -not $eligible.Count) { $outcome = 'Not applicable' }
                $reason = 'Current domain and hosting ownership must be confirmed for every non-loopback HTTP(S) redirect, including tenant verified-domain matches. Exported configuration cannot prove a domain is owned, expired, dangling or reclaimable. No DNS, HTTP, registration or takeover probe is performed; unresolved ownership is never a pass.'
            }
            'TenantWideConsent' {
                $eligible = @($rows | Where-Object { $_.PermissionType -eq 'Delegated' -and $_.GrantState -eq 'Granted' })
                $affected = @($eligible | Where-Object { $_.ConsentScope -eq 'AllPrincipals' })
                $unknown = @($eligible | Where-Object { $_.ConsentScope -notin @('AllPrincipals','Principal') -or
                    ($_.ConsentScope -eq 'Principal' -and -not $_.ConsentPrincipalId) -or
                    ($_.ConsentScope -eq 'AllPrincipals' -and $_.ConsentPrincipalId) }).Count
                if ($dataset.DelegatedGrantEvidence.State -eq 'Available' -and -not $unknown) { $outcome = if ($eligible.Count) { 'Pass' } else { 'Not applicable' } }
                $reason = 'Granted delegated scopes with consentType=AllPrincipals authorize the client on behalf of all users, subject to signed-in-user/resource restrictions. This is the resulting grant associated with organization-wide admin consent, not proof that a checkbox was clicked or who approved it; grants can be created through APIs. Informational scope review is separate from permission capability severity. Counts are permission rows, not distinct consent events or users.'
            }
            'Permissions' {
                $eligible = @($rows | Where-Object { $_.GrantState -eq 'Granted' })
                Set-WorkloadPermissionRisk -Rows $rows -Catalog $catalog
                $unknown = @($eligible | Where-Object { $_.Tier -in @('UNKNOWN','UNCLASSIFIED') }).Count
                $affected = @($eligible | Where-Object { $_.RiskSeverity -eq $control.Severity -and $_.ReviewRequired })
                if ($dataset -and -not $unknown) { $outcome = if ($eligible.Count) { 'Pass' } else { 'Not applicable' } }
                $reason = "Catalog $($catalog.PermissionRisk.Version): AZTier Graph application tiers 0/1/2 map to High/Medium/Info; delegated and other access uses separate Microsoft/toolkit rules. Untiered is Low / Unrated, not proven low risk. Microsoft/vendor/official requirements never suppress exposure; review can result in mitigation or explicit risk acceptance. Not proof of compromise or unnecessary access."
            }
            'UnclassifiedPermissions' {
                $eligible = @($rows | Where-Object { $_.GrantState -eq 'Granted' })
                Set-WorkloadPermissionRisk -Rows $rows -Catalog $catalog
                $affected = @($eligible | Where-Object { $_.Tier -in @('UNKNOWN','UNCLASSIFIED') })
                $unknown = $affected.Count
                if ($dataset -and -not $unknown) { $outcome = if ($eligible.Count) { 'Pass' } else { 'Not applicable' } }
                $reason = 'Untiered, unresolved or unclassified API capability requires manual review. Low / Unrated is a reviewer-selected priority, not a researched low-risk finding. Detection recency is not risk-research recency; any separate capability warning remains relevant. No STANDARD/safe fallback is used.'
            }
            'Rbac' {
                $affected = @($rows | Where-Object { $_.IsPrivilegedRole -eq $true })
                $reason = 'Azure access scope and business necessity require review.'
            }
            'Federation' {
                $affected = @($rows | Where-Object { $_.SubjectClassification -in @('BROAD','WILDCARD') })
                $reason = 'Trust provider and flexible-expression semantics require manual validation; no CI/CD assumption is made.'
            }
            'DirectoryRoles' {
                $capability = $dataset.WorkloadEvidence.DirectoryRoles
                if ($capability.State -eq 'Available') {
                    $ids = @($dataset.servicePrincipals.SpObjectId)
                    $affected = @($capability.Records | Where-Object { $_.principalId -in $ids })
                }
                $reason = 'Role assignments are reviewed for workload principals only; role necessity and effective scope require validation.'
            }
            'Risk' {
                $capability = $dataset.WorkloadEvidence.RiskyServicePrincipals
                if ($capability.State -eq 'Available') { $affected = @($capability.Records | Where-Object { $_.riskState -notin @('remediated','dismissed') -and $_.riskLevel -notin @('none','hidden') }) }
                $reason = 'Risk detections and response procedures require review; API absence is not an all-clear.'
            }
            'Protection' {
                $reason = 'Review eligible single-tenant SP targeting, exclusions, resource scope and block conditions. Legacy coverage is not authoritative.'
                if ($dataset.CoverageSchemaVersion -eq 2) {
                    $eligible = @($rows | Where-Object { $_.Eligibility -ne 'Not applicable' })
                    $unknown = @($eligible | Where-Object { $_.Eligibility -ne 'Eligible' -or $null -eq $_.CoveredByAnyCAPolicy }).Count
                    $affected = @($eligible | Where-Object { $_.CoveredByAnyCAPolicy -eq $false -and $_.Eligibility -eq 'Eligible' })
                }
            }
            'Logging' {
                $reason = 'Routing settings are evidence only. Confirm enabled workload categories, destination delivery, retention and SOC response manually.'
            }
            { $_ -in @('PasswordPolicy','PasswordLifetime','CertificateLifetime','Consent') } {
                if ($control.Kind -ne 'Consent') {
                    $outcome = Test-WorkloadPolicy $dataset.WorkloadEvidence $control.Kind
                    if ($outcome -eq 'Fail') {
                        $affected = @([pscustomobject]@{
                            DisplayName = 'Tenant default app management policy'
                            Policy = $dataset.WorkloadEvidence.DefaultAppManagementPolicy.Records
                            Predicate = $control.Kind
                        })
                        $failure = 'Fail'
                    }
                } elseif ($Data['01'].AuthorizationPolicy.PermissionGrantPolicyIdsAssignedToDefaultUserRole -is [array] -and
                    $Data['01'].AuthorizationPolicy.PermissionGrantPolicyIdsAssignedToDefaultUserRole.Count -eq 0) {
                    $outcome = 'Pass'
                }
                $reason = 'Policy exceptions/date cutoffs require manual review. Only a verified default covering both object types with complete override inventory can pass automatically.'
            }
        }
        $fieldValue = $null
        if ($dataset -is [System.Collections.IDictionary]) { $fieldValue = $dataset[$control.Field] }
        elseif ($dataset) { $fieldValue = $dataset.PSObject.Properties[$control.Field].Value }
        if (-not $dataset -or $null -eq $fieldValue) {
            $eligible = @(); $affected = @(); $outcome = 'Not assessed'
            $reason = 'Required dataset/field not collected or unavailable. This is not a passing result.'
        }
        if ($affected.Count) { $outcome = $failure }
        if ($outcome -eq 'Not assessed' -and $unknown -eq 0) {
            $unknown = $eligible.Count
            $reason += ' Not automatically assessed: missing capability or manual/effective-configuration validation required.'
        }
        if ($outcome -eq 'Pass') { $reason = 'No violation of this specific collected predicate was found. This is not a complete security or business-necessity assessment.' }
        $url = Get-ControlProperty $catalog.Sources $control.Source
        $permissionSourceUrls = @(if ($control.Kind -in @('Permissions','UnclassifiedPermissions')) {
            $affected | ForEach-Object { $_.RiskSourceUrl; $_.CapabilitySourceUrl; $_.RiskReferences.Url } |
                Where-Object { $_ } | Sort-Object -Unique
        })
        $results.Add([pscustomobject]@{
            Id = $control.Id; ExternalId = $control.ExternalId; Domain = $control.Domain
            Title = $control.Title; Severity = $control.Severity; Outcome = $outcome
            Source = $control.Source; SourceUrl = $url; Strength = $control.Strength
            PermissionSourceUrls = $permissionSourceUrls
            BaselineSourceUrl = if ($control.ExternalId) { $catalog.Sources.SCUBA } else { $null }
            Recommendation = $control.Remediation; Detail = $reason
            EvaluatedCount = $eligible.Count - $unknown; UnknownCount = $unknown
            ExcludedCount = $rows.Count - $eligible.Count; EligibleCount = $eligible.Count
            Denominator = "$($control.Field): eligible exported records; unknown evidence is not a pass."
            AffectedCount = $affected.Count; AffectedRows = @($affected)
            Evidence = @($rows)
            Dataset = $control.Dataset; Field = $control.Field
            RequiredEvidence = @("$($control.Dataset).$($control.Field)")
            Limitations = 'Snapshot-only assessment; no live effective-access, business-necessity or historical-absence conclusion.'
        })
    }
    return [pscustomobject]@{
        CatalogVersion = $catalog.Version; BaselineRevision = $catalog.BaselineRevision
        BaselineApplicability = $catalog.BaselineApplicability
        PermissionRisk = $catalog.PermissionRisk
        Results = $results.ToArray()
    }
}

Export-ModuleMember -Function Get-WorkloadCategory, ConvertTo-WorkloadSnapshot, Invoke-WorkloadControls, Set-WorkloadPermissionRisk
