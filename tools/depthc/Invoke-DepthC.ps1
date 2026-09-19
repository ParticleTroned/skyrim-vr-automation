#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SaveNumberText,
    [string]$RunDirectory,
    [string]$Controller = (Join-Path $PSScriptRoot '../devbench-control/Invoke-DevBenchControl.ps1'),
    [Parameter(Mandatory)][string]$FpsVrCmd,
    [ValidateRange(1, 65535)][int]$DevBenchPort = 8921,
    [string]$WprPath,
    [string]$RecorderValidationPath = (Join-Path $PSScriptRoot '../../build/gameft-sw/recorder-validation.json'),
    [Parameter(Mandatory)][string]$ArchiveDirectory
)
$ErrorActionPreference = 'Stop'
# Share recorder and calculations; the live variant supplies explicit settled-phase anchors.
& (Join-Path $PSScriptRoot '../gameft-sw/Invoke-GameFtStackWait.ps1') @PSBoundParameters -DepthC
