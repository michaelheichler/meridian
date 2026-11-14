---
category: supporting
model: sonnet
disable-model-invocation: true
description: Restore project context from .meridian/ state.
argument-hint: "[session-or-phase]"
allowed-tools: Read, Bash, Glob
---

# MERIDIAN Resume

## Context

Working directory:
```
!`pwd`
```
Plugin root:
```
!`SESSION_KEY="${CLAUDE_SESSION_ID:-root-$(printf "%s\n" "$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)" | shasum -a 256 | cut -c1-64)}"; [ "$SESSION_KEY" != root- ] || { echo "MERIDIAN: plugin root hash unavailable" >&2; exit 1; }; L="/tmp/.meridian-plugin-root-link-${SESSION_KEY}"; R="$L/scripts/resolve-plugin-root.sh"; [ -f "$R" ] || R="${CLAUDE_PLUGIN_ROOT:-}/scripts/resolve-plugin-root.sh"; [ -f "$R" ] || { echo "MERIDIAN: plugin root unavailable. Restart this session to recreate $L." >&2; exit 1; }; bash "$R" >/dev/null || exit 1; bash "$L/scripts/phase-detect.sh" > "/tmp/.meridian-phase-detect-${SESSION_KEY}.txt" 2>/dev/null || echo "phase_detect_error=true" > "/tmp/.meridian-phase-detect-${SESSION_KEY}.txt"; echo "$L"`
```

Pre-computed state (via phase-detect.sh):
```
!`SESSION_KEY="${CLAUDE_SESSION_ID:-root-$(printf "%s\n" "$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)" | shasum -a 256 | cut -c1-64)}"; [ "$SESSION_KEY" != root- ] || { echo "MERIDIAN: plugin root hash unavailable" >&2; exit 1; }
L="/tmp/.meridian-plugin-root-link-${SESSION_KEY}"
P="/tmp/.meridian-phase-detect-${SESSION_KEY}.txt"
PD=""
_refresh_phase_detect() {
  local resolver root
  resolver="$L/scripts/resolve-plugin-root.sh"
  if [ ! -f "$resolver" ]; then
    if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-plugin-root.sh" ]; then
      resolver="${CLAUDE_PLUGIN_ROOT}/scripts/resolve-plugin-root.sh"
    else
      return 1
    fi
  fi
  root=$(bash "$resolver" --require-script phase-detect.sh 2>/dev/null) || return 1
  PD=$(bash "$root/scripts/phase-detect.sh" 2>/dev/null) || PD=""
  if [ -z "$(printf '%s' "$PD" | tr -d '[:space:]')" ] || [ "$PD" = "phase_detect_error=true" ]; then
    return 1
  fi
  printf '%s' "$PD" > "$P"
  return 0
}
if ! _refresh_phase_detect
then
  PD="phase_detect_error=true"
  printf '%s\n' "$PD" > "$P"
fi
[ -f "$P" ] && PD=$(cat "$P")
if [ -n "$(printf '%s' "$PD" | tr -d '[:space:]')" ] && [ "$PD" != "phase_detect_error=true" ]; then
  printf '%s' "$PD"
else
  echo "phase_detect_error=true"
fi`
```

## Guard

1. **Not initialized** (no .meridian/ dir): STOP "Run /meridian:init first."
2. **Brownfield normalization:** If Pre-computed state (from Context above) contains `misnamed_plans=true`, normalize all phase directories before proceeding:
   ```bash
   NORM_SCRIPT="{plugin-root}/scripts/normalize-plan-filenames.sh"
   if [ -f "$NORM_SCRIPT" ]; then
     for pdir in .meridian/phases/*/; do
       [ -d "$pdir" ] && bash "$NORM_SCRIPT" "$pdir"
     done
   fi
   ```
   Display: "⚠ Renamed misnamed plan files to `{NN}-PLAN.md` convention."
   Then re-run phase-detect.sh to refresh state:
   ```bash
   SESSION_KEY="${CLAUDE_SESSION_ID:-root-$(printf "%s\n" "$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)" | shasum -a 256 | cut -c1-64)}"
   [ "$SESSION_KEY" != root- ] || { echo "MERIDIAN: plugin root hash unavailable" >&2; exit 1; }
   bash "{plugin-root}/scripts/phase-detect.sh" > "/tmp/.meridian-phase-detect-${SESSION_KEY}.txt"
   ```
   Use the refreshed phase-detect output for all subsequent steps.
3. **No roadmap:** `.meridian/ROADMAP.md` missing → STOP: "No roadmap found. Run /meridian:transit."
4. **Phase-detect error:** If output contains `phase_detect_error=true`, display: "⚠ Phase detection failed. Run phase-detect.sh manually to debug." and STOP.

## Steps

1. **Read ground truth from active planning state only.** Never read archived milestone state.

   Project state:
   - `.meridian/PROJECT.md`, name and core value
   - `.meridian/STATE.md`, decisions, todos, and blockers
   - `.meridian/ROADMAP.md`, phases overview
   - `.meridian/RESUME.md`, session notes

   Run the deterministic resume helper after the guards and any normalization.
   ```bash
   bash "{plugin-root}/scripts/resume-context.sh"
   ```
   It reads `explorer-journal.sh current`, compares the journal HEAD with current HEAD, prints `git log --oneline <journal HEAD>..HEAD` when HEAD moved, and prints `git diff --stat`. Show its staleness or unknown HEAD line and any consistency findings. Clean consistency checks produce no output.

   Execution evidence from the active phase only.
   - Read each `active_phase_file=` path from the helper output. These are the canonical PLAN and SUMMARY files of the phase that phase-detect selects, including its most recent terminal SUMMARY.
   - Do not read PLAN or SUMMARY files from other phases or archived milestones.
   - Query task contracts and generated-agent manifest state when a build may have stopped before completion. For an interrupted build in another phase, inspect its contract, commits and verify results, report the phase mismatch, and leave recovery blocked until that phase becomes active.

   Keep reading `RESUME.md` even when a journal entry exists. Skip missing optional files. A missing required PLAN, contract, or terminal summary remains a blocker.
2. **Compute progress from phase-detect.sh output:** Use the pre-computed `phase_count`, `next_phase`, `next_phase_state`, `next_phase_plans`, `next_phase_summaries`, `uat_issues_phase`, `uat_issues_slug`, `uat_issues_phases`, and `uat_issues_count` values. Map `next_phase_state` to display: `needs_uat_remediation` → "⚠ Needs remediation", `needs_verification` → "⏳ Needs UAT verification", `needs_plan_and_execute` → "not started", `needs_execute` → "in progress", `all_done` → "complete". **Per-phase status:** any phase whose number appears in the comma-separated `uat_issues_phases` list has unresolved UAT issues, mark it "⚠ Needs remediation". Only mark a phase as "✓ Done" if its number is NOT in `uat_issues_phases` and it has completed execution (SUMMARY count ≥ PLAN count). Phases not yet executed are "not started".
   **Known issues check:** For each phase directory, run:
   ```bash
   bash "{plugin-root}/scripts/track-known-issues.sh" promote-todos "{phase-dir}" 2>/dev/null || true
   bash "{plugin-root}/scripts/track-known-issues.sh" status "{phase-dir}" 2>/dev/null
   ```
   Parse `known_issues_count` from the status output. For each phase with `known_issues_count > 0`, include in the dashboard after the phase table: `⚠ Phase {NN}: N known issue(s) deferred, run /meridian:list-todos to review`. Omit for phases with zero known issues. The `promote-todos` call is a backfill, it promotes any known issues not yet in `STATE.md ## Todos` on resume.
3. **Detect interrupted builds:** Query task contracts and the generated-agent manifest. A contract in `dispatched`, `running`, `awaiting_review`, or `blocked`, or a generated member still `registered` or `running`, means the build is incomplete. Confirm the corresponding PLAN, commits, verify results, and terminal SUMMARY before choosing recovery.
4. **Present dashboard:** Phase Banner "Context Restored / {project name}" with core value, phase/progress, overall progress bar, key decisions, todos, blockers (⚠), last completed, build status (✓ completed / ⚠ interrupted), session notes. Run `bash "{plugin-root}/scripts/suggest-next.sh" resume`.

## Output Format

Follow @${CLAUDE_PLUGIN_ROOT}/references/meridian-brand-essentials.md, double-line box, Metrics Block, ⚠ warnings, ✓ completions, ➜ Next Up, no ANSI.

## Next Up

Run `scripts/suggest-next.sh resume` and display its exact MERIDIAN command. Stop without starting it.
