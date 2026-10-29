# Permission risk reference

Verified: 2026-10-24. This describes **implemented behavior**.
Assessment catalog version: 1.3. Permission risk catalog version: 1.2.
The executable source of truth is [catalog.json](catalog.json), together with
the permission evaluators in `../scripts/Assessment.Controls.psm1`.

## Where to see it

In the report, open **Control coverage > Permission risk catalog and sources**.
That opens searchable tables of all 614 reviewed AZTier application permissions,
158 detected-but-untiered entries and 12 Microsoft/toolkit fallback rules.
The dialog includes source revisions, dates, attribution and license. Permission
rows also show their severity, matching rule, reason, capability context or
elevated-risk warning, and relevant source. The complete machine-readable mapping is in
`PermissionRisk.AZTier` in [catalog.json](catalog.json).

The catalog is not an exhaustive risk assessment of every Microsoft Graph
permission. Unlisted is unclassified, never verified safe.

## Evaluation order and current severity mapping

1. For a resolved **Graph application permission**, use its reviewed AZTier
   entry when present. Match the resolved permission name within the API/type
   boundary, checking the permission GUID too when exported as a valid GUID.
   A conflicting GUID/name stays unresolved, not rated from the name alone.
2. If present in AZTier's untiered list, show **Low / Unrated**. This is the
   selected toolkit review priority, not a risk rating published by AZTier.
   Preserve any Microsoft/toolkit capability warning alongside it.
3. Otherwise, including all **delegated** permissions and other APIs, use the
   first matching Microsoft/toolkit rule below. Unmatched or unresolved
   permissions are **Low / Unrated**, not a safety assurance.

| AZTier application-only classification | Report severity | Finding |
| --- | --- | --- |
| Reviewed Tier 0 | High | `WI.PERM.1` |
| Reviewed Tier 1 | Medium | `WI.PERM.5` |
| Reviewed Tier 2 | Info | `WI.PERM.6` |
| Detected, not manually tiered | Low / Unrated | `WI.PERM.4` |

These translations are the assessment policy, not Microsoft's criticality
ratings. A Tier 1 sensitive read such as application `Mail.Read` is Medium,
not Info. A Tier 2 inventory read such as application `Application.Read.All`
is Info, with its separate toolkit reconnaissance context retained.

Derived classifications (the applicable source takes precedence as above):

| Classification | Existing finding severity | Meaning |
| --- | --- | --- |
| `PRIVILEGED` | High / Review, `WI.PERM.1` | Matched sensitive-data, write, administration or impersonation capability. |
| `PRIVILEGED_READ` | High / Review, `WI.PERM.1` | Compatibility classification; current ordinary inventory and security-read rules no longer emit this tier. |
| `RESTRICTED` | Medium / Review, `WI.PERM.5` | Reviewed AZTier Tier 1 or toolkit security/audit read capability. |
| `INFORMATIONAL` | Info / Review, `WI.PERM.6` | Reviewed AZTier Tier 2 or toolkit ordinary inventory read capability. |
| `LOWER_IMPACT` | No permission-risk finding | Small basic delegated-access list. Not a safety or necessity assurance. |
| `UNCLASSIFIED` | Low / Review, `WI.PERM.4` | Untiered or unclassified permission; risk is not yet researched. Low is a chosen priority, not proven low impact. |
| `UNKNOWN` | Low / Review, `WI.PERM.4` | Missing, conflicting or unresolved definition. |

**There is no Critical permission severity in the current implementation.**
The reviewed application ratings distinguish ordinary reads from restricted
capabilities and potential tenant takeover. Delegated inventory reads are Info
under toolkit policy, while security/audit reads are Medium. Sensitive-content
reads and powerful management writes retain High. Delegated alone is not a
severity trigger. AZTier does not provide delegated equivalents; these toolkit
priorities are independent, capability-based decisions.

Only actual `GrantState=Granted` rows enter these findings. Configured requests
can show their capability classification without being counted as existing
grants. Publisher, vendor requirements, official setup instructions and business
justification never suppress an exposure warning.

## Complete Microsoft/toolkit fallback rule list

After the AZTier precedence described above, rules are evaluated in the following
order; the first match wins. Their capability rationale is also retained when
an AZTier entry overrides the report priority. `*` below
describes a family or suffix, not a literal permission name. Names are matched
case-insensitively. Application and Delegated are separate permission types.
Not every family/operation combination necessarily exists in Microsoft Graph.

| Rule | Existing tier / severity | Permission type | API boundary | Origin |
| --- | --- | --- | --- | --- |
| `MS.IR.SENSITIVE` | PRIVILEGED / High | Application, Delegated | Graph and configured legacy equivalents | Microsoft published risky categories |
| `MS.IR.IMPERSONATION` | PRIVILEGED / High | Delegated | Any API | Microsoft published risky categories |
| `MS.IR.HIGH` | PRIVILEGED / High | Application, Delegated | Graph and configured legacy equivalents | Microsoft published highest-risk list |
| `TK.AGENT.WRITE` | PRIVILEGED / High | Application, Delegated | Microsoft Graph | Toolkit capability extension |
| `TK.AGENT.READ` | INFORMATIONAL / Info | Application, Delegated | Microsoft Graph | Toolkit capability extension |
| `TK.GRAPH.WRITE` | PRIVILEGED / High | Application, Delegated | Microsoft Graph | Toolkit capability extension |
| `TK.GRAPH.READ` | INFORMATIONAL / Info | Application, Delegated | Microsoft Graph | Toolkit capability extension |
| `TK.GRAPH.SECURITY.READ` | RESTRICTED / Medium | Application, Delegated | Microsoft Graph | Toolkit capability extension |
| `TK.EXCHANGE` | PRIVILEGED / High | Application | Exchange Online | Toolkit capability extension |
| `MS.IR.APPWRITE` | PRIVILEGED / High | Application | Any API | Toolkit name-based interpretation of Microsoft's app-only write category |
| `MS.IR.LOWER` | LOWER_IMPACT / no finding | Delegated | Microsoft Graph | Microsoft published lowest-impact starting list |
| `MS.IR.OFFLINE` | LOWER_IMPACT / no finding, conditional | Delegated | Microsoft Graph | Microsoft published conditional lowest-impact scope |

### MS.IR.SENSITIVE

- `Mail.*`, **excluding `Mail.ReadBasic*`**.
- `Contacts.*`.
- `MailboxSettings.*`.
- `People.*`.
- `Files.*`.
- `Notes.*`.
- `Directory.AccessAsUser.All`.

This includes sensitive read access, for example delegated `Mail.Read` and
`Files.Read`, not just writes. An admin-consent requirement is not necessary
for a dangerous-data-access warning. Exclusion of `Mail.ReadBasic*` does not
classify it as safe: unless another rule matches, it remains unclassified.

### MS.IR.IMPERSONATION

- `user_impersonation`, exact name, Delegated only.

This is a blanket impersonation review trigger. Actual impact depends on the
API, exposed data, user rights and effective restrictions.

### MS.IR.HIGH

- `Application.ReadWrite.All`.
- `Directory.ReadWrite.All`.
- `Domain.ReadWrite.All*`.
- `EduRoster.ReadWrite.All*`.
- `Group.ReadWrite.All`.
- `Member.Read.Hidden*`.
- `RoleManagement.ReadWrite.Directory`.
- `User.ReadWrite.All*`.
- `User.ManageCreds.All`.

The suffixed families above reproduce the source's trailing wildcard categories.
Other entries are exact matches. This list does not establish that every entry
has an unconditional path to Global Administrator.

### TK.AGENT.WRITE

Matches these Graph permission families:

- `AgentIdentity`.
- `AgentIdentityBlueprint`.
- `AgentIdentityBlueprintPrincipal`.
- `AgentRegistration`.
- `AgentIdUser`.

When the next operation component is one of:

- `ReadWrite`.
- `Create`.
- `DeleteRestore`.
- `EnableDisable`.
- `AddRemoveCreds`.
- `UpdateAuthProperties`.
- `UpdateBranding`.

An additional suffix such as `.All` is permitted. This is a **toolkit rule**,
not a Microsoft-published High/Critical rating of all these Agent ID operations.
Under this fallback rule, the broad grouping assigns the same High severity to
operations whose actual impacts can differ substantially. Application entries
in either AZTier list take the explicit reviewed/untiered priority instead.

### TK.AGENT.READ

- `AgentIdentity.Read.All`.
- `AgentIdentityBlueprint.Read.All`.
- `AgentIdentityBlueprintPrincipal.Read.All`.
- `AgentRegistration.Read.All`.

The fallback rule is Info for ordinary inventory access, including delegated
access. Inventory can aid reconnaissance, but is not an elevated-risk warning
by itself. This is toolkit policy, not a published Microsoft severity or an
AZTier delegated rating.

### TK.GRAPH.WRITE

- `Application.ReadWrite.OwnedBy`.
- `AppRoleAssignment.ReadWrite.All`.
- `Policy.ReadWrite.ConditionalAccess`.
- `Sites.FullControl.All`.
- `GroupMember.ReadWrite.All`.
- `DelegatedPermissionGrant.ReadWrite.All`.
- `Calendars.ReadWrite`.

These are exact matches. Effective impact varies: arbitrary permission grants
and scoped calendar modification are not equivalent capabilities even though
the current rule puts both into High.

### TK.GRAPH.READ

- `Directory.Read.All`.
- `Application.Read.All`.
- `RoleManagement.Read.Directory`.
- `User.Read.All`.
- `Group.Read.All`.

These are exact matches. They are Info under toolkit policy: inventory access
does not itself grant management writes or permission control. Reconnaissance
context and business-need review remain visible without an elevated-risk warning.

### TK.GRAPH.SECURITY.READ

- `AuditLog.Read.All`.
- `IdentityRiskEvent.Read.All`.

These are exact matches, separated from ordinary inventory reads. They are
Medium under toolkit policy because they expose security/audit evidence and
identity-risk information, not because they are delegated or write-capable.
The source describes capabilities, not an official Microsoft Medium rating.
AZTier application entries retain their own reviewed/untiered precedence.

### TK.EXCHANGE

- `Exchange.ManageAsApp`.
- `full_access_as_app`.

Application only, on the Exchange Online resource API. Actual management and
mailbox scope still requires separate validation.

### MS.IR.APPWRITE

Application-only permissions on any API whose names contain a complete
dot-delimited operation component from:

`ReadWrite`, `Write`, `Create`, `Delete`, `DeleteRestore`, `Update`, `Send`,
`Manage`, `ManageAsApp`, `FullControl`, `AddRemoveCreds`, `EnableDisable`.

Microsoft's playbook includes all other app-only write access in its highest-risk
starting point. The implementation recognizes operation names, not proven
effective access. It can group very different writes into High and does not
recognize every opaque/nonstandard write permission. Unmatched capabilities
still require unclassified review.

### MS.IR.LOWER

- `User.Read`.
- `User.ReadBasic.All`.
- `openid`.
- `email`.
- `profile`.

Delegated Graph scopes only. The playbook spells some OpenID scope names
differently; the implementation uses their actual OAuth scope values.

### MS.IR.OFFLINE

- `offline_access`.

Lower impact only when there are known companion granted scopes and **all**
companions are on the lower-impact list, for the same client, Graph API,
consent scope and consent subject. A missing/unknown consent scope or missing
user subject cannot establish this condition.

Otherwise this scope is unclassified and gets Low / Unrated review if granted.

### API identities used by these rules

Display names do not establish which API a permission belongs to.

| API | Application ID |
| --- | --- |
| Microsoft Graph | `00000003-0000-0000-c000-000000000000` |
| Legacy Azure AD Graph | `00000002-0000-0000-c000-000000000000` |
| Exchange Online | `00000002-0000-0ff1-ce00-000000000000` |
| SharePoint Online | `00000003-0000-0ff1-ce00-000000000000` |

The configured legacy-equivalent set is the four IDs above. It is not discovery
of all historical APIs. Unknown API identities are not inferred from names.
The "Any API" rules are explicitly marked exceptions to API-specific matching.

## The seven Agent CLI grants in the screenshot

All seven are Delegated in this example.

| Permission | Current classification | Current finding | Origin |
| --- | --- | --- | --- |
| `AgentIdentityBlueprint.ReadWrite.All` | PRIVILEGED | High / Review | TK.AGENT.WRITE |
| `AgentIdentityBlueprintPrincipal.Create` | PRIVILEGED | High / Review | TK.AGENT.WRITE |
| `AgentRegistration.ReadWrite.All` | PRIVILEGED | High / Review | TK.AGENT.WRITE |
| `AgentIdentity.Read.All` | INFORMATIONAL | Info | TK.AGENT.READ |
| `AgentIdentity.DeleteRestore.All` | PRIVILEGED | High / Review | TK.AGENT.WRITE |
| `Application.Read.All` | INFORMATIONAL | Info | TK.GRAPH.READ |
| `User.Read` | LOWER_IMPACT | No permission-risk finding | MS.IR.LOWER |

The four management grants remain High; the two ordinary inventory reads are
Info, not red. Basic `User.Read` remains lower impact without a permission-risk
finding. None of these delegated ratings is borrowed from AZTier's
application-only catalog.

## Published references and what they actually provide

### Microsoft: risky-permission categories

[App consent grant investigation: Classifying risky permissions](https://learn.microsoft.com/en-us/security/operations/incident-response-playbook-app-consent#classifying-risky-permissions)

The direct official risky-list reference. Covers sensitive delegated families,
application-only equivalents, highest-risk entries and a lowest-impact starting
list. Explicitly non-exhaustive; also warns about sensitive reads such as
`Mail.Read` and `Files.Read`, including apps without malicious intent.
It is not a comprehensive per-permission Critical/High/Medium/Low matrix.

### Microsoft: permission definitions

[Microsoft Graph permissions reference](https://learn.microsoft.com/en-us/graph/permissions-reference)

Defines application versus delegated capabilities and consent requirements.
Use it to establish what a permission allows, not to imply an official numeric
or severity rating for every entry.

### Microsoft: tenant permission classifications

[Configure permission classifications](https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/configure-permission-classifications)

Tenant-configured consent-policy classifications, not a universal Microsoft
risk list. The page documents Low, Medium (preview) and High (preview), and
currently limits classification to delegated permissions not requiring admin
consent. Do not confuse these with this assessment's grant-risk severity.

### SpecterOps: concrete dangerous grant relationships

[BloodHound AZMGGrantAppRoles](https://bloodhound.specterops.io/resources/edges/az-mg-grant-app-roles)

Documents the app-role danger of `AppRoleAssignment.ReadWrite.All` and
`RoleManagement.ReadWrite.Directory`, including potential Global Administrator
escalation. This is an application-permission attack-path reference, not a
uniform ranking of every delegated permission with a similar name.

[Azure Privilege Escalation via Azure API Permissions Abuse](https://specterops.io/blog/2021/12/01/azure-privilege-escalation-via-azure-api-permissions-abuse/)

Explains the underlying permission-grant and directory-role-administration
relationships. Historical terminology/examples need current API verification.

[Directory.ReadWrite.All Is Not As Powerful As You Might Think](https://specterops.io/blog/2024/02/12/directory-readwrite-all-is-not-as-powerful-as-you-might-think/)

An important counterweight to overrating permissions solely by their names.
Shows that `Directory.ReadWrite.All` is not automatically equivalent to Global
Administrator, while retaining configuration-dependent abuse concerns.

[AzureHound Data Collection and Permissions](https://bloodhound.specterops.io/collect-data/azurehound-data-permissions)

Distinguishes inventory collection capabilities such as `Application.Read.All`
from write/permission-grant capabilities. Required use is not a safety exemption,
but collection access should not be mistaken for direct tenant takeover.

### Independent catalog: AZTier

[AZTier](https://aztier.com) and
[Tiering Entra roles and application permissions based on known attack paths](https://www.emiliensocchi.io/tiering-entra-roles-and-application-permissions-based-on-attack-paths/)

[Complete tiered Microsoft Graph application-permission list](https://github.com/emiliensocchi/azure-tiering/blob/main/Microsoft%20Graph%20application%20permissions/tiered-msgraph-app-permissions.json)

The imported classified list has **614 application permissions**: 41 Tier 0,
327 Tier 1 and 246 Tier 2. The latest commit affecting that file at verification
was `d72055f059ac7b2710ad97244fe00208de20a717` (2025-10-30).
The imported [untiered list](https://github.com/emiliensocchi/azure-tiering/blob/7738e071a2087c79626875f890cd4f6476fd848d/Microsoft%20Graph%20application%20permissions/untiered-msgraph-app-permissions.json)
has **158 entries**, all detected additions, and was last updated on
2026-10-23. Both lists were fetched at repository snapshot
`7738e071a2087c79626875f890cd4f6476fd848d`; per-file SHA-256 hashes and immutable
source URLs are recorded in the mapping.

The upstream README explains that daily automated discovery adds new
permissions to the untiered list, followed by manual attack-path research.
Therefore a recent untiered update does **not** establish recent manual risk
assessment of those permissions. Some Agent entries have awaited tiering since
2025-12-13. This is best-effort independent research, not an official Microsoft
severity standard or a guarantee that older entries remain accurate.

- **Tier 0:** risk of a direct or indirect path to Global Administrator.
- **Tier 1:** write capabilities or sensitive reads, without a known path
  to Global Administrator.
- **Tier 2:** ordinary reads with little to no security implications under
  the project's model.

Examples in that published **application-only** catalog:

| Permission | AZTier classification |
| --- | --- |
| `AppRoleAssignment.ReadWrite.All` | Tier 0 |
| `RoleManagement.ReadWrite.Directory` | Tier 0 |
| `Application.ReadWrite.All` | Tier 0 |
| `Application.ReadWrite.OwnedBy` | Tier 0, with owned-target limitations |
| `Directory.ReadWrite.All` | Tier 0, with a configuration-dependent indirect path |
| `Mail.Read` | Tier 1 |
| `Application.Read.All` | Tier 2 |
| `Directory.Read.All` | Tier 2 |
| `User.Read.All` | Tier 2 |

Tier 0 means a potential path, not proof of a path in every tenant. Tier 2 is
not a blanket assurance that exposed inventory has no confidentiality value.
These application-only ratings must not be blindly transferred to delegated
scopes. The reviewed list does not include the Agent ID permissions
`AgentIdentity.Read.All`, `AgentIdentityBlueprint.ReadWrite.All` or
`AgentRegistration.ReadWrite.All`. They appear in the detected-but-untiered
application list and get Low / Unrated under the selected policy, with known
capability warnings preserved. Their delegated versions still use the
Microsoft/toolkit fallback rules, not these application ratings.

The imported projection retains factual permission ID, name, tier or detection
metadata, plus source/author attribution. It omits upstream descriptions and
attack examples. The complete GPL-3.0 source-data license is embedded in the
catalog and available offline in the report's mapping dialog.

### Semperis: corroborating app-only permission abuse

[Exploiting App-Only Graph Permissions in Entra ID](https://www.semperis.com/blog/exploiting-app-only-graph-permissions-in-entra-id/)

Documents an EntraGoat scenario using `AppRoleAssignment.ReadWrite.All` and
`RoleManagement.ReadWrite.Directory` to reach Global Administrator. Useful
corroboration of the capability, not a comprehensive permission-risk catalog.

## Report disclaimer

Permissions and Control coverage display the complete evaluation policy,
application/delegated boundaries, source dates and limitations. Findings keeps
a short visible caveat and the full explanation under **Permission severity
methodology and sources**. Each finding retains its reference links under
**Details > Sources and rationale**, rather than showing them in the summary
table. In particular:

- Severity is review priority, not proof of compromise, unnecessary access,
  effective access or an unconditional path to Global Administrator.
- Low / Unrated is the selected default for an assessment gap. It must never
  be read as evidence that the permission is low risk.
- Info is not proof of safety. Sensitive reads are not automatically Info.
- Permission combinations, user rights, effective resource restrictions,
  business necessity and changes since the source snapshot require review.
- Microsoft, vendor and officially required permissions remain visible.
- No network lookup or automatic source refresh occurs during offline rendering.
- Already generated HTML files do not change automatically; re-render the
  snapshot with the updated renderer to use the new policy and disclaimer.
