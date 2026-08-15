# Changelog

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
  no tool calls — so a session can be identified before deciding to reopen it.
- Listings show the session's Claude Code title next to its working directory, and its opening
  prompt wrapped over up to ten lines (`-SampleLines`) instead of cut at the first.
- `-Pick` opens an interactive list — arrows, space to toggle, enter to reopen — for choosing a
  subset. `-Include` does the same non-interactively, for when the script is driven by a tool
  rather than typed at a prompt.
- Unrecognised arguments are forwarded verbatim to every `claude` invocation, so
  `/recover-sessions 3 --dangerously-skip-permissions` or `--model opus` work as typed. Nothing
  is added to the command line on your behalf.
