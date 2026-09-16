@{
    RootModule           = 'AtlassianPS.Standards.psm1'
    ModuleVersion        = '0.1.12'
    GUID                 = 'b558bd8c-dc02-4ff2-96b7-4d2c61d9d103'
    Author               = 'AtlassianPS'
    CompanyName          = 'AtlassianPS'
    Copyright            = '(c) 2026 AtlassianPS. All rights reserved.'
    Description          = 'Shared analyzer settings and standards utilities for AtlassianPS modules.'
    PowerShellVersion    = '5.1'
    RequiredModules      = @(
        @{ ModuleName = 'PSScriptAnalyzer'; RequiredVersion = '1.25.0' }
    )

    FunctionsToExport    = @(
        'ConvertTo-ApiCanaryResult'
        'Copy-ModuleArtifacts'
        'Get-ReleaseNotesFromChangelog'
        'Import-DotEnvFile'
        'Initialize-BuildEnvironment'
        'Initialize-ModuleTestEnvironment'
        'Install-DependencyRequirement'
        'Invoke-Lint'
        'Invoke-ModuleTests'
        'Join-ModuleSource'
        'New-ModulePackage'
        'New-ReleaseProvenance'
        'Remove-OrphanedExternalHelp'
        'Resolve-ModuleSource'
        'Resolve-ProjectRoot'
        'Set-ModuleManifestVersion'
        'Sync-ScriptAnalyzerSettings'
        'Test-ApiOperationInventory'
        'Test-ApiResponseHeader'
        'Test-ApiSunset'
        'Test-ModulePackage'
        'Test-ReleaseProvenance'
        'Update-DependencyReference'
        'Update-ExternalHelp'
        'Update-ModuleManifestExports'
        'Update-StandardsDependencyPin'
        'Write-BuildInfo'
    )
    DefaultCommandPrefix = 'AtlassianPS'
    FileList             = @(
        'PSScriptAnalyzerSettings.psd1'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    PrivateData          = @{
        PSData = @{
            Tags         = @(
                'AtlassianPS'
                'PSScriptAnalyzer'
                'Standards'
            )
            Prerelease   = ''
            LicenseUri   = 'https://github.com/AtlassianPS/AtlassianPS.Standards/blob/master/LICENSE'
            ProjectUri   = 'https://github.com/AtlassianPS/AtlassianPS.Standards'
            ReleaseNotes = ''
        }
    }
}
