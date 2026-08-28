# SPDX-License-Identifier: GPL-3.0-or-later

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$entry = Join-Path $PSScriptRoot 'Invoke-SteamVRHeadPoseControl.ps1'
$mapName = "Local\CSXVRHeadPose-test-$([guid]::NewGuid().ToString('N'))"
$mapping = $null
$view = $null
$passed = 0

function Assert-Test([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:passed++
}

try {
    $repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $bundleRoot = Join-Path $repositoryRoot 'drivers\codex_head_pose'
    $provenance = Get-Content -LiteralPath (Join-Path $bundleRoot 'build-provenance.json') -Raw | ConvertFrom-Json
    foreach ($artifact in $provenance.artifacts.psobject.Properties) {
        $artifactPath = Join-Path $bundleRoot $artifact.Name
        Assert-Test ((Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash -eq [string]$artifact.Value) "bundled artifact hash matches provenance: $($artifact.Name)"
    }
    Assert-Test (Test-Path -LiteralPath (Join-Path $bundleRoot 'licenses\OpenVR-LICENSE.txt') -PathType Leaf) 'bundled OpenVR runtime license is present'

    $mapping = [IO.MemoryMappedFiles.MemoryMappedFile]::CreateNew($mapName, 88)
    $view = $mapping.CreateViewAccessor(0, 88, [IO.MemoryMappedFiles.MemoryMappedFileAccess]::ReadWrite)
    $view.Write(0, [uint32]0x48505343)
    $view.Write(4, [uint16]1)
    $view.Write(6, [uint16]88)
    $view.Write(8, [uint64]2)
    $view.Write(16, [uint64]2)
    $view.Write(24, [uint32]1)
    $view.Write(28, [uint32]1)
    $view.Write(32, [double]0); $view.Write(40, [double]1.68); $view.Write(48, [double]0)
    $view.Write(56, [double]1); $view.Write(64, [double]0); $view.Write(72, [double]0); $view.Write(80, [double]0)
    $view.Flush()

    $inspect = & $entry inspect -MapName $mapName -Compact -NoExit | ConvertFrom-Json
    Assert-Test ($inspect.ok -and $inspect.state -eq 'provider-running' -and $inspect.data.pose.eyeHeightMeters -eq 1.68) 'inspect reads the versioned pose map'

    $qualify = & $entry qualify -MapName $mapName -SkipOpenVRProbe -Compact -NoExit | ConvertFrom-Json
    Assert-Test ($qualify.ok -and $qualify.state -eq 'head-pose-qualified') 'qualify accepts an acknowledged standing pose'

    $set = & $entry set -MapName $mapName -EyeHeightMeters 1.72 -YawDegrees 15 -NoWait -Compact -NoExit | ConvertFrom-Json
    Assert-Test ($set.ok -and $set.state -eq 'pose-submitted' -and ($view.ReadUInt64(8) % 2) -eq 0) 'set publishes an atomic even pose sequence'
    Assert-Test ([Math]::Abs($view.ReadDouble(40) - 1.72) -lt 0.000001) 'set writes the requested eye height'

    $view.Write(16, $view.ReadUInt64(8)); $view.Write(24, [uint32]1); $view.Flush()
    $requalified = & $entry qualify -MapName $mapName -SkipOpenVRProbe -Compact -NoExit | ConvertFrom-Json
    Assert-Test ($requalified.ok -and [Math]::Abs($requalified.data.pose.eyeHeightMeters - 1.72) -lt 0.000001) 'provider acknowledgement requalifies the updated pose'

    [pscustomobject]@{ ok = $true; passed = $passed } | ConvertTo-Json -Compress
}
finally {
    if ($view) { $view.Dispose() }
    if ($mapping) { $mapping.Dispose() }
}
