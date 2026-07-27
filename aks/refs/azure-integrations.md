# Azure integrations after deployment

Use this reference when the customer wants Phase to sync to Azure Key Vault or Azure workloads to authenticate to Phase without long-lived Phase tokens. These are post-deployment product integrations, not prerequisites for installing Phase.

## Contents

- [Current Phase references](#current-phase-references)
- [Azure Key Vault sync](#azure-key-vault-sync)
- [Azure external identities](#azure-external-identities)
- [AKS workload identity boundary](#aks-workload-identity-boundary)
- [Acceptance](#acceptance)

## Current Phase references

- Azure Key Vault sync: https://docs.phase.dev/integrations/platforms/azure-key-vault
- External identities: https://docs.phase.dev/access-control/external-identities
- Azure Key Vault RBAC: https://learn.microsoft.com/azure/key-vault/general/rbac-guide

Re-open the current product docs before configuring roles or credentials.

## Azure Key Vault sync

Current Phase Key Vault sync uses an Azure service principal with tenant ID, client ID, and client secret stored as third-party credentials inside Phase. It supports:

- individual secrets, where Phase controls individual Key Vault entries and can disable entries absent from Phase;
- JSON blob, where Phase overwrites one target Key Vault secret with the selected Phase environment/path.

Warn the user about source-of-truth behavior and import/reconcile existing Key Vault contents before enabling a sync.

Use the narrowest practical Azure scope. For one vault, assign `Key Vault Secrets Officer` at the vault resource, not subscription scope. Have the user create the service principal locally because `az ad sp create-for-rbac` returns a client secret:

```bash
az ad sp create-for-rbac \
  --name <phase-key-vault-sync-name> \
  --role "Key Vault Secrets Officer" \
  --scopes <exact-key-vault-resource-id>
```

The user must take the returned tenant, app ID, and password directly to **Phase → Integrations → Third-party credentials → Azure**. They must not paste the password into chat, a manifest, or Helm values.

Validate only non-secret identity and role assignment from the normal administrator account:

```bash
az ad sp show --id <client-id> --query '{appId:appId,id:id,displayName:displayName}' -o yaml
az role assignment list --assignee <client-id> --scope <exact-key-vault-resource-id> \
  --query '[].{role:roleDefinitionName,scope:scope}' -o table
```

Test with a disposable Phase secret/path and a non-production vault first. Confirm create/update/delete/disable semantics match the chosen sync mode before selecting production data.

## Azure external identities

Phase external identities solve the opposite direction: an Azure Managed Identity or service principal obtains an Azure token and exchanges it for a short-lived Phase access token bound to a Phase service account. They avoid distributing static Phase service-account tokens to AKS/VM workloads.

The user configures in Phase:

- Azure tenant ID;
- resource/audience, defaulting to `https://management.azure.com/` unless intentionally changed;
- allowed service-principal object IDs (`oid` claims), not application/client IDs.

Bind the external identity to a Phase service account with server-side encryption enabled. Scope the Phase service account to only the applications, environments, paths, and operations the workload needs.

For an AKS workload identity, discover the managed identity principal/object ID without handling credentials and register that exact object ID in Phase. Test from the intended pod identity using the current Phase CLI/API flow.

## AKS workload identity boundary

Do not confuse:

- AKS workload identity used by a workload authenticating **to Phase** through Phase external identities;
- a service principal stored **inside Phase** for Phase-to-Key-Vault sync;
- the Tailscale operator's own OAuth/WIF identity.

Current Phase chart `1.0.2` can annotate a ServiceAccount but cannot add the required Azure workload identity pod labels. It therefore cannot fully express Azure Workload Identity for Phase backend/worker integrations using values alone. Do not claim it can; either keep the current supported service-principal flow or treat the missing pod-label support as a chart change.

## Acceptance

- Key Vault role scope is no broader than required.
- No Azure client secret appears in Kubernetes values, Git, logs, or chat.
- Sync source-of-truth behavior is tested on disposable data.
- Azure external identity validates tenant, audience, and the intended object ID.
- Issued Phase token TTL and service-account permissions meet least privilege.
- Credential rotation/revocation and audit ownership are documented.
