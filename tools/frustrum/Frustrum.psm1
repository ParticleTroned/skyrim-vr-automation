#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-FrustrumPlan {
    param([Parameter(Mandatory)][int[]]$SaveNumbers)
    $ordinal = 0
    $pairIndex = 0
    foreach ($number in $SaveNumbers) {
        if ($number -lt 0) { throw 'Save numbers must be nonnegative.' }
        $pairIndex++
        foreach ($enabled in @($false, $true)) {
            $ordinal++
            [pscustomobject]@{
                ordinal = $ordinal; pairIndex = $pairIndex
                saveNumber = $number.ToString('00', [Globalization.CultureInfo]::InvariantCulture)
                enabled = $enabled; mode = $(if ($enabled) { 'ON' } else { 'OFF' })
            }
        }
    }
}

function Assert-FrustrumState {
    param($State, [Nullable[bool]]$ExpectedEnabled = $null)
    if (!$State -or $State.schemaVersion -ne 2 -or $State.implementation -cne 'single_traversal') {
        throw 'frustrum requires single_traversal diagnostics schema 2.'
    }
    foreach ($key in @('installed','enabled','verification','mismatchLatched')) {
        if ($State.$key -isnot [bool]) { throw "Missing or invalid frustum state: $key" }
    }
    if (!$State.installed -or $State.verification -or $State.mismatchLatched) {
        throw 'Fast path unavailable, verification active or mismatch latched; comparison stopped.'
    }
    $mode = if ($State.enabled) { 'fast' } else { 'native' }
    if ($State.effectiveMode -cne $mode -or ($null -ne $ExpectedEnabled -and $State.enabled -ne $ExpectedEnabled)) {
        throw 'Requested and effective frustum modes do not match the measurement leg.'
    }
}

function Assert-DepthJobBackoffState {
    param($Status, [Nullable[bool]]$ExpectedEnabled = $null, $ExpectedControl = $null, $ExpectedCollection = $null)
    Assert-FrustrumState $Status.frustumFastPath $false
    $native = $Status.nativeFrustum
    $jobs = $native.depthJobs
    $state = $jobs.backoff
    if ($native.schemaVersion -ne 2 -or $jobs.schemaVersion -ne 1 -or $state.schemaVersion -ne 1) {
        throw 'Backoff requires native frustum schema 2 and depth-job/backoff schema 1.'
    }
    foreach ($value in @($native.enabled, $native.active, $jobs.installed, $jobs.active)) {
        if ($value -isnot [bool] -or !$value) { throw 'Depth-job collection is unavailable or inactive.' }
    }
    if ($native.detailEnabled -isnot [bool] -or !$native.detailEnabled) { throw 'Matched detailed collection is required.' }
    foreach ($value in @($state.enabled, $state.active)) {
        if ($value -isnot [bool]) { throw 'Invalid backoff boolean state.' }
    }
    foreach ($value in @($state.control, $state.controlAtEnd, $native.collectionGeneration, $native.collectionGenerationAtEnd)) {
        if ($null -eq $value -or $value -is [string] -or $value -is [bool] -or $value -lt 0 -or $value -ne [math]::Truncate($value)) { throw 'Invalid backoff control/generation.' }
    }
    if ($state.control -ne $state.controlAtEnd -or $native.collectionGeneration -ne $native.collectionGenerationAtEnd -or
        $state.active -ne $state.enabled -or [bool]($state.control -band 1) -ne $state.enabled -or
        $state.warmupEndMarkers -ne 8 -or $state.maximumPauseInstructionsPerDispatch -ne 32 -or
        ($null -ne $ExpectedEnabled -and $state.enabled -ne $ExpectedEnabled) -or
        ($null -ne $ExpectedControl -and $state.control -ne $ExpectedControl) -or
        ($null -ne $ExpectedCollection -and $native.collectionGeneration -ne $ExpectedCollection)) {
        throw 'Backoff mode, controls or collection changed during the measurement leg.'
    }
}

Export-ModuleMember -Function New-FrustrumPlan, Assert-FrustrumState, Assert-DepthJobBackoffState
