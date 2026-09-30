function Update-StandardsDependencyPin {
    <#
    .SYNOPSIS
        Atomically updates the Standards dependency and setup-action pins.

    .DESCRIPTION
        Resolves an AtlassianPSVII.Standards release from PSGallery and its trusted
        GitHub vX.Y.Z tag, then updates Tools/build.requirements.psd1 and every
        matching setup-powershell action reference as one rollback-capable
        transaction.

    .PARAMETER RepositoryRoot
        Root of the downstream AtlassianPSVII repository to update.

    .PARAMETER Version
        Stable AtlassianPSVII.Standards release version. When omitted, the latest
        PSGallery version is used.

    .PARAMETER SetupActionCommitSha
        Optional approved 40-character commit SHA. When supplied, it must match
        the commit resolved from the trusted release tag.

    .PARAMETER BuildRequirementsPath
        Optional build requirements path. It must remain below RepositoryRoot
        and defaults to Tools/build.requirements.psd1.

    .PARAMETER WorkflowPath
        Optional workflow paths to update. Paths must remain below
        RepositoryRoot/.github/workflows. By default all YAML workflow files
        below that directory are inspected.

    .OUTPUTS
        PSCustomObject describing the resolved pins and transaction result.

    .EXAMPLE
        Update-StandardsDependencyPin -RepositoryRoot ../JiraPSVII -Version 0.1.12

    .EXAMPLE
        Update-StandardsDependencyPin -RepositoryRoot ../JiraPSVII -Version 0.1.12 -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String]$RepositoryRoot,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [String]$Version,

        [Parameter()]
        [ValidatePattern('^[0-9a-fA-F]{40}$')]
        [String]$SetupActionCommitSha,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [String]$BuildRequirementsPath,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [String[]]$WorkflowPath
    )

    $moduleName = 'AtlassianPSVII.Standards'
    $actionCoordinate = 'GregoryMachin/AtlassianPSVII.Standards/.github/actions/setup-powershell'

    function Resolve-PathBelowRoot {
        [CmdletBinding()]
        [OutputType([String])]
        param(
            [Parameter(Mandatory)]
            [String]$Path,

            [Parameter(Mandatory)]
            [String]$Root,

            [Parameter(Mandatory)]
            [String]$Description
        )

        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "$Description was not found: '$Path'."
        }

        $resolvedPath = (Resolve-Path -LiteralPath $Path).ProviderPath
        $rootPrefix = $Root.TrimEnd(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar
        ) + [IO.Path]::DirectorySeparatorChar
        if (-not $resolvedPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "$Description '$resolvedPath' is outside trusted root '$Root'."
        }

        return $resolvedPath
    }

    $resolvedRepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot -ErrorAction Stop).ProviderPath
    if (-not (Test-Path -LiteralPath $resolvedRepositoryRoot -PathType Container)) {
        throw "Repository root was not found: '$RepositoryRoot'."
    }

    if ($Version -and $Version -notmatch '^\d+\.\d+\.\d+$') {
        throw "Invalid AtlassianPSVII.Standards version '$Version'. Expected X.Y.Z."
    }

    $release = Resolve-StandardsReleasePin -RequestedVersion $Version
    if (
        $SetupActionCommitSha -and
        $SetupActionCommitSha -ne $release.CommitSha
    ) {
        throw "Setup action SHA '$SetupActionCommitSha' does not match trusted tag '$($release.TagName)' commit '$($release.CommitSha)'."
    }

    $requirementsCandidate = if ($BuildRequirementsPath) {
        $BuildRequirementsPath
    }
    else {
        Join-Path -Path $resolvedRepositoryRoot -ChildPath 'Tools/build.requirements.psd1'
    }
    $resolvedRequirementsPath = Resolve-PathBelowRoot `
        -Path $requirementsCandidate `
        -Root $resolvedRepositoryRoot `
        -Description 'Build requirements file'

    $workflowRoot = Join-Path -Path $resolvedRepositoryRoot -ChildPath '.github/workflows'
    if (-not (Test-Path -LiteralPath $workflowRoot -PathType Container)) {
        throw "Trusted workflow root was not found: '$workflowRoot'."
    }
    $resolvedWorkflowRoot = (Resolve-Path -LiteralPath $workflowRoot).ProviderPath
    $workflowCandidates = if ($WorkflowPath) {
        @($WorkflowPath)
    }
    else {
        @(
            Get-ChildItem -LiteralPath $resolvedWorkflowRoot -File -Recurse |
                Where-Object { $_.Extension -in @('.yml', '.yaml') } |
                Select-Object -ExpandProperty FullName
        )
    }
    if ($workflowCandidates.Count -eq 0) {
        throw "No workflow files were found below '$resolvedWorkflowRoot'."
    }

    $resolvedWorkflowPaths = @(
        foreach ($candidate in $workflowCandidates) {
            $resolvedPath = Resolve-PathBelowRoot `
                -Path $candidate `
                -Root $resolvedWorkflowRoot `
                -Description 'Workflow file'
            if ([IO.Path]::GetExtension($resolvedPath) -notin @('.yml', '.yaml')) {
                throw "Workflow file '$resolvedPath' must use a .yml or .yaml extension."
            }
            $resolvedPath
        }
    ) | Sort-Object -Unique

    $releaseVersion = $release.Version
    $requirementsState = Get-TextFileState -Path $resolvedRequirementsPath
    $requirementBlockPattern = [Text.RegularExpressions.Regex]::new(
        '(?ms)@\{(?:(?!\}).)*ModuleName\s*=\s*[''"]AtlassianPSVII\.Standards[''"](?:(?!\}).)*\}'
    )
    $requirementMatches = $requirementBlockPattern.Matches($requirementsState.Text)
    if ($requirementMatches.Count -ne 1) {
        throw "Expected exactly one '$moduleName' requirement in '$resolvedRequirementsPath'; found $($requirementMatches.Count)."
    }

    $requirementBlock = $requirementMatches[0].Value
    $versionPattern = [Text.RegularExpressions.Regex]::new(
        '(?<prefix>RequiredVersion\s*=\s*[''"])(?<version>[^''"]+)(?<suffix>[''"])'
    )
    $versionMatches = $versionPattern.Matches($requirementBlock)
    if ($versionMatches.Count -ne 1) {
        throw "The '$moduleName' requirement in '$resolvedRequirementsPath' must contain exactly one RequiredVersion pin."
    }
    $updatedRequirementBlock = $versionPattern.Replace(
        $requirementBlock,
        '${prefix}' + $releaseVersion + '${suffix}',
        1
    )
    $updatedRequirementsText = $requirementsState.Text.Remove(
        $requirementMatches[0].Index,
        $requirementMatches[0].Length
    ).Insert($requirementMatches[0].Index, $updatedRequirementBlock)

    $workflowUpdates = [Collections.Generic.List[Object]]::new()
    $setupPinCount = 0
    $untrustedSetupPattern = '(?im)uses:\s*(?<coordinate>[^\s@]+/setup-powershell)@'
    $trustedPinPattern = [Text.RegularExpressions.Regex]::new(
        '(?im)^(?<prefix>\s*-\s*uses:\s*GregoryMachin/AtlassianPSVII\.Standards/\.github/actions/setup-powershell@)' +
        '(?<sha>[0-9a-f]{40})(?<trailer>[ \t]*(?:#[^\r\n]*)?)(?=\r?$)'
    )

    foreach ($workflowFilePath in $resolvedWorkflowPaths) {
        $workflowState = Get-TextFileState -Path $workflowFilePath
        foreach ($coordinateMatch in [regex]::Matches($workflowState.Text, $untrustedSetupPattern)) {
            if ($coordinateMatch.Groups['coordinate'].Value -ne $actionCoordinate) {
                throw "Untrusted setup action coordinate '$($coordinateMatch.Groups['coordinate'].Value)' in '$workflowFilePath'."
            }
        }

        $trustedMatches = $trustedPinPattern.Matches($workflowState.Text)
        if (
            $workflowState.Text.Contains($actionCoordinate) -and
            $trustedMatches.Count -eq 0
        ) {
            throw "Trusted setup action in '$workflowFilePath' is missing a 40-character commit SHA pin."
        }
        if ($trustedMatches.Count -eq 0) {
            continue
        }

        $setupPinCount += $trustedMatches.Count
        $updatedWorkflowText = $trustedPinPattern.Replace(
            $workflowState.Text,
            '${prefix}' + $release.CommitSha + " # v$releaseVersion"
        )
        if ($updatedWorkflowText -ne $workflowState.Text) {
            $workflowUpdates.Add([PSCustomObject]@{
                    State = $workflowState
                    Text  = $updatedWorkflowText
                })
        }
    }

    if ($setupPinCount -eq 0) {
        throw "No trusted '$actionCoordinate' commit pins were found below '$resolvedWorkflowRoot'."
    }

    $updates = [Collections.Generic.List[Object]]::new()
    if ($updatedRequirementsText -ne $requirementsState.Text) {
        $updates.Add([PSCustomObject]@{
                State = $requirementsState
                Text  = $updatedRequirementsText
            })
    }
    foreach ($workflowUpdate in $workflowUpdates) {
        $updates.Add($workflowUpdate)
    }

    $applied = $false
    if ($updates.Count -gt 0) {
        $targetDescription = '{0} file(s) below {1}' -f $updates.Count, $resolvedRepositoryRoot
        $actionDescription = "Atomically set $moduleName $releaseVersion and setup action $($release.CommitSha)"
        if ($PSCmdlet.ShouldProcess($targetDescription, $actionDescription)) {
            Set-AtomicTextFileSet -Update @($updates)
            $applied = $true
        }
    }

    return [PSCustomObject]@{
        RepositoryRoot       = $resolvedRepositoryRoot
        Version              = $releaseVersion
        SetupActionCommitSha = $release.CommitSha
        SetupActionPinCount  = $setupPinCount
        ChangedFileCount     = $updates.Count
        Changed              = $updates.Count -gt 0
        Applied              = $applied
        ChangedPath          = @($updates.State.Path)
    }
}
