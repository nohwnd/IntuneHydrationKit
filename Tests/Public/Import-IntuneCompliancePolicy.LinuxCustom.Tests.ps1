#Requires -Modules Pester

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\..\'
    Import-Module (Join-Path $modulePath 'IntuneHydrationKit.psd1') -Force

    function New-TestLinuxCustomComplianceTemplateJson {
        param(
            [Parameter()]
            [string]$PolicyName = 'Linux Custom Compliance Policy',

            [Parameter()]
            [string]$ScriptName = 'Linux Custom Compliance Script',

            [Parameter()]
            [switch]$OmitRules
        )

        $scriptDefinition = @{
            displayName                  = $ScriptName
            description                  = 'Discovery script'
            detectionScriptContentBase64 = 'ZGV0ZWN0aW9u'
            enforceSignatureCheck        = $false
            publisher                    = 'Intune Hydration Kit'
            runAs32Bit                   = $false
            runAsAccount                 = 'user'
            rules                        = @{
                Rules = @(
                    @{
                        SettingName        = 'UfwEnabled'
                        Operator           = 'IsEquals'
                        DataType           = 'Boolean'
                        Operand            = $true
                        MoreInfoUrl        = 'https://help.ubuntu.com/community/UFW'
                        RemediationStrings = @(
                            @{
                                Language    = 'en_US'
                                Title       = 'Firewall must be enabled.'
                                Description = 'Enable the firewall.'
                            }
                        )
                    }
                )
            }
        }
        if ($OmitRules) {
            $scriptDefinition.Remove('rules')
        }

        @{
            displayName                            = $PolicyName
            name                                   = $PolicyName
            description                            = 'Linux custom compliance'
            platforms                              = 'linux'
            technologies                           = 'linuxMdm'
            roleScopeTagIds                        = @('0')
            settings                               = @()
            deviceCompliancePolicyScript           = @{}
            deviceCompliancePolicyScriptDefinition = $scriptDefinition
        } | ConvertTo-Json -Depth 20
    }
}

Describe 'Import-IntuneCompliancePolicy Linux custom compliance' {
    BeforeAll {
        Mock Write-HydrationLog -ModuleName IntuneHydrationKit
        Mock Get-GraphErrorMessage { return 'Test error message' } -ModuleName IntuneHydrationKit
        Mock Test-HydrationKitObject { return $true } -ModuleName IntuneHydrationKit
    }

    BeforeEach {
        Mock Get-FilteredTemplates {
            @([PSCustomObject]@{ FullName = 'TestPath\Linux-Custom-Compliance.json'; Name = 'Linux-Custom-Compliance.json' })
        } -ModuleName IntuneHydrationKit
    }

    It 'Should create Linux custom compliance policies through reusable policy settings' {
        Mock Get-Content {
            New-TestLinuxCustomComplianceTemplateJson
        } -ModuleName IntuneHydrationKit

        Mock Get-GraphPagedResults {
            param($Uri, $ProcessItems)

            if ($Uri -like '*reusablePolicySettings*' -and $ProcessItems) {
                & $ProcessItems @()
            }
        } -ModuleName IntuneHydrationKit

        $script:capturedReusableSettingBody = $null
        $script:capturedLinuxPolicyBody = $null
        Mock Invoke-MgGraphRequest {
            param($Method, $Uri, $Body)

            if ($Method -eq 'GET') {
                return @{ value = @() }
            }
            if ($Method -eq 'POST' -and $Uri -eq 'beta/deviceManagement/reusablePolicySettings') {
                $script:capturedReusableSettingBody = $Body | ConvertFrom-Json
                return @{ id = 'reusable-setting-id' }
            }
            if ($Method -eq 'POST' -and $Uri -eq 'beta/deviceManagement/compliancePolicies') {
                $script:capturedLinuxPolicyBody = $Body | ConvertFrom-Json
                return @{ id = 'linux-policy-id' }
            }
        } -ModuleName IntuneHydrationKit

        $result = Import-IntuneCompliancePolicy -Platform Linux

        $result | Should -HaveCount 1
        $result[0].Action | Should -Be 'Created'

        $script:capturedReusableSettingBody.displayName | Should -Be '[IHD] Linux Custom Compliance Script'
        $script:capturedReusableSettingBody.description | Should -Match 'Imported by Intune Hydration Kit'
        $script:capturedReusableSettingBody.settingDefinitionId | Should -Be 'linux_customcompliance_discoveryscript_reusablesetting'
        $script:capturedReusableSettingBody.settingInstance.simpleSettingValue.value | Should -Be 'ZGV0ZWN0aW9u'

        $script:capturedLinuxPolicyBody.name | Should -Be '[IHD] Linux Custom Compliance Policy'
        $script:capturedLinuxPolicyBody.PSObject.Properties['deviceCompliancePolicyScript'] | Should -BeNullOrEmpty
        $script:capturedLinuxPolicyBody.PSObject.Properties['deviceCompliancePolicyScriptDefinition'] | Should -BeNullOrEmpty

        $customSetting = @($script:capturedLinuxPolicyBody.settings)[0]
        $customSetting.settingInstance.settingDefinitionId | Should -Be 'linux_customcompliance_required'
        $customSetting.settingInstance.choiceSettingValue.value | Should -Be 'linux_customcompliance_required_true'

        $children = @($customSetting.settingInstance.choiceSettingValue.children)
        $children | Should -HaveCount 2
        $children[0].settingDefinitionId | Should -Be 'linux_customcompliance_discoveryscript'
        $children[0].simpleSettingValue.'@odata.type' | Should -Be '#microsoft.graph.deviceManagementConfigurationReferenceSettingValue'
        $children[0].simpleSettingValue.value | Should -Be 'reusable-setting-id'
        $children[1].settingDefinitionId | Should -Be 'linux_customcompliance_rules'
        [string]::IsNullOrWhiteSpace([string]$children[1].simpleSettingValue.value) | Should -BeFalse

        Should -Invoke Invoke-MgGraphRequest -ModuleName IntuneHydrationKit -ParameterFilter {
            $Method -eq 'POST' -and $Uri -eq 'beta/deviceManagement/deviceComplianceScripts'
        } -Times 0
    }

    It 'Should not create reusable policy settings when Linux custom compliance rules are missing' {
        Mock Get-Content {
            New-TestLinuxCustomComplianceTemplateJson -OmitRules
        } -ModuleName IntuneHydrationKit

        Mock Get-GraphPagedResults {
            param($Uri, $ProcessItems)

            if ($Uri -like '*reusablePolicySettings*' -and $ProcessItems) {
                & $ProcessItems @()
            }
        } -ModuleName IntuneHydrationKit

        Mock Invoke-MgGraphRequest {
            param($Method, $Uri)

            if ($Method -eq 'GET') {
                return @{ value = @() }
            }
            if ($Method -eq 'POST') {
                throw "Unexpected POST to $Uri"
            }
        } -ModuleName IntuneHydrationKit

        $result = Import-IntuneCompliancePolicy -Platform Linux

        $result | Should -HaveCount 1
        $result[0].Action | Should -Be 'Failed'
        $result[0].Status | Should -Be 'Missing rules in deviceCompliancePolicyScriptDefinition'
        Should -Invoke Invoke-MgGraphRequest -ModuleName IntuneHydrationKit -ParameterFilter {
            $Method -eq 'POST'
        } -Times 0
    }

    It 'Should delete only tagged Linux reusable settings that match selected templates' {
        Mock Get-Content {
            New-TestLinuxCustomComplianceTemplateJson
        } -ModuleName IntuneHydrationKit
        Mock Test-HydrationKitObject {
            param($Description)

            return $Description -like '*Imported by Intune Hydration Kit*'
        } -ModuleName IntuneHydrationKit
        Mock Invoke-MgGraphRequest {
            param($Method)

            if ($Method -eq 'GET') {
                return @{ value = @() }
            }
        } -ModuleName IntuneHydrationKit
        Mock Get-GraphPagedResults {
            param($Uri)

            if ($Uri -like '*deviceComplianceScripts*') {
                return @()
            } elseif ($Uri -like '*reusablePolicySettings*') {
                return @(
                    @{
                        id                  = 'matching-setting-id'
                        displayName         = '[IHD] Linux Custom Compliance Script'
                        description         = 'Imported by Intune Hydration Kit'
                        settingDefinitionId = 'linux_customcompliance_discoveryscript_reusablesetting'
                    }
                    @{
                        id                  = 'other-setting-id'
                        displayName         = '[IHD] Other Linux Script'
                        description         = 'Imported by Intune Hydration Kit'
                        settingDefinitionId = 'linux_customcompliance_discoveryscript_reusablesetting'
                    }
                    @{
                        id                  = 'manual-setting-id'
                        displayName         = '[IHD] Linux Custom Compliance Script Manual'
                        description         = 'Created manually'
                        settingDefinitionId = 'linux_customcompliance_discoveryscript_reusablesetting'
                    }
                )
            }
        } -ModuleName IntuneHydrationKit
        Mock Invoke-GraphBatchOperation {
            param($Items, $Operation, $BaseUrl, $ResultType)

            $Operation | Should -Be 'DELETE'
            $BaseUrl | Should -Be '/deviceManagement/reusablePolicySettings'
            $ResultType | Should -Be 'ReusablePolicySetting'
            @($Items) | Should -HaveCount 1
            $Items[0].Name | Should -Be '[IHD] Linux Custom Compliance Script'

            New-HydrationResult -Name $Items[0].Name -Type 'ReusablePolicySetting' -Action 'Deleted' -Status 'Success'
        } -ModuleName IntuneHydrationKit

        $result = Import-IntuneCompliancePolicy -RemoveExisting -Confirm:$false

        $deletedItems = @($result | Where-Object { $_.Action -eq 'Deleted' })
        $deletedItems | Should -HaveCount 1
        $deletedItems[0].Type | Should -Be 'ReusablePolicySetting'
        Should -Invoke Invoke-GraphBatchOperation -ModuleName IntuneHydrationKit -Times 1
    }
}
