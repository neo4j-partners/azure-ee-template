// Step 1: Deploy Azure Container Registry
// Run this before building the Keycloak image, then deploy main.bicep

param location string = resourceGroup().location

var deploymentUniqueId = uniqueString(resourceGroup().id)
var resourceSuffix = deploymentUniqueId

module registry 'modules/registry.bicep' = {
  name: 'registry-deployment'
  params: {
    location: location
    resourceSuffix: resourceSuffix
  }
}

@description('ACR name for image build: az acr build --registry <name> --image keycloak:latest .')
output acrName string = registry.outputs.registryName
output acrLoginServer string = registry.outputs.registryLoginServer
output acrId string = registry.outputs.registryId
