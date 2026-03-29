// User-assigned managed identity with AcrPull role for Container App image pull

param location string
param resourceSuffix string
param registryId string

var identityName = 'id-keycloak-${resourceSuffix}'

// AcrPull built-in role definition ID
var acrPullRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '7f951dda-4ed3-4680-a7ca-43fe172d538d'
)

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: identityName
  location: location
}

resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registryId, identity.id, 'AcrPull')
  scope: registry
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: acrPullRoleDefinitionId
  }
}

// Reference the existing ACR to scope the role assignment
resource registry 'Microsoft.ContainerRegistry/registries@2025-04-01' existing = {
  name: last(split(registryId, '/'))
}

output identityId string = identity.id
output identityPrincipalId string = identity.properties.principalId
