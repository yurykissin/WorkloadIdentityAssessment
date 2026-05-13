# Workload Identity Policy

Workload identities — service principals, managed identities, and federated identity credentials — are non-human identities that represent applications, pipelines, and automated processes. They are not governed by joiner-mover-leaver HR processes and can accumulate permissions, stale credentials, and absent owners without any natural self-correction. This policy establishes the required baseline for all workload identities across `<organization>`'s Entra tenant.

Path to configure:
```
Microsoft Entra admin center > Identity > Applications > Enterprise applications
Microsoft Entra admin center > Protection > Conditional Access (workload identity policies)
Microsoft Entra admin center > Protection > Identity Protection > Risky workload identities
Azure portal > <resource> > Identity
Microsoft Graph > appManagementPolicies
```

---

## Policy Table

| Policy / Setting                                              | Required Value                                                                                                                                                           |
|---------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Managed identities                                            | **Preferred** for all Azure-hosted workloads. Must be the default choice before considering any credential-based alternative.                                            |
| System-assigned managed identity                              | **Use where the identity lifecycle must follow the Azure resource lifecycle** — the identity is created and deleted with the resource.                                   |
| User-assigned managed identity                                | **Use where the identity must be shared across multiple Azure resources**, or where the identity must outlive the compute resource (e.g., re-created VMs, AKS pods).    |
| Service principals with credential (non-MI)                   | **Use only where managed identity is not supported** for the workload scenario. Documented exception required.                                                           |
| Workload identity ownership                                   | **≥ 2 named accountable owners assigned** at creation. Owners are recorded in the app registration owners list and in the workload identity inventory.                  |
| Orphaned workload identities (no active owner)                | **Disabled within 30 days** of last owner departure if no replacement is assigned. Deleted within 90 days if not claimed.                                               |
| Workload identity naming convention                           | **Required** — `app-<env>-<bu>-<workload>-<instance>` for app registrations; `mi-<env>-<bu>-<workload>-<instance>` for user-assigned MIs. See naming policy.           |
| Workload identity inventory                                   | **Maintained** — all service principals and managed identities recorded in the central inventory tool. **Reviewed quarterly** — orphaned and stale identities remediated.|
| Stale workload identities (no sign-in > 90 days)              | **Reviewed monthly**. Disabled if no legitimate justification is provided within 30 days of the review.                                                                 |
| Federated identity credentials                                | **Preferred** for CI/CD pipelines (GitHub Actions, ADO, GitLab) and external-cloud scenarios. No secret stored in Azure or the external platform.                       |
| Federated credential subject specificity                      | **Exact match required** in production — no wildcard subjects. Subject must identify the specific repo, branch, environment, namespace, or service account.            |
| Conditional Access for workload identities                    | **Required for high-value workload identities** (those with privileged Graph permissions or subscription Owner/Contributor RBAC). Location-restrict and risk-based block. Requires Entra Workload Identities Premium SKU. |
| Conditional Access policy mode — initial deployment           | **Report-only for 30 days**, then enforced. Exception: immediate enforcement for any SP flagged as risky.                                                               |
| Risky workload identities (Identity Protection)               | **Reviewed weekly** by Identity Security. Confirmed compromised identities disabled within 4 hours. Risk remediation documented.                                        |
| Service principal sign-in logs                                | **Diagnostic settings configured** to stream non-interactive sign-in logs to Log Analytics workspace and Microsoft Sentinel. Retained ≥ 90 days (≥ 365 days preferred). |
| Audit logs — app registration changes                         | **Streamed to Log Analytics**. Alert rules configured for: new credential added, redirect URI changed, owner changed, API permission added.                             |
| Custom security attributes                                    | **Applied** to classify workload identities: `Sensitivity` (public / internal / confidential / restricted), `Owner` (email), `AppCode` (CMDB code).                    |
| Workload identities in PIM for Groups                         | **Used for just-in-time access** where a workload identity requires periodic elevated access. Group membership managed via PIM; standard assignment is zero-standing privilege. Requires Entra ID P2 or Governance licence. |
| Multi-tenant app registrations                                | **Approved exception only** — documented scope, permissions, publisher verification, and your tenant notification required.                                          |
| Service principal with subscription Owner RBAC                | **Approved exception only**. Quarterly recertification. Conditional Access policy applied.                                                                              |
| Service principal with privileged Graph application permission | **Approved exception only**. Quarterly recertification. Conditional Access policy applied. Sign-in logs alerted.                                                       |

---

## Workload Identity Classification Tiers

Not all workload identities carry the same risk. Use these tiers to apply proportionate controls.

| Tier | Criteria                                                                                 | Controls Required                                                                                          |
|------|------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------|
| **Tier 0 — Critical** | Holds any of: `Directory.ReadWrite.All`, `RoleManagement.ReadWrite.Directory`, `Application.ReadWrite.All`; or subscription-level Owner / UAA RBAC | CA policy enforced; monthly access review; Conditional Access location-restrict; Sentinel alert on every sign-in; quarterly recertification |
| **Tier 1 — Privileged** | Holds any of: `Mail.ReadWrite`, `Files.ReadWrite.All`, `User.ReadWrite.All`, `GroupMember.ReadWrite.All`; or subscription-level Contributor RBAC | CA policy (report-only → enforced); quarterly access review; sign-in alerts; semi-annual recertification |
| **Tier 2 — Sensitive** | Accesses production data (PII, financial, health); holds resource-group-scope Contributor or above | Quarterly access review; sign-in log review; pre-expiry alerts enforced |
| **Tier 3 — Standard** | Read-only permissions; resource-scope RBAC; no sensitive data access                    | Semi-annual access review; standard monitoring; pre-expiry alerts                                         |

Assign a tier to each workload identity at provisioning. Record the tier in the central inventory and in the workload identity's custom security attributes. Review tier assignments when a workload's permissions change.

---

## Scope and Applicability

This policy applies to all non-human identities authenticating to Entra-protected resources in `<organization>`'s tenant, including:

- Service principals created from internally-owned app registrations.
- System-assigned and user-assigned managed identities on Azure resources in subscriptions under `<organization>`'s management group scope.
- Federated identity credentials on app registrations and user-assigned MIs.

This policy does **not** cover:

- Guest (external) user identities or B2B collaboration users used for automation (these are also an anti-pattern and should be migrated — document as a separate finding).
- Service principals for Microsoft first-party applications (Microsoft 365 service principals) — these are managed by Microsoft and are excluded from the permission review cadence.

---

## Enforcement
|-----------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------|
| Credential type and lifetime restriction                        | Microsoft Graph `appManagementPolicies` — tenant default policy (`isEnabled: true`) + per-app override policies where stricter limits are needed. |
| Conditional Access for workload identities                      | Entra admin center > Protection > Conditional Access — policies scoped to service principal target with location and risk conditions. |
| Risky workload identity response                                | Identity Protection — `riskLevel` alerts → Sentinel analytic rule → SOC incident queue.                                         |
| Custom security attribute enforcement                           | Azure Policy (preview) or Graph-based attestation script run at provisioning.                                                   |
| Inventory review                                                | Quarterly automated Graph query (`GET /servicePrincipals?$filter=...`) exported to review queue.                               |
| Stale identity detection                                        | Monthly: Graph query for SPs with `signInActivity.lastSignInDateTime < [90 days ago]` and no standing PIM group membership.    |

---

## Workload Identity Maturity Indicators

Use these indicators at the quarterly governance review to assess whether the policy is being implemented effectively.

### Green — Policy Compliant

- Every service principal has ≥ 2 active owners.
- No client secrets older than 180 days exist anywhere in the tenant.
- Zero app registrations with `localhost` or HTTP redirect URIs in production.
- All new Azure-hosted workloads deployed in the quarter use managed identity.
- Service principal sign-in logs are flowing to Log Analytics with no gaps.
- Quarterly access review completed on schedule with zero outstanding decisions.

### Amber — Remediation in Progress

- One or more secrets exceed the 180-day limit but are actively being rotated (rotation ticket open).
- A Tier 1 or Tier 2 SP has no Conditional Access policy yet (Workload Identities Premium recently activated).
- Inventory is partially populated — migration in progress.

### Red — Non-Compliant

- Any secret over 365 days with no rotation in progress.
- Any app registration with no owner and no active investigation.
- Service principal sign-in logs not collected (no diagnostic settings configured).
- A service principal with subscription Owner RBAC has no approved exception on record.
- Admin consent granted to a privileged Graph permission without Identity Security review.

---

## Policy Implementation Phasing

Apply this policy in tiers to avoid breaking existing workloads.

**Phase 1 — Immediate (week 1):**
- Configure diagnostic settings for non-interactive and SP sign-in logs → Log Analytics.
- Run inventory query: identify all SPs with no owner, all secrets older than 180 days, and all SPs with privileged Graph permissions.
- Assign tiers (0–3) to the top 50 highest-value identities.

**Phase 2 — Governance baseline (weeks 2–6):**
- Assign ≥ 2 owners to all Tier 0 and Tier 1 SPs.
- Apply `appManagementPolicy` tenant default in report-only mode; review impact.
- Disable or decommission confirmed orphaned SPs (no sign-in in 180 days, no owner).

**Phase 3 — Enforced controls (weeks 7–12):**
- Enforce `appManagementPolicy` tenant default.
- Apply Conditional Access policies to all Tier 0 and Tier 1 SPs (requires Workload Identities Premium).
- Rotate all secrets older than 180 days.
- Begin converting CI/CD pipelines to federated credentials.

**Phase 4 — Steady state (ongoing):**
- Weekly Identity Protection risky workload identity review.
- Quarterly access reviews per cadence table.
- Monthly orphaned identity report and remediation.

---

## See Also

- `/Volumes/data/vscode/MyProjects/entra-nrt/kb/app-registrations/01-overview-essentials.md`
- `/Volumes/data/vscode/MyProjects/entra-nrt/kb/enterprise-apps/`
- `/Volumes/data/vscode/MyProjects/WorkloadIdentity/kb/02-governance/03-credential-and-secret-policy.md`
- `/Volumes/data/vscode/MyProjects/WorkloadIdentity/kb/02-governance/04-permission-assignment-policy.md`

## References
- https://learn.microsoft.com/en-us/entra/workload-id/workload-identities-overview
- https://learn.microsoft.com/en-us/graph/api/resources/appmanagementpolicy
- https://learn.microsoft.com/en-us/entra/identity/conditional-access/workload-identity
