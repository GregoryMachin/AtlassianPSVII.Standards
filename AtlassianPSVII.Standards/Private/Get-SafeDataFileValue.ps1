function Get-SafeDataFileValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [String]$Path
    )

    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [Ref]$tokens,
        [Ref]$parseErrors
    )
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        throw "Unable to parse data file '$Path': $($parseErrors[0].Message)"
    }
    if (-not $ast.EndBlock -or $ast.EndBlock.Statements.Count -ne 1) {
        throw "Data file '$Path' must contain exactly one safe data expression."
    }

    $statement = $ast.EndBlock.Statements[0]
    if ($statement -isnot [Management.Automation.Language.PipelineAst]) {
        throw "Data file '$Path' does not contain a safe data expression."
    }
    $pipelineElement = $statement.PipelineElements[0]
    if ($pipelineElement -isnot [Management.Automation.Language.CommandExpressionAst]) {
        throw "Data file '$Path' does not contain a safe data expression."
    }

    return $pipelineElement.Expression.SafeGetValue()
}
