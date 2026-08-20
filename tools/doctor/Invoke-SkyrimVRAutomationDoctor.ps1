# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('inspect', 'init')]
    [string]$Command = 'inspect',

    [string]$ConfigPath,
    [string]$SourceConfigPath,
    [string]$UserConfigPath,
    [string]$SteamVRSettingsPath = 'C:\Program Files (x86)\Steam\config\steamvr.vrsettings',
    [string]$SteamVRRoot = 'C:\Program Files (x86)\Steam\steamapps\common\SteamVR',
    [string]$RuntimePath = $env:CSX_DEVBENCH_RUNTIME_PATH,
    [switch]$WhatIf,
    [switch]$Compact
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$mo2Root = Join-Path $repositoryRoot 'tools\mo2-control'
Import-Module (Join-Path $mo2Root 'ConfigResolution.psm1') -Force

function New-DoctorCheck([string]$Name, [string]$Status, [string]$Message, $Data = $null) {
    [pscustomobject][ordered]@{ name = $Name; status = $Status; message = $Message; data = $Data }
}

try {
    $targetPath = if ([string]::IsNullOrWhiteSpace($UserConfigPath)) { Get-MO2ControlUserConfigPath } else { [IO.Path]::GetFullPath($UserConfigPath) }
    if ($Command -eq 'init') {
        $source = if (-not [string]::IsNullOrWhiteSpace($SourceConfigPath)) {
            [IO.Path]::GetFullPath($SourceConfigPath)
        } else {
            Join-Path $mo2Root 'config\machine.example.json'
        }
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Configuration source does not exist: $source" }
        if (Test-Path -LiteralPath $targetPath) { throw "Configuration target already exists; it was not overwritten: $targetPath" }

        $created = $false
        if (-not $WhatIf) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $targetPath) -Force | Out-Null
            Copy-Item -LiteralPath $source -Destination $targetPath
            $created = $true
        }
        $result = [pscustomobject][ordered]@{
            schemaVersion = 1; ok = $true; command = 'init'; timestampUtc = [DateTime]::UtcNow.ToString('o')
            state = if ($created) { 'created' } else { 'dry-run' }
            checks = @(); warnings = @(); errors = @()
            data = [pscustomobject][ordered]@{ source = $source; target = $targetPath; created = $created; sha256 = if ($created) { (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash } else { $null } }
        }
    }
    else {
        $checks = [System.Collections.Generic.List[object]]::new()
        $resolution = Resolve-MO2ControlConfigPath -ConfigPath $ConfigPath -PackageRoot $mo2Root -UserConfigPath $targetPath
        $checks.Add((New-DoctorCheck 'powershell' $(if ($PSVersionTable.PSVersion.Major -ge 7) { 'pass' } else { 'fail' }) "PowerShell $($PSVersionTable.PSVersion)"))
        $checks.Add((New-DoctorCheck 'platform' $(if ($IsWindows) { 'pass' } else { 'fail' }) $(if ($IsWindows) { 'Windows detected.' } else { 'The bundled controllers currently require Windows.' })))
        $checks.Add((New-DoctorCheck 'mo2-config' $(if ($resolution.exists) { 'pass' } else { 'fail' }) "MO2 config source '$($resolution.source)': $($resolution.path)" $resolution))

        $mo2Validation = $null
        if ($resolution.exists) {
            $raw = & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $mo2Root 'Invoke-MO2Control.ps1') validate -ConfigPath $resolution.path -Compact 2>&1
            try { $mo2Validation = ($raw -join "`n") | ConvertFrom-Json -Depth 30 } catch { $mo2Validation = [pscustomobject]@{ ok = $false; raw = @($raw) } }
            $checks.Add((New-DoctorCheck 'mo2-validation' $(if ($mo2Validation.ok) { 'pass' } else { 'fail' }) $(if ($mo2Validation.ok) { 'MO2 configuration validates.' } else { 'MO2 configuration validation failed.' }) $mo2Validation))
        }

        $nullProfile = Join-Path $repositoryRoot 'profiles\steamvr-null.profile.json'
        $checks.Add((New-DoctorCheck 'null-profile' $(if (Test-Path -LiteralPath $nullProfile -PathType Leaf) { 'pass' } else { 'fail' }) $nullProfile))
        $checks.Add((New-DoctorCheck 'steamvr-settings' $(if (Test-Path -LiteralPath $SteamVRSettingsPath -PathType Leaf) { 'pass' } else { 'warn' }) $SteamVRSettingsPath))
        $checks.Add((New-DoctorCheck 'steamvr-root' $(if (Test-Path -LiteralPath $SteamVRRoot -PathType Container) { 'pass' } else { 'warn' }) $SteamVRRoot))
        $checks.Add((New-DoctorCheck 'devbench-runtime' $(if ([string]::IsNullOrWhiteSpace($RuntimePath)) { 'info' } elseif (Test-Path -LiteralPath $RuntimePath -PathType Leaf) { 'pass' } else { 'warn' }) $(if ([string]::IsNullOrWhiteSpace($RuntimePath)) { 'Optional DevBench runtime path is not configured.' } else { $RuntimePath })))

        $failed = @($checks | Where-Object status -eq 'fail')
        $result = [pscustomobject][ordered]@{
            schemaVersion = 1; ok = $failed.Count -eq 0; command = 'inspect'; timestampUtc = [DateTime]::UtcNow.ToString('o')
            state = if ($failed.Count -eq 0) { 'ready' } else { 'configuration-required' }
            checks = @($checks); warnings = @($checks | Where-Object status -eq 'warn' | ForEach-Object message); errors = @($failed | ForEach-Object message)
            data = [pscustomobject][ordered]@{ repositoryRoot = $repositoryRoot; configuration = $resolution; userConfigPath = $targetPath }
        }
    }
}
catch {
    $result = [pscustomobject][ordered]@{ schemaVersion = 1; ok = $false; command = $Command; timestampUtc = [DateTime]::UtcNow.ToString('o'); state = 'tool-error'; checks = @(); warnings = @(); errors = @($_.Exception.Message); data = $null }
}

$json = @{ InputObject = $result; Depth = 40 }
if ($Compact) { $json.Compress = $true }
ConvertTo-Json @json
if (-not $result.ok) { exit 2 }
