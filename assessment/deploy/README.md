# Workload Identity Assessment — Deploy to Azure

A read-only assessment of your Microsoft Entra workload identities (app
registrations, service principals, managed identities, federated credentials,
permissions, monitoring, Conditional Access).

The assessment runs **inside your tenant** as a managed identity you control,
and produces a self-contained **HTML report** plus a **raw-data ZIP**, both
delivered as 7-day SAS URLs. Nothing leaves your tenant unless you choose to
share those URLs.

---

## How it works

A single ARM template (`azuredeploy.json`) provisions:

| Resource | Purpose |
|---|---|
| Storage account (Standard_LRS, private) | Stores the report |
| Blob container `reports`, private | Holds the report blobs |
| Role assignments: Reader on the RG, Storage Blob Data Contributor + Storage Blob Delegator on the storage account | Lets the UAMI read your resources and upload the report |
| Deployment script container | Runs the assessment, then auto-deletes |

The template does **not** create the user-assigned managed identity (UAMI).
You create it manually first (1 click in the portal), then grant it the
read-only Microsoft Graph application permissions listed below (also manual,
because granting Graph app roles is not an ARM operation). After that, the
ARM template is a single Deploy-to-Azure click.

Cost: roughly $0.05 / month for storage + a few cents per assessment run.

---

## Step 1 — Create the user-assigned managed identity (manual)

You can do this via the Azure portal (3 minutes) or Azure CLI (30 seconds).

### Option A — Azure portal

1. Go to **Managed Identities** → **+ Create**.
2. Pick (or create) a resource group, e.g. `rg-wia`. Same RG you'll use for
   the assessment deployment.
3. Region: any. Name: e.g. `id-wia`. Click **Review + create** → **Create**.
4. After it's created, open it. Copy from the **Overview** tab:
   * **Client ID** (a GUID)
   * **Object (principal) ID** (a different GUID — needed for step 2)
   * **Resource ID** (use the JSON view button or read it from the URL)

### Option B — Azure CLI (Cloud Shell)

```bash
RG=rg-wia
LOCATION=westeurope
NAME=id-wia

az group create -n $RG -l $LOCATION
az identity create -n $NAME -g $RG -l $LOCATION

# Capture the IDs you'll need
az identity show -n $NAME -g $RG \
  --query "{resourceId:id, clientId:clientId, principalId:principalId}" -o json
```

Save those three values.

---

## Step 2 — Grant Microsoft Graph application permissions to the UAMI (manual)

The assessment needs 7 read-only Microsoft Graph application permissions.
Granting Graph app roles requires **Global Administrator** (or
Privileged Role Administrator). Two ways:

### Option A — Cloud Shell PowerShell (recommended, ~30 seconds)

```powershell
# 1. Download the helper from the assessor's repo
$url = 'https://raw.githubusercontent.com/yurykissin/WorkloadIdentityAssessment/main/assessment/deploy/grant-graph-permissions.ps1'
Invoke-WebRequest $url -OutFile grant-graph-permissions.ps1

# 2. Connect with the scopes needed to grant app roles
Connect-MgGraph -Scopes 'AppRoleAssignment.ReadWrite.All','Application.Read.All' -NoWelcome

# 3. Run it (use the principalId / Object ID from step 1)
./grant-graph-permissions.ps1 -PrincipalId <principalId-from-step-1>
```

The script grants exactly these 7 application permissions and nothing else:

| Microsoft Graph permission       | Why it's needed                                  |
|----------------------------------|--------------------------------------------------|
| `Application.Read.All`           | Enumerate app registrations and service principals |
| `Directory.Read.All`             | Read directory roles and memberships             |
| `Policy.Read.All`                | Read Conditional Access policies, authorization policy |
| `RoleManagement.Read.Directory`  | Read directory role assignments                  |
| `AuditLog.Read.All`              | Read sign-in activity for service principals / managed identities |
| `IdentityRiskEvent.Read.All`     | Read risky workload identity events (skipped if Identity Protection isn't licensed) |
| `CrossTenantInformation.ReadBasic.All` | Read cross-tenant access policy defaults    |

All are **read-only**. The MI cannot modify anything in your directory.

### Option B — Azure portal (manual click-through, ~5 minutes)

The portal does not expose Graph app role grants for managed identities
directly — you have to use the **Enterprise applications** blade.

1. **Microsoft Entra admin center** → **Identity** → **Applications** →
   **Enterprise applications**.
2. Application type filter: **Managed Identities**. Search for the UAMI you
   created in step 1 (e.g. `id-wia`). Open it.
3. **Permissions** → **Grant admin consent**. The portal will prompt for
   each permission you want to add.
4. For each of the 7 permissions in the table above:
   * Click **Add a permission** → **Microsoft Graph** → **Application
     permissions** → search → select → **Add permission**.
   * Then click **Grant admin consent for <tenant>**.

Option A is far less tedious. Use it if you can.

Optional Agent ID and risky-service-principal collection needs additional
**read-only** app roles. Opt in when granting permissions:

```powershell
./grant-graph-permissions.ps1 -PrincipalId '<uami-principal-id>' -IncludeOptionalWorkloadEvidence
```

This adds `AgentIdentity.Read.All`, `AgentIdentityBlueprint.Read.All` and
`IdentityRiskyServicePrincipal.Read.All`. It does not bypass feature licensing
or cloud/API availability. Missing optional permissions leave those capabilities
unavailable while baseline collection continues. The assessment itself performs
GETs; this separate permission-granting bootstrap is an administrative write.
See [capability and manual-assessment limits](../README.md#controls-sources-and-evidence-limits).

### Option C — Azure CLI / REST one-liner per permission

```bash
PRINCIPAL_ID=<principalId-from-step-1>
GRAPH_APP_ID=00000003-0000-0000-c000-000000000000

# Microsoft Graph SP object ID
GRAPH_SP_ID=$(az ad sp show --id $GRAPH_APP_ID --query id -o tsv)

for ROLE in Application.Read.All Directory.Read.All Policy.Read.All \
            RoleManagement.Read.Directory AuditLog.Read.All \
            IdentityRiskEvent.Read.All CrossTenantInformation.ReadBasic.All; do
  ROLE_ID=$(az ad sp show --id $GRAPH_APP_ID \
    --query "appRoles[?value=='$ROLE'].id | [0]" -o tsv)
  az rest --method POST \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$PRINCIPAL_ID/appRoleAssignments" \
    --body "{\"principalId\":\"$PRINCIPAL_ID\",\"resourceId\":\"$GRAPH_SP_ID\",\"appRoleId\":\"$ROLE_ID\"}"
done
```

---

## Step 3 — Deploy the assessment (one click)

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FCHANGE-ME%2FCHANGE-ME%2Fmain%2Fassessment%2Fdeploy%2Fazuredeploy.json)

> The repo path `yurykissin/WorkloadIdentityAssessment` in the URL above must be replaced with
> the public GitHub repo your assessor published the templates to.

Fill in the form:

| Field              | Value |
|--------------------|-------|
| Resource group     | Same RG as the UAMI (e.g. `rg-wia`) |
| `uamiResourceId`   | from step 1 |
| `uamiClientId`     | from step 1 |
| `namePrefix`       | `wia` (default — controls the storage account name) |
| `artifactsBaseUrl` | as provided by your assessor (must end with `/`) |

The artifact host must preserve the assessment directory layout: the base points
to `scripts/`, including its `report-assets/` child, and `controls/catalog.json`
is a sibling of `scripts/`. The downloader requests `../controls/catalog.json`.
For SAS-protected hosting, that relative path must be covered by the supplied
token as well as the script and asset paths.

Click **Create**. The template:

1. Creates a private storage account + a `reports` blob container.
2. Assigns the UAMI three role assignments (Reader on the RG, Storage Blob
   Data Contributor + Delegator on the storage account).
3. Spins up an `AzurePowerShell` deployment-script container running as
   that UAMI. The container:
   * Installs the Microsoft Graph PowerShell modules (~3 min).
   * Connects to Graph as the UAMI.
   * Verifies the required permissions are granted (fails fast otherwise).
   * Downloads the selected collectors, `Assessment.Common.psm1`, `Assessment.Controls.psm1`, `../controls/catalog.json`,
     `09-html-report.ps1` and the three
     `report-assets/` files from `artifactsBaseUrl`.
   * Runs the selected collection scripts with one shared, in-memory directory
     cache. Duration depends on tenant size, Graph latency and throttling.
   * Builds the HTML report.
   * Uploads HTML + a raw-data ZIP to your storage account.
   * Mints a 7-day SAS URL for each.
   * Auto-deletes itself on success.

When the deployment finishes, open the **Outputs** tab.
You'll see:

* `reportUrl`  — open in a browser to view the HTML report
* `rawDataUrl` — ZIP of all raw JSON outputs
* `expiresAt`  — UTC timestamp when the SAS URLs expire (default 7 days)
* `storageAccountName` — the storage account that holds the blobs

Forward `reportUrl` to your assessor if you want them to debrief you.

---

## Re-running the assessment

The deployment script is keyed on `forceUpdateTag` (default = `utcNow()`),
so any redeploy re-runs the assessment and produces a fresh
`report-<timestamp>.html` and `raw-<timestamp>.zip` in the same container.
Previous reports remain (until you delete them).

If the UAMI is missing a permission, the deployment script fails fast with
a clear message. Add the missing permission per step 2, redeploy, done.

## Cleanup

Delete the resource group (or just the storage account + UAMI). Everything
created lives there. Role assignments are scoped to that RG and storage
account, so nothing is left behind elsewhere.

## Hosting the templates yourself

If you'd rather host the templates and scripts in your own repo (for
auditability or because your tenant blocks GitHub egress):

```bash
# Replace the placeholder repo path everywhere
sed -i '' 's|yurykissin/WorkloadIdentityAssessment|<your-org>/<your-repo>|g' deploy/*.json deploy/*.md
```

Push to GitHub. The `artifactsBaseUrl` parameter on `azuredeploy.json`
accepts any HTTPS-reachable URL ending in `/`. If hosted in a private
storage account, also set `artifactsSasToken` (include the leading `?`).

Publish the collectors, shared module, renderer and assets from the same version, preserving this
layout beneath `artifactsBaseUrl`:

```text
Assessment.Common.psm1
09-html-report.ps1
report-assets/template.html
report-assets/styles.css
report-assets/app.js
```

The deployment downloads the assets beside the renderer and embeds them into
the final HTML. Report readers need only the HTML file, not the asset folder.
The deployment's flat output directory remains supported. Local validation
parses the ARM JSON and embedded PowerShell and checks asset packaging; it does
not execute an Azure deployment.

---

## Security posture

* The UAMI lives in your tenant. You created it. You control it. You can
  revoke its Graph permissions at any time from Enterprise applications →
  the UAMI → Permissions → trash icon.
* The storage account is **private**. The only way to read the report is
  via the SAS URL emitted in the deployment outputs.
* The SAS URL expires after 7 days. Generate a fresh one any time by
  redeploying.
* The UAMI's Graph permissions are **all read-only**.
* The UAMI's Azure permission is **Reader on a single resource group**
  (the one you deploy to), plus **Storage Blob Data Contributor +
  Delegator on the one storage account** the template creates.
* The deployment-script container has outbound network only to:
  Azure ARM, Microsoft Graph, the artifacts URL you supply, and PowerShell
  Gallery (for module install).
