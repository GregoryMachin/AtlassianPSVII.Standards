# AtlassianPSVII.Standards

> **Fork notice:** AtlassianPSVII.Standards is a fork of [AtlassianPS.Standards](https://github.com/AtlassianPS/AtlassianPS.Standards) by the [AtlassianPS](https://github.com/AtlassianPS) team (MIT License), renamed and maintained by Gregory Machin. "VII" is only part of the name: it supports Windows PowerShell 5.1 and PowerShell 7.4+, and can be loaded side by side with the upstream module.

`AtlassianPSVII.Standards` is a shared toolbag module that ships the AtlassianPSVII PSScriptAnalyzer baseline and reusable build helpers for AtlassianPSVII repositories.

Exported helpers cover:

- analyzer settings sync and lint orchestration (`Sync-ScriptAnalyzerSettings`, `Invoke-Lint`)
- build environment bootstrap and diagnostics (`Initialize-BuildEnvironment`, `Write-BuildInfo`)
- build output helpers (`Copy-ModuleArtifacts`, `Join-ModuleSource`)
- manifest, reproducible package, and provenance helpers (`New-ModulePackage`, `New-ReleaseProvenance`, `Test-ReleaseProvenance`)
- help generation helpers (`Update-ExternalHelp`, `Remove-OrphanedExternalHelp`)
- Pester orchestration (`Invoke-ModuleTests`)
- test bootstrap helpers (`Resolve-ProjectRoot`, `Resolve-ModuleSource`, `Initialize-ModuleTestEnvironment`)
- integration-test helpers (`Import-DotEnvFile`)
- dependency bootstrap and maintenance (`Install-DependencyRequirement`, `Update-DependencyReference`)
- API inventory, header, sunset, and canary quality primitives

## Usage

```powershell
Import-Module AtlassianPSVII.Standards
$settingsPath = Sync-AtlassianPSVIIScriptAnalyzerSettings -DestinationPath ./PSScriptAnalyzerSettings.psd1
Invoke-ScriptAnalyzer -Path ./MyModule -Settings $settingsPath -Recurse
```

The module manifest sets `DefaultCommandPrefix = 'AtlassianPSVII'`, so consumers can call prefixed commands without the function names carrying that infix in source.

## Blueprint Primitives

Blueprint primitives are small shared operations behind the JiraPSVII blueprint build and test workflow.
They cover artifact copy, source merge, package validation, external help generation, test bootstrap, and `.env` loading.
Repository build scripts should keep task orchestration local and readable.

Detailed contracts and examples live in [`docs/BlueprintHelpers.md`](docs/BlueprintHelpers.md).
API conformance and canary contracts live in [`docs/ApiQualityPrimitives.md`](docs/ApiQualityPrimitives.md).
Downstream migration guidance lives in [`docs/DownstreamAdoption.md`](docs/DownstreamAdoption.md).
Release flow guidance lives in [`docs/ReleaseBlueprint.md`](docs/ReleaseBlueprint.md).

## Repository Layout

- `AtlassianPSVII.Standards/` module source
- `Tests/` Pester tests
- `Tools/` dependency bootstrap scripts
- `.github/workflows/` CI/CD pipelines
- `AtlassianPSVII.Standards.build.ps1` Invoke-Build entrypoint

## Setup

```powershell
./Tools/setup.ps1
```

`setup.ps1` installs the union of runtime dependencies from `AtlassianPSVII.Standards.psd1` (`RequiredModules`) and build-only dependencies from `Tools/build.requirements.psd1`.

Use `Tools/update.dependencies.ps1` to refresh pinned dependency versions in `Tools/build.requirements.psd1` and `AtlassianPSVII.Standards.psd1`. The default behavior is fail-fast on lookup errors; use `Update-AtlassianPSVIIDependencyReference -AllowLookupFailure` only for explicit non-blocking/manual update runs.

Update a downstream repository's Standards package and setup-action pins as one transaction:

```powershell
./Tools/update.dependencies.ps1 `
    -TargetRepositoryRoot ../JiraPSVII `
    -StandardsVersion 0.1.12 `
    -SetupActionCommitSha <approved-40-character-sha>
```

The SHA is resolved from the trusted `AtlassianPSVII.Standards` `vX.Y.Z` tag and an explicitly supplied SHA must match it.
Only `Tools/build.requirements.psd1` and commit-pinned `GregoryMachin/AtlassianPSVII.Standards/.github/actions/setup-powershell` references below `.github/workflows` are eligible.
Use `-WhatIf` to preview the complete file set.
The update fails before writing when pins are missing or malformed and rolls back completed replacements if a later file cannot be replaced.

## Build, Lint, Test

```powershell
Invoke-Build -Task Lint, Build, Test
```

## Downstream Compatibility

Test a local Standards candidate against the four downstream repositories without publishing or changing their dependency pins:

```powershell
Invoke-Build -Task Build
./Tools/test.downstream.compatibility.ps1 `
    -CandidateModulePath ./Release/AtlassianPSVII.Standards `
    -WorkspaceRoot ..
```

The runner recognizes only `AtlassianPSVII.Configuration`, `JiraPSVII`, `JiraAgilePSVII`, and `ConfluencePSVII`.
For each repository it stages an isolated copy of the candidate at that repository's pinned Standards version, then invokes only the exact `<Repository>.build.ps1` entrypoint.
The fixed `Lint`, `Build`, and `Test` tasks run as separate invocations so each stage reloads the candidate while retaining build artifacts.
It attempts every selected repository before reporting aggregate failures.

Child processes receive an explicit environment allow-list rather than the caller's complete environment, so repository and Atlassian credentials are not forwarded.
Captured output is redacted for authorization, cookie, token, password, secret, and API-key values.
Missing repositories fail by default; use `-SkipMissingRepository` only when intentionally validating the subset available in a local workspace.

## Release

Label-based CD runs after release-labelled pull requests merge to `master`.
It computes the next semantic version from the merged PR's `release:*` label, prepares `CHANGELOG.md`, stamps the source manifest, commits that release metadata to `master`, validates the release metadata, creates an annotated tag, publishes to PowerShell Gallery, creates the GitHub release from the same changelog section, and notifies the website to update its module submodule.
The release-preparation commit also stamps the source module manifest with the exact released version and release notes so the tagged repository state matches the published package metadata.
The workflow should use `ATLASSIANPSVII_RELEASE_BOT_TOKEN` when pushing the release metadata commit and tag if branch protection does not allow the default `GITHUB_TOKEN` to push to `master`.

The continuous release workflow will:

1. Build the module.
2. Publish to PowerShell Gallery (when `PSGALLERY_API_KEY` is configured).
3. Create a GitHub release with a zipped module artifact.

The source manifest may start a development cycle on a major/minor maintenance baseline, but release-preparation commits stamp the exact `vX.Y.Z` release version before tagging.
Publish derives PSGallery release notes from the matching changelog version section and fails if that section is missing or empty.
Do not keep a separate tag-triggered release workflow unless it is intentionally idempotent across already-created tags, PSGallery packages, GitHub releases, and assets.
