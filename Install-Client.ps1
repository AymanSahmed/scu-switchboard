#Requires -Version 7.0
<#
.SYNOPSIS
    One-step user onboarding: writes config, registers your SCU environment,
    and installs the SCU Switchboard tray gadget.
.DESCRIPTION
    When the connection parameters (WebhookUrl, WebhookSecret, UserUpn) are
    supplied the script writes client/config.json automatically — no manual
    setup wizard needed.

    When the registration parameters (ConfigEndpoint, SubscriptionId,
    CapacityResourceGroup, CapacityName) are also supplied the script calls
    scripts/Add-UserEnvironment.ps1 to register the user's capacity in Azure
    App Configuration before launching the gadget.

    All values are printed at the end of .\Deploy-Azure.ps1 — copy-paste them.

.PARAMETER WebhookUrl
    Logic App webhook URL (from Deploy-Azure.ps1 output).
.PARAMETER WebhookSecret
    Shared webhook secret (from Deploy-Azure.ps1 output).
.PARAMETER UserUpn
    Your UPN, e.g. john@contoso.com.
.PARAMETER ConfigEndpoint
    App Configuration endpoint (from Deploy-Azure.ps1 output).
    When provided together with the capacity params, registers your environment.
.PARAMETER SubscriptionId
    Subscription ID where the SCU capacity lives.
.PARAMETER CapacityResourceGroup
    Resource group of the SCU capacity.
.PARAMETER CapacityName
    ARM resource name for the SCU capacity.
.PARAMETER Region
    Azure region for the capacity.  Default: eastus
.PARAMETER GeoCode
    Security Copilot geo code (US|EU|UK|ANZ|JP|CA).  Default: US
.PARAMETER DefaultScuCount
    SCU units used by 'start'.  Default: 1
.PARAMETER MaxScuCount
    Maximum allowed SCU count.  Default: 4
.PARAMETER AddToStartup
    Create a Windows startup shortcut so the gadget auto-launches on login.
.PARAMETER CreateDesktopShortcut
    Create a desktop shortcut for quick access.
.PARAMETER NoLaunch
    Write config / register env but do NOT launch the gadget now.
#>
[CmdletBinding()]
param(
    # ── Connection (write config.json) ────────────────────────────────────────
    [string] $WebhookUrl    = '',
    [string] $WebhookSecret = '',
    [string] $UserUpn       = '',

    # ── Environment registration (optional) ───────────────────────────────────
    [string] $ConfigEndpoint        = '',
    [string] $SubscriptionId        = '',
    [string] $CapacityResourceGroup = '',
    [string] $CapacityName          = '',
    [string] $Region                = 'eastus',
    [ValidateSet('US','EU','UK','ANZ','JP','CA')]
    [string] $GeoCode               = 'US',
    [int]    $DefaultScuCount       = 1,
    [int]    $MaxScuCount           = 4,

    # ── Gadget options ────────────────────────────────────────────────────────
    [switch] $AddToStartup,
    [switch] $CreateDesktopShortcut,
    [switch] $NoLaunch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot       = Split-Path -Parent $MyInvocation.MyCommand.Path
$GadgetPath       = Join-Path $ScriptRoot 'client\SCU-Switchboard.ps1'
$ConfigPath       = Join-Path $ScriptRoot 'client\config.json'
$AddUserEnvScript = Join-Path $ScriptRoot 'scripts\Add-UserEnvironment.ps1'

if (-not (Test-Path $GadgetPath)) {
    throw "Gadget script not found: $GadgetPath`nMake sure you are running from the repo root."
}

function Write-Step([string]$msg) { Write-Host "`n▶  $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg)   { Write-Host "   ✔  $msg" -ForegroundColor Green }
function Write-Warn([string]$msg) { Write-Host "   ⚠  $msg" -ForegroundColor Yellow }

# ── 1 · Write config.json ─────────────────────────────────────────────────────
if ($WebhookUrl -and $WebhookSecret -and $UserUpn) {
    Write-Step "Writing client configuration"
    [ordered]@{
        webhookUrl    = $WebhookUrl
        webhookSecret = $WebhookSecret
        userUpn       = $UserUpn
    } | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8
    Write-Ok "config.json written"
}

# ── 2 · Register environment in App Configuration ─────────────────────────────
$canRegister = $ConfigEndpoint -and $SubscriptionId -and $CapacityResourceGroup -and $CapacityName
if ($canRegister) {
    Write-Step "Registering environment in App Configuration"

    if (-not (Test-Path $AddUserEnvScript)) {
        throw "Add-UserEnvironment.ps1 not found at: $AddUserEnvScript"
    }

    $upnForReg = if ($UserUpn) { $UserUpn } else {
        az account show --query 'user.name' -o tsv 2>$null
    }
    if (-not $upnForReg) { throw "Could not determine UPN — pass -UserUpn." }

    & $AddUserEnvScript `
        -ConfigEndpoint     $ConfigEndpoint `
        -UserUpn            $upnForReg `
        -SubscriptionId     $SubscriptionId `
        -ResourceGroup      $CapacityResourceGroup `
        -CapacityName       $CapacityName `
        -Region             $Region `
        -GeoCode            $GeoCode `
        -DefaultScuCount    $DefaultScuCount `
        -MaxScuCount        $MaxScuCount
}

# ── 3 · Shortcuts ─────────────────────────────────────────────────────────────
function New-GadgetShortcut([string]$targetFolder, [string]$description) {
    $shortcutPath = Join-Path $targetFolder 'SCU-Switchboard.lnk'
    $wshell       = New-Object -ComObject WScript.Shell
    $sc           = $wshell.CreateShortcut($shortcutPath)
    $sc.TargetPath       = (Get-Command pwsh).Source
    $sc.Arguments        = "-WindowStyle Hidden -File `"$GadgetPath`""
    $sc.WorkingDirectory = Split-Path $GadgetPath
    $sc.Description      = $description
    $sc.Save()
    return $shortcutPath
}

if ($AddToStartup) {
    $path = New-GadgetShortcut `
        ([Environment]::GetFolderPath('Startup')) `
        'SCU Switchboard — Security Copilot capacity control'
    Write-Ok "Added to Windows startup: $path"
}

if ($CreateDesktopShortcut) {
    $path = New-GadgetShortcut `
        ([Environment]::GetFolderPath('Desktop')) `
        'SCU Switchboard — Security Copilot capacity control'
    Write-Ok "Desktop shortcut created: $path"
}

# ── 4 · Launch gadget ─────────────────────────────────────────────────────────
if (-not $NoLaunch) {
    Write-Step "Launching SCU Switchboard"

    if (-not (Test-Path $ConfigPath)) {
        Write-Warn "No config.json found — the setup wizard will appear."
        Write-Warn "Have your Webhook URL, Webhook Secret, and UPN ready."
    }

    Start-Process pwsh -ArgumentList "-WindowStyle Hidden -File `"$GadgetPath`""
    Write-Ok "Gadget launched — look for the shield icon in the system tray."
    Write-Host ''
    Write-Host '   Tip: re-open the setup wizard anytime via tray → right-click → ⚙  Setup…' -ForegroundColor Gray
}
