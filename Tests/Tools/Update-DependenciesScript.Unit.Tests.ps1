#requires -modules @{ ModuleName = "Pester"; ModuleVersion = "6.2"; MaximumVersion = "6.999" }

BeforeAll {
    . "$PSScriptRoot/../Helpers/TestTools.ps1"
}

Describe 'Tools/update.dependencies.ps1' {
    AfterEach {
        Get-Module -Name 'AtlassianPSVII.Standards' |
            Where-Object { $_.ModuleBase -like "$TestDrive*" } |
            Remove-Module -Force -ErrorAction SilentlyContinue
    }

    It 'invokes shared updater with expected default paths and switches' {
        $harness = Initialize-ToolScriptHarness -ScriptRelativePath 'Tools/update.dependencies.ps1' -ModuleContent @'
function Update-DependencyReference {
    [CmdletBinding()]
    param(
        [String]$BuildRequirementsPath,
        [String]$ManifestPath,
        [Switch]$SkipBuildRequirement,
        [Switch]$SkipManifestRequirement
    )

    [PSCustomObject]@{
        BuildRequirementsPath  = $BuildRequirementsPath
        ManifestPath           = $ManifestPath
        SkipBuildRequirement   = [Boolean]$SkipBuildRequirement
        SkipManifestRequirement = [Boolean]$SkipManifestRequirement
    }
}

Export-ModuleMember -Function Update-DependencyReference
'@

        $result = & $harness.ScriptPath -SkipBuildRequirement -SkipManifestRequirement

        $result.BuildRequirementsPath | Should -Be (Join-Path -Path $harness.Root -ChildPath 'Tools/build.requirements.psd1')
        $result.ManifestPath | Should -Be (Join-Path -Path $harness.Root -ChildPath 'AtlassianPSVII.Standards/AtlassianPSVII.Standards.psd1')
        $result.SkipBuildRequirement | Should -BeTrue
        $result.SkipManifestRequirement | Should -BeTrue
    }

    It 'fails fast when shared updater emits a non-terminating error' {
        $harness = Initialize-ToolScriptHarness -ScriptRelativePath 'Tools/update.dependencies.ps1' -ModuleContent @'
function Update-DependencyReference {
    [CmdletBinding()]
    param(
        [String]$BuildRequirementsPath,
        [String]$ManifestPath,
        [Switch]$SkipBuildRequirement,
        [Switch]$SkipManifestRequirement
    )

    Write-Error -Message 'simulated updater failure'
}

Export-ModuleMember -Function Update-DependencyReference
'@

        {
            & $harness.ScriptPath -SkipBuildRequirement -SkipManifestRequirement
        } | Should -Throw -ExpectedMessage '*simulated updater failure*'
    }

    It 'delegates atomic Standards and workflow pin updates to the shared operation' {
        $harness = Initialize-ToolScriptHarness -ScriptRelativePath 'Tools/update.dependencies.ps1' -ModuleContent @'
function Update-StandardsDependencyPin {
    [CmdletBinding()]
    param(
        [String]$RepositoryRoot,
        [String]$Version,
        [String]$SetupActionCommitSha,
        [String[]]$WorkflowPath
    )

    [PSCustomObject]@{
        RepositoryRoot       = $RepositoryRoot
        Version              = $Version
        SetupActionCommitSha = $SetupActionCommitSha
        WorkflowPath         = $WorkflowPath
    }
}

Export-ModuleMember -Function Update-StandardsDependencyPin
'@
        $targetRoot = Join-Path $TestDrive 'downstream repository'
        $workflowPath = Join-Path $targetRoot '.github/workflows/ci.yml'

        $result = & $harness.ScriptPath `
            -TargetRepositoryRoot $targetRoot `
            -StandardsVersion '0.1.12' `
            -SetupActionCommitSha 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' `
            -WorkflowPath $workflowPath

        $result.RepositoryRoot | Should -Be $targetRoot
        $result.Version | Should -Be '0.1.12'
        $result.SetupActionCommitSha | Should -Be 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        $result.WorkflowPath | Should -Be $workflowPath
    }
}
