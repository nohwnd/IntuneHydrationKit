function Get-HydrationReusablePolicySettingMap {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string]$SettingDefinitionId
    )

    $hasSettingDefinitionFilter = -not [string]::IsNullOrWhiteSpace($SettingDefinitionId)

    $select = 'id,displayName,description,settingDefinitionId'
    return Get-HydrationExistingObjectMap `
        -Uri "beta/deviceManagement/reusablePolicySettings?`$select=$select" `
        -Where { param($setting) -not $hasSettingDefinitionFilter -or $setting.settingDefinitionId -eq $SettingDefinitionId }
}
