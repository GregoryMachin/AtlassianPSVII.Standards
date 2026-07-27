function Get-ApiQualityValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [Object]$InputObject,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ([String]$key -ieq $Name) {
                return $InputObject[$key]
            }
        }

        return $null
    }

    $property = $InputObject.PSObject.Properties |
        Where-Object { $_.Name -ieq $Name } |
        Select-Object -First 1
    if ($property) {
        return $property.Value
    }

    return $null
}

function Test-SensitiveApiFieldName {
    [CmdletBinding()]
    [OutputType([Boolean])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String]$Name,

        [Parameter()]
        [String[]]$AdditionalSensitiveName = @()
    )

    if ($Name -match '(?i)(authorization|cookie|token|api[-_]?key|secret)') {
        return $true
    }

    return @($AdditionalSensitiveName | Where-Object { $_ -ieq $Name }).Count -gt 0
}

function Get-ApiQualityHeaderEntry {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [Object]$Header
    )

    if ($Header -is [Collections.IDictionary]) {
        foreach ($key in $Header.Keys) {
            [PSCustomObject]@{
                Name  = [String]$key
                Value = $Header[$key]
            }
        }

        return
    }

    if ($Header -is [Collections.Specialized.NameValueCollection]) {
        foreach ($key in $Header.AllKeys) {
            [PSCustomObject]@{
                Name  = [String]$key
                Value = $Header.GetValues($key)
            }
        }

        return
    }

    if ($Header -is [Collections.IEnumerable] -and $Header -isnot [String]) {
        $entries = @(
            foreach ($item in $Header) {
                $keyProperty = $item.PSObject.Properties |
                    Where-Object { $_.Name -ieq 'Key' } |
                    Select-Object -First 1
                $valueProperty = $item.PSObject.Properties |
                    Where-Object { $_.Name -ieq 'Value' } |
                    Select-Object -First 1
                if ($keyProperty -and $valueProperty) {
                    [PSCustomObject]@{
                        Name  = [String]$keyProperty.Value
                        Value = $valueProperty.Value
                    }
                }
            }
        )
        if ($entries.Count -gt 0) {
            $entries
            return
        }
    }

    $Header.PSObject.Properties | ForEach-Object {
        [PSCustomObject]@{
            Name  = $_.Name
            Value = $_.Value
        }
    }
}

function Protect-ApiQualityText {
    [CmdletBinding()]
    [OutputType([String])]
    param(
        [Parameter()]
        [AllowNull()]
        [String]$Text
    )

    if ([String]::IsNullOrEmpty($Text)) {
        return $Text
    }

    $protectedText = [Regex]::Replace(
        $Text,
        '(?im)\b(authorization|proxy-authorization|cookie|set-cookie)\s*[:=]\s*[^\r\n]+',
        '$1: [REDACTED]'
    )
    $protectedText = [Regex]::Replace(
        $protectedText,
        '(?im)\b(api[-_]?key|access[-_]?token|refresh[-_]?token|secret)\s*[:=]\s*[^\s,;]+',
        '$1=[REDACTED]'
    )

    return $protectedText
}

function ConvertTo-StableApiQualityData {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [Object]$InputObject,

        [Parameter()]
        [String[]]$AdditionalSensitiveName = @()
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [String]) {
        return Protect-ApiQualityText -Text $InputObject
    }

    if ($InputObject -is [Collections.IDictionary]) {
        $result = [Ordered]@{}
        foreach ($key in @($InputObject.Keys | ForEach-Object { [String]$_ } | Sort-Object)) {
            if (Test-SensitiveApiFieldName -Name $key -AdditionalSensitiveName $AdditionalSensitiveName) {
                $result[$key] = '[REDACTED]'
            }
            else {
                $result[$key] = ConvertTo-StableApiQualityData `
                    -InputObject (Get-ApiQualityValue -InputObject $InputObject -Name $key) `
                    -AdditionalSensitiveName $AdditionalSensitiveName
            }
        }

        return $result
    }

    if (
        $InputObject -is [Collections.IEnumerable] -and
        $InputObject -isnot [String]
    ) {
        return @(
            foreach ($item in $InputObject) {
                ConvertTo-StableApiQualityData `
                    -InputObject $item `
                    -AdditionalSensitiveName $AdditionalSensitiveName
            }
        )
    }

    if ($InputObject -is [PSCustomObject]) {
        $propertyMap = @{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $propertyMap[$property.Name] = $property.Value
        }

        return ConvertTo-StableApiQualityData `
            -InputObject $propertyMap `
            -AdditionalSensitiveName $AdditionalSensitiveName
    }

    return $InputObject
}
