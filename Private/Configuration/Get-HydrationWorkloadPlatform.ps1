function Get-HydrationWorkloadPlatform {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter()]
        [hashtable]$WorkloadPlatforms,

        [Parameter(Mandatory)]
        [string]$Workload,

        [Parameter()]
        [string[]]$Default = @('All')
    )

    if (-not $WorkloadPlatforms) {
        return $Default
    }

    if ($WorkloadPlatforms.ContainsKey($Workload)) {
        return @($WorkloadPlatforms[$Workload])
    }

    return $Default
}
