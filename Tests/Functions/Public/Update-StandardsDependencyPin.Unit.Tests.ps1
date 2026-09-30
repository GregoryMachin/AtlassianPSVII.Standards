#requires -modules @{ ModuleName = "Pester"; ModuleVersion = "6.2"; MaximumVersion = "6.999" }

BeforeAll {
    . "$PSScriptRoot/../../Helpers/TestTools.ps1"
    $script:moduleToTest = Initialize-TestEnvironment

    function New-StandardsPinRepositoryFixture {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions',
            '',
            Justification = 'Creates files only inside the Pester TestDrive.'
        )]
        param(
            [Parameter(Mandatory)]
            [String]$Path,

            [Parameter()]
            [String]$Version = '0.1.11',

            [Parameter()]
            [String]$CommitSha = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',

            [Parameter()]
            [Int32]$WorkflowCount = 1,

            [Parameter()]
            [Switch]$OmitRequirement,

            [Parameter()]
            [Switch]$OmitActionPin,

            [Parameter()]
            [String]$ActionCoordinate = 'AtlassianPS/AtlassianPS.Standards/.github/actions/setup-powershell'
        )

        $resolvedTestDrive = [IO.Path]::GetFullPath($TestDrive).TrimEnd(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar
        ) + [IO.Path]::DirectorySeparatorChar
        $resolvedFixture = [IO.Path]::GetFullPath($Path).TrimEnd(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar
        ) + [IO.Path]::DirectorySeparatorChar
        if (-not $resolvedFixture.StartsWith(
                $resolvedTestDrive,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw "Refusing to create fixture outside TestDrive: '$resolvedFixture'."
        }

        $toolsPath = Join-Path -Path $Path -ChildPath 'Tools'
        $workflowRoot = Join-Path -Path $Path -ChildPath '.github/workflows'
        $null = New-Item -Path $toolsPath, $workflowRoot -ItemType Directory -Force

        $requirements = if ($OmitRequirement) {
            '@(@{ ModuleName = "InvokeBuild"; RequiredVersion = "5.14.23" })'
        }
        else {
            "@(@{ ModuleName = `"AtlassianPSVII.Standards`"; RequiredVersion = `"$Version`" })"
        }
        $requirementsPath = Join-Path -Path $toolsPath -ChildPath 'build.requirements.psd1'
        Set-Content -LiteralPath $requirementsPath -Value $requirements

        $workflowPaths = [Collections.Generic.List[String]]::new()
        for ($index = 1; $index -le $WorkflowCount; $index++) {
            $extension = if ($index % 2 -eq 0) { '.yaml' } else { '.yml' }
            $workflowPath = Join-Path -Path $workflowRoot -ChildPath "workflow-$index$extension"
            $workflowContent = if ($OmitActionPin) {
                "name: workflow-$index"
            }
            else {
                @"
name: workflow-$index
steps:
  - uses: $ActionCoordinate@$CommitSha # v$Version
"@
            }
            Set-Content -LiteralPath $workflowPath -Value $workflowContent
            $workflowPaths.Add($workflowPath)
        }

        return [PSCustomObject]@{
            Root             = $Path
            RequirementsPath = $requirementsPath
            WorkflowPath     = @($workflowPaths)
        }
    }
}

Describe 'Update-StandardsDependencyPin' {
    BeforeEach {
        InModuleScope AtlassianPSVII.Standards {
            Mock -CommandName Find-Module -MockWith {
                [PSCustomObject]@{ Version = [Version]'0.1.12' }
            }
            Mock -CommandName Invoke-RestMethod -MockWith {
                [PSCustomObject]@{
                    object = [PSCustomObject]@{
                        type = 'commit'
                        sha  = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
                    }
                }
            }
        }
    }

    It 'is exported with comment-based help' {
        $command = Get-Command -Name 'Update-AtlassianPSVIIStandardsDependencyPin' -ErrorAction Stop
        $command | Should -Not -BeNullOrEmpty
        (Get-Help -Name $command.Name).Synopsis | Should -Not -BeNullOrEmpty
    }

    It 'atomically updates the dependency and every workflow pin' {
        $fixture = New-StandardsPinRepositoryFixture `
            -Path (Join-Path $TestDrive 'repository with spaces') `
            -WorkflowCount 2

        $result = Update-AtlassianPSVIIStandardsDependencyPin `
            -RepositoryRoot $fixture.Root `
            -Version '0.1.12' `
            -SetupActionCommitSha 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

        $result.Applied | Should -BeTrue
        $result.ChangedFileCount | Should -Be 3
        $result.SetupActionPinCount | Should -Be 2
        (Get-Content -LiteralPath $fixture.RequirementsPath -Raw) |
            Should -Match 'RequiredVersion = "0.1.12"'
        foreach ($workflowPath in $fixture.WorkflowPath) {
            (Get-Content -LiteralPath $workflowPath -Raw) |
                Should -Match '@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v0\.1\.12'
        }
    }

    It 'supports WhatIf without changing either pin' {
        $fixture = New-StandardsPinRepositoryFixture -Path (Join-Path $TestDrive 'whatif')
        $beforeRequirement = Get-Content -LiteralPath $fixture.RequirementsPath -Raw
        $beforeWorkflow = Get-Content -LiteralPath $fixture.WorkflowPath[0] -Raw

        $result = Update-AtlassianPSVIIStandardsDependencyPin `
            -RepositoryRoot $fixture.Root `
            -Version '0.1.12' `
            -WhatIf

        $result.Changed | Should -BeTrue
        $result.Applied | Should -BeFalse
        (Get-Content -LiteralPath $fixture.RequirementsPath -Raw) | Should -Be $beforeRequirement
        (Get-Content -LiteralPath $fixture.WorkflowPath[0] -Raw) | Should -Be $beforeWorkflow
    }

    It 'returns a no-op when the dependency and workflows already match' {
        $fixture = New-StandardsPinRepositoryFixture `
            -Path (Join-Path $TestDrive 'current') `
            -Version '0.1.12' `
            -CommitSha 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' `
            -WorkflowCount 2

        $result = Update-AtlassianPSVIIStandardsDependencyPin `
            -RepositoryRoot $fixture.Root `
            -Version '0.1.12'

        $result.Changed | Should -BeFalse
        $result.Applied | Should -BeFalse
        $result.ChangedFileCount | Should -Be 0
    }

    It 'fails when the Standards dependency pin is missing' {
        $fixture = New-StandardsPinRepositoryFixture `
            -Path (Join-Path $TestDrive 'missing requirement') `
            -OmitRequirement

        {
            Update-AtlassianPSVIIStandardsDependencyPin `
                -RepositoryRoot $fixture.Root `
                -Version '0.1.12'
        } | Should -Throw -ExpectedMessage '*Expected exactly one*requirement*found 0*'
    }

    It 'fails when no trusted workflow pin exists' {
        $fixture = New-StandardsPinRepositoryFixture `
            -Path (Join-Path $TestDrive 'missing workflow pin') `
            -OmitActionPin

        {
            Update-AtlassianPSVIIStandardsDependencyPin `
                -RepositoryRoot $fixture.Root `
                -Version '0.1.12'
        } | Should -Throw -ExpectedMessage '*No trusted*setup-powershell*commit pins*'
    }

    It 'rejects invalid stable versions before lookup' {
        $fixture = New-StandardsPinRepositoryFixture -Path (Join-Path $TestDrive 'invalid version')

        {
            Update-AtlassianPSVIIStandardsDependencyPin `
                -RepositoryRoot $fixture.Root `
                -Version 'latest'
        } | Should -Throw -ExpectedMessage '*Invalid AtlassianPSVII.Standards version*'

        InModuleScope AtlassianPSVII.Standards {
            Should -Invoke -CommandName Find-Module -Times 0
        }
    }

    It 'fails without changing files when the trusted tag lookup fails' {
        $fixture = New-StandardsPinRepositoryFixture -Path (Join-Path $TestDrive 'lookup failure')
        $beforeRequirement = Get-Content -LiteralPath $fixture.RequirementsPath -Raw
        InModuleScope AtlassianPSVII.Standards {
            Mock -CommandName Invoke-RestMethod -MockWith {
                throw 'simulated tag lookup failure'
            }
        }

        {
            Update-AtlassianPSVIIStandardsDependencyPin `
                -RepositoryRoot $fixture.Root `
                -Version '0.1.12'
        } | Should -Throw -ExpectedMessage '*Unable to resolve trusted GitHub tag*'

        (Get-Content -LiteralPath $fixture.RequirementsPath -Raw) | Should -Be $beforeRequirement
    }

    It 'fails without calling GitHub when the trusted package lookup fails' {
        $fixture = New-StandardsPinRepositoryFixture -Path (Join-Path $TestDrive 'package lookup failure')
        InModuleScope AtlassianPSVII.Standards {
            Mock -CommandName Find-Module -MockWith {
                throw 'simulated package lookup failure'
            }
        }

        {
            Update-AtlassianPSVIIStandardsDependencyPin `
                -RepositoryRoot $fixture.Root `
                -Version '0.1.12'
        } | Should -Throw -ExpectedMessage '*Unable to resolve trusted PSGallery package*'

        InModuleScope AtlassianPSVII.Standards {
            Should -Invoke -CommandName Invoke-RestMethod -Times 0
        }
    }

    It 'fails when the approved SHA does not match the trusted tag' {
        $fixture = New-StandardsPinRepositoryFixture -Path (Join-Path $TestDrive 'sha mismatch')

        {
            Update-AtlassianPSVIIStandardsDependencyPin `
                -RepositoryRoot $fixture.Root `
                -Version '0.1.12' `
                -SetupActionCommitSha 'cccccccccccccccccccccccccccccccccccccccc'
        } | Should -Throw -ExpectedMessage '*does not match trusted tag*'
    }

    It 'rolls back the requirements file when a workflow replacement fails' {
        $fixture = New-StandardsPinRepositoryFixture -Path (Join-Path $TestDrive 'rollback')
        $beforeRequirement = Get-Content -LiteralPath $fixture.RequirementsPath -Raw
        $beforeWorkflow = Get-Content -LiteralPath $fixture.WorkflowPath[0] -Raw

        InModuleScope AtlassianPSVII.Standards -Parameters @{
            RepositoryRoot = $fixture.Root
        } {
            param($RepositoryRoot)

            Mock -CommandName Set-AtomicTextFile -MockWith {
                param($File)

                if ([IO.Path]::GetExtension($File.DestinationPath) -in @('.yml', '.yaml')) {
                    throw 'simulated workflow write failure'
                }
                [IO.File]::Replace($File.StagedPath, $File.DestinationPath, $File.BackupPath)
            }

            {
                Update-StandardsDependencyPin `
                    -RepositoryRoot $RepositoryRoot `
                    -Version '0.1.12'
            } | Should -Throw -ExpectedMessage '*completed files were rolled back*'
        }

        (Get-Content -LiteralPath $fixture.RequirementsPath -Raw) | Should -Be $beforeRequirement
        (Get-Content -LiteralPath $fixture.WorkflowPath[0] -Raw) | Should -Be $beforeWorkflow
    }

    It 'rejects untrusted setup action coordinates' {
        $fixture = New-StandardsPinRepositoryFixture `
            -Path (Join-Path $TestDrive 'untrusted action') `
            -ActionCoordinate 'example/Untrusted/.github/actions/setup-powershell'

        {
            Update-AtlassianPSVIIStandardsDependencyPin `
                -RepositoryRoot $fixture.Root `
                -Version '0.1.12'
        } | Should -Throw -ExpectedMessage '*Untrusted setup action coordinate*'
    }
}
