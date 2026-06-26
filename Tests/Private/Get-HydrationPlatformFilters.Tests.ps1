#Requires -Modules Pester

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\..\'
    Import-Module (Join-Path $modulePath 'IntuneHydrationKit.psd1') -Force
}

Describe 'Get-HydrationPlatformFilters' {
    It 'Should include Linux scripts when all platforms are selected' {
        InModuleScope IntuneHydrationKit {
            $filters = Get-HydrationPlatformFilters -Platforms @('All')

            $filters.LinuxScripts | Should -Be @('All')
        }
    }

    It 'Should include Linux scripts only when Linux is selected' {
        InModuleScope IntuneHydrationKit {
            $linuxFilters = Get-HydrationPlatformFilters -Platforms @('Linux')
            $windowsFilters = Get-HydrationPlatformFilters -Platforms @('Windows')

            $linuxFilters.LinuxScripts | Should -Be @('Linux')
            $windowsFilters.LinuxScripts | Should -BeNullOrEmpty
        }
    }
}
