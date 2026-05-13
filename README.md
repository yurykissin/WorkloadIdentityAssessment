# WorkloadIdentity — customer engagement deliverable

Time-bound project: customer call about defining/designing **workload &
managed identity** end-to-end (architecture, governance, management).

Format mirrors the consultant's previously-delivered customer report style
(numbered sections, policy / required-value tables — see §§8.12–8.14 of the
prior deliverable as the reference shape).

## How to use

| Phase | Open this |
|-------|-----------|
| **Before the call** | `kb/00-call-prep/01-discovery-questions.md` — read questions to drive the conversation. `kb/00-call-prep/03-talking-points.md` — opening + key messages. **Pre-flight the assessment toolkit** — see `assessment/README.md` and run `assessment/scripts/run-all.ps1` so live data is ready when the customer joins. |
| **During the call** | Follow `assessment/RUNBOOK.md` (90-min agenda). Walk evidence in `assessment/output/<ts>/` with the customer. Capture decisions live in `kb/00-call-prep/02-decision-log-template.md` and fill in `assessment/REPORT-TEMPLATE.md`. |
| **After the call** | Hand the customer the populated report (`assessment/REPORT-TEMPLATE.md` filled in) plus the relevant `kb/01-architecture/`, `kb/02-governance/`, `kb/03-management/` articles as the design baseline. Backlog items map back to specific governance sections. |

## KB structure

| Section | Purpose |
|---------|---------|
| [`kb/00-call-prep/`](kb/00-call-prep/) | Discovery questions, decision log, talking points. Use day-of-call. |
| [`kb/01-architecture/`](kb/01-architecture/) | Workload identity taxonomy (MI / SP / app reg / federated WI), decision matrix, reference architectures, trust model, naming. |
| [`kb/02-governance/`](kb/02-governance/) | Policy / required-value tables: app reg, workload identity, credentials, permissions, ownership, exceptions. |
| [`kb/03-management/`](kb/03-management/) | Operations: lifecycle, credential rotation, access reviews, monitoring, IR, tooling. |
| [`assessment/`](assessment/) | **Read-only** PowerShell toolkit that walks the discovery questions in `kb/00-call-prep/01-discovery-questions.md` against the customer's actual tenant + subscriptions. Produces evidence files + a fillable report. Used in the working-session phase. |

## Federation

Layer 1 portal-walkthrough (field-by-field) content for app registrations
already lives at
`/Volumes/data/vscode/MyProjects/entra-nrt/kb/app-registrations/`.
This project does NOT duplicate it — articles here link out via "See also"
where a portal walkthrough is the right next read for the customer.

This project's `kb/INDEX.md` is registered with the federated search at
`/Volumes/data/vscode/MyProjects/_nrt-search.sh`.

## Conventions (this project)

- Customer-facing tone: actionable, prescriptive.
- Every governance article uses the policy/required-value table shape from
  the prior §§8.12–8.14 deliverable.
- Top of every article: portal path(s) (Entra admin center / Azure portal).
- Bottom of every article: `## References` (1–3 learn.microsoft.com URLs).
- No customer-specific data committed — templates only. Fill in
  customer name, tenant ID, etc. in your own working copy or the
  decision log.

## Status

See [`PROGRESS.md`](PROGRESS.md).
