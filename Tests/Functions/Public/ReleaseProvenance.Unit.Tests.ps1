#requires -modules @{ ModuleName = "Pester"; ModuleVersion = "5.7"; MaximumVersion = "5.999" }

BeforeAll {
    . "$PSScriptRoot/../../Helpers/TestTools.ps1"
    $script:moduleToTest = Initialize-TestEnvironment

    function Initialize-ProvenanceFixture {
        param(
            [Parameter(Mandatory)]
            [String]$Root,

            [Parameter()]
            [String]$Prerelease = ''
        )

        $releasePath = Join-Path -Path $Root -ChildPath 'Release'
        $modulePath = Join-Path -Path $releasePath -ChildPath 'Example'
        $null = New-Item -Path $modulePath -ItemType Directory -Force
        Set-Content -LiteralPath (Join-Path -Path $modulePath -ChildPath 'Example.psm1') -Value 'function Get-Example { }'

        $manifestPath = Join-Path -Path $modulePath -ChildPath 'Example.psd1'
        @"
@{
    RootModule = 'Example.psm1'
    ModuleVersion = '2.3.4'
    RequiredModules = @(
        @{ ModuleName = 'RuntimeDependency'; RequiredVersion = '3.0.0' }
    )
    PrivateData = @{
        PSData = @{
            Prerelease = '$Prerelease'
        }
    }
}
"@ | Set-Content -LiteralPath $manifestPath

        $requirementsPath = Join-Path -Path $Root -ChildPath 'build.requirements.psd1'
        @'
@(
    @{ ModuleName = 'ZetaBuild'; RequiredVersion = '2.0.0' }
    @{ ModuleName = 'AlphaBuild'; RequiredVersion = '1.0.0' }
)
'@ | Set-Content -LiteralPath $requirementsPath

        $packagePath = New-AtlassianPSVIIModulePackage `
            -BuildOutputPath $releasePath `
            -ModuleName 'Example'
        $result = New-AtlassianPSVIIReleaseProvenance `
            -PackagePath $packagePath `
            -ModuleManifestPath $manifestPath `
            -BuildRequirementsPath $requirementsPath `
            -Repository 'AtlassianPS/Example' `
            -CommitSha ('a' * 40) `
            -SourceRef 'refs/heads/master' `
            -RunId '12345' `
            -OutputPath $releasePath

        [PSCustomObject]@{
            ReleasePath      = $releasePath
            PackagePath      = $packagePath
            ManifestPath     = $manifestPath
            RequirementsPath = $requirementsPath
            Result           = $result
        }
    }
}

Describe 'Release provenance' {
    It 'writes deterministic checksums and a sorted dependency manifest' {
        $fixture = Initialize-ProvenanceFixture -Root (Join-Path -Path $TestDrive -ChildPath 'stable')
        $firstProvenance = Get-Content -LiteralPath $fixture.Result.ProvenancePath -Raw
        $firstDependencies = Get-Content -LiteralPath $fixture.Result.DependencyManifestPath -Raw
        $firstChecksums = Get-Content -LiteralPath $fixture.Result.ChecksumPath -Raw

        $null = New-AtlassianPSVIIReleaseProvenance `
            -PackagePath $fixture.PackagePath `
            -ModuleManifestPath $fixture.ManifestPath `
            -BuildRequirementsPath $fixture.RequirementsPath `
            -Repository 'AtlassianPS/Example' `
            -CommitSha ('a' * 40) `
            -SourceRef 'refs/heads/master' `
            -RunId '12345' `
            -OutputPath $fixture.ReleasePath

        (Get-Content -LiteralPath $fixture.Result.ProvenancePath -Raw) |
            Should -BeExactly $firstProvenance
        (Get-Content -LiteralPath $fixture.Result.DependencyManifestPath -Raw) |
            Should -BeExactly $firstDependencies
        (Get-Content -LiteralPath $fixture.Result.ChecksumPath -Raw) |
            Should -BeExactly $firstChecksums

        $dependencyManifest = $firstDependencies | ConvertFrom-Json
        @($dependencyManifest.Components.Name) | Should -Be @(
            'AlphaBuild'
            'ZetaBuild'
            'RuntimeDependency'
        )
        $firstProvenance | Should -Not -Match 'Generated|Timestamp|Created'
    }

    It 'verifies a matching artifact, commit, run, and stable release tag' {
        $fixture = Initialize-ProvenanceFixture -Root (Join-Path -Path $TestDrive -ChildPath 'valid')
        $attestationPath = Join-Path -Path $fixture.ReleasePath -ChildPath 'attestation.json'
        Set-Content -LiteralPath $attestationPath -Value '{}'

        $result = Test-AtlassianPSVIIReleaseProvenance `
            -ReleasePath $fixture.ReleasePath `
            -ExpectedRepository 'AtlassianPS/Example' `
            -ExpectedCommitSha ('a' * 40) `
            -ExpectedRunId '12345' `
            -ExpectedReleaseTag 'v2.3.4' `
            -AttestationPath $attestationPath `
            -RequireAttestation

        $result.IsValid | Should -BeTrue
        $result.ReleaseTag | Should -Be 'v2.3.4'
    }

    It 'rejects an altered package with a checksum mismatch' {
        $fixture = Initialize-ProvenanceFixture -Root (Join-Path -Path $TestDrive -ChildPath 'altered')
        Add-Content -LiteralPath $fixture.PackagePath -Value 'tampered'

        {
            Test-AtlassianPSVIIReleaseProvenance `
                -ReleasePath $fixture.ReleasePath `
                -ExpectedRepository 'AtlassianPS/Example' `
                -ExpectedCommitSha ('a' * 40) `
                -ExpectedRunId '12345' `
                -ExpectedReleaseTag 'v2.3.4'
        } | Should -Throw -ExpectedMessage "SHA256 checksum mismatch for 'Example.zip'."
    }

    It 'rejects a release when its attestation bundle is missing' {
        $fixture = Initialize-ProvenanceFixture -Root (Join-Path -Path $TestDrive -ChildPath 'missing-attestation')

        {
            Test-AtlassianPSVIIReleaseProvenance `
                -ReleasePath $fixture.ReleasePath `
                -ExpectedRepository 'AtlassianPS/Example' `
                -ExpectedCommitSha ('a' * 40) `
                -ExpectedRunId '12345' `
                -ExpectedReleaseTag 'v2.3.4' `
                -RequireAttestation
        } | Should -Throw -ExpectedMessage 'A GitHub artifact attestation bundle is required but was not found.'
    }

    It 'rejects artifact reuse from another commit' {
        $fixture = Initialize-ProvenanceFixture -Root (Join-Path -Path $TestDrive -ChildPath 'wrong-commit')

        {
            Test-AtlassianPSVIIReleaseProvenance `
                -ReleasePath $fixture.ReleasePath `
                -ExpectedRepository 'AtlassianPS/Example' `
                -ExpectedCommitSha ('b' * 40) `
                -ExpectedRunId '12345' `
                -ExpectedReleaseTag 'v2.3.4'
        } | Should -Throw -ExpectedMessage "Provenance commit*does not match expected*"
    }

    It 'accepts a matching prerelease tag and rejects a stable-tag substitution' {
        $fixture = Initialize-ProvenanceFixture `
            -Root (Join-Path -Path $TestDrive -ChildPath 'prerelease') `
            -Prerelease 'rc-2'

        $result = Test-AtlassianPSVIIReleaseProvenance `
            -ReleasePath $fixture.ReleasePath `
            -ExpectedRepository 'AtlassianPS/Example' `
            -ExpectedCommitSha ('a' * 40) `
            -ExpectedRunId '12345' `
            -ExpectedReleaseTag 'v2.3.4-rc-2'
        $result.ReleaseTag | Should -Be 'v2.3.4-rc-2'

        {
            Test-AtlassianPSVIIReleaseProvenance `
                -ReleasePath $fixture.ReleasePath `
                -ExpectedRepository 'AtlassianPS/Example' `
                -ExpectedCommitSha ('a' * 40) `
                -ExpectedRunId '12345' `
                -ExpectedReleaseTag 'v2.3.4'
        } | Should -Throw -ExpectedMessage "Provenance release tag 'v2.3.4-rc-2' does not match expected 'v2.3.4'."
    }
}
