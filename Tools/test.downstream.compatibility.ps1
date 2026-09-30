#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter()]
    [String]$CandidateModulePath,

    [Parameter()]
    [String]$WorkspaceRoot = (Split-Path -Path $PSScriptRoot -Parent | Split-Path -Parent),

    [Parameter()]
    [ValidateSet('AtlassianPSVII.Configuration', 'JiraPSVII', 'JiraAgilePSVII', 'ConfluencePSVII')]
    [String[]]$RepositoryName = @(
        'AtlassianPSVII.Configuration',
        'JiraPSVII',
        'JiraAgilePSVII',
        'ConfluencePSVII'
    ),

    [Parameter()]
    [String]$PowerShellPath,

    [Parameter()]
    [ValidateRange(1, 86400)]
    [Int32]$TimeoutSeconds = 3600,

    [Parameter()]
    [Switch]$SkipMissingRepository,

    [Parameter()]
    [Switch]$KeepOverlay
)

function Resolve-StandardsCandidateModule {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Candidate Standards path '$Path' does not exist."
    }

    $resolvedPath = (Resolve-Path -LiteralPath $Path).ProviderPath
    $candidateManifestPaths = @()

    if (Test-Path -LiteralPath $resolvedPath -PathType Leaf) {
        $candidateManifestPaths += $resolvedPath
    }
    else {
        $candidateManifestPaths += Join-Path -Path $resolvedPath -ChildPath 'AtlassianPSVII.Standards.psd1'
        $candidateManifestPaths += Join-Path -Path $resolvedPath -ChildPath 'AtlassianPSVII.Standards/AtlassianPSVII.Standards.psd1'
    }

    $manifestPath = @(
        $candidateManifestPaths |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            Select-Object -First 1
    )

    if ($manifestPath.Count -ne 1) {
        throw "Candidate Standards path '$resolvedPath' does not contain AtlassianPSVII.Standards.psd1."
    }

    $manifestPath = (Resolve-Path -LiteralPath $manifestPath[0]).ProviderPath
    $manifestData = Import-PowerShellDataFile -LiteralPath $manifestPath
    if (-not $manifestData.ModuleVersion) {
        throw "Candidate manifest '$manifestPath' does not define ModuleVersion."
    }

    $moduleRoot = Split-Path -Path $manifestPath -Parent
    $rootModule = [String]$manifestData.RootModule
    if ([String]::IsNullOrWhiteSpace($rootModule)) {
        throw "Candidate manifest '$manifestPath' does not define RootModule."
    }

    $rootModulePath = Join-Path -Path $moduleRoot -ChildPath $rootModule
    if (-not (Test-Path -LiteralPath $rootModulePath -PathType Leaf)) {
        throw "Candidate RootModule '$rootModulePath' does not exist."
    }

    [PSCustomObject]@{
        ModuleRoot    = $moduleRoot
        ManifestPath  = $manifestPath
        ModuleVersion = [Version]$manifestData.ModuleVersion
    }
}

function Get-AllowedDownstreamRepository {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String]$WorkspaceRoot,

        [Parameter(Mandatory)]
        [ValidateSet('AtlassianPSVII.Configuration', 'JiraPSVII', 'JiraAgilePSVII', 'ConfluencePSVII')]
        [String]$Name
    )

    if (-not (Test-Path -LiteralPath $WorkspaceRoot -PathType Container)) {
        throw "Workspace root '$WorkspaceRoot' does not exist."
    }

    $resolvedWorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).ProviderPath
    $repositoryPath = Join-Path -Path $resolvedWorkspaceRoot -ChildPath $Name
    if (-not (Test-Path -LiteralPath $repositoryPath -PathType Container)) {
        return [PSCustomObject]@{
            Name             = $Name
            RepositoryPath   = $repositoryPath
            BuildScriptPath  = Join-Path -Path $repositoryPath -ChildPath "$Name.build.ps1"
            RequirementsPath = Join-Path -Path $repositoryPath -ChildPath 'Tools/build.requirements.psd1'
            Exists           = $false
        }
    }

    $resolvedRepositoryPath = (Resolve-Path -LiteralPath $repositoryPath).ProviderPath
    $workspacePrefix = $resolvedWorkspaceRoot.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    ) + [System.IO.Path]::DirectorySeparatorChar

    if (-not $resolvedRepositoryPath.StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Repository '$resolvedRepositoryPath' resolves outside workspace '$resolvedWorkspaceRoot'."
    }

    $buildScriptPath = Join-Path -Path $resolvedRepositoryPath -ChildPath "$Name.build.ps1"
    $requirementsPath = Join-Path -Path $resolvedRepositoryPath -ChildPath 'Tools/build.requirements.psd1'

    if (-not (Test-Path -LiteralPath $buildScriptPath -PathType Leaf)) {
        throw "Allow-listed build entrypoint '$buildScriptPath' does not exist."
    }
    if (-not (Test-Path -LiteralPath $requirementsPath -PathType Leaf)) {
        throw "Build requirements '$requirementsPath' do not exist."
    }

    [PSCustomObject]@{
        Name             = $Name
        RepositoryPath   = $resolvedRepositoryPath
        BuildScriptPath  = (Resolve-Path -LiteralPath $buildScriptPath).ProviderPath
        RequirementsPath = (Resolve-Path -LiteralPath $requirementsPath).ProviderPath
        Exists           = $true
    }
}

function Get-DownstreamStandardsVersion {
    [CmdletBinding()]
    [OutputType([Version])]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [String]$RequirementsPath
    )

    $requirements = @(Import-PowerShellDataFile -LiteralPath $RequirementsPath)
    $standardsRequirements = @(
        $requirements |
            Where-Object { $_.ModuleName -eq 'AtlassianPSVII.Standards' }
    )

    if ($standardsRequirements.Count -ne 1) {
        throw "Build requirements '$RequirementsPath' must contain exactly one AtlassianPSVII.Standards dependency."
    }

    $requiredVersion = $standardsRequirements[0].RequiredVersion
    if (-not $requiredVersion) {
        throw "AtlassianPSVII.Standards in '$RequirementsPath' must use RequiredVersion."
    }

    return [Version]$requiredVersion
}

function Initialize-StandardsCandidateOverlay {
    [CmdletBinding()]
    [OutputType([String])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'Creates an isolated temporary module overlay that the runner always cleans up.'
    )]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [String]$CandidateModuleRoot,

        [Parameter(Mandatory)]
        [Version]$RequiredVersion,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String]$OverlayModuleRoot
    )

    $versionPath = Join-Path -Path $OverlayModuleRoot -ChildPath "AtlassianPSVII.Standards/$RequiredVersion"
    if (Test-Path -LiteralPath $versionPath -PathType Container) {
        return $OverlayModuleRoot
    }

    $null = New-Item -Path $versionPath -ItemType Directory -Force
    foreach ($candidateItem in (Get-ChildItem -LiteralPath $CandidateModuleRoot -Force)) {
        Copy-Item -LiteralPath $candidateItem.FullName -Destination $versionPath -Recurse -Force
    }

    $overlayManifestPath = Join-Path -Path $versionPath -ChildPath 'AtlassianPSVII.Standards.psd1'
    if (-not (Test-Path -LiteralPath $overlayManifestPath -PathType Leaf)) {
        throw "Candidate overlay '$versionPath' does not contain AtlassianPSVII.Standards.psd1."
    }

    $manifestContent = [IO.File]::ReadAllText($overlayManifestPath)
    $moduleVersionPattern = '(?m)^(?<Prefix>\s*ModuleVersion\s*=\s*)[''"][^''"]+[''"]'
    $moduleVersionRegex = New-Object Text.RegularExpressions.Regex $moduleVersionPattern
    if ($moduleVersionRegex.Matches($manifestContent).Count -ne 1) {
        throw "Candidate overlay manifest '$overlayManifestPath' must define ModuleVersion exactly once."
    }

    $versionText = $RequiredVersion.ToString()
    $versionEvaluator = [Text.RegularExpressions.MatchEvaluator] {
        param($match)
        return $match.Groups['Prefix'].Value + "'" + $versionText + "'"
    }
    $updatedManifestContent = $moduleVersionRegex.Replace(
        $manifestContent,
        $versionEvaluator,
        1
    )
    $updatedManifestContent = $updatedManifestContent -replace "(?<!`r)`n", "`r`n"
    [IO.File]::WriteAllText(
        $overlayManifestPath,
        $updatedManifestContent,
        (New-Object Text.UTF8Encoding $true)
    )

    $overlayManifest = Import-PowerShellDataFile -LiteralPath $overlayManifestPath
    if ([Version]$overlayManifest.ModuleVersion -ne $RequiredVersion) {
        throw "Candidate overlay manifest '$overlayManifestPath' did not stage version '$RequiredVersion'."
    }

    return $OverlayModuleRoot
}

function Get-DownstreamSafeEnvironment {
    [CmdletBinding()]
    [OutputType([Hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String]$CandidateModuleRoot
    )

    $safeNames = @(
        'PATH',
        'PATHEXT',
        'SystemRoot',
        'WINDIR',
        'COMSPEC',
        'TEMP',
        'TMP',
        'TMPDIR',
        'HOME',
        'USERPROFILE',
        'HOMEDRIVE',
        'HOMEPATH',
        'LOCALAPPDATA',
        'APPDATA',
        'ProgramData',
        'ProgramFiles',
        'ProgramFiles(x86)',
        'CommonProgramFiles',
        'CommonProgramFiles(x86)',
        'DOTNET_ROOT',
        'LANG',
        'LC_ALL',
        'TERM',
        'NO_COLOR',
        'POWERSHELL_TELEMETRY_OPTOUT'
    )

    $safeEnvironment = @{}
    foreach ($name in $safeNames) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if (-not [String]::IsNullOrWhiteSpace($value)) {
            $safeEnvironment[$name] = $value
        }
    }

    $existingModulePath = [Environment]::GetEnvironmentVariable('PSModulePath', 'Process')
    $modulePaths = @($CandidateModuleRoot)
    if (-not [String]::IsNullOrWhiteSpace($existingModulePath)) {
        $modulePaths += $existingModulePath
    }
    $safeEnvironment['PSModulePath'] = $modulePaths -join [System.IO.Path]::PathSeparator

    return $safeEnvironment
}

function Protect-DownstreamOutput {
    [CmdletBinding()]
    [OutputType([String])]
    param(
        [Parameter()]
        [AllowNull()]
        [String]$Text
    )

    if ([String]::IsNullOrEmpty($Text)) {
        return $Text
    }

    $protectedText = $Text
    $protectedText = [Regex]::Replace(
        $protectedText,
        '(?im)^(Authorization|Cookie|Set-Cookie)\s*:\s*.+$',
        '$1: [REDACTED]'
    )
    $protectedText = [Regex]::Replace(
        $protectedText,
        '(?im)\b(password|token|secret|api[-_]?key)\s*[:=]\s*([^\s;]+)',
        '$1=[REDACTED]'
    )

    return $protectedText
}

function Invoke-DownstreamValidationProcess {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [String]$PowerShellPath,

        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [String]$RepositoryPath,

        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [String]$BuildScriptPath,

        [Parameter(Mandatory)]
        [Hashtable]$Environment,

        [Parameter(Mandatory)]
        [ValidateRange(1, 86400)]
        [Int32]$TimeoutSeconds
    )

    $buildPathBytes = [Text.Encoding]::UTF8.GetBytes($BuildScriptPath)
    $buildPathBase64 = [Convert]::ToBase64String($buildPathBytes)
    $validationCommand = @"
`$ErrorActionPreference = 'Stop'
`$buildPath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$buildPathBase64'))
Import-Module InvokeBuild -ErrorAction Stop
foreach (`$taskName in @('Lint', 'Build', 'Test')) {
    Invoke-Build -File `$buildPath -Task `$taskName
}
"@
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($validationCommand))

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $PowerShellPath
    $startInfo.Arguments = "-NoLogo -NoProfile -NonInteractive -EncodedCommand $encodedCommand"
    $startInfo.WorkingDirectory = $RepositoryPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables.Clear()
    foreach ($entry in $Environment.GetEnumerator()) {
        $startInfo.EnvironmentVariables[$entry.Key] = [String]$entry.Value
    }

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $null = $process.Start()
    $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
    $standardErrorTask = $process.StandardError.ReadToEndAsync()
    $completed = $process.WaitForExit($TimeoutSeconds * 1000)

    if (-not $completed) {
        try {
            $process.Kill()
        }
        catch {
            Write-Verbose 'Downstream process exited before the timeout termination request completed.'
        }
        $process.WaitForExit()
    }

    $standardOutput = $standardOutputTask.Result
    $standardError = $standardErrorTask.Result
    $exitCode = if ($completed) { $process.ExitCode } else { -1 }
    $process.Dispose()
    $stopwatch.Stop()

    [PSCustomObject]@{
        Status         = if (-not $completed) { 'TimedOut' } elseif ($exitCode -eq 0) { 'Passed' } else { 'Failed' }
        ExitCode       = $exitCode
        Duration       = $stopwatch.Elapsed
        StandardOutput = Protect-DownstreamOutput -Text $standardOutput
        StandardError  = Protect-DownstreamOutput -Text $standardError
    }
}

function Invoke-DownstreamCompatibility {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String]$CandidateModulePath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String]$WorkspaceRoot,

        [Parameter()]
        [ValidateSet('AtlassianPSVII.Configuration', 'JiraPSVII', 'JiraAgilePSVII', 'ConfluencePSVII')]
        [String[]]$RepositoryName = @(
            'AtlassianPSVII.Configuration',
            'JiraPSVII',
            'JiraAgilePSVII',
            'ConfluencePSVII'
        ),

        [Parameter()]
        [String]$PowerShellPath,

        [Parameter()]
        [ValidateRange(1, 86400)]
        [Int32]$TimeoutSeconds = 3600,

        [Parameter()]
        [Switch]$SkipMissingRepository,

        [Parameter()]
        [Switch]$KeepOverlay
    )

    $candidate = Resolve-StandardsCandidateModule -Path $CandidateModulePath
    $resolvedPowerShellPath = $PowerShellPath
    if ([String]::IsNullOrWhiteSpace($resolvedPowerShellPath)) {
        $resolvedPowerShellPath = (Get-Process -Id $PID).Path
    }
    if (-not (Test-Path -LiteralPath $resolvedPowerShellPath -PathType Leaf)) {
        throw "PowerShell executable '$resolvedPowerShellPath' does not exist."
    }
    $resolvedPowerShellPath = (Resolve-Path -LiteralPath $resolvedPowerShellPath).ProviderPath

    $overlayRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath (
        'AtlassianPSVII-Standards-Compatibility-{0}' -f [Guid]::NewGuid().ToString('N')
    )
    $overlayModuleRoot = Join-Path -Path $overlayRoot -ChildPath 'Modules'
    $results = New-Object System.Collections.Generic.List[PSCustomObject]

    try {
        foreach ($name in $RepositoryName) {
            $repository = Get-AllowedDownstreamRepository -WorkspaceRoot $WorkspaceRoot -Name $name
            if (-not $repository.Exists) {
                $missingStatus = if ($SkipMissingRepository.IsPresent) { 'Skipped' } else { 'Missing' }
                $missingResult = [PSCustomObject]@{
                    Repository       = $name
                    RepositoryPath   = $repository.RepositoryPath
                    CandidateVersion = $candidate.ModuleVersion
                    RequiredVersion  = $null
                    Status           = $missingStatus
                    ExitCode         = $null
                    Duration         = [TimeSpan]::Zero
                    StandardOutput   = ''
                    StandardError    = "Repository '$name' was not found."
                }
                $results.Add($missingResult)
                continue
            }

            $requiredVersion = Get-DownstreamStandardsVersion -RequirementsPath $repository.RequirementsPath
            $null = Initialize-StandardsCandidateOverlay `
                -CandidateModuleRoot $candidate.ModuleRoot `
                -RequiredVersion $requiredVersion `
                -OverlayModuleRoot $overlayModuleRoot

            $safeEnvironment = Get-DownstreamSafeEnvironment -CandidateModuleRoot $overlayModuleRoot
            $processResult = Invoke-DownstreamValidationProcess `
                -PowerShellPath $resolvedPowerShellPath `
                -RepositoryPath $repository.RepositoryPath `
                -BuildScriptPath $repository.BuildScriptPath `
                -Environment $safeEnvironment `
                -TimeoutSeconds $TimeoutSeconds

            $validationResult = [PSCustomObject]@{
                Repository       = $name
                RepositoryPath   = $repository.RepositoryPath
                CandidateVersion = $candidate.ModuleVersion
                RequiredVersion  = $requiredVersion
                Status           = $processResult.Status
                ExitCode         = $processResult.ExitCode
                Duration         = $processResult.Duration
                StandardOutput   = $processResult.StandardOutput
                StandardError    = $processResult.StandardError
            }
            $results.Add($validationResult)
        }
    }
    finally {
        if ((-not $KeepOverlay.IsPresent) -and (Test-Path -LiteralPath $overlayRoot -PathType Container)) {
            $resolvedOverlayRoot = (Resolve-Path -LiteralPath $overlayRoot).ProviderPath
            $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
                [IO.Path]::DirectorySeparatorChar,
                [IO.Path]::AltDirectorySeparatorChar
            ) + [IO.Path]::DirectorySeparatorChar

            if (
                $resolvedOverlayRoot.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -and
                ((Split-Path -Path $resolvedOverlayRoot -Leaf) -like 'AtlassianPSVII-Standards-Compatibility-*')
            ) {
                Remove-Item -LiteralPath $resolvedOverlayRoot -Recurse -Force
            }
            else {
                throw "Refusing to remove unexpected overlay path '$resolvedOverlayRoot'."
            }
        }
    }

    $results
    $failures = @($results | Where-Object { $_.Status -in @('Failed', 'TimedOut', 'Missing') })
    if ($failures.Count -gt 0) {
        $failureSummary = $failures | ForEach-Object {
            '{0} ({1}, exit {2})' -f $_.Repository, $_.Status, $_.ExitCode
        }
        throw "Downstream compatibility validation failed: $($failureSummary -join '; ')."
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ([String]::IsNullOrWhiteSpace($CandidateModulePath)) {
        throw 'CandidateModulePath is required when running the compatibility runner.'
    }

    Invoke-DownstreamCompatibility `
        -CandidateModulePath $CandidateModulePath `
        -WorkspaceRoot $WorkspaceRoot `
        -RepositoryName $RepositoryName `
        -PowerShellPath $PowerShellPath `
        -TimeoutSeconds $TimeoutSeconds `
        -SkipMissingRepository:$SkipMissingRepository `
        -KeepOverlay:$KeepOverlay
}
