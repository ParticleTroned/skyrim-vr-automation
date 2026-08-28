# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('inspect', 'apply', 'start', 'restore', 'stop')]
    [string]$Command = 'inspect',

    [string]$SettingsPath = 'C:\Program Files (x86)\Steam\config\steamvr.vrsettings',

    [string]$NullProfilePath,

    [string]$SteamVRRoot = 'C:\Program Files (x86)\Steam\steamapps\common\SteamVR',

    [string]$ServerLogPath = 'C:\Program Files (x86)\Steam\logs\vrserver.txt',

    [string]$OpenVRPathsPath = $(if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { Join-Path $env:LOCALAPPDATA 'openvr\openvrpaths.vrpath' } else { $null }),

    [string]$HeadPoseDriverRoot = $(if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { Join-Path $env:LOCALAPPDATA 'CSX-VR-Automation\SteamVR\drivers\codex_head_pose' } else { $null }),

    [string]$EvidenceDirectory,

    [switch]$WhatIf,

    [switch]$Force,

    [switch]$AllowExternalDisplayRedirector,

    [ValidateSet('', 'apply-after-openvr', 'restore-after-settings')]
    [string]$InternalTestFailurePoint = '',

    [switch]$IsolateExternalDisplayRedirectors,

    [string[]]$ExternalDisplayRedirectorRoot = @(),

    [ValidateRange(5, 120)]
    [int]$StartupTimeoutSeconds = 45,

    [switch]$NoExit,

    [switch]$Compact
)

if ($PSVersionTable.PSVersion.Major -lt 7) {
    $versionFailure = [pscustomobject][ordered]@{
        schemaVersion = 1
        command = $Command
        ok = $false
        state = 'unsupported-powershell-version'
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        errors = @("steamvr-null-control requires PowerShell 7.0 or newer; current host is $($PSVersionTable.PSVersion). Invoke the script with pwsh.exe, not Windows PowerShell powershell.exe.")
        data = @{ requiredPowerShellVersion = '7.0'; actualPowerShellVersion = [string]$PSVersionTable.PSVersion; requiredExecutable = 'pwsh.exe' }
    }
    $versionJsonParameters = @{ InputObject = $versionFailure; Depth = 8 }
    if ($Compact) { $versionJsonParameters['Compress'] = $true }
    ConvertTo-Json @versionJsonParameters
    if (-not $NoExit) { exit 2 }
    return
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($NullProfilePath)) {
    $NullProfilePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\profiles\steamvr-null.profile.json'))
}

function Get-SteamVRProcesses {
    $records = @()
    foreach ($name in @('vrserver', 'vrmonitor', 'vrcompositor', 'vrstartup', 'vrdashboard', 'vrwebhelper')) {
        foreach ($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            $records += [pscustomobject][ordered]@{
                name = $process.ProcessName
                id = $process.Id
                startTimeUtc = $(try { $process.StartTime.ToUniversalTime().ToString('o') } catch { $null })
                path = $(try { $process.Path } catch { $null })
            }
        }
    }
    return @($records | Sort-Object name, id)
}

function Get-HashOrNull {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $stream = $null
        $algorithm = $null
        try {
            $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            $algorithm = [Security.Cryptography.SHA256]::Create()
            return [Convert]::ToHexString($algorithm.ComputeHash($stream))
        }
        finally {
            if ($algorithm) { $algorithm.Dispose() }
            if ($stream) { $stream.Dispose() }
        }
    }
    return $null
}

function Get-SharedTextTail([string]$Path, [int]$Count) {
    $stream = $null
    $reader = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
        $lines = @($reader.ReadToEnd() -split "`r?`n")
        if ($lines.Count -le $Count) { return $lines }
        return @($lines[($lines.Count - $Count)..($lines.Count - 1)])
    }
    finally {
        if ($reader) { $reader.Dispose() }
        elseif ($stream) { $stream.Dispose() }
    }
}

function Read-JsonHashtable {
    param([Parameter(Mandatory)][string]$Path)
    return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
}

function ConvertTo-CanonicalJsonValue {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [Collections.IDictionary]) {
        $canonical = [ordered]@{}
        $keys = [string[]]@($Value.Keys | ForEach-Object { [string]$_ })
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        foreach ($key in $keys) { $canonical[$key] = ConvertTo-CanonicalJsonValue -Value $Value[$key] }
        return $canonical
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        return ,@($Value | ForEach-Object { ConvertTo-CanonicalJsonValue -Value $_ })
    }
    return $Value
}

function Get-JsonSemanticSha256 {
    param([string]$Path, [AllowNull()]$Value)
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        $Value = Read-JsonHashtable -Path $Path
    }
    $json = (ConvertTo-CanonicalJsonValue -Value $Value) | ConvertTo-Json -Depth 64 -Compress
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToHexString($algorithm.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($json))) }
    finally { $algorithm.Dispose() }
}

function Get-IsolatedRegistrationExpectation {
    param(
        [Parameter(Mandatory)][string]$BackupPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Targets
    )
    $document = Read-JsonHashtable -Path $BackupPath
    $registered = @($document['external_drivers'])
    $targetRoots = @($Targets | ForEach-Object { Get-NormalizedPath ([string]$_['root']) })
    $uniqueTargets = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($targetRoot in $targetRoots) {
        if ([string]::IsNullOrWhiteSpace($targetRoot) -or -not $uniqueTargets.Add($targetRoot)) {
            throw 'The isolation receipt contains an empty or duplicate normalized target root.'
        }
    }

    $occurrences = @{}
    foreach ($targetRoot in $targetRoots) { $occurrences[$targetRoot] = 0 }
    $retained = [Collections.Generic.List[string]]::new()
    foreach ($rootValue in $registered) {
        if ([string]::IsNullOrWhiteSpace([string]$rootValue)) { continue }
        $normalized = Get-NormalizedPath ([string]$rootValue)
        if ($uniqueTargets.Contains($normalized)) { $occurrences[$normalized] = [int]$occurrences[$normalized] + 1 }
        else { $retained.Add([string]$rootValue) }
    }
    foreach ($targetRoot in $targetRoots) {
        if ([int]$occurrences[$targetRoot] -ne 1) {
            throw "The exact registration backup contains isolation target '$targetRoot' $($occurrences[$targetRoot]) times; exactly one occurrence is required."
        }
    }
    $document['external_drivers'] = @($retained)
    return [pscustomobject][ordered]@{
        semanticSha256 = Get-JsonSemanticSha256 -Value $document
        targetRoots = @($targetRoots)
        retainedRoots = @($retained)
    }
}

function Get-IsolationValidation {
    param(
        [Parameter(Mandatory)]$Isolation,
        [Parameter(Mandatory)][string]$BackupPath,
        [Parameter(Mandatory)][string]$CurrentPath
    )
    $expectation = Get-IsolatedRegistrationExpectation -BackupPath $BackupPath -Targets @($Isolation['targets'])
    $recordedSemanticSha256 = if ($Isolation.ContainsKey('semanticSha256Isolated')) { [string]$Isolation['semanticSha256Isolated'] } else { $null }
    if (-not [string]::IsNullOrWhiteSpace($recordedSemanticSha256) -and $recordedSemanticSha256 -ne $expectation.semanticSha256) {
        throw 'The receipt semantic hash does not match the isolated state reconstructed from the exact registration backup.'
    }
    $currentSha256 = Get-HashOrNull $CurrentPath
    $expectedSha256 = [string]$Isolation['sha256Isolated']
    $currentSemanticSha256 = Get-JsonSemanticSha256 -Path $CurrentPath
    return [pscustomobject][ordered]@{
        exactMatch = $currentSha256 -eq $expectedSha256
        semanticMatch = $currentSemanticSha256 -eq $expectation.semanticSha256
        formattingOnlyDriftAccepted = $currentSha256 -ne $expectedSha256 -and $currentSemanticSha256 -eq $expectation.semanticSha256
        currentSha256 = $currentSha256
        expectedSha256 = $expectedSha256
        currentSemanticSha256 = $currentSemanticSha256
        expectedSemanticSha256 = $expectation.semanticSha256
        recordedSemanticSha256 = $recordedSemanticSha256
        expectationSource = 'exact-backup-minus-unique-targets'
        targetRoots = $expectation.targetRoots
    }
}

function Get-ExternalDriverInventory {
    param([string]$Path)
    $drivers = [Collections.Generic.List[object]]::new()
    $errors = [Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject][ordered]@{ path = $null; exists = $false; sha256 = $null; semanticSha256 = $null; drivers = @(); conflicts = @(); errors = @('The OpenVR paths file could not be resolved because LOCALAPPDATA is unavailable.') }
    }
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        return [pscustomobject][ordered]@{ path = $resolvedPath; exists = $false; sha256 = $null; semanticSha256 = $null; drivers = @(); conflicts = @(); errors = @() }
    }
    try {
        $paths = Read-JsonHashtable -Path $resolvedPath
        foreach ($rootValue in @($paths['external_drivers'])) {
            if ([string]::IsNullOrWhiteSpace([string]$rootValue)) { continue }
            $root = [IO.Path]::GetFullPath([string]$rootValue)
            $manifestPath = Join-Path $root 'driver.vrdrivermanifest'
            $record = [ordered]@{
                root = $root
                manifestPath = $manifestPath
                manifestExists = Test-Path -LiteralPath $manifestPath -PathType Leaf
                manifestSha256 = $null
                name = $null
                alwaysActivate = $false
                redirectsDisplay = $false
                conflictsWithNullDisplay = $false
                error = $null
            }
            if ($record.manifestExists) {
                try {
                    $manifest = Read-JsonHashtable -Path $manifestPath
                    $record.manifestSha256 = Get-HashOrNull $manifestPath
                    $record.name = if ($manifest.ContainsKey('name')) { [string]$manifest['name'] } else { [IO.Path]::GetFileName($root) }
                    $record.alwaysActivate = $manifest.ContainsKey('alwaysActivate') -and [bool]$manifest['alwaysActivate']
                    $record.redirectsDisplay = $manifest.ContainsKey('redirectsDisplay') -and [bool]$manifest['redirectsDisplay']
                    $record.conflictsWithNullDisplay = [bool]$record.redirectsDisplay
                }
                catch { $record.error = $_.Exception.Message }
            }
            else { $record.error = 'External driver registration has no driver.vrdrivermanifest.' }
            $drivers.Add([pscustomobject]$record)
            if (-not [string]::IsNullOrWhiteSpace([string]$record.error)) { $errors.Add("External driver '$root' could not be classified: $($record.error)") }
        }
    }
    catch { $errors.Add($_.Exception.Message) }
    $conflicts = @($drivers | Where-Object conflictsWithNullDisplay)
    return [pscustomobject][ordered]@{
        path = $resolvedPath
        exists = $true
        sha256 = Get-HashOrNull $resolvedPath
        semanticSha256 = Get-JsonSemanticSha256 -Path $resolvedPath
        drivers = @($drivers)
        conflicts = $conflicts
        errors = @($errors)
    }
}

function Get-NormalizedPath([string]$Path) {
    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Get-ExternalDisplayIsolationTargets {
    param(
        [Parameter(Mandatory)]$Inventory,
        [string[]]$RequestedRoots = @()
    )
    if ($Inventory.errors.Count -gt 0) {
        throw 'External display-driver isolation requires a complete, error-free OpenVR driver inventory.'
    }
    $conflicts = @($Inventory.conflicts)
    if ($conflicts.Count -eq 0) {
        throw 'External display-driver isolation was requested, but no registered display redirector is present.'
    }

    $requested = @($RequestedRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { Get-NormalizedPath $_ } | Select-Object -Unique)
    if ($requested.Count -eq 0) {
        if ($conflicts.Count -ne 1) {
            throw "External display-driver isolation found $($conflicts.Count) redirectors. Specify every exact root with -ExternalDisplayRedirectorRoot."
        }
        return @($conflicts)
    }

    $selected = [Collections.Generic.List[object]]::new()
    foreach ($root in $requested) {
        $matches = @($conflicts | Where-Object { (Get-NormalizedPath ([string]$_.root)) -eq $root })
        if ($matches.Count -ne 1) {
            throw "Requested external display redirector '$root' is not one exact classified conflict."
        }
        $selected.Add($matches[0])
    }
    $unselected = @($conflicts | Where-Object { (Get-NormalizedPath ([string]$_.root)) -notin $requested })
    if ($unselected.Count -gt 0) {
        throw "External display-driver isolation must account for every redirector. Unselected: $(@($unselected.root) -join ', ')"
    }
    return @($selected)
}

function Disable-ExternalDriverRegistrations {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Targets
    )
    $document = Read-JsonHashtable -Path $Path
    $registered = @($document['external_drivers'])
    $targetRoots = @($Targets | ForEach-Object { Get-NormalizedPath ([string]$_.root) })
    $uniqueTargets = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($targetRoot in $targetRoots) {
        if ([string]::IsNullOrWhiteSpace($targetRoot) -or -not $uniqueTargets.Add($targetRoot)) {
            throw 'External display-driver isolation contains an empty or duplicate normalized target root.'
        }
    }
    $removed = [Collections.Generic.List[string]]::new()
    $retained = [Collections.Generic.List[string]]::new()
    foreach ($rootValue in $registered) {
        if ([string]::IsNullOrWhiteSpace([string]$rootValue)) { continue }
        $normalized = Get-NormalizedPath ([string]$rootValue)
        if ($uniqueTargets.Contains($normalized)) { $removed.Add($normalized) } else { $retained.Add([string]$rootValue) }
    }
    foreach ($targetRoot in $targetRoots) {
        if (@($removed | Where-Object { $_ -eq $targetRoot }).Count -ne 1) {
            throw "OpenVR registration changed before isolation. Target '$targetRoot' must occur exactly once."
        }
    }
    $document['external_drivers'] = @($retained)
    Write-JsonAtomic -Path $Path -Value $document
    return [pscustomobject][ordered]@{ removedRoots = @($removed); retainedRoots = @($retained) }
}

function Copy-FileAtomic {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    $temporary = "$Destination.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        Copy-Item -LiteralPath $Source -Destination $temporary
        Move-Item -LiteralPath $temporary -Destination $Destination -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )
    $json = $Value | ConvertTo-Json -Depth 32
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
        $null = Read-JsonHashtable -Path $temporary
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Restore-SteamVRTransactionTargets {
    param(
        [Parameter(Mandatory)]$Targets,
        [Parameter(Mandatory)]$Journal,
        [Parameter(Mandatory)][string]$JournalPath,
        [Parameter(Mandatory)][string]$FailureContext
    )
    $errors = @()
    foreach ($target in @($Targets)) {
        try {
            if (-not (Test-Path -LiteralPath ([string]$target['backupPath']) -PathType Leaf)) { throw 'exact rollback preimage is missing' }
            if ((Get-HashOrNull ([string]$target['backupPath'])) -ne [string]$target['expectedHash']) { throw 'rollback preimage hash differs from the journal' }
            Copy-FileAtomic -Source ([string]$target['backupPath']) -Destination ([string]$target['path'])
        }
        catch { $errors += "$($target['name']): $($_.Exception.Message)" }
    }
    foreach ($target in @($Targets)) {
        try { if ((Get-HashOrNull ([string]$target['path'])) -ne [string]$target['expectedHash']) { throw 'live hash does not match the rollback preimage' } }
        catch { $errors += "$($target['name']) verification: $($_.Exception.Message)" }
    }
    $Journal['phase'] = if ($errors.Count -eq 0) { 'rolled-back' } else { 'recovery-required' }
    $Journal['rollback'] = [ordered]@{ verified = $errors.Count -eq 0; errors = $errors; completedUtc = [DateTime]::UtcNow.ToString('o') }
    try { Write-JsonAtomic -Path $JournalPath -Value $Journal } catch { $errors += "journal: $($_.Exception.Message)" }
    if ($errors.Count -gt 0) { throw "$FailureContext Rollback requires recovery: $($errors -join '; ')" }
}

function Resolve-PendingSteamVRJournal([string]$JournalPath) {
    if (-not (Test-Path -LiteralPath $JournalPath -PathType Leaf)) { return $null }
    $journal = Read-JsonHashtable -Path $JournalPath
    if ([string]$journal['phase'] -in @('committed', 'rolled-back', 'recovered')) { return $journal }
    if (-not $journal.ContainsKey('rollbackTargets')) { throw "SteamVR transaction journal requires manual recovery: $JournalPath" }
    Restore-SteamVRTransactionTargets -Targets @($journal['rollbackTargets']) -Journal $journal -JournalPath $JournalPath -FailureContext 'Interrupted SteamVR transaction recovery failed.'
    $journal['phase'] = 'recovered'; $journal['recoveredUtc'] = [DateTime]::UtcNow.ToString('o')
    Write-JsonAtomic -Path $JournalPath -Value $journal
    return $journal
}

function Stop-ExactStartedSteamVRProcesses([DateTime]$StartedUtc) {
    $targets = @(Get-SteamVRProcesses | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.path) -and
        [IO.Path]::GetFullPath([string]$_.path).StartsWith($resolvedSteamVRRoot, [StringComparison]::OrdinalIgnoreCase) -and
        -not [string]::IsNullOrWhiteSpace([string]$_.startTimeUtc) -and [DateTime]::Parse([string]$_.startTimeUtc).ToUniversalTime() -ge $StartedUtc.AddSeconds(-1)
    })
    $errors = @()
    foreach ($target in $targets) { try { Stop-Process -Id ([int]$target.id) -Force -ErrorAction Stop } catch { $errors += "$($target.name)[$($target.id)]: $($_.Exception.Message)" } }
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $remaining = @($targets | Where-Object { Get-Process -Id ([int]$_.id) -ErrorAction SilentlyContinue })
        if ($remaining.Count -gt 0) { Start-Sleep -Milliseconds 100 }
    } while ($remaining.Count -gt 0 -and [DateTime]::UtcNow -lt $deadline)
    return [pscustomobject][ordered]@{ requested = $targets; remaining = $remaining; errors = $errors; verified = $remaining.Count -eq 0 -and $errors.Count -eq 0 }
}

function Get-EffectiveState {
    param(
        [Parameter(Mandatory)]$Settings,
        [Parameter(Mandatory)]$Profile
    )
    $steamvr = if ($Settings.ContainsKey('steamvr')) { $Settings['steamvr'] } else { @{} }
    $dashboard = if ($Settings.ContainsKey('dashboard')) { $Settings['dashboard'] } else { @{} }
    $driver = if ($Settings.ContainsKey('driver_null')) { $Settings['driver_null'] } else { @{} }
    $headPoseDriver = if ($Settings.ContainsKey('driver_codex_head_pose')) { $Settings['driver_codex_head_pose'] } else { @{} }
    $trackingOverrides = if ($Settings.ContainsKey('TrackingOverrides')) { $Settings['TrackingOverrides'] } else { @{} }
    $expectedSteamVR = $Profile['steamvr']
    $expectedDashboard = $Profile['dashboard']
    $expectedDriver = $Profile['driver_null']
    $expectedHeadPoseDriver = $Profile['driver_codex_head_pose']
    $expectedTrackingOverrides = $Profile['TrackingOverrides']

    $checks = [ordered]@{}
    foreach ($key in @('forcedDriver', 'requireHmd', 'activateMultipleDrivers', 'enableHomeApp')) {
        $checks["steamvr.$key"] = [ordered]@{
            actual = if ($steamvr.ContainsKey($key)) { $steamvr[$key] } else { $null }
            expected = $expectedSteamVR[$key]
            matches = $steamvr.ContainsKey($key) -and $steamvr[$key] -eq $expectedSteamVR[$key]
        }
    }
    foreach ($key in $expectedDashboard.Keys) {
        $checks["dashboard.$key"] = [ordered]@{
            actual = if ($dashboard.ContainsKey($key)) { $dashboard[$key] } else { $null }
            expected = $expectedDashboard[$key]
            matches = $dashboard.ContainsKey($key) -and $dashboard[$key] -eq $expectedDashboard[$key]
        }
    }
    foreach ($key in @('enable', 'serialNumber', 'modelNumber', 'windowWidth', 'windowHeight', 'renderWidth', 'renderHeight', 'displayFrequency')) {
        $checks["driver_null.$key"] = [ordered]@{
            actual = if ($driver.ContainsKey($key)) { $driver[$key] } else { $null }
            expected = $expectedDriver[$key]
            matches = $driver.ContainsKey($key) -and $driver[$key] -eq $expectedDriver[$key]
        }
    }
    foreach ($key in $expectedHeadPoseDriver.Keys) {
        $checks["driver_codex_head_pose.$key"] = [ordered]@{
            actual = if ($headPoseDriver.ContainsKey($key)) { $headPoseDriver[$key] } else { $null }
            expected = $expectedHeadPoseDriver[$key]
            matches = $headPoseDriver.ContainsKey($key) -and $headPoseDriver[$key] -eq $expectedHeadPoseDriver[$key]
        }
    }
    foreach ($key in $expectedTrackingOverrides.Keys) {
        $checks["TrackingOverrides.$key"] = [ordered]@{
            actual = if ($trackingOverrides.ContainsKey($key)) { $trackingOverrides[$key] } else { $null }
            expected = $expectedTrackingOverrides[$key]
            matches = $trackingOverrides.ContainsKey($key) -and $trackingOverrides[$key] -eq $expectedTrackingOverrides[$key]
        }
    }
    return [pscustomobject][ordered]@{
        active = @($checks.Values | Where-Object { -not $_.matches }).Count -eq 0
        checks = $checks
    }
}

function Get-HeadPoseSharedState {
    param([Parameter(Mandatory)]$Contract)
    $mapping = $null
    $view = $null
    try {
        $mapping = [IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting(
            [string]$Contract['sharedMemoryName'],
            [IO.MemoryMappedFiles.MemoryMappedFileRights]::Read)
        $view = $mapping.CreateViewAccessor(0, 88, [IO.MemoryMappedFiles.MemoryMappedFileAccess]::Read)
        $firstSequence = $view.ReadUInt64(8)
        $state = [ordered]@{
            magic = $view.ReadUInt32(0)
            version = $view.ReadUInt16(4)
            size = $view.ReadUInt16(6)
            requestedSequence = $firstSequence
            appliedSequence = $view.ReadUInt64(16)
            status = $view.ReadUInt32(24)
            flags = $view.ReadUInt32(28)
            position = @($view.ReadDouble(32), $view.ReadDouble(40), $view.ReadDouble(48))
            quaternion = @($view.ReadDouble(56), $view.ReadDouble(64), $view.ReadDouble(72), $view.ReadDouble(80))
        }
        $secondSequence = $view.ReadUInt64(8)
        $state['stable'] = $firstSequence -eq $secondSequence -and ($secondSequence % 2) -eq 0
        $state['available'] = $true
        $state['protocolValid'] = $state.magic -eq 0x48505343 -and $state.version -eq [int]$Contract['sharedMemoryVersion'] -and $state.size -eq 88
        $state['acknowledged'] = $state.stable -and $state.requestedSequence -gt 0 -and $state.appliedSequence -eq $state.requestedSequence -and $state.status -eq 1
        $state['eyeHeightQualified'] = $state.position[1] -ge [double]$Contract['minimumQualifiedEyeHeightMeters'] -and $state.position[1] -le [double]$Contract['maximumQualifiedEyeHeightMeters']
        $state['qualified'] = $state.protocolValid -and $state.acknowledged -and $state.eyeHeightQualified -and (($state.flags -band 1) -eq 1)
        return [pscustomobject]$state
    }
    catch [IO.FileNotFoundException] {
        return [pscustomobject][ordered]@{ available = $false; qualified = $false; error = 'The head-pose shared-memory provider is not running.' }
    }
    catch {
        return [pscustomobject][ordered]@{ available = $false; qualified = $false; error = $_.Exception.Message }
    }
    finally {
        if ($view) { $view.Dispose() }
        if ($mapping) { $mapping.Dispose() }
    }
}

function Get-ApplicationHeadPose {
    param([Parameter(Mandatory)]$Contract)
    if ([string]::IsNullOrWhiteSpace($HeadPoseDriverRoot)) {
        return [pscustomobject][ordered]@{ available = $false; qualified = $false; error = 'The stable head-pose driver root could not be resolved.' }
    }
    $probePath = Join-Path $HeadPoseDriverRoot ([string]$Contract['poseProbeRelativePath'])
    if (-not (Test-Path -LiteralPath $probePath -PathType Leaf)) {
        return [pscustomobject][ordered]@{ available = $false; qualified = $false; probePath = $probePath; error = 'The independent OpenVR pose probe is not installed.' }
    }
    try {
        $boundedTool = Join-Path (Split-Path -Parent $PSScriptRoot) 'process-control\Invoke-BoundedProcess.ps1'
        if (-not (Test-Path -LiteralPath $boundedTool -PathType Leaf)) { throw "Bounded process controller is missing: $boundedTool" }
        $bounded = & $boundedTool -FilePath $probePath -WorkingDirectory (Split-Path -Parent $probePath) -MaxAttempts 1 -TimeoutSeconds 10 -NoExit -Compact | ConvertFrom-Json -Depth 30
        $attempt = if (@($bounded.attempts).Count -gt 0) { $bounded.attempts[-1] } else { $null }
        if ($null -eq $attempt -or [string]::IsNullOrWhiteSpace([string]$attempt.stdout)) { throw "Independent OpenVR pose probe produced no bounded output. $($bounded.errors -join '; ')" }
        $payload = [string]$attempt.stdout | ConvertFrom-Json -ErrorAction Stop
        $qualified = $bounded.ok -and $payload.ok -and $payload.standing.connected -and $payload.standing.valid -and
            [double]$payload.standing.position[1] -ge [double]$Contract['minimumQualifiedEyeHeightMeters'] -and
            [double]$payload.standing.position[1] -le [double]$Contract['maximumQualifiedEyeHeightMeters']
        return [pscustomobject][ordered]@{
            available = $true
            qualified = $qualified
            probePath = $probePath
            exitCode = $attempt.exitCode
            boundedProcess = $bounded
            observation = $payload
        }
    }
    catch {
        return [pscustomobject][ordered]@{ available = $false; qualified = $false; probePath = $probePath; error = $_.Exception.Message }
    }
}

function Get-LogTimestampUtc([string]$Line) {
    if ($Line -notmatch '^(?<timestamp>[A-Za-z]{3}\s+[A-Za-z]{3}\s+\d{1,2}\s+\d{4}\s+\d{2}:\d{2}:\d{2}\.\d{3})\s+\[') {
        return $null
    }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParseExact(
        $Matches.timestamp,
        'ddd MMM d yyyy HH:mm:ss.fff',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeLocal,
        [ref]$parsed)) {
        return $null
    }
    return $parsed.UtcDateTime
}

function Get-NullRuntimeEvidence {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Processes,
        [Parameter(Mandatory)]$Profile
    )
    $resolvedRoot = [IO.Path]::GetFullPath($SteamVRRoot).TrimEnd('\') + '\'
    $owned = @($Processes | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.path) -and
        [IO.Path]::GetFullPath([string]$_.path).StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)
    })
    $server = @($owned | Where-Object name -eq 'vrserver' | Sort-Object startTimeUtc | Select-Object -First 1)
    $serverStartUtc = if ($server.Count -eq 1 -and $server[0].startTimeUtc) { [DateTime]::Parse([string]$server[0].startTimeUtc).ToUniversalTime() } else { $null }
    $loaded = $null
    $active = $null
    $headPoseLoaded = $null
    $headPoseRegistered = $null
    $tail = @()
    if ($serverStartUtc -and (Test-Path -LiteralPath $ServerLogPath -PathType Leaf)) {
        $tail = @(Get-SharedTextTail -Path $ServerLogPath -Count 2000)
        $minimumUtc = $serverStartUtc.AddSeconds(-3)
        foreach ($line in $tail) {
            $timestampUtc = Get-LogTimestampUtc -Line $line
            if (-not $timestampUtc -or $timestampUtc -lt $minimumUtc) { continue }
            if ($line -match 'Loaded server driver null .*driver_null\.dll') {
                $loaded = [pscustomobject]@{ timestampUtc = $timestampUtc.ToString('o'); line = $line }
            }
            if ($line -match "Active HMD set to null\.$([regex]::Escape([string]$Profile['driver_null']['serialNumber']))") {
                $active = [pscustomobject]@{ timestampUtc = $timestampUtc.ToString('o'); line = $line }
            }
            if ($line -match 'Loaded server driver codex_head_pose .*driver_codex_head_pose\.dll') {
                $headPoseLoaded = [pscustomobject]@{ timestampUtc = $timestampUtc.ToString('o'); line = $line }
            }
            if ($line -match 'codex_head_pose: registered synthetic head-pose device at configured standing pose') {
                $headPoseRegistered = [pscustomobject]@{ timestampUtc = $timestampUtc.ToString('o'); line = $line }
            }
        }
    }
    $headPoseState = Get-HeadPoseSharedState -Contract $Profile['headPoseProviderContract']
    $applicationHeadPose = if ($server.Count -eq 1 -and [bool]$headPoseState.qualified) { Get-ApplicationHeadPose -Contract $Profile['headPoseProviderContract'] } else { [pscustomobject][ordered]@{ available = $false; qualified = $false; error = 'The provider is not ready for an application-facing pose probe.' } }
    return [pscustomobject][ordered]@{
        active = $server.Count -eq 1 -and $null -ne $loaded -and $null -ne $active
        serverProcess = if ($server.Count -eq 1) { $server[0] } else { $null }
        steamVrProcesses = $owned
        unprovenProcesses = @($Processes | Where-Object { $_ -notin $owned })
        serverLogPath = $ServerLogPath
        serverLogSha256 = Get-HashOrNull $ServerLogPath
        driverLoaded = $loaded
        activeHmd = $active
        headPoseDriverLoaded = $headPoseLoaded
        headPoseDeviceRegistered = $headPoseRegistered
        headPoseState = $headPoseState
        applicationHeadPose = $applicationHeadPose
        headPoseReady = $server.Count -eq 1 -and $null -ne $headPoseLoaded -and $null -ne $headPoseRegistered -and [bool]$headPoseState.qualified -and [bool]$applicationHeadPose.qualified
        dashboardProcesses = @($owned | Where-Object name -eq 'vrdashboard')
        dashboardSuppressed = $Profile['dashboard'].ContainsKey('enableDashboard') -and -not [bool]$Profile['dashboard']['enableDashboard']
    }
}

function New-Result {
    param([bool]$Ok, [string]$State, $Data, [string[]]$Errors = @())
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        command = $Command
        ok = $Ok
        state = $State
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        errors = @($Errors)
        data = $Data
    }
}

function Get-RuntimeInputContract {
    param(
        [Parameter(Mandatory)]$BaseContract,
        [Parameter(Mandatory)]$Effective,
        [Parameter(Mandatory)]$Runtime,
        [Parameter(Mandatory)]$ExternalDrivers,
        [bool]$DiagnosticDisplayOverride = $false
    )
    $contract = ($BaseContract | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable)
    $blockers = [Collections.Generic.List[string]]::new()
    if (-not [bool]$Effective.active) { $blockers.Add('null-profile-not-effective') }
    if (-not [bool]$Runtime.active) { $blockers.Add('null-runtime-not-active') }
    if (-not [bool]$Runtime.headPoseReady) { $blockers.Add('head-pose-not-qualified') }
    if ($ExternalDrivers.errors.Count -gt 0) { $blockers.Add('external-driver-inventory-incomplete') }
    if ($ExternalDrivers.conflicts.Count -gt 0) { $blockers.Add('external-display-redirector-present') }
    if ($DiagnosticDisplayOverride) { $blockers.Add('diagnostic-display-override') }
    $contract['measurementReady'] = $blockers.Count -eq 0
    $contract['measurementBlockers'] = @($blockers)
    $contract['dashboardProcessTelemetryOnly'] = $true
    return $contract
}

try {
    if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
        throw "SteamVR settings file does not exist: $SettingsPath"
    }
    if (-not (Test-Path -LiteralPath $NullProfilePath -PathType Leaf)) {
        throw "Null-HMD profile does not exist: $NullProfilePath"
    }
    $settings = Read-JsonHashtable -Path $SettingsPath
    $profile = Read-JsonHashtable -Path $NullProfilePath
    foreach ($section in @('steamvr', 'dashboard', 'driver_null', 'driver_codex_head_pose', 'TrackingOverrides', 'headPoseProviderContract', 'automationInputContract')) {
        if (-not $profile.ContainsKey($section)) { throw "Null-HMD profile is missing '$section'." }
    }
    $processes = @(Get-SteamVRProcesses)
    $resolvedSteamVRRoot = [IO.Path]::GetFullPath($SteamVRRoot).TrimEnd('\') + '\'
    $ownedProcesses = @($processes | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.path) -and
        [IO.Path]::GetFullPath([string]$_.path).StartsWith($resolvedSteamVRRoot, [StringComparison]::OrdinalIgnoreCase)
    })
    $unprovenProcesses = @($processes | Where-Object { $_ -notin $ownedProcesses })
    $effective = Get-EffectiveState -Settings $settings -Profile $profile
    $runtime = Get-NullRuntimeEvidence -Processes $processes -Profile $profile
    $externalDrivers = Get-ExternalDriverInventory -Path $OpenVRPathsPath

    if ($Command -eq 'stop') {
        if ($ownedProcesses.Count -eq 0) {
            $result = New-Result -Ok $true -State 'already-stopped' -Data @{ processes = @(); unprovenProcesses = $unprovenProcesses; force = [bool]$Force }
        }
        elseif ($WhatIf) {
            $result = New-Result -Ok $true -State 'dry-run' -Data @{ processes = $ownedProcesses; unprovenProcesses = $unprovenProcesses; force = [bool]$Force }
        }
        else {
            if ($Force) {
                $resolvedRoot = [IO.Path]::GetFullPath($SteamVRRoot).TrimEnd('\') + '\'
                foreach ($process in $ownedProcesses) {
                    if ([string]::IsNullOrWhiteSpace([string]$process.path)) {
                        throw "Cannot prove executable ownership for SteamVR PID $($process.id)."
                    }
                    $resolvedProcessPath = [IO.Path]::GetFullPath([string]$process.path)
                    if (-not $resolvedProcessPath.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
                        throw "Refusing to terminate PID $($process.id): '$resolvedProcessPath' is outside '$resolvedRoot'."
                    }
                }
                foreach ($process in $ownedProcesses) {
                    Stop-Process -Id ([int]$process.id) -Force -ErrorAction SilentlyContinue
                }
            }
            else {
                $monitor = @($ownedProcesses | Where-Object name -eq 'vrmonitor' | Select-Object -First 1)
                if ($monitor.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$monitor[0].path)) {
                    $helper = Start-Process -FilePath ([string]$monitor[0].path) -ArgumentList '-shutdown' -WindowStyle Hidden -PassThru
                    $null = $helper.WaitForExit(5000)
                }
                foreach ($process in @($ownedProcesses | Where-Object name -eq 'vrmonitor')) {
                    $live = Get-Process -Id ([int]$process.id) -ErrorAction SilentlyContinue
                    if ($live) { $null = $live.CloseMainWindow() }
                }
            }

            $deadline = [DateTime]::UtcNow.AddSeconds(15)
            do {
                Start-Sleep -Milliseconds 250
                    $remaining = @(Get-SteamVRProcesses | Where-Object {
                        -not [string]::IsNullOrWhiteSpace([string]$_.path) -and
                        [IO.Path]::GetFullPath([string]$_.path).StartsWith($resolvedSteamVRRoot, [StringComparison]::OrdinalIgnoreCase)
                    })
            } while ($remaining.Count -gt 0 -and [DateTime]::UtcNow -lt $deadline)

            if ($remaining.Count -eq 0) {
                $result = New-Result -Ok $true -State 'stopped' -Data @{ processesBefore = $ownedProcesses; unprovenProcesses = $unprovenProcesses; remaining = @(); force = [bool]$Force }
            }
            else {
                $result = New-Result -Ok $false -State 'stop-incomplete' -Data @{ processesBefore = $ownedProcesses; unprovenProcesses = $unprovenProcesses; remaining = $remaining; force = [bool]$Force } -Errors @(
                    $(if ($Force) { 'One or more verified SteamVR processes remained after forced termination.' } else { 'SteamVR did not accept the graceful shutdown request; retry with -Force after reviewing the exact process inventory.' })
                )
            }
        }
    }
    elseif ($Command -eq 'inspect') {
        $providerDriver = @($externalDrivers.drivers | Where-Object name -eq ([string]$profile['headPoseProviderContract']['driverName']))
        $inputContract = Get-RuntimeInputContract -BaseContract $profile['automationInputContract'] -Effective $effective -Runtime $runtime -ExternalDrivers $externalDrivers
        $state = if ($externalDrivers.errors.Count -gt 0) { 'external-driver-inventory-failed' } elseif ($providerDriver.Count -ne 1) { 'head-pose-provider-unavailable' } elseif ($externalDrivers.conflicts.Count -gt 0) { 'external-driver-conflict' } elseif ($runtime.active -and -not $runtime.headPoseReady) { 'head-pose-provider-not-ready' } elseif ($runtime.active -and $effective.active) { 'null-runtime-active-head-pose-ready' } elseif ($effective.active) { 'null-configured-runtime-stopped' } else { 'null-inactive' }
        $result = New-Result -Ok $true -State $state -Data @{
            settingsPath = $SettingsPath
            settingsSha256 = Get-HashOrNull $SettingsPath
            profilePath = $NullProfilePath
            profileSha256 = Get-HashOrNull $NullProfilePath
            processes = $processes
            effective = $effective
            runtime = $runtime
            externalDrivers = $externalDrivers
            inputContract = $inputContract
        }
    }
    elseif ($Command -eq 'start') {
        $providerDriver = @($externalDrivers.drivers | Where-Object name -eq ([string]$profile['headPoseProviderContract']['driverName']))
        if ($externalDrivers.errors.Count -gt 0) {
            $result = New-Result -Ok $false -State 'external-driver-inventory-failed' -Data @{ effective = $effective; runtime = $runtime; externalDrivers = $externalDrivers } -Errors @('The external OpenVR driver inventory could not be read reliably; refusing null-HMD startup.')
        }
        elseif ($providerDriver.Count -ne 1) {
            $result = New-Result -Ok $false -State 'head-pose-provider-unavailable' -Data @{ effective = $effective; runtime = $runtime; externalDrivers = $externalDrivers; requiredDriverName = $profile['headPoseProviderContract']['driverName'] } -Errors @('The CSX SteamVR head-pose driver must be installed and registered exactly once before null-HMD startup.')
        }
        elseif ($externalDrivers.conflicts.Count -gt 0 -and -not $AllowExternalDisplayRedirector) {
            $names = @($externalDrivers.conflicts | ForEach-Object { if ([string]::IsNullOrWhiteSpace([string]$_.name)) { $_.root } else { $_.name } })
            $result = New-Result -Ok $false -State 'external-driver-conflict' -Data @{ effective = $effective; runtime = $runtime; externalDrivers = $externalDrivers; explicitDiagnosticOverrideRequired = $true } -Errors @("Refusing null-HMD startup because external OpenVR display driver(s) redirect the display path: $($names -join ', '). Disable or unregister the exact driver registration, or use -AllowExternalDisplayRedirector only for an explicitly authorized diagnostic coexistence run.")
        }
        elseif (-not $effective.active) {
            $result = New-Result -Ok $false -State 'null-not-configured' -Data @{ effective = $effective; runtime = $runtime } -Errors @('Apply the null-HMD settings transaction before starting SteamVR.')
        }
        elseif ($runtime.active -and -not $runtime.headPoseReady) {
            $inputContract = Get-RuntimeInputContract -BaseContract $profile['automationInputContract'] -Effective $effective -Runtime $runtime -ExternalDrivers $externalDrivers -DiagnosticDisplayOverride ([bool]$AllowExternalDisplayRedirector)
            $result = New-Result -Ok $false -State 'head-pose-provider-not-ready' -Data @{ effective = $effective; runtime = $runtime; inputContract = $inputContract } -Errors @('The Valve null display is active, but the synthetic standing head pose is not qualified.')
        }
        elseif ($runtime.active) {
            $inputContract = Get-RuntimeInputContract -BaseContract $profile['automationInputContract'] -Effective $effective -Runtime $runtime -ExternalDrivers $externalDrivers -DiagnosticDisplayOverride ([bool]$AllowExternalDisplayRedirector)
            $result = New-Result -Ok $true -State 'already-running-head-pose-ready' -Data @{ effective = $effective; runtime = $runtime; inputContract = $inputContract }
        }
        elseif ($ownedProcesses.Count -gt 0) {
            $result = New-Result -Ok $false -State 'ambiguous-runtime' -Data @{ effective = $effective; runtime = $runtime; processes = $ownedProcesses; unprovenProcesses = $unprovenProcesses } -Errors @('SteamVR processes are running from the configured root, but current-session null-driver activation is not proven. Stop and inspect them before retrying.')
        }
        else {
            if ([string]::IsNullOrWhiteSpace($EvidenceDirectory) -or -not (Test-Path -LiteralPath $EvidenceDirectory -PathType Container)) {
                throw 'start requires an existing -EvidenceDirectory owned by the apply transaction.'
            }
            $receiptPath = Join-Path $EvidenceDirectory 'steamvr-null-receipt.json'
            if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) { throw "Apply receipt is missing: $receiptPath" }
            $applyReceipt = Read-JsonHashtable -Path $receiptPath
            $isolation = if ($applyReceipt.ContainsKey('externalDriverIsolation')) { $applyReceipt['externalDriverIsolation'] } else { $null }
            $isolationValidation = if ($null -ne $isolation -and [bool]$isolation['enabled']) {
                $isolationBackupPath = [string]$isolation['backupPath']
                if (-not (Test-Path -LiteralPath $isolationBackupPath -PathType Leaf)) { throw "Exact OpenVR registration backup is missing: $isolationBackupPath" }
                if ((Get-HashOrNull $isolationBackupPath) -ne [string]$isolation['sha256Before']) { throw 'The exact OpenVR registration backup hash does not match the apply receipt.' }
                Get-IsolationValidation -Isolation $isolation -BackupPath $isolationBackupPath -CurrentPath ([string]$isolation['openVRPathsPath'])
            }
            else { $null }
            $isolationDrift = $null -ne $isolationValidation -and -not [bool]$isolationValidation.semanticMatch
            $startupPath = Join-Path $SteamVRRoot 'bin\win64\vrstartup.exe'
            if (-not (Test-Path -LiteralPath $startupPath -PathType Leaf)) { throw "SteamVR startup executable does not exist: $startupPath" }
            if ($isolationDrift) {
                $result = New-Result -Ok $false -State 'external-driver-isolation-drift' -Data @{ effective = $effective; runtime = $runtime; externalDrivers = $externalDrivers; externalDriverIsolation = $isolation; externalDriverIsolationValidation = $isolationValidation } -Errors @('The OpenVR registration file is semantically different from the isolated state reconstructed from the exact backup. Refusing startup until the drift is classified or the exact transaction is restored.')
            }
            elseif ($WhatIf) {
                $inputContract = Get-RuntimeInputContract -BaseContract $profile['automationInputContract'] -Effective $effective -Runtime $runtime -ExternalDrivers $externalDrivers -DiagnosticDisplayOverride ([bool]$AllowExternalDisplayRedirector)
                $result = New-Result -Ok $true -State 'dry-run' -Data @{ startupPath = $startupPath; effective = $effective; runtime = $runtime; externalDrivers = $externalDrivers; externalDisplayRedirectorAllowed = [bool]$AllowExternalDisplayRedirector; externalDriverIsolation = $isolation; externalDriverIsolationValidation = $isolationValidation; inputContract = $inputContract }
            }
            else {
                $startedUtc = [DateTime]::UtcNow
                $launcher = Start-Process -FilePath $startupPath -WindowStyle Hidden -PassThru
                $deadline = $startedUtc.AddSeconds($StartupTimeoutSeconds)
                do {
                    Start-Sleep -Milliseconds 250
                    $processes = @(Get-SteamVRProcesses)
                    $runtime = Get-NullRuntimeEvidence -Processes $processes -Profile $profile
                } while ((-not $runtime.active -or -not $runtime.headPoseReady) -and [DateTime]::UtcNow -lt $deadline)
                if ($runtime.active -and $runtime.headPoseReady) {
                    Start-Sleep -Seconds 2
                    $processes = @(Get-SteamVRProcesses)
                    $runtime = Get-NullRuntimeEvidence -Processes $processes -Profile $profile
                }
                $runtimeReceiptPath = Join-Path $EvidenceDirectory 'steamvr-null-runtime.receipt.json'
                $runtimeReceipt = [ordered]@{
                    schemaVersion = 1
                    startedUtc = $startedUtc.ToString('o')
                    launcherPid = $launcher.Id
                    startupPath = $startupPath
                    runtimeActive = [bool]$runtime.active
                    runtime = $runtime
                    externalDrivers = $externalDrivers
                    externalDisplayRedirectorAllowed = [bool]$AllowExternalDisplayRedirector
                    externalDriverIsolationValidation = $isolationValidation
                }
                Write-JsonAtomic -Path $runtimeReceiptPath -Value $runtimeReceipt
                $inputContract = Get-RuntimeInputContract -BaseContract $profile['automationInputContract'] -Effective $effective -Runtime $runtime -ExternalDrivers $externalDrivers -DiagnosticDisplayOverride ([bool]$AllowExternalDisplayRedirector)
                if ($runtime.active -and -not $runtime.headPoseReady) {
                    $startupCleanup = Stop-ExactStartedSteamVRProcesses -StartedUtc $startedUtc
                    $result = New-Result -Ok $false -State 'head-pose-provider-not-ready' -Data @{ effective = $effective; runtime = $runtime; runtimeReceiptPath = $runtimeReceiptPath; inputContract = $inputContract; startupCleanup = $startupCleanup } -Errors @('SteamVR activated the Valve null display, but the synthetic standing head pose was not loaded and acknowledged; exact processes started by this attempt were stopped.')
                }
                elseif ($runtime.active) {
                    $result = New-Result -Ok $true -State $(if ($AllowExternalDisplayRedirector) { 'null-runtime-started-head-pose-ready-unqualified-display-route' } else { 'null-runtime-started-head-pose-ready' }) -Data @{ effective = $effective; runtime = $runtime; runtimeReceiptPath = $runtimeReceiptPath; inputContract = $inputContract; externalDrivers = $externalDrivers; externalDisplayRedirectorAllowed = [bool]$AllowExternalDisplayRedirector; externalDriverIsolation = $isolation; externalDriverIsolationValidation = $isolationValidation }
                }
                else {
                    $startupCleanup = Stop-ExactStartedSteamVRProcesses -StartedUtc $startedUtc
                    $result = New-Result -Ok $false -State 'startup-incomplete' -Data @{ effective = $effective; runtime = $runtime; processes = $processes; runtimeReceiptPath = $runtimeReceiptPath; startupCleanup = $startupCleanup } -Errors @('SteamVR started, but current-session Valve null-driver and active-HMD log proof was not observed before the timeout; exact processes started by this attempt were stopped.')
                }
            }
        }
    }
    else {
        if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
            throw 'EvidenceDirectory is required for apply and restore.'
        }
        if (-not (Test-Path -LiteralPath $EvidenceDirectory -PathType Container)) {
            throw "Evidence directory does not exist: $EvidenceDirectory"
        }
        if ($ownedProcesses.Count -gt 0) {
            throw "SteamVR must be stopped before $Command. Running from configured root: $($ownedProcesses.name -join ', ')"
        }
        $backupPath = Join-Path $EvidenceDirectory 'steamvr.vrsettings.before'
        $openVRPathsBackupPath = Join-Path $EvidenceDirectory 'openvrpaths.vrpath.before'
        $receiptPath = Join-Path $EvidenceDirectory 'steamvr-null-receipt.json'
        $applyJournalPath = Join-Path $EvidenceDirectory 'steamvr-null-apply.journal.json'
        $restoreJournalPath = Join-Path $EvidenceDirectory 'steamvr-null-restore.journal.json'

        if ($Command -eq 'apply') {
            $null = Resolve-PendingSteamVRJournal -JournalPath $applyJournalPath
            if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                throw "Refusing to replace the existing exact backup: $backupPath"
            }
            $isolationTargets = if ($IsolateExternalDisplayRedirectors) { @(Get-ExternalDisplayIsolationTargets -Inventory $externalDrivers -RequestedRoots $ExternalDisplayRedirectorRoot) } else { @() }
            if ($IsolateExternalDisplayRedirectors -and (Test-Path -LiteralPath $openVRPathsBackupPath -PathType Leaf)) {
                throw "Refusing to replace the existing exact OpenVR registration backup: $openVRPathsBackupPath"
            }
            if ($WhatIf) {
                $result = New-Result -Ok $true -State 'dry-run' -Data @{
                    wouldBackup = $SettingsPath
                    backupPath = $backupPath
                    wouldApplyProfile = $NullProfilePath
                    settingsSha256Before = Get-HashOrNull $SettingsPath
                    externalDriverIsolation = [ordered]@{
                        enabled = [bool]$IsolateExternalDisplayRedirectors
                        openVRPathsPath = $OpenVRPathsPath
                        wouldBackupPath = if ($IsolateExternalDisplayRedirectors) { $openVRPathsBackupPath } else { $null }
                        targets = $isolationTargets
                    }
                }
            }
            else {
                Copy-Item -LiteralPath $SettingsPath -Destination $backupPath
                $beforeHash = Get-HashOrNull $backupPath
                $openVRPathsBeforeHash = $null
                $openVRPathsIsolatedHash = $null
                $openVRPathsBeforeSemanticHash = $null
                $openVRPathsIsolatedSemanticHash = $null
                $isolationMutation = $null
                if ($IsolateExternalDisplayRedirectors) {
                    if (-not (Test-Path -LiteralPath $OpenVRPathsPath -PathType Leaf)) { throw "OpenVR registration file does not exist: $OpenVRPathsPath" }
                    Copy-Item -LiteralPath $OpenVRPathsPath -Destination $openVRPathsBackupPath
                    $openVRPathsBeforeHash = Get-HashOrNull $openVRPathsBackupPath
                    $openVRPathsBeforeSemanticHash = Get-JsonSemanticSha256 -Path $openVRPathsBackupPath
                }
                $transactionId = [guid]::NewGuid().ToString('N')
                $rollbackTargets = @([ordered]@{ name = 'steamvr-settings'; path = [IO.Path]::GetFullPath($SettingsPath); backupPath = [IO.Path]::GetFullPath($backupPath); expectedHash = $beforeHash })
                if ($IsolateExternalDisplayRedirectors) { $rollbackTargets += [ordered]@{ name = 'openvr-registrations'; path = [IO.Path]::GetFullPath($OpenVRPathsPath); backupPath = [IO.Path]::GetFullPath($openVRPathsBackupPath); expectedHash = $openVRPathsBeforeHash } }
                $journal = [ordered]@{
                    contractVersion = '1.0.0'; operation = 'apply'; transactionId = $transactionId; phase = 'prepared'
                    settingsPath = [IO.Path]::GetFullPath($SettingsPath); openVRPathsPath = if ($IsolateExternalDisplayRedirectors) { [IO.Path]::GetFullPath($OpenVRPathsPath) } else { $null }
                    rollbackTargets = $rollbackTargets; preparedUtc = [DateTime]::UtcNow.ToString('o'); rollback = $null
                }
                Write-JsonAtomic -Path $applyJournalPath -Value $journal
                try {
                    if ($IsolateExternalDisplayRedirectors) {
                        $isolationMutation = Disable-ExternalDriverRegistrations -Path $OpenVRPathsPath -Targets $isolationTargets
                        $journal['phase'] = 'openvr-isolated-uncommitted'; Write-JsonAtomic -Path $applyJournalPath -Value $journal
                        if ($InternalTestFailurePoint -eq 'apply-after-openvr') { throw 'Injected apply failure after OpenVR isolation.' }
                        $isolatedInventory = Get-ExternalDriverInventory -Path $OpenVRPathsPath
                        if ($isolatedInventory.errors.Count -gt 0 -or $isolatedInventory.conflicts.Count -gt 0) {
                            throw 'External display-driver isolation did not produce a complete, conflict-free OpenVR inventory.'
                        }
                        foreach ($target in $isolationTargets) {
                            if (@($isolatedInventory.drivers | Where-Object { (Get-NormalizedPath ([string]$_.root)) -eq (Get-NormalizedPath ([string]$target.root)) }).Count -ne 0) {
                                throw "External display redirector remained registered after isolation: $($target.root)"
                            }
                        }
                        $openVRPathsIsolatedHash = Get-HashOrNull $OpenVRPathsPath
                        $openVRPathsIsolatedSemanticHash = Get-JsonSemanticSha256 -Path $OpenVRPathsPath
                    }
                    foreach ($section in @('steamvr', 'dashboard', 'driver_null', 'driver_codex_head_pose', 'TrackingOverrides')) {
                        if (-not $settings.ContainsKey($section)) { $settings[$section] = [ordered]@{} }
                        foreach ($key in $profile[$section].Keys) { $settings[$section][$key] = $profile[$section][$key] }
                    }
                    Write-JsonAtomic -Path $SettingsPath -Value $settings
                    $journal['phase'] = 'settings-applied-uncommitted'; Write-JsonAtomic -Path $applyJournalPath -Value $journal
                    $afterSettings = Read-JsonHashtable -Path $SettingsPath
                    $afterEffective = Get-EffectiveState -Settings $afterSettings -Profile $profile
                    if (-not $afterEffective.active) { throw 'The written settings do not match the null-HMD profile.' }
                    $receipt = [ordered]@{
                        schemaVersion = 2
                        operation = 'apply'
                        transactionId = $transactionId
                        journalPath = $applyJournalPath
                        appliedUtc = [DateTime]::UtcNow.ToString('o')
                        settingsPath = $SettingsPath
                        backupPath = $backupPath
                        settingsSha256Before = $beforeHash
                        settingsSha256Null = Get-HashOrNull $SettingsPath
                        profilePath = $NullProfilePath
                        profileSha256 = Get-HashOrNull $NullProfilePath
                        externalDriverIsolation = [ordered]@{
                            enabled = [bool]$IsolateExternalDisplayRedirectors
                            openVRPathsPath = if ($IsolateExternalDisplayRedirectors) { [IO.Path]::GetFullPath($OpenVRPathsPath) } else { $null }
                            backupPath = if ($IsolateExternalDisplayRedirectors) { $openVRPathsBackupPath } else { $null }
                            sha256Before = $openVRPathsBeforeHash
                            sha256Isolated = $openVRPathsIsolatedHash
                            semanticSha256Before = $openVRPathsBeforeSemanticHash
                            semanticSha256Isolated = $openVRPathsIsolatedSemanticHash
                            targets = $isolationTargets
                            mutation = $isolationMutation
                        }
                    }
                    Write-JsonAtomic -Path $receiptPath -Value $receipt
                    $journal['phase'] = 'committed'; $journal['committedUtc'] = [DateTime]::UtcNow.ToString('o'); $journal['receiptPath'] = $receiptPath
                    Write-JsonAtomic -Path $applyJournalPath -Value $journal
                }
                catch {
                    $failure = $_.Exception.Message
                    Restore-SteamVRTransactionTargets -Targets $rollbackTargets -Journal $journal -JournalPath $applyJournalPath -FailureContext "Null-HMD apply failed: $failure"
                    throw "Null-HMD apply failed; every exact backup was restored and verified. $failure"
                }
                $result = New-Result -Ok $true -State 'null-applied' -Data @{
                    settingsPath = $SettingsPath
                    backupPath = $backupPath
                    receiptPath = $receiptPath
                    settingsSha256Before = $beforeHash
                    settingsSha256Null = Get-HashOrNull $SettingsPath
                    effective = $afterEffective
                    externalDriverIsolation = $receipt['externalDriverIsolation']
                }
            }
        }
        else {
            $pendingRestore = Resolve-PendingSteamVRJournal -JournalPath $restoreJournalPath
            if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) { throw "Exact backup is missing: $backupPath" }
            if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) { throw "Apply receipt is missing: $receiptPath" }
            $receipt = Read-JsonHashtable -Path $receiptPath
            $backupHash = Get-HashOrNull $backupPath
            if ($backupHash -ne $receipt['settingsSha256Before']) { throw 'The exact backup hash does not match the apply receipt.' }
            if (-not $receipt.ContainsKey('settingsPath') -or [string]::IsNullOrWhiteSpace([string]$receipt['settingsPath'])) { throw 'The apply receipt does not identify its SteamVR settings path.' }
            if (-not [string]::Equals([IO.Path]::GetFullPath([string]$receipt['settingsPath']), [IO.Path]::GetFullPath($SettingsPath), [StringComparison]::OrdinalIgnoreCase)) {
                throw 'The requested SteamVR settings path does not match the apply receipt.'
            }
            if (-not $receipt.ContainsKey('settingsSha256Null') -or [string]::IsNullOrWhiteSpace([string]$receipt['settingsSha256Null'])) { throw 'The apply receipt does not identify the applied SteamVR settings hash.' }
            $settingsLiveHash = Get-HashOrNull $SettingsPath
            $restoreAlreadyCommitted = $null -ne $pendingRestore -and [string]$pendingRestore['phase'] -eq 'committed' -and $settingsLiveHash -eq $backupHash
            if (-not $restoreAlreadyCommitted -and $settingsLiveHash -ne [string]$receipt['settingsSha256Null']) {
                throw 'SteamVR settings changed after apply; refusing to overwrite unclassified settings drift.'
            }
            $isolation = if ($receipt.ContainsKey('externalDriverIsolation')) { $receipt['externalDriverIsolation'] } else { $null }
            $restoreExternalDrivers = $null -ne $isolation -and [bool]$isolation['enabled']
            $isolationValidation = $null
            if ($restoreExternalDrivers) {
                if ([IO.Path]::GetFullPath([string]$isolation['openVRPathsPath']) -ne [IO.Path]::GetFullPath($OpenVRPathsPath)) {
                    throw 'The requested OpenVR registration path does not match the apply receipt.'
                }
                if (-not (Test-Path -LiteralPath $openVRPathsBackupPath -PathType Leaf)) { throw "Exact OpenVR registration backup is missing: $openVRPathsBackupPath" }
                if ((Get-HashOrNull $openVRPathsBackupPath) -ne [string]$isolation['sha256Before']) { throw 'The exact OpenVR registration backup hash does not match the apply receipt.' }
                $openVRLiveHash = Get-HashOrNull $OpenVRPathsPath
                if ($restoreAlreadyCommitted) {
                    if ($openVRLiveHash -ne [string]$isolation['sha256Before']) { throw 'Committed restore journal exists but OpenVR registrations do not match the exact baseline.' }
                }
                else {
                    $isolationValidation = Get-IsolationValidation -Isolation $isolation -BackupPath $openVRPathsBackupPath -CurrentPath $OpenVRPathsPath
                    if (-not [bool]$isolationValidation.semanticMatch) { throw 'The OpenVR registration file changed semantically after isolation. Refusing to overwrite unclassified registration drift.' }
                }
                foreach ($target in @($isolation['targets'])) {
                    if ((Get-HashOrNull ([string]$target['manifestPath'])) -ne [string]$target['manifestSha256']) {
                        throw "Suppressed driver manifest changed after apply: $($target['manifestPath'])"
                    }
                }
            }
            if ($restoreAlreadyCommitted) {
                $result = New-Result -Ok $true -State 'already-restored' -Data @{
                    settingsPath = $SettingsPath; restoredSha256 = $settingsLiveHash; backupPath = $backupPath; backupRetained = $true
                    externalDriverIsolation = $isolation; openVRPathsRestoredSha256 = if ($restoreExternalDrivers) { Get-HashOrNull $OpenVRPathsPath } else { $null }
                    externalDriverIsolationValidation = $isolationValidation; restoreJournalPath = $restoreJournalPath
                }
            }
            if ($WhatIf) {
                $result = New-Result -Ok $true -State 'dry-run' -Data @{
                    wouldRestore = $backupPath
                    settingsPath = $SettingsPath
                    expectedSha256 = $backupHash
                    backupRetained = $true
                    externalDriverIsolation = $isolation
                    externalDriverIsolationValidation = $isolationValidation
                    wouldRestoreOpenVRPaths = if ($restoreExternalDrivers) { $openVRPathsBackupPath } else { $null }
                }
            }
            elseif (-not $restoreAlreadyCommitted) {
                $transactionId = [guid]::NewGuid().ToString('N')
                $settingsRollbackPath = Join-Path $EvidenceDirectory ("steamvr.vrsettings.applied.$transactionId")
                Copy-Item -LiteralPath $SettingsPath -Destination $settingsRollbackPath
                $rollbackTargets = @([ordered]@{ name = 'steamvr-settings'; path = [IO.Path]::GetFullPath($SettingsPath); backupPath = $settingsRollbackPath; expectedHash = [string]$receipt['settingsSha256Null'] })
                if ($restoreExternalDrivers) {
                    $openVRRollbackPath = Join-Path $EvidenceDirectory ("openvrpaths.vrpath.isolated.$transactionId")
                    Copy-Item -LiteralPath $OpenVRPathsPath -Destination $openVRRollbackPath
                    $rollbackTargets += [ordered]@{ name = 'openvr-registrations'; path = [IO.Path]::GetFullPath($OpenVRPathsPath); backupPath = $openVRRollbackPath; expectedHash = $openVRLiveHash }
                }
                $journal = [ordered]@{
                    contractVersion = '1.0.0'; operation = 'restore'; transactionId = $transactionId; phase = 'prepared'
                    applyTransactionId = [string]$receipt['transactionId']; settingsPath = [IO.Path]::GetFullPath($SettingsPath)
                    openVRPathsPath = if ($restoreExternalDrivers) { [IO.Path]::GetFullPath($OpenVRPathsPath) } else { $null }
                    rollbackTargets = $rollbackTargets; preparedUtc = [DateTime]::UtcNow.ToString('o'); rollback = $null
                }
                Write-JsonAtomic -Path $restoreJournalPath -Value $journal
                try {
                    Copy-FileAtomic -Source $backupPath -Destination $SettingsPath
                    $journal['phase'] = 'settings-restored-uncommitted'; Write-JsonAtomic -Path $restoreJournalPath -Value $journal
                    if ($InternalTestFailurePoint -eq 'restore-after-settings') { throw 'Injected restore failure after settings restoration.' }
                    if ($restoreExternalDrivers) { Copy-FileAtomic -Source $openVRPathsBackupPath -Destination $OpenVRPathsPath }
                    $journal['phase'] = 'all-targets-restored-uncommitted'; Write-JsonAtomic -Path $restoreJournalPath -Value $journal
                    $restoredHash = Get-HashOrNull $SettingsPath
                    if ($restoredHash -ne $backupHash) { throw 'Restored SteamVR settings hash does not match the exact backup.' }
                    if ($restoreExternalDrivers -and (Get-HashOrNull $OpenVRPathsPath) -ne [string]$isolation['sha256Before']) { throw 'Restored OpenVR registration hash does not match the exact backup.' }
                    $restoreReceiptPath = Join-Path $EvidenceDirectory ("steamvr-null-restore.$transactionId.receipt.json")
                    Write-JsonAtomic -Path $restoreReceiptPath -Value ([ordered]@{
                        schemaVersion = 1; operation = 'restore'; transactionId = $transactionId; applyTransactionId = [string]$receipt['transactionId']
                        settingsPath = [IO.Path]::GetFullPath($SettingsPath); settingsSha256Restored = $restoredHash
                        openVRPathsPath = if ($restoreExternalDrivers) { [IO.Path]::GetFullPath($OpenVRPathsPath) } else { $null }
                        openVRPathsSha256Restored = if ($restoreExternalDrivers) { Get-HashOrNull $OpenVRPathsPath } else { $null }; restoredUtc = [DateTime]::UtcNow.ToString('o')
                    })
                    $journal['phase'] = 'committed'; $journal['committedUtc'] = [DateTime]::UtcNow.ToString('o'); $journal['receiptPath'] = $restoreReceiptPath
                    Write-JsonAtomic -Path $restoreJournalPath -Value $journal
                }
                catch {
                    $failure = $_.Exception.Message
                    Restore-SteamVRTransactionTargets -Targets $rollbackTargets -Journal $journal -JournalPath $restoreJournalPath -FailureContext "Null-HMD restore failed: $failure"
                    throw "Null-HMD restore failed; the exact applied state was restored and verified. $failure"
                }
                $result = New-Result -Ok $true -State 'restored' -Data @{
                    settingsPath = $SettingsPath; restoredSha256 = $restoredHash; backupPath = $backupPath; backupRetained = $true
                    externalDriverIsolation = $isolation; openVRPathsRestoredSha256 = if ($restoreExternalDrivers) { Get-HashOrNull $OpenVRPathsPath } else { $null }
                    externalDriverIsolationValidation = $isolationValidation; restoreJournalPath = $restoreJournalPath; restoreReceiptPath = $restoreReceiptPath
                }
            }
        }
    }
}
catch {
    $result = New-Result -Ok $false -State 'blocked' -Data @{ settingsPath = $SettingsPath; profilePath = $NullProfilePath; evidenceDirectory = $EvidenceDirectory } -Errors @($_.Exception.Message)
}

$jsonParameters = @{ InputObject = $result; Depth = 20 }
if ($Compact) { $jsonParameters['Compress'] = $true }
ConvertTo-Json @jsonParameters
if (-not $result.ok -and -not $NoExit) { exit 2 }
