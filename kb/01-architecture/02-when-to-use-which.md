# Decision Matrix — When to Use Which Workload Identity

A lookup reference and decision guide for selecting the right workload identity type for a given scenario.

---

## How to Use This Document

Start with the lookup table. If your scenario does not appear, use the tie-breaker rules below the table to reason through the choice. Escalate to the architecture decision log if the answer is still unclear.

---

## Decision Lookup Table

| Scenario                                                       | Recommended Identity Type                          | Why                                                                                                                   | Notes / Caveats                                                                                             |
|----------------------------------------------------------------|----------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------|
| Azure VM calling Azure Storage                                 | System-assigned managed identity                   | VM lifecycle = identity lifecycle; no credential management.                                                          | Enable on the VM; grant `Storage Blob Data Reader/Contributor` at the container or account scope.           |
| Azure App Service calling Azure Key Vault                      | System-assigned managed identity                   | Single app, single resource; lifecycle match is clean.                                                                | Use Key Vault references in App Service config for transparent secret injection.                             |
| Azure App Service calling Microsoft Graph                      | System-assigned managed identity                   | MI can hold Graph application permissions via app role assignment on the MI's service principal.                      | Assign Graph app roles to the MI's SP via Graph API or portal; no secret required.                          |
| Azure Function App calling downstream Azure service            | System-assigned managed identity                   | Functions are ephemeral; system-assigned ties cleanly to the Function App resource.                                   | Use `DefaultAzureCredential` in Azure SDK; ensure the function's MI has the required RBAC.                  |
| AKS pod calling Azure Key Vault                                | User-assigned MI + Azure Workload Identity add-on (OIDC federation) | Pod-level identity via federated credential; user-assigned MI shared across replicas; no secrets in pod manifest. | AKS cluster must have OIDC issuer and Workload Identity add-on enabled. Create a Kubernetes `ServiceAccount` and annotate it with the MI's client ID. |
| AKS pod calling Azure SQL                                      | User-assigned MI + Azure Workload Identity add-on  | Same pattern as Key Vault; SQL supports Entra authentication for managed identities.                                  | Configure SQL server to use Entra authentication; add the MI as a SQL user with least-privilege role.       |
| Azure Container Apps job calling Storage                       | System-assigned or user-assigned managed identity  | Container Apps supports managed identities natively.                                                                  | User-assigned preferred if the identity is shared across multiple Container Apps.                           |
| GitHub Actions deploying Bicep / Terraform to Azure            | Federated credential on an app registration        | No secret stored in GitHub or Azure; OIDC token from GitHub Actions exchanged for Entra access token.                | Configure federated credential with issuer `https://token.actions.githubusercontent.com` and subject matching the repo and branch/environment. |
| Azure DevOps pipeline deploying to Azure                       | Federated credential on an app registration (workload identity federation in ADO service connection) | ADO supports WIF service connections natively since 2023; no secret rotation needed. | Create a service connection of type "Azure Resource Manager" and select "Workload Identity Federation (automatic or manual)". |
| GitLab CI pipeline deploying to Azure                          | Federated credential on an app registration        | GitLab CI supports OIDC token injection; configure federated credential with GitLab's issuer URL.                     | Subject claim format: `project_path:<group>/<project>:ref_type:branch:ref:<branch-name>`.                   |
| On-premises service calling Microsoft Graph                    | Federated credential via on-prem OIDC issuer       | If the on-prem environment runs an OIDC-capable issuer (e.g., Kubernetes, SPIFFE/SPIRE), no secret is needed.        | If no OIDC issuer available, use a certificate credential stored in an HSM or on-prem Key Vault equivalent. |
| On-premises service calling Azure — no OIDC available          | Service principal + certificate credential         | Certificate is stronger than a secret; store private key in an HSM or on-prem Key Vault.                             | Plan migration to federated credential when the environment supports an OIDC issuer.                        |
| Cross-tenant SaaS application calling organization tenant APIs     | Multi-tenant app registration + per-tenant SP + admin consent | SaaS model: one app reg in vendor tenant; SP instantiated in each your tenant on admin consent. | Organization tenant admin must grant consent; document permissions requested. Verified publisher recommended.   |
| Logic App (Standard or Consumption) calling Azure service      | System-assigned managed identity                   | Logic Apps support managed identity for Azure connector authentication natively.                                      | Enable MI on the Logic App; configure the connector to use managed identity authentication.                 |
| Azure API Management backend authentication                    | System-assigned managed identity                   | APIM policy `authentication-managed-identity` uses the APIM instance's MI to obtain a token for the backend.         | Backend must accept Entra tokens (validate `aud` claim against the backend's app ID).                      |
| Azure Data Factory pipeline accessing Storage + SQL            | User-assigned managed identity shared across pipelines | Shared identity simplifies RBAC management; one RBAC assignment for one MI, used by multiple linked services. | Create user-assigned MI; attach to ADF; configure linked services to use managed identity authentication.  |
| Azure Synapse Analytics pipeline                               | System-assigned managed identity (Synapse workspace) | Synapse creates a system-assigned MI automatically; use it for storage and SQL access.                                | Grant `Storage Blob Data Contributor` to the Synapse workspace MI at the storage account scope.            |
| Azure Kubernetes Service cluster-level operations (e.g., pulling images from ACR) | Managed identity on the kubelet (user-assigned) | AKS creates a user-assigned MI for the kubelet by default; grant `AcrPull` to this MI on the ACR.               | Do not use admin credentials or service principal for ACR pull — kubelet MI is the standard pattern.       |
| Azure Arc-enabled server calling Azure services                | System-assigned managed identity on the Arc server | Arc assigns a system-assigned MI; token obtained via Arc's local metadata endpoint (not IMDS).                        | IMDS endpoint for Arc: `http://localhost:40342/metadata/identity/oauth2/token`.                            |
| Data plane access for an external SaaS that does not support cert auth | Service principal + client secret (exception) | No better option available; requires governance exception.                                                           | Apply 90-day rotation, Key Vault storage, alert on access. Document as a governance exception.             |
| Azure Automation runbook executing Azure PowerShell            | System-assigned managed identity on the Automation Account | Automation Account supports MI; eliminates "Run As" accounts (deprecated).                                       | "Run As" accounts in Azure Automation were retired in September 2023. Migrate to managed identity.          |
| Power Platform custom connector / Azure Logic App calling external API | Service principal + client secret or certificate | Power Platform does not support managed identity for custom connectors.                                          | Use certificate where the external API supports it; store client secret in Key Vault and reference via Logic App action. |

---

## Tie-Breaker Rules

When the table above does not cover a scenario exactly, apply these rules in order:

### Rule 1 — Is the workload Azure-hosted?
Yes → Use a **managed identity** (system-assigned or user-assigned). Stop here unless Rule 2 forces user-assigned.

### Rule 2 — Does the identity need to be shared across multiple Azure resources?
Yes → **User-assigned managed identity**. Create it as a standalone Azure resource and attach to all relevant resources.
No → **System-assigned managed identity**. Enable directly on the resource.

### Rule 3 — Is the workload outside Azure but runs an OIDC-capable issuer?
Yes → **Federated identity credential** (on an app registration, or on a user-assigned MI for AKS patterns). No secret stored anywhere.

### Rule 4 — Is the workload outside Azure with no OIDC issuer available?
Yes → **Service principal + certificate credential** stored in an HSM or equivalent. Plan to migrate to federation.

### Rule 5 — Must the identity call APIs *as a delegated user* (acting on behalf of a specific person)?
Yes → This is not a workload identity pattern. Use OAuth 2.0 On-Behalf-Of (OBO) flow from a user-facing app; the workload identity should not impersonate users.

### Rule 6 — Is the workload a multi-tenant SaaS product?
Yes → **Multi-tenant app registration** in the vendor's home tenant + per-organization service principals created on admin consent. Do not use managed identity (it is tenant-scoped).

---

## Scenario Quick-Reference by Platform

When the decision matrix table is too long for a quick answer, use this condensed platform lookup:

| Platform / Technology                                | Identity Type                            | Key Configuration Step                                         |
|------------------------------------------------------|------------------------------------------|----------------------------------------------------------------|
| Azure Virtual Machine                                | System-assigned MI                       | VM > Identity > System assigned > On                          |
| Azure App Service                                    | System-assigned MI                       | App Service > Identity > System assigned > On                 |
| Azure Function App                                   | System-assigned MI                       | Function App > Identity > System assigned > On                |
| Azure Container Apps                                 | System-assigned or user-assigned MI      | Container App > Identity blade                                |
| Azure Kubernetes Service (pod-level)                 | User-assigned MI + Workload Identity add-on | `az aks update --enable-oidc-issuer --enable-workload-identity` |
| Azure Kubernetes Service (kubelet / node pool)       | User-assigned MI (AKS-managed)           | Automatically provisioned; grant `AcrPull` to kubelet MI      |
| Azure Logic App (Standard or Consumption)            | System-assigned MI                       | Logic App > Settings > Identity                               |
| Azure Data Factory                                   | System-assigned or user-assigned MI      | ADF > Managed identities blade                                |
| Azure Synapse Analytics                              | System-assigned MI (workspace)           | Automatically provisioned; grant RBAC as needed               |
| Azure API Management                                 | System-assigned MI                       | APIM > Security > Managed identities                          |
| Azure Automation Runbook                             | System-assigned MI                       | Automation Account > Identity > System assigned               |
| Azure Arc-enabled server                             | System-assigned MI                       | Automatically provisioned when Arc agent enrolls              |
| GitHub Actions                                       | Federated cred on app registration       | App reg > Certificates & secrets > Federated credentials      |
| Azure DevOps Pipeline                                | Federated cred on app registration (WIF) | ADO > Project settings > Service connections > WIF type       |
| GitLab CI                                            | Federated cred on app registration       | App reg > Federated credentials, issuer = GitLab OIDC URL     |
| On-prem service with SPIFFE/SPIRE or K8s OIDC        | Federated cred on app registration       | Configure FIC with on-prem issuer OIDC discovery URL          |
| On-prem service — no OIDC available                  | SP + certificate (stored in HSM/KV)      | App reg > Certificates & secrets > Upload .cer file           |
| AWS Lambda / EC2 calling Azure                       | Federated cred on app registration       | Issuer = `https://sts.amazonaws.com`; subject = ARN           |
| Multi-tenant SaaS (vendor side)                      | Multi-tenant app registration            | App reg > Authentication > Supported account types            |

---

## Common Mistakes to Avoid

- Using a single shared service principal for multiple unrelated workloads → blast radius risk; use user-assigned MI or per-workload app registrations.
- Using a system-assigned MI where an identity must outlive the compute resource (e.g., a VM gets rebuilt) → switch to user-assigned.
- Creating a federated credential on an app registration with a wildcard subject → restricts nothing; enumerate subject claims exactly.
- Using a client secret for AKS pods → use Azure Workload Identity add-on with OIDC federation.
- Using "Run As" accounts in Azure Automation → deprecated; migrate to managed identity.

---

## Additional Scenarios — Less Common but Important

| Scenario                                                       | Recommended Identity Type                          | Why                                                                 | Notes / Caveats                                                                                             |
|----------------------------------------------------------------|----------------------------------------------------|---------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------|
| Azure Spring Apps calling Azure services                       | System-assigned managed identity                   | Spring Apps supports system-assigned MI; standard IMDS token acquisition. | Enable in Azure Spring Apps instance; assign RBAC at resource scope.                           |
| Azure Batch job accessing Storage                              | System-assigned MI on the Batch pool               | Pool nodes get a system-assigned MI; use in job tasks via IMDS.     | Enable at Batch pool creation: `userAssignedIdentities` or `taskContainerSettings`.             |
| Azure Static Web Apps back-end API calling Graph              | User-assigned MI (linked Function or App Service) | Static Web Apps fronts a backend; backend uses MI.                  | Backend compute (Function/App Service) holds the MI; the static frontend has no server identity. |
| AWS workload calling Microsoft Graph                           | Federated credential on app registration          | AWS STS issues OIDC-compatible tokens for IAM roles; Entra can federate against them. | Configure FIC with issuer `https://sts.amazonaws.com`, subject = AWS IAM role ARN. |
| Service mesh (Istio / Linkerd) inter-service calls on AKS      | User-assigned MI + Workload Identity add-on per service | Each microservice gets its own Kubernetes SA and user-assigned MI.  | Avoid sharing one MI across all mesh services — per-service MI enables least-privilege.       |
| Azure Managed Application (ISV) accessing organization resources   | Service principal created by the managed app deployment | ARM creates an SP in the your tenant when the managed app is deployed. | Organization reviews permissions granted to the managed app SP at deployment time.            |
| Azure Key Vault backup / restore operations                    | System-assigned MI on the automation account       | Key Vault backup via Automation Account MI; avoids certificate management. | Grant `Key Vault Contributor` scoped to the specific vault.                                  |
| Azure DevTest Labs automated operations                        | System-assigned MI on the DevTest Lab             | Labs support MI for storage and Key Vault access.                   | Enable MI on the lab resource; scope RBAC to lab resource group only.                          |

---

## Edge Cases and Clarifications

### System-assigned vs user-assigned — when the line is blurry

Use user-assigned when **any** of these are true:
- The same logical identity needs to be attached to more than one Azure resource simultaneously.
- The compute resource is ephemeral or gets rebuilt frequently (e.g., AKS node pool scaling, VM scale sets).
- The identity needs to survive a resource rebuild or redeployment.
- A federated credential is needed on the MI (federated credentials are only available on user-assigned MIs, not system-assigned).

### Federated credentials on app registration vs on user-assigned MI

Both patterns eliminate secrets. Choose based on what you want the receiving token to look like to the downstream resource:
- **App registration FIC** → access token represents a service principal (`appid` claim = the client ID of the app reg). Use when calling Microsoft Graph or a resource that validates the application identity by client ID.
- **User-assigned MI FIC** → access token represents a managed identity (includes `xms_az_rid` claim with the MI's Azure resource ID). Use for AKS Workload Identity where the resource expects a managed identity token.

### Multiple workloads, one identity — when is it acceptable?

Sharing a user-assigned MI across multiple Azure resources that serve the **same logical workload** is correct design (e.g., a blue/green pair of App Service instances for the same application). Sharing across **unrelated workloads** is not — it couples the blast radius and makes RBAC reviews impossible to reason about.

### Service principals for Microsoft first-party apps

The tenant contains many service principals for Microsoft 365 and Azure built-in services. These SPs are provisioned and managed by Microsoft and should not be modified. Exclude them from custom governance processes but do monitor for unexpected activity.

---

## Identity Type Summary — One-Line Rules

When you need an instant answer:

- Azure resource doing anything → **system-assigned MI** unless sharing is needed.
- Shared identity across resources → **user-assigned MI**.
- AKS pod → **user-assigned MI + Workload Identity add-on**.
- GitHub/GitLab/ADO pipeline → **federated credential on app registration**.
- On-premises with OIDC issuer → **federated credential on app registration**.
- On-premises, no OIDC → **service principal + certificate in HSM/KV**.
- Multi-tenant SaaS vendor → **multi-tenant app registration + per-organization SP**.
- Workload calling API *as a user* → **not a workload identity pattern; use OBO**.
- Anything with a password in YAML or a `.env` file → **critical finding; fix first**.

---

## Frequently Requested — Scenario Not in the Table?

If your scenario is not in the decision table above, check the reference architectures document for worked examples of the most common deployments, or use the tie-breaker rules to reason through the choice. Submit a gap as a pull request / update request if a new platform or scenario should be added.

---

## Migration Roadmap — Moving Off Secrets

For tenants with existing client secrets, use this phased migration approach:

**Step 1 — Inventory (week 1):** Run a Graph query to list all app registrations with active password credentials. Sort by expiry date (soonest first) and by risk tier (Tier 0 highest priority).

**Step 2 — Assess each workload (weeks 1–2):**
- Is the workload Azure-hosted? → Target system-assigned or user-assigned MI.
- Is the workload a CI/CD pipeline? → Target federated credential.
- Is the workload on-premises? → Assess OIDC issuer availability; target federated credential or certificate.
- Is the workload a third-party SaaS that only accepts secrets? → Governance exception; 90-day rotation, Key Vault only.

**Step 3 — Migrate (in order of risk tier):**
1. Tier 0 and Tier 1 SPs — highest risk; migrate first.
2. Tier 2 SPs — production workloads with sensitive data access.
3. Tier 3 SPs — standard workloads; migrate during normal release cycles.

**Step 4 — Enforce:**
Apply `appManagementPolicy` with `passwordAddition: disabled` to prevent regression.

---

## See Also

- `/Volumes/data/vscode/MyProjects/entra-nrt/kb/app-registrations/12-certificates-and-secrets.md` — federated credentials field-by-field
- `/Volumes/data/vscode/MyProjects/WorkloadIdentity/kb/01-architecture/01-workload-identity-taxonomy.md` — identity type definitions
- `/Volumes/data/vscode/MyProjects/WorkloadIdentity/kb/01-architecture/03-reference-architectures.md` — worked examples

## References
- https://learn.microsoft.com/en-us/entra/workload-id/workload-identities-overview
- https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/managed-identity-best-practice-recommendations
- https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation

