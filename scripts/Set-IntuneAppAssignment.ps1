#Requires -Version 7.0

<#
.SYNOPSIS
    Adds an Intune mobile-app assignment (Required or Available, to All Devices or All Users),
    preserving any existing assignments.

.DESCRIPTION
    Development helper for test tenants. Queries Microsoft Intune mobile apps of the requested
    types and, for each app that does not already have a matching assignment, adds one with the
    requested intent and target while preserving existing assignments. Supports -WhatIf.

    Replaces the former Set-AllAppsRequiredOnAllDevices.ps1 and Set-WindowsAppsAvailableToAllUsers.ps1.

.PARAMETER Intent
    Assignment intent to add: Required or Available.

.PARAMETER Target
    Assignment target: AllDevices (all devices) or AllUsers (all licensed users).

.PARAMETER AppTypes
    Mobile app @odata.type values to include. Defaults to common deployable app types across
    Windows, iOS, Android, and macOS. Pass a narrower list to scope to specific platforms.

.EXAMPLE
    ./scripts/Set-IntuneAppAssignment.ps1 -Intent Required -Target AllDevices -WhatIf
    Dry-run: assign every supported app as Required on All Devices.

.EXAMPLE
    ./scripts/Set-IntuneAppAssignment.ps1 -Intent Available -Target AllUsers -AppTypes '#microsoft.graph.win32LobApp','#microsoft.graph.winGetApp','#microsoft.graph.microsoftStoreForBusinessApp','#microsoft.graph.officeSuiteApp','#microsoft.graph.windowsMicrosoftEdgeApp','#microsoft.graph.windowsUniversalAppX'
    Assign Windows apps as Available to All Users.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Required', 'Available')]
    [string]$Intent,

    [Parameter(Mandatory)]
    [ValidateSet('AllDevices', 'AllUsers')]
    [string]$Target,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$AppTypes = @(
        '#microsoft.graph.win32LobApp',
        '#microsoft.graph.winGetApp',
        '#microsoft.graph.microsoftStoreForBusinessApp',
        '#microsoft.graph.officeSuiteApp',
        '#microsoft.graph.windowsMicrosoftEdgeApp',
        '#microsoft.graph.windowsUniversalAppX',
        '#microsoft.graph.iosStoreApp',
        '#microsoft.graph.iosLobApp',
        '#microsoft.graph.managedIOSStoreApp',
        '#microsoft.graph.androidStoreApp',
        '#microsoft.graph.androidLobApp',
        '#microsoft.graph.managedAndroidStoreApp',
        '#microsoft.graph.macOSLobApp',
        '#microsoft.graph.macOSDmgApp',
        '#microsoft.graph.macOSPkgApp'
    )
)

# Resolve the run configuration once from the Intent/Target choices.
$script:IntentValue = $Intent.ToLowerInvariant()
$script:TargetODataType = if ($Target -eq 'AllDevices') {
    '#microsoft.graph.allDevicesAssignmentTarget'
} else {
    '#microsoft.graph.allLicensedUsersAssignmentTarget'
}
$script:TargetLabel = if ($Target -eq 'AllDevices') { 'All Devices' } else { 'All Users' }

function Connect-AssignmentGraph {
    [CmdletBinding()]
    param()

    $requiredScope = 'DeviceManagementApps.ReadWrite.All'
    $context = Get-MgContext
    if (-not $context) {
        Connect-MgGraph -Scopes $requiredScope -NoWelcome | Out-Null
        return
    }

    if ($context.Scopes -notcontains $requiredScope) {
        Disconnect-MgGraph | Out-Null
        Connect-MgGraph -Scopes $requiredScope -NoWelcome | Out-Null
    }
}

function ConvertTo-PlainValue {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    return $InputObject |
        ConvertTo-Json -Depth 100 -Compress |
        ConvertFrom-Json -AsHashtable
}

function Get-MobileApp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$IncludedTypes
    )

    $apps = [System.Collections.Generic.List[object]]::new()
    $uri = 'beta/deviceAppManagement/mobileApps'

    do {
        $response = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
        foreach ($app in @($response.value)) {
            if ($app.'@odata.type' -in $IncludedTypes) {
                $apps.Add($app)
            }
        }

        $uri = $response.'@odata.nextLink'
    } while ($uri)

    return @($apps)
}

function Get-MobileAppAssignment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$AppId
    )

    $response = Invoke-MgGraphRequest -Method GET -Uri "beta/deviceAppManagement/mobileApps/$AppId/assignments" -ErrorAction Stop
    return @($response.value)
}

function Get-AssignmentSetting {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$MobileAppType,

        [Parameter(Mandatory)]
        [string]$IntentValue,

        [Parameter()]
        [AllowNull()]
        [object[]]$ExistingAssignments
    )

    # Reuse settings from an existing assignment of the same intent if present.
    $existing = @($ExistingAssignments | Where-Object { $_.intent -eq $IntentValue } | Select-Object -First 1)
    if ($existing.Count -gt 0 -and $null -ne $existing[0].settings) {
        $settings = ConvertTo-PlainValue -InputObject $existing[0].settings
        if ($settings -is [System.Collections.IDictionary]) {
            foreach ($readOnlyKey in @('id', 'lastModifiedDateTime')) {
                if ($settings.Contains($readOnlyKey)) {
                    $null = $settings.Remove($readOnlyKey)
                }
            }
        }

        return $settings
    }

    switch ($MobileAppType) {
        '#microsoft.graph.win32LobApp' {
            return @{
                '@odata.type'                = '#microsoft.graph.win32LobAppAssignmentSettings'
                notifications                = 'showAll'
                deliveryOptimizationPriority = 'notConfigured'
                installTimeSettings          = $null
                restartSettings              = $null
            }
        }
        default {
            return $null
        }
    }
}

function ConvertTo-WritableAssignmentSetting {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Settings
    )

    $writableSettings = ConvertTo-PlainValue -InputObject $Settings
    if ($writableSettings -is [System.Collections.IDictionary]) {
        foreach ($readOnlyKey in @('id', 'lastModifiedDateTime')) {
            if ($writableSettings.Contains($readOnlyKey)) {
                $null = $writableSettings.Remove($readOnlyKey)
            }
        }
    }

    return $writableSettings
}

function ConvertTo-MobileAppAssignmentPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object]$Assignment
    )

    process {
        @{
            '@odata.type' = '#microsoft.graph.mobileAppAssignment'
            intent        = [string]$Assignment.intent
            target        = ConvertTo-PlainValue -InputObject $Assignment.target
            settings      = ConvertTo-WritableAssignmentSetting -Settings $Assignment.settings
        }
    }
}

function Set-AppAssignment {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$AppId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$AppName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$MobileAppType
    )

    $existingAssignments = Get-MobileAppAssignment -AppId $AppId

    # Skip if a matching intent + target assignment already exists.
    $existingMatch = @(
        $existingAssignments | Where-Object {
            $_.intent -eq $script:IntentValue -and
            $_.target.'@odata.type' -eq $script:TargetODataType
        }
    )

    if ($existingMatch.Count -gt 0) {
        return [PSCustomObject]@{
            Name   = $AppName
            Type   = $MobileAppType
            Status = 'Skipped'
            Reason = "Already $($script:IntentValue) on $($script:TargetLabel)"
        }
    }

    # Preserve existing assignments and append the new one.
    $assignmentPayload = [System.Collections.Generic.List[object]]::new()
    foreach ($assignment in $existingAssignments) {
        $assignmentPayload.Add((ConvertTo-MobileAppAssignmentPayload -Assignment $assignment))
    }

    $assignmentPayload.Add(@{
            '@odata.type' = '#microsoft.graph.mobileAppAssignment'
            intent        = $script:IntentValue
            target        = @{
                '@odata.type' = $script:TargetODataType
            }
            settings      = Get-AssignmentSetting -MobileAppType $MobileAppType -IntentValue $script:IntentValue -ExistingAssignments $existingAssignments
        })

    if (-not $PSCmdlet.ShouldProcess($AppName, "Assign as $Intent to $($script:TargetLabel)")) {
        return [PSCustomObject]@{
            Name   = $AppName
            Type   = $MobileAppType
            Status = 'WhatIf'
            Reason = $null
        }
    }

    $bodyJson = @{
        mobileAppAssignments = @($assignmentPayload)
    } | ConvertTo-Json -Depth 30

    Invoke-MgGraphRequest -Method POST -Uri "beta/deviceAppManagement/mobileApps/$AppId/assign" -Body $bodyJson -ContentType 'application/json' -ErrorAction Stop | Out-Null

    return [PSCustomObject]@{
        Name   = $AppName
        Type   = $MobileAppType
        Status = 'Assigned'
        Reason = $null
    }
}

# --- Main ---

Connect-AssignmentGraph

$apps = Get-MobileApp -IncludedTypes $AppTypes
if ($apps.Count -eq 0) {
    Write-Warning 'No matching apps were found in Intune.'
    return
}

$results = foreach ($app in $apps) {
    try {
        Set-AppAssignment -AppId $app.id -AppName $app.displayName -MobileAppType $app.'@odata.type'
    } catch {
        [PSCustomObject]@{
            Name   = [string]$app.displayName
            Type   = [string]$app.'@odata.type'
            Status = 'Failed'
            Reason = $_.Exception.Message
        }
    }
}

$results
