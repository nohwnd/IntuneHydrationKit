function Import-IntuneCompliancePolicy {
    <#
    .SYNOPSIS
        Imports device compliance policies from templates
    .DESCRIPTION
        Reads JSON templates from Templates/Compliance and creates compliance policies via Graph.
    .PARAMETER TemplatePath
        Path to the compliance template directory (defaults to Templates/Compliance)
    .PARAMETER Platform
        Filter templates by platform. Valid values: Windows, macOS, iOS, Android, Linux, All.
        Defaults to 'All' which imports all compliance templates regardless of platform.
    .EXAMPLE
        Import-IntuneCompliancePolicy
    .EXAMPLE
        Import-IntuneCompliancePolicy -Platform Windows,macOS
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [string]$TemplatePath,

        [Parameter()]
        [ValidateSet('Windows', 'macOS', 'iOS', 'Android', 'Linux', 'All')]
        [string[]]$Platform = @('All'),

        [Parameter()]
        [switch]$RemoveExisting
    )

    if (-not $TemplatePath) {
        $TemplatePath = Join-Path -Path $script:TemplatesPath -ChildPath "Compliance"
    }

    if (-not (Test-Path -Path $TemplatePath)) {
        Write-Warning "Compliance template directory not found: $TemplatePath"
        return @()
    }

    $templateFiles = Get-FilteredTemplates -Path $TemplatePath -Platform $Platform -FilterMode 'Prefix' -Recurse -ResourceType "compliance template"

    if (-not $templateFiles -or $templateFiles.Count -eq 0) {
        Write-Warning "No compliance templates found in: $TemplatePath"
        return @()
    }

    $linuxDiscoveryScriptReusableSettingDefinitionId = 'linux_customcompliance_discoveryscript_reusablesetting'
    $results = @()

    # Remove existing policies if requested
    # SAFETY: Only delete policies with both hydration marker and matching selected template name.
    if ($RemoveExisting) {
        $knownPolicyNames = Get-HydrationCompliancePolicyTemplateNameSet -TemplateFile $templateFiles
        $deleteEndpoints = @(
            'beta/deviceManagement/deviceCompliancePolicies',
            'beta/deviceManagement/compliancePolicies'
        )
        $policiesToDelete = Get-HydrationDeleteCandidates -Endpoint $deleteEndpoints -KnownTemplateNames $knownPolicyNames -RequireTemplateMatch

        $scriptsToDelete = @()
        $reusableSettingsToDelete = @()
        $knownScriptNames = Get-HydrationComplianceScriptTemplateNameSet -TemplateFile $templateFiles
        if ($knownScriptNames.Count -gt 0) {
            $scriptsToDelete = Get-HydrationDeleteCandidates `
                -Endpoint "beta/deviceManagement/deviceComplianceScripts?`$select=id,displayName,description" `
                -DeleteBaseUrl '/deviceManagement/deviceComplianceScripts' `
                -KnownTemplateNames $knownScriptNames `
                -RequireTemplateMatch

            $reusableSettingsToDelete = Get-HydrationDeleteCandidates `
                -Endpoint "beta/deviceManagement/reusablePolicySettings?`$select=id,displayName,description,settingDefinitionId&`$filter=settingDefinitionId eq '$linuxDiscoveryScriptReusableSettingDefinitionId'" `
                -DeleteBaseUrl '/deviceManagement/reusablePolicySettings' `
                -KnownTemplateNames $knownScriptNames `
                -RequireTemplateMatch
        }

        if (($policiesToDelete.Count + $scriptsToDelete.Count + $reusableSettingsToDelete.Count) -eq 0) {
            Write-Verbose "No compliance policies, scripts, or reusable settings found to delete"
            return $results
        }

        # Handle WhatIf mode
        $deleteTarget = "$($policiesToDelete.Count) compliance policy/policies, $($scriptsToDelete.Count) compliance script(s), and $($reusableSettingsToDelete.Count) reusable setting(s)"
        if (-not $PSCmdlet.ShouldProcess($deleteTarget, "Delete")) {
            foreach ($policy in $policiesToDelete) {
                Write-HydrationLog -Message "  WouldDelete: $($policy.Name)" -Level Info
                $results += New-HydrationResult -Name $policy.Name -Type 'CompliancePolicy' -Action 'WouldDelete' -Status 'DryRun'
            }
            foreach ($scriptItem in $scriptsToDelete) {
                Write-HydrationLog -Message "  WouldDelete: $($scriptItem.Name)" -Level Info
                $results += New-HydrationResult -Name $scriptItem.Name -Type 'ComplianceScript' -Action 'WouldDelete' -Status 'DryRun'
            }
            foreach ($settingItem in $reusableSettingsToDelete) {
                Write-HydrationLog -Message "  WouldDelete: $($settingItem.Name)" -Level Info
                $results += New-HydrationResult -Name $settingItem.Name -Type 'ReusablePolicySetting' -Action 'WouldDelete' -Status 'DryRun'
            }
            return $results
        }

        if ($policiesToDelete.Count -gt 0) {
            $results += Invoke-GraphBatchOperation -Items $policiesToDelete -Operation 'DELETE' -ResultType 'CompliancePolicy'
        }
        if ($scriptsToDelete.Count -gt 0) {
            $results += Invoke-GraphBatchOperation -Items $scriptsToDelete -Operation 'DELETE' -BaseUrl '/deviceManagement/deviceComplianceScripts' -ResultType 'ComplianceScript'
        }
        if ($reusableSettingsToDelete.Count -gt 0) {
            $results += Invoke-GraphBatchOperation -Items $reusableSettingsToDelete -Operation 'DELETE' -BaseUrl '/deviceManagement/reusablePolicySettings' -ResultType 'ReusablePolicySetting'
        }

        return $results
    }

    $existingPolicies = @{}
    $endpointsToList = @(
        @{ Uri = 'beta/deviceManagement/deviceCompliancePolicies'; Select = 'id,displayName,description'; NameProperty = 'displayName' },
        @{ Uri = 'beta/deviceManagement/compliancePolicies'; Select = 'id,name,description'; NameProperty = 'name' }
    )
    foreach ($ep in $endpointsToList) {
        $listUri = "$($ep.Uri)`?`$select=$($ep.Select)"
        $endpointPolicies = Get-HydrationExistingObjectMap `
            -Uri $listUri `
            -NameProperty $ep.NameProperty `
            -Endpoint $ep.Uri

        foreach ($policyName in $endpointPolicies.Keys) {
            if (-not $existingPolicies.ContainsKey($policyName) -or
                ($endpointPolicies[$policyName].IsTagged -and -not $existingPolicies[$policyName].IsTagged)) {
                $existingPolicies[$policyName] = $endpointPolicies[$policyName]
            }
        }
    }

    # Collect policies to create - separate standard and custom (with scripts)
    $standardPoliciesToCreate = @()
    $customPoliciesToCreate = @()
    $linuxCustomPoliciesToCreate = @()

    foreach ($templateFile in $templateFiles) {
        try {
            $template = Get-Content -Path $templateFile.FullName -Raw -Encoding utf8 | ConvertFrom-Json
            $isLinuxCompliance = $template.platforms -eq 'linux' -and $template.technologies -eq 'linuxMdm'
            $templatePolicyName = if ($template.displayName) {
                $template.displayName
            } elseif ($isLinuxCompliance -and $template.name) {
                $template.name
            } else {
                $null
            }
            if (-not $templatePolicyName) {
                Write-Warning "Template missing displayName/name: $($templateFile.FullName)"
                $results += New-HydrationResult -Name $templateFile.Name -Path $templateFile.FullName -Type 'CompliancePolicy' -Action 'Failed' -Status 'Missing displayName'
                continue
            }
            $displayName = if ($templatePolicyName.StartsWith($script:ImportPrefix)) {
                $templatePolicyName
            } else {
                "$($script:ImportPrefix)$templatePolicyName"
            }

            # Choose endpoint: Linux uses compliancePolicies, others use deviceCompliancePolicies
            $endpoint = if ($isLinuxCompliance) {
                "deviceManagement/compliancePolicies"
            } else {
                "deviceManagement/deviceCompliancePolicies"
            }

            # Check both prefixed and unprefixed names to avoid duplicates when upgrading from pre-prefix tenants
            $lookupNames = @($displayName)
            if ($templatePolicyName -ne $displayName) {
                $lookupNames += $templatePolicyName
            }
            if ($isLinuxCompliance -and $template.name -and $template.name -ne $templatePolicyName) {
                $lookupNames += $template.name
            }

            $alreadyExists = $false
            foreach ($ln in $lookupNames) {
                if ($existingPolicies.ContainsKey($ln) -and $existingPolicies[$ln].IsTagged) {
                    $alreadyExists = $true
                    break
                }
            }

            if ($alreadyExists) {
                Write-HydrationLog -Message "  Skipped: $displayName" -Level Info
                $results += New-HydrationResult -Name $displayName -Path $templateFile.FullName -Type 'CompliancePolicy' -Action 'Skipped' -Status 'Already exists'
                continue
            }

            $importBody = Copy-DeepObject -InputObject $template
            Remove-ReadOnlyGraphProperties -InputObject $importBody

            # Apply import prefix to body
            if ($importBody.displayName) { $importBody.displayName = $displayName }

            # Add hydration kit tag to description
            $importBody.description = New-HydrationDescription -ExistingText $importBody.description

            # Linux endpoint expects 'name' instead of displayName; ensure it matches the prefixed name
            if ($isLinuxCompliance) {
                $importBody | Add-Member -MemberType NoteProperty -Name name -Value $displayName -Force
            }

            # Custom compliance policies with scripts need sequential processing
            $isLinuxCustomCompliance = $isLinuxCompliance -and $importBody.PSObject.Properties['deviceCompliancePolicyScriptDefinition']
            if ($isLinuxCustomCompliance) {
                if ($importBody.PSObject.Properties['deviceCompliancePolicyScript']) {
                    $null = $importBody.PSObject.Properties.Remove('deviceCompliancePolicyScript')
                }

                $linuxCustomPoliciesToCreate += @{
                    Name       = $displayName
                    Path       = $templateFile.FullName
                    Endpoint   = $endpoint
                    ImportBody = $importBody
                    Template   = $template
                }
            } elseif ($importBody.deviceCompliancePolicyScript) {
                $customPoliciesToCreate += @{
                    Name       = $displayName
                    Path       = $templateFile.FullName
                    Endpoint   = $endpoint
                    ImportBody = $importBody
                    Template   = $template
                }
            } else {
                # Remove internal helper definition before storing
                if ($importBody.PSObject.Properties['deviceCompliancePolicyScriptDefinition']) {
                    $null = $importBody.PSObject.Properties.Remove('deviceCompliancePolicyScriptDefinition')
                }

                # Store body as JSON string to avoid PowerShell serialization issues
                $standardPoliciesToCreate += @{
                    Name     = $displayName
                    Path     = $templateFile.FullName
                    Url      = "/$endpoint"
                    BodyJson = ($importBody | ConvertTo-Json -Depth 100 -Compress)
                }
            }
        } catch {
            $errMessage = Get-GraphErrorMessage -ErrorRecord $_
            Write-HydrationLog -Message "  Failed to prepare: $($templateFile.Name) - $errMessage" -Level Warning
            $results += New-HydrationResult -Name $templateFile.Name -Path $templateFile.FullName -Type 'CompliancePolicy' -Action 'Failed' -Status "Prepare error: $errMessage"
        }
    }

    # Handle WhatIf mode
    $policiesToCreateCount = $standardPoliciesToCreate.Count + $customPoliciesToCreate.Count + $linuxCustomPoliciesToCreate.Count
    if (-not $PSCmdlet.ShouldProcess("$policiesToCreateCount compliance policies", "Create")) {
        foreach ($policy in $standardPoliciesToCreate) {
            Write-HydrationLog -Message "  WouldCreate: $($policy.Name)" -Level Info
            $results += New-HydrationResult -Name $policy.Name -Path $policy.Path -Type 'CompliancePolicy' -Action 'WouldCreate' -Status 'DryRun'
        }
        foreach ($policy in $linuxCustomPoliciesToCreate) {
            Write-HydrationLog -Message "  WouldCreate: $($policy.Name)" -Level Info
            $results += New-HydrationResult -Name $policy.Name -Path $policy.Path -Type 'CompliancePolicy' -Action 'WouldCreate' -Status 'DryRun'
        }
        foreach ($policy in $customPoliciesToCreate) {
            Write-HydrationLog -Message "  WouldCreate: $($policy.Name)" -Level Info
            $results += New-HydrationResult -Name $policy.Name -Path $policy.Path -Type 'CompliancePolicy' -Action 'WouldCreate' -Status 'DryRun'
        }
        return $results
    }

    # Batch create standard policies using centralized helper
    if ($standardPoliciesToCreate.Count -gt 0) {
        $results += Invoke-GraphBatchOperation -Items $standardPoliciesToCreate -Operation 'POST' -ResultType 'CompliancePolicy'
    }

    if ($linuxCustomPoliciesToCreate.Count -gt 0) {
        $existingReusableSettings = Get-HydrationReusablePolicySettingMap -SettingDefinitionId $linuxDiscoveryScriptReusableSettingDefinitionId
        $results += Invoke-HydrationCustomCompliancePolicyCreate `
            -PolicyInfo $linuxCustomPoliciesToCreate `
            -ExistingDependencyMap $existingReusableSettings `
            -DependencyKind ReusablePolicySetting `
            -ReusableSettingDefinitionId $linuxDiscoveryScriptReusableSettingDefinitionId
    }

    if ($customPoliciesToCreate.Count -gt 0) {
        $existingComplianceScripts = Get-HydrationExistingObjectMap `
            -Uri "beta/deviceManagement/deviceComplianceScripts?`$select=id,displayName,description"
        $results += Invoke-HydrationCustomCompliancePolicyCreate `
            -PolicyInfo $customPoliciesToCreate `
            -ExistingDependencyMap $existingComplianceScripts `
            -DependencyKind DeviceComplianceScript
    }

    return $results
}
