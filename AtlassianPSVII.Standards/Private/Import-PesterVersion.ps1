function Import-PesterVersion {
    [CmdletBinding()]
    [OutputType([Version])]
    param(
        [Parameter()]
        [Version]$MinimumVersion = [Version]'6.2.0',

        [Parameter()]
        [Version]$MaximumVersion
    )

    $pesterVersionToUse = Get-UsablePesterVersion -MinimumVersion $MinimumVersion -MaximumVersion $MaximumVersion
    $loadedPester = Get-Module -Name 'Pester' | Sort-Object -Property Version -Descending | Select-Object -First 1
    if ((-not $loadedPester) -or ($loadedPester.Version -ne $pesterVersionToUse)) {
        if ($loadedPester) {
            Get-Module -Name 'Pester' | Remove-Module -Force -ErrorAction SilentlyContinue
        }
        # -Global: imported from inside this module, Pester would otherwise land in this module's
        # session state only, and test code (e.g. Mock inside InModuleScope) would auto-load a
        # second, different Pester version from PSModulePath.
        Import-Module -Name 'Pester' -RequiredVersion $pesterVersionToUse -Global -ErrorAction Stop
    }

    return $pesterVersionToUse
}
