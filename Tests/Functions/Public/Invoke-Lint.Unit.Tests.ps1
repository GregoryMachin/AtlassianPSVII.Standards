#requires -modules @{ ModuleName = "Pester"; ModuleVersion = "6.2"; MaximumVersion = "6.999" }

BeforeAll {
    . "$PSScriptRoot/../../Helpers/TestTools.ps1"

    $script:moduleToTest = Initialize-TestEnvironment
}

Describe 'Invoke-Lint' {
    It 'is exported by the module' {
        $lintCommand = Get-Command -Module 'AtlassianPSVII.Standards' |
            Where-Object { $_.CommandType -eq 'Function' -and $_.Verb -eq 'Invoke' -and $_.Name -like '*Lint' } |
            Select-Object -First 1

        $lintCommand | Should -Not -BeNullOrEmpty
    }

    It 'runs through the exported prefixed command' {
        $projectPath = Join-Path -Path $TestDrive -ChildPath 'project-exported-command'
        $modulePath = Join-Path -Path $projectPath -ChildPath 'AtlassianPSVII.Standards'
        $testsPath = Join-Path -Path $projectPath -ChildPath 'Tests'
        $toolsPath = Join-Path -Path $projectPath -ChildPath 'Tools'
        $stylePath = Join-Path -Path $testsPath -ChildPath 'Style.Tests.ps1'
        $settingsPath = Join-Path -Path $modulePath -ChildPath 'PSScriptAnalyzerSettings.psd1'
        $buildScriptPath = Join-Path -Path $projectPath -ChildPath 'AtlassianPSVII.Standards.build.ps1'

        $null = New-Item -Path $modulePath -ItemType Directory -Force
        $null = New-Item -Path $testsPath -ItemType Directory -Force
        $null = New-Item -Path $toolsPath -ItemType Directory -Force
        Set-Content -LiteralPath $stylePath -Value 'Describe "style" { It "passes" { $true | Should -BeTrue } }'
        Set-Content -LiteralPath $settingsPath -Value '@{ IncludeRules = @() }'
        Set-Content -LiteralPath $buildScriptPath -Value '$null = $true'

        $result = Invoke-AtlassianPSVIILint `
            -ProjectPath $projectPath `
            -ModulePath $modulePath `
            -BuildScriptPath $buildScriptPath `
            -AnalyzerSettingsPath $settingsPath `
            -AnalyzerPaths @($buildScriptPath) `
            -PesterVerbosity None

        $result.StyleFailedCount | Should -Be 0
        $result.AnalyzerIssueCount | Should -Be 0
    }

    It 'fails fast when Pester is below the minimum version' {
        $projectPath = Join-Path -Path $TestDrive -ChildPath 'project-old-pester'
        $modulePath = Join-Path -Path $projectPath -ChildPath 'AtlassianPSVII.Standards'
        $testsPath = Join-Path -Path $projectPath -ChildPath 'Tests'
        $stylePath = Join-Path -Path $testsPath -ChildPath 'Style.Tests.ps1'
        $settingsPath = Join-Path -Path $modulePath -ChildPath 'PSScriptAnalyzerSettings.psd1'
        $buildScriptPath = Join-Path -Path $projectPath -ChildPath 'AtlassianPSVII.Standards.build.ps1'

        $null = New-Item -Path $modulePath -ItemType Directory -Force
        $null = New-Item -Path $testsPath -ItemType Directory -Force
        Set-Content -LiteralPath $stylePath -Value 'Describe "style" { It "passes" { $true | Should -BeTrue } }'
        Set-Content -LiteralPath $settingsPath -Value '@{ IncludeRules = @() }'
        Set-Content -LiteralPath $buildScriptPath -Value '$null = $true'

        InModuleScope AtlassianPSVII.Standards -Parameters @{
            ProjectPath     = $projectPath
            ModulePath      = $modulePath
            BuildScriptPath = $buildScriptPath
            SettingsPath    = $settingsPath
        } {
            param($ProjectPath, $ModulePath, $BuildScriptPath, $SettingsPath)

            {
                Invoke-Lint -ProjectPath $ProjectPath -ModulePath $ModulePath -BuildScriptPath $BuildScriptPath -AnalyzerSettingsPath $SettingsPath -MinimumPesterVersion ([Version]'99.0.0')
            } | Should -Throw -ExpectedMessage "Pester version between 99.0.0 and * is required*"
        }
    }

    It 'does not pick an installed Pester newer than -MaximumPesterVersion' {
        # Regression (backlog PSVII-6): lint used to take the newest installed Pester with no
        # upper bound, so installing a new Pester major broke every build.
        $projectPath = Join-Path -Path $TestDrive -ChildPath 'project-newer-pester'
        $modulePath = Join-Path -Path $projectPath -ChildPath 'AtlassianPSVII.Standards'
        $testsPath = Join-Path -Path $projectPath -ChildPath 'Tests'
        $stylePath = Join-Path -Path $testsPath -ChildPath 'Style.Tests.ps1'
        $settingsPath = Join-Path -Path $modulePath -ChildPath 'PSScriptAnalyzerSettings.psd1'
        $buildScriptPath = Join-Path -Path $projectPath -ChildPath 'AtlassianPSVII.Standards.build.ps1'

        $null = New-Item -Path $modulePath -ItemType Directory -Force
        $null = New-Item -Path $testsPath -ItemType Directory -Force
        Set-Content -LiteralPath $stylePath -Value 'Describe "style" { It "passes" { $true | Should -BeTrue } }'
        Set-Content -LiteralPath $settingsPath -Value '@{ IncludeRules = @() }'
        Set-Content -LiteralPath $buildScriptPath -Value '$null = $true'

        InModuleScope AtlassianPSVII.Standards -Parameters @{
            ProjectPath     = $projectPath
            ModulePath      = $modulePath
            BuildScriptPath = $buildScriptPath
            SettingsPath    = $settingsPath
            RunningPester   = (Get-Module -Name 'Pester' | Sort-Object -Property Version -Descending | Select-Object -First 1).Version
        } {
            param($ProjectPath, $ModulePath, $BuildScriptPath, $SettingsPath, $RunningPester)

            # Pester 6 throws when no -ParameterFilter matches, so every other call goes to the real cmdlet.
            $realGetModule = Get-Command -Name Get-Module -CommandType Cmdlet
            Mock -CommandName Get-Module -MockWith { & $realGetModule @PesterBoundParameters }
            Mock -CommandName Get-Module -ParameterFilter { $ListAvailable -and $Name -eq 'Pester' } -MockWith {
                [PSCustomObject]@{ Name = 'Pester'; Version = [Version]'99.0.0' }
                [PSCustomObject]@{ Name = 'Pester'; Version = $RunningPester }
            }

            $result = Invoke-Lint -ProjectPath $ProjectPath -ModulePath $ModulePath -BuildScriptPath $BuildScriptPath -AnalyzerSettingsPath $SettingsPath -AnalyzerPaths @($BuildScriptPath) -PesterVerbosity None -MaximumPesterVersion ([Version]"$($RunningPester.Major).999")

            # Picking 99.0.0 would have tried to swap Pester out mid-run (and failed); instead the
            # running version was selected and kept.
            $result.StyleFailedCount | Should -Be 0
            @(& $realGetModule -Name 'Pester').Version | Should -Be @($RunningPester)
        }
    }

    It 'returns lint counts when style tests and analyzer pass' {
        $projectPath = Join-Path -Path $TestDrive -ChildPath 'project'
        $modulePath = Join-Path -Path $projectPath -ChildPath 'AtlassianPSVII.Standards'
        $testsPath = Join-Path -Path $projectPath -ChildPath 'Tests'
        $toolsPath = Join-Path -Path $projectPath -ChildPath 'Tools'
        $stylePath = Join-Path -Path $testsPath -ChildPath 'Style.Tests.ps1'
        $settingsPath = Join-Path -Path $modulePath -ChildPath 'PSScriptAnalyzerSettings.psd1'
        $buildScriptPath = Join-Path -Path $projectPath -ChildPath 'AtlassianPSVII.Standards.build.ps1'

        $null = New-Item -Path $modulePath -ItemType Directory -Force
        $null = New-Item -Path $testsPath -ItemType Directory -Force
        $null = New-Item -Path $toolsPath -ItemType Directory -Force
        Set-Content -LiteralPath $stylePath -Value 'Describe "style" { It "passes" { $true | Should -BeTrue } }'
        Set-Content -LiteralPath $settingsPath -Value '@{ IncludeRules = @() }'
        Set-Content -LiteralPath $buildScriptPath -Value '$null = $true'

        InModuleScope AtlassianPSVII.Standards -Parameters @{
            ProjectPath     = $projectPath
            ModulePath      = $modulePath
            BuildScriptPath = $buildScriptPath
            SettingsPath    = $settingsPath
        } {
            param($ProjectPath, $ModulePath, $BuildScriptPath, $SettingsPath)

            Mock -CommandName Invoke-Pester -MockWith {
                [PSCustomObject]@{ FailedCount = 0 }
            }
            Mock -CommandName Invoke-ScriptAnalyzer -MockWith { @() }

            $result = Invoke-Lint -ProjectPath $ProjectPath -ModulePath $ModulePath -BuildScriptPath $BuildScriptPath -AnalyzerSettingsPath $SettingsPath

            $result.StyleFailedCount | Should -Be 0
            $result.AnalyzerIssueCount | Should -Be 0
            $result.AnalyzerPathCount | Should -BeGreaterThan 0
        }
    }

    It 'aggregates style and analyzer failures into one error' {
        $originalGitHubActions = $env:GITHUB_ACTIONS
        $projectPath = Join-Path -Path $TestDrive -ChildPath 'project-failure'
        $modulePath = Join-Path -Path $projectPath -ChildPath 'AtlassianPSVII.Standards'
        $testsPath = Join-Path -Path $projectPath -ChildPath 'Tests'
        $stylePath = Join-Path -Path $testsPath -ChildPath 'Style.Tests.ps1'
        $settingsPath = Join-Path -Path $modulePath -ChildPath 'PSScriptAnalyzerSettings.psd1'
        $buildScriptPath = Join-Path -Path $projectPath -ChildPath 'AtlassianPSVII.Standards.build.ps1'

        $null = New-Item -Path $modulePath -ItemType Directory -Force
        $null = New-Item -Path $testsPath -ItemType Directory -Force
        Set-Content -LiteralPath $stylePath -Value 'Describe "style" { It "fails" { $false | Should -BeTrue } }'
        Set-Content -LiteralPath $settingsPath -Value '@{ IncludeRules = @() }'
        Set-Content -LiteralPath $buildScriptPath -Value '$null = $true'

        try {
            $env:GITHUB_ACTIONS = $null

            InModuleScope AtlassianPSVII.Standards -Parameters @{
                ProjectPath     = $projectPath
                ModulePath      = $modulePath
                BuildScriptPath = $buildScriptPath
                SettingsPath    = $settingsPath
            } {
                param($ProjectPath, $ModulePath, $BuildScriptPath, $SettingsPath)

                Mock -CommandName Invoke-Pester -MockWith {
                    [PSCustomObject]@{ FailedCount = 1 }
                }
                Mock -CommandName Invoke-ScriptAnalyzer -MockWith {
                    @(
                        [PSCustomObject]@{
                            Severity   = 'Warning'
                            ScriptName = 'AtlassianPSVII.Standards.build.ps1'
                            ScriptPath = $BuildScriptPath
                            Line       = 12
                            Column     = 4
                            RuleName   = 'PSRule'
                            Message    = 'Mock warning'
                        }
                    )
                }

                {
                    Invoke-Lint -ProjectPath $ProjectPath -ModulePath $ModulePath -BuildScriptPath $BuildScriptPath -AnalyzerSettingsPath $SettingsPath
                } | Should -Throw -ExpectedMessage "Lint failed:*style test(s) failed.*PSScriptAnalyzer issue(s) found.*"
            }
        }
        finally {
            $env:GITHUB_ACTIONS = $originalGitHubActions
        }
    }
}
