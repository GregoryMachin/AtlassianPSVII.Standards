#requires -modules @{ ModuleName = "Pester"; ModuleVersion = "6.2"; MaximumVersion = "6.999" }

BeforeAll {
    . "$PSScriptRoot/../../Helpers/TestTools.ps1"
    $script:moduleToTest = Initialize-TestEnvironment
}

Describe 'Get-BuildEnvironmentInfo' {
    It 'normalizes version input and builds manifest path from BH env vars' {
        InModuleScope AtlassianPSVII.Standards {
            $env:BHBuildSystem = 'Local'
            $env:BHProjectName = 'AtlassianPSVII.Standards'
            $env:BHProjectPath = '/tmp/project'
            $env:BHModulePath = '/tmp/project/AtlassianPSVII.Standards'
            $env:BHPSModuleManifest = '/tmp/project/AtlassianPSVII.Standards/AtlassianPSVII.Standards.psd1'
            $env:BHBuildOutput = '/tmp/project/Release'
            $env:BHBranchName = 'feature/test'
            $env:BHCommitHash = 'abc123'
            $env:BHCommitMessage = 'test'
            $env:BHBuildNumber = '1'

            Mock -CommandName Get-HostPlatformInfo -MockWith {
                [PSCustomObject]@{
                    OS        = 'Linux'
                    OSVersion = '1.0'
                }
            }

            $info = Get-BuildEnvironmentInfo -VersionToPublish 'v1.2.3'

            $info.VersionToPublish | Should -Be '1.2.3'
            $expectedBuiltManifestPath = Join-Path -Path (Join-Path -Path $env:BHBuildOutput -ChildPath $env:BHProjectName) -ChildPath "$($env:BHProjectName).psd1"
            $info.BuiltManifestPath | Should -Be $expectedBuiltManifestPath
            $info.OS | Should -Be 'Linux'
        }
    }

    It 'returns null built manifest path when build output data is missing' {
        InModuleScope AtlassianPSVII.Standards {
            $env:BHBuildOutput = $null
            $env:BHProjectName = $null

            Mock -CommandName Get-HostPlatformInfo -MockWith {
                [PSCustomObject]@{
                    OS        = 'Linux'
                    OSVersion = '1.0'
                }
            }

            $info = Get-BuildEnvironmentInfo

            $info.BuiltManifestPath | Should -Be $null
        }
    }
}

Describe 'Initialize-BuildEnvironment' {
    It 'sets BH environment variables and returns build info' {
        $projectRoot = Join-Path -Path $TestDrive -ChildPath 'project'
        $null = New-Item -Path $projectRoot -ItemType Directory -Force

        InModuleScope AtlassianPSVII.Standards -Parameters @{
            ProjectName = 'AtlassianPSVII.Standards'
            ProjectPath = $projectRoot
        } {
            param($ProjectName, $ProjectPath)

            Mock -CommandName Get-BuildEnvironmentMetadata -MockWith {
                [PSCustomObject]@{
                    BuildSystem   = 'Unknown'
                    BranchName    = 'main'
                    CommitHash    = 'deadbeef'
                    BuildNumber   = '0'
                    CommitMessage = 'msg'
                }
            }

            Mock -CommandName Get-BuildEnvironmentInfo -MockWith {
                [PSCustomObject]@{
                    ProjectName     = $env:BHProjectName
                    BuildOutputPath = $env:BHBuildOutput
                }
            }

            $result = Initialize-BuildEnvironment -ProjectName $ProjectName -ProjectPath $ProjectPath -BuildOutputFolder 'out'

            $env:BHProjectName | Should -Be 'AtlassianPSVII.Standards'
            $env:BHProjectPath | Should -Be (Resolve-Path -LiteralPath $ProjectPath).ProviderPath
            $env:BHBuildOutput | Should -Be (Join-Path -Path $env:BHProjectPath -ChildPath 'out')
            $result.ProjectName | Should -Be 'AtlassianPSVII.Standards'
        }
    }

    It 'resets pre-existing BH variables when requested' {
        $projectRoot = Join-Path -Path $TestDrive -ChildPath 'project-reset'
        $null = New-Item -Path $projectRoot -ItemType Directory -Force

        InModuleScope AtlassianPSVII.Standards -Parameters @{
            ProjectPath = $projectRoot
        } {
            param($ProjectPath)

            $env:BHStaleVariable = 'stale'

            Mock -CommandName Get-BuildEnvironmentMetadata -MockWith {
                [PSCustomObject]@{
                    BuildSystem   = 'Unknown'
                    BranchName    = 'main'
                    CommitHash    = 'deadbeef'
                    BuildNumber   = '0'
                    CommitMessage = 'msg'
                }
            }
            Mock -CommandName Get-BuildEnvironmentInfo -MockWith { [PSCustomObject]@{} }

            $null = Initialize-BuildEnvironment -ProjectName 'AtlassianPSVII.Standards' -ProjectPath $ProjectPath -ResetBuildEnvironmentVariables

            $env:BHStaleVariable | Should -BeNullOrEmpty
        }
    }
}
