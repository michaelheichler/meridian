---
category: advanced
disable-model-invocation: true
description: Update Meridian to the latest version with automatic cache refresh.
argument-hint: "[--check]"
allowed-tools: Read, Bash, Glob
---

# Meridian Update $ARGUMENTS

## Context

Plugin root:
```
!`SESSION_KEY="${CLAUDE_SESSION_ID:-root-$(printf "%s\n%s\n" "${CLAUDE_PLUGIN_ROOT:-}" "$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)" | shasum -a 256 | cut -c1-64)}"; [ "$SESSION_KEY" != root- ] || { echo "MERIDIAN: plugin root hash unavailable" >&2; exit 1; }; L="/tmp/.meridian-plugin-root-link-${SESSION_KEY}"; R="$L/scripts/resolve-plugin-root.sh"; [ -f "$R" ] || R="${CLAUDE_PLUGIN_ROOT:-}/scripts/resolve-plugin-root.sh"; [ -f "$R" ] || { echo "MERIDIAN: plugin root unavailable. Restart this session to recreate $L." >&2; exit 1; }; bash "$R" >/dev/null || exit 1; echo "$L"`
```

Store the plugin root output as `{plugin-root}` and substitute that literal path in script and file lookups below.

**Resolve config directory.** Try `CLAUDE_CONFIG_DIR` first if it names an existing directory, then `~/.config/claude-code` if it exists, and otherwise `~/.claude`. Store the result as `CLAUDE_DIR` for all config paths below.

## Steps

### Step 1. Read the installed version

Read the cached version, which identifies the installed plugin.
```bash
for _d in "${CLAUDE_CONFIG_DIR:-}" "$HOME/.config/claude-code" "$HOME/.claude"
do
  [ -z "$_d" ] && continue
  v=$(cat "$_d"/plugins/cache/meridian-marketplace/meridian/*/VERSION 2>/dev/null | sort -V | tail -1 || true)
  [ -n "$v" ] && echo "$v" && break
done
```
Store the result as `old_version`. If empty, fall back to `{plugin-root}/VERSION`.

Do not use `{plugin-root}/VERSION` as the primary source because a development session may resolve it to a newer source checkout and incorrectly report that the installed plugin needs no update.

### Step 2. Handle --check

If the user supplied `--check`, display a version banner with the installed version and stop.

### Step 3. Check for an update

```bash
curl -sf --max-time 5 "https://raw.githubusercontent.com/michaelheichler/vibe-better-with-claude-code-lbwc/main/VERSION"
```
Store the result as `remote_version`. If curl fails, stop and display "⚠ Could not reach GitHub to check for updates."
If the remote and installed versions match, display "✓ Already at latest (v{old_version}). Refreshing cache..." and continue to Step 4.

### Step 4. Refresh the cache

```bash
bash "{plugin-root}/scripts/cache-nuke.sh"
```
The helper removes `CLAUDE_DIR/plugins/cache/meridian-marketplace/meridian/` and `CLAUDE_DIR/commands/meridian/`, along with `/tmp/meridian-*`.

### Step 5. Perform the update

For the same version, display "Refreshing Meridian v{old_version} cache..." Otherwise display "Updating Meridian v{old_version}..."

Prefix every `claude plugin` command with `unset CLAUDECODE &&` because Claude Code otherwise detects the parent session variable and rejects nested execution.

Refresh the marketplace first because a stale checkout causes the plugin update to cache old code again.
```bash
unset CLAUDECODE && claude plugin marketplace update meridian-marketplace 2>&1
```
If that fails, display "⚠ Marketplace refresh failed, trying update anyway..."

Try these options in order and stop at the first success.

- **Platform update.** `unset CLAUDECODE && claude plugin update meridian@meridian-marketplace 2>&1`
- **Reinstall.** `unset CLAUDECODE && claude plugin uninstall meridian@meridian-marketplace 2>&1 && unset CLAUDECODE && claude plugin install meridian@meridian-marketplace 2>&1`
- **Manual fallback.** Display the commands for the user to run and stop.

After a platform update or reinstall succeeds, remove stale global commands.
```bash
for _d in "${CLAUDE_CONFIG_DIR:-}" "$HOME/.config/claude-code" "$HOME/.claude"
do
  [ -z "$_d" ] && continue
  rm -rf "$_d/commands/meridian" 2>/dev/null
done
```
This removes copies that break `{plugin-root}` resolution, so commands load from the plugin cache instead.

### Step 5.5. Ensure Meridian statusline

Read `CLAUDE_DIR/settings.json` and check `statusLine` (a string or the object `.command`). If it contains `meridian-statusline`, skip this step. Otherwise use this command.
```json
{"type": "command", "command": "bash -c 'for _d in \"${CLAUDE_CONFIG_DIR:-}\" \"$HOME/.config/claude-code\" \"$HOME/.claude\"\\n do\\n   [ -z \"$_d\" ] && continue\\n   f=$(ls -1 \"$_d\"/plugins/cache/meridian-marketplace/meridian/*/scripts/meridian-statusline.sh 2>/dev/null | sort -V | tail -1 || true)\\n   [ -f \"$f\" ] && exec bash \"$f\"\\n done'"}
```
Use jq to write the setting after creating a backup and restore that backup on failure. Display `✓ Statusline restored (restart to activate)` if the setting changes.

### Step 6. Verify the update

```bash
NEW_CACHED=$(for _d in "${CLAUDE_CONFIG_DIR:-}" "$HOME/.config/claude-code" "$HOME/.claude"
do
  [ -z "$_d" ] && continue
  v=$(cat "$_d"/plugins/cache/meridian-marketplace/meridian/*/VERSION 2>/dev/null | sort -V | tail -1 || true)
  [ -n "$v" ] && echo "$v" && break
done)
```
Use `NEW_CACHED` as the authoritative version. If it is empty or still equals `old_version` after an expected upgrade, display "⚠ Update may not have applied. Try /meridian:update again after restart."

### Step 7. Display the result

Use `NEW_CACHED` for every version display. For the same version, show the "Meridian Cache Refreshed" banner and "Changes active immediately". For a new version, show the "Meridian Updated" banner with old and new versions, followed by "Changes active immediately" and `/meridian:whats-new`.

If Step 6 found an empty or unchanged version after an expected upgrade, keep the restart suggestion as a diagnostic fallback.

## Output Format

Follow @${CLAUDE_PLUGIN_ROOT}/references/meridian-brand-essentials.md. Use the double-line box and ✓ for success or ⚠ for a fallback warning, followed by Next Up. Do not use ANSI.

## Guard

`--check` is read-only. Before replacing an installed plugin or statusline, preserve the current version and require the helper rollback boundary. Never push or change project source.

## Next Up

After verification, show `/meridian:whats-new` and stop.
