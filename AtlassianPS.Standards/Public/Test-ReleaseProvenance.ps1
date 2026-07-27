function Test-ReleaseProvenance {
    <#
    .SYNOPSIS
        Verifies release checksums, source identity, and attestation presence.

    .DESCRIPTION
        Fails when an artifact or dependency manifest digest differs, provenance
        belongs to another repository, commit, run, or release tag, or a required
        GitHub attestation bundle is absent. Signature verification remains the
        responsibility of `gh attestation verify`.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [String]$ReleasePath,

        [Parameter(Mandatory)]
        [ValidatePattern('^[^/\s]+/[^/\s]+$')]
        [String]$ExpectedRepository,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{40}$')]
        [String]$ExpectedCommitSha,

        [Parameter(Mandatory)]
        [ValidatePattern('^\d+$')]
        [String]$ExpectedRunId,

        [Parameter(Mandatory)]
        [ValidatePattern('^v\d+\.\d+\.\d+(?:-(?:alpha|beta|rc)(?:-\d+)?)?$')]
        [String]$ExpectedReleaseTag,

        [Parameter()]
        [String]$AttestationPath,

        [Parameter()]
        [Switch]$RequireAttestation
    )

    $resolvedReleasePath = (Resolve-Path -LiteralPath $ReleasePath).ProviderPath
    $provenancePath = Join-Path -Path $resolvedReleasePath -ChildPath 'release-provenance.json'
    $checksumPath = Join-Path -Path $resolvedReleasePath -ChildPath 'SHA256SUMS'
    foreach ($requiredPath in @($provenancePath, $checksumPath)) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "Required release provenance file was not found: '$requiredPath'."
        }
    }

    if ($RequireAttestation.IsPresent) {
        if (
            [String]::IsNullOrWhiteSpace($AttestationPath) -or
            -not (Test-Path -LiteralPath $AttestationPath -PathType Leaf)
        ) {
            throw 'A GitHub artifact attestation bundle is required but was not found.'
        }
    }

    $provenance = Get-Content -LiteralPath $provenancePath -Raw | ConvertFrom-Json
    if ($provenance.Source.Repository -cne $ExpectedRepository) {
        throw "Provenance repository '$($provenance.Source.Repository)' does not match expected '$ExpectedRepository'."
    }
    if ($provenance.Source.CommitSha -ine $ExpectedCommitSha) {
        throw "Provenance commit '$($provenance.Source.CommitSha)' does not match expected '$ExpectedCommitSha'."
    }
    if ([String]$provenance.Ci.RunId -cne $ExpectedRunId) {
        throw "Provenance run '$($provenance.Ci.RunId)' does not match expected '$ExpectedRunId'."
    }
    if ($provenance.Module.ReleaseTag -cne $ExpectedReleaseTag) {
        throw "Provenance release tag '$($provenance.Module.ReleaseTag)' does not match expected '$ExpectedReleaseTag'."
    }

    $checksums = @{}
    foreach ($line in Get-Content -LiteralPath $checksumPath) {
        if ($line -notmatch '^(?<hash>[0-9a-f]{64}) \*(?<name>[^\\/]+)$') {
            throw "Malformed SHA256SUMS entry: '$line'."
        }
        $checksums[$Matches.name] = $Matches.hash
    }

    foreach ($name in @($provenance.Artifact.Name, $provenance.DependencyManifest.Name)) {
        if (-not $checksums.ContainsKey($name)) {
            throw "SHA256SUMS does not contain required file '$name'."
        }
        $filePath = Join-Path -Path $resolvedReleasePath -ChildPath $name
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            throw "Checksummed release file was not found: '$filePath'."
        }
        $actualHash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -cne $checksums[$name]) {
            throw "SHA256 checksum mismatch for '$name'."
        }
    }

    if ($checksums[$provenance.Artifact.Name] -cne $provenance.Artifact.Sha256) {
        throw 'Package checksum does not match release-provenance.json.'
    }
    if ($checksums[$provenance.DependencyManifest.Name] -cne $provenance.DependencyManifest.Sha256) {
        throw 'Dependency manifest checksum does not match release-provenance.json.'
    }

    [PSCustomObject][Ordered]@{
        IsValid                = $true
        PackagePath            = Join-Path -Path $resolvedReleasePath -ChildPath $provenance.Artifact.Name
        DependencyManifestPath = Join-Path -Path $resolvedReleasePath -ChildPath $provenance.DependencyManifest.Name
        ProvenancePath         = $provenancePath
        ChecksumPath           = $checksumPath
        AttestationPath        = if ($AttestationPath) {
            $AttestationPath
        }
        else {
            $null
        }
        ReleaseTag             = $provenance.Module.ReleaseTag
        CommitSha              = $provenance.Source.CommitSha
    }
}
