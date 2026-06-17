#Requires -Version 7.0
<#
.SYNOPSIS
    One-shot deployment of SCU Switchboard.
.DESCRIPTION
    Creates infrastructure, registers the current user, and writes client/config.json.
    Safe to re-run — all steps are idempotent.
.PARAMETER InfraResourceGroup
    Resource group for SCU Switchboard infrastructure.  Default: rg-scu-switchboard
.PARAMETER CapacityResourceGroup
    Resource group where your SCU capacity will live.  Default: prompted if missing.
.PARAMETER CapacityName
    ARM name for the SCU capacity resource.  Default: prompted if missing.
.PARAMETER Location
    Azure region.  Default: eastus
.PARAMETER GeoCode
    Security Copilot geo code (US|EU|UK|ANZ|JP|CA).  Default: US
.PARAMETER DefaultScuCount
    SCU units created by Start.  Default: 1
.PARAMETER MaxScuCount
    Max SCU units (informational).  Default: 4
.PARAMETER LaunchGadget
    Launch the tray gadget after setup.
#>
[CmdletBinding()]
param(
    [string] $InfraResourceGroup   = 'rg-scu-switchboard',
    [string] $CapacityResourceGroup = '',
    [string] $CapacityName          = '',
    [string] $Location              = 'eastus',
    [ValidateSet('US','EU','UK','ANZ','JP','CA')]
    [string] $GeoCode               = 'US',
    [int]    $DefaultScuCount       = 1,
    [int]    $MaxScuCount           = 4,
    [switch] $LaunchGadget
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-Step([string]$msg) { Write-Host "`n▶  $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg)   { Write-Host "   ✔  $msg" -ForegroundColor Green }
function Write-Warn([string]$msg) { Write-Host "   ⚠  $msg" -ForegroundColor Yellow }

# ── 0 · Prerequisites ──────────────────────────────────────────────────────────
Write-Step "Checking prerequisites"

$null = az account show 2>&1
if ($LASTEXITCODE -ne 0) { throw "Not logged in to Azure CLI.  Run: az login" }

$sub    = (az account show | ConvertFrom-Json)
$subId  = $sub.id
$upn    = (az ad signed-in-user show --query userPrincipalName -o tsv)
$ownerId = (az ad signed-in-user show --query id -o tsv)
Write-Ok "Logged in as $upn  (sub: $($sub.name))"

# ── 1 · Prompt for missing capacity details ────────────────────────────────────
if (-not $CapacityResourceGroup) {
    $CapacityResourceGroup = Read-Host "  Capacity resource group (e.g. rg-scu-myenv)"
}
if (-not $CapacityName) {
    $alias = ($upn -split '@')[0].ToLower() -replace '[^a-z0-9\-]',''
    $default = "scu-$alias"
    $input = Read-Host "  Capacity name [default: $default]"
    $CapacityName = if ($input) { $input } else { $default }
}

# ── 2 · Create resource groups ─────────────────────────────────────────────────
Write-Step "Ensuring resource groups exist"

az group create --name $InfraResourceGroup      --location $Location --output none
Write-Ok "$InfraResourceGroup"

$rgExists = az group show --name $CapacityResourceGroup --query name -o tsv 2>$null
if (-not $rgExists) {
    az group create --name $CapacityResourceGroup --location $Location --output none
    Write-Ok "$CapacityResourceGroup  (created)"
} else {
    Write-Ok "$CapacityResourceGroup  (exists)"
}

# ── 3 · Generate or retrieve webhook secret ────────────────────────────────────
Write-Step "Resolving webhook secret"

$kvName  = 'scu-sw-kv'
$kvExists = az keyvault show --name $kvName --resource-group $InfraResourceGroup --query name -o tsv 2>$null
if ($kvExists) {
    # Ensure the admin has Key Vault Secrets Officer so they can read the secret
    $kvId = az keyvault show --name $kvName --resource-group $InfraResourceGroup --query id -o tsv 2>$null
    $kvRoleExists = az role assignment list --assignee $ownerId --role "Key Vault Secrets Officer" --scope $kvId --query "[0].name" -o tsv 2>$null
    if (-not $kvRoleExists) {
        az role assignment create --assignee $ownerId --role "Key Vault Secrets Officer" --scope $kvId --output none 2>$null
        Write-Warn "Waiting 30s for RBAC to propagate…"
        Start-Sleep -Seconds 30
    }
    $secret = az keyvault secret show --vault-name $kvName --name webhook-secret --query value -o tsv 2>$null
}
if (-not $secret) {
    $secret = (New-Guid).Guid + (New-Guid).Guid
    Write-Ok "New secret generated"
} else {
    Write-Ok "Reusing existing secret from Key Vault"
}

# ── 4 · Deploy Bicep ───────────────────────────────────────────────────────────
Write-Step "Deploying Azure infrastructure (Bicep)"

az deployment group create `
    --resource-group $InfraResourceGroup `
    --template-file  "$ScriptRoot/infra/main.bicep" `
    --parameters prefix=scu-sw location=$Location "webhookSecret=$secret" "adminPrincipalId=$ownerId" `
    --query "properties.outputs" -o json 2>$null | Set-Variable deployOutput

if ($LASTEXITCODE -ne 0) { throw "Bicep deployment failed. Re-run with 2>&1 to see errors." }
$outputs = $deployOutput | ConvertFrom-Json

$principalId      = $outputs.logicAppPrincipalId.value
$appConfigEndpoint = $outputs.appConfigEndpoint.value
$logicAppName      = $outputs.logicAppName.value
Write-Ok "Logic App: $logicAppName  |  Principal: $principalId"

# ── 5 · Grant Logic App Contributor on capacity RG ────────────────────────────
Write-Step "Granting Logic App managed identity Contributor on $CapacityResourceGroup"

$scope = "/subscriptions/$subId/resourceGroups/$CapacityResourceGroup"
$existing = az role assignment list --assignee $principalId --role Contributor --scope $scope --query "[0].name" -o tsv 2>$null
if ($existing) {
    Write-Ok "Role already assigned"
} else {
    az role assignment create --assignee $principalId --role Contributor --scope $scope --output none
    Write-Ok "Contributor assigned"
}

# ── 6 · Register user in App Configuration ────────────────────────────────────
Write-Step "Registering user environment in App Configuration"

& "$ScriptRoot/scripts/Add-UserEnvironment.ps1" `
    -ConfigEndpoint   $appConfigEndpoint `
    -UserUpn          $upn `
    -SubscriptionId   $subId `
    -ResourceGroup    $CapacityResourceGroup `
    -CapacityName     $CapacityName `
    -Region           $Location `
    -GeoCode          $GeoCode `
    -DefaultScuCount  $DefaultScuCount `
    -MaxScuCount      $MaxScuCount `
    -OwnerObjectId    $ownerId

Write-Ok "User '$upn' registered"

# ── 7 · Get webhook URL ────────────────────────────────────────────────────────
Write-Step "Retrieving webhook URL"

$webhookUrl = az rest --method post `
    --uri "https://management.azure.com/subscriptions/$subId/resourceGroups/$InfraResourceGroup/providers/Microsoft.Logic/workflows/$logicAppName/triggers/HTTP_Webhook/listCallbackUrl?api-version=2016-06-01" `
    --query value -o tsv

Write-Ok "Webhook URL retrieved"

# ── 8 · Write client config.json ──────────────────────────────────────────────
Write-Step "Writing client/config.json"

$configPath = "$ScriptRoot/client/config.json"
@{
    webhookUrl    = $webhookUrl
    webhookSecret = $secret
    userUpn       = $upn
} | ConvertTo-Json | Set-Content $configPath -Encoding UTF8

Write-Ok "Written to $configPath"

# ── Done ───────────────────────────────────────────────────────────────────────
Write-Host "`n✅  SCU Switchboard is ready!" -ForegroundColor Green
Write-Host "   Logic App : https://portal.azure.com/#resource/subscriptions/$subId/resourceGroups/$InfraResourceGroup/providers/Microsoft.Logic/workflows/$logicAppName"
Write-Host "   App Config: $appConfigEndpoint"
Write-Host ""
Write-Host "   To start the tray gadget:" -ForegroundColor White
Write-Host "   pwsh -WindowStyle Hidden -File `"$ScriptRoot/client/SCU-Switchboard.ps1`"" -ForegroundColor White

if ($LaunchGadget) {
    Write-Step "Launching tray gadget"
    Start-Process pwsh -ArgumentList "-WindowStyle Hidden -File `"$ScriptRoot/client/SCU-Switchboard.ps1`""
    Write-Ok "Gadget launched"
}
