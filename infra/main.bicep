targetScope = 'resourceGroup'

// ─────────────────────────────────────────────────────────────────────────────
// Parameters
// ─────────────────────────────────────────────────────────────────────────────

@description('Azure region for all resources.')
param location string = resourceGroup().location

@minLength(3)
@maxLength(16)
@description('Short prefix applied to every resource name (lowercase alphanumeric + hyphens).')
param prefix string = 'scu-sw'

@description('Webhook shared secret.  Pass from Key Vault or CI variable — never commit.')
@secure()
param webhookSecret string

@description('AAD object ID of the admin/operator principal; receives App Configuration Data Owner so they can run Add-UserEnvironment.ps1.')
param adminPrincipalId string = ''

// ─────────────────────────────────────────────────────────────────────────────
// Variables
// ─────────────────────────────────────────────────────────────────────────────

// 6-char hash unique per resource group — prevents global name conflicts when
// the same prefix is deployed into multiple resource groups / environments.
var uniqueSuffix = take(uniqueString(resourceGroup().id), 6)

// ─────────────────────────────────────────────────────────────────────────────
// Modules
// ─────────────────────────────────────────────────────────────────────────────

module loganalytics 'modules/loganalytics.bicep' = {
  name: 'loganalytics'
  params: {
    location: location
    workspaceName: '${prefix}-law'
    appInsightsName: '${prefix}-ai'
  }
}

module appconfig 'modules/appconfig.bicep' = {
  name: 'appconfig'
  params: {
    location: location
    configStoreName: '${prefix}-ac-${uniqueSuffix}'
    adminPrincipalId: adminPrincipalId
  }
}

module keyvault 'modules/keyvault.bicep' = {
  name: 'keyvault'
  params: {
    location: location
    keyVaultName: '${prefix}-kv-${uniqueSuffix}'
    webhookSecret: webhookSecret
  }
}

module logicapp 'modules/logicapp.bicep' = {
  name: 'logicapp'
  params: {
    location: location
    logicAppName: '${prefix}-la'
    webhookSecret: webhookSecret
    appConfigEndpoint: appconfig.outputs.endpoint
    logAnalyticsWorkspaceId: loganalytics.outputs.workspaceId
  }
  dependsOn: [keyvault]
}

// ─────────────────────────────────────────────────────────────────────────────
// Role assignments: Logic App managed identity → supporting services
// ─────────────────────────────────────────────────────────────────────────────

// App Configuration Data Reader  (built-in: 516239f1-63e1-4d78-a4de-a74fb236a071)
resource appConfigReaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, '${prefix}-la', '516239f1-63e1-4d78-a4de-a74fb236a071')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '516239f1-63e1-4d78-a4de-a74fb236a071')
    principalId: logicapp.outputs.principalId
    principalType: 'ServicePrincipal'
    description: 'Allows Logic App to read user environment entries from App Configuration'
  }
}

// Key Vault Secrets User  (built-in: 4633458b-17de-408a-b874-0445c86b69e6)
resource kvSecretsUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, '${prefix}-la', '4633458b-17de-408a-b874-0445c86b69e6')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: logicapp.outputs.principalId
    principalType: 'ServicePrincipal'
    description: 'Allows Logic App to read the webhook secret from Key Vault (future use)'
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Outputs
// ─────────────────────────────────────────────────────────────────────────────

@description('Logic App system-assigned managed identity principal ID.  Grant this Contributor on each user capacity resource group.')
output logicAppPrincipalId string = logicapp.outputs.principalId

@description('App Configuration endpoint.  Pass to Add-UserEnvironment.ps1 -ConfigEndpoint.')
output appConfigEndpoint string = appconfig.outputs.endpoint

@description('Logic App resource name.  Use with az logic workflow trigger list-callback-url to get the webhook URL.')
output logicAppName string = logicapp.outputs.logicAppName

@description('Application Insights connection string (optional — for client-side telemetry).')
output appInsightsConnectionString string = loganalytics.outputs.appInsightsConnectionString
