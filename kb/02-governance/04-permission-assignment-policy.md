# Permission Assignment Policy

Over-privileged workload identities are the single largest contributing factor to the blast radius of a workload identity compromise. This policy requires that every permission assignment — Azure RBAC, Microsoft Graph application permission, or app role assignment — be scoped to the minimum necessary, reviewed on a regular cadence, and approved before assignment.

Path to configure:
```
Azure portal > <resource> > Access control (IAM) > Role assignments
Microsoft Entra admin center > Identity > Applications > Enterprise applications > <app> > Permissions
Microsoft Entra admin center > Identity > Enterprise applications > App role assignments
Microsoft Graph > servicePrincipals/<id>/appRoleAssignments
```

---

## Policy Table

| Policy / Setting                                              | Required Value                                                                                                                                                        |
|---------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Azure RBAC assignment scope                                   | **Narrowest scope that satisfies the workload requirement**: resource > resource group > subscription > management group. Start at the resource level; escalate only if technically required. |
| Azure RBAC — Owner at subscription scope                      | **Not allowed** for workload identities (managed identities or service principals) unless a documented exception is approved. Quarterly recertification required.     |
| Azure RBAC — Contributor at subscription scope                | **Approved exception only.** Scope down to resource group at the next governance review cycle. Document why subscription scope is required.                          |
| Azure RBAC — User Access Administrator                        | **Approved exception only.** PIM-eligible only — no standing assignment. Maximum activation duration: 8 hours. Time-limited assignment: maximum 90 days.             |
| Azure RBAC assignment lifecycle                               | **Reviewed quarterly** for workload identities. Assignments with no recent usage evidence (Azure resource activity log) must be justified or removed.                |
| Microsoft Graph application permissions                       | **Least-privilege** — select the narrowest scope that satisfies the workload. Admin consent required. Identity Security review required before consent.              |
| Microsoft Graph — admin consent process                       | **Formal approval required**: workload owner requests → Identity Security reviews → designated admin consents. Decision documented in change record.                 |
| Privileged Graph application permissions                      | **Approved exception only.** See Privileged Graph Permissions reference below. Quarterly recertification. Conditional Access policy applied to the SP.               |
| Graph delegated permissions                                   | **Not used for workload identities.** Client credentials flow (workload identity) must use application permissions, not delegated scopes.                            |
| App role assignments (application-to-application)             | **Reviewed quarterly** for any SP that receives app roles on sensitive application APIs. Assignments not renewed in the review cycle are revoked.                    |
| Cross-tenant access                                           | **Documented** — all cross-tenant permission grants recorded. Cross-tenant access settings in both the source and target tenant reviewed quarterly.                  |
| Custom Entra roles for workload identity management           | **Preferred over built-in privileged roles** (Application Administrator, Cloud App Administrator) where a custom role provides the minimum necessary permissions.   |
| Built-in privileged Entra roles assigned to service principals | **Approved exception only.** PIM-eligible only; no standing assignment.                                                                                             |
| Permission change notification                                | **Alert generated** on every new RBAC assignment, app role assignment, or Graph permission grant involving a workload identity.                                       |
| Inherited vs direct assignments                               | **Direct RBAC assignments preferred** over broad inherited assignments from management group scope for individual workloads.                                          |

---

## Privileged Graph Permissions Reference

The following Graph application permissions are frequently over-granted. This sub-section documents what they allow, the risk they carry, and what to use instead.

| Permission                             | What it allows                                                                 | Risk               | Use instead                                                          |
|----------------------------------------|--------------------------------------------------------------------------------|--------------------|----------------------------------------------------------------------|
| `Directory.ReadWrite.All`              | Read and write all directory objects — users, groups, applications, roles, devices | Critical — tenant takeover | `User.Read.All` (read users only); `Group.ReadWrite.All` (groups only) |
| `RoleManagement.ReadWrite.Directory`   | Create / modify / delete Entra role assignments — including Global Admin       | Critical — privilege escalation | `RoleManagement.Read.Directory` if read-only is sufficient          |
| `Application.ReadWrite.All`            | Create, update, delete any app registration; add credentials                   | Critical — credential injection | `Application.Read.All` for read; avoid write unless essential       |
| `AppRoleAssignment.ReadWrite.All`      | Grant and revoke app roles for any service principal                           | High — permission escalation | Avoid; use admin process for individual app role grants             |
| `Mail.ReadWrite` (application)         | Read and write all mail in all mailboxes in the tenant                         | High — data exfiltration | `Mail.Send` (send only); `Mail.Read` + resource-specific access    |
| `Files.ReadWrite.All` (application)    | Read and write all files in all SharePoint sites and OneDrive                  | High — data exfiltration | `Sites.Selected` (scoped to specific site collections)             |
| `User.ReadWrite.All`                   | Update all user profiles, including resetting passwords via Graph              | High               | `User.Read.All` if read-only; `User.EnableDisableAccount.All` if specific |
| `GroupMember.ReadWrite.All`            | Add/remove members from all groups, including privileged groups                | High               | `Group.Read.All` if read-only; target specific group if write needed|
| `Policy.ReadWrite.ConditionalAccess`   | Create and modify Conditional Access policies                                  | High               | Avoid; use admin process for CA changes                             |
| `PrivilegedAccess.ReadWrite.AzureAD`   | Manage PIM assignments for Entra roles                                         | Critical           | Avoid; use PIM UI or dedicated governance tooling                   |

**Governance rule:** Any SP holding a permission marked "Critical" above must have a Conditional Access policy applied (location-restrict minimum), quarterly recertification in the access review cycle, and sign-in alerts configured in Sentinel.

---

## Scope and Applicability

This policy applies to all workload identities in `<organization>`'s Entra tenant and Azure subscriptions, specifically:

- All Microsoft Graph application permissions granted to service principals via admin consent.
- All Azure RBAC assignments where the principal is a service principal or managed identity.
- All app role assignments (application-to-application authorisation) where the assignee is a service principal.
- Cross-tenant permission grants and cross-tenant access settings.

This policy does not cover delegated (user-context) permissions used by user-facing applications — those are governed by the user identity access management policy.

---

## Permission Request and Approval Process

When a workload owner needs a new permission:

1. **Workload Owner submits a request** via the ITSM system, specifying:
   - The service principal (name + object ID).
   - The permission requested (Graph scope name, or RBAC role + scope path).
   - The business justification (what the workload does with this permission).
   - The data classification of information the permission provides access to.
   - Alternative narrower permissions considered and why they were ruled out.

2. **Identity Security reviews** the request:
   - Validates least-privilege (is there a narrower option?).
   - Checks for existing over-permission on the same SP.
   - For privileged permissions: reviews with reference to the Privileged Graph Permissions table below.
   - Approves, rejects, or requests narrowing.

3. **Designated Application Administrator grants consent** (for Graph permissions) or **Subscription Owner assigns the role** (for Azure RBAC), after Identity Security approval is confirmed in the ITSM record.

4. **Evidence of the grant** is retained in the ITSM record linked to the SP object ID.

5. **Quarterly access review** verifies the permission is still needed.

---

## Enforcement

| Control                                                        | Enforcement Mechanism                                                                                              |
|----------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------|
| RBAC scope enforcement                                         | Azure Policy — deny role assignments above resource group scope for specified roles, or require approval workflow.  |
| Privileged RBAC PIM-eligible requirement                       | PIM for Azure Resources — configure User Access Administrator and Owner as eligible-only at subscription scope.    |
| Admin consent gate                                             | Entra admin consent workflow — all consent requests routed to Identity Security reviewer queue.                    |
| Quarterly RBAC access review                                   | Entra ID Governance — access review on Azure RBAC assignments for service principals (requires Governance / P2).   |
| Quarterly app role assignment review                           | Entra ID Governance — access review on app role assignments to service principals.                                 |
| New permission assignment alert                                | Log Analytics alert on audit event `Add delegated permission grant` and `Add app role assignment to service principal`. |

---

## Permission Review — Evidence Requirements

For each quarterly access review, the reviewer must capture the following evidence in the ITSM ticket:

| Evidence Item                                          | Where to Find It                                                              |
|--------------------------------------------------------|-------------------------------------------------------------------------------|
| RBAC assignment list for the SP                        | `az role assignment list --assignee <sp-object-id>` or Azure portal IAM blade |
| Graph app role assignments for the SP                  | `Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId <id>`           |
| Last sign-in date for the SP                           | Entra sign-in logs or `signInActivity` on the service principal object        |
| Business justification for continued access            | Provided by Workload Owner in the review response                             |
| Confirmation that the scope is still the minimum needed | Workload Owner attestation                                                   |

Retain review evidence for 3 years.

---

## Permission Posture Scorecard

Monthly indicator for the Governance Board.

| Indicator                                                           | Healthy Threshold         | Data Source                                                      |
|---------------------------------------------------------------------|---------------------------|------------------------------------------------------------------|
| # SPs with subscription-level Owner outside approved exceptions     | 0                         | Azure Resource Graph RBAC query                                  |
| # SPs with subscription-level Contributor outside approved exceptions | 0                       | Azure Resource Graph RBAC query                                  |
| # privileged Graph permissions granted with no quarterly recert     | 0                         | App role assignments vs access review history                   |
| # admin consent grants with no ITSM change record                  | 0                         | Entra audit log vs change management system                     |
| # SPs where Graph permission grant is older than 12 months with no review | 0                  | Permission grant date vs last access review date                |

---

## See Also

- `/Volumes/data/vscode/MyProjects/entra-nrt/kb/app-registrations/14-api-permissions.md`
- `/Volumes/data/vscode/MyProjects/entra-nrt/kb/app-registrations/16-app-roles.md`
- `/Volumes/data/vscode/MyProjects/WorkloadIdentity/kb/03-management/03-access-reviews.md`

## References
- https://learn.microsoft.com/en-us/entra/identity-platform/permissions-consent-overview
- https://learn.microsoft.com/en-us/azure/role-based-access-control/best-practices
- https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/delegate-by-task


