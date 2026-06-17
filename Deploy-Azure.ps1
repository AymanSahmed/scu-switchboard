#Requires -Version 7.0
<#
.SYNOPSIS
    Deploy SCU Switchboard Azure infrastructure (admin / one-time step).
.DESCRIPTION
    Deploys the Logic App, Key Vault, App Configuration store, and Log Analytics
    workspace into a dedicated resource group.  Safe to re-run — all steps are
    idempotent.

    Run this ONCE as the team administrator.  The output shows the Webhook URL,
    Webhook Secret, and App Config Endpoint that each user needs to configure
    their client.  Share those values securely (e.g. via a team KeyVault or
    secure channel).

    Each end-user then runs:
        .\Install-Client.ps1

.PARAMETER InfraResourceGroup
    Resource group for SCU Switchboard infrastructure.  Default: rg-scu-switchboard
.PARAMETER Location
    Azure region.  Default: eastus
.PARAMETER Prefix
    Short prefix used for all resource names.  Default: scu-sw
.PARAMETER OutputFile
    Optional path to write setup info (URL, secret, endpoint) as JSON.
    IMPORTANT: this file contains a secret — protect it appropriately.
#>
[CmdletBinding()]
param(
    [string] $InfraResourceGroup = 'rg-scu-switchboard',
    [string] $Location           = 'eastus',
    [string] $Prefix             = 'scu-sw',
    [string] $OutputFile         = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-Step([string]$msg) { Write-Host "`n▶  $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg)   { Write-Host "   ✔  $msg" -ForegroundColor Green }
function Write-Warn([string]$msg) { Write-Host "   ⚠  $msg" -ForegroundColor Yellow }

# ── 0 · Prerequisites ──────────────────────────────────────────────────────────
Write-Step 'Checking prerequisites'

$null = az account show 2>&1
if ($LASTEXITCODE -ne 0) { throw 'Not logged in to Azure CLI.  Run: az login' }

$sub     = (az account show | ConvertFrom-Json)
$subId   = $sub.id
$ownerId = (az ad signed-in-user show --query id -o tsv)
Write-Ok "Logged in as $($sub.user.name)  (sub: $($sub.name))"

# ── 1 · Resource group ─────────────────────────────────────────────────────────
Write-Step "Ensuring resource group '$InfraResourceGroup'"

az group create --name $InfraResourceGroup --location $Location --output none
Write-Ok $InfraResourceGroup

# ── 2 · Webhook secret ─────────────────────────────────────────────────────────
Write-Step 'Resolving webhook secret'

$kvName   = "$Prefix-kv"
$kvExists = az keyvault show --name $kvName --resource-group $InfraResourceGroup --query name -o tsv 2>$null
if ($kvExists) {
    $kvId = az keyvault show --name $kvName --resource-group $InfraResourceGroup --query id -o tsv 2>$null
    $kvRoleExists = az role assignment list --assignee $ownerId --role 'Key Vault Secrets Officer' `
        --scope $kvId --query '[0].name' -o tsv 2>$null
    if (-not $kvRoleExists) {
        az role assignment create --assignee $ownerId --role 'Key Vault Secrets Officer' `
            --scope $kvId --output none 2>$null
        Write-Warn 'Waiting 30 s for RBAC to propagate…'
        Start-Sleep -Seconds 30
    }
    $secret = az keyvault secret show --vault-name $kvName --name webhook-secret --query value -o tsv 2>$null
}
if (-not $secret) {
    $secret = (New-Guid).Guid + (New-Guid).Guid
    Write-Ok 'New secret generated'
} else {
    Write-Ok 'Reusing existing secret from Key Vault'
}

# ── 3 · Deploy Bicep ───────────────────────────────────────────────────────────
Write-Step 'Deploying Azure infrastructure (Bicep)'

az deployment group create `
    --resource-group $InfraResourceGroup `
    --template-file  "$ScriptRoot/infra/main.bicep" `
    --parameters prefix=$Prefix location=$Location "webhookSecret=$secret" "adminPrincipalId=$ownerId" `
    --query 'properties.outputs' -o json 2>$null | Set-Variable deployOutput

if ($LASTEXITCODE -ne 0) { throw 'Bicep deployment failed. Re-run with 2>&1 to see errors.' }
$outputs = $deployOutput | ConvertFrom-Json

$principalId       = $outputs.logicAppPrincipalId.value
$appConfigEndpoint = $outputs.appConfigEndpoint.value
$logicAppName      = $outputs.logicAppName.value
Write-Ok "Logic App: $logicAppName  |  Principal: $principalId"

# ── 4 · Get webhook URL ────────────────────────────────────────────────────────
Write-Step 'Retrieving webhook URL'

$webhookUrl = az rest --method post `
    --uri "https://management.azure.com/subscriptions/$subId/resourceGroups/$InfraResourceGroup/providers/Microsoft.Logic/workflows/$logicAppName/triggers/HTTP_Webhook/listCallbackUrl?api-version=2016-06-01" `
    --query value -o tsv

Write-Ok 'Webhook URL retrieved'

# ── 5 · Output setup info ──────────────────────────────────────────────────────
$setupInfo = [ordered]@{
    webhookUrl         = $webhookUrl
    webhookSecret      = $secret
    appConfigEndpoint  = $appConfigEndpoint
    logicAppName       = $logicAppName
    logicAppPrincipalId = $principalId
    infraResourceGroup = $InfraResourceGroup
    subscriptionId     = $subId
}

if ($OutputFile) {
    $setupInfo | ConvertTo-Json | Set-Content $OutputFile -Encoding UTF8
    Write-Warn "Setup info written to: $OutputFile  (KEEP THIS FILE SECURE)"
}

Write-Host ''
Write-Host '════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host '  SCU Switchboard Azure infrastructure deployed!' -ForegroundColor Green
Write-Host ''
Write-Host '  Share these values with each client user (via secure channel):' -ForegroundColor White
Write-Host "    Webhook URL    : $webhookUrl" -ForegroundColor Yellow
Write-Host "    Webhook Secret : $secret" -ForegroundColor Yellow
Write-Host "    App Config EP  : $appConfigEndpoint" -ForegroundColor Yellow
Write-Host "    Subscription ID: $subId" -ForegroundColor Yellow
Write-Host ''
Write-Host '  Each user runs from the repo root:' -ForegroundColor White
Write-Host '    .\Install-Client.ps1' -ForegroundColor White
Write-Host ''
Write-Host '  To register a user environment manually:' -ForegroundColor White
Write-Host '    .\scripts\Add-UserEnvironment.ps1 -ConfigEndpoint <ep> -UserUpn <upn> ...' -ForegroundColor White
Write-Host '════════════════════════════════════════════════════════════' -ForegroundColor Cyan
