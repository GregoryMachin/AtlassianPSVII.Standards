function New-ReleaseProvenance {
    <#
    .SYNOPSIS
        Creates deterministic release checksums and dependency provenance.

    .DESCRIPTION
        Records the exact package digest, source commit, CI run, release version,
        and pinned runtime/build dependencies. JSON and checksum output is stable
        for identical inputs.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [String]$PackagePath,

        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [String]$ModuleManifestPath,

        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [String]$BuildRequirementsPath,

        [Parameter(Mandatory)]
        [ValidatePattern('^[^/\s]+/[^/\s]+$')]
        [String]$Repository,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{40}$')]
        [String]$CommitSha,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String]$SourceRef,

        [Parameter(Mandatory)]
        [ValidatePattern('^\d+$')]
        [String]$RunId,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [String]$OutputPath
    )

    $resolvedPackagePath = (Resolve-Path -LiteralPath $PackagePath).ProviderPath
    $resolvedManifestPath = (Resolve-Path -LiteralPath $ModuleManifestPath).ProviderPath
    $resolvedRequirementsPath = (Resolve-Path -LiteralPath $BuildRequirementsPath).ProviderPath
    if (-not $OutputPath) {
        $OutputPath = Split-Path -Path $resolvedPackagePath -Parent
    }
    if (-not (Test-Path -LiteralPath $OutputPath -PathType Container)) {
        $null = New-Item -Path $OutputPath -ItemType Directory -Force
    }
    $resolvedOutputPath = (Resolve-Path -LiteralPath $OutputPath).ProviderPath

    $manifest = Import-PowerShellDataFile -LiteralPath $resolvedManifestPath -ErrorAction Stop
    $moduleName = [IO.Path]::GetFileNameWithoutExtension($resolvedManifestPath)
    $prerelease = [String]$manifest.PrivateData.PSData.Prerelease
    $releaseTag = 'v{0}{1}' -f $manifest.ModuleVersion, $(
        if ([String]::IsNullOrWhiteSpace($prerelease)) { '' } else { "-$prerelease" }
    )

    $dependencies = [Collections.Generic.List[Object]]::new()
    foreach ($requirement in @($manifest.RequiredModules)) {
        $dependencies.Add([PSCustomObject][Ordered]@{
                Name    = [String]$requirement.ModuleName
                Version = [String]$requirement.RequiredVersion
                Scope   = 'Runtime'
                Source  = 'PSGallery'
            })
    }
    foreach ($requirement in @(Get-SafeDataFileValue -Path $resolvedRequirementsPath)) {
        $dependencies.Add([PSCustomObject][Ordered]@{
                Name    = [String]$requirement.ModuleName
                Version = [String]$requirement.RequiredVersion
                Scope   = 'Build'
                Source  = 'PSGallery'
            })
    }

    $dependencyDocument = [Ordered]@{
        SchemaVersion = '1.0'
        Format        = 'AtlassianPS.DependencyManifest'
        Module        = $moduleName
        Components    = @($dependencies | Sort-Object Scope, Name)
    }
    $dependencyPath = Join-Path -Path $resolvedOutputPath -ChildPath 'dependency-manifest.json'
    $provenancePath = Join-Path -Path $resolvedOutputPath -ChildPath 'release-provenance.json'
    $checksumPath = Join-Path -Path $resolvedOutputPath -ChildPath 'SHA256SUMS'

    if ($PSCmdlet.ShouldProcess($resolvedOutputPath, 'Write release provenance files')) {
        $utf8NoBom = [Text.UTF8Encoding]::new($false)
        $dependencyJson = $dependencyDocument |
            ConvertTo-Json -Depth 10 |
            ForEach-Object { $_ -replace "`r`n", "`n" }
        [IO.File]::WriteAllText($dependencyPath, "$dependencyJson`n", $utf8NoBom)

        $packageHash = (Get-FileHash -LiteralPath $resolvedPackagePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $dependencyHash = (Get-FileHash -LiteralPath $dependencyPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $packageFile = Get-Item -LiteralPath $resolvedPackagePath
        $provenanceDocument = [Ordered]@{
            SchemaVersion      = '1.0'
            Format             = 'AtlassianPS.ReleaseProvenance'
            Artifact           = [Ordered]@{
                Name   = $packageFile.Name
                Size   = $packageFile.Length
                Sha256 = $packageHash
            }
            DependencyManifest = [Ordered]@{
                Name   = [IO.Path]::GetFileName($dependencyPath)
                Sha256 = $dependencyHash
            }
            Module             = [Ordered]@{
                Name       = $moduleName
                Version    = [String]$manifest.ModuleVersion
                Prerelease = $prerelease
                ReleaseTag = $releaseTag
            }
            Source             = [Ordered]@{
                Repository = $Repository
                CommitSha  = $CommitSha.ToLowerInvariant()
                Ref        = $SourceRef
            }
            Ci                 = [Ordered]@{
                Provider = 'GitHubActions'
                RunId    = $RunId
            }
        }
        $provenanceJson = $provenanceDocument |
            ConvertTo-Json -Depth 10 |
            ForEach-Object { $_ -replace "`r`n", "`n" }
        [IO.File]::WriteAllText($provenancePath, "$provenanceJson`n", $utf8NoBom)

        $checksumLines = @(
            "$packageHash *$($packageFile.Name)"
            "$dependencyHash *$([IO.Path]::GetFileName($dependencyPath))"
        ) | Sort-Object
        [IO.File]::WriteAllText(
            $checksumPath,
            (($checksumLines -join "`n") + "`n"),
            $utf8NoBom
        )
    }

    [PSCustomObject][Ordered]@{
        PackagePath            = $resolvedPackagePath
        DependencyManifestPath = $dependencyPath
        ProvenancePath         = $provenancePath
        ChecksumPath           = $checksumPath
        ReleaseTag             = $releaseTag
    }
}
