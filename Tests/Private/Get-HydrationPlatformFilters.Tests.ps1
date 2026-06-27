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

    It 'Should fail closed for workloads that do not support the selected platform' {
        InModuleScope IntuneHydrationKit {
            $filters = Get-HydrationPlatformFilters -Platforms @('Linux')

            $filters.DeviceFilters | Should -BeNullOrEmpty
            $filters.AppProtection | Should -BeNullOrEmpty
            $filters.MobileApps | Should -BeNullOrEmpty
            $filters.EnrollmentProfiles | Should -BeNullOrEmpty
            $filters.Baseline | Should -BeNullOrEmpty
            $filters.Groups | Should -BeNullOrEmpty
            $filters.Compliance | Should -Be @('Linux')
            $filters.CISBaseline | Should -Be @('Linux')
            $filters.LinuxScripts | Should -Be @('Linux')
        }
    }

    It 'Should disable non-matching and platform-neutral imports for platform-scoped delete' {
        InModuleScope IntuneHydrationKit {
            $imports = @{
                dynamicGroups         = $true
                staticGroups          = $true
                deviceFilters         = $true
                openIntuneBaseline    = $true
                cisBaselines          = $true
                complianceTemplates   = $true
                linuxScripts          = $true
                notificationTemplates = $true
                appProtection         = $true
                enrollmentProfiles    = $true
                conditionalAccess     = $true
                mobileApps            = $true
            }
            $filters = Get-HydrationPlatformFilters -Platforms @('Linux')

            $effectiveImports = Resolve-HydrationPlatformScopedImport `
                -Imports $imports `
                -PlatformFilters $filters `
                -Platforms @('Linux') `
                -DeleteMode

            foreach ($importName in @('dynamicGroups', 'staticGroups', 'deviceFilters', 'openIntuneBaseline', 'appProtection', 'enrollmentProfiles', 'conditionalAccess', 'notificationTemplates', 'mobileApps')) {
                $effectiveImports[$importName] | Should -BeFalse
            }

            foreach ($importName in @('cisBaselines', 'complianceTemplates', 'linuxScripts')) {
                $effectiveImports[$importName] | Should -BeTrue
            }
        }
    }
}
