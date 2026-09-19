#Requires -Version 7.0
param([Parameter(Mandatory)][string]$RunDirectory)
$ErrorActionPreference = 'Stop'
$plan = @(Get-Content -LiteralPath (Join-Path $RunDirectory 'frustrum-plan.json') -Raw | ConvertFrom-Json)
$summary = @(Get-Content -LiteralPath (Join-Path $RunDirectory 'quick-summary.json') -Raw | ConvertFrom-Json)
$markers = @(Get-Content -LiteralPath (Join-Path $RunDirectory 'markers.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
$policy = @($markers | Where-Object label -EQ 'frustrum-policy')
$toggleLabel = if ($policy.Count -eq 1 -and $policy[0].detail.depthJobBackoff -eq $true) { 'Depth-job backoff' } else { 'Fast path' }
$off = @(); $on = @(); $labels = @(); $paired = @()
foreach ($group in @($plan | Group-Object pairIndex)) {
    $legs = @($group.Group | Sort-Object ordinal)
    if ($legs.Count -ne 2 -or $legs[0].enabled -cne $false -or $legs[1].enabled -cne $true -or $legs[0].saveNumber -cne $legs[1].saveNumber) {
        throw 'Invalid OFF/ON pair plan; no comparison produced.'
    }
    $rows = @()
    foreach ($leg in $legs) {
        $key = "save-$($leg.ordinal)"
        $found = @($summary | Where-Object save -EQ $key)
        $ended = @($markers | Where-Object label -EQ "$key-hold-end")
        $stopped = @($markers | Where-Object label -EQ "$key-health-recorder-stopped")
        $verified = @($markers | Where-Object label -EQ "$key-frustrum-verified")
        $row = if ($found.Count -eq 1 -and $ended.Count -eq 1 -and $stopped.Count -eq 1 -and $verified.Count -eq 1) { $found[0] } else { $null }
        $paired += [pscustomobject]@{ pairIndex=$leg.pairIndex; saveNumber=$leg.saveNumber; mode=$leg.mode; ordinal=$leg.ordinal; complete=($null -ne $row); result=$row }
        $rows += $row
    }
    if ($null -eq $rows[0] -or $null -eq $rows[1]) {
        Write-Output "Save $($legs[0].saveNumber), pair $($group.Name): incomplete OFF/ON pair; available rows retained in quick-summary.json."
        continue
    }
    if ($rows[0].name -cne $rows[1].name) { throw 'OFF/ON rows reference different saves.' }
    $off += $rows[0]; $on += $rows[1]; $labels += $legs[0].saveNumber
}
$paired | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $RunDirectory 'frustrum-summary.json')
if (!$off.Count) { Write-Output 'No complete OFF/ON pair available.'; return }
$offPath = Join-Path $RunDirectory 'frustrum-off.json'
$onPath = Join-Path $RunDirectory 'frustrum-on.json'
ConvertTo-Json -InputObject $off -Depth 20 | Set-Content -LiteralPath $offPath
ConvertTo-Json -InputObject $on -Depth 20 | Set-Content -LiteralPath $onPath
$table = & (Join-Path $PSScriptRoot '../gameft-sw/protocol/Compare-GameFtRuns.ps1') -BaselineSummary $offPath -ComparisonSummaries $onPath -BaselineLabel "$toggleLabel OFF" -ComparisonLabels "$toggleLabel ON" -SaveLabels $labels
$table | Set-Content -LiteralPath (Join-Path $RunDirectory 'frustrum-comparison.md')
$table
