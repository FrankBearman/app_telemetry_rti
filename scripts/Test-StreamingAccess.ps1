#Requires -Version 5.1
<#
.SYNOPSIS
  Offline regression checks for streaming bootstrap and configuration validation.
  Azure CLI and Fabric HTTP calls are mocked; no cloud resources are accessed.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path ([IO.Path]::GetTempPath()) ("streaming-access-test-" + [guid]::NewGuid())
New-Item -ItemType Directory (Join-Path $fixture 'customers') -Force | Out-Null
New-Item -ItemType Directory (Join-Path $fixture 'fabric\test.Eventstream') -Force | Out-Null
$cfg = Get-Content (Join-Path $repo 'customers\_template.json') -Raw | ConvertFrom-Json
$cfg.customerCode = 'test'
$cfg.tenantId = '11111111-2222-3333-4444-555555555555'
$cfg.subscriptionId = '22222222-3333-4444-5555-666666666666'
$cfg.resourceGroup = 'rg-test'
$cfg.azure.namePrefix = 'test'
$cfg.fabric.workspaceId = '33333333-4444-5555-6666-777777777777'
$cfg.azure.realtime.enabled = $true
$cfg.azure.realtime.privateNetworking.enabled = $true
$cfg.azure.realtime.privateNetworking.location = 'centralus'
$cfg.fabric.itemTypes += 'Eventstream'
$cfg.fabric.realtime.eventHubConnectionId = '44444444-5555-6666-7777-888888888888'
$principal = '55555555-6666-7777-8888-999999999999'
$vnetScope = "/subscriptions/$($cfg.subscriptionId)/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/test-streaming-vnet"
$roleId = "/subscriptions/$($cfg.subscriptionId)/providers/Microsoft.Authorization/roleDefinitions/4d97b98b-1d4f-4787-a291-c67834d212e7"
$grantName = '66666666-7777-8888-9999-111111111111'
$grants = @()
$calls = [Collections.Generic.List[object]]::new()

function az {
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'account' -and $args[1] -eq 'show') {
        return (@{ tenantId = $cfg.tenantId; id = $cfg.subscriptionId } | ConvertTo-Json)
    }
    if ($args[0] -eq 'account' -and $args[1] -eq 'get-access-token') { return 'test-token-not-a-credential' }
    if ($args[0] -eq 'role' -and $args[1] -eq 'assignment') {
        return (ConvertTo-Json -InputObject @($grants) -Depth 10)
    }
    if ($args[0] -eq 'deployment') { $calls.Add(@($args)); return }
    throw "Unexpected CLI call: $args"
}
function Invoke-RestMethod {
    param($Method, $Uri, $Headers, $TimeoutSec)
    if ($Method -ne 'Get' -or $Uri -notlike 'https://api.fabric.microsoft.com/v1/workspaces/*') {
        throw "Unexpected Fabric request: $Method $Uri"
    }
    @{ workspaceIdentity = @{ servicePrincipalId = $principal; applicationId = $cfg.fabric.workspaceId } }
}
function Save-Config {
    $cfg | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $fixture 'customers\test.json') -Encoding utf8
}
function Expect-ConfigFailure([string]$Expected) {
    try {
        & "$PSScriptRoot\Get-CustomerConfig.ps1" -Customer test -RepoRoot $fixture | Out-Null
    } catch {
        if ($_.Exception.Message -like "*$Expected*") { return }
        throw
    }
    throw "Expected configuration rejection: $Expected"
}

try {
    Save-Config
    & "$PSScriptRoot\Deploy-StreamingAccess.ps1" -Customer test -RepoRoot $fixture -WhatIf
    if ($calls.Count -ne 1 -or $calls[0][2] -ne 'what-if' -or
        $calls[0] -notcontains "workspacePrincipalId=$principal" -or
        $calls[0] -contains "roleAssignmentName=$grantName") { throw 'New-grant preview failed.' }

    $grants = @(@{ scope = $vnetScope; principalId = $principal; roleDefinitionId = $roleId; name = $grantName })
    & "$PSScriptRoot\Deploy-StreamingAccess.ps1" -Customer test -RepoRoot $fixture
    if ($calls.Count -ne 2 -or $calls[1][2] -ne 'create' -or
        $calls[1] -notcontains "roleAssignmentName=$grantName") { throw 'Existing-grant adoption failed.' }

    $cfg.fabric.realtime.eventHubConnectionId = '00000000-0000-0000-0000-000000000000'
    Save-Config
    Expect-ConfigFailure 'connection'
    $cfg.fabric.realtime.eventHubConnectionId = '44444444-5555-6666-7777-888888888888'
    $cfg.fabric.itemTypes = @($cfg.fabric.itemTypes | Where-Object { $_ -ne 'KQLDatabase' })
    Save-Config
    Expect-ConfigFailure 'requires KQLDatabase'
    $cfg.fabric.itemTypes += 'KQLDatabase'
    $cfg.azure.realtime.enabled = $false
    $cfg.azure.realtime.privateNetworking.enabled = $false
    Save-Config
    Expect-ConfigFailure 'Remove Eventstream'
    Write-Host 'PASS: new-grant preview, existing-grant adoption, zero connection, missing database, disabled realtime.'
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
