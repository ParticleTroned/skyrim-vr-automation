#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-HotspotPinnedFunctions {
    param([string]$Path, [string[]]$Names)
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Cannot parse pinned helper source: $Path" }
    $definitions = foreach ($name in $Names) {
        $found = @($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name}.GetNewClosure(), $false))
        if ($found.Count -ne 1) { throw "Expected exactly one helper '$name' in $Path" }
        $found[0].Extent.Text
    }
    return [scriptblock]::Create($definitions -join [Environment]::NewLine)
}

function Save-HotspotArtifact {
    param([string]$Source, [string]$ArchiveDirectory, [string]$Tag = 'hotspot-sw-UNVERIFIED')
    $before = Get-Item -LiteralPath $Source -ErrorAction Stop
    $length = $before.Length
    $hash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
    [void][IO.Directory]::CreateDirectory($ArchiveDirectory)
    $name = '{0}__{1}__{2}__{3}' -f $Tag, [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), [guid]::NewGuid().ToString('N').Substring(0,8), $before.Name
    $destination = Join-Path $ArchiveDirectory $name
    [IO.File]::Copy($before.FullName, $destination, $false)
    if ((Get-Item -LiteralPath $Source).Length -ne $length -or
        (Get-FileHash -LiteralPath $Source).Hash -ne $hash -or
        (Get-Item -LiteralPath $destination).Length -ne $length -or
        (Get-FileHash -LiteralPath $destination).Hash -ne $hash) {
        throw "Artifact changed during preservation; retain but do not analyze $destination"
    }
    return [ordered]@{source=$before.FullName; archivePath=$destination; byteLength=$length; sha256=$hash}
}

function Assert-HotspotFrustum {
    param($Status)
    $native = $Status.nativeFrustum
    if ($native.schemaVersion -ne 2 -or !$native.installed -or !$native.active -or !$native.enabled) {
        throw 'Perf build must expose active nativeFrustum schema 2. Enable diagnostic collection before starting.'
    }
    if ($native.depthJobs.schemaVersion -ne 1 -or !$native.depthJobs.installed) {
        throw 'Verified depth-job telemetry schema 1 is required.'
    }
    if ($native.collectionGeneration -ne $native.collectionGenerationAtEnd) {
        throw 'Frustum collection changed during this snapshot.'
    }
}

Export-ModuleMember -Function Get-HotspotPinnedFunctions, Save-HotspotArtifact, Assert-HotspotFrustum
