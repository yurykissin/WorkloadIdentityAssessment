# KB INDEX — fast lookup table

Single grep this file for any heading across the KB. Each row points to a heading in a KB article.
Format: `H<level> · <article-path>:<line> · <heading text>`

_Auto-generated. Re-run `scripts/build-index.py` after editing KB._

## 01-architecture

| Lvl | Heading | Path:Line |
|-----|---------|-----------|
| H1 | Workload Identity Taxonomy | `kb/01-architecture/01-workload-identity-taxonomy.md:1` |
| H2 | 1. Application Object (App Registration) | `kb/01-architecture/01-workload-identity-taxonomy.md:7` |
| H2 | 2. Service Principal | `kb/01-architecture/01-workload-identity-taxonomy.md:26` |
| H2 | 3. System-Assigned Managed Identity | `kb/01-architecture/01-workload-identity-taxonomy.md:47` |
| H2 | 4. User-Assigned Managed Identity | `kb/01-architecture/01-workload-identity-taxonomy.md:66` |
| H2 | 5. Federated Identity Credential on an App Registration | `kb/01-architecture/01-workload-identity-taxonomy.md:89` |
| H2 | 6. Federated Identity Credential on a User-Assigned Managed Identity | `kb/01-architecture/01-workload-identity-taxonomy.md:108` |
| H2 | 7. Legacy Service Account (Entra User as Automation Identity) — Anti-Pattern | `kb/01-architecture/01-workload-identity-taxonomy.md:123` |
| H2 | Comparison Table | `kb/01-architecture/01-workload-identity-taxonomy.md:138` |
| H2 | Portal Navigation Quick Reference | `kb/01-architecture/01-workload-identity-taxonomy.md:152` |
| H2 | Anti-Pattern Quick Reference | `kb/01-architecture/01-workload-identity-taxonomy.md:169` |
| H2 | See Also | `kb/01-architecture/01-workload-identity-taxonomy.md:181` |
| H2 | Key Terminology Summary | `kb/01-architecture/01-workload-identity-taxonomy.md:188` |
| H2 | References | `kb/01-architecture/01-workload-identity-taxonomy.md:199` |
| H1 | Decision Matrix — When to Use Which Workload Identity | `kb/01-architecture/02-when-to-use-which.md:1` |
| H2 | How to Use This Document | `kb/01-architecture/02-when-to-use-which.md:7` |
| H2 | Decision Lookup Table | `kb/01-architecture/02-when-to-use-which.md:13` |
| H2 | Tie-Breaker Rules | `kb/01-architecture/02-when-to-use-which.md:42` |
| H3 | Rule 1 — Is the workload Azure-hosted? | `kb/01-architecture/02-when-to-use-which.md:46` |
| H3 | Rule 2 — Does the identity need to be shared across multiple Azure resources? | `kb/01-architecture/02-when-to-use-which.md:49` |
| H3 | Rule 3 — Is the workload outside Azure but runs an OIDC-capable issuer? | `kb/01-architecture/02-when-to-use-which.md:53` |
| H3 | Rule 4 — Is the workload outside Azure with no OIDC issuer available? | `kb/01-architecture/02-when-to-use-which.md:56` |
| H3 | Rule 5 — Must the identity call APIs *as a delegated user* (acting on behalf of a specific person)? | `kb/01-architecture/02-when-to-use-which.md:59` |
| H3 | Rule 6 — Is the workload a multi-tenant SaaS product? | `kb/01-architecture/02-when-to-use-which.md:62` |
| H2 | Scenario Quick-Reference by Platform | `kb/01-architecture/02-when-to-use-which.md:67` |
| H2 | Common Mistakes to Avoid | `kb/01-architecture/02-when-to-use-which.md:95` |
| H2 | Additional Scenarios — Less Common but Important | `kb/01-architecture/02-when-to-use-which.md:105` |
| H2 | Edge Cases and Clarifications | `kb/01-architecture/02-when-to-use-which.md:120` |
| H3 | System-assigned vs user-assigned — when the line is blurry | `kb/01-architecture/02-when-to-use-which.md:122` |
| H3 | Federated credentials on app registration vs on user-assigned MI | `kb/01-architecture/02-when-to-use-which.md:130` |
| H3 | Multiple workloads, one identity — when is it acceptable? | `kb/01-architecture/02-when-to-use-which.md:136` |
| H3 | Service principals for Microsoft first-party apps | `kb/01-architecture/02-when-to-use-which.md:140` |
| H2 | Identity Type Summary — One-Line Rules | `kb/01-architecture/02-when-to-use-which.md:146` |
| H2 | Frequently Requested — Scenario Not in the Table? | `kb/01-architecture/02-when-to-use-which.md:162` |
| H2 | Migration Roadmap — Moving Off Secrets | `kb/01-architecture/02-when-to-use-which.md:168` |
| H2 | See Also | `kb/01-architecture/02-when-to-use-which.md:190` |
| H2 | References | `kb/01-architecture/02-when-to-use-which.md:196` |
| H1 | Reference Architectures | `kb/01-architecture/03-reference-architectures.md:1` |
| H2 | Architecture A — Azure App Service → Microsoft Graph (System-Assigned MI) | `kb/01-architecture/03-reference-architectures.md:7` |
| H2 | Architecture B — AKS Pod → Azure SQL (User-Assigned MI + Workload Identity Federation) | `kb/01-architecture/03-reference-architectures.md:53` |
| H2 | Architecture C — GitHub Actions → Azure Deployment (Federated Credential, No Secrets) | `kb/01-architecture/03-reference-architectures.md:98` |
| H2 | Architecture D — On-Premises Service → Microsoft Graph (Federated Credential via On-Prem OIDC Issuer) | `kb/01-architecture/03-reference-architectures.md:157` |
| H2 | Architecture E — Cross-Tenant SaaS / Multi-Tenant Application | `kb/01-architecture/03-reference-architectures.md:198` |
| H2 | Architecture F — Azure Function → Key Vault → Downstream API (System-Assigned MI + KV References) | `kb/01-architecture/03-reference-architectures.md:243` |
| H2 | Architecture G — Azure Data Factory → Storage + SQL (User-Assigned MI Shared Across Pipelines) | `kb/01-architecture/03-reference-architectures.md:287` |
| H2 | See Also | `kb/01-architecture/03-reference-architectures.md:326` |
| H2 | References | `kb/01-architecture/03-reference-architectures.md:331` |
| H1 | Trust Model & Token Flow | `kb/01-architecture/04-trust-model-and-token-flow.md:1` |
| H2 | 1. Entra ID as Issuer | `kb/01-architecture/04-trust-model-and-token-flow.md:7` |
| H2 | 2. Client Credentials Grant (App Registration + Secret or Certificate) | `kb/01-architecture/04-trust-model-and-token-flow.md:24` |
| H2 | 3. Managed Identity Token Acquisition via IMDS | `kb/01-architecture/04-trust-model-and-token-flow.md:53` |
| H2 | 4. Federated Identity Credential Exchange Flow | `kb/01-architecture/04-trust-model-and-token-flow.md:84` |
| H2 | 5. Token Contents | `kb/01-architecture/04-trust-model-and-token-flow.md:131` |
| H2 | 6. Conditional Access Evaluation for Workload Identity Sign-Ins | `kb/01-architecture/04-trust-model-and-token-flow.md:153` |
| H2 | See Also | `kb/01-architecture/04-trust-model-and-token-flow.md:182` |
| H2 | Token Request Quick Reference | `kb/01-architecture/04-trust-model-and-token-flow.md:187` |
| H2 | References | `kb/01-architecture/04-trust-model-and-token-flow.md:197` |
| H1 | Naming & Tagging Convention | `kb/01-architecture/05-naming-and-tagging.md:1` |
| H2 | 1. Naming Components | `kb/01-architecture/05-naming-and-tagging.md:7` |
| H2 | 2. Naming Patterns | `kb/01-architecture/05-naming-and-tagging.md:22` |
| H3 | App Registration (App Object / Service Principal) | `kb/01-architecture/05-naming-and-tagging.md:24` |
| H3 | System-Assigned Managed Identity | `kb/01-architecture/05-naming-and-tagging.md:37` |
| H3 | User-Assigned Managed Identity | `kb/01-architecture/05-naming-and-tagging.md:41` |
| H3 | Federated Identity Credential (on App Reg or User-Assigned MI) | `kb/01-architecture/05-naming-and-tagging.md:54` |
| H2 | 3. Display Name vs Object ID | `kb/01-architecture/05-naming-and-tagging.md:71` |
| H2 | 4. Required Azure Tags — User-Assigned Managed Identity Resources | `kb/01-architecture/05-naming-and-tagging.md:84` |
| H2 | 5. Tagging App Registrations via Microsoft Graph | `kb/01-architecture/05-naming-and-tagging.md:102` |
| H2 | 6. Required-Value Summary Table | `kb/01-architecture/05-naming-and-tagging.md:134` |
| H2 | Naming Convention Validation Checklist | `kb/01-architecture/05-naming-and-tagging.md:151` |
| H2 | Approved Business Unit Abbreviations | `kb/01-architecture/05-naming-and-tagging.md:167` |
| H2 | Gotcha — Portal vs Graph Tag Visibility | `kb/01-architecture/05-naming-and-tagging.md:186` |
| H2 | References | `kb/01-architecture/05-naming-and-tagging.md:200` |

## 02-governance

| Lvl | Heading | Path:Line |
|-----|---------|-----------|
| H1 | App Registration Policy | `kb/02-governance/01-app-registration-policy.md:1` |
| H2 | Policy Table | `kb/02-governance/01-app-registration-policy.md:14` |
| H2 | Scope and Applicability | `kb/02-governance/01-app-registration-policy.md:45` |
| H2 | Tenant-Level Security Settings — Quick Reference | `kb/02-governance/01-app-registration-policy.md:60` |
| H2 | Common Policy Gaps Found in Practice | `kb/02-governance/01-app-registration-policy.md:82` |
| H2 | Enforcement | `kb/02-governance/01-app-registration-policy.md:96` |
| H2 | Rollout Phasing | `kb/02-governance/01-app-registration-policy.md:112` |
| H2 | See Also | `kb/02-governance/01-app-registration-policy.md:140` |
| H2 | References | `kb/02-governance/01-app-registration-policy.md:148` |
| H1 | Workload Identity Policy | `kb/02-governance/02-workload-identity-policy.md:1` |
| H2 | Policy Table | `kb/02-governance/02-workload-identity-policy.md:16` |
| H2 | Workload Identity Classification Tiers | `kb/02-governance/02-workload-identity-policy.md:44` |
| H2 | Scope and Applicability | `kb/02-governance/02-workload-identity-policy.md:59` |
| H2 | Enforcement | `kb/02-governance/02-workload-identity-policy.md:74` |
| H2 | Workload Identity Maturity Indicators | `kb/02-governance/02-workload-identity-policy.md:85` |
| H3 | Green — Policy Compliant | `kb/02-governance/02-workload-identity-policy.md:89` |
| H3 | Amber — Remediation in Progress | `kb/02-governance/02-workload-identity-policy.md:98` |
| H3 | Red — Non-Compliant | `kb/02-governance/02-workload-identity-policy.md:104` |
| H2 | Policy Implementation Phasing | `kb/02-governance/02-workload-identity-policy.md:114` |
| H2 | See Also | `kb/02-governance/02-workload-identity-policy.md:141` |
| H2 | References | `kb/02-governance/02-workload-identity-policy.md:148` |
| H1 | Credential and Secret Policy | `kb/02-governance/03-credential-and-secret-policy.md:1` |
| H2 | Policy Table | `kb/02-governance/03-credential-and-secret-policy.md:14` |
| H2 | App Management Policy — Illustrative Configuration | `kb/02-governance/03-credential-and-secret-policy.md:43` |
| H2 | Enforcement | `kb/02-governance/03-credential-and-secret-policy.md:86` |
| H2 | Credential Inventory — Minimum Required Fields | `kb/02-governance/03-credential-and-secret-policy.md:101` |
| H2 | Tenant-Level Credential Posture Scorecard | `kb/02-governance/03-credential-and-secret-policy.md:123` |
| H2 | See Also | `kb/02-governance/03-credential-and-secret-policy.md:140` |
| H2 | References | `kb/02-governance/03-credential-and-secret-policy.md:145` |
| H1 | Permission Assignment Policy | `kb/02-governance/04-permission-assignment-policy.md:1` |
| H2 | Policy Table | `kb/02-governance/04-permission-assignment-policy.md:15` |
| H2 | Privileged Graph Permissions Reference | `kb/02-governance/04-permission-assignment-policy.md:37` |
| H2 | Scope and Applicability | `kb/02-governance/04-permission-assignment-policy.md:58` |
| H2 | Permission Request and Approval Process | `kb/02-governance/04-permission-assignment-policy.md:71` |
| H2 | Enforcement | `kb/02-governance/04-permission-assignment-policy.md:96` |
| H2 | Permission Review — Evidence Requirements | `kb/02-governance/04-permission-assignment-policy.md:109` |
| H2 | Permission Posture Scorecard | `kb/02-governance/04-permission-assignment-policy.md:125` |
| H2 | See Also | `kb/02-governance/04-permission-assignment-policy.md:139` |
| H2 | References | `kb/02-governance/04-permission-assignment-policy.md:145` |
| H1 | Ownership & Accountability (RACI) | `kb/02-governance/05-ownership-and-accountability.md:1` |
| H2 | RACI Matrix | `kb/02-governance/05-ownership-and-accountability.md:7` |
| H2 | Role Definitions | `kb/02-governance/05-ownership-and-accountability.md:35` |
| H3 | Workload Owner | `kb/02-governance/05-ownership-and-accountability.md:37` |
| H3 | Application Administrator / Cloud App Administrator | `kb/02-governance/05-ownership-and-accountability.md:43` |
| H3 | Identity Security | `kb/02-governance/05-ownership-and-accountability.md:49` |
| H3 | Subscription Owner | `kb/02-governance/05-ownership-and-accountability.md:55` |
| H3 | SOC (Security Operations Centre) | `kb/02-governance/05-ownership-and-accountability.md:61` |
| H3 | Governance Board | `kb/02-governance/05-ownership-and-accountability.md:67` |
| H2 | What Good Owners Do — Checklist | `kb/02-governance/05-ownership-and-accountability.md:75` |
| H2 | Escalation and Dispute Resolution | `kb/02-governance/05-ownership-and-accountability.md:91` |
| H2 | Owner Departure — Responsibilities Transfer | `kb/02-governance/05-ownership-and-accountability.md:102` |
| H2 | What Good Owners Do — Checklist | `kb/02-governance/05-ownership-and-accountability.md:114` |
| H2 | Inventory Freshness Requirements | `kb/02-governance/05-ownership-and-accountability.md:130` |
| H2 | See Also | `kb/02-governance/05-ownership-and-accountability.md:144` |
| H2 | References | `kb/02-governance/05-ownership-and-accountability.md:150` |
| H1 | Exception Process | `kb/02-governance/06-exception-process.md:1` |
| H2 | When an Exception Is Needed | `kb/02-governance/06-exception-process.md:7` |
| H2 | Exception Request Template | `kb/02-governance/06-exception-process.md:20` |
| H2 | Compensating Control Library | `kb/02-governance/06-exception-process.md:43` |
| H2 | Exception Review Cadence | `kb/02-governance/06-exception-process.md:62` |
| H2 | Exception Register | `kb/02-governance/06-exception-process.md:74` |
| H2 | Approval Authority Delegation | `kb/02-governance/06-exception-process.md:86` |
| H2 | Exception Governance Integration | `kb/02-governance/06-exception-process.md:99` |
| H2 | Exception Process SLA | `kb/02-governance/06-exception-process.md:110` |
| H2 | Frequently Approved vs Rarely Approved Exceptions | `kb/02-governance/06-exception-process.md:124` |
| H2 | Related Governance Documents | `kb/02-governance/06-exception-process.md:139` |
| H2 | References | `kb/02-governance/06-exception-process.md:150` |

## 03-management

| Lvl | Heading | Path:Line |
|-----|---------|-----------|
| H1 | Workload Identity Lifecycle — Create to Retire | `kb/03-management/01-lifecycle-create-to-retire.md:1` |
| H2 | Stage Overview | `kb/03-management/01-lifecycle-create-to-retire.md:7` |
| H2 | Stage 1 — Request | `kb/03-management/01-lifecycle-create-to-retire.md:15` |
| H2 | Stage 2 — Provision | `kb/03-management/01-lifecycle-create-to-retire.md:37` |
| H2 | Stage 3 — Operate | `kb/03-management/01-lifecycle-create-to-retire.md:64` |
| H2 | Stage 4 — Review | `kb/03-management/01-lifecycle-create-to-retire.md:89` |
| H2 | Stage 5 — Renew | `kb/03-management/01-lifecycle-create-to-retire.md:111` |
| H2 | Stage 6 — Retire | `kb/03-management/01-lifecycle-create-to-retire.md:132` |
| H2 | Decommission Checklist | `kb/03-management/01-lifecycle-create-to-retire.md:149` |
| H2 | References | `kb/03-management/01-lifecycle-create-to-retire.md:170` |
| H1 | Credential Rotation Runbook | `kb/03-management/02-credential-rotation-runbook.md:1` |
| H2 | Rotation Triggers | `kb/03-management/02-credential-rotation-runbook.md:7` |
| H2 | Rotation Procedure — Client Secret | `kb/03-management/02-credential-rotation-runbook.md:20` |
| H3 | Pre-rotation | `kb/03-management/02-credential-rotation-runbook.md:22` |
| H3 | Rotation steps (zero-downtime — overlap window) | `kb/03-management/02-credential-rotation-runbook.md:29` |
| H2 | Rotation Procedure — Certificate | `kb/03-management/02-credential-rotation-runbook.md:72` |
| H3 | Pre-rotation | `kb/03-management/02-credential-rotation-runbook.md:74` |
| H3 | Rotation steps | `kb/03-management/02-credential-rotation-runbook.md:79` |
| H2 | Rotation Procedure — Federated Credential Subject Change | `kb/03-management/02-credential-rotation-runbook.md:109` |
| H2 | Validation Steps (Post-Rotation) | `kb/03-management/02-credential-rotation-runbook.md:139` |
| H2 | Failure Modes & Rollback | `kb/03-management/02-credential-rotation-runbook.md:151` |
| H2 | Automation Reference | `kb/03-management/02-credential-rotation-runbook.md:163` |
| H3 | Key Vault Auto-Rotation for Certificates | `kb/03-management/02-credential-rotation-runbook.md:165` |
| H3 | Graph PowerShell — Secret Rotation Script Sketch | `kb/03-management/02-credential-rotation-runbook.md:178` |
| H1 | Requires: Microsoft.Graph.Applications module | `kb/03-management/02-credential-rotation-runbook.md:181` |
| H1 | Run: Connect-MgGraph -Scopes "Application.ReadWrite.All" | `kb/03-management/02-credential-rotation-runbook.md:182` |
| H1 | 1. Add new credential | `kb/03-management/02-credential-rotation-runbook.md:191` |
| H1 | 2. Store in Key Vault | `kb/03-management/02-credential-rotation-runbook.md:199` |
| H2 | References | `kb/03-management/02-credential-rotation-runbook.md:209` |
| H1 | Access Reviews — Workload Identities | `kb/03-management/03-access-reviews.md:1` |
| H2 | What Can Be Reviewed | `kb/03-management/03-access-reviews.md:7` |
| H2 | Review Cadence | `kb/03-management/03-access-reviews.md:24` |
| H2 | Reviewer Selection | `kb/03-management/03-access-reviews.md:42` |
| H2 | Auto-Apply Decisions vs Manual Review | `kb/03-management/03-access-reviews.md:57` |
| H2 | Evidence Retention | `kb/03-management/03-access-reviews.md:68` |
| H2 | Tooling | `kb/03-management/03-access-reviews.md:80` |
| H3 | Entra ID Governance Access Reviews (Primary Tool) | `kb/03-management/03-access-reviews.md:82` |
| H3 | PIM for Groups — Quarterly Recertification | `kb/03-management/03-access-reviews.md:93` |
| H3 | Manual Graph Queries for Coverage Gaps | `kb/03-management/03-access-reviews.md:104` |
| H1 | Lists all app-only permission grants (oAuth2PermissionGrants + appRoleAssignments) | `kb/03-management/03-access-reviews.md:108` |
| H1 | Requires AuditLog.Read.All and Directory.Read.All | `kb/03-management/03-access-reviews.md:125` |
| H2 | Review Evidence and Audit Trail | `kb/03-management/03-access-reviews.md:133` |
| H3 | What evidence is generated by Entra access reviews | `kb/03-management/03-access-reviews.md:135` |
| H3 | Exporting review results | `kb/03-management/03-access-reviews.md:143` |
| H1 | Export decisions for a completed access review instance | `kb/03-management/03-access-reviews.md:146` |
| H2 | See Also | `kb/03-management/03-access-reviews.md:160` |
| H2 | References | `kb/03-management/03-access-reviews.md:166` |
| H1 | Monitoring & Alerts — Workload Identities | `kb/03-management/04-monitoring-and-alerts.md:1` |
| H2 | Monitoring Table | `kb/03-management/04-monitoring-and-alerts.md:7` |
| H2 | Log Retention Requirements | `kb/03-management/04-monitoring-and-alerts.md:29` |
| H2 | Sentinel Content | `kb/03-management/04-monitoring-and-alerts.md:49` |
| H3 | Content Hub Solutions to Install | `kb/03-management/04-monitoring-and-alerts.md:53` |
| H3 | Specific Analytic Rules of Interest | `kb/03-management/04-monitoring-and-alerts.md:62` |
| H3 | Workbook — Workload Identity Monitoring | `kb/03-management/04-monitoring-and-alerts.md:76` |
| H2 | Alert Severity Classification | `kb/03-management/04-monitoring-and-alerts.md:82` |
| H2 | Diagnostic Settings Configuration Reference | `kb/03-management/04-monitoring-and-alerts.md:102` |
| H2 | Monthly Monitoring Health Check | `kb/03-management/04-monitoring-and-alerts.md:131` |
| H2 | References | `kb/03-management/04-monitoring-and-alerts.md:147` |
| H1 | Incident Response — Workload Identity Compromise | `kb/03-management/05-incident-response-workload-identity.md:1` |
| H2 | Playbook 1 — Leaked Client Secret in Source Code | `kb/03-management/05-incident-response-workload-identity.md:7` |
| H3 | Detection | `kb/03-management/05-incident-response-workload-identity.md:9` |
| H3 | Containment | `kb/03-management/05-incident-response-workload-identity.md:15` |
| H3 | Eradication | `kb/03-management/05-incident-response-workload-identity.md:26` |
| H3 | Recovery | `kb/03-management/05-incident-response-workload-identity.md:33` |
| H3 | Post-Incident Actions | `kb/03-management/05-incident-response-workload-identity.md:39` |
| H2 | Playbook 2 — Compromised Service Principal (Anomalous Sign-In Pattern) | `kb/03-management/05-incident-response-workload-identity.md:50` |
| H3 | Detection | `kb/03-management/05-incident-response-workload-identity.md:52` |
| H3 | Containment | `kb/03-management/05-incident-response-workload-identity.md:59` |
| H3 | Eradication | `kb/03-management/05-incident-response-workload-identity.md:75` |
| H3 | Recovery | `kb/03-management/05-incident-response-workload-identity.md:85` |
| H3 | Post-Incident Actions | `kb/03-management/05-incident-response-workload-identity.md:92` |
| H2 | Playbook 3 — Rogue Admin Consent Granted to Malicious Application | `kb/03-management/05-incident-response-workload-identity.md:102` |
| H3 | Detection | `kb/03-management/05-incident-response-workload-identity.md:104` |
| H3 | Containment | `kb/03-management/05-incident-response-workload-identity.md:111` |
| H3 | Eradication | `kb/03-management/05-incident-response-workload-identity.md:129` |
| H3 | Recovery | `kb/03-management/05-incident-response-workload-identity.md:139` |
| H3 | Post-Incident Actions | `kb/03-management/05-incident-response-workload-identity.md:145` |
| H2 | Playbook 4 — Federated Credential Subject Manipulated | `kb/03-management/05-incident-response-workload-identity.md:155` |
| H3 | Detection | `kb/03-management/05-incident-response-workload-identity.md:159` |
| H3 | Containment | `kb/03-management/05-incident-response-workload-identity.md:165` |
| H3 | Eradication | `kb/03-management/05-incident-response-workload-identity.md:177` |
| H3 | Recovery | `kb/03-management/05-incident-response-workload-identity.md:189` |
| H3 | Post-Incident Actions | `kb/03-management/05-incident-response-workload-identity.md:194` |
| H2 | Playbook 5 — Privileged Graph Permission Abused | `kb/03-management/05-incident-response-workload-identity.md:204` |
| H3 | Detection | `kb/03-management/05-incident-response-workload-identity.md:208` |
| H3 | Containment | `kb/03-management/05-incident-response-workload-identity.md:214` |
| H3 | Eradication | `kb/03-management/05-incident-response-workload-identity.md:227` |
| H3 | Recovery | `kb/03-management/05-incident-response-workload-identity.md:233` |
| H3 | Post-Incident Actions | `kb/03-management/05-incident-response-workload-identity.md:240` |
| H2 | References | `kb/03-management/05-incident-response-workload-identity.md:250` |
| H1 | Tooling Reference — Graph, Bicep / Terraform, PIM for Groups | `kb/03-management/06-tooling-graph-bicep-pim-for-groups.md:1` |
| H2 | Microsoft Graph (PowerShell SDK + REST) | `kb/03-management/06-tooling-graph-bicep-pim-for-groups.md:7` |
| H3 | Key Cmdlets — Microsoft Graph PowerShell SDK | `kb/03-management/06-tooling-graph-bicep-pim-for-groups.md:11` |
| H2 | Bicep / Terraform — Infrastructure-as-Code | `kb/03-management/06-tooling-graph-bicep-pim-for-groups.md:40` |
| H3 | Bicep | `kb/03-management/06-tooling-graph-bicep-pim-for-groups.md:44` |
| H3 | Terraform | `kb/03-management/06-tooling-graph-bicep-pim-for-groups.md:73` |
| H1 | AzAPI provider — app management policy binding (not available in azuread provider) | `kb/03-management/06-tooling-graph-bicep-pim-for-groups.md:93` |
| H2 | Azure CLI / Az PowerShell — Quick Operations | `kb/03-management/06-tooling-graph-bicep-pim-for-groups.md:108` |
| H2 | PIM for Groups — JIT Access for Workload Identities | `kb/03-management/06-tooling-graph-bicep-pim-for-groups.md:122` |
| H2 | Entra ID Governance | `kb/03-management/06-tooling-graph-bicep-pim-for-groups.md:160` |
| H2 | Microsoft Defender for Cloud | `kb/03-management/06-tooling-graph-bicep-pim-for-groups.md:171` |
| H2 | Decision Card — Task to Tool | `kb/03-management/06-tooling-graph-bicep-pim-for-groups.md:190` |
| H2 | References | `kb/03-management/06-tooling-graph-bicep-pim-for-groups.md:209` |
