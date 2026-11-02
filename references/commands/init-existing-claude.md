- If the file exists, preserve all user-authored content verbatim. Never overwrite the file or assume that its first heading and core-value lines belong to LBWC.
- Refresh only the exact canonical sections that LBWC already emitted, `## Active Context`, `## LBWC Rules`, and `## Plugin Isolation`.
- If the file has no Code Intelligence heading or guidance anywhere, add `## Code Intelligence`.

After refreshing existing sections, display `✓ CLAUDE.md (LBWC sections refreshed in place)`.
