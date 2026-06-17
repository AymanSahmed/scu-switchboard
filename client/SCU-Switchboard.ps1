#Requires -Version 7.0
<#
.SYNOPSIS
    SCU Switchboard — System-tray + floating panel for Security Copilot capacity control.
.DESCRIPTION
    Floating panel shows current status, uptime, and Start/Stop/Scale buttons.
    Hourly balloon reminder fires while capacity is running.
    All operations are delegated to a Logic App webhook.
.NOTES
    Requires config.json in the same directory.  See config.json.template.
    Run with:  pwsh -WindowStyle Hidden -File SCU-Switchboard.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptDir 'config.json'

# ─────────────────────────────────────────────────────────────────────────────
# Setup Wizard  (shown on first launch, or re-opened via tray → Setup…)
# ─────────────────────────────────────────────────────────────────────────────

function Show-SetupWizard {
    <#  Returns $true when config.json was written successfully, $false if cancelled.  #>
    $COL_BG    = [System.Drawing.Color]::FromArgb(22, 22, 36)
    $COL_FG    = [System.Drawing.Color]::FromArgb(220, 220, 230)
    $COL_SUB   = [System.Drawing.Color]::FromArgb(140, 140, 160)
    $COL_INPUT = [System.Drawing.Color]::FromArgb(42, 42, 62)
    $COL_BLUE  = [System.Drawing.Color]::FromArgb(100, 140, 240)
    $COL_BTN   = [System.Drawing.Color]::FromArgb(50, 80, 150)
    $FONT_UI   = [System.Drawing.Font]::new('Segoe UI', 9)
    $FONT_SM   = [System.Drawing.Font]::new('Segoe UI', 8)
    $FONT_BOLD = [System.Drawing.Font]::new('Segoe UI Semibold', 9)

    # ── Auto-detect from az cli ───────────────────────────────────────────────
    $detectedUpn   = ''
    $detectedSubId = ''
    $azAvailable   = $null -ne (Get-Command az -ErrorAction SilentlyContinue)
    if ($azAvailable) {
        try {
            $acct = az account show 2>$null | ConvertFrom-Json
            if ($acct) { $detectedUpn = $acct.user.name; $detectedSubId = $acct.id }
        } catch {}
    }

    # ── Pre-fill from existing config ─────────────────────────────────────────
    $exUrl = ''; $exSecret = ''
    $exUpn = if ($detectedUpn) { $detectedUpn } else { '' }
    if (Test-Path $ConfigPath) {
        try {
            $ex = Get-Content $ConfigPath -Raw | ConvertFrom-Json
            if ($ex.webhookUrl)    { $exUrl    = $ex.webhookUrl    }
            if ($ex.webhookSecret) { $exSecret = $ex.webhookSecret }
            if ($ex.userUpn)       { $exUpn    = $ex.userUpn       }
        } catch {}
    }

    # ── Form ──────────────────────────────────────────────────────────────────
    $wz = [System.Windows.Forms.Form]@{
        Text            = 'SCU Switchboard — Setup'
        Size            = [System.Drawing.Size]::new(500, 570)
        FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        MaximizeBox     = $false
        MinimizeBox     = $false
        StartPosition   = [System.Windows.Forms.FormStartPosition]::CenterScreen
        BackColor       = $COL_BG
        ForeColor       = $COL_FG
        Font            = $FONT_UI
    }

    # Button bar (docked bottom — added to form first so it claims the bottom strip)
    $btnBar = [System.Windows.Forms.Panel]@{
        Dock      = [System.Windows.Forms.DockStyle]::Bottom
        Height    = 52
        BackColor = [System.Drawing.Color]::FromArgb(18, 18, 30)
    }

    $btnSave = [System.Windows.Forms.Button]@{
        Text      = 'Save && Launch'
        Location  = [System.Drawing.Point]::new(256, 10)
        Size      = [System.Drawing.Size]::new(124, 32)
        BackColor = $COL_BTN
        ForeColor = [System.Drawing.Color]::White
        FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        Font      = $FONT_UI
    }
    $btnSave.FlatAppearance.BorderSize = 0

    $btnCancel = [System.Windows.Forms.Button]@{
        Text         = 'Cancel'
        Location     = [System.Drawing.Point]::new(388, 10)
        Size         = [System.Drawing.Size]::new(80, 32)
        BackColor    = [System.Drawing.Color]::FromArgb(50, 50, 70)
        ForeColor    = $COL_FG
        FlatStyle    = [System.Windows.Forms.FlatStyle]::Flat
        DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        Font         = $FONT_UI
    }
    $btnCancel.FlatAppearance.BorderSize = 0
    $wz.CancelButton = $btnCancel
    $btnBar.Controls.AddRange(@($btnSave, $btnCancel))

    # Scroll panel (fills remaining space)
    $scroll = [System.Windows.Forms.Panel]@{
        Dock       = [System.Windows.Forms.DockStyle]::Fill
        AutoScroll = $true
        BackColor  = $COL_BG
    }

    $y = 16

    # Helper: make label
    $mkLbl = {
        param([string]$t, [int]$top, [bool]$section)
        [System.Windows.Forms.Label]@{
            Text      = $t
            Location  = [System.Drawing.Point]::new(16, $top)
            Size      = [System.Drawing.Size]::new(452, 18)
            ForeColor = if ($section) { $COL_BLUE } else { $COL_SUB }
            Font      = if ($section) { $FONT_BOLD } else { $FONT_SM }
        }
    }

    # Helper: make textbox
    $mkTxt = {
        param([string]$val, [int]$top, [bool]$pwd)
        $tb = [System.Windows.Forms.TextBox]@{
            Text        = $val
            Location    = [System.Drawing.Point]::new(16, $top)
            Size        = [System.Drawing.Size]::new(452, 26)
            BackColor   = $COL_INPUT
            ForeColor   = $COL_FG
            BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
            Font        = $FONT_UI
        }
        if ($pwd) { $tb.PasswordChar = [char]0x25CF }
        $tb
    }

    # ── CONNECTION ─────────────────────────────────────────────────────────────
    $scroll.Controls.Add((& $mkLbl 'CONNECTION' $y $true))                                    ; $y += 26
    $scroll.Controls.Add((& $mkLbl 'Webhook URL  (from Deploy-Azure output)' $y $false))     ; $y += 20
    $tbUrl = & $mkTxt $exUrl $y $false
    $scroll.Controls.Add($tbUrl)                                                               ; $y += 34
    $scroll.Controls.Add((& $mkLbl 'Webhook Secret' $y $false))                              ; $y += 20
    $tbSecret = & $mkTxt $exSecret $y $true
    $scroll.Controls.Add($tbSecret)                                                            ; $y += 34
    $scroll.Controls.Add((& $mkLbl 'Your UPN  (e.g. you@company.com)' $y $false))            ; $y += 20
    $tbUpn = & $mkTxt $exUpn $y $false
    $scroll.Controls.Add($tbUpn)                                                               ; $y += 42

    # ── ENVIRONMENT REGISTRATION ───────────────────────────────────────────────
    $scroll.Controls.Add((& $mkLbl 'ENVIRONMENT REGISTRATION' $y $true))                     ; $y += 26
    $scroll.Controls.Add((& $mkLbl '(requires az login + App Configuration Data Owner role)' $y $false)) ; $y += 22

    $chkReg = [System.Windows.Forms.CheckBox]@{
        Text     = 'Register / update my environment in App Configuration'
        Location = [System.Drawing.Point]::new(16, $y)
        Size     = [System.Drawing.Size]::new(452, 24)
        ForeColor = $COL_FG
        Font     = $FONT_UI
        Checked  = $azAvailable
        Enabled  = $azAvailable
    }
    $scroll.Controls.Add($chkReg)                                                              ; $y += 30

    if (-not $azAvailable) {
        $scroll.Controls.Add([System.Windows.Forms.Label]@{
            Text      = 'ⓘ  Install Azure CLI (az) to enable environment registration'
            Location  = [System.Drawing.Point]::new(16, $y)
            Size      = [System.Drawing.Size]::new(452, 18)
            ForeColor = [System.Drawing.Color]::FromArgb(180, 140, 60)
            Font      = $FONT_SM
        })                                                                                     ; $y += 24
    }

    # Registration fields sub-panel (enable/disable as a group)
    $regPanel = [System.Windows.Forms.Panel]@{
        Location  = [System.Drawing.Point]::new(16, $y)
        Size      = [System.Drawing.Size]::new(452, 10)   # height set after populating
        BackColor = $COL_BG
        Enabled   = $chkReg.Checked
    }
    $ry = 0

    $mkRegLbl = {
        param([string]$t, [int]$top)
        [System.Windows.Forms.Label]@{
            Text = $t; Location = [System.Drawing.Point]::new(0, $top)
            Size = [System.Drawing.Size]::new(452, 18); ForeColor = $COL_SUB; Font = $FONT_SM
        }
    }
    $mkRegTxt = {
        param([string]$val, [int]$top, [int]$w)
        [System.Windows.Forms.TextBox]@{
            Text = $val; Location = [System.Drawing.Point]::new(0, $top)
            Size = [System.Drawing.Size]::new($w, 26); BackColor = $COL_INPUT
            ForeColor = $COL_FG; BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle; Font = $FONT_UI
        }
    }

    $regPanel.Controls.Add((& $mkRegLbl 'App Configuration Endpoint' $ry))                   ; $ry += 20
    $tbEndpoint = & $mkRegTxt '' $ry 452
    $regPanel.Controls.Add($tbEndpoint)                                                        ; $ry += 34

    $regPanel.Controls.Add((& $mkRegLbl 'Subscription ID' $ry))                              ; $ry += 20
    $tbSubId = & $mkRegTxt $detectedSubId $ry 452
    $regPanel.Controls.Add($tbSubId)                                                           ; $ry += 34

    $regPanel.Controls.Add((& $mkRegLbl 'Resource Group  (where SCU capacity lives)' $ry))  ; $ry += 20
    $tbRg = & $mkRegTxt '' $ry 452
    $regPanel.Controls.Add($tbRg)                                                              ; $ry += 34

    $regPanel.Controls.Add((& $mkRegLbl 'Capacity Name  (ARM resource name)' $ry))           ; $ry += 20
    $tbCapName = & $mkRegTxt '' $ry 452
    $regPanel.Controls.Add($tbCapName)                                                         ; $ry += 34

    # Region + Geo side by side
    $regPanel.Controls.Add([System.Windows.Forms.Label]@{
        Text = 'Region'; Location = [System.Drawing.Point]::new(0, $ry)
        Size = [System.Drawing.Size]::new(215, 18); ForeColor = $COL_SUB; Font = $FONT_SM
    })
    $regPanel.Controls.Add([System.Windows.Forms.Label]@{
        Text = 'Geo Code'; Location = [System.Drawing.Point]::new(240, $ry)
        Size = [System.Drawing.Size]::new(120, 18); ForeColor = $COL_SUB; Font = $FONT_SM
    })
    $ry += 20
    $cbRegion = [System.Windows.Forms.ComboBox]@{
        Location = [System.Drawing.Point]::new(0, $ry); Size = [System.Drawing.Size]::new(215, 26)
        DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
        BackColor = $COL_INPUT; ForeColor = $COL_FG; Font = $FONT_UI
    }
    @('eastus','westus2','westeurope','uksouth','australiaeast','japaneast','canadacentral') |
        ForEach-Object { $cbRegion.Items.Add($_) | Out-Null }
    $cbRegion.Text = 'eastus'
    $cbGeo = [System.Windows.Forms.ComboBox]@{
        Location = [System.Drawing.Point]::new(240, $ry); Size = [System.Drawing.Size]::new(120, 26)
        DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
        BackColor = $COL_INPUT; ForeColor = $COL_FG; Font = $FONT_UI
    }
    @('US','EU','UK','ANZ','JP','CA') | ForEach-Object { $cbGeo.Items.Add($_) | Out-Null }
    $cbGeo.SelectedIndex = 0
    $regPanel.Controls.Add($cbRegion); $regPanel.Controls.Add($cbGeo)                         ; $ry += 34

    # Default SCUs + Max SCUs side by side
    $regPanel.Controls.Add([System.Windows.Forms.Label]@{
        Text = 'Default SCUs'; Location = [System.Drawing.Point]::new(0, $ry)
        Size = [System.Drawing.Size]::new(120, 18); ForeColor = $COL_SUB; Font = $FONT_SM
    })
    $regPanel.Controls.Add([System.Windows.Forms.Label]@{
        Text = 'Max SCUs'; Location = [System.Drawing.Point]::new(150, $ry)
        Size = [System.Drawing.Size]::new(120, 18); ForeColor = $COL_SUB; Font = $FONT_SM
    })
    $ry += 20
    $nudDef = [System.Windows.Forms.NumericUpDown]@{
        Minimum = 1; Maximum = 100; Value = 1
        Location = [System.Drawing.Point]::new(0, $ry); Size = [System.Drawing.Size]::new(110, 26)
        BackColor = $COL_INPUT; ForeColor = $COL_FG; Font = $FONT_UI
    }
    $nudMax = [System.Windows.Forms.NumericUpDown]@{
        Minimum = 1; Maximum = 100; Value = 4
        Location = [System.Drawing.Point]::new(150, $ry); Size = [System.Drawing.Size]::new(110, 26)
        BackColor = $COL_INPUT; ForeColor = $COL_FG; Font = $FONT_UI
    }
    $regPanel.Controls.Add($nudDef); $regPanel.Controls.Add($nudMax)                          ; $ry += 32

    $regPanel.Size = [System.Drawing.Size]::new(452, $ry)
    $scroll.Controls.Add($regPanel)                                                            ; $y += $ry + 16

    # Toggle registration fields with checkbox
    $chkReg.Add_CheckedChanged({ $regPanel.Enabled = $chkReg.Checked }.GetNewClosure())

    # ── Save handler — validates before closing ────────────────────────────────
    $btnSave.Add_Click({
        $url = $tbUrl.Text.Trim()
        $sec = $tbSecret.Text.Trim()
        $upn = $tbUpn.Text.Trim()

        if (-not $url -or -not $sec -or -not $upn) {
            [System.Windows.Forms.MessageBox]::Show(
                'Webhook URL, Webhook Secret, and User UPN are required.',
                'SCU Switchboard',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        if (-not $url.StartsWith('https://', [System.StringComparison]::OrdinalIgnoreCase)) {
            [System.Windows.Forms.MessageBox]::Show(
                'Webhook URL must use HTTPS.',
                'SCU Switchboard',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        # Write config.json
        @{ webhookUrl = $url; webhookSecret = $sec; userUpn = $upn } |
            ConvertTo-Json | Set-Content $ConfigPath -Encoding UTF8

        # Register environment in App Configuration (optional)
        if ($chkReg.Checked) {
            $ep      = $tbEndpoint.Text.Trim()
            $subId   = $tbSubId.Text.Trim()
            $rg      = $tbRg.Text.Trim()
            $capName = $tbCapName.Text.Trim()
            $region  = $cbRegion.Text.Trim()
            $geo     = if ($cbGeo.SelectedItem) { $cbGeo.SelectedItem.ToString() } else { 'US' }

            if (-not $ep -or -not $subId -or -not $rg -or -not $capName -or -not $region) {
                [System.Windows.Forms.MessageBox]::Show(
                    'All Environment Registration fields are required when the checkbox is ticked.',
                    'SCU Switchboard',
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                return
            }

            $addEnvScript = Join-Path (Split-Path $ScriptDir -Parent) 'scripts\Add-UserEnvironment.ps1'
            if (Test-Path $addEnvScript) {
                try {
                    $wz.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
                    & $addEnvScript `
                        -ConfigEndpoint  $ep      `
                        -UserUpn         $upn     `
                        -SubscriptionId  $subId   `
                        -ResourceGroup   $rg      `
                        -CapacityName    $capName `
                        -Region          $region  `
                        -GeoCode         $geo     `
                        -DefaultScuCount ([int]$nudDef.Value) `
                        -MaxScuCount     ([int]$nudMax.Value)
                    $wz.Cursor = [System.Windows.Forms.Cursors]::Default
                } catch {
                    $wz.Cursor = [System.Windows.Forms.Cursors]::Default
                    [System.Windows.Forms.MessageBox]::Show(
                        "Environment registration failed:`n$_`n`nConfig was saved — re-open Setup to retry.",
                        'SCU Switchboard',
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                }
            } else {
                [System.Windows.Forms.MessageBox]::Show(
                    "scripts\Add-UserEnvironment.ps1 not found.`nConfig saved — run it manually to register.",
                    'SCU Switchboard',
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Info) | Out-Null
            }
        }

        $wz.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $wz.Close()
    }.GetNewClosure())

    # Add button bar first (Bottom dock), then scroll panel (Fill)
    $wz.Controls.Add($btnBar)
    $wz.Controls.Add($scroll)

    return ($wz.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK)
}

# ── Config validation helper ───────────────────────────────────────────────────
function Test-ConfigValid {
    if (-not (Test-Path $ConfigPath)) { return $false }
    try {
        $c = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        foreach ($f in @('webhookUrl', 'webhookSecret', 'userUpn')) {
            if ([string]::IsNullOrWhiteSpace($c.$f)) { return $false }
        }
        return $c.webhookUrl.StartsWith('https://', [System.StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

# ── Load config — show wizard if missing or incomplete ─────────────────────────
while (-not (Test-ConfigValid)) {
    if (-not (Show-SetupWizard)) { exit 0 }
}
$Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

# ─────────────────────────────────────────────────────────────────────────────
# State
# ─────────────────────────────────────────────────────────────────────────────

$script:StartedAt     = $null      # [datetime] when capacity was confirmed running; $null = stopped
$script:CapacityState = 'Unknown'  # Running | Provisioning | Stopped | Unknown
$script:ScuCount      = 0
$script:Panel         = $null      # the floating window

# ─────────────────────────────────────────────────────────────────────────────
# Webhook helper
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-SCUWebhook {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('start', 'scale', 'stop', 'status')]
        [string] $Action,

        [int] $ScuCount    = 0,
        [int] $TimeoutSec  = 60
    )

    $payload = [ordered]@{
        action = $Action
        user   = $Config.userUpn
    }
    if ($ScuCount -gt 0) { $payload['scuCount'] = $ScuCount }

    $headers = @{
        'Content-Type'     = 'application/json'
        'x-webhook-secret' = $Config.webhookSecret
    }

    try {
        $response = Invoke-RestMethod `
            -Uri        $Config.webhookUrl `
            -Method     POST `
            -Headers    $headers `
            -Body       ($payload | ConvertTo-Json -Compress -Depth 3) `
            -TimeoutSec $TimeoutSec

        return [PSCustomObject]@{ Success = $true; Response = $response }
    }
    catch {
        $code = $_.Exception.Response?.StatusCode.value__
        $msg  = $null
        try {
            $errBody = $_.ErrorDetails.Message | ConvertFrom-Json
            $msg     = $errBody.message ?? $errBody.error
            $armCode = $errBody.armErrorCode
        }
        catch { $msg = $_.Exception.Message; $armCode = $null }
        return [PSCustomObject]@{ Success = $false; StatusCode = $code; Error = $msg; ArmErrorCode = $armCode }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# State refresh  (called by poll timer and after every user action)
# ─────────────────────────────────────────────────────────────────────────────

function Update-CapacityState {
    param([switch]$Silent)

    $result = Invoke-SCUWebhook -Action status -TimeoutSec 10

    if ($result.Success) {
        $provState = $result.Response.provisioningState
        if ($provState -in @('Succeeded', 'Running', 'Active')) {
            if (-not $script:StartedAt) { $script:StartedAt = [datetime]::UtcNow }
            $script:CapacityState = 'Running'
            $script:ScuCount      = [int]($result.Response.PSObject.Properties['numberOfUnits']?.Value ??
                                          $result.Response.PSObject.Properties['scuCount']?.Value ?? 0)
        }
        elseif ($provState -in @('Creating', 'Updating')) {
            $script:CapacityState = 'Provisioning'
            if (-not $script:StartedAt) { $script:StartedAt = [datetime]::UtcNow }
        }
        else {
            # Any other non-null successful response = something is running
            if (-not $script:StartedAt) { $script:StartedAt = [datetime]::UtcNow }
            $script:CapacityState = 'Running'
        }
    }
    else {
        if ($result.StatusCode -eq 404) {
            $script:CapacityState = 'Stopped'
            $script:StartedAt     = $null
            $script:ScuCount      = 0
        }
        else {
            $script:CapacityState = 'Unknown'
        }
    }

    Sync-Panel

    # Adaptive polling: 10 s during transitional states, 5 min when stable
    if ($null -ne $script:PollTimer) {
        $transitioning = $script:CapacityState -in @('Provisioning', 'Stopping')
        $targetMs      = if ($transitioning) { 10000 } else { 300000 }
        if ($script:PollTimer.Interval -ne $targetMs) {
            $script:PollTimer.Stop()
            $script:PollTimer.Interval = $targetMs
            $script:PollTimer.Start()
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Uptime text
# ─────────────────────────────────────────────────────────────────────────────

function Get-UptimeText {
    if (-not $script:StartedAt) { return '' }
    $span = [datetime]::UtcNow - $script:StartedAt
    if ($span.TotalHours -ge 1) {
        return "$([int]$span.TotalHours)h $($span.Minutes)m"
    }
    return "$($span.Minutes)m"
}

# ─────────────────────────────────────────────────────────────────────────────
# Balloon helper
# ─────────────────────────────────────────────────────────────────────────────

function Show-Balloon {
    param(
        [string] $Title,
        [string] $Text,
        [System.Windows.Forms.ToolTipIcon] $Icon = [System.Windows.Forms.ToolTipIcon]::Info
    )
    $script:TrayIcon.BalloonTipTitle = $Title
    $script:TrayIcon.BalloonTipText  = $Text
    $script:TrayIcon.BalloonTipIcon  = $Icon
    $script:TrayIcon.ShowBalloonTip(8000)
}

# ─────────────────────────────────────────────────────────────────────────────
# Scale dialog
# ─────────────────────────────────────────────────────────────────────────────

function Show-ScaleDialog {
    $form = [System.Windows.Forms.Form] @{
        Text            = 'SCU Switchboard — Scale'
        Size            = [System.Drawing.Size]::new(280, 155)
        FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        MaximizeBox     = $false; MinimizeBox = $false
        StartPosition   = [System.Windows.Forms.FormStartPosition]::CenterScreen
    }
    $lbl = [System.Windows.Forms.Label] @{
        Text = 'Number of SCUs (1–100):'
        Location = [System.Drawing.Point]::new(16, 18)
        Size     = [System.Drawing.Size]::new(240, 20)
    }
    $spinner = [System.Windows.Forms.NumericUpDown] @{
        Minimum = 1; Maximum = 100
        Value   = [Math]::Max(1, $script:ScuCount)
        Location = [System.Drawing.Point]::new(16, 44)
        Size     = [System.Drawing.Size]::new(240, 26)
    }
    $okBtn = [System.Windows.Forms.Button] @{
        Text = 'Scale'; Location = [System.Drawing.Point]::new(76, 80)
        Size = [System.Drawing.Size]::new(80, 30)
        DialogResult = [System.Windows.Forms.DialogResult]::OK
    }
    $cancelBtn = [System.Windows.Forms.Button] @{
        Text = 'Cancel'; Location = [System.Drawing.Point]::new(168, 80)
        Size = [System.Drawing.Size]::new(68, 30)
        DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    }
    $form.AcceptButton = $okBtn; $form.CancelButton = $cancelBtn
    $form.Controls.AddRange(@($lbl, $spinner, $okBtn, $cancelBtn))
    if ($form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return [int]$spinner.Value }
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Action handlers
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-Start {
    $script:CapacityState = 'Provisioning'
    Sync-Panel
    $result = Invoke-SCUWebhook -Action start
    if ($result.Success) {
        $script:StartedAt     = [datetime]::UtcNow
        $script:CapacityState = 'Provisioning'
        Show-Balloon -Title 'SCU Starting' -Text 'Capacity is provisioning — this takes ~30 seconds.'
    }
    elseif ($result.ArmErrorCode -eq 'Capacity_AlreadyExists') {
        if (-not $script:StartedAt) { $script:StartedAt = [datetime]::UtcNow }
        $script:CapacityState = 'Running'
        Show-Balloon -Title 'SCU Already Running' -Text 'Capacity is already provisioned and running.'
    }
    else {
        $script:CapacityState = 'Unknown'
        Show-Balloon -Title 'Start Failed' -Text $result.Error -Icon Error
    }
    Sync-Panel
}

function Invoke-Scale {
    $count = Show-ScaleDialog
    if ($count -gt 0) {
        $result = Invoke-SCUWebhook -Action scale -ScuCount $count
        if ($result.Success) {
            $script:ScuCount = $count
            Show-Balloon -Title 'SCU Scaled' -Text "Scaling to $count SCU(s)."
        }
        else { Show-Balloon -Title 'Scale Failed' -Text $result.Error -Icon Error }
        Sync-Panel
    }
}

function Invoke-Stop {
    $uptime = Get-UptimeText
    $uptimeMsg = if ($uptime) { " (running $uptime)" } else { '' }
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Stop (delete) your Security Copilot capacity${uptimeMsg}?`nThis ends billing immediately.",
        'SCU Switchboard — Confirm Stop',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2
    )
    if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
        $script:CapacityState = 'Stopping'
        Sync-Panel
        $result = Invoke-SCUWebhook -Action stop
        if ($result.Success) {
            $script:CapacityState = 'Stopped'
            $script:StartedAt     = $null
            $script:ScuCount      = 0
            Show-Balloon -Title 'SCU Stopped' -Text 'Capacity deleted — billing has stopped.'
        }
        else {
            $script:CapacityState = 'Unknown'
            Show-Balloon -Title 'Stop Failed' -Text $result.Error -Icon Error
        }
        Sync-Panel
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Floating panel
# ─────────────────────────────────────────────────────────────────────────────

function New-Panel {
    $PANEL_W = 320
    $PANEL_H = 118
    $COL_BG  = [System.Drawing.Color]::FromArgb(30, 30, 46)
    $COL_FG  = [System.Drawing.Color]::FromArgb(220, 220, 230)
    $COL_SUB = [System.Drawing.Color]::FromArgb(140, 140, 160)
    $COL_BTN = [System.Drawing.Color]::FromArgb(50, 50, 70)
    $COL_BTN_HOVER = [System.Drawing.Color]::FromArgb(70, 70, 100)
    $FONT_UI = [System.Drawing.Font]::new('Segoe UI', 9)
    $FONT_SMALL = [System.Drawing.Font]::new('Segoe UI', 8)
    $FONT_BOLD  = [System.Drawing.Font]::new('Segoe UI Semibold', 9)

    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea

    $f = [System.Windows.Forms.Form] @{
        Text            = 'SCU Switchboard'
        Size            = [System.Drawing.Size]::new($PANEL_W, $PANEL_H)
        FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
        StartPosition   = [System.Windows.Forms.FormStartPosition]::Manual
        TopMost         = $true
        ShowInTaskbar   = $false
        BackColor       = $COL_BG
        ForeColor       = $COL_FG
        Padding         = [System.Windows.Forms.Padding]::new(0)
    }
    $f.Location = [System.Drawing.Point]::new($wa.Right - $PANEL_W - 12, $wa.Bottom - $PANEL_H - 12)

    # ── Top bar ───────────────────────────────────────────────────────────────
    $topBar = [System.Windows.Forms.Panel] @{
        Dock      = [System.Windows.Forms.DockStyle]::Top
        Height    = 36
        BackColor = [System.Drawing.Color]::FromArgb(22, 22, 36)
    }

    $lblTitle = [System.Windows.Forms.Label] @{
        Text      = 'Security Copilot'
        Font      = $FONT_BOLD
        ForeColor = $COL_FG
        Location  = [System.Drawing.Point]::new(12, 9)
        AutoSize  = $true
    }

    # Status dot (drawn as a colored panel)
    $script:DotPanel = [System.Windows.Forms.Panel] @{
        Size      = [System.Drawing.Size]::new(10, 10)
        Location  = [System.Drawing.Point]::new(178, 13)
        BackColor = [System.Drawing.Color]::Gray
    }
    # Make it circular via Paint event
    $script:DotPanel.Add_Paint({
        $g = $_.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.FillEllipse([System.Drawing.SolidBrush]::new($script:DotPanel.BackColor), 0, 0, 9, 9)
    })

    $script:LblState = [System.Windows.Forms.Label] @{
        Text      = 'Checking…'
        Font      = $FONT_UI
        ForeColor = $COL_SUB
        Location  = [System.Drawing.Point]::new(193, 9)
        AutoSize  = $true
    }

    # Close button
    $btnClose = [System.Windows.Forms.Button] @{
        Text      = '✕'
        Font      = [System.Drawing.Font]::new('Segoe UI', 8)
        ForeColor = $COL_SUB
        BackColor = [System.Drawing.Color]::FromArgb(22, 22, 36)
        FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        Size      = [System.Drawing.Size]::new(28, 28)
        Location  = [System.Drawing.Point]::new($PANEL_W - 30, 4)
        TabStop   = $false
    }
    $btnClose.FlatAppearance.BorderSize = 0
    $btnClose.Add_Click({ $script:Panel.Hide() })
    $btnClose.Add_MouseEnter({ $btnClose.ForeColor = [System.Drawing.Color]::White }.GetNewClosure())
    $btnClose.Add_MouseLeave({ $btnClose.ForeColor = $COL_SUB }.GetNewClosure())

    $topBar.Controls.AddRange(@($lblTitle, $script:DotPanel, $script:LblState, $btnClose))

    # ── Info row ──────────────────────────────────────────────────────────────
    $script:LblInfo = [System.Windows.Forms.Label] @{
        Text      = $Config.userUpn
        Font      = $FONT_SMALL
        ForeColor = $COL_SUB
        Location  = [System.Drawing.Point]::new(12, 44)
        Size      = [System.Drawing.Size]::new($PANEL_W - 20, 18)
    }

    $script:LblUptime = [System.Windows.Forms.Label] @{
        Text      = ''
        Font      = [System.Drawing.Font]::new('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
        ForeColor = [System.Drawing.Color]::FromArgb(100, 210, 130)
        Location  = [System.Drawing.Point]::new($PANEL_W - 90, 38)
        Size      = [System.Drawing.Size]::new(82, 28)
        TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    }

    # ── Button row ────────────────────────────────────────────────────────────
    $btnRow = [System.Windows.Forms.Panel] @{
        Dock      = [System.Windows.Forms.DockStyle]::Bottom
        Height    = 40
        BackColor = [System.Drawing.Color]::FromArgb(22, 22, 36)
    }

    $btnDefs = @(
        @{ Text = '▶  Start'; X = 8;   W = 84; Action = { Invoke-Start } }
        @{ Text = '⏹  Stop';  X = 98;  W = 84; Action = { Invoke-Stop  } }
        @{ Text = '⇅  Scale'; X = 188; W = 84; Action = { Invoke-Scale } }
    )

    $script:BtnStart = $null
    $script:BtnStop  = $null

    foreach ($def in $btnDefs) {
        $btn = [System.Windows.Forms.Button] @{
            Text      = $def.Text
            Font      = $FONT_UI
            ForeColor = $COL_FG
            BackColor = $COL_BTN
            FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
            Size      = [System.Drawing.Size]::new($def.W, 28)
            Location  = [System.Drawing.Point]::new($def.X, 6)
            Cursor    = [System.Windows.Forms.Cursors]::Hand
        }
        $btn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(80, 80, 110)
        $btn.FlatAppearance.BorderSize  = 1
        $action = $def.Action
        $btn.Add_Click($action)
        $btn.Add_MouseEnter({ $this.BackColor = $COL_BTN_HOVER }.GetNewClosure())
        $btn.Add_MouseLeave({ $this.BackColor = $COL_BTN }.GetNewClosure())
        $btnRow.Controls.Add($btn)

        if ($def.Text -like '*Start*') { $script:BtnStart = $btn }
        if ($def.Text -like '*Stop*')  { $script:BtnStop  = $btn }
    }

    # Allow dragging the panel
    $script:_dragging = $false
    $script:_dragStart = [System.Drawing.Point]::Empty
    $f.Add_MouseDown({ $script:_dragging = $true; $script:_dragStart = $_.Location })
    $f.Add_MouseMove({ if ($script:_dragging) { $f.Location = [System.Drawing.Point]::new($f.Left + $_.X - $script:_dragStart.X, $f.Top + $_.Y - $script:_dragStart.Y) } }.GetNewClosure())
    $f.Add_MouseUp({ $script:_dragging = $false })
    $topBar.Add_MouseDown({ $script:_dragging = $true; $script:_dragStart = $_.Location })
    $topBar.Add_MouseMove({ if ($script:_dragging) { $f.Location = [System.Drawing.Point]::new($f.Left + $_.X - $script:_dragStart.X, $f.Top + $_.Y - $script:_dragStart.Y) } }.GetNewClosure())
    $topBar.Add_MouseUp({ $script:_dragging = $false })

    $f.Controls.AddRange(@($topBar, $script:LblInfo, $script:LblUptime, $btnRow))

    return $f
}

# ─────────────────────────────────────────────────────────────────────────────
# Sync panel state → UI
# ─────────────────────────────────────────────────────────────────────────────

function Sync-Panel {
    if (-not $script:Panel) { return }

    switch ($script:CapacityState) {
        'Running' {
            $script:DotPanel.BackColor = [System.Drawing.Color]::FromArgb(80, 200, 120)
            $script:LblState.Text      = 'Running'
            $script:LblState.ForeColor = [System.Drawing.Color]::FromArgb(80, 200, 120)
            $uptime = Get-UptimeText
            $scuTxt = if ($script:ScuCount -gt 0) { "$($script:ScuCount) SCU" } else { '' }
            $script:LblInfo.Text   = if ($scuTxt) { "$scuTxt  ·  $($Config.userUpn)" } else { $Config.userUpn }
            $script:LblUptime.Text = $uptime
            $script:TrayIcon.Text  = "SCU Running · $uptime"
        }
        'Provisioning' {
            $script:DotPanel.BackColor = [System.Drawing.Color]::FromArgb(255, 160, 60)
            $script:LblState.Text      = 'Provisioning…'
            $script:LblState.ForeColor = [System.Drawing.Color]::FromArgb(255, 160, 60)
            $script:LblUptime.Text     = ''
            $script:TrayIcon.Text      = 'SCU Switchboard — Provisioning…'
        }
        'Stopping' {
            $script:DotPanel.BackColor = [System.Drawing.Color]::FromArgb(255, 100, 80)
            $script:LblState.Text      = 'Stopping…'
            $script:LblState.ForeColor = [System.Drawing.Color]::FromArgb(255, 100, 80)
            $script:LblUptime.Text     = ''
            $script:TrayIcon.Text      = 'SCU Switchboard — Stopping…'
        }
        'Stopped' {
            $script:DotPanel.BackColor = [System.Drawing.Color]::FromArgb(120, 120, 140)
            $script:LblState.Text      = 'Stopped'
            $script:LblState.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 140)
            $script:LblInfo.Text       = $Config.userUpn
            $script:LblUptime.Text     = ''
            $script:TrayIcon.Text      = 'SCU Switchboard — Stopped'
        }
        default {
            $script:DotPanel.BackColor = [System.Drawing.Color]::FromArgb(100, 100, 120)
            $script:LblState.Text      = 'Unknown'
            $script:LblState.ForeColor = [System.Drawing.Color]::FromArgb(100, 100, 120)
            $script:LblUptime.Text     = ''
            $script:TrayIcon.Text      = 'SCU Switchboard'
        }
    }

    $script:DotPanel.Invalidate()
    $script:Panel.Refresh()
}

# ─────────────────────────────────────────────────────────────────────────────
# Tray icon + context menu
# ─────────────────────────────────────────────────────────────────────────────

$script:TrayIcon = [System.Windows.Forms.NotifyIcon] @{
    Icon    = [System.Drawing.SystemIcons]::Shield
    Text    = 'SCU Switchboard'
    Visible = $true
}

$menu = [System.Windows.Forms.ContextMenuStrip]::new()

$userLabel = [System.Windows.Forms.ToolStripLabel] @{
    Text    = $Config.userUpn
    Enabled = $false
    Font    = [System.Drawing.Font]::new('Segoe UI', 8, [System.Drawing.FontStyle]::Italic)
}
$menu.Items.Add($userLabel) | Out-Null
$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new()) | Out-Null

$miPanel = [System.Windows.Forms.ToolStripMenuItem] @{ Text = '🖥  Show Panel' }
$miPanel.Add_Click({
    if ($script:Panel.Visible) { $script:Panel.Hide() }
    else {
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $script:Panel.Location = [System.Drawing.Point]::new($wa.Right - $script:Panel.Width - 12, $wa.Bottom - $script:Panel.Height - 12)
        $script:Panel.Show()
        $script:Panel.BringToFront()
    }
})
$menu.Items.Add($miPanel) | Out-Null
$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new()) | Out-Null

foreach ($def in @(
    @{ Text = '▶  Start';  Handler = { Invoke-Start } }
    @{ Text = '⇅  Scale…'; Handler = { Invoke-Scale } }
    @{ Text = '⏹  Stop';   Handler = { Invoke-Stop  } }
)) {
    $mi = [System.Windows.Forms.ToolStripMenuItem] @{ Text = $def.Text }
    $h  = $def.Handler
    $mi.Add_Click($h)
    $menu.Items.Add($mi) | Out-Null
}

$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new()) | Out-Null

$miSetup = [System.Windows.Forms.ToolStripMenuItem] @{ Text = '⚙  Setup…' }
$miSetup.Add_Click({
    if (Show-SetupWizard) {
        $script:Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        [System.Windows.Forms.MessageBox]::Show(
            'Environment registration complete.' + [System.Environment]::NewLine +
            'Restart the gadget to apply any Webhook URL or Secret changes.',
            'SCU Switchboard',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
})
$menu.Items.Add($miSetup) | Out-Null
$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new()) | Out-Null

$miExit = [System.Windows.Forms.ToolStripMenuItem] @{ Text = 'Exit' }
$miExit.Add_Click({
    $script:PollTimer.Stop()
    $script:ReminderTimer.Stop()
    $script:UptimeTimer.Stop()
    $script:TrayIcon.Visible = $false
    $script:TrayIcon.Dispose()
    [System.Windows.Forms.Application]::Exit()
})
$menu.Items.Add($miExit) | Out-Null
$script:TrayIcon.ContextMenuStrip = $menu

# Left-click toggles panel
$script:TrayIcon.Add_MouseClick({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        if ($script:Panel.Visible) { $script:Panel.Hide() }
        else {
            $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
            $script:Panel.Location = [System.Drawing.Point]::new($wa.Right - $script:Panel.Width - 12, $wa.Bottom - $script:Panel.Height - 12)
            $script:Panel.Show()
            $script:Panel.BringToFront()
        }
    }
})

# ─────────────────────────────────────────────────────────────────────────────
# Timers
# ─────────────────────────────────────────────────────────────────────────────

# Uptime label: refresh every 30 seconds (no HTTP)
$script:UptimeTimer          = [System.Windows.Forms.Timer]::new()
$script:UptimeTimer.Interval = 30000
$script:UptimeTimer.Add_Tick({ Sync-Panel })
$script:UptimeTimer.Start()

# Status poll: refresh from Azure every 5 minutes
$script:PollTimer          = [System.Windows.Forms.Timer]::new()
$script:PollTimer.Interval = 300000
$script:PollTimer.Add_Tick({ Update-CapacityState -Silent })
$script:PollTimer.Start()

# Hourly reminder: warn if capacity is still running
$script:ReminderTimer          = [System.Windows.Forms.Timer]::new()
$script:ReminderTimer.Interval = 3600000
$script:ReminderTimer.Add_Tick({
    if ($script:CapacityState -eq 'Running' -and $script:StartedAt) {
        $hours = [Math]::Round(([datetime]::UtcNow - $script:StartedAt).TotalHours, 1)
        Show-Balloon `
            -Title "⚠  SCU Still Running (${hours}h)" `
            -Text  "Your Security Copilot capacity is active.`nRight-click the tray icon → Stop if you're done." `
            -Icon  Warning
    }
})
$script:ReminderTimer.Start()

# ─────────────────────────────────────────────────────────────────────────────
# Run
# ─────────────────────────────────────────────────────────────────────────────

$script:Panel = New-Panel
$script:Panel.Show()

# Initial status check (background — short timeout so startup isn't slow)
Update-CapacityState -Silent

[System.Windows.Forms.Application]::Run()

