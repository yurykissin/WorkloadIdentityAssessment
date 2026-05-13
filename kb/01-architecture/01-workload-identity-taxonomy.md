# Workload Identity Taxonomy

A reference defining every workload identity type in Microsoft Entra ID and Azure, how each one works, and where it lives.

---

## 1. Application Object (App Registration)

**What it is:** The application object is the *definition* of an application — its identity contract with Microsoft Entra ID. It is created via "App registrations" in the Entra admin center or via Microsoft Graph (`POST /applications`). The application object lives in exactly one tenant: the home tenant of the developer or organisation that registered it.

**Where it lives:** Microsoft Entra ID — visible at *Entra admin center > Identity > Applications > App registrations*.

**Lifecycle owner:** The application owner(s) assigned to the registration. Application objects are not tied to any Azure resource; they persist independently.

**Credentials it can hold:**
- Client secrets (passwords) — avoid; use only where no better option exists.
- Certificate credentials (X.509 public key uploaded; private key held by the app).
- Federated identity credentials — see §5.

**Cross-tenant behaviour:** A multi-tenant app registration can be consented to by other tenants. A single-tenant app registration is visible only in the home tenant.

**Portal location:** Entra admin center > Identity > Applications > **App registrations** (shows apps owned by your tenant). The "All applications" filter shows third-party apps that have been consented in.

---

## 2. Service Principal

**What it is:** The service principal is the *runtime instance* of an application object inside a specific Entra tenant. When an app registration is used in a tenant (including its own home tenant), Entra creates a corresponding service principal object that holds the actual permission grants, role assignments, and sign-in policy for that tenant.

**Key relationship:**
```
App Registration (home tenant)  ──creates──►  Service Principal (home tenant)
                                              Service Principal (tenant B, after consent)
                                              Service Principal (tenant C, after consent)
```

**Where it lives:** Microsoft Entra ID — visible at *Entra admin center > Identity > Applications > Enterprise applications*.

**Lifecycle owner:** Follows the app registration. The service principal is automatically deleted when the app registration is deleted (in the home tenant). In a guest tenant, the SP persists until explicitly removed or until the app is removed.

**Credentials it can hold:** Credentials are held on the *application object*, not the service principal. The SP authenticates using the credentials of its linked app registration.

**Portal location:** Entra admin center > Identity > Applications > **Enterprise applications** (all service principals). Filter by "Application type: Microsoft applications / Managed identities / All" to narrow down.

---

## 3. System-Assigned Managed Identity

**What it is:** A managed identity that is created automatically when enabled on a supported Azure resource (VM, App Service, Function App, AKS node pool, etc.) and is permanently bound to that resource's lifecycle.

**Lifecycle:** Created when enabled on the resource; automatically deleted when the resource is deleted. Cannot be shared across resources.

**Where it lives:** As a service principal in Entra ID (type: `ManagedIdentity`), visible at *Entra admin center > Identity > Applications > Enterprise applications* (filter: Managed Identities). Also visible at *Azure portal > \<resource\> > Identity > System assigned*.

**Credentials it can hold:** None visible to the application. Token acquisition is handled internally by the Azure platform via the Instance Metadata Service (IMDS) or the Azure Instance Metadata endpoint. No secret, certificate, or federated credential can be added.

**Portal path to enable:**
```
Azure portal > <resource> > Identity > System assigned > Status: On > Save
```

**Best for:** Single Azure resources whose identity lifecycle should be identical to the resource lifecycle.

---

## 4. User-Assigned Managed Identity

**What it is:** A standalone Azure resource of type `Microsoft.ManagedIdentity/userAssignedIdentities` that exists independently of any compute resource. It can be attached to one or more Azure resources simultaneously.

**Lifecycle:** Created and deleted explicitly, independently of any compute resource. Exists as long as the ARM resource exists.

**Where it lives:** As a service principal in Entra ID (type: `ManagedIdentity`), and as an Azure resource in a resource group. Visible at:
- Entra admin center > Identity > Applications > Enterprise applications (filter: Managed Identities).
- Azure portal > Resource group > \<user-assigned MI resource\>.
- Azure portal > \<compute resource\> > Identity > User assigned.

**Credentials it can hold:** Like system-assigned, no secret or certificate is exposed to the application. Additionally, **federated identity credentials can be added to user-assigned MIs** — enabling cross-cloud and cross-environment federation scenarios (e.g., an AKS pod using OIDC to assume a user-assigned MI without a secret).

**Portal path to create:**
```
Azure portal > Create a resource > search "User Assigned Managed Identity"
Azure portal > <resource> > Identity > User assigned > + Add
```

**Best for:** Identities shared across multiple Azure resources; identities that must outlive any single resource; AKS workload identity federation.

---

## 5. Federated Identity Credential on an App Registration

**What it is:** A trust relationship configured on an application object that allows an external identity provider (IdP) to issue OIDC tokens which Entra ID will exchange for Entra access tokens — without any secret or certificate stored in Azure.

**Mechanism:** The external IdP (GitHub Actions, GitLab, AKS OIDC issuer, AWS STS, generic OIDC) issues a JWT. The workload presents this JWT to Entra ID's token endpoint (`/oauth2/v2.0/token`). Entra validates the issuer URL, subject claim, and audience claim against the registered federated credential. If valid, Entra issues an access token for the requested scope.

**Where it lives:** On the application object in the app registration. Visible at:
```
Entra admin center > Identity > Applications > App registrations > <app> > Certificates & secrets > Federated credentials
```

**Key fields:** Issuer URL, Subject identifier, Audience (defaults to `api://AzureADTokenExchange`), Name.

**Credentials it can hold:** The federated credential configuration itself has no expiry and holds no secret.

**Best for:** GitHub Actions → Azure deployment; GitLab CI; AKS pods via Kubernetes service account token projection; cross-cloud federation (AWS IAM role assumption → Azure).

---

## 6. Federated Identity Credential on a User-Assigned Managed Identity

**What it is:** The same OIDC federation mechanism as §5, but configured directly on a user-assigned managed identity rather than on an app registration. The workload exchanges an external OIDC token for an Entra access token that represents the MI's identity.

**Where it lives:** On the user-assigned MI resource:
```
Azure portal > <user-assigned MI> > Federated credentials > + Add credential
```

**Why it matters:** This pattern is the canonical approach for **AKS Workload Identity** — a Kubernetes pod's service account token (projected via the AKS OIDC issuer) is exchanged for an Azure access token representing the user-assigned MI. No secret is needed anywhere in the pod.

**Best for:** AKS workloads; multi-cloud federation where the target identity should be a managed identity (not an app registration).

---

## 7. Legacy Service Account (Entra User as Automation Identity) — Anti-Pattern

**What it is:** A regular `User` object in Entra ID that is used as an automation or service account — authenticated via username and password or sometimes MFA-bypass configurations.

**Why it is an anti-pattern:**
- User accounts are subject to Conditional Access, MFA requirements, and password expiry policies designed for humans — workarounds create security gaps.
- Licensing cost: each user account consumes a licence.
- No clean lifecycle: user accounts are deprovisioned by HR/joiner-mover-leaver processes, not by workload decommissioning.
- Sign-in logs show as user sign-ins, not service principal sign-ins — harder to distinguish from human activity.
- Cannot hold federated credentials or benefit from IMDS-based token acquisition.

**Migration path:** Replace with a managed identity (if Azure-hosted) or a federated identity credential (if external), or a service principal with a certificate credential (if neither is feasible).

---

## Comparison Table

| Type                             | Lives in                       | Created by                        | Lifecycle                        | Credentials                          | Cross-tenant | Best for                                              |
|----------------------------------|--------------------------------|-----------------------------------|----------------------------------|--------------------------------------|--------------|-------------------------------------------------------|
| App Registration                 | Entra ID (home tenant)         | Developer / admin via portal / Graph | Explicit deletion required    | Secret, certificate, federated cred  | Yes (multi-tenant) | Defining an application's identity contract         |
| Service Principal                | Entra ID (any tenant)          | Auto-created from app reg; or via Graph | Follows app reg (home tenant); explicit in guest tenants | Inherited from app reg | Per-tenant SP | Runtime identity instance; RBAC / consent target   |
| System-Assigned MI               | Azure resource + Entra ID      | Azure platform when enabled on resource | Tied to Azure resource lifecycle | None (platform-managed)              | No           | Single Azure resource; simple lifecycle              |
| User-Assigned MI                 | Azure ARM resource + Entra ID  | Explicit ARM / IaC creation       | Explicit deletion required       | None (platform-managed) + federated creds | No      | Shared identity; AKS federation; cross-resource      |
| Federated Cred (App Reg)         | App Registration               | Admin via portal / Graph          | No expiry; trust chain rotated externally | None (trust relationship only) | N/A       | GitHub Actions, GitLab, generic OIDC CI/CD → Azure  |
| Federated Cred (User-Assigned MI)| User-Assigned MI               | Admin via portal / Graph          | No expiry; trust chain rotated externally | None (trust relationship only) | N/A       | AKS Workload Identity; multi-cloud federation        |
| Legacy Service Account (User)    | Entra ID                       | Admin                             | HR / manual                      | Password (MFA bypassed in many cases) | No          | **Anti-pattern — do not use for automation**         |

---

## Portal Navigation Quick Reference

| Object Type                          | Where to Find in Entra Admin Center                                             |
|--------------------------------------|---------------------------------------------------------------------------------|
| App registrations (all)              | Identity > Applications > App registrations > All applications                 |
| App registrations (my org's)         | Identity > Applications > App registrations > Owned applications               |
| Service principals / Enterprise apps | Identity > Applications > Enterprise applications                               |
| Filter for managed identities        | Enterprise applications > Application type: Managed identities                 |
| Federated credentials on an app      | App registrations > \<app\> > Certificates & secrets > Federated credentials   |
| MI federated credentials             | Azure portal > \<user-assigned MI resource\> > Federated credentials           |
| System-assigned MI on a resource     | Azure portal > \<resource\> > Identity > System assigned                       |
| User-assigned MI attachment          | Azure portal > \<resource\> > Identity > User assigned                         |
| Custom security attributes           | Identity > Overview > Custom security attributes                               |
| App management policies              | Microsoft Graph only — `GET /v1.0/policies/appManagementPolicies`              |

---

## Anti-Pattern Quick Reference

| Anti-Pattern                             | Correct Pattern                                                    |
|------------------------------------------|--------------------------------------------------------------------|
| Regular Entra user as service account    | Managed identity or federated credential                           |
| Shared SP across unrelated workloads     | Per-workload SP or user-assigned MI with documented sharing rationale |
| System-assigned MI on ephemeral compute  | User-assigned MI so identity survives resource rebuild             |
| Federated credential with wildcard subject | Exact subject match scoped to repo + environment or K8s namespace |
| FIC on system-assigned MI               | Not supported — use user-assigned MI for federation               |

---

## See Also

- `/Volumes/data/vscode/MyProjects/entra-nrt/kb/app-registrations/01-overview-essentials.md`
- `/Volumes/data/vscode/MyProjects/entra-nrt/kb/app-registrations/12-certificates-and-secrets.md` — federated credentials field-by-field
- `/Volumes/data/vscode/MyProjects/entra-nrt/kb/app-registrations/17-owners.md`
- `/Volumes/data/vscode/MyProjects/entra-nrt/kb/enterprise-apps/` — enterprise apps / service principal portal walkthrough

## Key Terminology Summary

| Term                       | Meaning                                                                                   |
|----------------------------|-------------------------------------------------------------------------------------------|
| Application (object)       | The app registration — the design-time definition living in the home tenant              |
| Service principal          | The runtime instance of an application in a specific tenant                              |
| Managed identity           | A service principal whose lifecycle and credentials are managed by the Azure platform    |
| Federated credential       | A trust relationship between an Entra SP/MI and an external OIDC IdP — no secret        |
| Client ID                  | The application's public identifier, used in token requests and RBAC assignments         |
| Object ID (OID)            | The immutable GUID of the service principal in a given tenant                            |

## References
- https://learn.microsoft.com/en-us/entra/workload-id/workload-identities-overview
- https://learn.microsoft.com/en-us/entra/identity-platform/app-objects-and-service-principals
- https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/overview
