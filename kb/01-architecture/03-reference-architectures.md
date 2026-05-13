# Reference Architectures

Worked reference architectures for the most common workload identity scenarios. Each architecture names the identity types involved, describes the token flow, identifies RBAC scopes, and calls out governance and monitoring touchpoints.

---

## Architecture A — Azure App Service → Microsoft Graph (System-Assigned MI)

**Scenario:** A line-of-business web application running on Azure App Service needs to call Microsoft Graph to read user profiles and send mail on behalf of the service.

**Identities used:** System-assigned managed identity on the App Service instance.

```
 [App Service]
  system-assigned MI
       │
       │  1. Request token via IMDS
       ▼
 [Azure IMDS endpoint]
 http://169.254.169.254/...
       │
       │  2. Platform issues token (aud = https://graph.microsoft.com)
       ▼
 [Microsoft Graph API]
  validates token, returns data
```

**Token flow:**
1. App code calls `DefaultAzureCredential` (Azure SDK) or requests a token via IMDS directly.
2. Azure platform issues a short-lived access token with `aud = https://graph.microsoft.com`.
3. App presents the token in the `Authorization: Bearer` header to Graph.
4. Graph validates the `oid` claim against the MI's service principal and checks app role assignments.

**RBAC / Permission scopes:**
- Assign Graph application permissions (app roles) to the MI's service principal via Microsoft Graph API or the Azure portal (Enterprise applications > \<MI name\> > API Permissions).
- Apply least-privilege: use `User.Read.All` not `Directory.Read.All` if only user profiles are needed; `Mail.Send` not `Mail.ReadWrite` if only sending is required.

**Key Azure / Entra resources:**
- App Service plan and App Service instance (enable MI in the Identity blade).
- Enterprise application object for the MI in Entra ID (receives the app role assignments).

**Governance call-outs:**
- Owner: assign ≥ 2 owners to the MI's enterprise app object.
- Review Graph app role assignments quarterly.
- Tag the App Service with `Owner`, `AppCode`, `Environment`.

**Monitoring touchpoints:**
- Non-interactive sign-in logs for the MI's service principal → Log Analytics / Sentinel.
- Alert on new app role assignments to this service principal.

---

## Architecture B — AKS Pod → Azure SQL (User-Assigned MI + Workload Identity Federation)

**Scenario:** Microservices running in AKS need to authenticate to Azure SQL Database using Entra ID without any credentials in the container image or Kubernetes secrets.

**Identities used:** User-assigned managed identity; federated identity credential on the MI; Kubernetes service account annotated with the MI's client ID.

```
 [AKS Pod]
  mounted K8s ServiceAccount token (projected)
       │
       │  1. Present K8s SA token to Entra ID /token endpoint
       ▼
 [Entra ID — Token Exchange]
  Validates: issuer = AKS OIDC issuer URL
             subject = system:serviceaccount:<ns>:<sa-name>
             audience = api://AzureADTokenExchange
       │
       │  2. Issues access token (aud = https://database.windows.net/)
       ▼
 [Azure SQL Database]
  Entra authentication — validates token, maps to SQL user
```

**Prerequisites:**
- AKS cluster: OIDC issuer enabled (`--enable-oidc-issuer`), Workload Identity add-on enabled (`--enable-workload-identity`).
- User-assigned MI created and attached to the AKS kubelet (or as an additional identity).
- Federated credential on the MI: issuer = cluster's OIDC issuer URL, subject = `system:serviceaccount:<namespace>:<serviceaccount-name>`.
- Kubernetes `ServiceAccount` annotated: `azure.workload.identity/client-id: <mi-client-id>`.
- Pod labels: `azure.workload.identity/use: "true"`.

**RBAC / Permission scopes:**
- Add the MI as an Entra user in Azure SQL: `CREATE USER [<mi-display-name>] FROM EXTERNAL PROVIDER; ALTER ROLE db_datareader ADD MEMBER [<mi-display-name>];`

**Governance call-outs:**
- The user-assigned MI is an ARM resource — apply tags (`Owner`, `Environment`, `AppCode`).
- Federated credential subject must be scoped to a specific namespace and service account — no wildcards.
- Review the OIDC issuer URL annually to ensure the cluster certificate rotation has not invalidated trust.

**Monitoring touchpoints:**
- Non-interactive sign-in logs for the MI's service principal.
- Alert on federated credential configuration changes (issuer or subject modified).
- Azure SQL audit logs for login events.

---

## Architecture C — GitHub Actions → Azure Deployment (Federated Credential, No Secrets)

**Scenario:** A GitHub Actions workflow deploys Bicep templates to Azure. No secrets stored in GitHub.

**Identities used:** App registration in Entra ID with a federated identity credential; corresponding service principal with Azure RBAC.

```
 [GitHub Actions Runner]
       │
       │  1. ACTIONS_ID_TOKEN_REQUEST (GitHub OIDC issuer)
       ▼
 [GitHub OIDC Endpoint]
  issues JWT: iss=https://token.actions.githubusercontent.com
              sub=repo:<org>/<repo>:environment:<env>
              aud=api://AzureADTokenExchange
       │
       │  2. Exchange JWT at Entra /token (client_assertion flow)
       ▼
 [Entra ID — Token Exchange]
  Validates federated credential: issuer + subject + audience match
       │
       │  3. Issues access token (aud = https://management.azure.com/)
       ▼
 [Azure Resource Manager]
  RBAC check on service principal → deploys resources
```

**GitHub Actions workflow (key steps):**
```yaml
permissions:
  id-token: write
  contents: read

steps:
  - uses: azure/login@v2
    with:
      client-id: ${{ secrets.AZURE_CLIENT_ID }}
      tenant-id: ${{ secrets.AZURE_TENANT_ID }}
      subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
```

Note: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and `AZURE_SUBSCRIPTION_ID` are not secrets — they are non-sensitive identifiers. Using GitHub Secrets for them is convention, not a security requirement.

**RBAC / Permission scopes:**
- Assign the service principal `Contributor` at the target resource group scope (not subscription scope).
- If deploying role assignments, add `User Access Administrator` at the same scope — time-bound, documented exception.

**Governance call-outs:**
- Federated credential subject should target a specific environment (`repo:<org>/<repo>:environment:production`), not just the repo or branch, for production deployments.
- Review federated credential configuration on every job ownership change.
- App registration must have ≥ 2 owners.

**Monitoring touchpoints:**
- Service principal sign-in logs for the app registration's SP.
- Alert on new credentials added to the app registration (a new secret or cert on this reg is a red flag — it should only ever use federated credentials).
- GitHub Actions audit log for workflow runs.

---

## Architecture D — On-Premises Service → Microsoft Graph (Federated Credential via On-Prem OIDC Issuer)

**Scenario:** An on-premises service (running in a data centre Kubernetes cluster or with SPIFFE/SPIRE) needs to call Microsoft Graph without storing any secret in the data centre.

**Identities used:** App registration with a federated identity credential; OIDC issuer running on-premises (e.g., SPIFFE/SPIRE OIDC discovery endpoint, or a self-managed OIDC issuer).

```
 [On-Prem Service / K8s Pod]
       │
       │  1. Request SVID / SA token from local OIDC issuer
       ▼
 [On-Prem OIDC Issuer]
  issues JWT: iss=https://oidc.<organization>.internal
              sub=spiffe://cluster.local/ns/default/sa/my-svc
              aud=api://AzureADTokenExchange
       │
       │  2. POST to Entra /token (client_assertion=<JWT>)
       ▼
 [Entra ID — Token Exchange]
  Fetches OIDC discovery at issuer URL (must be publicly reachable OR use private endpoint)
  Validates signing keys, issuer, subject, audience
       │
       │  3. Issues access token (aud = https://graph.microsoft.com/)
       ▼
 [Microsoft Graph API]
```

**Key requirement:** The on-premises OIDC issuer's discovery endpoint (`/.well-known/openid-configuration`) and JWKS endpoint must be reachable by Entra ID's token service — typically this means a public HTTPS endpoint. For air-gapped environments, this pattern is not viable; use certificate credential instead.

**Governance call-outs:**
- Document the on-prem OIDC issuer as an authoritative source in the architecture record.
- Subject claim must be specific — not a wildcard; review when service account names change.
- If the OIDC issuer's signing key rotates, the federated credential trust is unaffected (Entra re-fetches JWKS dynamically), but verify after any issuer key rotation event.

**Monitoring touchpoints:**
- Sign-in logs for the app registration's service principal.
- Alert on federated credential changes.
- On-prem OIDC issuer availability monitoring (a downed issuer = workload authentication failure).

---

## Architecture E — Cross-Tenant SaaS / Multi-Tenant Application

**Scenario:** A SaaS vendor's application needs to call APIs in organization tenants. The vendor registers one application and customers install it via admin consent.

**Identities used:** Multi-tenant app registration in the vendor's Entra tenant; service principal instantiated in each your tenant on admin consent.

```
 [Vendor Tenant]                              [Organization Tenant A]
 App Registration (multi-tenant)  ──consent──► Service Principal
   - App ID: <vendor-app-id>                    - Tenant-specific object ID
   - Redirect URI: https://app.vendor.com/auth  - Permission grants (app roles)
   - Required permissions declared              - Conditional Access applies here
       │
       │  Organization admin grants admin consent
       │  SP created in your tenant
       │
       │  Vendor service authenticates:
       │  POST /oauth2/v2.0/token (tenant = your tenant ID)
       │  client_credentials grant + cert/secret/FIC
       ▼
 [Organization Tenant A — Microsoft Graph or API]
```

**Key design points:**
- The app registration's `signInAudience` must be set to `AzureADMultipleOrgs` (or `AzureADandPersonalMicrosoftAccount`).
- Organization admin must grant admin consent to application permissions; delegated permissions require a user sign-in.
- Verified publisher status is strongly recommended — required for any permission marked as "high" privilege in the Microsoft consent framework.
- The vendor should use `/.default` scope against the your tenant ID in the token request.

**RBAC / Permission scopes:**
- Graph permissions granted in each your tenant's SP — least-privilege, documented.
- Organization tenant CA policies apply to sign-ins from the vendor's SP.

**Governance call-outs:**
- Vendor must maintain a registry of which organization tenants have consented.
- Organization must review the permissions granted at least annually.
- Cross-tenant access policies in the your tenant control whether the vendor's SP can authenticate.

**Monitoring touchpoints:**
- Vendor: service principal sign-in logs per your tenant (non-interactive).
- Organization: audit log for admin consent event; SP sign-in logs in their own Log Analytics.
- Alert (organization side) on new API permission grants to vendor SP.

---

## Architecture F — Azure Function → Key Vault → Downstream API (System-Assigned MI + KV References)

**Scenario:** An Azure Function App retrieves a third-party API key from Key Vault and calls a downstream API that does not support Entra authentication.

**Identities used:** System-assigned managed identity on the Function App.

```
 [Azure Function App]
  system-assigned MI
       │
       │  1. Key Vault Reference — resolved at runtime by Azure platform
       ▼
 [Azure Key Vault]
  MI has Key Vault Secrets User RBAC
       │
       │  2. Secret value injected as environment variable (or fetched via SDK)
       ▼
 [Function App runtime]
       │
       │  3. Calls downstream API using retrieved secret
       ▼
 [Third-party API]
```

**Two patterns for secret consumption:**
- **Key Vault References (recommended):** Set App Setting value to `@Microsoft.KeyVault(SecretUri=https://<vault>.vault.azure.net/secrets/<secret-name>/)`. Azure resolves the reference before the function starts. No SDK code required.
- **SDK fetch:** Use `SecretClient` with `DefaultAzureCredential` to fetch at runtime (use when the secret must be refreshed mid-execution or the reference pattern doesn't apply).

**RBAC / Permission scopes:**
- Function App MI → Key Vault: `Key Vault Secrets User` role at the secret or vault scope.
- Downstream API secret stored in Key Vault; the MI does not call the downstream API using its own Entra token.

**Governance call-outs:**
- The third-party API key in Key Vault is a secret subject to the credential and secret policy — rotate on schedule, alert on pre-expiry.
- Key Vault soft-delete and purge-protection must be enabled.
- Enable Key Vault diagnostic logging → Log Analytics.

**Monitoring touchpoints:**
- Key Vault audit logs: alert on unexpected secret access outside the Function App's MI.
- Function App sign-in logs (non-interactive, MI).
- Key Vault access log for the secret object.

---

## Architecture G — Azure Data Factory → Storage + SQL (User-Assigned MI Shared Across Pipelines)

**Scenario:** Multiple ADF pipelines need to access Azure Data Lake Storage Gen2 and Azure SQL Database. A single user-assigned MI simplifies RBAC management.

**Identities used:** User-assigned managed identity attached to the ADF workspace.

```
 [ADF Pipeline A]     [ADF Pipeline B]     [ADF Pipeline C]
       │                    │                    │
       └────────────────────┼────────────────────┘
                            │
                   [User-Assigned MI]
                   (attached to ADF workspace)
                            │
             ┌──────────────┼──────────────┐
             ▼              ▼              ▼
    [ADLS Gen2]       [Azure SQL]    [Azure Key Vault]
    Storage Blob      Entra auth     Secrets User
    Data Contributor  db_datareader
```

**Configuration steps:**
1. Create user-assigned MI: `az identity create -g <rg> -n <mi-name>`.
2. Attach to ADF: in ADF workspace > Managed identities > Add user-assigned managed identity.
3. In each linked service, select "User Assigned Managed Identity" as the authentication method and specify the MI's client ID.
4. Grant RBAC: `Storage Blob Data Contributor` on the storage account; Entra SQL user on the database.

**Governance call-outs:**
- The user-assigned MI is an ARM resource — tag it (`Owner`, `Environment`, `AppCode`, `CostCenter`).
- RBAC is assigned to one MI, not per-pipeline — changes to RBAC affect all pipelines sharing the identity. Review with that scope in mind.
- If pipelines have different data sensitivity levels, consider separate user-assigned MIs per sensitivity tier.

**Monitoring touchpoints:**
- Non-interactive sign-in logs for the MI's service principal.
- Storage account diagnostic logs: filter by the MI's object ID.
- SQL audit log for login events by the MI.

---

## See Also

- `/Volumes/data/vscode/MyProjects/WorkloadIdentity/kb/01-architecture/04-trust-model-and-token-flow.md`
- `/Volumes/data/vscode/MyProjects/entra-nrt/kb/app-registrations/12-certificates-and-secrets.md`

## References
- https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation
- https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview
- https://learn.microsoft.com/en-us/azure/data-factory/data-factory-service-identity
