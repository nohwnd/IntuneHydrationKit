function Import-IntuneLinuxScript {
    <#
    .SYNOPSIS
        Imports Linux shell scripts from bundled templates.
    .DESCRIPTION
        Reads JSON templates from Templates/LinuxScripts and creates Linux custom configuration policies via Graph.
    .PARAMETER TemplatePath
        Path to the Linux script template directory (defaults to Templates/LinuxScripts).
    .PARAMETER Platform
        Filter templates by platform. Linux scripts are imported only when Linux or All is selected.
    .PARAMETER RemoveExisting
        Deletes matching Linux custom configuration policies created by this kit instead of creating new ones.
    .EXAMPLE
        Import-IntuneLinuxScript
    .EXAMPLE
        Import-IntuneLinuxScript -Platform Linux -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter()]
        [string]$TemplatePath,

        [Parameter()]
        [ValidateSet('Windows', 'macOS', 'iOS', 'Android', 'Linux', 'All')]
        [string[]]$Platform = @('All'),

        [Parameter()]
        [switch]$RemoveExisting
    )

    if ($Platform -and $Platform -notcontains 'All' -and $Platform -notcontains 'Linux') {
        Write-Verbose "Skipping Linux scripts because Linux is not in the selected platform filter: $($Platform -join ', ')"
        return @()
    }

    if (-not $TemplatePath) {
        $TemplatePath = Join-Path -Path $script:TemplatesPath -ChildPath 'LinuxScripts'
    }

    if (-not (Test-Path -Path $TemplatePath)) {
        Write-Warning "Linux script template directory not found: $TemplatePath"
        return @()
    }

    $templateFiles = Get-FilteredTemplates -Path $TemplatePath -Platform @('Linux') -FilterMode 'Prefix' -Recurse -ResourceType 'Linux script template'
    if (-not $templateFiles -or $templateFiles.Count -eq 0) {
        Write-Warning "No Linux script templates found in: $TemplatePath"
        return @()
    }

    $linuxScriptPolicyUri = "beta/deviceManagement/configurationPolicies?`$select=id,name,description,platforms,technologies,templateReference&`$filter=templateReference/TemplateFamily eq 'deviceConfigurationScripts'&`$top=50"
    $results = @()

    if ($RemoveExisting) {
        $knownTemplateNames = Get-TemplateDisplayNames -Path $TemplatePath -Recurse
        $scriptsToDelete = Get-HydrationDeleteCandidates `
            -Endpoint $linuxScriptPolicyUri `
            -DeleteBaseUrl '/deviceManagement/configurationPolicies' `
            -KnownTemplateNames $knownTemplateNames `
            -RequireTemplateMatch

        if ($scriptsToDelete.Count -eq 0) {
            Write-Verbose 'No Linux scripts found to delete'
            return $results
        }

        $deleteTarget = "$($scriptsToDelete.Count) Linux script configuration policy/policies"
        if (-not $PSCmdlet.ShouldProcess($deleteTarget, 'Delete')) {
            if ($WhatIfPreference) {
                foreach ($script in $scriptsToDelete) {
                    Write-HydrationLog -Message "  WouldDelete: $($script.Name)" -Level Info
                    $results += New-HydrationResult -Name $script.Name -Platform 'Linux' -Type 'LinuxScript' -Action 'WouldDelete' -Status 'DryRun'
                }
            }
            return $results
        }

        $results += Invoke-GraphBatchOperation -Items $scriptsToDelete -Operation 'DELETE' -ResultType 'LinuxScript'

        return $results
    }

    $existingScripts = Get-HydrationExistingObjectMap `
        -Uri $linuxScriptPolicyUri `
        -NameProperty 'name'

    $scriptsToCreate = @()
    foreach ($templateFile in $templateFiles) {
        try {
            $template = Get-Content -Path $templateFile.FullName -Raw -Encoding utf8 | ConvertFrom-Json
            if (-not $template.displayName) {
                Write-Warning "Template missing displayName: $($templateFile.FullName)"
                $results += New-HydrationResult -Name $templateFile.Name -Path $templateFile.FullName -Type 'LinuxScript' -Action 'Failed' -Status 'Missing displayName'
                continue
            }
            if (-not $template.scriptContentBase64) {
                Write-Warning "Template missing scriptContentBase64: $($templateFile.FullName)"
                $results += New-HydrationResult -Name $template.displayName -Path $templateFile.FullName -Type 'LinuxScript' -Action 'Failed' -Status 'Missing scriptContentBase64'
                continue
            }

            $displayName = if ($template.displayName.StartsWith($script:ImportPrefix)) {
                $template.displayName
            } else {
                "$($script:ImportPrefix)$($template.displayName)"
            }

            $existingName = $null
            $existingEntry = $null
            if ($existingScripts.ContainsKey($displayName) -and $existingScripts[$displayName].IsTagged) {
                $existingName = $displayName
                $existingEntry = $existingScripts[$displayName]
            } elseif ($existingScripts.ContainsKey($template.displayName) -and $existingScripts[$template.displayName].IsTagged) {
                $existingName = $template.displayName
                $existingEntry = $existingScripts[$template.displayName]
            }

            if ($existingEntry) {
                Write-HydrationLog -Message "  Skipped: $existingName" -Level Info
                $results += New-HydrationResult -Name $existingName -Id $existingEntry.Id -Path $templateFile.FullName -Platform 'Linux' -Type 'LinuxScript' -Action 'Skipped' -Status 'Already exists'
                continue
            }

            [string[]]$roleScopeTagIds = if ($template.roleScopeTagIds) {
                @($template.roleScopeTagIds)
            } else {
                @('0')
            }

            $scriptBody = New-HydrationLinuxScriptConfigurationPolicyBody `
                -Name $displayName `
                -Description (New-HydrationDescription -ExistingText $template.description) `
                -RoleScopeTagIds $roleScopeTagIds `
                -ScriptContentBase64 $template.scriptContentBase64

            $scriptsToCreate += @{
                Name     = $displayName
                Path     = $templateFile.FullName
                Platform = 'Linux'
                BodyJson = ($scriptBody | ConvertTo-Json -Depth 100 -Compress)
            }
        } catch {
            $errMessage = Get-GraphErrorMessage -ErrorRecord $_
            Write-HydrationLog -Message "  Failed to prepare: $($templateFile.Name) - $errMessage" -Level Warning
            $results += New-HydrationResult -Name $templateFile.Name -Path $templateFile.FullName -Type 'LinuxScript' -Action 'Failed' -Status "Prepare error: $errMessage"
        }
    }

    if (-not $PSCmdlet.ShouldProcess("$($scriptsToCreate.Count) Linux script(s)", 'Create')) {
        if ($WhatIfPreference) {
            foreach ($script in $scriptsToCreate) {
                Write-HydrationLog -Message "  WouldCreate: $($script.Name)" -Level Info
                $results += New-HydrationResult -Name $script.Name -Path $script.Path -Platform 'Linux' -Type 'LinuxScript' -Action 'WouldCreate' -Status 'DryRun'
            }
        }
        return $results
    }

    if ($scriptsToCreate.Count -gt 0) {
        $results += Invoke-GraphBatchOperation -Items $scriptsToCreate -Operation 'POST' -BaseUrl '/deviceManagement/configurationPolicies' -ResultType 'LinuxScript'
    }

    return $results
}
