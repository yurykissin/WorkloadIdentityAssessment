# Credential Rotation Runbook

Operational runbook for rotating workload identity credentials — client secrets, certificates, and federated credential subject changes. Follow this runbook for all credential rotation events regardless of trigger.

---

## Rotation Triggers

| Trigger                           | Response SLA     | Notes                                                                          |
|-----------------------------------|------------------|--------------------------------------------------------------------------------|
| Scheduled rotation (secret)       | Before expiry    | Rotate at 150 days (30 days before the 180-day policy maximum).                |
| Scheduled rotation (certificate)  | Before expiry    | Rotate at 22 months (2 months before the 24-month maximum).                   |
| Pre-expiry alert — 30 / 14 / 7 days | Acknowledge in 24 hours; rotate before expiry | Escalate if Workload Owner does not acknowledge. |
| Suspected credential compromise   | Revoke within 4 hours; new credential within 24 hours | See Failure Modes & Rollback section.       |
| Owner change                      | Within 30 days of owner departure | All secrets must be rotated; certificates reviewed.         |
| Audit finding / policy breach     | Per audit remediation SLA        | Treat as equivalent to suspected compromise.               |

---

## Rotation Procedure — Client Secret

### Pre-rotation

1. Confirm you have the correct app registration object ID and display name.
2. Confirm the workload(s) consuming this secret are identified.
3. Notify dependent teams of the rotation window (minimum 48 hours' notice for production workloads).
4. Confirm the new secret destination (Key Vault name, secret name).

### Rotation steps (zero-downtime — overlap window)

1. **Add the new secret** — do not delete the old one yet.
   ```powershell
   # Microsoft Graph PowerShell SDK
   $params = @{
       passwordCredential = @{
           displayName = "rotation-$(Get-Date -Format 'yyyyMMdd')"
           endDateTime = (Get-Date).AddDays(180).ToString("o")
       }
   }
   $newCred = Add-MgApplicationPassword -ApplicationId "<app-object-id>" -BodyParameter $params
   $newCred.SecretText   # Capture this value immediately — it is shown only once
   ```

2. **Store the new secret in Key Vault:**
   ```powershell
   Set-AzKeyVaultSecret -VaultName "<vault-name>" `
       -Name "<secret-name>" `
       -SecretValue (ConvertTo-SecureString $newCred.SecretText -AsPlainText -Force)
   ```

3. **Update the workload** to consume the new secret. Options:
   - If using Key Vault reference in App Service / Function: update the `@Microsoft.KeyVault(...)` reference to point to the new version, or use the latest version reference (no version in the URI) to pick up automatically.
   - If using SDK fetch at runtime: the workload fetches from Key Vault on next startup; a restart triggers the new value.

4. **Validate** (see Validation Steps below).

5. **Revoke the old secret** after confirming the new credential is working:
   ```powershell
   # List credentials to find the old key ID
   $app = Get-MgApplication -ApplicationId "<app-object-id>" -Property "passwordCredentials"
   $oldKeyId = $app.PasswordCredentials | Where-Object { $_.DisplayName -ne "rotation-$(Get-Date -Format 'yyyyMMdd')" } | Select-Object -ExpandProperty KeyId
   
   Remove-MgApplicationPassword -ApplicationId "<app-object-id>" -BodyParameter @{ keyId = $oldKeyId }
   ```

6. **Update the inventory** — record rotation date, new expiry, and responsible person.

7. **Close the rotation ticket** with validation evidence attached.

---

## Rotation Procedure — Certificate

### Pre-rotation

1. Identify the certificate: subject, thumbprint, expiry, and storage location (Key Vault or external store).
2. Determine issuer: Key Vault internal CA (auto-renewal possible) or externally issued (manual process).

### Rotation steps

1. **Issue or request a new certificate** with a new key pair. Do not reuse the private key.
   - Key Vault CA: initiate renewal via portal or `az keyvault certificate create`.
   - External CA: submit CSR, obtain signed certificate.

2. **Upload the new certificate's public key to the app registration:**
   ```powershell
   # Read the certificate public key bytes
   $certBytes = [System.IO.File]::ReadAllBytes("<path-to-new-cert.cer>")
   
   $keyCredential = @{
       type = "AsymmetricX509Cert"
       usage = "Verify"
       key = [System.Convert]::ToBase64String($certBytes)
   }
   # Update the application to add the new key credential alongside the old one
   # (Use Graph API PATCH /applications/<id> with keyCredentials array containing both old + new)
   ```

3. **Deploy the new private key** to the workload (Key Vault secret or platform certificate store). Update workload configuration to reference the new certificate thumbprint.

4. **Validate** (see below).

5. **Remove the old certificate** from the app registration after confirming the new one is operational.

6. **Update inventory** with new thumbprint, issuer, and expiry.

---

## Rotation Procedure — Federated Credential Subject Change

Federated credential rotation is required when the external identity source changes — for example, a GitHub repository is renamed, a Kubernetes namespace is changed, or a service account is replaced.

1. **Add a new federated credential** with the updated issuer / subject / audience — do not delete the old one yet.
   ```powershell
   $ficParams = @{
       name = "fic-github-<org>-<repo>-<env>-new"
       issuer = "https://token.actions.githubusercontent.com"
       subject = "repo:<org>/<new-repo>:environment:production"
       audiences = @("api://AzureADTokenExchange")
       description = "Rotation: repo renamed from <old-repo> to <new-repo>"
   }
   New-MgApplicationFederatedIdentityCredential -ApplicationId "<app-object-id>" -BodyParameter $ficParams
   ```

2. **Update the external workload** to use the new subject (e.g., update GitHub Actions workflow reference).

3. **Test a full token exchange** with the new subject. Confirm a valid Entra access token is issued.

4. **Delete the old federated credential:**
   ```powershell
   Remove-MgApplicationFederatedIdentityCredential -ApplicationId "<app-object-id>" `
       -FederatedIdentityCredentialId "<old-fic-id>"
   ```

5. **Update inventory** with the new federated credential name, issuer, and subject.

---

## Validation Steps (Post-Rotation)

Complete all three steps before closing any rotation ticket.

1. **Token acquisition test:** Confirm the workload can acquire a valid access token using the new credential. For secrets: use `az account get-access-token` or a test script. For certificates: sign a client assertion JWT with the new private key and submit to the token endpoint. For federated credentials: trigger the external workflow / pipeline and confirm token exchange succeeds.

2. **Downstream call test:** Confirm the workload can successfully complete its primary operation (e.g., Graph API call succeeds, Key Vault read succeeds, Storage write succeeds) using the new token.

3. **Sign-in log check:** Within 5 minutes of the successful downstream call, verify a successful non-interactive sign-in log entry appears for the service principal in the Entra sign-in logs. Confirm the old credential key ID does not appear in any subsequent sign-in events.

---

## Failure Modes & Rollback

| Failure                                     | Immediate action                                         | Rollback                                                               |
|---------------------------------------------|----------------------------------------------------------|------------------------------------------------------------------------|
| New secret not accepted (wrong value stored) | Re-read from Key Vault; confirm no encoding/whitespace error. | Keep old secret active; re-store correct value and retry.             |
| New certificate rejected (wrong key usage or CN) | Verify the certificate type is `AsymmetricX509Cert` with `Verify` usage. | Revert workload to old certificate thumbprint; re-issue cert.        |
| Federated credential subject mismatch       | Confirm the `sub` claim in the external JWT exactly matches the FIC subject (case-sensitive). | Restore old FIC while debugging; test with a new federation exchange. |
| Workload fails after rotation — old credential already revoked | Re-add a new temporary credential; update workload; rotate again cleanly. | Avoid by using the overlap window; never revoke before validation.   |
| Suspected compromise during rotation window  | Revoke both old and new credentials immediately. Treat as incident. | Issue a net-new credential only after incident containment is confirmed. |

---

## Automation Reference

### Key Vault Auto-Rotation for Certificates

For certificates stored in and managed by Azure Key Vault, configure the certificate's rotation policy:

```
Azure portal > Key Vault > Certificates > <cert-name> > Certificate policy
  > Rotation policy:
    - Rotate at: 80% of lifetime (or N days before expiry)
    - Email contacts on: expiry, near expiry, policy change
```

For app registration certificate credentials, Key Vault can trigger rotation via an Event Grid event + Logic App or Function that uploads the new public key to the app registration automatically.

### Graph PowerShell — Secret Rotation Script Sketch

```powershell
# Requires: Microsoft.Graph.Applications module
# Run: Connect-MgGraph -Scopes "Application.ReadWrite.All"

param(
    [string]$AppObjectId,
    [string]$KeyVaultName,
    [string]$SecretName,
    [int]$LifetimeDays = 180
)

# 1. Add new credential
$newCred = Add-MgApplicationPassword -ApplicationId $AppObjectId -BodyParameter @{
    passwordCredential = @{
        displayName = "auto-rotation-$(Get-Date -Format 'yyyyMMdd')"
        endDateTime = (Get-Date).AddDays($LifetimeDays).ToString("o")
    }
}

# 2. Store in Key Vault
Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $SecretName `
    -SecretValue (ConvertTo-SecureString $newCred.SecretText -AsPlainText -Force)

Write-Host "New secret stored. KeyId: $($newCred.KeyId)"
Write-Host "Validate the workload, then run Remove-MgApplicationPassword to revoke the old credential."
```

---

## References
- https://learn.microsoft.com/en-us/graph/api/application-addpassword
- https://learn.microsoft.com/en-us/azure/key-vault/certificates/tutorial-rotate-certificates
- https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation
