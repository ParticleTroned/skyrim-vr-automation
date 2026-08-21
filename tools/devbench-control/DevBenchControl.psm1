# SPDX-License-Identifier: GPL-3.0-or-later

Set-StrictMode -Version Latest

function Get-DevBenchSemanticStatus {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Content)

    $known = $false
    $reasons = [Collections.Generic.List[string]]::new()
    foreach ($item in @($Content)) {
        if ($null -eq $item -or $item -is [string]) { continue }
        $okProperty = $item.PSObject.Properties['ok']
        if ($okProperty) {
            $known = $true
            if (-not [bool]$okProperty.Value) { $reasons.Add('content.ok is false') }
        }
        $abortedProperty = $item.PSObject.Properties['aborted']
        if ($abortedProperty -and [bool]$abortedProperty.Value) {
            $known = $true
            $reasons.Add('content.aborted is true')
        }
        foreach ($propertyName in @('status', 'resultStatus')) {
            $property = $item.PSObject.Properties[$propertyName]
            if (-not $property -or $null -eq $property.Value) { continue }
            $nameProperty = $property.Value.PSObject.Properties['name']
            $valueProperty = $property.Value.PSObject.Properties['value']
            if ($nameProperty) {
                $known = $true
                $name = [string]$nameProperty.Value
                if ($name -notin @('success', 'ok')) { $reasons.Add("$propertyName.name is '$name'") }
            }
            elseif ($valueProperty) {
                $known = $true
                if ([int64]$valueProperty.Value -ne 0) { $reasons.Add("$propertyName.value is $($valueProperty.Value)") }
            }
        }
    }
    return [pscustomobject][ordered]@{ known = $known; ok = $reasons.Count -eq 0; reasons = @($reasons) }
}

function Test-DevBenchNoBlockingMenu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$MenuState,
        [string[]]$IgnoredMenus = @('HUD Menu')
    )
    $openMenus = if ($MenuState.PSObject.Properties['openMenus']) { @($MenuState.openMenus) } else { @() }
    $blocking = @($openMenus | Where-Object { $_ -notin $IgnoredMenus })
    $messageBoxOpen = $MenuState.PSObject.Properties['messageBoxOpen'] -and [bool]$MenuState.messageBoxOpen
    return [pscustomobject][ordered]@{
        satisfied = $blocking.Count -eq 0 -and -not $messageBoxOpen
        openMenus = $openMenus
        ignoredMenus = @($IgnoredMenus)
        blockingMenus = $blocking
        messageBoxOpen = [bool]$messageBoxOpen
    }
}

function Get-DevBenchRuntimeExpectations {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Runtime)
    $pidValue = $null
    foreach ($name in @('pid', 'processId')) {
        $property = $Runtime.PSObject.Properties[$name]
        if ($property -and $null -ne $property.Value) { $pidValue = [int]$property.Value; break }
    }
    $exeValue = $null
    foreach ($name in @('exe', 'executable')) {
        $property = $Runtime.PSObject.Properties[$name]
        if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) { $exeValue = [string]$property.Value; break }
    }
    $buildId = if ($Runtime.PSObject.Properties['buildId']) { [string]$Runtime.buildId } else { $null }
    $artifactPath = if ($Runtime.PSObject.Properties['artifactPath']) { [string]$Runtime.artifactPath } elseif ($Runtime.PSObject.Properties['dllPath']) { [string]$Runtime.dllPath } else { $null }
    $artifactSha256 = if ($Runtime.PSObject.Properties['artifactSha256']) { [string]$Runtime.artifactSha256 } else { $null }
    return [pscustomobject][ordered]@{ port = [int]$Runtime.port; pid = $pidValue; exe = $exeValue; buildId = $buildId; artifactPath = $artifactPath; artifactSha256 = $artifactSha256 }
}

Export-ModuleMember -Function Get-DevBenchSemanticStatus, Test-DevBenchNoBlockingMenu, Get-DevBenchRuntimeExpectations
