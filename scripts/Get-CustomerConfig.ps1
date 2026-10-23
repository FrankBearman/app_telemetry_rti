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
$network = $rt.privateNetworking
if ($network -and $network.enabled) {
    if (-not $rt.enabled) { throw "$path : realtime must be enabled when privateNetworking is enabled." }
    if ([string]::IsNullOrWhiteSpace($network.location)) {
        throw "$path : azure.realtime.privateNetworking.location must match the Fabric Eventstream region."
    }
    $workspaceId = [guid]::Empty
    if (-not [guid]::TryParse([string]$cfg.fabric.workspaceId, [ref]$workspaceId) -or $workspaceId -eq [guid]::Empty) {
        throw "$path : fabric.workspaceId must identify an existing workspace for privateNetworking identity provisioning."
    }

    function Get-Ipv4Range([string]$Cidr) {
        if ($Cidr -notmatch '^(\d{1,3}\.){3}\d{1,3}/(\d|[12]\d|3[0-2])$') {
            throw "$path : Invalid IPv4 CIDR '$Cidr' in privateNetworking."
        }
        $parts = $Cidr.Split('/')
        $bytes = @($parts[0].Split('.') | ForEach-Object { [int]$_ })
        if (@($bytes | Where-Object { $_ -gt 255 }).Count) { throw "$path : Invalid IPv4 CIDR '$Cidr'." }
        [long]$start = 0
        foreach ($octet in $bytes) { $start = $start * 256 + $octet }
        $prefix = [int]$parts[1]
        [long]$size = [math]::Pow(2, 32 - $prefix)
        if ($start % $size) { throw "$path : '$Cidr' must start at its network address." }
        [pscustomobject]@{ Start = $start; End = $start + $size - 1; Prefix = $prefix }
    }

    $vnet = Get-Ipv4Range ([string]$network.addressPrefix)
    $connector = Get-Ipv4Range ([string]$network.connectorSubnetPrefix)
    $endpoint = Get-Ipv4Range ([string]$network.privateEndpointSubnetPrefix)
    if ($connector.Prefix -gt 27) { throw "$path : connectorSubnetPrefix must be /27 or larger." }
    if ($endpoint.Prefix -gt 29) { throw "$path : privateEndpointSubnetPrefix must be /29 or larger." }
    foreach ($subnet in @($connector, $endpoint)) {
        if ($subnet.Start -lt $vnet.Start -or $subnet.End -gt $vnet.End) {
            throw "$path : Both privateNetworking subnets must be inside addressPrefix."
        }
    }
    if ($connector.Start -le $endpoint.End -and $endpoint.Start -le $connector.End) {
        throw "$path : Connector and private-endpoint subnets must not overlap."
    }
    foreach ($reserved in @('10.240.0.0/16', '10.224.0.0/12')) {
        $range = Get-Ipv4Range $reserved
        if ($vnet.Start -le $range.End -and $range.Start -le $vnet.End) {
            throw "$path : addressPrefix overlaps Fabric's reserved range $reserved."
        }
    }
}
$hasEventstream = @(Get-ChildItem (Join-Path $RepoRoot 'fabric') -Directory -Filter '*.Eventstream' -ErrorAction SilentlyContinue).Count -gt 0
if ($hasEventstream -and $cfg.fabric.itemTypes -contains 'Eventstream') {
    if (-not $rt.enabled) {
        throw "$path : Remove Eventstream from fabric.itemTypes when azure.realtime.enabled is false."
    }
    $conn = $cfg.fabric.realtime.eventHubConnectionId
    $connectionId = [guid]::Empty
    if (-not [guid]::TryParseExact([string]$conn, 'D', [ref]$connectionId) -or $connectionId -eq [guid]::Empty) {
        throw "$path : fabric.realtime.eventHubConnectionId must be the GUID of the customer's Event Hub connection when an Eventstream is deployed."
    }
    foreach ($requiredType in @('Eventhouse', 'KQLDatabase')) {
        if ($cfg.fabric.itemTypes -notcontains $requiredType) {
            throw "$path : Eventstream deployment requires $requiredType in fabric.itemTypes."
        }
    }
}

$cfg
