using './main.bicep'

// ─── Required — fill before deploying ─────────────────────────────────────────
// Pass webhookSecret on the CLI so it is never written to disk:
//   az deployment group create ... --parameters webhookSecret=$secret
//
// To read it from Key Vault instead:
//   param webhookSecret = az.getSecret('<subId>', '<rg>', '<kvName>', 'webhook-secret')

// ─── Optional — change as needed ──────────────────────────────────────────────
param prefix = 'scu-sw'
param location = 'eastus'

// Your own AAD object ID (az ad signed-in-user show --query id -o tsv)
// Grants you App Configuration Data Owner so you can run Add-UserEnvironment.ps1
param adminPrincipalId = ''
