# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('inspect', 'disable', 'restore')]
    [string]$Command,

    [Parameter(Mandatory)]
    [string]$ProfilePath,

    [Parameter(Mandatory)]
    [string]$ModName,

    [string]$EvidenceDirectory,

    [ValidateNotNullOrEmpty()]
    [string[]]$BlockingProcessNames = @('ModOrganizer', 'SkyrimVR', 'sksevr_loader')
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

function Get-ModLineRecord([byte[]]$Bytes, [string]$Name) {
    $text = [Text.Encoding]::UTF8.GetString($Bytes)
    $escaped = [regex]::Escape($Name)
    $matches = [regex]::Matches($text, "(?m)^(?<marker>[+-])(?<name>$escaped)\r?$")
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

$resolvedProfile = [IO.Path]::GetFullPath($ProfilePath)
if (-not (Test-Path -LiteralPath $resolvedProfile -PathType Leaf)) {
    throw "Profile modlist does not exist: $resolvedProfile"
}

$beforeBytes = [IO.File]::ReadAllBytes($resolvedProfile)
$beforeLine = Get-ModLineRecord -Bytes $beforeBytes -Name $ModName
$beforeHash = Get-Sha256 $resolvedProfile
$processes = @(Get-LiveProcesses -Names $BlockingProcessNames)

if ($Command -eq 'inspect') {
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
    exit 0
}

if ($processes.Count -gt 0) {
    throw "MO2 profile mutation requires MO2 and Skyrim to be closed. Active: $($processes.name -join ', ')."
}
if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    throw '-EvidenceDirectory is required for disable and restore.'
}

$resolvedEvidence = [IO.Path]::GetFullPath($EvidenceDirectory)
$backupPath = Join-Path $resolvedEvidence 'modlist.before.bin'
$receiptPath = Join-Path $resolvedEvidence 'modlist-control.receipt.json'

if ($Command -eq 'disable') {
    if (-not $beforeLine.enabled) {
        throw "The exact mod is already disabled: $ModName"
    }
    if (-not (Test-Path -LiteralPath $resolvedEvidence -PathType Container)) {
        New-Item -ItemType Directory -Path $resolvedEvidence -Force | Out-Null
    }
    if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
        throw "Refusing to overwrite an existing exact backup: $backupPath"
    }

    [IO.File]::WriteAllBytes($backupPath, $beforeBytes)
    $afterBytes = [byte[]]::new($beforeBytes.Length)
    [Array]::Copy($beforeBytes, $afterBytes, $beforeBytes.Length)
    if ($afterBytes[$beforeLine.byteOffset] -ne [byte][char]'+') {
        throw 'The calculated marker byte is not the expected plus sign.'
    }
    $afterBytes[$beforeLine.byteOffset] = [byte][char]'-'

    if ($PSCmdlet.ShouldProcess($resolvedProfile, "Disable exact MO2 mod '$ModName'")) {
        Write-BytesAtomically -Path $resolvedProfile -Bytes $afterBytes
        $afterHash = Get-Sha256 $resolvedProfile
        $afterLine = Get-ModLineRecord -Bytes ([IO.File]::ReadAllBytes($resolvedProfile)) -Name $ModName
        if ($afterLine.enabled -or $afterHash -eq $beforeHash) {
            throw 'Postcondition failed: exact mod was not disabled.'
        }
        [pscustomobject][ordered]@{
            contractVersion = '1.0.0'
            profilePath = $resolvedProfile
            modName = $ModName
            backupPath = $backupPath
            beforeSha256 = $beforeHash
            disabledSha256 = $afterHash
            disabledUtc = [DateTime]::UtcNow.ToString('o')
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
    if ($beforeHash -ne [string]$receipt.disabledSha256) {
        throw 'Current modlist differs from the state produced by this control; refusing to overwrite it.'
    }
    $restoreBytes = [IO.File]::ReadAllBytes($backupPath)
    if ($PSCmdlet.ShouldProcess($resolvedProfile, "Restore exact MO2 modlist bytes for '$ModName'")) {
        Write-BytesAtomically -Path $resolvedProfile -Bytes $restoreBytes
        if ((Get-Sha256 $resolvedProfile) -ne [string]$receipt.beforeSha256) {
            throw 'Postcondition failed: exact modlist bytes were not restored.'
        }
    }
}

$finalBytes = [IO.File]::ReadAllBytes($resolvedProfile)
$finalLine = Get-ModLineRecord -Bytes $finalBytes -Name $ModName
[pscustomobject][ordered]@{
    ok = $true
    command = $Command
    whatIf = [bool]$WhatIfPreference
    profilePath = $resolvedProfile
    modName = $ModName
    enabled = $finalLine.enabled
    marker = $finalLine.marker
    sha256 = Get-Sha256 $resolvedProfile
    backupPath = $backupPath
    receiptPath = $receiptPath
} | ConvertTo-Json -Depth 5
