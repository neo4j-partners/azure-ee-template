// Step 2: Deploy Container Apps environment and Keycloak
// Requires the ACR from registry.bicep and the image to already be built

param location string = resourceGroup().location

@secure()
@description('Password for the Keycloak admin console.')
param keycloakAdminPassword string

@description('Name of the existing ACR (from registry.bicep output).')
param acrName string

@description('Resource ID of the existing ACR (from registry.bicep output).')
param acrId string

@description('Tag for the custom Keycloak image in ACR.')
param keycloakImageTag string = '26.5.6'

@description('Keycloak realm name. Must match the realm in realm-export.json.')
param realmName string = 'neo4j'

@description('Unique ID per deployment. Changes force a new Container App revision, ensuring the latest image is pulled.')
param deploymentId string = ''

var deploymentUniqueId = uniqueString(resourceGroup().id)
var resourceSuffix = deploymentUniqueId

// Reference the ACR deployed in step 1
resource acr 'Microsoft.ContainerRegistry/registries@2025-04-01' existing = {
  name: acrName
}

// --- Modules ---

module identity 'modules/identity.bicep' = {
  name: 'identity-deployment'
  params: {
    location: location
    resourceSuffix: resourceSuffix
    registryId: acrId
  }
}

module environment 'modules/environment.bicep' = {
  name: 'environment-deployment'
  params: {
    location: location
    resourceSuffix: resourceSuffix
  }
}

module keycloak 'modules/keycloak.bicep' = {
  name: 'keycloak-deployment'
  params: {
    location: location
    resourceSuffix: resourceSuffix
    environmentId: environment.outputs.environmentId
    defaultDomain: environment.outputs.defaultDomain
    registryLoginServer: acr.properties.loginServer
    identityId: identity.outputs.identityId
    keycloakAdminPassword: keycloakAdminPassword
    keycloakImageTag: keycloakImageTag
    realmName: realmName
    deploymentId: deploymentId
  }
}

// --- Outputs ---
// Everything needed to configure Neo4j OIDC and run the test client

@description('Keycloak public URL.')
output keycloakUrl string = keycloak.outputs.keycloakUrl

@description('Keycloak admin console.')
output adminConsoleUrl string = keycloak.outputs.adminConsoleUrl

@description('OIDC discovery URI for Neo4j well_known_discovery_uri setting.')
output oidcDiscoveryUri string = keycloak.outputs.discoveryUri

@description('Token endpoint for client credentials grant.')
output oidcTokenEndpoint string = keycloak.outputs.tokenEndpoint

@description('Audience value for Neo4j OIDC audience setting.')
output oidcAudience string = 'neo4j-client'

@description('Client ID from the baked-in realm export.')
output oidcClientId string = 'neo4j-client'

@description('Role mapping string for Neo4j group_to_role_mapping setting.')
output oidcRoleMapping string = '"neo4j-admin"=admin;"neo4j-readwrite"=editor;"neo4j-readonly"=reader'

@description('Token type config for Neo4j OIDC config setting. Required for M2M client credentials flow (no ID tokens).')
output oidcTokenTypeConfig string = 'token_type_principal=access_token;token_type_authentication=access_token'

@description('Display name for Neo4j OIDC provider. Set visible=false to hide from Browser login screen.')
output oidcDisplayName string = 'Keycloak M2M'

@description('Test client command to validate token acquisition. Client secret is in .deployment.json.')
output testCommand string = 'cd keycloak-test-client && uv run test_keycloak.py --server-url ${keycloak.outputs.keycloakUrl} --client-secret <from .deployment.json>'
