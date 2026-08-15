<#
.SYNOPSIS
    Reopens the Claude Code sessions you actually worked on recently, one terminal tab each.

.DESCRIPTION
    After a crash, a power cut or an unplanned reboot, the conversations are still on disk
    under ~/.claude/projects — but getting them back means running `claude --resume` once per
    project, picking each session out of a list by hand.

    This script does it in bulk: it scans the transcripts, keeps the sessions that contain a
    real human message inside the requested time window, resolves the working directory each
    one belongs to, and opens them all as tabs of a single Windows Terminal window.

    Selection is based on message timestamps, not on file modification time. A plain
    `claude --resume` rewrites the transcript without you typing anything, so an mtime-based
    filter happily "recovers" sessions you never actually worked in.

.PARAMETER Days
    How far back to look, in calendar days. 1 means "since yesterday at midnight", so it covers
    both yesterday and today — the usual shape of an overnight crash. 0 limits the search to
    today. Called with nothing at all, the script prints its usage and opens nothing.

.PARAMETER ClaudeArgs
    Anything left on the command line is forwarded verbatim to every `claude` invocation, so
    the recovered sessions can be started with the flags you would have typed yourself:
    --dangerously-skip-permissions, --model, and so on.

.PARAMETER WindowName
    Target Windows Terminal window. '0' (default) reuses the current one, matching what
    Windows Terminal does when it is configured to reuse an existing window. Any other string
    names a dedicated window, which keeps recovered sessions grouped together.

.PARAMETER Exclude
    Session ids, full or partial, to leave alone. The current session excludes itself.

.PARAMETER Include
    Session ids, full or partial, comma-separated. Given, only these are reopened. This is the
    non-interactive half of picking: list with -DryRun, then reopen the ones you want. Separate
    the ids with commas rather than spaces, or the second one is taken for a forwarded argument.

.PARAMETER SampleLines
    How many lines of a session's opening prompt to show before cutting it off. Default 10. The
    first line of a prompt is often just a preamble, so one line is rarely enough to recognise
    what the session was about.

.PARAMETER Grouping
    How the reopened sessions are spread over windows. 'single' (default) puts every tab in one
    window, 'workdir' gives each working directory a window of its own so related conversations
    stay together, 'session' gives every session its own window.

.PARAMETER Order
    Launch order within a window. 'oldest' (default) opens oldest first, which leaves the most
    recent session as the active tab. 'newest' reverses it.

.PARAMETER NoPrompt
    Skip the confirmation screen that would otherwise let you change grouping and order before
    anything opens.

.PARAMETER Pick
    Choose which sessions to reopen in an interactive list — arrows to move, space to toggle,
    enter to confirm. Needs a real console, so it is unavailable when the script is driven by
    another program; use -DryRun with -Include there.

.PARAMETER DryRun
    List what would be reopened and stop.

.EXAMPLE
    ./Recover-ClaudeSessions.ps1
    Reopen everything worked on since yesterday midnight.

.EXAMPLE
    ./Recover-ClaudeSessions.ps1 -Days 3 -DryRun
    Show, without opening anything, the sessions worked on in the last three days.

.EXAMPLE
    ./Recover-ClaudeSessions.ps1 3 --dangerously-skip-permissions
    Reopen the last three days, each session started without permission prompts.

.LINK
    https://github.com/csm101/claude-recover-sessions
#>
# PositionalBinding is off so that a forwarded flag cannot be bound to -Days and rejected as a
# malformed integer. Every loose token reaches $ClaudeArgs, and the leading day count is taken
# out of it below.
[CmdletBinding(PositionalBinding = $false)]
param(
    [int]$Days = 1,
    [string]$WindowName = '0',
    [string[]]$Exclude = @(),
    [string[]]$Include = @(),
    [int]$SampleLines = 10,
    [ValidateSet('single', 'workdir', 'session')]
    [string]$Grouping = 'single',
    [ValidateSet('oldest', 'newest')]
    [string]$Order = 'oldest',
    [switch]$Pick,
    [switch]$NoPrompt,
    [switch]$DryRun,

    # Everything not recognised above — including bare --flags — lands here and is handed to
    # `claude` untouched.
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ClaudeArgs = @()
)

$ErrorActionPreference = 'Stop'

function Show-Usage {
    $me = if ($PSCommandPath) { Split-Path $PSCommandPath -Leaf } else { 'Recover-ClaudeSessions.ps1' }
    $lines = @(
        '',
        'Reopens the Claude Code sessions you actually worked on, one terminal tab each.',
        '',
        "  $me <days> [-Pick] [-DryRun] [-Include <id>] [-Exclude <id>] [-WindowName <name>] [claude flags...]",
        '',
        '  <days>            how far back to look. 1 covers yesterday and today, 0 today only.',
        '  -Pick             choose from an interactive list instead of reopening everything.',
        '  -DryRun           list what would reopen, open nothing.',
        '  -Include          reopen only these session ids, full or partial. Comma-separated.',
        '  -Exclude          session ids, full or partial, to leave alone. Comma-separated.',
        '  -SampleLines      how many lines of the opening prompt to show. Default 10.',
        '  -Grouping         single (default) | workdir | session — how tabs spread over windows.',
        '  -Order            oldest (default) | newest — launch order within a window.',
        '  -NoPrompt         skip the screen that asks about grouping and order.',
        '  -WindowName       target window when grouping is single. 0 (default) reuses the current one.',
        '  claude flags      anything else is forwarded verbatim to each recovered session.',
        '',
        'Examples:',
        "  $me 1                                    everything since yesterday midnight",
        "  $me 3 -Pick                              pick from the last three days",
        "  $me 3 -DryRun                            list the last three days, open nothing",
        "  $me 3 -Include b47087de,eb3865e1         reopen just those two",
        "  $me 1 --dangerously-skip-permissions     reopen without permission prompts",
        "  $me 7 --model opus                       last week, each session on a chosen model",
        '',
        'Sessions already open in another tab are skipped, so running it twice is safe.',
        ''
    )
    foreach ($line in $lines) { Write-Host $line }
}

# Called bare, say what this does rather than reopening a week of work unasked.
if ($PSBoundParameters.Count -eq 0 -and $ClaudeArgs.Count -eq 0) {
    Show-Usage
    return
}

# A leading bare number is the day count; everything after it belongs to claude.
if (-not $PSBoundParameters.ContainsKey('Days') -and $ClaudeArgs.Count -gt 0 -and $ClaudeArgs[0] -match '^\d+$') {
    $Days = [int]$ClaudeArgs[0]
    $ClaudeArgs = @($ClaudeArgs | Select-Object -Skip 1)
}

$From = (Get-Date).Date.AddDays(-$Days)
$To   = Get-Date

function Get-ClaudeProjectRoot {
    $configDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
    return (Join-Path $configDir 'projects')
}

# Claude Code names each project directory after its working directory, flattening the
# characters that are illegal in a path. The mapping is lossy, so it is only ever used to
# recognise a candidate cwd, never to reconstruct one.
function ConvertTo-ProjectDirName([string]$Path) {
    return ($Path -replace '[:\\/_.]', '-')
}

function Test-HumanPrompt($Entry) {
    if ($Entry.isMeta -or $Entry.toolUseResult -or -not $Entry.timestamp) { return $false }
    return $true
}

function Get-PromptText($Entry) {
    if ($Entry.message.content -is [string]) { return $Entry.message.content }
    return ($Entry.message.content | Where-Object { $_.type -eq 'text' } | Select-Object -First 1).text
}

# User-role entries also carry tool results, injected reminders and hook output. Only text the
# person actually typed counts as evidence that the session was in use.
function Test-UserAuthored([string]$Text) {
    if (-not $Text) { return $false }
    foreach ($prefix in '<', 'Caveat:', '[Request interrupted') {
        if ($Text.StartsWith($prefix)) { return $false }
    }
    return $true
}

# `claude --resume <id>` looks the session up relative to the current directory, so the tab has
# to start in the cwd whose encoded form matches the project directory holding the transcript.
# That is not always the first cwd recorded in the file: a session continued elsewhere keeps its
# original cwd in the early entries.
function Resolve-SessionCwd([System.IO.FileInfo]$Jsonl, [string[]]$CwdsSeen) {
    foreach ($cwd in $CwdsSeen) {
        if ((ConvertTo-ProjectDirName $cwd) -eq $Jsonl.Directory.Name) { return $cwd }
    }
    if ($CwdsSeen.Count -gt 0) { return $CwdsSeen[0] }
    return $null
}

function Expand-JsonString([string]$Raw) {
    return $Raw -replace '\\n', ' ' -replace '\\t', ' ' -replace '\\"', '"' -replace '\\\\', '\'
}

function Get-WorkedSession([System.IO.FileInfo]$Jsonl) {
    $cwds = [System.Collections.Generic.List[string]]::new()
    $times = [System.Collections.Generic.List[datetime]]::new()
    $firstPrompt = $null
    $title = $null

    # Transcripts reach hundreds of megabytes, so lines are streamed and only the ones that can
    # possibly be user turns are handed to the JSON parser.
    foreach ($line in [System.IO.File]::ReadLines($Jsonl.FullName)) {
        if ($line -notmatch '"type":"user"') {
            if ($cwds.Count -eq 0 -and $line -match '"cwd":"((?:[^"\\]|\\.)*)"') {
                $cwds.Add(($Matches[1] -replace '\\\\', '\'))
            }
            # Claude Code names the conversation as it goes and rewrites the entry each time, so
            # the last one wins. Older sessions predate the feature and simply have none.
            if ($line -match '"aiTitle":"((?:[^"\\]|\\.)*)"') {
                $title = Expand-JsonString $Matches[1]
            }
            continue
        }
        try { $entry = $line | ConvertFrom-Json } catch { continue }
        if ($entry.cwd -and -not $cwds.Contains($entry.cwd)) { $cwds.Add($entry.cwd) }
        if (-not (Test-HumanPrompt $entry)) { continue }

        $when = ([datetime]$entry.timestamp).ToLocalTime()
        if ($when -lt $From -or $when -gt $To) { continue }

        $text = Get-PromptText $entry
        if (-not (Test-UserAuthored $text)) { continue }

        $times.Add($when)
        if (-not $firstPrompt) { $firstPrompt = ($text -replace '\s+', ' ').Trim() }
    }

    if ($times.Count -eq 0) { return $null }
    return [pscustomobject]@{
        Id        = $Jsonl.BaseName
        Path      = $Jsonl.FullName
        Cwd       = Resolve-SessionCwd $Jsonl $cwds
        Title     = $title
        Prompts   = $times.Count
        FirstSeen = ($times | Measure-Object -Minimum).Minimum
        LastSeen  = ($times | Measure-Object -Maximum).Maximum
        Sample    = $firstPrompt
    }
}

# When this script runs as a child of Claude Code, the environment carries variables that the
# recovered sessions would inherit: NO_COLOR=1 strips the colours from their UI, and
# CLAUDECODE / CLAUDE_CODE_* convince a fresh instance that it is nested inside another one.
# wt.exe passes its own environment on to the tabs it opens, so the cleanup has to happen here,
# before it is invoked — doing it inside the tab command would mean another layer of quoting.
# The variables are put back afterwards: the caller may be a long-lived shell that goes on to
# run this script again, and a permanently stripped CLAUDE_CODE_SESSION_ID would stop the second
# run from recognising — and skipping — the session it is running in.
function Clear-InheritedClaudeEnv {
    $names = @('NO_COLOR', 'CLAUDECODE', 'CLAUDE_PID') +
             @(Get-ChildItem Env: | Where-Object Name -like 'CLAUDE_CODE_*' | Select-Object -ExpandProperty Name)
    $saved = @{}
    foreach ($name in $names) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($null -ne $value) { $saved[$name] = $value }
        Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    }
    return $saved
}

function Restore-InheritedClaudeEnv([hashtable]$Saved) {
    foreach ($name in $Saved.Keys) {
        Set-Item "Env:$name" $Saved[$name]
    }
}

# A session already live in another tab must not be opened twice. Its id appears in the command
# line of the shell hosting it.
#
# Do not narrow this by searching for 'claude --resume' in the command lines: that string also
# ends up in the command line of the process doing the search, which then kills itself.
function Get-AlreadyOpenSessionId {
    $ids = [System.Collections.Generic.List[string]]::new()
    $guid = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    foreach ($p in Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'") {
        if ($p.ProcessId -eq $PID -or -not $p.CommandLine) { continue }
        foreach ($m in [regex]::Matches($p.CommandLine, $guid)) {
            if (-not $ids.Contains($m.Value)) { $ids.Add($m.Value) }
        }
    }
    return $ids
}

# [Console]::WindowWidth throws an invalid-handle error when the output is redirected, which is
# exactly what happens when another program runs the script and reads what it prints.
function Get-ConsoleSize([string]$Dimension, [int]$Fallback) {
    try {
        $value = if ($Dimension -eq 'Width') { [Console]::WindowWidth } else { [Console]::WindowHeight }
        if ($value -gt 0) { return $value }
    } catch { }
    return $Fallback
}

function Format-SessionLine($Session) {
    $line = '{0}  {1}  {2,3} prompts  {3}' -f $Session.Id.Substring(0, 8),
                                              $Session.LastSeen.ToString('MM-dd HH:mm'),
                                              $Session.Prompts,
                                              $Session.Cwd
    if ($Session.Title) { $line += '  — ' + $Session.Title }
    return $line
}

function Write-Truncated([string]$Text, [int]$Width, [hashtable]$Colour) {
    if ($Text.Length -gt $Width) { $Text = $Text.Substring(0, [Math]::Max(0, $Width - 1)) + '…' }
    Write-Host $Text @Colour
}

# An opening prompt is often a paragraph, and its first line rarely says what the session is
# about. Wrapping it over a few lines is what makes the list recognisable.
function Format-Wrapped([string]$Text, [int]$Width, [int]$MaxLines) {
    $lines = [System.Collections.Generic.List[string]]::new()
    if (-not $Text -or $Width -lt 10) { return $lines }

    $rest = $Text
    while ($rest.Length -gt 0 -and $lines.Count -lt $MaxLines) {
        if ($rest.Length -le $Width) {
            $lines.Add($rest)
            $rest = ''
            break
        }
        $break = $rest.LastIndexOf(' ', $Width)
        # A word longer than the line has no break point to find; split it mid-way instead.
        if ($break -lt [int]($Width / 2)) { $break = $Width }
        $lines.Add($rest.Substring(0, $break).TrimEnd())
        $rest = $rest.Substring($break).TrimStart()
    }

    if ($rest.Length -gt 0) {
        $last = $lines[$lines.Count - 1]
        if ($last.Length -ge $Width) { $last = $last.Substring(0, $Width - 1) }
        $lines[$lines.Count - 1] = $last + '…'
    }
    return $lines
}

function Write-SessionSample($Session, [int]$Width, [int]$MaxLines, [string]$Indent) {
    # @() matters: PowerShell unrolls the returned list, and a single wrapped line would arrive
    # as a bare string whose indexer yields characters instead of lines.
    $wrapped = @(Format-Wrapped $Session.Sample ($Width - $Indent.Length - 2) $MaxLines)
    for ($i = 0; $i -lt $wrapped.Count; $i++) {
        $prefix = if ($i -eq 0) { '> ' } else { '  ' }
        Write-Host ($Indent + $prefix + $wrapped[$i]) -ForegroundColor DarkGray
    }
}

# Only what was said: tool calls, their results and injected reminders are left out, because the
# question the reader is answering is "which conversation was this", not "what did it run".
function Get-Conversation([string]$Path) {
    $messages = [System.Collections.Generic.List[object]]::new()
    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if ($line -notmatch '"type":"(user|assistant)"') { continue }
        try { $entry = $line | ConvertFrom-Json } catch { continue }
        if ($entry.isMeta -or $entry.toolUseResult) { continue }

        $text = if ($entry.message.content -is [string]) {
            $entry.message.content
        } else {
            (($entry.message.content | Where-Object { $_.type -eq 'text' }).text) -join "`n"
        }
        if (-not $text) { continue }
        if ($entry.type -eq 'user' -and -not (Test-UserAuthored $text)) { continue }

        $messages.Add([pscustomobject]@{
            Role = $entry.type
            When = if ($entry.timestamp) { ([datetime]$entry.timestamp).ToLocalTime() } else { $null }
            Text = ($text -replace "`r", '')   # parenthesised: inside a method call the comma would split arguments
        })
    }
    return , $messages
}

function Get-ConversationDisplay($Messages, [int]$Width) {
    $lines = [System.Collections.Generic.List[object]]::new()
    foreach ($message in $Messages) {
        $who = if ($message.Role -eq 'user') { 'you' } else { 'claude' }
        if ($message.When) { $who += '   ' + $message.When.ToString('MM-dd HH:mm') }
        $lines.Add(@{
            Text   = $who
            Colour = @{ ForegroundColor = if ($message.Role -eq 'user') { 'Cyan' } else { 'DarkYellow' } }
        })
        foreach ($paragraph in ($message.Text -split "`n")) {
            if (-not $paragraph.Trim()) {
                $lines.Add(@{ Text = ''; Colour = @{} })
                continue
            }
            foreach ($wrapped in @(Format-Wrapped $paragraph ($Width - 2) 5000)) {
                $lines.Add(@{ Text = '  ' + $wrapped; Colour = @{} })
            }
        }
        $lines.Add(@{ Text = ''; Colour = @{} })
    }
    if ($lines.Count -eq 0) { $lines.Add(@{ Text = '(nothing said in this session)'; Colour = @{} }) }
    return , $lines
}

function Show-Conversation($Session) {
    $width = [Math]::Max(60, (Get-ConsoleSize Width 120) - 1)
    Clear-Host
    Write-Host 'Reading the conversation…' -ForegroundColor DarkGray
    $lines = Get-ConversationDisplay (Get-Conversation $Session.Path) $width
    $offset = 0

    while ($true) {
        $viewport = [Math]::Max(3, (Get-ConsoleSize Height 30) - 4)
        $maxOffset = [Math]::Max(0, $lines.Count - $viewport)
        if ($offset -gt $maxOffset) { $offset = $maxOffset }
        if ($offset -lt 0) { $offset = 0 }

        Clear-Host
        $heading = '{0}  {1}' -f $Session.Id.Substring(0, 8), $Session.Cwd
        if ($Session.Title) { $heading += '  — ' + $Session.Title }
        Write-Truncated $heading $width @{ ForegroundColor = 'Cyan' }
        Write-Host ('↑↓ scroll   pgup/pgdn page   home/end   esc back    {0}-{1} of {2}' -f
                    ($offset + 1), [Math]::Min($offset + $viewport, $lines.Count), $lines.Count) -ForegroundColor DarkGray
        Write-Host ''

        for ($i = $offset; $i -lt [Math]::Min($offset + $viewport, $lines.Count); $i++) {
            Write-Truncated $lines[$i].Text $width $lines[$i].Colour
        }

        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            'UpArrow'   { $offset-- }
            'DownArrow' { $offset++ }
            'PageUp'    { $offset -= $viewport }
            'PageDown'  { $offset += $viewport }
            'Home'      { $offset = 0 }
            'End'       { $offset = $maxOffset }
            'Escape'    { return }
            default {
                switch ($key.KeyChar) {
                    'k' { $offset-- }
                    'j' { $offset++ }
                    'q' { return }
                    ' ' { $offset += $viewport }
                }
            }
        }
    }
}

# Arrow keys to move, space to toggle, enter to confirm. Everything starts selected, because the
# common case is still "give me all of it" and deselecting two is quicker than selecting twenty.
# Returns the chosen sessions, or $null when the user backs out.
function Invoke-SessionPicker([object[]]$Sessions) {
    $chosen = [bool[]]::new($Sessions.Count)
    for ($i = 0; $i -lt $chosen.Count; $i++) { $chosen[$i] = $true }
    $cursor = 0
    $offset = 0

    while ($true) {
        $width = [Math]::Max(60, (Get-ConsoleSize Width 120) - 1)

        # Reserve the detail area for the longest prompt in the set rather than for the one under
        # the cursor, so the list does not jump up and down as you move through it.
        $detailHeight = 1
        foreach ($s in $Sessions) {
            $needed = @(Format-Wrapped $s.Sample ($width - 4) $SampleLines).Count
            if ($needed -gt $detailHeight) { $detailHeight = $needed }
        }

        $viewport = [Math]::Max(3, (Get-ConsoleSize Height 30) - 7 - $detailHeight)
        if ($viewport -gt $Sessions.Count) { $viewport = $Sessions.Count }
        if ($cursor -lt $offset) { $offset = $cursor }
        if ($cursor -ge $offset + $viewport) { $offset = $cursor - $viewport + 1 }

        Clear-Host
        Write-Host ("Select the sessions to reopen — {0} of {1}" -f ($chosen | Where-Object { $_ }).Count, $Sessions.Count) -ForegroundColor Cyan
        Write-Host '↑↓ move   space toggle   a all/none   v view conversation   enter reopen   esc cancel' -ForegroundColor DarkGray
        Write-Host ''

        for ($i = $offset; $i -lt $offset + $viewport; $i++) {
            $line = '{0} {1} {2}' -f $(if ($i -eq $cursor) { '>' } else { ' ' }),
                                     $(if ($chosen[$i]) { '[x]' } else { '[ ]' }),
                                     (Format-SessionLine $Sessions[$i])
            $colour = if ($i -eq $cursor) { @{ ForegroundColor = 'Black'; BackgroundColor = 'Gray' } }
                      elseif ($chosen[$i]) { @{} }
                      else { @{ ForegroundColor = 'DarkGray' } }
            Write-Truncated $line $width $colour
        }

        if ($Sessions.Count -gt $viewport) {
            Write-Host ("  … {0}-{1} of {2}" -f ($offset + 1), ($offset + $viewport), $Sessions.Count) -ForegroundColor DarkGray
        }
        Write-Host ''
        Write-SessionSample $Sessions[$cursor] $width $SampleLines '  '

        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            'UpArrow'   { if ($cursor -gt 0) { $cursor-- } }
            'DownArrow' { if ($cursor -lt $Sessions.Count - 1) { $cursor++ } }
            'Home'      { $cursor = 0 }
            'End'       { $cursor = $Sessions.Count - 1 }
            'PageUp'    { $cursor = [Math]::Max(0, $cursor - $viewport) }
            'PageDown'  { $cursor = [Math]::Min($Sessions.Count - 1, $cursor + $viewport) }
            'Spacebar'  { $chosen[$cursor] = -not $chosen[$cursor] }
            'Enter'     {
                Clear-Host
                $picked = @(for ($i = 0; $i -lt $Sessions.Count; $i++) { if ($chosen[$i]) { $Sessions[$i] } })
                return $picked
            }
            'Escape'    { Clear-Host; return $null }
            default {
                switch ($key.KeyChar) {
                    'a' {
                        $turnOn = ($chosen | Where-Object { $_ }).Count -lt $Sessions.Count
                        for ($i = 0; $i -lt $chosen.Count; $i++) { $chosen[$i] = $turnOn }
                    }
                    'k' { if ($cursor -gt 0) { $cursor-- } }
                    'j' { if ($cursor -lt $Sessions.Count - 1) { $cursor++ } }
                    'v' { Show-Conversation $Sessions[$cursor] }
                    'q' { Clear-Host; return $null }
                }
            }
        }
    }
}

function Get-GroupingLabel([string]$Value) {
    switch ($Value) {
        'single'  { return 'everything in one window' }
        'workdir' { return 'one window per working directory' }
        'session' { return 'one window per session' }
    }
}

function Get-OrderLabel([string]$Value) {
    if ($Value -eq 'oldest') { return 'oldest prompt first — the most recent ends up active' }
    return 'most recent prompt first'
}

# Asked rather than assumed: how the tabs are spread over windows is a matter of taste, and the
# moment to decide it is when you can see how many sessions came back.
function Invoke-OptionsPrompt([object[]]$Sessions, [string]$Grouping, [string]$Order) {
    $groupings = @('single', 'workdir', 'session')
    $orders = @('oldest', 'newest')

    while ($true) {
        $windows = switch ($Grouping) {
            'single'  { 1 }
            'workdir' { @($Sessions | Select-Object -ExpandProperty Cwd -Unique).Count }
            'session' { $Sessions.Count }
        }

        Clear-Host
        Write-Host ("About to reopen {0} session(s) in {1} window(s)." -f $Sessions.Count, $windows) -ForegroundColor Cyan
        Write-Host ''
        Write-Host ('  g   grouping   ' + (Get-GroupingLabel $Grouping))
        Write-Host ('  o   order      ' + (Get-OrderLabel $Order))
        Write-Host ''
        Write-Host '  enter reopen   esc cancel' -ForegroundColor DarkGray

        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            'Enter'  { Clear-Host; return @{ Grouping = $Grouping; Order = $Order } }
            'Escape' { Clear-Host; return $null }
            default {
                switch ($key.KeyChar) {
                    'g' { $Grouping = $groupings[(($groupings.IndexOf($Grouping)) + 1) % $groupings.Count] }
                    'o' { $Order = $orders[(($orders.IndexOf($Order)) + 1) % $orders.Count] }
                    'q' { Clear-Host; return $null }
                }
            }
        }
    }
}

# Sessions of the same working directory must be launched consecutively, or their tabs would be
# interleaved with other windows' — so groups are ordered by their own most recent session, and
# the chosen order applies both between groups and inside them.
function Sort-ForLaunch([object[]]$Sessions, [string]$Grouping, [string]$Order) {
    $descending = $Order -eq 'newest'
    if ($Grouping -ne 'workdir') {
        return @($Sessions | Sort-Object LastSeen -Descending:$descending)
    }

    $groups = $Sessions | Group-Object Cwd | ForEach-Object {
        [pscustomobject]@{
            Members = @($_.Group | Sort-Object LastSeen -Descending:$descending)
            Latest  = ($_.Group | Measure-Object LastSeen -Maximum).Maximum
        }
    }
    return @($groups | Sort-Object Latest -Descending:$descending | ForEach-Object { $_.Members })
}

function Get-TargetWindow($Session, [string]$Grouping) {
    switch ($Grouping) {
        'single'  { return $WindowName }
        'session' { return $Session.Id }
        'workdir' {
            # Window names have to be stable and distinct: the leaf alone collides between
            # unrelated repositories that happen to share a folder name.
            $leaf = Split-Path $Session.Cwd -Leaf
            $hash = [Math]::Abs($Session.Cwd.ToLowerInvariant().GetHashCode()) % 100000
            return ('{0}-{1}' -f $leaf, $hash)
        }
    }
}

function Get-TabShell {
    foreach ($candidate in 'pwsh', 'powershell') {
        $found = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($found) { return $candidate }
    }
    throw 'No PowerShell host found on PATH.'
}

# The tab is launched through `pwsh -Command <string>`, so a forwarded argument carrying spaces
# or quotes has to survive one more round of parsing.
function Format-ShellArgument([string]$Value) {
    if ($Value -match "^[-\w./:=@]+$") { return $Value }
    return "'" + ($Value -replace "'", "''") + "'"
}

function Open-Session($Session, [string]$Shell, [bool]$UseWindowsTerminal, [string]$Window) {
    $resume = "claude --resume $($Session.Id)"
    foreach ($arg in $ClaudeArgs) {
        $resume += ' ' + (Format-ShellArgument $arg)
    }
    $title = '{0} {1}' -f (Split-Path $Session.Cwd -Leaf), $Session.Id.Substring(0, 8)

    if ($UseWindowsTerminal) {
        wt.exe -w $Window new-tab --title $title -d $Session.Cwd $Shell -NoLogo -NoExit -Command $resume
        # Tabs fired back to back at `-w 0` can race and land in windows of their own.
        Start-Sleep -Milliseconds 600
        return
    }
    Start-Process $Shell -WorkingDirectory $Session.Cwd -ArgumentList '-NoLogo', '-NoExit', '-Command', $resume
}

$projectRoot = Get-ClaudeProjectRoot
if (-not (Test-Path -LiteralPath $projectRoot)) {
    throw "Claude Code transcripts not found at $projectRoot. Set CLAUDE_CONFIG_DIR if yours live elsewhere."
}

# CLAUDE_CODE_SESSION_ID is set when the command runs inside Claude Code: that is how this
# session recognises, and skips, itself.
$excluded = @($Exclude) + @($env:CLAUDE_CODE_SESSION_ID) | Where-Object { $_ }
$alreadyOpen = Get-AlreadyOpenSessionId

$candidates = Get-ChildItem $projectRoot -Recurse -Filter *.jsonl -File |
    Where-Object { $_.Directory.Name -ne 'subagents' -and $_.LastWriteTime -gt $From }

$skipped = [System.Collections.Generic.List[string]]::new()
$worked = foreach ($f in $candidates) {
    $s = Get-WorkedSession $f
    if (-not $s) { continue }
    if ($excluded | Where-Object { $s.Id.StartsWith($_) }) { continue }
    if ($alreadyOpen -contains $s.Id) {
        $skipped.Add($s.Id.Substring(0, 8))
        continue
    }
    if (-not $s.Cwd -or -not (Test-Path -LiteralPath $s.Cwd)) {
        Write-Warning "Skipping $($s.Id.Substring(0,8)): working directory is gone ($($s.Cwd))"
        continue
    }
    $s
}

# The same session id can appear under more than one project directory when a conversation was
# carried into another working directory. Only the latest copy is worth reopening.
$worked = @($worked | Group-Object Id | ForEach-Object {
    $_.Group | Sort-Object LastSeen -Descending | Select-Object -First 1
})

# Oldest first, so the most recent sessions end up as the rightmost — and active — tabs.
$worked = @($worked | Sort-Object LastSeen)

if ($Include.Count -gt 0) {
    $worked = @($worked | Where-Object { $id = $_.Id; $Include | Where-Object { $id.StartsWith($_) } })
}

Write-Host ("Sessions worked on since {0}: {1}" -f $From.ToString('yyyy-MM-dd HH:mm'), $worked.Count) -ForegroundColor Cyan
if ($skipped.Count -gt 0) {
    Write-Host ("Already open, left alone: {0}" -f (($skipped | Select-Object -Unique) -join ', ')) -ForegroundColor DarkYellow
}
if ($worked.Count -eq 0) { return }

if ($Pick -and -not $DryRun) {
    if ([Console]::IsInputRedirected) {
        Write-Warning 'Nothing was opened: -Pick needs an interactive console. Run with -DryRun and reopen your choice with -Include <id> <id>.'
        return
    }
    $worked = Invoke-SessionPicker $worked
    if (-not $worked -or $worked.Count -eq 0) {
        Write-Host 'Nothing selected.' -ForegroundColor DarkYellow
        return
    }
}

# Sorted before it is printed, so -DryRun shows the order the tabs would actually open in.
$worked = Sort-ForLaunch $worked $Grouping $Order

$listWidth = [Math]::Max(60, (Get-ConsoleSize Width 120) - 1)
foreach ($s in $worked) {
    Write-Host ('  ' + (Format-SessionLine $s))
    Write-SessionSample $s $listWidth $SampleLines '            '
}
if ($ClaudeArgs.Count -gt 0) {
    Write-Host ("Each session starts with: {0}" -f ($ClaudeArgs -join ' ')) -ForegroundColor Yellow
}
if ($DryRun) { return }

if (-not $NoPrompt -and -not [Console]::IsInputRedirected) {
    $answer = Invoke-OptionsPrompt $worked $Grouping $Order
    if (-not $answer) {
        Write-Host 'Cancelled, nothing opened.' -ForegroundColor DarkYellow
        return
    }
    $Grouping = $answer.Grouping
    $Order = $answer.Order
    $worked = Sort-ForLaunch $worked $Grouping $Order   # the answers may have changed both
}

$shell = Get-TabShell
$useWindowsTerminal = [bool](Get-Command wt.exe -ErrorAction SilentlyContinue)
if (-not $useWindowsTerminal) {
    Write-Host ("Windows Terminal not found; opening {0} separate console windows..." -f $worked.Count) -ForegroundColor Yellow
} else {
    $windowCount = @($worked | ForEach-Object { Get-TargetWindow $_ $Grouping } | Select-Object -Unique).Count
    Write-Host ("Opening {0} tabs across {1} window(s) — {2}, {3}." -f
                $worked.Count, $windowCount, (Get-GroupingLabel $Grouping), (Get-OrderLabel $Order)) -ForegroundColor Cyan
}

$savedEnv = Clear-InheritedClaudeEnv
try {
    foreach ($s in $worked) {
        Open-Session $s $shell $useWindowsTerminal (Get-TargetWindow $s $Grouping)
    }
} finally {
    Restore-InheritedClaudeEnv $savedEnv
}
Write-Host 'Done.' -ForegroundColor Green
