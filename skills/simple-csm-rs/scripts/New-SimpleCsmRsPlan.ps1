# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('nvidia', 'amd')][string]$Adapter,
    [Parameter(Mandatory)][ValidateSet('fsr3', 'fsr4')][string]$FsrRuntime,
    [string]$ProtocolPath = (Join-Path $PSScriptRoot '../../../tools/render-scale-qualification/protocol.v1.json')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$raw = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $ProtocolPath).Path)
$protocol = [Text.Encoding]::UTF8.GetString($raw) | ConvertFrom-Json -Depth 30
if ($protocol.schema -cne 'csx-render-scale-pr-v1' -or $protocol.protocolRevision -ne 6) {
    throw 'Unsupported canonical protocol schema/revision; review the expansion before running.'
}
$matrix = @($protocol.menuAssay.($Adapter.ToLowerInvariant() + 'Matrix'))
if ($matrix.Count -ne 25) { throw 'Canonical menu matrix must contain 25 entries.' }
$qualities = @('native_aa', 'hoshipa', 'ultra_quality', 'quality', 'balanced', 'performance', 'ultra_performance')
$plan = [Collections.Generic.List[object]]::new()
$sourceOrdinal = 0
foreach ($entry in $matrix) {
    $sourceOrdinal++
    if ($entry.ordinal -ne $sourceOrdinal -or $entry.method -cnotin @('dlss', 'fsr') -or
        ($Adapter -eq 'amd' -and $entry.method -cne 'fsr') -or
        $entry.qualityModeValue -isnot [long] -or $entry.qualityModeValue -lt 0 -or $entry.qualityModeValue -gt 6 -or
        $entry.qualityMode -cne $qualities[$entry.qualityModeValue] -or
        $entry.renderScaleMode -isnot [bool] -or $entry.renderScaleMode -ne ($entry.qualityModeValue -ne 0)) {
        throw "Invalid canonical menu entry $sourceOrdinal."
    }
    $states = if ($entry.qualityModeValue -eq 0) { @($false) } else { @($false, $true) }
    foreach ($enabled in $states) {
        $plan.Add([ordered]@{
            ordinal = $plan.Count + 1
            sourceOrdinal = $sourceOrdinal
            leg = if ($entry.qualityModeValue -eq 0) { 'native-aa' } elseif ($enabled) { 'on' } else { 'off' }
            waitBeforeApplyMs = 5000
            target = [ordered]@{
                method = $entry.method
                qualityMode = $entry.qualityMode
                renderScaleMode = $enabled
                dlssProfile = 'K'
                fsrRuntime = $FsrRuntime
            }
            qualityModeValue = $entry.qualityModeValue
        })
    }
}
[ordered]@{
    schema = 'csx-simple-csm-rs-plan-v1'
    protocol = 'simple-csm-rs'
    protocolRevision = 5
    canonicalProtocolRevision = $protocol.protocolRevision
    canonicalSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($raw))
    adapter = $Adapter.ToLowerInvariant()
    transitionCount = $plan.Count
    pacingMs = 5000
    recoveryTimeoutMs = 30000
    transitions = $plan.ToArray()
} | ConvertTo-Json -Depth 10
