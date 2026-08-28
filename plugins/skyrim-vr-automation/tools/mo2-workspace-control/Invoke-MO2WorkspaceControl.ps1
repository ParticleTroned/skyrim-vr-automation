# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('create', 'resume', 'list-task', 'inspect', 'fixture-status', 'refresh-fixture', 'prepare-source', 'register-mod', 'ensure-mod-wins', 'retire', 'release')]
    [string]$Command,

    [string]$ConfigPath,
    [string]$AccessId,
    [string]$WorkspaceId,
    [string]$TaskId,
    [string]$Label = 'task',
    [string]$SourceProfile,
    [ValidateSet('MainMenuOnly', 'FreshGame', 'VerifiedFixture')]
    [string]$SavePolicy = 'MainMenuOnly',
    [string]$FixtureManifestPath,
    [string]$FixtureId,
    [string]$ModName,
    [string]$ModDirectory,
    [ValidateSet('End', 'Before', 'After')]
    [string]$Placement = 'End',
    [string]$RelativeToMod,
    [string[]]$WinningPaths,
    [switch]$RegisterEnabled,
    [switch]$CleanupOwnedMods,
    [switch]$Compact,
    [switch]$NoExit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $toolRoot 'mo2-control\ConfigResolution.psm1') -Force
Import-Module (Join-Path $toolRoot 'mo2-control\MO2Control.psm1') -Force

function New-WorkspaceApprovalMetadata([string]$Subcommand) {
    $hostExecutable = [string][Environment]::ProcessPath
    if ([string]::IsNullOrWhiteSpace($hostExecutable)) { $hostExecutable = [string](Get-Process -Id $PID -ErrorAction Stop).Path }
    $entryPoint = [IO.Path]::GetFullPath($PSCommandPath)
    $oneShotCommands = @('refresh-fixture', 'prepare-source', 'retire', 'release')
    return [pscustomobject][ordered]@{
        hostExecutable = $hostExecutable; entryPoint = $entryPoint; subcommand = $Subcommand
        reusablePrefix = @($hostExecutable, '-NoProfile', '-NonInteractive', '-File', $entryPoint, $Subcommand)
        reusableApprovalEligible = $Subcommand -notin $oneShotCommands
        escalationUsuallyRequired = $Subcommand -notin @('inspect', 'fixture-status', 'list-task')
        oneShotReason = if ($Subcommand -eq 'refresh-fixture') { 'Shared fixture replacement must remain a one-shot approval.' } elseif ($Subcommand -eq 'prepare-source') { 'Moving overwrite cache trees into a shared stable-profile mod must remain a one-shot approval.' } elseif ($Subcommand -in @('retire', 'release')) { 'Recursive owned-workspace removal must remain a one-shot approval.' } else { $null }
        invocationRule = 'Use this literal prefix directly. Put changing access, workspace, mod, and evidence arguments afterward; do not hide the prefix in variables, -Command, pipelines, or a command string.'
    }
}

function Write-WorkspaceJsonAtomic([string]$Path, $Value) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporary -Encoding utf8
        [IO.File]::Move($temporary, $Path, $true)
    }
    finally { if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force } }
}

function Get-SafeName([string]$Value) {
    $safe = (($Value.Trim().ToLowerInvariant() -replace '[^a-z0-9]+', '-') -replace '(^-+|-+$)', '')
    if ([string]::IsNullOrWhiteSpace($safe)) { return 'task' }
    if ($safe.Length -gt 32) { return $safe.Substring(0, 32).TrimEnd('-') }
    return $safe
}

function Resolve-DirectProfilePath([string]$ProfilesRoot, [string]$ProfileName) {
    if ([string]::IsNullOrWhiteSpace($ProfileName) -or $ProfileName -in @('.', '..')) {
        throw 'SourceProfile is missing or malformed.'
    }
    if ($ProfileName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $ProfileName.Contains([IO.Path]::DirectorySeparatorChar) -or $ProfileName.Contains([IO.Path]::AltDirectorySeparatorChar)) {
        throw 'SourceProfile is malformed; it must be one direct profile-directory name.'
    }
    $resolvedRoot = [IO.Path]::GetFullPath($ProfilesRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $resolvedPath = [IO.Path]::GetFullPath((Join-Path $resolvedRoot $ProfileName))
    if (-not [string]::Equals([IO.Path]::GetDirectoryName($resolvedPath), $resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'SourceProfile must resolve to a direct child of the configured profiles directory.'
    }
    return $resolvedPath
}

function Get-ProfileSnapshot([string]$Path) {
    $records = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force | Sort-Object FullName)) {
        $relative = [IO.Path]::GetRelativePath($Path, $file.FullName)
        if ($relative -match '^(?i:saves)[\\/]') { continue }
        $records += [pscustomobject][ordered]@{ path = $relative; bytes = [long]$file.Length; sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash }
    }
    $canonical = $records | ConvertTo-Json -Compress -Depth 4
    $hashBytes = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical))
    return [pscustomobject][ordered]@{ files = @($records); sha256 = [Convert]::ToHexString($hashBytes) }
}

function Get-SaveTreeSnapshot([string]$ProfilePath) {
    $savesPath = [IO.Path]::GetFullPath((Join-Path $ProfilePath 'saves'))
    $records = @()
    if (Test-Path -LiteralPath $savesPath -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $savesPath -File -Recurse -Force | Sort-Object FullName)) {
            $records += [pscustomobject][ordered]@{
                path = [IO.Path]::GetRelativePath($savesPath, $file.FullName)
                bytes = [long]$file.Length
                sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
            }
        }
    }
    $canonical = ConvertTo-Json -InputObject @($records) -Compress -Depth 4
    $hashBytes = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical))
    return [pscustomobject][ordered]@{
        path = $savesPath
        exists = Test-Path -LiteralPath $savesPath -PathType Container
        fileCount = @($records).Count
        bytes = [long](($records | Measure-Object -Property bytes -Sum).Sum)
        sha256 = [Convert]::ToHexString($hashBytes)
        files = @($records)
    }
}

function Write-WorkspaceBytesAtomic([string]$Path, [byte[]]$Bytes) {
    $parent = Split-Path -Parent $Path
    $temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllBytes($temporary, $Bytes)
        [IO.File]::Move($temporary, $Path, $true)
    }
    finally { if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force } }
}

function Set-MO2SelectedProfile($Config, [string]$TargetProfile, [string]$Operation, [string]$EvidenceRoot, [switch]$WhatIf) {
    $iniPath = [IO.Path]::GetFullPath([string]$Config.mo2.ini)
    if (-not (Test-Path -LiteralPath $iniPath -PathType Leaf)) { throw "MO2 INI does not exist: $iniPath" }
    $beforeBytes = [IO.File]::ReadAllBytes($iniPath)
    $beforeText = [Text.Encoding]::UTF8.GetString($beforeBytes)
    $selectionMatches = [regex]::Matches($beforeText, '(?im)^(?<prefix>\s*selected_profile\s*=\s*)(?<value>[^\r\n]*)\r?$')
    if ($selectionMatches.Count -ne 1) { throw "Expected exactly one selected_profile entry in MO2 INI; found $($selectionMatches.Count)." }
    $rawBeforeValue = $selectionMatches[0].Groups['value'].Value.Trim()
    $byteArrayMatch = [regex]::Match($rawBeforeValue, '^@ByteArray\((.*)\)$')
    $beforeValue = if ($byteArrayMatch.Success) { $byteArrayMatch.Groups[1].Value } else { $rawBeforeValue }
    $replacement = $selectionMatches[0].Groups['prefix'].Value + '@ByteArray(' + $TargetProfile + ')'
    $afterText = $beforeText.Remove($selectionMatches[0].Index, $selectionMatches[0].Length).Insert($selectionMatches[0].Index, $replacement)
    $backupPath = Join-Path $EvidenceRoot 'ModOrganizer.before.ini'
    $receiptPath = Join-Path $EvidenceRoot ('selected-profile-' + (Get-SafeName $Operation) + '.receipt.json')
    $record = [pscustomobject][ordered]@{
        iniPath = $iniPath; selectedProfileBefore = $beforeValue; selectedProfileAfter = $TargetProfile
        backupPath = $backupPath; receiptPath = $receiptPath; changed = $beforeValue -cne $TargetProfile
    }
    if ($WhatIf) { return $record }
    if (-not (Test-Path -LiteralPath $EvidenceRoot -PathType Container)) { New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null }
    if (Test-Path -LiteralPath $backupPath -PathType Leaf) { throw "Refusing to overwrite the exact MO2 INI backup: $backupPath" }
    [IO.File]::WriteAllBytes($backupPath, $beforeBytes)
    try {
        if ($beforeValue -cne $TargetProfile) {
            Write-WorkspaceBytesAtomic -Path $iniPath -Bytes ([Text.Encoding]::UTF8.GetBytes($afterText))
        }
        $verifiedText = [IO.File]::ReadAllText($iniPath, [Text.Encoding]::UTF8)
        $verifiedMatches = [regex]::Matches($verifiedText, '(?im)^\s*selected_profile\s*=\s*@ByteArray\((?<value>[^\r\n]*)\)\s*\r?$')
        $verified = if ($verifiedMatches.Count -eq 1) { $verifiedMatches[0].Groups['value'].Value } else { $null }
        if ($verified -cne $TargetProfile) { throw "MO2 selected profile postcondition did not match '$TargetProfile'." }
        $receipt = [pscustomobject][ordered]@{
            contractVersion = '1.1.0'; operation = $Operation; iniPath = $iniPath
            targetProfile = $TargetProfile; selectedProfileBefore = $beforeValue
            selectedProfileAfter = $verified; backupPath = $backupPath
            beforeSha256 = (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash
            resultSha256 = (Get-FileHash -LiteralPath $iniPath -Algorithm SHA256).Hash
            changedUtc = [DateTime]::UtcNow.ToString('o')
        }
        Write-WorkspaceJsonAtomic -Path $receiptPath -Value $receipt
    }
    catch {
        Write-WorkspaceBytesAtomic -Path $iniPath -Bytes $beforeBytes
        throw "MO2 selected profile transaction '$Operation' failed; the exact INI bytes were restored. $($_.Exception.Message)"
    }
    return $record
}

function Get-WorkspaceManifestPath($Config, [string]$Id) {
    if ([string]::IsNullOrWhiteSpace($Id) -or $Id -notmatch '^[a-z0-9-]+$') { throw 'WorkspaceId is missing or malformed.' }
    return Join-Path (Join-Path ([string]$Config.storage.sessionStaging) 'workspaces') ($Id + '.json')
}

function Resolve-VerifiedSaveFixture($Config, [string]$SourceName, [string]$SourcePath, $SourceSnapshot, [string]$RequestedManifestPath, [string]$RequestedFixtureId) {
    $configuredManifest = if ($Config.defaults.PSObject.Properties['newGameFixtureManifest']) { [string]$Config.defaults.newGameFixtureManifest } else { '' }
    $manifestInput = if (-not [string]::IsNullOrWhiteSpace($RequestedManifestPath)) { $RequestedManifestPath } else { $configuredManifest }
    if ([string]::IsNullOrWhiteSpace($manifestInput)) { throw 'VerifiedFixture requires -FixtureManifestPath or defaults.newGameFixtureManifest.' }
    $manifestPath = [IO.Path]::GetFullPath($manifestInput)
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Fixture manifest does not exist: $manifestPath" }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if (-not $manifest.PSObject.Properties['profileFingerprintSha256'] -or [string]$manifest.profileFingerprintSha256 -cne [string]$SourceSnapshot.sha256) { throw 'Verified fixture profile fingerprint does not match the stable source profile.' }
    if ($manifest.PSObject.Properties['sourceProfile'] -and -not [string]::IsNullOrWhiteSpace([string]$manifest.sourceProfile) -and [string]$manifest.sourceProfile -cne $SourceName) { throw 'Verified fixture sourceProfile does not match the exact stable source profile.' }
    $fixtures = @($manifest.fixtures)
    if ($fixtures.Count -eq 0) { throw 'Verified fixture manifest contains no fixtures.' }
    $selectedId = if (-not [string]::IsNullOrWhiteSpace($RequestedFixtureId)) { $RequestedFixtureId } elseif ($manifest.PSObject.Properties['defaultFixtureId']) { [string]$manifest.defaultFixtureId } else { '' }
    if ([string]::IsNullOrWhiteSpace($selectedId)) { throw 'Verified fixture selection requires -FixtureId or manifest.defaultFixtureId.' }
    $matches = @($fixtures | Where-Object { [string]$_.id -ceq $selectedId })
    if ($matches.Count -ne 1) { throw "Expected exactly one fixture named '$selectedId'; found $($matches.Count)." }
    $selected = $matches[0]
    $files = @($selected.files)
    if ($files.Count -eq 0) { throw "Verified fixture '$selectedId' contains no files." }
    $sourceSaves = [IO.Path]::GetFullPath((Join-Path $SourcePath 'saves'))
    $verifiedFiles = @()
    $essCount = 0
    foreach ($file in $files) {
        $relative = [string]$file.relativePath
        if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative)) { throw "Fixture '$selectedId' contains a missing or rooted relativePath." }
        $sourceFile = [IO.Path]::GetFullPath((Join-Path $sourceSaves $relative))
        if (-not $sourceFile.StartsWith($sourceSaves + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "Fixture file escapes the source saves directory: $relative" }
        if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) { throw "Fixture source file does not exist: $sourceFile" }
        $item = Get-Item -LiteralPath $sourceFile
        $hash = (Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash
        if (-not $file.PSObject.Properties['sha256'] -or $hash -cne [string]$file.sha256) { throw "Fixture source hash does not match for '$relative'." }
        if ($file.PSObject.Properties['bytes'] -and [long]$file.bytes -ne [long]$item.Length) { throw "Fixture source byte count does not match for '$relative'." }
        if ([IO.Path]::GetExtension($relative) -ieq '.ess') { $essCount++ }
        $verifiedFiles += [pscustomobject][ordered]@{ relativePath = $relative; sourcePath = $sourceFile; bytes = [long]$item.Length; sha256 = $hash }
    }
    if ($essCount -ne 1) { throw "Verified fixture '$selectedId' must contain exactly one .ess save; found $essCount." }
    return [pscustomobject][ordered]@{
        manifestPath = $manifestPath
        manifestContractVersion = [string]$manifest.contractVersion
        id = $selectedId
        label = if ($selected.PSObject.Properties['label']) { [string]$selected.label } else { $selectedId }
        location = if ($selected.PSObject.Properties['location']) { [string]$selected.location } else { $null }
        loadName = if ($selected.PSObject.Properties['loadName']) { [string]$selected.loadName } else { [IO.Path]::GetFileNameWithoutExtension([string](@($verifiedFiles | Where-Object { [IO.Path]::GetExtension($_.relativePath) -ieq '.ess' })[0].relativePath)) }
        files = @($verifiedFiles)
    }
}

function Get-VerifiedSaveFixtureStatus($Config, [string]$SourceName, [string]$SourcePath, $SourceSnapshot, [string]$RequestedManifestPath, [string]$RequestedFixtureId) {
    $configuredManifest = if ($Config.defaults.PSObject.Properties['newGameFixtureManifest']) { [string]$Config.defaults.newGameFixtureManifest } else { '' }
    $manifestInput = if (-not [string]::IsNullOrWhiteSpace($RequestedManifestPath)) { $RequestedManifestPath } else { $configuredManifest }
    $manifestSource = if (-not [string]::IsNullOrWhiteSpace($RequestedManifestPath)) { 'parameter' } elseif (-not [string]::IsNullOrWhiteSpace($configuredManifest)) { 'configuration' } else { 'none' }
    $exampleManifestPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'save-fixtures.example.json'))
    $guidance = @(
        'Copy and adapt tools/mo2-workspace-control/save-fixtures.example.json outside the checkout.',
        'Set defaults.newGameFixtureManifest in the stable per-user machine configuration, or pass -FixtureManifestPath explicitly.',
        'Declare one .ess save plus any matching co-save files, then run fixture-status again to validate exact hashes and the stable-profile fingerprint.'
    )
    if ([string]::IsNullOrWhiteSpace($manifestInput)) {
        return [pscustomobject][ordered]@{
            configured = $false; discoveryState = 'manifest-not-configured'; manifestSource = $manifestSource
            manifestPath = $null; manifestExists = $false; exampleManifestPath = $exampleManifestPath
            configurationProperty = 'defaults.newGameFixtureManifest'; guidance = $guidance
            sourceProfileName = $SourceName; sourceProfileDirectory = $SourcePath
            actualProfileFingerprintSha256 = [string]$SourceSnapshot.sha256; valid = $false
        }
    }
    $manifestPath = [IO.Path]::GetFullPath($manifestInput)
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return [pscustomobject][ordered]@{
            configured = $true; discoveryState = 'manifest-missing'; manifestSource = $manifestSource
            manifestPath = $manifestPath; manifestExists = $false; exampleManifestPath = $exampleManifestPath
            configurationProperty = 'defaults.newGameFixtureManifest'; guidance = $guidance
            sourceProfileName = $SourceName; sourceProfileDirectory = $SourcePath
            actualProfileFingerprintSha256 = [string]$SourceSnapshot.sha256; valid = $false
        }
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $fixtures = @($manifest.fixtures)
    $selectedId = if (-not [string]::IsNullOrWhiteSpace($RequestedFixtureId)) { $RequestedFixtureId } elseif ($manifest.PSObject.Properties['defaultFixtureId']) { [string]$manifest.defaultFixtureId } else { '' }
    if ([string]::IsNullOrWhiteSpace($selectedId)) { throw 'Fixture inspection requires -FixtureId or manifest.defaultFixtureId.' }
    $matches = @($fixtures | Where-Object { [string]$_.id -ceq $selectedId })
    if ($matches.Count -ne 1) { throw "Expected exactly one fixture named '$selectedId'; found $($matches.Count)." }
    $selected = $matches[0]
    $sourceSaves = [IO.Path]::GetFullPath((Join-Path $SourcePath 'saves'))
    $fileStatus = @()
    $essCount = 0
    foreach ($file in @($selected.files)) {
        $relative = [string]$file.relativePath
        if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative)) { throw "Fixture '$selectedId' contains a missing or rooted relativePath." }
        $sourceFile = [IO.Path]::GetFullPath((Join-Path $sourceSaves $relative))
        if (-not $sourceFile.StartsWith($sourceSaves + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "Fixture file escapes the source saves directory: $relative" }
        $exists = Test-Path -LiteralPath $sourceFile -PathType Leaf
        $actualBytes = if ($exists) { [long](Get-Item -LiteralPath $sourceFile).Length } else { $null }
        $actualHash = if ($exists) { (Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash } else { $null }
        $expectedHash = if ($file.PSObject.Properties['sha256']) { [string]$file.sha256 } else { $null }
        $expectedBytes = if ($file.PSObject.Properties['bytes']) { [long]$file.bytes } else { $null }
        if ([IO.Path]::GetExtension($relative) -ieq '.ess') { $essCount++ }
        $fileStatus += [pscustomobject][ordered]@{
            relativePath = $relative; sourcePath = $sourceFile; exists = $exists
            expectedSha256 = $expectedHash; actualSha256 = $actualHash
            expectedBytes = $expectedBytes; actualBytes = $actualBytes
            hashMatches = $exists -and -not [string]::IsNullOrWhiteSpace($expectedHash) -and $actualHash -ceq $expectedHash
            bytesMatch = $exists -and ($null -eq $expectedBytes -or $actualBytes -eq $expectedBytes)
        }
    }
    $expectedFingerprint = if ($manifest.PSObject.Properties['profileFingerprintSha256']) { [string]$manifest.profileFingerprintSha256 } else { $null }
    $sourceProfileMatches = -not $manifest.PSObject.Properties['sourceProfile'] -or [string]::IsNullOrWhiteSpace([string]$manifest.sourceProfile) -or [string]$manifest.sourceProfile -ceq $SourceName
    $allFilesMatch = @($fileStatus | Where-Object { -not $_.exists -or -not $_.hashMatches -or -not $_.bytesMatch }).Count -eq 0
    return [pscustomobject][ordered]@{
        configured = $true; discoveryState = 'manifest-ready'; manifestSource = $manifestSource; manifestExists = $true
        exampleManifestPath = $exampleManifestPath; configurationProperty = 'defaults.newGameFixtureManifest'; guidance = $guidance
        manifestPath = $manifestPath; manifest = $manifest; fixture = $selected; fixtureId = $selectedId
        sourceProfileName = $SourceName; sourceProfileDirectory = $SourcePath
        expectedProfileFingerprintSha256 = $expectedFingerprint; actualProfileFingerprintSha256 = [string]$SourceSnapshot.sha256
        profileFingerprintMatches = -not [string]::IsNullOrWhiteSpace($expectedFingerprint) -and $expectedFingerprint -ceq [string]$SourceSnapshot.sha256
        sourceProfileMatches = $sourceProfileMatches; files = @($fileStatus); allFilesMatch = $allFilesMatch
        essCount = $essCount
        valid = $sourceProfileMatches -and $allFilesMatch -and $essCount -eq 1 -and -not [string]::IsNullOrWhiteSpace($expectedFingerprint) -and $expectedFingerprint -ceq [string]$SourceSnapshot.sha256
    }
}

function Resolve-TaskId([string]$RequestedTaskId, [switch]$Required) {
    $resolved = $RequestedTaskId
    if ([string]::IsNullOrWhiteSpace($resolved)) { $resolved = [Environment]::GetEnvironmentVariable('CODEX_THREAD_ID') }
    if ([string]::IsNullOrWhiteSpace($resolved)) { $resolved = [Environment]::GetEnvironmentVariable('CODEX_TASK_ID') }
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        if ($Required) { throw 'A stable task identity is required. Pass -TaskId or set CODEX_THREAD_ID/CODEX_TASK_ID.' }
        return $null
    }
    $resolved = $resolved.Trim()
    if ($resolved.Length -gt 256 -or $resolved -match '[\r\n]') { throw 'TaskId is malformed.' }
    return $resolved
}

function Read-Workspace($Config, [string]$Id) {
    $path = Get-WorkspaceManifestPath -Config $Config -Id $Id
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Workspace does not exist: $Id" }
    $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ([string]$manifest.workspaceId -cne $Id) { throw 'Workspace manifest identity does not match its filename.' }
    return [pscustomobject]@{ path = $path; data = $manifest }
}

function Assert-WorkspaceTaskOwner($Workspace, [string]$ResolvedTaskId) {
    if (-not $Workspace.data.PSObject.Properties['ownerTaskId']) { throw 'Workspace predates durable task ownership and cannot be resumed. Create a fresh task workspace.' }
    if ([string]$Workspace.data.ownerTaskId -cne $ResolvedTaskId) { throw 'Workspace belongs to a different task identity.' }
}

function Read-OwnedWorkspace($Config, [string]$Id, [string]$OwnedAccessId, [string]$ResolvedTaskId) {
    $workspace = Read-Workspace -Config $Config -Id $Id
    Assert-WorkspaceTaskOwner -Workspace $workspace -ResolvedTaskId $ResolvedTaskId
    $manifest = $workspace.data
    if ([string]$manifest.accessId -cne $OwnedAccessId) { throw 'Workspace is owned by a different MO2 access lease.' }
    return $workspace
}

function Get-TaskWorkspaces($Config, [string]$ResolvedTaskId) {
    $root = Join-Path ([string]$Config.storage.sessionStaging) 'workspaces'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
    $items = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File -Force | Sort-Object LastWriteTimeUtc -Descending)) {
        try {
            $manifest = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            if ($manifest.PSObject.Properties['ownerTaskId'] -and [string]$manifest.ownerTaskId -ceq $ResolvedTaskId) {
                $profilePath = [IO.Path]::GetFullPath([string]$manifest.profilePath)
                $items += [pscustomobject][ordered]@{
                    workspaceId = [string]$manifest.workspaceId; status = [string]$manifest.status
                    profileName = [string]$manifest.profileName; profileDirectory = $profilePath
                    profileExists = Test-Path -LiteralPath $profilePath -PathType Container
                    resumable = ([string]$manifest.status -in @('ready', 'retained')) -and (Test-Path -LiteralPath $profilePath -PathType Container)
                    sourceProfile = [string]$manifest.sourceProfile; accessId = [string]$manifest.accessId
                    createdUtc = [string]$manifest.createdUtc; lastResumedUtc = if ($manifest.PSObject.Properties['lastResumedUtc']) { [string]$manifest.lastResumedUtc } else { $null }
                    manifestPath = $file.FullName
                }
            }
        }
        catch { }
    }
    return @($items)
}

function Assert-AccessAndClosed($Config, [string]$OwnedAccessId, [string]$Profile, [switch]$AllowOverwriteShaderCaches) {
    if ([string]::IsNullOrWhiteSpace($OwnedAccessId)) { throw '-AccessId is required for workspace mutation.' }
    $access = Invoke-MO2AccessStatus -Config $Config -AccessId $OwnedAccessId
    if (-not $access.ok -or -not $access.data.owned) { throw 'The exact MO2 access lease is not owned by this task.' }
    if (-not [string]::IsNullOrWhiteSpace([string]$access.data.access.sessionId)) { throw 'Release the active MO2 evidence session before mutating a test workspace.' }
    $validation = Invoke-MO2Validate -Config $Config -Profile $Profile -RequireClosed -OwnedAccessId $OwnedAccessId
    if (-not $validation.ok) {
        $failedChecks = @($validation.checks | Where-Object status -eq 'fail')
        $onlyExpectedCaches = $AllowOverwriteShaderCaches -and $failedChecks.Count -eq 1 -and $failedChecks[0].name -eq 'overwrite' -and @($validation.data.overwrite.shaderCaches).Count -gt 0
        if (-not $onlyExpectedCaches) { throw "MO2 closed-state validation failed: $($validation.errors -join '; ')" }
    }
    return $validation
}

function Get-OverwriteShaderCacheDirectories($Config) {
    $overwriteRoot = [IO.Path]::GetFullPath([string]$Config.mo2.overwriteDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $overwriteRoot -PathType Container)) { return @() }
    $matches = @(Get-ChildItem -LiteralPath $overwriteRoot -Directory -Recurse -Force | Where-Object { $_.Name -match '^(?i:ShaderCache)(?:[.]|$)' } | Sort-Object FullName)
    $roots = @()
    foreach ($match in $matches) {
        $nested = @($roots | Where-Object { $match.FullName.StartsWith($_.FullName + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        if (-not $nested) { $roots += $match }
    }
    return @($roots)
}

function Get-DirectorySummary([string]$Path) {
    $files = @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force)
    return [pscustomobject][ordered]@{
        files = $files.Count
        bytes = [long](($files | Measure-Object -Property Length -Sum).Sum ?? 0)
    }
}

function Move-OverwriteShaderCachesToStableMod($Config, [string]$SourceName, [string]$SourcePath, [string]$ModsRoot, [switch]$WhatIf) {
    $overwriteRoot = [IO.Path]::GetFullPath([string]$Config.mo2.overwriteDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $cacheDirectories = @(Get-OverwriteShaderCacheDirectories -Config $Config)
    if ($cacheDirectories.Count -eq 0) {
        return [pscustomobject][ordered]@{
            state = 'clean'; sourceProfile = $SourceName; overwriteDirectory = $overwriteRoot
            movedDirectories = @(); modName = $null; modDirectory = $null; receiptPath = $null
        }
    }

    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $modName = 'CSX Legacy Shader Cache - ' + $stamp
    $modDirectory = [IO.Path]::GetFullPath((Join-Path $ModsRoot $modName))
    if (-not $modDirectory.StartsWith($ModsRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Generated shader-cache mod path escaped the configured mods directory.' }
    if (Test-Path -LiteralPath $modDirectory) { throw "Generated shader-cache mod already exists: $modDirectory" }
    $modListPath = Join-Path $SourcePath 'modlist.txt'
    if (-not (Test-Path -LiteralPath $modListPath -PathType Leaf)) { throw "Stable source modlist does not exist: $modListPath" }
    $evidenceRoot = Join-Path (Join-Path ([string]$Config.storage.sessionStaging) 'source-preparation') ($stamp + '-' + (Get-SafeName $SourceName))
    $profileEvidence = Join-Path $evidenceRoot 'profile-registration'
    $receiptPath = Join-Path $evidenceRoot 'shader-cache-migration.receipt.json'
    $moves = @($cacheDirectories | ForEach-Object {
        $relative = [IO.Path]::GetRelativePath($overwriteRoot, $_.FullName)
        if ([IO.Path]::IsPathRooted($relative) -or $relative.StartsWith('..')) { throw "Shader-cache source escaped overwrite: $($_.FullName)" }
        $summary = Get-DirectorySummary -Path $_.FullName
        [pscustomobject][ordered]@{
            relativePath = $relative; sourcePath = $_.FullName
            destinationPath = [IO.Path]::GetFullPath((Join-Path $modDirectory $relative))
            files = $summary.files; bytes = $summary.bytes
        }
    })
    if ($WhatIf) {
        return [pscustomobject][ordered]@{
            state = 'migration-planned'; sourceProfile = $SourceName; overwriteDirectory = $overwriteRoot
            movedDirectories = $moves; modName = $modName; modDirectory = $modDirectory; receiptPath = $receiptPath
        }
    }

    $profileTool = Join-Path $toolRoot 'mo2-profile-control\Invoke-MO2ProfileControl.ps1'
    $modListBefore = [IO.File]::ReadAllBytes($modListPath)
    try {
        New-Item -ItemType Directory -Path $modDirectory -Force | Out-Null
        foreach ($move in $moves) {
            $destinationParent = Split-Path -Parent ([string]$move.destinationPath)
            if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) { New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null }
            [IO.Directory]::Move([string]$move.sourcePath, [string]$move.destinationPath)
        }
        $blockingProcessNames = @(
            @($Config.mo2.processNames)
            @($Config.mo2.gameProcessNames)
            @($Config.mo2.runtimeProcessNames)
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique
        if ($blockingProcessNames.Count -eq 0) { $blockingProcessNames = @('ModOrganizer', 'SkyrimVR', 'sksevr_loader') }
        $registration = & $profileTool register -ProfilePath $modListPath -ModName $modName -ModDirectory $modDirectory -Placement End -RegisterEnabled -EvidenceDirectory $profileEvidence -BlockingProcessNames $blockingProcessNames -Confirm:$false | ConvertFrom-Json
        if (-not $registration.enabled) { throw 'Stable source profile did not enable the migrated shader-cache mod.' }
        $remaining = @(Get-OverwriteShaderCacheDirectories -Config $Config)
        if ($remaining.Count -ne 0) { throw "Overwrite shader-cache postcondition failed; remaining: $($remaining.FullName -join ', ')" }
        foreach ($move in $moves) {
            if (Test-Path -LiteralPath ([string]$move.sourcePath)) { throw "Shader-cache source still exists after move: $($move.sourcePath)" }
            if (-not (Test-Path -LiteralPath ([string]$move.destinationPath) -PathType Container)) { throw "Shader-cache destination is missing after move: $($move.destinationPath)" }
            $after = Get-DirectorySummary -Path ([string]$move.destinationPath)
            if ($after.files -ne $move.files -or $after.bytes -ne $move.bytes) { throw "Shader-cache move summary mismatch: $($move.relativePath)" }
        }
        $receipt = [pscustomobject][ordered]@{
            contractVersion = '1.0.0'; operation = 'move-overwrite-shader-caches-to-stable-mod'
            sourceProfile = $SourceName; sourceProfileDirectory = $SourcePath; overwriteDirectory = $overwriteRoot
            modName = $modName; modDirectory = $modDirectory; movedDirectories = $moves
            profileRegistrationReceipt = [string]$registration.receiptPath; completedUtc = [DateTime]::UtcNow.ToString('o')
        }
        Write-WorkspaceJsonAtomic -Path $receiptPath -Value $receipt
        return [pscustomobject][ordered]@{
            state = 'migrated'; sourceProfile = $SourceName; overwriteDirectory = $overwriteRoot
            movedDirectories = $moves; modName = $modName; modDirectory = $modDirectory; receiptPath = $receiptPath
        }
    }
    catch {
        $failure = $_.Exception.Message
        $rollbackErrors = @()
        try { Write-WorkspaceBytesAtomic -Path $modListPath -Bytes $modListBefore } catch { $rollbackErrors += "modlist: $($_.Exception.Message)" }
        foreach ($move in @($moves | Sort-Object { ([string]$_.relativePath).Length } -Descending)) {
            if (Test-Path -LiteralPath ([string]$move.destinationPath) -PathType Container) {
                try {
                    $sourceParent = Split-Path -Parent ([string]$move.sourcePath)
                    if (-not (Test-Path -LiteralPath $sourceParent -PathType Container)) { New-Item -ItemType Directory -Path $sourceParent -Force | Out-Null }
                    [IO.Directory]::Move([string]$move.destinationPath, [string]$move.sourcePath)
                }
                catch { $rollbackErrors += "$($move.relativePath): $($_.Exception.Message)" }
            }
        }
        try {
            if ((Test-Path -LiteralPath $modDirectory -PathType Container) -and @(Get-ChildItem -LiteralPath $modDirectory -Force).Count -eq 0) { Remove-Item -LiteralPath $modDirectory -Force }
        }
        catch { $rollbackErrors += "mod directory: $($_.Exception.Message)" }
        if ($rollbackErrors.Count -gt 0) { throw "Shader-cache migration failed. Rollback needs attention: $($rollbackErrors -join '; '). Original failure: $failure" }
        throw "Shader-cache migration failed and was rolled back. $failure"
    }
}

try {
    $resolvedConfig = Resolve-MO2ControlConfigPath -ConfigPath $ConfigPath -PackageRoot (Join-Path $toolRoot 'mo2-control')
    if (-not $resolvedConfig.exists) { throw "MO2 configuration was not found: $($resolvedConfig.path)" }
    $config = Read-MO2ControlConfig -ConfigPath $resolvedConfig.path
    $profilesRoot = [IO.Path]::GetFullPath([string]$config.mo2.profilesDirectory)
    $modsRoot = [IO.Path]::GetFullPath([string]$config.mo2.modsDirectory)

    if ($Command -eq 'list-task') {
        $resolvedTaskId = Resolve-TaskId -RequestedTaskId $TaskId -Required
        $allWorkspaces = @(Get-TaskWorkspaces -Config $config -ResolvedTaskId $resolvedTaskId)
        $workspaces = @($allWorkspaces | Where-Object resumable)
        $result = [pscustomobject][ordered]@{
            ok = $true; command = $Command; state = $(if ($workspaces.Count -eq 0) { 'no-retained-workspaces' } else { 'retained-workspaces-found' })
            data = [pscustomobject][ordered]@{
                ownerTaskId = $resolvedTaskId; count = $workspaces.Count; workspaces = $workspaces
                unavailableWorkspaces = @($allWorkspaces | Where-Object { -not $_.resumable })
                guidance = if ($workspaces.Count -eq 0) { 'This task has no retained workspace. After acquiring MO2 access, explicitly create a fresh workspace.' } else { 'After acquiring MO2 access, explicitly resume one listed WorkspaceId or explicitly create a fresh workspace.' }
            }
        }
    }
    elseif ($Command -in @('fixture-status', 'refresh-fixture')) {
        $sourceName = if (-not [string]::IsNullOrWhiteSpace($SourceProfile)) { $SourceProfile } elseif ($config.defaults.PSObject.Properties['testProfileSource']) { [string]$config.defaults.testProfileSource } else { throw 'defaults.testProfileSource is required for fixture control.' }
        $sourcePath = Resolve-DirectProfilePath -ProfilesRoot $profilesRoot -ProfileName $sourceName
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) { throw "Stable source profile does not exist: $sourceName" }
        if ($Command -eq 'refresh-fixture') { $null = Assert-AccessAndClosed -Config $config -OwnedAccessId $AccessId -Profile $sourceName }
        $sourceSnapshot = Get-ProfileSnapshot -Path $sourcePath
        $status = Get-VerifiedSaveFixtureStatus -Config $config -SourceName $sourceName -SourcePath $sourcePath -SourceSnapshot $sourceSnapshot -RequestedManifestPath $FixtureManifestPath -RequestedFixtureId $FixtureId
        if ($Command -eq 'fixture-status') {
            $fixtureState = if ([string]$status.discoveryState -eq 'manifest-not-configured') { 'fixture-not-configured' } elseif ([string]$status.discoveryState -eq 'manifest-missing') { 'fixture-manifest-missing' } elseif ($status.valid) { 'fixture-valid' } else { 'fixture-stale' }
            $result = [pscustomobject][ordered]@{ ok = $true; command = $Command; state = $fixtureState; data = $status }
        }
        else {
            if ([string]$status.discoveryState -ne 'manifest-ready') { throw "Fixture refresh requires an existing manifest. $(@($status.guidance)[0])" }
            if (-not $status.sourceProfileMatches) { throw 'Fixture sourceProfile does not match the exact stable source profile; refusing refresh.' }
            if ($status.essCount -ne 1) { throw "Fixture '$($status.fixtureId)' must contain exactly one .ess save before refresh; found $($status.essCount)." }
            if (@($status.files | Where-Object { -not $_.exists }).Count -gt 0) { throw 'Fixture refresh requires every declared source save file to exist.' }
            $manifest = $status.manifest
            $manifest.profileFingerprintSha256 = [string]$sourceSnapshot.sha256
            $selected = @($manifest.fixtures | Where-Object { [string]$_.id -ceq [string]$status.fixtureId })[0]
            foreach ($file in @($selected.files)) {
                $actual = @($status.files | Where-Object { [string]$_.relativePath -ceq [string]$file.relativePath })[0]
                if ($file.PSObject.Properties['bytes']) { $file.bytes = [long]$actual.actualBytes } else { $file | Add-Member -NotePropertyName bytes -NotePropertyValue ([long]$actual.actualBytes) }
                if ($file.PSObject.Properties['sha256']) { $file.sha256 = [string]$actual.actualSha256 } else { $file | Add-Member -NotePropertyName sha256 -NotePropertyValue ([string]$actual.actualSha256) }
            }
            $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
            $evidenceRoot = Join-Path (Split-Path -Parent ([string]$status.manifestPath)) ('.fixture-refresh-' + $status.fixtureId + '-' + $stamp)
            $backupPath = Join-Path $evidenceRoot 'manifest.before.json'
            $receiptPath = Join-Path $evidenceRoot 'fixture-refresh.receipt.json'
            if ($PSCmdlet.ShouldProcess([string]$status.manifestPath, "refresh exact fixture '$($status.fixtureId)' fingerprints from stable profile '$sourceName'")) {
                New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
                Copy-Item -LiteralPath ([string]$status.manifestPath) -Destination $backupPath
                Write-WorkspaceJsonAtomic -Path ([string]$status.manifestPath) -Value $manifest
                $verifiedSnapshot = Get-ProfileSnapshot -Path $sourcePath
                $verified = Get-VerifiedSaveFixtureStatus -Config $config -SourceName $sourceName -SourcePath $sourcePath -SourceSnapshot $verifiedSnapshot -RequestedManifestPath ([string]$status.manifestPath) -RequestedFixtureId ([string]$status.fixtureId)
                if (-not $verified.valid) {
                    Copy-Item -LiteralPath $backupPath -Destination ([string]$status.manifestPath) -Force
                    throw 'Fixture refresh postcondition failed; the exact manifest backup was restored.'
                }
                Write-WorkspaceJsonAtomic -Path $receiptPath -Value ([pscustomobject][ordered]@{
                    contractVersion = '1.0.0'; operation = 'refresh-fixture'; fixtureId = [string]$status.fixtureId
                    sourceProfileName = $sourceName; sourceProfileDirectory = $sourcePath; manifestPath = [string]$status.manifestPath
                    backupPath = $backupPath; beforeSha256 = (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash
                    resultSha256 = (Get-FileHash -LiteralPath ([string]$status.manifestPath) -Algorithm SHA256).Hash
                    expectedFingerprintBefore = [string]$status.expectedProfileFingerprintSha256
                    actualFingerprint = [string]$verified.actualProfileFingerprintSha256; refreshedUtc = [DateTime]::UtcNow.ToString('o')
                })
                $status = $verified
            }
            $status | Add-Member -NotePropertyName backupPath -NotePropertyValue $backupPath -Force
            $status | Add-Member -NotePropertyName receiptPath -NotePropertyValue $receiptPath -Force
            $result = [pscustomobject][ordered]@{ ok = $true; command = $Command; state = $(if ($WhatIfPreference) { 'dry-run' } else { 'fixture-refreshed' }); data = $status }
        }
    }
    elseif ($Command -eq 'prepare-source') {
        $sourceName = if (-not [string]::IsNullOrWhiteSpace($SourceProfile)) { $SourceProfile } elseif ($config.defaults.PSObject.Properties['testProfileSource']) { [string]$config.defaults.testProfileSource } else { throw 'defaults.testProfileSource is required for source preparation.' }
        $sourcePath = Resolve-DirectProfilePath -ProfilesRoot $profilesRoot -ProfileName $sourceName
        $null = Assert-AccessAndClosed -Config $config -OwnedAccessId $AccessId -Profile $sourceName -AllowOverwriteShaderCaches
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) { throw "Stable source profile does not exist: $sourceName" }
        $preparation = if ($PSCmdlet.ShouldProcess([string]$config.mo2.overwriteDirectory, "move every ShaderCache folder into a new enabled mod in stable profile '$sourceName'")) {
            Move-OverwriteShaderCachesToStableMod -Config $config -SourceName $sourceName -SourcePath $sourcePath -ModsRoot $modsRoot
        }
        else {
            Move-OverwriteShaderCachesToStableMod -Config $config -SourceName $sourceName -SourcePath $sourcePath -ModsRoot $modsRoot -WhatIf
        }
        $result = [pscustomobject][ordered]@{ ok = $true; command = $Command; state = [string]$preparation.state; data = $preparation }
    }
    elseif ($Command -eq 'create') {
        $resolvedTaskId = Resolve-TaskId -RequestedTaskId $TaskId -Required
        $sourceName = if (-not [string]::IsNullOrWhiteSpace($SourceProfile)) { $SourceProfile } elseif ($config.defaults.PSObject.Properties['testProfileSource']) { [string]$config.defaults.testProfileSource } else { throw 'defaults.testProfileSource is required; test workspaces never infer a stable source from the ordinary session default.' }
        $sourcePath = Resolve-DirectProfilePath -ProfilesRoot $profilesRoot -ProfileName $sourceName
        $validation = Assert-AccessAndClosed -Config $config -OwnedAccessId $AccessId -Profile $sourceName
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) { throw "Stable source profile does not exist: $sourceName" }
        $unmanagedCaches = @(Get-OverwriteShaderCacheDirectories -Config $config)
        if ($unmanagedCaches.Count -gt 0) { throw "Overwrite contains ShaderCache folders. Run prepare-source for '$sourceName' before creating a task workspace: $($unmanagedCaches.FullName -join ', ')" }
        $workspaceId = '{0}-{1}-{2}' -f ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ').ToLowerInvariant()), (Get-SafeName $Label), ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $profileName = 'Codex Task - ' + $workspaceId
        $profilePath = Join-Path $profilesRoot $profileName
        $manifestPath = Get-WorkspaceManifestPath -Config $config -Id $workspaceId
        if (Test-Path -LiteralPath $profilePath) { throw "Generated profile already exists: $profilePath" }
        if (Test-Path -LiteralPath $manifestPath) { throw "Generated workspace already exists: $manifestPath" }
        $sourceSnapshot = Get-ProfileSnapshot -Path $sourcePath
        $sourceSaveSnapshot = Get-SaveTreeSnapshot -ProfilePath $sourcePath
        $initialMods = @(Get-ChildItem -LiteralPath $modsRoot -Directory -Force | Select-Object -ExpandProperty Name | Sort-Object)
        $fixture = $null
        if ($SavePolicy -eq 'VerifiedFixture') {
            $fixture = Resolve-VerifiedSaveFixture -Config $config -SourceName $sourceName -SourcePath $sourcePath -SourceSnapshot $sourceSnapshot -RequestedManifestPath $FixtureManifestPath -RequestedFixtureId $FixtureId
        }
        $manifest = [pscustomobject][ordered]@{
            contractVersion = '1.4.0'; workspaceId = $workspaceId; ownerTaskId = $resolvedTaskId; accessId = $AccessId; status = 'creating'; acquisitionDisposition = 'fresh-clone'
            leaseHistory = @([pscustomobject][ordered]@{ accessId = $AccessId; acquiredForWorkspaceUtc = [DateTime]::UtcNow.ToString('o'); disposition = 'created' })
            label = $Label; createdUtc = [DateTime]::UtcNow.ToString('o'); sourceProfile = $sourceName
            sourceProfileName = $sourceName; sourceProfilePath = $sourcePath; sourceProfileDirectory = $sourcePath; sourceSnapshot = $sourceSnapshot
            profile = $profileName; profilePath = $profilePath; profileName = $profileName; profileDirectory = $profilePath; modListPath = (Join-Path $profilePath 'modlist.txt')
            savePolicy = $SavePolicy; fixtureManifestPath = if ($fixture) { [string]$fixture.manifestPath } else { $null }
            saveFixture = $fixture; sourceSaveSnapshot = $sourceSaveSnapshot; initialModNames = $initialMods; protectedSharedModNames = $initialMods; registeredMods = @(); inheritedSaves = $true
            saveGuidance = 'Every source-profile save is copied. MainMenuOnly and FreshGame still describe test authorization; use VerifiedFixture for an exact declared load target. See docs/BREEZEHOME-SAVE.md.'
            ownershipRule = 'The workspace may change only its cloned profile and mods it created and registered. Existing shared mod directories are immutable; profile-local enable/disable markers are allowed.'
        }
        if ($PSCmdlet.ShouldProcess($profilePath, "clone stable MO2 profile '$sourceName' including its complete saves tree")) {
            New-Item -ItemType Directory -Path $profilePath -Force | Out-Null
            foreach ($directory in @(Get-ChildItem -LiteralPath $sourcePath -Directory -Recurse -Force)) {
                $relative = [IO.Path]::GetRelativePath($sourcePath, $directory.FullName)
                New-Item -ItemType Directory -Path (Join-Path $profilePath $relative) -Force | Out-Null
            }
            foreach ($file in @(Get-ChildItem -LiteralPath $sourcePath -File -Recurse -Force)) {
                $relative = [IO.Path]::GetRelativePath($sourcePath, $file.FullName)
                $target = Join-Path $profilePath $relative
                New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
                Copy-Item -LiteralPath $file.FullName -Destination $target
            }
            New-Item -ItemType Directory -Path (Join-Path $profilePath 'saves') -Force | Out-Null
            $profileSaveSnapshot = Get-SaveTreeSnapshot -ProfilePath $profilePath
            if ([string]$profileSaveSnapshot.sha256 -cne [string]$sourceSaveSnapshot.sha256 -or [int]$profileSaveSnapshot.fileCount -ne [int]$sourceSaveSnapshot.fileCount) {
                throw 'Complete source save-tree copy verification failed.'
            }
            $manifest | Add-Member -NotePropertyName profileSaveSnapshot -NotePropertyValue $profileSaveSnapshot
            if ($fixture) {
                $targetSaves = [IO.Path]::GetFullPath((Join-Path $profilePath 'saves'))
                foreach ($file in @($fixture.files)) {
                    $target = [IO.Path]::GetFullPath((Join-Path $targetSaves ([string]$file.relativePath)))
                    if (-not $target.StartsWith($targetSaves + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "Fixture target escapes the task saves directory: $($file.relativePath)" }
                    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "Verified fixture was not present in the complete copied save tree: $target" }
                    if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -cne [string]$file.sha256) { throw "Copied fixture verification failed: $target" }
                }
                $manifest | Add-Member -NotePropertyName copiedVerifiedSaves -NotePropertyValue $true
            }
            $manifest.status = 'ready'
            $manifest | Add-Member -NotePropertyName profileSnapshot -NotePropertyValue (Get-ProfileSnapshot -Path $profilePath)
            Write-WorkspaceJsonAtomic -Path $manifestPath -Value $manifest
            $selectionEvidence = Join-Path (Split-Path -Parent $manifestPath) ($workspaceId + '-create-select')
            $selection = Set-MO2SelectedProfile -Config $config -TargetProfile $profileName -Operation 'select-created-task-workspace' -EvidenceRoot $selectionEvidence
            $manifest | Add-Member -NotePropertyName selectedProfileTransaction -NotePropertyValue $selection
            Write-WorkspaceJsonAtomic -Path $manifestPath -Value $manifest
        }
        elseif ($WhatIfPreference) {
            $selectionEvidence = Join-Path (Split-Path -Parent $manifestPath) ($workspaceId + '-create-select')
            $manifest | Add-Member -NotePropertyName selectedProfileTransaction -NotePropertyValue (Set-MO2SelectedProfile -Config $config -TargetProfile $profileName -Operation 'select-created-task-workspace' -EvidenceRoot $selectionEvidence -WhatIf)
        }
        $result = [pscustomobject][ordered]@{ ok = $true; command = $Command; state = $(if ($WhatIfPreference) { 'dry-run' } else { 'workspace-ready' }); data = $manifest }
    }
    elseif ($Command -eq 'resume') {
        $resolvedTaskId = Resolve-TaskId -RequestedTaskId $TaskId -Required
        if ([string]::IsNullOrWhiteSpace($WorkspaceId)) {
            $available = @(Get-TaskWorkspaces -Config $config -ResolvedTaskId $resolvedTaskId)
            throw "resume requires an exact -WorkspaceId. Available retained workspaces for this task: $((@($available.workspaceId) -join ', ') ?? '<none>')."
        }
        $workspace = Read-Workspace -Config $config -Id $WorkspaceId
        Assert-WorkspaceTaskOwner -Workspace $workspace -ResolvedTaskId $resolvedTaskId
        if ([string]$workspace.data.status -notin @('ready', 'retained')) { throw "Workspace '$WorkspaceId' is not resumable; status is '$($workspace.data.status)'." }
        $profilePath = [IO.Path]::GetFullPath([string]$workspace.data.profilePath)
        if (-not (Test-Path -LiteralPath $profilePath -PathType Container)) {
            $available = @(Get-TaskWorkspaces -Config $config -ResolvedTaskId $resolvedTaskId | Where-Object profileExists)
            throw "Retained workspace '$WorkspaceId' has no profile directory at '$profilePath'. Valid retained workspaces: $((@($available.workspaceId) -join ', ') ?? '<none>'). Request a fresh workspace if none remain."
        }
        $null = Assert-AccessAndClosed -Config $config -OwnedAccessId $AccessId -Profile ([string]$workspace.data.profile)
        $resumeEvidence = Join-Path (Split-Path -Parent $workspace.path) ($WorkspaceId + '-resume-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))
        $approved = $PSCmdlet.ShouldProcess($profilePath, "bind retained workspace to access '$AccessId' and select profile '$($workspace.data.profile)'")
        $selection = Set-MO2SelectedProfile -Config $config -TargetProfile ([string]$workspace.data.profile) -Operation 'resume-retained-task-workspace' -EvidenceRoot $resumeEvidence -WhatIf:(-not $approved)
        if ($approved) {
            $priorAccessId = [string]$workspace.data.accessId
            $registeredNames = @($workspace.data.registeredMods | ForEach-Object { [string]$_.name })
            $protectedNames = if ($workspace.data.PSObject.Properties['protectedSharedModNames']) { @($workspace.data.protectedSharedModNames) } else { @($workspace.data.initialModNames) }
            $currentSharedNames = @(Get-ChildItem -LiteralPath $modsRoot -Directory -Force | Select-Object -ExpandProperty Name | Where-Object { $_ -notin $registeredNames })
            $protectedNames = @($protectedNames + $currentSharedNames | Sort-Object -Unique)
            $workspace.data.accessId = $AccessId
            $workspace.data.status = 'ready'
            $workspace.data | Add-Member -NotePropertyName acquisitionDisposition -NotePropertyValue 'retained-resume' -Force
            $workspace.data | Add-Member -NotePropertyName protectedSharedModNames -NotePropertyValue $protectedNames -Force
            $workspace.data | Add-Member -NotePropertyName lastResumedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
            $history = if ($workspace.data.PSObject.Properties['leaseHistory']) { @($workspace.data.leaseHistory) } else { @() }
            $updatedHistory = @($history) + ,([pscustomobject][ordered]@{ accessId = $AccessId; priorAccessId = $priorAccessId; acquiredForWorkspaceUtc = [DateTime]::UtcNow.ToString('o'); disposition = 'resumed' })
            $workspace.data | Add-Member -NotePropertyName leaseHistory -NotePropertyValue $updatedHistory -Force
            $workspace.data | Add-Member -NotePropertyName selectedProfileTransaction -NotePropertyValue $selection -Force
            Write-WorkspaceJsonAtomic -Path $workspace.path -Value $workspace.data
        }
        $result = [pscustomobject][ordered]@{ ok = $true; command = $Command; state = $(if ($WhatIfPreference) { 'dry-run' } else { 'workspace-resumed' }); data = $workspace.data }
    }
    elseif ($Command -eq 'inspect') {
        $resolvedTaskId = Resolve-TaskId -RequestedTaskId $TaskId -Required
        $owned = Read-OwnedWorkspace -Config $config -Id $WorkspaceId -OwnedAccessId $AccessId -ResolvedTaskId $resolvedTaskId
        $result = [pscustomobject][ordered]@{ ok = $true; command = $Command; state = [string]$owned.data.status; data = $owned.data }
    }
    elseif ($Command -eq 'register-mod') {
        $resolvedTaskId = Resolve-TaskId -RequestedTaskId $TaskId -Required
        $owned = Read-OwnedWorkspace -Config $config -Id $WorkspaceId -OwnedAccessId $AccessId -ResolvedTaskId $resolvedTaskId
        $null = Assert-AccessAndClosed -Config $config -OwnedAccessId $AccessId -Profile ([string]$owned.data.profile)
        if ([string]::IsNullOrWhiteSpace($ModName) -or [string]::IsNullOrWhiteSpace($ModDirectory)) { throw 'register-mod requires ModName and ModDirectory.' }
        $protectedNames = if ($owned.data.PSObject.Properties['protectedSharedModNames']) { @($owned.data.protectedSharedModNames) } else { @($owned.data.initialModNames) }
        if (@($protectedNames | Where-Object { $_ -ceq $ModName }).Count -gt 0) { throw "Refusing to register, edit, or claim the protected shared mod '$ModName'." }
        if (@($owned.data.registeredMods | Where-Object { $_.name -ceq $ModName }).Count -gt 0) { throw "Workspace already registered '$ModName'." }
        $resolvedMod = [IO.Path]::GetFullPath($ModDirectory)
        $expectedMod = [IO.Path]::GetFullPath((Join-Path $modsRoot $ModName))
        if ($resolvedMod -cne $expectedMod) { throw "ModDirectory must be the exact task-owned MO2 mod path: $expectedMod" }
        $evidence = Join-Path (Split-Path -Parent $owned.path) ($WorkspaceId + '-register-' + (Get-SafeName $ModName))
        $profileTool = Join-Path $toolRoot 'mo2-profile-control\Invoke-MO2ProfileControl.ps1'
        $winning = @($WinningPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $arguments = @{
            Command = $(if ($winning.Count -gt 0) { 'register-winning' } else { 'register' }); ProfilePath = (Join-Path ([string]$owned.data.profilePath) 'modlist.txt')
            ModName = $ModName; ModDirectory = $resolvedMod; Placement = $Placement
            EvidenceDirectory = $evidence; BlockingProcessNames = @('MO2WorkspaceImpossibleFixtureProcess')
            Confirm = $false; RegisterEnabled = [bool]$RegisterEnabled; WhatIf = [bool]$WhatIfPreference
        }
        if ($winning.Count -gt 0) { $arguments['ModsDirectory'] = $modsRoot; $arguments['WinningPaths'] = $winning }
        if (-not [string]::IsNullOrWhiteSpace($RelativeToMod)) { $arguments['RelativeToMod'] = $RelativeToMod }
        $registration = & $profileTool @arguments | ConvertFrom-Json
        if (-not $WhatIfPreference) {
            $entry = [pscustomobject][ordered]@{ name = $ModName; path = $resolvedMod; registeredUtc = [DateTime]::UtcNow.ToString('o'); enabled = [bool]$registration.enabled; placement = $Placement; relativeToMod = $RelativeToMod; winningPaths = $winning; evidenceDirectory = $evidence }
            $owned.data.registeredMods = @($owned.data.registeredMods) + @($entry)
            $owned.data.profileSnapshot = Get-ProfileSnapshot -Path ([string]$owned.data.profilePath)
            Write-WorkspaceJsonAtomic -Path $owned.path -Value $owned.data
        }
        $result = [pscustomobject][ordered]@{ ok = $true; command = $Command; state = $(if ($WhatIfPreference) { 'dry-run' } else { 'mod-registered' }); data = @{ workspaceId = $WorkspaceId; registration = $registration } }
    }
    elseif ($Command -eq 'ensure-mod-wins') {
        $resolvedTaskId = Resolve-TaskId -RequestedTaskId $TaskId -Required
        $owned = Read-OwnedWorkspace -Config $config -Id $WorkspaceId -OwnedAccessId $AccessId -ResolvedTaskId $resolvedTaskId
        $null = Assert-AccessAndClosed -Config $config -OwnedAccessId $AccessId -Profile ([string]$owned.data.profile)
        if ([string]::IsNullOrWhiteSpace($ModName)) { throw 'ensure-mod-wins requires ModName.' }
        $matches = @($owned.data.registeredMods | Where-Object { [string]$_.name -ceq $ModName })
        if ($matches.Count -ne 1) { throw "ensure-mod-wins requires exactly one task-owned registered mod named '$ModName'; found $($matches.Count)." }
        $winning = @($WinningPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($winning.Count -eq 0) { throw 'ensure-mod-wins requires at least one WinningPaths entry.' }
        $registered = $matches[0]
        $evidence = Join-Path (Split-Path -Parent $owned.path) ($WorkspaceId + '-winner-' + (Get-SafeName $ModName) + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $profileTool = Join-Path $toolRoot 'mo2-profile-control\Invoke-MO2ProfileControl.ps1'
        $winner = & $profileTool ensure-winner -ProfilePath (Join-Path ([string]$owned.data.profilePath) 'modlist.txt') -ModName $ModName -ModDirectory ([string]$registered.path) -ModsDirectory $modsRoot -WinningPaths $winning -EvidenceDirectory $evidence -BlockingProcessNames @('MO2WorkspaceImpossibleFixtureProcess') -Confirm:$false -WhatIf:$WhatIfPreference | ConvertFrom-Json
        if (-not $WhatIfPreference) {
            $registered.enabled = $true
            if ($registered.PSObject.Properties['winningPaths']) { $registered.winningPaths = $winning } else { $registered | Add-Member -NotePropertyName winningPaths -NotePropertyValue $winning }
            $history = if ($registered.PSObject.Properties['winnerEvidenceDirectories']) { @($registered.winnerEvidenceDirectories) } else { @() }
            if ($registered.PSObject.Properties['winnerEvidenceDirectories']) { $registered.winnerEvidenceDirectories = $history + @($evidence) } else { $registered | Add-Member -NotePropertyName winnerEvidenceDirectories -NotePropertyValue ($history + @($evidence)) }
            $owned.data.profileSnapshot = Get-ProfileSnapshot -Path ([string]$owned.data.profilePath)
            Write-WorkspaceJsonAtomic -Path $owned.path -Value $owned.data
        }
        $result = [pscustomobject][ordered]@{ ok = $true; command = $Command; state = $(if ($WhatIfPreference) { 'dry-run' } else { 'winner-verified' }); data = @{ workspaceId = $WorkspaceId; winner = $winner; evidenceDirectory = $evidence } }
    }
    else {
        $resolvedTaskId = Resolve-TaskId -RequestedTaskId $TaskId -Required
        $owned = Read-OwnedWorkspace -Config $config -Id $WorkspaceId -OwnedAccessId $AccessId -ResolvedTaskId $resolvedTaskId
        $null = Assert-AccessAndClosed -Config $config -OwnedAccessId $AccessId -Profile ([string]$owned.data.sourceProfile)
        $profilePath = [IO.Path]::GetFullPath([string]$owned.data.profilePath)
        if (-not $profilePath.StartsWith($profilesRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or $profilePath -eq [IO.Path]::GetFullPath([string]$owned.data.sourceProfilePath)) { throw 'Workspace profile cleanup target escaped the configured profiles directory or matched the stable source.' }
        $cleanupMods = @()
        foreach ($mod in @($owned.data.registeredMods)) {
            $modPath = [IO.Path]::GetFullPath([string]$mod.path)
            $expected = [IO.Path]::GetFullPath((Join-Path $modsRoot ([string]$mod.name)))
            if ($modPath -cne $expected -or -not $modPath.StartsWith($modsRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "Owned mod cleanup target is unsafe: $modPath" }
            $cleanupMods += $modPath
        }
        $releaseEvidence = Join-Path (Split-Path -Parent $owned.path) ($WorkspaceId + '-retire')
        $releaseApproved = $PSCmdlet.ShouldProcess($profilePath, "select stable profile '$($owned.data.sourceProfile)' and remove exact task-owned profile")
        $profileSelection = Set-MO2SelectedProfile -Config $config -TargetProfile ([string]$owned.data.sourceProfile) -Operation 'select-stable-before-workspace-retirement' -EvidenceRoot $releaseEvidence -WhatIf:(-not $releaseApproved)
        if ($releaseApproved) {
            try {
                if (Test-Path -LiteralPath $profilePath -PathType Container) { Remove-Item -LiteralPath $profilePath -Recurse -Force }
            }
            catch {
                Write-WorkspaceBytesAtomic -Path ([string]$profileSelection.iniPath) -Bytes ([IO.File]::ReadAllBytes([string]$profileSelection.backupPath))
                throw "Workspace profile removal failed; the exact prior MO2 INI bytes were restored. $($_.Exception.Message)"
            }
            if ($CleanupOwnedMods) {
                foreach ($modPath in $cleanupMods) { if (Test-Path -LiteralPath $modPath -PathType Container) { Remove-Item -LiteralPath $modPath -Recurse -Force } }
            }
            $owned.data.status = 'retired'
            $owned.data | Add-Member -NotePropertyName retiredUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
            $owned.data | Add-Member -NotePropertyName profileRemoved -NotePropertyValue $true -Force
            $owned.data | Add-Member -NotePropertyName ownedModsRemoved -NotePropertyValue ([bool]$CleanupOwnedMods) -Force
            $owned.data | Add-Member -NotePropertyName selectedProfileRelease -NotePropertyValue $profileSelection -Force
            Write-WorkspaceJsonAtomic -Path $owned.path -Value $owned.data
        }
        $result = [pscustomobject][ordered]@{ ok = $true; command = $Command; state = $(if ($WhatIfPreference) { 'dry-run' } else { 'workspace-retired' }); data = @{
            workspaceId = $WorkspaceId; profile = [string]$owned.data.profile; profilePath = $profilePath
            profileName = [string]$owned.data.profile; profileDirectory = $profilePath; modListPath = (Join-Path $profilePath 'modlist.txt')
            selectedProfileRelease = $profileSelection; wouldOrDidRemoveOwnedMods = [bool]$CleanupOwnedMods
            releaseAccessRequired = $true; manifestPath = $owned.path
            deprecatedCommand = if ($Command -eq 'release') { 'release is a compatibility alias for destructive retire; use retire. To yield scarce MO2 access while retaining this profile, call MO2 release-access only.' } else { $null }
        } }
    }
}
catch {
    $result = [pscustomobject][ordered]@{ ok = $false; command = $Command; state = 'tool-error'; errors = @($_.Exception.Message); data = @{} }
}

$result.data | Add-Member -NotePropertyName approval -NotePropertyValue (New-WorkspaceApprovalMetadata -Subcommand $Command) -Force
$jsonParameters = @{ InputObject = $result; Depth = 18 }
if ($Compact) { $jsonParameters['Compress'] = $true }
ConvertTo-Json @jsonParameters
if (-not $result.ok -and -not $NoExit) { exit 2 }
