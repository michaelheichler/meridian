---
category: supporting
model: sonnet
disable-model-invocation: true
description: Save session notes for next time (state auto-persists).
argument-hint: "[notes]"
allowed-tools: Read, Write, Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/explorer-journal.sh *)
---

# MERIDIAN Pause: $ARGUMENTS

## Context

Working directory:
```
!`pwd`
```

## Guard

1. **Not initialized** (no .meridian/ dir): STOP "Run /meridian:init first."

## Steps

1. **Write notes:** If $ARGUMENTS has notes, write `.meridian/RESUME.md` with timestamp + notes + resume hint. If no notes, skip write.
2. **Append journal.** With or without notes, run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/explorer-journal.sh" append --trigger pause --command /meridian:pause --request "$ARGUMENTS" --next /meridian:resume` exactly once. Pass notes as one quoted argument without evaluating their contents. If the helper fails, show at most one warning and continue to the presentation.
3. **Present:** Phase Banner "Session Paused". Show notes path if saved. "State is always saved in .meridian/. Nothing to lose, nothing to remember." Next Up: /meridian:resume.

## Output Format

Follow @${CLAUDE_PLUGIN_ROOT}/references/meridian-brand-essentials.md , double-line box, ➜ Next Up, no ANSI.

## Next Up

After the pause artifact validates, show `/meridian:resume` and stop.
