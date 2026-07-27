# API Quality Primitives

The Standards module provides four additive primitives for API contract tests and scheduled canaries.
They operate on parsed objects so JiraPS, JiraAgilePS, and ConfluencePS can keep repository-specific Markdown parsing and transport logic local.

## Operation inventory conformance

`Test-AtlassianPSApiOperationInventory` compares exported command names with parsed inventory rows.
It reports missing, unexpected, duplicate, and incomplete rows in a stable result schema.
Use `-ThrowOnFailure` in a build gate.

```powershell
$result = Test-AtlassianPSApiOperationInventory `
    -CommandName $exportedCommands `
    -InventoryRow $inventoryRows `
    -RequiredProperty Command, Method, CloudRoute, DataCenterRoute `
    -ThrowOnFailure
```

## Safe response-header assertions

`Test-AtlassianPSApiResponseHeader` validates expected header values and rejects malformed header names or values.
Its output always redacts authorization, proxy authorization, cookies, set-cookie, API keys, token-like headers, secret-like headers, and names supplied through `-SensitiveHeader`.
Mismatch diagnostics for those headers are also redacted.

```powershell
$assertion = Test-AtlassianPSApiResponseHeader `
    -Header $response.Headers `
    -ExpectedHeader @{ 'X-RateLimit-Remaining' = '42' } `
    -SensitiveHeader 'X-Internal-Trace'
```

Do not log the raw transport header collection.
Log only `RedactedHeaders` or the complete assertion result.

## Sunset thresholds

`Test-AtlassianPSApiSunset` classifies operation sunset dates as `Current`, `Warning`, `Failing`, `Expired`, or `Invalid`.
The failure threshold must be less than or equal to the warning threshold.
Expired, invalid, and failure-threshold results make the summary noncompliant.

```powershell
Test-AtlassianPSApiSunset `
    -Operation $inventoryRows `
    -NameProperty Command `
    -SunsetProperty SunsetDate `
    -FailureThresholdDays 30 `
    -WarningThresholdDays 90 `
    -ThrowOnFailure
```

Pass a fixed `-Now` value in unit tests.

## Scheduled canary results

`ConvertTo-AtlassianPSApiCanaryResult` emits a fixed versioned property order, UTC timestamps, duration in milliseconds, and deterministically sorted metadata.
Use `-AsJson` for compact machine-readable output.
Sensitive metadata keys and recognizable credentials in messages are redacted.

```powershell
ConvertTo-AtlassianPSApiCanaryResult `
    -Repository JiraPS `
    -Operation Search-Issue `
    -DeploymentType Cloud `
    -Status Passed `
    -StartedAt $startedAt `
    -CompletedAt ([DateTimeOffset]::UtcNow) `
    -Metadata @{ httpStatus = 200 } `
    -AsJson
```

Canaries should pass only non-sensitive metadata and header assertion results into formatters.
