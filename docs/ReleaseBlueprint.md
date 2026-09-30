# AtlassianPSVII Release Blueprint

This document is the canonical release blueprint for AtlassianPSVII PowerShell modules.
Module repositories may keep short local runbooks, but cross-repository release strategy belongs here.

## Goals

- Keep release workflows predictable across AtlassianPSVII modules.
- Reuse shared Standards primitives instead of copying release logic into each repository.
- Keep `CHANGELOG.md`, GitHub release bodies, and PSGallery manifest `PrivateData.PSData.ReleaseNotes` synchronized.
- Fail release-note and tag validation before publishing immutable PSGallery packages.
- Publish the exact CI-tested package identified by deterministic checksums and signed provenance.
- Ship a machine-readable dependency manifest with every release.
- Make workflow drift visible in tests.

## Version And Changelog Contract

Use one `v`-prefixed three-part version everywhere a release is identified.

| Artifact | Format | Example |
|----------|--------|---------|
| Git tag | `vX.Y.Z` | `v3.0.0` |
| Changelog heading | `## vX.Y.Z - YYYY-MM-DD` | `## v3.0.0 - 2026-05-10` |
| Module manifest | `X.Y.Z` | `ModuleVersion = '3.0.0'` |

Pre-release tags may append a prerelease label, for example `v3.1.0-beta`.
The module manifest keeps the numeric version in `ModuleVersion` and uses `PrivateData.PSData.Prerelease` for the prerelease label where needed.

The release notes parser preserves the full markdown body under the matching `##` heading until the next `##` heading.
Introductory paragraphs before `###` sections are supported and are included in both PSGallery and GitHub release notes.

## Required Continuous Release Flow

The default path is label-based continuous delivery from merged pull requests.
After CI succeeds on a normal merged pull request with `release:patch`, `release:minor`, or `release:major`, the trusted `workflow_run` workflow should:

1. Check out the repository with full history and tags.
2. Resolve the merged pull request associated with the pushed commit.
3. Read the pull request release and changelog labels.
4. Compute the next `vX.Y.Z` tag from the latest stable semver tag and the release impact.
5. Create a generated `.changelog/<pr>.<impact>.<type>.md` fragment when the PR used a `changelog:*` label.
6. Run `prepare-release-changelog` to fold pending notes and fragments into the new version section.
7. Stamp only the release version into the source module manifest; release notes stay empty in the committed source.
8. Commit the release metadata changes directly to `master`.
9. Let CI build and test the bot-authored release metadata commit; the build populates release notes into the built manifest before the test matrix.
10. After every required test job passes, create one reproducible ZIP from the unchanged tested module directory.
11. Generate `SHA256SUMS`, `dependency-manifest.json`, and `release-provenance.json` for that ZIP and exact source commit.
12. Sign and persist a GitHub build-provenance attestation for the ZIP, then upload a commit-specific verified artifact.
13. Download only that commit-specific artifact and verify its checksums, repository, commit, workflow run, release tag, and signed attestation.
14. Create an annotated tag on the tested release metadata commit and build release notes from the committed `CHANGELOG.md` section.
15. Extract the attested ZIP and publish its unchanged module contents to PSGallery.
16. Create the GitHub release with the same attested ZIP, checksums, dependency manifest, provenance, and attestation bundle.
17. Notify the website to update its module submodule.

`release:none` merges should stop after planning and must not publish.
The workflow should be serialized with concurrency so multiple release-labelled merges do not race the next-version calculation.
Use `GITHUB_TOKEN` by default when committing release metadata to `master`.
Keep an optional release automation token, for example `ATLASSIANPSVII_RELEASE_BOT_TOKEN`, only for repositories where branch protection or repository rules block `GITHUB_TOKEN` pushes.

When unreleased changes already exist on `master` without an associated merged release-labelled PR, use the manual `workflow_dispatch` input on `continuous_release.yml` and choose the release impact for the whole bucket.
Manual dispatch must still check out `master`, not the arbitrary ref selected in the GitHub UI.
The manual path does not generate a PR-title changelog fragment; it releases the existing `## Unreleased` body and any existing `.changelog/*.md` fragments.
For prereleases, enter `alpha`, `beta`, `rc`, or a numbered form like `rc-2` in the manual `prerelease` input.
The generated tag and changelog section use forms like `vX.Y.Z-alpha`, `vX.Y.Z-beta`, `vX.Y.Z-rc`, or `vX.Y.Z-rc-2`; `Set-AtlassianPSVIIModuleManifestVersion` writes the manifest `PrivateData.PSData.Prerelease` label, and the GitHub release is marked as a prerelease.

## Release Recovery

Do not keep a separate tag-triggered release workflow unless it is intentionally idempotent across already-created tags, PSGallery packages, GitHub releases, uploaded assets, and website notifications.
The default AtlassianPSVII release path has one publishing workflow: `continuous_release.yml`.
If a release fails after publishing an immutable PSGallery package, repair the failed downstream artifact directly, for example by creating the missing GitHub release or rerunning the website dispatch, instead of rerunning a workflow that calls `Publish-Module` again.

## Required Shared Actions

Pin all Standards actions to the same released commit SHA and include a version comment. The release
workflow consumes these Standards actions: `setup-powershell`, `plan-merged-release`,
`prepare-release-changelog`, `commit-release-metadata`, `create-release-tag`, `resolve-release-tag`, and
`build-release-notes`.

```yaml
- name: Validate release tag
  id: release_ref
  uses: GregoryMachin/AtlassianPSVII.Standards/.github/actions/resolve-release-tag@<standards-sha> # v0.1.11

- uses: GregoryMachin/AtlassianPSVII.Standards/.github/actions/setup-powershell@<standards-sha> # v0.1.11

- uses: GregoryMachin/AtlassianPSVII.Standards/.github/actions/build-release-notes@<standards-sha> # v0.1.11
  id: release_notes
  with:
    release-version: ${{ steps.release_ref.outputs.release_tag }}
```

GitHub releases should use the generated file path and pin third-party actions to full commit SHAs:

```yaml
- name: Create Release and Upload Asset
  uses: softprops/action-gh-release@<action-sha> # v3
  with:
    tag_name: ${{ steps.release_ref.outputs.release_tag }}
    name: ${{ steps.release_ref.outputs.release_tag }}
    body_path: ${{ steps.release_notes.outputs.release_notes_path }}
```

Do not use `MatteoCampinoti94/changelog-to-release` or repo-local changelog formatting configuration.
GitHub release notes and PSGallery manifest release notes should be the same source text, not independently formatted variants.

## Required Build Script Pattern

Release metadata and provenance creation belong in the local `Invoke-Build` script, not inline in workflow YAML.
The committed source manifest keeps release notes empty.
The build copies the module, populates release notes into the built manifest, and then exposes that exact directory to every test job.
Only after tests pass may CI package it and create provenance.
The publishing workflow verifies and extracts that attested package; it must not stamp, rebuild, or repackage it.

```powershell
# Synopsis: Stamp the planned version into the committed source manifest (release notes stay empty here).
Task SetSourceVersion {
    if (-not $script:BuildInfo.VersionToPublish) {
        throw 'VersionToPublish is required for SetSourceVersion. Use -VersionToPublish <semver>.'
    }

    $null = Set-AtlassianPSVIIModuleManifestVersion `
        -BuiltManifestPath $env:BHPSModuleManifest `
        -ModuleName $env:BHProjectName `
        -VersionToPublish $script:BuildInfo.VersionToPublish
}

Task SetArtifactReleaseNotes {
    $builtManifestPath = $script:BuildInfo.BuiltManifestPath
    $built = Import-PowerShellDataFile -LiteralPath $builtManifestPath
    $releaseVersion = "v$($built.ModuleVersion)"
    $releaseNotes = Get-AtlassianPSVIIReleaseNotesFromChangelog `
        -ChangelogPath (Join-Path -Path $env:BHProjectPath -ChildPath 'CHANGELOG.md') `
        -ReleaseVersion $releaseVersion

    $null = Set-AtlassianPSVIIModuleManifestVersion `
        -BuiltManifestPath $builtManifestPath `
        -ModuleName $env:BHProjectName `
        -VersionToPublish $releaseVersion `
        -ReleaseNotes $releaseNotes
}

Task Package {
    $script:PackagePath = New-AtlassianPSVIIModulePackage `
        -BuildOutputPath $env:BHBuildOutput `
        -ModuleName $env:BHProjectName
}

Task Provenance Package, {
    $null = New-AtlassianPSVIIReleaseProvenance `
        -PackagePath $script:PackagePath `
        -ModuleManifestPath $script:BuildInfo.BuiltManifestPath `
        -BuildRequirementsPath "$env:BHProjectPath/Tools/build.requirements.psd1" `
        -Repository $SourceRepository `
        -CommitSha $SourceCommitSha `
        -SourceRef $SourceRef `
        -RunId $RunId `
        -OutputPath $env:BHBuildOutput
}
```

Keep repository build orchestration local.
Use Standards for small primitives and shared actions, not for broad module-specific release wrappers.
CI invokes build tasks (`SetArtifactReleaseNotes`, `Package`, and `Provenance`) for module-domain work.
Continuous release invokes `SetSourceVersion` only while preparing metadata, then uses Standards verification primitives and composite actions for deployment plumbing.

## Drift Guards

Each module should include guard tests that enforce the blueprint.
At minimum, test that:

- `Tools/build.requirements.psd1` pins `AtlassianPSVII.Standards` to the intended version.
- Every `AtlassianPSVII.Standards/.github/actions/*` workflow reference is pinned to a 40-character commit SHA.
- Every Standards action pin uses the same version comment as `Tools/build.requirements.psd1`.
- The release workflow uses `build-release-notes`.
- The release workflow uses `body_path: ${{ steps.release_notes.outputs.release_notes_path }}`.
- The release workflow builds release notes before publishing.
- CI packages only after the complete test matrix and creates deterministic checksums plus a dependency manifest.
- CI signs the package through `actions/attest` with only `id-token`, `attestations`, and artifact-metadata write permissions.
- The verified artifact name includes the exact source commit SHA.
- The publish job checks repository, commit, run, release tag, checksums, and attestation before `Publish-Module`.
- The publish job enforces the CI signer workflow, source digest, source ref, and hosted-runner policy with `gh attestation verify`.
- The publish job contains no artifact stamping, rebuild, or repackaging step.
- All third-party actions are pinned to full commit SHAs with version comments.
- The repository does not keep a non-idempotent `.github/workflows/release.yml` beside `continuous_release.yml`.
- The build script uses `Get-AtlassianPSVIIReleaseNotesFromChangelog` for manifest release notes.
- The built manifest receives release notes before the test matrix.
- The build script keeps publishing secrets and a `Publish` task out (publishing stays in the workflow).
- The committed source manifest keeps `PrivateData.PSData.ReleaseNotes` empty; release notes are populated only into the built artifact.
- The repository does not contain `changelog-to-release`, `.github/changelog.configuration.json`, or copied inline parser/write-file plumbing.

JiraPSVII is the reference implementation for these guard tests.
Future Standards work may consolidate the checks into a shared `Test-AtlassianPSVIIReleaseBlueprint` command.

## Pull Request Release Intent

Module repositories should require each pull request to declare release intent before merge.
GitHub branch protection cannot require labels directly, so repositories should make a `Release Intent` workflow check required.

Use exactly one release label:

- `release:none` for changes that do not belong in release notes and should not affect release versioning.
- `release:patch` for bug fixes and other patch releases.
- `release:minor` for new backward-compatible functionality.
- `release:major` for breaking changes.

For user-facing changes, use exactly one changelog source: either one changelog label or one valid custom changelog fragment, not both.
Use a changelog label when the standard generated fragment text is enough:

- `changelog:added`
- `changelog:changed`
- `changelog:fixed`
- `changelog:removed`
- `changelog:deprecated`
- `changelog:security`
- `changelog:breaking`

`changelog:breaking` requires `release:major`.

Custom fragments must be named:

```text
.changelog/<pr-number>.<patch|minor|major>.<added|changed|fixed|removed|deprecated|security|breaking>.md
```

Example:

```text
.changelog/701.patch.fixed.md
```

Generated fragments should use this content format:

```markdown
* <PR Title> (#<PR number>, @<PR author>)
```

Example workflow:

```yaml
name: Release Intent

on:
  pull_request_target:
    types: [opened, edited, synchronize, reopened, ready_for_review, labeled, unlabeled]

permissions:
  contents: read
  pull-requests: write
  issues: write

jobs:
  validate:
    name: Release Intent
    runs-on: ubuntu-latest
    steps:
      - uses: GregoryMachin/AtlassianPSVII.Standards/.github/actions/validate-release-intent@<standards-sha>
```

The workflow intentionally runs on `pull_request_target` and must not check out or execute pull request code.
The shared action reads PR labels and changed file names through the GitHub API, then maintains a sticky PR comment when a human needs to fix labels or fragments.

Make the `Release Intent` job a required branch protection check.

## Migration Checklist

For each existing module repository:

1. Bump `Tools/build.requirements.psd1` to the current `AtlassianPSVII.Standards` version.
2. Pin all Standards workflow actions to the same release commit SHA.
3. Remove non-idempotent tag-triggered release workflows such as `.github/workflows/release.yml`.
4. Replace local changelog parsers in build scripts with `Get-AtlassianPSVIIReleaseNotesFromChangelog`.
5. Add or update drift guard tests.
6. Add the `Release Intent` workflow and make it a required check.
7. Add the label-based `Continuous Release` workflow.
8. Configure required labels and secrets.
9. Update the local release runbook to link back to this blueprint.
10. Run local workflow syntax, guard tests, lint, build/test, and release metadata preflight before pushing.

## Implementing Label-Based CD In A Module Repository

Use this section as the implementation order when migrating another AtlassianPSVII module.
Replace every `<ModuleName>`, `<standards-sha>`, and version comment with the target repository values.

### Required Labels

Create these labels in the repository before making `Release Intent` required:

```text
release:none
release:patch
release:minor
release:major
changelog:added
changelog:changed
changelog:fixed
changelog:removed
changelog:deprecated
changelog:security
changelog:breaking
```

### Required Secrets And Variables

Required secrets:

```text
PSGALLERY_API_KEY
HOMEPAGE_PAT
```

Optional secret:

```text
ATLASSIANPSVII_RELEASE_BOT_TOKEN
```

Use `ATLASSIANPSVII_RELEASE_BOT_TOKEN` when branch protection or repository rules prevent `GITHUB_TOKEN` from pushing the release metadata commit and annotated tag to `master`.
If the repository has no branch protection, `GITHUB_TOKEN` is enough.

### Release Intent Workflow

Add `.github/workflows/release_intent.yml`:

```yaml
name: Release Intent

on:
  pull_request_target:
    types: [opened, edited, synchronize, reopened, ready_for_review, labeled, unlabeled]

permissions:
  contents: read
  pull-requests: write
  issues: write

jobs:
  validate:
    name: Release Intent
    runs-on: ubuntu-latest
    steps:
      - name: Validate release intent
        uses: GregoryMachin/AtlassianPSVII.Standards/.github/actions/validate-release-intent@<standards-sha> # vX.Y.Z
```

Do not check out pull request code in this workflow.
Make `Release Intent` a required branch-protection check when the repository uses branch protection.

### Continuous Release Workflow

Add `.github/workflows/continuous_release.yml`:

```yaml
name: Continuous Release

on:
  workflow_run:
    workflows: [CI]
    types: [completed]
  workflow_dispatch:
    inputs:
      release_impact:
        description: Release impact for unreleased changes already on master
        required: true
        type: choice
        options:
          - patch
          - minor
          - major
      prerelease:
        description: Optional prerelease label for unreleased changes already on master, for example alpha, beta, rc, or rc-2
        required: false
        type: string

concurrency:
  group: continuous-release
  cancel-in-progress: false

permissions:
  actions: read
  contents: write
  pull-requests: read

jobs:
  prepare:
    name: Prepare release metadata
    if: >-
      github.event_name == 'workflow_dispatch' ||
      (github.event.workflow_run.conclusion == 'success' &&
      github.event.workflow_run.head_branch == 'master' &&
      !startsWith(github.event.workflow_run.head_commit.message, 'Prepare v'))
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<checkout-sha> # v6
        with:
          fetch-depth: 0
          ref: ${{ github.event_name == 'workflow_dispatch' && 'master' || github.event.workflow_run.head_sha }}

      - name: Plan release
        id: plan
        uses: GregoryMachin/AtlassianPSVII.Standards/.github/actions/plan-merged-release@<standards-sha> # vX.Y.Z
        with:
          commit-sha: ${{ github.event_name == 'workflow_run' && github.event.workflow_run.head_sha || '' }}
          release-impact: ${{ github.event_name == 'workflow_dispatch' && inputs.release_impact || '' }}
          prerelease-label: ${{ github.event_name == 'workflow_dispatch' && inputs.prerelease || '' }}

      - name: Create generated changelog fragment
        if: steps.plan.outputs.should_release == 'true' && steps.plan.outputs.fragment_path != ''
        shell: pwsh
        env:
          FRAGMENT_PATH: ${{ steps.plan.outputs.fragment_path }}
          FRAGMENT_CONTENT: ${{ steps.plan.outputs.fragment_content }}
        run: |
          New-Item -Path (Split-Path -Path $env:FRAGMENT_PATH -Parent) -ItemType Directory -Force | Out-Null
          $env:FRAGMENT_CONTENT | Set-Content -LiteralPath $env:FRAGMENT_PATH -Encoding utf8

      - name: Prepare release changelog
        if: steps.plan.outputs.should_release == 'true'
        uses: GregoryMachin/AtlassianPSVII.Standards/.github/actions/prepare-release-changelog@<standards-sha> # vX.Y.Z
        with:
          release-version: ${{ steps.plan.outputs.release_tag }}

      - uses: GregoryMachin/AtlassianPSVII.Standards/.github/actions/setup-powershell@<standards-sha> # vX.Y.Z
        if: steps.plan.outputs.should_release == 'true'

      - name: Stamp source manifest version
        if: steps.plan.outputs.should_release == 'true'
        run: Invoke-Build -Task SetSourceVersion -VersionToPublish ${{ steps.plan.outputs.release_tag }}
        shell: pwsh

      - name: Commit release metadata
        if: steps.plan.outputs.should_release == 'true'
        uses: GregoryMachin/AtlassianPSVII.Standards/.github/actions/commit-release-metadata@<standards-sha> # vX.Y.Z
        with:
          release-tag: ${{ steps.plan.outputs.release_tag }}
          manifest-path: <ModuleName>/<ModuleName>.psd1
          github-token: ${{ github.token }}
          release-bot-token: ${{ secrets.ATLASSIANPSVII_RELEASE_BOT_TOKEN }}

  publish:
    name: Publish tested release artifact
    if: >-
      github.event_name == 'workflow_run' &&
      github.event.workflow_run.conclusion == 'success' &&
      github.event.workflow_run.head_branch == 'master' &&
      startsWith(github.event.workflow_run.head_commit.message, 'Prepare v') &&
      github.event.workflow_run.head_commit.author.name == 'github-actions[bot]'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<checkout-sha> # v6
        with:
          fetch-depth: 0
          ref: ${{ github.event.workflow_run.head_sha }}

      - name: Resolve prepared release
        id: prepared_release
        shell: pwsh
        run: |
          $message = '${{ github.event.workflow_run.head_commit.message }}'
          if ($message -notmatch '^Prepare (?<tag>v\d+\.\d+\.\d+(?:-(?:alpha|beta|rc)(?:-\d+)?)?) release$') {
              throw "Commit message '$message' is not a release metadata commit."
          }

          "release_tag=$($Matches.tag)" >> $env:GITHUB_OUTPUT

      - name: Download tested release artifact
        uses: dawidd6/action-download-artifact@<download-action-sha> # v21
        with:
          run_id: ${{ github.event.workflow_run.id }}
          name: Verified-Release-${{ github.event.workflow_run.head_sha }}
          path: ./VerifiedRelease/
          if_no_artifact_found: fail

      - uses: GregoryMachin/AtlassianPSVII.Standards/.github/actions/setup-powershell@<standards-sha> # vX.Y.Z

      - name: Verify checksums and provenance identity
        shell: pwsh
        run: |
          Test-AtlassianPSVIIReleaseProvenance `
            -ReleasePath ./VerifiedRelease `
            -ExpectedRepository '${{ github.repository }}' `
            -ExpectedCommitSha '${{ github.event.workflow_run.head_sha }}' `
            -ExpectedRunId '${{ github.event.workflow_run.id }}' `
            -ExpectedReleaseTag '${{ steps.prepared_release.outputs.release_tag }}' `
            -AttestationPath ./VerifiedRelease/<ModuleName>.intoto.jsonl `
            -RequireAttestation

      - name: Verify GitHub artifact attestation
        shell: bash
        run: |
          gh attestation verify ./VerifiedRelease/<ModuleName>.zip \
            --bundle ./VerifiedRelease/<ModuleName>.intoto.jsonl \
            --repo '${{ github.repository }}' \
            --signer-workflow '${{ github.repository }}/.github/workflows/ci.yml' \
            --source-digest '${{ github.event.workflow_run.head_sha }}' \
            --source-ref 'refs/heads/master' \
            --deny-self-hosted-runners

      - name: Extract attested package
        shell: pwsh
        run: Expand-Archive -LiteralPath ./VerifiedRelease/<ModuleName>.zip -DestinationPath ./Publish

      - name: Create annotated release tag
        uses: GregoryMachin/AtlassianPSVII.Standards/.github/actions/create-release-tag@<standards-sha> # vX.Y.Z
        with:
          tag: ${{ steps.prepared_release.outputs.release_tag }}

      - name: Resolve release ref
        id: release_ref
        uses: GregoryMachin/AtlassianPSVII.Standards/.github/actions/resolve-release-tag@<standards-sha> # vX.Y.Z
        with:
          tag: ${{ steps.prepared_release.outputs.release_tag }}

      - name: Build release notes
        id: release_notes
        uses: GregoryMachin/AtlassianPSVII.Standards/.github/actions/build-release-notes@<standards-sha> # vX.Y.Z
        with:
          release-version: ${{ steps.release_ref.outputs.release_tag }}

      - name: Publish tested module artifact
        run: Publish-Module -Path ./Publish/<ModuleName> -NuGetApiKey ${{ secrets.PSGALLERY_API_KEY }} -ErrorAction Stop
        shell: pwsh

      - name: Create GitHub release and upload asset
        uses: softprops/action-gh-release@<release-action-sha> # v3
        with:
          tag_name: ${{ steps.release_ref.outputs.release_tag }}
          name: ${{ steps.release_ref.outputs.release_tag }}
          body_path: ${{ steps.release_notes.outputs.release_notes_path }}
          files: |
            ./VerifiedRelease/<ModuleName>.zip
            ./VerifiedRelease/SHA256SUMS
            ./VerifiedRelease/dependency-manifest.json
            ./VerifiedRelease/release-provenance.json
            ./VerifiedRelease/<ModuleName>.intoto.jsonl
          fail_on_unmatched_files: true
          draft: false
          prerelease: ${{ contains(steps.release_ref.outputs.release_tag, '-alpha') || contains(steps.release_ref.outputs.release_tag, '-beta') || contains(steps.release_ref.outputs.release_tag, '-rc') }}
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      - name: Notify homepage to update submodule
        if: ${{ !contains(steps.release_ref.outputs.release_tag, '-alpha') && !contains(steps.release_ref.outputs.release_tag, '-beta') && !contains(steps.release_ref.outputs.release_tag, '-rc') }}
        uses: peter-evans/repository-dispatch@<dispatch-action-sha> # v4
        with:
          token: ${{ secrets.HOMEPAGE_PAT }}
          repository: AtlassianPS/AtlassianPS.github.io
          event-type: module-release
          client-payload: '{"module": "<ModuleName>", "version": "${{ steps.release_ref.outputs.release_tag }}"}'
```

Use the exact repository secret name for the website token.
Existing modules use `HOMEPAGE_PAT`; if a repository uses a different name, adjust the snippet instead of creating duplicate secrets.

### Releasing A Bucket Already On Master

If a maintainer asks an agent to release unreleased changes that already exist on `master`, do not create an empty release PR.
Use the manual dispatch path of `continuous_release.yml` instead:

1. Inspect `CHANGELOG.md` and `.changelog/*.md` to understand the pending release notes.
2. Choose the highest required impact: `major` beats `minor`, `minor` beats `patch`.
3. Run `continuous_release.yml` with `release_impact` set to that impact; leave `prerelease` empty for a stable release or enter `alpha`, `beta`, `rc`, or a numbered form like `rc-2` for a prerelease.
4. Monitor the run until the release metadata commit, annotated tag, PSGallery publish, GitHub release, and website dispatch for stable releases complete.

The manual path computes the next version from existing stable `vX.Y.Z` tags and folds the current `## Unreleased` body plus all valid changelog fragments into that version section.
It intentionally does not generate a PR-title fragment because there is no single source PR.

### Module-Specific Substitutions

When copying templates, replace:

| Placeholder | Replace with |
|-------------|--------------|
| `<ModuleName>` | Repository module name, for example `JiraPSVII` |
| `<standards-sha>` | 40-character `AtlassianPSVII.Standards` release commit SHA |
| `# vX.Y.Z` | Matching Standards package version comment |
| `./Release/<ModuleName>.zip` | Actual release artifact zip path |
| Website token secret | Existing repository secret, usually `HOMEPAGE_PAT` |

Do not copy the Standards repository's self-import path unless the target repository is `AtlassianPSVII.Standards` itself.

### Validation Before Opening The Migration PR

Run these checks from the target repository root:

```bash
actionlint .github/workflows/ci.yml .github/workflows/release_intent.yml .github/workflows/continuous_release.yml
git diff --check
```

```powershell
Invoke-Build -Task Lint, Build, Test
```

Optionally use a local throwaway version for a build preflight only after `CHANGELOG.md` has a matching section.
If no release section exists yet, test the parser by preparing a temporary changelog section and revert that temporary change before opening the PR.

## Release Preparation

Before creating a release tag, prepare the changelog section, run the module's normal build/test gate, and verify release metadata for the exact tag.

```yaml
- uses: GregoryMachin/AtlassianPSVII.Standards/.github/actions/prepare-release-changelog@<standards-sha>
  with:
    release-version: vX.Y.Z
```

This moves pending `## Unreleased` content and valid `.changelog/*.md` fragments into `## vX.Y.Z - YYYY-MM-DD`, then deletes the consumed fragments.
The generated release-notes file is written outside the repository by default; commit only `CHANGELOG.md` and consumed fragment deletions.
In the continuous release flow, the trusted workflow creates and commits these changes automatically after the labelled PR merges.
The same release metadata commit should update the source module manifest so `CHANGELOG.md`, the tag, the repository manifest, the GitHub release body, and PSGallery metadata all describe the same version.
For manual release preparation outside the continuous release workflow, review the generated changelog before tagging the release.

```powershell
Invoke-Build -Task Build, Test
```

Optionally run `Invoke-Build -Task Build` after temporarily aligning the source manifest and changelog in a throwaway branch.
If the preflight cannot find a matching changelog section, do not tag the release.

## Common Mistakes

- Creating a non-annotated release tag.
- Tagging a commit that is not reachable from `origin/master`.
- Using `## X.Y.Z` in the changelog while tagging `vX.Y.Z`.
- Using two-part tags for one repo and three-part tags for another.
- Publishing with GitHub release notes generated from a different parser than PSGallery release notes.
- Publishing before building release notes from the changelog.
- Fixing GitHub release notes after PSGallery publish and assuming package metadata changed too.

Published PSGallery package metadata is immutable.
The release workflow must get release notes right before publishing.
