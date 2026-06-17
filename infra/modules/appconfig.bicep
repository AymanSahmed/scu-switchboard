param location string
param configStoreName string

@description('AAD object ID of an admin/operator who should get App Configuration Data Owner rights.')
param adminPrincipalId string = ''

// Built-in: App Configuration Data Owner
var appConfigDataOwnerRoleId = '5ae67dd6-50cb-40e7-96ff-dc2bfa4b606b'

resource appConfig 'Microsoft.AppConfiguration/configurationStores@2024-05-01' = {
  name: configStoreName
  location: location
  sku: {
    name: 'standard'
  }
  properties: {
    disableLocalAuth: false
    enablePurgeProtection: false
    softDeleteRetentionInDays: 1
    publicNetworkAccess: 'Enabled'
  }
}

// Grant admin principal Data Owner (needed to run Add-UserEnvironment.ps1)
resource adminRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(adminPrincipalId)) {
  name: guid(appConfig.id, adminPrincipalId, appConfigDataOwnerRoleId)
  scope: appConfig
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', appConfigDataOwnerRoleId)
    principalId: adminPrincipalId
    principalType: 'User'
  }
}

output endpoint string = appConfig.properties.endpoint
output configStoreName string = appConfig.name
output configStoreId string = appConfig.id
