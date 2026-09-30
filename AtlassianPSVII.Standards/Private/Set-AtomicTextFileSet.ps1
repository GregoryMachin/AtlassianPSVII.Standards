function Get-TextFileState {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file was not found: '$Path'."
    }

    $resolvedPath = (Resolve-Path -LiteralPath $Path).ProviderPath
    $bytes = [IO.File]::ReadAllBytes($resolvedPath)
    $hasBom = (
        $bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and
        $bytes[2] -eq 0xBF
    )
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    if ($text.Length -gt 0 -and $text[0] -eq [Char]0xFEFF) {
        $text = $text.Substring(1)
    }

    $newLine = if ($text -match "`r`n") {
        "`r`n"
    }
    elseif ($text -match "`n") {
        "`n"
    }
    else {
        [Environment]::NewLine
    }

    return [PSCustomObject]@{
        Path    = $resolvedPath
        Text    = $text
        HasBom  = $hasBom
        NewLine = $newLine
    }
}

function Set-AtomicTextFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'Called only after the exported transaction command has obtained ShouldProcess approval.'
    )]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [PSCustomObject]$File
    )

    [IO.File]::Replace($File.StagedPath, $File.DestinationPath, $File.BackupPath)
}

function Set-AtomicTextFileSet {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'Called only after the exported transaction command has obtained ShouldProcess approval.'
    )]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [Object[]]$Update
    )

    $transactionId = [Guid]::NewGuid().ToString('N')
    $stagedFiles = [Collections.Generic.List[Object]]::new()
    $committedFiles = [Collections.Generic.List[Object]]::new()

    try {
        foreach ($item in $Update) {
            $state = $item.State
            $normalizedText = [Text.RegularExpressions.Regex]::Replace(
                [String]$item.Text,
                '\r?\n',
                $state.NewLine
            )
            if (-not $normalizedText.EndsWith($state.NewLine)) {
                $normalizedText += $state.NewLine
            }

            $directory = Split-Path -Path $state.Path -Parent
            $leafName = Split-Path -Path $state.Path -Leaf
            $stagedPath = Join-Path -Path $directory -ChildPath ".$leafName.$transactionId.tmp"
            $backupPath = Join-Path -Path $directory -ChildPath ".$leafName.$transactionId.bak"
            $encoding = [Text.UTF8Encoding]::new([Boolean]$state.HasBom)
            [IO.File]::WriteAllText($stagedPath, $normalizedText, $encoding)

            $stagedState = Get-TextFileState -Path $stagedPath
            if ($stagedState.Text -ne $normalizedText) {
                throw "Staged dependency update validation failed for '$($state.Path)'."
            }

            $stagedFiles.Add([PSCustomObject]@{
                    DestinationPath = $state.Path
                    StagedPath      = $stagedPath
                    BackupPath      = $backupPath
                })
        }

        foreach ($stagedFile in $stagedFiles) {
            Set-AtomicTextFile -File $stagedFile
            $committedFiles.Add($stagedFile)
        }
    }
    catch {
        $originalErrorMessage = $_.Exception.Message
        $rollbackErrors = [Collections.Generic.List[String]]::new()
        for ($index = $committedFiles.Count - 1; $index -ge 0; $index--) {
            $committedFile = $committedFiles[$index]
            if (Test-Path -LiteralPath $committedFile.BackupPath -PathType Leaf) {
                $rollbackDiscardPath = "$($committedFile.DestinationPath).$transactionId.rollback"
                try {
                    [IO.File]::Replace(
                        $committedFile.BackupPath,
                        $committedFile.DestinationPath,
                        $rollbackDiscardPath
                    )
                }
                catch {
                    $rollbackErrors.Add(
                        "Failed to restore '$($committedFile.DestinationPath)': $($_.Exception.Message)"
                    )
                }
                finally {
                    if (Test-Path -LiteralPath $rollbackDiscardPath -PathType Leaf) {
                        [IO.File]::Delete($rollbackDiscardPath)
                    }
                }
            }
        }

        if ($rollbackErrors.Count -gt 0) {
            throw "Atomic dependency update failed and rollback was incomplete. Original error: $originalErrorMessage Rollback error: $($rollbackErrors -join '; ')"
        }

        throw "Atomic dependency update failed and completed files were rolled back. Original error: $originalErrorMessage"
    }
    finally {
        foreach ($stagedFile in $stagedFiles) {
            foreach ($temporaryPath in @($stagedFile.StagedPath, $stagedFile.BackupPath)) {
                if (
                    $temporaryPath -and
                    (Test-Path -LiteralPath $temporaryPath -PathType Leaf)
                ) {
                    [IO.File]::Delete($temporaryPath)
                }
            }
        }
    }
}
