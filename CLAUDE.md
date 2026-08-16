# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single PowerShell script (`scripts/Recover-ClaudeSessions.ps1`) that reopens Claude Code
sessions after a crash/reboot, one Windows Terminal tab each. No build system, no package
manager, no test suite — the entire project is that one file plus README.md and CHANGELOG.md.

## Running / trying it out

```powershell
.\scripts\Recover-ClaudeSessions.ps1            # usage only, opens nothing
.\scripts\Recover-ClaudeSessions.ps1 3 -DryRun   # exercise the selection logic without side effects
```

There's no automated test suite. Verify changes with `-DryRun` (safe, no windows opened) or by
actually reopening real sessions from `~/.claude/projects`. Check syntax with:

```powershell
[System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw .\scripts\Recover-ClaudeSessions.ps1), [ref]$null)
```

## Architecture

Everything lives in one file, in pipeline order:

1. **Selection** (`Get-WorkedSession`, `Test-HumanPrompt`, `Test-UserAuthored`) — streams each
   `*.jsonl` transcript under `~/.claude/projects` (or `$CLAUDE_CONFIG_DIR`) line-by-line,
   pre-filtering with a regex (`"type":"user"`) before handing candidate lines to `ConvertFrom-Json`,
   because transcripts get large. A session only counts as "worked on" if it has a human-authored
   message (not a tool result, hook output, or injected reminder) inside the `-Days` window —
   this is deliberately **not** based on file mtime, since `claude --resume` rewrites the
   transcript just by loading it, which would make every prior recovery look freshly worked.

2. **Cwd resolution** (`Resolve-SessionCwd`, `ConvertTo-ProjectDirName`) — a session can carry
   more than one recorded cwd if it was continued from a different directory. The one that
   matters is whichever encodes (lossily, colons/slashes/dots to dashes) to the project directory
   name actually holding the transcript file, since that's what `claude --resume <id>` needs to
   find it.

3. **Dedup / filtering** — drops sessions already open in another tab (matched by scanning
   `Win32_Process` command lines for GUIDs, `Get-AlreadyOpenSessionId`), the currently-running
   session (`$env:CLAUDE_CODE_SESSION_ID`), and sessions whose working directory no longer exists.

4. **Picking** (`Invoke-SessionPicker`, `Show-Conversation`) — an interactive console UI
   (arrow keys, space, `v` to read the full conversation, `a` to toggle all) is the default
   unless `-All`, `-DryRun`, or `-Include` is given. Runs only when stdin is a real console;
   if invoked with redirected/piped stdin (e.g. launched as a tool call from inside Claude Code
   itself), it instead spawns a new terminal tab via `Start-InteractiveConsole` and hands the
   picker a real keyboard there. Sessions unticked and confirmed (Enter, not `esc`) are recorded
   in `recover-sessions-deselected.json` next to the transcripts (`Get-DeselectedIds` /
   `Save-DeselectedIds` / `Get-UpdatedDeselection` / `Get-PrunedDeselection`), so the same session
   starts unticked next time instead of being asked about again. Every one of those functions
   returns its `HashSet[string]` as `, $x` — an empty `HashSet` is still `IEnumerable`, and a bare
   `return` unrolls it into the pipeline, which collapses zero elements into `$null` instead of an
   empty set. This bites silently: the failure only shows up later, as `.Add()`/`.Contains()` on
   what turns out to be `$null`. The codebase already has this idiom (`Get-Conversation`'s
   `return , $messages`) — follow it for any function returning a collection here.

5. **Arrangement** (`Invoke-OptionsPrompt`, `Sort-ForLaunch`, `Get-TargetWindow`) — asks how to
   group tabs across windows (`single`/`workdir`/`session`) and launch order
   (`oldest`/`newest`), unless `-NoPrompt`.

6. **Launch** (`Open-Session`) — shells out to `wt.exe new-tab` per session (falling back to
   `Start-Process` per window if Windows Terminal isn't installed), running
   `claude --resume <id>` plus any forwarded `-ClaudeArgs`.

### Two environment-handling subtleties worth knowing before touching this code

- **`Clear-InheritedClaudeEnv` / `Restore-InheritedClaudeEnv`**: when this script itself runs
  inside Claude Code, its process env carries `NO_COLOR=1` and `CLAUDECODE`/`CLAUDE_CODE_*`,
  which `wt.exe` would otherwise pass on to every reopened tab (stripping their UI colors and
  making them think they're nested). These are cleared around the launch calls and always
  restored afterward — restoring matters because `CLAUDE_CODE_SESSION_ID` is how a *subsequent*
  run of this same script recognizes and excludes itself.

- **`Format-ShellArgument`**: every forwarded argument gets re-quoted because it will be parsed
  a second time, either by `pwsh -Command <string>` (tab launch) or by the interactive-console
  relaunch path. Don't pass raw strings into a `wt.exe`/`Start-Process` command string without it.

### Argument parsing quirks

`[CmdletBinding(PositionalBinding = $false)]` is intentional — it keeps a forwarded `claude` flag
from being misbound to `-Days`. Unbound leading tokens land in `$ClaudeArgs`; the script then
manually peels off a leading bare integer as the day count (see the block right after
`Show-Usage`). Keep this ordering in mind when adding new named parameters — anything not
explicitly declared falls straight through to `claude` on the command line.
