function Test-ApiOperationInventory {
    <#
    .SYNOPSIS
        Tests parsed API inventory rows against an exported command set.

    .DESCRIPTION
        Reports missing, unexpected, duplicate, and incomplete operation rows.
        Consumers remain responsible for parsing their Markdown or data-file
        inventory into objects.

    .PARAMETER CommandName
        Public command names that must each have exactly one inventory row.

    .PARAMETER InventoryRow
        Parsed inventory rows.

    .PARAMETER CommandProperty
        Property containing the public command name.

    .PARAMETER RequiredProperty
        Row properties that must exist and contain a non-empty value.

    .PARAMETER AllowUnexpectedCommand
        Permits inventory rows for commands outside CommandName.

    .PARAMETER ThrowOnFailure
        Throws a redacted summary when the inventory is not conformant.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String[]]$CommandName,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Object[]]$InventoryRow,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [String]$CommandProperty = 'Command',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [String[]]$RequiredProperty = @('Command'),

        [Parameter()]
        [Switch]$AllowUnexpectedCommand,

        [Parameter()]
        [Switch]$ThrowOnFailure
    )

    $requiredProperties = @($RequiredProperty + $CommandProperty | Sort-Object -Unique)
    $normalizedCommands = @($CommandName | Sort-Object -Unique)
    $rowCommands = [Collections.Generic.List[String]]::new()
    $invalidRows = [Collections.Generic.List[Object]]::new()

    for ($index = 0; $index -lt $InventoryRow.Count; $index++) {
        $row = $InventoryRow[$index]
        foreach ($propertyName in $requiredProperties) {
            $value = Get-ApiQualityValue -InputObject $row -Name $propertyName
            $hasValue = if ($value -is [String]) {
                -not [String]::IsNullOrWhiteSpace($value)
            }
            elseif ($value -is [Collections.IEnumerable]) {
                @($value).Count -gt 0
            }
            else {
                $null -ne $value
            }

            if (-not $hasValue) {
                $invalidRows.Add([PSCustomObject]@{
                        Row      = $index + 1
                        Property = $propertyName
                        Reason   = 'MissingOrEmpty'
                    })
            }
        }

        $command = [String](Get-ApiQualityValue -InputObject $row -Name $CommandProperty)
        if (-not [String]::IsNullOrWhiteSpace($command)) {
            $rowCommands.Add($command)
        }
    }

    $missingCommands = @(
        $normalizedCommands |
            Where-Object { $_ -notin $rowCommands } |
            Sort-Object
    )
    $unexpectedCommands = if ($AllowUnexpectedCommand.IsPresent) {
        @()
    }
    else {
        @(
            $rowCommands |
                Where-Object { $_ -notin $normalizedCommands } |
                Sort-Object -Unique
        )
    }
    $duplicateCommands = @(
        $rowCommands |
            Group-Object |
            Where-Object { $_.Count -gt 1 } |
            Select-Object -ExpandProperty Name |
            Sort-Object
    )
    $isConformant = (
        $missingCommands.Count -eq 0 -and
        $unexpectedCommands.Count -eq 0 -and
        $duplicateCommands.Count -eq 0 -and
        $invalidRows.Count -eq 0
    )

    $result = [PSCustomObject][Ordered]@{
        SchemaVersion      = '1.0'
        IsConformant       = $isConformant
        CommandCount       = $normalizedCommands.Count
        InventoryRowCount  = $InventoryRow.Count
        MissingCommands    = $missingCommands
        UnexpectedCommands = $unexpectedCommands
        DuplicateCommands  = $duplicateCommands
        InvalidRows        = @($invalidRows)
    }

    if ($ThrowOnFailure.IsPresent -and -not $isConformant) {
        throw (
            'API operation inventory is not conformant. Missing: [{0}]; unexpected: [{1}]; duplicates: [{2}]; invalid fields: {3}.' -f
            ($missingCommands -join ', '),
            ($unexpectedCommands -join ', '),
            ($duplicateCommands -join ', '),
            $invalidRows.Count
        )
    }

    return $result
}
