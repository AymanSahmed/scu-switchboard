# SCU Switchboard

> Start, scale, and stop your **Security Copilot (SCU) capacity** from the Windows system tray — no portal, no CLI for daily use.

The floating panel shows live status (**Provisioning → Running → Stopping → Stopped**), uptime, and fires an hourly reminder while capacity is running.

---

## Quick start

### Step 1 — Admin: deploy Azure infrastructure (once per team)

> Requires: Azure CLI, PowerShell 7+, Contributor on the target subscription.

```powershell
# Clone the repo
git clone https://github.com/AymanSahmed/scu-switchboard
cd scu-switchboard

# Log in
az login

# Deploy everything — prompts for capacity resource group and capacity name
.\Deploy.ps1 -CapacityResourceGroup <your-RG> -CapacityName <your-capacity-name>
```

At the end the script prints:

```
✅  SCU Switchboard is ready!
   Webhook URL    : https://prod-xx.eastus.logic.azure.com/...
   Webhook Secret : <secret>
   App Config     : https://scu-sw-ac-xxxxxx.azconfig.io
```

**Share the Webhook URL, Webhook Secret, and App Config Endpoint with each user via a secure channel.**

---

### Step 2 — User: install the tray gadget

> Requires: PowerShell 7+, `az login` (only needed if registering your environment).

Run this **once** on each user machine, replacing the values the admin shared:

```powershell
.\Install-Client.ps1 `
  -WebhookUrl            "https://prod-xx.eastus.logic.azure.com/..." `
  -WebhookSecret         "<secret from admin>" `
  -UserUpn               "you@contoso.com" `
  -ConfigEndpoint        "https://scu-sw-ac-xxxxxx.azconfig.io" `
  -SubscriptionId        "<subscription-id>" `
  -CapacityResourceGroup "<capacity-resource-group>" `
  -CapacityName          "<capacity-name>" `
  -Region                "eastus" `
  -GeoCode               "US" `
  -AddToStartup
```

The script will:
1. Write `client/config.json`
2. Register your SCU environment in App Configuration
3. Create a Windows **Startup shortcut** so the gadget launches automatically
4. Launch the tray gadget — look for the **shield icon** in the system tray

> **Tip:** right-click the tray icon → **⚙ Setup…** to update settings at any time.

---

### Optional parameters for `Install-Client.ps1`

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Region` | `eastus` | Azure region of the capacity |
| `-GeoCode` | `US` | Security Copilot geo (`US` `EU` `UK` `ANZ` `JP` `CA`) |
| `-DefaultScuCount` | `1` | SCU units when you press **Start** |
| `-MaxScuCount` | `4` | Maximum SCU units shown in the Scale slider |
| `-AddToStartup` | off | Add a Windows startup shortcut |
| `-CreateDesktopShortcut` | off | Add a desktop shortcut |
| `-NoLaunch` | off | Write config / shortcuts but don't start the gadget now |

---

## What the tray gadget does

| Button | Action |
|--------|--------|
| **Start** | Creates the SCU capacity with `DefaultScuCount` units |
| **Scale** | Changes the running capacity to a chosen SCU count |
| **Stop** | Deletes the capacity — billing stops immediately |
| **Status** | Refreshes the current provisioning state |

---

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

The Logic App uses a **system-assigned managed identity** — user machines hold only the webhook URL and a shared secret.

---

## Deploy to Azure (admin, portal alternative)

If you prefer the Azure Portal instead of the CLI:

[![Deploy to Azure](https://aka.ms/deploytoazure)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAymanSahmed%2Fscu-switchboard%2Fmaster%2Finfra%2Fmain.json)

After deployment, run `Add-UserEnvironment.ps1` manually for each user (see below).

---

## Register additional users (admin)

```powershell
az login   # must have App Configuration Data Owner on the store

.\scripts\Add-UserEnvironment.ps1 `
  -ConfigEndpoint  "https://scu-sw-ac-xxxxxx.azconfig.io" `
  -UserUpn         "jane@contoso.com" `
  -SubscriptionId  "<sub-id>" `
  -ResourceGroup   "<capacity-RG>" `
  -CapacityName    "<capacity-name>" `
  -Region          "eastus" `
  -GeoCode         "US"
```

---

## Prerequisites

| Tool | Version | Used by |
|------|---------|---------|
| PowerShell | 7+ | All scripts |
| Azure CLI | 2.60+ | Admin deploy + environment registration |
| Bicep CLI | any | Bundled with az CLI |

---

## Project structure

```
Deploy.ps1                  All-in-one: deploy infra + register current user
Deploy-Azure.ps1            Infra-only deploy
Install-Client.ps1          User onboarding: config + registration + gadget

infra/
  main.bicep / main.json    Bicep template (uniquely named resources per RG)
  modules/                  appconfig · keyvault · logicapp · loganalytics

workflows/scu-control/
  workflow.json             Logic App workflow definition

client/
  SCU-Switchboard.ps1       Windows tray gadget (PowerShell + WinForms)
  config.json.template      Gadget config template

scripts/
  Add-UserEnvironment.ps1   Register a user's capacity in App Configuration
```

