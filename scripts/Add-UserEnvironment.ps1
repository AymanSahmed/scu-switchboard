#Requires -Version 7.0
<#
.SYNOPSIS
    Register a user's Security Copilot dev environment in Azure App Configuration.
.DESCRIPTION
    Creates (or overwrites) the key  scu:env:<alias>  in the App Configuration store
    with the environment details needed by the SCU Switchboard Logic App.

    Requires the caller to have  App Configuration Data Owner  on the store
    (granted automatically if adminPrincipalId was set during infra deployment).
.PARAMETER ConfigEndpoint
    App Configuration endpoint, e.g. https://scu-sw-appconfig.azconfig.io
    (shown in the infra deployment outputs as 'appConfigEndpoint').
.PARAMETER UserUpn
    User's UPN, e.g. johndoe@contoso.com.  The alias (part before @) becomes the key suffix.
.PARAMETER SubscriptionId
    Azure subscription ID where the SCU capacity resource will be created/managed.
.PARAMETER ResourceGroup
    Resource group for the SCU capacity, e.g. rg-scu-johndoe-dev.
.PARAMETER CapacityName
    ARM resource name for the capacity, e.g. scu-johndoe-dev.
.PARAMETER Region
    Azure region, e.g. eastus.
.PARAMETER GeoCode
    Security Copilot geo code.  Valid values: US, EU, UK, ANZ, JP, CA.
.PARAMETER DefaultScuCount
    SCU count used by 'start' when the caller does not specify scuCount.  Default: 1.
.PARAMETER MaxScuCount
    Maximum allowed SCU count (informational — enforced in v2).  Default: 4.
.PARAMETER OwnerObjectId
    AAD object ID of the capacity owner (optional, for audit).
.EXAMPLE
    scripts/Add-UserEnvironment.ps1 `
      -ConfigEndpoint https://scu-sw-appconfig.azconfig.io `
      -UserUpn johndoe@contoso.com `
      -SubscriptionId xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx `
      -ResourceGroup rg-scu-johndoe-dev `
      -CapacityName scu-johndoe-dev `
      -Region eastus `
      -GeoCode US
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $ConfigEndpoint,
    [Parameter(Mandatory)] [string] $UserUpn,
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $CapacityName,
    [Parameter(Mandatory)] [string] $Region,
    [Parameter(Mandatory)]
    [ValidateSet('US','EU','UK','ANZ','JP','CA')]
    [string] $GeoCode,
    [int]    $DefaultScuCount = 1,
    [int]    $MaxScuCount     = 4,
    [string] $OwnerObjectId   = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Validate inputs ────────────────────────────────────────────────────────────

if ($UserUpn -notmatch '^[^@]+@[^@]+\.[^@]+$') {
    throw "UserUpn '$UserUpn' does not look like a valid UPN."
}

if ($DefaultScuCount -lt 1 -or $DefaultScuCount -gt 100) {
    throw "DefaultScuCount must be between 1 and 100."
}

if ($MaxScuCount -lt $DefaultScuCount) {
    throw "MaxScuCount ($MaxScuCount) must be >= DefaultScuCount ($DefaultScuCount)."
}

$ConfigEndpoint = $ConfigEndpoint.TrimEnd('/')

if (-not $ConfigEndpoint.StartsWith('https://', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "ConfigEndpoint must use HTTPS."
}

# ── Build App Configuration key / value ───────────────────────────────────────

$alias = $UserUpn.Split('@')[0].ToLower()
$key   = "scu:env:$alias"

$envValue = [ordered]@{
    subscriptionId  = $SubscriptionId
    resourceGroup   = $ResourceGroup
    capacityName    = $CapacityName
    region          = $Region
    geoCode         = $GeoCode
    defaultScuCount = $DefaultScuCount
    maxScuCount     = $MaxScuCount
    ownerObjectId   = $OwnerObjectId
    registeredBy    = (az account show --query 'user.name' -o tsv 2>$null) ?? 'unknown'
    registeredAt    = (Get-Date -Format 'o')
} | ConvertTo-Json -Compress -Depth 3

# ── Write key-value via az rest + temp file (avoids quoting & auth conflicts) ─

if ($PSCmdlet.ShouldProcess($key, "Write to App Configuration ($ConfigEndpoint)")) {
    Write-Host "Writing key '$key' to $ConfigEndpoint …" -ForegroundColor Cyan

    # Build App Config REST body.  Write to a temp file so that embedded JSON
    # is never passed through PowerShell → process argument quoting (which
    # strips double quotes on Windows and causes the auth conflict error).
    $restBody = [ordered]@{
        value        = $envValue
        content_type = 'application/json'
    } | ConvertTo-Json -Compress -Depth 2

    $tempFile = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($tempFile, $restBody, [System.Text.Encoding]::UTF8)

        $uri    = "$ConfigEndpoint/kv/$([Uri]::EscapeDataString($key))?api-version=2023-10-01"
        $result = az rest `
            --method   PUT `
            --url      $uri `
            --resource 'https://azconfig.io' `
            --body     "@$tempFile" `
            --output   json 2>&1

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to write to App Configuration.`n$result"
        }
        $response = $result | ConvertFrom-Json
    } finally {
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    }

    Write-Host "✓ Registered environment for '$UserUpn'" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Key          : $($response.key)"
    Write-Host "  Capacity     : $CapacityName  ($ResourceGroup)"
    Write-Host "  Subscription : $SubscriptionId"
    Write-Host "  Region       : $Region  ($GeoCode)"
    Write-Host "  Default SCUs : $DefaultScuCount  (max $MaxScuCount)"
}
