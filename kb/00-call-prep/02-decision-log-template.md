# Decision Log Template — Workload Identity Engagement

A fill-in template the consultant updates live during and immediately after the call. Complete all sections before sending the summary to the customer. Greyed placeholder rows show the expected format; replace or delete them.

---

## Engagement Metadata

| Field                   | Value                                   |
|-------------------------|-----------------------------------------|
| Customer                | `<customer>`                            |
| Engagement date         | YYYY-MM-DD                              |
| Consultant              | `<consultant-name>`                     |
| Customer attendees      | `<name, role>` / `<name, role>`         |
| Entra Tenant ID         | `<tenant-id>`                           |
| Subscriptions in scope  | `<subscription-name / id>`, ...         |
| Entra SKU in use        | P1 / P2 / Workload Identities Premium / Governance |
| Engagement phase        | Discovery / Design / Review / Sign-off  |
| Related ticket / SOW    | `<reference>`                           |
| Next meeting            | YYYY-MM-DD HH:MM UTC                    |

---

## Scope Decisions

### In Scope

- [ ] App registration governance policy
- [ ] Workload (managed) identity architecture
- [ ] Credential and secret policy
- [ ] Permission assignment policy
- [ ] Lifecycle management process
- [ ] Monitoring and alerting design
- [ ] CI/CD workload identity federation
- [ ] `<additional item>`

### Out of Scope

- [ ] Human identity governance (covered by separate engagement)
- [ ] B2C / External ID workloads
- [ ] `<explicitly excluded item>`

---

## Architecture Decisions

| ID  | Decision                          | Options Considered                                        | Chosen Option                  | Rationale                                           | Owner              | Due        | Status  |
|-----|-----------------------------------|-----------------------------------------------------------|--------------------------------|-----------------------------------------------------|--------------------|------------|---------|
| A01 | Identity type for Azure-hosted workloads | System-assigned MI / User-assigned MI / SP + secret    | `<chosen>`                     | `<rationale>`                                       | `<name>`           | YYYY-MM-DD | Open    |
| A02 | CI/CD pipeline identity           | SP + client secret / SP + cert / Federated credential (OIDC) | `<chosen>`                 | `<rationale>`                                       | `<name>`           | YYYY-MM-DD | Open    |
| A03 | AKS workload identity approach    | Pod identity (deprecated) / Azure Workload Identity add-on | `<chosen>`                   | `<rationale>`                                       | `<name>`           | YYYY-MM-DD | Open    |
| A04 | On-premises workload identity     | SP + cert / Federated credential via on-prem OIDC issuer  | `<chosen>`                     | `<rationale>`                                       | `<name>`           | YYYY-MM-DD | Open    |
| A05 | Naming convention                 | `<option 1>` / `<option 2>`                               | `<chosen>`                     | `<rationale>`                                       | `<name>`           | YYYY-MM-DD | Open    |
| A06 | `<decision>`                      | `<options>`                                               | `<chosen>`                     | `<rationale>`                                       | `<name>`           | YYYY-MM-DD | Open    |

---

## Governance Decisions

| ID  | Decision                                  | Options Considered                                        | Chosen Option                  | Rationale                                           | Owner              | Due        | Status  |
|-----|-------------------------------------------|-----------------------------------------------------------|--------------------------------|-----------------------------------------------------|--------------------|------------|---------|
| G01 | "Users can register applications" setting | Enabled / Disabled                                        | `<chosen>`                     | `<rationale>`                                       | `<name>`           | YYYY-MM-DD | Open    |
| G02 | Admin consent workflow                    | Enabled (workflow) / Disabled (block) / Enabled (no workflow) | `<chosen>`                 | `<rationale>`                                       | `<name>`           | YYYY-MM-DD | Open    |
| G03 | Client secret maximum lifetime            | 90 days / 180 days / 12 months / Banned                   | `<chosen>`                     | `<rationale>`                                       | `<name>`           | YYYY-MM-DD | Open    |
| G04 | Conditional Access for workload identities | Not implemented / Report-only / Enforced                  | `<chosen>`                     | `<rationale>` (requires Workload Identities Premium) | `<name>`          | YYYY-MM-DD | Open    |
| G05 | Access review cadence — privileged SPs    | Monthly / Quarterly / Semi-annual                         | `<chosen>`                     | `<rationale>`                                       | `<name>`           | YYYY-MM-DD | Open    |
| G06 | App management policy enforcement         | Tenant default only / Tenant default + per-app overrides  | `<chosen>`                     | `<rationale>`                                       | `<name>`           | YYYY-MM-DD | Open    |
| G07 | Exception approval authority              | Identity Security team / CISO / Governance Board          | `<chosen>`                     | `<rationale>`                                       | `<name>`           | YYYY-MM-DD | Open    |
| G08 | `<decision>`                              | `<options>`                                               | `<chosen>`                     | `<rationale>`                                       | `<name>`           | YYYY-MM-DD | Open    |

---

## Management Decisions

| ID  | Decision                                  | Options Considered                                        | Chosen Option                  | Rationale                                           | Owner              | Due        | Status  |
|-----|-------------------------------------------|-----------------------------------------------------------|--------------------------------|-----------------------------------------------------|--------------------|------------|---------|
| M01 | Credential rotation mechanism             | Manual / Key Vault auto-rotation / Graph PowerShell script | `<chosen>`                    | `<rationale>`                                       | `<name>`           | YYYY-MM-DD | Open    |
| M02 | Pre-expiry notification owner             | App owner / Central team / Both via Logic App alert       | `<chosen>`                     | `<rationale>`                                       | `<name>`           | YYYY-MM-DD | Open    |
| M03 | Sign-in log destination                   | Log Analytics only / Sentinel / Third-party SIEM          | `<chosen>`                     | `<rationale>`                                       | `<name>`           | YYYY-MM-DD | Open    |
| M04 | Sign-in log retention                     | 90 days / 180 days / 365 days                             | `<chosen>`                     | `<rationale>`                                       | `<name>`           | YYYY-MM-DD | Open    |
| M05 | Inventory tooling                         | Manual spreadsheet / Azure Resource Graph / Graph API + workbook | `<chosen>`              | `<rationale>`                                       | `<name>`           | YYYY-MM-DD | Open    |
| M06 | Orphaned SP remediation trigger           | 30 days no sign-in / 60 days / 90 days                    | `<chosen>`                     | `<rationale>`                                       | `<name>`           | YYYY-MM-DD | Open    |
| M07 | IaC tooling for identity resources        | Bicep / Terraform (AzAPI) / Mixed                         | `<chosen>`                     | `<rationale>`                                       | `<name>`           | YYYY-MM-DD | Open    |
| M08 | `<decision>`                              | `<options>`                                               | `<chosen>`                     | `<rationale>`                                       | `<name>`           | YYYY-MM-DD | Open    |

---

## Open Questions / Parking Lot

| #  | Question / Topic                                          | Raised by      | Date       | Status  |
|----|-----------------------------------------------------------|----------------|------------|---------|
| 1  | `<question>`                                              | `<name>`       | YYYY-MM-DD | Open    |
| 2  | `<question>`                                              | `<name>`       | YYYY-MM-DD | Open    |
| 3  | `<question>`                                              | `<name>`       | YYYY-MM-DD | Open    |

---

## Action Items

| #  | Action                                                    | Owner          | Due        | Status  |
|----|-----------------------------------------------------------|----------------|------------|---------|
| 1  | Share current app registration export (Graph query output) | `<name>`      | YYYY-MM-DD | Open    |
| 2  | Confirm Entra licence SKU and Workload Identities Premium status | `<name>` | YYYY-MM-DD | Open    |
| 3  | Identify two owners for each app registration in scope    | `<name>`       | YYYY-MM-DD | Open    |
| 4  | Provide consultant read access to Entra tenant (Global Reader) | `<name>`  | YYYY-MM-DD | Open    |
| 5  | `<action>`                                                | `<name>`       | YYYY-MM-DD | Open    |

---

## Risks Accepted / Exceptions Granted

| #  | Policy Clause                             | Exception Granted                         | Compensating Controls                     | Expiry     | Approved by    |
|----|-------------------------------------------|-------------------------------------------|-------------------------------------------|------------|----------------|
| 1  | `<policy clause ref>`                     | `<what was waived>`                       | `<controls in place>`                     | YYYY-MM-DD | `<name>`       |

---

## Notes

> _Free-text space for the consultant. Record key verbatim customer statements here, especially any that indicate risk tolerance, blockers, or political constraints._

---

## References
- https://learn.microsoft.com/en-us/entra/workload-id/workload-identities-overview
- https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/what-is-application-management
