# claude-recover-sessions

A PowerShell script that reopens the Claude Code sessions you were actually working on, one
Windows Terminal tab each.

```powershell
.\scripts\Recover-ClaudeSessions.ps1 1
```

```
Select the sessions to reopen — 8 of 8
↑↓ move   space toggle   a all/none   v view conversation   enter reopen   esc cancel

  [x] eb3865e1  08-14 00:54   25 prompts  C:\repos\trace-viewer
> [x] b47087de  08-14 01:23   18 prompts  C:\repos\billing-api  — retry-policy-consolidation
  [ ] fddb0d10  08-14 01:30    6 prompts  C:\repos\billing-api  — Crash reports from scheduled jobs
  [x] b693b3c2  08-14 17:01    1 prompts  C:\repos\billing-api  — Remember connection dialog values
  ...

  > the migration on the staging database has already been applied
```

## Why

09:14, the power goes out. Eight Claude Code sessions were open across five repositories: a
library refactor half applied, a database updater you had been bisecting since midnight, a
release you were about to tag, two you had opened an hour ago and barely started. The screen
comes back empty.

Or nobody cuts the power and Windows Update simply decides, at 03:00, that it has waited long
enough.

The transcripts survive under `~/.claude/projects`. Getting back to work does not. It means
opening a terminal per repository, remembering which ones you were in, running `claude --resume`
in each, and recognising the right conversation in a list of forty by its opening line — eight
times, from memory, before you have done any actual work.

This is one command instead. There is a picker when you want to trim the list, but you never have
to go through the sessions one at a time.

## What makes the selection correct

A session counts as "worked on" when it holds **a message you actually typed** inside the time
window. Not when its file was modified.

The distinction matters more than it sounds. `claude --resume` rewrites a transcript the moment
it loads, so recovering ten sessions stamps all ten with the current time. Filter on modification
time and the next recovery hands you back everything you recovered *last* time, and buries the
handful of sessions you really worked in. Tool results, injected reminders and hook output are
skipped for the same reason: only human turns are evidence.

## Requirements

- Windows, PowerShell 5.1 or 7+
- Claude Code on `PATH`
- [Windows Terminal](https://aka.ms/terminal) — optional; without it, sessions open in separate
  console windows instead of tabs

## Install

There is nothing to install. Clone it and run the script:

```powershell
git clone https://github.com/csm101/claude-recover-sessions
cd claude-recover-sessions
.\scripts\Recover-ClaudeSessions.ps1
```

Called with no arguments it prints its usage — reopening a week of work is not something to do by
accident, so it explains itself rather than guessing how far back you meant.

To reach it from anywhere, add a function to your PowerShell profile (`notepad $PROFILE`):

```powershell
function recover-sessions {
    & 'C:\path\to\claude-recover-sessions\scripts\Recover-ClaudeSessions.ps1' @args
}
```

Then `recover-sessions 2` from any directory. `@args` matters: it forwards everything,
including the bare day count and the flags meant for `claude`.

## Use

```powershell
.\scripts\Recover-ClaudeSessions.ps1            # usage and examples, opens nothing
.\scripts\Recover-ClaudeSessions.ps1 1          # choose from what you worked on since yesterday
.\scripts\Recover-ClaudeSessions.ps1 3          # go back three days
.\scripts\Recover-ClaudeSessions.ps1 0          # today only
.\scripts\Recover-ClaudeSessions.ps1 3 -All     # reopen all of it, no list
.\scripts\Recover-ClaudeSessions.ps1 3 -DryRun  # list it, open nothing
```

### Picking

Choosing is what happens by default, from the list shown above. Everything starts ticked,
because the usual answer is still "all of it" and unticking two beats ticking twenty — but a
recovery reopens somebody's whole afternoon, and that is worth a look before it happens.

`-All` skips the list. So does `-Include`, which is a choice already made.

Two things do the identifying. The name after the dash is the title Claude Code gave the
conversation — sessions started before that feature simply have none. Under the list is the
session's opening prompt, wrapped over up to ten lines rather than cut at the first: the first
line of a prompt is usually a preamble, and what tells you which session this is tends to come
after it. `-SampleLines` changes the limit.

If you would rather not be asked at all, list first and reopen a subset by id:

```powershell
.\scripts\Recover-ClaudeSessions.ps1 3 -DryRun
.\scripts\Recover-ClaudeSessions.ps1 3 -Include b47087de,eb3865e1
```

Separate ids with commas, not spaces: a space-separated second id is taken for a forwarded
`claude` argument instead.

### Reading a conversation before deciding

A title and an opening prompt do not always settle it. Press `v` on a highlighted session and
the conversation opens in a scrollable view — what you said, what Claude answered, in order,
with tool calls and their output left out. `esc` returns to the list with your selection intact.

Leaving the picker itself asks for confirmation, and keys pressed while a large transcript is
loading are discarded rather than queued: an impatient escape typed during the wait would
otherwise be spent the moment the reader opens, and the next one would land on the picker and
cancel it.

### Windows and order

Before anything opens, a screen asks how the tabs should be arranged:

```
About to reopen 8 session(s) in 3 window(s).

  g   grouping   one window per working directory
  o   order      oldest prompt first — the most recent ends up active

  enter reopen   esc cancel
```

`g` cycles the grouping — everything in one window, one window per working directory (so
conversations about the same repository stay together), or one window per session. `o` flips the
order within each window. The window count updates as you cycle, which is usually what decides
it.

Both are also parameters, and passing `-NoPrompt` skips the screen:

```powershell
.\scripts\Recover-ClaudeSessions.ps1 3 -Grouping workdir -Order newest -NoPrompt
```

### Forwarding arguments

Anything after the day count is passed straight through to each recovered session:

```powershell
.\scripts\Recover-ClaudeSessions.ps1 3 --dangerously-skip-permissions
.\scripts\Recover-ClaudeSessions.ps1 1 --model opus
```

A useful one is `/remote-control`, which pairs a session with the Claude mobile app. Recovering
over a remote desktop, it means every session you bring back stays reachable after you disconnect:

```powershell
.\scripts\Recover-ClaudeSessions.ps1 2 /remote-control
```

An argument beginning with `/` is executed by the resumed session as a command rather than read
as text, so nothing else is needed. Note the asymmetry: this is for recovering *onto* a machine
you are about to leave. Starting a recovery *from* the phone is a different matter — the picker
is a console UI on a desktop you are not sitting at, so pass `-All` or `-Include` there.

| Parameter       | Default |   |
|-----------------|---------|---|
| `-Days`         | `1`     | Calendar days back, also accepted as a bare leading number. `1` covers yesterday *and* today — the shape of an overnight crash. |
| `-All`          | off     | Reopen everything, skipping the list. `-Include` implies it. |
| `-DryRun`       | off     | List what would reopen, open nothing. |
| `-Include`      | —       | Reopen only these session ids, full or partial, comma-separated. |
| `-Exclude`      | —       | Session ids, full or partial, to leave alone. |
| `-SampleLines`  | `10`    | How many lines of each opening prompt to show. |
| `-Grouping`     | `single`| `single`, `workdir` or `session` — how tabs are spread over windows. |
| `-Order`        | `oldest`| `oldest` or `newest` — launch order within a window. |
| `-NoPrompt`     | off     | Skip the grouping/order screen. |
| `-WindowName`   | `0`     | Target window. `0` reuses the current one; any other string groups the tabs in a window of its own. |
| *anything else* | —       | Forwarded verbatim to every `claude` invocation. |

Running it twice is safe: sessions already live in another tab are recognised and skipped.

## About `--dangerously-skip-permissions`

Nothing is added to the `claude` command line unless you put it there, and that includes
`--dangerously-skip-permissions`. Forwarding it is reasonable when you are resuming your own work
and about to supervise it. Be aware of what it means at this scale: eight sessions coming back at
once, each free to run commands and edit files before you have looked at any of them.

## How it works

1. Read the transcripts under `~/.claude/projects` (or `$CLAUDE_CONFIG_DIR`), skipping
   `subagents/`. Lines are streamed and pre-filtered before parsing — transcripts get large.
2. Keep sessions with at least one human message in the window.
3. Resolve each session's working directory. `claude --resume <id>` resolves the id relative to
   the current directory, and a session continued elsewhere records more than one cwd, so the
   right one is the cwd whose encoded form matches the project directory holding the transcript.
4. Drop sessions already open, the session the script was launched from, and any whose working
   directory is gone.
5. Open the rest oldest-first, so the most recent lands as the active tab.

### Running it from inside Claude Code

Nothing stops you asking Claude to run this script, and two things then need handling.

Its process environment carries `NO_COLOR=1` plus `CLAUDECODE` and `CLAUDE_CODE_*`, and `wt.exe`
passes its own environment to the tabs it spawns. Without a cleanup every recovered session
starts with its UI colours stripped and believes it is nested inside another instance. The script
clears those variables around the launch and puts them back afterwards. The restore is not
politeness: `CLAUDE_CODE_SESSION_ID` is how the script recognises the session it is running in,
and stripping it for good would leave a long-lived shell offering to reopen that very session on
the next run.

The picker also needs a keyboard, and a script run by another program has none — its stdin is a
pipe. Rather than refuse, it opens a terminal tab and puts the list there, carrying the arguments
it was given and excluding the session it was launched from. Pass `-All` or `-Include` if you
want a tool-driven run to reopen without asking.

## Not Windows?

The selection logic is portable; only the last step isn't. A macOS or Linux port needs
`Open-Session` to talk to iTerm2, tmux or your terminal of choice. PRs welcome.

## Prior art

Two tools restore a whole working set after a crash, and both need to have been running
**before** it: they replay a terminal layout they recorded in advance.

- [Quil](https://quil.cc/blog/resume-claude-code-session-after-reboot/) — a terminal multiplexer
  that snapshots your workspace continuously and reruns `claude --resume` for every pane it had.
  Linux and macOS.
- [claude-sessions (daksh-gargas)](https://dev.to/daksh-gargas/snapshot-your-terminal-state-restore-it-after-a-crash-claude-code-sessions-included-32pj) —
  a launchd daemon snapshotting iTerm every five minutes. macOS.

This script works the other way round: retroactively, from the transcripts alone. Nothing has to
have been installed or running when the machine went down, which is the situation you are usually
in the first time you need it.

The rest are interactive browsers for finding *one* conversation:

- [greeun/claude-sessions](https://github.com/greeun/claude-sessions) — TUI picker with full-text search, which this script does not have
- [davidpp/claude-session-browser](https://github.com/davidpp/claude-session-browser) — TUI, copies the resume command to your clipboard
- [nikbq/claude-resume](https://github.com/nikbq/claude-resume) — browse history in the browser
- [d-kimuson/claude-code-viewer](https://github.com/d-kimuson/claude-code-viewer) — web client for session logs

## License

MIT
