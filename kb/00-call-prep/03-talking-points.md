# Talking Points — Workload & Managed Identity

Consultant reference for opening the call and landing the key messages. Read the framing paragraphs as a loose script; the bullet sections are prompts, not verbatim lines. Adjust emphasis based on what you learn in the first 10 minutes.

---

## Opening Framing (~3 paragraphs, read or paraphrase)

"Every application or pipeline that calls an API, reads from storage, or writes to a database needs an identity — not a username and password, but a cryptographically-verifiable identity that Azure or Entra ID can authenticate without a human in the loop. These are workload identities. Most organisations have hundreds of them and a surprisingly small number of people who know what they all do or who owns them."

"The good news is that Azure has built first-class primitives for this: managed identities remove the secret entirely for Azure-hosted workloads; workload identity federation removes the secret for CI/CD pipelines and workloads running outside Azure; and Entra ID issues short-lived access tokens that travel no further than the resource being called. When we design this well, you get passwordless-by-default for your applications, explainable RBAC at the narrowest possible scope, and an audit trail that your SOC can actually use."

"Today's session has three pillars. **Architecture** — which identity type belongs in which scenario. **Governance** — the policies that make sure the architecture stays healthy over time. **Management** — the day-to-day operations: rotation, access reviews, monitoring, and incident response. We will capture decisions live in the decision log and come out of this call with a clear set of actions and a draft policy set you can take into your security review."

---

## Key Messages to Land

### 1. The Credential Preference Hierarchy

Land this early — it frames every architecture decision that follows.

- **Tier 1 — Managed identity (system-assigned or user-assigned):** No credential to manage; Azure handles the token exchange via the Instance Metadata Service. Use for any Azure-hosted workload.
- **Tier 2 — Federated identity credential (Workload Identity Federation):** External OIDC token exchanged for an Entra access token; no secret stored in Azure. Use for GitHub Actions, GitLab, AKS pods, other cloud providers, on-premises OIDC issuers.
- **Tier 3 — Certificate credential:** Short-lived, asymmetric; secret never leaves Key Vault if using managed cert. Use only where Tier 1 and Tier 2 are not supported.
- **Tier 4 — Client secret (password):** Should be the exception, never the default. Time-limited, rotated, stored only in Key Vault, never in source code or pipeline variables.

The goal of this engagement is to push as many workloads to Tier 1 or Tier 2 as possible, and to put hard policy guardrails on anything that must stay at Tier 3 or 4.

### 2. Why Workload Identity Governance Matters

- Service principals are non-human identities; they don't have an HR record, don't appear in joiners/movers/leavers workflows, and don't reset their own passwords.
- They can be over-privileged silently — a workload that needed `Storage Blob Data Contributor` in 2021 may still have subscription-level `Contributor` today because nobody reviewed it.
- A single leaked client secret on a service principal with `RoleManagement.ReadWrite.Directory` is a complete tenant takeover scenario.
- The MITRE ATT&CK framework lists service principal credential theft as a documented initial access and persistence vector in real-world attacks.

### 3. Governance Is What Makes It Last

- Policy without automation decays. Architecture decisions made today are worthless in 18 months if there is no lifecycle process to enforce them.
- The three governance levers we will configure: (a) app management policies via Microsoft Graph to enforce credential type and lifetime at the tenant level; (b) Conditional Access for workload identities to block sign-ins from unexpected locations or risky principals; (c) access reviews on a quarterly cadence to catch permission creep.
- Ownership is the foundation. Every workload identity must have at least two named owners who are accountable for its lifecycle, its permissions, and its decommissioning.

### 4. Licensing Checkpoint

Raise this early if the SKU is unknown:
- Conditional Access for workload identities and risky workload identity detection in Identity Protection require **Entra Workload Identities Premium** (also referred to as "Workload ID" add-on or the premium workload identity feature set).
- Access reviews on service principals require **Entra ID Governance** (or **P2** where Governance is not yet available as a separate licence).
- PIM for Groups (for just-in-time group membership for workload identities) requires **Entra ID P2** or **Governance**.
- Confirm which SKUs are in place before designing controls that depend on them.

---

## Anti-Patterns to Surface Diplomatically

Use these to gently challenge practices the customer reveals during discovery. Frame as "this is something we see often and it's straightforward to address" rather than as criticism.

| Anti-Pattern                                                         | How to Reframe                                                                                                                                                              |
|----------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Secrets stored in pipeline variables or repository secrets           | "Pipeline variables are fine for non-sensitive values, but a client secret is a credential — it should live in Key Vault and be fetched at runtime, not hardcoded at commit time." |
| One service principal used by multiple unrelated workloads           | "Shared SPs create a blast-radius problem. If one workload is compromised, all workloads sharing that SP are affected. User-assigned managed identities are the right way to share an identity with clear governance." |
| Client secrets with 24-month or 'never expire' lifetime              | "Long-lived secrets are the attacker's best friend. A 90-day limit forces rotation and limits the window of exposure if a secret leaks without anyone noticing."             |
| App registrations with `Directory.ReadWrite.All` or `RoleManagement.ReadWrite.Directory` | "These are effectively Global Administrator permissions via API. We treat any SP with these permissions as a Tier-0 asset requiring quarterly recertification and CA policy." |
| Developer self-service app registration with no central visibility   | "Developers being able to register apps is a productivity feature, but without guardrails it creates an unmanaged inventory. The fix is a structured request process — still fast, but with an owner assigned at creation." |
| Subscription-level Contributor assigned to a managed identity        | "Contributor at subscription scope is the 'I'll sort out the permissions later' pattern. Later never comes. We'll scope it down to the resource group or resource during this engagement." |
| No owner on an app registration                                      | "An app registration with no owner is an orphan. When something goes wrong at 2 AM, there's no one to call. Two owners minimum is the policy — discoverable, accountable, replaceable." |
| `Users can register applications = Enabled`                         | "This is off-by-default for good reason. Enabling it means every user can create an app registration with application permissions — no visibility, no governance. The admin consent workflow is the right replacement." |
| Service principal creds checked into a Git repository               | "This is a critical finding regardless of whether the repo is private. Secret scanning should be retroactively run on all repos, and the secret must be rotated immediately." |
| Monitoring set to 'we rely on Microsoft Secure Score alerts'         | "Secure Score is a posture tool, not a detection tool. SP sign-in anomalies need to land in your SIEM on a sub-hour basis with a defined response owner."                   |

---

## Common Objections & How to Handle Them

These come up in almost every discovery call. Prepare for them.

**"We don't have time to rotate secrets — our release cycle is too fast."**
Response: Rotation only takes time if it's manual. We're designing automation: Key Vault auto-rotation for certificates, and ideally we migrate you off secrets entirely with federated credentials or managed identities — there's nothing to rotate. The argument for no rotation is actually the argument for no secrets.

**"Our developers need to be able to create their own app registrations."**
Response: That's a legitimate developer experience goal. The answer is not "no self-service" — it's "governed self-service." We design a lightweight request-and-provision process that responds in under 30 minutes, assigns an owner automatically, and sets the right defaults. Developers get speed; you get visibility.

**"We're not on Entra Workload Identities Premium — can we still do this?"**
Response: Yes. Managed identities, federated credentials, app management policies, access reviews on P2, and sign-in log monitoring are all available without the Workload ID premium add-on. The Premium SKU unlocks Conditional Access for service principals and risk-based detection. If you're starting from zero, P1/P2 gets you 80% of the governance story. We'll design for what you have today and flag the Premium features as the roadmap.

**"We use Terraform for everything — why can't we just do this in Terraform?"**
Response: You can, and you should for infrastructure. The gotcha is that app registrations and service principals live in Entra, not ARM — and the azuread Terraform provider doesn't cover every governance configuration (notably app management policies and custom security attributes). We'll use Terraform for what it handles well and Graph PowerShell / AzAPI for the rest. We'll document exactly which layer owns which resource.

**"Our audit team hasn't flagged this — is it really a risk?"**
Response: Workload identities are consistently under-represented in traditional IT audits because auditors look at user identity controls (MFA, password policy, joiners/leavers) and often miss the non-human side. The MITRE ATT&CK technique T1528 (Steal Application Access Token) is a documented, active attack pattern. We don't want your next audit finding to be a post-breach control failure.

---

## Questions to Listen For During Discovery

These customer statements are signal — listen for them and capture them in the decision log.

| Customer Says                                               | What It Signals                                                                  |
|-------------------------------------------------------------|----------------------------------------------------------------------------------|
| "We just use one service principal for everything in that team" | Shared SP; blast-radius risk; need to decompose to per-workload identities  |
| "Secrets are in the pipeline YAML, but it's a private repo" | Critical finding; secret exposure; rotation and migration urgently needed         |
| "I'm not sure who owns that app registration"              | Orphaned identity; lifecycle process absent                                      |
| "The cert expired and we just added a new one"             | No pre-expiry alerting; no rotation process; overlap window not being managed    |
| "We gave it Contributor because it's easier"               | Over-privileged RBAC; needs scope-down as a priority action                      |
| "We don't have a SIEM"                                     | Log collection gap; even Log Analytics without Sentinel covers the baseline       |
| "We have hundreds of app registrations and nobody knows what half of them do" | Inventory crisis; this engagement is urgently needed         |
| "The developer who set this up left six months ago"        | Orphaned identity; credentials may still be live with no owner accountability     |
| "It's just an internal tool, it doesn't matter"            | Internal tools often have broad permissions; assumption of low risk is the risk  |
| "We'll sort out the permissions after the PoC"             | Permission creep locked-in at PoC → production; govern from day one              |

---

## Call Close — What We Want to Walk Away With

Before ending the call, confirm:

1. **Scope is agreed** — what's in, what's out, what's a future phase.
2. **Architecture decisions logged** — at least the top 3 (identity type for Azure workloads, CI/CD identity approach, AKS identity approach).
3. **Three action items assigned** — minimum: export current SP inventory, confirm licence SKUs, assign two owners to the highest-risk app registrations.
4. **Next session booked** — policy review or architecture deep-dive.
5. **Decision log sent** — share the filled-in template within 24 hours of the call.

---

## Engagement Maturity Ladder

Use this to set expectations on what "done" looks like at each phase. Customers often expect to jump straight to Level 3 — anchor them to sequencing.

| Level | Name            | What it means                                                                                    | Typical timeline |
|-------|-----------------|--------------------------------------------------------------------------------------------------|------------------|
| 1     | Visibility      | Full inventory in place; every SP has ≥ 2 owners; sign-in logs flowing to Log Analytics.        | 4–8 weeks        |
| 2     | Control         | App management policy deployed; admin consent workflow active; RBAC scoped to resource level.    | 8–16 weeks       |
| 3     | Automated governance | Access reviews running on schedule; pre-expiry alerts automated; IaC for new provisioning. | 3–6 months       |
| 4     | Proactive security | Conditional Access for Tier 0/1 SPs; Identity Protection risky identity reviewed weekly; federated credentials adopted for all CI/CD. | 6–12 months |
| 5     | Continuous assurance | PIM for Groups JIT; quarterly recertification automated; incident playbooks tested; posture dashboard live. | 12+ months |

---

## Call Preparation Checklist

Complete before the call:

- [ ] Decision log template open and ready to fill in live.
- [ ] Graph PowerShell or Graph Explorer ready to run a quick SP inventory query if the customer can share screen access.
- [ ] Know the customer's Entra licence tier (P1/P2/Workload ID Premium/Governance) — check pre-call or ask early.
- [ ] Have the three opening framing paragraphs bookmarked — use them verbatim or adapt freely.
- [ ] Discovery questions list open on a second screen — select 10–15 targeted questions based on what you know about the customer.
- [ ] Anti-pattern table ready — you will use at least 3 of these in a typical call.
- [ ] Maturity ladder slide or table ready for the "future state" portion of the call.

---

## References
- https://learn.microsoft.com/en-us/entra/workload-id/workload-identities-overview
- https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/what-is-application-management
- https://learn.microsoft.com/en-us/entra/identity/conditional-access/workload-identity
