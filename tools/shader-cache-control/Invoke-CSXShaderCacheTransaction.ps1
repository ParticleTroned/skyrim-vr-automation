# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('inspect', 'providers', 'snapshot', 'verify', 'seed', 'restore')]
    [string]$Command,

    [string]$CachePath,

    [string]$EvidenceDirectory,

    [string]$SourceCachePath,

    [string]$ExpectedSourceTreeSha256,

    [string]$ShaderCacheAbiOverride,

    [string]$CompatibilityReason,

    [string]$ProfilePath,

    [string]$ModsPath,

    [string]$RelativeCachePath = 'ShaderCache',

    [ValidateRange(1, 1000000)]
    [int]$MaxInventoryFiles = 20000,

    [ValidateRange(1, [long]::MaxValue)]
    [long]$MaxInventoryBytes = 21474836480,

    [ValidateRange(1, 128)]
    [int]$MaxInventoryDepth = 24,

    [ValidateRange(1, 3600)]
    [int]$InventoryTimeoutSeconds = 120,

    [ValidateNotNullOrEmpty()]
    [string[]]$BlockingProcessNames = @('ModOrganizer', 'SkyrimVR', 'sksevr_loader'),

    [switch]$DeepInventory,

    [ValidateSet('', 'seed-after-activate', 'restore-after-activate')]
    [string]$InternalTestFailurePoint = '',

    [switch]$NoExit,

    [switch]$Compact
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LiveProcesses([string[]]$Names) {
    $records = @()
    foreach ($name in $Names) {
        foreach ($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            $records += [pscustomobject][ordered]@{ name = $process.ProcessName; id = $process.Id }
        }
    }
    return @($records)
}

function Assert-SafeCachePath([string]$Path) {
    $resolved = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($resolved)
    if ([string]::IsNullOrWhiteSpace($resolved) -or $resolved -eq $root) {
        throw "Refusing a filesystem root as a shader-cache target: $resolved"
    }
    if ([IO.Path]::GetFileName($resolved) -ne [IO.Path]::GetFileName($RelativeCachePath)) {
        throw "CachePath must end in the exact relative cache leaf '$RelativeCachePath': $resolved"
    }
    return $resolved
}

function Assert-SafeSourcePath([string]$Path) {
    $resolved = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($resolved)
    if ([string]::IsNullOrWhiteSpace($resolved) -or $resolved -eq $root) {
        throw "Refusing a filesystem root as a shader-cache seed source: $resolved"
    }
    return $resolved
}

function Assert-NoCacheReparsePoint([string]$Path, [string]$Purpose) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    while ($null -ne $item) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Purpose traverses a reparse point: $($item.FullName)" }
        $item = if ($item -is [IO.FileInfo]) { $item.Directory } else { $item.Parent }
    }
}

function Get-TreeInventory([string]$Root) {
    $resolved = [IO.Path]::GetFullPath($Root)
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        throw "Shader-cache root is not a directory: $resolved"
    }
    Assert-NoCacheReparsePoint -Path $resolved -Purpose 'Shader-cache inventory root'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $pending = [Collections.Generic.Queue[object]]::new()
    $pending.Enqueue([pscustomobject]@{ path = $resolved; depth = 0 })
    $files = [Collections.Generic.List[object]]::new()
    $totalBytes = [long]0
    while ($pending.Count -gt 0) {
        if ($timer.Elapsed.TotalSeconds -gt $InventoryTimeoutSeconds) { throw "Shader-cache inventory exceeded its $InventoryTimeoutSeconds second bound." }
        $directory = $pending.Dequeue()
        foreach ($item in @(Get-ChildItem -LiteralPath ([string]$directory.path) -Force)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Shader-cache inventory encountered a reparse point: $($item.FullName)" }
            if ($item.PSIsContainer) {
                $nextDepth = [int]$directory.depth + 1
                if ($nextDepth -gt $MaxInventoryDepth) { throw "Shader-cache inventory exceeded its depth bound of $MaxInventoryDepth." }
                $pending.Enqueue([pscustomobject]@{ path = $item.FullName; depth = $nextDepth })
                continue
            }
            if ($files.Count + 1 -gt $MaxInventoryFiles) { throw "Shader-cache inventory exceeded its file-count bound of $MaxInventoryFiles." }
            $totalBytes += [long]$item.Length
            if ($totalBytes -gt $MaxInventoryBytes) { throw "Shader-cache inventory exceeded its byte bound of $MaxInventoryBytes." }
            $files.Add([pscustomobject][ordered]@{
                relativePath = [IO.Path]::GetRelativePath($resolved, $item.FullName).Replace('/', '\')
                bytes = [long]$item.Length
                sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
            })
        }
    }
    $files = @($files | Sort-Object relativePath)
    $canonical = ($files | ForEach-Object { '{0}|{1}|{2}' -f $_.relativePath, $_.bytes, $_.sha256 }) -join "`n"
    $treeHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical)))
    return [pscustomobject][ordered]@{
        root = $resolved
        files = $files.Count
        bytes = $totalBytes
        treeSha256 = $treeHash
        entries = $files
    }
}

function Get-FileInventory([string]$Path) {
    $resolved = [IO.Path]::GetFullPath($Path)
    $file = Get-Item -LiteralPath $resolved -ErrorAction Stop
    $sha256 = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash
    return [pscustomobject][ordered]@{
        root = $resolved
        files = 1
        bytes = [long]$file.Length
        treeSha256 = $sha256
        entries = @([pscustomobject][ordered]@{
            relativePath = [IO.Path]::GetFileName($resolved)
            bytes = [long]$file.Length
            sha256 = $sha256
        })
    }
}

function Write-JsonFile([string]$Path, $Value) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally { if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force } }
}

function Invoke-CacheSwapRollback([string]$LivePath, [string]$DisplacedPath, [string]$ExpectedOriginalHash, [string]$EvidenceRoot, $Journal, [string]$JournalPath, [string]$FailureMessage) {
    $rollbackErrors = @()
    $failedReplacement = Join-Path (Split-Path -Parent $LivePath) ('.' + (Split-Path -Leaf $LivePath) + '.failed.' + [guid]::NewGuid().ToString('N'))
    try {
        if (Test-Path -LiteralPath $LivePath -PathType Container) { Move-Item -LiteralPath $LivePath -Destination $failedReplacement -ErrorAction Stop }
    }
    catch { $rollbackErrors += "replacement-quarantine: $($_.Exception.Message)" }
    try {
        if (-not (Test-Path -LiteralPath $DisplacedPath -PathType Container)) { throw 'The exact displaced original is missing.' }
        if (Test-Path -LiteralPath $LivePath) { throw 'The live path remains occupied after replacement quarantine.' }
        Move-Item -LiteralPath $DisplacedPath -Destination $LivePath -ErrorAction Stop
        $restored = Get-TreeInventory $LivePath
        if ([string]$restored.treeSha256 -cne $ExpectedOriginalHash) { throw "Restored tree hash differs: $($restored.treeSha256)" }
    }
    catch { $rollbackErrors += "original-restore: $($_.Exception.Message)" }
    if (Test-Path -LiteralPath $failedReplacement -PathType Container) {
        try { Assert-NoCacheReparsePoint -Path $failedReplacement -Purpose 'Failed shader-cache replacement'; Remove-Item -LiteralPath $failedReplacement -Recurse -Force -ErrorAction Stop }
        catch { $rollbackErrors += "failed-replacement-cleanup: $($_.Exception.Message)" }
    }
    $Journal.phase = if ($rollbackErrors.Count -eq 0) { 'rolled-back' } else { 'recovery-required' }
    $Journal | Add-Member -NotePropertyName rollback -NotePropertyValue ([pscustomobject]@{ verified = $rollbackErrors.Count -eq 0; errors = $rollbackErrors; completedUtc = [DateTime]::UtcNow.ToString('o') }) -Force
    try { Write-JsonFile $JournalPath $Journal } catch { $rollbackErrors += "journal: $($_.Exception.Message)" }
    if ($rollbackErrors.Count -gt 0) { throw "$FailureMessage Rollback requires recovery: $($rollbackErrors -join '; ')" }
    throw "$FailureMessage The exact original cache was restored and verified."
}

function Set-IniValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value
    )

    $lines = [Collections.Generic.List[string]]::new()
    foreach ($line in @(Get-Content -LiteralPath $Path)) { $lines.Add([string]$line) }
    $sectionPattern = '^\s*\[' + [regex]::Escape($Section) + '\]\s*$'
    $keyPattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    $sectionStart = -1
    $sectionEnd = $lines.Count
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $sectionPattern) {
            $sectionStart = $i
            for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                if ($lines[$j] -match '^\s*\[.+\]\s*$') { $sectionEnd = $j; break }
            }
            break
        }
    }
    if ($sectionStart -lt 0) { throw "INI section [$Section] is missing: $Path" }

    $keyIndexes = @()
    for ($i = $sectionStart + 1; $i -lt $sectionEnd; $i++) {
        if ($lines[$i] -match $keyPattern) { $keyIndexes += $i }
    }
    if ($keyIndexes.Count -ne 1) {
        throw "Expected exactly one '$Key' entry in [$Section], found $($keyIndexes.Count): $Path"
    }
    $previous = (($lines[$keyIndexes[0]] -split '=', 2)[1]).Trim()
    $lines[$keyIndexes[0]] = "$Key = $Value"
    [IO.File]::WriteAllLines($Path, $lines, [Text.UTF8Encoding]::new($false))
    return $previous
}

function Get-ProviderMetadata([string]$ModRoot) {
    $records = @()
    foreach ($relative in @('Info.ini', 'CSX.BuildManifest.json', 'ShaderCacheManifest.json')) {
        $path = Join-Path $ModRoot $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $record = [ordered]@{
            relativePath = $relative
            bytes = [long](Get-Item -LiteralPath $path).Length
            sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        }
        if ([IO.Path]::GetExtension($path) -eq '.json') {
            try { $record['json'] = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 30 } catch { $record['parseError'] = $_.Exception.Message }
        }
        else {
            $record['lines'] = @(Get-Content -LiteralPath $path | Where-Object { $_ -match '^\s*[^;#\[].*=.*$' })
        }
        $records += [pscustomobject]$record
    }
    return @($records)
}

function Get-Providers {
    if ([string]::IsNullOrWhiteSpace($ProfilePath) -or [string]::IsNullOrWhiteSpace($ModsPath)) {
        throw 'providers requires both -ProfilePath and -ModsPath.'
    }
    $resolvedProfile = [IO.Path]::GetFullPath($ProfilePath)
    $resolvedMods = [IO.Path]::GetFullPath($ModsPath)
    if (-not (Test-Path -LiteralPath $resolvedProfile -PathType Leaf)) { throw "MO2 modlist does not exist: $resolvedProfile" }
    if (-not (Test-Path -LiteralPath $resolvedMods -PathType Container)) { throw "MO2 mods root does not exist: $resolvedMods" }
    $providers = @()
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $resolvedProfile) {
        $lineNumber++
        if ($line -notmatch '^(?<marker>[+-])(?<name>.+)$') { continue }
        $marker = $Matches.marker
        $modName = $Matches.name.TrimEnd("`r")
        $modRoot = Join-Path $resolvedMods $modName
        $providerPath = Join-Path $modRoot $RelativeCachePath
        if (-not (Test-Path -LiteralPath $providerPath)) { continue }
        $providerType = if (Test-Path -LiteralPath $providerPath -PathType Container) { 'directory' } else { 'file' }
        $inventory = if (-not $DeepInventory) {
            $null
        }
        elseif ($providerType -eq 'directory') {
            Get-TreeInventory $providerPath
        }
        else {
            Get-FileInventory $providerPath
        }
        $providers += [pscustomobject][ordered]@{
            lineNumber = $lineNumber
            marker = $marker
            enabled = $marker -eq '+'
            modName = $modName
            modRoot = $modRoot
            cachePath = $providerPath
            providerPath = $providerPath
            providerType = $providerType
            inventory = $inventory
            metadata = @(Get-ProviderMetadata $modRoot)
        }
    }
    $enabled = @($providers | Where-Object enabled | Sort-Object lineNumber)
    $winner = if ($enabled.Count -gt 0) { $enabled[0] } else { $null }
    foreach ($provider in $providers) {
        $provider | Add-Member -NotePropertyName effectiveWinnerAmongEnabledMods -NotePropertyValue ($null -ne $winner -and $provider.lineNumber -eq $winner.lineNumber)
    }
    return [pscustomobject][ordered]@{
        profilePath = $resolvedProfile
        profileSha256 = (Get-FileHash -LiteralPath $resolvedProfile -Algorithm SHA256).Hash
        modsPath = $resolvedMods
        relativeCachePath = $RelativeCachePath
        providers = $providers
        enabledProviders = @($providers | Where-Object enabled).Count
        disabledProviders = @($providers | Where-Object { -not $_.enabled }).Count
        effectiveWinnerAmongEnabledMods = $winner
        priorityNote = 'Among enabled loose-file mod providers, the earliest modlist line wins. Overwrite, unmanaged game files, archives, and runtime deployment still require separate VFS evidence.'
    }
}

function Assert-Closed {
    $processes = @(Get-LiveProcesses $BlockingProcessNames)
    if ($processes.Count -gt 0) {
        throw "Shader-cache mutation requires MO2 and Skyrim to be closed. Active: $($processes.name -join ', ')."
    }
}

function Get-ReceiptPaths {
    if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) { throw '-EvidenceDirectory is required for snapshot, verify, seed, and restore.' }
    $evidence = [IO.Path]::GetFullPath($EvidenceDirectory)
    return [pscustomobject][ordered]@{
        evidence = $evidence
        receipt = Join-Path $evidence 'shader-cache-transaction.receipt.json'
        before = Join-Path $evidence 'cache.before'
        beforeInventory = Join-Path $evidence 'cache.before.inventory.json'
    }
}

$result = $null
try {
    if ($Command -eq 'providers') {
        $result = [pscustomobject][ordered]@{ ok = $true; command = $Command; data = Get-Providers; errors = @() }
    }
    else {
        if ([string]::IsNullOrWhiteSpace($CachePath)) { throw "$Command requires -CachePath." }
        $resolvedCache = if ($Command -eq 'inspect') {
            Assert-SafeSourcePath $CachePath
        }
        else {
            Assert-SafeCachePath $CachePath
        }
        Assert-NoCacheReparsePoint -Path $resolvedCache -Purpose 'Shader-cache target'
        if ($Command -eq 'inspect') {
            $result = [pscustomobject][ordered]@{ ok = $true; command = $Command; data = Get-TreeInventory $resolvedCache; errors = @() }
        }
        else {
            $paths = Get-ReceiptPaths
            if ($Command -eq 'snapshot') {
                Assert-Closed
                if (Test-Path -LiteralPath $paths.receipt -PathType Leaf) { throw "Refusing to overwrite an existing transaction receipt: $($paths.receipt)" }
                $before = Get-TreeInventory $resolvedCache
                if ($PSCmdlet.ShouldProcess($resolvedCache, 'Snapshot exact shader-cache tree')) {
                    New-Item -ItemType Directory -Path $paths.evidence -Force | Out-Null
                    if (Test-Path -LiteralPath $paths.before) { throw "Refusing to overwrite an existing cache backup: $($paths.before)" }
                    Copy-Item -LiteralPath $resolvedCache -Destination $paths.before -Recurse
                    $backup = Get-TreeInventory $paths.before
                    if ($backup.treeSha256 -ne $before.treeSha256) { throw 'Backup verification failed: copied cache tree differs from source.' }
                    Write-JsonFile $paths.beforeInventory $before
                    $receipt = [pscustomobject][ordered]@{
                        contractVersion = '2.0.0'
                        operation = 'snapshot'
                        transactionId = [guid]::NewGuid().ToString('N')
                        cachePath = $resolvedCache
                        cacheParentPath = [IO.Path]::GetFullPath((Split-Path -Parent $resolvedCache))
                        cacheLeaf = [IO.Path]::GetFileName($resolvedCache)
                        evidenceDirectory = $paths.evidence
                        backupPath = $paths.before
                        beforeTreeSha256 = $before.treeSha256
                        beforeFiles = $before.files
                        beforeBytes = $before.bytes
                        createdUtc = [DateTime]::UtcNow.ToString('o')
                    }
                    Write-JsonFile $paths.receipt $receipt
                }
                $result = [pscustomobject][ordered]@{ ok = $true; command = $Command; whatIf = [bool]$WhatIfPreference; data = @{ cachePath = $resolvedCache; evidenceDirectory = $paths.evidence; inventory = $before; receiptPath = $paths.receipt }; errors = @() }
            }
            else {
                if (-not (Test-Path -LiteralPath $paths.receipt -PathType Leaf)) { throw "Transaction receipt does not exist: $($paths.receipt)" }
                $receipt = Get-Content -LiteralPath $paths.receipt -Raw | ConvertFrom-Json
                if ([string]$receipt.operation -cne 'snapshot' -or [string]::IsNullOrWhiteSpace([string]$receipt.transactionId)) { throw 'Transaction receipt lacks exact snapshot operation ownership.' }
                if ([IO.Path]::GetFullPath([string]$receipt.cachePath) -cne $resolvedCache -or [IO.Path]::GetFullPath([string]$receipt.backupPath) -cne [IO.Path]::GetFullPath($paths.before)) { throw 'Transaction receipt ownership does not match this cache and evidence directory.' }
                if ([IO.Path]::GetFullPath([string]$receipt.cacheParentPath) -cne [IO.Path]::GetFullPath((Split-Path -Parent $resolvedCache)) -or [string]$receipt.cacheLeaf -cne [IO.Path]::GetFileName($resolvedCache)) { throw 'Transaction receipt does not bind the exact cache parent and leaf.' }
                Assert-NoCacheReparsePoint -Path $paths.before -Purpose 'Preserved shader-cache baseline'
                $backup = Get-TreeInventory $paths.before
                if ($backup.treeSha256 -ne [string]$receipt.beforeTreeSha256) { throw 'Preserved backup no longer matches its transaction receipt.' }
                if ($Command -eq 'verify') {
                    $current = Get-TreeInventory $resolvedCache
                    $matches = $current.treeSha256 -eq [string]$receipt.beforeTreeSha256
                    $result = [pscustomobject][ordered]@{ ok = $matches; command = $Command; data = @{ matches = $matches; current = $current; receiptPath = $paths.receipt }; errors = $(if ($matches) { @() } else { @('Current shader-cache tree differs from the preserved transaction baseline.') }) }
                }
                elseif ($Command -eq 'seed') {
                    Assert-Closed
                    if ([string]::IsNullOrWhiteSpace($SourceCachePath)) { throw 'seed requires -SourceCachePath.' }
                    if ([string]::IsNullOrWhiteSpace($ExpectedSourceTreeSha256)) { throw 'seed requires -ExpectedSourceTreeSha256.' }
                    $resolvedSource = Assert-SafeSourcePath $SourceCachePath
                    Assert-NoCacheReparsePoint -Path $resolvedSource -Purpose 'Shader-cache seed source'
                    if ($resolvedSource -eq $resolvedCache) { throw 'Seed source and live cache must be different directories.' }
                    $source = Get-TreeInventory $resolvedSource
                    if ($source.treeSha256 -ne $ExpectedSourceTreeSha256) {
                        throw "Seed source tree hash mismatch. Expected $ExpectedSourceTreeSha256, observed $($source.treeSha256)."
                    }
                    if (-not [string]::IsNullOrWhiteSpace($ShaderCacheAbiOverride) -and [string]::IsNullOrWhiteSpace($CompatibilityReason)) {
                        throw '-CompatibilityReason is required when -ShaderCacheAbiOverride is used.'
                    }

                    $parent = Split-Path -Parent $resolvedCache
                    $leaf = Split-Path -Leaf $resolvedCache
                    $staging = Join-Path $parent ('.' + $leaf + '.seed.' + [guid]::NewGuid().ToString('N'))
                    $displaced = Join-Path $parent ('.' + $leaf + '.displaced.' + [guid]::NewGuid().ToString('N'))
                    $preservedDisplaced = Join-Path $paths.evidence ('cache.displaced-before-seed.' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '.' + [guid]::NewGuid().ToString('N'))
                    $current = Get-TreeInventory $resolvedCache
                    $abiBefore = $null
                    $staged = $null
                    $journalPath = $null
                    $seedReceiptPath = $null
                    if ($PSCmdlet.ShouldProcess($resolvedCache, 'Seed verified shader-cache tree and retain displaced contents')) {
                        $operationId = [guid]::NewGuid().ToString('N')
                        $journalPath = Join-Path $paths.evidence ("shader-cache-seed.$operationId.journal.json")
                        $seedReceiptPath = Join-Path $paths.evidence ("shader-cache-seed.$operationId.receipt.json")
                        $journal = [pscustomobject][ordered]@{
                            contractVersion = '1.0.0'; operation = 'seed'; phase = 'prepared'; operationId = $operationId
                            snapshotTransactionId = [string]$receipt.transactionId; cachePath = $resolvedCache; sourceCachePath = $resolvedSource
                            originalTreeSha256 = [string]$current.treeSha256; requestedTreeSha256 = [string]$source.treeSha256
                            stagingPath = $staging; displacedPath = $displaced; preparedUtc = [DateTime]::UtcNow.ToString('o'); rollback = $null
                        }
                        Write-JsonFile $journalPath $journal
                        Copy-Item -LiteralPath $resolvedSource -Destination $staging -Recurse
                        $copied = Get-TreeInventory $staging
                        if ($copied.treeSha256 -ne $source.treeSha256) { throw 'Staged seed tree differs from its verified source.' }
                        if (-not [string]::IsNullOrWhiteSpace($ShaderCacheAbiOverride)) {
                            $infoPath = Join-Path $staging 'Info.ini'
                            if (-not (Test-Path -LiteralPath $infoPath -PathType Leaf)) { throw 'ShaderCacheABI override requires a staged Info.ini.' }
                            $abiBefore = Set-IniValue -Path $infoPath -Section 'Cache' -Key 'ShaderCacheABI' -Value $ShaderCacheAbiOverride
                        }
                        $staged = Get-TreeInventory $staging
                        try {
                            Move-Item -LiteralPath $resolvedCache -Destination $displaced
                            $journal.phase = 'original-displaced'; Write-JsonFile $journalPath $journal
                            Move-Item -LiteralPath $staging -Destination $resolvedCache
                            $journal.phase = 'replacement-active-uncommitted'; Write-JsonFile $journalPath $journal
                            if ($InternalTestFailurePoint -eq 'seed-after-activate') { throw 'Injected seed failure after replacement activation.' }
                            $seeded = Get-TreeInventory $resolvedCache
                            if ($seeded.treeSha256 -ne $staged.treeSha256) { throw 'Seeded cache tree failed postcondition verification.' }
                            Copy-Item -LiteralPath $displaced -Destination $preservedDisplaced -Recurse
                            $preserved = Get-TreeInventory $preservedDisplaced
                            if ($preserved.treeSha256 -ne $current.treeSha256) { throw 'Displaced cache preservation failed verification.' }
                            $seedReceipt = [pscustomobject][ordered]@{
                                contractVersion = '2.0.0'; operation = 'seed'; transactionId = $operationId
                                snapshotTransactionId = [string]$receipt.transactionId
                                cachePath = $resolvedCache
                                sourceCachePath = $resolvedSource
                                sourceTreeSha256 = $source.treeSha256
                                seededTreeSha256 = $staged.treeSha256
                                displacedTreeSha256 = $current.treeSha256
                                displacedPath = $preservedDisplaced
                                shaderCacheAbiBefore = $abiBefore
                                shaderCacheAbiOverride = $(if ([string]::IsNullOrWhiteSpace($ShaderCacheAbiOverride)) { $null } else { $ShaderCacheAbiOverride })
                                compatibilityReason = $(if ([string]::IsNullOrWhiteSpace($CompatibilityReason)) { $null } else { $CompatibilityReason })
                                seededUtc = [DateTime]::UtcNow.ToString('o')
                            }
                            Write-JsonFile $seedReceiptPath $seedReceipt
                            $journal.phase = 'committed'; $journal | Add-Member -NotePropertyName committedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force; $journal | Add-Member -NotePropertyName receiptPath -NotePropertyValue $seedReceiptPath -Force
                            Write-JsonFile $journalPath $journal
                        }
                        catch {
                            Invoke-CacheSwapRollback -LivePath $resolvedCache -DisplacedPath $displaced -ExpectedOriginalHash ([string]$current.treeSha256) -EvidenceRoot $paths.evidence -Journal $journal -JournalPath $journalPath -FailureMessage "Shader-cache seed failed: $($_.Exception.Message)"
                        }
                        if (Test-Path -LiteralPath $displaced -PathType Container) { Remove-Item -LiteralPath $displaced -Recurse -Force }
                    }
                    $result = [pscustomobject][ordered]@{ ok = $true; command = $Command; whatIf = [bool]$WhatIfPreference; data = @{ cachePath = $resolvedCache; source = $source; seeded = $staged; displacedPath = $preservedDisplaced; receiptPath = $paths.receipt; seedReceiptPath = $seedReceiptPath; journalPath = $journalPath }; errors = @() }
                }
                else {
                    Assert-Closed
                    $parent = Split-Path -Parent $resolvedCache
                    $leaf = Split-Path -Leaf $resolvedCache
                    $staging = Join-Path $parent ('.' + $leaf + '.restore.' + [guid]::NewGuid().ToString('N'))
                    $displaced = Join-Path $parent ('.' + $leaf + '.displaced.' + [guid]::NewGuid().ToString('N'))
                    $preservedDisplaced = Join-Path $paths.evidence ('cache.displaced.' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '.' + [guid]::NewGuid().ToString('N'))
                    $current = Get-TreeInventory $resolvedCache
                    $journalPath = $null
                    $restoreReceiptPath = $null
                    if ($PSCmdlet.ShouldProcess($resolvedCache, 'Restore exact preserved shader-cache tree and retain displaced contents')) {
                        $operationId = [guid]::NewGuid().ToString('N')
                        $journalPath = Join-Path $paths.evidence ("shader-cache-restore.$operationId.journal.json")
                        $restoreReceiptPath = Join-Path $paths.evidence ("shader-cache-restore.$operationId.receipt.json")
                        $journal = [pscustomobject][ordered]@{
                            contractVersion = '1.0.0'; operation = 'restore'; phase = 'prepared'; operationId = $operationId
                            snapshotTransactionId = [string]$receipt.transactionId; cachePath = $resolvedCache
                            originalTreeSha256 = [string]$current.treeSha256; requestedTreeSha256 = [string]$receipt.beforeTreeSha256
                            stagingPath = $staging; displacedPath = $displaced; preparedUtc = [DateTime]::UtcNow.ToString('o'); rollback = $null
                        }
                        Write-JsonFile $journalPath $journal
                        Write-JsonFile (Join-Path $paths.evidence 'cache.current-before-restore.inventory.json') $current
                        Copy-Item -LiteralPath $paths.before -Destination $staging -Recurse
                        $staged = Get-TreeInventory $staging
                        if ($staged.treeSha256 -ne [string]$receipt.beforeTreeSha256) { throw 'Staged restore tree failed verification.' }
                        try {
                            Move-Item -LiteralPath $resolvedCache -Destination $displaced
                            $journal.phase = 'original-displaced'; Write-JsonFile $journalPath $journal
                            Move-Item -LiteralPath $staging -Destination $resolvedCache
                            $journal.phase = 'replacement-active-uncommitted'; Write-JsonFile $journalPath $journal
                            if ($InternalTestFailurePoint -eq 'restore-after-activate') { throw 'Injected restore failure after replacement activation.' }
                            $restored = Get-TreeInventory $resolvedCache
                            if ($restored.treeSha256 -ne [string]$receipt.beforeTreeSha256) { throw 'Restored cache tree failed postcondition verification.' }
                            Copy-Item -LiteralPath $displaced -Destination $preservedDisplaced -Recurse
                            $preserved = Get-TreeInventory $preservedDisplaced
                            if ($preserved.treeSha256 -ne $current.treeSha256) { throw 'Displaced cache preservation failed verification.' }
                            $restoreReceipt = [pscustomobject][ordered]@{
                                contractVersion = '2.0.0'; operation = 'restore'; transactionId = $operationId
                                snapshotTransactionId = [string]$receipt.transactionId; cachePath = $resolvedCache
                                restoredTreeSha256 = [string]$receipt.beforeTreeSha256
                                displacedTreeSha256 = $current.treeSha256
                                displacedPath = $preservedDisplaced
                                restoredUtc = [DateTime]::UtcNow.ToString('o')
                            }
                            Write-JsonFile $restoreReceiptPath $restoreReceipt
                            $journal.phase = 'committed'; $journal | Add-Member -NotePropertyName committedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force; $journal | Add-Member -NotePropertyName receiptPath -NotePropertyValue $restoreReceiptPath -Force
                            Write-JsonFile $journalPath $journal
                        }
                        catch {
                            Invoke-CacheSwapRollback -LivePath $resolvedCache -DisplacedPath $displaced -ExpectedOriginalHash ([string]$current.treeSha256) -EvidenceRoot $paths.evidence -Journal $journal -JournalPath $journalPath -FailureMessage "Shader-cache restore failed: $($_.Exception.Message)"
                        }
                        if (Test-Path -LiteralPath $displaced -PathType Container) { Remove-Item -LiteralPath $displaced -Recurse -Force }
                    }
                    $result = [pscustomobject][ordered]@{ ok = $true; command = $Command; whatIf = [bool]$WhatIfPreference; data = @{ cachePath = $resolvedCache; baseline = $backup; displacedPath = $preservedDisplaced; receiptPath = $paths.receipt; restoreReceiptPath = $restoreReceiptPath; journalPath = $journalPath }; errors = @() }
                }
            }
        }
    }
}
catch {
    $result = [pscustomobject][ordered]@{ ok = $false; command = $Command; data = $null; errors = @($_.Exception.Message) }
}

$json = $result | ConvertTo-Json -Depth 30 -Compress:$Compact
Write-Output $json
if (-not $result.ok -and -not $NoExit) { exit 2 }
