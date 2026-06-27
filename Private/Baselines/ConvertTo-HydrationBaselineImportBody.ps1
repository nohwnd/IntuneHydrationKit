function ConvertTo-HydrationBaselineImportBody {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$PolicyContent,

        [Parameter(Mandatory)]
        [string]$DisplayName,

        [Parameter(Mandatory)]
        [string]$Endpoint,

        [Parameter()]
        [string[]]$AdditionalReadOnlyProperties = @(),

        [Parameter()]
        [scriptblock]$SettingTransform
    )

    $importBody = Copy-DeepObject -InputObject $PolicyContent
    Remove-ReadOnlyGraphProperties -InputObject $importBody -AdditionalProperties $AdditionalReadOnlyProperties

    $importBody.description = New-HydrationDescription -ExistingText $importBody.description
    if ($importBody.displayName) { $importBody.displayName = $DisplayName }
    if ($importBody.name) { $importBody.name = $DisplayName }

    if ($Endpoint -eq 'deviceManagement/groupPolicyConfigurations' -and $importBody.PSObject.Properties['definitionValues']) {
        $importBody.definitionValues = @($importBody.definitionValues)
        foreach ($definitionValue in $importBody.definitionValues) {
            if ($definitionValue -and $definitionValue.PSObject.Properties['presentationValues']) {
                $definitionValue.presentationValues = @($definitionValue.presentationValues)
            }
        }
    }

    if ($Endpoint -eq 'deviceManagement/configurationPolicies') {
        $cleanBody = @{
            name         = $importBody.name
            description  = $importBody.description
            platforms    = $importBody.platforms
            technologies = $importBody.technologies
            settings     = @()
        }

        if ($importBody.roleScopeTagIds) {
            $cleanBody.roleScopeTagIds = $importBody.roleScopeTagIds
        }
        if ($importBody.templateReference -and $importBody.templateReference.templateId) {
            $cleanBody.templateReference = @{
                templateId = $importBody.templateReference.templateId
            }
        }

        if ($importBody.settings) {
            foreach ($setting in $importBody.settings) {
                $cleanSetting = $setting | ConvertTo-Json -Depth 100 -Compress | ConvertFrom-Json
                Remove-ReadOnlyGraphProperties -InputObject $cleanSetting -AdditionalProperties @('settingDefinitions')
                if ($SettingTransform) {
                    & $SettingTransform $cleanSetting
                }
                $cleanBody.settings += $cleanSetting
            }
        }

        $importBody = [PSCustomObject]$cleanBody
    }

    if ($importBody.scheduledActionsForRule) {
        $cleanedActions = @()
        foreach ($action in $importBody.scheduledActionsForRule) {
            $cleanAction = @{
                ruleName = $action.ruleName
            }
            if ($action.scheduledActionConfigurations) {
                $cleanConfigs = @()
                foreach ($config in $action.scheduledActionConfigurations) {
                    $ccList = @()
                    if ($null -ne $config.notificationMessageCCList -and $config.notificationMessageCCList.Count -gt 0) {
                        $ccList = @($config.notificationMessageCCList)
                    }
                    $cleanConfigs += @{
                        actionType                = $config.actionType
                        gracePeriodHours          = [int]$config.gracePeriodHours
                        notificationTemplateId    = if ($config.notificationTemplateId) { $config.notificationTemplateId } else { "" }
                        notificationMessageCCList = $ccList
                    }
                }
                $cleanAction.scheduledActionConfigurations = $cleanConfigs
            }
            $cleanedActions += $cleanAction
        }
        $importBody.scheduledActionsForRule = $cleanedActions
    }

    return $importBody
}
