#Requires -Version 5.1
<#
.SYNOPSIS
  Runs the whole deployment for one customer: Azure, then Fabric, then Power Platform.
  This is the same sequence the ADO pipeline runs; use it to deploy manually or to hand the
  solution to a customer who deploys it themselves.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Customer,
    [switch]$SkipAzure,
    [switch]$SkipFabric,
    [switch]$SkipPowerPlatform
)

$ErrorActionPreference = 'Stop'
$cfg = & "$PSScriptRoot\Get-CustomerConfig.ps1" -Customer $Customer

if (-not $SkipAzure) { & "$PSScriptRoot\Deploy-Azure.ps1" -Customer $Customer }
if (-not $SkipFabric -and $cfg.fabric.deploy) { & "$PSScriptRoot\Deploy-Fabric.ps1" -Customer $Customer }
if (-not $SkipPowerPlatform -and $cfg.powerPlatform.deploy) { & "$PSScriptRoot\Deploy-PowerPlatform.ps1" -Customer $Customer }
