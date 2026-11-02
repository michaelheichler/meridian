Otherwise, display the detected languages and recommended LSP plugins, then follow these substeps.

For Step 2.5a, if `env_needed=true`, ask about the environment flag.

- Use AskUserQuestion with "○ LSP Tools\n\nEnable LSP tools for Claude Code? This adds ENABLE_LSP_TOOL=1 to settings.json,\ngiving Claude access to goToDefinition, findReferences, and other code navigation tools."
  - If the user approves, set `env.ENABLE_LSP_TOOL` to `"1"` in `CLAUDE_DIR/settings.json`. Use the write pattern from Step 0c.
  - If the user declines, display "○ LSP env flag skipped".

For Step 2.5b, check each plugin where `binary_installed=false`.

- If `install_cmd` is not null, use AskUserQuestion with "Install {description} language server?\nCommand: `{install_cmd}`".
  - If the user approves, run the command via Bash.
  - If the user declines, display "○ {description}: skipped".
- If `install_cmd` is null and only install_url exists, display "○ {description}: manual install: {install_url}".

For Step 2.5c, if any plugins have `plugin_enabled=false`, inspect the marketplace catalog.

- Check the catalog with `unset CLAUDECODE && claude plugin marketplace list 2>&1 | grep -q "{org}"`. Use `org` from the first pending plugin.
- If the catalog is missing, use AskUserQuestion with "LSP plugins are published on the `{org}` marketplace catalog. Add it?"
  - If the user approves, run `unset CLAUDECODE && claude plugin marketplace add {org} 2>&1`.
  - If the user declines or the command fails, display "○ Marketplace catalog not available: skipping plugin installs" and skip 2.5d.

For Step 2.5d, ask about each plugin where `plugin_enabled=false`.

- Use AskUserQuestion with "Install Claude LSP plugins for: {comma-separated descriptions}?"
  - If the user approves, run `unset CLAUDECODE && claude plugin marketplace update {org} 2>&1` once.
  - Then, for each approved plugin, run `unset CLAUDECODE && claude plugin install {plugin} 2>&1`.
  - If the user declines, display "○ LSP plugins: skipped".

Display `✓ LSP: {N} language server(s) configured` or `○ LSP: skipped`.
If settings.json changes or plugin installation occurred, display `(restart Claude Code to activate LSP)`.
