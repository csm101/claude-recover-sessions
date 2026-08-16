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

.PARAMETER All
    Reopen everything found, skipping the list you would otherwise choose from. Naming sessions
    with -Include has the same effect: the choice is already made.

.PARAMETER Pick
    Accepted and ignored. Choosing from the list is the default; this exists so the old spelling
    is not mistaken for an argument meant for claude.

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
    [switch]$All,

    # Accepted and ignored: picking is the default now. Declared so that a -Pick typed from
    # memory is not swept into $ClaudeArgs and handed to claude, which would not understand it.
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
        "  $me <days> [-All] [-DryRun] [-Include <id>] [-Exclude <id>] [-WindowName <name>] [claude flags...]",
        '',
        '  <days>            how far back to look. 1 covers yesterday and today, 0 today only.',
        '  -All              reopen everything, skipping the list you would otherwise choose from.',
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
        "  $me 1                                    choose from what you worked on since yesterday",
        "  $me 3 -All                               reopen the last three days without choosing",
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

function Get-ClaudeConfigDir {
    if ($env:CLAUDE_CONFIG_DIR) { return $env:CLAUDE_CONFIG_DIR }
    return (Join-Path $HOME '.claude')
}

function Get-ClaudeProjectRoot {
    return (Join-Path (Get-ClaudeConfigDir) 'projects')
}

# Session ids the picker was told 'no' for, remembered across runs so the next recovery does not
# ask again about the same session. Lives next to the transcripts rather than the script, since a
# clone of the repo should not start out claiming to know what you have already declined.
function Get-DeselectionStorePath {
    return (Join-Path (Get-ClaudeConfigDir) 'recover-sessions-deselected.json')
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

# Ids read as strings, never resolved against anything here — a session gone from disk is
# handled separately, by Get-PrunedDeselection, so a transient read error does not wipe memory.
#
# Every return below is `, $ids` rather than `$ids`: an empty HashSet is still IEnumerable, and
# PowerShell unrolls a returned IEnumerable into the pipeline — zero elements in means the caller
# captures $null instead of an empty set. Same trick Get-Conversation uses, same reason.
function Get-DeselectedIds([string]$Path) {
    $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if (-not (Test-Path -LiteralPath $Path)) { return , $ids }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        Write-Warning "Could not read $Path, starting with no remembered deselections: $($_.Exception.Message)"
        return , $ids
    }
    foreach ($id in @($raw)) { if ($id) { $ids.Add([string]$id) | Out-Null } }
    return , $ids
}

function Save-DeselectedIds([string]$Path, [System.Collections.Generic.HashSet[string]]$Ids) {
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $sorted = @($Ids | Sort-Object)
    # The unary comma keeps ConvertTo-Json from unrolling a one-item (or empty) array into a bare
    # scalar before it ever sees it — the same trick Get-Conversation uses for the same reason.
    (, $sorted | ConvertTo-Json) | Set-Content -LiteralPath $Path -Encoding utf8
}

# A session deselected once and never seen again (its transcript deleted, or the whole project
# directory gone) would otherwise sit in the store forever. Checked against every transcript on
# disk, not just the current -Days window, since an old deselection must survive a narrower search.
function Get-PrunedDeselection([System.Collections.Generic.HashSet[string]]$Ids, [string[]]$ExistingSessionIds) {
    $existing = [System.Collections.Generic.HashSet[string]]::new([string[]]$ExistingSessionIds, [System.StringComparer]::OrdinalIgnoreCase)
    $pruned = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $Ids) { if ($existing.Contains($id)) { $pruned.Add($id) | Out-Null } }
    return , $pruned
}

# What the picker returns is only the ones kept; what has to be remembered is the ones dropped.
# Diffed against every session the picker showed, not just $Picked, so ticking a session back on
# forgets its old deselection instead of leaving a stale entry the next run would still honour.
function Get-UpdatedDeselection([object[]]$Shown, [object[]]$Picked, [System.Collections.Generic.HashSet[string]]$Current) {
    $pickedIds = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Picked | ForEach-Object Id), [System.StringComparer]::OrdinalIgnoreCase)
    $updated = [System.Collections.Generic.HashSet[string]]::new($Current, [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($s in $Shown) {
        if ($pickedIds.Contains($s.Id)) { $updated.Remove($s.Id) | Out-Null } else { $updated.Add($s.Id) | Out-Null }
    }
    return , $updated
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

# Prints a line built from differently-coloured pieces, truncating (with a trailing ellipsis)
# at the first piece that would overflow the width instead of at a fixed character count —
# so colour never gets cut off mid-escape-sequence and a later piece never renders past $Width.
function Write-Segments([object[]]$Segments, [int]$Width) {
    $used = 0
    foreach ($segment in $Segments) {
        $remaining = $Width - $used
        if ($remaining -le 0) { break }
        $text = $segment.Text
        if ($text.Length -gt $remaining) {
            $text = $text.Substring(0, [Math]::Max(0, $remaining - 1)) + '…'
            $used = $Width
        } else {
            $used += $text.Length
        }
        $colour = $segment.Colour
        Write-Host $text @colour -NoNewline
    }
    Write-Host ''
}

# The picker packs id/date/prompt-count/folder/title onto one row when they fit; when the title
# would not (the common case for a real conversation summary), it drops to a second row of its
# own instead of being truncated away — the two-row layout used by Write-SessionRow.
function Get-SessionLayout($Session, [int]$Width) {
    $prefixWidth = 6   # "> [x] "
    $meta = '{0}  {1}  {2,3} prompts  ' -f $Session.Id.Substring(0, 8),
                                            $Session.LastSeen.ToString('MM-dd HH:mm'),
                                            $Session.Prompts
    $oneLineWidth = $Width - $prefixWidth
    $combined = if ($Session.Title) { '{0}{1}  — {2}' -f $meta, $Session.Cwd, $Session.Title } else { $meta + $Session.Cwd }
    $twoRow = [bool]$Session.Title -and $combined.Length -gt $oneLineWidth

    return @{ Meta = $meta; Cwd = $Session.Cwd; Title = $Session.Title; TwoRow = $twoRow; RowCount = $(if ($twoRow) { 2 } else { 1 }) }
}

function Write-SessionRow($Session, [bool]$IsCursor, [bool]$IsChosen, [int]$Width) {
    $layout = Get-SessionLayout $Session $Width
    $prefix = '{0} {1} ' -f $(if ($IsCursor) { '>' } else { ' ' }), $(if ($IsChosen) { '[x]' } else { '[ ]' })
    $titleSuffix = if (-not $layout.TwoRow -and $layout.Title) { '  — ' + $layout.Title } else { '' }

    if ($IsCursor -or -not $IsChosen) {
        $uniform = if ($IsCursor) { @{ ForegroundColor = 'Black'; BackgroundColor = 'Gray' } } else { @{ ForegroundColor = 'DarkGray' } }
        Write-Truncated ($prefix + $layout.Meta + $layout.Cwd + $titleSuffix) $Width $uniform
        if ($layout.TwoRow) { Write-Truncated ('      — ' + $layout.Title) $Width $uniform }
        return
    }

    # Chosen and not under the cursor: folder and title each get their own colour so the two
    # things you actually scan for — where it was, what it was about — stand out from the rest.
    $segments = @(
        @{ Text = $prefix + $layout.Meta; Colour = @{} },
        @{ Text = $layout.Cwd; Colour = @{ ForegroundColor = 'DarkCyan' } }
    )
    if ($titleSuffix) { $segments += @{ Text = $titleSuffix; Colour = @{ ForegroundColor = 'DarkYellow' } } }
    Write-Segments $segments $Width

    if ($layout.TwoRow) {
        Write-Segments @(@{ Text = '      — ' + $layout.Title; Colour = @{ ForegroundColor = 'DarkYellow' } }) $Width
    }
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

# Keys pressed while something slow is happening are not commands for the screen that appears
# afterwards. Left in the buffer, an impatient escape typed during a long read would be consumed
# the instant the reader opens, and the next one — the one meant to leave the reader — would
# reach the picker and cancel it.
function Clear-InputBuffer {
    while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) }
}

# Console.ReadKey blocks, so a plain read-key loop only notices a resized window on the next
# keystroke. Polling window size between keystrokes and bailing out (without consuming a key)
# the moment it changes lets the caller redraw immediately — `continue` back to the top of its
# loop recomputes width/height from Get-ConsoleSize and repaints at the new size.
function Read-KeyOrResize {
    $startWidth = [Console]::WindowWidth
    $startHeight = [Console]::WindowHeight
    while (-not [Console]::KeyAvailable) {
        if ([Console]::WindowWidth -ne $startWidth -or [Console]::WindowHeight -ne $startHeight) { return $null }
        Start-Sleep -Milliseconds 100
    }
    return [Console]::ReadKey($true)
}

function Show-Conversation($Session) {
    $width = [Math]::Max(60, (Get-ConsoleSize Width 120) - 1)
    Clear-Host
    Write-Host 'Reading the conversation…' -ForegroundColor DarkGray

    # A transcript this large is worth guarding: one malformed entry must not take the picker
    # down with it, losing a selection the user has been building.
    try {
        $lines = Get-ConversationDisplay (Get-Conversation $Session.Path) $width
    } catch {
        $lines = [System.Collections.Generic.List[object]]::new()
        $lines.Add(@{ Text = "Could not read this transcript: $($_.Exception.Message)"; Colour = @{ ForegroundColor = 'Red' } })
    }

    Clear-InputBuffer
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

        $key = Read-KeyOrResize
        if ($null -eq $key) { continue }
        switch ($key.Key) {
            'UpArrow'   { $offset-- }
            'DownArrow' { $offset++ }
            'PageUp'    { $offset -= $viewport }
            'PageDown'  { $offset += $viewport }
            'Home'      { $offset = 0 }
            'End'       { $offset = $maxOffset }
            'Escape'    { Clear-InputBuffer; return }
            default {
                switch ($key.KeyChar) {
                    'k' { $offset-- }
                    'j' { $offset++ }
                    'q' { Clear-InputBuffer; return }
                    ' ' { $offset += $viewport }
                }
            }
        }
    }
}

# Leaving the picker throws away a selection that took reading to build, so it is worth one key.
function Confirm-Cancel {
    Clear-Host
    Write-Host 'Cancel and open nothing?' -ForegroundColor Yellow
    Write-Host 'y to cancel — any other key goes back to the list' -ForegroundColor DarkGray
    $answer = [Console]::ReadKey($true)
    if ($answer.KeyChar -eq 'y' -or $answer.KeyChar -eq 'Y') {
        Clear-Host
        return $true
    }
    return $false
}

# Arrow keys to move, space to toggle, enter to confirm. Everything starts selected except
# sessions declined in an earlier run, because the common case is still "give me all of it" and
# deselecting two is quicker than selecting twenty — the exception is whatever you already said
# no to. Returns the chosen sessions, or $null when the user backs out.
function Invoke-SessionPicker([object[]]$Sessions, [System.Collections.Generic.HashSet[string]]$DeselectedIds) {
    $chosen = [bool[]]::new($Sessions.Count)
    for ($i = 0; $i -lt $chosen.Count; $i++) { $chosen[$i] = -not $DeselectedIds.Contains($Sessions[$i].Id) }
    $remembered = ($chosen | Where-Object { -not $_ }).Count
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

        # Sessions can now render as one or two rows (title wraps to its own line when it does
        # not fit next to the folder), so "how many sessions are visible" is not a fixed count
        # any more — it depends on how many rows each one actually needs.
        if ($cursor -lt $offset) { $offset = $cursor }
        while ($offset -lt $cursor) {
            $rows = 0
            for ($i = $offset; $i -le $cursor; $i++) { $rows += (Get-SessionLayout $Sessions[$i] $width).RowCount }
            if ($rows -le $viewport) { break }
            $offset++
        }

        Clear-Host
        Write-Host ("Select the sessions to reopen — {0} of {1}" -f ($chosen | Where-Object { $_ }).Count, $Sessions.Count) -ForegroundColor Cyan
        Write-Host '↑↓ move   space toggle   a all/none   v view conversation   enter reopen   esc cancel' -ForegroundColor DarkGray
        if ($remembered -gt 0) {
            Write-Host ("{0} pre-deselected — declined in an earlier run" -f $remembered) -ForegroundColor DarkGray
        }
        Write-Host ''

        $rowsUsed = 0
        $lastShown = $offset - 1
        for ($i = $offset; $i -lt $Sessions.Count; $i++) {
            $rowCount = (Get-SessionLayout $Sessions[$i] $width).RowCount
            if ($rowsUsed + $rowCount -gt $viewport -and $i -gt $offset) { break }
            Write-SessionRow $Sessions[$i] ($i -eq $cursor) $chosen[$i] $width
            $rowsUsed += $rowCount
            $lastShown = $i
        }

        if ($offset -gt 0 -or $lastShown -lt $Sessions.Count - 1) {
            Write-Host ("  … {0}-{1} of {2}" -f ($offset + 1), ($lastShown + 1), $Sessions.Count) -ForegroundColor DarkGray
        }
        Write-Host ''
        Write-SessionSample $Sessions[$cursor] $width $SampleLines '  '

        $key = Read-KeyOrResize
        if ($null -eq $key) { continue }
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
            'Escape'    { if (Confirm-Cancel) { return $null } }
            default {
                switch ($key.KeyChar) {
                    'a' {
                        $turnOn = ($chosen | Where-Object { $_ }).Count -lt $Sessions.Count
                        for ($i = 0; $i -lt $chosen.Count; $i++) { $chosen[$i] = $turnOn }
                    }
                    'k' { if ($cursor -gt 0) { $cursor-- } }
                    'j' { if ($cursor -lt $Sessions.Count - 1) { $cursor++ } }
                    'v' { Show-Conversation $Sessions[$cursor] }
                    'q' { if (Confirm-Cancel) { return $null } }
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

# The picker and the arrangement screen need a keyboard, and a script invoked through a tool call
# has none: its stdin is a pipe. Refusing there would mean the interactive half of this tool is
# unreachable from the very command most people use, so instead it hands itself a real console —
# a terminal tab running the same invocation, which the user then drives.
#
# $Bound is the script's own $PSBoundParameters, handed in on purpose: inside a function that
# automatic variable describes the function's parameters, not the script's, and reading it here
# would silently rebuild the command line without any of the flags the caller actually passed.
function Start-InteractiveConsole($Bound) {
    # Exclude is rebuilt rather than copied: the current session id has to join it, and emitting
    # the parameter twice would be an error rather than a merge.
    $excludeList = @($Exclude)
    if ($env:CLAUDE_CODE_SESSION_ID -and $excludeList -notcontains $env:CLAUDE_CODE_SESSION_ID) {
        $excludeList += $env:CLAUDE_CODE_SESSION_ID
    }

    $quoted = [System.Collections.Generic.List[string]]::new()

    # Always passed by name: a day count given as a bare leading number never reached
    # $PSBoundParameters, and the new console would silently fall back to the default.
    $quoted.Add('-Days')
    $quoted.Add([string]$Days)

    foreach ($name in $Bound.Keys) {
        if ($name -in 'Days', 'Exclude', 'ClaudeArgs') { continue }
        $value = $Bound[$name]
        if ($value -is [switch]) {
            if ($value.IsPresent) { $quoted.Add("-$name") }
            continue
        }
        if ($value -is [array]) {
            $quoted.Add("-$name")
            $quoted.Add((($value | ForEach-Object { Format-ShellArgument $_ }) -join ','))
            continue
        }
        $quoted.Add("-$name")
        $quoted.Add((Format-ShellArgument ([string]$value)))
    }
    if ($excludeList.Count -gt 0) {
        $quoted.Add('-Exclude')
        $quoted.Add((($excludeList | ForEach-Object { Format-ShellArgument $_ }) -join ','))
    }
    foreach ($arg in $ClaudeArgs) { $quoted.Add((Format-ShellArgument $arg)) }

    $shell = Get-TabShell
    $command = "& '{0}' {1}" -f $PSCommandPath, ($quoted -join ' ')
    $savedEnv = Clear-InheritedClaudeEnv
    try {
        if (Get-Command wt.exe -ErrorAction SilentlyContinue) {
            wt.exe -w $WindowName new-tab --title 'recover sessions' -d (Split-Path $PSCommandPath) $shell -NoLogo -NoExit -Command $command
        } else {
            Start-Process $shell -ArgumentList '-NoLogo', '-NoExit', '-Command', $command
        }
    } finally {
        Restore-InheritedClaudeEnv $savedEnv
    }
    Write-Host 'Opened a terminal tab with the session picker — choose there.' -ForegroundColor Cyan
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

$allTranscripts = Get-ChildItem $projectRoot -Recurse -Filter *.jsonl -File |
    Where-Object { $_.Directory.Name -ne 'subagents' }
$candidates = $allTranscripts | Where-Object { $_.LastWriteTime -gt $From }

# Loaded against every transcript on disk, not just $candidates, so a session declined outside
# today's -Days window is not mistaken for one that no longer exists and pruned from memory.
$deselectedPath = Get-DeselectionStorePath
$deselected = Get-DeselectedIds $deselectedPath
$prunedDeselected = Get-PrunedDeselection $deselected @($allTranscripts.BaseName)
if ($prunedDeselected.Count -ne $deselected.Count) { Save-DeselectedIds $deselectedPath $prunedDeselected }
$deselected = $prunedDeselected

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

# Choosing is the default. -All skips the list, and so does naming the sessions with -Include,
# which is already a choice made.
if (-not $All -and -not $DryRun -and $Include.Count -eq 0) {
    if ([Console]::IsInputRedirected) {
        Start-InteractiveConsole $PSBoundParameters
        return
    }
    $shown = $worked
    $picked = Invoke-SessionPicker $worked $deselected
    # $null means cancelled — nothing was decided, so memory is left alone. An empty but non-null
    # result means every session was deliberately unticked, which is still a decision to remember.
    if ($null -ne $picked) {
        Save-DeselectedIds $deselectedPath (Get-UpdatedDeselection $shown $picked $deselected)
    }
    $worked = $picked
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
