# Ownership & Accountability (RACI)

Clear ownership is the foundation of workload identity governance. Without a named, accountable owner, a workload identity accumulates permissions, stale credentials, and eventually becomes an orphan that nobody can safely decommission. This document defines who is responsible, accountable, consulted, and informed for each workload identity activity.

---

## RACI Matrix

**Key:** R = Responsible (does the work) | A = Accountable (owns the outcome) | C = Consulted (input required) | I = Informed (notified of outcome)

| Activity                                           | Workload Owner | App Admin / Cloud App Admin | Identity Security | Subscription Owner | SOC  | Governance Board |
|----------------------------------------------------|----------------|-----------------------------|-------------------|--------------------|------|------------------|
| Create app registration                            | R              | A                           | C                 | –                  | –    | –                |
| Create user-assigned managed identity              | R              | C                           | C                 | A                  | –    | –                |
| Enable system-assigned managed identity on resource| R              | –                           | –                 | A                  | –    | –                |
| Configure federated identity credential            | R              | C                           | C                 | –                  | –    | –                |
| Request admin consent (Graph permission)           | R              | –                           | A                 | –                  | –    | –                |
| Grant admin consent (Graph permission)             | –              | R/A                         | C                 | –                  | I    | –                |
| Assign Azure RBAC to workload identity             | R              | –                           | C                 | A                  | –    | –                |
| Assign privileged Azure RBAC (Owner / UAA)         | –              | –                           | C                 | A                  | I    | C                |
| Add credential (secret or certificate)             | R              | A                           | I                 | –                  | –    | –                |
| Rotate credential (scheduled)                      | R              | C                           | –                 | –                  | –    | –                |
| Rotate credential (incident / suspected compromise) | R              | C                           | A                 | –                  | R    | I                |
| Review and respond to risky workload identity alert | –             | C                           | R/A               | –                  | R    | I                |
| Respond to SP anomalous sign-in alert              | –              | –                           | C                 | –                  | R/A  | –                |
| Conduct quarterly access review                    | R              | –                           | A                 | C                  | –    | –                |
| Decommission workload identity                     | R              | C                           | C                 | A                  | –    | I                |
| Approve policy exception                           | R (requests)   | –                           | C                 | –                  | –    | A                |
| Maintain workload identity inventory               | C              | R                           | A                 | –                  | –    | –                |
| Approve multi-tenant app registration              | R (requests)   | C                           | C                 | –                  | –    | A                |
| Approve privileged Graph permission exception      | R (requests)   | C                           | R                 | –                  | –    | A                |

---

## Role Definitions

### Workload Owner

The individual or team that owns the application or pipeline the workload identity serves. Accountable for the business need, the permissions requested, and the decommissioning of the identity when the workload is retired. In practice this is usually a development team lead, a platform engineer, or a business application owner.

**Must:** assign ≥ 2 named owners on the app registration or MI; maintain the accuracy of inventory metadata; initiate decommissioning when a workload is retired; respond to governance review requests within the agreed SLA (default: 14 days).

### Application Administrator / Cloud App Administrator

An Entra role holder responsible for administering app registrations and enterprise applications in the tenant. In a well-governed tenant this role is PIM-eligible only (no standing assignment) and all activations are logged. The Application Administrator can create app registrations, manage credentials, and grant admin consent. Cloud App Administrator has the same permissions except it cannot manage on-premises app proxy.

**Must:** ensure every app registration created has ≥ 2 owners and a naming-convention-compliant display name; enforce the credential policy at creation; alert Identity Security when an exception to policy is needed.

### Identity Security

The identity security team (or individual) responsible for the security posture of all identities in the tenant. This is typically the IAM security architect or the equivalent role within the organisation's security function.

**Must:** review and approve admin consent requests for privileged permissions; lead the quarterly access review process; review risky workload identity alerts; maintain the workload identity governance policy; approve or reject exception requests with documented rationale.

### Subscription Owner

The Azure subscription owner or platform engineering team responsible for the Azure environment in which workloads run. Accountable for Azure RBAC assignments at the subscription and resource group scope.

**Must:** ensure managed identities are used for new Azure-hosted workloads; review RBAC assignments quarterly; approve and document any subscription-scope RBAC exception.

### SOC (Security Operations Centre)

The team responsible for detecting and responding to security incidents. Receives and triages alerts from Sentinel / SIEM, investigates anomalous workload identity sign-ins, and initiates containment for confirmed compromised identities.

**Must:** respond to SP sign-in anomaly alerts within the agreed SLA (default: 4 hours for high-severity); escalate confirmed compromises to Identity Security; preserve evidence before revoking credentials.

### Governance Board

The body (committee or individual) that has authority to approve exceptions to this policy and to adjudicate on cross-team disputes. Membership typically includes CISO (or delegate), Identity Security lead, and a business technology representative.

**Must:** convene within 5 business days for exception requests; document decisions with rationale; review exception register quarterly.

---

## What Good Owners Do — Checklist

Workload owners should be able to confirm all of the following at any quarterly review:

- [ ] I can name at least two people (including myself) who are owners of this workload identity.
- [ ] The workload identity's display name follows the naming convention.
- [ ] I know which permissions (Graph and/or Azure RBAC) this workload identity holds and can justify each one.
- [ ] There are no client secrets on this workload identity that I did not create or are not rotated within the last 180 days.
- [ ] The workload identity's credentials are not stored in source code, pipeline variables, or any location other than Azure Key Vault.
- [ ] I have received (and acted on) any pre-expiry alerts for credentials on this workload identity.
- [ ] I know what this workload identity signs in to and approximately how often.
- [ ] If this workload identity became compromised tomorrow, I know who to call and what to revoke.
- [ ] If this workload is being decommissioned, I have initiated the decommission checklist.

---

## Escalation and Dispute Resolution

When a Workload Owner disagrees with an access review decision or an Identity Security remediation:

1. **Workload Owner raises a dispute** with Identity Security within 5 business days of the decision.
2. **Identity Security and Workload Owner** agree on a resolution or escalate to the Governance Board within 3 business days.
3. **Governance Board** makes a final binding decision within 5 business days.
4. The identity remains in its restricted state (disabled or reduced permission) until the dispute is resolved, unless the Governance Board explicitly grants a temporary exception.

---

## Owner Departure — Responsibilities Transfer

When a Workload Owner leaves the organisation, the following steps apply within 30 days:

1. The departing owner's manager nominates a replacement primary owner.
2. The replacement owner is added to the app registration owners list.
3. The departing owner is removed from the owners list.
4. If no replacement can be identified: Identity Security designates a custodian and flags the workload identity as "at-risk orphan" in the inventory.
5. All client secrets on the workload identity are rotated within 30 days of the owner change.

---

## What Good Owners Do — Checklist

Workload owners should be able to confirm all of the following at any quarterly review:

- [ ] I can name at least two people (including myself) who are owners of this workload identity.
- [ ] The workload identity's display name follows the naming convention.
- [ ] I know which permissions (Graph and/or Azure RBAC) this workload identity holds and can justify each one.
- [ ] There are no client secrets on this workload identity that I did not create or are not rotated within the last 180 days.
- [ ] The workload identity's credentials are not stored in source code, pipeline variables, or any location other than Azure Key Vault.
- [ ] I have received (and acted on) any pre-expiry alerts for credentials on this workload identity.
- [ ] I know what this workload identity signs in to and approximately how often.
- [ ] If this workload identity became compromised tomorrow, I know who to call and what to revoke.
- [ ] If this workload is being decommissioned, I have initiated the decommission checklist.

---

## Inventory Freshness Requirements

The workload identity inventory must be updated:

- **At creation** — record added by the provisioning workflow before the identity is used.
- **On any permission change** — record updated within 1 business day of the change.
- **On owner change** — record updated immediately.
- **On decommission** — record marked retired with decommission date and ticket reference.
- **At quarterly review** — all records attested as current by the Application Administrator.

Stale inventory records (not verified in the last 90 days) are treated as unverified and escalated to Identity Security for manual validation.

---

## See Also

- `/Volumes/data/vscode/MyProjects/entra-nrt/kb/app-registrations/17-owners.md`
- `/Volumes/data/vscode/MyProjects/WorkloadIdentity/kb/02-governance/06-exception-process.md`
- `/Volumes/data/vscode/MyProjects/WorkloadIdentity/kb/03-management/01-lifecycle-create-to-retire.md`

## References
- https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/permissions-reference
- https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/what-is-application-management
- https://learn.microsoft.com/en-us/entra/id-governance/privileged-identity-management/pim-configure
