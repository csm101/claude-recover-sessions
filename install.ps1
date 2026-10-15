<#
.SYNOPSIS
    Installs the /done command into your personal Claude Code configuration.

.DESCRIPTION
    Copies commands/done.md from this repository into the commands folder of your Claude Code
    configuration ($CLAUDE_CONFIG_DIR, or ~/.claude), where every session on this machine can use
    it. Running /done in a session marks it as concluded: Recover-ClaudeSessions.ps1 then lists it
    unticked and marked "closed" instead of reopening it.

    Run it once per machine, and again after pulling a newer done.md. It is a plain copy, so
    nothing breaks if this repository is later moved or deleted.

.PARAMETER Force
    Overwrite an existing done.md that differs from the one in this repository. Without it, a
    different file is left alone: it may be an older copy from here, or a /done of your own.

.PARAMETER Uninstall
    Remove the installed command. Only removes a file identical to the one in this repository,
    unless -Force is given as well.

.EXAMPLE
    .\install.ps1
    Install /done, or report that it is already up to date.

.EXAMPLE
    .\install.ps1 -Force
    Replace an older installed copy with the current one.
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot 'commands\done.md'
$configDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
$targetDir = Join-Path $configDir 'commands'
$target = Join-Path $targetDir 'done.md'

if (-not (Test-Path -LiteralPath $source)) {
    throw "Command source not found at $source."
}

function Test-SameContent([string]$A, [string]$B) {
    return (Get-FileHash -LiteralPath $A).Hash -eq (Get-FileHash -LiteralPath $B).Hash
}

if ($Uninstall) {
    if (-not (Test-Path -LiteralPath $target)) {
        Write-Host "Not installed, nothing to remove: $target" -ForegroundColor DarkYellow
        return
    }
    if (-not $Force -and -not (Test-SameContent $source $target)) {
        throw "$target differs from the one in this repository, so it was left in place. Use -Uninstall -Force to remove it anyway."
    }
    Remove-Item -LiteralPath $target
    Write-Host "Removed $target" -ForegroundColor Green
    return
}

if (Test-Path -LiteralPath $target) {
    if (Test-SameContent $source $target) {
        Write-Host "Already up to date: $target" -ForegroundColor Green
        return
    }
    if (-not $Force) {
        throw "$target already exists and differs from the one in this repository (an older copy, or a /done of your own). Use -Force to overwrite it."
    }
}

New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
Copy-Item -LiteralPath $source -Destination $target -Force
Write-Host "Installed /done -> $target" -ForegroundColor Green
Write-Host 'New Claude Code sessions see it straight away; a session already open may need restarting.' -ForegroundColor DarkGray
