For Step 3b, if `.meridian/codebase/STACK.md` exists, read it.
Merge additional stack components into detected_stack[].

For Step 3b2, if `.meridian/codebase/PATTERNS.md` exists, detect conventions.

- Read PATTERNS.md, ARCHITECTURE.md, STACK.md, CONCERNS.md.
- Extract conventions per `{plugin-root}/commands/teach.md` (Step R2).
- Write `.meridian/conventions.json` and display `✓ {count} conventions auto-detected from codebase`.
