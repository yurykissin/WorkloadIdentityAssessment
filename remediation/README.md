# Remediation scripts

**Write-action** PowerShell scripts to apply the policies recommended in
the [`kb/02-governance/`](../kb/02-governance/) articles. Unlike the
[`assessment/`](../assessment/) toolkit, these **modify tenant state**.

All scripts support `-WhatIf`. Always preview before applying.

| Folder | Scope |
|--------|-------|
| [`app-management-policies/`](app-management-policies/) | Tenant-default + per-app `appManagementPolicy` — client secrets, certs, identifier URIs, sign-in audiences. |

More remediation areas (managed identity migration helpers, FIC rollout,
PIM-for-Groups configuration, etc.) will be added here over time.
