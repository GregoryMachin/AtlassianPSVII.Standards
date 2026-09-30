function Resolve-StandardsReleasePin {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [String]$RequestedVersion
    )

    $moduleName = 'AtlassianPSVII.Standards'
    $repositoryApiRoot = 'https://api.github.com/repos/AtlassianPS/AtlassianPS.Standards'
    if ($RequestedVersion -and $RequestedVersion -notmatch '^\d+\.\d+\.\d+$') {
        throw "Invalid AtlassianPSVII.Standards version '$RequestedVersion'. Expected X.Y.Z."
    }

    try {
        $findParameters = @{
            Name        = $moduleName
            Repository  = 'PSGallery'
            ErrorAction = 'Stop'
        }
        if ($RequestedVersion) {
            $findParameters.RequiredVersion = $RequestedVersion
        }

        $package = Find-Module @findParameters
    }
    catch {
        throw "Unable to resolve trusted PSGallery package '$moduleName'. Original error: $($_.Exception.Message)"
    }

    if (-not $package -or -not $package.Version) {
        throw "PSGallery lookup for '$moduleName' returned no version."
    }

    $resolvedVersion = [String]$package.Version
    if ($resolvedVersion -notmatch '^\d+\.\d+\.\d+$') {
        throw "PSGallery returned invalid stable version '$resolvedVersion' for '$moduleName'."
    }
    if ($RequestedVersion -and $resolvedVersion -ne $RequestedVersion) {
        throw "PSGallery resolved '$resolvedVersion' instead of requested version '$RequestedVersion'."
    }

    $tagName = "v$resolvedVersion"
    try {
        $reference = Invoke-RestMethod `
            -Method Get `
            -Uri "$repositoryApiRoot/git/ref/tags/$tagName" `
            -ErrorAction Stop
        if (-not $reference.object -or $reference.object.type -notin @('commit', 'tag')) {
            throw "Tag '$tagName' did not resolve to a commit or annotated tag."
        }

        $commitSha = [String]$reference.object.sha
        if ($reference.object.type -eq 'tag') {
            $tag = Invoke-RestMethod `
                -Method Get `
                -Uri "$repositoryApiRoot/git/tags/$commitSha" `
                -ErrorAction Stop
            if (-not $tag.object -or $tag.object.type -ne 'commit') {
                throw "Annotated tag '$tagName' did not resolve to a commit."
            }
            $commitSha = [String]$tag.object.sha
        }
    }
    catch {
        throw "Unable to resolve trusted GitHub tag '$tagName'. Original error: $($_.Exception.Message)"
    }

    if ($commitSha -notmatch '^[0-9a-fA-F]{40}$') {
        throw "Trusted GitHub tag '$tagName' returned invalid commit SHA '$commitSha'."
    }

    return [PSCustomObject]@{
        Version   = $resolvedVersion
        TagName   = $tagName
        CommitSha = $commitSha.ToLowerInvariant()
    }
}
