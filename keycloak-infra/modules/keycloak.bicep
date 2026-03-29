// Keycloak Container App running in dev mode with HTTPS ingress
// Uses managed identity to pull image from ACR (no admin credentials)

param location string
param resourceSuffix string
param environmentId string
param defaultDomain string
param registryLoginServer string
param identityId string

@secure()
@description('Keycloak admin console password.')
param keycloakAdminPassword string

param keycloakImageTag string = '26.5.6'
param realmName string = 'neo4j'

@description('Unique ID per deployment. Changes force a new Container App revision.')
param deploymentId string = ''

var appName = 'keycloak-${resourceSuffix}'
var imageName = '${registryLoginServer}/keycloak:${keycloakImageTag}'

// The FQDN is deterministic: {appName}.{defaultDomain}
var keycloakHostname = 'https://${appName}.${defaultDomain}'

resource keycloak 'Microsoft.App/containerApps@2025-01-01' = {
  name: appName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    environmentId: environmentId
    configuration: {
      secrets: [
        {
          name: 'keycloak-admin-password'
          value: keycloakAdminPassword
        }
      ]
      registries: [
        {
          server: registryLoginServer
          identity: identityId
        }
      ]
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
        allowInsecure: false
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
      activeRevisionsMode: 'Single'
    }
    template: {
      containers: [
        {
          name: 'keycloak'
          image: imageName
          resources: {
            #disable-next-line BCP036
            cpu: json('1.0')
            memory: '2Gi'
          }
          env: [
            {
              name: 'KC_BOOTSTRAP_ADMIN_USERNAME'
              value: 'admin'
            }
            {
              name: 'KC_BOOTSTRAP_ADMIN_PASSWORD'
              secretRef: 'keycloak-admin-password'
            }
            {
              name: 'KC_HOSTNAME'
              value: keycloakHostname
            }
            {
              name: 'KC_PROXY_HEADERS'
              value: 'xforwarded'
            }
            {
              name: 'KC_HTTP_ENABLED'
              value: 'true'
            }
            {
              name: 'KC_HTTP_PORT'
              value: '8080'
            }
            {
              name: 'KC_HEALTH_ENABLED'
              value: 'true'
            }
            {
              name: 'KC_HOSTNAME_STRICT'
              value: 'false'
            }
            {
              name: 'DEPLOYMENT_ID'
              value: deploymentId
            }
          ]
          probes: [
            {
              type: 'Startup'
              httpGet: {
                path: '/health/started'
                port: 9000
              }
              initialDelaySeconds: 10
              periodSeconds: 5
              failureThreshold: 30
              timeoutSeconds: 10
            }
            {
              type: 'Liveness'
              httpGet: {
                path: '/health/live'
                port: 9000
              }
              initialDelaySeconds: 30
              periodSeconds: 10
              failureThreshold: 3
              timeoutSeconds: 10
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/health/ready'
                port: 9000
              }
              initialDelaySeconds: 15
              periodSeconds: 5
              failureThreshold: 6
              timeoutSeconds: 10
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

// Outputs for Neo4j OIDC configuration
output keycloakUrl string = 'https://${keycloak.properties.configuration.ingress.fqdn}'
output adminConsoleUrl string = 'https://${keycloak.properties.configuration.ingress.fqdn}/admin'
output discoveryUri string = 'https://${keycloak.properties.configuration.ingress.fqdn}/realms/${realmName}/.well-known/openid-configuration'
output tokenEndpoint string = 'https://${keycloak.properties.configuration.ingress.fqdn}/realms/${realmName}/protocol/openid-connect/token'
output fqdn string = keycloak.properties.configuration.ingress.fqdn
