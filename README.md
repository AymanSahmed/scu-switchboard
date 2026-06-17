# SCU Switchboard

> Azure Logic App webhook + Windows PowerShell tray gadget for **per-user Security Copilot (SCU) capacity control**.

## What it does

| Action | Behaviour |
|--------|-----------|
| **Start** | Creates the user's SCU capacity with `defaultScuCount` units |
| **Scale** | Updates the running capacity to a chosen SCU count |
| **Stop** | Deletes the capacity — billing stops immediately |
| **Status** | Queries the capacity provisioning state (auto-refreshes) |

The floating panel updates live: **Provisioning → Running → Stopping → Stopped**.  
While capacity is running the panel shows an uptime counter and fires an hourly balloon reminder.

## Architecture

```
[Windows Tray Gadget]
        │  POST /webhook  (x-webhook-secret header)
        ▼
[Logic App — HTTP trigger]
        ├─ Validate secret
        ├─ Resolve user alias  ──► Azure App Configuration  (scu:env:<alias>)
        ├─ ARM operation       ──► Microsoft.SecurityCopilot/capacities
        └─ Return JSON result
```

The Logic App uses a **system-assigned managed identity** — end-user machines hold only the webhook URL and a shared secret.

---

## Deployment

There are two roles:

| Role | Script | Run |
|------|--------|-----|
| **Admin** (once per team) | `Deploy-Azure.ps1` | Deploys Logic App, Key Vault, App Config |
| **Each user** | `Install-Client.ps1` | Sets up the tray gadget on their machine |

### Admin — Deploy Azure infrastructure

**Option A — One-click via Azure Portal** (repo must be public):

[![Deploy to Azure](https://aka.ms/deploytoazure)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAymanSahmed%2Fscu-switchboard%2Fmaster%2Finfra%2Fmain.json)
[![Visualize](https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/visualizebutton.svg)](https://portal.azure.com/#view/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAymanSahmed%2Fscu-switchboard%2Fmaster%2Finfra%2Fmain.json)

Portal parameters to fill in:

| Parameter | Notes |
|-----------|-------|
| `prefix` | Short prefix for resource names (default `scu-sw`) |
| `webhookSecret` | Generate a strong random string — keep a copy |
| `adminPrincipalId` | Your Azure AD Object ID (`az ad signed-in-user show --query id -o tsv`) |

**Option B — PowerShell script** (handles RBAC + secret management automatically):

```powershell
.\Deploy-Azure.ps1
```

Optional parameters:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-InfraResourceGroup` | `rg-scu-switchboard` | Resource group for infra |
| `-Location` | `eastus` | Azure region |
| `-Prefix` | `scu-sw` | Prefix for all resource names |
| `-OutputFile` | _(none)_ | Write setup info to a JSON file (keep secure!) |

The script outputs the **Webhook URL**, **Webhook Secret**, and **App Config Endpoint**.  
Share those with each user via a secure channel.

> `Deploy.ps1` (legacy all-in-one) is still available if you want a single script that deploys infra AND registers the current user in one shot.

### User — Install the client

```powershell
.\Install-Client.ps1
```

On first launch a **Setup Wizard** appears automatically:

- Enter the **Webhook URL** and **Webhook Secret** from the admin.
- Enter your **UPN**.
- Optionally tick **Register my environment** to register your SCU capacity details directly from the wizard (requires `az login` and App Configuration Data Owner role).

Optional parameters:

| Parameter | Description |
|-----------|-------------|
| `-AddToStartup` | Create a Windows startup shortcut (auto-launch on login) |
| `-CreateDesktopShortcut` | Create a desktop shortcut |
| `-NoLaunch` | Write shortcuts only, do not launch now |

```powershell
# Full install with startup shortcut:
.\Install-Client.ps1 -AddToStartup -CreateDesktopShortcut
```

### Re-opening the Setup Wizard

Right-click the tray icon → **⚙ Setup…** at any time to update config or register a new environment.

### Manual environment registration (admin or user with az cli)

```powershell
.\scripts\Add-UserEnvironment.ps1 `
  -ConfigEndpoint https://<appconfig-name>.azconfig.io `
  -UserUpn        johndoe@contoso.com `
  -SubscriptionId xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx `
  -ResourceGroup  rg-scu-johndoe-dev `
  -CapacityName   scu-johndoe-dev `
  -Region         eastus `
  -GeoCode        US `
  -DefaultScuCount 1 `
  -MaxScuCount     4
```

---

## Prerequisites

- Azure CLI ≥ 2.60 + Bicep CLI (for `Deploy-Azure.ps1`)
- PowerShell 7+ on the client machine
- Contributor on the resource group(s) where SCU capacities are created (admin grants this)

---

## Project structure

```
Deploy-Azure.ps1            Admin: deploy Azure infrastructure (one-time)
Deploy.ps1                  Admin: all-in-one deploy + register current user (legacy)
Install-Client.ps1          User: install gadget + launch setup wizard

infra/
  main.bicep              Root Bicep template
  main.bicepparam         Parameter defaults
  modules/
    loganalytics.bicep    Log Analytics workspace + App Insights
    appconfig.bicep       Azure App Configuration store
    keyvault.bicep        Key Vault (webhook secret storage)
    logicapp.bicep        Consumption Logic App + managed identity

workflows/
  scu-control/
    workflow.json         Logic App workflow definition

client/
  SCU-Switchboard.ps1     Windows system-tray gadget (PowerShell + WinForms)
  config.json.template    Gadget config template (never commit config.json)

scripts/
  Add-UserEnvironment.ps1 Register a user environment in App Configuration
```

---

## App Configuration schema

Each user environment is stored as a key-value entry:

| Field | Example |
|-------|---------|
| **Key** | `scu:env:<upn-alias>` e.g. `scu:env:johndoe` |
| **Content type** | `application/json` |

**Value (JSON):**

```json
{
  "subscriptionId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "resourceGroup": "rg-scu-johndoe-dev",
  "capacityName": "scu-johndoe-dev",
  "region": "eastus",
  "geoCode": "US",
  "defaultScuCount": 1,
  "maxScuCount": 4,
  "ownerObjectId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
}
```

Valid `geoCode` values: `US`, `EU`, `UK`, `ANZ`, `JP`, `CA`

---

## Notes

- **ARM API version:** The Security Copilot capacity API version (`2024-03-01-preview`) should be validated against your subscription. Check with: `az provider show -n Microsoft.SecurityCopilot --query "resourceTypes[?resourceType=='capacities'].apiVersions"`
- **Secret rotation:** Update the Key Vault secret and redeploy (`az deployment group create ...`) to push the new value into the Logic App parameters.
- **Audit log:** All Logic App runs (including inputs/outputs) are retained for 90 days in the run history. A dedicated Log Analytics table can be added in v2.
