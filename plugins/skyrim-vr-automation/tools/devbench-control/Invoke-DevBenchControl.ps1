# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('list', 'call', 'wait')]
    [string]$Command = 'list',
    [string]$Tool,
    [string]$ArgumentsJson = '{}',
    [string]$RuntimePath = $env:CSX_DEVBENCH_RUNTIME_PATH,
    [string]$ToolFilter,
    [switch]$NamesOnly,
    [switch]$RequireSuccess,
    [switch]$SkipRuntimeIdentityVerification,
    [string]$EvidenceDirectory,
    [string]$EvidenceLabel,
    [string]$ArtifactPath,
    [string]$ExpectedBuildId,
    [string]$ExpectedArtifactSha256,
    [ValidateSet('noBlockingMenu', 'playerLoaded', 'upscalingStable', 'toolAvailable', 'serviceReady')]
    [string]$Condition = 'noBlockingMenu',
    [ValidateRange(1, 600)]
    [int]$TimeoutSeconds = 30,
    [ValidateRange(50, 5000)]
    [int]$PollMilliseconds = 250,
    [ValidateRange(0, 10)]
    [int]$MaxTransientRetries = 4,
    [ValidateRange(50, 5000)]
    [int]$MaxPollMilliseconds = 5000,
    [string[]]$AcceptedState = @('ready', 'idle', 'available', 'completed', 'success', 'ok'),
    [string[]]$RetryableState = @('service_unavailable', 'initializing', 'starting', 'waiting_for_safe_point', 'loading_transition', 'relatch_pending', 'compiling', 'pending', 'queued', 'running'),
    [string]$ExpectedErrorCode,
    [string]$ProgressLogPath,
    [string[]]$IgnoredMenus = @('HUD Menu'),
    [switch]$AcceptAlreadyLoaded,
    [string]$ExpectedCell,
    [string]$ExpectedProfileJson,
    [ValidateRange(2, 20)]
    [int]$StableSamples = 2,
    [ValidateRange(1, 1000)]
    [int]$MinimumStableFrameAdvance = 5,
    [switch]$NoExit,
    [switch]$Compact
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$endpoint = $null
$headers = $null
$runtimeIdentity = $null
$transportRetries = [Collections.Generic.List[object]]::new()
Import-Module (Join-Path $PSScriptRoot 'DevBenchControl.psm1') -Force

function Invoke-McpRequest {
    param([string]$Endpoint, [hashtable]$Headers, $Payload)
    $body = $Payload | ConvertTo-Json -Depth 30 -Compress
    $attempt = 0
    $delay = [Math]::Max(50, $PollMilliseconds)
    while ($true) {
        $attempt++
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $Endpoint -Headers $Headers -Body $body -TimeoutSec 15
            return [pscustomobject]@{ response = $response; json = ($response.Content | ConvertFrom-Json -Depth 50); attempts = $attempt }
        }
        catch {
            $statusCode = $null
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { $statusCode = $null }
            if ($Command -eq 'wait' -and $statusCode -eq 404 -and $Headers.ContainsKey('Mcp-Session-Id') -and $attempt -le $MaxTransientRetries) {
                try {
                    $resetHeaders = @{ Accept = 'application/json, text/event-stream'; 'Content-Type' = 'application/json' }
                    $resetBody = @{ jsonrpc = '2.0'; id = [DateTime]::UtcNow.Ticks; method = 'initialize'; params = @{ protocolVersion = '2025-03-26'; capabilities = @{}; clientInfo = @{ name = 'DevBenchControl'; version = '1.4' } } } | ConvertTo-Json -Depth 10 -Compress
                    $resetResponse = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $Endpoint -Headers $resetHeaders -Body $resetBody -TimeoutSec 15
                    $resetSessionHeader = $resetResponse.Headers['Mcp-Session-Id']
                    $resetSessionId = if ($resetSessionHeader -is [array]) { [string]$resetSessionHeader[0] } else { [string]$resetSessionHeader }
                    if ([string]::IsNullOrWhiteSpace($resetSessionId)) { throw 'DevBench session recovery did not return an MCP session ID.' }
                    $Headers['Mcp-Session-Id'] = $resetSessionId
                    Invoke-WebRequest -UseBasicParsing -Method Post -Uri $Endpoint -Headers $Headers -Body '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' -TimeoutSec 15 | Out-Null
                    $transportRetries.Add([pscustomobject][ordered]@{
                        attempt = $attempt
                        statusCode = $statusCode
                        delayMilliseconds = $delay
                        recovery = 'mcp-session-reinitialized'
                        message = $_.Exception.Message
                        timestampUtc = [DateTime]::UtcNow.ToString('o')
                    })
                    Start-Sleep -Milliseconds $delay
                    $delay = [Math]::Min($MaxPollMilliseconds, $delay * 2)
                    continue
                }
                catch {
                    $transportRetries.Add([pscustomobject][ordered]@{
                        attempt = $attempt
                        statusCode = $statusCode
                        delayMilliseconds = $delay
                        recovery = 'mcp-session-reinitialize-failed'
                        message = $_.Exception.Message
                        timestampUtc = [DateTime]::UtcNow.ToString('o')
                    })
                }
            }
            $transient = $statusCode -in @(429, 502, 503, 504) -or
                ($Command -eq 'wait' -and $statusCode -eq 404) -or
                $_.Exception -is [System.TimeoutException] -or
                $_.Exception.Message -match 'timed out|temporarily unavailable|connection.*closed'
            if (-not $transient -or $attempt -gt $MaxTransientRetries) { throw }
            $transportRetries.Add([pscustomobject][ordered]@{
                attempt = $attempt
                statusCode = $statusCode
                delayMilliseconds = $delay
                message = $_.Exception.Message
                timestampUtc = [DateTime]::UtcNow.ToString('o')
            })
            Start-Sleep -Milliseconds $delay
            $delay = [Math]::Min($MaxPollMilliseconds, $delay * 2)
        }
    }
}

function Invoke-ToolRpc {
    param([string]$Name, [hashtable]$Arguments, [hashtable]$Headers)
    $rpc = Invoke-McpRequest -Endpoint $endpoint -Headers $Headers -Payload @{ jsonrpc = '2.0'; id = [DateTime]::UtcNow.Ticks; method = 'tools/call'; params = @{ name = $Name; arguments = $Arguments } }
    if ($rpc.json.PSObject.Properties['error']) { throw "DevBench tools/call failed: $($rpc.json.error | ConvertTo-Json -Compress)" }
    if ($rpc.json.result.PSObject.Properties['isError'] -and $rpc.json.result.isError) {
        $message = ($rpc.json.result.content | ForEach-Object { $_.text }) -join "`n"
        throw "DevBench tool '$Name' failed: $message"
    }
    $parsed = @()
    foreach ($item in @($rpc.json.result.content)) {
        if ($item.type -eq 'text') {
            try { $parsed += ,($item.text | ConvertFrom-Json -Depth 50) } catch { $parsed += ,([string]$item.text) }
        }
        else { $parsed += ,$item }
    }
    return [pscustomobject][ordered]@{ tool = $Name; content = $parsed; rawResult = $rpc.json.result }
}

function Test-WaitRetryableException {
    param([Parameter(Mandatory)]$Exception)
    $message = [string]$Exception.Message
    $statusCode = $null
    try { $statusCode = [int]$Exception.Response.StatusCode } catch { $statusCode = $null }
    return $statusCode -in @(404, 429, 502, 503, 504) -or
        $message -match '\[(404|429|502|503|504)\]|timed out|temporarily unavailable|connection.*closed|connection.*refused|actively refused|main-thread task did not run|main thread busy'
}

function Close-McpSession {
    param([string]$Endpoint, [hashtable]$Headers)
    $sessionId = if ($null -ne $Headers -and $Headers.ContainsKey('Mcp-Session-Id')) {
        [string]$Headers['Mcp-Session-Id']
    }
    else { $null }
    if ([string]::IsNullOrWhiteSpace($Endpoint) -or [string]::IsNullOrWhiteSpace($sessionId)) {
        return [pscustomobject][ordered]@{
            attempted = $false; ok = $true; state = 'not_opened'; sessionId = $sessionId
            statusCode = $null; error = $null
        }
    }
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Method Delete -Uri $Endpoint -Headers $Headers -TimeoutSec 2
        return [pscustomobject][ordered]@{
            attempted = $true; ok = $true; state = 'closed'; sessionId = $sessionId
            statusCode = [int]$response.StatusCode; error = $null
        }
    }
    catch {
        $statusCode = $null
        try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { $statusCode = $null }
        if ($statusCode -eq 404) {
            return [pscustomobject][ordered]@{
                attempted = $true; ok = $true; state = 'already_absent'; sessionId = $sessionId
                statusCode = $statusCode; error = $null
            }
        }
        return [pscustomobject][ordered]@{
            attempted = $true; ok = $false; state = 'cleanup_failed'; sessionId = $sessionId
            statusCode = $statusCode; error = $_.Exception.Message
        }
    }
}

function Open-McpSession($Runtime, [switch]$AllowDeferredBuildIdentity) {
    $baseHeaders = @{ Accept = 'application/json, text/event-stream'; 'Content-Type' = 'application/json' }
    $sessionHeaders = $null
    try {
        $initialize = Invoke-McpRequest -Endpoint $endpoint -Headers $baseHeaders -Payload @{
            jsonrpc = '2.0'; id = [DateTime]::UtcNow.Ticks; method = 'initialize'; params = @{
                protocolVersion = '2025-03-26'; capabilities = @{}; clientInfo = @{ name = 'DevBenchControl'; version = '1.4' }
            }
        }
        $sessionHeader = $initialize.response.Headers['Mcp-Session-Id']
        $sessionId = if ($sessionHeader -is [array]) { [string]$sessionHeader[0] } else { [string]$sessionHeader }
        if ([string]::IsNullOrWhiteSpace($sessionId)) { throw 'DevBench did not return an MCP session ID.' }
        $sessionHeaders = @{ Accept = 'application/json, text/event-stream'; 'Content-Type' = 'application/json'; 'Mcp-Session-Id' = $sessionId }
        Invoke-WebRequest -UseBasicParsing -Method Post -Uri $endpoint -Headers $sessionHeaders -Body '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' -TimeoutSec 15 | Out-Null
        $listRpc = Invoke-McpRequest -Endpoint $endpoint -Headers $sessionHeaders -Payload @{ jsonrpc = '2.0'; id = [DateTime]::UtcNow.Ticks; method = 'tools/list'; params = @{} }
        if ($listRpc.json.PSObject.Properties['error']) { throw "DevBench tools/list failed: $($listRpc.json.error | ConvertTo-Json -Compress)" }
        $sessionTools = @($listRpc.json.result.tools)
        $identity = $null
        if (-not $SkipRuntimeIdentityVerification) {
            $identity = Get-RuntimeIdentity -Runtime $Runtime -Headers $sessionHeaders -Tools $sessionTools -AllowDeferredBuildIdentity:$AllowDeferredBuildIdentity
            if ($identity.errors.Count -gt 0) { throw "DevBench runtime identity verification failed: $($identity.errors -join ' ')" }
        }
        return [pscustomobject][ordered]@{ headers = $sessionHeaders; tools = $sessionTools; runtimeIdentity = $identity; sessionId = $sessionId }
    }
    catch {
        if ($null -ne $sessionHeaders) {
            Close-McpSession -Endpoint $endpoint -Headers $sessionHeaders | Out-Null
        }
        throw
    }
}

function Get-ListenerPid([int]$Port) {
    $records = @()
    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        try {
            $records = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop | Where-Object { $_.LocalAddress -in @('127.0.0.1', '::1') } | Select-Object -ExpandProperty OwningProcess -Unique)
        }
        catch { $records = @() }
    }
    if ($records.Count -eq 0) {
        $pattern = "^\s*TCP\s+(127\.0\.0\.1|\[::1\]):$Port\s+.*LISTENING\s+(?<pid>\d+)\s*$"
        $records = @(netstat -ano | ForEach-Object { if ($_ -match $pattern) { [int]$Matches.pid } } | Sort-Object -Unique)
    }
    if ($records.Count -ne 1) { return $null }
    return [int]$records[0]
}

function Get-RuntimeIdentity($Runtime, [hashtable]$Headers, [object[]]$Tools, [switch]$AllowDeferredBuildIdentity) {
    $expectations = Get-DevBenchRuntimeExpectations -Runtime $Runtime
    if (-not [string]::IsNullOrWhiteSpace($ArtifactPath)) { $expectations.artifactPath = [IO.Path]::GetFullPath($ArtifactPath) }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedBuildId)) { $expectations.buildId = $ExpectedBuildId }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedArtifactSha256)) { $expectations.artifactSha256 = $ExpectedArtifactSha256 }
    $listenerPid = Get-ListenerPid $expectations.port
    $inspectAvailable = @($Tools | Where-Object name -eq 'inspect').Count -eq 1
    $health = $null
    $errors = [Collections.Generic.List[string]]::new()
    if ($inspectAvailable) {
        try { $health = @(Invoke-ToolRpc -Name 'inspect' -Arguments @{ kind = 'health' } -Headers $Headers).content | Select-Object -First 1 }
        catch { $errors.Add($_.Exception.Message) }
    }
    else { $errors.Add("The authoritative tool list does not expose 'inspect' for process identity verification.") }
    if ($null -eq $listenerPid) { $errors.Add("Could not prove one loopback listener owner for port $($expectations.port).") }
    if ($health -and $listenerPid -and [int]$health.pid -ne $listenerPid) { $errors.Add("DevBench health PID $($health.pid) differs from listener PID $listenerPid.") }
    if ($null -ne $expectations.pid -and $listenerPid -and $expectations.pid -ne $listenerPid) { $errors.Add("Runtime metadata PID $($expectations.pid) differs from listener PID $listenerPid.") }
    if ($null -ne $expectations.pid -and $health -and $expectations.pid -ne [int]$health.pid) { $errors.Add("Runtime metadata PID $($expectations.pid) differs from DevBench health PID $($health.pid).") }
    if ($expectations.exe -and $health -and [string]$health.exe -ne $expectations.exe) { $errors.Add("Runtime metadata executable '$($expectations.exe)' differs from DevBench health executable '$($health.exe)'.") }
    $processIdentity = $null
    if ($listenerPid) {
        try {
            $process = Get-Process -Id $listenerPid -ErrorAction Stop
            $processIdentity = [pscustomobject][ordered]@{
                pid = $listenerPid
                name = $process.ProcessName
                path = $(try { $process.Path } catch { $null })
                startTimeUtc = $(try { $process.StartTime.ToUniversalTime().ToString('o') } catch { $null })
                responding = $(try { [bool]$process.Responding } catch { $null })
            }
        }
        catch { $errors.Add("Could not inspect DevBench listener process PID ${listenerPid}: $($_.Exception.Message)") }
    }

    $registrySources = [Collections.Generic.List[object]]::new()
    $producers = [Collections.Generic.List[object]]::new()
    foreach ($candidate in @($Tools | Where-Object { $_.name -like 'communityshaders.*_api' } | Sort-Object name)) {
        $candidateError = $null
        $producer = $null
        foreach ($action in @('registry', 'capabilities')) {
            try {
                $arguments = @{ contractMajor = 1; clientId = 'devbench-runtime-identity'; commandId = "identity-$([guid]::NewGuid().ToString('N'))"; action = $action }
                $payload = @(Invoke-ToolRpc -Name ([string]$candidate.name) -Arguments $arguments -Headers $Headers).content | Select-Object -First 1
                if ($payload) {
                    if ($payload.PSObject.Properties['producer']) { $producer = $payload.producer }
                    elseif ($payload.PSObject.Properties['registry'] -and $payload.registry.PSObject.Properties['producer']) { $producer = $payload.registry.producer }
                    elseif ($payload.PSObject.Properties['result'] -and $payload.result.PSObject.Properties['producer']) { $producer = $payload.result.producer }
                    elseif ($payload.PSObject.Properties['server']) { $producer = $payload.server }
                }
                if ($producer) { break }
            }
            catch { $candidateError = $_.Exception.Message }
        }
        if ($producer) { $producers.Add($producer) }
        $registrySources.Add([pscustomobject][ordered]@{ tool = [string]$candidate.name; producer = $producer; error = $candidateError })
    }
    $buildIds = @($producers | ForEach-Object { if ($_.PSObject.Properties['buildId']) { [string]$_.buildId } } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($buildIds.Count -gt 1) { $errors.Add("CSX service registries disagree on build ID: $($buildIds -join ', ')") }
    $actualBuildId = if ($buildIds.Count -eq 1) { $buildIds[0] } else { $null }
    $build = [pscustomobject][ordered]@{ buildId = $actualBuildId; producers = @($producers); sources = @($registrySources) }
    if ($expectations.buildId -and -not $actualBuildId -and -not $AllowDeferredBuildIdentity) { $errors.Add('A build ID expectation was supplied but no CSX service registry exposed a producer build ID.') }
    elseif (
        $expectations.buildId -and
        $actualBuildId -and
        -not [string]::Equals(
            ([string]$actualBuildId).Trim(),
            ([string]$expectations.buildId).Trim(),
            [StringComparison]::OrdinalIgnoreCase)
    ) {
        $errors.Add("Expected CSX build ID '$($expectations.buildId)' differs from runtime build ID '$actualBuildId'.")
    }
    $artifact = $null
    if ($expectations.artifactPath) {
        $resolvedArtifact = [IO.Path]::GetFullPath($expectations.artifactPath)
        if (-not (Test-Path -LiteralPath $resolvedArtifact -PathType Leaf)) { $errors.Add("Expected deployed artifact does not exist: $resolvedArtifact") }
        else {
            $actualSha = (Get-FileHash -LiteralPath $resolvedArtifact -Algorithm SHA256).Hash
            $artifact = [pscustomobject][ordered]@{ path = $resolvedArtifact; sha256 = $actualSha; bytes = [long](Get-Item -LiteralPath $resolvedArtifact).Length }
            if ($expectations.artifactSha256 -and $actualSha -ne $expectations.artifactSha256) { $errors.Add("Expected artifact SHA-256 '$($expectations.artifactSha256)' differs from deployed artifact SHA-256 '$actualSha'.") }
        }
    }
    elseif ($expectations.artifactSha256) { $errors.Add('An artifact SHA-256 expectation requires artifactPath/dllPath or -ArtifactPath.') }
    $missing = [Collections.Generic.List[string]]::new()
    if (-not $listenerPid) { $missing.Add('pid') }
    if (-not $processIdentity -or -not $processIdentity.path) { $missing.Add('process.path') }
    if (-not $actualBuildId) { $missing.Add('buildId') }
    if (-not $artifact) { $missing.Add('artifact.path+sha256') }
    return [pscustomobject][ordered]@{
        verified = $errors.Count -eq 0 -and $null -ne $listenerPid -and $null -ne $health
        complete = $missing.Count -eq 0
        expectations = $expectations
        listenerPid = $listenerPid
        process = $processIdentity
        health = $health
        build = $build
        artifact = $artifact
        missing = @($missing)
        errors = @($errors)
        verifiedUtc = [DateTime]::UtcNow.ToString('o')
    }
}

function Write-RuntimeEvidence($Binding) {
    if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) { return $null }
    $resolved = [IO.Path]::GetFullPath($EvidenceDirectory)
    New-Item -ItemType Directory -Path $resolved -Force | Out-Null
    $rawLabel = if (-not [string]::IsNullOrWhiteSpace($EvidenceLabel)) {
        $EvidenceLabel
    } elseif ($Command -eq 'wait') {
        "$Command-$Condition-$Tool"
    } else {
        "$Command-$Tool"
    }
    $safeLabel = ($rawLabel -replace '[^A-Za-z0-9._-]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($safeLabel)) { $safeLabel = 'invocation' }
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $path = Join-Path $resolved "devbench-runtime-binding.$safeLabel.$stamp.$PID.json"
    [pscustomobject][ordered]@{
        schemaVersion = 1
        runtimePath = [IO.Path]::GetFullPath($RuntimePath)
        runtimeSha256 = (Get-FileHash -LiteralPath $RuntimePath -Algorithm SHA256).Hash
        endpoint = $endpoint
        identity = $Binding
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8
    return $path
}

try {
    if ([string]::IsNullOrWhiteSpace($RuntimePath)) { throw 'RuntimePath is required. Pass -RuntimePath or set CSX_DEVBENCH_RUNTIME_PATH.' }
    if (-not (Test-Path -LiteralPath $RuntimePath -PathType Leaf)) { throw "DevBench runtime metadata does not exist: $RuntimePath" }
    $runtime = Get-Content -LiteralPath $RuntimePath -Raw | ConvertFrom-Json
    if (-not $runtime.PSObject.Properties['port']) { throw 'DevBench runtime metadata has no port.' }
    $endpoint = "http://127.0.0.1:$([int]$runtime.port)/mcp"
    $tools = @()
    $evidencePath = $null
    if ($Command -ne 'wait') {
        $session = Open-McpSession -Runtime $runtime
        $headers = $session.headers
        $tools = @($session.tools)
        $runtimeIdentity = $session.runtimeIdentity
        $evidencePath = Write-RuntimeEvidence $runtimeIdentity
    }

    $semantic = [pscustomobject][ordered]@{ known = $false; ok = $true; outcome = 'unknown'; guarded = $false; transient = $false; codes = @(); states = @(); reasons = @() }
    if ($Command -eq 'list') {
        if (-not [string]::IsNullOrWhiteSpace($ToolFilter)) { $tools = @($tools | Where-Object { $_.name -like "*$ToolFilter*" }) }
        $data = if ($NamesOnly) { [pscustomobject][ordered]@{ names = @($tools | ForEach-Object name); count = $tools.Count } } else { [pscustomobject][ordered]@{ tools = $tools } }
    }
    elseif ($Command -eq 'call') {
        if ([string]::IsNullOrWhiteSpace($Tool)) { throw 'Tool is required for call.' }
        if (@($tools | Where-Object name -eq $Tool).Count -ne 1) { throw "Tool '$Tool' is not present in the authoritative tools/list response." }
        try { $arguments = $ArgumentsJson | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { throw "ArgumentsJson is invalid: $($_.Exception.Message)" }
        $data = Invoke-ToolRpc -Name $Tool -Arguments $arguments -Headers $headers
        $semantic = Get-DevBenchSemanticStatus -Content @($data.content)
        if (-not [string]::IsNullOrWhiteSpace($ExpectedErrorCode)) {
            $matched = @($semantic.codes | Where-Object { $_ -eq $ExpectedErrorCode }).Count -gt 0
            $semantic | Add-Member -NotePropertyName expectedErrorCode -NotePropertyValue $ExpectedErrorCode -Force
            $semantic | Add-Member -NotePropertyName expectedErrorMatched -NotePropertyValue $matched -Force
            if ($matched) {
                $semantic.ok = $true
                $semantic.outcome = 'expected-guard'
                $semantic.reasons = @()
            }
        }
    }
    else {
        if ($Condition -in @('toolAvailable', 'serviceReady') -and [string]::IsNullOrWhiteSpace($Tool)) { throw "Condition '$Condition' requires -Tool." }
        if ($Condition -eq 'upscalingStable' -and [string]::IsNullOrWhiteSpace($ExpectedCell)) { throw "Condition 'upscalingStable' requires -ExpectedCell so the prior scene cannot satisfy the barrier." }
        if ($Condition -ne 'upscalingStable' -and -not [string]::IsNullOrWhiteSpace($ExpectedProfileJson)) { throw '-ExpectedProfileJson is valid only with Condition upscalingStable.' }
        $expectedUpscalingProfile = $null
        if (-not [string]::IsNullOrWhiteSpace($ExpectedProfileJson)) {
            try {
                $expectedUpscalingProfile = $ExpectedProfileJson | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                throw "ExpectedProfileJson is invalid: $($_.Exception.Message)"
            }
            foreach ($name in @('method', 'qualityMode', 'renderScaleMode', 'dlssProfile', 'fsrRuntime')) {
                if (-not $expectedUpscalingProfile.PSObject.Properties[$name]) {
                    throw "ExpectedProfileJson requires '$name'."
                }
            }
        }
        $requiredTools = switch ($Condition) {
            'noBlockingMenu' { @('menu') }
            'playerLoaded' { @('inspect') }
            'upscalingStable' { @('inspect', 'menu', 'communityshaders.upscaling_api', 'communityshaders.renderscale') }
            default { @() }
        }
        $waitArguments = @{}
        if ($Condition -eq 'serviceReady') {
            try { $waitArguments = $ArgumentsJson | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { throw "ArgumentsJson is invalid: $($_.Exception.Message)" }
        }
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        $waitStartedUtc = [DateTime]::UtcNow
        $attempts = 0
        $observation = $null
        $currentDelay = $PollMilliseconds
        $progress = [Collections.Generic.List[object]]::new()
        $lastProgressUtc = [DateTime]::MinValue
        $firstCpu = $null
        $lastCpu = $null
        $playerTransitionObserved = $false
        $playerInitialState = $null
        $stableCandidateCount = 0
        $stableFirstFrame = 0u
        $stableLastFrame = 0u
        $stableSignature = $null
        do {
            $attempts++
            if ($null -eq $headers) {
                try {
                    $session = Open-McpSession -Runtime $runtime -AllowDeferredBuildIdentity:($Condition -in @('toolAvailable', 'serviceReady'))
                    $headers = $session.headers
                    $tools = @($session.tools)
                    $runtimeIdentity = $session.runtimeIdentity
                    $evidencePath = Write-RuntimeEvidence $runtimeIdentity
                }
                catch {
                    if (-not (Test-WaitRetryableException -Exception $_.Exception)) { throw }
                    $transportRetries.Add([pscustomobject][ordered]@{
                        attempt = $attempts; phase = 'initialize'; recovery = 'outer-wait-retry'
                        delayMilliseconds = $currentDelay; message = $_.Exception.Message; timestampUtc = [DateTime]::UtcNow.ToString('o')
                    })
                    $observation = [pscustomobject][ordered]@{
                        satisfied = $false; retryable = $true; phase = 'initialize'; classification = 'api-initializing-or-unavailable'
                        probeError = $_.Exception.Message
                    }
                    Start-Sleep -Milliseconds $currentDelay
                    $currentDelay = [Math]::Min($MaxPollMilliseconds, $currentDelay * 2)
                    continue
                }
            }
            $missingRequiredTools = @($requiredTools | Where-Object { $requiredName = $_; @($tools | Where-Object name -eq $requiredName).Count -ne 1 })
            if ($missingRequiredTools.Count -gt 0) {
                try {
                    $currentList = Invoke-McpRequest -Endpoint $endpoint -Headers $headers -Payload @{ jsonrpc = '2.0'; id = [DateTime]::UtcNow.Ticks; method = 'tools/list'; params = @{} }
                    if ($currentList.json.PSObject.Properties['error']) { throw "DevBench tools/list failed: $($currentList.json.error | ConvertTo-Json -Compress)" }
                    $tools = @($currentList.json.result.tools)
                }
                catch {
                    if (-not (Test-WaitRetryableException -Exception $_.Exception)) { throw }
                    $headers = $null
                    $observation = [pscustomobject][ordered]@{ satisfied = $false; retryable = $true; phase = 'tools-list'; probeError = $_.Exception.Message }
                    Start-Sleep -Milliseconds $currentDelay
                    $currentDelay = [Math]::Min($MaxPollMilliseconds, $currentDelay * 2)
                    continue
                }
                $missingRequiredTools = @($requiredTools | Where-Object { $requiredName = $_; @($tools | Where-Object name -eq $requiredName).Count -ne 1 })
                if ($missingRequiredTools.Count -gt 0) {
                    $observation = [pscustomobject][ordered]@{ satisfied = $false; retryable = $true; phase = 'tool-registration'; requiredTools = @($requiredTools); missingTools = @($missingRequiredTools); authoritativeToolCount = $tools.Count }
                    Start-Sleep -Milliseconds $currentDelay
                    $currentDelay = [Math]::Min($MaxPollMilliseconds, $currentDelay * 2)
                    continue
                }
            }
            if ($Condition -eq 'noBlockingMenu') {
                try {
                    $menu = @(Invoke-ToolRpc -Name 'menu' -Arguments @{ action = 'list' } -Headers $headers).content | Select-Object -First 1
                    $observation = Test-DevBenchNoBlockingMenu -MenuState $menu -IgnoredMenus $IgnoredMenus
                }
                catch {
                    if (-not (Test-WaitRetryableException -Exception $_.Exception)) { throw }
                    $observation = [pscustomobject][ordered]@{ satisfied = $false; retryable = $true; probeError = $_.Exception.Message }
                }
            }
            elseif ($Condition -eq 'playerLoaded') {
                try {
                    $state = @(Invoke-ToolRpc -Name 'inspect' -Arguments @{ kind = 'state' } -Headers $headers).content | Select-Object -First 1
                    $loaded = [bool]$state.playerLoaded
                    if ($null -eq $playerInitialState) { $playerInitialState = $loaded }
                    if (-not $loaded) { $playerTransitionObserved = $true }
                    $fresh = [bool]$AcceptAlreadyLoaded -or $playerTransitionObserved
                    $observation = [pscustomobject][ordered]@{
                        satisfied = $loaded -and $fresh; state = $state; retryable = $false; probeError = $null
                        initialPlayerLoaded = $playerInitialState; freshTransitionObserved = $playerTransitionObserved
                        acceptAlreadyLoaded = [bool]$AcceptAlreadyLoaded
                    }
                }
                catch {
                    if (-not (Test-WaitRetryableException -Exception $_.Exception)) { throw }
                    $observation = [pscustomobject][ordered]@{ satisfied = $false; state = $null; retryable = $true; probeError = $_.Exception.Message }
                }
            }
            elseif ($Condition -eq 'upscalingStable') {
                try {
                    $state = @(Invoke-ToolRpc -Name 'inspect' -Arguments @{ kind = 'state' } -Headers $headers).content | Select-Object -First 1
                    $scene = @(Invoke-ToolRpc -Name 'inspect' -Arguments @{ kind = 'scene' } -Headers $headers).content | Select-Object -First 1
                    $menu = @(Invoke-ToolRpc -Name 'menu' -Arguments @{ action = 'list' } -Headers $headers).content | Select-Object -First 1
                    $menuState = Test-DevBenchNoBlockingMenu -MenuState $menu -IgnoredMenus $IgnoredMenus
                    $buildId = if ($runtimeIdentity -and $runtimeIdentity.build) { [string]$runtimeIdentity.build.buildId } else { $ExpectedBuildId }
                    $upscalingArguments = @{
                        contractMajor = 1
                        clientId = 'devbench-control'
                        commandId = "stable-$([guid]::NewGuid().ToString('N'))"
                        action = 'snapshot'
                    }
                    $renderScaleArguments = @{ action = 'status' }
                    if (-not [string]::IsNullOrWhiteSpace($buildId)) {
                        $upscalingArguments['expectedBuildId'] = $buildId
                        $renderScaleArguments['expectedBuildId'] = $buildId
                    }
                    $upscaling = @(Invoke-ToolRpc -Name 'communityshaders.upscaling_api' -Arguments $upscalingArguments -Headers $headers).content | Select-Object -First 1
                    $renderScale = @(Invoke-ToolRpc -Name 'communityshaders.renderscale' -Arguments $renderScaleArguments -Headers $headers).content | Select-Object -First 1
                    $stability = Test-DevBenchUpscalingStable -UpscalingSnapshot $upscaling -RenderScaleStatus $renderScale -ExpectedProfile $expectedUpscalingProfile
                    $actualCell = if ($scene.cell -is [string]) {
                        [string]$scene.cell
                    }
                    elseif ($scene.cell -and $scene.cell.PSObject.Properties['editorId']) {
                        [string]$scene.cell.editorId
                    }
                    else { $null }
                    $cellMatches = [string]::Equals($actualCell, $ExpectedCell, [StringComparison]::OrdinalIgnoreCase)
                    $instantaneousStable = [bool]$state.playerLoaded -and $cellMatches -and $menuState.satisfied -and $stability.satisfied
                    if ($instantaneousStable) {
                        if ($stableSignature -eq $stability.signature -and [uint32]$stability.frame -gt $stableLastFrame) {
                            $stableCandidateCount++
                        }
                        else {
                            $stableCandidateCount = 1
                            $stableFirstFrame = [uint32]$stability.frame
                            $stableSignature = $stability.signature
                        }
                        $stableLastFrame = [uint32]$stability.frame
                    }
                    else {
                        $stableCandidateCount = 0
                        $stableFirstFrame = 0u
                        $stableLastFrame = 0u
                        $stableSignature = $null
                    }
                    $stableFrameAdvance = if ($stableFirstFrame -ne 0 -and $stableLastFrame -ge $stableFirstFrame) { $stableLastFrame - $stableFirstFrame } else { 0u }
                    $observation = [pscustomobject][ordered]@{
                        satisfied = $instantaneousStable -and $stableCandidateCount -ge $StableSamples -and $stableFrameAdvance -ge $MinimumStableFrameAdvance
                        retryable = $false
                        expectedCell = $ExpectedCell
                        expectedProfile = $expectedUpscalingProfile
                        actualCell = $actualCell
                        cellMatches = $cellMatches
                        playerLoaded = [bool]$state.playerLoaded
                        menu = $menuState
                        upscaling = $stability
                        stableSamples = $stableCandidateCount
                        requiredStableSamples = $StableSamples
                        stableFirstFrame = $stableFirstFrame
                        stableLastFrame = $stableLastFrame
                        stableFrameAdvance = $stableFrameAdvance
                        requiredFrameAdvance = $MinimumStableFrameAdvance
                        probeError = $null
                    }
                }
                catch {
                    if (-not (Test-WaitRetryableException -Exception $_.Exception)) { throw }
                    $stableCandidateCount = 0
                    $stableFirstFrame = 0u
                    $stableLastFrame = 0u
                    $stableSignature = $null
                    $observation = [pscustomobject][ordered]@{
                        satisfied = $false
                        retryable = $true
                        expectedCell = $ExpectedCell
                        probeError = $_.Exception.Message
                    }
                }
            }
            else {
                $currentList = Invoke-McpRequest -Endpoint $endpoint -Headers $headers -Payload @{ jsonrpc = '2.0'; id = [DateTime]::UtcNow.Ticks; method = 'tools/list'; params = @{} }
                if ($currentList.json.PSObject.Properties['error']) { throw "DevBench tools/list failed: $($currentList.json.error | ConvertTo-Json -Compress)" }
                $currentTools = @($currentList.json.result.tools)
                $toolPresent = @($currentTools | Where-Object name -eq $Tool).Count -eq 1
                if ($toolPresent -and -not $SkipRuntimeIdentityVerification) {
                    $refreshedIdentity = Get-RuntimeIdentity -Runtime $runtime -Headers $headers -Tools $currentTools
                    if ($refreshedIdentity.errors.Count -gt 0) { throw "DevBench runtime identity verification failed after target registration: $($refreshedIdentity.errors -join ' ')" }
                    $runtimeIdentity = $refreshedIdentity
                }
                $service = $null
                if ($Condition -eq 'serviceReady' -and $toolPresent) {
                    try {
                        $toolResult = Invoke-ToolRpc -Name $Tool -Arguments $waitArguments -Headers $headers
                        $service = Test-DevBenchServiceReady -Content @($toolResult.content) -AcceptedStates $AcceptedState -RetryableStates $RetryableState
                    }
                    catch {
                        if (-not (Test-WaitRetryableException -Exception $_.Exception)) { throw }
                        $service = [pscustomobject][ordered]@{
                            ready = $false
                            retryable = $true
                            terminalFailure = $false
                            state = 'transport_retry'
                            statePath = $null
                            probeError = $_.Exception.Message
                            semantic = $null
                        }
                    }
                }

                $now = [DateTime]::UtcNow
                if (($now - $lastProgressUtc).TotalSeconds -ge 5 -or $progress.Count -eq 0) {
                    $listenerProcessId = if ($runtimeIdentity -and $runtimeIdentity.listenerPid) { [int]$runtimeIdentity.listenerPid } else { Get-ListenerPid ([int]$runtime.port) }
                    $processSample = $null
                    if ($listenerProcessId) {
                        $process = Get-Process -Id $listenerProcessId -ErrorAction SilentlyContinue
                        if ($process) {
                            $lastCpu = [double]$process.CPU
                            if ($null -eq $firstCpu) { $firstCpu = $lastCpu }
                            $processSample = [pscustomobject][ordered]@{ pid = $listenerProcessId; responding = $(try { [bool]$process.Responding } catch { $null }); cpuSeconds = $lastCpu; workingSetBytes = [long]$process.WorkingSet64 }
                        }
                    }
                    $logSample = $null
                    if (-not [string]::IsNullOrWhiteSpace($ProgressLogPath)) {
                        $resolvedLog = [IO.Path]::GetFullPath($ProgressLogPath)
                        if (Test-Path -LiteralPath $resolvedLog -PathType Leaf) {
                            $item = Get-Item -LiteralPath $resolvedLog
                            $logSample = [pscustomobject][ordered]@{ path = $resolvedLog; bytes = [long]$item.Length; lastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o'); tail = @(Get-Content -LiteralPath $resolvedLog -Tail 5) }
                        }
                    }
                    $progress.Add([pscustomobject][ordered]@{ timestampUtc = $now.ToString('o'); toolCount = $currentTools.Count; targetPresent = $toolPresent; process = $processSample; log = $logSample })
                    while ($progress.Count -gt 120) { $progress.RemoveAt(0) }
                    $lastProgressUtc = $now
                }
                $cpuDelta = if ($null -ne $firstCpu -and $null -ne $lastCpu) { [Math]::Round($lastCpu - $firstCpu, 3) } else { $null }
                $classification = if ($toolPresent) { if ($Condition -eq 'serviceReady' -and -not $service.ready) { 'service-registered-not-ready' } else { 'service-ready' } } elseif ($null -ne $cpuDelta -and $cpuDelta -gt 1) { 'api-waiting-behind-initialization' } else { 'api-absent-or-not-registered' }
                $observation = [pscustomobject][ordered]@{
                    satisfied = if ($Condition -eq 'toolAvailable') { $toolPresent } else { $toolPresent -and $service.ready }
                    tool = $Tool
                    toolPresent = $toolPresent
                    service = $service
                    classification = $classification
                    cpuDeltaSeconds = $cpuDelta
                    authoritativeToolCount = $currentTools.Count
                    progress = @($progress)
                }
                if ($service -and $service.terminalFailure) { break }
            }
            if ($observation.satisfied) { break }
            Start-Sleep -Milliseconds $currentDelay
            if ($Condition -in @('toolAvailable', 'serviceReady')) { $currentDelay = [Math]::Min($MaxPollMilliseconds, $currentDelay * 2) }
        } while ([DateTime]::UtcNow -lt $deadline)
        $waitCompletedUtc = [DateTime]::UtcNow
        $data = [pscustomobject][ordered]@{
            condition = $Condition
            satisfied = [bool]$observation.satisfied
            attempts = $attempts
            timeoutSeconds = $TimeoutSeconds
            initialPollMilliseconds = $PollMilliseconds
            maxPollMilliseconds = $MaxPollMilliseconds
            startedUtc = $waitStartedUtc.ToString('o')
            completedUtc = $waitCompletedUtc.ToString('o')
            elapsedMs = [Math]::Round(($waitCompletedUtc - $waitStartedUtc).TotalMilliseconds, 3)
            observation = $observation
        }
        if ($observation.satisfied -and -not $SkipRuntimeIdentityVerification) { $evidencePath = Write-RuntimeEvidence $runtimeIdentity }
        $semantic = [pscustomobject][ordered]@{ known = $true; ok = [bool]$observation.satisfied; reasons = $(if ($observation.satisfied) { @() } else { @("Condition '$Condition' was not satisfied within $TimeoutSeconds seconds.") }) }
    }

    $semanticFailure = $semantic.known -and -not $semantic.ok -and ($RequireSuccess -or $Command -eq 'wait')
    $result = [pscustomobject][ordered]@{
        ok = -not $semanticFailure
        transportOk = $true
        command = $Command
        endpoint = $endpoint
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        runtimeIdentity = $runtimeIdentity
        evidencePath = $evidencePath
        semantic = $semantic
        transportRetries = @($transportRetries)
        data = $data
        errors = $(if ($semanticFailure) { @($semantic.reasons) } else { @() })
    }
}
catch {
    $result = [pscustomobject][ordered]@{
        ok = $false
        transportOk = $false
        command = $Command
        endpoint = $endpoint
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        runtimeIdentity = $runtimeIdentity
        evidencePath = $null
        semantic = $null
        transportRetries = @($transportRetries)
        data = $null
        errors = @($_.Exception.Message)
    }
}

$sessionCleanup = Close-McpSession -Endpoint $endpoint -Headers $headers
$result | Add-Member -NotePropertyName sessionCleanup -NotePropertyValue $sessionCleanup

$parameters = @{ InputObject = $result; Depth = 50 }
if ($Compact) { $parameters['Compress'] = $true }
ConvertTo-Json @parameters
if (-not $result.ok -and -not $NoExit) { exit 2 }
