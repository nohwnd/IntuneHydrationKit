function Get-HydrationExistingObjectMap {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter()]
        [string]$NameProperty = 'displayName',

        [Parameter()]
        [scriptblock]$Where,

        [Parameter()]
        [string]$Endpoint
    )

    $objects = @{}
    $currentNameProperty = $NameProperty
    $currentWhere = $Where
    $currentEndpoint = $Endpoint

    try {
        Get-GraphPagedResults -Uri $Uri -ProcessItems {
            param($items)

            foreach ($item in $items) {
                if ($currentWhere -and -not (& $currentWhere $item)) {
                    continue
                }

                $name = $item.$currentNameProperty
                if (-not $name) {
                    continue
                }

                $isTagged = Test-HydrationKitObject -Description $item.description -Notes $item.notes
                if (-not $objects.ContainsKey($name) -or ($isTagged -and -not $objects[$name].IsTagged)) {
                    $objects[$name] = @{
                        Id          = $item.id
                        Description = $item.description
                        Notes       = $item.notes
                        Endpoint    = $currentEndpoint
                        IsTagged    = $isTagged
                    }
                }
            }
        }
    } catch {
        Write-Warning "Failed to prefetch existing objects from $Uri`: $_"
    }

    return $objects
}
