#requires -Module PowerShellGet

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [Switch]$SkipBuildRequirement,

    [Parameter()]
    [Switch]$SkipManifestRequirement,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [String]$TargetRepositoryRoot,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [String]$StandardsVersion,

    [Parameter()]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [String]$SetupActionCommitSha,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [String[]]$WorkflowPath
)

$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..')).ProviderPath
$moduleSourcePath = Join-Path -Path $projectRoot -ChildPath 'AtlassianPSVII.Standards/AtlassianPSVII.Standards.psm1'

try {
    Import-Module -Name $moduleSourcePath -Force -ErrorAction Stop
}
catch {
    throw "Failed to import AtlassianPSVII.Standards module source from '$moduleSourcePath'. Original error: $($_.Exception.Message)"
}

$atomicPinMode = $TargetRepositoryRoot -or $StandardsVersion -or $SetupActionCommitSha -or $WorkflowPath
if ($atomicPinMode) {
    if (-not $TargetRepositoryRoot) {
        throw 'TargetRepositoryRoot is required when updating Standards dependency and workflow pins.'
    }
    if ($SkipBuildRequirement -or $SkipManifestRequirement) {
        throw 'SkipBuildRequirement and SkipManifestRequirement cannot be used with atomic Standards pin updates.'
    }

    $atomicParameters = @{
        RepositoryRoot = $TargetRepositoryRoot
        ErrorAction    = 'Stop'
    }
    if ($StandardsVersion) {
        $atomicParameters.Version = $StandardsVersion
    }
    if ($SetupActionCommitSha) {
        $atomicParameters.SetupActionCommitSha = $SetupActionCommitSha
    }
    if ($WorkflowPath) {
        $atomicParameters.WorkflowPath = $WorkflowPath
    }

    $result = AtlassianPSVII.Standards\Update-StandardsDependencyPin @atomicParameters
}
else {
    $result = AtlassianPSVII.Standards\Update-DependencyReference `
        -BuildRequirementsPath (Join-Path -Path $projectRoot -ChildPath 'Tools/build.requirements.psd1') `
        -ManifestPath (Join-Path -Path $projectRoot -ChildPath 'AtlassianPSVII.Standards/AtlassianPSVII.Standards.psd1') `
        -SkipBuildRequirement:$SkipBuildRequirement `
        -SkipManifestRequirement:$SkipManifestRequirement `
        -ErrorAction Stop
}

$result
