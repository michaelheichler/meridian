---
category: supporting
model: haiku
disable-model-invocation: true
description: Run health checks on MERIDIAN installation and project setup.
argument-hint: "[--cleanup] [--verbose]"
allowed-tools: Read, Bash, Glob, Grep, LSP
---

# MERIDIAN Doctor

## Context

Plugin root, project root, and version (self-contained, shell variables do not survive across directives):

```bash
!`SESSION_KEY="${CLAUDE_SESSION_ID:-root-$(printf %s "$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)" | shasum -a 256 | cut -c1-64)}"; L="/tmp/.meridian-plugin-root-link-${SESSION_KEY}"; R="$L/scripts/resolve-plugin-root.sh"; [ -f "$R" ] || R="${CLAUDE_PLUGIN_ROOT:-}/scripts/resolve-plugin-root.sh"; [ -f "$R" ] || { echo "MERIDIAN: plugin root unavailable. Restart this session to recreate $L." >&2; exit 1; }; LINK=$(bash "$R" --require-script tmux-preflight.sh) || exit 1; PROJECT_ROOT=$(source "$LINK/scripts/lib/meridian-target-root.sh" && meridian_resolve_target_root 0 2>/dev/null || git rev-parse --show-toplevel 2>/dev/null) || { echo "MERIDIAN: no Git repository root found. /meridian:doctor requires a Git repository." >&2; exit 1; }; VERSION=$(cat "$LINK/VERSION" 2>/dev/null || printf 'none'); printf 'Plugin root: %s\nProject root: %s\nVersion: %s\n' "$LINK" "$PROJECT_ROOT" "$VERSION"`
```

Store the returned `Plugin root` value as `{LINK}` and the returned `Project root` value as `{PROJECT_ROOT}` for every later literal helper invocation. Never guess a plugin path or substitute a missing helper with an inline approximation.

## Checks

Run ALL checks below. For each, report PASS or FAIL with a one-line detail. Replace `{LINK}` and `{PROJECT_ROOT}` with their literal Context values.

### 1. jq installed

`jq --version 2>/dev/null || echo "MISSING"`
FAIL if missing: "Install jq: brew install jq (macOS) or apt install jq (Linux)"

### 2. VERSION file exists

Check `{LINK}/VERSION`. FAIL if missing.

### 3. Version sync

`bash "{LINK}/scripts/version-bump.sh" --verify 2>&1`
FAIL if mismatch detected.

### 4. Plugin cache present

Check `${CLAUDE_CONFIG_DIR:-~/.claude}/plugins/cache/meridian-marketplace/meridian/` exists and has at least one version directory. FAIL if empty or missing.

### 5. hooks.json valid

Parse `{LINK}/hooks/hooks.json` with `jq empty`. FAIL if parse error.

### 6. Agent role templates present

Glob `{LINK}/templates/agent-roles/*.md.tpl`. Expect 8 files (lead, dev, qa, qa-author, scout, debugger, architect, docs). FAIL if any missing.

### 7. Config valid (project only)

If `.meridian/config.json` exists, parse with `jq empty`. FAIL if parse error. SKIP if no project initialized.

### 8. Scripts executable

Check all `{LINK}/scripts/*.sh` files. WARN if any lack execute permission.

### 9. gh CLI available

`gh --version 2>/dev/null || echo "MISSING"`
WARN if missing: "Install gh for GitHub CLI integration (used by maintainer release tooling)."

### 10. sort -V support

`echo -e "1.0.2\n1.0.10" | sort -V 2>/dev/null | tail -1`
PASS if result is "1.0.10". WARN if sort -V is unavailable (use the fallback).

### Runtime Health

### 11. Stale teams

Run `bash "{LINK}/scripts/doctor-cleanup.sh" scan 2>/dev/null` and count lines starting with `stale_team|`.
PASS if 0. WARN if any, show count.

### 12. Orphaned processes

Count lines starting with `orphan_process|` from the scan output.
PASS if 0. WARN if any, show count.

### 13. Dangling PIDs

Count lines starting with `dangling_pid|` from the scan output.
PASS if 0. WARN if any, show count.

### 14. Stale markers

Count lines starting with `stale_marker|` from the scan output.
PASS if 0. WARN if any, list which markers.

### 15. Watchdog status

If the environment defines $TMUX, check if .meridian/.watchdog-pid exists and process is alive via kill -0.
PASS if alive or not in tmux. WARN if dead watchdog in tmux.

### 16. CLAUDE.md sections

If `.meridian/` exists (project initialized):

- Run `bash "{LINK}/scripts/check-claude-md-staleness.sh" --json 2>/dev/null`
- Parse JSON output: `stale`, `missing_sections`, `version_mismatch`, `installed_version`, `marker_version`
- PASS if `stale` is false
- WARN if `stale` is true, show missing sections and/or version mismatch detail
- SKIP if no `.meridian/` directory (not bootstrapped)

If user invoked with `--cleanup`, run `bash "{LINK}/scripts/check-claude-md-staleness.sh" --fix 2>&1` and report result. The fix must refresh only MERIDIAN-owned sections in place, preserve all other `CLAUDE.md` content verbatim, and add `## Code Intelligence` only when no Code Intelligence heading/guidance already exists.

### 17. State consistency

If `.meridian/` exists:

- Run `bash "{LINK}/scripts/verify-state-consistency.sh" .meridian --mode advisory 2>/dev/null`
- Parse JSON output with jq: `.verdict`
- PASS if verdict is `"pass"`
- WARN if verdict is `"fail"`, show `.failed_checks` array
- SKIP if no `.meridian/` directory (not bootstrapped)

### 18. RTK integration

Run `bash "{LINK}/scripts/rtk-manager.sh" doctor-json 2>/dev/null`.

- Parse JSON output: `doctor_status`, `doctor_detail`, `compatibility`, `compatibility_basis`, `updated_input_risk`, `proof_source`, `diagnostic_caveat`, `upstream_issue`
- SKIP only when RTK is absent and helper JSON reports no local/global RTK artifacts, no MERIDIAN RTK receipt, and no partial install evidence
- WARN when binary-only, hook-active-unverified, artifact-only, missing/error config, settings are unreadable, or a cached explicit update check reports an outdated RTK version
- PASS when `compatibility` is `"verified"` with a concrete `proof_source`, even if `updated_input_risk=true`, the runtime proof verifies this local RTK/MERIDIAN hook setup
- In normal output, do not warn solely because anthropics/claude-code#15897 still exists after proof. When invoked with `--verbose`, include `diagnostic_caveat`/`upstream_issue` as detail so the upstream caveat remains visible without downgrading health.
- Doctor must not query the network, run RTK history/stats, or run runtime smoke, runtime smoke requires explicit Claude Code Bash-tool orchestration and belongs in `/meridian:rtk verify`. Update availability may only come from cached explicit `/meridian:rtk status --check-updates` or `/meridian:rtk update` data.

### 19. Agent routing evidence

If `.meridian/.agent-routing-evidence.jsonl` exists, run `bash "{LINK}/scripts/agent-routing-evidence.sh" check` and report its compact summary. PASS when the report records no model mismatches. WARN when the report contains any model mismatch or stale running entry. SKIP when the evidence file is absent.

### 20. Temporary agent runs

Read `temporary_run_*` findings from `doctor-cleanup.sh scan`. PASS when none exist. WARN for active or unreadable retained runs and old terminal runs awaiting cleanup. With `--cleanup`, remove only readable terminal runs older than 72 hours.

### Runtime diagnostics

Run `bash "{LINK}/scripts/tmux-doctor.sh" --project-root "{PROJECT_ROOT}" --control-root "{PROJECT_ROOT}/.meridian"`. Parse the JSON with jq for `.status` (`PASS`, `WARN`, or `FAIL`) and `.detail` (the one-line finding). Print that PASS/WARN/FAIL detail as part of check 20. Do not add a 21st check.

The helper reports the execution backend, tmux session and pane health, agent lifecycle counts, registry validity, routes, and stale heartbeats. A malformed registry is WARN/FAIL from the helper, not freeform prose. A malformed route, missing tmux session, missing pane, or stale heartbeat is WARN from the helper. Do not source `tmux-runtime.sh` in this command or interpret runtime records inline.

Check 20 combined status is FAIL when the helper status is FAIL. It is WARN when temporary runs warn or the helper status is WARN. It is PASS when both PASS. Include the helper `.status` and `.detail` in the check 20 detail field.

- Check the registry and routing table before calling tmux. Do not trust malformed state to authorize a backend switch or cleanup.
- These diagnostics are read-only. `--cleanup` does not authorize cleanup of TMUX runtime state. Never remove registry, route, lock, claim, pane, or session state through doctor.
- For an unavailable runtime, run `bash "{LINK}/scripts/tmux-preflight.sh" --project-root "{PROJECT_ROOT}" --control-root "{PROJECT_ROOT}/.meridian" --main-id "${CLAUDE_SESSION_ID:-main}"`. For a valid bus, use `bash "{LINK}/scripts/tmux-bus.sh"` only with the authenticated principal arguments from its registry owner.
- Show `Run `/meridian:doctor --cleanup`` only for the existing cleanup checks. It does not authorize cleanup of TMUX runtime state.

## Output Format

```text
MERIDIAN Doctor v{version}

  1. jq installed          {PASS|FAIL} {detail}
  2. VERSION file          {PASS|FAIL}
  3. Version sync          {PASS|FAIL} {detail}
  4. Plugin cache          {PASS|FAIL} {detail}
  5. hooks.json valid      {PASS|FAIL}
  6. Agent role templates {PASS|FAIL} {count}/8
  7. Config valid          {PASS|FAIL|SKIP}
  8. Scripts executable    {PASS|WARN} {detail}
  9. gh CLI                {PASS|WARN}
 10. sort -V support       {PASS|WARN}
 11. Stale teams          {PASS|WARN} {count}
 12. Orphaned processes   {PASS|WARN} {count}
 13. Dangling PIDs        {PASS|WARN} {count}
 14. Stale markers        {PASS|WARN} {markers}
 15. Watchdog status      {PASS|WARN}
 16. CLAUDE.md sections   {PASS|WARN|SKIP}
 17. State consistency    {PASS|WARN|SKIP}
 18. RTK integration      {PASS|WARN|SKIP} {detail}
  19. Routing evidence     {PASS|WARN|SKIP} {detail}
  20. Temporary runs       {PASS|WARN|FAIL} {detail}

Result: {N}/20 passed, {W} warnings, {F} failures
```

Use checkmark for PASS, warning triangle for WARN, X for FAIL.

### Cleanup

If any WARN from checks 11-14, 16, or 17:

- Show cleanup preview listing all findings
- Display: "Run `/meridian:doctor --cleanup` to apply cleanup"

If user invoked with `--cleanup` (check for this in the command arguments):

- Run `bash "{LINK}/scripts/doctor-cleanup.sh" cleanup 2>&1` for runtime findings
- Run `bash "{LINK}/scripts/check-claude-md-staleness.sh" --fix 2>&1` for stale CLAUDE.md (non-destructive in-place refresh of MERIDIAN-owned sections only)
- Report what you cleaned
- Show updated counts

## Guard

All checks are read-only unless `--cleanup` is explicit. Clean up only MERIDIAN-owned stale state. Never modify project source or remote state.

## Next Up

For a failed check, show its exact repair command. For a clean result, stop without suggesting mutation.
