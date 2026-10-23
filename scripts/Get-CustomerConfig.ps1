#Requires -Version 5.1
<#
.SYNOPSIS
  Loads and validates customers/<Customer>.json and returns it as an object.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Customer,
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = 'Stop'

$path = Join-Path $RepoRoot "customers\$Customer.json"
if (-not (Test-Path $path)) { throw "Customer config not found: $path" }

$cfg = Get-Content $path -Raw | ConvertFrom-Json

foreach ($key in 'customerCode', 'tenantId', 'subscriptionId', 'resourceGroup', 'location') {
    $value = $cfg.$key
    if ([string]::IsNullOrWhiteSpace($value) -or $value -match '^0{8}-') {
        throw "$path : '$key' must be set."
    }
}
if ($cfg.customerCode -ne $Customer) {
    throw "$path : customerCode '$($cfg.customerCode)' must match the file name '$Customer'."
}
if ($cfg.azure.useExistingAppInsights -and [string]::IsNullOrWhiteSpace($cfg.azure.existingAppInsightsName)) {
    throw "$path : azure.existingAppInsightsName is required when useExistingAppInsights is true."
}
if ($cfg.azure.useExistingKeyVault -and [string]::IsNullOrWhiteSpace($cfg.azure.existingKeyVaultName)) {
    throw "$path : azure.existingKeyVaultName is required when useExistingKeyVault is true."
}
$rt = $cfg.azure.realtime
if ($rt -and $rt.enabled -and $cfg.azure.useExistingAppInsights -and [string]::IsNullOrWhiteSpace($rt.existingLogAnalyticsWorkspaceId)) {
    throw "$path : azure.realtime.existingLogAnalyticsWorkspaceId is required when realtime is enabled with useExistingAppInsights."
}
$hasEventstream = @(Get-ChildItem (Join-Path $RepoRoot 'fabric') -Directory -Filter '*.Eventstream' -ErrorAction SilentlyContinue).Count -gt 0
if ($hasEventstream -and $cfg.fabric.itemTypes -contains 'Eventstream') {
    $conn = $cfg.fabric.realtime.eventHubConnectionId
    if ([string]::IsNullOrWhiteSpace($conn) -or $conn -notmatch '^[0-9a-fA-F-]{36}$' -or $conn -match '^0{8}-') {
        throw "$path : fabric.realtime.eventHubConnectionId must be the GUID of the customer's Event Hub connection when an Eventstream is deployed."
    }
}

$cfg
