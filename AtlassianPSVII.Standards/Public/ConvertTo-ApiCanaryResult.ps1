function ConvertTo-ApiCanaryResult {
    <#
    .SYNOPSIS
        Formats a scheduled API canary result with a stable schema.

    .DESCRIPTION
        Returns an ordered machine-readable record or compressed JSON.
        Metadata keys and diagnostic text that appear sensitive are redacted.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject], [String])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String]$Repository,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String]$Operation,

        [Parameter(Mandatory)]
        [ValidateSet('Cloud', 'DataCenter')]
        [String]$DeploymentType,

        [Parameter(Mandatory)]
        [ValidateSet('Passed', 'Failed', 'Warning', 'Skipped')]
        [String]$Status,

        [Parameter(Mandatory)]
        [DateTimeOffset]$StartedAt,

        [Parameter(Mandatory)]
        [DateTimeOffset]$CompletedAt,

        [Parameter()]
        [AllowEmptyString()]
        [String]$Message = '',

        [Parameter()]
        [Collections.IDictionary]$Metadata = @{},

        [Parameter()]
        [String[]]$SensitiveMetadataName = @(),

        [Parameter()]
        [Switch]$AsJson
    )

    $startedUtc = $StartedAt.ToUniversalTime()
    $completedUtc = $CompletedAt.ToUniversalTime()
    if ($completedUtc -lt $startedUtc) {
        throw 'CompletedAt cannot be earlier than StartedAt.'
    }

    $result = [PSCustomObject][Ordered]@{
        SchemaVersion        = '1.0'
        Repository           = $Repository
        Operation            = $Operation
        DeploymentType       = $DeploymentType
        Status               = $Status
        StartedAtUtc         = $startedUtc.ToString('o')
        CompletedAtUtc       = $completedUtc.ToString('o')
        DurationMilliseconds = [Int64][Math]::Round(
            ($completedUtc - $startedUtc).TotalMilliseconds,
            0,
            [MidpointRounding]::AwayFromZero
        )
        Message              = Protect-ApiQualityText -Text $Message
        Metadata             = ConvertTo-StableApiQualityData `
            -InputObject $Metadata `
            -AdditionalSensitiveName $SensitiveMetadataName
    }

    if ($AsJson.IsPresent) {
        return $result | ConvertTo-Json -Depth 20 -Compress
    }

    return $result
}
