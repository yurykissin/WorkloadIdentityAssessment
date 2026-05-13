# Workload Identity Assessment Toolkit

Read-only PowerShell scripts + ARM-based one-click deploy that inventory the
**workload identity surface** in a Microsoft Entra tenant + linked Azure
subscriptions and produce a single self-contained HTML report with findings
and recommendations.

The scripts never modify state. They call read-only Microsoft Graph and Azure
Resource Manager endpoints only.

## What it produces

- CSV / JSON dumps of the current workload-identity surface (app
  registrations, service principals, managed identities, federated
  credentials, credentials, permissions, sign-in activity, monitoring
  coverage, Conditional Access policies)
- A prioritized findings + recommendations HTML report
  (`output/<ts>/report-<ts>.html`) — see screenshots in the
  [root README](../README.md#sample-report)
- A summary written to console after each script run

## Two ways to run

| Mode | Best for | Doc |
|------|---------|-----|
| **Local PowerShell** | Iterating on the scripts, debugging, dev | this README, below |
| **One-click ARM** | Running against a tenant where you don't want to install modules locally; producing a sharable report URL | [`deploy/README.md`](deploy/README.md) |

## Prerequisites (local mode)

| Requirement | Value |
|-------------|-------|
| PowerShell | 7.2+ (Windows / macOS / Linux) |
| Microsoft Graph PowerShell SDK | Installed via `00-prereqs.ps1` |
| Az PowerShell module | Installed via `00-prereqs.ps1` |
| `Microsoft.Graph` scopes (delegated, signed in interactively) | `Application.Read.All`, `Directory.Read.All`, `Policy.Read.All`, `AuditLog.Read.All`, `IdentityRiskEvent.Read.All`, `RoleManagement.Read.Directory` |
| Azure RBAC | `Reader` on subscriptions in scope |

Run `./scripts/00-prereqs.ps1` first — it installs modules and validates that
the signed-in user has the required scopes/roles.

## Layout

```
assessment/
├── README.md                          ← this file
├── scripts/
│   ├── 00-prereqs.ps1                 ← module install + permission check
│   ├── 01-tenant-context.ps1          ← tenant info, licenses, auth policy
│   ├── 02-inventory.ps1               ← MIs, SPs, app regs
│   ├── 03-credential-hygiene.ps1      ← secrets vs certs, lifetime, expiry
│   ├── 04-federated-credentials.ps1   ← FICs (CI/CD, agent, etc.)
│   ├── 05-permission-surface.ps1      ← Graph app-roles + Azure RBAC
│   ├── 06-stale-and-orphaned.ps1      ← unused / unowned identities
│   ├── 07-monitoring-coverage.ps1     ← diag settings, LAW, KV
│   ├── 08-ca-for-workload-identities.ps1  ← CA policy targeting WIs
│   ├── 09-html-report.ps1             ← consolidated HTML report
│   └── run-all.ps1                    ← runs 01..09 in order
├── deploy/                            ← ARM one-click
│   ├── README.md
│   ├── azuredeploy.json
│   ├── azuredeploy.parameters.json
│   └── grant-graph-permissions.ps1    ← helper for required app-roles
├── docs/screenshots/                  ← report screenshots used by READMEs
└── output/                            ← per-run JSON/CSV/HTML (gitignored)
```

## Quick start (local)

```powershell
# 1. Install modules and validate permissions
./scripts/00-prereqs.ps1

# 2. Sign in (interactive)
Connect-MgGraph -Scopes 'Application.Read.All','Directory.Read.All',`
    'Policy.Read.All','AuditLog.Read.All','IdentityRiskEvent.Read.All',`
    'RoleManagement.Read.Directory'
Connect-AzAccount

# 3. Run all collectors + report
./scripts/run-all.ps1

# 4. Open the report
start ./output/<ts>/report-<ts>.html      # Windows
open  ./output/<ts>/report-<ts>.html      # macOS
xdg-open ./output/<ts>/report-<ts>.html   # Linux
```

Each script can also be run independently — handy for re-collecting one slice
of the data without re-running everything.

## Running individual scripts

```powershell
./scripts/01-tenant-context.ps1
./scripts/02-inventory.ps1
# ...
./scripts/09-html-report.ps1   # picks up the latest output of each 01..08
```

`09-html-report.ps1` accepts `-RunDir <ts>` to pin to a specific run, and
`-OutputDir <path>` if your output dir differs from `./output`.

## Output structure

```
output/
└── 20260101-120000/
    ├── 01-tenant-context.json
    ├── 01-tenant-context.csv
    ├── 02-inventory.json
    ├── 02-inventory.csv
    ├── 03-credential-hygiene.json
    ├── ...
    └── report-20260101-120000.html
```

Outputs include tenant identifiers, app registration display names, service
principal IDs, and other potentially sensitive data — **never commit them**.
The repo's `.gitignore` already excludes `assessment/output/`.

## Findings model

The HTML report classifies findings into four severities:

| Tier | Meaning |
|------|---------|
| **HIGH** | Active risk or compliance gap; remediate ASAP. |
| **MED** | Hygiene issue or governance gap; remediate within the quarter. |
| **LOW** | Best-practice deviation; address opportunistically. |
| **INFO** | Surface area worth reviewing; no automatic remediation implied (e.g. first-party Microsoft SPs with privileged Graph permissions). |

Each finding includes a one-sentence explanation and a concrete
recommendation pointing at the relevant Entra portal path or KB article.

## Limitations

- Scripts do not enumerate every Azure subscription unless you have access
  to it — `Reader` on each subscription is required for full RBAC coverage.
- Identity Protection signals (Risky workload identities) require
  Workload Identities Premium; absence is reported as a finding.
- Conditional Access for workload identities also requires Workload
  Identities Premium.

## Related

- [Root README](../README.md) — repo overview + sample report screenshots.
- [`../kb/02-governance/`](../kb/02-governance/) — policy templates the
  findings map back to.
- [`../kb/03-management/04-monitoring-and-alerts.md`](../kb/03-management/04-monitoring-and-alerts.md)
  — what to wire up after the assessment.
