# SPDX-License-Identifier: GPL-3.0-or-later

Set-StrictMode -Version Latest

function Get-MO2ControlUserConfigPath {
    [CmdletBinding()]
    param()

    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        throw 'Windows LocalApplicationData could not be resolved.'
    }
    Join-Path $localAppData 'SkyrimVRAutomation\machine.local.json'
}

function Resolve-MO2ControlConfigPath {
    [CmdletBinding()]
    param(
        [string]$ConfigPath,
        [string]$PackageRoot = $PSScriptRoot,
        [string]$UserConfigPath
    )

    $candidates = [System.Collections.Generic.List[object]]::new()
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        $candidates.Add([pscustomobject]@{ source = 'explicit'; path = [IO.Path]::GetFullPath($ConfigPath) })
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:SKYRIM_VR_AUTOMATION_CONFIG)) {
        $candidates.Add([pscustomobject]@{ source = 'environment'; path = [IO.Path]::GetFullPath($env:SKYRIM_VR_AUTOMATION_CONFIG) })
    }
    else {
        $stablePath = if ([string]::IsNullOrWhiteSpace($UserConfigPath)) { Get-MO2ControlUserConfigPath } else { [IO.Path]::GetFullPath($UserConfigPath) }
        $candidates.Add([pscustomobject]@{ source = 'user'; path = $stablePath })
        $candidates.Add([pscustomobject]@{ source = 'legacy-package-local'; path = [IO.Path]::GetFullPath((Join-Path $PackageRoot 'config\machine.local.json')) })
    }

    $selected = @($candidates | Where-Object { Test-Path -LiteralPath $_.path -PathType Leaf } | Select-Object -First 1)
    if ($selected.Count -eq 0) { $selected = @($candidates[0]) }

    [pscustomobject][ordered]@{
        path = [string]$selected[0].path
        source = [string]$selected[0].source
        exists = Test-Path -LiteralPath $selected[0].path -PathType Leaf
        candidates = @($candidates)
    }
}

Export-ModuleMember -Function Get-MO2ControlUserConfigPath, Resolve-MO2ControlConfigPath
