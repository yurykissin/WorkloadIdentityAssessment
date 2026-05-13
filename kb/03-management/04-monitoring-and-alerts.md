# Monitoring & Alerts — Workload Identities

Effective monitoring of workload identities closes the gap between governance policy and ground truth. Service principals and managed identities generate a rich audit and sign-in log stream, but that signal is valuable only if it is collected, retained, and acted upon. This document defines what to monitor, what to alert on, and what Microsoft Sentinel content is available to operationalise that monitoring.

---

## Monitoring Table

| Area to Monitor                                     | What to Collect                                                    | Required Alert / Action                                                                                    | Log Source                                          |
|-----------------------------------------------------|--------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------|-----------------------------------------------------|
| Service principal sign-ins (non-interactive)        | All non-interactive sign-in events for service principals          | Alert on: new source IP not seen in 30 days; new resource (audience) not seen before; sign-in after-hours for workloads with defined operational window; sustained high failure rate (> 10 failures in 5 min) | Entra non-interactive sign-in logs → Log Analytics |
| Service principal sign-in failures                  | Failed sign-in events with error code and reason                   | Alert on error codes 70011 (invalid scope), 7000218 (blocked by appManagementPolicy), 50176 (CA block)    | Entra non-interactive sign-in logs → Log Analytics |
| Managed identity token requests                     | IMDS token requests are not logged by Entra; use Azure resource activity logs as a proxy | Alert on Azure resource configuration changes that add a new MI attachment                              | Azure Activity Log → Log Analytics                  |
| App registration changes — credentials              | Audit log events: `Update application - Certificates and secrets management` | Alert (high priority) on: new credential added to any app registration; existing credential deleted outside a rotation ticket window | Entra audit log → Log Analytics / Sentinel        |
| App registration changes — permissions              | Audit log events: `Add delegated permission grant`, `Add app role assignment to service principal` | Alert on: new Graph application permission granted; new app role assignment where the resource is a sensitive API | Entra audit log → Log Analytics / Sentinel        |
| App registration changes — owners / URIs            | Audit log events: `Update application`, `Add owner to application` | Alert on: owner added or removed from an app registration; redirect URI added or modified               | Entra audit log → Log Analytics / Sentinel          |
| Admin consent grants                                | Audit log event: `Consent to application`                          | Alert on every admin consent grant to an application permission; verify against known-good approved list  | Entra audit log → Log Analytics / Sentinel          |
| Risky workload identities (Identity Protection)     | Risk detections for service principals (anomalous token, suspicious sign-in, threat intelligence match) | Weekly review of Identity Protection > Risky workload identities blade; Sentinel incident on high-risk detection | Entra Identity Protection → Log Analytics (requires Workload Identities Premium) |
| Conditional Access for workload identities          | CA sign-in result: `success`, `failure`, `reportOnly`              | Daily review of report-only events; alert on block events for high-value SPs; alert on unexpected CA policy bypass | Entra sign-in logs (CA detail) → Log Analytics   |
| Federated credential changes                        | Audit log event: `Update application - Federated identity credentials` | Alert (high priority) — issuer, subject, or audience change on any federated credential is a high-confidence indicator of supply chain or identity tampering | Entra audit log → Log Analytics / Sentinel       |
| Privileged Entra role activations on SPs            | Audit log: `Add member to role`, PIM log: `PIM activation`         | Alert on every role assignment to a service principal; alert on every PIM activation by a SP            | Entra audit log + PIM audit → Log Analytics / Sentinel |
| Azure RBAC changes on workload identities           | Azure Activity Log: `Microsoft.Authorization/roleAssignments/write` | Alert on new RBAC assignment where the principal is a service principal or managed identity, at subscription scope or higher | Azure Activity Log → Log Analytics             |
| Stale credentials (approaching expiry)              | Weekly scheduled query on app registration `passwordCredentials.endDateTime` and `keyCredentials.endDateTime` | Alert at 30 / 14 / 7 / 1 day thresholds to credential owner and Identity Security                   | Graph API scheduled query → Automation / Alert     |
| Orphaned workload identities                        | Monthly: SPs with no owner, no sign-in in 90 days                  | Monthly report to Application Administrator review queue                                                   | Graph API scheduled query → Logic App / workbook   |
| Key Vault access by workload identities             | Key Vault diagnostic logs — `SecretGet`, `CertificateGet` operations | Alert on unexpected principal (OID not matching the expected workload MI/SP) accessing a KV secret        | Key Vault diagnostic logs → Log Analytics          |

---

## Log Retention Requirements

| Log Type                         | Minimum Retention | Preferred Retention |
|----------------------------------|-------------------|---------------------|
| Entra non-interactive sign-in    | 90 days           | 365 days            |
| Entra audit log                  | 90 days           | 365 days            |
| Entra Identity Protection events | 90 days           | 365 days            |
| Azure Activity Log               | 90 days           | 365 days            |
| Key Vault diagnostic logs        | 90 days           | 365 days            |

Configure via:
```
Microsoft Entra admin center > Monitoring & health > Diagnostic settings
  > Add diagnostic setting
  > Categories: NonInteractiveUserSignInLogs, AuditLogs, RiskyServicePrincipals, ServicePrincipalRiskEvents
  > Destination: Log Analytics workspace / Storage account
```

---

## Sentinel Content

The following Microsoft Sentinel content hub solutions and analytic rules are relevant to workload identity monitoring. Install from the Sentinel content hub and validate rules in report-only mode before enabling alert generation.

### Content Hub Solutions to Install

| Solution Name                        | Relevant Coverage                                                        |
|--------------------------------------|--------------------------------------------------------------------------|
| Microsoft Entra ID                   | Entra sign-in and audit analytics; risky sign-in; anomalous token rules  |
| Microsoft Entra ID Protection        | Risky user and (with licence) risky workload identity rules              |
| Azure Activity                       | RBAC assignment changes; ARM-level activity anomalies                    |
| Azure Key Vault                      | Anomalous Key Vault access; secret access by unexpected principals       |

### Specific Analytic Rules of Interest

| Rule Name (approximate — verify in content hub)                         | What it detects                                                      |
|-------------------------------------------------------------------------|----------------------------------------------------------------------|
| New credentials added to application or service principal               | Secret or certificate added outside rotation window                 |
| Application credential activity for nonexistent or invalid applications | Credential use on a deleted or disabled app registration            |
| Suspicious application consent — AppID, permission                      | Admin consent to high-risk Graph permissions                        |
| Service principal created and immediately used — anomalous              | SP created and used within a short window (potential attacker TTPs) |
| Federated identity credential added or modified                         | Federated credential change on any app registration                 |
| Azure Role Assignment to service principal at subscription scope        | RBAC privilege escalation indicator                                 |
| Anomalous sign-in from service principal — new geolocation              | SP sign-in from an unexpected country / IP range                    |
| Risky service principal risk level increase                             | Identity Protection risk escalation (Workload Identities Premium)   |
| Mass secret read from Key Vault                                         | Potential exfiltration via compromised MI / SP token                |

### Workbook — Workload Identity Monitoring

The "Microsoft Entra Workload Identities" workbook (available in the Entra admin center under Monitoring & health > Workbooks) provides an inventory view, sign-in activity, and credential expiry visibility. Deploy as a shared workbook in the Log Analytics workspace for SOC daily review.

---

## Alert Severity Classification

Assign alert severity at ingestion to prioritise SOC response.

| Alert / Event                                                 | Suggested Severity | Target Response SLA     |
|---------------------------------------------------------------|--------------------|--------------------------|
| New credential added to high-value app registration (Tier 0/1) | Critical          | 30 minutes               |
| Federated credential issuer or subject modified               | Critical           | 30 minutes               |
| Risky workload identity — risk level High or Critical         | High               | 1 hour                   |
| SP sign-in from new geolocation / unexpected IP               | High               | 1 hour                   |
| Admin consent granted for privileged Graph permission         | High               | 1 hour                   |
| New RBAC Owner/UAA assignment to service principal            | High               | 1 hour                   |
| Conditional Access block for workload identity sign-in        | Medium             | 4 hours                  |
| SP sign-in after-hours for non-24x7 workload                  | Medium             | 4 hours                  |
| New credential added to standard app registration             | Low                | 24 hours                 |
| Credential approaching expiry (30 days)                       | Informational      | Within 2 business days   |
| Orphaned SP detected in monthly report                        | Informational      | Within 5 business days   |

---

## Diagnostic Settings Configuration Reference

Configure the following diagnostic settings to ensure all relevant logs reach the Log Analytics workspace.

```
Microsoft Entra admin center > Monitoring & health > Diagnostic settings > + Add diagnostic setting
  Diagnostic setting name: diag-entra-<workspace-name>
  
  Categories to enable:
  ✅ AuditLogs
  ✅ SignInLogs
  ✅ NonInteractiveUserSignInLogs      ← key for service principal sign-ins
  ✅ ServicePrincipalSignInLogs        ← dedicated SP sign-in category
  ✅ RiskyServicePrincipals            ← requires Workload Identities Premium
  ✅ ServicePrincipalRiskEvents        ← requires Workload Identities Premium
  
  Destination: Log Analytics workspace / Event Hub → SIEM
```

Verify service principal sign-ins are flowing within 24 hours of configuration by querying:
```kusto
AADServicePrincipalSignInLogs
| where TimeGenerated > ago(1h)
| summarize count() by ServicePrincipalName
| order by count_ desc
```

---

## Monthly Monitoring Health Check

Run the following checks monthly and report status to Identity Security.

| Check                                                              | Tool / Method                                                                           | Pass Criterion                              |
|--------------------------------------------------------------------|-----------------------------------------------------------------------------------------|---------------------------------------------|
| Non-interactive sign-in logs flowing with < 1h lag                | Log Analytics: `AADServicePrincipalSignInLogs | summarize max(TimeGenerated)`             | Max ingestion lag < 1 hour                  |
| Alert rules firing on credential additions                         | Sentinel: review alert rule `New credentials added to application`                      | Rule enabled; at least 1 test alert verified|
| Risky workload identities reviewed                                 | Entra admin center > Identity Protection > Risky workload identities                    | Zero unreviewed High/Critical risk items    |
| Federated credential change alert functional                       | Verify audit log event routes to Sentinel alert                                         | Alert triggered within 5 min of test change |
| Orphaned SP report generated                                       | Monthly Graph query executed; results reviewed                                          | Report delivered; remediations tracked      |
| Stale credential report generated                                  | Weekly expiry query executed                                                            | No credentials within 7-day expiry window unaddressed |

---


## References
- https://learn.microsoft.com/en-us/entra/identity/monitoring-health/concept-sign-in-log-activity-details
- https://learn.microsoft.com/en-us/azure/sentinel/overview
- https://learn.microsoft.com/en-us/entra/id-protection/concept-workload-identity-risk

