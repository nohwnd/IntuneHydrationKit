function Resolve-HydrationPlatformScopedImport {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Imports,

        [Parameter(Mandatory)]
        [hashtable]$PlatformFilters,

        [Parameter(Mandatory)]
        [string[]]$Platforms,

        [Parameter()]
        [switch]$DeleteMode
    )

    $effectiveImports = @{}
    foreach ($key in $Imports.Keys) {
        $effectiveImports[$key] = [bool]$Imports[$key]
    }

    $importPlatformFilterMap = @{
        dynamicGroups       = 'Groups'
        staticGroups        = 'Groups'
        deviceFilters       = 'DeviceFilters'
        openIntuneBaseline  = 'Baseline'
        cisBaselines        = 'CISBaseline'
        complianceTemplates = 'Compliance'
        appProtection       = 'AppProtection'
        enrollmentProfiles  = 'EnrollmentProfiles'
        mobileApps          = 'MobileApps'
        linuxScripts        = 'LinuxScripts'
    }

    foreach ($importKey in $importPlatformFilterMap.Keys) {
        if (-not $effectiveImports.ContainsKey($importKey) -or -not $effectiveImports[$importKey]) {
            continue
        }

        $filterKey = $importPlatformFilterMap[$importKey]
        if (@($PlatformFilters[$filterKey]).Count -eq 0) {
            $effectiveImports[$importKey] = $false
        }
    }

    $isPlatformScoped = $Platforms -and $Platforms -notcontains 'All'
    if ($DeleteMode -and $isPlatformScoped) {
        foreach ($platformNeutralImport in @('conditionalAccess', 'notificationTemplates')) {
            if ($effectiveImports.ContainsKey($platformNeutralImport)) {
                $effectiveImports[$platformNeutralImport] = $false
            }
        }
    }

    return $effectiveImports
}
