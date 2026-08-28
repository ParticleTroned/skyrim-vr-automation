# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$FilePath,
    [string[]]$ArgumentList = @(),
    [string]$WorkingDirectory = (Get-Location).Path,
    [string]$EvidenceDirectory,
    [ValidateRange(1, 10)][int]$MaxAttempts = 2,
    [ValidateRange(1, 3600)][int]$TimeoutSeconds = 600,
    [ValidateRange(100, 30000)][int]$TerminationGraceMilliseconds = 3000,
    [ValidateRange(100, 30000)][int]$StreamDrainGraceMilliseconds = 3000,
    [ValidateRange(0, 10000)][int]$RetryDelayMilliseconds = 250,
    [string[]]$RetryPatterns = @('(?is)\.d\.json.*permission denied', '(?is)permission denied.*\.d\.json'),
    [switch]$NoExit,
    [switch]$Compact
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Invoke-BoundedProcess currently requires Windows job objects.' }

if (-not ('SkyrimVRAutomation.Native.JobObjects' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace SkyrimVRAutomation.Native {
    public static class JobObjects {
        public const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
        public const int JobObjectExtendedLimitInformation = 9;
        [StructLayout(LayoutKind.Sequential)] public struct IO_COUNTERS {
            public UInt64 ReadOperationCount, WriteOperationCount, OtherOperationCount;
            public UInt64 ReadTransferCount, WriteTransferCount, OtherTransferCount;
        }
        [StructLayout(LayoutKind.Sequential)] public struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
            public Int64 PerProcessUserTimeLimit, PerJobUserTimeLimit;
            public UInt32 LimitFlags;
            public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
            public UInt32 ActiveProcessLimit;
            public Int64 Affinity;
            public UInt32 PriorityClass, SchedulingClass;
        }
        [StructLayout(LayoutKind.Sequential)] public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, UInt32 length);
        [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError=true)] public static extern bool TerminateJobObject(IntPtr job, UInt32 exitCode);
        [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr handle);
    }
}
'@
}

function New-KillOnCloseJob {
    $native = [SkyrimVRAutomation.Native.JobObjects]
    $job = $native::CreateJobObject([IntPtr]::Zero, $null)
    if ($job -eq [IntPtr]::Zero) { throw "CreateJobObject failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())." }
    $information = [SkyrimVRAutomation.Native.JobObjects+JOBOBJECT_EXTENDED_LIMIT_INFORMATION]::new()
    $information.BasicLimitInformation.LimitFlags = $native::JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    $size = [Runtime.InteropServices.Marshal]::SizeOf($information)
    $buffer = [Runtime.InteropServices.Marshal]::AllocHGlobal($size)
    try {
        [Runtime.InteropServices.Marshal]::StructureToPtr($information, $buffer, $false)
        if (-not $native::SetInformationJobObject($job, $native::JobObjectExtendedLimitInformation, $buffer, [uint32]$size)) {
            $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            $null = $native::CloseHandle($job)
            throw "SetInformationJobObject failed with Win32 error $errorCode."
        }
    }
    finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($buffer) }
    return $job
}

function Write-TextAtomic([string]$Path, [string]$Value) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, $Value, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $Path, $false)
    }
    finally { if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force } }
}

function Invoke-OneAttempt([int]$Attempt, [int]$AttemptTimeoutMilliseconds, [string]$TransactionId) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $resolvedExecutable
    $start.WorkingDirectory = $resolvedWorkingDirectory
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.CreateNoWindow = $true
    foreach ($argument in $ArgumentList) { $null = $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $job = [IntPtr]::Zero
    $startedUtc = [DateTime]::UtcNow
    $processId = $null
    $terminationErrors = [Collections.Generic.List[string]]::new()
    $jobAssigned = $false
    $jobTerminated = $false
    $jobClosed = $false
    $stdoutTask = $null
    $stderrTask = $null
    $completed = $false
    $exitCode = $null
    try {
        $job = New-KillOnCloseJob
        if (-not $process.Start()) { throw "Failed to start process: $resolvedExecutable" }
        $processId = $process.Id
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.HasExited) {
            $jobAssigned = [SkyrimVRAutomation.Native.JobObjects]::AssignProcessToJobObject($job, $process.Handle)
            if (-not $jobAssigned) {
                $assignError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                try { $process.Kill($true) } catch { $terminationErrors.Add("Fallback process-tree kill failed: $($_.Exception.Message)") }
                $null = $process.WaitForExit($TerminationGraceMilliseconds)
                throw "AssignProcessToJobObject failed with Win32 error $assignError; the process was not admitted without owned tree termination."
            }
        }
        else { $jobAssigned = $true }
        $completed = $process.WaitForExit([Math]::Max(1, $AttemptTimeoutMilliseconds))
        if ($completed) { $exitCode = $process.ExitCode }
        else {
            $jobTerminated = [SkyrimVRAutomation.Native.JobObjects]::TerminateJobObject($job, [uint32]3758096385)
            if (-not $jobTerminated) { $terminationErrors.Add("TerminateJobObject failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()).") }
            try { if (-not $process.HasExited) { $process.Kill($true) } } catch { $terminationErrors.Add("Fallback process-tree kill failed: $($_.Exception.Message)") }
            $completed = $process.WaitForExit($TerminationGraceMilliseconds)
        }
    }
    finally {
        if ($job -ne [IntPtr]::Zero) {
            $jobClosed = [SkyrimVRAutomation.Native.JobObjects]::CloseHandle($job)
            if (-not $jobClosed) { $terminationErrors.Add("CloseHandle(job) failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()).") }
        }
    }
    $streamDrainComplete = $false
    if ($null -ne $stdoutTask -and $null -ne $stderrTask) {
        try { $streamDrainComplete = [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdoutTask, $stderrTask), $StreamDrainGraceMilliseconds) }
        catch { $terminationErrors.Add("Stream drain faulted: $($_.Exception.Message)") }
    }
    $stdout = if ($streamDrainComplete -and $stdoutTask.IsCompletedSuccessfully) { $stdoutTask.GetAwaiter().GetResult() } else { $null }
    $stderr = if ($streamDrainComplete -and $stderrTask.IsCompletedSuccessfully) { $stderrTask.GetAwaiter().GetResult() } else { $null }
    $combined = [string]$stdout + "`n" + [string]$stderr
    $matchedPatterns = @(if ($streamDrainComplete) { $RetryPatterns | Where-Object { $combined -match $_ } })
    $timedOut = $null -ne $processId -and $null -eq $exitCode
    $unresolved = $timedOut -and -not $completed
    $record = [pscustomobject][ordered]@{
        attempt = $Attempt; pid = $processId; startedUtc = $startedUtc.ToString('o')
        elapsedMs = [long]([DateTime]::UtcNow - $startedUtc).TotalMilliseconds; allottedTimeoutMs = $AttemptTimeoutMilliseconds
        exitCode = $exitCode; timedOut = $timedOut; processTreeOwned = $jobAssigned
        terminationRequested = $timedOut; terminationConfirmed = $timedOut -and $completed; unresolvedProcess = $unresolved
        jobTerminated = $jobTerminated; jobClosed = $jobClosed; streamDrainComplete = $streamDrainComplete
        retryPatternMatched = $matchedPatterns.Count -gt 0; matchedPatterns = $matchedPatterns
        stdout = $stdout; stderr = $stderr; terminationErrors = @($terminationErrors)
    }
    if ($null -ne $resolvedEvidenceDirectory) {
        $stem = "bounded-process.$TransactionId.attempt-{0:D2}" -f $Attempt
        Write-TextAtomic -Path (Join-Path $resolvedEvidenceDirectory ($stem + '.stdout.log')) -Value $(if ($null -ne $stdout) { $stdout } else { '[stream drain did not complete within its bounded grace period]' })
        Write-TextAtomic -Path (Join-Path $resolvedEvidenceDirectory ($stem + '.stderr.log')) -Value $(if ($null -ne $stderr) { $stderr } else { '[stream drain did not complete within its bounded grace period]' })
    }
    $process.Dispose()
    return $record
}

try {
    $resolvedExecutable = (Get-Command $FilePath -ErrorAction Stop).Source
    $resolvedWorkingDirectory = [IO.Path]::GetFullPath($WorkingDirectory)
    if (-not (Test-Path -LiteralPath $resolvedWorkingDirectory -PathType Container)) { throw "WorkingDirectory does not exist: $resolvedWorkingDirectory" }
    $resolvedEvidenceDirectory = if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) { $null } else { [IO.Path]::GetFullPath($EvidenceDirectory) }
    if ($null -ne $resolvedEvidenceDirectory -and -not (Test-Path -LiteralPath $resolvedEvidenceDirectory -PathType Container)) { New-Item -ItemType Directory -Path $resolvedEvidenceDirectory -Force | Out-Null }
    $transactionId = [guid]::NewGuid().ToString('N')
    $startedUtc = [DateTime]::UtcNow
    $deadlineUtc = $startedUtc.AddSeconds($TimeoutSeconds)
    $attempts = [Collections.Generic.List[object]]::new()
    for ($number = 1; $number -le $MaxAttempts; $number++) {
        $remainingMs = [long]($deadlineUtc - [DateTime]::UtcNow).TotalMilliseconds
        if ($remainingMs -le 0) { break }
        $attempt = Invoke-OneAttempt -Attempt $number -AttemptTimeoutMilliseconds ([int][Math]::Min([int]::MaxValue, $remainingMs)) -TransactionId $transactionId
        $attempts.Add($attempt)
        if (-not $attempt.timedOut -and $attempt.exitCode -eq 0) { break }
        if ($attempt.timedOut -or -not $attempt.retryPatternMatched -or $number -eq $MaxAttempts) { break }
        $remainingAfterAttemptMs = [long]($deadlineUtc - [DateTime]::UtcNow).TotalMilliseconds
        if ($RetryDelayMilliseconds -gt 0 -and $remainingAfterAttemptMs -gt $RetryDelayMilliseconds) { Start-Sleep -Milliseconds $RetryDelayMilliseconds }
        elseif ($RetryDelayMilliseconds -gt 0) { break }
    }
    $last = if ($attempts.Count -gt 0) { $attempts[$attempts.Count - 1] } else { $null }
    $ok = $null -ne $last -and -not $last.timedOut -and $last.exitCode -eq 0
    $result = [pscustomobject][ordered]@{
        contractVersion = '2.0.0'; ok = $ok; command = 'bounded-process'; transactionId = $transactionId
        filePath = $resolvedExecutable; argumentList = @($ArgumentList); workingDirectory = $resolvedWorkingDirectory
        timeoutSeconds = $TimeoutSeconds; elapsedMs = [long]([DateTime]::UtcNow - $startedUtc).TotalMilliseconds
        maxAttempts = $MaxAttempts; attemptsRun = $attempts.Count; retried = $attempts.Count -gt 1; attempts = @($attempts)
        errors = @(
            if ($ok) { @() }
            elseif ($null -eq $last) { @("The total process budget of $TimeoutSeconds seconds expired before an attempt could start.") }
            elseif ($last.unresolvedProcess) { @("Process PID $($last.pid) exceeded the deadline and termination could not be confirmed within $TerminationGraceMilliseconds ms.") + @($last.terminationErrors) }
            elseif ($last.timedOut) { @("Process exceeded the total bounded timeout of $TimeoutSeconds seconds; owned tree termination was confirmed.") + @($last.terminationErrors) }
            else { @("Process exited with code $($last.exitCode).") }
        )
    }
    if ($null -ne $resolvedEvidenceDirectory) {
        $receiptPath = Join-Path $resolvedEvidenceDirectory "bounded-process.$transactionId.receipt.json"
        Write-TextAtomic -Path $receiptPath -Value (($result | ConvertTo-Json -Depth 20) + "`n")
        $result | Add-Member -NotePropertyName receiptPath -NotePropertyValue $receiptPath
    }
}
catch {
    $result = [pscustomobject][ordered]@{ contractVersion = '2.0.0'; ok = $false; command = 'bounded-process'; filePath = $FilePath; argumentList = @($ArgumentList); attemptsRun = 0; retried = $false; attempts = @(); errors = @($_.Exception.Message) }
}

$result | ConvertTo-Json -Depth 20 -Compress:$Compact
if (-not $result.ok -and -not $NoExit) { exit 2 }
