# Plan — WorkloadIdentity engagement

## Engagement context

- **Customer:** TBD (capture in decision log).
- **Trigger:** customer call to define/design workload & managed identity —
  architecture, governance, management.
- **Reference deliverable:** prior consultant artifact §§8.12–8.14
  (App Registrations / Workload Identities & Managed Identities / Identity
  Monitoring & Secure Score). Format = numbered sections + policy /
  required-value tables.

## Deliverable batches

### Batch 1 — Call-prep (priority: tomorrow)
- `kb/00-call-prep/01-discovery-questions.md`
- `kb/00-call-prep/02-decision-log-template.md`
- `kb/00-call-prep/03-talking-points.md`

### Batch 2 — Architecture
- `kb/01-architecture/01-workload-identity-taxonomy.md` — MI (system / user
  assigned), SP, app registration, federated workload identity, federated
  credentials. Definitions + when-each-applies.
- `kb/01-architecture/02-when-to-use-which.md` — decision matrix (Azure
  resource? cross-tenant? on-prem? CI/CD? K8s?).
- `kb/01-architecture/03-reference-architectures.md` — Azure-hosted app,
  AKS workload, GitHub Actions OIDC → Azure, Azure → external API,
  on-prem service via federation.
- `kb/01-architecture/04-trust-model-and-token-flow.md` — issuer, audience,
  client-credentials grant, MSI endpoint, IMDS, federated assertion exchange.
- `kb/01-architecture/05-naming-and-tagging.md` — proposed convention.

### Batch 3 — Governance (mirror §§8.12–8.14 exactly)
- `kb/02-governance/01-app-registration-policy.md` (style of §8.12).
- `kb/02-governance/02-workload-identity-policy.md` (style of §8.13.1).
- `kb/02-governance/03-credential-and-secret-policy.md` (style of §8.13.2).
- `kb/02-governance/04-permission-assignment-policy.md` (style of §8.13.3).
- `kb/02-governance/05-ownership-and-accountability.md` — RACI.
- `kb/02-governance/06-exception-process.md` — when/how to grant exceptions.

### Batch 4 — Management
- `kb/03-management/01-lifecycle-create-to-retire.md` — request → provision
  → operate → review → retire.
- `kb/03-management/02-credential-rotation-runbook.md`.
- `kb/03-management/03-access-reviews.md` — cadence, scope, signoff.
- `kb/03-management/04-monitoring-and-alerts.md` — style of §8.14, focused
  on workload identity signals.
- `kb/03-management/05-incident-response-workload-identity.md` — leaked
  secret, compromised SP, rogue consent.
- `kb/03-management/06-tooling-graph-bicep-pim-for-groups.md` — what
  tooling to use for what.

## Build approach
Single Sonnet writer agent dispatched with full article list, absolute paths,
and verification clause (per INSTRUCTIONS.md §6). After write: ls/wc verify,
build INDEX, register in `_nrt-search.sh`, smoke-test search.

## Out of scope (v1)
- IaC / Bicep samples (add `AzureLab/` later if customer wants).
- Customer-specific tenant data.
- Migration plans from existing customer SPs (separate engagement).
