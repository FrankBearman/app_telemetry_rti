#Requires -Version 5.1
<#
.SYNOPSIS
  Installs dependencies and runs scripts/deploy_fabric.py for a customer.
  Run Deploy-Azure.ps1 first (it produces out/<Customer>/azure-outputs.json).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Customer,
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = 'Stop'
& "$PSScriptRoot\Get-CustomerConfig.ps1" -Customer $Customer -RepoRoot $RepoRoot | Out-Null

python -m pip install --quiet -r "$PSScriptRoot\requirements.txt"
if ($LASTEXITCODE) { throw 'pip install failed.' }

python "$PSScriptRoot\deploy_fabric.py" --customer $Customer --repo-root $RepoRoot
if ($LASTEXITCODE) { throw 'Fabric deployment failed.' }
