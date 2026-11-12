- **QA gate (NON-NEGOTIABLE unless `--skip-qa`):** Before entering UAT Steps, check whether QA has passed for the target phase. Use `qa_status` from Phase state only when the target phase is the same as the auto-detected `verify_target_slug` / first-unverified phase. If the user specified an explicit phase number that differs from the auto-detected target, ignore the pre-computed `qa_status` and compute the gate from that explicit phase's own VERIFICATION.md + QA remediation state.
  ```bash
  PDIR=".meridian/phases/{target-slug}"
  PHASE_NUM=$(echo "{target-slug}" | sed 's/^\([0-9]*\).*/\1/')
  VERIF_FILE=$(bash "{plugin-root}/scripts/resolve-verification-path.sh" phase "$PDIR" 2>/dev/null || true)
  [ -n "$VERIF_FILE" ] && [ ! -f "$VERIF_FILE" ] && VERIF_FILE=""
  QA_REM_FILE="$PDIR/remediation/qa/.qa-remediation-stage"
  QA_REM_STAGE="none"
  if [ -f "$QA_REM_FILE" ]; then
    QA_REM_STAGE=$(grep '^stage=' "$QA_REM_FILE" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]')
    QA_REM_STAGE="${QA_REM_STAGE:-none}"
    case "$QA_REM_STAGE" in
      plan|execute|verify|done) ;;
      *) QA_REM_STAGE="none" ;;
    esac
  fi
  ```
  - If `QA_REM_STAGE` is `plan`, `execute`, or `verify`, STOP "Phase {NN} has active QA remediation (round {round}, stage {stage}). Run `/meridian:transit` to continue QA remediation before UAT."
  - If `QA_REM_STAGE=done`, refresh `VERIF_FILE` before reading `result:` or running stale-QA checks:
    ```bash
    VERIF_FILE=$(bash "{plugin-root}/scripts/resolve-verification-path.sh" current "$PDIR" 2>/dev/null || true)
    [ -n "$VERIF_FILE" ] && [ ! -f "$VERIF_FILE" ] && VERIF_FILE=""
    if [ -z "$VERIF_FILE" ]; then
      echo "Phase {NN} QA remediation is done, but the round-scoped VERIFICATION artifact is missing. Run /meridian:transit to restore the remediation artifact before UAT." >&2
      exit 1
    fi
    ```
    This requires the remediated round VERIFICATION.md. Keep the phase-level VERIFICATION.md frozen and do not reuse it once QA remediation reaches `done`.
  - If `QA_REM_FILE` exists but `QA_REM_STAGE=none` after normalization, treat it as corrupt/stale and continue using the resolved `VERIF_FILE` above.
  - If there is no VERIFICATION.md and no `--skip-qa`, STOP "Phase {NN} has no QA verification. Run `/meridian:transit` to execute QA first, or use `/meridian:verify --skip-qa` to bypass."
  - If `VERIF_FILE` exists but `known-issues.json` is missing or malformed, restore the authoritative registry before trusting QA/UAT state:
    ```bash
    KNOWN_ISSUES_META=$(bash "{plugin-root}/scripts/track-known-issues.sh" status "$PDIR" 2>/dev/null || true)
    KNOWN_ISSUES_STATUS=$(printf '%s\n' "$KNOWN_ISSUES_META" | awk -F= '/^known_issues_status=/{print $2; exit}')
    if [ -n "$VERIF_FILE" ] && { [ "$KNOWN_ISSUES_STATUS" = "missing" ] || [ "$KNOWN_ISSUES_STATUS" = "malformed" ]; }; then
      bash "{plugin-root}/scripts/track-known-issues.sh" sync-verification "$PDIR" "$VERIF_FILE" 2>/dev/null || true
      bash "{plugin-root}/scripts/track-known-issues.sh" promote-todos "$PDIR" 2>/dev/null || true
    fi
    ```
  - Before trusting any PASS artifact, re-run the deterministic QA gate for the target phase:
    ```bash
    QA_GATE_ROUTING=$(bash "{plugin-root}/scripts/qa-result-gate.sh" "$PDIR" 2>/dev/null | awk -F= '/^qa_gate_routing=/{print $2; exit}')
    ```
    - `PROCEED_TO_UAT`: continue to the freshness checks below.
    - `REMEDIATION_REQUIRED`: STOP "Phase {NN} QA gate still requires remediation (including unresolved tracked known issues, if any). Run `/meridian:transit` to continue QA remediation before UAT."
    - For `QA_RERUN_REQUIRED` or empty output, STOP "Phase {NN} QA verification is not authoritative yet. Run `/meridian:qa {NN}` or `/meridian:transit` to re-run QA before UAT, or use `/meridian:verify --skip-qa` to bypass."
  - If VERIFICATION.md exists, read its frontmatter `result:` field:
    - `PASS`: before proceeding, run the same stale-QA checks as phase-detect for this target phase: (1) if product-code working tree is dirty (`git status --porcelain --untracked-files=normal -- . ':!.meridian' ':!CLAUDE.md'` non-empty) → STOP and rerun QA via `/meridian:transit`, (2) if `verified_at_commit` exists and differs from current product-code `git log -1 --format='%H' -- . ':!.meridian' ':!CLAUDE.md'` → STOP and rerun QA, (3) if `verified_at_commit` is absent (brownfield file), compare VERIFICATION.md mtime to the latest product-code commit timestamp and STOP if the commit is newer. Only proceed to UAT when the PASS is both gate-authoritative and fresh for the target phase.
    - For `FAIL` or `PARTIAL`, STOP "Phase {NN} QA result is {result}. Run `/meridian:transit` to continue QA remediation, or use `/meridian:verify --skip-qa` to bypass."
  - If `--skip-qa` flag is present, bypass QA execution and PASS freshness checks only. This does **not** bypass unresolved phase known issues. Before entering UAT, run:
    ```bash
    KNOWN_ISSUES_META=$(bash "{plugin-root}/scripts/track-known-issues.sh" status "$PDIR" 2>/dev/null || true)
    KNOWN_ISSUES_STATUS=$(printf '%s\n' "$KNOWN_ISSUES_META" | awk -F= '/^known_issues_status=/{print $2; exit}')
    KNOWN_ISSUES_COUNT=$(printf '%s\n' "$KNOWN_ISSUES_META" | awk -F= '/^known_issues_count=/{print $2; exit}')
    ```
    If `KNOWN_ISSUES_STATUS=malformed`, STOP: "Phase {NN} has unreadable tracked known issues. Run `/meridian:transit` to continue QA remediation before UAT."
    If `KNOWN_ISSUES_COUNT > 0`, run the qa-result-gate for this phase to check whether the latest remediation round addressed all known issues:
    ```bash
    _gate_output=$(bash "{plugin-root}/scripts/qa-result-gate.sh" "$PDIR" 2>/dev/null || true)
    _gate_routing=$(printf '%s\n' "$_gate_output" | awk -F= '/^qa_gate_routing=/{print $2; exit}')
    _gate_all_addressed=$(printf '%s\n' "$_gate_output" | awk -F= '/^qa_gate_known_issues_all_addressed=/{print $2; exit}')
    ```
    If `_gate_all_addressed=true` and `_gate_routing=PROCEED_TO_UAT`, remediation resolved the known issues or recorded their acceptance as non-blocking, proceed to UAT. Otherwise STOP: "Phase {NN} still has unresolved tracked known issues. Run `/meridian:transit` to continue QA remediation before UAT."
