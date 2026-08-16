# Changelog

## Unreleased

- The picker remembers what you untick. Confirming a selection with sessions left unticked
  records them in `recover-sessions-deselected.json` (next to the transcripts), and any of them
  reappearing in a later run starts unticked again instead of asking a second time. Ticking one
  back on forgets it. Cancelling with `esc` does not count as a decision. Entries for sessions
  whose transcript no longer exists are pruned automatically on read.
- The picker and the conversation reader now redraw on their own when the terminal window is
  resized, instead of waiting for the next keystroke.
- The picker's session list colours the working directory and the title differently, and drops
  the title to its own row when it does not fit next to the folder instead of truncating it away.

## 3.0.0

- Choosing is now the default: running the script shows the session list instead of reopening
  everything. A recovery brings back a whole afternoon of work, which is worth a look first.
- `-All` reopens without the list, taking over what the absence of `-Pick` used to mean.
  `-Include` implies it — naming the sessions is already a choice.
- `-Pick` is still accepted and does nothing. It is declared rather than dropped so that typing
  it out of habit does not sweep it into the forwarded arguments and hand it to `claude`.

## 2.0.0

- Dropped the Claude Code plugin: the `.claude-plugin` manifests, the `/recover-sessions` slash
  command and the installers are gone, and the project is the PowerShell script alone.

  The command added nothing. All it could do was launch the same script in a terminal tab, which
  you can do yourself — and in the situation this exists for, the machine has just rebooted and
  Claude Code is not running either. A profile function does the job better, and the README shows
  one.

  The script still knows it may be started from inside Claude Code and still handles that: the
  inherited environment, the self-exclusion, and handing the picker a real console.

## 1.1.0

- `/recover-sessions` now shows the picker instead of deciding for you. A tool call has no
  keyboard, and the command used to work around that by skipping the interactive half entirely —
  so the slash command, the way most people run this, silently reopened whatever it judged best.
  `-Pick` under a redirected stdin now opens a terminal tab and puts the list there, carrying the
  original arguments and excluding the session it was launched from.

## 1.0.0

First release.

- `/recover-sessions [days]` reopens the Claude Code sessions worked on in the last N days, one
  Windows Terminal tab each.
- Sessions are selected by human message timestamps rather than file modification time, so a
  previous recovery does not pollute the next one.
- Per-session working directory resolved from the transcript, matching how `claude --resume`
  looks an id up.
- Already-open sessions and the invoking session are skipped, making repeat runs safe.
- Inherited `NO_COLOR` / `CLAUDECODE` / `CLAUDE_CODE_*` cleared before spawning tabs, so
  recovered sessions keep their UI colours and do not think they are nested.
- Falls back to separate console windows when Windows Terminal is absent.
- Called with no arguments, prints usage and examples instead of guessing how far back to go.
- Before opening anything, an interactive screen asks how to arrange the tabs: `-Grouping`
  spreads them over one window, one per working directory, or one per session, and `-Order`
  sets the launch order within a window. Both are parameters too; `-NoPrompt` skips the screen,
  as does having no console to ask on.
- `v` in the picker opens the highlighted conversation in a scrollable reader — messages only,
  no tool calls — so a session can be identified before deciding to reopen it. Keystrokes made
  while a transcript loads are discarded, leaving the picker requires confirmation, and an
  unreadable transcript reports itself instead of taking the picker down.
- Listings show the session's Claude Code title next to its working directory, and its opening
  prompt wrapped over up to ten lines (`-SampleLines`) instead of cut at the first.
- `-Pick` opens an interactive list — arrows, space to toggle, enter to reopen — for choosing a
  subset. `-Include` does the same non-interactively, for when the script is driven by a tool
  rather than typed at a prompt.
- Unrecognised arguments are forwarded verbatim to every `claude` invocation, so
  `/recover-sessions 3 --dangerously-skip-permissions` or `--model opus` work as typed. Nothing
  is added to the command line on your behalf.
