[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://localhost:5080',
    [int]$Count = 20
)

$paths = '/weather', '/weather', '/weather', '/slow', '/error'
1..$Count | ForEach-Object {
    $path = $paths | Get-Random
    $headers = @{ 'X-Demo-Run-Id' = [guid]::NewGuid().ToString() }
    try {
        $r = Invoke-WebRequest -Uri "$BaseUrl$path" -Headers $headers -UseBasicParsing
        Write-Host "$path -> $($r.StatusCode)"
    }
    catch {
        Write-Host "$path -> $($_.Exception.Response.StatusCode.value__)"
    }
    Start-Sleep -Milliseconds 200
}
