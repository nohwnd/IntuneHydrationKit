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
$ProgressPreference = 'SilentlyContinue'

function Get-SourceFileText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $sourcePath = Join-Path -Path $SourceRoot -ChildPath $Path
    if (-not (Test-Path -Path $sourcePath)) {
        Write-Error "Source file not found: $Path"
        return
    }

    return Get-Content -Path $sourcePath -Raw -Encoding utf8
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

$tempBase = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "LinuxBaseline-Update-$(Get-Random)"
$zipPath = Join-Path -Path $tempBase -ChildPath 'IntuneLinuxBaseline.zip'
$extractPath = Join-Path -Path $tempBase -ChildPath 'upstream'
$zipUrl = "https://github.com/$SourceRepo/archive/refs/heads/$Branch.zip"

try {
    $null = New-Item -Path $tempBase -ItemType Directory -Force
    Write-Output "Downloading IntuneLinuxBaseline from $zipUrl"
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -ErrorAction Stop

    Write-Output 'Extracting source archive'
    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

    $sourceRoot = Get-ChildItem -Path $extractPath -Directory | Select-Object -First 1
    if (-not $sourceRoot) {
        Write-Error "Failed to find extracted source folder in $extractPath"
        return
    }

    $compliancePath = Join-Path -Path $TemplateRoot -ChildPath 'Compliance'
    foreach ($template in $complianceTemplates) {
        $scriptText = Get-SourceFileText -SourceRoot $sourceRoot.FullName -Path $template.ScriptPath
        $rules = Get-SourceFileText -SourceRoot $sourceRoot.FullName -Path $template.RulePath | ConvertFrom-Json
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
        $scriptText = Get-SourceFileText -SourceRoot $sourceRoot.FullName -Path $template.ScriptPath
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
} finally {
    if (Test-Path -Path $tempBase -ErrorAction SilentlyContinue) {
        Remove-Item -Path $tempBase -Recurse -Force -ErrorAction SilentlyContinue *> $null
    }
}
