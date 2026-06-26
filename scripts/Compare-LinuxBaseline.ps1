#Requires -Version 7.0

<#
.SYNOPSIS
    Compares bundled Linux baseline templates against the maintained source repository.
.DESCRIPTION
    Generates the expected Linux compliance and configuration script templates from
    IntuneLinuxBaseline, then compares those generated templates with the bundled
    templates in Templates/Compliance and Templates/LinuxScripts.
.PARAMETER SourceRepo
    GitHub owner/repository for the maintained Linux baseline source.
.PARAMETER Branch
    Branch to compare against. Default: main.
.PARAMETER LocalTemplateRoot
    Path to the local Templates directory. Default: repository Templates directory.
.PARAMETER ExpectedTemplateRoot
    Optional path to an already generated Templates directory. When provided, the
    script skips downloading source content and uses this directory as expected output.
.PARAMETER KeepGenerated
    If specified, generated expected templates are not cleaned up after comparison.
.PARAMETER OutputPath
    Optional path to write a JSON comparison summary for automation.
.PARAMETER PassThru
    If specified, returns the comparison summary object to the pipeline.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$SourceRepo = 'jorgeasaurus/IntuneLinuxBaseline',

    [Parameter()]
    [string]$Branch = 'main',

    [Parameter()]
    [string]$LocalTemplateRoot,

    [Parameter()]
    [string]$ExpectedTemplateRoot,

    [Parameter()]
    [switch]$KeepGenerated,

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ($SourceRepo -notmatch '^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$') {
    Write-Error "Invalid source repository: '$SourceRepo'. Use owner/repository format."
    return
}

if ($Branch -notmatch '^[a-zA-Z0-9._/\-]+$') {
    Write-Error "Invalid branch name: '$Branch'. Branch names must contain only alphanumeric characters, dots, hyphens, underscores, or forward slashes."
    return
}

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
if (-not $LocalTemplateRoot) {
    $LocalTemplateRoot = Join-Path -Path $repoRoot -ChildPath 'Templates'
}

if (-not (Test-Path -Path $LocalTemplateRoot)) {
    Write-Error "Local template root not found: $LocalTemplateRoot"
    return
}

function Write-ComparisonMessage {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Message = ''
    )

    [Console]::Out.WriteLine($Message)
}

function Get-LinuxBaselineTemplateFile {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$TemplateRoot
    )

    $templateSets = @(
        @{
            Name    = 'Compliance'
            Path    = Join-Path -Path $TemplateRoot -ChildPath 'Compliance'
            Pattern = 'Linux-Default-Compliance-*.json'
        }
        @{
            Name    = 'LinuxScripts'
            Path    = Join-Path -Path $TemplateRoot -ChildPath 'LinuxScripts'
            Pattern = '*.json'
        }
    )

    $results = @{}
    foreach ($templateSet in $templateSets) {
        if (-not (Test-Path -Path $templateSet.Path)) {
            continue
        }

        $files = Get-ChildItem -Path $templateSet.Path -File -Filter $templateSet.Pattern -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            $relativePath = "$($templateSet.Name)/$($file.Name)"
            $results[$relativePath] = @{
                FullPath = $file.FullName
                Hash     = (Get-FileHash -Path $file.FullName -Algorithm SHA256).Hash
                Size     = $file.Length
            }
        }
    }

    return $results
}

$tempBase = $null
$expectedRoot = $ExpectedTemplateRoot

try {
    if (-not $expectedRoot) {
        $tempBase = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "LinuxBaseline-Compare-$(Get-Random)"
        $expectedRoot = Join-Path -Path $tempBase -ChildPath 'Templates'
        $null = New-Item -Path $expectedRoot -ItemType Directory -Force

        $updateScript = Join-Path -Path $PSScriptRoot -ChildPath 'Update-LinuxBaselineTemplates.ps1'
        if (-not (Test-Path -Path $updateScript)) {
            Write-Error "Linux baseline update script not found: $updateScript"
            return
        }

        Write-ComparisonMessage
        Write-ComparisonMessage -Message 'Linux Baseline Parity Check'
        Write-ComparisonMessage
        Write-ComparisonMessage -Message "  Source   : $SourceRepo ($Branch)"
        Write-ComparisonMessage -Message "  Local    : $LocalTemplateRoot"
        Write-ComparisonMessage -Message "  Expected : $expectedRoot"
        Write-ComparisonMessage
        Write-ComparisonMessage -Message '  Generating expected templates from source...'
        & $updateScript -SourceRepo $SourceRepo -Branch $Branch -TemplateRoot $expectedRoot
    } else {
        if (-not (Test-Path -Path $expectedRoot)) {
            Write-Error "Expected template root not found: $expectedRoot"
            return
        }

        Write-ComparisonMessage
        Write-ComparisonMessage -Message 'Linux Baseline Parity Check'
        Write-ComparisonMessage
        Write-ComparisonMessage -Message "  Source   : $SourceRepo ($Branch)"
        Write-ComparisonMessage -Message "  Local    : $LocalTemplateRoot"
        Write-ComparisonMessage -Message "  Expected : $expectedRoot"
        Write-ComparisonMessage
    }

    Write-ComparisonMessage -Message '  Scanning templates...'
    $expectedFiles = Get-LinuxBaselineTemplateFile -TemplateRoot $expectedRoot
    $localFiles = Get-LinuxBaselineTemplateFile -TemplateRoot $LocalTemplateRoot

    if ($expectedFiles.Count -eq 0) {
        Write-Error "Expected template root contains no Linux baseline templates: $expectedRoot"
        return
    }

    $onlyUpstream = [System.Collections.Generic.List[string]]::new()
    $onlyLocal = [System.Collections.Generic.List[string]]::new()
    $modified = [System.Collections.Generic.List[string]]::new()
    $matched = [System.Collections.Generic.List[string]]::new()

    foreach ($key in $expectedFiles.Keys) {
        if ($localFiles.ContainsKey($key)) {
            if ($expectedFiles[$key].Hash -ne $localFiles[$key].Hash) {
                $modified.Add($key)
            } else {
                $matched.Add($key)
            }
        } else {
            $onlyUpstream.Add($key)
        }
    }

    foreach ($key in $localFiles.Keys) {
        if (-not $expectedFiles.ContainsKey($key)) {
            $onlyLocal.Add($key)
        }
    }

    $issueCount = $modified.Count + $onlyUpstream.Count + $onlyLocal.Count
    $comparisonResult = [PSCustomObject]@{
        UpstreamRepository = $SourceRepo
        Branch             = $Branch
        LocalPath          = $LocalTemplateRoot
        GeneratedAt        = (Get-Date).ToUniversalTime().ToString('o')
        TotalUpstream      = $expectedFiles.Count
        TotalLocal         = $localFiles.Count
        IdenticalCount     = $matched.Count
        ModifiedCount      = $modified.Count
        OnlyUpstreamCount  = $onlyUpstream.Count
        OnlyLocalCount     = $onlyLocal.Count
        DifferenceCount    = $issueCount
        HasDifferences     = ($issueCount -gt 0)
        Modified           = @($modified | Sort-Object)
        OnlyUpstream       = @($onlyUpstream | Sort-Object)
        OnlyLocal          = @($onlyLocal | Sort-Object)
    }

    Write-ComparisonMessage
    Write-ComparisonMessage -Message 'RESULTS'
    Write-ComparisonMessage -Message "  Expected source templates : $($expectedFiles.Count)"
    Write-ComparisonMessage -Message "  Local bundled templates   : $($localFiles.Count)"
    Write-ComparisonMessage -Message "  Identical                 : $($matched.Count)"
    Write-ComparisonMessage -Message "  Modified                  : $($modified.Count)"
    Write-ComparisonMessage -Message "  Only in source            : $($onlyUpstream.Count)"
    Write-ComparisonMessage -Message "  Only in local             : $($onlyLocal.Count)"
    Write-ComparisonMessage

    if ($modified.Count -gt 0) {
        Write-ComparisonMessage -Message 'MODIFIED FILES'
        foreach ($file in ($modified | Sort-Object)) {
            Write-ComparisonMessage -Message "  $file"
        }
        Write-ComparisonMessage
    }

    if ($onlyUpstream.Count -gt 0) {
        Write-ComparisonMessage -Message 'ONLY IN SOURCE'
        foreach ($file in ($onlyUpstream | Sort-Object)) {
            Write-ComparisonMessage -Message "  $file"
        }
        Write-ComparisonMessage
    }

    if ($onlyLocal.Count -gt 0) {
        Write-ComparisonMessage -Message 'ONLY IN LOCAL'
        foreach ($file in ($onlyLocal | Sort-Object)) {
            Write-ComparisonMessage -Message "  $file"
        }
        Write-ComparisonMessage
    }

    if ($issueCount -eq 0) {
        Write-ComparisonMessage -Message 'PARITY CHECK PASSED - local Linux baseline templates match source output.'
    } else {
        Write-ComparisonMessage -Message "PARITY CHECK: $issueCount difference(s) found."
        Write-ComparisonMessage -Message 'Review the items above and update the bundled Linux baseline templates as needed.'
    }

    if ($OutputPath) {
        $outputDirectory = Split-Path -Path $OutputPath -Parent
        if ($outputDirectory -and -not (Test-Path -Path $outputDirectory)) {
            $null = New-Item -Path $outputDirectory -ItemType Directory -Force
        }

        $comparisonResult |
            ConvertTo-Json -Depth 5 |
            Set-Content -Path $OutputPath -Encoding utf8
        Write-ComparisonMessage -Message "Wrote comparison summary to: $OutputPath"
    }

    if ($PassThru.IsPresent) {
        Write-Output $comparisonResult
    }
} catch {
    Write-Error "Comparison failed: $_"
} finally {
    if (-not $KeepGenerated -and $tempBase -and (Test-Path -Path $tempBase -ErrorAction SilentlyContinue)) {
        Remove-Item -Path $tempBase -Recurse -Force -ErrorAction SilentlyContinue *> $null
        Write-ComparisonMessage -Message 'Cleaned up temporary files.'
    } elseif ($KeepGenerated -and $tempBase -and (Test-Path -Path $tempBase -ErrorAction SilentlyContinue)) {
        Write-ComparisonMessage -Message "Generated templates kept at: $tempBase"
    }
}
