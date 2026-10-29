# Workload Identity Assessment Toolkit

Read-only PowerShell scripts + ARM-based one-click deploy that inventory the
**workload identity surface** in a Microsoft Entra tenant + linked Azure
subscriptions and produce a single self-contained HTML report with findings
and recommendations.

The scripts never modify state. They call read-only Microsoft Graph and Azure
Resource Manager endpoints only.

## What it produces

- CSV / JSON dumps of the current workload-identity surface (app
  registrations, service principals, managed identities, federated
  credentials, credentials, permissions, sign-in activity, monitoring
  coverage, Conditional Access policies)
- A dark, tabbed offline HTML report with searchable identity details, severity
  filters, complete paged tables, source availability and raw JSON
  (`output/<ts>/report.html`) — see screenshots in the
  [root README](../README.md#sample-report)
- A summary written to console after each script run

## Two ways to run

| Mode | Best for | Doc |
|------|---------|-----|
| **Local PowerShell** | Iterating on the scripts, debugging, dev | this README, below |
| **One-click ARM** | Running against a tenant where you don't want to install modules locally; producing a sharable report URL | [`deploy/README.md`](deploy/README.md) |

## Prerequisites (local mode)

| Requirement | Value |
|-------------|-------|
| PowerShell | 7.2+ (Windows / macOS / Linux) |
| Microsoft Graph PowerShell SDK | Installed via `00-prereqs.ps1` |
| Az PowerShell module | Entra + Azure only; installed via `00-prereqs.ps1` |
| `Microsoft.Graph` scopes (delegated, signed in interactively) | `Application.Read.All`, `Directory.Read.All`, `Policy.Read.All`, `AuditLog.Read.All`, `IdentityRiskEvent.Read.All`, `RoleManagement.Read.Directory`, `CrossTenantInformation.ReadBasic.All` |
| Azure RBAC | Entra + Azure only: `Reader` on subscriptions in scope |

Run `./scripts/00-prereqs.ps1` first — it installs modules and validates that
the signed-in user has the required scopes/roles.

## Layout

```
assessment/
├── README.md                          ← this file
├── scripts/
│   ├── 00-prereqs.ps1                 ← module install + permission check
│   ├── 01-tenant-context.ps1          ← tenant info, licenses, auth policy
│   ├── 02-inventory.ps1               ← MIs, SPs, app regs
│   ├── 03-credential-hygiene.ps1      ← secrets vs certs, lifetime, expiry
│   ├── 04-federated-credentials.ps1   ← FICs (CI/CD, agent, etc.)
│   ├── 05-permission-surface.ps1      ← Graph app-roles + Azure RBAC
│   ├── 06-stale-and-orphaned.ps1      ← unused / unowned identities
│   ├── 07-monitoring-coverage.ps1     ← diag settings, LAW, KV
│   ├── 08-ca-for-workload-identities.ps1  ← CA policy targeting WIs
│   ├── 09-html-report.ps1             ← consolidated HTML report
│   ├── Assessment.Common.psm1        ← tenant checks, paged Graph reads, run cache
│   ├── report-assets/                ← template, CSS and JS embedded by 09
│   └── run-all.ps1                    ← runs collectors 01..08
├── tests/                             ← mocked collection + offline report tests
├── deploy/                            ← ARM one-click
│   ├── README.md
│   ├── azuredeploy.json
│   ├── azuredeploy.parameters.json
│   └── grant-graph-permissions.ps1    ← helper for required app-roles
├── docs/screenshots/                  ← report screenshots used by READMEs
└── output/                            ← per-run JSON/CSV/HTML (gitignored)
```

## Quick start (local)

Run from `assessment/` in PowerShell. After the one-time module setup, the
entry point handles sign-in, collection, report generation and opening the report.

```powershell
# One-time setup, if the required modules are not already installed
./scripts/00-prereqs.ps1

# Normal run: choose Entra only or Entra + Azure before sign-in
./scripts/run-all.ps1
```

The startup choices are:

| Choice | What it collects | Authentication |
| --- | --- | --- |
| **1. Entra only** (default) | App registrations, service principals, credentials, app federation, directory permissions, hygiene and Conditional Access | Microsoft Graph only |
| **2. Entra + Azure** | Everything above, plus subscriptions, managed-identity resources/federation, Azure RBAC, Key Vault, Log Analytics and diagnostic settings | Microsoft Graph and Azure |

Entra-only runs do not require or load Az modules, prompt for Azure login or
select a subscription. Managed-identity service principal objects can still
appear in Entra inventory; their Azure resource details are not collected.
Excluded Azure checks are labelled **Not collected**, not zero or compliant.

From `assessment/scripts/`, the same command is simply `./run-all.ps1`.
The default output is `assessment/output/<timestamp>/`, containing collected
JSON/CSV, run summaries, `transcript.txt` and `report.html`. Keep the complete
snapshot folder.

Optional controls:

```powershell
# Explicitly choose the assessment tenant
./scripts/run-all.ps1 -TenantId '<assessment-tenant-id>'

# Generate the report without opening a browser
./scripts/run-all.ps1 -NoOpen

# Bypass the menu and collect Entra only
./scripts/run-all.ps1 -AssessmentScope Entra

# Bypass the menu and include Azure resources
./scripts/run-all.ps1 -AssessmentScope EntraAndAzure

# Use already connected, caller-managed SDK contexts without signing in
./scripts/run-all.ps1 -UseExistingContext -NoOpen
```

### Authentication and collection behavior

`run-all.ps1` uses the same Graph sign-in pattern as CAPVisualizer: import
`Microsoft.Graph.Authentication`, then call `Connect-MgGraph` with the assessment
scopes and standard browser authentication. It leaves `ContextScope` unspecified,
using the SDK's default cache behavior rather than forcing process-only caching.
Normal interactive runs disconnect an existing Graph session before sign-in.
Without `-TenantId`, browser sign-in determines the tenant; the previous Graph
tenant is not passed into the new connection. Azure's process-scoped contexts
are cleared before Azure sign-in, which is pinned to the resulting Graph tenant.
Process-only context autosave is disabled and broad context population skipped.
On exit, including failed runs, the script disconnects its Graph session and,
when Azure was selected, clears its Azure process contexts. Entra-only runs
leave existing Azure sessions untouched. Cleanup failures are reported explicitly.
Browser SSO cookies and OS broker sessions are not cleared; browser/MFA prompts
and account selection depend on those services. `-TenantId` explicitly selects
the assessment tenant.

Different account names are valid when both contexts target the same tenant and
have the required access. Final tenant alignment is checked before collection;
canceled or failed authentication stops the run without falling back to an old
account. Azure subscription discovery is restricted to the assessment tenant.
Existing Graph cloud selection is retained for the public, US Government and
China clouds; other environments require caller-managed contexts.

An existing app-only Graph/Azure setup is reused without interactive login or
opening a browser. `-UseExistingContext` also selects caller-managed authentication
explicitly: required contexts must already target the same tenant, and delegated
Graph can use either default or process scope. Supply a GUID, not a tenant
domain, when combining that switch with `-TenantId`. Caller-managed and existing
app-only contexts are not signed out automatically.
Caller-managed/app-only runs default to `EntraAndAzure` without a menu; specify
`-AssessmentScope Entra` to require only Graph in those modes.

Individual collectors remain non-interactive and require connected contexts.
They can be run separately with `-OutputDir <run-folder>`. The bootstrap
uses the SDK's supported sign-out commands rather than manually deleting token
stores, changing Keychain permissions or weakening encrypted token storage.
The Graph SDK's default cache can persist authentication using the OS
credential store; macOS can therefore request Keychain access. This matches
CAPVisualizer's sign-in pattern, not a guarantee that every SDK/OS combination
avoids a credential-store dialog. Azure sign-in starts only after Graph sign-in
and tenant validation succeed; cleanup still runs if Graph authentication fails.
The assessment helper module is refreshed before each run. Collector 05 also
refreshes the control/classifier module on entry, so toolkit updates in an
existing PowerShell window do not reuse outdated permission functions. This
does not reset the shared collection cache or authentication. Updating an
already loaded Graph/Azure SDK can still require a fresh PowerShell process.

The `-SubscriptionIds` option requires `EntraAndAzure`. Entra-only collection
also requires a fresh output folder so stale Azure exports cannot enter the
report; use the offline renderer to reopen an existing snapshot. Individual
mixed collectors (01, 02, 04 and 05) accept `-EntraOnly` when run separately.
Collector 07 requires Azure and is excluded from Entra-only runs.

Collector failures remain visible in the run summary and produce a partial-run
warning. Available JSON can still be rendered into a partial report. If no
collector JSON exists, no report is generated. Rendering retained JSON with
`09-html-report.ps1` remains fully offline and requires no authentication.

Each run saves the PowerShell console transcript to `<run-folder>/transcript.txt`,
starting before the scope menu and sign-in and ending after sign-out, including
failed startup and collection. Reusing a folder appends to its transcript.
Failed startup can therefore leave a folder containing only that log.
Transcripts contain assessment identities, paths and diagnostic output; handle
them with the same access controls as the exports. SDK browser/OS dialogs and
animated progress updates are not console transcript text.

Directory paging updates a PowerShell progress display instead of printing a
line per page; one final count is logged per completed directory pass. Failed
collectors also retain their error message and script stack in `run-summary.json`.
The report uses that status to explain missing exports, and does not evaluate
an export whose collector is recorded as failed. Without run metadata, missing
files still have unknown collection status.
After fixing a failed permissions collector, rerun collection into a fresh run
folder. Re-rendering alone cannot recover grants that were never exported.

Service principals without an application ID remain in inventory with unknown
sign-in activity. Permission assignments with missing resource/role information
remain in the permissions export with their available IDs,
`ResolutionStatus=Unresolved` and `Tier=UNKNOWN`, with a collection warning.

### Secret lifetime, redirect ownership and organization-wide consent

Catalog 1.4 adds these source-backed review controls without changing the
permission-risk policy or making tenant changes:

| Control | What is checked | Interpretation |
| --- | --- | --- |
| `WI.CRED.6` / `WI.CRED.7` | Application-registration / SP-origin client-secret start and end dates | High review for total lifetime **over 365 days**, including far-future dates, or unknown/invalid lifetime evidence. Expired credentials have separate controls; certificates are not client secrets. |
| `WI.APP.4` | Each exported non-loopback HTTP(S) redirect URI and host | Medium **manual review** of current domain registration, DNS/hosting control and business need. Invalid URIs also require review. |
| `WI.CONSENT.1` | Actual delegated grants with `consentType=AllPrincipals` | Info visibility of organization-wide consent, independently of the permission's capability rating. Counts are granted permission rows, not users or consent events. |

[Microsoft recommends](https://learn.microsoft.com/en-us/entra/identity-platform/how-to-add-credentials)
client-secret expiration under 12 months and discourages production client
secrets. **365 days is this toolkit's review threshold**, not an exact universal
Microsoft maximum or a safety guarantee for shorter secrets. Missing expiry
does not prove a secret lives forever. Missing start dates, invalid ranges or
insufficient snapshot evidence remain explicitly unknown. Both secret controls
preserve exact credential/object evidence and show lifetime status in the
report. Validate dependencies and service-managed credential workflows before
rotation; prefer managed identities or federation where supported.

[Microsoft recommends maintaining ownership of redirect URIs](https://learn.microsoft.com/en-us/entra/identity-platform/security-best-practices-for-app-registration).
The report supplies a per-URI review list, including a tenant verified-domain
hint when exported. **It does not automatically establish that a domain is
abandoned, unregistered, dangling or reclaimable.** A verified-domain match is
not current ownership proof. No DNS, HTTP, RDAP/registration or takeover probes
are performed. Loopback and native/custom schemes are excluded from this
domain-ownership check only, not approved as safe authentication settings.
Known empty redirect arrays are distinct from uncollected configuration.

The Permissions view includes a searchable/filterable **Consent audience**:
organization-wide, specific user, not granted, unknown or not applicable.
[AllPrincipals](https://learn.microsoft.com/en-us/graph/api/resources/oauth2permissiongrant?view=graph-rest-1.0)
is the resulting grant associated with "Consent on behalf of your organization,"
not evidence that a literal checkbox was clicked or who approved it; grants
can also be created through APIs. Application permissions and configured-only
requests are not these delegated grants. Organization-wide `User.Read` is not
automatically High; dangerous delegated capabilities remain independently
flagged by the existing permission rules. Unavailable consent evidence cannot
produce an all-clear.

Re-render an existing snapshot offline to get these controls and views when
the required fields were exported. Missing credential dates, redirect inventory
or delegated-grant collection cannot be recovered by rendering; collect fresh
evidence when needed. Original exports and raw report evidence remain unchanged.

### Credential activity (preview) and privilege review

Collector 03 also queries the Microsoft Graph **beta**
`/reports/appCredentialSignInActivities` endpoint once per collection, following
every continuation with the existing retry handling. This preview API is
documented for the global cloud only. Existing bootstrap scopes already include
`AuditLog.Read.All` (the API's least-privileged permission; `Directory.Read.All`
is also supported). Delegated access requires a supported role such as Reports
Reader, Security Reader or Security Administrator and applicable report access.
No additional sign-in or Beta.Reports module is required.

Microsoft marks this API beta/preview, subject to change and unsupported for
production applications. Denied, unsupported, malformed or incomplete queries
are logged and exported as unavailable, never as a successful zero-result usage
assessment. The normal credential expiry inventory still completes.

Activity is matched to **app-registration credentials only**, using application
object ID, credential key ID, credential type and `credentialOrigin=application`.
Client IDs must also agree when returned. Names and key IDs alone are never join
keys. Service-principal-origin activity is not matched to application credentials.
The latest valid timestamp across matched resource records is retained, along
with activity IDs and resource/timestamp evidence in JSON and row details.

The **Credentials** tab separates expiry from usage:

- **Expired** comes from the credential inventory's expiration date.
- **Inactive >= 90 days (review)** requires matched, valid last-use evidence.
  It identifies a cleanup review candidate, not confirmed lack of business need.
- **Unknown** covers unmatched credentials, missing/invalid timestamps and
  unavailable activity. No returned activity does not mean "never used."

New activity metadata, usage fields and review flags appear in JSON/CSV, the
HTML report and run summaries. Older exports remain renderable and explicitly
show that credential usage was not assessed; they cannot gain activity evidence
through an offline re-render.

The **Permissions** and **Findings** tabs use the versioned `PermissionRisk`
rules in `controls/catalog.json`. The baseline is Microsoft's
[published risky-permission categories](https://learn.microsoft.com/en-us/security/operations/incident-response-playbook-app-consent#classifying-risky-permissions),
pinned to source revision `4d7884235fb91d7248ea81b51a909ed67abe04ce`.
The [readable permission-risk reference](controls/permission-risk-reference.md)
lists every current rule and severity, the Agent CLI example, external
Microsoft/SpecterOps/AZTier sources, and the implemented severity policy.
The implemented baseline includes sensitive delegated permission families, their application-only
versions, the highest-risk exact entries, and application-only write access.
`Mail.ReadBasic*` is excluded from the published Mail family, not declared safe.
Matching uses API identity and permission type, not the API's display name.
The catalog explicitly identifies known Microsoft/legacy API IDs; unfamiliar
legacy APIs or nonstandard write-capability names remain unclassified for review.

Additional Agent ID management/read, directory reconnaissance and other
capability rules are **labelled toolkit extensions**, grounded in Microsoft's
permission descriptions, not falsely attributed to the published risky list.
Application-only access has no signed-in-user boundary. Delegated scopes can
still be dangerous, including `Mail.Read` and `Files.Read` without an
admin-consent requirement. Neither publisher, official setup requirements nor
business justification suppresses exposure findings. Reviewers can mitigate or
explicitly accept the risk; this tool does not change tenant grants.

For **Microsoft Graph application permissions**, the catalog embeds 614 reviewed
AZTier mappings and 158 detected-but-untiered entries from snapshot
`7738e071a2087c79626875f890cd4f6476fd848d`. Reviewed tiers take precedence:
**Tier 0 = High** (`WI.PERM.1`), **Tier 1 = Medium** (`WI.PERM.5`),
**Tier 2 = Info** (`WI.PERM.6`). Detected-but-untiered access is **Low / Unrated**
(`WI.PERM.4`) by the selected assessment policy, even if a separate capability
rule raises concerns. Capability rationale is retained visibly, not suppressed.
Low is a review priority, **not a researched low-risk conclusion**.
Unclassified and unresolved definitions also use Low / Unrated.

AZTier's reviewed application-permission file last changed on 2025-10-30; its
untiered discovery file last changed on 2026-10-23. Upstream detects additions
daily, then reviews attack paths manually. Recent discovery does not imply
recent risk research. Source URLs, revision, file hashes, attribution and the
GPL-3.0 source-data license are embedded in the catalog and offline report.
SpecterOps and Semperis corroborating research is attached to the relevant
application permission-grant/directory-role-administration capabilities.

Application-only AZTier ratings **never transfer to delegated permissions or
other APIs**. Those, and permissions not present in either AZTier list, retain
the first matching Microsoft/toolkit capability rule. Ordinary agent, app and
directory inventory reads, including delegated `AgentIdentity.Read.All` and
`Application.Read.All`, are **Info** under toolkit policy, not elevated-risk
warnings. `AuditLog.Read.All` and `IdentityRiskEvent.Read.All` are **Medium**
because they expose security/audit evidence. Agent-management writes and
sensitive-content rules remain **High**. Delegated access alone never makes a
permission High. These are toolkit review priorities grounded in capability
descriptions, not new Microsoft or AZTier severity recommendations.
The application `Application.Read.All` rating remains AZTier Tier 2 / Info;
unreviewed Agent application permissions remain Low / Unrated.
There is no `STANDARD`/safe fallback. Microsoft's small lowest-impact delegated
list remains visible without a permission-risk finding; `offline_access`
qualifies only with known lower-impact companion scopes for the same client,
API and consent subject. Merely configured requests are classified for context
but do not count as existing grants or produce grant findings.
Privileged Azure RBAC retains its separate High review.

The same classifier runs during collection and offline re-render, replacing
stale derived tiers without modifying original exports or embedded `RawData`.
Permission rows show severity, classification, rationale, origin, rule and the
relevant Microsoft/AZTier source. Informational capability context is not styled
as an additional elevated-risk warning. **Control coverage > Permission risk catalog
and sources** exposes searchable reviewed/untiered mappings, fallback rules,
provenance and the source-data license. Permissions and Control coverage show
the full methodology disclaimer. Findings keeps a short visible caveat with
the complete policy under **Permission severity methodology and sources**,
covering precedence, freshness, delegated boundaries, Low / Unrated and
effective-scope limitations.
Findings identify exposure, not proven compromise, unnecessary or unused access.
Severity is a toolkit review decision, not a SCuBA compliance score.

References:
[Preview activity API and access requirements](https://learn.microsoft.com/graph/api/reportroot-list-appcredentialsigninactivities?view=graph-rest-beta),
[activity fields](https://learn.microsoft.com/graph/api/resources/appcredentialsigninactivity?view=graph-rest-beta),
[overprivilege and least-privilege review](https://learn.microsoft.com/security/zero-trust/develop/overprivileged-permissions).

Inventory uses paged Graph expansions for app/SP owners, app FICs and app-role
assignments instead of making one enrichment request per identity. Complete
relationships are cached in memory for one `run-all.ps1` invocation and reused
by federation, permissions and hygiene. The cache is cleared on completion or
failure. Expanded relationship continuations are followed; full expansions
without a continuation are conservatively reread. Throttling honors
`Retry-After` with bounded retries, and incomplete relationship reads fail
instead of producing false zero counts.

For 53,257 SPs with pages of 100 and small expanded relationships, the two SP
passes take **1,066 page requests**, reused across those collectors. Relationship
overflow pages, app reads, sign-in telemetry and Azure queries are additional.
This is a request-count model, not a runtime guarantee; Graph latency and
throttling still determine live duration. Progress reports loaded page counts.
Unavailable hygiene sign-in telemetry is exported as unknown (`null`), not as
evidence that every identity is stale or has never signed in.

Authentication reference:
[Graph context scope](https://learn.microsoft.com/powershell/microsoftgraph/authentication-commands),
[Azure process-only autosave](https://learn.microsoft.com/powershell/module/az.accounts/disable-azcontextautosave),
[Azure context population](https://learn.microsoft.com/powershell/module/az.accounts/connect-azaccount).

## Running individual scripts

```powershell
./scripts/01-tenant-context.ps1
./scripts/02-inventory.ps1
# ...
./scripts/09-html-report.ps1   # uses one latest timestamped snapshot, never a per-file mixture
```

## Offline report generation

Re-render a retained snapshot without Graph, Azure modules, authentication or
network access:

```powershell
./scripts/09-html-report.ps1 -OutputDir ./output -RunDir 20260101-120000 `
    -ReportPath ./output/20260101-120000/report.html
```

`-RunDir` accepts a folder name relative to `-OutputDir` or an absolute path.
Alternatively, pass the run folder itself as `-OutputDir`. Without `-RunDir`,
the renderer uses flat exports in `-OutputDir`, or selects the latest
`yyyyMMdd-HHmmss` child folder as a whole. Ambiguous non-timestamped folders
and duplicate exports for one collector are rejected.

Keep `scripts/report-assets/`, `scripts/Assessment.Controls.psm1` and
`controls/catalog.json` in their repository-relative locations when generating
a report. The resulting **single HTML file** can then be moved or shared alone
and opened through `file://`. It has no external fonts, scripts, styles,
telemetry or runtime requests. JavaScript must be enabled in the browser.

### Report views

Overview, Identities, Findings, Control coverage, Credentials, Federation, Permissions, Hygiene,
Monitoring, Conditional Access, Tenant and Raw data retain the existing
assessment content. Search and pagination cover every embedded row, including
records beyond the previous display limits. **Technical details** opens an
accessible side panel with complete exported fields and copyable IDs.
Escape or Close returns focus to the invoking control.

**Findings** is a compact table of severity, finding, outcome and affected /
eligible counts. **Details** expands the explanation and recommendation;
**Sources and rationale** expands the retained reference links separately.
Click the affected count to open the exact affected-object list directly.
Severity and text filters still search the full finding, including collapsed
recommendations. Returning from an affected identity preserves expanded evidence.

The identity view distinguishes application/client IDs, object/principal IDs
and Azure resource IDs. Related records use those exported keys, not display
names. The inventory has one selectable name per application/client ID.
Selecting a name shows both object panels without redundant open links in the
selector or related inventory tables. Links from other report views still
focus the exact object. The report uses the available page width, with a bounded
name sidebar and flexible detail area. Desktop panels are side by side and mobile
panels stack. Managed-identity resources are linked to their directory
principal, not misrepresented as registrations. Missing local counterparts and
external definitions are explicit, neutral evidence states.

**Loaded** describes a readable file with the required report fields, not
successful or complete collection. Missing, unreadable and partial exports
remain explicit; partial datasets are retained under Raw data but excluded from
findings and summary totals. Missing data is unavailable, not zero. The renderer
does not reconstruct collection failure reasons absent from older exports.
Explicit null hygiene activity totals are accepted as unknown; they do not
discard independent ownership evidence or become zero-use claims.

The default identity category is **Tenant-managed**, with independent object
type, SP subtype, audience, ownership, expired-credential and activity filters.
Microsoft-owned classification uses the two home-tenant IDs documented by
[Microsoft](https://learn.microsoft.com/troubleshoot/entra/entra-id/governance/verify-first-party-apps-sign-in);
names/publishers do not establish origin. Microsoft-owned does not prove
automatic/default provisioning. Missing home-tenant evidence remains unknown.
Category counts describe grouped workloads; overview tiles retain their
separate exported-object counts. Filters select matching workloads and keep
both counterpart panels visible. Each panel groups all exported settings,
including nested values, without ambiguous field-count suffixes in group
headings, and preserves the object's own owners, creation
evidence and activity. Unexported settings are not inferred.

The **API permissions** views have distinct **Configured permissions**,
**Other permissions granted**, and **Grants with unavailable configuration**
sections, globally and for each application. Configured rows retain actual
grant/consent status, including not granted or unknown. External or legacy
missing configuration is not an empty configured list and is never labelled
granted-but-not-configured. Removing a configured request does not itself
revoke an existing grant. Application/Delegated access is explicit. AllPrincipals means
tenant-wide delegated admin consent; Principal means consent for a specific
user, not necessarily granted by that user. No consenting administrator or time
is inferred. Actual Exchange grants remain visible when configured permissions
are empty. IDs and assignment metadata stay in Technical details.
See Microsoft's [configured-permission explanation](https://learn.microsoft.com/entra/identity-platform/quickstart-configure-app-access-web-apis#more-on-api-permissions-and-admin-consent)
and [actual-grant review guidance](https://learn.microsoft.com/entra/identity/enterprise-apps/manage-application-permissions).

Issues remain in the global **Findings** view. Source-backed inline flags link
to their exact finding and show **Fail** or **Review**, with High in red and
Medium in yellow. Unknown/manual evidence stays neutral. Neither multitenancy
nor a granted-but-not-configured permission automatically constitutes a defect.
Outside inventory, credential evidence has explicit **Open app registration**
and **Open enterprise application** actions instead of an ambiguous identity
link. Inventory keeps technical details and finding links, but omits redundant
counterpart navigation.

### Controls, sources and evidence limits

`controls/catalog.json` defines stable workload control IDs and maps the entire
Entra SCuBA baseline at revision
`ee94d60a973b46d3517422f41bbbe6c90a83c09b` to applicable, partial/manual or
out-of-scope entries. This is **not a full Entra SCuBA compliance scanner**.
Human MFA and guest posture are excluded. User-based service accounts require
an authoritative list and manual assessment; names never classify human users
as workloads.

Outcomes are **Pass, Fail, Review, Not assessed, Not applicable**, separate from
severity. Every finding links its source and exact affected records.
Unknown/excluded evidence is not a pass, and no aggregate compliance score is
calculated. Tenant registration/workflow settings and complete default
credential policies have automated predicates. Enabled policy overrides,
creation cutoffs and actor exceptions require manual effective-policy review.
Password/certificate policy limits use the pinned baseline's exclusive
181/366-day settings, not credential inventory as a proxy for prevention.
Consent-policy exceptions/classifications, federation trust semantics,
application identifiers/redirects/locks, managed-identity resource lifecycle,
agent blocking, SOC delivery and response remain explicit manual/partial
controls, with the collected configuration available for review.

[Microsoft recommends at least two application owners where possible](https://learn.microsoft.com/entra/identity/enterprise-apps/overview-assign-app-owners),
not as a universal platform requirement. Ownership grants administrative
power. Local Application SP ownership is assessed separately from app-registration
ownership; managed identities do not get a human-SP-owner recommendation.

Collector 02 now exports additive schema-v2 metadata for owners, configuration,
creation provenance and optional evidence. Successful creation audits are read
in one paged query bounded to the requested last 30 days and correlated by target
object ID. App registration creation and enterprise-app provisioning are
distinct. Actual retained history can be shorter, and absent audit evidence
means **Creator unavailable from retained audit history**, never a guessed owner.

SP activity is fetched once per run through the shared transport and preserves
the five documented overall/client/resource flows. It is beta and global-cloud
only. Observed activity does not necessarily establish successful login; no
record does not mean never used. Activity ages use valid dates against snapshot
time; future/sentinel/missing dates cannot produce inactivity findings.
SP-origin credential expiry is evaluated separately when schema-v2 metadata is
available; SP-origin credential usage remains unassessed.

Optional app-policy, consent-policy, directory-role, risky-SP and Agent ID reads
export per-capability state, source, version, time and error information.
Baseline collection continues when an optional API is denied or unsupported.
For extra Agent ID/risky-SP read scopes, use:

```powershell
./scripts/run-all.ps1 -AssessmentScope Entra -IncludeOptionalWorkloadEvidence
```

This requests `AgentIdentity.Read.All`, `AgentIdentityBlueprint.Read.All` and
`IdentityRiskyServicePrincipal.Read.All`, in addition to baseline read scopes.
Caller-managed authentication must already have them. Agent discovery uses
v1.0 typed collections; delegated nonowners need Agent ID Administrator.
Risk reads require Workload ID Premium and an applicable role such as Security
Reader. Discovery alone does not establish sponsor/owner completeness, agent risk
blocking or lifecycle compliance; these remain explicit manual gaps.
App-management evidence uses beta and Policy.Read.All; delegated roles and
national-cloud support vary by endpoint. Denied/unsupported queries do not become
empty successful evidence.

Offline rendering of older snapshots can correct denominators, origin and
presentation from retained facts. It cannot recover absent delegated grants,
creation audits, policy exceptions or reliable usage history. Raw exported
JSON remains unchanged. Reports include sensitive owner/actor/audit information:
store locally with appropriate access controls; do not commit or upload them
to third-party systems. Secret values and private keys are not collected.

## Output structure

```
output/
└── 20260101-120000/
    ├── 01-tenant-context.json
    ├── 01-tenant-context.csv
    ├── 02-inventory.json
    ├── 02-inventory.csv
    ├── 03-credential-hygiene.json
    ├── ...
    ├── run-summary.json
    └── report.html
```

Outputs include tenant identifiers, app registration display names, service
principal IDs, and other potentially sensitive data — **never commit them**.
The repo's `.gitignore` already excludes `assessment/output/`.

## Findings model

The HTML report classifies findings into four severities:

| Tier | Meaning |
|------|---------|
| **HIGH** | High-impact control observation or privilege review; validate applicability and evidence before remediation. |
| **MED** | Hygiene/governance observation or review. |
| **LOW** | Best-practice deviation; address opportunistically. |
| **INFO** | Informational review, such as intended application audience; not an automatic vulnerability. |

Each finding includes its stable ID, outcome, source, scope/counts,
recommendation and an affected-object drill-down.

## Limitations

- Scripts do not enumerate every Azure subscription unless you have access
  to it — `Reader` on each subscription is required for full RBAC coverage.
- Identity Protection signals (Risky workload identities) require
  Workload Identities Premium; unavailable evidence is not a blanket security failure.
- Conditional Access for workload identities also requires Workload
  Identities Premium.

## Related

- [Root README](../README.md) — repo overview + sample report screenshots.
- [`../kb/02-governance/`](../kb/02-governance/) — policy templates the
  findings map back to.
- [`../kb/03-management/04-monitoring-and-alerts.md`](../kb/03-management/04-monitoring-and-alerts.md)
  — what to wire up after the assessment.

## Offline validation

Collection regression checks mock all SDK calls. They cover tenant isolation,
process contexts, paging, expanded-relationship completeness, retry handling,
cache reuse, collector output, exit codes and a 53,257-SP scale fixture:

```powershell
pwsh -NoProfile -File ./tests/Test-Collection.ps1
pwsh -NoProfile -File ./tests/Test-Controls.ps1
pwsh -NoProfile -File ./tests/Test-EntryPoint.ps1
```

The entry-point suite mocks authentication and browser launching while generating
real reports from synthetic snapshots. These suites do not authenticate, access a
tenant or establish live network timings.

These checks create synthetic data only under the ignored `output/report-tests/`
folder. No tenant connection is used.

```powershell
pwsh -NoProfile -File ./tests/Test-HtmlReport.ps1
```

For browser checks, install the test-only dependency and use installed Google
Chrome (Node.js 18+):

```bash
cd tests
npm ci
npm test
```

The browser suite opens the generated files with networking disabled, including
a copy moved to an otherwise empty folder. It covers navigation, search,
filters, pagination, ID joins, missing data, hostile text and narrow layouts.
Screenshots are saved under `output/report-tests/screenshots/`.
