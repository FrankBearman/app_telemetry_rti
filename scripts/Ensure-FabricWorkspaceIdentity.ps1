#Requires -Version 5.1
<#
.SYNOPSIS
  Gets or provisions the existing Fabric workspace's identity using the Azure CLI login.
  Returns the identity, and records its IDs in out/<Customer>/fabric-identity.json.
  -ReadOnly requires an existing identity and never provisions one.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Customer,
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),
    [switch]$ReadOnly
)

$ErrorActionPreference = 'Stop'
$cfg = & "$PSScriptRoot\Get-CustomerConfig.ps1" -Customer $Customer -RepoRoot $RepoRoot
$workspaceId = [guid]::Empty
if (-not [guid]::TryParse([string]$cfg.fabric.workspaceId, [ref]$workspaceId) -or $workspaceId -eq [guid]::Empty) {
    throw 'fabric.workspaceId must identify an existing, capacity-assigned Fabric workspace.'
}

$token = az account get-access-token --tenant $cfg.tenantId --resource https://api.fabric.microsoft.com --query accessToken --output tsv
if ($LASTEXITCODE -or [string]::IsNullOrWhiteSpace($token)) { throw 'Could not obtain a Fabric access token from the Azure CLI login.' }
$headers = @{ Authorization = "Bearer $token" }
$workspaceUrl = "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId"
$workspace = Invoke-RestMethod -Method Get -Uri $workspaceUrl -Headers $headers -TimeoutSec 60
$identity = $workspace.workspaceIdentity

if (-not $identity) {
    if ($ReadOnly) {
        throw 'The Fabric workspace has no identity. Run Ensure-FabricWorkspaceIdentity.ps1 without -ReadOnly before previewing Azure deployment.'
    }
    Write-Host "Provisioning identity for Fabric workspace $workspaceId (Workspace Admin permission required)."
    $response = Invoke-WebRequest -UseBasicParsing -Method Post -Uri "$workspaceUrl/provisionIdentity" -Headers $headers -TimeoutSec 60
    $deadline = [DateTime]::UtcNow.AddMinutes(10)
    if ([int]$response.StatusCode -eq 202) {
        $operationUrl = [string]$response.Headers['Location']
        $operationUri = $null
        if (-not [uri]::TryCreate($operationUrl, [UriKind]::Absolute, [ref]$operationUri) -or
            $operationUri.Scheme -ne 'https' -or $operationUri.Host -ne 'api.fabric.microsoft.com') {
            throw 'Fabric returned an invalid identity-provisioning operation URL.'
        }
        $delay = 5
        $retryAfter = 0
        if ([int]::TryParse([string]$response.Headers['Retry-After'], [ref]$retryAfter) -and $retryAfter -gt 0) {
            $delay = $retryAfter
        }
        do {
            if ([DateTime]::UtcNow.AddSeconds($delay) -ge $deadline) {
                throw 'Timed out waiting for Fabric workspace identity provisioning.'
            }
            Start-Sleep -Seconds $delay
            $operationResponse = Invoke-WebRequest -UseBasicParsing -Method Get -Uri $operationUrl -Headers $headers -TimeoutSec 60
            $operation = $operationResponse.Content | ConvertFrom-Json
            if ($operation.status -in @('Failed', 'Cancelled', 'Canceled')) {
                throw "Fabric workspace identity provisioning failed: $($operation | ConvertTo-Json -Depth 10 -Compress)"
            }
            if ($operation.status -notin @('NotStarted', 'Running', 'Succeeded')) {
                throw "Unexpected Fabric operation status: '$($operation.status)'."
            }
            $retryAfter = 0
            if ([int]::TryParse([string]$operationResponse.Headers['Retry-After'], [ref]$retryAfter) -and $retryAfter -gt 0) {
                $delay = $retryAfter
            } else {
                $delay = 5
            }
        } while ($operation.status -ne 'Succeeded')
    } elseif ([int]$response.StatusCode -ne 200) {
        throw "Unexpected Fabric identity-provisioning response: $($response.StatusCode)."
    }

    do {
        $workspace = Invoke-RestMethod -Method Get -Uri $workspaceUrl -Headers $headers -TimeoutSec 60
        $identity = $workspace.workspaceIdentity
        if ($identity) { break }
        if ([DateTime]::UtcNow.AddSeconds(5) -ge $deadline) {
            throw 'Fabric completed provisioning but the workspace identity did not become available.'
        }
        Start-Sleep -Seconds 5
    } while (-not $identity)
}

$principalId = [guid]::Empty
$applicationId = [guid]::Empty
if (-not [guid]::TryParse([string]$identity.servicePrincipalId, [ref]$principalId) -or $principalId -eq [guid]::Empty -or
    -not [guid]::TryParse([string]$identity.applicationId, [ref]$applicationId) -or $applicationId -eq [guid]::Empty) {
    throw 'Fabric returned an invalid workspace identity; applicationId and servicePrincipalId are required.'
}
$result = [pscustomobject]@{
    workspaceId = $workspaceId.ToString()
    applicationId = $applicationId.ToString()
    servicePrincipalId = $principalId.ToString()
}
$outDir = Join-Path $RepoRoot "out\$Customer"
New-Item -ItemType Directory $outDir -Force | Out-Null
$result | ConvertTo-Json | Set-Content (Join-Path $outDir 'fabric-identity.json') -Encoding utf8
Write-Host "Fabric workspace identity ready: $principalId"
$result
