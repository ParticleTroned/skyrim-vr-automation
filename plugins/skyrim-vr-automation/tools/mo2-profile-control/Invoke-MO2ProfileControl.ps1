# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('inspect', 'register', 'enable', 'disable', 'restore')]
    [string]$Command,

    [Parameter(Mandatory)]
    [string]$ProfilePath,

    [Parameter(Mandatory)]
    [string]$ModName,

    [string]$ModDirectory,

    [ValidateSet('End', 'Before', 'After')]
    [string]$Placement = 'End',

    [string]$RelativeToMod,

    [switch]$RegisterEnabled,

    [string]$EvidenceDirectory,

    [ValidateNotNullOrEmpty()]
    [string[]]$BlockingProcessNames = @('ModOrganizer', 'SkyrimVR', 'sksevr_loader'),

    [switch]$NoExit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Test-ProfileShouldProcess($Caller, [string]$Target, [string]$Action) {
    try {
        return $Caller.ShouldProcess($Target, $Action)
    }
    catch {
        throw "PowerShell's interactive confirmation host is unavailable. Use -WhatIf to preview or -Confirm:`$false for an already-authorized automation transaction. Original error: $($_.Exception.Message)"
    }
}

$resolvedProfile = [IO.Path]::GetFullPath($ProfilePath)
if (-not (Test-Path -LiteralPath $resolvedProfile -PathType Leaf)) {
    throw "Profile modlist does not exist: $resolvedProfile"
}

$beforeBytes = [IO.File]::ReadAllBytes($resolvedProfile)
$beforeMatches = @(Get-ModLineMatches -Bytes $beforeBytes -Name $ModName)
$beforeLine = if ($beforeMatches.Count -eq 1) { Get-ModLineRecord -Bytes $beforeBytes -Name $ModName } else { $null }
$beforeHash = Get-Sha256 $resolvedProfile
$processes = @(Get-LiveProcesses -Names $BlockingProcessNames)

if ($Command -eq 'inspect') {
    if ($beforeMatches.Count -ne 1) { throw "Expected exactly one modlist line for '$ModName'; found $($beforeMatches.Count)." }
    [pscustomobject][ordered]@{
        ok = $true
        command = $Command
        profilePath = $resolvedProfile
        modName = $ModName
        enabled = $beforeLine.enabled
        marker = $beforeLine.marker
        sha256 = $beforeHash
        processes = $processes
    } | ConvertTo-Json -Depth 5
    return
}

if ($processes.Count -gt 0) {
    throw "MO2 profile mutation requires MO2 and Skyrim to be closed. Active: $($processes.name -join ', ')."
}
if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    throw '-EvidenceDirectory is required for enable, disable, and restore.'
}

$resolvedEvidence = [IO.Path]::GetFullPath($EvidenceDirectory)
$backupPath = Join-Path $resolvedEvidence 'modlist.before.bin'
$receiptPath = Join-Path $resolvedEvidence 'modlist-control.receipt.json'

if ($Command -eq 'register') {
    if ($beforeMatches.Count -ne 0) {
        throw "Registration requires no existing marker for '$ModName'; found $($beforeMatches.Count)."
    }
    if ([string]::IsNullOrWhiteSpace($ModDirectory)) { throw '-ModDirectory is required for register.' }
    $resolvedModDirectory = [IO.Path]::GetFullPath($ModDirectory)
    if (-not (Test-Path -LiteralPath $resolvedModDirectory -PathType Container)) { throw "Deployed mod directory does not exist: $resolvedModDirectory" }
    if ([IO.Path]::GetFileName($resolvedModDirectory) -cne $ModName) { throw "The deployed mod directory name must exactly match ModName ('$ModName')." }
    if (Test-Path -LiteralPath $backupPath -PathType Leaf) { throw "Refusing to overwrite an existing exact backup: $backupPath" }
    $afterBytes = Add-ModLine -Bytes $beforeBytes -Name $ModName -Enabled ([bool]$RegisterEnabled) -LinePlacement $Placement -RelativeName $RelativeToMod
    if (Test-ProfileShouldProcess -Caller $PSCmdlet -Target $resolvedProfile -Action "register exact MO2 mod '$ModName' as $(if ($RegisterEnabled) { 'enabled' } else { 'disabled' }) at $Placement") {
        if (-not (Test-Path -LiteralPath $resolvedEvidence -PathType Container)) { New-Item -ItemType Directory -Path $resolvedEvidence -Force | Out-Null }
        [IO.File]::WriteAllBytes($backupPath, $beforeBytes)
        Write-BytesAtomically -Path $resolvedProfile -Bytes $afterBytes
        $afterLine = Get-ModLineRecord -Bytes ([IO.File]::ReadAllBytes($resolvedProfile)) -Name $ModName
        $afterHash = Get-Sha256 $resolvedProfile
        [pscustomobject][ordered]@{
            contractVersion = '1.2.0'; operation = 'register'; profilePath = $resolvedProfile
            modName = $ModName; modDirectory = $resolvedModDirectory; backupPath = $backupPath
            beforeSha256 = $beforeHash; resultSha256 = $afterHash; beforeMarker = $null
            resultMarker = $afterLine.marker; placement = $Placement; relativeToMod = $RelativeToMod
            changedUtc = [DateTime]::UtcNow.ToString('o')
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $receiptPath -Encoding utf8
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
        if (-not (Test-Path -LiteralPath $resolvedEvidence -PathType Container)) {
            New-Item -ItemType Directory -Path $resolvedEvidence -Force | Out-Null
        }
        [IO.File]::WriteAllBytes($backupPath, $beforeBytes)
        Write-BytesAtomically -Path $resolvedProfile -Bytes $afterBytes
        $afterHash = Get-Sha256 $resolvedProfile
        $afterLine = Get-ModLineRecord -Bytes ([IO.File]::ReadAllBytes($resolvedProfile)) -Name $ModName
        if ($afterLine.enabled -ne $targetEnabled -or $afterHash -eq $beforeHash) {
            $targetState = if ($targetEnabled) { 'enabled' } else { 'disabled' }
            throw "Postcondition failed: exact mod was not $targetState."
        }
        [pscustomobject][ordered]@{
            contractVersion = '1.1.0'
            operation = $Command
            profilePath = $resolvedProfile
            modName = $ModName
            backupPath = $backupPath
            beforeSha256 = $beforeHash
            resultSha256 = $afterHash
            beforeMarker = $expectedMarker
            resultMarker = $targetMarker
            changedUtc = [DateTime]::UtcNow.ToString('o')
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $receiptPath -Encoding utf8
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
        Write-BytesAtomically -Path $resolvedProfile -Bytes $restoreBytes
        if ((Get-Sha256 $resolvedProfile) -ne [string]$receipt.beforeSha256) {
            throw 'Postcondition failed: exact modlist bytes were not restored.'
        }
    }
}

$finalBytes = [IO.File]::ReadAllBytes($resolvedProfile)
$finalMatches = @(Get-ModLineMatches -Bytes $finalBytes -Name $ModName)
$finalLine = if ($finalMatches.Count -eq 1) { Get-ModLineRecord -Bytes $finalBytes -Name $ModName } else { $null }
[pscustomobject][ordered]@{
    ok = $true
    command = $Command
    whatIf = [bool]$WhatIfPreference
    profilePath = $resolvedProfile
    modName = $ModName
    enabled = if ($finalLine) { $finalLine.enabled } else { $null }
    marker = if ($finalLine) { $finalLine.marker } else { $null }
    sha256 = Get-Sha256 $resolvedProfile
    backupPath = $backupPath
    receiptPath = $receiptPath
} | ConvertTo-Json -Depth 5
