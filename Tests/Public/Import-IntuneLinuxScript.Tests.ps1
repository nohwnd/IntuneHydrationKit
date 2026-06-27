#Requires -Modules Pester

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\..\'
    Import-Module (Join-Path $modulePath 'IntuneHydrationKit.psd1') -Force
}

Describe 'Import-IntuneLinuxScript' {
    BeforeAll {
        Mock Write-HydrationLog -ModuleName IntuneHydrationKit
        Mock Get-GraphErrorMessage { 'Test error message' } -ModuleName IntuneHydrationKit
    }

    BeforeEach {
        $script:TemplatePath = Join-Path -Path TestDrive: -ChildPath 'LinuxScripts'
        New-Item -Path $script:TemplatePath -ItemType Directory -Force | Out-Null
        $script:TemplateFile = Join-Path -Path $script:TemplatePath -ChildPath 'Linux-Test-Script.json'
        @{
            displayName                 = 'Linux - Default - Configuration - Test'
            description                 = 'Test Linux script'
            fileName                    = 'test.sh'
            platform                    = 'Linux'
            runAsAccount                = 'system'
            executionFrequency          = 'PT0S'
            retryCount                  = 3
            blockExecutionNotifications = $false
            roleScopeTagIds             = @('0')
            scriptContentBase64         = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('#!/bin/bash'))
        } | ConvertTo-Json -Depth 20 | Set-Content -Path $script:TemplateFile -Encoding utf8
    }

    Context 'Parameter Validation' {
        It 'Should be exported with expected parameters' {
            $command = Get-Command Import-IntuneLinuxScript

            $command.Parameters['TemplatePath'] | Should -Not -BeNullOrEmpty
            $command.Parameters['Platform'] | Should -Not -BeNullOrEmpty
            $command.Parameters['RemoveExisting'].ParameterType | Should -Be ([switch])
            $command.ScriptBlock.Attributes |
                Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] } |
                Select-Object -ExpandProperty SupportsShouldProcess |
                Should -BeTrue
        }

        It 'Should validate platform values' {
            $validateSet = (Get-Command Import-IntuneLinuxScript).Parameters['Platform'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }

            $validateSet.ValidValues | Should -Contain 'Linux'
            $validateSet.ValidValues | Should -Contain 'All'
            $validateSet.ValidValues | Should -Contain 'Windows'
        }
    }

    Context 'Create Mode' {
        It 'Should create Linux script configuration policy payloads through Graph batch' {
            Mock Get-GraphPagedResults {
                param($Uri)

                $Uri | Should -BeLike 'beta/deviceManagement/configurationPolicies*deviceConfigurationScripts*'
            } -ModuleName IntuneHydrationKit
            Mock Invoke-MgGraphRequest {
                param($Method, $Uri, $Body)

                if ($Method -eq 'POST' -and $Uri -like '*$batch*') {
                    $batch = $Body | ConvertFrom-Json
                    $request = $batch.requests[0]
                    $request.url | Should -Be '/deviceManagement/configurationPolicies'
                    $request.body.name | Should -Be '[IHD] Linux - Default - Configuration - Test'
                    $request.body.description | Should -Match 'Imported by Intune Hydration Kit'
                    $request.body.platforms | Should -Be 'Linux'
                    $request.body.technologies | Should -Be 'linuxMdm'
                    $request.body.roleScopeTagIds.GetType().IsArray | Should -BeTrue
                    $request.body.roleScopeTagIds | Should -Be @('0')
                    $request.body.templateReference.templateId | Should -Be '92439f26-2b30-4503-8429-6d40f7e172dd_1'
                    $request.body.PSObject.Properties.Name | Should -Not -Contain 'displayName'
                    $request.body.PSObject.Properties.Name | Should -Not -Contain 'fileName'
                    $request.body.PSObject.Properties.Name | Should -Not -Contain 'scriptContent'

                    $request.body.settings | Should -HaveCount 4
                    $request.body.settings[0].settingInstance.settingDefinitionId | Should -Be 'linux_customconfig_executioncontext'
                    $request.body.settings[0].settingInstance.choiceSettingValue.value | Should -Be 'linux_customconfig_executioncontext_root'
                    $request.body.settings[1].settingInstance.settingDefinitionId | Should -Be 'linux_customconfig_executionfrequency'
                    $request.body.settings[1].settingInstance.choiceSettingValue.value | Should -Be 'linux_customconfig_executionfrequency_1week'
                    $request.body.settings[2].settingInstance.settingDefinitionId | Should -Be 'linux_customconfig_executionretries'
                    $request.body.settings[2].settingInstance.choiceSettingValue.value | Should -Be 'linux_customconfig_executionretries_3'
                    $request.body.settings[3].settingInstance.settingDefinitionId | Should -Be 'linux_customconfig_script'
                    $request.body.settings[3].settingInstance.simpleSettingValue.value | Should -Be ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('#!/bin/bash')))

                    return @{
                        responses = @(
                            @{ id = '1'; status = 201; body = @{ id = 'script-id' } }
                        )
                    }
                }
            } -ModuleName IntuneHydrationKit

            $result = Import-IntuneLinuxScript -TemplatePath $script:TemplatePath

            $result | Should -HaveCount 1
            $result[0].Action | Should -Be 'Created'
            $result[0].Type | Should -Be 'LinuxScript'
            $result[0].Platform | Should -Be 'Linux'
        }

        It 'Should skip existing tagged scripts using prefixed names' {
            Mock Get-GraphPagedResults {
                param($Uri, $ProcessItems)

                $Uri | Should -BeLike 'beta/deviceManagement/configurationPolicies*deviceConfigurationScripts*'
                & $ProcessItems @(
                    @{
                        id          = 'existing-id'
                        name        = '[IHD] Linux - Default - Configuration - Test'
                        description = 'Imported by Intune Hydration Kit'
                    }
                )
            } -ModuleName IntuneHydrationKit
            Mock Invoke-MgGraphRequest -ModuleName IntuneHydrationKit

            $result = Import-IntuneLinuxScript -TemplatePath $script:TemplatePath

            $result | Should -HaveCount 1
            $result[0].Action | Should -Be 'Skipped'
            $result[0].Id | Should -Be 'existing-id'
            Should -Invoke Invoke-MgGraphRequest -ModuleName IntuneHydrationKit -Times 0
        }

        It 'Should return WouldCreate and skip Graph POST in WhatIf mode' {
            Mock Get-GraphPagedResults -ModuleName IntuneHydrationKit
            Mock Invoke-MgGraphRequest -ModuleName IntuneHydrationKit

            $result = Import-IntuneLinuxScript -TemplatePath $script:TemplatePath -WhatIf

            $result | Should -HaveCount 1
            $result[0].Action | Should -Be 'WouldCreate'
            Should -Invoke Invoke-MgGraphRequest -ModuleName IntuneHydrationKit -Times 0
        }

        It 'Should return no work when Linux is not selected' {
            Mock Get-GraphPagedResults -ModuleName IntuneHydrationKit

            $result = Import-IntuneLinuxScript -TemplatePath $script:TemplatePath -Platform Windows

            $result | Should -BeNullOrEmpty
            Should -Invoke Get-GraphPagedResults -ModuleName IntuneHydrationKit -Times 0
        }
    }

    Context 'Delete Mode' {
        It 'Should delete tagged configuration policies that match bundled template names' {
            Mock Get-GraphPagedResults {
                param($Uri)

                $Uri | Should -BeLike '*deviceConfigurationScripts*'
                return @(
                    @{
                        id          = 'matching-id'
                        name        = '[IHD] Linux - Default - Configuration - Test'
                        description = 'Imported by Intune Hydration Kit'
                    }
                    @{
                        id          = 'other-id'
                        name        = '[IHD] Linux - Other'
                        description = 'Imported by Intune Hydration Kit'
                    }
                )
            } -ModuleName IntuneHydrationKit
            Mock Invoke-MgGraphRequest {
                param($Method, $Uri, $Body)

                if ($Method -eq 'POST' -and $Uri -like '*$batch*') {
                    $requestUrl = $Body.requests[0].url
                    $Body.requests | Should -HaveCount 1

                    if ($requestUrl -eq '/deviceManagement/configurationPolicies/matching-id') {
                        return @{
                            responses = @(
                                @{ id = '1'; status = 204; body = @{} }
                            )
                        }
                    }

                    throw "Unexpected delete URL: $requestUrl"
                }
            } -ModuleName IntuneHydrationKit

            $result = Import-IntuneLinuxScript -TemplatePath $script:TemplatePath -RemoveExisting

            $result | Should -HaveCount 1
            $result[0].Action | Should -Be 'Deleted'
            $result[0].Name | Should -Be '[IHD] Linux - Default - Configuration - Test'
        }
    }
}
