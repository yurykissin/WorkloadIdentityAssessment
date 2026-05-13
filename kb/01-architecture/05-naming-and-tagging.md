# Naming & Tagging Convention

A prescriptive standard for naming app registrations, service principals, managed identities, and federated credentials — and for tagging user-assigned managed identity ARM resources.

---

## 1. Naming Components

All workload identity names are composed from a fixed set of components in a defined order. Components are joined by hyphens (`-`). Use lowercase only. No spaces. No special characters except hyphens.

| Component     | Description                                               | Allowed values / examples                          |
|---------------|-----------------------------------------------------------|----------------------------------------------------|
| `<type>`      | Identity object type abbreviation                         | `app`, `mi`, `sp` (inferred; not always explicit)  |
| `<env>`       | Deployment environment                                    | `prod`, `nprod`, `dev`, `test`, `stg`, `shared`    |
| `<bu>`        | Business unit or team abbreviation (2–6 chars)            | `fin`, `hr`, `ops`, `plat`, `sec`, `mktg`          |
| `<workload>`  | Short workload or application name (2–12 chars, no spaces)| `invoiceapi`, `graphbatch`, `datalake`, `cicd`     |
| `<purpose>`   | What the identity does (optional second descriptor)       | `deploy`, `reader`, `ingest`, `notify`             |
| `<instance>`  | Zero-padded three-digit instance counter                  | `001`, `002`                                       |

---

## 2. Naming Patterns

### App Registration (App Object / Service Principal)

```
app-<env>-<bu>-<workload>[-<purpose>]-<instance>
```

| Example                              | Interpretation                                                        |
|--------------------------------------|-----------------------------------------------------------------------|
| `app-prod-fin-invoiceapi-001`        | Production, Finance team, Invoice API workload, first instance.       |
| `app-prod-plat-graphbatch-reader-001`| Production, Platform team, Graph batch job, read-only role.          |
| `app-shared-sec-sentinelconn-001`    | Shared/cross-env, Security team, Sentinel data connector.            |
| `app-prod-hr-leavenotify-001`        | Production, HR team, leave notification service.                     |

### System-Assigned Managed Identity

System-assigned MIs take the display name of the Azure resource they are attached to. The resource itself should be named according to the organisation's Azure resource naming standard. No separate naming convention is needed for the identity object — it is inseparable from the resource.

### User-Assigned Managed Identity

```
mi-<env>-<bu>-<workload>[-<purpose>]-<instance>
```

| Example                              | Interpretation                                                        |
|--------------------------------------|-----------------------------------------------------------------------|
| `mi-prod-fin-invoiceapi-001`         | Production, Finance, Invoice API, first instance.                     |
| `mi-prod-plat-akspod-ingest-001`     | Production, Platform, AKS ingest pod.                                |
| `mi-shared-ops-adf-pipeline-001`     | Shared, Operations, Data Factory pipeline identity.                  |
| `mi-prod-fin-invoiceapi-002`         | Second instance — e.g., blue/green or region B.                      |

### Federated Identity Credential (on App Reg or User-Assigned MI)

Federated credentials have a `name` field. Use a short descriptor that captures the external issuer context.

```
fic-<issuer-shortname>-<repo-or-cluster>-<branch-or-namespace>[-<env>]
```

| Example                                        | Interpretation                                                          |
|------------------------------------------------|-------------------------------------------------------------------------|
| `fic-github-myorg-myrepo-main-prod`            | GitHub Actions, myorg/myrepo, main branch, production environment.      |
| `fic-aks-aks-prod-eastus-default-mysa`         | AKS OIDC, cluster aks-prod-eastus, namespace default, SA mysa.         |
| `fic-gitlab-mygroup-myproject-prod`            | GitLab CI, mygroup/myproject, production.                              |
| `fic-ado-myorg-myproject-prod`                 | Azure DevOps, myorg/myproject, production.                             |

---

## 3. Display Name vs Object ID

| Attribute      | What it is                                                                 | Where it shows up                                       |
|----------------|----------------------------------------------------------------------------|---------------------------------------------------------|
| Display name   | The human-readable name. Not unique across the tenant.                     | Entra portal; RBAC assignment target picker; audit logs (alongside OID) |
| Object ID (OID)| Immutable GUID assigned by Entra ID. Unique per tenant.                    | RBAC assignments; Graph API; audit logs; token `oid` claim |
| Client ID      | For app registrations: the application (client) ID. For MIs: the client ID of the MI's service principal. | `AZURE_CLIENT_ID` env var; IaC references; MSAL config |
| Resource ID    | ARM resource ID (user-assigned MIs only).                                  | Azure portal; IaC; Resource Graph queries              |

**Important:** Use object ID (not display name) in all IaC, API calls, and RBAC assignments. Display names can change; the OID is immutable.

---

## 4. Required Azure Tags — User-Assigned Managed Identity Resources

Apply these tags to every `Microsoft.ManagedIdentity/userAssignedIdentities` ARM resource at creation time. Tag enforcement should be applied via Azure Policy (`Require a tag on resources` initiative).

| Tag Name          | Required | Description                                                        | Example values                          |
|-------------------|----------|--------------------------------------------------------------------|-----------------------------------------|
| `Owner`           | Yes      | Email address or alias of the primary accountable owner.           | `team-platform@<organization>.com`          |
| `SecondaryOwner`  | Yes      | Email address of the secondary owner.                              | `eng-lead@<organization>.com`               |
| `CostCenter`      | Yes      | Cost centre code for chargeback.                                   | `CC-1234`                               |
| `Environment`     | Yes      | Deployment environment.                                            | `prod`, `nprod`, `dev`                  |
| `DataSensitivity` | Yes      | Highest sensitivity of data the workload accesses.                 | `public`, `internal`, `confidential`, `restricted` |
| `AppCode`         | Yes      | CMDB application code or application name.                         | `APP-0042`                              |
| `Lifecycle`       | Yes      | Expected end-of-life or "ongoing".                                 | `2026-12-31`, `ongoing`                 |
| `Project`         | No       | Project or initiative this identity supports.                      | `PROJ-DataPlatform-2025`                |
| `CreatedBy`       | No       | IaC module or identity that provisioned the resource.              | `bicep/modules/identity/v1.2`           |

---

## 5. Tagging App Registrations via Microsoft Graph

Azure portal tags (ARM tags) are not applicable to app registration objects — they are Entra directory objects, not ARM resources. Tags on app registrations are set via the `tags` property of the application object using the Microsoft Graph API.

**Graph API — set tags on an application:**
```http
PATCH https://graph.microsoft.com/v1.0/applications/<object-id>
Content-Type: application/json

{
  "tags": ["Owner:team-platform@<organization>.com", "Environment:prod", "AppCode:APP-0042"]
}
```

**Gotcha:** The `tags` property on the application object is an array of strings, not key-value pairs. Some portal views (including the App registrations blade) do not surface these tags in the UI. Query them via Graph (`GET /applications/<id>?$select=tags`) or via the application manifest view.

**Convention:** Use `Key:Value` format as a string to maintain queryability:
```
"Owner:team-platform@<organization>.com"
"Environment:prod"
"DataSensitivity:confidential"
"AppCode:APP-0042"
```

**Azure portal manifest view:**
```
Entra admin center > Identity > Applications > App registrations > <app> > Manifest
```
Look for the `"tags"` array in the JSON manifest.

---

## 6. Required-Value Summary Table

| Convention Item                          | Required Value / Pattern                                                       |
|------------------------------------------|--------------------------------------------------------------------------------|
| App registration name prefix             | `app-`                                                                         |
| User-assigned MI name prefix             | `mi-`                                                                          |
| Federated credential name prefix         | `fic-`                                                                         |
| Environment token in name                | `prod`, `nprod`, `dev`, `test`, `stg`, or `shared` — no abbreviation variants |
| Character set                            | Lowercase a–z, 0–9, hyphens only — no uppercase, underscores, or spaces       |
| Instance suffix                          | Three-digit zero-padded integer (`001`)                                        |
| RBAC / IaC references                    | Always by object ID or resource ID — never by display name alone               |
| App registration tags                    | Set via Graph API `tags` array; format `Key:Value`                             |
| Required ARM tags on user-assigned MI    | `Owner`, `SecondaryOwner`, `CostCenter`, `Environment`, `DataSensitivity`, `AppCode`, `Lifecycle` |
| Tag enforcement mechanism                | Azure Policy — `Require a tag on resources` applied at management group scope  |

---

## Naming Convention Validation Checklist

Before deploying any workload identity, validate the following naming and tagging requirements are met:

- [ ] Name uses only lowercase letters, digits, and hyphens.
- [ ] Name starts with `app-` (app registration) or `mi-` (user-assigned MI) or `fic-` (federated credential).
- [ ] Environment token is one of: `prod`, `nprod`, `dev`, `test`, `stg`, `shared`.
- [ ] Business unit token is 2–6 characters, matching the approved BU abbreviation list.
- [ ] Workload token is 2–12 characters with no spaces or special characters.
- [ ] Instance suffix is a three-digit zero-padded integer.
- [ ] All required ARM tags are present on the user-assigned MI resource.
- [ ] App registration `tags` property set via Graph API with `Owner:`, `Environment:`, `AppCode:` values.
- [ ] No duplicate display name exists in the tenant (check with `Get-MgApplication -Filter "displayName eq '<name>'"` before creating).

---

## Approved Business Unit Abbreviations

Update this table to match `<organization>`'s organisational structure before using in naming.

| BU Abbreviation | Business Unit Name          |
|-----------------|-----------------------------|
| `fin`           | Finance                     |
| `hr`            | Human Resources             |
| `ops`           | Operations                  |
| `plat`          | Platform Engineering        |
| `sec`           | Security                    |
| `mktg`          | Marketing                   |
| `sales`         | Sales                       |
| `data`          | Data & Analytics            |
| `shared`        | Shared / cross-team         |
| `ext`           | External / partner-facing   |

---

## Gotcha — Portal vs Graph Tag Visibility

The Azure portal's App registrations blade **does not** display the `tags` array from the application manifest in the main properties view. To verify tags are correctly set:

```powershell
Get-MgApplication -ApplicationId "<object-id>" -Property "tags" | Select-Object -ExpandProperty Tags
```

Or in the portal: App registrations > \<app\> > Manifest — search for `"tags"` in the JSON.

This is a platform limitation, not a configuration error. Always verify via Graph after setting tags.

---

## References
- https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-naming
- https://learn.microsoft.com/en-us/graph/api/resources/application
- https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/tag-resources
