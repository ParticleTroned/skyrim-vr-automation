# SPDX-License-Identifier: GPL-3.0-or-later

function Get-ProfilerTimingSemantics($Record) {
    $property = $Record.PSObject.Properties['timingSemantics']
    if ($null -eq $property) { return 'legacy_unspecified' }
    if ($property.Value -isnot [string] -or $property.Value -cnotin @('gpu_cpu_self_time', 'legacy_unspecified')) {
        throw 'Profiler timingSemantics is malformed or unsupported.'
    }
    return [string]$property.Value
}
