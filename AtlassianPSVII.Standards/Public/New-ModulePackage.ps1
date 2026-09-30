function New-ModulePackage {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String]$BuildOutputPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String]$ModuleName,

        [Parameter()]
        [String]$DestinationPath
    )

    $sourcePath = Join-Path -Path $BuildOutputPath -ChildPath $ModuleName
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
        throw "Missing files to package at '$sourcePath'."
    }

    if (-not $DestinationPath) {
        $DestinationPath = Join-Path -Path $BuildOutputPath -ChildPath "$ModuleName.zip"
    }

    if ($PSCmdlet.ShouldProcess($DestinationPath, "Create package from '$sourcePath'")) {
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem

        Remove-Item -LiteralPath $DestinationPath -ErrorAction SilentlyContinue
        $destinationDirectory = Split-Path -Path $DestinationPath -Parent
        if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
            $null = New-Item -Path $destinationDirectory -ItemType Directory -Force
        }

        $archiveStream = [IO.File]::Open(
            $DestinationPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
        try {
            $archive = [IO.Compression.ZipArchive]::new(
                $archiveStream,
                [IO.Compression.ZipArchiveMode]::Create,
                $false
            )
            try {
                $resolvedSourcePath = (Resolve-Path -LiteralPath $sourcePath).ProviderPath
                $sourcePrefix = $resolvedSourcePath.TrimEnd(
                    [IO.Path]::DirectorySeparatorChar,
                    [IO.Path]::AltDirectorySeparatorChar
                ) + [IO.Path]::DirectorySeparatorChar
                $files = @(
                    Get-ChildItem -LiteralPath $resolvedSourcePath -File -Recurse |
                        Sort-Object { $_.FullName.Substring($sourcePrefix.Length).Replace('\', '/') }
                )
                foreach ($file in $files) {
                    $relativePath = $file.FullName.Substring($sourcePrefix.Length).Replace('\', '/')
                    $entryName = '{0}/{1}' -f $ModuleName, $relativePath
                    $entry = $archive.CreateEntry(
                        $entryName,
                        [IO.Compression.CompressionLevel]::Optimal
                    )
                    $entry.LastWriteTime = [DateTimeOffset]'1980-01-01T00:00:00Z'

                    $inputStream = [IO.File]::OpenRead($file.FullName)
                    $entryStream = $entry.Open()
                    try {
                        $inputStream.CopyTo($entryStream)
                    }
                    finally {
                        $entryStream.Dispose()
                        $inputStream.Dispose()
                    }
                }
            }
            finally {
                $archive.Dispose()
            }
        }
        finally {
            $archiveStream.Dispose()
        }
    }

    return $DestinationPath
}
