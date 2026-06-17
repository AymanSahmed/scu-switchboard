param location string
param keyVaultName string

@secure()
param webhookSecret string

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true   // use RBAC, not access policies
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enabledForDeployment: false
    enabledForTemplateDeployment: false
    enabledForDiskEncryption: false
    publicNetworkAccess: 'Enabled'
  }
}

resource webhookSecretResource 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'webhook-secret'
  properties: {
    value: webhookSecret
    contentType: 'text/plain'
    attributes: {
      enabled: true
    }
  }
}

output keyVaultName string = keyVault.name
output keyVaultId string = keyVault.id
output webhookSecretUri string = webhookSecretResource.properties.secretUri
