# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('inspect', 'register', 'register-winning', 'ensure-winner', 'enable', 'disable', 'restore')]
    [string]$Command,

    [Parameter(Mandatory)]
    [Alias('ModListPath')]
    [string]$ProfilePath,

    [Parameter(Mandatory)]
    [string]$ModName,

    [string]$ModDirectory,

    [ValidateSet('End', 'Before', 'After')]
    [string]$Placement = 'End',

    [string]$RelativeToMod,

    [string]$ModsDirectory,

    [string[]]$WinningPaths,

    [switch]$RegisterEnabled,

    [string]$EvidenceDirectory,

    [ValidateNotNullOrEmpty()]
    [string[]]$BlockingProcessNames = @('ModOrganizer', 'SkyrimVR', 'sksevr_loader'),

    [ValidateRange(100, 60000)]
    [int]$TransactionLockTimeoutMilliseconds = 10000,

    [switch]$NoExit,

    [switch]$Compact
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-ProfileApprovalMetadata([string]$Subcommand) {
    $hostExecutable = [string][Environment]::ProcessPath
    if ([string]::IsNullOrWhiteSpace($hostExecutable)) { $hostExecutable = [string](Get-Process -Id $PID -ErrorAction Stop).Path }
    $entryPoint = [IO.Path]::GetFullPath($PSCommandPath)
    return [pscustomobject][ordered]@{
        hostExecutable = $hostExecutable; entryPoint = $entryPoint; subcommand = $Subcommand
        reusablePrefix = @($hostExecutable, '-NoProfile', '-NonInteractive', '-File', $entryPoint, $Subcommand)
        reusableApprovalEligible = $Subcommand -eq 'inspect'
        escalationUsuallyRequired = $Subcommand -ne 'inspect'
        oneShotReason = if ($Subcommand -ne 'inspect') { 'Profile mutations overwrite modlist.txt under an exact backup transaction and must remain one-shot approvals.' } else { $null }
        invocationRule = 'Use this literal prefix directly. Put the exact profile, mod, and evidence arguments afterward; do not hide the prefix in variables, -Command, pipelines, or a command string.'
    }
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-LiveProcesses([string[]]$Names) {
    $records = @()
    foreach ($name in $Names) {
        foreach ($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            $records += [pscustomobject]@{ name = $process.ProcessName; id = $process.Id }
        }
    }
    return @($records)
}

function Assert-NoReparsePointPath([string]$Path, [string]$Purpose) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    while ($null -ne $item) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Purpose traverses a reparse point and is not qualified for mutation: $($item.FullName)"
        }
        $item = if ($item -is [IO.FileInfo]) { $item.Directory } else { $item.Parent }
    }
}

function Get-ModLineMatches([byte[]]$Bytes, [string]$Name) {
    $text = [Text.Encoding]::UTF8.GetString($Bytes)
    $escaped = [regex]::Escape($Name)
    return [regex]::Matches($text, "(?m)^(?<marker>[+-])(?<name>$escaped)\r?$")
}

function Get-ModLineRecord([byte[]]$Bytes, [string]$Name) {
    $text = [Text.Encoding]::UTF8.GetString($Bytes)
    $matches = @(Get-ModLineMatches -Bytes $Bytes -Name $Name)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one modlist line for '$Name'; found $($matches.Count)."
    }
    $match = $matches[0]
    return [pscustomobject]@{
        marker = $match.Groups['marker'].Value
        enabled = $match.Groups['marker'].Value -eq '+'
        line = $match.Value.TrimEnd("`r")
        byteOffset = [Text.Encoding]::UTF8.GetByteCount($text.Substring(0, $match.Index))
    }
}

function Add-ModLine([byte[]]$Bytes, [string]$Name, [bool]$Enabled, [string]$LinePlacement, [string]$RelativeName) {
    if (@(Get-ModLineMatches -Bytes $Bytes -Name $Name).Count -ne 0) {
        throw "Refusing to register '$Name' because a marker already exists."
    }
    $text = [Text.Encoding]::UTF8.GetString($Bytes)
    $lineBreak = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $markerLine = "$(if ($Enabled) { '+' } else { '-' })$Name"
    if ($LinePlacement -eq 'End') {
        $result = if ($text.Length -eq 0) { "$markerLine$lineBreak" } elseif ($text.EndsWith("`n")) { "$text$markerLine$lineBreak" } else { "$text$lineBreak$markerLine$lineBreak" }
    }
    else {
        if ([string]::IsNullOrWhiteSpace($RelativeName)) {
            throw "-RelativeToMod is required for placement '$LinePlacement'."
        }
        $relativeMatches = @(Get-ModLineMatches -Bytes $Bytes -Name $RelativeName)
        if ($relativeMatches.Count -ne 1) {
            throw "Expected exactly one relative modlist line for '$RelativeName'; found $($relativeMatches.Count)."
        }
        $relative = $relativeMatches[0]
        $lineEnd = $relative.Index + $relative.Length
        if ($lineEnd -lt $text.Length -and $text[$lineEnd] -eq "`n") { $lineEnd++ }
        elseif ($lineEnd -lt $text.Length - 1 -and $text.Substring($lineEnd, 2) -eq "`r`n") { $lineEnd += 2 }
        if ($LinePlacement -eq 'Before') {
            $result = $text.Insert($relative.Index, "$markerLine$lineBreak")
        }
        else {
            $result = $text.Insert($lineEnd, "$markerLine$lineBreak")
        }
    }
    return [Text.Encoding]::UTF8.GetBytes($result)
}

function Remove-ModLine([byte[]]$Bytes, [string]$Name) {
    $text = [Text.Encoding]::UTF8.GetString($Bytes)
    $matches = @(Get-ModLineMatches -Bytes $Bytes -Name $Name)
    if ($matches.Count -ne 1) { throw "Expected exactly one modlist line for '$Name'; found $($matches.Count)." }
    $match = $matches[0]
    $start = $match.Index
    $length = $match.Length
    if ($start + $length -lt $text.Length -and $text[$start + $length] -eq "`n") { $length++ }
    return [Text.Encoding]::UTF8.GetBytes($text.Remove($start, $length))
}

function Get-ModListRecords([byte[]]$Bytes) {
    $text = [Text.Encoding]::UTF8.GetString($Bytes)
    $records = @()
    $lineNumber = 0
    foreach ($line in @($text -split "`r?`n")) {
        $lineNumber++
        if ($line -match '^(?<marker>[+-])(?<name>.+)$') {
            $records += [pscustomobject][ordered]@{ lineNumber = $lineNumber; marker = $Matches.marker; enabled = $Matches.marker -eq '+'; name = $Matches.name }
        }
    }
    return @($records)
}

function Resolve-WinningPlan([byte[]]$Bytes, [string]$TargetName, [string]$TargetDirectory, [string]$ModRoot, [string[]]$Paths) {
    if ([string]::IsNullOrWhiteSpace($ModRoot)) { throw '-ModsDirectory is required for winning-provider operations.' }
    $resolvedRoot = [IO.Path]::GetFullPath($ModRoot)
    $resolvedTarget = [IO.Path]::GetFullPath($TargetDirectory)
    if (-not $resolvedTarget.StartsWith($resolvedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'The target mod is not inside ModsDirectory.' }
    Assert-NoReparsePointPath -Path $resolvedRoot -Purpose 'ModsDirectory'
    Assert-NoReparsePointPath -Path $resolvedTarget -Purpose 'Target mod directory'
    $normalizedPaths = @()
    foreach ($path in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($path) -or [IO.Path]::IsPathRooted($path)) { throw 'WinningPaths must contain non-rooted relative file paths.' }
        $normalized = $path.Replace('/', [IO.Path]::DirectorySeparatorChar).TrimStart([IO.Path]::DirectorySeparatorChar)
        $targetFile = [IO.Path]::GetFullPath((Join-Path $resolvedTarget $normalized))
        if (-not $targetFile.StartsWith($resolvedTarget + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "Winning path escapes the target mod: $path" }
        if (-not (Test-Path -LiteralPath $targetFile -PathType Leaf)) { throw "The target mod does not provide required winning path: $normalized" }
        if ($normalizedPaths -inotcontains $normalized) { $normalizedPaths += $normalized }
    }
    if ($normalizedPaths.Count -eq 0) { throw 'At least one WinningPaths entry is required.' }
    $providers = @()
    foreach ($record in @(Get-ModListRecords -Bytes $Bytes | Where-Object { $_.enabled -and $_.name -cne $TargetName })) {
        $providerRoot = [IO.Path]::GetFullPath((Join-Path $resolvedRoot ([string]$record.name)))
        if (-not $providerRoot.StartsWith($resolvedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $providerRoot -PathType Container)) { continue }
        Assert-NoReparsePointPath -Path $providerRoot -Purpose "Enabled provider '$($record.name)'"
        foreach ($path in $normalizedPaths) {
            $providerFile = [IO.Path]::GetFullPath((Join-Path $providerRoot $path))
            if ($providerFile.StartsWith($providerRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $providerFile -PathType Leaf)) {
                $providers += [pscustomobject][ordered]@{ path = $path; modName = [string]$record.name; lineNumber = [int]$record.lineNumber; filePath = $providerFile; sha256 = (Get-FileHash -LiteralPath $providerFile -Algorithm SHA256).Hash }
            }
        }
    }
    $earliest = @($providers | Sort-Object lineNumber | Select-Object -First 1)
    return [pscustomobject][ordered]@{
        relativePaths = $normalizedPaths
        otherEnabledProviders = @($providers | Sort-Object path, lineNumber)
        placeBeforeMod = if ($earliest.Count -eq 1) { [string]$earliest[0].modName } else { $null }
        scopeNote = 'Winner proof covers enabled loose-file providers registered in this exact modlist. MO2 overwrite, unmanaged game files, and archives require separate VFS evidence.'
    }
}

function Test-WinningPostcondition([byte[]]$Bytes, [string]$TargetName, [string]$TargetDirectory, [string]$ModRoot, [string[]]$Paths) {
    $target = Get-ModListRecords -Bytes $Bytes | Where-Object { $_.name -ceq $TargetName }
    if (@($target).Count -ne 1 -or -not @($target)[0].enabled) { throw "Winning target '$TargetName' is not enabled exactly once." }
    $plan = Resolve-WinningPlan -Bytes $Bytes -TargetName $TargetName -TargetDirectory $TargetDirectory -ModRoot $ModRoot -Paths $Paths
    $targetLine = [int]@($target)[0].lineNumber
    $losing = @($plan.otherEnabledProviders | Where-Object { [int]$_.lineNumber -lt $targetLine })
    if ($losing.Count -gt 0) { throw "Winning postcondition failed; an enabled provider precedes '$TargetName': $($losing.modName -join ', ')." }
    return [pscustomobject][ordered]@{ verified = $true; targetLineNumber = $targetLine; relativePaths = $plan.relativePaths; displacedProviders = $plan.otherEnabledProviders; scopeNote = $plan.scopeNote }
}

function Write-BytesAtomically([string]$Path, [byte[]]$Bytes) {
    $directory = Split-Path -Parent $Path
    $temporary = Join-Path $directory ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllBytes($temporary, $Bytes)
        [IO.File]::Move($temporary, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Get-BytesSha256([byte[]]$Bytes) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToHexString($algorithm.ComputeHash($Bytes)) }
    finally { $algorithm.Dispose() }
}

function Write-ProfileJsonAtomic([string]$Path, $Value) {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 12))
    Write-BytesAtomically -Path $Path -Bytes $bytes
}

function Invoke-WithProfileTransactionLock([string]$Path, [scriptblock]$Action, [int]$TimeoutMilliseconds = $TransactionLockTimeoutMilliseconds) {
    $lockPath = "$Path.transaction.lock"
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    $stream = $null
    while ($null -eq $stream) {
        try {
            $stream = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        }
        catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { throw "Timed out waiting for the profile transaction lock: $lockPath" }
            Start-Sleep -Milliseconds 50
        }
    }
    try { return & $Action }
    finally { $stream.Dispose() }
}

function Invoke-ProfileMutationTransaction {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][byte[]]$ExpectedBeforeBytes,
        [Parameter(Mandatory)][byte[]]$AfterBytes,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [Parameter(Mandatory)][string]$BackupPath,
        [Parameter(Mandatory)][string]$ReceiptPath,
        [Parameter(Mandatory)]$Receipt,
        [Parameter(Mandatory)][scriptblock]$Postcondition
    )

    $expectedBeforeHash = Get-BytesSha256 $ExpectedBeforeBytes
    $expectedAfterHash = Get-BytesSha256 $AfterBytes
    return Invoke-WithProfileTransactionLock -Path $Path -Action {
        if (-not (Test-Path -LiteralPath $EvidenceRoot -PathType Container)) { New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null }
        if (Test-Path -LiteralPath $BackupPath -PathType Leaf) { throw "Refusing to overwrite an existing exact backup: $BackupPath" }
        if (Test-Path -LiteralPath $ReceiptPath -PathType Leaf) { throw "Refusing to overwrite an existing transaction receipt: $ReceiptPath" }

        $currentHash = Get-Sha256 $Path
        if ($currentHash -cne $expectedBeforeHash) { throw 'The profile changed after planning and before commit; no live bytes were written.' }

        $transactionId = [guid]::NewGuid().ToString('N')
        $journalPath = Join-Path $EvidenceRoot "modlist-control.$transactionId.journal.json"
        $journal = [pscustomobject][ordered]@{
            contractVersion = '2.0.0'; transactionId = $transactionId; operation = [string]$Receipt.operation
            phase = 'preparing'; profilePath = $Path; backupPath = $BackupPath; receiptPath = $ReceiptPath
            beforeSha256 = $expectedBeforeHash; intendedSha256 = $expectedAfterHash
            preparedUtc = [DateTime]::UtcNow.ToString('o'); liveWriteStartedUtc = $null; committedUtc = $null
            rollback = $null
        }
        [IO.File]::WriteAllBytes($BackupPath, $ExpectedBeforeBytes)
        if ((Get-Sha256 $BackupPath) -cne $expectedBeforeHash) { throw 'Exact backup verification failed before profile mutation.' }
        $journal.phase = 'prepared'
        Write-ProfileJsonAtomic -Path $journalPath -Value $journal

        $liveWritten = $false
        try {
            $journal.phase = 'writing-live'
            $journal.liveWriteStartedUtc = [DateTime]::UtcNow.ToString('o')
            Write-ProfileJsonAtomic -Path $journalPath -Value $journal
            Write-BytesAtomically -Path $Path -Bytes $AfterBytes
            $liveWritten = $true
            if ((Get-Sha256 $Path) -cne $expectedAfterHash) { throw 'Atomic profile replacement did not produce the intended hash.' }
            $postconditionResult = & $Postcondition ([IO.File]::ReadAllBytes($Path))

            $Receipt | Add-Member -NotePropertyName contractVersion -NotePropertyValue '2.0.0' -Force
            $Receipt | Add-Member -NotePropertyName transactionId -NotePropertyValue $transactionId -Force
            $Receipt | Add-Member -NotePropertyName transactionJournalPath -NotePropertyValue $journalPath -Force
            $Receipt | Add-Member -NotePropertyName backupPath -NotePropertyValue $BackupPath -Force
            $Receipt | Add-Member -NotePropertyName beforeSha256 -NotePropertyValue $expectedBeforeHash -Force
            $Receipt | Add-Member -NotePropertyName resultSha256 -NotePropertyValue $expectedAfterHash -Force
            $Receipt | Add-Member -NotePropertyName changedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
            if ($null -ne $postconditionResult) { $Receipt | Add-Member -NotePropertyName postcondition -NotePropertyValue $postconditionResult -Force }
            Write-ProfileJsonAtomic -Path $ReceiptPath -Value $Receipt
            if (-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) { throw 'Durable profile receipt was not created.' }

            $journal.phase = 'committed'
            $journal.committedUtc = [DateTime]::UtcNow.ToString('o')
            Write-ProfileJsonAtomic -Path $journalPath -Value $journal
            return [pscustomobject]@{ receipt = $Receipt; journalPath = $journalPath; transactionId = $transactionId }
        }
        catch {
            $failure = $_.Exception.Message
            $rollbackOk = $true
            $rollbackError = $null
            if ($liveWritten) {
                try {
                    Write-BytesAtomically -Path $Path -Bytes $ExpectedBeforeBytes
                    $rollbackOk = (Get-Sha256 $Path) -ceq $expectedBeforeHash
                    if (-not $rollbackOk) { $rollbackError = 'Rollback hash verification failed.' }
                }
                catch { $rollbackOk = $false; $rollbackError = $_.Exception.Message }
            }
            $journal.phase = if ($rollbackOk) { 'rolled-back' } else { 'recovery-required' }
            $journal.rollback = [pscustomobject][ordered]@{ attempted = $liveWritten; verified = $rollbackOk; error = $rollbackError; completedUtc = [DateTime]::UtcNow.ToString('o') }
            try { Write-ProfileJsonAtomic -Path $journalPath -Value $journal } catch { $rollbackError = "${rollbackError}; journal: $($_.Exception.Message)" }
            if (-not $rollbackOk) { throw "Profile transaction failed and rollback requires recovery. $failure Rollback: $rollbackError" }
            throw "Profile transaction failed; exact preimage restored. $failure"
        }
    }
}

function Invoke-ProfileRestoreTransaction {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][byte[]]$CurrentBytes,
        [Parameter(Mandatory)][byte[]]$RestoreBytes,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [Parameter(Mandatory)][string]$ExpectedCurrentHash,
        [Parameter(Mandatory)][string]$ExpectedRestoreHash
    )

    return Invoke-WithProfileTransactionLock -Path $Path -Action {
        if ((Get-Sha256 $Path) -cne $ExpectedCurrentHash) { throw 'Current modlist changed before restore commit; no live bytes were written.' }
        $transactionId = [guid]::NewGuid().ToString('N')
        $preimagePath = Join-Path $EvidenceRoot "modlist.restore-before.$transactionId.bin"
        $journalPath = Join-Path $EvidenceRoot "modlist-restore.$transactionId.journal.json"
        [IO.File]::WriteAllBytes($preimagePath, $CurrentBytes)
        $journal = [pscustomobject][ordered]@{
            contractVersion = '2.0.0'; transactionId = $transactionId; operation = 'restore'; phase = 'prepared'
            profilePath = $Path; preimagePath = $preimagePath; beforeSha256 = $ExpectedCurrentHash; intendedSha256 = $ExpectedRestoreHash
            preparedUtc = [DateTime]::UtcNow.ToString('o'); committedUtc = $null; rollback = $null
        }
        Write-ProfileJsonAtomic -Path $journalPath -Value $journal
        $liveWritten = $false
        try {
            Write-BytesAtomically -Path $Path -Bytes $RestoreBytes
            $liveWritten = $true
            if ((Get-Sha256 $Path) -cne $ExpectedRestoreHash) { throw 'Restore postcondition hash failed.' }
            $journal.phase = 'committed'; $journal.committedUtc = [DateTime]::UtcNow.ToString('o')
            Write-ProfileJsonAtomic -Path $journalPath -Value $journal
            return [pscustomobject]@{ journalPath = $journalPath; transactionId = $transactionId }
        }
        catch {
            $failure = $_.Exception.Message; $rollbackOk = $true; $rollbackError = $null
            if ($liveWritten) {
                try {
                    Write-BytesAtomically -Path $Path -Bytes $CurrentBytes
                    $rollbackOk = (Get-Sha256 $Path) -ceq $ExpectedCurrentHash
                    if (-not $rollbackOk) { $rollbackError = 'Restore rollback hash verification failed.' }
                }
                catch { $rollbackOk = $false; $rollbackError = $_.Exception.Message }
            }
            $journal.phase = if ($rollbackOk) { 'rolled-back' } else { 'recovery-required' }
            $journal.rollback = [pscustomobject][ordered]@{ attempted = $liveWritten; verified = $rollbackOk; error = $rollbackError; completedUtc = [DateTime]::UtcNow.ToString('o') }
            try { Write-ProfileJsonAtomic -Path $journalPath -Value $journal } catch { }
            if (-not $rollbackOk) { throw "Profile restore failed and rollback requires recovery. $failure Rollback: $rollbackError" }
            throw "Profile restore failed; exact preimage restored. $failure"
        }
    }
}

function Test-ProfileShouldProcess($Caller, [string]$Target, [string]$Action) {
    try {
        return $Caller.ShouldProcess($Target, $Action)
    }
    catch {
        throw "PowerShell's interactive confirmation host is unavailable. Use -WhatIf to preview or -Confirm:`$false for an already-authorized automation transaction. Original error: $($_.Exception.Message)"
    }
}

$resolvedInput = [IO.Path]::GetFullPath($ProfilePath)
if (Test-Path -LiteralPath $resolvedInput -PathType Container) {
    $profileDirectory = $resolvedInput.TrimEnd([IO.Path]::DirectorySeparatorChar)
    $resolvedProfile = Join-Path $profileDirectory 'modlist.txt'
}
else {
    $resolvedProfile = $resolvedInput
    $profileDirectory = Split-Path -Parent $resolvedProfile
}
if (-not (Test-Path -LiteralPath $resolvedProfile -PathType Leaf)) {
    throw "Profile modlist does not exist. Pass either the profile directory or its modlist.txt: $resolvedProfile"
}
Assert-NoReparsePointPath -Path $resolvedProfile -Purpose 'Profile modlist'
$profileName = [IO.Path]::GetFileName($profileDirectory)

$beforeBytes = [IO.File]::ReadAllBytes($resolvedProfile)
$beforeMatches = @(Get-ModLineMatches -Bytes $beforeBytes -Name $ModName)
$beforeLine = if ($beforeMatches.Count -eq 1) { Get-ModLineRecord -Bytes $beforeBytes -Name $ModName } else { $null }
$beforeHash = Get-Sha256 $resolvedProfile
$processes = @(Get-LiveProcesses -Names $BlockingProcessNames)

if ($Command -eq 'inspect') {
    if ($beforeMatches.Count -ne 1) { throw "Expected exactly one modlist line for '$ModName'; found $($beforeMatches.Count)." }
    $inspectResult = [pscustomobject][ordered]@{
        ok = $true
        command = $Command
        profilePath = $resolvedProfile
        profileName = $profileName
        profileDirectory = $profileDirectory
        modListPath = $resolvedProfile
        modName = $ModName
        enabled = $beforeLine.enabled
        marker = $beforeLine.marker
        sha256 = $beforeHash
        processes = $processes
        approval = New-ProfileApprovalMetadata -Subcommand $Command
    }
    $jsonParameters = @{ InputObject = $inspectResult; Depth = 7 }
    if ($Compact) { $jsonParameters['Compress'] = $true }
    ConvertTo-Json @jsonParameters
    return
}

if ($processes.Count -gt 0) {
    throw "MO2 profile mutation requires MO2 and Skyrim to be closed. Active: $($processes.name -join ', ')."
}
if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    throw '-EvidenceDirectory is required for every profile mutation and restore.'
}

$resolvedEvidence = [IO.Path]::GetFullPath($EvidenceDirectory)
$backupPath = Join-Path $resolvedEvidence 'modlist.before.bin'
$receiptPath = Join-Path $resolvedEvidence 'modlist-control.receipt.json'

if ($Command -in @('register', 'register-winning')) {
    if ($beforeMatches.Count -ne 0) {
        throw "Registration requires no existing marker for '$ModName'; found $($beforeMatches.Count)."
    }
    if ([string]::IsNullOrWhiteSpace($ModDirectory)) { throw '-ModDirectory is required for register.' }
    $resolvedModDirectory = [IO.Path]::GetFullPath($ModDirectory)
    if (-not (Test-Path -LiteralPath $resolvedModDirectory -PathType Container)) { throw "Deployed mod directory does not exist: $resolvedModDirectory" }
    if ([IO.Path]::GetFileName($resolvedModDirectory) -cne $ModName) { throw "The deployed mod directory name must exactly match ModName ('$ModName')." }
    if (Test-Path -LiteralPath $backupPath -PathType Leaf) { throw "Refusing to overwrite an existing exact backup: $backupPath" }
    $winningPlan = $null
    if ($Command -eq 'register-winning') {
        $winningPlan = Resolve-WinningPlan -Bytes $beforeBytes -TargetName $ModName -TargetDirectory $resolvedModDirectory -ModRoot $ModsDirectory -Paths $WinningPaths
        $effectivePlacement = if ([string]::IsNullOrWhiteSpace([string]$winningPlan.placeBeforeMod)) { 'End' } else { 'Before' }
        $effectiveRelative = [string]$winningPlan.placeBeforeMod
        $afterBytes = Add-ModLine -Bytes $beforeBytes -Name $ModName -Enabled $true -LinePlacement $effectivePlacement -RelativeName $effectiveRelative
    }
    else {
        $effectivePlacement = $Placement
        $effectiveRelative = $RelativeToMod
        $afterBytes = Add-ModLine -Bytes $beforeBytes -Name $ModName -Enabled ([bool]$RegisterEnabled) -LinePlacement $Placement -RelativeName $RelativeToMod
    }
    if (Test-ProfileShouldProcess -Caller $PSCmdlet -Target $resolvedProfile -Action "$Command exact MO2 mod '$ModName' at $effectivePlacement") {
        $afterLine = Get-ModLineRecord -Bytes $afterBytes -Name $ModName
        $winnerProof = if ($Command -eq 'register-winning') { Test-WinningPostcondition -Bytes $afterBytes -TargetName $ModName -TargetDirectory $resolvedModDirectory -ModRoot $ModsDirectory -Paths $WinningPaths } else { $null }
        $receipt = [pscustomobject][ordered]@{
            operation = $Command; profilePath = $resolvedProfile
            profileName = $profileName; profileDirectory = $profileDirectory; modListPath = $resolvedProfile
            modName = $ModName; modDirectory = $resolvedModDirectory; beforeMarker = $null
            resultMarker = $afterLine.marker; placement = $effectivePlacement; relativeToMod = $effectiveRelative
            winnerProof = $winnerProof; providerPlan = $winningPlan
        }
        $postcondition = {
            param([byte[]]$liveBytes)
            $line = Get-ModLineRecord -Bytes $liveBytes -Name $ModName
            if ($line.marker -cne $afterLine.marker) { throw 'Registration marker postcondition failed.' }
            if ($Command -eq 'register-winning') { return Test-WinningPostcondition -Bytes $liveBytes -TargetName $ModName -TargetDirectory $resolvedModDirectory -ModRoot $ModsDirectory -Paths $WinningPaths }
            return [pscustomobject]@{ verified = $true; marker = $line.marker }
        }
        $null = Invoke-ProfileMutationTransaction -Path $resolvedProfile -ExpectedBeforeBytes $beforeBytes -AfterBytes $afterBytes -EvidenceRoot $resolvedEvidence -BackupPath $backupPath -ReceiptPath $receiptPath -Receipt $receipt -Postcondition $postcondition
    }
}
elseif ($Command -eq 'ensure-winner') {
    if ($beforeMatches.Count -ne 1) { throw "Expected exactly one modlist line for '$ModName'; found $($beforeMatches.Count)." }
    if ([string]::IsNullOrWhiteSpace($ModDirectory)) { throw '-ModDirectory is required for ensure-winner.' }
    $resolvedModDirectory = [IO.Path]::GetFullPath($ModDirectory)
    $withoutTarget = Remove-ModLine -Bytes $beforeBytes -Name $ModName
    $winningPlan = Resolve-WinningPlan -Bytes $withoutTarget -TargetName $ModName -TargetDirectory $resolvedModDirectory -ModRoot $ModsDirectory -Paths $WinningPaths
    $effectivePlacement = if ([string]::IsNullOrWhiteSpace([string]$winningPlan.placeBeforeMod)) { 'End' } else { 'Before' }
    $effectiveRelative = [string]$winningPlan.placeBeforeMod
    $afterBytes = Add-ModLine -Bytes $withoutTarget -Name $ModName -Enabled $true -LinePlacement $effectivePlacement -RelativeName $effectiveRelative
    if (Test-ProfileShouldProcess -Caller $PSCmdlet -Target $resolvedProfile -Action "enable and place '$ModName' before every enabled loose-file provider") {
        $winnerProof = Test-WinningPostcondition -Bytes $afterBytes -TargetName $ModName -TargetDirectory $resolvedModDirectory -ModRoot $ModsDirectory -Paths $WinningPaths
        $receipt = [pscustomobject][ordered]@{
            operation = 'ensure-winner'; profilePath = $resolvedProfile
            profileName = $profileName; profileDirectory = $profileDirectory; modListPath = $resolvedProfile
            modName = $ModName; modDirectory = $resolvedModDirectory; beforeMarker = $beforeLine.marker
            resultMarker = '+'; placement = $effectivePlacement; relativeToMod = $effectiveRelative
            winnerProof = $winnerProof; providerPlan = $winningPlan
        }
        $postcondition = { param([byte[]]$liveBytes) Test-WinningPostcondition -Bytes $liveBytes -TargetName $ModName -TargetDirectory $resolvedModDirectory -ModRoot $ModsDirectory -Paths $WinningPaths }
        $null = Invoke-ProfileMutationTransaction -Path $resolvedProfile -ExpectedBeforeBytes $beforeBytes -AfterBytes $afterBytes -EvidenceRoot $resolvedEvidence -BackupPath $backupPath -ReceiptPath $receiptPath -Receipt $receipt -Postcondition $postcondition
    }
}
elseif ($Command -in @('enable', 'disable')) {
    if ($beforeMatches.Count -ne 1) { throw "Expected exactly one modlist line for '$ModName'; found $($beforeMatches.Count)." }
    $targetEnabled = $Command -eq 'enable'
    if ($beforeLine.enabled -eq $targetEnabled) {
        throw "The exact mod is already $($targetEnabled ? 'enabled' : 'disabled'): $ModName"
    }
    if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
        throw "Refusing to overwrite an existing exact backup: $backupPath"
    }

    $afterBytes = [byte[]]::new($beforeBytes.Length)
    [Array]::Copy($beforeBytes, $afterBytes, $beforeBytes.Length)
    $expectedMarker = if ($targetEnabled) { '-' } else { '+' }
    $targetMarker = if ($targetEnabled) { '+' } else { '-' }
    if ($afterBytes[$beforeLine.byteOffset] -ne [byte][char]$expectedMarker) {
        throw "The calculated marker byte is not the expected '$expectedMarker' sign."
    }
    $afterBytes[$beforeLine.byteOffset] = [byte][char]$targetMarker

    if (Test-ProfileShouldProcess -Caller $PSCmdlet -Target $resolvedProfile -Action "$Command exact MO2 mod '$ModName'") {
        $receipt = [pscustomobject][ordered]@{
            operation = $Command
            profilePath = $resolvedProfile
            profileName = $profileName
            profileDirectory = $profileDirectory
            modListPath = $resolvedProfile
            modName = $ModName
            beforeMarker = $expectedMarker
            resultMarker = $targetMarker
        }
        $postcondition = {
            param([byte[]]$liveBytes)
            $line = Get-ModLineRecord -Bytes $liveBytes -Name $ModName
            if ($line.enabled -ne $targetEnabled -or (Get-BytesSha256 $liveBytes) -ceq $beforeHash) {
                $targetState = if ($targetEnabled) { 'enabled' } else { 'disabled' }
                throw "Postcondition failed: exact mod was not $targetState."
            }
            return [pscustomobject]@{ verified = $true; enabled = $line.enabled; marker = $line.marker }
        }
        $null = Invoke-ProfileMutationTransaction -Path $resolvedProfile -ExpectedBeforeBytes $beforeBytes -AfterBytes $afterBytes -EvidenceRoot $resolvedEvidence -BackupPath $backupPath -ReceiptPath $receiptPath -Receipt $receipt -Postcondition $postcondition
    }
}
elseif ($Command -eq 'restore') {
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf) -or -not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
        throw 'The exact backup and receipt are both required for restoration.'
    }
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    if ([string]$receipt.profilePath -ne $resolvedProfile -or [string]$receipt.modName -ne $ModName) {
        throw 'Receipt ownership does not match the requested profile and mod.'
    }
    if ((Get-Sha256 $backupPath) -ne [string]$receipt.beforeSha256) {
        throw 'Exact backup hash does not match its receipt.'
    }
    $resultHashProperty = $receipt.PSObject.Properties['resultSha256']
    $legacyHashProperty = $receipt.PSObject.Properties['disabledSha256']
    $expectedResultHash = if ($resultHashProperty) {
        [string]$resultHashProperty.Value
    }
    elseif ($legacyHashProperty) {
        [string]$legacyHashProperty.Value
    }
    else {
        throw 'Receipt does not contain a recognized result hash.'
    }
    if ($beforeHash -ne $expectedResultHash) {
        throw 'Current modlist differs from the state produced by this control; refusing to overwrite it.'
    }
    $restoreBytes = [IO.File]::ReadAllBytes($backupPath)
    if (Test-ProfileShouldProcess -Caller $PSCmdlet -Target $resolvedProfile -Action "Restore exact MO2 modlist bytes for '$ModName'") {
        $null = Invoke-ProfileRestoreTransaction -Path $resolvedProfile -CurrentBytes $beforeBytes -RestoreBytes $restoreBytes -EvidenceRoot $resolvedEvidence -ExpectedCurrentHash $expectedResultHash -ExpectedRestoreHash ([string]$receipt.beforeSha256)
    }
}

$finalBytes = [IO.File]::ReadAllBytes($resolvedProfile)
$finalMatches = @(Get-ModLineMatches -Bytes $finalBytes -Name $ModName)
$finalLine = if ($finalMatches.Count -eq 1) { Get-ModLineRecord -Bytes $finalBytes -Name $ModName } else { $null }
$finalResult = [pscustomobject][ordered]@{
    ok = $true
    command = $Command
    whatIf = [bool]$WhatIfPreference
    profilePath = $resolvedProfile
    profileName = $profileName
    profileDirectory = $profileDirectory
    modListPath = $resolvedProfile
    modName = $ModName
    enabled = if ($finalLine) { $finalLine.enabled } else { $null }
    marker = if ($finalLine) { $finalLine.marker } else { $null }
    sha256 = Get-Sha256 $resolvedProfile
    backupPath = $backupPath
    receiptPath = $receiptPath
    approval = New-ProfileApprovalMetadata -Subcommand $Command
}
$jsonParameters = @{ InputObject = $finalResult; Depth = 7 }
if ($Compact) { $jsonParameters['Compress'] = $true }
ConvertTo-Json @jsonParameters
