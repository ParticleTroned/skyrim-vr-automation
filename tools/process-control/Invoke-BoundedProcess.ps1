# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$FilePath,
    [string[]]$ArgumentList = @(),
    [string]$WorkingDirectory = (Get-Location).Path,
    [string]$EvidenceDirectory,
    [ValidateRange(1, 10)][int]$MaxAttempts = 2,
    [ValidateRange(1, 3600)][int]$TimeoutSeconds = 600,
    [ValidateRange(0, 10000)][int]$RetryDelayMilliseconds = 250,
    [string[]]$RetryPatterns = @('(?is)\.d\.json.*permission denied', '(?is)permission denied.*\.d\.json'),
    [switch]$NoExit,
    [switch]$Compact
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-OneAttempt([int]$Attempt) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FilePath
    $start.WorkingDirectory = [IO.Path]::GetFullPath($WorkingDirectory)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.CreateNoWindow = $true
    foreach ($argument in $ArgumentList) { $null = $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $startedUtc = [DateTime]::UtcNow
    if (-not $process.Start()) { throw "Failed to start process: $FilePath" }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $completed = $process.WaitForExit($TimeoutSeconds * 1000)
    $timedOut = -not $completed
    if ($timedOut) {
        try { $process.Kill($true) } catch {}
        $process.WaitForExit()
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $combined = $stdout + "`n" + $stderr
    $matchedPatterns = @($RetryPatterns | Where-Object { $combined -match $_ })
    $record = [pscustomobject][ordered]@{
        attempt = $Attempt
        pid = $process.Id
        startedUtc = $startedUtc.ToString('o')
        elapsedMs = [long]([DateTime]::UtcNow - $startedUtc).TotalMilliseconds
        exitCode = $(if ($timedOut) { $null } else { $process.ExitCode })
        timedOut = $timedOut
        retryPatternMatched = $matchedPatterns.Count -gt 0
        matchedPatterns = $matchedPatterns
        stdout = $stdout
        stderr = $stderr
    }
    if (-not [string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
        $evidence = [IO.Path]::GetFullPath($EvidenceDirectory)
        New-Item -ItemType Directory -Path $evidence -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $evidence ("attempt-{0:D2}.stdout.log" -f $Attempt)) -Value $stdout -Encoding utf8
        Set-Content -LiteralPath (Join-Path $evidence ("attempt-{0:D2}.stderr.log" -f $Attempt)) -Value $stderr -Encoding utf8
    }
    return $record
}

try {
    $resolvedExecutable = (Get-Command $FilePath -ErrorAction Stop).Source
    if (-not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) { throw "WorkingDirectory does not exist: $WorkingDirectory" }
    $attempts = [Collections.Generic.List[object]]::new()
    for ($number = 1; $number -le $MaxAttempts; $number++) {
        $attempt = Invoke-OneAttempt $number
        $attempts.Add($attempt)
        if (-not $attempt.timedOut -and $attempt.exitCode -eq 0) { break }
        if ($attempt.timedOut -or -not $attempt.retryPatternMatched -or $number -eq $MaxAttempts) { break }
        Start-Sleep -Milliseconds $RetryDelayMilliseconds
    }
    $last = $attempts[$attempts.Count - 1]
    $ok = -not $last.timedOut -and $last.exitCode -eq 0
    $result = [pscustomobject][ordered]@{
        ok = $ok
        command = 'bounded-process'
        filePath = $resolvedExecutable
        argumentList = @($ArgumentList)
        workingDirectory = [IO.Path]::GetFullPath($WorkingDirectory)
        maxAttempts = $MaxAttempts
        attemptsRun = $attempts.Count
        retried = $attempts.Count -gt 1
        attempts = @($attempts)
        errors = $(if ($ok) { @() } elseif ($last.timedOut) { @("Process exceeded the bounded timeout of $TimeoutSeconds seconds.") } else { @("Process exited with code $($last.exitCode).") })
    }
    if (-not [string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
        $result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path ([IO.Path]::GetFullPath($EvidenceDirectory)) 'bounded-process.receipt.json') -Encoding utf8
    }
}
catch {
    $result = [pscustomobject][ordered]@{ ok = $false; command = 'bounded-process'; filePath = $FilePath; argumentList = @($ArgumentList); attemptsRun = 0; retried = $false; attempts = @(); errors = @($_.Exception.Message) }
}

$result | ConvertTo-Json -Depth 20 -Compress:$Compact
if (-not $result.ok -and -not $NoExit) { exit 2 }
