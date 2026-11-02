For Step 3b, if `.lbwc-planning/codebase/STACK.md` exists, read it.
Merge additional stack components into detected_stack[].

For Step 3b2, if `.lbwc-planning/codebase/PATTERNS.md` exists, detect conventions.

- Read PATTERNS.md, ARCHITECTURE.md, STACK.md, CONCERNS.md.
- Extract conventions per `{plugin-root}/commands/teach.md` (Step R2).
- Write `.lbwc-planning/conventions.json` and display `✓ {count} conventions auto-detected from codebase`.

If this is greenfield, write `{"conventions": []}` and display `○ Conventions: none yet (add with /lbwc:teach)`.
