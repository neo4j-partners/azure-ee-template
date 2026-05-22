// Neo4j Enterprise Edition - Azure Deployment Template
// Deploys Neo4j EE on Azure VM Scale Sets with optional load balancer for clusters

@description('Admin username for SSH access to VMs.')
param adminUsername string = 'neo4j'

@secure()
@description('Admin password for Neo4j VMs.')
param adminPassword string

param vmSize string

@description('Neo4j graph database version. Uses latest available from the stable yum repository.')
param graphDatabaseVersion string

param licenseType string = 'Enterprise'

@allowed([
  1
  3
  4
  5
  6
  7
  8
  9
  10
])
param nodeCount int

param diskSize int

param location string = resourceGroup().location

@description('OIDC configuration for M2M authentication (optional). Pass "none" to disable.')
param oidcConfig string = 'none'

@description('Fixed name for the Private Link Service. Stable across redeploys of the same resource group.')
param plsName string = 'pls-neo4j'

@description('Source CIDR for the SSH NSG rule. Defaults to Internet (open). Restrict to a known range for production.')
param sshSourceCidr string = 'Internet'

@description('Assign a public IP to each VMSS instance. Set to false for cluster deployments where LB is the only entry point.')
param publicIpEnabled bool = true

@description('Enable the Neo4j HTTP connector on port 7474. Set to false to serve the browser exclusively over HTTPS (7473).')
param enableHttp bool = true

@description('Install the Bloom plugin from /var/lib/neo4j/products/ and configure its license file path. Requires the license JWT to live in Key Vault at the secret name given by bloomSecretName.')
param installBloom bool = false

@description('Install the Graph Data Science plugin from /var/lib/neo4j/products/ and configure the enterprise license file path.')
param installGds bool = false

@description('Key Vault name holding the Bloom and/or GDS license JWTs. Required when installBloom or installGds is true.')
param keyVaultName string = ''

@description('Resource group of the Key Vault. Used so the per-deployment UAMI can be granted Key Vault Secrets User via cross-RG role assignment.')
param keyVaultResourceGroup string = ''

@description('Key Vault secret name containing the Bloom license JWT.')
param bloomSecretName string = 'bloom-license'

@description('Key Vault secret name containing the GDS Enterprise license JWT.')
param gdsSecretName string = 'gds-license'

var deploymentUniqueId = uniqueString(resourceGroup().id, deployment().name)
var resourceSuffix = deploymentUniqueId
var needsKvAccess = installBloom || installGds

module network 'modules/network.bicep' = {
  name: 'network-deployment'
  params: {
    location: location
    resourceSuffix: resourceSuffix
    sshSourceCidr: sshSourceCidr
  }
}

module identity 'modules/identity.bicep' = {
  name: 'identity-deployment'
  params: {
    location: location
    resourceSuffix: resourceSuffix
  }
}

// Cross-RG role assignment: grant the per-deployment UAMI Key Vault Secrets User
// on the license Key Vault. Only deployed when Bloom or GDS licenses need to
// be fetched. The license KV typically lives in a separate RG (so the same
// vault can be reused across many deployments), so we deploy this module at
// that RG's scope via the `scope: resourceGroup(...)` form.
module keyVaultAccess 'modules/kv-role-assignment.bicep' = if (needsKvAccess) {
  name: 'kv-role-assignment'
  scope: resourceGroup(keyVaultResourceGroup)
  params: {
    keyVaultName: keyVaultName
    principalId: identity.outputs.identityPrincipalId
  }
}

var loadBalancerCondition = (nodeCount >= 3)

module loadbalancer 'modules/loadbalancer.bicep' = {
  name: 'loadbalancer-deployment'
  params: {
    location: location
    resourceSuffix: resourceSuffix
    loadBalancerCondition: loadBalancerCondition
    subnetId: network.outputs.subnetId
    plsSubnetId: network.outputs.plsSubnetId
    plsName: plsName
  }
}

// Cloud-init configuration for standalone and cluster deployments
var cloudInitStandalone = loadTextContent('cloud-init/standalone.yaml')
var cloudInitCluster = loadTextContent('cloud-init/cluster.yaml')

// Shared cloud-init helper scripts — loaded once and base64-injected into both
// YAMLs so the install/wait logic lives in exactly one place. cloud-init's
// write_files block decodes the base64 and writes them to /usr/local/bin.
var installNeo4jScript = loadTextContent('cloud-init/scripts/install-neo4j.sh')
var waitForNeo4jScript = loadTextContent('cloud-init/scripts/wait-for-neo4j.sh')

// Base64 encode the password for safe passing through cloud-init
// Note: This is for avoiding shell escaping issues, NOT for security/encryption
// The adminPassword parameter is already marked @secure() for encryption in deployment metadata
var passwordBase64 = base64(adminPassword)

// Primary cluster cloud-init processing (sequential variable assignments for readability)
var cloudInitTemplate = (nodeCount == 1) ? cloudInitStandalone : cloudInitCluster
var licenseAgreement = (licenseType == 'Evaluation') ? 'eval' : 'yes'
var cloudInitStep1 = replace(cloudInitTemplate, '\${unique_string}', deploymentUniqueId)
var cloudInitStep2 = replace(cloudInitStep1, '\${location}', location)
var cloudInitStep3 = replace(cloudInitStep2, '\${admin_password}', passwordBase64)
var cloudInitStep4 = replace(cloudInitStep3, '\${license_agreement}', licenseAgreement)
var cloudInitStep5 = replace(cloudInitStep4, '\${node_count}', string(nodeCount))
var cloudInitStep6 = replace(cloudInitStep5, '\${oidc_config}', oidcConfig)
var cloudInitStep7 = replace(cloudInitStep6, '\${disable_http_config}', enableHttp ? '' : 'server.http.enabled=false')
var cloudInitStep8 = replace(cloudInitStep7, '\${install_bloom}', installBloom ? 'true' : 'false')
var cloudInitStep9 = replace(cloudInitStep8, '\${install_gds}', installGds ? 'true' : 'false')
var cloudInitStep10 = replace(cloudInitStep9, '\${kv_name}', keyVaultName)
var cloudInitStep11 = replace(cloudInitStep10, '\${bloom_secret_name}', bloomSecretName)
var cloudInitStep12 = replace(cloudInitStep11, '\${gds_secret_name}', gdsSecretName)
var cloudInitStep13 = replace(cloudInitStep12, '\${install_script_b64}', base64(installNeo4jScript))
var cloudInitStep14 = replace(cloudInitStep13, '\${wait_script_b64}', base64(waitForNeo4jScript))
var cloudInitData = cloudInitStep14
var cloudInitBase64 = base64(cloudInitData)

module vmss 'modules/vmss.bicep' = {
  name: 'vmss-deployment'
  params: {
    location: location
    resourceSuffix: resourceSuffix
    adminUsername: adminUsername
    adminPassword: adminPassword
    graphDatabaseVersion: graphDatabaseVersion
    licenseType: licenseType
    nodeCount: nodeCount
    vmSize: vmSize
    diskSize: diskSize
    cloudInitBase64: cloudInitBase64
    identityId: identity.outputs.identityId
    subnetId: network.outputs.subnetId
    loadBalancerBackendAddressPools: loadbalancer.outputs.loadBalancerBackendAddressPools
    loadBalancerCondition: loadBalancerCondition
    publicIpEnabled: publicIpEnabled
  }
}

output vnetId string = network.outputs.vnetId
output subnetId string = network.outputs.subnetId
output nsgId string = network.outputs.nsgId
output identityId string = identity.outputs.identityId
output loadBalancerBackendAddressPools array = loadbalancer.outputs.loadBalancerBackendAddressPools
output lbPrivateIpAddress string = loadBalancerCondition ? loadbalancer.outputs.privateIpAddress : ''
output privateLinkServiceId string = loadbalancer.outputs.privateLinkServiceId
output vmScaleSetsId string = vmss.outputs.vmScaleSetsId
output vmScaleSetsName string = vmss.outputs.vmScaleSetsName

output Neo4jBrowserURL string = publicIpEnabled ? uri('http://vm0.neo4j-${deploymentUniqueId}.${location}.cloudapp.azure.com:7474', '') : ''
output Username string = 'neo4j'

// SSH access information (empty when publicIpEnabled = false — use Bastion or a jumpbox instead)
output sshHostname string = publicIpEnabled ? 'vm0.neo4j-${deploymentUniqueId}.${location}.cloudapp.azure.com' : ''
output sshUsername string = adminUsername
output sshCommand string = publicIpEnabled ? 'ssh ${adminUsername}@vm0.neo4j-${deploymentUniqueId}.${location}.cloudapp.azure.com' : ''
