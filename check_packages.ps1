<#>
.SYNOPSIS
    Keyv Supply-Chain Package Scanner for Windows
.DESCRIPTION
    PowerShell script for checking whether affected versions from the `keyv` and `cacheable`
    npm supply-chain compromise (August 4, 2026) are present in a local JavaScript
    development environment on Windows.

    The package and version list in `packages.csv` is a local copy of Wiz Research's
    published IOC list: https://github.com/wiz-sec-public/wiz-research-iocs

    Incident background: https://socket.dev/blog/popular-npm-packages-in-the-keyv-and-cacheable-namespaces-compromised-in-active-supply-chain

.REQUIREMENTS
    - PowerShell 5.1+ (Windows built-in) or PowerShell 7+
    - Node.js (required for package inventory scanning)
    - Any package manager you want to check: npm, pnpm, or Yarn

.NOTES
    Exit codes:
    - 0: No affected packages found
    - 1: One or more affected packages found
    - 2: Scan incomplete or failed to start
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$CsvFile
)

# Strict mode
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Resolve script directory
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ScriptDir = Resolve-Path $ScriptDir

# Default CSV file location
if (-not $CsvFile) {
    $CsvFile = Join-Path $ScriptDir "packages.csv"
}
else {
    $CsvFile = Resolve-Path $CsvFile
}

$InventoryScript = Join-Path $ScriptDir "package_inventory.js"

# Validate required files
if (-not (Test-Path $CsvFile)) {
    Write-Error "Error: cannot read package list: $CsvFile"
    exit 2
}

if (-not (Test-Path $InventoryScript)) {
    Write-Error "Error: cannot read inventory helper: $InventoryScript"
    exit 2
}

# Check for Node.js
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Error "Error: node is required but was not found in PATH."
    exit 2
}

# Create temp directory
$TempDir = [System.IO.Path]::GetTempFileName()
Remove-Item $TempDir
New-Item -ItemType Directory -Path $TempDir | Out-Null

# Cleanup on exit
$global:TempDir = $TempDir
function Cleanup {
    if (Test-Path $global:TempDir) {
        Remove-Item $global:TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Register-EngineEvent -SourceIdentifier "PowerShell.Exiting" -Action { Cleanup } | Out-Null

$FindingsFile = Join-Path $TempDir "findings.tsv"
New-Item -ItemType File -Path $FindingsFile -Force | Out-Null

$ScanFailures = 0
$ManagerCount = 0

function Warn-ScanFailed {
    param([string]$Source)
    Write-Warning "Warning: $Source could not be checked; results are incomplete."
    $global:ScanFailures++
}

function Scan-Path {
    param(
        [string]$Source,
        [string]$Kind,
        [string]$Mode,
        [string]$Path
    )

    $OutputFile = Join-Path $TempDir "output.tsv"

    try {
        $result = & node $InventoryScript $CsvFile $Mode $Path 2>$null
        if ($LASTEXITCODE -ne 0) {
            Warn-ScanFailed $Source
            return
        }
        $result | Set-Content -Path $OutputFile -Encoding UTF8
    }
    catch {
        Warn-ScanFailed $Source
        return
    }

    if (Test-Path $OutputFile) {
        $lines = Get-Content $OutputFile -Raw -ErrorAction SilentlyContinue
        if ($lines) {
            $lines.TrimEnd("`r`n").Split("`n") | ForEach-Object {
                $parts = $_ -split "`t"
                if ($parts.Count -ge 2 -and $parts[0] -and $parts[1]) {
                    "$Kind`t$Source`t$($parts[0])`t$($parts[1])" | Add-Content -Path $FindingsFile -Encoding UTF8
                }
            }
        }
    }
}

function Capture-Command {
    param(
        [string]$Description,
        [string]$OutputFile,
        [scriptblock]$Command
    )

    try {
        & $Command > $OutputFile 2>$null
        if ($LASTEXITCODE -ne 0) {
            Warn-ScanFailed $Description
            return $false
        }
        return $true
    }
    catch {
        Warn-ScanFailed $Description
        return $false
    }
}

function Scan-CommandPath {
    param(
        [string]$Description,
        [string]$Source,
        [string]$Kind,
        [string]$Mode,
        [scriptblock]$Command
    )

    $PathFile = Join-Path $TempDir "path.txt"

    if (-not (Capture-Command $Description $PathFile $Command)) {
        return
    }

    $rawPath = Get-Content $PathFile -Raw -ErrorAction SilentlyContinue
    if (-not $rawPath) {
        Warn-ScanFailed $Description
        return
    }

    # Try to parse as JSON (for npm root --global which outputs JSON)
    try {
        $path = $rawPath.Trim() | ConvertFrom-Json
    }
    catch {
        $path = $rawPath.Trim()
    }

    if (-not $path) {
        Warn-ScanFailed $Description
        return
    }

    Scan-Path $Source $Kind $Mode $path
}

Write-Host "Checking affected npm packages from $CsvFile"

# Scan project node_modules
Scan-Path "project" "installed" "node-modules" (Join-Path $PWD "node_modules")

# Scan yarn unplugged
Scan-Path "yarn-unplugged" "installed" "package-tree" (Join-Path $PWD ".yarn\unplugged")

# npm checks
if (Get-Command npm -ErrorAction SilentlyContinue) {
    $ManagerCount++
    Scan-CommandPath "npm global dependencies" "npm-global" "installed" "node-modules" { npm root --global }

    if (Capture-Command "npm cache" (Join-Path $TempDir "npm-cache.txt") { npm cache ls }) {
        Scan-Path "npm-cache" "cached" "npm-cache" (Join-Path $TempDir "npm-cache.txt")
    }
}

# pnpm checks
if (Get-Command pnpm -ErrorAction SilentlyContinue) {
    $ManagerCount++
    
    $pnpmGlobalRoot = & pnpm root --global 2>$null
    if ($LASTEXITCODE -eq 0 -and $pnpmGlobalRoot -and (Test-Path $pnpmGlobalRoot)) {
        Scan-Path "pnpm-global" "installed" "node-modules" $pnpmGlobalRoot
    }

    Scan-CommandPath "pnpm store" "pnpm-store" "cached" "pnpm-store" { pnpm store path }
}

# Yarn checks
if (Get-Command yarn -ErrorAction SilentlyContinue) {
    $ManagerCount++

    if (Capture-Command "Yarn version" (Join-Path $TempDir "yarn-version.txt") { yarn --version }) {
        $yarnVersion = Get-Content (Join-Path $TempDir "yarn-version.txt") -Raw
        $yarnMajor = $yarnVersion.Trim().Split('.')[0]

        if ($yarnMajor -eq "1") {
            Scan-CommandPath "Yarn global dependencies" "yarn-global" "installed" "package-tree" { yarn global dir --silent }
            Scan-CommandPath "Yarn cache" "yarn-cache" "cached" "yarn-cache" { yarn cache dir --silent }
        }
        else {
            Scan-CommandPath "Yarn cache" "yarn-cache" "cached" "yarn-cache" { yarn config get cacheFolder }
        }
    }

    # Yarn Berry project cache
    Scan-Path "yarn-project-cache" "cached" "yarn-cache" (Join-Path $PWD ".yarn\cache")
}

if ($ManagerCount -eq 0) {
    Warn-ScanFailed "npm, pnpm, and Yarn package-manager stores"
}

# Deduplicate and report
$uniqueFindings = Join-Path $TempDir "unique-findings.tsv"
if (Test-Path $FindingsFile) {
    Get-Content $FindingsFile | Sort-Object -Unique | Set-Content $uniqueFindings
}
else {
    New-Item -ItemType File -Path $uniqueFindings -Force | Out-Null
}

$Matches = 0
$InstalledMatches = 0
$CachedMatches = 0

if (Test-Path $uniqueFindings) {
    Get-Content $uniqueFindings | ForEach-Object {
        $parts = $_ -split "`t"
        if ($parts.Count -ge 4) {
            $kind = $parts[0]
            $source = $parts[1]
            $package = $parts[2]
            $version = $parts[3]
            
            Write-Host ("FOUND  {0,-9} {1,-18} {2}@{3}" -f $kind, $source, $package, $version)
            $Matches++
            if ($kind -eq "installed") { $InstalledMatches++ }
            else { $CachedMatches++ }
        }
    }
}

if ($Matches -gt 0) {
    $plural = if ($Matches -eq 1) { "y" } else { "ies" }
    Write-Host "$InstalledMatches installed and $CachedMatches cached affected package entr$plural found."
}

if ($ScanFailures -gt 0) {
    $plural = if ($ScanFailures -eq 1) { "" } else { "s" }
    Write-Warning "Scan incomplete: $ScanFailures check$plural failed."
    exit 2
}

if ($Matches -gt 0) {
    exit 1
}

Write-Host "No affected packages found."
exit 0