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
        It 'Should create Linux shell script payloads through Graph batch' {
            Mock Get-GraphPagedResults -ModuleName IntuneHydrationKit
            Mock Invoke-MgGraphRequest {
                param($Method, $Uri, $Body)

                if ($Method -eq 'POST' -and $Uri -like '*$batch*') {
                    $batch = $Body | ConvertFrom-Json
                    $request = $batch.requests[0]
                    $request.url | Should -Be '/deviceManagement/deviceShellScripts'
                    $request.body.displayName | Should -Be '[IHD] Linux - Default - Configuration - Test'
                    $request.body.description | Should -Match 'Imported by Intune Hydration Kit'
                    $request.body.fileName | Should -Be 'test.sh'
                    $request.body.runAsAccount | Should -Be 'system'
                    $request.body.executionFrequency | Should -Be 'PT0S'
                    $request.body.scriptContent | Should -Not -BeNullOrEmpty

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

                $Uri | Should -BeLike 'beta/deviceManagement/deviceShellScripts*'
                & $ProcessItems @(
                    @{
                        id          = 'existing-id'
                        displayName = '[IHD] Linux - Default - Configuration - Test'
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
        It 'Should delete only tagged scripts that match bundled template names' {
            Mock Get-GraphPagedResults {
                param($Uri, $ProcessItems)

                $Uri | Should -BeLike 'beta/deviceManagement/deviceShellScripts*'
                & $ProcessItems @(
                    @{
                        id          = 'matching-id'
                        displayName = '[IHD] Linux - Default - Configuration - Test'
                        description = 'Imported by Intune Hydration Kit'
                    }
                    @{
                        id          = 'other-id'
                        displayName = '[IHD] Linux - Other'
                        description = 'Imported by Intune Hydration Kit'
                    }
                )
            } -ModuleName IntuneHydrationKit
            Mock Invoke-MgGraphRequest {
                param($Method, $Uri, $Body)

                if ($Method -eq 'POST' -and $Uri -like '*$batch*') {
                    $Body.requests | Should -HaveCount 1
                    $Body.requests[0].url | Should -Be '/deviceManagement/deviceShellScripts/matching-id'

                    return @{
                        responses = @(
                            @{ id = '1'; status = 204; body = @{} }
                        )
                    }
                }
            } -ModuleName IntuneHydrationKit

            $result = Import-IntuneLinuxScript -TemplatePath $script:TemplatePath -RemoveExisting

            $result | Should -HaveCount 1
            $result[0].Action | Should -Be 'Deleted'
            $result[0].Name | Should -Be '[IHD] Linux - Default - Configuration - Test'
        }
    }
}
