#Requires -Version 7.0
<#
.SYNOPSIS
    Install SCU Switchboard client on this machine.
.DESCRIPTION
    Launches the floating tray gadget.  On first run (or if config.json is
    missing), a setup wizard appears where you enter the Webhook URL, Webhook
    Secret, and your UPN.  Optionally you can register your Security Copilot
    environment in App Configuration directly from the wizard (requires az cli
    and App Configuration Data Owner role).

    The admin who deployed the Azure infrastructure (Deploy-Azure.ps1) will
    provide the Webhook URL, Webhook Secret, and App Config Endpoint values.

.PARAMETER AddToStartup
    Create a Windows startup shortcut so the gadget launches automatically
    when you log in.
.PARAMETER CreateDesktopShortcut
    Create a desktop shortcut for quick access.
.PARAMETER NoLaunch
    Write shortcuts but do not launch the gadget now.
#>
[CmdletBinding()]
param(
    [switch] $AddToStartup,
    [switch] $CreateDesktopShortcut,
    [switch] $NoLaunch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$GadgetPath  = Join-Path $ScriptRoot 'client\SCU-Switchboard.ps1'

if (-not (Test-Path $GadgetPath)) {
    throw "Gadget script not found: $GadgetPath`nMake sure you are running from the repo root."
}

# ── Shortcuts ──────────────────────────────────────────────────────────────────
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
    Write-Host "   ✔  Added to Windows startup: $path" -ForegroundColor Green
}

if ($CreateDesktopShortcut) {
    $path = New-GadgetShortcut `
        ([Environment]::GetFolderPath('Desktop')) `
        'SCU Switchboard — Security Copilot capacity control'
    Write-Host "   ✔  Desktop shortcut created: $path" -ForegroundColor Green
}

# ── Launch ─────────────────────────────────────────────────────────────────────
if (-not $NoLaunch) {
    Write-Host "`n▶  Launching SCU Switchboard…" -ForegroundColor Cyan

    $configPath = Join-Path $ScriptRoot 'client\config.json'
    if (-not (Test-Path $configPath)) {
        Write-Host '   ℹ  No config.json found — the setup wizard will appear.' -ForegroundColor Yellow
        Write-Host '      Have your Webhook URL, Webhook Secret, and UPN ready.' -ForegroundColor Yellow
    }

    Start-Process pwsh -ArgumentList "-WindowStyle Hidden -File `"$GadgetPath`""
    Write-Host '   ✔  Gadget launched — look for the shield icon in the system tray.' -ForegroundColor Green
    Write-Host ''
    Write-Host '   Tip: re-open the setup wizard anytime via tray icon → right-click → ⚙  Setup…' -ForegroundColor Gray
}
