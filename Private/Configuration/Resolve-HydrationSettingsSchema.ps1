function Resolve-HydrationSettingsSchema {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Settings,

        [Parameter()]
        [hashtable]$Schema,

        [Parameter()]
        [string]$SchemaPath
    )

    function New-SettingsValidationError {
        param(
            [Parameter(Mandatory)]
            [string]$Message,

            [Parameter(Mandatory)]
            [string]$ErrorId,

            [Parameter(Mandatory)]
            [System.Management.Automation.ErrorCategory]$Category,

            [Parameter()]
            [object]$TargetObject
        )

        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new($Message),
            $ErrorId,
            $Category,
            $TargetObject
        )
        $PSCmdlet.ThrowTerminatingError($errorRecord)
    }

    function Get-SchemaTypes {
        param(
            [Parameter()]
            [object]$TypeValue
        )

        if ($null -eq $TypeValue) {
            return @()
        }

        if ($TypeValue -is [System.Array]) {
            return @($TypeValue)
        }

        return @($TypeValue)
    }

    function Add-SettingsDefaults {
        param(
            [Parameter(Mandatory)]
            [System.Collections.IDictionary]$SettingsObject,

            [Parameter(Mandatory)]
            [hashtable]$ObjectSchema
        )

        if (-not $ObjectSchema.properties) {
            return
        }

        foreach ($propertyName in @($ObjectSchema.properties.Keys | Where-Object { $null -ne $_ })) {
            $propertySchema = $ObjectSchema.properties[$propertyName]
            $hasProperty = $SettingsObject.Contains($propertyName)

            if (-not $hasProperty) {
                if ($propertySchema.ContainsKey('default')) {
                    $SettingsObject[$propertyName] = $propertySchema.default
                    $hasProperty = $true
                } elseif ((Get-SchemaTypes -TypeValue $propertySchema.type) -contains 'object' -and $propertySchema.properties) {
                    $hasNestedDefaults = $false
                    foreach ($nestedPropertyName in @($propertySchema.properties.Keys)) {
                        if ($propertySchema.properties[$nestedPropertyName].ContainsKey('default')) {
                            $hasNestedDefaults = $true
                            break
                        }
                    }

                    if ($hasNestedDefaults) {
                        $SettingsObject[$propertyName] = @{}
                        $hasProperty = $true
                    }
                }
            }

            if ($hasProperty -and
                $SettingsObject[$propertyName] -is [System.Collections.IDictionary] -and
                (Get-SchemaTypes -TypeValue $propertySchema.type) -contains 'object') {
                Add-SettingsDefaults -SettingsObject $SettingsObject[$propertyName] -ObjectSchema $propertySchema
            }
        }
    }

    if (-not $SchemaPath) {
        $SchemaPath = Get-HydrationSettingsSchemaPath
    }

    if (-not $Schema) {
        $schemaContent = Get-Content -Path $SchemaPath -Raw -Encoding utf8 -ErrorAction Stop
        $Schema = $schemaContent | ConvertFrom-Json -AsHashtable
    }

    try {
        $settingsJson = $Settings | ConvertTo-Json -Depth 100
        $null = Test-Json -Json $settingsJson -SchemaFile $SchemaPath -ErrorAction Stop
    } catch {
        New-SettingsValidationError -Message $_.Exception.Message -ErrorId 'InvalidSettingsSchema' -Category ([System.Management.Automation.ErrorCategory]::InvalidData) -TargetObject $SchemaPath
    }

    Add-SettingsDefaults -SettingsObject $Settings -ObjectSchema $Schema

    $authMode = $Settings.authentication.mode
    if ($authMode -eq 'clientSecret') {
        if ([string]::IsNullOrWhiteSpace($Settings.authentication.clientId)) {
            New-SettingsValidationError -Message "Missing required field for clientSecret authentication: root.authentication.clientId" -ErrorId 'MissingClientId' -Category ([System.Management.Automation.ErrorCategory]::InvalidData) -TargetObject 'root.authentication.clientId'
        }

        if ([string]::IsNullOrWhiteSpace($Settings.authentication.clientSecret)) {
            New-SettingsValidationError -Message "Missing required field for clientSecret authentication: root.authentication.clientSecret" -ErrorId 'MissingClientSecret' -Category ([System.Management.Automation.ErrorCategory]::InvalidData) -TargetObject 'root.authentication.clientSecret'
        }
    }

    return $Settings
}
