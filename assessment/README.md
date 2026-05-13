# WorkloadIdentity Assessment Toolkit

Tooling to walk through the discovery questions in `../kb/00-call-prep/01-discovery-questions.md` against the customer's **actual** tenant + subscriptions during the working session — not a synthetic lab.

## What it produces
- CSV / JSON dumps of the customer's current workload identity surface (app registrations, service principals, managed identities, federated credentials, credentials, permissions, sign-in activity, monitoring coverage, CA policies)
- A populated `REPORT-TEMPLATE.md` mapping each discovery question to a concrete answer + evidence file
- A prioritized remediation backlog the customer leaves the session with

## What it does NOT do
- Make changes. Every script is **read-only**. No `Set-`, `New-`, or `Remove-` cmdlets are used.
- Replace organisational discovery. Half the questions are about process / ownership / future state — those still come from the conversation. The toolkit answers the questions that data alone can answer, so meeting time is spent on the questions data **can't** answer.

## Prerequisites

| Item | Why |
|------|-----|
| PowerShell 7.x | Required for `Microsoft.Graph` and `Az` modules |
| `Microsoft.Graph` PowerShell SDK | App / SP / FIC / CA / Identity Protection queries |
| `Az.Accounts`, `Az.Resources` | Managed identity inventory, RBAC, diagnostic settings |
| `Microsoft.Graph` scopes (delegated, consultant signs in interactively) | `Application.Read.All`, `Directory.Read.All`, `Policy.Read.All`, `AuditLog.Read.All`, `IdentityRiskEvent.Read.All`, `RoleManagement.Read.Directory` |
| Azure read access to in-scope subscriptions | `Reader` is sufficient for all inventory; `Monitoring Reader` for diagnostic settings |
| `jq` (optional) | Pretty-print JSON output |

Run `./scripts/00-prereqs.ps1` first — it installs modules and validates the consultant's permissions.

## Layout
```
assessment/
├── README.md                          ← this file
├── RUNBOOK.md                         ← 90-min working session agenda
├── 00-discovery-to-evidence-map.md    ← Q → script/conversational mapping
├── REPORT-TEMPLATE.md                 ← fill in from script output + conversation
├── scripts/
│   ├── 00-prereqs.ps1                 ← module install + permission check
│   ├── 01-tenant-context.ps1          ← tenant + license inventory (Workload Identities Premium? P2? Governance?)
│   ├── 02-inventory.ps1               ← unified inventory of app regs, SPs, MIs
│   ├── 03-credential-hygiene.ps1      ← secrets / certs analysis (expiring, expired, long-lived)
│   ├── 04-federated-credentials.ps1   ← FICs everywhere (app reg + user-assigned MI), subject classifier
│   ├── 05-permission-surface.ps1      ← Graph app permissions classified + Azure RBAC at sub scope
│   ├── 06-stale-and-orphaned.ps1      ← no recent sign-in, no owner
│   ├── 07-monitoring-coverage.ps1     ← diagnostic settings on AAD logs + Sentinel detection
│   ├── 08-ca-for-workload-identities.ps1 ← CA policies targeting workload identities
│   └── run-all.ps1                    ← orchestrator (runs 01–08, prints summary)
└── output/                            ← results land here, .gitignored
```

## Typical run

```powershell
pwsh
cd assessment
./scripts/00-prereqs.ps1                  # one-time per machine
Connect-MgGraph -Scopes "Application.Read.All","Directory.Read.All","Policy.Read.All","AuditLog.Read.All","IdentityRiskEvent.Read.All","RoleManagement.Read.Directory"
Connect-AzAccount
./scripts/run-all.ps1 -OutputDir ./output -SubscriptionIds @('sub-id-1','sub-id-2')
```

Outputs land in `./output/<timestamp>/`. Each script produces a CSV and a JSON file. The orchestrator also prints a one-screen summary.

## During the session
Use `RUNBOOK.md` as the agenda. For each discovery question block, the consultant runs the relevant script (or refers to the already-completed run), reads the data with the customer, and captures the answer in `REPORT-TEMPLATE.md`.
