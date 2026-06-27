function Get-HydrationSettingsSchemaPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($script:ModuleRoot -and (Test-Path -Path $script:ModuleRoot)) {
        $schemaPath = Join-Path -Path $script:ModuleRoot -ChildPath 'settings.schema.json'
    } else {
        $schemaPath = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'settings.schema.json'
    }

    if (-not (Test-Path -Path $schemaPath)) {
        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new("Settings schema not found at '$schemaPath'."),
            'SettingsSchemaNotFound',
            [System.Management.Automation.ErrorCategory]::ObjectNotFound,
            $schemaPath
        )
        $PSCmdlet.ThrowTerminatingError($errorRecord)
    }

    return $schemaPath
}
