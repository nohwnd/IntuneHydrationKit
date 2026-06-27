function Invoke-HydrationCustomCompliancePolicyCreate {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory)]
        [object[]]$PolicyInfo,

        [Parameter(Mandatory)]
        [hashtable]$ExistingDependencyMap,

        [Parameter(Mandatory)]
        [ValidateSet('DeviceComplianceScript', 'ReusablePolicySetting')]
        [string]$DependencyKind,

        [Parameter()]
        [string]$ReusableSettingDefinitionId
    )

    $results = @()

    function New-HydrationReusablePolicySettingDependency {
        param(
            [Parameter(Mandatory)]
            [object]$ScriptDefinition,

            [Parameter(Mandatory)]
            [object]$ScriptName,

            [Parameter(Mandatory)]
            [string]$SettingDefinitionId
        )

        $reusableSettingBody = @{
            displayName         = $ScriptName.DisplayName
            description         = New-HydrationDescription -ExistingText $ScriptDefinition.description
            settingDefinitionId = $SettingDefinitionId
            settingInstance     = @{
                '@odata.type'       = '#microsoft.graph.deviceManagementConfigurationSimpleSettingInstance'
                settingDefinitionId = $SettingDefinitionId
                simpleSettingValue  = @{
                    '@odata.type' = '#microsoft.graph.deviceManagementConfigurationStringSettingValue'
                    value         = $ScriptDefinition.detectionScriptContentBase64
                }
            }
        }

        $newReusableSetting = Invoke-MgGraphRequest `
            -Method POST `
            -Uri 'beta/deviceManagement/reusablePolicySettings' `
            -Body ($reusableSettingBody | ConvertTo-Json -Depth 100) `
            -ContentType 'application/json' `
            -ErrorAction Stop

        $ExistingDependencyMap[$ScriptName.DisplayName] = @{
            Id       = $newReusableSetting.id
            IsTagged = $true
        }

        return $newReusableSetting.id
    }

    function New-HydrationDeviceComplianceScriptDependency {
        param(
            [Parameter(Mandatory)]
            [object]$ScriptDefinition,

            [Parameter(Mandatory)]
            [object]$ScriptName
        )

        $scriptBody = @{
            description            = New-HydrationDescription -ExistingText $(if ($ScriptDefinition.description) { $ScriptDefinition.description } else { '' })
            detectionScriptContent = $ScriptDefinition.detectionScriptContentBase64
            displayName            = $ScriptName.DisplayName
            enforceSignatureCheck  = [bool]$ScriptDefinition.enforceSignatureCheck
            publisher              = if ($ScriptDefinition.publisher) { $ScriptDefinition.publisher } else { 'Publisher' }
            runAs32Bit             = [bool]$ScriptDefinition.runAs32Bit
            runAsAccount           = if ($ScriptDefinition.runAsAccount) { $ScriptDefinition.runAsAccount } else { 'system' }
        }

        $newScript = Invoke-MgGraphRequest `
            -Method POST `
            -Uri 'beta/deviceManagement/deviceComplianceScripts' `
            -Body ($scriptBody | ConvertTo-Json -Depth 10) `
            -ContentType 'application/json' `
            -ErrorAction Stop

        $ExistingDependencyMap[$ScriptName.DisplayName] = @{
            Id       = $newScript.id
            IsTagged = $true
        }

        return $newScript.id
    }

    function New-HydrationCustomComplianceDependency {
        param(
            [Parameter(Mandatory)]
            [object]$ScriptDefinition,

            [Parameter(Mandatory)]
            [object]$ScriptName,

            [Parameter()]
            [string]$SettingDefinitionId
        )

        if ($DependencyKind -eq 'ReusablePolicySetting') {
            return New-HydrationReusablePolicySettingDependency -ScriptDefinition $ScriptDefinition -ScriptName $ScriptName -SettingDefinitionId $SettingDefinitionId
        }

        return New-HydrationDeviceComplianceScriptDependency -ScriptDefinition $ScriptDefinition -ScriptName $ScriptName
    }

    function Add-HydrationCustomComplianceDependencyToPolicy {
        param(
            [Parameter(Mandatory)]
            [object]$ImportBody,

            [Parameter(Mandatory)]
            [string]$DependencyId,

            [Parameter(Mandatory)]
            [string]$RulesContentBase64
        )

        if ($DependencyKind -eq 'ReusablePolicySetting') {
            $customComplianceSetting = New-HydrationLinuxCustomComplianceSetting `
                -ReusableSettingId $DependencyId `
                -RulesContentBase64 $RulesContentBase64

            [object[]]$settings = if ($ImportBody.settings) { @($ImportBody.settings) } else { @() }
            $settings += $customComplianceSetting
            if ($ImportBody.PSObject.Properties['settings']) {
                $ImportBody.settings = $settings
            } else {
                $ImportBody | Add-Member -MemberType NoteProperty -Name settings -Value $settings
            }

            return
        }

        $ImportBody.deviceCompliancePolicyScript = @{
            deviceComplianceScriptId = $DependencyId
            rulesContent             = $RulesContentBase64
        }
    }

    foreach ($currentPolicyInfo in $PolicyInfo) {
        $displayName = $currentPolicyInfo.Name
        $templateFile = @{ FullName = $currentPolicyInfo.Path }
        $importBody = $currentPolicyInfo.ImportBody
        $template = $currentPolicyInfo.Template
        $endpoint = "beta/$($currentPolicyInfo.Endpoint)"

        try {
            $scriptDefinition = $template.deviceCompliancePolicyScriptDefinition
            $scriptName = Get-HydrationComplianceScriptName -ScriptDefinition $scriptDefinition -PolicyDisplayName $displayName
            if (-not $scriptDefinition -or -not $scriptDefinition.detectionScriptContentBase64) {
                Write-Warning "Skipping compliance policy '$displayName' - no script definition found with detectionScriptContentBase64"
                $results += New-HydrationResult -Name $displayName -Path $templateFile.FullName -Type 'CompliancePolicy' -Action 'Failed' -Status 'Missing detectionScriptContentBase64 in deviceCompliancePolicyScriptDefinition'
                continue
            }

            $rulesSource = $scriptDefinition.rules
            if (-not $rulesSource) {
                Write-Warning "Skipping compliance policy '$displayName' - no rules found in deviceCompliancePolicyScriptDefinition"
                $results += New-HydrationResult -Name $displayName -Path $templateFile.FullName -Type 'CompliancePolicy' -Action 'Failed' -Status 'Missing rules in deviceCompliancePolicyScriptDefinition'
                continue
            }

            $rulesJson = $rulesSource | ConvertTo-Json -Depth 100 -Compress
            $rulesBytes = [System.Text.Encoding]::UTF8.GetBytes($rulesJson)
            $rulesBase64 = [System.Convert]::ToBase64String($rulesBytes)

            $displayEntry = if ($ExistingDependencyMap.ContainsKey($scriptName.DisplayName)) { $ExistingDependencyMap[$scriptName.DisplayName] } else { $null }
            $baseEntry = if ($ExistingDependencyMap.ContainsKey($scriptName.BaseName)) { $ExistingDependencyMap[$scriptName.BaseName] } else { $null }

            if ($displayEntry -and ($DependencyKind -ne 'ReusablePolicySetting' -or $displayEntry.IsTagged)) {
                $dependencyId = $displayEntry.Id
            } elseif ($baseEntry -and ($DependencyKind -ne 'ReusablePolicySetting' -or $baseEntry.IsTagged)) {
                $dependencyId = $baseEntry.Id
            } else {
                $dependencyId = New-HydrationCustomComplianceDependency -ScriptDefinition $scriptDefinition -ScriptName $scriptName -SettingDefinitionId $ReusableSettingDefinitionId
            }

            Add-HydrationCustomComplianceDependencyToPolicy -ImportBody $importBody -DependencyId $dependencyId -RulesContentBase64 $rulesBase64

            if ($importBody.PSObject.Properties['deviceCompliancePolicyScriptDefinition']) {
                $null = $importBody.PSObject.Properties.Remove('deviceCompliancePolicyScriptDefinition')
            }

            $null = Invoke-MgGraphRequest -Method POST -Uri $endpoint -Body ($importBody | ConvertTo-Json -Depth 100) -ContentType 'application/json' -ErrorAction Stop
            Write-HydrationLog -Message "  Created: $displayName" -Level Info
            $results += New-HydrationResult -Name $displayName -Path $templateFile.FullName -Type 'CompliancePolicy' -Action 'Created' -Status 'Success'
        } catch {
            $errMessage = Get-GraphErrorMessage -ErrorRecord $_
            Write-HydrationLog -Message "  Failed: $displayName - $errMessage" -Level Warning
            $results += New-HydrationResult -Name $displayName -Path $templateFile.FullName -Type 'CompliancePolicy' -Action 'Failed' -Status $errMessage
        }
    }

    return $results
}
