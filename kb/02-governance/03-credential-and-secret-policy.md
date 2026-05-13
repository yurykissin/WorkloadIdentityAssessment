# Credential and Secret Policy

Workload identity credentials — client secrets, certificates, and federated identity credential configurations — are the keys that allow an application to prove its identity to Microsoft Entra ID. Weak credential management is the most exploited vector in workload identity attacks. This policy sets binding requirements for credential type, lifetime, storage, rotation, and detection.

Path to configure:
```
Microsoft Entra admin center > Identity > Applications > App registrations > <app> > Certificates & secrets
Microsoft Graph > appManagementPolicies (tenant default and per-app)
Azure portal > Key Vault > Certificates / Secrets
```

---

## Policy Table

| Policy / Setting                                              | Required Value                                                                                                                                                          |
|---------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Default credential type preference order                      | **Managed identity (no credential) > Federated credential > Certificate > Client secret.** Deviations require written exception.                                       |
| Client secrets (password credentials)                         | **Approved exception only.** Use only where managed identity and federation are not supported by the workload scenario.                                                 |
| Client secret maximum lifetime                                | **180 days** for all new secrets. Existing secrets exceeding this limit must be rotated to comply within 90 days of this policy taking effect.                         |
| Client secret storage                                         | **Azure Key Vault only.** Never stored in source code, pipeline variables, environment variables (outside Key Vault reference resolution), configuration files, or email. |
| Client secret — pipeline usage                                | **Key Vault reference or runtime fetch only.** Never hardcoded in pipeline YAML or scripts.                                                                             |
| Certificate credentials                                       | **Preferred over client secrets** where managed identity and federation are not available.                                                                              |
| Certificate maximum lifetime                                  | **24 months** maximum. Certificates issued by Key Vault CA may use auto-renewal; manually managed certificates must be rotated before expiry.                          |
| Certificate private key storage                               | **Azure Key Vault or HSM only.** Private key must not be exported except under a documented exception (e.g., cross-environment migration).                              |
| Certificate key size and algorithm                            | **RSA 2048-bit minimum**; RSA 4096-bit or EC P-256 preferred for new issuances.                                                                                        |
| Federated identity credentials                                | **Preferred for CI/CD and cross-cloud scenarios.** No expiry on the credential object; the trust chain (external IdP signing key rotation) is managed by the external platform. |
| Federated credential subject                                  | **Exact match** — no wildcards in production. Subject must identify the specific source: repo + environment, K8s namespace + SA, or equivalent.                       |
| Federated credential audience                                 | **`api://AzureADTokenExchange`** (default) — do not change unless an approved exception documents the reason.                                                          |
| Pre-expiry alerts — client secrets                            | **30 / 14 / 7 / 1 day** warnings sent to the credential owner. Alert owner, not a generic mailbox.                                                                     |
| Pre-expiry alerts — certificates                              | **90 / 30 / 14 / 1 day** warnings sent to the credential owner.                                                                                                        |
| Expired credentials                                           | **Removed within 7 days** of expiry. Expired credentials left on an app registration are a hygiene indicator and increase the attack surface via confusion.            |
| Secret scanning in source control                             | **Required.** Secret scanning enabled on all repositories. Pipelines fail on detection. Retroactive scanning run on existing repositories at least annually.           |
| Secret scanning — response on detection                       | **Immediate rotation** of any detected credential. The old credential is revoked, not merely noted. Incident review completed.                                          |
| Centralised credential inventory                              | **Maintained.** All active credentials (secrets and certificates) tracked in the central inventory with owner, expiry, and rotation date. Reviewed quarterly.           |
| Multiple credentials on one app registration                  | **Maximum 2 active credentials simultaneously** — one in active use, one for overlap during rotation. Revoke the old credential after confirming the new one works.   |
| Credential rotation on owner change                           | **Required.** When an app registration changes owners, all existing client secrets must be rotated within 30 days.                                                      |
| Credential rotation on suspected compromise                   | **Immediate** — within 4 hours of detection. Revoke the compromised credential first; issue a new one only after containment is confirmed.                             |
| App management policy enforcement                             | **Tenant default `appManagementPolicy`** applies to all app registrations. Per-app override policies applied where stricter limits are needed for high-value apps.     |

---

## App Management Policy — Illustrative Configuration

The following JSON illustrates an `appManagementPolicy` object posted to Microsoft Graph that disables password credentials and caps certificate lifetime. This is not production-ready configuration — validate against your tenant before applying.

```json
POST https://graph.microsoft.com/v1.0/policies/appManagementPolicies

{
  "displayName": "<organization>-workload-identity-default-policy",
  "description": "Tenant default credential policy. Disables password credentials; caps certificate lifetime at 730 days.",
  "isEnabled": true,
  "restrictions": {
    "passwordCredentials": [
      {
        "restrictionType": "passwordAddition",
        "state": "disabled"
      }
    ],
    "keyCredentials": [
      {
        "restrictionType": "asymmetricKeyLifetime",
        "state": "enabled",
        "maxLifetime": "P730D"
      }
    ]
  }
}
```

To apply this as the **tenant default** (affects all app registrations unless overridden):
```http
PATCH https://graph.microsoft.com/v1.0/policies/defaultAppManagementPolicy
```
Use the same `restrictions` body. The tenant default does not require a separate POST.

To apply a **per-app override** (stricter or looser than the default for one specific app):
```http
POST https://graph.microsoft.com/v1.0/policies/appManagementPolicies          (create policy)
POST https://graph.microsoft.com/v1.0/applications/<objectId>/appManagementPolicies/$ref  (bind to app)
```

---

## Enforcement

| Control                                                        | Enforcement Mechanism                                                                                               |
|----------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------|
| Password credential prohibition                                | `appManagementPolicy` — `passwordAddition: disabled` on tenant default or per-app policy.                          |
| Certificate lifetime cap                                       | `appManagementPolicy` — `asymmetricKeyLifetime: P730D` (24 months).                                                |
| Secret scanning                                                | GitHub Advanced Security / ADO secret scanning / `detect-secrets` in pre-commit hooks.                             |
| Pre-expiry alerting                                            | Azure Monitor alert on `microsoft.aadiam/applications` `expiryDateTime` field; or Logic App / Function querying Graph `credentialExpiration` data. |
| Credential inventory review                                    | Quarterly: Graph query `GET /applications?$select=id,displayName,passwordCredentials,keyCredentials` exported to review queue. |
| Rotation on owner change                                       | Enforced via process control (owner change ticket triggers rotation workflow).                                      |

---

---

## Credential Inventory — Minimum Required Fields

The centralised credential inventory must record the following for each active credential:

| Field                   | Description                                                               |
|-------------------------|---------------------------------------------------------------------------|
| App / MI display name   | Human-readable name following naming convention                           |
| Object ID               | Entra directory object ID (immutable)                                     |
| Credential type         | `secret`, `certificate`, or `federated`                                   |
| Key ID                  | The `keyId` GUID for secrets and certificates; FIC name for federation    |
| Created date            | When the credential was issued                                            |
| Expiry date             | For secrets and certs; `N/A` for federated credentials                    |
| Owner (primary)         | Email of primary owner                                                    |
| Owner (secondary)       | Email of secondary owner                                                  |
| Storage location        | Key Vault name + secret name; or `platform-managed` for MIs               |
| Last rotation date      | Date of most recent rotation                                              |
| Exception reference     | Exception register ID if credential exists under a policy exception       |

Review the inventory quarterly. Any row with a missing owner, missing Key Vault reference, or expiry within 30 days is flagged for immediate action.

---

## Tenant-Level Credential Posture Scorecard

Use as a monthly indicator for the Governance Board.

| Indicator                                                       | Healthy Threshold                     | Data Source                                                    |
|-----------------------------------------------------------------|---------------------------------------|----------------------------------------------------------------|
| # client secrets older than 180 days                           | 0 (outside approved exceptions)       | Graph `passwordCredentials.endDateTime` on all applications    |
| # certificates expiring within 30 days                         | 0 (active rotation in progress)       | Graph `keyCredentials.endDateTime` on all applications         |
| # secrets stored in source code (detected)                     | 0                                     | Secret scanning alert report                                   |
| # app registrations with > 2 active credentials simultaneously | 0                                     | Graph `passwordCredentials` count per application              |
| # credentials on app registrations with no owner               | 0                                     | Cross-reference ownership + credential presence                |
| # Key Vault secrets with no expiry set                         | 0 (all workload credential secrets must have expiry) | Key Vault secret properties audit                  |

> **Enforcement note:** `appManagementPolicy` at tenant scope applies to all app registrations by default. Use per-application overrides only when a formal exception has been approved via `06-exception-process.md`.

---

## See Also

- `/Volumes/data/vscode/MyProjects/entra-nrt/kb/app-registrations/12-certificates-and-secrets.md`
- `/Volumes/data/vscode/MyProjects/WorkloadIdentity/kb/03-management/02-credential-rotation-runbook.md`

## References
- https://learn.microsoft.com/en-us/graph/api/resources/appmanagementpolicy
- https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/configure-app-credential-policy
- https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation



