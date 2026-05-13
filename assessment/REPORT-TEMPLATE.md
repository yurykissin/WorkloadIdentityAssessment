# Workload Identity Assessment — `<customer>` `<date>`

> Fill in during the working session. Each section maps to the corresponding question block in `../kb/00-call-prep/01-discovery-questions.md`. For data-driven answers, cite the evidence file from `output/<ts>/`. For conversational answers, capture the substance verbatim where useful.

## Engagement metadata

| Field | Value |
|-------|-------|
| Customer | |
| Date | |
| Attendees | |
| Tenant ID | |
| Subscriptions in scope | |
| Evidence run timestamp | `output/<YYYYMMDD-HHMMSS>/` |
| Consultant | |

---

## §1. Current State

Headline numbers (from `02-inventory.csv` + `01-tenant-context.json`):

| Metric | Value |
|--------|-------|
| App registrations | |
| Enterprise apps (service principals, all tiers) | |
| Managed identities (system-assigned) | |
| Managed identities (user-assigned) | |
| App regs with no owner | |
| App regs with a single owner | |
| Application Administrator role holders | |
| Cloud Application Administrator role holders | |
| "Users can register applications" setting | |
| Admin consent workflow enabled | |
| Multi-tenant app registrations | |

Conversational findings:

- Who creates app registrations:
- Approval process:
- Past clean-up exercises:
- User accounts used as service accounts:
- Guest users as service identities:

---

## §2. Workload Inventory

| Metric | Value |
|--------|-------|
| Workloads using managed identity | |
| Federated identity credentials configured (app reg) | |
| Federated identity credentials configured (user-assigned MI) | |
| GitHub Actions OIDC issuer present | |
| Azure DevOps OIDC issuer present | |
| Third-party / external OIDC issuers present | |
| Multi-tenant app registrations | |
| Third-party SaaS with admin consent | |

Conversational findings:

- On-prem workloads to Entra APIs:
- Non-Azure cloud workloads:
- AKS workloads / Workload Identity add-on adoption:
- ADF / Synapse / Logic Apps with external auth:
- APIM backend auth:
- Azure Arc with MI:

---

## §3. Sensitivity & Risk

From `05-permission-surface.csv`:

| Metric | Value |
|--------|-------|
| SPs with privileged Graph application permissions (Directory.ReadWrite.All, RoleManagement.ReadWrite.Directory, Application.ReadWrite.All, etc.) | |
| SPs with subscription Owner | |
| SPs with subscription Contributor | |
| SPs with User Access Administrator (any scope) | |

From `03-credential-hygiene.csv`:

| Metric | Value |
|--------|-------|
| Secrets older than 12 months still active | |
| Secrets older than 24 months still active | |
| Expired credentials still on app registrations (dead weight) | |

From `04-federated-credentials.csv`:

| Metric | Value |
|--------|-------|
| Federated credentials with WILDCARD subject | |
| Federated credentials with BROAD subject (e.g., env-less repo:owner/repo) | |

Conversational findings:

- Access to PII / financial / health data:
- Past compromised SP incidents:
- Plain-text secrets in code / config (customer assessment):
- Highest blast-radius workload (jointly identified):
- Formal sensitivity classification today:

---

## §4. Lifecycle & Ownership

From `06-stale-and-orphaned.csv`:

| Metric | Value |
|--------|-------|
| SPs with no sign-in in 90 days | |
| SPs with no sign-in in 365 days | |
| SPs with no assigned owner | |
| App regs with no tags (CMDB linkage gap) | |
| SPs owned by users no longer in the directory (truly orphaned) | |

Conversational findings:

- Owner replacement on developer departure:
- Offboarding process (contractor / partner credentials):
- CMDB / cost-centre linkage:
- Active vs retired tracking mechanism:
- Project-end decommission process:
- MI lifecycle policy:
- RBAC cleanup on resource delete:
- Max permitted no-sign-in age:

---

## §5. Secrets Hygiene

From `03-credential-hygiene.csv`:

| Metric | Value |
|--------|-------|
| Median secret lifetime (months) | |
| Max secret lifetime found (months) | |
| Cert credentials vs password credentials (ratio) | |
| Multi-credential SPs (>2 active creds) | |

From `07-monitoring-coverage.json` (Key Vault scan):

| Metric | Value |
|--------|-------|
| Key Vaults in scope | |
| Key Vaults using RBAC authorization | |
| Key Vaults using legacy access policies | |
| Key Vaults with soft-delete enabled | |
| Key Vaults with purge protection enabled | |

Conversational findings:

- Defined rotation schedule:
- Key Vault adoption for workload secrets:
- Secret scanning in source control:
- Secrets found in code/logs (past 12 mo):
- Pre-expiry notification process:
- Centralised credential inventory:
- Third-party vault bypass:

---

## §6. Permission Hygiene

From `05-permission-surface.csv`:

| Metric | Value |
|--------|-------|
| Average # of Graph application permissions per SP | |
| Max # of Graph application permissions on a single SP | |
| SPs with Azure RBAC at subscription scope | |
| SPs with Azure RBAC at management group scope | |
| SPs with custom Entra role assignments | |
| App role assignments granted to SPs (count) | |

Conversational findings:

- Graph app permission request / approval process:
- Approved permission catalogue exists:
- RBAC review cadence:
- App role assignment review cadence:
- Cross-tenant access policy:
- Permission creep detection:

---

## §7. Monitoring & Detection

From `07-monitoring-coverage.json`:

| Metric | Value |
|--------|-------|
| Sign-in logs → Log Analytics | yes / no |
| Sign-in logs → Storage | yes / no |
| Sign-in logs → Event Hub / SIEM | yes / no |
| Sign-in logs retention (days) | |
| Audit logs → Log Analytics | yes / no |
| Sentinel deployed (workspace + SecurityInsights solution present) | yes / no |
| Workload Identities Premium licensed | yes / no |
| Identity Protection enabled | yes / no |

From `08-ca-for-workload-identities.csv`:

| Metric | Value |
|--------|-------|
| CA policies targeting workload identities | |
| Of which: enabled | |
| Of which: report-only | |
| Workload identities covered by at least one CA policy | |

Conversational findings:

- SP sign-in anomaly alerts in place:
- SP sign-in alert response owner:
- Alerts on new credentials added:
- Alerts on new admin consent:
- FIC change review process:
- Defender for Cloud MI recommendations reviewed:

---

## §8. Tooling & Automation

Conversational findings (cross-check against §1 inventory for "no tags / no description" anomalies):

- IaC in use (Bicep / Terraform / AzAPI / Microsoft.Graph extension):
- Microsoft Graph PowerShell SDK in use:
- Azure RBAC automated or manual:
- Azure Policy for MI enforcement:
- Automated credential rotation:
- Consistent tagging:
- Resource Graph / MS Graph queries for inventory:
- Secret-scanning gate in CI:
- GitOps / policy-as-code for IaC:

---

## §9. Compliance & Regulatory

Conversational only:

- Regulatory frameworks in scope:
- Current audit findings related to workload ID:
- Evidence required by auditors:
- Data residency constraints:
- Separation of duties:
- JIT requirement for privileged ops:
- Access review documentation as control evidence:
- Risk acceptance / exception process:
- Non-human identity lifecycle in InfoSec policy:

---

## §10. Future State Goals

Conversational only:

- 12-month vision of "good":
- Secret elimination target:
- Self-service developer experience:
- Centralised dashboard ambition:
- CA for workload identities as near-term control:
- Lifecycle automation in scope:
- PIM for Groups adoption plan:
- Governance maturity target (reactive / proactive / automated):
- Owning team post-engagement:
- Single biggest pain point to resolve:

---

## §11. Prioritized Remediation Backlog

| # | Item | Why now (impact + finding) | Effort | Owner | Target date | Maps to policy section |
|---|------|----------------------------|--------|-------|-------------|------------------------|
| 1 | | | | | | |
| 2 | | | | | | |
| 3 | | | | | | |
| 4 | | | | | | |
| 5 | | | | | | |
| 6 | | | | | | |
| 7 | | | | | | |
| 8 | | | | | | |

## §12. Open questions / parking lot

- 
- 

## §13. Next session

| Field | Value |
|-------|-------|
| Date | |
| Attendees needed | |
| Pre-work for customer | |
| Pre-work for consultant | |
