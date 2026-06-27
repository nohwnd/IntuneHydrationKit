function New-HydrationLinuxCustomComplianceSetting {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$ReusableSettingId,

        [Parameter(Mandatory)]
        [string]$RulesContentBase64
    )

    return @{
        '@odata.type'   = '#microsoft.graph.deviceManagementConfigurationSetting'
        settingInstance = @{
            '@odata.type'       = '#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance'
            settingDefinitionId = 'linux_customcompliance_required'
            choiceSettingValue  = @{
                '@odata.type' = '#microsoft.graph.deviceManagementConfigurationChoiceSettingValue'
                value         = 'linux_customcompliance_required_true'
                children      = @(
                    @{
                        '@odata.type'        = '#microsoft.graph.deviceManagementConfigurationSimpleSettingInstance'
                        settingDefinitionId  = 'linux_customcompliance_discoveryscript'
                        simpleSettingValue   = @{
                            '@odata.type' = '#microsoft.graph.deviceManagementConfigurationReferenceSettingValue'
                            value         = $ReusableSettingId
                        }
                    }
                    @{
                        '@odata.type'        = '#microsoft.graph.deviceManagementConfigurationSimpleSettingInstance'
                        settingDefinitionId  = 'linux_customcompliance_rules'
                        simpleSettingValue   = @{
                            '@odata.type' = '#microsoft.graph.deviceManagementConfigurationStringSettingValue'
                            value         = $RulesContentBase64
                        }
                    }
                )
            }
        }
    }
}
