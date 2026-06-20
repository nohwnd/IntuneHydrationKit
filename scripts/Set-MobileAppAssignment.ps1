#Requires -Version 7.0

<#
.SYNOPSIS
    Adds a broad Intune mobile app assignment.
.DESCRIPTION
    Queries Intune mobile apps, preserves existing assignments, and adds one
    assignment when the selected target is not already assigned.
.PARAMETER Intent
    Assignment intent to add.
.PARAMETER Target
    Assignment target to add.
.PARAMETER AppTypes
    Mobile app @odata.type values to include. Defaults to Windows apps for
    available/allUsers and common deployable app types otherwise.
.EXAMPLE
    ./Scripts/Set-MobileAppAssignment.ps1 -WhatIf
.EXAMPLE
    ./Scripts/Set-MobileAppAssignment.ps1 -Intent required -Target allDevices -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [ValidateSet('available', 'required')]
    [string]$Intent = 'available',

    [Parameter()]
    [ValidateSet('allUsers', 'allDevices')]
    [string]$Target = 'allUsers',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$AppTypes
)

$windowsAppTypes = @(
    '#microsoft.graph.win32LobApp'
    '#microsoft.graph.winGetApp'
    '#microsoft.graph.microsoftStoreForBusinessApp'
    '#microsoft.graph.officeSuiteApp'
    '#microsoft.graph.windowsMicrosoftEdgeApp'
    '#microsoft.graph.windowsUniversalAppX'
)

if (-not $PSBoundParameters.ContainsKey('AppTypes')) {
    $AppTypes = if ($Intent -eq 'available' -and $Target -eq 'allUsers') {
        $windowsAppTypes
    } else {
        @(
            $windowsAppTypes
            '#microsoft.graph.iosStoreApp'
            '#microsoft.graph.iosLobApp'
            '#microsoft.graph.managedIOSStoreApp'
            '#microsoft.graph.androidStoreApp'
            '#microsoft.graph.androidLobApp'
            '#microsoft.graph.managedAndroidStoreApp'
            '#microsoft.graph.macOSLobApp'
            '#microsoft.graph.macOSDmgApp'
            '#microsoft.graph.macOSPkgApp'
        )
    }
}

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
        [object]$InputObject,

        [Parameter()]
        [System.Collections.Generic.HashSet[object]]$Seen = [System.Collections.Generic.HashSet[object]]::new()
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $type = $InputObject.GetType()
    if ($type.IsValueType -or $InputObject -is [string]) {
        return $InputObject
    }

    if ($Seen.Contains($InputObject)) {
        return $null
    }
    $null = $Seen.Add($InputObject)

    try {
        if ($InputObject -is [System.Collections.IDictionary]) {
            $hash = @{}
            foreach ($key in $InputObject.Keys) {
                $hash[$key] = ConvertTo-PlainValue -InputObject $InputObject[$key] -Seen $Seen
            }
            return $hash
        }

        if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
            $hash = @{}
            foreach ($prop in $InputObject.PSObject.Properties) {
                $hash[$prop.Name] = ConvertTo-PlainValue -InputObject $prop.Value -Seen $Seen
            }
            return $hash
        }

        if ($InputObject -is [System.Collections.IEnumerable]) {
            $list = [System.Collections.Generic.List[object]]::new()
            foreach ($item in $InputObject) {
                $list.Add((ConvertTo-PlainValue -InputObject $item -Seen $Seen))
            }
            return [object[]]$list.ToArray()
        }

        return $InputObject
    } finally {
        $null = $Seen.Remove($InputObject)
    }
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

function Get-MobileAppAssignmentSetting {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$MobileAppType,

        [Parameter(Mandatory)]
        [string]$Intent,

        [Parameter()]
        [AllowNull()]
        [object[]]$ExistingAssignments
    )

    $matchingAssignment = @($ExistingAssignments | Where-Object { $_.intent -eq $Intent } | Select-Object -First 1)
    if ($matchingAssignment.Count -gt 0 -and $null -ne $matchingAssignment[0].settings) {
        return ConvertTo-WritableAssignmentSetting -Settings $matchingAssignment[0].settings
    }

    if ($MobileAppType -eq '#microsoft.graph.win32LobApp') {
        return @{
            '@odata.type'                = '#microsoft.graph.win32LobAppAssignmentSettings'
            notifications                = 'showAll'
            deliveryOptimizationPriority = 'notConfigured'
            installTimeSettings          = $null
            restartSettings              = $null
        }
    }

    return $null
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

function Set-MobileAppAssignment {
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
        [string]$MobileAppType,

        [Parameter(Mandatory)]
        [string]$Intent,

        [Parameter(Mandatory)]
        [string]$TargetType,

        [Parameter(Mandatory)]
        [string]$TargetLabel
    )

    $existingAssignments = Get-MobileAppAssignment -AppId $AppId
    $matchingAssignment = @(
        $existingAssignments | Where-Object {
            $_.intent -eq $Intent -and $_.target.'@odata.type' -eq $TargetType
        }
    )

    if ($matchingAssignment.Count -gt 0) {
        return [PSCustomObject]@{
            Name   = $AppName
            Type   = $MobileAppType
            Status = 'Skipped'
            Reason = "Already $Intent on $TargetLabel"
        }
    }

    $assignmentPayload = [System.Collections.Generic.List[object]]::new()
    foreach ($assignment in $existingAssignments) {
        $assignmentPayload.Add((ConvertTo-MobileAppAssignmentPayload -Assignment $assignment))
    }

    $assignmentPayload.Add(@{
            '@odata.type' = '#microsoft.graph.mobileAppAssignment'
            intent        = $Intent
            target        = @{
                '@odata.type' = $TargetType
            }
            settings      = Get-MobileAppAssignmentSetting -MobileAppType $MobileAppType -Intent $Intent -ExistingAssignments $existingAssignments
        })

    $action = "Assign as $Intent on $TargetLabel"
    if (-not $PSCmdlet.ShouldProcess($AppName, $action)) {
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

$targetInfo = @{
    allDevices = @{
        Type  = '#microsoft.graph.allDevicesAssignmentTarget'
        Label = 'All Devices'
    }
    allUsers   = @{
        Type  = '#microsoft.graph.allLicensedUsersAssignmentTarget'
        Label = 'All Users'
    }
}[$Target]

Connect-AssignmentGraph

$apps = Get-MobileApp -IncludedTypes $AppTypes
if ($apps.Count -eq 0) {
    Write-Warning 'No matching apps were found in Intune.'
    return
}

foreach ($app in $apps) {
    try {
        Set-MobileAppAssignment -AppId $app.id -AppName $app.displayName -MobileAppType $app.'@odata.type' -Intent $Intent -TargetType $targetInfo.Type -TargetLabel $targetInfo.Label
    } catch {
        [PSCustomObject]@{
            Name   = [string]$app.displayName
            Type   = [string]$app.'@odata.type'
            Status = 'Failed'
            Reason = $_.Exception.Message
        }
    }
}
