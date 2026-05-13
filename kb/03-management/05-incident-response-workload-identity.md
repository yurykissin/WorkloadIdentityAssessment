# Incident Response — Workload Identity Compromise

Playbooks for the five most common workload identity compromise scenarios. Each playbook follows the PCEPR structure: Detect → Contain → Eradicate → Recover → Post-incident. Execute steps in order. Do not skip containment to reach recovery.

---

## Playbook 1 — Leaked Client Secret in Source Code

### Detection

- [ ] Secret scanning alert from GitHub Advanced Security / ADO secret scanning / third-party scanner.
- [ ] Developer self-reports a committed secret.
- [ ] SOC alert: sign-in from unexpected IP using the app's service principal (may lag the leak).

### Containment

- [ ] Immediately revoke the leaked client secret from the app registration:
  ```powershell
  # Identify the key ID of the leaked secret from the audit log or manifest
  Remove-MgApplicationPassword -ApplicationId "<app-object-id>" -BodyParameter @{ keyId = "<leaked-key-id>" }
  ```
- [ ] Confirm revocation: attempt a token request using the leaked secret — it must fail with `AADSTS7000222`.
- [ ] If the repository is public: report the exposure to GitHub / ADO security contact immediately. Assume the secret has been scraped by credential-harvesting bots.
- [ ] Block the secret in GitHub's secret scanning UI to prevent re-commit warnings from being ignored.

### Eradication

- [ ] Remove the secret from all locations it was committed: purge from git history (use `git filter-repo` or BFG Repo-Cleaner), not just a new commit that removes the file.
- [ ] Rotate ALL secrets on the same app registration — assume all credentials on the registration may be known if the commit history was exposed.
- [ ] Review sign-in logs for the service principal for the period from the commit date to the revocation timestamp. Look for sign-ins from unexpected IPs, unexpected resource audiences, or unusual times.
- [ ] If suspicious sign-in activity is found, escalate to Playbook 2.

### Recovery

- [ ] Issue a new client secret (or migrate to federated credential / managed identity — use the incident as the trigger to eliminate the secret entirely).
- [ ] Update Key Vault with the new secret.
- [ ] Validate workload function post-rotation (see rotation runbook validation steps).

### Post-Incident Actions

- [ ] File an incident report. Include: commit SHA, exposure window, access log analysis findings, remediation steps.
- [ ] Require secret scanning to be enabled and enforced (push protection) on all repositories in the organisation.
- [ ] Review whether the affected workload can migrate to managed identity or federated credential to eliminate client secrets permanently.
- [ ] Update the exception register if this secret existed as a policy exception.

**Evidence to preserve:** Git commit history (before purge — export diff); Entra sign-in logs for the SP for the exposure window; Key Vault access logs; secret scanning alert details.

---

## Playbook 2 — Compromised Service Principal (Anomalous Sign-In Pattern)

### Detection

- [ ] Sentinel analytic rule: SP sign-in from new IP / country.
- [ ] Identity Protection: risky service principal risk level set to high or critical (requires Workload Identities Premium).
- [ ] SOC alert: sign-ins to resources the SP has never accessed before.
- [ ] Sign-in volume spike (normal: ~100 calls/hour; anomaly: 10,000 calls/hour).

### Containment

- [ ] **Disable the service principal immediately** (do not wait for full investigation):
  ```powershell
  Update-MgServicePrincipal -ServicePrincipalId "<sp-object-id>" -AccountEnabled:$false
  ```
- [ ] If Conditional Access (Workload Identities Premium) is available, apply an immediate block policy scoped to this SP as an additional control.
- [ ] Revoke all active credentials (secrets and certificates) on the app registration:
  ```powershell
  $app = Get-MgApplication -ApplicationId "<app-object-id>"
  $app.PasswordCredentials | ForEach-Object { Remove-MgApplicationPassword -ApplicationId "<app-object-id>" -BodyParameter @{ keyId = $_.KeyId } }
  # Certificate credentials — update keyCredentials array via PATCH to remove all
  ```
- [ ] Preserve the sign-in logs **before** any remediation steps alter the audit trail.
- [ ] Notify Workload Owner, Identity Security, and SOC lead.

### Eradication

- [ ] Review all actions taken by the SP during the anomalous period:
  - Azure Activity Log: what ARM operations were performed?
  - Graph audit log: were any directory objects read, created, or modified?
  - Storage / Key Vault / SQL logs: what data was accessed?
- [ ] Determine the initial access vector: leaked secret? Compromised owner account? Supply chain attack on the IaC pipeline?
- [ ] Remediate the root cause before re-enabling the SP.
- [ ] If the SP had privileged permissions (subscription Owner, Graph Directory.ReadWrite.All, etc.), perform a full Tier-0 compromise review — assume the tenant may be partially compromised.

### Recovery

- [ ] Issue new credentials (or configure federated credential / managed identity).
- [ ] Re-enable the service principal only after root cause is addressed and new credentials are in place.
- [ ] Apply a Conditional Access policy (location-restrict) if not already in place.
- [ ] Increase monitoring frequency for this SP for 30 days post-incident.

### Post-Incident Actions

- [ ] Document the incident timeline, IOCs, and remediation actions.
- [ ] Determine whether GDPR / regulatory notification is required based on data accessed.
- [ ] Conduct a review of all SPs with similar permission profiles — lateral risk assessment.

**Evidence to preserve:** Entra non-interactive sign-in logs (full period); Azure Activity Log; resource-specific access logs (KV, Storage, SQL); Identity Protection risk event details; any attacker-created directory objects.

---

## Playbook 3 — Rogue Admin Consent Granted to Malicious Application

### Detection

- [ ] Sentinel alert: `Consent to application` event for an application not in the known-good approved list.
- [ ] User reports receiving a consent prompt for an unknown application.
- [ ] Identity Protection: suspicious consent grant detection.
- [ ] Periodic review of admin consent grants surfaces an unrecognised application.

### Containment

- [ ] Revoke the admin consent grant immediately:
  ```powershell
  # Find the service principal for the rogue app
  $sp = Get-MgServicePrincipal -Filter "displayName eq '<rogue-app-name>'"
  # Remove app role assignments
  Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id | 
      ForEach-Object { Remove-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -AppRoleAssignmentId $_.Id }
  # Remove OAuth2 permission grants (delegated)
  Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId $sp.Id |
      ForEach-Object { Remove-MgOauth2PermissionGrant -OAuth2PermissionGrantId $_.Id }
  # Disable the SP
  Update-MgServicePrincipal -ServicePrincipalId $sp.Id -AccountEnabled:$false
  ```
- [ ] Determine who granted the consent and whether the consenting admin account is compromised.
- [ ] Identify all users or service principals that may have used the rogue application.

### Eradication

- [ ] Review the Graph audit log for all operations performed by the rogue SP during the exposure window.
- [ ] Check whether the rogue app exfiltrated data: mail, files, user directory objects.
- [ ] Delete the service principal from the tenant (after evidence is preserved):
  ```powershell
  Remove-MgServicePrincipal -ServicePrincipalId $sp.Id
  ```
- [ ] If the rogue app is a multi-tenant app controlled by an attacker, the SP deletion removes it from your tenant only — it may re-appear if a user re-consents.

### Recovery

- [ ] Enable admin consent workflow if not already in place (prevents direct user consent to application permissions).
- [ ] Set "Users can consent to apps" = Disabled.
- [ ] Apply a Conditional Access policy blocking user consent to unknown applications (where platform supports it).

### Post-Incident Actions

- [ ] Report the rogue application to Microsoft (via the report-abuse link on the enterprise app, or via the Microsoft Security Response Center).
- [ ] Notify affected users if their data (mail, files) may have been accessed.
- [ ] Review all enterprise applications in the tenant for similar patterns (recently created, high-privilege permissions, no verified publisher).

**Evidence to preserve:** Admin consent audit log event (who consented, when, which permissions); Graph audit events during exposure window; any user sign-in logs showing token acquisition via the rogue app.

---

## Playbook 4 — Federated Credential Subject Manipulated

**Attack pattern:** An attacker who has write access to an app registration or user-assigned MI adds a new federated credential (or modifies the subject of an existing one) to trust a GitHub repository, Kubernetes namespace, or OIDC issuer they control. They then acquire a valid Entra access token for the victim SP without needing any secret.

### Detection

- [ ] Sentinel alert: federated credential added or modified on an app registration (audit event: `Update application - Federated identity credentials`).
- [ ] Application Administrator or Workload Owner reports an unexpected federated credential configuration.
- [ ] Sign-in log: service principal sign-in from an OIDC issuer URL that is not the expected source (check `homeTenantId` and sign-in details for federated credential sign-ins).

### Containment

- [ ] Remove the attacker-controlled federated credential immediately:
  ```powershell
  $ficId = "<attacker-fic-object-id>"
  Remove-MgApplicationFederatedIdentityCredential -ApplicationId "<app-object-id>" `
      -FederatedIdentityCredentialId $ficId
  ```
- [ ] Review sign-in logs to determine whether the attacker successfully obtained a token via the rogue FIC.
- [ ] If a token was obtained: treat the SP as compromised and execute Playbook 2 containment.
- [ ] Revoke all SP-issued tokens (disable the SP) if sign-in events confirm attacker use.

### Eradication

- [ ] Audit all federated credentials on all app registrations and user-assigned MIs:
  ```powershell
  Get-MgApplication -All | ForEach-Object {
      $fics = Get-MgApplicationFederatedIdentityCredential -ApplicationId $_.Id
      if ($fics) { $fics | Select-Object @{N="App";E={$_.DisplayName}}, Issuer, Subject, Audiences }
  }
  ```
- [ ] Verify every remaining FIC has a documented owner and legitimate subject.
- [ ] Determine the initial access vector for the rogue FIC addition: compromised Application Administrator account? Compromised IaC pipeline? Insider threat?

### Recovery

- [ ] Re-enable the SP after removing the rogue FIC and confirming no token misuse.
- [ ] Add alert rule: any new federated credential on a high-value app registration triggers immediate review.

### Post-Incident Actions

- [ ] Add FIC configuration changes to the monitoring table (if not already alerted).
- [ ] Review Application Administrator role holders — reduce to minimum; ensure PIM-eligible only.
- [ ] Implement IaC-only provisioning for FIC changes (no portal self-service for high-value apps).

**Evidence to preserve:** Audit log event for the rogue FIC addition; sign-in logs for the SP during the exposure window; any OIDC issuer / JWT details if captured in logs.

---

## Playbook 5 — Privileged Graph Permission Abused

**Scenario:** A service principal with a high-privilege Graph permission (e.g., `Directory.ReadWrite.All`, `RoleManagement.ReadWrite.Directory`) is abused — either via a compromised credential or by a legitimate but misconfigured workload — to make unauthorised changes to the directory.

### Detection

- [ ] Sentinel alert: directory object creation, modification, or role assignment by a service principal object ID that does not match the expected admin account.
- [ ] Graph audit log: `Add member to role`, `Update user`, `Add application`, `Grant admin consent` performed by a service principal (not a human admin).
- [ ] Identity Protection: risky service principal with privileged permissions flagged.

### Containment

- [ ] Disable the service principal immediately (see Playbook 2 containment steps).
- [ ] Revoke all credentials.
- [ ] Identify all directory changes made by the SP during the suspected abuse window:
  ```powershell
  # Entra audit log — filter by initiatedBy.app.servicePrincipalId
  # Use Log Analytics or Graph API:
  GET https://graph.microsoft.com/v1.0/auditLogs/directoryAudits?$filter=initiatedBy/app/servicePrincipalId eq '<sp-id>'&$orderby=activityDateTime desc
  ```
- [ ] If role assignments were created by the rogue SP: remove them immediately.
- [ ] If new application registrations or credentials were created by the rogue SP: treat those objects as attacker-controlled and delete them.

### Eradication

- [ ] Revert all unauthorised directory changes. Document each change and its reversal.
- [ ] Determine the full scope of data accessed (user profiles, group memberships, application configurations).
- [ ] Review all other SPs with the same privileged permission — are any similarly at risk?

### Recovery

- [ ] Re-enable the SP only after root cause is resolved and the permission is confirmed as still necessary.
- [ ] Apply Conditional Access policy (location-restrict) to the SP.
- [ ] If the permission is no longer needed at the current broad scope, reduce it (e.g., `Directory.ReadWrite.All` → `User.Read.All` + specific resource scope).
- [ ] Schedule quarterly recertification for this SP.

### Post-Incident Actions

- [ ] Determine if regulatory breach notification is required (directory data may include PII).
- [ ] Consider whether the privileged permission can be replaced with a less-privileged alternative.
- [ ] Validate that the Sentinel detection rule for privileged directory operations by SPs is correctly tuned.

**Evidence to preserve:** Full Graph audit log for the SP (all operations); sign-in logs; any created objects (even after deletion — export before purge); list of directory changes and their reversal record.

---

## References
- https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/manage-application-permissions
- https://learn.microsoft.com/en-us/security/operations/incident-response-playbook-compromised-malicious-app
- https://learn.microsoft.com/en-us/entra/id-protection/howto-identity-protection-investigate-risk
