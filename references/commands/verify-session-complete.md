Use `{plugin-root}` as the literal plugin root resolved by the parent command. Replace it before running helpers or reading files.

- **Finalize UAT status (script-based, NON-NEGOTIABLE):** Run the finalize script to deterministically compute and update frontmatter status, counts, and completed date:
  ```bash
  bash "{plugin-root}/scripts/finalize-uat-status.sh" "{phase-dir}/{uat_path}"
  ```
  If the script fails or reports unrecognized `**Result:**` values, STOP and surface the error. Do NOT patch the UAT frontmatter manually. The script reads all `**Result:**` lines, counts pass/skip/issue, and updates the YAML frontmatter (`status`, `completed`, `passed`, `skipped`, `issues`, `total_tests`). Its output (`status={status} passed={N} ...`) provides the values for the summary display below. Do NOT manually update frontmatter fields, the script is the source of truth.
- **Accepted deviation registry sync:** After finalization, run:
  ```bash
  bash "{plugin-root}/scripts/track-uat-deviations.sh" record-from-uat "{phase-dir}" "{phase-dir}/{uat_path}"
  ```
  This persists accepted summary-deviation signatures so identical source/text deviations are not prefilled again in future UAT sessions.
- Display summary:

```text
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Phase {NN}: {name}, UAT Complete
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Result:   {✓ PASS | ✗ ISSUES FOUND}
  Passed:   {N}
  Skipped:  {N}
  Issues:   {N}

  Report:   {path to UAT.md}
```

**Discovered Issues in summary:** If you recorded any discovered issues (`D{NN}` entries) during the session, list them after the result box so the user sees them at a glance:
```text
  Discovered Issues:
    ⚠ D01: {short-title} (severity: {level})
    ⚠ D02: {short-title} (severity: {level})
```
These are already recorded in the UAT.md and will flow into remediation alongside test failures. If there are no discovered issues, omit the section.

**Remediation lifecycle advance (ONLY when `verify_scope=remediation`, skip entirely for first-time UAT):**
First, verify that UAT remediation state exists before running any lifecycle commands. If no state file exists (neither new-format nor legacy location), this is a first-time UAT, do NOT call `needs-round` or any remediation state command:
```bash
_uat_state_file="{phase-dir}/remediation/uat/.uat-remediation-stage"
_uat_legacy_remed_file="{phase-dir}/remediation/.uat-remediation-stage"
_uat_legacy_file="{phase-dir}/.uat-remediation-stage"
_uat_state_exists=false
{ [ -f "$_uat_state_file" ] || [ -f "$_uat_legacy_remed_file" ] || [ -f "$_uat_legacy_file" ]; } && _uat_state_exists=true
```
**If `_uat_state_exists=false`:** Skip this entire block, this is a first-time UAT, not a re-verification after remediation.
**If `_uat_state_exists=true` AND `verify_scope=remediation`:**
- If `status=issues_found`, handle based on calling context:

  **Orchestrated mode** (called from transit.md, you are executing inside transit.md's Verify mode): Do NOT call `needs-round`. The caller will advance state after checking the round cap. Emit this signal for the calling orchestrator: `remediation_continue=true issues={N}` (where `{N}` is the issue count from finalization above).

  **Standalone mode** (running via `/meridian:verify` directly, not called from transit.md): Check the shared UAT remediation round-cap contract before mutating state:
  ```bash
  _current_round=$(bash "{plugin-root}/scripts/uat-remediation-state.sh" current-round "{phase-dir}")
  _cap_decision=$(bash "{plugin-root}/scripts/resolve-uat-remediation-round-limit.sh" --next-round-decision .meridian/config.json "${_current_round}" 2>/dev/null)
  _next_round=$(printf '%s\n' "$_cap_decision" | awk -F= '/^next_round=/{print $2; exit}')
  _max_rounds=$(printf '%s\n' "$_cap_decision" | awk -F= '/^max_rounds=/{print $2; exit}')
  _cap_reached=$(printf '%s\n' "$_cap_decision" | awk -F= '/^cap_reached=/{print $2; exit}')
  ```
  - If `_cap_reached` is empty or `_cap_decision` is empty, the round-cap helper failed or returned malformed output. Display: "⚠ Could not determine UAT remediation round cap. Run `/meridian:verify` to retry." STOP. Do NOT call `needs-round`, no state mutation on error paths.
  - If `_cap_reached=true`, display:
    ```text
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
      Reached maximum UAT remediation rounds ({_max_rounds}).
      Review issues manually or adjust max_uat_remediation_rounds
      in config.json.
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    ```
    STOP, do not call `needs-round`.
  - Otherwise call:
    ```bash
    bash "{plugin-root}/scripts/uat-remediation-state.sh" needs-round "{phase-dir}"
    ```
    This increments the round counter, creates the next round directory, and resets stage to `research`. Do NOT emit the `remediation_continue` signal, standalone verify has no caller to receive it.
- If `status=complete`, remediation verification succeeded. Mark remediation as verified (do NOT delete the state file, `current_uat()` needs it to locate the round-dir UAT):
  ```bash
  # Mark remediation as verified, preserves round/layout so current_uat() can still find the active round-scoped UAT
  _state_file="{phase-dir}/remediation/uat/.uat-remediation-stage"
  _legacy_remed_file="{phase-dir}/remediation/.uat-remediation-stage"
  _legacy_phase_file="{phase-dir}/.uat-remediation-stage"
  _write_state_file=""
  if [ -f "$_state_file" ]; then
    _write_state_file="$_state_file"
  elif [ -f "$_legacy_remed_file" ]; then
    _write_state_file="$_legacy_remed_file"
  elif [ -f "$_legacy_phase_file" ]; then
    _write_state_file="$_legacy_phase_file"
  fi
  if [ -n "$_write_state_file" ]; then
    _cur_round=$(grep '^round=' "$_write_state_file" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]')
    _cur_layout=$(grep '^layout=' "$_write_state_file" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]')
    case "$_write_state_file" in
      */remediation/.uat-remediation-stage|*/.uat-remediation-stage)
        _cur_round="${_cur_round:-01}"
        _cur_layout="${_cur_layout:-legacy}"
        ;;
      *)
        _cur_round="${_cur_round:-01}"
        _cur_layout="${_cur_layout:-round-dir}"
        ;;
    esac
    printf 'stage=verified\nround=%s\nlayout=%s\n' "$_cur_round" "$_cur_layout" > "$_write_state_file"
  fi
  ```

- If issues found:
  - Any issue severity is `critical` or `major`:
    - `Suggest /meridian:transit to continue UAT remediation directly from {uat_path}`
  - All issues are `minor`:
    - `Suggest /meridian:fix to address recorded issues.`

**Planning artifact boundary commit (conditional):**
```bash
PG_SCRIPT="{plugin-root}/scripts/planning-git.sh"
if [ -f "$PG_SCRIPT" ]; then
  bash "$PG_SCRIPT" commit-boundary "verify phase {NN}" .meridian/config.json
else
  echo "⚠ MERIDIAN: planning-git.sh unavailable. Skipping planning git boundary commit." >&2
fi
```
- `planning_tracking=commit`: commits `.meridian/` + `CLAUDE.md` when changed (includes UAT report)
- `planning_tracking=manual|ignore`: no-op
- `auto_push=always`: push happens inside the boundary commit command when upstream exists

When executed inline from `/meridian:transit`, the calling mode handles auto-continuation based on `remediation_continue`. The `suggest-next.sh` output and severity-based suggestions above serve as the standalone `/meridian:verify` fallback.

Run `bash "{plugin-root}/scripts/suggest-next.sh" verify {result} {phase}` and display.
