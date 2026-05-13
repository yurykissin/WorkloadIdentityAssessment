# App Management Policies — remediation scripts

Read/write helpers to manage the **tenant-default `appManagementPolicy`**
and **per-app named policies** that govern client secrets, certificates,
identifier URIs, and sign-in audiences for application registrations and
service principals.

These map 1:1 to the eight controls in the Entra portal:
**Enterprise applications → Application policies → Default app management
policy**. The portal only manages the tenant default; named policies and
per-app assignments are Graph-only.

## ⚠️ These scripts modify tenant state

Unlike the read-only assessment toolkit in [`../../assessment/`](../../assessment/),
the scripts here **change configuration**. Always run with `-WhatIf` first.

## Permissions

```powershell
Connect-MgGraph -Scopes 'Policy.ReadWrite.ApplicationConfiguration','Application.Read.All'
```

| Script | Required scope |
|---|---|
| `Get-TenantDefaultAppManagementPolicy.ps1` | `Policy.Read.All` |
| `Set-TenantDefaultAppManagementPolicy.ps1` | `Policy.ReadWrite.ApplicationConfiguration` |
| `New-AppManagementPolicy.ps1` | `Policy.ReadWrite.ApplicationConfiguration` |

Caller also needs an Entra role with the equivalent privilege — typically
**Security Administrator** or **Application Administrator**.

## Scripts

### `Get-TenantDefaultAppManagementPolicy.ps1`

Read-only. Prints the current default policy in human-readable form. Use
before/after changes for evidence.

```powershell
./Get-TenantDefaultAppManagementPolicy.ps1
```

### `Set-TenantDefaultAppManagementPolicy.ps1`

Configures the tenant default. Each control is opt-in via a switch
parameter. Supports a soft-launch date so existing apps are exempt.

```powershell
# Soft launch — locks down only NEW apps, existing apps unaffected
./Set-TenantDefaultAppManagementPolicy.ps1 `
    -BlockPasswordAddition `
    -BlockCustomPasswords `
    -MaxCertificateLifetimeDays 365 `
    -BlockMultiTenantApps `
    -BlockConsumerApps `
    -RestrictForAppsCreatedAfter (Get-Date).ToUniversalTime() `
    -WhatIf

# Hard enforcement — applies to all existing apps too
./Set-TenantDefaultAppManagementPolicy.ps1 `
    -BlockPasswordAddition `
    -MaxPasswordLifetimeDays 180 `
    -BlockCustomPasswords `
    -MaxCertificateLifetimeDays 365 `
    -BlockCustomIdentifierUris `
    -BlockMultiTenantApps `
    -BlockConsumerApps
```

### `New-AppManagementPolicy.ps1`

Creates a **named** policy and assigns it to specific applications and/or
service principals. Use for stricter rules on privileged apps when the
tenant default is permissive.

```powershell
./New-AppManagementPolicy.ps1 `
    -DisplayName 'privileged-apps-no-secrets' `
    -Description 'Apps with Graph admin permissions — certs/FICs only' `
    -BlockPasswordAddition `
    -MaxCertificateLifetimeDays 365 `
    -ApplicationObjectIds 'aaaaaaaa-1111-...','bbbbbbbb-2222-...' `
    -WhatIf
```

`ApplicationObjectIds` are the **object IDs** of the app registrations,
NOT the appId/clientId.

## What "Block password addition" actually does

Forward-looking only. Existing secrets keep working until expiry; the
policy blocks `addPassword` calls (portal "New client secret",
`Add-MgApplicationPassword`, Graph `addPassword`, Terraform
`azuread_application_password`, etc.). Cert credentials and FICs are
unaffected. See the recommended rollout sequence in
[`../../kb/02-governance/01-app-registration-policy.md`](../../kb/02-governance/01-app-registration-policy.md)
and [`03-credential-and-secret-policy.md`](../../kb/02-governance/03-credential-and-secret-policy.md).

## Recommended workflow

1. Run `assessment/scripts/03-credential-hygiene.ps1` to inventory secrets.
2. Run `Get-TenantDefaultAppManagementPolicy.ps1` to capture baseline.
3. Run `Set-TenantDefaultAppManagementPolicy.ps1 -RestrictForAppsCreatedAfter (Get-Date) -WhatIf`,
   review the JSON body, then re-run without `-WhatIf`.
4. Optionally create per-app stricter policies with `New-AppManagementPolicy.ps1`
   for privileged apps.
5. Migrate legacy apps from secrets → certs / FICs / managed identity.
6. Re-run `Set-TenantDefaultAppManagementPolicy.ps1` **without**
   `-RestrictForAppsCreatedAfter` to enforce on the entire estate.
7. Re-run `Get-...` to confirm; commit the JSON output as evidence.

## References

- [Microsoft Graph: appManagementPolicy](https://learn.microsoft.com/graph/api/resources/appmanagementpolicy)
- [Microsoft Graph: defaultAppManagementPolicy](https://learn.microsoft.com/graph/api/resources/tenantappmanagementpolicy)
- [Restrict app authentication credentials](https://learn.microsoft.com/entra/identity-platform/restrict-app-credentials)
