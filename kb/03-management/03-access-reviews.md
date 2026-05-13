# Access Reviews — Workload Identities

Access reviews for workload identities are the primary mechanism for detecting and remediating permission creep, orphaned assignments, and stale access that builds up over the operating life of a service principal or managed identity. Unlike user access reviews, workload identity access reviews have no self-service element — a human reviewer (the Workload Owner or Identity Security) must attest to each assignment.

---

## What Can Be Reviewed

| Reviewable Object                                             | Review Tool                                    | Licence Required                          |
|---------------------------------------------------------------|------------------------------------------------|-------------------------------------------|
| Azure RBAC role assignments held by service principals        | Entra ID Governance access reviews (Azure resource roles) | Entra ID Governance or P2        |
| Microsoft Graph app role assignments to service principals    | Entra ID Governance access reviews (app roles) | Entra ID Governance or P2                 |
| Group membership — where SPs are members of security groups   | Entra ID Governance access reviews (group membership) | Entra ID Governance or P2          |
| PIM for Groups — eligible and active SP group membership      | Entra ID Governance access reviews (PIM for Groups) | Entra ID Governance + P2             |
| Privileged Entra role assignments to SPs (e.g., App Admin)   | Entra ID Governance access reviews (directory roles) | Entra ID Governance or P2           |
| Admin consent grants (Graph permissions on service principals) | Manual review via Graph query — not natively supported in Entra access reviews | P1 minimum (manual) |
| Federated credential configurations on app registrations     | Manual review via Graph query                  | P1 minimum (manual)                       |
| App registration ownership                                   | Manual review via Graph query or portal         | Any                                       |

**Coverage gap:** Admin consent grants (the permissions visible under Enterprise applications > Permissions > Application permissions) are not surfaced natively in Entra access reviews. These must be reviewed via a manual Graph query and the results presented to reviewers in a custom report.

---

## Review Cadence

| Identity / Permission Tier                                        | Cadence        | Reviewer                              |
|-------------------------------------------------------------------|----------------|---------------------------------------|
| Privileged Graph application permissions (`Directory.*`, `RoleManagement.*`, `Application.ReadWrite.All`) | Monthly | Identity Security |
| Azure RBAC Owner or User Access Administrator held by SP/MI      | Monthly        | Subscription Owner + Identity Security |
| Sensitive Graph permissions (`Mail.ReadWrite`, `Files.ReadWrite.All`, `User.ReadWrite.All`) | Quarterly | Identity Security + Workload Owner |
| Standard Azure RBAC (Contributor and below)                      | Quarterly      | Workload Owner (Identity Security as fallback) |
| Standard app role assignments (non-privileged)                   | Quarterly      | Workload Owner                        |
| Group membership — security groups used for RBAC                 | Quarterly      | Group Owner                           |
| PIM for Groups — SP eligible membership                          | Quarterly      | Workload Owner + Identity Security    |
| Admin consent grants — all application permissions               | Semi-annual    | Identity Security                     |
| App registration ownership                                       | Semi-annual    | Application Administrator             |
| Federated credential configurations                              | Semi-annual    | Workload Owner + Identity Security    |
| All workload identities — inventory completeness and activity    | Semi-annual    | Application Administrator             |

---

## Reviewer Selection

| Review Type                         | Primary Reviewer                  | Fallback (if primary is unavailable or inactive) |
|-------------------------------------|-----------------------------------|----------------------------------------------------|
| RBAC on Azure resource/RG/subscription | Workload Owner                 | Subscription Owner                                |
| Graph permission grant              | Identity Security                 | Application Administrator                         |
| App role assignment                 | Workload Owner                    | Identity Security                                 |
| Privileged Entra role on SP         | Identity Security                 | CISO / Governance Board                           |
| Group membership for SP             | Group Owner                       | Identity Security                                 |
| PIM for Groups membership           | Workload Owner                    | Identity Security                                 |

**Conflict of interest rule:** The person who originally granted an assignment should not be the sole reviewer for that assignment. Identity Security should co-review any assignment they did not independently verify at grant time.

---

## Auto-Apply Decisions vs Manual Review

| Setting                       | Recommendation                                                                                      |
|-------------------------------|------------------------------------------------------------------------------------------------------|
| Auto-apply decisions          | **Enabled** for standard-tier reviews where the reviewer is the Workload Owner and the access is non-privileged. Assignments not responded to within 14 days are auto-denied. |
| Manual-apply decisions        | **Required** for privileged reviews (monthly) and for any review where the auto-denied result would affect a production workload. Reviewer must explicitly confirm denial before removal. |
| Non-response behaviour        | Default to **deny access** (remove the assignment) — not "approve access". Non-response means no justification can be provided. |
| Justification required        | **Enabled** — reviewers must type a short justification when approving continued access. "Still needed" is not sufficient; "Needed for X capability until Y date" is the expected format. |

---

## Evidence Retention

| Evidence Type                           | Retention Period              | Storage Location                              |
|-----------------------------------------|-------------------------------|-----------------------------------------------|
| Completed access review report          | 3 years                       | Entra audit log + exported to SharePoint/ITSM |
| Individual reviewer decision and justification | 3 years                | Entra access review history (exportable via Graph) |
| Manual Graph review export              | 3 years                       | Secure SharePoint or ITSM attachment          |
| Remediation actions (removal tickets)   | 3 years                       | ITSM records                                 |
| Non-response escalation records         | 3 years                       | Email audit trail + ITSM                     |

---

## Tooling

### Entra ID Governance Access Reviews (Primary Tool)

Path to configure:
```
Microsoft Entra admin center > Identity Governance > Access reviews > + New access review
  > Review type: Teams + Groups (group membership) or Applications (app roles) or Azure resource roles
  > Scope: Service principals (for workload identity reviews)
  > Reviewers: Specific reviewers (Workload Owner) or Managers
  > Settings: Auto-apply, require justification, reminder frequency
```

### PIM for Groups — Quarterly Recertification

PIM for Groups access reviews are configured in Identity Governance and surface the eligible and active group membership for SPs. Useful for just-in-time elevated access governance.

```
Microsoft Entra admin center > Identity Governance > Access reviews > + New access review
  > Review type: Teams + Groups
  > Group: <PIM-managed group>
  > Scope: All members (includes SP members)
```

### Manual Graph Queries for Coverage Gaps

**Admin consent grants on all service principals (application permissions):**
```powershell
# Lists all app-only permission grants (oAuth2PermissionGrants + appRoleAssignments)
Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId "<sp-object-id>" |
    Select-Object PrincipalDisplayName, ResourceDisplayName, AppRoleId
```

**App registrations with credentials expiring in 90 days:**
```powershell
$threshold = (Get-Date).AddDays(90)
Get-MgApplication -All | ForEach-Object {
    $_.PasswordCredentials + $_.KeyCredentials |
        Where-Object { $_.EndDateTime -lt $threshold } |
        Select-Object @{N="App";E={$_.DisplayName}}, EndDateTime
}
```

**Service principals with no sign-in in 90 days (stale identity candidates):**
```powershell
# Requires AuditLog.Read.All and Directory.Read.All
$cutoff = (Get-Date).AddDays(-90).ToString("o")
Get-MgServicePrincipal -All -Filter "signInActivity/lastSignInDateTime le $cutoff" |
    Select-Object DisplayName, Id, SignInActivity
```

---

## Review Evidence and Audit Trail

### What evidence is generated by Entra access reviews

When an access review is completed in Entra ID Governance, the following artefacts are available:

- **Review summary report** — downloadable from the access review blade showing total decisions, approved, denied, not reviewed, and auto-applied.
- **Individual reviewer decisions** — exportable via Graph API (`GET /identityGovernance/accessReviews/instances/<id>/decisions`) — includes reviewer, decision, justification, and timestamp.
- **Audit log events** — `Update accessReview`, `Apply accessReview` events in the Entra audit log for each review completion.

### Exporting review results

```powershell
# Export decisions for a completed access review instance
$reviewId = "<access-review-id>"
$instanceId = "<instance-id>"
Get-MgIdentityGovernanceAccessReviewDefinitionInstanceDecision `
    -AccessReviewScheduleDefinitionId $reviewId `
    -AccessReviewInstanceId $instanceId |
    Select-Object Principal, Resource, Decision, Justification, ReviewedDateTime |
    Export-Csv -Path "access-review-evidence-$(Get-Date -Format 'yyyyMMdd').csv" -NoTypeInformation
```

Export and archive this CSV as the control evidence record for each completed review.

---

## See Also

- `/Volumes/data/vscode/MyProjects/WorkloadIdentity/kb/02-governance/04-permission-assignment-policy.md`
- `/Volumes/data/vscode/MyProjects/WorkloadIdentity/kb/02-governance/05-ownership-and-accountability.md`
- `/Volumes/data/vscode/MyProjects/WorkloadIdentity/kb/03-management/01-lifecycle-create-to-retire.md`

## References
- https://learn.microsoft.com/en-us/entra/id-governance/access-reviews-overview
- https://learn.microsoft.com/en-us/entra/id-governance/privileged-identity-management/groups-features
- https://learn.microsoft.com/en-us/graph/api/resources/accessreview
