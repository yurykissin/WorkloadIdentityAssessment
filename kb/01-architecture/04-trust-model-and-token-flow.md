# Trust Model & Token Flow

How each workload identity type obtains an access token, what that token contains, and where Conditional Access is evaluated.

---

## 1. Entra ID as Issuer

Microsoft Entra ID is the OAuth 2.0 / OIDC authorisation server for all workload identity token flows described here.

| Attribute         | Value                                                                 |
|-------------------|-----------------------------------------------------------------------|
| Issuer URL        | `https://login.microsoftonline.com/<tenant-id>/v2.0`                 |
| OIDC discovery    | `https://login.microsoftonline.com/<tenant-id>/v2.0/.well-known/openid-configuration` |
| Token endpoint    | `https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/token`    |
| Signing keys      | JWKS at `jwks_uri` in the discovery document; rotated by Microsoft   |
| Token lifetime    | Access tokens: 60–75 minutes (default); configurable via token lifetime policy |
| Audience (`aud`)  | Set to the resource being called, e.g., `https://graph.microsoft.com`, `https://management.azure.com/`, or a custom app ID URI |

Entra ID signs access tokens with RS256. Consumers validate the `iss`, `aud`, `exp`, and `nbf` claims, and verify the signature against the JWKS.

---

## 2. Client Credentials Grant (App Registration + Secret or Certificate)

Based on RFC 6749 §4.4. The workload authenticates directly to Entra as itself — no user is involved.

```
POST https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/token

Content-Type: application/x-www-form-urlencoded

grant_type=client_credentials
&client_id=<app-registration-client-id>
&client_secret=<secret>          ← secret credential
&scope=https://graph.microsoft.com/.default
```

Or with a certificate (JWT client assertion, preferred over secret):

```
grant_type=client_credentials
&client_id=<app-registration-client-id>
&client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer
&client_assertion=<signed-JWT>   ← JWT signed with the registered certificate's private key
&scope=https://graph.microsoft.com/.default
```

The `/.default` scope instructs Entra to issue a token containing all *application* permissions (app roles) that have been granted to the service principal via admin consent.

---

## 3. Managed Identity Token Acquisition via IMDS

Azure-hosted resources obtain tokens via the Instance Metadata Service (IMDS) — a link-local HTTP endpoint that is only reachable from within the Azure resource.

**IMDS endpoint:**
```
http://169.254.169.254/metadata/identity/oauth2/token
  ?api-version=2018-02-01
  &resource=https://graph.microsoft.com/
  [&client_id=<user-assigned-mi-client-id>]   ← required if multiple MIs are attached
```

The Azure platform intercepts this request, verifies that the caller is the entitled resource, and returns a short-lived access token. No credential is exposed to the application.

**Azure SDK — `DefaultAzureCredential` chain:**

The Azure SDK's `DefaultAzureCredential` class tries credential sources in this order. The first to succeed is used:

1. `EnvironmentCredential` — reads `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_CLIENT_SECRET` / `AZURE_CLIENT_CERTIFICATE_PATH` from environment variables.
2. `WorkloadIdentityCredential` — reads `AZURE_FEDERATED_TOKEN_FILE`, `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` (injected by Azure Workload Identity / AKS webhook).
3. `ManagedIdentityCredential` — calls IMDS; uses `AZURE_CLIENT_ID` env var if set (targets a specific user-assigned MI).
4. `SharedTokenCacheCredential` — reads from the local token cache (dev machine scenarios).
5. `VisualStudioCodeCredential` — VS Code Azure Account extension.
6. `AzureCliCredential` — calls `az account get-access-token`.
7. `AzurePowerShellCredential` — calls `Get-AzAccessToken`.
8. `AzureDeveloperCliCredential` — `azd auth token`.

In production, the chain typically resolves at step 2 (AKS Workload Identity) or step 3 (managed identity). Steps 4–8 are for local development only and should never be the active credential in a deployed workload.

---

## 4. Federated Identity Credential Exchange Flow

Workload Identity Federation replaces the client secret or certificate with an external OIDC token. Entra ID acts as a token exchange endpoint.

**Numbered sequence:**

```
  External IdP                   Workload                    Entra ID
  (GitHub / K8s / SPIFFE)
        │                            │                           │
        │  1. Issue OIDC JWT          │                           │
        │  (iss, sub, aud)            │                           │
        │ ─────────────────────────► │                           │
        │                            │  2. POST /token           │
        │                            │     grant_type=           │
        │                            │     urn:ietf:params:oauth │
        │                            │     :grant-type:jwt-bearer │
        │                            │     client_assertion=<JWT>│
        │                            │ ────────────────────────► │
        │                            │                           │  3. Fetch issuer's
        │                            │                           │     OIDC discovery +
        │                            │                           │     JWKS (cached)
        │                            │                           │
        │                            │                           │  4. Validate:
        │                            │                           │     • issuer matches FIC
        │                            │                           │     • subject matches FIC
        │                            │                           │     • audience =
        │                            │                           │       api://AzureADTokenExchange
        │                            │                           │     • JWT signature valid
        │                            │                           │     • JWT not expired
        │                            │  5. Return access token   │
        │                            │  (aud = resource)         │
        │                            │ ◄──────────────────────── │
        │                            │                           │
        │                            │  6. Call resource API     │
        │                            │  Authorization: Bearer <token>
        │                            │ ──────────────────────────────►
```

**Key validation points (step 4):**
- The issuer URL in the FIC must exactly match the `iss` claim in the external JWT.
- The subject in the FIC must exactly match the `sub` claim (case-sensitive, no wildcards in production).
- The audience in the external JWT must be `api://AzureADTokenExchange` (the default and recommended value).
- Entra ID caches the external IdP's JWKS; cache is refreshed on key ID (`kid`) mismatch.

---

## 5. Token Contents

Access tokens issued by Entra ID for workload identity flows contain the following key claims:

| Claim     | Description                                                                            | Example Value                                          |
|-----------|----------------------------------------------------------------------------------------|--------------------------------------------------------|
| `aud`     | Audience — the resource the token is for.                                              | `https://graph.microsoft.com`                          |
| `iss`     | Issuer — the Entra ID token endpoint for the tenant.                                   | `https://login.microsoftonline.com/<tid>/v2.0`         |
| `appid`   | Application (client) ID of the app registration (v1 tokens).                           | `<client-id-guid>`                                     |
| `azp`     | Authorised party — client ID of the application (v2 tokens).                           | `<client-id-guid>`                                     |
| `oid`     | Object ID of the service principal in the tenant the token was issued in.              | `<sp-object-id-guid>`                                  |
| `sub`     | Subject — same as `oid` for service principal tokens (not user-specific).              | `<sp-object-id-guid>`                                  |
| `tid`     | Tenant ID where the token was issued.                                                  | `<tenant-id-guid>`                                     |
| `roles`   | App roles granted to the service principal (application permissions).                  | `["User.Read.All", "Mail.Send"]`                       |
| `idtyp`   | Identity type. Value `app` indicates a workload identity (service principal) token.   | `app`                                                  |
| `scp`     | Delegated scopes — **absent** in pure client credentials / workload identity tokens.  | (absent)                                               |
| `xms_az_rid` | Azure Resource ID — present on managed identity tokens; identifies the source resource. | `/subscriptions/<sub>/resourceGroups/<rg>/providers/...` |

**How to detect a workload identity token at the resource:** Check for `idtyp = app` and the absence of `scp`. If `scp` is present, the token is a delegated (user-context) token. Resources should validate both to ensure they are not mistakenly accepting user tokens in a workload-only API surface.

---

## 6. Conditional Access Evaluation for Workload Identity Sign-Ins

Conditional Access (CA) policies can be targeted at service principals — but only with the **Entra Workload Identities Premium** (Workload ID) licence.

**Evaluation point:** CA is evaluated at the Entra token endpoint (step 2 in any of the flows above) when the service principal requests an access token. If CA blocks the request, the token endpoint returns an error and no token is issued.

**What can be evaluated for workload identities:**
- IP/location conditions — allow only from specific named locations (e.g., Azure datacenter IP ranges or on-premises egress IPs).
- Sign-in risk condition — block sign-ins from service principals flagged as at-risk by Identity Protection (requires Workload Identities Premium for risk detection).
- Grant controls — "Block access" is supported; MFA and compliant device are not applicable to service principals.

**What cannot be evaluated (as of May 2026):**
- Device compliance — service principals do not have a device context.
- Application filter based on user assignment — not applicable.
- Authentication strength — not applicable.

**Configuration path:**
```
Entra admin center > Protection > Conditional Access > + New policy
  > Assignments > Workload identities
  > Target resources > (resource app or all cloud apps)
  > Conditions > Locations / Sign-in risk
  > Grant > Block access
```

**Licensing note:** Creating CA policies targeted at service principals is available only in tenants that have the Entra Workload Identities Premium add-on. The policy UI will not surface the "Workload identities" assignment option without this licence.

---

## See Also

- `/Volumes/data/vscode/MyProjects/entra-nrt/kb/app-registrations/12-certificates-and-secrets.md`
- `/Volumes/data/vscode/MyProjects/WorkloadIdentity/kb/01-architecture/01-workload-identity-taxonomy.md`

## Token Request Quick Reference

| Identity Type                            | Grant Type                                 | Auth Method                          | Endpoint Tenant Param                   |
|------------------------------------------|--------------------------------------------|--------------------------------------|-----------------------------------------|
| App registration + secret                | `client_credentials`                       | `client_secret`                      | Home tenant ID or `common`              |
| App registration + certificate           | `client_credentials`                       | `client_assertion` (signed JWT)      | Home tenant ID                          |
| App registration + federated credential  | `client_credentials` + `jwt-bearer`        | `client_assertion` (external JWT)    | Home tenant ID                          |
| System-assigned MI                       | IMDS (platform-handled)                    | None — platform-managed              | N/A (IMDS returns token directly)       |
| User-assigned MI                         | IMDS with `client_id` parameter            | None — platform-managed              | N/A                                     |

## References
- https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-client-creds-grant-flow
- https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation
- https://learn.microsoft.com/en-us/entra/identity/conditional-access/workload-identity
