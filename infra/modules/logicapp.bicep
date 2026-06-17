param location string
param logicAppName string

@secure()
param webhookSecret string

param appConfigEndpoint string
param logAnalyticsWorkspaceId string

// Load the workflow definition from the sibling workflows/ folder.
// Path is relative to this .bicep file: infra/modules/ → ../../workflows/scu-control/
var workflowDefinition = loadJsonContent('../../workflows/scu-control/workflow.json')

resource logicApp 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    state: 'Enabled'
    definition: workflowDefinition
    // Pass runtime values for the workflow parameters declared in workflow.json
    parameters: {
      webhookSecret: {
        value: webhookSecret
      }
      appConfigEndpoint: {
        value: appConfigEndpoint
      }
      logAnalyticsWorkspaceId: {
        value: logAnalyticsWorkspaceId
      }
    }
  }
}

output principalId string = logicApp.identity.principalId
output logicAppId string = logicApp.id
output logicAppName string = logicApp.name
