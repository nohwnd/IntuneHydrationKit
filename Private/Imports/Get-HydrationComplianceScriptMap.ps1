function Get-HydrationComplianceScriptMap {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $existingComplianceScripts = @{}

    try {
        Get-GraphPagedResults -Uri "beta/deviceManagement/deviceComplianceScripts?`$select=id,displayName,description" -ProcessItems {
            param($items)

            foreach ($scriptItem in $items) {
                if (-not $scriptItem.displayName) {
                    continue
                }

                $isTagged = Test-HydrationKitObject -Description $scriptItem.description
                if (-not $existingComplianceScripts.ContainsKey($scriptItem.displayName) -or
                    ($isTagged -and -not $existingComplianceScripts[$scriptItem.displayName].IsTagged)) {
                    $existingComplianceScripts[$scriptItem.displayName] = @{
                        Id          = $scriptItem.id
                        Description = $scriptItem.description
                        IsTagged    = $isTagged
                    }
                }
            }
        }
    } catch {
        Write-Warning "Failed to prefetch compliance scripts: $_"
    }

    return $existingComplianceScripts
}
