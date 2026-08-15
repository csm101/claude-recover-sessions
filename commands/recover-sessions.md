---
name: recover-sessions
description: Reopen the Claude Code sessions you were working on before a crash, one Windows Terminal tab each
argument-hint: "[days] [claude flags...] — e.g. 3 --dangerously-skip-permissions"
allowed-tools: PowerShell, Bash
---

The user lost their Claude Code sessions to a crash, a power cut or a reboot, and wants them back.

Arguments given: `$ARGUMENTS`

If they are empty, run the script with no arguments too: it prints its usage, and relaying that
is the whole answer. Do not pick a day count on the user's behalf.

Otherwise a leading number is how many days back to look, and everything else is forwarded
verbatim to each recovered session's `claude` invocation — that is how the user asks for
`--dangerously-skip-permissions`, `--model opus` and the like. Pass those through as typed; do
not second-guess them.

Resolve the bundled script and run it. `CLAUDE_PLUGIN_ROOT` is set when this command comes from
the plugin; the fallback path is where `install.ps1` puts the script for a manual install:

```powershell
$script = if ($env:CLAUDE_PLUGIN_ROOT) {
    Join-Path $env:CLAUDE_PLUGIN_ROOT 'scripts/Recover-ClaudeSessions.ps1'
} else {
    Join-Path $HOME '.claude/claude-recover-sessions/Recover-ClaudeSessions.ps1'
}
& $script <days> -Pick <forwarded flags>
```

**Pass `-Pick`.** It is what puts the user in charge: the script opens a terminal tab with the
session list, where they choose what comes back and how the tabs are arranged. Your job ends at
reporting that the tab is open — do not make those choices for them.

Drop `-Pick` only when the user has said they want everything reopened without being asked.

The script's own parameters are `-Days`, `-Pick`, `-DryRun`, `-Include`, `-Exclude`, `-Grouping`,
`-Order`, `-SampleLines`, `-NoPrompt` and `-WindowName`; anything else on the line goes to
`claude`. Add `-DryRun` yourself if the user wants to see the list before anything opens.

If the user says how they want the windows arranged — one per project, everything together, most
recent first — pass `-Grouping single|workdir|session` and `-Order oldest|newest`. The screen
that would otherwise ask is skipped automatically when the script has no console, so what you
pass is what happens.

The script handles the rest: it keeps only sessions holding a real human message in the period,
resolves each session's working directory, leaves already-open sessions and the current one
alone, cleans the inherited environment, and hands the picker a real console because a tool call
has no keyboard attached.

What to report depends on which way it went.

With `-Pick`, the script prints how many sessions it found and then opens the tab. Say that the
picker is waiting in a terminal tab and how many sessions are in it. Nothing has been reopened
yet, so do not describe the outcome — the user has not chosen.

With `-DryRun`, or when the user asked for everything, report what the script listed: short id,
time of last activity, prompt count, working directory, title, and each session's opening prompt
as a reminder of what it was about. List separately anything skipped because it was already
open, and say plainly if nothing matched.

`-Include <id>,<id>` reopens a specific subset without any interaction — comma-separated, since
space-separated ids would be taken for forwarded `claude` arguments.
