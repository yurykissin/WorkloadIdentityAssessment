# Tooling Reference — Graph, Bicep / Terraform, PIM for Groups

A decision guide for which tool to use for each workload identity management task. No single tool covers everything — this document explains the coverage, gaps, and gotchas for each option.

---

## Microsoft Graph (PowerShell SDK + REST)

**When to use:** Microsoft Graph is the authoritative source of truth for Entra directory objects — app registrations, service principals, federated identity credentials, app role assignments, admin consent grants, and app management policies. Use Graph (via the PowerShell SDK or REST) for any identity governance operation that involves reading or modifying Entra objects.

### Key Cmdlets — Microsoft Graph PowerShell SDK

Install: `Install-Module Microsoft.Graph -Scope CurrentUser`
Connect: `Connect-MgGraph -Scopes "Application.ReadWrite.All","AppRoleAssignment.ReadWrite.All","Policy.ReadWrite.ApplicationConfiguration"`

| Task                                              | Cmdlet / Endpoint                                                               |
|---------------------------------------------------|---------------------------------------------------------------------------------|
| List all app registrations                        | `Get-MgApplication -All`                                                        |
| Get a specific app registration                   | `Get-MgApplication -ApplicationId "<object-id>"`                               |
| Create app registration                           | `New-MgApplication -DisplayName "..." -SignInAudience AzureADMyOrg`             |
| Add client secret                                 | `Add-MgApplicationPassword -ApplicationId "<id>" -BodyParameter @{...}`        |
| Remove client secret                              | `Remove-MgApplicationPassword -ApplicationId "<id>" -BodyParameter @{keyId="..."}` |
| Add certificate credential                        | `Update-MgApplication -ApplicationId "<id>" -KeyCredentials @(...)`            |
| Add federated identity credential                 | `New-MgApplicationFederatedIdentityCredential -ApplicationId "<id>" -BodyParameter @{...}` |
| List federated identity credentials               | `Get-MgApplicationFederatedIdentityCredential -ApplicationId "<id>"`           |
| Remove federated identity credential              | `Remove-MgApplicationFederatedIdentityCredential -ApplicationId "<id>" -FederatedIdentityCredentialId "<fic-id>"` |
| List all service principals                       | `Get-MgServicePrincipal -All`                                                   |
| Enable / disable service principal                | `Update-MgServicePrincipal -ServicePrincipalId "<id>" -AccountEnabled:$false`  |
| List app role assignments on SP                   | `Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId "<id>"`           |
| Grant app role assignment to SP                   | `New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId "<id>" -BodyParameter @{...}` |
| Remove app role assignment from SP                | `Remove-MgServicePrincipalAppRoleAssignment -ServicePrincipalId "<id>" -AppRoleAssignmentId "<id>"` |
| Get / set tenant default app management policy    | `GET/PATCH https://graph.microsoft.com/v1.0/policies/defaultAppManagementPolicy` |
| Create per-app management policy                  | `POST https://graph.microsoft.com/v1.0/policies/appManagementPolicies`         |
| Bind app management policy to app registration    | `POST https://graph.microsoft.com/v1.0/applications/<id>/appManagementPolicies/$ref` |
| Get stale SP sign-in activity                     | `Get-MgServicePrincipal -Filter "signInActivity/lastSignInDateTime le <date>"` |
| Set application tags                              | `Update-MgApplication -ApplicationId "<id>" -Tags @("Owner:...", "Env:prod")`  |

---

## Bicep / Terraform — Infrastructure-as-Code

**When to use:** Use IaC for all user-assigned managed identity creation and all Azure RBAC assignments. IaC ensures changes are version-controlled, reviewed, and reproducible.

### Bicep

User-assigned managed identity:
```bicep
resource mi 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'mi-prod-plat-myworkload-001'
  location: resourceGroup().location
  tags: {
    Owner: 'team@<customer>.com'
    Environment: 'prod'
    AppCode: 'APP-0042'
    Lifecycle: 'ongoing'
  }
}
```

RBAC assignment:
```bicep
resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, mi.id, storageBlobContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe') // Storage Blob Data Contributor
    principalId: mi.properties.principalId
    principalType: 'ServicePrincipal'
  }
}
```

### Terraform

User-assigned MI with the AzureRM provider:
```hcl
resource "azurerm_user_assigned_identity" "mi" {
  name                = "mi-prod-plat-myworkload-001"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  tags = {
    Owner       = "team@<customer>.com"
    Environment = "prod"
    AppCode     = "APP-0042"
  }
}
```

**Gotcha — App Registrations and Service Principals in Terraform:**
The `hashicorp/azuread` provider (formerly `azureAD`) covers app registrations and service principals. However, some advanced features — notably `appManagementPolicies` binding, custom security attributes, and certain federated credential scenarios — require the `Azure/azapi` provider, which calls the ARM/Graph REST API directly.

```hcl
# AzAPI provider — app management policy binding (not available in azuread provider)
resource "azapi_resource_action" "bind_policy" {
  type        = "Microsoft.Graph/applications@v1.0"
  resource_id = "/applications/${azuread_application.app.object_id}/appManagementPolicies/$ref"
  method      = "POST"
  body = jsonencode({
    "@odata.id" = "https://graph.microsoft.com/v1.0/policies/appManagementPolicies/${var.policy_id}"
  })
}
```

Use the AzAPI provider (`registry.terraform.io/Azure/azapi`) for any Entra object or ARM resource not fully supported by the first-party providers.

---

## Azure CLI / Az PowerShell — Quick Operations

**When to use:** Ad-hoc investigation, one-off validation, or running queries interactively. **Not the source of truth** — do not use for provisioning that is not tracked in IaC. Changes made via CLI directly are not version-controlled.

| Task                                          | Tool / Command                                                                |
|-----------------------------------------------|-------------------------------------------------------------------------------|
| List managed identities in a resource group   | `az identity list -g <rg>`                                                    |
| Enable system-assigned MI on a VM             | `az vm identity assign -g <rg> -n <vm-name>`                                 |
| Assign RBAC to a managed identity             | `az role assignment create --assignee <mi-principal-id> --role "..." --scope "..."` |
| Get an access token for a managed identity    | `az account get-access-token --resource https://graph.microsoft.com`         |
| Show SP for an app registration               | `az ad sp show --id <app-id>`                                                 |

---

## PIM for Groups — JIT Access for Workload Identities

**What it is:** PIM for Groups allows service principals to be *eligible* members of a security group. The SP can be activated into the group for a defined duration, then membership expires automatically. Use this pattern to give a workload identity just-in-time elevated access (e.g., a deployment pipeline that needs temporary write access to a privileged resource).

**Why it matters for workload identities:** Standing RBAC assignments for high-privilege operations create a permanently-elevated blast radius. PIM for Groups reduces this to time-bounded activations with a full audit trail.

**Licence requirement:** Entra ID P2 or Entra ID Governance.

**Configuration path:**
```
Microsoft Entra admin center > Identity Governance > Privileged Identity Management > Groups
  > Discover groups > Add <target group>
  > Enable PIM for Groups
  > Assignments > Add assignments > Member (eligible) > Select the service principal
  > Settings > Activation duration: 4h max (for privileged operations); require justification
```

**How the workload activates membership:**
The SP calls the PIM API to activate its group membership before performing the privileged operation:
```http
POST https://graph.microsoft.com/v1.0/identityGovernance/privilegedAccess/group/eligibilityScheduleRequests
{
  "action": "selfActivate",
  "principalId": "<sp-object-id>",
  "groupId": "<group-id>",
  "accessId": "member",
  "justification": "Deploying to production — scheduled deployment pipeline run",
  "scheduleInfo": {
    "startDateTime": "<ISO8601-now>",
    "expiration": { "type": "afterDuration", "duration": "PT4H" }
  }
}
```

**Gotcha:** The SP must have a credential that allows it to authenticate to Graph to call the PIM API. This is one scenario where a system-assigned managed identity on the compute resource (e.g., the GitHub Actions runner VM, or an Azure Automation account) calls Graph to activate the group membership, then uses the group's RBAC to perform the elevated operation. The credential for PIM activation is the MI token — no separate secret needed.

---

## Entra ID Governance

**When to use:** Access reviews, lifecycle workflows, and entitlement management.

**Workload identity coverage:**
- Access reviews on Azure resource roles, app roles, and group membership for service principals — fully supported.
- Lifecycle workflows (automated user onboarding/offboarding flows) — currently scoped to user identities. **Workload identity lifecycle automation is not yet covered** by Lifecycle Workflows as of May 2026. Use Logic Apps or Azure Automation runbooks for equivalent workload identity lifecycle automation.
- Entitlement management — access packages can include group membership (which can indirectly govern SP access via PIM for Groups).

---

## Microsoft Defender for Cloud

**When to use:** Continuous posture assessment for managed identity adoption and secret hygiene on Azure resources.

**Relevant recommendations:**

| Recommendation                                                            | Description                                                              |
|---------------------------------------------------------------------------|--------------------------------------------------------------------------|
| Virtual machines should use managed identity                              | Flags VMs that authenticate via service principal credentials rather than MI |
| Function apps should use managed identity                                 | Flags Function Apps without managed identity enabled                     |
| App Service apps should use managed identity                              | Same for App Service                                                     |
| Secrets should not be stored in Azure Container Registry environment variables | Secret detection in container build pipelines                        |
| Key Vault secrets should have an expiration date                         | Flags secrets without expiry — applies to workload credential secrets   |
| Managed identity should be used in API Management service                | Flags APIM backends using static credentials                            |

Configure Defender for Cloud recommendations to route to the relevant subscription owner or platform engineering team for remediation tracking.

---

## Decision Card — Task to Tool

| Task                                              | Best Tool                              | Fallback                              |
|---------------------------------------------------|----------------------------------------|---------------------------------------|
| Create user-assigned managed identity             | Bicep / Terraform (IaC)                | Azure CLI (`az identity create`)      |
| Attach MI to Azure resource                       | Bicep / Terraform                      | Azure portal (Identity blade)         |
| Create app registration                           | Terraform (`azuread` provider) / Bicep (`Microsoft.Graph` extension) | Graph PowerShell SDK |
| Add federated identity credential                 | Terraform (`azuread_application_federated_identity_credential`) | Graph PowerShell SDK |
| Assign Azure RBAC                                 | Bicep / Terraform (`azurerm_role_assignment`) | Azure CLI / Graph PowerShell SDK     |
| Grant Graph admin consent (app role assignment)   | Graph PowerShell SDK / REST            | Entra admin center (manual)           |
| Rotate client secret                              | Graph PowerShell SDK                   | Entra admin center (manual, not automated) |
| Enforce appManagementPolicy                       | Graph REST / PowerShell SDK            | AzAPI Terraform provider              |
| Configure PIM for Groups                          | Entra admin center (initial setup) + Graph API for activation | PIM portal              |
| Run access review                                 | Entra ID Governance (portal / Graph)   | Manual Graph query export + review     |
| Query inventory (stale SPs, expiring creds)       | Graph PowerShell SDK / Resource Graph  | Entra workbooks (Log Analytics)        |
| Detect posture issues                             | Defender for Cloud                     | Secure Score + Graph PowerShell       |

---

## References
- https://learn.microsoft.com/en-us/powershell/microsoftgraph/overview
- https://learn.microsoft.com/en-us/azure/templates/microsoft.managedidentity/userassignedidentities
- https://learn.microsoft.com/en-us/entra/id-governance/privileged-identity-management/groups-features
