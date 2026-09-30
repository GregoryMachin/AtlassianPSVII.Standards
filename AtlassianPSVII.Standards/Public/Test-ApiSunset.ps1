function Test-ApiSunset {
    <#
    .SYNOPSIS
        Evaluates API sunset dates against warning and failure thresholds.

    .DESCRIPTION
        Produces deterministic per-operation status records. Expired, malformed,
        missing, or within-failure-threshold sunset dates make the result
        noncompliant.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [Object[]]$Operation,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [String]$NameProperty = 'Operation',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [String]$SunsetProperty = 'SunsetDate',

        [Parameter()]
        [ValidateRange(0, 36500)]
        [Int32]$FailureThresholdDays = 30,

        [Parameter()]
        [ValidateRange(0, 36500)]
        [Int32]$WarningThresholdDays = 90,

        [Parameter()]
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow,

        [Parameter()]
        [Switch]$ThrowOnFailure
    )

    if ($FailureThresholdDays -gt $WarningThresholdDays) {
        throw 'FailureThresholdDays cannot be greater than WarningThresholdDays.'
    }

    $nowUtc = $Now.ToUniversalTime()
    $results = [Collections.Generic.List[Object]]::new()
    foreach ($item in $Operation) {
        $name = [String](Get-ApiQualityValue -InputObject $item -Name $NameProperty)
        $sunsetValue = Get-ApiQualityValue -InputObject $item -Name $SunsetProperty
        $sunset = [DateTimeOffset]::MinValue
        $parsed = (
            $null -ne $sunsetValue -and
            [DateTimeOffset]::TryParse(
                [String]$sunsetValue,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AssumeUniversal -bor
                [Globalization.DateTimeStyles]::AdjustToUniversal,
                [Ref]$sunset
            )
        )

        if ([String]::IsNullOrWhiteSpace($name) -or -not $parsed) {
            $results.Add([PSCustomObject][Ordered]@{
                    Operation     = $name
                    SunsetUtc     = $null
                    DaysRemaining = $null
                    Status        = 'Invalid'
                })
            continue
        }

        $sunsetUtc = $sunset.ToUniversalTime()
        $daysRemaining = [Math]::Floor(($sunsetUtc - $nowUtc).TotalDays)
        $status = if ($sunsetUtc -le $nowUtc) {
            'Expired'
        }
        elseif ($daysRemaining -le $FailureThresholdDays) {
            'Failing'
        }
        elseif ($daysRemaining -le $WarningThresholdDays) {
            'Warning'
        }
        else {
            'Current'
        }
        $results.Add([PSCustomObject][Ordered]@{
                Operation     = $name
                SunsetUtc     = $sunsetUtc.ToString('o')
                DaysRemaining = [Int32]$daysRemaining
                Status        = $status
            })
    }

    $orderedResults = @($results | Sort-Object Operation)
    $failures = @($orderedResults | Where-Object { $_.Status -in @('Invalid', 'Expired', 'Failing') })
    $warnings = @($orderedResults | Where-Object { $_.Status -eq 'Warning' })
    $result = [PSCustomObject][Ordered]@{
        SchemaVersion        = '1.0'
        EvaluatedAtUtc       = $nowUtc.ToString('o')
        FailureThresholdDays = $FailureThresholdDays
        WarningThresholdDays = $WarningThresholdDays
        IsCompliant          = $failures.Count -eq 0
        Results              = $orderedResults
        Failures             = $failures
        Warnings             = $warnings
    }

    if ($ThrowOnFailure.IsPresent -and -not $result.IsCompliant) {
        $failureSummary = $failures | ForEach-Object {
            '{0} ({1})' -f $_.Operation, $_.Status
        }
        throw "API sunset threshold failed: $($failureSummary -join '; ')."
    }

    return $result
}
