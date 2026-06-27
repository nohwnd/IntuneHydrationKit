function New-HydrationLinuxScriptConfigurationPolicyBody {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter()]
        [string]$Description,

        [Parameter(Mandatory)]
        [string[]]$RoleScopeTagIds,

        [Parameter(Mandatory)]
        [string]$ScriptContentBase64
    )

    function New-LinuxCustomConfigChoiceSetting {
        param(
            [Parameter(Mandatory)]
            [string]$SettingDefinitionId,

            [Parameter(Mandatory)]
            [string]$Value,

            [Parameter(Mandatory)]
            [string]$SettingValueTemplateId,

            [Parameter(Mandatory)]
            [string]$SettingInstanceTemplateId
        )

        return @{
            '@odata.type'   = '#microsoft.graph.deviceManagementConfigurationSetting'
            settingInstance = @{
                '@odata.type'                     = '#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance'
                settingDefinitionId               = $SettingDefinitionId
                choiceSettingValue                = @{
                    '@odata.type'                  = '#microsoft.graph.deviceManagementConfigurationChoiceSettingValue'
                    value                          = $Value
                    children                       = @()
                    settingValueTemplateReference  = @{
                        settingValueTemplateId = $SettingValueTemplateId
                    }
                }
                settingInstanceTemplateReference  = @{
                    settingInstanceTemplateId = $SettingInstanceTemplateId
                }
            }
        }
    }

    $settings = @(
        New-LinuxCustomConfigChoiceSetting `
            -SettingDefinitionId 'linux_customconfig_executioncontext' `
            -Value 'linux_customconfig_executioncontext_root' `
            -SettingValueTemplateId '119f0327-4114-444a-b53d-4b55fd579e43' `
            -SettingInstanceTemplateId '2c59a6c5-e874-445b-ac5a-d53688ef838e'
        New-LinuxCustomConfigChoiceSetting `
            -SettingDefinitionId 'linux_customconfig_executionfrequency' `
            -Value 'linux_customconfig_executionfrequency_1week' `
            -SettingValueTemplateId 'd0fb527e-606e-455f-891d-2a4de6a5db90' `
            -SettingInstanceTemplateId 'f42b866f-ff2b-4d19-bef8-63e7c763d49b'
        New-LinuxCustomConfigChoiceSetting `
            -SettingDefinitionId 'linux_customconfig_executionretries' `
            -Value 'linux_customconfig_executionretries_3' `
            -SettingValueTemplateId '92b31053-6ebb-4d2d-9e4d-081fe15d5d21' `
            -SettingInstanceTemplateId 'a3326517-152b-4b32-bc11-8772b5b4fe6a'
        @{
            '@odata.type'   = '#microsoft.graph.deviceManagementConfigurationSetting'
            settingInstance = @{
                '@odata.type'                     = '#microsoft.graph.deviceManagementConfigurationSimpleSettingInstance'
                settingDefinitionId               = 'linux_customconfig_script'
                simpleSettingValue                = @{
                    '@odata.type'                  = '#microsoft.graph.deviceManagementConfigurationStringSettingValue'
                    value                          = $ScriptContentBase64
                    settingValueTemplateReference  = @{
                        settingValueTemplateId = '18dc8a98-2ecd-4753-8baf-3ab7a1d677a9'
                    }
                }
                settingInstanceTemplateReference  = @{
                    settingInstanceTemplateId = 'add4347a-f9aa-4202-a497-34a4c178d013'
                }
            }
        }
    )

    return @{
        name              = $Name
        description       = $Description
        platforms         = 'Linux'
        technologies      = 'linuxMdm'
        roleScopeTagIds   = $RoleScopeTagIds
        settings          = $settings
        templateReference = @{
            templateId = '92439f26-2b30-4503-8429-6d40f7e172dd_1'
        }
    }
}
