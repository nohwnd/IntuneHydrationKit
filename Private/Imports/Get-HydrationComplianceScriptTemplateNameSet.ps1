function Get-HydrationComplianceScriptTemplateNameSet {
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.HashSet[string]])]
    param(
        [Parameter(Mandatory)]
        [object[]]$TemplateFile
    )

    $scriptNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($file in $TemplateFile) {
        try {
            $template = Get-Content -Path $file.FullName -Raw -Encoding utf8 | ConvertFrom-Json
            if (-not $template.deviceCompliancePolicyScriptDefinition) {
                continue
            }

            $policyDisplayName = if ($template.displayName -and $template.displayName.StartsWith($script:ImportPrefix)) {
                [string]$template.displayName
            } else {
                "$($script:ImportPrefix)$($template.displayName)"
            }

            $scriptName = Get-HydrationComplianceScriptName `
                -ScriptDefinition $template.deviceCompliancePolicyScriptDefinition `
                -PolicyDisplayName $policyDisplayName

            [void]$scriptNames.Add($scriptName.DisplayName)
            [void]$scriptNames.Add($scriptName.BaseName)
        } catch {
            Write-Verbose "Could not read custom compliance script name from template: $($file.FullName)"
        }
    }

    return $scriptNames
}
