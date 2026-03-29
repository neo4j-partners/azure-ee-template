// Azure Container Registry for the custom Keycloak image

param location string
param resourceSuffix string

var registryName = replace('acrkeycloak${resourceSuffix}', '-', '')

resource registry 'Microsoft.ContainerRegistry/registries@2025-04-01' = {
  name: registryName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
  }
}

output registryName string = registry.name
output registryLoginServer string = registry.properties.loginServer
output registryId string = registry.id
