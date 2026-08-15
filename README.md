# claude-recover-sessions

Reopen every Claude Code session you were actually working on, one Windows Terminal tab each.

```
/recover-sessions
```

```
Sessions worked on since 2026-08-14 00:00: 8
Already open, left alone: 9960f284
  eb3865e1  08-14 00:54   25 prompts  C:\repos\trace-viewer
            > I don't follow when this analysis is supposed to run: does it run live inside the
              debugger, or are you talking about some external tool that pre-analyses the
              binaries and generates the whitelist?
  b47087de  08-14 01:23   18 prompts  C:\repos\billing-api  — retry-policy-consolidation
            > the migration on the staging database has already been applied
  b693b3c2  08-14 17:01    1 prompts  C:\repos\billing-api  — Remember connection dialog values
            > silly request: I'd like the dialog that asks for the host and the account code to
              remember what I entered last time, instead of making me type it on every connection
  ...
Opening 8 tabs in a single window (-w 0)...
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

The existing session tools are interactive browsers: they help you find *one* conversation. This
one answers a different question — *give me back everything I had open* — and answers it in a
single command. There is a picker when you want to trim the list, but you never have to go
through one session at a time.

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
- [Windows Terminal](https://aka.ms/terminal) — optional; without it, sessions open in separate
  console windows instead of tabs
- Claude Code on `PATH`

## Install

As a plugin, so updates come with it:

```
/plugin marketplace add csm101/claude-recover-sessions
/plugin install claude-recover-sessions@csm101-plugins
```

Then `/reload-plugins` if the install summary asks for it. Later, `/plugin marketplace update
csm101-plugins` picks up new versions.

To install from a clone instead of from GitHub, point the first command at the directory:
`/plugin marketplace add ./claude-recover-sessions`.

Or by copying the files in, if you would rather not add a marketplace:

```powershell
git clone https://github.com/csm101/claude-recover-sessions
cd claude-recover-sessions
./install.ps1          # -Scope Project to install into the current repo only
```

`./uninstall.ps1` reverses the manual install.

## Use

```
/recover-sessions          print usage and examples, open nothing
/recover-sessions 1        pick from what you worked on since yesterday midnight
/recover-sessions 3        go back three days
/recover-sessions 0        today only
```

The slash command opens the picker in a terminal tab and leaves the choosing to you. A tool call
has no keyboard attached, so rather than deciding on your behalf the script hands the list a real
console — the same one you get running it yourself.

Reopening a week of work is not something to do by accident, so the bare command explains itself
instead of guessing how far back you meant.

### Picking

Everything is reopened by default. To choose, add `-Pick`:

```
/recover-sessions 3 -Pick
```

```
Select the sessions to reopen — 5 of 8
↑↓ move   space toggle   a all/none   v view conversation   enter reopen   esc cancel

  [x] b47087de  08-14 01:23   18 prompts  C:\repos\billing-api  — retry-policy-consolidation
> [x] eb3865e1  08-14 00:54   25 prompts  C:\repos\trace-viewer
  [ ] fddb0d10  08-14 01:30    6 prompts  C:\repos\billing-api  — Crash reports arriving from scheduled jobs
  [x] 73594b59  08-14 13:03   16 prompts  C:\repos\billing-api  — Silent rebuild call on startup
  ...

  > I don't follow when this analysis is supposed to run: does it run live inside the
    debugger, or are you talking about some external tool that pre-analyses the
    binaries and generates the whitelist?
```

Everything starts ticked, because the usual answer is still "all of it" and unticking two beats
ticking twenty.

Two things do the identifying. The name after the dash is the title Claude Code gave the
conversation — sessions started before that feature simply have none. Under the list is the
session's opening prompt, wrapped over up to ten lines rather than cut at the first: the first
line of a prompt is usually a preamble, and what tells you which session this is tends to come
after it. `-SampleLines` changes the limit.

When Claude runs the command for you the picker still appears — in a terminal tab it opens for
the purpose, carrying the arguments you gave and excluding the session you asked from, so it
cannot offer to reopen a copy of the conversation you are in.

If you would rather not be asked at all, list first and reopen a subset by id:

```powershell
./scripts/Recover-ClaudeSessions.ps1 3 -DryRun
./scripts/Recover-ClaudeSessions.ps1 3 -Include b47087de,eb3865e1
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
./scripts/Recover-ClaudeSessions.ps1 3 -Grouping workdir -Order newest -NoPrompt
```

The screen is skipped automatically when the script has no console to ask on, so a tool-driven
run uses whatever the parameters say.

### Forwarding arguments

Anything after the day count is passed straight through to each recovered session:

```
/recover-sessions 3 --dangerously-skip-permissions
/recover-sessions 1 --model opus
```

The script underneath takes the same shape:

```powershell
./scripts/Recover-ClaudeSessions.ps1 -Days 2 -DryRun
./scripts/Recover-ClaudeSessions.ps1 3 --dangerously-skip-permissions
```

| Parameter       | Default |   |
|-----------------|---------|---|
| `-Days`         | `1`     | Calendar days back, also accepted as a bare leading number. `1` covers yesterday *and* today — the shape of an overnight crash. |
| `-Pick`         | off     | Choose from an interactive list instead of reopening everything. Needs a real console. |
| `-DryRun`       | off     | List what would reopen, open nothing. |
| `-Include`      | —       | Reopen only these session ids, full or partial, comma-separated. |
| `-SampleLines`  | `10`    | How many lines of each opening prompt to show. |
| `-Grouping`     | `single`| `single`, `workdir` or `session` — how tabs are spread over windows. |
| `-Order`        | `oldest`| `oldest` or `newest` — launch order within a window. |
| `-NoPrompt`     | off     | Skip the grouping/order screen. |
| `-Exclude`      | —       | Session ids, full or partial, to leave alone. |
| `-WindowName`   | `0`     | Target window. `0` reuses the current one; any other string groups the tabs in a window of its own. |
| *anything else* | —       | Forwarded verbatim to every `claude` invocation. |

Running it twice is safe: sessions already live in another tab are recognised and skipped, and
the session invoking the command excludes itself.

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
4. Drop sessions already open, the current session, and any whose working directory is gone.
5. Open the rest oldest-first, so the most recent lands as the active tab.

### The environment trap

If the command runs from inside Claude Code, its process environment carries `NO_COLOR=1` plus
`CLAUDECODE` and `CLAUDE_CODE_*`. `wt.exe` passes its own environment to the tabs it spawns, so
without a cleanup every recovered session starts with its UI colours stripped and believes it is
nested inside another instance.

The script therefore clears those variables around the launch, and puts them back afterwards.
The restore is not politeness: `CLAUDE_CODE_SESSION_ID` is how the script recognises the session
it is running in, and stripping it for good would leave a long-lived shell offering to reopen
that very session on the next run.

## Not Windows?

The selection logic is portable; only the last step isn't. A macOS or Linux port needs
`Open-Session` to talk to iTerm2, tmux or your terminal of choice. PRs welcome.

## Prior art

Worth knowing about, all interactive and one session at a time:

- [greeun/claude-sessions](https://github.com/greeun/claude-sessions) — TUI picker with full-text search
- [davidpp/claude-session-browser](https://github.com/davidpp/claude-session-browser) — TUI, copies the resume command to your clipboard
- [nikbq/claude-resume](https://github.com/nikbq/claude-resume) — browse history in the browser
- [d-kimuson/claude-code-viewer](https://github.com/d-kimuson/claude-code-viewer) — web client for session logs

## License

MIT
