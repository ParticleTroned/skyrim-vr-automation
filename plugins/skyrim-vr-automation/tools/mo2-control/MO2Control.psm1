# SPDX-License-Identifier: GPL-3.0-or-later

Set-StrictMode -Version Latest

function Resolve-MO2ControlPath {
    param([Parameter(Mandatory)][string]$Path)

    return [Environment]::ExpandEnvironmentVariables($Path)
}

function Read-MO2ControlConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigPath)

    $resolved = Resolve-MO2ControlPath $ConfigPath
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "MO2 control configuration does not exist: $resolved"
    }

    try {
        $config = Get-Content -LiteralPath $resolved -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "MO2 control configuration is not valid JSON: $resolved. $($_.Exception.Message)"
    }

    foreach ($property in @('contractVersion', 'machine', 'mo2', 'defaults', 'storage', 'limits', 'session')) {
        if (-not $config.PSObject.Properties[$property]) {
            throw "MO2 control configuration is missing required property '$property': $resolved"
        }
    }

    return $config
}

function Read-MO2IniFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $sections = [ordered]@{}
    $sectionName = ''
    $sections[$sectionName] = [ordered]@{}

    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction Stop) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith(';') -or $trimmed.StartsWith('#')) {
            continue
        }

        if ($trimmed -match '^\[(.+)\]$') {
            $sectionName = $Matches[1]
            if (-not $sections.Contains($sectionName)) {
                $sections[$sectionName] = [ordered]@{}
            }
            continue
        }

        $separator = $line.IndexOf('=')
        if ($separator -lt 1) {
            continue
        }

        $key = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1).Trim()
        $sections[$sectionName][$key] = $value
    }

    return $sections
}

function ConvertFrom-MO2ByteArrayValue {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -match '^@ByteArray\((.*)\)$') {
        return $Matches[1]
    }

    return $Value
}

function ConvertTo-MO2WindowsPath {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Value
    }

    $path = $Value -replace '/', '\'
    # MO2's INI serializer may retain escaped backslashes. They are accepted by
    # Windows, but canonical paths make comparisons and diagnostics reliable.
    return ($path -replace '\\{2,}', '\')
}

function Find-MO2IniValue {
    param(
        [Parameter(Mandatory)]$Ini,
        [Parameter(Mandatory)][string]$Key
    )

    foreach ($section in $Ini.Keys) {
        if ($Ini[$section].Contains($Key)) {
            return $Ini[$section][$Key]
        }
    }

    return $null
}

function Get-MO2RegisteredExecutables {
    param([Parameter(Mandatory)]$Ini)

    if (-not $Ini.Contains('customExecutables')) {
        return @()
    }

    $groups = [ordered]@{}
    foreach ($key in $Ini['customExecutables'].Keys) {
        if ($key -notmatch '^(\d+)\\(.+)$') {
            continue
        }

        # OrderedDictionary treats an integer key as a positional index. MO2's
        # executable group number is an identifier, so retain it as a string.
        $index = [string]$Matches[1]
        $field = $Matches[2]
        if (-not $groups.Contains($index)) {
            $groups[$index] = [ordered]@{}
        }
        $groups[$index][$field] = $Ini['customExecutables'][$key]
    }

    $records = @()
    foreach ($index in ($groups.Keys | Sort-Object)) {
        $entry = $groups[$index]
        $records += [pscustomobject][ordered]@{
            index = [int]$index
            title = if ($entry.Contains('title')) { ConvertFrom-MO2ByteArrayValue $entry['title'] } else { $null }
            binary = if ($entry.Contains('binary')) { ConvertTo-MO2WindowsPath (ConvertFrom-MO2ByteArrayValue $entry['binary']) } else { $null }
            arguments = if ($entry.Contains('arguments')) { ConvertFrom-MO2ByteArrayValue $entry['arguments'] } else { $null }
            workingDirectory = if ($entry.Contains('workingDirectory')) { ConvertTo-MO2WindowsPath (ConvertFrom-MO2ByteArrayValue $entry['workingDirectory']) } else { $null }
        }
    }

    return @($records)
}

function Get-MO2ProcessRecords {
    param([string[]]$Names)

    $records = @()
    foreach ($name in @($Names | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        foreach ($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            $records += [pscustomobject][ordered]@{
                name = $process.ProcessName
                id = $process.Id
                startTime = $(try { $process.StartTime.ToUniversalTime().ToString('o') } catch { $null })
                cpuSeconds = $(try { [math]::Round($process.CPU, 3) } catch { $null })
                workingSetBytes = $(try { [long]$process.WorkingSet64 } catch { $null })
            }
        }
    }

    return @($records | Sort-Object name, id)
}

function Get-MO2BoundedDirectoryStats {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$MaximumFiles
    )

    $result = [ordered]@{
        path = $Path
        exists = Test-Path -LiteralPath $Path -PathType Container
        fileCount = 0
        bytes = [long]0
        truncated = $false
        errors = @()
    }

    if (-not $result.exists) {
        return [pscustomobject]$result
    }

    try {
        $enumerator = [System.IO.Directory]::EnumerateFiles(
            $Path,
            '*',
            [System.IO.SearchOption]::AllDirectories
        ).GetEnumerator()

        try {
            while ($enumerator.MoveNext()) {
                if ($result.fileCount -ge $MaximumFiles) {
                    $result.truncated = $true
                    break
                }

                $result.fileCount++
                try {
                    $result.bytes += [System.IO.FileInfo]::new($enumerator.Current).Length
                }
                catch {
                    $result.errors += "Could not stat '$($enumerator.Current)': $($_.Exception.Message)"
                }
            }
        }
        finally {
            if ($enumerator -is [System.IDisposable]) {
                $enumerator.Dispose()
            }
        }
    }
    catch {
        $result.errors += $_.Exception.Message
    }

    return [pscustomobject]$result
}

function Get-MO2JsonRecord {
    param(
        [Parameter(Mandatory)][string]$Path,
        [bool]$Archived = $false
    )

    $record = [ordered]@{
        path = $Path
        exists = Test-Path -LiteralPath $Path -PathType Leaf
        archived = $Archived
        valid = $false
        bytes = $null
        lastWriteTimeUtc = $null
        error = $null
    }

    if (-not $record.exists) {
        $record.error = 'File does not exist.'
        return [pscustomobject]$record
    }

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    $record.bytes = [long]$item.Length
    $record.lastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')

    if ($Archived) {
        $record.valid = $null
        return [pscustomobject]$record
    }

    try {
        $null = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $record.valid = $true
    }
    catch {
        $record.error = $_.Exception.Message
    }

    return [pscustomobject]$record
}

function Get-MO2RootBuilderRecords {
    param([Parameter(Mandatory)]$Config)

    $active = @()
    $archived = @()

    foreach ($pathValue in @($Config.mo2.rootBuilderDefinitions)) {
        $path = Resolve-MO2ControlPath ([string]$pathValue)
        $active += Get-MO2JsonRecord -Path $path
    }

    $dataRoot = Resolve-MO2ControlPath ([string]$Config.mo2.rootBuilderDataDirectory)
    if (Test-Path -LiteralPath $dataRoot -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $dataRoot -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue)) {
            if ($file.Name -match '(?i)\.corrupt-') {
                $archived += Get-MO2JsonRecord -Path $file.FullName -Archived $true
            }
            elseif ($file.Name -in @('BuildData.json', 'GameData.json', 'VersionManifest.json')) {
                $active += Get-MO2JsonRecord -Path $file.FullName
            }
        }
    }

    return [pscustomobject][ordered]@{
        dataDirectory = $dataRoot
        active = @($active)
        archived = @($archived)
    }
}

function Get-MO2StorageRecord {
    param([Parameter(Mandatory)][string]$Path)

    $resolved = Resolve-MO2ControlPath $Path
    $qualifier = Split-Path -Qualifier $resolved
    $driveRoot = if ($qualifier) { "$qualifier\" } else { $null }

    return [pscustomobject][ordered]@{
        path = $resolved
        exists = Test-Path -LiteralPath $resolved -PathType Container
        drive = $qualifier
        driveAvailable = if ($driveRoot) { Test-Path -LiteralPath $driveRoot -PathType Container } else { $false }
    }
}

function Get-MO2SessionLockRecord {
    param([Parameter(Mandatory)][string]$Path)

    $resolved = Resolve-MO2ControlPath $Path
    $record = [ordered]@{
        path = $resolved
        exists = Test-Path -LiteralPath $resolved -PathType Leaf
        valid = $null
        ownerPid = $null
        ownerRunning = $false
        sessionId = $null
        status = $null
        data = $null
        error = $null
    }

    if (-not $record.exists) {
        return [pscustomobject]$record
    }

    try {
        $data = Get-Content -LiteralPath $resolved -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $record.valid = $true
        $record.data = $data
        if ($data.PSObject.Properties['ownerPid']) {
            $record.ownerPid = [int]$data.ownerPid
            $record.ownerRunning = $null -ne (Get-Process -Id $record.ownerPid -ErrorAction SilentlyContinue)
        }
        if ($data.PSObject.Properties['sessionId']) {
            $record.sessionId = [string]$data.sessionId
        }
        if ($data.PSObject.Properties['status']) {
            $record.status = [string]$data.status
        }
    }
    catch {
        $record.valid = $false
        $record.error = $_.Exception.Message
    }

    return [pscustomobject]$record
}

function New-MO2Check {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('pass', 'warn', 'fail', 'info')][string]$Status,
        [Parameter(Mandatory)][string]$Message,
        $Details = $null
    )

    return [pscustomobject][ordered]@{
        name = $Name
        status = $Status
        message = $Message
        details = $Details
    }
}

function Get-MO2InspectionData {
    param(
        [Parameter(Mandatory)]$Config,
        [string]$RequestedProfile,
        [string]$RequestedExecutable
    )

    $mo2Root = Resolve-MO2ControlPath ([string]$Config.mo2.root)
    $mo2Exe = Resolve-MO2ControlPath ([string]$Config.mo2.executable)
    $mo2Ini = Resolve-MO2ControlPath ([string]$Config.mo2.ini)
    $profilesRoot = Resolve-MO2ControlPath ([string]$Config.mo2.profilesDirectory)
    $overwriteRoot = Resolve-MO2ControlPath ([string]$Config.mo2.overwriteDirectory)

    $ini = if (Test-Path -LiteralPath $mo2Ini -PathType Leaf) { Read-MO2IniFile -Path $mo2Ini } else { [ordered]@{} }
    $selectedProfile = if ($ini.Count -gt 0) { ConvertFrom-MO2ByteArrayValue (Find-MO2IniValue -Ini $ini -Key 'selected_profile') } else { $null }
    $profiles = if (Test-Path -LiteralPath $profilesRoot -PathType Container) {
        @(Get-ChildItem -LiteralPath $profilesRoot -Directory -ErrorAction Stop | Sort-Object Name | ForEach-Object Name)
    }
    else {
        @()
    }
    $executables = if ($ini.Count -gt 0) { @(Get-MO2RegisteredExecutables -Ini $ini) } else { @() }

    $profile = if ([string]::IsNullOrWhiteSpace($RequestedProfile)) { [string]$Config.defaults.profile } else { $RequestedProfile }
    $executable = if ([string]::IsNullOrWhiteSpace($RequestedExecutable)) { [string]$Config.defaults.executable } else { $RequestedExecutable }

    $mo2Processes = @(Get-MO2ProcessRecords -Names @($Config.mo2.processNames))
    $gameProcesses = @(Get-MO2ProcessRecords -Names @($Config.mo2.gameProcessNames))
    $runtimeProcesses = @(Get-MO2ProcessRecords -Names @($Config.mo2.runtimeProcessNames))

    return [pscustomobject][ordered]@{
        machine = [string]$Config.machine
        config = [pscustomobject][ordered]@{
            mo2Root = $mo2Root
            mo2Executable = $mo2Exe
            mo2Ini = $mo2Ini
            profilesDirectory = $profilesRoot
        }
        requested = [pscustomobject][ordered]@{
            profile = $profile
            executable = $executable
        }
        selectedProfile = $selectedProfile
        profiles = @($profiles)
        executables = @($executables)
        processes = [pscustomobject][ordered]@{
            mo2 = @($mo2Processes)
            game = @($gameProcesses)
            runtime = @($runtimeProcesses)
        }
        overwrite = Get-MO2BoundedDirectoryStats -Path $overwriteRoot -MaximumFiles ([int]$Config.limits.maxEnumeratedFiles)
        rootBuilder = Get-MO2RootBuilderRecords -Config $Config
        storage = [pscustomobject][ordered]@{
            staging = Get-MO2StorageRecord -Path ([string]$Config.storage.sessionStaging)
            archive = Get-MO2StorageRecord -Path ([string]$Config.storage.archive)
        }
        sessionLock = Get-MO2SessionLockRecord -Path ([string]$Config.session.lockFile)
    }
}

function ConvertTo-MO2Result {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][object[]]$Checks,
        [Parameter(Mandatory)]$Data,
        [string]$PreferredState
    )

    $errors = @($Checks | Where-Object status -eq 'fail' | ForEach-Object message)
    $warnings = @($Checks | Where-Object status -eq 'warn' | ForEach-Object message)
    $ok = $errors.Count -eq 0

    if (-not [string]::IsNullOrWhiteSpace($PreferredState)) {
        $state = $PreferredState
    }
    elseif (-not $ok) {
        $state = 'blocked'
    }
    elseif ($Data.processes.game.Count -gt 0) {
        $state = 'game-running'
    }
    elseif ($Data.processes.mo2.Count -gt 0) {
        $state = 'mo2-running'
    }
    elseif ($warnings.Count -gt 0) {
        $state = 'degraded'
    }
    else {
        $state = 'ready'
    }

    return [pscustomobject][ordered]@{
        contractVersion = [string]$Config.contractVersion
        command = $Command
        ok = $ok
        state = $state
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        checks = @($Checks)
        warnings = @($warnings)
        errors = @($errors)
        data = $Data
    }
}

function Invoke-MO2Inspect {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [string]$Profile,
        [string]$Executable
    )

    $data = Get-MO2InspectionData -Config $Config -RequestedProfile $Profile -RequestedExecutable $Executable
    $checks = @()

    $checks += New-MO2Check -Name 'mo2-root' -Status $(if (Test-Path -LiteralPath $data.config.mo2Root -PathType Container) { 'pass' } else { 'fail' }) -Message $(if (Test-Path -LiteralPath $data.config.mo2Root -PathType Container) { 'MO2 root exists.' } else { "MO2 root does not exist: $($data.config.mo2Root)" })
    $checks += New-MO2Check -Name 'mo2-executable' -Status $(if (Test-Path -LiteralPath $data.config.mo2Executable -PathType Leaf) { 'pass' } else { 'fail' }) -Message $(if (Test-Path -LiteralPath $data.config.mo2Executable -PathType Leaf) { 'MO2 executable exists.' } else { "MO2 executable does not exist: $($data.config.mo2Executable)" })
    $checks += New-MO2Check -Name 'mo2-ini' -Status $(if (Test-Path -LiteralPath $data.config.mo2Ini -PathType Leaf) { 'pass' } else { 'fail' }) -Message $(if (Test-Path -LiteralPath $data.config.mo2Ini -PathType Leaf) { 'MO2 INI exists and was read.' } else { "MO2 INI does not exist: $($data.config.mo2Ini)" })
    $checks += New-MO2Check -Name 'process-state' -Status 'info' -Message "MO2=$($data.processes.mo2.Count), game=$($data.processes.game.Count), runtime=$($data.processes.runtime.Count)."
    $overwriteNeedsAttention = (
        $data.overwrite.errors.Count -gt 0 -or
        $data.overwrite.truncated -or
        $data.overwrite.fileCount -ge [int]$Config.limits.overwriteWarningFiles -or
        $data.overwrite.bytes -ge [long]$Config.limits.overwriteWarningBytes
    )
    $checks += New-MO2Check -Name 'overwrite-scan' -Status $(if ($overwriteNeedsAttention) { 'warn' } else { 'pass' }) -Message $(
        if ($data.overwrite.errors.Count -gt 0) { 'Overwrite inspection completed with filesystem errors.' }
        elseif ($data.overwrite.truncated) { "Overwrite inspection stopped at the configured limit of $($Config.limits.maxEnumeratedFiles) files." }
        elseif ($overwriteNeedsAttention) { "Overwrite needs attention: $($data.overwrite.fileCount) files using $($data.overwrite.bytes) bytes." }
        else { "Overwrite contains $($data.overwrite.fileCount) files using $($data.overwrite.bytes) bytes." }
    ) -Details $data.overwrite

    return ConvertTo-MO2Result -Config $Config -Command 'inspect' -Checks $checks -Data $data
}

function Invoke-MO2Validate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [string]$Profile,
        [string]$Executable,
        [switch]$RequireClosed,
        [string]$OwnedSessionId
    )

    $data = Get-MO2InspectionData -Config $Config -RequestedProfile $Profile -RequestedExecutable $Executable
    $checks = @()

    foreach ($pathCheck in @(
        @{ Name = 'mo2-root'; Path = $data.config.mo2Root; Type = 'Container' },
        @{ Name = 'mo2-executable'; Path = $data.config.mo2Executable; Type = 'Leaf' },
        @{ Name = 'mo2-ini'; Path = $data.config.mo2Ini; Type = 'Leaf' },
        @{ Name = 'profiles-directory'; Path = $data.config.profilesDirectory; Type = 'Container' }
    )) {
        $exists = Test-Path -LiteralPath $pathCheck.Path -PathType $pathCheck.Type
        $checks += New-MO2Check -Name $pathCheck.Name -Status $(if ($exists) { 'pass' } else { 'fail' }) -Message $(if ($exists) { "$($pathCheck.Name) exists." } else { "$($pathCheck.Name) is missing: $($pathCheck.Path)" })
    }

    $profileExists = $data.profiles -contains $data.requested.profile
    $checks += New-MO2Check -Name 'requested-profile' -Status $(if ($profileExists) { 'pass' } else { 'fail' }) -Message $(if ($profileExists) { "Exact profile exists: $($data.requested.profile)" } else { "Exact profile does not exist: $($data.requested.profile). No fallback is permitted." }) -Details @{ availableProfiles = $data.profiles }

    if ($profileExists -and $data.selectedProfile -ne $data.requested.profile) {
        $checks += New-MO2Check -Name 'selected-profile' -Status 'warn' -Message "MO2 currently selects '$($data.selectedProfile)', not requested '$($data.requested.profile)'."
    }
    else {
        $checks += New-MO2Check -Name 'selected-profile' -Status 'pass' -Message "MO2 selected profile matches the request: $($data.requested.profile)"
    }

    $registered = @($data.executables | Where-Object title -eq $data.requested.executable)
    if ($registered.Count -eq 1) {
        $checks += New-MO2Check -Name 'registered-executable' -Status 'pass' -Message "Registered executable exists exactly once: $($data.requested.executable)" -Details $registered[0]
        $binaryExists = -not [string]::IsNullOrWhiteSpace($registered[0].binary) -and (Test-Path -LiteralPath $registered[0].binary -PathType Leaf)
        $checks += New-MO2Check -Name 'registered-binary' -Status $(if ($binaryExists) { 'pass' } else { 'fail' }) -Message $(if ($binaryExists) { "Registered binary exists: $($registered[0].binary)" } else { "Registered binary is missing: $($registered[0].binary)" })
        if (-not [string]::IsNullOrWhiteSpace($registered[0].workingDirectory)) {
            $workingExists = Test-Path -LiteralPath $registered[0].workingDirectory -PathType Container
            $checks += New-MO2Check -Name 'registered-working-directory' -Status $(if ($workingExists) { 'pass' } else { 'fail' }) -Message $(if ($workingExists) { "Registered working directory exists: $($registered[0].workingDirectory)" } else { "Registered working directory is missing: $($registered[0].workingDirectory)" })
        }
    }
    elseif ($registered.Count -eq 0) {
        $checks += New-MO2Check -Name 'registered-executable' -Status 'fail' -Message "Registered executable does not exist: $($data.requested.executable)" -Details @{ availableExecutables = @($data.executables.title) }
    }
    else {
        $checks += New-MO2Check -Name 'registered-executable' -Status 'fail' -Message "Registered executable is ambiguous ($($registered.Count) matches): $($data.requested.executable)"
    }

    $invalidJson = @($data.rootBuilder.active | Where-Object { -not $_.exists -or $_.valid -ne $true })
    $checks += New-MO2Check -Name 'rootbuilder-json' -Status $(if ($invalidJson.Count -eq 0) { 'pass' } else { 'fail' }) -Message $(if ($invalidJson.Count -eq 0) { "All $($data.rootBuilder.active.Count) active RootBuilder JSON files parse successfully." } else { "$($invalidJson.Count) active RootBuilder JSON file(s) are missing or invalid." }) -Details $invalidJson
    if ($data.rootBuilder.archived.Count -gt 0) {
        $checks += New-MO2Check -Name 'rootbuilder-archives' -Status 'warn' -Message "$($data.rootBuilder.archived.Count) quarantined RootBuilder JSON artifact(s) are retained as diagnostic evidence; they are not active state." -Details $data.rootBuilder.archived
    }

    if (-not $data.overwrite.exists) {
        $checks += New-MO2Check -Name 'overwrite' -Status 'fail' -Message "MO2 overwrite directory does not exist: $($data.overwrite.path)"
    }
    elseif ($data.overwrite.errors.Count -gt 0) {
        $checks += New-MO2Check -Name 'overwrite' -Status 'fail' -Message 'MO2 overwrite inspection encountered filesystem errors.' -Details $data.overwrite
    }
    elseif ($data.overwrite.truncated -or $data.overwrite.fileCount -ge [int]$Config.limits.overwriteBlockFiles -or $data.overwrite.bytes -ge [long]$Config.limits.overwriteBlockBytes) {
        $checks += New-MO2Check -Name 'overwrite' -Status 'fail' -Message "MO2 overwrite exceeds or cannot be proven below the automation safety limit: files=$($data.overwrite.fileCount), bytes=$($data.overwrite.bytes), truncated=$($data.overwrite.truncated)." -Details $data.overwrite
    }
    elseif ($data.overwrite.fileCount -ge [int]$Config.limits.overwriteWarningFiles -or $data.overwrite.bytes -ge [long]$Config.limits.overwriteWarningBytes) {
        $checks += New-MO2Check -Name 'overwrite' -Status 'warn' -Message "MO2 overwrite is above the warning threshold: files=$($data.overwrite.fileCount), bytes=$($data.overwrite.bytes)." -Details $data.overwrite
    }
    else {
        $checks += New-MO2Check -Name 'overwrite' -Status 'pass' -Message "MO2 overwrite is below automation thresholds: files=$($data.overwrite.fileCount), bytes=$($data.overwrite.bytes)." -Details $data.overwrite
    }

    foreach ($storageName in @('staging', 'archive')) {
        $record = $data.storage.$storageName
        if ($record.exists) {
            $checks += New-MO2Check -Name "storage-$storageName" -Status 'pass' -Message "Storage directory exists: $($record.path)"
        }
        elseif ($record.driveAvailable) {
            $checks += New-MO2Check -Name "storage-$storageName" -Status 'warn' -Message "Storage drive is available but the directory has not been created: $($record.path)"
        }
        else {
            $checks += New-MO2Check -Name "storage-$storageName" -Status 'fail' -Message "Storage drive is unavailable: $($record.path)"
        }
    }

    if ($data.sessionLock.exists -and $data.sessionLock.valid -and -not [string]::IsNullOrWhiteSpace($OwnedSessionId) -and $data.sessionLock.sessionId -eq $OwnedSessionId) {
        $checks += New-MO2Check -Name 'session-lock' -Status 'pass' -Message "The requested control session owns the lock: $OwnedSessionId" -Details $data.sessionLock
    }
    elseif ($data.sessionLock.exists -and $data.sessionLock.valid) {
        $checks += New-MO2Check -Name 'session-lock' -Status 'fail' -Message "Another MO2 control session owns the lock: $($data.sessionLock.sessionId)" -Details $data.sessionLock
    }
    elseif ($data.sessionLock.exists) {
        $checks += New-MO2Check -Name 'session-lock' -Status 'warn' -Message 'A stale or invalid session lock exists and requires documented recovery before mutation.' -Details $data.sessionLock
    }
    else {
        $checks += New-MO2Check -Name 'session-lock' -Status 'pass' -Message 'No active MO2 control session lock exists.'
    }

    if ($RequireClosed) {
        $closed = $data.processes.mo2.Count -eq 0 -and $data.processes.game.Count -eq 0
        $checks += New-MO2Check -Name 'closed-state' -Status $(if ($closed) { 'pass' } else { 'fail' }) -Message $(if ($closed) { 'MO2 and game processes are closed.' } else { 'MO2 or the game is running; closed-state validation failed.' }) -Details $data.processes
    }
    else {
        $checks += New-MO2Check -Name 'closed-state' -Status 'info' -Message "Closed state was not required. MO2=$($data.processes.mo2.Count), game=$($data.processes.game.Count)."
    }

    return ConvertTo-MO2Result -Config $Config -Command 'validate' -Checks $checks -Data $data
}

function ConvertTo-MO2SafeLabel {
    param([Parameter(Mandatory)][string]$Label)

    $safe = ($Label.Trim() -replace '[^A-Za-z0-9._-]+', '-') -replace '-{2,}', '-'
    $safe = $safe.Trim('-', '.')
    if ([string]::IsNullOrWhiteSpace($safe)) {
        return 'automation'
    }
    if ($safe.Length -gt 48) {
        return $safe.Substring(0, 48)
    }
    return $safe
}

function ConvertTo-MO2CommandLineArgument {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    if ($Value -notmatch '[\s"]') {
        return $Value
    }
    return '"' + (($Value -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

function Write-MO2JsonAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value,
        [switch]$CreateNew
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $json = $Value | ConvertTo-Json -Depth 16
    $encoding = [System.Text.UTF8Encoding]::new($false)
    if ($CreateNew) {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $writer = [System.IO.StreamWriter]::new($stream, $encoding)
            try { $writer.Write($json) } finally { $writer.Dispose() }
        }
        finally {
            if ($stream) { $stream.Dispose() }
        }
        return
    }

    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllText($temporary, $json, $encoding)
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Get-MO2OwnedSession {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SessionId
    )

    if ([string]::IsNullOrWhiteSpace($SessionId)) {
        throw 'SessionId is required for this command.'
    }
    $lockPath = Resolve-MO2ControlPath ([string]$Config.session.lockFile)
    $lock = Get-MO2SessionLockRecord -Path $lockPath
    if (-not $lock.exists) {
        throw "No MO2 control session lock exists: $lockPath"
    }
    if (-not $lock.valid) {
        throw "The MO2 control session lock is invalid: $($lock.error)"
    }
    if ($lock.sessionId -ne $SessionId) {
        throw "Session '$SessionId' does not own the active lock '$($lock.sessionId)'."
    }
    if (-not $lock.data.PSObject.Properties['sessionPath'] -or -not (Test-Path -LiteralPath ([string]$lock.data.sessionPath) -PathType Container)) {
        throw 'The active lock does not reference an existing session directory.'
    }
    return $lock
}

function New-MO2ActionResult {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][bool]$Ok,
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)]$Data,
        [string[]]$Warnings = @(),
        [string[]]$Errors = @()
    )

    $cleanWarnings = @($Warnings | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $cleanErrors = @($Errors | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })

    return [pscustomobject][ordered]@{
        contractVersion = [string]$Config.contractVersion
        command = $Command
        ok = $Ok
        state = $State
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        checks = @()
        warnings = $cleanWarnings
        errors = $cleanErrors
        data = $Data
    }
}

function Invoke-MO2Prepare {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [string]$Profile,
        [string]$Executable,
        [string]$Label = 'automation',
        [switch]$WhatIf
    )

    $validation = Invoke-MO2Validate -Config $Config -Profile $Profile -Executable $Executable -RequireClosed
    if (-not $validation.ok) {
        return New-MO2ActionResult -Config $Config -Command 'prepare' -Ok $false -State 'blocked' -Data @{ validation = $validation } -Warnings $validation.warnings -Errors $validation.errors
    }

    $profileName = [string]$validation.data.requested.profile
    $executableName = [string]$validation.data.requested.executable
    $safeLabel = ConvertTo-MO2SafeLabel $Label
    $sessionId = '{0}-{1}-{2}' -f ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')), $safeLabel, ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $stagingRoot = Resolve-MO2ControlPath ([string]$Config.storage.sessionStaging)
    $sessionPath = Join-Path $stagingRoot $sessionId
    $lockPath = Resolve-MO2ControlPath ([string]$Config.session.lockFile)
    $arguments = @('--profile', $profileName, 'run', '--executable', $executableName)

    $manifest = [pscustomobject][ordered]@{
        contractVersion = [string]$Config.contractVersion
        sessionId = $sessionId
        label = $safeLabel
        createdUtc = [DateTime]::UtcNow.ToString('o')
        status = 'prepared'
        profile = $profileName
        executable = $executableName
        mo2Path = [string]$validation.data.config.mo2Executable
        arguments = $arguments
        selectedProfileBefore = [string]$validation.data.selectedProfile
        launcherPid = $null
        launchedUtc = $null
        stoppedUtc = $null
    }
    $lock = [pscustomobject][ordered]@{
        contractVersion = [string]$Config.contractVersion
        sessionId = $sessionId
        sessionPath = $sessionPath
        status = 'prepared'
        createdUtc = $manifest.createdUtc
        profile = $profileName
        executable = $executableName
        ownerPid = $PID
    }

    if ($WhatIf) {
        return New-MO2ActionResult -Config $Config -Command 'prepare' -Ok $true -State 'dry-run' -Data @{ session = $manifest; sessionPath = $sessionPath; lockPath = $lockPath; wouldCreate = @($sessionPath, (Join-Path $sessionPath 'session.json'), $lockPath) } -Warnings $validation.warnings
    }

    if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
        return New-MO2ActionResult -Config $Config -Command 'prepare' -Ok $false -State 'blocked' -Data @{ lock = Get-MO2SessionLockRecord -Path $lockPath } -Errors @("An MO2 control session lock already exists: $lockPath")
    }

    New-Item -ItemType Directory -Path $sessionPath -ErrorAction Stop | Out-Null
    try {
        Write-MO2JsonAtomic -Path (Join-Path $sessionPath 'session.json') -Value $manifest -CreateNew
        Write-MO2JsonAtomic -Path $lockPath -Value $lock -CreateNew
    }
    catch {
        throw "Failed to prepare session '$sessionId'. The evidence directory is retained at '$sessionPath'. $($_.Exception.Message)"
    }

    return New-MO2ActionResult -Config $Config -Command 'prepare' -Ok $true -State 'prepared' -Data @{ session = $manifest; sessionPath = $sessionPath; lockPath = $lockPath } -Warnings $validation.warnings
}

function Invoke-MO2Status {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [string]$SessionId
    )

    $requestedProfile = $null
    $requestedExecutable = $null
    if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
        $owned = Get-MO2OwnedSession -Config $Config -SessionId $SessionId
        $requestedProfile = [string]$owned.data.profile
        $requestedExecutable = [string]$owned.data.executable
    }
    $data = Get-MO2InspectionData -Config $Config -RequestedProfile $requestedProfile -RequestedExecutable $requestedExecutable
    $state = if ($data.processes.game.Count -gt 0) { 'game-running' } elseif ($data.processes.mo2.Count -gt 0) { 'mo2-running' } elseif ($data.sessionLock.exists) { [string]$data.sessionLock.status } else { 'closed' }
    return New-MO2ActionResult -Config $Config -Command 'status' -Ok $true -State $state -Data $data
}

function Invoke-MO2Launch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SessionId,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 90,
        [switch]$WhatIf
    )

    $owned = Get-MO2OwnedSession -Config $Config -SessionId $SessionId
    $lockData = $owned.data
    if ([string]$lockData.status -notin @('prepared', 'launch-failed', 'game-stopped', 'stop-incomplete')) {
        return New-MO2ActionResult -Config $Config -Command 'launch' -Ok $false -State 'blocked' -Data @{ lock = $owned } -Errors @("Session status '$($lockData.status)' cannot be launched.")
    }

    $resumeExistingMO2 = [string]$lockData.status -in @('game-stopped', 'stop-incomplete')
    $validation = Invoke-MO2Validate -Config $Config -Profile ([string]$lockData.profile) -Executable ([string]$lockData.executable) -RequireClosed:(-not $resumeExistingMO2) -OwnedSessionId $SessionId
    if (-not $validation.ok) {
        return New-MO2ActionResult -Config $Config -Command 'launch' -Ok $false -State 'blocked' -Data @{ validation = $validation; lock = $owned } -Warnings $validation.warnings -Errors $validation.errors
    }
    if ($resumeExistingMO2) {
        $mo2Processes = @($validation.data.processes.mo2)
        $ownerPid = if ($lockData.PSObject.Properties['ownerPid']) { [int]$lockData.ownerPid } else { 0 }
        $ownedMO2 = @($mo2Processes | Where-Object { [int]$_.id -eq $ownerPid })
        if ($validation.data.processes.game.Count -gt 0 -or $mo2Processes.Count -ne 1 -or $ownedMO2.Count -ne 1) {
            return New-MO2ActionResult -Config $Config -Command 'launch' -Ok $false -State 'blocked' -Data @{ processes = $validation.data.processes; lock = $owned } -Errors @('Resume requires no game process and exactly one MO2 process matching the session owner PID.')
        }
    }

    $mo2Path = [string]$validation.data.config.mo2Executable
    $arguments = @('--profile', [string]$lockData.profile, 'run', '--executable', [string]$lockData.executable)
    $argumentLine = ($arguments | ForEach-Object { ConvertTo-MO2CommandLineArgument ([string]$_) }) -join ' '
    if ($WhatIf) {
        return New-MO2ActionResult -Config $Config -Command 'launch' -Ok $true -State 'dry-run' -Data @{ path = $mo2Path; arguments = $arguments; argumentLine = $argumentLine; workingDirectory = (Split-Path -Parent $mo2Path); sessionId = $SessionId }
    }

    $process = Start-Process -FilePath $mo2Path -ArgumentList $argumentLine -WorkingDirectory (Split-Path -Parent $mo2Path) -WindowStyle Hidden -PassThru
    $lockData.status = 'launching'
    if (-not $resumeExistingMO2) {
        if ($lockData.PSObject.Properties['ownerPid']) { $lockData.ownerPid = $process.Id } else { $lockData | Add-Member -NotePropertyName ownerPid -NotePropertyValue $process.Id }
    }
    if ($lockData.PSObject.Properties['latestLauncherPid']) { $lockData.latestLauncherPid = $process.Id } else { $lockData | Add-Member -NotePropertyName latestLauncherPid -NotePropertyValue $process.Id }
    if ($lockData.PSObject.Properties['launchedUtc']) { $lockData.launchedUtc = [DateTime]::UtcNow.ToString('o') } else { $lockData | Add-Member -NotePropertyName launchedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) }
    Write-MO2JsonAtomic -Path $owned.path -Value $lockData

    $primaryGameProcessName = [string]@($Config.mo2.gameProcessNames)[0]
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $status = $null
    do {
        Start-Sleep -Milliseconds 500
        $status = Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$lockData.profile) -RequestedExecutable ([string]$lockData.executable)
        if (@($status.processes.game | Where-Object { $_.name -ieq $primaryGameProcessName }).Count -gt 0) { break }
    } while ([DateTime]::UtcNow -lt $deadline)

    $gameObserved = @($status.processes.game | Where-Object { $_.name -ieq $primaryGameProcessName }).Count -gt 0
    $lockData.status = if ($gameObserved) { 'running' } else { 'launch-failed' }
    Write-MO2JsonAtomic -Path $owned.path -Value $lockData
    $manifestPath = Join-Path ([string]$lockData.sessionPath) 'session.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifest.status = $lockData.status
    $manifest.launcherPid = $process.Id
    $manifest.launchedUtc = $lockData.launchedUtc
    Write-MO2JsonAtomic -Path $manifestPath -Value $manifest

    if (-not $gameObserved) {
        return New-MO2ActionResult -Config $Config -Command 'launch' -Ok $false -State 'launch-failed' -Data @{ launcherPid = $process.Id; launcherExited = $process.HasExited; launcherExitCode = $(if ($process.HasExited) { $process.ExitCode } else { $null }); primaryGameProcessName = $primaryGameProcessName; processes = $status.processes; sessionPath = $lockData.sessionPath } -Errors @("The primary game process '$primaryGameProcessName' was not observed within $TimeoutSeconds seconds. A launcher helper exit is non-terminal because an existing MO2 instance can accept the request asynchronously.")
    }
    return New-MO2ActionResult -Config $Config -Command 'launch' -Ok $true -State 'game-running' -Data @{ launcherPid = $process.Id; primaryGameProcessName = $primaryGameProcessName; processes = $status.processes; sessionPath = $lockData.sessionPath }
}

function Invoke-MO2StopGame {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SessionId,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 90,
        [switch]$WhatIf
    )

    $owned = Get-MO2OwnedSession -Config $Config -SessionId $SessionId
    $before = Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$owned.data.profile) -RequestedExecutable ([string]$owned.data.executable)
    $targets = @($before.processes.game)
    if ($WhatIf) {
        return New-MO2ActionResult -Config $Config -Command 'stop-game' -Ok $true -State 'dry-run' -Data @{ sessionId = $SessionId; wouldRequestClose = $targets; wouldLeaveMO2Running = $true; forceTermination = $false }
    }

    foreach ($record in $targets) {
        $process = Get-Process -Id ([int]$record.id) -ErrorAction SilentlyContinue
        if ($process) { $null = $process.CloseMainWindow() }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 500
        $after = Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$owned.data.profile) -RequestedExecutable ([string]$owned.data.executable)
        if ($after.processes.game.Count -eq 0) { break }
    } while ([DateTime]::UtcNow -lt $deadline)

    $closed = $after.processes.game.Count -eq 0
    $owned.data.status = if ($closed) { 'game-stopped' } else { 'game-stop-incomplete' }
    Write-MO2JsonAtomic -Path $owned.path -Value $owned.data
    $manifestPath = Join-Path ([string]$owned.data.sessionPath) 'session.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifest.status = $owned.data.status
    $manifest.stoppedUtc = [DateTime]::UtcNow.ToString('o')
    Write-MO2JsonAtomic -Path $manifestPath -Value $manifest

    return New-MO2ActionResult -Config $Config -Command 'stop-game' -Ok $closed -State $owned.data.status -Data @{ before = $before.processes; after = $after.processes; mo2Retained = $after.processes.mo2.Count -gt 0; forceTermination = $false; sessionPath = $owned.data.sessionPath } -Errors $(if ($closed) { @() } else { @('The game did not accept a graceful close request; no force termination was attempted.') })
}

function Invoke-MO2Stop {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SessionId,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 90,
        [switch]$WhatIf
    )

    $owned = Get-MO2OwnedSession -Config $Config -SessionId $SessionId
    $before = Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$owned.data.profile) -RequestedExecutable ([string]$owned.data.executable)
    $targets = @($before.processes.game) + @($before.processes.mo2)
    if ($WhatIf) {
        return New-MO2ActionResult -Config $Config -Command 'stop' -Ok $true -State 'dry-run' -Data @{ sessionId = $SessionId; wouldRequestClose = @($targets); forceTermination = $false }
    }

    foreach ($record in $targets) {
        $process = Get-Process -Id ([int]$record.id) -ErrorAction SilentlyContinue
        if ($process) { $null = $process.CloseMainWindow() }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 500
        $after = Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$owned.data.profile) -RequestedExecutable ([string]$owned.data.executable)
        if ($after.processes.game.Count -eq 0 -and $after.processes.mo2.Count -eq 0) { break }
    } while ([DateTime]::UtcNow -lt $deadline)

    $closed = $after.processes.game.Count -eq 0 -and $after.processes.mo2.Count -eq 0
    $owned.data.status = if ($closed) { 'stopped' } else { 'stop-incomplete' }
    Write-MO2JsonAtomic -Path $owned.path -Value $owned.data
    $manifestPath = Join-Path ([string]$owned.data.sessionPath) 'session.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifest.status = $owned.data.status
    $manifest.stoppedUtc = [DateTime]::UtcNow.ToString('o')
    Write-MO2JsonAtomic -Path $manifestPath -Value $manifest

    return New-MO2ActionResult -Config $Config -Command 'stop' -Ok $closed -State $owned.data.status -Data @{ before = $before.processes; after = $after.processes; forceTermination = $false; sessionPath = $owned.data.sessionPath } -Errors $(if ($closed) { @() } else { @('One or more target processes did not accept a graceful close request; no force termination was attempted.') })
}

function Invoke-MO2Release {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SessionId,
        [switch]$WhatIf
    )

    $owned = Get-MO2OwnedSession -Config $Config -SessionId $SessionId
    $inspection = Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$owned.data.profile) -RequestedExecutable ([string]$owned.data.executable)
    $closed = $inspection.processes.game.Count -eq 0 -and $inspection.processes.mo2.Count -eq 0
    if (-not $closed) {
        return New-MO2ActionResult -Config $Config -Command 'release' -Ok $false -State 'blocked' -Data @{ processes = $inspection.processes; lock = $owned } -Errors @('The session cannot be released while MO2 or the game is running.')
    }
    if ($WhatIf) {
        return New-MO2ActionResult -Config $Config -Command 'release' -Ok $true -State 'dry-run' -Data @{ sessionId = $SessionId; lockPath = $owned.path; sessionPath = $owned.data.sessionPath; wouldRemoveLock = $true; wouldRetainSession = $true }
    }

    $manifestPath = Join-Path ([string]$owned.data.sessionPath) 'session.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifest.status = 'released'
    if ($manifest.PSObject.Properties['releasedUtc']) { $manifest.releasedUtc = [DateTime]::UtcNow.ToString('o') } else { $manifest | Add-Member -NotePropertyName releasedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) }
    Write-MO2JsonAtomic -Path $manifestPath -Value $manifest

    $current = Get-MO2SessionLockRecord -Path $owned.path
    if (-not $current.valid -or $current.sessionId -ne $SessionId) {
        return New-MO2ActionResult -Config $Config -Command 'release' -Ok $false -State 'blocked' -Data @{ lock = $current; sessionPath = $owned.data.sessionPath } -Errors @('Lock ownership changed before release; the lock was retained.')
    }
    Remove-Item -LiteralPath $owned.path -Force
    return New-MO2ActionResult -Config $Config -Command 'release' -Ok $true -State 'released' -Data @{ sessionId = $SessionId; lockPath = $owned.path; sessionPath = $owned.data.sessionPath; lockRemoved = $true; sessionRetained = $true }
}

function Invoke-MO2Terminate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SessionId,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 30,
        [switch]$WhatIf
    )

    $owned = Get-MO2OwnedSession -Config $Config -SessionId $SessionId
    $inspection = Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$owned.data.profile) -RequestedExecutable ([string]$owned.data.executable)
    if ($inspection.processes.game.Count -gt 0) {
        return New-MO2ActionResult -Config $Config -Command 'terminate' -Ok $false -State 'blocked' -Data @{ processes = $inspection.processes } -Errors @('Refusing forced MO2 termination while a game/loader process is running.')
    }
    $rootBuilderData = Resolve-MO2ControlPath ([string]$Config.mo2.rootBuilderDataDirectory)
    $activeBuildData = @()
    if (Test-Path -LiteralPath $rootBuilderData -PathType Container) {
        $activeBuildData = @(Get-ChildItem -LiteralPath $rootBuilderData -Filter 'BuildData.json' -File -Recurse -ErrorAction Stop)
    }
    if ($activeBuildData.Count -gt 0) {
        return New-MO2ActionResult -Config $Config -Command 'terminate' -Ok $false -State 'blocked' -Data @{ buildData = @($activeBuildData.FullName); processes = $inspection.processes } -Errors @('Refusing forced MO2 termination while RootBuilder BuildData.json remains active.')
    }
    $targets = @($inspection.processes.mo2)
    if ($WhatIf) {
        return New-MO2ActionResult -Config $Config -Command 'terminate' -Ok $true -State 'dry-run' -Data @{ sessionId = $SessionId; wouldForceTerminate = @($targets); gameProcesses = @(); activeRootBuilderBuildData = @() }
    }

    foreach ($record in $targets) {
        $process = Get-Process -Id ([int]$record.id) -ErrorAction SilentlyContinue
        if ($process -and @($Config.mo2.processNames) -contains $process.ProcessName) {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
        }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 250
        $remaining = @(Get-MO2ProcessRecords -Names @($Config.mo2.processNames))
        if ($remaining.Count -eq 0) { break }
    } while ([DateTime]::UtcNow -lt $deadline)
    $terminated = $remaining.Count -eq 0
    $owned.data.status = if ($terminated) { 'mo2-terminated' } else { 'terminate-incomplete' }
    Write-MO2JsonAtomic -Path $owned.path -Value $owned.data
    $manifestPath = Join-Path ([string]$owned.data.sessionPath) 'session.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifest.status = $owned.data.status
    if ($manifest.PSObject.Properties['terminatedUtc']) { $manifest.terminatedUtc = [DateTime]::UtcNow.ToString('o') } else { $manifest | Add-Member -NotePropertyName terminatedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) }
    Write-MO2JsonAtomic -Path $manifestPath -Value $manifest
    return New-MO2ActionResult -Config $Config -Command 'terminate' -Ok $terminated -State $owned.data.status -Data @{ targets = $targets; remaining = $remaining; gameProcesses = @(); activeRootBuilderBuildData = @(); sessionPath = $owned.data.sessionPath } -Errors $(if ($terminated) { @() } else { @('MO2 remained after exact forced termination was requested.') })
}

function Get-MO2ControlHelp {
    param([Parameter(Mandatory)]$Config)

    $data = [pscustomobject][ordered]@{
        commands = @(
            [pscustomobject]@{ name = 'inspect'; mutation = $false; description = 'Inspect MO2 paths, profiles, registered executables, processes, RootBuilder state, overwrite usage, storage and locks.' },
            [pscustomobject]@{ name = 'validate'; mutation = $false; description = 'Validate an exact profile and registered executable. Add -RequireClosed before future state-changing operations.' },
            [pscustomobject]@{ name = 'prepare'; mutation = $true; description = 'Validate closed state and create a durable single-owner evidence session. Supports -WhatIf.' },
            [pscustomobject]@{ name = 'launch'; mutation = $true; description = 'Launch one exact registered executable under one exact profile. Requires -SessionId and supports -WhatIf.' },
            [pscustomobject]@{ name = 'status'; mutation = $false; description = 'Report bounded MO2, game and runtime process state, optionally verifying -SessionId ownership.' },
            [pscustomobject]@{ name = 'stop-game'; mutation = $true; description = 'Request graceful game shutdown while retaining the exact owned MO2 process for controlled relaunch. Never force-terminates.' },
            [pscustomobject]@{ name = 'stop'; mutation = $true; description = 'Request graceful game and MO2 shutdown. Never force-terminates. Requires -SessionId and supports -WhatIf.' },
            [pscustomobject]@{ name = 'terminate'; mutation = $true; description = 'Force-terminate only owned MO2 processes after proving game absence and RootBuilder cleanup. Requires -SessionId and supports -WhatIf.' },
            [pscustomobject]@{ name = 'release'; mutation = $true; description = 'Release an owned lock only after closed-state proof; retain the evidence session. Requires -SessionId and supports -WhatIf.' },
            [pscustomobject]@{ name = 'help'; mutation = $false; description = 'Return the command contract.' }
        )
        examples = @(
            '.\Invoke-MO2Control.ps1 inspect',
            '.\Invoke-MO2Control.ps1 validate -RequireClosed',
            '.\Invoke-MO2Control.ps1 validate -Profile "Codex" -Executable "Launch MGO - Do Not Unlock" -Compact'
        )
        note = 'Version 0.3.0 adds retained-MO2 stop-game/relaunch cycles and treats a short-lived MO2 command helper as non-terminal while waiting for the game postcondition. Launch uses official --profile NAME run --executable NAME syntax. Stop operations are graceful-only.'
    }

    return [pscustomobject][ordered]@{
        contractVersion = [string]$Config.contractVersion
        command = 'help'
        ok = $true
        state = 'informational'
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        checks = @()
        warnings = @()
        errors = @()
        data = $data
    }
}

Export-ModuleMember -Function Read-MO2ControlConfig, Invoke-MO2Inspect, Invoke-MO2Validate, Invoke-MO2Prepare, Invoke-MO2Launch, Invoke-MO2Status, Invoke-MO2StopGame, Invoke-MO2Stop, Invoke-MO2Terminate, Invoke-MO2Release, Get-MO2ControlHelp
