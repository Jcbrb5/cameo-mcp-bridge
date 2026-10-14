<#
.SYNOPSIS
    Install the Cameo MCP Bridge on Windows for CATIA Magic 2026x.

.DESCRIPTION
    1. Builds the Java plugin with Gradle against your CATIA Magic install (JDK 21).
    2. Deploys it to <CameoHome>\plugins\com.claude.cameo.bridge.
    3. Creates mcp-server\.venv and installs the Python MCP server into it.
    4. Registers the server with Claude Code (if the `claude` CLI is on PATH).

    Deploying into C:\Program Files usually needs an elevated (Run as administrator)
    PowerShell. Close CATIA Magic before running so the plugin jar is not locked.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1 `
        -CameoHome "C:\Program Files\Magic Cyber Systems Engineer" `
        -JdkHome "C:\Program Files\Eclipse Adoptium\jdk-21.0.5.11-hotspot"
#>
[CmdletBinding()]
param(
    # CATIA Magic install root (the folder that contains lib\md.jar). Auto-detected if omitted.
    [string]$CameoHome = $env:CAMEO_HOME,
    # JDK 21 home used to run Gradle and compile the plugin. Auto-detected if omitted.
    [string]$JdkHome,
    # Skip the Gradle build and only deploy the existing build output.
    [switch]$SkipBuild,
    # Skip copying the plugin into the CATIA Magic install.
    [switch]$SkipDeploy,
    # Skip creating the venv and installing the Python MCP server.
    [switch]$SkipPython,
    # Skip registering the MCP server with Claude Code.
    [switch]$SkipClaudeRegister
)

$ErrorActionPreference = 'Stop'
$RepoRoot = $PSScriptRoot
$PluginId = 'com.claude.cameo.bridge'

function Write-Step([string]$Message) {
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

# Run a native command without PowerShell 5.1 turning stderr output into terminating errors.
function Invoke-Native {
    param([string]$FilePath, [string[]]$Arguments, [switch]$Quiet)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # Send output to the host so it isn't captured as the function's return value.
        if ($Quiet) {
            & $FilePath @Arguments 2>&1 | Out-Null
        } else {
            & $FilePath @Arguments | Out-Host
        }
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Test-CameoHome([string]$Path) {
    return $Path -and (Test-Path (Join-Path $Path 'lib\md.jar'))
}

function Find-CameoHome {
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, 'C:\', 'D:\') |
        Where-Object { $_ -and (Test-Path $_) } |
        Select-Object -Unique
    $found = @()
    foreach ($root in $roots) {
        foreach ($dir in Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue) {
            if (Test-CameoHome $dir.FullName) {
                $found += $dir.FullName
                continue
            }
            # Vendor folders such as "Dassault Systemes" or "Cameo" nest the install one level deeper.
            foreach ($child in Get-ChildItem -Path $dir.FullName -Directory -ErrorAction SilentlyContinue) {
                if (Test-CameoHome $child.FullName) {
                    $found += $child.FullName
                }
            }
        }
    }
    return @($found | Select-Object -Unique)
}

function Get-JdkMajorVersion([string]$Path) {
    if (-not $Path -or -not (Test-Path (Join-Path $Path 'bin\javac.exe'))) {
        return $null
    }
    $releaseFile = Join-Path $Path 'release'
    if (-not (Test-Path $releaseFile)) {
        return $null
    }
    $line = Select-String -Path $releaseFile -Pattern '^JAVA_VERSION="(\d+)' | Select-Object -First 1
    if (-not $line) {
        return $null
    }
    return [int]$line.Matches[0].Groups[1].Value
}

function Find-Jdk21 {
    $candidates = @($env:JDK21_HOME, $env:JAVA21_HOME, $env:JAVA_HOME)
    $searchRoots = @(
        (Join-Path $env:ProgramFiles 'Eclipse Adoptium'),
        (Join-Path $env:ProgramFiles 'Java'),
        (Join-Path $env:ProgramFiles 'Microsoft'),
        (Join-Path $env:ProgramFiles 'Amazon Corretto'),
        (Join-Path $env:ProgramFiles 'Zulu'),
        (Join-Path $env:ProgramFiles 'BellSoft')
    )
    foreach ($root in $searchRoots) {
        if (Test-Path $root) {
            $candidates += Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '21' } |
                Sort-Object Name -Descending |
                ForEach-Object { $_.FullName }
        }
    }
    if ($CameoHome) {
        # Some CATIA Magic bundles ship a full JDK; most ship a JRE without javac, which won't work.
        $candidates += (Join-Path $CameoHome 'jre')
        $candidates += (Join-Path $CameoHome 'jdk')
    }
    foreach ($candidate in $candidates) {
        if ((Get-JdkMajorVersion $candidate) -eq 21) {
            return $candidate
        }
    }
    return $null
}

function Find-Python {
    $py = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($py) {
        return @($py.Source, '-3')
    }
    $python = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($python -and $python.Source -notlike '*\WindowsApps\*') {
        return @($python.Source)
    }
    return $null
}

Write-Host '=== Cameo MCP Bridge Installer (CATIA Magic 2026x / Windows) ==='

# --- Resolve CATIA Magic install ------------------------------------------------
if (-not $SkipBuild -or -not $SkipDeploy) {
    if ($CameoHome) {
        if (-not (Test-CameoHome $CameoHome)) {
            throw "CameoHome '$CameoHome' does not contain lib\md.jar. Point -CameoHome at the CATIA Magic install root."
        }
    } else {
        $installs = Find-CameoHome
        if ($installs.Count -eq 0) {
            throw 'Could not find a CATIA Magic install (a folder containing lib\md.jar). Pass -CameoHome "C:\Path\To\CATIA Magic".'
        }
        if ($installs.Count -gt 1) {
            Write-Host 'Found several CATIA Magic installs:'
            $installs | ForEach-Object { Write-Host "  $_" }
            throw 'Pass -CameoHome to choose which one to install into.'
        }
        $CameoHome = $installs[0]
    }
    $CameoHome = (Resolve-Path $CameoHome).Path
    Write-Host "CATIA Magic: $CameoHome"
}

# --- Build ------------------------------------------------------------------------
$pluginDir = Join-Path $RepoRoot 'plugin'
$distDir = Join-Path $pluginDir "build\plugin-dist\$PluginId"

if (-not $SkipBuild) {
    Write-Step 'Building Java plugin'
    if (-not $JdkHome) {
        $JdkHome = Find-Jdk21
    }
    if (-not $JdkHome -or (Get-JdkMajorVersion $JdkHome) -ne 21) {
        throw ('A JDK 21 is required to build the plugin (CATIA Magic 2026x runs on Java 21). ' +
            'Install one (e.g. https://adoptium.net/temurin/releases/?version=21) and pass -JdkHome, or set JDK21_HOME.')
    }
    Write-Host "JDK 21: $JdkHome"

    $previousJavaHome = $env:JAVA_HOME
    $env:JAVA_HOME = $JdkHome
    Push-Location $pluginDir
    try {
        $gradleArgs = @(
            'clean', 'assemblePlugin',
            ('-PcameoHome=' + ($CameoHome -replace '\\', '/')),
            ('-PjdkHome=' + ($JdkHome -replace '\\', '/'))
        )
        $code = Invoke-Native (Join-Path $pluginDir 'gradlew.bat') $gradleArgs
        if ($code -ne 0) {
            throw "Gradle build failed (exit code $code)."
        }
    } finally {
        Pop-Location
        $env:JAVA_HOME = $previousJavaHome
    }
}

# --- Deploy -----------------------------------------------------------------------
if (-not $SkipDeploy) {
    Write-Step 'Deploying plugin to CATIA Magic'
    if (-not (Test-Path (Join-Path $distDir 'plugin.xml'))) {
        throw "Build output not found at $distDir. Run without -SkipBuild."
    }

    $running = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($CameoHome, [StringComparison]::OrdinalIgnoreCase) }
    if ($running) {
        throw 'CATIA Magic is running from this install. Close it so the plugin jar is not locked, then rerun.'
    }

    $targetDir = Join-Path $CameoHome "plugins\$PluginId"
    try {
        New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
        Get-ChildItem -Path $targetDir -Filter 'cameo-mcp-bridge-*.jar' -ErrorAction SilentlyContinue |
            Remove-Item -Force
        Copy-Item -Path (Join-Path $distDir '*') -Destination $targetDir -Recurse -Force
    } catch [System.UnauthorizedAccessException] {
        throw "No write access to $targetDir. Rerun this script from an elevated PowerShell (Run as administrator)."
    }
    Write-Host "Plugin deployed to: $targetDir"
}

# --- Python MCP server --------------------------------------------------------------
$serverDir = Join-Path $RepoRoot 'mcp-server'
$venvPython = Join-Path $serverDir '.venv\Scripts\python.exe'

if (-not $SkipPython) {
    Write-Step 'Installing Python MCP server'
    if (-not (Test-Path $venvPython)) {
        $python = Find-Python
        if (-not $python) {
            throw 'Python 3.10+ not found. Install it from https://www.python.org/downloads/windows/ (tick "Add python.exe to PATH") and rerun.'
        }
        $pythonExe = $python[0]
        $pythonArgs = @($python | Select-Object -Skip 1) + @('-m', 'venv', (Join-Path $serverDir '.venv'))
        $code = Invoke-Native $pythonExe $pythonArgs
        if ($code -ne 0 -or -not (Test-Path $venvPython)) {
            throw 'Failed to create mcp-server\.venv.'
        }
    }

    $code = Invoke-Native $venvPython @('-c', 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)')
    if ($code -ne 0) {
        throw "The Python in mcp-server\.venv is older than 3.10. Delete mcp-server\.venv and rerun with Python 3.10+."
    }

    Invoke-Native $venvPython @('-m', 'pip', 'install', '--quiet', '--upgrade', 'pip') | Out-Null
    $code = Invoke-Native $venvPython @('-m', 'pip', 'install', '--quiet', '-e', $serverDir)
    if ($code -ne 0) {
        throw 'pip install of the MCP server failed.'
    }
    Write-Host "Python server installed in: $(Split-Path (Split-Path $venvPython))"
}

# --- Claude Code registration --------------------------------------------------------
if (-not $SkipClaudeRegister) {
    Write-Step 'Registering MCP server with Claude Code'
    $claude = Get-Command claude -ErrorAction SilentlyContinue
    if ($claude) {
        Invoke-Native $claude.Source @('mcp', 'remove', 'cameo-bridge', '--scope', 'user') -Quiet | Out-Null
        $code = Invoke-Native $claude.Source @('mcp', 'add', 'cameo-bridge', '--scope', 'user', '--', $venvPython, '-m', 'cameo_mcp.server')
        if ($code -ne 0) {
            Write-Warning 'claude mcp add failed. Register manually with the command below.'
            Write-Host "  claude mcp add cameo-bridge --scope user -- `"$venvPython`" -m cameo_mcp.server"
        }
    } else {
        Write-Host 'Claude CLI not found. Register manually with:'
        Write-Host "  claude mcp add cameo-bridge --scope user -- `"$venvPython`" -m cameo_mcp.server"
    }
}

Write-Host ''
Write-Host '=== Installation complete ===' -ForegroundColor Green
Write-Host ''
Write-Host 'Next steps:'
Write-Host '  1. Start CATIA Magic and open a project'
Write-Host '  2. Start a new Claude Code session'
Write-Host "  3. Say: 'Check cameo status'"
