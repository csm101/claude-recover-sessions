<#
.SYNOPSIS
    Removes a manual install of the /recover-sessions command.

.PARAMETER Scope
    User (default) or Project — must match what was used at install time.
#>
[CmdletBinding()]
param(
    [ValidateSet('User', 'Project')]
    [string]$Scope = 'User'
)

$ErrorActionPreference = 'Stop'

$root = if ($Scope -eq 'Project') {
    Join-Path (Get-Location) '.claude'
} elseif ($env:CLAUDE_CONFIG_DIR) {
    $env:CLAUDE_CONFIG_DIR
} else {
    Join-Path $HOME '.claude'
}

$targets = @(
    (Join-Path $root 'commands/recover-sessions.md'),
    (Join-Path $root 'claude-recover-sessions')
)

foreach ($t in $targets) {
    if (Test-Path -LiteralPath $t) {
        Remove-Item -LiteralPath $t -Recurse -Force
        Write-Host "Removed $t" -ForegroundColor Green
    } else {
        Write-Host "Not present: $t" -ForegroundColor DarkGray
    }
}
