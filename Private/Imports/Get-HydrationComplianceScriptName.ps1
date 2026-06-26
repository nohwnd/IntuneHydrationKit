function Get-HydrationComplianceScriptName {
    [CmdletBinding()]
    param(
        [Parameter()]
        [object]$ScriptDefinition,

        [Parameter(Mandatory)]
        [string]$PolicyDisplayName
    )

    $baseName = if ($ScriptDefinition -and $ScriptDefinition.displayName) {
        [string]$ScriptDefinition.displayName
    } else {
        "$PolicyDisplayName Script"
    }

    $displayName = if ($baseName.StartsWith($script:ImportPrefix)) {
        $baseName
    } else {
        "$($script:ImportPrefix)$baseName"
    }

    [PSCustomObject]@{
        BaseName    = $baseName
        DisplayName = $displayName
    }
}
