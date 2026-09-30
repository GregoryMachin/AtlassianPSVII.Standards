# Blueprint Primitives

`AtlassianPSVII.Standards` provides small helpers for repeated JiraPSVII-style build and test details.
Repository build scripts should stay readable: keep task orchestration in the repository and call these commands only for concrete operations.
For the cross-repository release strategy, see [ReleaseBlueprint.md](ReleaseBlueprint.md).

The module manifest sets `DefaultCommandPrefix = 'AtlassianPSVII'`.
Consumers call commands with the prefixed names, for example `Test-AtlassianPSVIIModulePackage`.

## Helper Contracts

| Area | Helpers | Contract |
|------|---------|----------|
| Build output | `Copy-ModuleArtifacts`, `Join-ModuleSource` | Copy release artifacts and merge module source folders into the release `.psm1`. |
| Manifest and package validation | `Update-ModuleManifestExports`, `Set-ModuleManifestVersion`, `Get-ReleaseNotesFromChangelog`, `New-ModulePackage`, `Test-ModulePackage` | Update manifest exports, set release metadata, create a reproducible package ZIP, and validate the package contains the expected manifest. |
| Release provenance | `New-ReleaseProvenance`, `Test-ReleaseProvenance` | Write deterministic SHA-256 checksums and dependency/source provenance, then verify artifact identity before signed-attestation verification. |
| External help | `Update-ExternalHelp`, `Remove-OrphanedExternalHelp` | Generate PlatyPS external help and remove generated help files that no longer have markdown sources. |
| Test bootstrap | `Resolve-ProjectRoot`, `Resolve-ModuleSource`, `Initialize-ModuleTestEnvironment` | Resolve repository/module paths and import the module under test for Pester. |
| Environment loading | `Import-DotEnvFile` | Load `.env` values into process-scoped environment variables without emitting secret values. |

## Readable Build Task Example

Prefer explicit task dependencies and concrete helper calls over a generic build wrapper.

```powershell
Task Build Clean, CopyBuildArtifacts, CompileModule, UpdateManifest

Task CopyBuildArtifacts {
    $null = Copy-AtlassianPSVIIModuleArtifacts `
        -ProjectPath $env:BHProjectPath `
        -ModuleName $env:BHProjectName `
        -BuildOutputPath $env:BHBuildOutput `
        -AdditionalFiles @('CHANGELOG.md', 'README.md', 'LICENSE') `
        -IncludeTests
}

Task CompileModule {
    $releaseModulePath = Join-Path -Path $env:BHBuildOutput -ChildPath $env:BHProjectName
    $null = Join-AtlassianPSVIIModuleSource -ReleaseModulePath $releaseModulePath
}

Task UpdateManifest {
    $null = Update-AtlassianPSVIIModuleManifestExports `
        -SourceModulePath $env:BHModulePath `
        -BuiltManifestPath $script:BuildInfo.BuiltManifestPath `
        -ModuleName $env:BHProjectName
}
```

## Publish Dry Run

Package validation is intentionally two visible steps: create the reproducible package, then validate it.
CI performs these steps only after all tests pass and generates provenance for the unchanged tested directory.
Continuous release verifies and extracts the attested ZIP without rebuilding it.

```powershell
Task TestPublish Build, {
    $packagePath = New-AtlassianPSVIIModulePackage `
        -BuildOutputPath $env:BHBuildOutput `
        -ModuleName $env:BHProjectName

    $null = Test-AtlassianPSVIIModulePackage `
        -BuildOutputPath $env:BHBuildOutput `
        -ModuleName $env:BHProjectName `
        -PackagePath $packagePath
}
```

Create provenance beside the package:

```powershell
$provenance = New-AtlassianPSVIIReleaseProvenance `
    -PackagePath $packagePath `
    -ModuleManifestPath $script:BuildInfo.BuiltManifestPath `
    -BuildRequirementsPath ./Tools/build.requirements.psd1 `
    -Repository $env:GITHUB_REPOSITORY `
    -CommitSha $env:GITHUB_SHA `
    -SourceRef $env:GITHUB_REF `
    -RunId $env:GITHUB_RUN_ID `
    -OutputPath $env:BHBuildOutput
```

`Test-AtlassianPSVIIReleaseProvenance` verifies the recorded repository, commit, run, release tag, SHA-256 values, and required attestation-bundle presence.
Follow it with `gh attestation verify` to validate the signature and trusted CI identity.

## Release Notes

Release builds should derive manifest release notes from the same `CHANGELOG.md` section used for the GitHub release body.
Use tag-form headings, for example `## v1.2.3`, and pass the validated release tag through the build.
Use the shared `build-release-notes` action in GitHub workflows so repositories do not copy PowerShell plumbing.

```yaml
- name: Build release notes from changelog
  id: release_notes
  uses: GregoryMachin/AtlassianPSVII.Standards/.github/actions/build-release-notes@<standards-sha>
  with:
    release-version: ${{ steps.release_ref.outputs.release_tag }}

- name: Create Release
  uses: softprops/action-gh-release@<action-sha> # v3
  with:
    body_path: ${{ steps.release_notes.outputs.release_notes_path }}
```

```powershell
Task SetArtifactReleaseNotes {
    $built = Import-PowerShellDataFile -LiteralPath $script:BuildInfo.BuiltManifestPath
    $releaseVersion = "v$($built.ModuleVersion)"
    $releaseNotes = Get-AtlassianPSVIIReleaseNotesFromChangelog `
        -ChangelogPath (Join-Path -Path $env:BHProjectPath -ChildPath 'CHANGELOG.md') `
        -ReleaseVersion $releaseVersion

    $null = Set-AtlassianPSVIIModuleManifestVersion `
        -BuiltManifestPath $script:BuildInfo.BuiltManifestPath `
        -ModuleName $env:BHProjectName `
        -VersionToPublish $releaseVersion `
        -ReleaseNotes $releaseNotes
}
```

`Get-AtlassianPSVIIReleaseNotesFromChangelog` also accepts historical headings without the `v` prefix and dated headings like `## 1.2.3 - 2026-05-10`, so repositories can migrate existing changelogs without local parser code.

## Release Changelog Preparation

Release automation should fold pending changelog entries and custom fragments into the next version section, then delete the consumed fragments.
Use the `prepare-release-changelog` composite action instead of exporting another module helper for GitHub-only release mechanics.
In the continuous release workflow, commit the resulting `CHANGELOG.md` update and `.changelog` deletions directly to `master` after a release-labelled PR merges.
Commit the source module manifest version in that same release metadata commit.
Keep source release notes empty; the build derives them from the committed changelog before testing the artifact.
For manual release preparation, commit the same files before tagging the release.

```yaml
- uses: GregoryMachin/AtlassianPSVII.Standards/.github/actions/prepare-release-changelog@<standards-sha>
  with:
    release-version: v1.2.3
```

The action creates `## v1.2.3 - YYYY-MM-DD` immediately after `## Unreleased`, moves any existing Unreleased body plus valid `.changelog/*.md` fragment contents into that section, and deletes only the consumed fragments.
By default, the generated release-notes output file is written under the runner temp directory so release-preparation PRs only need to commit `CHANGELOG.md` and `.changelog` deletions.

Use the `plan-merged-release` composite action from trusted `push` workflows to resolve a merged PR's release labels, compute the next stable semver tag, and generate a standard fragment when the PR used a `changelog:*` label.
It does not publish by itself; the workflow remains responsible for committing the prepared changelog, validating the release, creating the annotated tag, publishing to PSGallery, and creating the GitHub release.

## External Help

The help generator wraps the PlatyPS v1 behavior expected by AtlassianPSVII modules, including nested MAML flattening and MAML metadata repair for aliases, pipeline input, default values, and examples.

```powershell
Update-AtlassianPSVIIExternalHelp `
    -DocsPath "$env:BHProjectPath/docs" `
    -ModulePath $env:BHModulePath `
    -ModuleName $env:BHProjectName

Remove-AtlassianPSVIIOrphanedExternalHelp `
    -DocsPath "$env:BHProjectPath/docs" `
    -ModulePath $env:BHModulePath `
    -ModuleName $env:BHProjectName
```

## Test Bootstrap

Use `Initialize-AtlassianPSVIIModuleTestEnvironment` from Pester `BeforeAll` blocks when a repository only needs the standard source/release manifest resolution and module import.

```powershell
BeforeAll {
    Import-Module AtlassianPSVII.Standards
    $script:moduleToTest = Initialize-AtlassianPSVIIModuleTestEnvironment `
        -ModuleName 'JiraPSVII' `
        -StartPath $PSScriptRoot
}
```

Use `Resolve-AtlassianPSVIIProjectRoot` and `Resolve-AtlassianPSVIIModuleSource` directly when a test needs only path resolution.

## Integration Tests

Keep integration orchestration local when it knows product semantics: Cloud/Data Center variable names, typed test contexts, Docker Compose service names, provisioning, fixture setup, and cleanup.

Use `Import-AtlassianPSVIIDotEnvFile` as the shared primitive for local `.env` loading, then validate product-specific environment variables in the repository helper.
