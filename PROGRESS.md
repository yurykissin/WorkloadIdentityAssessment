# PROGRESS — WorkloadIdentity

| Batch | Status | Files | Lines |
|-------|--------|------:|------:|
| 1 — Call-prep        | ✅ done | 3  | 440  |
| 2 — Architecture     | ✅ done | 5  | 1,139 |
| 3 — Governance       | ✅ done | 6  | 909  |
| 4 — Management       | ✅ done | 6  | 1,170 |
| INDEX build          | ✅ done | 1 (`kb/INDEX.md`) | 307 (281 headings) |
| Federation register  | ✅ done | — | added to `_nrt-search.sh` + root README |
| Smoke-test search    | ✅ done | — | 4 representative terms returned WorkloadIdentity hits |
| 5 — Assessment toolkit | ✅ done | 14 | ~7,400 |

**Total content: 34 files, ~7,400+ lines (KB + assessment scripts).**

## Assessment toolkit (added for the working session)

| File | Purpose |
|------|---------|
| `assessment/README.md` | How to install + run the toolkit |
| `assessment/RUNBOOK.md` | 90-min working-session agenda |
| `assessment/00-discovery-to-evidence-map.md` | For each Q in `kb/00-call-prep/01-discovery-questions.md` → which script answers it (DATA / CONVERSATION / HYBRID classification) |
| `assessment/REPORT-TEMPLATE.md` | Fillable customer report — every metric maps to a script output cell |
| `assessment/scripts/00-prereqs.ps1` | Module install + Graph scope + Az role checklist |
| `assessment/scripts/01-tenant-context.ps1` | Tenant info, licenses (WI Premium / P2 / Governance), auth policy, role member counts, subscriptions |
| `assessment/scripts/02-inventory.ps1` | Unified inventory: app regs + SPs + MIs (Resource Graph) |
| `assessment/scripts/03-credential-hygiene.ps1` | Per-credential analysis: lifetime, expired-still-attached, long-lived, multi-cred SPs |
| `assessment/scripts/04-federated-credentials.ps1` | FICs on app regs + UA-MIs; subject classifier (WILDCARD / BROAD / NARROW); issuer categoriser |
| `assessment/scripts/05-permission-surface.ps1` | Graph app permission grants classified PRIVILEGED / PRIVILEGED_READ / STANDARD + Azure RBAC for all SPs |
| `assessment/scripts/06-stale-and-orphaned.ps1` | Sign-in age, owner classification (none / single / orphaned-owner-user-deleted / ok) |
| `assessment/scripts/07-monitoring-coverage.ps1` | Entra diag settings + LA workspace + Sentinel detection + Key Vault inventory (RBAC, soft-delete, purge protection) |
| `assessment/scripts/08-ca-for-workload-identities.ps1` | CA policies targeting workload identities + per-SP coverage % |
| `assessment/scripts/run-all.ps1` | Orchestrator — runs 01–08, writes `run-summary.md` + `.json` |

All 10 PowerShell scripts pass `[System.Management.Automation.Language.Parser]::ParseFile` syntax validation. Scripts are **read-only** — no `Set-`/`New-`/`Remove-`/`Update-` cmdlets, safe to run against production tenants.

## What's where (quick map)

- **Pre-call (morning of working session):** read `kb/00-call-prep/03-talking-points.md`. Run `assessment/scripts/run-all.ps1` to pre-flight the data — takes 5–15 min.
- **During the call:** follow `assessment/RUNBOOK.md` (90-min agenda). Walk `assessment/output/<ts>/` evidence with the customer block-by-block. Fill in `assessment/REPORT-TEMPLATE.md` and `kb/00-call-prep/02-decision-log-template.md` live.
- **Reference live (architecture questions):** `kb/01-architecture/02-when-to-use-which.md` decision matrix; `03-reference-architectures.md` 7 named arches.
- **Hand to customer post-call:** populated `assessment/REPORT-TEMPLATE.md` + the `kb/02-governance/` policy articles + `kb/03-management/` ops runbooks. Backlog items in §11 of the report map back to specific governance sections.

## Next (optional, not blocking)

- Add `AzureLab/` with Bicep samples for user-assigned MI, role assignment, federated credential — if customer wants IaC patterns post-engagement.
- Add `migration-tools/` for SP cleanup automation (e.g., disable stale, owner re-assignment) once customer agrees on remediation policy.
- Layer 1 articles in `entra-nrt/kb/governance/` and `entra-nrt/kb/monitoring/` are still empty — could be populated later from this content if needed for call-mode lookup during future calls.
