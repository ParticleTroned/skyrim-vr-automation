# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BuildDirectory,
    [string[]]$TestExecutablePath = @(),
    [string]$EvidenceDirectory,
    [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300,
    [switch]$AllowExternalTestExecutable,
    [switch]$DiscoveryOnly,
    [switch]$NoExit,
    [switch]$Compact
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$boundedProcessTool = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\process-control\Invoke-BoundedProcess.ps1'))

function Test-PathUnderRoot([string]$Path, [string]$Root) {
    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    return $resolvedPath.StartsWith($resolvedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Get-RemainingSeconds([DateTime]$DeadlineUtc) {
    $remaining = ($DeadlineUtc - [DateTime]::UtcNow).TotalSeconds
    if ($remaining -le 0) { throw "The total build-test budget of $TimeoutSeconds seconds expired." }
    return [int][Math]::Max(1, [Math]::Ceiling($remaining))
}

function Invoke-BoundedCommand([string]$CommandPath, [string[]]$Arguments, [DateTime]$DeadlineUtc) {
    $remainingSeconds = Get-RemainingSeconds -DeadlineUtc $DeadlineUtc
    $parameters = @{
        FilePath = $CommandPath; ArgumentList = $Arguments; WorkingDirectory = $build
        TimeoutSeconds = $remainingSeconds; MaxAttempts = 1; NoExit = $true; Compact = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($EvidenceDirectory)) { $parameters.EvidenceDirectory = $EvidenceDirectory }
    $bounded = & $boundedProcessTool @parameters | ConvertFrom-Json -Depth 30
    $attempt = if (@($bounded.attempts).Count -gt 0) { @($bounded.attempts)[-1] } else { $null }
    return [pscustomobject][ordered]@{
        filePath = $CommandPath; arguments = @($Arguments); transactionId = $bounded.transactionId
        startedUtc = if ($attempt) { $attempt.startedUtc } else { $null }
        elapsedMilliseconds = if ($attempt) { $attempt.elapsedMs } else { $bounded.elapsedMs }
        timedOut = if ($attempt) { [bool]$attempt.timedOut } else { $false }
        unresolvedProcess = if ($attempt) { [bool]$attempt.unresolvedProcess } else { $false }
        exitCode = if ($attempt) { $attempt.exitCode } else { $null }
        stdout = if ($attempt) { $attempt.stdout } else { $null }
        stderr = if ($attempt) { $attempt.stderr } else { $null }
        boundedReceiptPath = if ($bounded.PSObject.Properties['receiptPath']) { $bounded.receiptPath } else { $null }
        errors = @($bounded.errors)
    }
}

function Resolve-ExplicitTests([string]$Directory, [string[]]$Explicit) {
    $paths = [Collections.Generic.List[string]]::new()
    foreach ($path in $Explicit) {
        $resolved = [IO.Path]::GetFullPath($path)
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "Explicit test executable does not exist: $resolved" }
        if (-not $AllowExternalTestExecutable -and -not (Test-PathUnderRoot -Path $resolved -Root $Directory)) {
            throw "Explicit test executable is outside the approved build root: $resolved"
        }
        if (-not $paths.Contains($resolved)) { $paths.Add($resolved) }
    }
    return @($paths)
}

function Write-JsonUnique([string]$Directory, [string]$Stem, $Value) {
    $resolved = [IO.Path]::GetFullPath($Directory)
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) { New-Item -ItemType Directory -Path $resolved -Force | Out-Null }
    $path = Join-Path $resolved ($Stem + '.' + [guid]::NewGuid().ToString('N') + '.json')
    $temporary = $path + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 30) + "`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $path, $false)
    }
    finally { if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force } }
    return $path
}

try {
    $build = [IO.Path]::GetFullPath($BuildDirectory)
    if (-not (Test-Path -LiteralPath $build -PathType Container)) { throw "Build directory does not exist: $build" }
    if (-not (Test-Path -LiteralPath $boundedProcessTool -PathType Leaf)) { throw "Bounded process controller does not exist: $boundedProcessTool" }
    $deadlineUtc = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $directTests = @(Resolve-ExplicitTests -Directory $build -Explicit $TestExecutablePath)
    $ctest = $null
    $ctestTests = @()
    $runs = @()
    $route = 'discovery-only'
    $ctestCommand = Get-Command ctest -ErrorAction SilentlyContinue
    if ($ctestCommand) {
        $ctestDiscovery = Invoke-BoundedCommand -CommandPath $ctestCommand.Source -Arguments @('--test-dir', $build, '--show-only=json-v1') -DeadlineUtc $deadlineUtc
        if (-not $ctestDiscovery.timedOut -and $ctestDiscovery.exitCode -eq 0) {
            try { $ctestTests = @(($ctestDiscovery.stdout | ConvertFrom-Json -Depth 30 -ErrorAction Stop).tests) } catch { $ctestTests = @() }
        }
        $ctest = [pscustomobject][ordered]@{ discovery = $ctestDiscovery; testCount = $ctestTests.Count; run = $null }
    }

    if (-not $DiscoveryOnly) {
        if ($ctestTests.Count -gt 0) {
            $route = 'ctest'
            $ctest.run = Invoke-BoundedCommand -CommandPath $ctestCommand.Source -Arguments @('--test-dir', $build, '--output-on-failure') -DeadlineUtc $deadlineUtc
            $runs = @($ctest.run)
        }
        elseif ($directTests.Count -gt 0) {
            $route = 'explicit-executables'
            foreach ($test in $directTests) { $runs += Invoke-BoundedCommand -CommandPath $test -Arguments @() -DeadlineUtc $deadlineUtc }
        }
    }
    $failures = @($runs | Where-Object { $_.timedOut -or $_.unresolvedProcess -or $null -eq $_.exitCode -or $_.exitCode -ne 0 })
    $discovered = if ($ctestTests.Count -gt 0) { $ctestTests.Count } else { $directTests.Count }
    $ok = if ($DiscoveryOnly) { $discovered -gt 0 } else { $runs.Count -gt 0 -and $failures.Count -eq 0 }
    $result = [pscustomobject][ordered]@{
        contractVersion = '2.0.0'; ok = $ok; route = $route; buildDirectory = $build; totalTimeoutSeconds = $TimeoutSeconds
        ctest = $ctest; directTestExecutables = @($directTests); runs = @($runs)
        summary = [pscustomobject][ordered]@{ discovered = $discovered; executed = $runs.Count; failed = $failures.Count }
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        errors = @(if ($ok) {} elseif ($discovered -eq 0) { 'No authoritative CTest tests or explicitly authorized test executables were found.' } else { 'One or more test executions failed, timed out, or could not confirm termination.' })
    }
    if (-not [string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
        $evidencePath = Write-JsonUnique -Directory $EvidenceDirectory -Stem 'csx-build-tests' -Value $result
        $result | Add-Member -NotePropertyName evidencePath -NotePropertyValue $evidencePath
    }
}
catch {
    $result = [pscustomobject][ordered]@{
        contractVersion = '2.0.0'; ok = $false; route = 'error'; buildDirectory = $BuildDirectory
        ctest = $null; directTestExecutables = @(); runs = @(); summary = $null
        timestampUtc = [DateTime]::UtcNow.ToString('o'); errors = @($_.Exception.Message)
    }
}

$json = @{ InputObject = $result; Depth = 30 }
if ($Compact) { $json.Compress = $true }
ConvertTo-Json @json
if (-not $result.ok -and -not $NoExit) { exit 2 }
