#requires -modules @{ ModuleName = "Pester"; ModuleVersion = "6.2"; MaximumVersion = "6.999" }

BeforeAll {
    . "$PSScriptRoot/../../Helpers/TestTools.ps1"
    $script:moduleToTest = Initialize-TestEnvironment
}

Describe 'Write-BuildInfo' {
    It 'writes formatted lines when Write-Build is unavailable' {
        InModuleScope AtlassianPSVII.Standards {
            Mock -CommandName Get-Command -MockWith { $null } -ParameterFilter { $Name -eq 'Write-Build' }

            $buildInfo = [PSCustomObject]@{
                BuildSystem       = 'Local'
                ProjectName       = 'AtlassianPSVII.Standards'
                ProjectPath       = '/tmp/project'
                ModulePath        = '/tmp/project/AtlassianPSVII.Standards'
                ModuleManifest    = '/tmp/project/AtlassianPSVII.Standards/AtlassianPSVII.Standards.psd1'
                BuildOutputPath   = '/tmp/project/Release'
                BuiltManifestPath = '/tmp/project/Release/AtlassianPSVII.Standards/AtlassianPSVII.Standards.psd1'
                BranchName        = 'main'
                CommitHash        = 'abc123'
                CommitMessage     = 'test'
                BuildNumber       = '1'
                VersionToPublish  = '1.0.0'
                OS                = 'Linux'
                OSVersion         = '1.0'
            }

            $output = @(Write-BuildInfo -BuildInfo $buildInfo)
            ($output -join "`n") | Should -Match 'BHProjectName:\s+AtlassianPSVII\.Standards'
        }
    }

    It 'uses Write-Build when it is available' {
        InModuleScope AtlassianPSVII.Standards {
            function Write-Build {
                param(
                    [string]$Color,
                    [string]$Message
                )
            }
            Mock -CommandName Write-Build -MockWith {}

            $buildInfo = [PSCustomObject]@{
                BuildSystem       = 'Local'
                ProjectName       = 'AtlassianPSVII.Standards'
                ProjectPath       = '/tmp/project'
                ModulePath        = '/tmp/project/AtlassianPSVII.Standards'
                ModuleManifest    = '/tmp/project/AtlassianPSVII.Standards/AtlassianPSVII.Standards.psd1'
                BuildOutputPath   = '/tmp/project/Release'
                BuiltManifestPath = '/tmp/project/Release/AtlassianPSVII.Standards/AtlassianPSVII.Standards.psd1'
                BranchName        = 'main'
                CommitHash        = 'abc123'
                CommitMessage     = 'test'
                BuildNumber       = '1'
                VersionToPublish  = '1.0.0'
                OS                = 'Linux'
                OSVersion         = '1.0'
            }

            $null = Write-BuildInfo -BuildInfo $buildInfo

            Should -Invoke -CommandName Write-Build -Scope It
        }
    }

    It 'resolves build info when BuildInfo is not provided' {
        InModuleScope AtlassianPSVII.Standards {
            Mock -CommandName Get-Command -MockWith { $null } -ParameterFilter { $Name -eq 'Write-Build' }
            Mock -CommandName Get-BuildEnvironmentInfo -MockWith {
                [PSCustomObject]@{
                    BuildSystem       = 'Local'
                    ProjectName       = 'AtlassianPSVII.Standards'
                    ProjectPath       = '/tmp/project'
                    ModulePath        = '/tmp/project/AtlassianPSVII.Standards'
                    ModuleManifest    = '/tmp/project/AtlassianPSVII.Standards/AtlassianPSVII.Standards.psd1'
                    BuildOutputPath   = '/tmp/project/Release'
                    BuiltManifestPath = '/tmp/project/Release/AtlassianPSVII.Standards/AtlassianPSVII.Standards.psd1'
                    BranchName        = 'main'
                    CommitHash        = 'abc123'
                    CommitMessage     = 'test'
                    BuildNumber       = '1'
                    VersionToPublish  = '1.0.0'
                    OS                = 'Linux'
                    OSVersion         = '1.0'
                }
            }

            $null = @(Write-BuildInfo -VersionToPublish 'v1.0.0')

            Should -Invoke -CommandName Get-BuildEnvironmentInfo -Times 1 -Exactly -Scope It
        }
    }
}
