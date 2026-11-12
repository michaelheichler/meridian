- If the file exists, preserve all user-authored content verbatim. Never overwrite the file or assume that its first heading and core-value lines belong to MERIDIAN.
- Refresh only the exact canonical sections that MERIDIAN already emitted, `## Active Context`, `## MERIDIAN Rules`, and `## Plugin Isolation`.
- If the file has no Code Intelligence heading or guidance anywhere, add `## Code Intelligence`.

After refreshing existing sections, display `✓ CLAUDE.md (MERIDIAN sections refreshed in place)`.
