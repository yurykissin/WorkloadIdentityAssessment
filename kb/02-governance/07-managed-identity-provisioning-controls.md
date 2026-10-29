# Managed Identity Provisioning Controls

Managed identities are provisioned in **Azure** (RBAC + Azure Policy), not in the Entra admin center. This article answers the control questions that come up on governance calls: *can I control whether identities get created, who can create them, and where I manage and monitor them?* The short answer to every "block/restrict" question is **Azure RBAC + Azure Policy** — there is no single Entra tenant toggle.

Path to configure:
```
Azure portal > Managed Identities (create/delete user-assigned MI)
Azure portal > <resource> > Identity (enable/disable system-assigned MI)
Azure portal > Policy > Definitions / Assignments (enforce or block)
Azure portal > <scope> > Access control (IAM) (who can create/attach)
Microsoft Entra admin center > Identity > Enterprise applications (observe the MI as an identity)
```

---

## Quick Answers

| Question | Answer | Lever |
|----------|--------|-------|
| Are system-assigned MIs on by default? | **No.** Off by default on virtually every resource; must be explicitly enabled (toggle, ARM/Bicep, or a service feature/DINE policy that adds one). | Default state + Azure Policy |
| Can I force system-assigned MI on/off? | Yes — **Azure Policy** at management-group/subscription scope (`deny`, `audit`, or `deployIfNotExists`). There is no Entra-level "default MI" switch. | Azure Policy |
| Can I control who creates user-assigned MI? | Yes — **Azure RBAC.** Creation requires `Managed Identity Contributor`. Withhold it and users cannot create UAMIs. | Azure RBAC |
| Can I block user-assigned MI entirely? | Yes — **Azure Policy** `deny` on `Microsoft.ManagedIdentity/userAssignedIdentities`, or `deny` on resources whose `identity.type` includes `UserAssigned`. | Azure Policy |
| Do Azure Arc resources have MI? | Yes — Arc-enabled servers get a **system-assigned MI automatically** at onboarding. **No user-assigned MI** on Arc servers. Token via local endpoint `localhost:40342`, not IMDS. | N/A (platform behaviour) |
| Best place to manage MI? | **Azure portal** for lifecycle + RBAC; **Entra** to observe the identity and its activity. | Split by object type |

---

## System-Assigned MI — Default State and Enforcement

**Default:** system-assigned managed identity is **disabled** on new resources. It is created only when someone explicitly enables it — via the resource's *Identity* blade, an ARM/Bicep `identity` block, or a platform feature that provisions one on your behalf (this is why tenants accumulate system MIs no one remembers creating — Guest Configuration / Azure Monitor Agent baselines use `deployIfNotExists` policies that add one).

There is **no tenant-wide "system MI on/off by default" setting.** To enforce a posture, use Azure Policy:

| Goal | Policy approach |
|------|-----------------|
| Prevent resources from having a system-assigned identity | `deny` effect on the `identity.type` property (e.g. deny when `identity.type` contains `SystemAssigned`) |
| Require system-assigned MI on specific resource types | `deployIfNotExists` — built-in policies exist for VMs and VM Scale Sets ("Use Azure Policy to assign managed identities", preview) that add a system-assigned (or a specified user-assigned) identity automatically |
| Audit-only visibility before enforcing | Same policies with `audit` effect first; move to `deny`/`deployIfNotExists` after reviewing compliance |

**Governance rule:** default posture is "system MI off unless the workload needs it." Enable per-resource, scope RBAC least-privilege, and let system MIs auto-delete with their resource (no orphans).

---

## User-Assigned MI — Who Can Create and Attach

Two distinct RBAC actions gate the UAMI lifecycle. Controlling **both** is required — controlling only creation still leaves the attach-based escalation path open.

| Action | Required built-in role | Permission | Notes |
|--------|-----------------------|------------|-------|
| **Create / delete** a user-assigned MI | `Managed Identity Contributor` | `Microsoft.ManagedIdentity/userAssignedIdentities/write` (+ read/delete) | Withhold this role to stop users minting UAMIs. |
| **Attach / assign** an existing UAMI to a resource | `Managed Identity Operator` | `Microsoft.ManagedIdentity/userAssignedIdentities/*/assign/action` | **The subtle escalation path:** anyone who can attach a UAMI grants that resource all the identity's permissions **without touching RBAC on the target resources.** Lock this down as tightly as creation. |
| **List / read** a UAMI | `Managed Identity Operator` or `Managed Identity Contributor` | read actions | — |

**Block user-assigned MI entirely** with Azure Policy:

| Goal | Policy approach |
|------|-----------------|
| Forbid creating any UAMI in a scope | `deny` on resource type `Microsoft.ManagedIdentity/userAssignedIdentities` |
| Forbid resources from carrying a UAMI | `deny` when `identity.type` includes `UserAssigned` |
| Restrict which UAMIs may be attached | `audit`/`deny` policy evaluating `identity.userAssignedIdentities` against an allow-list of approved identity resource IDs |

**Governance rule:** treat `Managed Identity Operator` as a privileged assignment. Grant it narrowly (resource-group scope, specific approved UAMIs), never broadly at subscription scope, and review it in the quarterly permission recertification.

---

## Azure Arc Resources

- **Arc-enabled servers** receive a **system-assigned managed identity automatically** when the Connected Machine agent onboards. There is **no user-assigned MI** option on Arc servers.
- Token retrieval differs from a native Azure VM: apps call the **local endpoint `http://localhost:40342/metadata/identity/oauth2/token`** and must first read a **challenge token file** written by the agent (readable only by privileged local accounts) — so it is more locked-down than a native VM's IMDS at `169.254.169.254`.
- Arc-enabled **Kubernetes**, **data services**, and **VMware/SCVMM** have their own identity models and are out of scope for the Arc-server system-MI behaviour above.

**Governance implication:** Arc servers are in the workload-identity inventory scope — their system MIs get RBAC assignments and must be reviewed like any other MI. Because tokens require local privileged access to the challenge file, the host-trust risk is narrower than a native VM but not eliminated.

---

## Where to Manage vs. Observe

Split by object type — this is the single most common source of "I can't find my managed identity" confusion. Managed identities **do not appear under App registrations.**

| Task | Location |
|------|----------|
| Create / delete **user-assigned** MI | **Azure portal** → *Managed Identities* service (it is a first-class Azure resource) |
| Enable / disable **system-assigned** MI | **Azure portal** → the resource's *Identity* blade |
| Assign Azure RBAC roles / Key Vault access to an MI | **Azure portal** → *Access control (IAM)* on the target resource/scope |
| View the MI as an identity — object ID, sign-in and audit logs, app-role (Graph) grants, risk state | **Entra admin center** → *Enterprise applications* |
| Enforce or block MI provisioning across the estate | **Azure portal** → *Policy* |

**Rule of thumb:** manage **lifecycle and permissions in Azure portal**; observe the **identity and its activity in Entra**.

---

## Reports and Insights for Managed Identities

There is no single "MI overview" report in the portal, so combine these:

| Source | What it shows | Notes |
|--------|---------------|-------|
| Entra → Sign-in logs → **Managed identity sign-ins** tab | Every token an MI requested and the resource it targeted | Best "what is this MI actually doing" view |
| Entra → **Audit logs** | MI creation, RBAC/app-role/permission changes | Change forensics |
| Entra → ID Protection → **Risky workload identities** | Anomalous MI behaviour (suspicious API traffic, anomalous SP activity) | **Requires Workload Identities Premium.** Carries extra weight because CA does not apply to managed identities |
| Entra → Enterprise applications → the MI → **Permissions** | Graph/API application permissions held by the MI | Blast-radius review |
| **Azure Policy compliance** | Which resources have/lack MI; disallowed identity types | Fleet-wide posture |
| **Defender for Cloud / MDCA** | Over-privileged and unused identities | Recommendations engine |
| **This project's assessment scripts** | `02-inventory` (all MIs), `06-stale-and-orphaned` (orphaned UAMIs), `05-permission-surface` (RBAC + Graph blast radius) | Fills the portal's missing single-pane MI view |

**Governance rule:** orphaned **user-assigned** MIs are the primary MI hygiene finding (they do not auto-delete). Run `06-stale-and-orphaned` on the quarterly cadence and remediate standing, unused UAMIs and their dangling role assignments.

---

## See Also

- `/Volumes/data/vscode/MyProjects/WorkloadIdentity/kb/01-architecture/01-workload-identity-taxonomy.md` — system-assigned vs user-assigned MI definitions
- `/Volumes/data/vscode/MyProjects/WorkloadIdentity/kb/01-architecture/02-when-to-use-which.md` — decision matrix, Arc token endpoint
- `/Volumes/data/vscode/MyProjects/WorkloadIdentity/kb/02-governance/04-permission-assignment-policy.md` — least-privilege RBAC and Graph permission policy
- `/Volumes/data/vscode/MyProjects/WorkloadIdentity/kb/03-management/01-lifecycle-create-to-retire.md` — lifecycle and cleanup

---

## References

- Azure services and resource types supporting managed identities — https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/managed-identities-status
- Managed identities FAQ (RBAC to create/assign UAMI) — https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/managed-identities-faq
- Manage user-assigned managed identities — https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/how-manage-user-assigned-managed-identities
- Use Azure Policy to assign managed identities (preview) — https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/how-to-assign-managed-identity-via-azure-policy
- Azure built-in roles for Identity (Managed Identity Contributor / Operator) — https://learn.microsoft.com/azure/role-based-access-control/built-in-roles#identity
- Access Azure resources with managed identity on Azure Arc-enabled servers — https://learn.microsoft.com/azure/azure-arc/servers/managed-identity-authentication
- Azure Policy built-in definitions (Managed Identity category) — https://learn.microsoft.com/azure/governance/policy/samples/built-in-policies#managed-identity
