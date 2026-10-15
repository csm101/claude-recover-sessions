---
description: Mark this session as concluded, so Recover-ClaudeSessions does not offer to reopen it
disable-model-invocation: true
---
The user has run /done: they consider this conversation concluded. Recover-ClaudeSessions.ps1
reads that from the transcript and, after a crash or a reboot, lists this session unticked and
marked "closed" instead of reopening it. Typing a new prompt here later makes it recoverable again.

Reply with one short line confirming that the session is closed, in the language the user has
been writing in. Do not call any tools, do not summarise the conversation, do not suggest next steps.
