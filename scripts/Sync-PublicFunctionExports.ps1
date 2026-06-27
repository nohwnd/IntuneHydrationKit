#Requires -Version 7.0

<#
.SYNOPSIS
    Verifies (and optionally fixes) the public-function export list in the module manifest.

.DESCRIPTION
    The expected public surface is every *.ps1 file under Public/ (one function per file) plus a
    few helper functions that live under Private/ but are exported. The root module
    (IntuneHydrationKit.psm1) derives this same set at import time, so only the manifest's
    FunctionsToExport needs to be kept aligned.

    Comparison is by name set, so the hand-curated grouping/comments and ordering in the manifest
    are preserved. The manifest is only rewritten (as a flat sorted list) when a function is
    genuinely missing or extra - run this after adding or removing a public function.

.PARAMETER CheckOnly
    Report whether FunctionsToExport is missing or has extra functions and exit with code 1 if so,
    without making changes. Useful in CI to catch a forgotten export update.

.EXAMPLE
    ./scripts/Sync-PublicFunctionExports.ps1

.EXAMPLE
    ./scripts/Sync-PublicFunctionExports.ps1 -CheckOnly
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [switch]$CheckOnly
)

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$publicPath = Join-Path -Path $repoRoot -ChildPath 'Public'
$manifestPath = Join-Path -Path $repoRoot -ChildPath 'IntuneHydrationKit.psd1'

if (-not (Test-Path -Path $publicPath -PathType Container)) {
    throw "Public function directory not found: $publicPath"
}

# Helper functions that live under Private/ but are part of the public surface.
# Keep this in step with $exportedPrivateHelpers in IntuneHydrationKit.psm1.
$exportedPrivateHelpers = @(
    'Get-GraphErrorMessage'
    'Get-ObfuscatedTenantId'
    'Get-ResultSummary'
    'New-HydrationResult'
    'Test-HydrationKitObject'
)

$expectedExports = @(
    Get-ChildItem -Path $publicPath -Filter '*.ps1' -File -Recurse | ForEach-Object { $_.BaseName }
) + $exportedPrivateHelpers | Sort-Object -Unique

if ($expectedExports.Count -eq 0) {
    throw 'No public function files were found under Public/.'
}

$currentExports = @((Import-PowerShellDataFile -Path $manifestPath).FunctionsToExport) | Sort-Object -Unique
$difference = Compare-Object -ReferenceObject $expectedExports -DifferenceObject $currentExports

if (-not $difference) {
    Write-Information 'FunctionsToExport is in sync with Public/**/*.ps1.' -InformationAction Continue
    return
}

$missing = @($difference | Where-Object SideIndicator -eq '<=' | ForEach-Object InputObject)
$extra = @($difference | Where-Object SideIndicator -eq '=>' | ForEach-Object InputObject)
if ($missing) { Write-Information "Missing from FunctionsToExport: $($missing -join ', ')" -InformationAction Continue }
if ($extra) { Write-Information "Unexpected in FunctionsToExport: $($extra -join ', ')" -InformationAction Continue }

if ($CheckOnly) {
    Write-Information 'FunctionsToExport is out of sync. Run scripts/Sync-PublicFunctionExports.ps1 to apply updates.' -InformationAction Continue
    exit 1
}

$functionListText = ($expectedExports | ForEach-Object { "        '$_'" }) -join ",`n"
$manifestContent = Get-Content -Path $manifestPath -Raw -Encoding utf8
$manifestPattern = 'FunctionsToExport\s*=\s*@\((?s:.*?)\)\s*\r?\n\s*\r?\n\s*# Cmdlets to export from this module'
$manifestReplacement = @"
FunctionsToExport = @(
$functionListText
    )

    # Cmdlets to export from this module
"@

if (-not [regex]::IsMatch($manifestContent, $manifestPattern)) {
    throw "Could not locate FunctionsToExport block in module manifest: $manifestPath"
}

if ($PSCmdlet.ShouldProcess($manifestPath, 'Update FunctionsToExport list')) {
    $newManifestContent = [regex]::Replace($manifestContent, $manifestPattern, $manifestReplacement)
    Set-Content -Path $manifestPath -Value $newManifestContent -Encoding utf8
    Write-Information 'Updated FunctionsToExport in IntuneHydrationKit.psd1 from Public/**/*.ps1.' -InformationAction Continue
}
