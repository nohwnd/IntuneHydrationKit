function Get-HydrationCompliancePolicyTemplateNameSet {
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.HashSet[string]])]
    param(
        [Parameter(Mandatory)]
        [object[]]$TemplateFile
    )

    $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $escapedPrefix = [regex]::Escape($script:ImportPrefix)

    foreach ($file in $TemplateFile) {
        try {
            $template = Get-Content -Path $file.FullName -Raw -Encoding utf8 | ConvertFrom-Json
            foreach ($name in @($template.displayName, $template.name)) {
                if ([string]::IsNullOrWhiteSpace($name)) {
                    continue
                }

                [void]$names.Add($name)
                if ($name.StartsWith($script:ImportPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    [void]$names.Add(($name -replace "^$escapedPrefix", ''))
                } else {
                    [void]$names.Add("$($script:ImportPrefix)$name")
                }
            }
        } catch {
            Write-Verbose "Could not read compliance policy name from template: $($file.FullName)"
        }
    }

    return , $names
}
