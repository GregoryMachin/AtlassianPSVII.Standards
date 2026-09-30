function Test-ApiResponseHeader {
    <#
    .SYNOPSIS
        Asserts API response headers without exposing sensitive values.

    .DESCRIPTION
        Validates header syntax and expected values, returning only a redacted
        header view and safe diagnostics. Authorization, proxy authorization,
        cookies, API keys, token-like headers, and caller-configured names are
        always suppressed.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [Object]$Header,

        [Parameter()]
        [ValidateNotNull()]
        [Object]$ExpectedHeader = @{},

        [Parameter()]
        [String[]]$SensitiveHeader = @(),

        [Parameter()]
        [Switch]$ThrowOnFailure
    )

    $headerMap = @{}
    $redactedHeaders = [Ordered]@{}
    $malformedHeaders = [Collections.Generic.List[Object]]::new()
    $inputProperties = @(Get-ApiQualityHeaderEntry -Header $Header)

    foreach ($entry in $inputProperties) {
        $name = [String]$entry.Name
        $values = @($entry.Value | ForEach-Object { [String]$_ })
        if ($name -notmatch '^[!#$%&''*+\-.^_`|~0-9A-Za-z]+$') {
            $malformedHeaders.Add([PSCustomObject]@{
                    Name   = Protect-ApiQualityText -Text $name
                    Reason = 'InvalidName'
                })
            continue
        }
        if (@($values | Where-Object { $_ -match '[\r\n]' }).Count -gt 0) {
            $malformedHeaders.Add([PSCustomObject]@{
                    Name   = $name
                    Reason = 'InvalidValue'
                })
            continue
        }

        $headerMap[$name] = $values -join ', '
    }

    foreach ($name in @($headerMap.Keys | Sort-Object)) {
        $redactedHeaders[$name] = if (
            Test-SensitiveApiFieldName -Name $name -AdditionalSensitiveName $SensitiveHeader
        ) {
            '[REDACTED]'
        }
        else {
            $headerMap[$name]
        }
    }

    $expectedProperties = @(Get-ApiQualityHeaderEntry -Header $ExpectedHeader)
    $missingHeaders = [Collections.Generic.List[String]]::new()
    $mismatchedHeaders = [Collections.Generic.List[Object]]::new()
    foreach ($expected in $expectedProperties) {
        $name = [String]$expected.Name
        if (-not $headerMap.ContainsKey($name)) {
            $missingHeaders.Add($name)
            continue
        }

        $expectedValue = @($expected.Value | ForEach-Object { [String]$_ }) -join ', '
        if ($headerMap[$name] -cne $expectedValue) {
            $sensitive = Test-SensitiveApiFieldName `
                -Name $name `
                -AdditionalSensitiveName $SensitiveHeader
            $mismatchedHeaders.Add([PSCustomObject]@{
                    Name     = $name
                    Expected = if ($sensitive) { '[REDACTED]' } else { $expectedValue }
                    Actual   = if ($sensitive) { '[REDACTED]' } else { $headerMap[$name] }
                })
        }
    }

    $isMatch = (
        $malformedHeaders.Count -eq 0 -and
        $missingHeaders.Count -eq 0 -and
        $mismatchedHeaders.Count -eq 0
    )
    $result = [PSCustomObject][Ordered]@{
        SchemaVersion     = '1.0'
        IsMatch           = $isMatch
        RedactedHeaders   = $redactedHeaders
        MissingHeaders    = @($missingHeaders | Sort-Object)
        MismatchedHeaders = @($mismatchedHeaders | Sort-Object Name)
        MalformedHeaders  = @($malformedHeaders | Sort-Object Name)
    }

    if ($ThrowOnFailure.IsPresent -and -not $isMatch) {
        throw (
            'API response header assertion failed. Missing: [{0}]; mismatched: [{1}]; malformed: [{2}].' -f
            ($missingHeaders -join ', '),
            (@($mismatchedHeaders.Name) -join ', '),
            (@($malformedHeaders.Name) -join ', ')
        )
    }

    return $result
}
