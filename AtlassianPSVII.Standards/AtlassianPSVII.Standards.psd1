@{
    RootModule           = 'AtlassianPSVII.Standards.psm1'
    ModuleVersion        = '0.2.0'
    GUID                 = '4453c019-c7cb-4a8f-8074-a21380db71f3'
    Author               = 'AtlassianPSVII'
    CompanyName          = 'AtlassianPSVII'
    Copyright            = '(c) 2026 AtlassianPSVII. All rights reserved.'
    Description          = 'Shared analyzer settings and standards utilities for AtlassianPSVII modules.'
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
    DefaultCommandPrefix = 'AtlassianPSVII'
    FileList             = @(
        'PSScriptAnalyzerSettings.psd1'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    PrivateData          = @{
        PSData = @{
            Tags         = @(
                'AtlassianPSVII'
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
