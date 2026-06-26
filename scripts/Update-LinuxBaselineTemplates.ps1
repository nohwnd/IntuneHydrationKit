#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter()]
    [string]$SourceRepo = 'jorgeasaurus/IntuneLinuxBaseline',

    [Parameter()]
    [string]$Branch = 'main',

    [Parameter()]
    [string]$TemplateRoot = (Join-Path -Path $PSScriptRoot -ChildPath '../Templates')
)

$ErrorActionPreference = 'Stop'

function Get-GitHubFileText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Repo,

        [Parameter(Mandatory)]
        [string]$Ref,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $uri = "https://api.github.com/repos/$Repo/contents/$Path`?ref=$Ref"
    $response = Invoke-RestMethod -Method GET -Uri $uri -ErrorAction Stop
    $base64 = ([string]$response.content) -replace '\s', ''
    return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($base64))
}

function ConvertTo-Base64Utf8 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    return [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text))
}

function Save-JsonTemplate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $directory = Split-Path -Path $Path -Parent
    if (-not (Test-Path -Path $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    $InputObject |
        ConvertTo-Json -Depth 100 |
        Set-Content -Path $Path -Encoding utf8
}

$complianceTemplates = @(
    @{
        FileName    = 'Linux-Default-Compliance-Defender-Health.json'
        DisplayName = 'Linux - Default - Compliance - Defender Health'
        ScriptName  = 'Linux - Default - Compliance Script - Defender Health'
        ScriptPath  = 'compliance/defender_health_discovery.sh'
        RulePath    = 'compliance/defender_health_rule.json'
    }
    @{
        FileName    = 'Linux-Default-Compliance-Firewall.json'
        DisplayName = 'Linux - Default - Compliance - Firewall'
        ScriptName  = 'Linux - Default - Compliance Script - Firewall'
        ScriptPath  = 'compliance/firewall_enabled_discovery.sh'
        RulePath    = 'compliance/firewall_enabled_rule.json'
    }
    @{
        FileName    = 'Linux-Default-Compliance-Secure-Boot.json'
        DisplayName = 'Linux - Default - Compliance - Secure Boot'
        ScriptName  = 'Linux - Default - Compliance Script - Secure Boot'
        ScriptPath  = 'compliance/secure_boot_discovery.sh'
        RulePath    = 'compliance/secure_boot_rule.json'
    }
    @{
        FileName    = 'Linux-Default-Compliance-Package-Updates.json'
        DisplayName = 'Linux - Default - Compliance - Package Updates'
        ScriptName  = 'Linux - Default - Compliance Script - Package Updates'
        ScriptPath  = 'compliance/update_check_discovery.sh'
        RulePath    = 'compliance/update_check_rule.json'
    }
)

$linuxScriptTemplates = @(
    @{ FileName = 'Linux-Default-Configuration-Disable-Telemetry.json'; DisplayName = 'Linux - Default - Configuration - Disable Telemetry'; ScriptPath = 'configuration/disable_telemetry.sh' }
    @{ FileName = 'Linux-Default-Configuration-Edge-Default-Browser.json'; DisplayName = 'Linux - Default - Configuration - Edge Default Browser'; ScriptPath = 'configuration/edge_default_browser.sh' }
    @{ FileName = 'Linux-Default-Configuration-Edge-Managed-Favorites.json'; DisplayName = 'Linux - Default - Configuration - Edge Managed Favorites'; ScriptPath = 'configuration/edge_managed_favorites.sh' }
    @{ FileName = 'Linux-Default-Configuration-Enable-Firewall.json'; DisplayName = 'Linux - Default - Configuration - Enable Firewall'; ScriptPath = 'configuration/enable_firewall.sh' }
    @{ FileName = 'Linux-Default-Configuration-Enable-Intune-Sync.json'; DisplayName = 'Linux - Default - Configuration - Enable Intune Sync'; ScriptPath = 'configuration/enable_intune_sync.sh' }
    @{ FileName = 'Linux-Default-Configuration-Package-Updates.json'; DisplayName = 'Linux - Default - Configuration - Package Updates'; ScriptPath = 'configuration/package_updates.sh' }
    @{ FileName = 'Linux-Default-Configuration-Screen-Lock-Idle.json'; DisplayName = 'Linux - Default - Configuration - Screen Lock Idle'; ScriptPath = 'configuration/screen_lock_idle.sh' }
    @{ FileName = 'Linux-Default-Configuration-Set-Device-Name.json'; DisplayName = 'Linux - Default - Configuration - Set Device Name'; ScriptPath = 'configuration/set_device_name.sh' }
)

$compliancePath = Join-Path -Path $TemplateRoot -ChildPath 'Compliance'
foreach ($template in $complianceTemplates) {
    $scriptText = Get-GitHubFileText -Repo $SourceRepo -Ref $Branch -Path $template.ScriptPath
    $rules = Get-GitHubFileText -Repo $SourceRepo -Ref $Branch -Path $template.RulePath | ConvertFrom-Json
    $sourceUrl = "https://github.com/$SourceRepo/blob/$Branch/$($template.ScriptPath)"

    $output = [ordered]@{
        displayName                            = $template.DisplayName
        name                                   = $template.DisplayName
        description                            = "Linux custom compliance from IntuneLinuxBaseline. Source: $sourceUrl"
        platforms                              = 'linux'
        technologies                           = 'linuxMdm'
        roleScopeTagIds                        = @('0')
        settings                               = @()
        deviceCompliancePolicyScript           = @{}
        deviceCompliancePolicyScriptDefinition = [ordered]@{
            displayName                  = $template.ScriptName
            description                  = "Discovery script from IntuneLinuxBaseline. Source: $sourceUrl"
            detectionScriptContentBase64 = ConvertTo-Base64Utf8 -Text $scriptText
            enforceSignatureCheck        = $false
            publisher                    = 'Intune Hydration Kit'
            runAs32Bit                   = $false
            runAsAccount                 = 'user'
            rules                        = $rules
        }
    }

    Save-JsonTemplate -InputObject $output -Path (Join-Path -Path $compliancePath -ChildPath $template.FileName)
}

$linuxScriptsPath = Join-Path -Path $TemplateRoot -ChildPath 'LinuxScripts'
foreach ($template in $linuxScriptTemplates) {
    $scriptText = Get-GitHubFileText -Repo $SourceRepo -Ref $Branch -Path $template.ScriptPath
    $sourceUrl = "https://github.com/$SourceRepo/blob/$Branch/$($template.ScriptPath)"
    $sourceFileName = Split-Path -Path $template.ScriptPath -Leaf

    $output = [ordered]@{
        displayName                 = $template.DisplayName
        description                 = "Linux configuration script from IntuneLinuxBaseline. Source: $sourceUrl"
        fileName                    = $sourceFileName
        platform                    = 'Linux'
        runAsAccount                = 'system'
        executionFrequency          = 'PT0S'
        retryCount                  = 3
        blockExecutionNotifications = $false
        roleScopeTagIds             = @('0')
        scriptContentBase64         = ConvertTo-Base64Utf8 -Text $scriptText
    }

    Save-JsonTemplate -InputObject $output -Path (Join-Path -Path $linuxScriptsPath -ChildPath $template.FileName)
}
