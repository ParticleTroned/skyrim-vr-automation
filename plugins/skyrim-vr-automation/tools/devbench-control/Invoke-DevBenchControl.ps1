# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('list', 'call')]
    [string]$Command = 'list',

    [string]$Tool,

    [string]$ArgumentsJson = '{}',

    [string]$RuntimePath = $env:CSX_DEVBENCH_RUNTIME_PATH,

    [switch]$Compact
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$endpoint = $null

function Invoke-McpRequest {
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)]$Payload
    )
    $body = $Payload | ConvertTo-Json -Depth 30 -Compress
    $response = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $Endpoint -Headers $Headers -Body $body -TimeoutSec 15
    return [pscustomobject]@{ response = $response; json = ($response.Content | ConvertFrom-Json -Depth 50) }
}

try {
    if ([string]::IsNullOrWhiteSpace($RuntimePath)) {
        throw 'RuntimePath is required. Pass -RuntimePath or set CSX_DEVBENCH_RUNTIME_PATH.'
    }
    if (-not (Test-Path -LiteralPath $RuntimePath -PathType Leaf)) { throw "DevBench runtime metadata does not exist: $RuntimePath" }
    $runtime = Get-Content -LiteralPath $RuntimePath -Raw | ConvertFrom-Json
    if (-not $runtime.PSObject.Properties['port']) { throw 'DevBench runtime metadata has no port.' }
    $endpoint = "http://127.0.0.1:$([int]$runtime.port)/mcp"
    $baseHeaders = @{ Accept = 'application/json, text/event-stream'; 'Content-Type' = 'application/json' }
    $initialize = Invoke-McpRequest -Endpoint $endpoint -Headers $baseHeaders -Payload @{
        jsonrpc = '2.0'; id = 1; method = 'initialize'; params = @{
            protocolVersion = '2025-03-26'; capabilities = @{}; clientInfo = @{ name = 'DevBenchControl'; version = '1.0' }
        }
    }
    $sessionHeader = $initialize.response.Headers['Mcp-Session-Id']
    $sessionId = if ($sessionHeader -is [array]) { [string]$sessionHeader[0] } else { [string]$sessionHeader }
    if ([string]::IsNullOrWhiteSpace($sessionId)) { throw 'DevBench did not return an MCP session ID.' }
    $headers = @{ Accept = 'application/json, text/event-stream'; 'Content-Type' = 'application/json'; 'Mcp-Session-Id' = $sessionId }
    Invoke-WebRequest -UseBasicParsing -Method Post -Uri $endpoint -Headers $headers -Body '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' -TimeoutSec 15 | Out-Null

    if ($Command -eq 'list') {
        $rpc = Invoke-McpRequest -Endpoint $endpoint -Headers $headers -Payload @{ jsonrpc = '2.0'; id = 2; method = 'tools/list'; params = @{} }
        if ($rpc.json.PSObject.Properties['error']) { throw "DevBench tools/list failed: $($rpc.json.error | ConvertTo-Json -Compress)" }
        $data = $rpc.json.result
    }
    else {
        if ([string]::IsNullOrWhiteSpace($Tool)) { throw 'Tool is required for call.' }
        try { $arguments = $ArgumentsJson | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { throw "ArgumentsJson is invalid: $($_.Exception.Message)" }
        $rpc = Invoke-McpRequest -Endpoint $endpoint -Headers $headers -Payload @{ jsonrpc = '2.0'; id = 2; method = 'tools/call'; params = @{ name = $Tool; arguments = $arguments } }
        if ($rpc.json.PSObject.Properties['error']) { throw "DevBench tools/call failed: $($rpc.json.error | ConvertTo-Json -Compress)" }
        if ($rpc.json.result.PSObject.Properties['isError'] -and $rpc.json.result.isError) {
            $message = ($rpc.json.result.content | ForEach-Object { $_.text }) -join "`n"
            throw "DevBench tool '$Tool' failed: $message"
        }
        $content = @($rpc.json.result.content)
        $parsed = @()
        foreach ($item in $content) {
            if ($item.type -eq 'text') {
                try { $parsed += ,($item.text | ConvertFrom-Json -Depth 50) } catch { $parsed += ,([string]$item.text) }
            }
            else { $parsed += ,$item }
        }
        $data = [pscustomobject][ordered]@{ tool = $Tool; content = $parsed; rawResult = $rpc.json.result }
    }

    $result = [pscustomobject][ordered]@{
        ok = $true
        command = $Command
        endpoint = $endpoint
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        data = $data
        errors = @()
    }
}
catch {
    $result = [pscustomobject][ordered]@{
        ok = $false
        command = $Command
        endpoint = $endpoint
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        data = $null
        errors = @($_.Exception.Message)
    }
}

$parameters = @{ InputObject = $result; Depth = 50 }
if ($Compact) { $parameters['Compress'] = $true }
ConvertTo-Json @parameters
if (-not $result.ok) { exit 2 }
