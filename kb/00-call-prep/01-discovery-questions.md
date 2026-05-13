# Discovery Questions — Workload & Managed Identity

Use this list to drive the discovery portion of the call. Not every question will apply — select based on what you learn as the conversation unfolds. Capture answers in the Decision Log (`02-decision-log-template.md`). Mark questions the customer cannot answer on the day as open items in the parking lot. Aim to cover Current State, Inventory, and Risk in the first 30 minutes; save Future State Goals for the close.

---

## Current State

- Do you have an inventory of all service principals (app registrations and enterprise apps) in your Entra tenant today?
- Who is currently responsible for creating app registrations — development teams, a central IT team, or both?
- Is there a formal approval process for creating new app registrations?
- Are there any regular Entra user accounts being used as service accounts or shared automation accounts?
- How many app registrations and enterprise applications are in the tenant? (Rough order of magnitude is fine.)
- Do you know which app registrations are actively used vs dormant?
- Are there app registrations with no owner assigned?
- Have you ever run a clean-up exercise on stale or orphaned service principals?
- How many people in your organisation currently hold the Application Administrator or Cloud App Administrator Entra role?
- Is the tenant-wide setting "Users can register applications" currently enabled or disabled?
- Is the tenant-wide admin consent workflow enabled, or can users grant consent directly?
- Do any teams use guest user accounts as service identities?

## Workload Inventory

- How many Azure-hosted workloads call external APIs or Azure services using an identity?
- How many of those Azure-hosted workloads already use managed identities (system-assigned or user-assigned)?
- Do you have on-premises workloads (non-Azure hosted) that authenticate to Entra-protected APIs?
- Do you have workloads running outside Azure (AWS, GCP, Kubernetes not on Azure) that need access to Azure resources?
- Are any CI/CD pipelines (GitHub Actions, Azure DevOps, GitLab CI) deploying to Azure using credentials today?
- Do any pipelines store client secrets or certificates in pipeline variables, repository secrets, or configuration files?
- Have you implemented Workload Identity Federation (federated credentials on an app registration or user-assigned MI) in any scenario?
- How many AKS clusters run workloads that authenticate to Azure services?
- Are those AKS clusters using the Azure Workload Identity add-on with the OIDC issuer enabled?
- Do you have Azure Functions, App Services, or Container Apps that call Microsoft Graph?
- Do you have Azure Data Factory, Synapse Analytics, or Logic Apps with external authenticated connections?
- Do you use Azure API Management with backend authentication requiring an identity?
- Are there multi-tenant app registrations currently registered in the tenant?
- Do any third-party SaaS products installed in the tenant require admin consent to application (non-delegated) permissions?
- How many Azure subscriptions are in scope for this engagement?
- Are there any Azure Arc-connected servers or Kubernetes clusters that use managed identity?

## Sensitivity & Risk

- Which workloads have Microsoft Graph **application** permissions (not delegated)?
- Which workloads have highly privileged Graph permissions such as `Directory.ReadWrite.All`, `RoleManagement.ReadWrite.Directory`, `Application.ReadWrite.All`, `Mail.ReadWrite`, or `Files.ReadWrite.All`?
- Which workloads have Owner, Contributor, or User Access Administrator Azure RBAC at subscription scope or higher?
- Are there workloads with access to production data that contains PII, financial data, or health information?
- Have there been any incidents involving compromised service principal credentials in the past 24 months?
- Are client secrets stored in plain text anywhere — source code, config files, environment variables not backed by Key Vault?
- Do any CI/CD pipelines have subscription-level Contributor or Owner rights?
- Are there long-lived secrets (over 12 months) on service principals that have not been rotated?
- Which workloads, if compromised, would represent the highest blast radius?
- Is there a formal classification of workload identities by sensitivity or criticality today?
- Are there any federated credential configurations that allow broad subject matching (e.g., `repo:*` or no subject filter)?

## Lifecycle & Ownership

- Who owns an app registration after the developer who created it leaves the organisation?
- Is there an offboarding process that re-assigns or revokes workload identities when a team or individual owner departs?
- Is each app registration associated with a team, cost centre, or business application in a CMDB or equivalent?
- How do you track which workloads are still active versus retired?
- When a project ends, what is the process to decommission the associated service principals?
- Have you ever discovered orphaned app registrations after a team was disbanded?
- Are there workloads running with credentials provisioned by contractors or partners who have since left?
- Who currently approves the creation of new app registrations?
- Is there a formal lifecycle policy for managed identities attached to Azure resources?
- When an Azure resource is deleted, do you verify that associated managed identity RBAC assignments are also removed?
- Is there a defined maximum age for a service principal that has had no sign-in activity?
- Do system-assigned managed identity deletions generate any alerting or review step?

## Secrets Hygiene

- What is the current maximum permitted lifetime for client secrets on app registrations?
- Are secrets rotated on a defined schedule, or only when they expire or a breach is suspected?
- Do you use Azure Key Vault to store and manage client secrets and certificates used by workload identities?
- Is Key Vault RBAC (not legacy access policies) in use to control which workloads can retrieve secrets?
- Do you have secret scanning enabled in your source control repositories (GitHub Advanced Security, ADO secret scanning)?
- Have any secrets been found in source code or pipeline logs in the past 12 months?
- Are certificates used in preference to secrets where managed identity and federation are not supported?
- Who is notified when a secret or certificate approaches expiry, and how far in advance?
- Is there a centralised credential inventory, or does each team track their own?
- Do any third-party integrations bypass Key Vault and store secrets in proprietary vaults or databases?
- Are service principal certificates stored in Azure Key Vault, local certificate stores, or managed manually?
- How are Key Vault soft-delete and purge protection configured?

## Permission Hygiene

- What is the current process for requesting and approving new Microsoft Graph application permissions?
- Who reviews and formally grants admin consent to Graph application permissions?
- Are admin consent decisions documented anywhere (change record, approval ticket)?
- Do you have service principals with more permissions than you can actively justify today?
- Is there an approved list of Graph application permissions, or are requests handled ad-hoc?
- Are Azure RBAC assignments for workload identities scoped at the resource, resource group, or subscription level?
- Do any managed identities or service principals have Owner or Contributor rights at subscription scope?
- How often are Azure RBAC assignments reviewed for workload identities?
- Are custom Entra roles used, or do workloads rely entirely on built-in roles?
- Are app role assignments (application-to-application authorisation) reviewed on a regular cadence?
- Do any SaaS applications have app role assignments granting access to sensitive internal APIs?
- Are cross-tenant access policies configured for workloads that operate across Entra tenants?
- Is there a process to detect and remediate permission creep on long-running service principals?

## Monitoring & Detection

- Are service principal sign-in logs being collected? If so, where (Log Analytics workspace, Sentinel, third-party SIEM)?
- What is the current retention period for sign-in logs?
- Do you have alerts on service principal sign-in anomalies — new IP address, new resource, after-hours activity, high failure rate?
- Is Microsoft Sentinel deployed in your environment?
- Are Entra ID audit logs (app registration changes, admin consent events) ingested into the SIEM?
- Who receives and responds to an alert on a suspicious service principal sign-in?
- Do you have the Entra Workload Identities Premium SKU (Entra Workload ID) enabled?
- Is Microsoft Entra Identity Protection enabled, and does anyone review the "Risky workload identities" blade?
- Are Conditional Access policies applied to any workload identities today?
- Do you receive alerts when new credentials (secrets, certificates, federated credentials) are added to an existing app registration?
- Are alerts generated when a new admin consent grant is made for a Graph application permission?
- Is there a process for reviewing changes to federated credential configurations?
- Are Defender for Cloud recommendations related to managed identity adoption and secret usage actively reviewed?

## Tooling & Automation

- Are app registrations and managed identities provisioned via infrastructure-as-code (Bicep, Terraform)?
- If Terraform is used, which provider manages Entra resources — AzureAD/AzureRM, or AzAPI?
- Is the Microsoft Graph PowerShell SDK in use for identity management tasks?
- Are Azure RBAC assignments automated or applied manually through the portal?
- Do you use Azure Policy to enforce managed identity usage or to detect resources without managed identities?
- Is there an automated credential rotation process for client secrets or certificates?
- Are workload identity resources tagged consistently to enable cost attribution and ownership lookup?
- Do you use Azure Resource Graph or Microsoft Graph queries to build or maintain your identity inventory?
- Does your CI/CD pipeline gate on detected secrets (build fails on secret leak detection)?
- Is there a GitOps or policy-as-code workflow governing who can modify identity-related IaC?
- Do you use the AzAPI Terraform provider or the `Microsoft.Graph` Bicep extension for app registrations?

## Compliance & Regulatory

- Are you subject to any regulatory frameworks (ISO 27001, SOC 2, PCI-DSS, HIPAA, NIS2, DORA, CPS234) with requirements for non-human identities?
- Is there a current audit finding or compliance gap specifically related to workload identity management?
- Do auditors require documented evidence of credential rotation and access review completion?
- Is there a data residency requirement that constrains where token-issuing services or logs can be stored?
- Is separation of duties enforced for workload identity management — the person who creates cannot also approve?
- Is there a requirement for Just-In-Time access for privileged identity operations?
- Are access reviews for workload identities currently documented as part of your ISO/SOC control evidence set?
- Do you have a formal risk acceptance / exception process for identity governance policy waivers?
- Is the concept of a non-human identity lifecycle formally covered by your information security policy today?

## Future State Goals

- What does "good" look like to you in 12 months for workload identity management?
- Are you targeting full elimination of client secrets for Azure-hosted workloads (managed identity everywhere)?
- Do you want a self-service developer experience for app registration requests within policy guardrails?
- Is centralised inventory and dashboard visibility (Azure Workbook, Power BI) a stated priority?
- Do you want to implement Conditional Access for workload identities as a near-term compensating control?
- Is lifecycle automation (auto-disable stale SPs, auto-notify owners pre-expiry) in scope for this engagement?
- Are you planning to adopt PIM for Groups to manage just-in-time access for workload identities?
- What governance maturity level are you aiming for — reactive (break/fix), proactive (policy-driven), or automated (self-healing)?
- Is there an identity or platform engineering team that will own this programme post-engagement?
- What is the single biggest workload identity pain point you want resolved by this engagement?

## References
- https://learn.microsoft.com/en-us/entra/workload-id/workload-identities-overview
- https://learn.microsoft.com/en-us/entra/architecture/security-operations-applications
- https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/what-is-application-management
