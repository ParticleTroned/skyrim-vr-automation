# SPDX-License-Identifier: GPL-3.0-or-later

Set-StrictMode -Version Latest

function Copy-CaptureInteractionValue($Value) {
    if ($null -eq $Value) { return $null }
    return ($Value | ConvertTo-Json -Depth 80 -Compress | ConvertFrom-Json -Depth 80)
}

function Get-CaptureInteractionActionCatalog {
    [CmdletBinding()]
    param([string]$Path = (Join-Path $PSScriptRoot 'actions.v1.json'))
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Action catalog does not exist: $Path" }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 30
}

function Get-CaptureInteractionProperty($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $Default
}

function New-CaptureInteractionBurstPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RegionsJson,
        [Parameter(Mandatory)][ValidateRange(1, 240)][int]$FrameCount,
        [ValidateRange(1, 536870912)][long]$MaximumBytes = 536870912,
        [ValidateRange(0, 216000)][int]$StartDelayFrames = 0
    )
    if ([long]$StartDelayFrames + $FrameCount - 1 -gt 216000) { throw 'Burst delay and frame count exceed the native sequence frame span.' }
    try { $regions = ConvertFrom-Json -InputObject $RegionsJson -AsHashtable -NoEnumerate -Depth 20 -ErrorAction Stop }
    catch { throw "BurstRegionsJson is invalid JSON: $($_.Exception.Message)" }
    if ($regions -isnot [array] -or $regions.Count -lt 1 -or $regions.Count -gt 8) { throw 'BurstRegionsJson must be an array of one to eight regions.' }
    $width = 0L
    $height = 0L
    foreach ($region in $regions) {
        if ($region -isnot [Collections.IDictionary] -or $region.Count -ne 4) { throw 'Each burst region requires exactly x, y, width and height.' }
        foreach ($key in @('x', 'y', 'width', 'height')) {
            $number = $region[$key]
            $minimum = if ($key -in @('x', 'y')) { 0 } else { 1 }
            $maximum = if ($key -in @('x', 'y')) { 16383 } else { 16384 }
            if (($number -isnot [int] -and $number -isnot [long]) -or $number -lt $minimum -or $number -gt $maximum) { throw "Burst region $key must be an integer within $minimum..$maximum." }
        }
        if (($width -ne 0 -and $region.width -ne $width) -or $region.x + $region.width -gt 16384 -or
            $region.y + $region.height -gt 16384 -or $height + $region.height -gt 16384) {
            throw 'Burst regions must have equal widths and fit native texture and atlas bounds.'
        }
        $width = [long]$region.width
        $height += [long]$region.height
    }
    $frameBytes = $width * $height * 8L
    $payloadBytes = $frameBytes * $FrameCount
    if ($frameBytes -gt 134217728 -or $payloadBytes -gt $MaximumBytes) { throw 'Burst exceeds the raw stereo payload budget; reduce regions or MaximumFrames.' }
    return [pscustomobject][ordered]@{
        descriptor = [ordered]@{ regions = $regions; maximumBytes = $MaximumBytes }
        frameCount = $FrameCount; startDelayFrames = $StartDelayFrames
        atlasWidth = $width * 2; atlasHeight = $height; rawPayloadBytes = $payloadBytes
    }
}

function Get-CaptureInteractionBurstEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Receipt, [Parameter(Mandatory)]$Plan)
    $terminal = [string](Get-CaptureInteractionProperty $Receipt 'state') -in @('completed','completed_with_warnings','stopped','cancelled','cancelled_partial','failed','failed_partial','rejected')
    $continuity = Get-CaptureInteractionProperty $Receipt 'continuity'
    $observed = Get-CaptureInteractionProperty $Receipt 'observedManifest'
    $document = Get-CaptureInteractionProperty $observed 'document'
    $manifestContinuity = Get-CaptureInteractionProperty $document 'continuity'
    $manifest = Get-CaptureInteractionProperty $Receipt 'manifest'
    $manifestPublished = -not [string]::IsNullOrWhiteSpace([string](Get-CaptureInteractionProperty $manifest 'finalPath')) -and
        [string](Get-CaptureInteractionProperty $manifest 'finalPath') -eq [string](Get-CaptureInteractionProperty $observed 'path')
    $errors = [Collections.Generic.List[string]]::new()
    $count = [int]$Plan.frameCount
    if ($terminal) {
        if ([string]$Receipt.state -notin @('completed','completed_with_warnings')) { $errors.Add('Burst acquisition did not complete normally.') }
        if (-not $manifestPublished) { $errors.Add('Burst final manifest publication is not verified.') }
        foreach ($entry in @(@{name='receipt';value=$continuity}, @{name='manifest';value=$manifestContinuity})) {
            $value = $entry.value
            $complete = Get-CaptureInteractionProperty $value 'complete'
            $acquired = Get-CaptureInteractionProperty $value 'acquired'
            $requested = Get-CaptureInteractionProperty $value 'requested'
            $first = Get-CaptureInteractionProperty $value 'firstEngineFrame'
            $last = Get-CaptureInteractionProperty $value 'lastEngineFrame'
            if ($complete -isnot [bool] -or -not $complete -or
                ($acquired -isnot [int] -and $acquired -isnot [long]) -or ($requested -isnot [int] -and $requested -isnot [long]) -or
                $acquired -ne $count -or $requested -ne $count -or
                ($first -isnot [int] -and $first -isnot [long]) -or ($last -isnot [int] -and $last -isnot [long]) -or
                $first -lt 0 -or $last -lt $first -or $last - $first -ne $count - 1 -or
                -not [string]::IsNullOrEmpty([string](Get-CaptureInteractionProperty $value 'failure'))) {
                $errors.Add("Burst $($entry.name) continuity is incomplete or inconsistent.")
            }
        }
        foreach ($field in @('firstEngineFrame','lastEngineFrame','acquired','requested')) {
            if ((Get-CaptureInteractionProperty $continuity $field) -ne (Get-CaptureInteractionProperty $manifestContinuity $field)) { $errors.Add("Burst manifest and receipt disagree on $field.") }
        }
        $children = @(Get-CaptureInteractionProperty $document 'children' @())
        if ($children.Count -ne $count) { $errors.Add('Burst manifest does not contain every requested frame.') }
        $ordinals = [Collections.Generic.HashSet[long]]::new()
        foreach ($child in $children) {
            $ordinal = Get-CaptureInteractionProperty $child 'ordinal'
            $acquisition = Get-CaptureInteractionProperty (Get-CaptureInteractionProperty $child 'actual') 'acquisition'
            $engineFrame = Get-CaptureInteractionProperty $acquisition 'engineFrame'
            $artifacts = @(Get-CaptureInteractionProperty $child 'artifacts' @())
            if (($ordinal -isnot [int] -and $ordinal -isnot [long]) -or $ordinal -lt 1 -or $ordinal -gt $count -or -not $ordinals.Add([long]$ordinal) -or
                [string](Get-CaptureInteractionProperty $child 'state') -notin @('completed','completed_with_warnings') -or
                [string](Get-CaptureInteractionProperty $acquisition 'sourceKind') -ne 'hmd_submission' -or
                ($engineFrame -isnot [int] -and $engineFrame -isnot [long]) -or
                $engineFrame -ne (Get-CaptureInteractionProperty $continuity 'firstEngineFrame' 0) + $ordinal - 1 -or $artifacts.Count -ne 1) {
                $errors.Add('Burst manifest has an invalid native frame or ordinal.'); break
            }
            $artifact = $artifacts[0]
            $actual = Get-CaptureInteractionProperty $artifact 'actual'
            $committed = Get-CaptureInteractionProperty $artifact 'committed'
            if ($committed -isnot [bool] -or -not $committed -or
                (Get-CaptureInteractionProperty $actual 'view') -ne 'side_by_side' -or
                (Get-CaptureInteractionProperty $actual 'format') -ne 'png' -or
                (Get-CaptureInteractionProperty $actual 'colourContract') -ne 'sdr_srgb' -or
                (Get-CaptureInteractionProperty $actual 'width') -ne $Plan.atlasWidth -or
                (Get-CaptureInteractionProperty $actual 'height') -ne $Plan.atlasHeight) {
                $errors.Add('Burst manifest atlas layout or committed encoding is invalid.'); break
            }
        }
    }
    return [pscustomobject][ordered]@{
        terminal = $terminal; continuityVerified = $terminal -and $errors.Count -eq 0
        manifestPublished = $manifestPublished; continuity = $continuity; manifestContinuity = $manifestContinuity
        plan = $Plan; artifactFilesVerified = $false; errors = @($errors)
    }
}

function Set-CaptureInteractionControllerNeutral($Controller) {
    if (-not $Controller.PSObject.Properties['controller']) {
        $Controller | Add-Member -NotePropertyName controller -NotePropertyValue ([pscustomobject]@{})
    }
    $state = $Controller.controller
    $packet = [uint32](Get-CaptureInteractionProperty $state 'packetNumber' 0)
    foreach ($pair in @(@('packetNumber', [uint32]($packet + 1)), @('pressed', [uint64]0), @('touched', [uint64]0))) {
        if ($state.PSObject.Properties[$pair[0]]) { $state.($pair[0]) = $pair[1] } else { $state | Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1] }
    }
    $axes = @(@(0.0, 0.0), @(0.0, 0.0), @(0.0, 0.0), @(0.0, 0.0), @(0.0, 0.0))
    if ($state.PSObject.Properties['axes']) { $state.axes = $axes } else { $state | Add-Member -NotePropertyName axes -NotePropertyValue $axes }
}

function New-CaptureInteractionFrames {
    [CmdletBinding()]
    param(
        $ObservedFrame,
        [Parameter(Mandatory)][string]$ActionName,
        $ActionArguments = ([pscustomobject]@{}),
        [string]$CatalogPath = (Join-Path $PSScriptRoot 'actions.v1.json')
    )
    $catalog = Get-CaptureInteractionActionCatalog -Path $CatalogPath
    $matches = @($catalog.actions | Where-Object name -eq $ActionName)
    if ($matches.Count -ne 1) { throw "Unknown or ambiguous named action '$ActionName'." }
    $action = $matches[0]
    $values = [ordered]@{}
    foreach ($property in @($action.defaults.PSObject.Properties)) { $values[$property.Name] = $property.Value }
    foreach ($property in @($ActionArguments.PSObject.Properties)) { $values[$property.Name] = $property.Value }
    foreach ($required in @(Get-CaptureInteractionProperty $action 'required' @())) {
        if (-not $values.Contains([string]$required)) { throw "Action '$ActionName' requires '$required'." }
    }

    $holdValue = if ($values.Contains('holdMs')) { $values.holdMs } else { 50 }
    $holdMs = [int]$holdValue
    if ([string]$action.kind -eq 'keyboard') {
        if ($holdMs -lt 10 -or $holdMs -gt 5000) { throw 'Keyboard holdMs must be between 10 and 5000.' }
        return [pscustomobject][ordered]@{
            device = 'keyboard'; arguments = [pscustomobject][ordered]@{
                action = 'tap'; device = 'keyboard'; key = [string]$values.key; durationMs = $holdMs
            }
        }
    }
    if ($holdMs -lt 10 -or $holdMs -gt 10000) { throw 'holdMs must be between 10 and 10000.' }
    if ($null -eq $ObservedFrame) { throw "Action '$ActionName' requires an observed tracked set." }
    $neutral = Copy-CaptureInteractionValue $ObservedFrame
    foreach ($role in @('left', 'right')) {
        if (-not $neutral.PSObject.Properties[$role]) { throw "Observed tracked set is missing '$role'." }
        Set-CaptureInteractionControllerNeutral $neutral.$role
    }
    foreach ($required in @('hmd', 'left', 'right')) {
        if (-not $neutral.PSObject.Properties[$required]) { throw "Observed tracked set is missing '$required'." }
    }
    $neutral | Add-Member -NotePropertyName tMs -NotePropertyValue 0 -Force
    $neutral | Add-Member -NotePropertyName seq -NotePropertyValue ([uint64]1) -Force

    if ([string]$action.kind -eq 'tracked-set') { return @($neutral) }

    $active = Copy-CaptureInteractionValue $neutral
    $release = Copy-CaptureInteractionValue $neutral
    $active.tMs = 10
    $active.seq = [uint64]2
    $release.tMs = 10 + $holdMs
    $release.seq = [uint64]3
    foreach ($role in @('left', 'right')) {
        $basePacket = [uint32]$neutral.$role.controller.packetNumber
        $active.$role.controller.packetNumber = [uint32]($basePacket + 1)
        $release.$role.controller.packetNumber = [uint32]($basePacket + 2)
    }
    $controller = [string]$values.controller
    if ($controller -notin @('left', 'right')) { throw "Action '$ActionName' controller must be left or right." }
    if ([string]$action.kind -eq 'button-pulse') {
        $mask = [uint64]$values.buttonMask
        $active.$controller.controller.pressed = $mask
        $active.$controller.controller.touched = $mask
    }
    elseif ([string]$action.kind -eq 'axis-pulse') {
        $axis = [int]$values.axis
        $x = [double]$values.x
        $y = [double]$values.y
        if ($axis -lt 0 -or $axis -gt 4) { throw 'axis must be between 0 and 4.' }
        if ($x -lt -1 -or $x -gt 1 -or $y -lt -1 -or $y -gt 1) { throw 'axis x/y must be within [-1,1].' }
        $axes = @($active.$controller.controller.axes)
        $axes[$axis] = @($x, $y)
        $active.$controller.controller.axes = $axes
    }
    else { throw "Action kind '$($action.kind)' is not implemented." }
    return @($neutral, $active, $release)
}

function Find-CaptureInteractionScreenshotReceipt {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Value, [string]$RequestId)
    $found = [Collections.Generic.List[object]]::new()
    function Visit($Current) {
        if ($null -eq $Current -or $Current -is [string] -or $Current -is [ValueType]) { return }
        $requestId = $Current.PSObject.Properties['requestId']
        $state = $Current.PSObject.Properties['state']
        if ($requestId -and $state) { $found.Add($Current) }
        if ($Current -is [Collections.IDictionary]) { foreach ($entry in $Current.GetEnumerator()) { Visit $entry.Value }; return }
        if ($Current -is [Collections.IEnumerable] -and $Current -isnot [pscustomobject]) { foreach ($entry in $Current) { Visit $entry }; return }
        foreach ($property in @($Current.PSObject.Properties)) { Visit $property.Value }
    }
    Visit $Value
    if ($RequestId) { return @($found | Where-Object requestId -eq $RequestId | Select-Object -First 1) }
    return @($found | Select-Object -First 1)
}

function Get-CaptureInteractionLatestFrame {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Receipt,
        [ValidateSet('left_eye', 'right_eye', 'side_by_side', 'framed_combined', 'source_native')]
        [string]$PreferredView = 'left_eye'
    )
    $items = [Collections.Generic.List[object]]::new()
    $observedManifest = Get-CaptureInteractionProperty $Receipt 'observedManifest'
    $observedManifestPath = Get-CaptureInteractionProperty $observedManifest 'path'
    $manifestDirectory = if ($observedManifestPath) { [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath([string]$observedManifestPath)) } else { $null }
    function VisitArtifact($Current) {
        if ($null -eq $Current -or $Current -is [string] -or $Current -is [ValueType]) { return }
        $acquisition = Get-CaptureInteractionProperty (Get-CaptureInteractionProperty $Current 'actual') 'acquisition'
        foreach ($artifact in @(Get-CaptureInteractionProperty $Current 'artifacts' @())) {
            if ([bool](Get-CaptureInteractionProperty $artifact 'committed' $false)) {
                $artifactPath = [string](Get-CaptureInteractionProperty $artifact 'path')
                $manifest = Get-CaptureInteractionProperty $Current 'manifest'
                $declaredManifestPaths = @((Get-CaptureInteractionProperty $manifest 'finalPath'), (Get-CaptureInteractionProperty $manifest 'partialPath'))
                if ((Get-CaptureInteractionProperty $Current 'kind') -eq 'sequence' -and
                    -not [string]::IsNullOrWhiteSpace($artifactPath) -and $artifactPath -in $declaredManifestPaths) {
                    continue
                }
                $actual = Get-CaptureInteractionProperty $artifact 'actual'
                if ([string](Get-CaptureInteractionProperty $acquisition 'sourceKind') -ne 'hmd_submission') {
                    throw 'Committed screenshot artifact lacks an actual hmd_submission acquisition.'
                }
                if ([string](Get-CaptureInteractionProperty $actual 'format') -ne 'png' -or
                    [string](Get-CaptureInteractionProperty $actual 'colourContract') -ne 'sdr_srgb') {
                    throw 'Committed screenshot artifact is not an actual sdr_srgb PNG.'
                }
                if ($manifestDirectory) {
                    if (-not [IO.Path]::IsPathRooted($artifactPath)) { $artifactPath = Join-Path $manifestDirectory $artifactPath }
                    $artifactPath = [IO.Path]::GetFullPath($artifactPath)
                    $artifactRoot = $manifestDirectory.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
                    if (-not $artifactPath.StartsWith($artifactRoot, [StringComparison]::OrdinalIgnoreCase)) {
                        throw 'Screenshot artifact escaped the observed manifest directory.'
                    }
                }
                $items.Add([pscustomobject][ordered]@{
                    path = $artifactPath
                    view = [string](Get-CaptureInteractionProperty $actual 'view' '')
                    format = [string]$actual.format
                    colourContract = [string]$actual.colourContract
                    width = Get-CaptureInteractionProperty $actual 'width'
                    height = Get-CaptureInteractionProperty $actual 'height'
                    sha256 = Get-CaptureInteractionProperty $artifact 'sha256'
                    bytes = Get-CaptureInteractionProperty $artifact 'bytes'
                    requestId = Get-CaptureInteractionProperty $Current 'requestId'
                    ordinal = Get-CaptureInteractionProperty $Current 'ordinal' -1
                    engineFrame = Get-CaptureInteractionProperty $acquisition 'engineFrame' -1
                    scheduledEngineFrame = Get-CaptureInteractionProperty $Current 'scheduledEngineFrame' -1
                    acquisition = $acquisition
                    committed = $true
                })
            }
        }
        foreach ($child in @(Get-CaptureInteractionProperty $Current 'children' @())) { VisitArtifact $child }
    }
    VisitArtifact $Receipt
    $ranked = @($items | Sort-Object @{ Expression = 'ordinal'; Descending = $true }, @{ Expression = 'engineFrame'; Descending = $true }, @{ Expression = { if ($_.view -eq $PreferredView) { 1 } else { 0 } }; Descending = $true })
    if ($ranked.Count -eq 0) { return $null }
    return $ranked[0]
}

function ConvertTo-CaptureInteractionUtcBoundary {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Value)
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    $parsed = [DateTimeOffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture, $styles)
    return $parsed.ToUniversalTime()
}

function Resolve-CaptureInteractionOwnedPath([string]$Root, [string]$Path) {
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not $resolved.StartsWith($rootPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Viewing artifact path escaped the owned capture directory.'
    }
    for ($cursor = $resolved; $cursor; $cursor = [IO.Path]::GetDirectoryName($cursor)) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Viewing artifact paths must not traverse reparse points.'
            }
        }
    }
    return $resolved
}

function New-CaptureInteractionFrameSubmission {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$LatestFrame,
        [Parameter(Mandatory)][string]$SessionDirectory,
        [Parameter(Mandatory)][string]$FramesDirectory,
        [Parameter(Mandatory)][string]$ObservationId,
        [ValidateRange(1, 4194304)][int]$MaximumBytes = 4194304
    )

    if (-not (Get-CaptureInteractionProperty $LatestFrame 'committed' $false) -or
        (Get-CaptureInteractionProperty $LatestFrame 'format') -ne 'png' -or
        (Get-CaptureInteractionProperty $LatestFrame 'colourContract') -ne 'sdr_srgb' -or
        (Get-CaptureInteractionProperty (Get-CaptureInteractionProperty $LatestFrame 'acquisition') 'sourceKind') -ne 'hmd_submission') {
        throw 'Viewing submission requires a committed SDR PNG with verified HMD acquisition.'
    }
    $framesRoot = Resolve-CaptureInteractionOwnedPath $SessionDirectory $FramesDirectory
    $sourcePath = Resolve-CaptureInteractionOwnedPath $framesRoot ([string]$LatestFrame.path)
    $viewRoot = Resolve-CaptureInteractionOwnedPath $SessionDirectory (Join-Path $SessionDirectory 'viewing')
    $source = [IO.File]::Open($sourcePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $decoded = $null
    try {
        if ($source.Length -lt 24 -or $source.Length -gt 134217728 -or $source.Length -ne $LatestFrame.bytes) {
            throw 'Original PNG byte length is invalid, exceeds 128 MiB, or differs from its capture receipt.'
        }
        $sourceHash = (Get-FileHash -InputStream $source -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($sourceHash -ne [string]$LatestFrame.sha256) { throw 'Original PNG SHA-256 differs from its capture receipt.' }
        $source.Position = 0
        $header = [byte[]]::new(24)
        $source.ReadExactly($header, 0, $header.Length)
        if ([Convert]::ToHexString($header[0..7]) -ne '89504E470D0A1A0A' -or [Text.Encoding]::ASCII.GetString($header, 12, 4) -ne 'IHDR') {
            throw 'Original capture is not a PNG image.'
        }
        $widthBytes = [byte[]]$header[16..19]; [Array]::Reverse($widthBytes)
        $heightBytes = [byte[]]$header[20..23]; [Array]::Reverse($heightBytes)
        $width = [BitConverter]::ToUInt32($widthBytes, 0)
        $height = [BitConverter]::ToUInt32($heightBytes, 0)
        if ($width -lt 1 -or $height -lt 1 -or $width -gt 16384 -or $height -gt 16384 -or
            [long]$width * $height -gt 67108864 -or $width -ne $LatestFrame.width -or $height -ne $LatestFrame.height) {
            throw 'Original PNG dimensions differ from the receipt or exceed the 16384-axis/64-megapixel decode bound.'
        }
        Add-Type -AssemblyName System.Drawing.Common
        $source.Position = 0
        $decoded = [Drawing.Image]::FromStream($source, $false, $true)
        if ($decoded.Width -ne $width -or $decoded.Height -ne $height) { throw 'Decoded PNG dimensions differ from its header.' }
        $submissionPath = $sourcePath
        $submissionHash = $sourceHash
        $submissionBytes = $source.Length
        $mimeType = 'image/png'
        $quality = $null
        $attemptedQualities = [Collections.Generic.List[int]]::new()
        if ($source.Length -gt $MaximumBytes) {
            $encoder = @([Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object MimeType -eq 'image/jpeg')[0]
            $encodedBytes = $null
            foreach ($candidateQuality in @(95, 90, 85, 80, 70, 60, 50, 40, 30, 20, 10)) {
                $attemptedQualities.Add($candidateQuality)
                $buffer = [IO.MemoryStream]::new()
                $parameters = [Drawing.Imaging.EncoderParameters]::new(1)
                try {
                    $parameters.Param[0] = [Drawing.Imaging.EncoderParameter]::new([Drawing.Imaging.Encoder]::Quality, [long]$candidateQuality)
                    $decoded.Save($buffer, $encoder, $parameters)
                    if ($buffer.Length -le $MaximumBytes) {
                        $encodedBytes = $buffer.ToArray()
                        $quality = $candidateQuality
                        break
                    }
                }
                finally { $parameters.Dispose(); $buffer.Dispose() }
            }
            if ($null -eq $encodedBytes) {
                throw "No full-resolution viewing JPEG fits the $MaximumBytes-byte limit at qualities 95 through 10; original PNG remains intact."
            }
            $submissionHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($encodedBytes)).ToLowerInvariant()
            $submissionBytes = $encodedBytes.Length
            $mimeType = 'image/jpeg'
            New-Item -ItemType Directory -Path $viewRoot -Force | Out-Null
            $submissionPath = Resolve-CaptureInteractionOwnedPath $SessionDirectory (Join-Path $viewRoot "view-$sourceHash-q$quality.jpg")
            if (-not (Test-Path -LiteralPath $submissionPath)) {
                $temporary = Resolve-CaptureInteractionOwnedPath $SessionDirectory (Join-Path $viewRoot ('.view-' + [guid]::NewGuid().ToString('N') + '.tmp'))
                try {
                    $output = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                    try { $output.Write($encodedBytes, 0, $encodedBytes.Length); $output.Flush($true) }
                    finally { $output.Dispose() }
                    try { [IO.File]::Move($temporary, $submissionPath, $false) }
                    catch [IO.IOException] { if (-not [IO.File]::Exists($submissionPath)) { throw } }
                }
                finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
            }
            $written = Get-Item -LiteralPath $submissionPath
            if ($written.Length -ne $submissionBytes -or (Get-FileHash -LiteralPath $submissionPath -Algorithm SHA256).Hash -ne $submissionHash) {
                throw 'Existing viewing artifact conflicts with the deterministic encoding; no file was overwritten.'
            }
        }
        return [pscustomobject][ordered]@{
            kind = 'image-file'; path = $submissionPath; mimeType = $mimeType
            view = [string]$LatestFrame.view; observationId = $ObservationId
            ordinal = $LatestFrame.ordinal; engineFrame = $LatestFrame.engineFrame
            width = $width; height = $height; bytes = $submissionBytes; sha256 = $submissionHash
            maximumBytes = $MaximumBytes
            original = [pscustomobject][ordered]@{
                path = $sourcePath; mimeType = 'image/png'; sha256 = $sourceHash; bytes = $source.Length
                width = $width; height = $height; requestId = $LatestFrame.requestId
                acquisition = $LatestFrame.acquisition; colourContract = 'sdr_srgb'
            }
            viewing = [pscustomobject][ordered]@{
                derivative = $null -ne $quality; purpose = 'view_only'; lossy = $null -ne $quality
                fullResolution = $true; resized = $false; retouched = $false
                jpegQuality = $quality; attemptedQualities = @($attemptedQualities)
                encoding = if ($null -ne $quality) { 'System.Drawing JPEG; alpha omitted; no color-management transform' } else { 'original PNG bytes' }
            }
        }
    }
    finally { if ($decoded) { $decoded.Dispose() }; $source.Dispose() }
}

function Get-CaptureInteractionSaveCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][DateTimeOffset]$SinceUtc,
        [string]$NamePattern = '*'
    )
    $resolved = [IO.Path]::GetFullPath($Directory)
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) { throw "Save directory does not exist: $resolved" }
    $boundary = $SinceUtc.ToUniversalTime()
    return @(Get-ChildItem -LiteralPath $resolved -File -Filter '*.ess' | Where-Object {
        ([DateTimeOffset]$_.LastWriteTimeUtc) -gt $boundary -and $_.BaseName -like $NamePattern
    } | Sort-Object LastWriteTimeUtc | ForEach-Object {
        [pscustomobject][ordered]@{
            path = $_.FullName
            name = $_.Name
            baseName = $_.BaseName
            bytes = $_.Length
            lastWriteUtc = ([DateTimeOffset]$_.LastWriteTimeUtc).ToUniversalTime().ToString('o')
        }
    })
}

Export-ModuleMember -Function Get-CaptureInteractionActionCatalog, Get-CaptureInteractionProperty, New-CaptureInteractionFrames, Find-CaptureInteractionScreenshotReceipt, Get-CaptureInteractionLatestFrame, New-CaptureInteractionFrameSubmission, New-CaptureInteractionBurstPlan, Get-CaptureInteractionBurstEvidence, ConvertTo-CaptureInteractionUtcBoundary, Get-CaptureInteractionSaveCandidates
