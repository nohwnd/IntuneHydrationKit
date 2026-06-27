function Invoke-HydrationGroupStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$StepLabel,

        [Parameter(Mandatory)]
        [string]$GroupType,

        [Parameter(Mandatory)]
        [string]$TemplatePath,

        [Parameter(Mandatory)]
        [string[]]$Platforms,

        [Parameter(Mandatory)]
        [bool]$RemoveExisting,

        [Parameter(Mandatory)]
        [bool]$WhatIfEnabled
    )

    $stepAction = if ($RemoveExisting) { 'Deleting' } else { 'Creating' }
    $logParams = @{
        Message = "${StepLabel}: $stepAction $GroupType Groups"
        Level   = 'Info'
    }
    Write-HydrationLog @logParams

    if ($RemoveExisting) {
        $knownNames = $null
        if (Test-Path -Path $TemplatePath) {
            $groupDataParams = @{
                TemplatePath = $TemplatePath
                Platforms    = $Platforms
            }
            $groupData = Get-HydrationGroupDefinitionsFromTemplates @groupDataParams
            if ($groupData) {
                $knownNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($groupDefinition in $groupData.Filtered) {
                    if ($groupDefinition.displayName) {
                        $null = $knownNames.Add($groupDefinition.displayName)
                    }
                }
            }
        }

        $deleteGroupParams = @{
            GroupType  = $GroupType
            Delete     = $true
            KnownNames = $knownNames
            WhatIf     = $WhatIfEnabled
        }
        $deleteResults = Invoke-GroupBatchImport @deleteGroupParams
        foreach ($result in $deleteResults) {
            if ($result.Name) {
                $logParams = @{
                    Message = "  $($result.Action): $($result.Name)"
                    Level   = 'Info'
                }
                Write-HydrationLog @logParams
            }
        }

        return $deleteResults
    }

    $groupDataParams = @{
        TemplatePath = $TemplatePath
        Platforms    = $Platforms
    }
    $groupData = Get-HydrationGroupDefinitionsFromTemplates @groupDataParams
    if ($null -eq $groupData) {
        $logParams = @{
            Message = "$GroupType Groups template directory not found"
            Level   = 'Warning'
        }
        Write-HydrationLog @logParams
        return @()
    }

    if ($groupData.Filtered.Count -lt $groupData.All.Count) {
        $logParams = @{
            Message = "  Filtered to $($groupData.Filtered.Count) of $($groupData.All.Count) groups based on platform selection: $($Platforms -join ', ')"
            Level   = 'Info'
        }
        Write-HydrationLog @logParams
    }

    $createGroupParams = @{
        GroupDefinitions = $groupData.Filtered
        GroupType        = $GroupType
        WhatIf           = $WhatIfEnabled
    }
    $groupResults = Invoke-GroupBatchImport @createGroupParams
    foreach ($result in $groupResults) {
        if ($result.Name) {
            $logParams = @{
                Message = "  $($result.Action): $($result.Name)"
                Level   = 'Info'
            }
            Write-HydrationLog @logParams
        }
    }

    return $groupResults
}
