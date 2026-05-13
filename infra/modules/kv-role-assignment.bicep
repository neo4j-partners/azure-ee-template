// Grant a user-assigned managed identity the "Key Vault Secrets User" role on a
// pre-existing Key Vault. Deployed at the KV's resource-group scope from main.bicep
// using the `scope: resourceGroup(...)` form, so the per-deployment UAMI created
// in the deployment's own RG can read secrets from a Key Vault that lives in a
// separate resource group (e.g. one reused across many deployments).
//
// Look up the role definition ID with:
//   az role definition list --name "Key Vault Secrets User" \
//     --query '[0].name' -o tsv
param keyVaultName string
param principalId string

// Built-in role: "Key Vault Secrets User"
// https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/security#key-vault-secrets-user
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  name: keyVaultName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  // Use a deterministic GUID so re-deploys don't try to recreate the assignment.
  name: guid(keyVault.id, principalId, keyVaultSecretsUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      keyVaultSecretsUserRoleId
    )
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
