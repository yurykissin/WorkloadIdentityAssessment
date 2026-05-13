# Discovery Question → Evidence Map

For every question in `../kb/00-call-prep/01-discovery-questions.md`, this map identifies whether the answer comes from:

- **DATA** → a script in `scripts/` produces the answer mechanically
- **CONVERSATION** → must be asked of the customer (process / org / future-state)
- **HYBRID** → script gives the raw count or shape; conversation fills in the "why"

The script name in the right column points to the output file under `output/<ts>/<script>.csv|.json`. "—" in the script column means pure conversation.

---

## Current State

| # | Question | Source | Script |
|---|----------|--------|--------|
| 1 | Inventory of all service principals? | DATA | `02-inventory` (count + CSV is the inventory) |
| 2 | Who creates app registrations? | CONVERSATION | — |
| 3 | Formal approval process? | CONVERSATION | — |
| 4 | Regular user accounts used as service accounts? | HYBRID | `06-stale-and-orphaned` flags users with no MFA + automation-style sign-in patterns; confirm with customer |
| 5 | Count of app regs and enterprise apps? | DATA | `02-inventory` |
| 6 | Active vs dormant? | DATA | `06-stale-and-orphaned` (90-day sign-in window) |
| 7 | App regs with no owner? | DATA | `06-stale-and-orphaned` |
| 8 | Past clean-up exercise? | CONVERSATION | — |
| 9 | Count of Application Admin / Cloud App Admin role holders? | DATA | `01-tenant-context` (role member count section) |
| 10 | "Users can register applications" setting? | DATA | `01-tenant-context` (authorization policy) |
| 11 | Admin consent workflow enabled? | DATA | `01-tenant-context` (authorization policy) |
| 12 | Guest users as service identities? | HYBRID | `02-inventory` flags guest owners on app regs; confirm with customer |

## Workload Inventory

| # | Question | Source | Script |
|---|----------|--------|--------|
| 13 | Azure workloads calling APIs via an identity? | HYBRID | `02-inventory` lists MIs; customer confirms which are external-facing |
| 14 | Workloads using managed identity already? | DATA | `02-inventory` MI count |
| 15 | On-prem workloads to Entra APIs? | CONVERSATION | — |
| 16 | Workloads outside Azure (AWS / GCP / on-prem K8s)? | CONVERSATION (HYBRID via 04) | `04-federated-credentials` (issuer ≠ Microsoft / GitHub indicates external cloud) |
| 17 | CI/CD pipelines deploying to Azure? | HYBRID | `04-federated-credentials` (GitHub/ADO/GitLab issuer presence); the absence is also informative |
| 18 | Pipelines storing secrets? | CONVERSATION (HYBRID) | `03-credential-hygiene` (presence of password creds on SPs known to be pipeline-tied is a signal) |
| 19 | Federated credentials implemented? | DATA | `04-federated-credentials` |
| 20 | AKS clusters with workloads authenticating? | CONVERSATION | — (could be derived via `Get-AzAksCluster` + OIDC issuer state — covered briefly by `02-inventory`) |
| 21 | AKS using Workload Identity add-on? | CONVERSATION | — |
| 22 | Functions / App Services / Container Apps calling Graph? | HYBRID | `05-permission-surface` (Graph-permission-bearing SPs); customer maps to compute |
| 23 | ADF / Synapse / Logic Apps with external auth connections? | CONVERSATION | — |
| 24 | APIM backend auth? | CONVERSATION | — |
| 25 | Multi-tenant app registrations? | DATA | `02-inventory` (signInAudience column) |
| 26 | Third-party SaaS requiring admin consent? | DATA | `02-inventory` (publisherName ≠ tenant + appRoleAssignments present) |
| 27 | Subscriptions in scope? | DATA | `01-tenant-context` |
| 28 | Azure Arc with MI? | CONVERSATION | — |

## Sensitivity & Risk

| # | Question | Source | Script |
|---|----------|--------|--------|
| 29 | Workloads with Graph **application** permissions? | DATA | `05-permission-surface` |
| 30 | Highly privileged Graph permissions? | DATA | `05-permission-surface` (classified PRIVILEGED tier) |
| 31 | Sub-scope Owner / Contributor / UAA on workload identities? | DATA | `05-permission-surface` (Azure RBAC section) |
| 32 | Access to sensitive data? | CONVERSATION | — |
| 33 | Past compromised SP incidents? | CONVERSATION | — |
| 34 | Plain-text secrets in code / config? | CONVERSATION | — |
| 35 | Sub-level Contributor/Owner on pipelines? | DATA | `05-permission-surface` |
| 36 | Long-lived unrotated secrets (>12 months)? | DATA | `03-credential-hygiene` |
| 37 | Highest blast-radius workload? | HYBRID | `05-permission-surface` shows candidates; customer confirms business criticality |
| 38 | Formal sensitivity classification? | CONVERSATION | — |
| 39 | Broad federated credential subjects? | DATA | `04-federated-credentials` (subject classifier: WILDCARD / BROAD / NARROW) |

## Lifecycle & Ownership

| # | Question | Source | Script |
|---|----------|--------|--------|
| 40 | Owner replacement after developer departure? | CONVERSATION | — |
| 41 | Offboarding process? | CONVERSATION | — |
| 42 | App reg tied to CMDB? | HYBRID | `02-inventory` (tags column — empty tags is a finding) |
| 43 | Active vs retired tracking? | CONVERSATION | — |
| 44 | Decommission process at project end? | CONVERSATION | — |
| 45 | Orphaned app regs found in past? | CONVERSATION | — |
| 46 | Credentials from departed contractors? | HYBRID | `06-stale-and-orphaned` |
| 47 | Approval to create new app regs? | CONVERSATION | — |
| 48 | Formal MI lifecycle policy? | CONVERSATION | — |
| 49 | RBAC cleanup on resource delete? | CONVERSATION | — |
| 50 | Maximum age for no-sign-in SP? | CONVERSATION | — |
| 51 | Alerting on system-assigned MI delete? | CONVERSATION | — |

## Secrets Hygiene

| # | Question | Source | Script |
|---|----------|--------|--------|
| 52 | Max permitted secret lifetime? | DATA | `03-credential-hygiene` (max(endDateTime - startDateTime) across all secrets) |
| 53 | Defined rotation schedule? | CONVERSATION | — |
| 54 | Key Vault used for secrets? | CONVERSATION | — |
| 55 | Key Vault RBAC vs access policies? | DATA | `07-monitoring-coverage` (Key Vault access model inventory across in-scope subs) |
| 56 | Secret scanning in source control? | CONVERSATION | — |
| 57 | Secrets found in code/logs in past 12 mo? | CONVERSATION | — |
| 58 | Certs preferred over secrets? | DATA | `03-credential-hygiene` (ratio of key vs password credentials) |
| 59 | Pre-expiry notifications? | CONVERSATION | — |
| 60 | Centralised credential inventory? | CONVERSATION | — |
| 61 | Third-party vault bypass? | CONVERSATION | — |
| 62 | Cert storage location? | CONVERSATION | — |
| 63 | KV soft-delete + purge protection? | DATA | `07-monitoring-coverage` (KV configuration across in-scope subs) |

## Permission Hygiene

| # | Question | Source | Script |
|---|----------|--------|--------|
| 64 | New Graph app permission request process? | CONVERSATION | — |
| 65 | Who grants admin consent? | CONVERSATION | — |
| 66 | Consent decisions documented? | CONVERSATION | — |
| 67 | Over-permissioned SPs? | DATA | `05-permission-surface` (count of permissions per SP, flag PRIVILEGED) |
| 68 | Approved Graph permission list? | CONVERSATION | — |
| 69 | Azure RBAC scope distribution? | DATA | `05-permission-surface` (scope distribution chart) |
| 70 | Sub-Owner / Contributor on workload identity? | DATA | `05-permission-surface` |
| 71 | Cadence of RBAC review? | CONVERSATION | — |
| 72 | Custom Entra roles? | DATA | `01-tenant-context` |
| 73 | App role assignment review cadence? | CONVERSATION | — |
| 74 | SaaS app roles to internal APIs? | DATA | `05-permission-surface` (appRoleAssignments granted TO SPs) |
| 75 | Cross-tenant access policies for workload IDs? | DATA | `01-tenant-context` (cross-tenant access settings) |
| 76 | Detection of permission creep? | CONVERSATION | — |

## Monitoring & Detection

| # | Question | Source | Script |
|---|----------|--------|--------|
| 77 | SP sign-in logs collected? Where? | DATA | `07-monitoring-coverage` (diagnostic setting destinations for Entra logs) |
| 78 | Retention period? | DATA | `07-monitoring-coverage` |
| 79 | Anomaly alerts on SP sign-in? | CONVERSATION | — |
| 80 | Sentinel deployed? | DATA | `07-monitoring-coverage` (Log Analytics workspaces with SecurityInsights solution) |
| 81 | Audit logs ingested into SIEM? | DATA | `07-monitoring-coverage` |
| 82 | SP sign-in alert ownership? | CONVERSATION | — |
| 83 | Workload Identities Premium SKU? | DATA | `01-tenant-context` |
| 84 | Identity Protection enabled? Risky workload identities reviewed? | DATA | `01-tenant-context` (IP enablement) + risky-workload-identity count if licensed |
| 85 | CA on workload identities? | DATA | `08-ca-for-workload-identities` |
| 86 | Alerts on new credentials added? | CONVERSATION | — |
| 87 | Alerts on new admin consent grants? | CONVERSATION | — |
| 88 | Review process for FIC config changes? | CONVERSATION | — |
| 89 | Defender for Cloud MI recommendations reviewed? | CONVERSATION | — |

## Tooling & Automation, Compliance, Future State

Blocks 8–10 of the question file are **almost entirely conversational** (process, regulatory frameworks, organisational goals). No data extraction. The toolkit's job here is just to surface the customer's stated maturity vs the technical reality the earlier scripts already exposed, e.g.:

- Customer says "we use Terraform for everything" → cross-check `02-inventory` for app registrations with no tags / no description (often manual portal creations).
- Customer says "we rotate secrets every 90 days" → cross-check `03-credential-hygiene` long-lived count.
- Customer says "we'll eliminate all secrets" → present `03-credential-hygiene` baseline + `04-federated-credentials` adoption to anchor the goal.

These dissonance moments are some of the most valuable in the session. Use them carefully.
