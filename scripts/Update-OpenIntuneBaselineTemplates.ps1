#Requires -Version 7.0

<#
.SYNOPSIS
    Syncs bundled OpenIntuneBaseline templates from upstream.
.DESCRIPTION
    Downloads OpenIntuneBaseline, filters it to JSON templates, excludes duplicate
    NativeImport and Scripts directories, and replaces Templates/OpenIntuneBaseline.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$TemplatePath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
if (-not $TemplatePath) {
    $TemplatePath = Join-Path -Path $repoRoot -ChildPath (Join-Path -Path 'Templates' -ChildPath 'OpenIntuneBaseline')
}

$zipUrl = 'https://github.com/SkipToTheEndpoint/OpenIntuneBaseline/archive/refs/heads/main.zip'
$tempBase = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "OIB-Update-$(Get-Random)"
$zipPath = Join-Path -Path $tempBase -ChildPath 'OpenIntuneBaseline-main.zip'
$extractPath = Join-Path -Path $tempBase -ChildPath 'upstream'
$stagingPath = Join-Path -Path $tempBase -ChildPath 'OpenIntuneBaseline'

try {
    $null = New-Item -Path $tempBase -ItemType Directory -Force
    $null = New-Item -Path $stagingPath -ItemType Directory -Force

    Write-Output "Downloading OpenIntuneBaseline from $zipUrl"
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -ErrorAction Stop

    Write-Output 'Extracting upstream archive'
    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

    $upstreamRoot = Get-ChildItem -Path $extractPath -Directory | Select-Object -First 1
    if (-not $upstreamRoot) {
        Write-Error "Failed to find extracted upstream folder in $extractPath"
        return
    }

    $jsonFiles = Get-ChildItem -Path $upstreamRoot.FullName -Recurse -File -Filter '*.json' -ErrorAction SilentlyContinue
    if (-not $jsonFiles) {
        Write-Error 'Upstream repository contains no JSON files. The archive may have an unexpected structure.'
        return
    }

    $copiedCount = 0
    foreach ($file in $jsonFiles) {
        $relativePath = $file.FullName.Substring($upstreamRoot.FullName.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, '/', '\')
        $relativePath = $relativePath -replace '\\', '/'

        if ($relativePath -match '(^|/)(NativeImport|Scripts)(/|$)') {
            continue
        }

        $destination = Join-Path -Path $stagingPath -ChildPath $relativePath
        $destinationDirectory = Split-Path -Path $destination -Parent
        if ($destinationDirectory -and -not (Test-Path -Path $destinationDirectory)) {
            $null = New-Item -Path $destinationDirectory -ItemType Directory -Force
        }

        Copy-Item -Path $file.FullName -Destination $destination -Force
        $copiedCount++
    }

    if ($copiedCount -eq 0) {
        Write-Error 'No OpenIntuneBaseline template JSON files remained after filtering.'
        return
    }

    if (Test-Path -Path $TemplatePath) {
        Remove-Item -Path $TemplatePath -Recurse -Force
    }

    $templateDirectory = Split-Path -Path $TemplatePath -Parent
    if ($templateDirectory -and -not (Test-Path -Path $templateDirectory)) {
        $null = New-Item -Path $templateDirectory -ItemType Directory -Force
    }

    Copy-Item -Path $stagingPath -Destination $TemplatePath -Recurse -Force
    Write-Output "Synced $copiedCount OpenIntuneBaseline JSON templates to $TemplatePath"
} catch {
    Write-Error "OpenIntuneBaseline template update failed: $_"
} finally {
    if (Test-Path -Path $tempBase -ErrorAction SilentlyContinue) {
        Remove-Item -Path $tempBase -Recurse -Force -ErrorAction SilentlyContinue *> $null
    }
}
