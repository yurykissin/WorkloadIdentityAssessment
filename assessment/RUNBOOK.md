# Working Session Runbook — Workload Identity Assessment

90-minute agenda. Pre-flight is done before the call. During the call the consultant runs scripts live with the customer, walks the data on screen, and fills in `REPORT-TEMPLATE.md` together.

## Pre-flight (before the call — ~30 min, alone)

1. Confirm Azure CLI / PowerShell login to the customer tenant (consultant should already have Application Administrator + Reader on subscriptions, or be sharing screen with a customer admin).
2. Run `./scripts/00-prereqs.ps1` on the consultant's machine.
3. Run `./scripts/run-all.ps1 -OutputDir ./output -SubscriptionIds @('...')` and let it complete (5–15 min depending on tenant size).
4. Skim the summary. Flag anything surprising — those become talking points.
5. Open `REPORT-TEMPLATE.md` in a split screen ready to fill in.
6. Have `../kb/00-call-prep/01-discovery-questions.md` open in another tab.

## Working session — 90 minutes

| Block | Time | Activity |
|-------|-----:|----------|
| 0. Welcome + agenda | 5 | Frame the session: today we'll inventory current state, identify gaps, and walk away with a prioritized backlog. Show the discovery question doc to set expectations on scope. |
| 1. Tenant context | 5 | Open `output/<ts>/01-tenant-context.json`. Walk: tenant ID, licenses present, Workload Identities Premium gate, P2 gate. |
| 2. Current State + Inventory | 15 | Run/show `02-inventory.csv`. Walk numbers (count of app regs, SPs, MIs). Ask the org questions from the **Current State** and **Workload Inventory** blocks in `01-discovery-questions.md` that data alone can't answer (ownership, approval process, dormancy). Fill in REPORT §1–2. |
| 3. Sensitivity & Risk | 10 | Show `05-permission-surface.csv` filtered to privileged Graph permissions + sub-scope RBAC. Show `03-credential-hygiene.csv` for plain-text-secrets-in-config probability. Ask the qualitative risk questions. Fill in REPORT §3. |
| 4. Lifecycle & Ownership | 10 | Show `06-stale-and-orphaned.csv`. Ask the offboarding / CMDB / decommission process questions. Fill in REPORT §4. |
| 5. Secrets Hygiene | 10 | Show `03-credential-hygiene.csv` summary (long-lived, expired-still-present, multi-credential SPs). Ask the Key Vault adoption / scanning questions. Fill in REPORT §5. |
| 6. Permission Hygiene | 5 | Drill `05-permission-surface.csv`. Show the worst offenders. Ask the consent process question. Fill in REPORT §6. |
| 7. Monitoring & Detection | 10 | Show `07-monitoring-coverage.json` (diagnostic settings, Sentinel content), `08-ca-for-workload-identities.csv`. Ask the SOC / response questions. Fill in REPORT §7. |
| 8. Tooling, Compliance, Future State | 10 | Conversational only. Cover **Tooling & Automation**, **Compliance**, **Future State Goals** blocks of `01-discovery-questions.md`. Fill in REPORT §8–10. |
| 9. Backlog + close | 10 | Look at the gap list that emerged. Together rank top 5–8 remediation items by impact + effort. Confirm owners + rough timeline. Schedule the next session. |

## Facilitation tips

- **Run nothing live for the first time during the call.** Always pre-flight.
- **Read the data on screen with them.** Don't summarise. They need to see their own tenant's numbers.
- **When a script finds something embarrassing** (e.g., a 5-year-old client secret with Directory.ReadWrite.All on a subscription Owner), don't dwell. Note it, move on, come back at backlog time. Customer dignity matters.
- **If the customer answers "I don't know" to a process question** — that's a finding. Mark it as an action item ("define X process") in the backlog.
- **Never modify their tenant.** Even helpful changes. The toolkit is read-only and the consultant should be too. Changes belong to the customer's own change process.

## Outputs at end of session

1. `REPORT-TEMPLATE.md` (renamed `report-<customer>-<date>.md`) — fully populated.
2. The `output/<ts>/` folder — raw evidence, attached to the report.
3. A prioritized remediation backlog (markdown or shared with the customer's tracker).
4. Next session date booked.

## If you run out of time

Don't try to finish everything in 90 minutes for a complex tenant. Time-box:
- **First session:** blocks 0–4 (current state + inventory + risk + lifecycle).
- **Second session:** blocks 5–8 (hygiene + monitoring + future state + backlog).

The pre-flight script run already produced all evidence, so the second session is faster.
