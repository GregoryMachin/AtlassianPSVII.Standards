# AtlassianPS.Standards current state

Reviewed: 2026-07-27

## Purpose

`AtlassianPS.Standards` is the shared build, lint, test, packaging, dependency, and release-automation module for AtlassianPS repositories.
It is infrastructure for the PowerShell projects rather than an Atlassian product API client.

## How it works

- The manifest is version `0.1.12`, supports PowerShell 5.1, and applies the `AtlassianPS` default prefix.
- Twenty public source files expose primitives for resolving projects, joining module source, generating help, testing packages, installing dependencies, running tests/lint, and preparing releases.
- Eleven private helpers implement shared internals.
- Downstream repositories keep their task orchestration locally but call these stable primitives.
- Composite actions under `.github/actions` implement release intent validation, changelog preparation, release-note construction, tag resolution, and PowerShell setup.
- `docs/ReleaseBlueprint.md`, `docs/BlueprintHelpers.md`, and `docs/DownstreamAdoption.md` define the cross-repository contract.

Snapshot: branch `master`, last local commit `b95fd4d` dated 2026-06-18, matching manifest version `0.1.12`.

## Testing and delivery

- 19 `*.Tests.ps1` files are present, including 14 named unit-test files.
- Tests cover public/private helpers, tooling entry points, build behavior, manifest validity, help, and release artifacts.
- CI lints on Ubuntu, builds once, and tests Windows PowerShell 5.1 plus PowerShell 7 on Windows, Ubuntu, and macOS.
- The repository dogfoods its own setup action and continuous release process.
- Pester 5.7.1 and InvokeBuild 5.14.23 are pinned in both manifest/build requirements as applicable.
- The required local gate is `Invoke-Build -Task Lint, Build, Test`.

## Current strengths

- This is the most current shared-infrastructure repository in the workspace.
- Compatibility and semantic-versioning expectations are explicit.
- Release automation promotes CI-tested artifacts and derives release notes from one changelog source.
- Shared helpers reduce drift across product repositories.
- Windows PowerShell 5.1 and cross-platform PowerShell 7 remain tested.

## Gaps and risks

1. Downstream adoption is uneven: Configuration, ConfluencePS, and JiraAgilePS are pinned to older Standards releases.
2. `FunctionsToExport = '*'` weakens the stated stable-contract boundary.
3. Shared action consumers pin commit SHAs, but synchronized-update tooling and drift reporting remain essential.
4. There is no workspace-level compatibility test that exercises all downstream repositories against a candidate Standards release.
5. The project must decide how long Windows PowerShell 5.1 remains a required baseline as the wider ecosystem moves to PowerShell 7.
6. The release process is sophisticated enough that recovery, rollback, compromised-token, and partial-publish procedures should be exercised, not only documented.

## Recommended update plan

### Now

1. Generate explicit manifest exports and fail CI on unplanned public-surface changes.
2. Add a downstream compatibility matrix that checks candidate Standards builds against Configuration, ConfluencePS, JiraAgilePS, and JiraPS.
3. Provide one supported command/action to update both `Tools/build.requirements.psd1` and workflow SHA pins.
4. Add contract tests for failed Gallery publication, existing tags, missing artifacts, and changelog preparation races.

### Next

5. Publish a deprecation policy for shared helpers and a machine-readable compatibility matrix.
6. Add provenance/SBOM generation and artifact attestations to module releases.
7. Centralize reusable Cloud integration-test conventions: secret names, redaction, retry telemetry, deprecation-header capture, and scheduled canaries.
8. Create a PowerShell 7 migration policy while retaining PowerShell 5.1 only where user demand and Data Center transition requirements justify it.
9. Add a repository template or conformance command that reports drift from the release blueprint.

## Atlassian platform relevance

Product repositories now need faster Cloud API migration cycles.
Standards should make scheduled contract tests and deprecation-header reporting routine because Atlassian Cloud uses time-bound deprecation and sunset notices:
<https://developer.atlassian.com/platform/marketplace/atlassian-rest-api-policy/>

## Review boundary

This was a static review.
The test suite and release dry-runs were inventoried but not executed.

