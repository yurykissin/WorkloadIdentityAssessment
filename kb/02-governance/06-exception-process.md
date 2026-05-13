# Exception Process

Governance policies are designed to be the default — not the ceiling. Where a workload cannot meet a policy requirement, this exception process provides a controlled, time-limited, and compensating-control-backed alternative to silent non-compliance.

---

## When an Exception Is Needed

An exception is required whenever a workload identity cannot meet a policy requirement and will knowingly operate outside it. Common scenarios include:

- **Client secret required** — the target API or platform (typically a third-party SaaS) does not support certificate authentication or federated credentials; only a client secret is accepted.
- **Broad Graph permission unavoidable** — the required capability genuinely has no narrower permission (e.g., Microsoft does not publish a resource-specific consent scope for the required operation).
- **Subscription-scope RBAC** — the workload must deploy resources across multiple resource groups and scoping at resource group level is operationally infeasible.
- **Permanent assignment instead of PIM** — PIM activation time or token caching behaviour would cause the workload to fail SLA requirements.
- **Long-lived credential** — external platform or partner SLA requires a secret or certificate valid longer than the standard maximum.
- **No owner assignable** — a workload identity has no identifiable owner (e.g., inherited from a departed team); a custodian is assigned instead, and the exception documents the migration plan.

---

## Exception Request Template

Complete all fields. Incomplete requests are returned to the requestor without review.

| Field                    | Content                                                                                       |
|--------------------------|-----------------------------------------------------------------------------------------------|
| Requestor name           | `<name>`                                                                                      |
| Requestor team / BU      | `<team>`                                                                                      |
| Date of request          | YYYY-MM-DD                                                                                    |
| Workload name            | `<workload-name>` (must match inventory entry)                                                |
| Workload identity object | App registration / SP / user-assigned MI object ID: `<object-id>`                            |
| Policy clause breached   | Reference exact policy table row (e.g., "Credential and Secret Policy — Client secret maximum lifetime") |
| Current behaviour        | Describe what the workload is doing that breaches the policy.                                 |
| Reason policy cannot be met | Explain the technical or business constraint. Attach evidence (vendor documentation, architecture diagram). |
| Compensating controls    | List each compensating control that mitigates the residual risk (see Compensating Control Library). |
| Requested exception expiry | YYYY-MM-DD — maximum 12 months; shorter terms preferred.                                    |
| Review date              | YYYY-MM-DD — exception reviewed at this date (minimum quarterly for critical policy breaches).|
| Approver                 | Governance Board (or delegated approver per the RACI matrix).                                 |
| Approval status          | Pending / Approved / Rejected / Approved with conditions                                      |
| Conditions imposed       | Any conditions the Governance Board attached to the approval.                                 |

---

## Compensating Control Library

When the standard control cannot be applied, the following compensating controls are available. Select those that apply to the specific exception scenario. More than one is expected for high-risk exceptions.

| Policy Waiver                                      | Required Compensating Controls                                                                                                                    |
|----------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------|
| Client secret in use (instead of MI / FIC)         | 90-day rotation schedule; Key Vault storage; Key Vault access log alerting on unexpected access; Conditional Access policy applied to the SP.      |
| Secret lifetime > 180 days                         | Key Vault storage mandatory; rotation triggered immediately on any owner change; pre-expiry alert at 30/14/7/1 days; justified business case on file. |
| Certificate lifetime > 24 months                   | Key Vault auto-renewal configured; expiry monitoring mandatory; HSM storage of private key.                                                       |
| Broad Graph permission (e.g., `User.ReadWrite.All`)| Conditional Access policy applied (location-restrict); quarterly recertification in access review; sign-in alert in Sentinel; service principal monitored as Tier-0 asset. |
| Subscription-scope Contributor                     | PIM-eligible only — no standing assignment; quarterly recertification; alert on every activation and use.                                         |
| Subscription-scope Owner                           | PIM-eligible, maximum 4-hour activation; dual-approval required; every activation reviewed by Identity Security; quarterly recertification.       |
| User Access Administrator standing assignment      | Not permissible under any compensating control. Convert to PIM-eligible.                                                                          |
| Multi-tenant app registration (broad audience)     | Verified publisher required; permissions documented; customer tenant consent reviewed; annual customer notification.                               |
| No owner assignable                                | Custodian assigned (documented); migration plan to assign a real owner within 90 days; inventory flagged as "at-risk orphan".                      |
| Permanent PIM assignment (no JIT)                  | Sign-in alerting for every activation; quarterly recertification mandatory; Conditional Access applied.                                            |

---

## Exception Review Cadence

| Exception risk level                       | Review cadence                                |
|--------------------------------------------|-----------------------------------------------|
| Critical policy breach (privilege / secret) | Monthly review until mitigated; quarterly recertification while active |
| High-risk breach (broad permission / subscription RBAC) | Quarterly recertification                |
| Standard breach (certificate lifetime, non-PIM) | Semi-annual review                        |
| All exceptions                             | Automatically expire on the approval date — must be explicitly renewed |
| Exception not renewed by expiry date       | Workload flagged as non-compliant; escalated to Governance Board        |

---

## Exception Register

Maintain this register as a living document. Review at each Governance Board meeting.

| ID    | Workload Name      | Object ID       | Policy Clause Breached                       | Compensating Controls Applied                    | Exception Expiry | Approver       | Status   |
|-------|--------------------|-----------------|----------------------------------------------|--------------------------------------------------|------------------|----------------|----------|
| EX-001 | `<workload-name>` | `<object-id>`  | `<policy clause>`                             | `<controls>`                                     | YYYY-MM-DD       | `<approver>`   | Active   |
| EX-002 | `<workload-name>` | `<object-id>`  | `<policy clause>`                             | `<controls>`                                     | YYYY-MM-DD       | `<approver>`   | Active   |
| EX-003 | `<workload-name>` | `<object-id>`  | `<policy clause>`                             | `<controls>`                                     | YYYY-MM-DD       | `<approver>`   | Expired  |

---

## Approval Authority Delegation

| Exception type                                        | Minimum approver                          |
|-------------------------------------------------------|-------------------------------------------|
| Standard credential exception (short-lived secret, cert lifetime) | Identity Security lead          |
| Privileged Graph permission exception                 | Governance Board (CISO quorum)            |
| Subscription-scope Owner/UAA assignment               | Governance Board                          |
| Multi-tenant app registration                         | Governance Board                          |
| No owner / custodian arrangement                      | Identity Security lead + Subscription Owner |
| Any exception where compensating controls are not in the library | Governance Board              |

---

## Exception Governance Integration

Exception records feed into these downstream governance processes:

- **Quarterly Governance Board review** — the exception register is a standing agenda item. Expired exceptions that were not renewed are escalated.
- **Access review integration** — workload identities with active exceptions are tagged in the access review queue so reviewers can apply heightened scrutiny.
- **Incident response** — in a workload identity compromise, the incident response team reviews the active exception register first. Exceptions with weak compensating controls are the most likely root cause.
- **Annual policy review** — exception patterns (what is being excepted, how often) inform the next policy revision cycle. High exception frequency for a specific clause signals either an unclear policy or a capability gap.

---

## Exception Process SLA

| Milestone                                         | Target SLA                                           |
|---------------------------------------------------|------------------------------------------------------|
| Initial triage of submitted exception request     | 1 business day                                       |
| Identity Security assessment complete             | 3 business days                                      |
| Governance Board decision (for Board-level items) | 5 business days from Identity Security escalation    |
| Exception register updated post-decision          | 1 business day after decision                        |
| Requestor notified of decision                    | Same day as decision                                 |
| Compensating controls verified in place           | Within 5 business days of approval                  |
| Exception record closed (post-expiry)             | 5 business days after expiry date                    |

---

## Frequently Approved vs Rarely Approved Exceptions

| Exception Type                                    | Frequency in Practice | Notes                                                              |
|---------------------------------------------------|-----------------------|--------------------------------------------------------------------|
| Client secret for third-party SaaS (no cert support) | Common             | Approve with 90-day rotation and Key Vault storage requirement.    |
| Secret lifetime > 180 days for partner integration | Occasional          | Require explicit partner timeline for cert/FIC migration.         |
| Subscription-scope Contributor for deployment SP  | Occasional           | Require scope-down plan; time-limit the exception.               |
| `Directory.ReadWrite.All` for synchronisation tool | Rare               | Require monthly recertification and CA policy before approval.    |
| Permanent PIM assignment (no JIT)                 | Rarely approved       | Almost never justified for workload identities; push back hard.   |
| No owner assignable                               | Rare                  | Approve only with custodian assigned and active migration plan.   |

---

---

## Related Governance Documents

This exception process operates within the broader workload identity governance framework. Refer to these documents when processing an exception:

- **What the policy requires:** `/Volumes/data/vscode/MyProjects/WorkloadIdentity/kb/02-governance/02-workload-identity-policy.md`
- **Credential-specific rules:** `/Volumes/data/vscode/MyProjects/WorkloadIdentity/kb/02-governance/03-credential-and-secret-policy.md`
- **Permission-specific rules:** `/Volumes/data/vscode/MyProjects/WorkloadIdentity/kb/02-governance/04-permission-assignment-policy.md`
- **Who approves what (RACI):** `/Volumes/data/vscode/MyProjects/WorkloadIdentity/kb/02-governance/05-ownership-and-accountability.md`

---

## References
- https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/configure-app-credential-policy
- https://learn.microsoft.com/en-us/entra/workload-id/workload-identities-overview
- https://learn.microsoft.com/en-us/entra/id-governance/privileged-identity-management/pim-configure
