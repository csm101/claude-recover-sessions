<#
.SYNOPSIS
    Installs the /recover-sessions command for Claude Code without going through the plugin system.

.DESCRIPTION
    Copies the slash command into the Claude Code commands directory and the script next to it.
    Prefer the plugin install described in the README if you want updates handled for you; this
    is the plain-copy route for people who would rather not add a marketplace.

.PARAMETER Scope
    User (default) installs for every project, under the Claude Code config directory.
    Project installs into .claude/ of the current repository instead.

.PARAMETER Force
    Overwrite an existing installation.
#>
[CmdletBinding()]
param(
    [ValidateSet('User', 'Project')]
    [string]$Scope = 'User',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$source = $PSScriptRoot

$root = if ($Scope -eq 'Project') {
    Join-Path (Get-Location) '.claude'
} elseif ($env:CLAUDE_CONFIG_DIR) {
    $env:CLAUDE_CONFIG_DIR
} else {
    Join-Path $HOME '.claude'
}

$commandsDir = Join-Path $root 'commands'
$scriptDir   = Join-Path $root 'claude-recover-sessions'
$commandFile = Join-Path $commandsDir 'recover-sessions.md'

if ((Test-Path -LiteralPath $commandFile) -and -not $Force) {
    throw "$commandFile already exists. Re-run with -Force to overwrite."
}

foreach ($dir in $commandsDir, $scriptDir) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

Copy-Item (Join-Path $source 'commands/recover-sessions.md') $commandFile -Force
Copy-Item (Join-Path $source 'scripts/Recover-ClaudeSessions.ps1') $scriptDir -Force

Write-Host 'Installed:' -ForegroundColor Green
Write-Host "  command  $commandFile"
Write-Host "  script   $(Join-Path $scriptDir 'Recover-ClaudeSessions.ps1')"
Write-Host ''
Write-Host 'Restart Claude Code, then run /recover-sessions'

if (-not (Get-Command wt.exe -ErrorAction SilentlyContinue)) {
    Write-Warning 'Windows Terminal (wt.exe) was not found. Sessions will open in separate console windows instead of tabs.'
}
