function Import-IntuneLinuxScript {
    <#
    .SYNOPSIS
        Imports Linux shell scripts from bundled templates.
    .DESCRIPTION
        Reads JSON templates from Templates/LinuxScripts and creates Linux shell scripts via Graph.
    .PARAMETER TemplatePath
        Path to the Linux script template directory (defaults to Templates/LinuxScripts).
    .PARAMETER Platform
        Filter templates by platform. Linux scripts are imported only when Linux or All is selected.
    .PARAMETER RemoveExisting
        Deletes matching Linux shell scripts created by this kit instead of creating new ones.
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

    $existingScripts = @{}
    try {
        Get-GraphPagedResults -Uri "beta/deviceManagement/deviceShellScripts?`$select=id,displayName,description" -ProcessItems {
            param($items)

            foreach ($script in $items) {
                if (-not $script.displayName) {
                    continue
                }

                $isTagged = Test-HydrationKitObject -Description $script.description
                if (-not $existingScripts.ContainsKey($script.displayName) -or
                    ($isTagged -and -not $existingScripts[$script.displayName].IsTagged)) {
                    $existingScripts[$script.displayName] = @{
                        Id          = $script.id
                        Description = $script.description
                        IsTagged    = $isTagged
                    }
                }
            }
        }
    } catch {
        Write-Warning "Could not retrieve existing Linux scripts: $_"
        $existingScripts = @{}
    }

    $results = @()

    if ($RemoveExisting) {
        $knownTemplateNames = Get-TemplateDisplayNames -Path $TemplatePath -Recurse
        $scriptsToDelete = @()
        foreach ($scriptName in $existingScripts.Keys) {
            $scriptInfo = $existingScripts[$scriptName]
            if (-not (Test-HydrationKitObject -Description $scriptInfo.Description -ObjectName $scriptName)) {
                Write-Verbose "Skipping '$scriptName' - not created by Intune Hydration Kit"
                continue
            }

            $escapedPrefix = [regex]::Escape($script:ImportPrefix)
            $nameForLookup = $scriptName -replace "^$escapedPrefix", ''
            if (-not ($knownTemplateNames.Contains($scriptName) -or $knownTemplateNames.Contains($nameForLookup))) {
                Write-Verbose "Skipping '$scriptName' - not in this kit's Linux script templates"
                continue
            }

            $scriptsToDelete += @{
                Name = $scriptName
                Id   = $scriptInfo.Id
            }
        }

        if ($scriptsToDelete.Count -eq 0) {
            Write-Verbose 'No Linux scripts found to delete'
            return $results
        }

        if (-not $PSCmdlet.ShouldProcess("$($scriptsToDelete.Count) Linux script(s)", 'Delete')) {
            if ($WhatIfPreference) {
                foreach ($script in $scriptsToDelete) {
                    Write-HydrationLog -Message "  WouldDelete: $($script.Name)" -Level Info
                    $results += New-HydrationResult -Name $script.Name -Platform 'Linux' -Type 'LinuxScript' -Action 'WouldDelete' -Status 'DryRun'
                }
            }
            return $results
        }

        $results += Invoke-GraphBatchOperation -Items $scriptsToDelete -Operation 'DELETE' -BaseUrl '/deviceManagement/deviceShellScripts' -ResultType 'LinuxScript'
        return $results
    }

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

            $scriptBody = @{
                displayName                 = $displayName
                description                 = New-HydrationDescription -ExistingText $template.description
                fileName                    = if ($template.fileName) { $template.fileName } else { $templateFile.Name -replace '\.json$', '.sh' }
                scriptContent               = $template.scriptContentBase64
                runAsAccount                = if ($template.runAsAccount) { $template.runAsAccount } else { 'system' }
                executionFrequency          = if ($template.executionFrequency) { $template.executionFrequency } else { 'PT0S' }
                retryCount                  = if ($null -ne $template.retryCount) { [int]$template.retryCount } else { 3 }
                blockExecutionNotifications = if ($null -ne $template.blockExecutionNotifications) { [bool]$template.blockExecutionNotifications } else { $false }
                roleScopeTagIds             = if ($template.roleScopeTagIds) { @($template.roleScopeTagIds) } else { @('0') }
            }

            $scriptsToCreate += @{
                Name     = $displayName
                Path     = $templateFile.FullName
                Platform = 'Linux'
                BodyJson = ($scriptBody | ConvertTo-Json -Depth 20 -Compress)
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
        $results += Invoke-GraphBatchOperation -Items $scriptsToCreate -Operation 'POST' -BaseUrl '/deviceManagement/deviceShellScripts' -ResultType 'LinuxScript'
    }

    return $results
}
