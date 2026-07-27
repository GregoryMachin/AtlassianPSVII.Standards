#requires -modules @{ ModuleName = "Pester"; ModuleVersion = "5.7"; MaximumVersion = "5.999" }

BeforeAll {
    $script:runnerPath = Join-Path -Path $PSScriptRoot -ChildPath '../../Tools/test.downstream.compatibility.ps1'
    . $script:runnerPath

    function New-TestStandardsCandidate {
        [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions',
            '',
            Justification = 'Creates isolated Pester TestDrive fixtures only.'
        )]
        param(
            [Parameter(Mandatory)]
            [String]$Path
        )

        $null = New-Item -Path $Path -ItemType Directory -Force
        $modulePath = Join-Path -Path $Path -ChildPath 'AtlassianPS.Standards.psm1'
        $manifestPath = Join-Path -Path $Path -ChildPath 'AtlassianPS.Standards.psd1'
        Set-Content -LiteralPath $modulePath -Value 'function Get-CandidateMarker { ''candidate'' }'
        New-ModuleManifest `
            -Path $manifestPath `
            -RootModule 'AtlassianPS.Standards.psm1' `
            -ModuleVersion '9.9.9' `
            -Guid 'c569c2c6-ed21-4d00-9b4e-14bd466cad81' `
            -Author 'AtlassianPS' `
            -Description 'Candidate fixture.'

        return $Path
    }

    function New-TestDownstreamRepository {
        [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions',
            '',
            Justification = 'Creates isolated Pester TestDrive fixtures only.'
        )]
        param(
            [Parameter(Mandatory)]
            [String]$WorkspaceRoot,

            [Parameter(Mandatory)]
            [ValidateSet('AtlassianPS.Configuration', 'JiraPS', 'JiraAgilePS', 'ConfluencePS')]
            [String]$Name,

            [Parameter()]
            [String]$RequiredVersion = '0.1.11'
        )

        $resolvedTestDrive = [IO.Path]::GetFullPath($TestDrive).TrimEnd(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar
        ) + [IO.Path]::DirectorySeparatorChar
        $resolvedWorkspaceRoot = [IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar
        ) + [IO.Path]::DirectorySeparatorChar
        if (-not $resolvedWorkspaceRoot.StartsWith(
                $resolvedTestDrive,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw "Refusing to create a fixture outside Pester TestDrive: '$resolvedWorkspaceRoot'."
        }

        $repositoryPath = Join-Path -Path $WorkspaceRoot -ChildPath $Name
        $toolsPath = Join-Path -Path $repositoryPath -ChildPath 'Tools'
        $null = New-Item -Path $toolsPath -ItemType Directory -Force
        Set-Content `
            -LiteralPath (Join-Path -Path $repositoryPath -ChildPath "$Name.build.ps1") `
            -Value "task . { 'validated' }"
        Set-Content `
            -LiteralPath (Join-Path -Path $toolsPath -ChildPath 'build.requirements.psd1') `
            -Value "@(@{ ModuleName = 'AtlassianPS.Standards'; RequiredVersion = '$RequiredVersion' })"

        return $repositoryPath
    }

    function Get-PassedProcessResult {
        [PSCustomObject]@{
            Status         = 'Passed'
            ExitCode       = 0
            Duration       = [TimeSpan]::FromSeconds(1)
            StandardOutput = 'passed'
            StandardError  = ''
        }
    }
}

Describe 'Downstream compatibility candidate resolution' -Tag Unit {
    It 'resolves a candidate module directory' {
        $candidatePath = New-TestStandardsCandidate -Path (Join-Path $TestDrive 'candidate')

        $candidate = Resolve-StandardsCandidateModule -Path $candidatePath

        $candidate.ModuleRoot | Should -Be (Resolve-Path $candidatePath).ProviderPath
        $candidate.ModuleVersion | Should -Be ([Version]'9.9.9')
        $candidate.ManifestPath | Should -Be (Join-Path $candidate.ModuleRoot 'AtlassianPS.Standards.psd1')
    }

    It 'resolves an artifact root containing the module directory' {
        $artifactRoot = Join-Path $TestDrive 'artifact'
        $candidatePath = New-TestStandardsCandidate -Path (
            Join-Path $artifactRoot 'AtlassianPS.Standards'
        )

        $candidate = Resolve-StandardsCandidateModule -Path $artifactRoot

        $candidate.ModuleRoot | Should -Be (Resolve-Path $candidatePath).ProviderPath
    }

    It 'fails clearly when the candidate does not exist' {
        {
            Resolve-StandardsCandidateModule -Path (Join-Path $TestDrive 'missing-candidate')
        } | Should -Throw -ExpectedMessage "Candidate Standards path*does not exist."
    }
}

Describe 'Downstream repository discovery' -Tag Unit {
    It 'discovers only the allow-listed build entrypoint in a path containing spaces' {
        $workspaceRoot = Join-Path $TestDrive 'workspace with spaces'
        $repositoryPath = New-TestDownstreamRepository `
            -WorkspaceRoot $workspaceRoot `
            -Name 'JiraPS'
        Set-Content -LiteralPath (Join-Path $repositoryPath 'untrusted.ps1') -Value "throw 'must not run'"

        $repository = Get-AllowedDownstreamRepository `
            -WorkspaceRoot $workspaceRoot `
            -Name 'JiraPS'

        $repository.Exists | Should -BeTrue
        $repository.RepositoryPath | Should -Be (Resolve-Path $repositoryPath).ProviderPath
        $repository.BuildScriptPath | Should -Be (
            Join-Path $repository.RepositoryPath 'JiraPS.build.ps1'
        )
        $repository.BuildScriptPath | Should -Not -Match 'untrusted'
    }

    It 'returns a missing record without searching for another script' {
        $workspaceRoot = Join-Path $TestDrive 'partial-workspace'
        $null = New-Item -Path $workspaceRoot -ItemType Directory

        $repository = Get-AllowedDownstreamRepository `
            -WorkspaceRoot $workspaceRoot `
            -Name 'ConfluencePS'

        $repository.Exists | Should -BeFalse
        $repository.BuildScriptPath | Should -Match 'ConfluencePS\.build\.ps1$'
    }

    It 'rejects repository names outside the allow-list' {
        $workspaceRoot = Join-Path $TestDrive 'allowed-workspace'
        $null = New-Item -Path $workspaceRoot -ItemType Directory

        {
            Get-AllowedDownstreamRepository -WorkspaceRoot $workspaceRoot -Name 'UntrustedRepo'
        } | Should -Throw
    }
}

Describe 'Downstream compatibility orchestration' -Tag Unit {
    It 'runs every repository and aggregates failures after the final repository' {
        $candidatePath = New-TestStandardsCandidate -Path (
            Join-Path $TestDrive ('candidate with spaces {0}' -f [Guid]::NewGuid().ToString('N'))
        )
        $workspaceRoot = Join-Path $TestDrive (
            'downstream workspace with spaces {0}' -f [Guid]::NewGuid().ToString('N')
        )

        foreach ($name in @(
                'AtlassianPS.Configuration',
                'JiraPS',
                'JiraAgilePS',
                'ConfluencePS'
            )) {
            $null = New-TestDownstreamRepository -WorkspaceRoot $workspaceRoot -Name $name
        }

        Mock Invoke-DownstreamValidationProcess {
            if ((Split-Path -Path $RepositoryPath -Leaf) -eq 'JiraPS') {
                return [PSCustomObject]@{
                    Status         = 'Failed'
                    ExitCode       = 7
                    Duration       = [TimeSpan]::FromSeconds(1)
                    StandardOutput = ''
                    StandardError  = 'test failure'
                }
            }
            Get-PassedProcessResult
        }

        {
            Invoke-DownstreamCompatibility `
                -CandidateModulePath $candidatePath `
                -WorkspaceRoot $workspaceRoot `
                -PowerShellPath (Get-Process -Id $PID).Path
        } | Should -Throw -ExpectedMessage '*JiraPS (Failed, exit 7)*'

        Should -Invoke Invoke-DownstreamValidationProcess -Exactly -Times 4
    }

    It 'reports a missing repository after validating repositories that are present' {
        $candidatePath = New-TestStandardsCandidate -Path (
            Join-Path $TestDrive ('candidate with spaces {0}' -f [Guid]::NewGuid().ToString('N'))
        )
        $workspaceRoot = Join-Path $TestDrive (
            'downstream workspace with spaces {0}' -f [Guid]::NewGuid().ToString('N')
        )
        $null = New-TestDownstreamRepository -WorkspaceRoot $workspaceRoot -Name 'JiraPS'
        Mock Invoke-DownstreamValidationProcess { Get-PassedProcessResult }

        {
            Invoke-DownstreamCompatibility `
                -CandidateModulePath $candidatePath `
                -WorkspaceRoot $workspaceRoot `
                -RepositoryName @('JiraPS', 'ConfluencePS') `
                -PowerShellPath (Get-Process -Id $PID).Path
        } | Should -Throw -ExpectedMessage '*ConfluencePS (Missing*'

        Should -Invoke Invoke-DownstreamValidationProcess -Exactly -Times 1
    }

    It 'can skip missing repositories explicitly' {
        $candidatePath = New-TestStandardsCandidate -Path (
            Join-Path $TestDrive ('candidate with spaces {0}' -f [Guid]::NewGuid().ToString('N'))
        )
        $workspaceRoot = Join-Path $TestDrive (
            'downstream workspace with spaces {0}' -f [Guid]::NewGuid().ToString('N')
        )
        $null = New-TestDownstreamRepository -WorkspaceRoot $workspaceRoot -Name 'JiraPS'
        Mock Invoke-DownstreamValidationProcess { Get-PassedProcessResult }

        $results = @(
            Invoke-DownstreamCompatibility `
                -CandidateModulePath $candidatePath `
                -WorkspaceRoot $workspaceRoot `
                -RepositoryName @('JiraPS', 'ConfluencePS') `
                -PowerShellPath (Get-Process -Id $PID).Path `
                -SkipMissingRepository
        )

        $results.Status | Should -Be @('Passed', 'Skipped')
    }

    It 'passes exact paths containing spaces and the pinned candidate version' {
        $candidatePath = New-TestStandardsCandidate -Path (
            Join-Path $TestDrive ('candidate with spaces {0}' -f [Guid]::NewGuid().ToString('N'))
        )
        $workspaceRoot = Join-Path $TestDrive (
            'downstream workspace with spaces {0}' -f [Guid]::NewGuid().ToString('N')
        )
        $repositoryPath = New-TestDownstreamRepository `
            -WorkspaceRoot $workspaceRoot `
            -Name 'JiraAgilePS' `
            -RequiredVersion '0.1.2'
        Mock Invoke-DownstreamValidationProcess { Get-PassedProcessResult }

        $result = Invoke-DownstreamCompatibility `
            -CandidateModulePath $candidatePath `
            -WorkspaceRoot $workspaceRoot `
            -RepositoryName 'JiraAgilePS' `
            -PowerShellPath (Get-Process -Id $PID).Path

        $result.Status | Should -Be 'Passed'
        $result.RequiredVersion | Should -Be ([Version]'0.1.2')
        Should -Invoke Invoke-DownstreamValidationProcess -Exactly -Times 1 -ParameterFilter {
            $RepositoryPath -eq (Resolve-Path $repositoryPath).ProviderPath -and
            $BuildScriptPath -eq (Join-Path (Resolve-Path $repositoryPath).ProviderPath 'JiraAgilePS.build.ps1')
        }
    }
}

Describe 'Downstream process security boundary' -Tag Unit {
    It 'uses an environment allow-list and does not forward secrets' {
        $originalToken = $env:ATLASSIAN_TOKEN
        try {
            $env:ATLASSIAN_TOKEN = 'must-not-be-forwarded'
            $candidateRoot = Join-Path $TestDrive 'module-overlay'

            $environment = Get-DownstreamSafeEnvironment -CandidateModuleRoot $candidateRoot

            $environment.Keys | Should -Not -Contain 'ATLASSIAN_TOKEN'
            $environment.Keys | Should -Not -Contain 'CI_CONFLUENCE_TOKEN'
            $environment.PSModulePath.Split([IO.Path]::PathSeparator)[0] |
                Should -Be $candidateRoot
        }
        finally {
            $env:ATLASSIAN_TOKEN = $originalToken
        }
    }

    It 'redacts sensitive headers and secret assignments in captured output' {
        $output = @'
Authorization: Bearer example-value
Cookie: session=example-value
token=example-value
ordinary output
'@

        $protected = Protect-DownstreamOutput -Text $output

        $protected | Should -Not -Match 'example-value'
        $protected | Should -Match 'Authorization: \[REDACTED\]'
        $protected | Should -Match 'ordinary output'
    }
}
