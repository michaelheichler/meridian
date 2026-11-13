---
category: supporting
model: sonnet
disable-model-invocation: true
description: Add an item to the persistent backlog in STATE.md.
argument-hint: <todo-description> [--priority=high|normal|low]
allowed-tools: Read, Edit, Bash
---

# MERIDIAN Todo: $ARGUMENTS

## Context

- Use the current workspace root as the working directory.
- Plugin cache root: `"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/meridian-marketplace/meridian"` (respects non-default `CLAUDE_CONFIG_DIR`, always quote, path may contain spaces).

## Guard

1. **Not initialized** (no .meridian/ dir): STOP "Run /meridian:init first."
2. **Missing description:** STOP: `Usage: /meridian:todo <description> [--priority=high|normal|low]`
3. **Restricted mode:** If the current permission mode does not allow both Bash and edits, STOP: "`/meridian:todo` needs Bash plus write access to update `.meridian/STATE.md` and run the planning git boundary. If you're in read-only or another restricted mode, switch to a mode that allows both and rerun the command."

## Steps

1. **Resolve context:** Always use `.meridian/STATE.md` for todos, project-level data lives at the root, not in milestone subdirectories. If `.meridian/STATE.md` does not exist, STOP: "STATE.md not found. Session startup normally recovers archived state automatically, try restarting your Claude session, or run /meridian:init to set up your project."
2. **Parse args:** Description (non-flag text), --priority (normal by default). Format high=`[HIGH]`, normal=plain, low=`[low]`. Append `(added {YYYY-MM-DD})`.
3. **Add plain todo to STATE.md:** Find `## Todos` section. Replace "None." / placeholder or append after last item.
### Resolve helpers and preserve detail

4. **Resolve plugin root.** Determine the plugin root path for helper-backed follow-up work. Always quote derived paths (they may contain spaces). Try in order:
   (a) The `local/` subdirectory under the plugin cache root (i.e. `"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/meridian-marketplace/meridian/local/"`), if it exists and contains `scripts/hook-wrapper.sh`.
   (b) The numerically highest versioned directory under the plugin cache root, list subdirectories matching a dotted-version pattern (e.g. `1.30.0`), sort by each numeric component (major, minor, patch), pick the highest, and accept it only if it contains `scripts/hook-wrapper.sh`.
   (c) Any other (non-versioned) subdirectory under the plugin cache root, pick the newest by name, accept only if it contains `scripts/hook-wrapper.sh`. This covers non-standard cache layouts.
   (d) The session symlink `/tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-root-$(printf %s "$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)" | shasum -a 256 | cut -c1-64)}`, or any existing `/tmp/.meridian-plugin-root-link-*` symlink whose target contains `scripts/hook-wrapper.sh`.
   (e) Extract `--plugin-dir <path>` from the process tree (`ps axww`) and use that path if it contains `scripts/hook-wrapper.sh`.
   Store the resolved path as `PLUGIN_ROOT` for subsequent helper calls. If none of the fallbacks resolve, leave `PLUGIN_ROOT` empty and continue, extended detail and the planning git boundary will degrade gracefully later.
5. **Capture extended detail (conditional).** Check whether the description from step 2 contains file paths, reproduction steps, stack traces, code references, error messages, or multi-sentence design rationale. Only evaluate the current `$ARGUMENTS` text, do not scan prior conversation history.
   - **If triggered:** The todo has rich context worth preserving for later execution.
     1. If `PLUGIN_ROOT` is empty, leave the plain todo line from step 3 unchanged, do not append a ref tag, do not write `.meridian/todo-details/HASH.json` yourself, and continue to step 6 with a warning that extended detail was not saved.
     2. Extract a brief one-line summary (first sentence or the user's explicit title), this is already the `STATE.md` bullet text from step 3.
     3. Compute a hash: `printf '%s' "<summary text>" | shasum | cut -c1-8`
     4. Build a JSON detail object: `{"summary": "<brief summary>", "context": "<full description, max 2000 chars>", "files": ["<any file paths mentioned>"], "added": "<YYYY-MM-DD>", "source": "user"}`
     5. Store it through the canonical helper, pipe JSON via heredoc to avoid shell-quoting issues with apostrophes or special characters in user text:
        ```bash
        bash "${PLUGIN_ROOT}/scripts/todo-details.sh" add HASH - <<'DETAIL_JSON'
        <json>
        DETAIL_JSON
        ```
     6. Parse the helper's stdout JSON. Only when the parsed stdout is valid JSON with `status="ok"` may you:
        - edit the exact todo line you added in step 3 in `STATE.md` to append `(ref:HASH)` after the `(added YYYY-MM-DD)` tag
        - later report `Extended detail saved (ref:HASH).`
     7. If the helper's stdout is not valid JSON or the parsed `status` is anything other than `ok`, leave the plain todo line from step 3 unchanged, do not append a ref tag, and do not write `.meridian/todo-details/HASH.json` yourself.
   - **If the description does not trigger detail capture** (simple one-liner with no structural context), skip, no ref tag, no detail storage. Brief bullets keep STATE.md scannable and token-efficient for context compilation. The detail file preserves context that a later session would otherwise lose when executing the todo.
6. **Run planning git boundary.** This step only happens after the plain `STATE.md` write from step 3 succeeded. For simple one-line todos, run it after step 3 using the shared `PLUGIN_ROOT` from step 4. For rich-detail todos, run it only after step 5 completes, after the `(ref:HASH)` update on detail-save success, or after the failed-detail/no-ref branch on helper failure. If `PLUGIN_ROOT` is non-empty and `${PLUGIN_ROOT}/scripts/planning-git.sh` exists, run:
   ```bash
   bash "${PLUGIN_ROOT}/scripts/planning-git.sh" commit-boundary "add todo item" .meridian/config.json
   ```
   If `PLUGIN_ROOT` is empty or the helper is unavailable, keep the todo write intact and warn with the literal existing message:
   ```text
   ⚠ MERIDIAN: planning-git.sh unavailable. Skipping planning git boundary commit.
   ```
   Do not add bespoke staging, commit, or push logic here, the helper owns that behavior.
   - `planning_tracking=commit`: the helper stages `.meridian/` + `CLAUDE.md` and commits if there are changes.
   - `planning_tracking=manual|ignore`: the helper no-ops.
   - `auto_push=always`: the helper pushes when the branch already has an upstream.
7. **Confirm:** Display ✓ + formatted item + Next Up (/meridian:status). If step 5.6 captured detail successfully, also display `Extended detail saved (ref:HASH).` If step 5 triggered but helper-backed storage did not succeed, warn that you added the plain todo but did not save extended detail. If step 6 emitted the planning-git warning, surface it too.

## Output Format

Follow @${CLAUDE_PLUGIN_ROOT}/references/meridian-brand-essentials.md, ✓ success, Next Up, no ANSI.

## Next Up

After persistence succeeds, show `/meridian:list-todos` and stop.
