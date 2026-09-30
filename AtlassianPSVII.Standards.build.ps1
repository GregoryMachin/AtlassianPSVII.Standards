#requires -Modules InvokeBuild
[CmdletBinding()]
param(
    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')]
    [String]$PesterVerbosity = 'Normal',

    [Parameter()]
    [String]$VersionToPublish,

    [Parameter()]
    [String[]]$Tag,

    [Parameter()]
    [String[]]$ExcludeTag,

    # Release-publish mode: require the built artifact to already carry the planned version,
    # enforce it is newer than the published package, and verify release notes were written.
    [Parameter()]
    [Switch]$VerifyPublishedRelease,

    [Parameter()]
    [String]$SourceRepository,

    [Parameter()]
    [String]$SourceCommitSha,

    [Parameter()]
    [String]$SourceRef,

    [Parameter()]
    [String]$RunId
)

$projectName = 'AtlassianPSVII.Standards'
$moduleManifestPath = Join-Path -Path $PSScriptRoot -ChildPath "$projectName/$projectName.psd1"

try {
    Import-Module $moduleManifestPath -Force -ErrorAction Stop
}
catch {
    throw "Failed to import '$projectName'. Run './Tools/setup.ps1' and retry. Original error: $($_.Exception.Message)"
}

$script:BuildInfo = Initialize-AtlassianPSVIIBuildEnvironment `
    -ProjectName $projectName `
    -ProjectPath $PSScriptRoot `
    -VersionToPublish $VersionToPublish `
    -ResetBuildEnvironmentVariables

Task ShowDebugInfo {
    Write-AtlassianPSVIIBuildInfo -BuildInfo $script:BuildInfo
}

Task Lint {
    $null = Invoke-AtlassianPSVIIModuleTests `
        -TestPath (Join-Path -Path $env:BHProjectPath -ChildPath 'Tests/DependencyConsistency.Tests.ps1') `
        -PesterVerbosity $PesterVerbosity `
        -DefaultExcludeTag @()

    Invoke-AtlassianPSVIILint `
        -BuildScriptPath "$env:BHProjectPath/AtlassianPSVII.Standards.build.ps1" `
        -PesterVerbosity $PesterVerbosity
}

Task Clean {
    $testFiles = Join-Path -Path $env:BHProjectPath -ChildPath 'Test-*.xml'

    Remove-Item -Path $env:BHBuildOutput -Force -Recurse -ErrorAction SilentlyContinue
    Remove-Item -Path $testFiles -Force -ErrorAction SilentlyContinue
}

Task CopyBuildArtifacts {
    $additionalFiles = @(
        'CHANGELOG.md'
        'README.md'
        'LICENSE'
    )

    $null = Copy-AtlassianPSVIIModuleArtifacts `
        -ProjectPath $env:BHProjectPath `
        -ModuleName $env:BHProjectName `
        -BuildOutputPath $env:BHBuildOutput `
        -AdditionalFiles $additionalFiles `
        -IncludeTests
}

Task Build Clean, CopyBuildArtifacts, CompileModule, UpdateManifest, SetArtifactReleaseNotes

# Synopsis: Compile all functions into the .psm1 file
Task CompileModule {
    $releaseModulePath = Join-Path -Path $env:BHBuildOutput -ChildPath $env:BHProjectName
    $null = Join-AtlassianPSVIIModuleSource -ReleaseModulePath $releaseModulePath
}

# Synopsis: Update the manifest of the module
Task UpdateManifest {
    $null = Update-AtlassianPSVIIModuleManifestExports `
        -SourceModulePath $env:BHModulePath `
        -BuiltManifestPath $script:BuildInfo.BuiltManifestPath `
        -ModuleName $env:BHProjectName
}

# Synopsis: Populate release notes before tests so publication never mutates the tested artifact.
Task SetArtifactReleaseNotes {
    $builtManifestPath = $script:BuildInfo.BuiltManifestPath
    $built = Import-PowerShellDataFile -LiteralPath $builtManifestPath -ErrorAction Stop
    $prerelease = [String]$built.PrivateData.PSData.Prerelease
    $releaseVersion = 'v{0}{1}' -f $built.ModuleVersion, $(
        if ([String]::IsNullOrWhiteSpace($prerelease)) { '' } else { "-$prerelease" }
    )
    $releaseNotes = Get-AtlassianPSVIIReleaseNotesFromChangelog `
        -ChangelogPath (Join-Path -Path $env:BHProjectPath -ChildPath 'CHANGELOG.md') `
        -ReleaseVersion $releaseVersion `
        -ErrorAction Stop

    $null = Set-AtlassianPSVIIModuleManifestVersion `
        -BuiltManifestPath $builtManifestPath `
        -ModuleName $env:BHProjectName `
        -VersionToPublish $releaseVersion `
        -ReleaseNotes $releaseNotes `
        -ErrorAction Stop
}

Task Test {
    $resultOutputPath = Join-Path -Path $env:BHProjectPath -ChildPath "Test-$($script:BuildInfo.OS)-$($PSVersionTable.PSVersion.ToString()).xml"
    $null = Invoke-AtlassianPSVIIModuleTests `
        -TestPath (Join-Path -Path $env:BHProjectPath -ChildPath 'Tests') `
        -PesterVerbosity $PesterVerbosity `
        -Tag $Tag `
        -ExcludeTag $ExcludeTag `
        -DefaultExcludeTag @('Integration', 'Lint') `
        -ResultOutputPath $resultOutputPath
}

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

# Synopsis: Stamp release notes into the built artifact; in -VerifyPublishedRelease mode also verify it.
Task SetVersion {
    if (-not $script:BuildInfo.VersionToPublish) {
        throw 'VersionToPublish is required for SetVersion. Use -VersionToPublish <semver>.'
    }

    $builtManifestPath = $script:BuildInfo.BuiltManifestPath
    $expectedCore = $script:BuildInfo.VersionToPublish -replace '-.*$', ''

    if ($VerifyPublishedRelease) {
        # The published artifact is rebuilt from the version-stamped source, so it must already match.
        $built = Import-PowerShellDataFile -LiteralPath $builtManifestPath
        if ($built.ModuleVersion -ne $expectedCore) {
            throw "Built artifact ModuleVersion '$($built.ModuleVersion)' does not match release version '$($script:BuildInfo.VersionToPublish)'. The prepare step did not stamp the source manifest version."
        }
    }

    $changelogPath = Join-Path -Path $env:BHProjectPath -ChildPath 'CHANGELOG.md'
    $releaseNotes = Get-AtlassianPSVIIReleaseNotesFromChangelog -ChangelogPath $changelogPath -ReleaseVersion $script:BuildInfo.VersionToPublish

    $setVersionParameters = @{
        BuiltManifestPath = $builtManifestPath
        ModuleName        = $env:BHProjectName
        VersionToPublish  = $script:BuildInfo.VersionToPublish
        ReleaseNotes      = $releaseNotes
    }
    if ($VerifyPublishedRelease) {
        $setVersionParameters.EnforceGreaterThanPublished = $true
    }

    $null = Set-AtlassianPSVIIModuleManifestVersion @setVersionParameters

    if ($VerifyPublishedRelease) {
        $stamped = Import-PowerShellDataFile -LiteralPath $builtManifestPath
        if ($stamped.ModuleVersion -ne $expectedCore) {
            throw "Artifact ModuleVersion '$($stamped.ModuleVersion)' does not match expected '$expectedCore' after stamping."
        }
        if ([string]::IsNullOrWhiteSpace($stamped.PrivateData.PSData.ReleaseNotes)) {
            throw 'Artifact PrivateData.PSData.ReleaseNotes is empty after stamping.'
        }
    }
}

# Synopsis: Compress the built module into the publishable release artifact
Task Package {
    $script:PackagePath = New-AtlassianPSVIIModulePackage `
        -BuildOutputPath $env:BHBuildOutput `
        -ModuleName $env:BHProjectName
}

# Synopsis: Record package checksums, pinned dependencies, source identity, and CI identity.
Task Provenance Package, {
    foreach ($requiredValue in @(
            @{ Name = 'SourceRepository'; Value = $SourceRepository }
            @{ Name = 'SourceCommitSha'; Value = $SourceCommitSha }
            @{ Name = 'SourceRef'; Value = $SourceRef }
            @{ Name = 'RunId'; Value = $RunId }
        )) {
        if ([String]::IsNullOrWhiteSpace([String]$requiredValue.Value)) {
            throw "$($requiredValue.Name) is required for Provenance."
        }
    }

    $script:Provenance = New-AtlassianPSVIIReleaseProvenance `
        -PackagePath $script:PackagePath `
        -ModuleManifestPath $script:BuildInfo.BuiltManifestPath `
        -BuildRequirementsPath (Join-Path -Path $env:BHProjectPath -ChildPath 'Tools/build.requirements.psd1') `
        -Repository $SourceRepository `
        -CommitSha $SourceCommitSha `
        -SourceRef $SourceRef `
        -RunId $RunId `
        -OutputPath $env:BHBuildOutput
}

Task TestPublish Build, Package, {
    $null = Test-AtlassianPSVIIModulePackage `
        -BuildOutputPath $env:BHBuildOutput `
        -ModuleName $env:BHProjectName `
        -PackagePath $script:PackagePath
}

Task . Lint, Build, Test
