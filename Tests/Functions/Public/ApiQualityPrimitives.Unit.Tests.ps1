#requires -modules @{ ModuleName = "Pester"; ModuleVersion = "5.7"; MaximumVersion = "5.999" }

BeforeAll {
    . "$PSScriptRoot/../../Helpers/TestTools.ps1"
    $script:moduleToTest = Initialize-TestEnvironment
}

Describe 'API quality primitives' {
    It 'reports missing, duplicate, unexpected, and incomplete inventory rows' {
        $result = Test-AtlassianPSVIIApiOperationInventory `
            -CommandName @('Get-One', 'Get-Two') `
            -InventoryRow @(
            [PSCustomObject]@{ Command = 'Get-One'; Method = 'GET' }
            [PSCustomObject]@{ Command = 'Get-One'; Method = '' }
            [PSCustomObject]@{ Command = 'Get-Other'; Method = 'GET' }
        ) `
            -RequiredProperty @('Command', 'Method')

        $result.IsConformant | Should -BeFalse
        $result.MissingCommands | Should -Be @('Get-Two')
        $result.DuplicateCommands | Should -Be @('Get-One')
        $result.UnexpectedCommands | Should -Be @('Get-Other')
        $result.InvalidRows.Count | Should -Be 1
        $result.InvalidRows[0].Property | Should -Be 'Method'
    }

    It 'returns a conformant inventory result with a stable schema' {
        $result = Test-AtlassianPSVIIApiOperationInventory `
            -CommandName @('Get-Two', 'Get-One') `
            -InventoryRow @(
            @{ Command = 'Get-One'; Method = 'GET' }
            @{ Command = 'Get-Two'; Method = 'GET' }
        ) `
            -RequiredProperty @('Command', 'Method')

        $result.SchemaVersion | Should -Be '1.0'
        $result.IsConformant | Should -BeTrue
        @($result.PSObject.Properties.Name) | Should -Be @(
            'SchemaVersion'
            'IsConformant'
            'CommandCount'
            'InventoryRowCount'
            'MissingCommands'
            'UnexpectedCommands'
            'DuplicateCommands'
            'InvalidRows'
        )
    }

    It 'redacts standard and configured sensitive headers in every diagnostic' {
        $result = Test-AtlassianPSVIIApiResponseHeader `
            -Header @{
            Authorization           = 'Bearer actual-token'
            'Proxy-Authorization'   = 'Basic proxy-secret'
            Cookie                  = 'session=secret'
            'Set-Cookie'            = 'session=secret'
            'X-Api-Key'             = 'api-secret'
            'X-Custom-Private'      = 'custom-secret'
            'X-RateLimit-Remaining' = '42'
        } `
            -ExpectedHeader @{
            Authorization           = 'Bearer expected-token'
            'X-Custom-Private'      = 'different-secret'
            'X-RateLimit-Remaining' = '41'
        } `
            -SensitiveHeader 'X-Custom-Private'

        $result.IsMatch | Should -BeFalse
        $result.RedactedHeaders.Authorization | Should -Be '[REDACTED]'
        $result.RedactedHeaders.'Proxy-Authorization' | Should -Be '[REDACTED]'
        $result.RedactedHeaders.Cookie | Should -Be '[REDACTED]'
        $result.RedactedHeaders.'Set-Cookie' | Should -Be '[REDACTED]'
        $result.RedactedHeaders.'X-Api-Key' | Should -Be '[REDACTED]'
        $result.RedactedHeaders.'X-Custom-Private' | Should -Be '[REDACTED]'
        $result.RedactedHeaders.'X-RateLimit-Remaining' | Should -Be '42'
        ($result | ConvertTo-Json -Depth 10) | Should -Not -Match 'actual-token|proxy-secret|session=secret|api-secret|custom-secret|expected-token|different-secret'
    }

    It 'reports malformed headers without returning their values' {
        $result = Test-AtlassianPSVIIApiResponseHeader -Header @{
            'Bad Header' = 'value'
            'X-Good'     = "value`r`ninjected"
        }

        $result.IsMatch | Should -BeFalse
        $result.MalformedHeaders.Count | Should -Be 2
        ($result | ConvertTo-Json -Depth 10) | Should -Not -Match 'injected'
    }

    It 'accepts native enumerable key-value response headers' {
        $headers = @(
            [PSCustomObject]@{
                Key   = 'X-Request-Id'
                Value = [String[]]@('request-123')
            }
        )

        $result = Test-AtlassianPSVIIApiResponseHeader `
            -Header $headers `
            -ExpectedHeader @{ 'X-Request-Id' = 'request-123' }

        $result.IsMatch | Should -BeTrue
        $result.RedactedHeaders.'X-Request-Id' | Should -Be 'request-123'
    }

    It 'classifies past and future sunset dates at configured thresholds' {
        $now = [DateTimeOffset]'2026-07-28T00:00:00Z'
        $result = Test-AtlassianPSVIIApiSunset `
            -Now $now `
            -FailureThresholdDays 30 `
            -WarningThresholdDays 90 `
            -Operation @(
            @{ Operation = 'Expired'; SunsetDate = '2026-07-27T00:00:00Z' }
            @{ Operation = 'Failing'; SunsetDate = '2026-08-15T00:00:00Z' }
            @{ Operation = 'Warning'; SunsetDate = '2026-10-01T00:00:00Z' }
            @{ Operation = 'Current'; SunsetDate = '2027-01-01T00:00:00Z' }
            @{ Operation = 'Malformed'; SunsetDate = 'not-a-date' }
        )

        $result.IsCompliant | Should -BeFalse
        ($result.Results | Where-Object Operation -EQ 'Expired').Status | Should -Be 'Expired'
        ($result.Results | Where-Object Operation -EQ 'Failing').Status | Should -Be 'Failing'
        ($result.Results | Where-Object Operation -EQ 'Warning').Status | Should -Be 'Warning'
        ($result.Results | Where-Object Operation -EQ 'Current').Status | Should -Be 'Current'
        ($result.Results | Where-Object Operation -EQ 'Malformed').Status | Should -Be 'Invalid'
    }

    It 'throws when a sunset reaches the failure threshold' {
        {
            Test-AtlassianPSVIIApiSunset `
                -Now ([DateTimeOffset]'2026-07-28T00:00:00Z') `
                -FailureThresholdDays 30 `
                -WarningThresholdDays 90 `
                -Operation @(
                @{ Operation = 'Soon'; SunsetDate = '2026-08-01T00:00:00Z' }
            ) `
                -ThrowOnFailure
        } | Should -Throw -ExpectedMessage 'API sunset threshold failed: Soon (Failing).'
    }

    It 'emits deterministic redacted canary JSON' {
        $parameters = @{
            Repository     = 'JiraPSVII'
            Operation      = 'Search-Issue'
            DeploymentType = 'Cloud'
            Status         = 'Passed'
            StartedAt      = [DateTimeOffset]'2026-07-28T01:00:00+12:00'
            CompletedAt    = [DateTimeOffset]'2026-07-28T01:00:01.250+12:00'
            Message        = 'Authorization: Bearer hidden'
            Metadata       = [Ordered]@{
                zeta          = 2
                Authorization = 'Bearer secret'
                apiToken      = 'token-value'
                alpha         = 1
                nested        = @{ cookie = 'session-secret'; result = 'ok' }
            }
            AsJson         = $true
        }

        $first = ConvertTo-AtlassianPSVIIApiCanaryResult @parameters
        $second = ConvertTo-AtlassianPSVIIApiCanaryResult @parameters

        $first | Should -BeExactly $second
        $first | Should -BeExactly '{"SchemaVersion":"1.0","Repository":"JiraPSVII","Operation":"Search-Issue","DeploymentType":"Cloud","Status":"Passed","StartedAtUtc":"2026-07-27T13:00:00.0000000+00:00","CompletedAtUtc":"2026-07-27T13:00:01.2500000+00:00","DurationMilliseconds":1250,"Message":"Authorization: [REDACTED]","Metadata":{"alpha":1,"apiToken":"[REDACTED]","Authorization":"[REDACTED]","nested":{"cookie":"[REDACTED]","result":"ok"},"zeta":2}}'
        $first | Should -Not -Match 'hidden|Bearer secret|token-value|session-secret'
    }
}
