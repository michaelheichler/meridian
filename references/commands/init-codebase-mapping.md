For Step 2c, adapt codebase mapping to the project.

- If BROWNFIELD=false, skip mapping and display `○ Greenfield: skipping codebase mapping`.
- If SOURCE_FILE_COUNT < 200, read `{plugin-root}/commands/map.md` and follow it inline.
- If SOURCE_FILE_COUNT >= 200, run mapping inline and display `◆ Codebase mapping started ({SOURCE_FILE_COUNT} files)`.

Never run mapping in the background.
Complete mapping before Step 3.
