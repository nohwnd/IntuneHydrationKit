function Get-HydrationSettingsSchema {
    [CmdletBinding()]
    param()

    $schemaPath = Get-HydrationSettingsSchemaPath
    $schemaContent = Get-Content -Path $schemaPath -Raw -Encoding utf8 -ErrorAction Stop
    return $schemaContent | ConvertFrom-Json -AsHashtable
}
