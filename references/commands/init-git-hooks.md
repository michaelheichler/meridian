1. Run `git rev-parse --git-dir`. If the directory is not a git repository, display "○ Git hooks skipped (not a git repository)" and skip.
2. Run `bash "{plugin-root}/scripts/install-hooks.sh"` and choose the display text from its output.
   - If the output contains "Installed", display `✓ Git hooks installed (pre-push)`.
   - If the output contains "already installed", display `✓ Git hooks (already installed)`.
   - If the output contains "Updated" or "Upgraded", display `✓ Git hooks updated (pre-push)`.
