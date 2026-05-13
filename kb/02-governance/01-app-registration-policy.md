# App Registration Policy

An app registration is the definition of an application's identity in Microsoft Entra ID — its allowed credentials, redirect URIs, requested API permissions, and ownership record. Every service principal that authenticates to Entra-protected resources originates from an app registration. Weak governance of app registrations is the most common root cause of over-privileged identities, leaked secrets, and orphaned access in an Entra tenant.

Path to configure:
```
Microsoft Entra admin center > Identity > Applications > App registrations
Microsoft Entra admin center > Identity > Applications > User settings
Microsoft Entra admin center > Identity > Enterprise applications > Consent and permissions
```

---

## Policy Table

| Policy / Setting                                              | Required Value                                                                                                                                      |
|---------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------|
| Users can register applications (tenant setting)              | **Disabled** — only designated roles (Application Administrator, Cloud App Administrator) may create app registrations.                              |
| Users can consent to apps accessing data on their behalf      | **Disabled** — admin consent workflow must be enabled as the alternative.                                                                           |
| Admin consent workflow                                        | **Enabled** — designated consent reviewers must approve any consent request.                                                                        |
| Group owners can consent to apps accessing data for the group | **Disabled**                                                                                                                                        |
| Client secrets (password credentials)                         | **Avoid** — approved exception only. Maximum lifetime 180 days where used. Stored in Azure Key Vault only; never in source code or pipeline variables. |
| Certificate credentials                                       | **Preferred** over client secrets where managed identity and federated credentials are not supported.                                               |
| Federated identity credentials (Workload Identity Federation) | **Preferred** for all CI/CD, GitHub Actions, GitLab, AKS, and cross-cloud scenarios. No credential stored in Azure.                                |
| App registration owners                                       | **≥ 2 named owners assigned at creation**; owners must be active employees; reviewed and updated on owner departure.                               |
| Orphaned app registrations (no active owner)                  | **Disabled within 30 days** of owner departure if no replacement is assigned.                                                                      |
| Redirect URIs — production                                    | **Locked to specific production HTTPS URIs only.** No wildcards, no `localhost`, no HTTP, no broad-domain wildcards (e.g., `*.contoso.com`).       |
| Redirect URIs — localhost / development                       | **Not permitted on production app registrations.** Use separate dev/test registrations.                                                             |
| Implicit grant — ID tokens                                    | **Disabled** unless the application is a legacy SPA that cannot migrate to authorisation code + PKCE. Requires approved exception.                 |
| Implicit grant — access tokens                                | **Disabled** — no exceptions. Use authorisation code + PKCE for SPAs.                                                                              |
| Verified publisher                                            | **Required** for any third-party application requesting admin consent to any application permission with "High" or "Medium" risk level.            |
| Multi-tenant app registrations                                | **Approved exception only** — document the intended tenant audience, required permissions, and publisher verification status.                       |
| API permissions — Microsoft Graph (delegated)                 | **Least-privilege** — request only the minimum scope needed; do not request `.ReadWrite` when `.Read` is sufficient.                               |
| API permissions — Microsoft Graph (application)               | **Least-privilege and security review required**. Admin consent granted only after Identity Security review.                                        |
| Privileged Graph application permissions                      | **Approved exception only** (e.g., `Directory.ReadWrite.All`, `RoleManagement.ReadWrite.Directory`). Quarterly recertification required.           |
| Custom signing keys on app registrations                      | **Standard Entra signing only** unless an approved exception is documented for a specific application scenario (e.g., SAML with custom cert).      |
| Application manifest changes                                  | **Reviewed via change control** — changes to the manifest (roles, `requiredResourceAccess`, `appRoles`) must be tracked and peer-reviewed.         |
| App registration display names                                | **Follow naming convention** — `app-<env>-<bu>-<workload>-<instance>`. See naming and tagging policy.                                              |
| Application tags (Graph `tags` property)                      | **Required** — `Owner:`, `Environment:`, `AppCode:` tags set via Graph API at creation.                                                            |
| Stale app registrations (no sign-in > 90 days)                | **Reviewed monthly** — disable or decommission if no longer needed.                                                                                |
| App registrations with no credentials and no sign-in activity | **Investigated and removed** — likely orphaned or unused.                                                                                          |

---

## Scope and Applicability

This policy applies to all app registrations created in `<customer>`'s Microsoft Entra tenant, including:

- App registrations owned by the customer's internal engineering teams.
- App registrations registered by platform or cloud engineering for shared service SPs.
- App registrations for SaaS or ISV applications that have been registered (not enterprise applications consented from a third-party publisher's tenant — those are covered by the service principal consent review process).

This policy does **not** cover:

- Enterprise applications (service principals) instantiated from third-party multi-tenant apps — those are governed by the admin consent review process.
- App registrations in development or test tenants — those tenants should have equivalent but separately maintained policies.

---

## Tenant-Level Security Settings — Quick Reference

These settings are set once and affect all app registrations in the tenant. Verify these are in the correct state before the customer call ends.

Path to verify:
```
Microsoft Entra admin center > Identity > Applications > User settings
Microsoft Entra admin center > Identity > Enterprise applications > User settings
Microsoft Entra admin center > Identity > Enterprise applications > Consent and permissions > User consent settings
```

| Setting                                                         | Required State | Portal Location                                                         |
|-----------------------------------------------------------------|----------------|-------------------------------------------------------------------------|
| Users can register applications                                 | **No**         | Identity > Applications > User settings                                 |
| Users can consent to apps accessing data on their behalf        | **Do not allow user consent** | Enterprise apps > Consent and permissions          |
| Users can consent to apps from verified publishers              | **Do not allow** (if strictest) or **Allow for selected permissions** | Enterprise apps > Consent and permissions |
| Group owners can consent to apps accessing data for their groups | **No**        | Enterprise apps > Consent and permissions                               |
| Admin consent requests — users can request admin consent        | **Yes** (enables the workflow) | Enterprise apps > Consent and permissions > Admin consent requests |
| Restrict access to Microsoft Entra admin center (non-admin users) | **Yes**      | Identity > Users > User settings                                        |

---

## Common Policy Gaps Found in Practice

The following gaps are found in the majority of tenants without an enforced app registration policy. Use this as a pre-call checklist:

- App registrations with secrets that have never been rotated and are approaching or past expiry.
- Production app registrations with `localhost` or `http://` redirect URIs — left from development.
- App registrations with no owner assigned — often created by developers who have since left.
- Graph application permissions granted via admin consent with no documented business justification.
- `Users can register applications` is enabled — any user can create an app registration with no oversight.
- Implicit grant (access tokens) enabled on registrations that could use authorization code + PKCE.
- Multi-tenant app registrations with no publisher verification and no documented intended tenant scope.

---

## Enforcement

| Control                                                        | Enforcement Mechanism                                                                                             |
|----------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------|
| `Users can register applications = No`                         | Entra admin center > Identity > Applications > User settings > "Users can register applications: No"             |
| Admin consent workflow                                         | Entra admin center > Identity > Enterprise applications > Consent and permissions > Admin consent requests        |
| Credential type restriction                                    | Microsoft Graph `appManagementPolicies` — tenant default policy restricts password credentials; per-app overrides for exceptions |
| Credential lifetime cap                                        | `appManagementPolicies` — `passwordCredentials.maxLifetime` and `keyCredentials.maxLifetime`                     |
| Privileged role guard on app management actions                | PIM for Entra roles — Application Administrator and Cloud App Administrator are PIM-eligible, not permanently assigned |
| Alert on new credentials added to app registrations            | Entra ID audit log → Log Analytics alert rule — event `Update application - Certificates and secrets management` |
| Alert on new admin consent grants                              | Entra ID audit log → alert on `Consent to application`                                                           |
| Redirect URI governance                                        | Periodic script review via Graph (`GET /applications?$select=web,spa`) — alert on non-HTTPS or localhost URIs    |
| Orphaned app registration detection                            | Monthly Graph query for app registrations with no owner and no sign-in in 90 days → review queue                 |

---

## Rollout Phasing

Deploying this policy against a live tenant requires phasing to avoid service disruption.

**Phase 1 — Observe (weeks 1–2):**
- Enable all audit log → Log Analytics streaming.
- Run Graph inventory query to establish the baseline (total app registrations, SPs with no owner, secrets expiring within 90 days).
- Do not change any existing credentials or permissions — observe only.

**Phase 2 — Quick wins (weeks 3–6):**
- Set `Users can register applications = No`.
- Enable admin consent workflow.
- Assign owners to the top 20 highest-risk app registrations (those with privileged Graph permissions or sub-level RBAC).
- Apply `appManagementPolicy` in report-only mode (test against existing apps; do not enforce yet).

**Phase 3 — Enforce (weeks 7–12):**
- Apply `appManagementPolicy` tenant default in enforced mode.
- Rotate all secrets older than 180 days — stagger by risk tier.
- Remove localhost and HTTP redirect URIs from production registrations.
- Complete owner assignment for all remaining app registrations.

**Phase 4 — Steady state (ongoing):**
- Monthly orphaned SP review.
- Quarterly access reviews.
- Annual policy review and refresh.

---

## See Also

- `/Volumes/data/vscode/MyProjects/entra-nrt/kb/app-registrations/01-overview-essentials.md`
- `/Volumes/data/vscode/MyProjects/entra-nrt/kb/app-registrations/12-certificates-and-secrets.md` — federated credentials and secrets field-by-field
- `/Volumes/data/vscode/MyProjects/entra-nrt/kb/app-registrations/14-api-permissions.md`
- `/Volumes/data/vscode/MyProjects/entra-nrt/kb/app-registrations/17-owners.md`
- `/Volumes/data/vscode/MyProjects/entra-nrt/kb/app-registrations/18-roles-and-administrators.md`

## References
- https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/configure-admin-consent-workflow
- https://learn.microsoft.com/en-us/graph/api/resources/appmanagementpolicy
- https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/manage-consent-requests
