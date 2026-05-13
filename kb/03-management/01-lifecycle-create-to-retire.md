# Workload Identity Lifecycle — Create to Retire

Every workload identity passes through six lifecycle stages. At each stage there are defined participants, controls, automation hooks, and evidence requirements. Skipping stages — particularly Retire — is the primary cause of orphaned identities.

---

## Stage Overview

```
 Request ──► Provision ──► Operate ──► Review ──► Renew ──► Retire
```

---

## Stage 1 — Request

**Purpose:** Validate the business need before any identity object is created.

**Who is involved:** Workload Owner (initiates); Application Administrator (reviews); Identity Security (approves for privileged permissions).

**Key controls:**
- Workload owner submits a request capturing: workload name, environment, required credential type, required permissions (Azure RBAC scopes and/or Graph permissions), justification, named primary and secondary owners, and expected workload end-of-life date.
- Identity Security reviews permissions — any Graph application permission or subscription-scope RBAC triggers a security review before approval.
- Naming convention and tagging requirements validated before provisioning is authorised.
- Exception process initiated here if the request breaches credential or permission policy.

**Automation hooks:**
- Request submitted via ITSM ticket or self-service portal with mandatory fields enforced.
- Automated pre-flight check: name format validation, duplicate identity detection, licence availability for Conditional Access / PIM features.

**Evidence captured:**
- Approved request ticket with approver name, date, permissions granted, and justification.
- Stored in ITSM / change record system linked to the workload identity's object ID.

---

## Stage 2 — Provision

**Purpose:** Create the identity object with correct configuration from day one.

**Who is involved:** Application Administrator or platform engineer (provisions via IaC); Workload Owner (verifies configuration); Subscription Owner (assigns RBAC).

**Key controls:**
- Provisioned via IaC (Bicep or Terraform) where possible — not manually via portal. Portal-only provisioning permitted only for small-scale or one-off cases; must be documented.
- Naming convention applied. Tags set at creation (ARM tags for user-assigned MI; Graph `tags` property for app registrations).
- Owners assigned to the app registration (≥ 2) before the identity is used.
- Credential type selected per the credential preference hierarchy: MI > FIC > certificate > secret.
- RBAC assigned at narrowest feasible scope. Admin consent granted by designated admin after Identity Security approval.
- Federated credential subjects set to exact match — no wildcards.
- Conditional Access policy applied if the workload holds privileged permissions (if Workload Identities Premium licence is available).
- Workload identity added to the central inventory at creation with all metadata populated.

**Automation hooks:**
- IaC pipeline linting: validate naming, tag completeness, RBAC scope before apply.
- Post-provision: automated scan confirms owners set, tags present, no secrets in pipeline state files.

**Evidence captured:**
- IaC commit / pull request record with reviewer approval.
- RBAC assignment and admin consent audit log entries.
- Inventory record created (object ID, display name, environment, owner, created date, credential type, permissions).

---

## Stage 3 — Operate

**Purpose:** The workload identity is in active use. Standard operations — monitoring, rotation, and owner maintenance — run continuously.

**Who is involved:** Workload Owner (day-to-day accountability); SOC (monitoring and alerts); Application Administrator (credential operations if needed).

**Key controls:**
- Sign-in logs streamed to Log Analytics / Sentinel. Alerts configured.
- Pre-expiry alerts fired at configured intervals (see Credential and Secret Policy).
- Conditional Access events (block / report-only) reviewed.
- Owner change: if primary owner leaves, secondary owner assumes primary responsibility and nominates a new secondary within 30 days.
- Any new credential additions, permission requests, or redirect URI changes go through the same approval process as initial provisioning.

**Automation hooks:**
- Pre-expiry alert automation (Logic App, Azure Monitor alert, or Key Vault near-expiry event) notifies owners.
- Anomalous sign-in alert fires to SOC queue.
- Identity Protection risk event triggers Sentinel incident.

**Evidence captured:**
- Sign-in logs (retained per log retention policy).
- Rotation events logged in ITSM.
- Alert acknowledgements and resolutions.

---

## Stage 4 — Review

**Purpose:** Periodic verification that the workload identity's permissions, owners, and credentials remain valid and least-privilege.

**Who is involved:** Workload Owner (reviews and attests); Identity Security (leads the review process and follows up on non-responses); Application Administrator (executes remediation).

**Key controls:**
- Quarterly access review for privileged identities (Entra ID Governance access review or manual review via Graph query).
- Semi-annual access review for standard identities.
- Review covers: RBAC assignments still needed and scoped correctly; Graph permissions still needed; owners still active employees; credentials within policy limits; no unexplained sign-in activity.
- Non-response by Workload Owner within 14 days → escalate to their manager; within 30 days → Identity Security auto-remediates (disables the identity and notifies Governance Board).

**Automation hooks:**
- Entra ID Governance access review auto-generates review tasks.
- Graph query export: `GET /servicePrincipals?$filter=...&$select=id,displayName,signInActivity,owners,appRoleAssignments` for identities without Entra Governance licence coverage.

**Evidence captured:**
- Completed access review report (reviewer, decision, date).
- ITSM ticket for any remediation actions.

---

## Stage 5 — Renew

**Purpose:** Extend or update the workload identity as the workload evolves — new permissions, new credentials, or new federated credential subjects.

**Who is involved:** Workload Owner (requests change); Application Administrator (executes); Identity Security (approves if permissions are being escalated).

**Key controls:**
- Permission escalation (adding a new privilege) follows the same approval process as initial provisioning.
- Permission reduction (removing a privilege the workload no longer needs) is encouraged and does not require a security review — only Workload Owner authorisation.
- Federated credential subject changes (e.g., repository renamed, Kubernetes namespace changed) require Workload Owner approval and are logged.
- Any expansion beyond originally approved scope is treated as a new request.

**Automation hooks:**
- Alert on credential or permission change (audit log event) — auto-notifies Identity Security.

**Evidence captured:**
- Change record / ITSM ticket for each renewal.
- Updated inventory record.

---

## Stage 6 — Retire

**Purpose:** Safely decommission the workload identity when the workload is retired or replaced.

**Who is involved:** Workload Owner (initiates and signs off); Application Administrator (executes decommission); Subscription Owner (removes RBAC); Identity Security (verifies clean-up).

**Key controls:**
- Decommission checklist (below) must be completed and signed off before closure.
- Retired identities are not repurposed — create a new identity for any new workload.
- Evidence of decommission retained for 12 months.

**Automation hooks:**
- Azure resource deletion triggers automated notification to check for associated system-assigned MI in RBAC.
- Decommission ticket creation on workload retirement event (if ITSM integration is in place).

---

## Decommission Checklist

Complete all steps. Check off each item in the ITSM ticket before closing.

- [ ] Identify all RBAC assignments held by the workload identity → list in the ticket.
- [ ] Remove all Azure RBAC assignments (resource, resource group, and subscription scope).
- [ ] Remove all app role assignments (application-to-application permissions) from the service principal.
- [ ] Remove all Microsoft Graph admin consent grants (delegated and application) from the service principal.
- [ ] Revoke and delete all client secrets from the app registration.
- [ ] Delete all certificate credentials from the app registration.
- [ ] Delete all federated identity credentials from the app registration or user-assigned MI.
- [ ] Delete the user-assigned MI ARM resource (if applicable) — confirm soft-delete / purge behaviour if applicable.
- [ ] Delete the app registration (this deletes the home-tenant service principal). For guest-tenant SPs, remove from the guest tenant first.
- [ ] Remove the workload identity from the central inventory (or mark as retired with decommission date).
- [ ] Notify all dependent teams that the identity has been decommissioned (avoid downstream break).
- [ ] Verify sign-in logs show no activity post-decommission (check after 24 hours).
- [ ] Archive sign-in logs for the identity for 12 months.
- [ ] Close ITSM ticket with decommission sign-off from Workload Owner and Identity Security.

---

## References
- https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/what-is-application-management
- https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/managed-identity-best-practice-recommendations
- https://learn.microsoft.com/en-us/entra/id-governance/access-reviews-overview
