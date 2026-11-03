writer_fixture() {
  export LBWC_PLANNING_DIR="$PWD/.lbwc-planning"
  mkdir -p "$LBWC_PLANNING_DIR/phases/01-demo"
  printf '{}\n' > "$LBWC_PLANNING_DIR/config.json"
  printf 'Phase: 1\nStatus: in_progress\nPlans: 0/1\nProgress: 0%%\n' > "$LBWC_PLANNING_DIR/STATE.md"
  printf '# Plan\n' > "$LBWC_PLANNING_DIR/phases/01-demo/PLAN.md"
  printf -v JOURNAL '%s' "$LBWC_PLANNING_DIR/EXPLORER-JOURNAL.md"
}

writer_hook() {
  printf '%s' "$WRITER_INPUT" | bash "$SCRIPTS_DIR/$1.sh" > "$BATS_TEST_TMPDIR/stdout" 2> "$BATS_TEST_TMPDIR/stderr"
}

hold_journal_lock() {
  . "$SCRIPTS_DIR/lib/manifest-lock.sh"
  manifest_lock_acquire "$LBWC_PLANNING_DIR/.explorer-journal.lock" EXPLORER_JOURNAL
}

release_journal_lock() {
  manifest_lock_release "$LBWC_PLANNING_DIR/.explorer-journal.lock"
}

precompact_fixture() {
  writer_fixture
  printf -v WRITER_INPUT '%s' "$1"
  run env LBWC_PLANNING_DIR="$PWD/uninitialized" bash "$SCRIPTS_DIR/compaction-instructions.sh" <<< "$WRITER_INPUT"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/expected-json"
}

assert_writer_entry() {
  local trigger="$1"
  [ -f "$JOURNAL" ]
  [ "$(grep -c '^## ' "$JOURNAL")" -eq 1 ]
  [ "$(grep -c "^## .* $trigger$" "$JOURNAL")" -eq 1 ]
}

assert_precompact_output() {
  [ "$status" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/expected-json" "$BATS_TEST_TMPDIR/stdout"
}

precompact_retains_context() {
  precompact_fixture '{"command":"inspect work","request":"keep all features","next_step":"verify changes"}'
  run writer_hook compaction-instructions
  assert_precompact_output
  [ ! -s "$BATS_TEST_TMPDIR/stderr" ]
  assert_writer_entry precompact
  assert_field 'Active command' 'inspect work'
  assert_field 'Original request' 'keep all features'
  assert_field 'Next step' 'verify changes'
}

precompact_without_context() {
  precompact_fixture '{}'
  run writer_hook compaction-instructions
  assert_precompact_output
  [ ! -s "$BATS_TEST_TMPDIR/stderr" ]
  assert_writer_entry precompact
  assert_field 'Active command' ''
  assert_field 'Original request' ''
  assert_field 'Open questions' ''
  local next_step
  next_step=$(awk '/^### Next step$/ { found = 1; next } found && /^    / { print }' "$JOURNAL")
  [ -n "$next_step" ]
}

precompact_waits_for_lock() {
  precompact_fixture '{"next_step":"continue"}'
  hold_journal_lock
  (sleep 0.5; release_journal_lock) &
  local releaser=$!
  run writer_hook compaction-instructions
  wait "$releaser"
  assert_precompact_output
  [ ! -s "$BATS_TEST_TMPDIR/stderr" ]
  assert_writer_entry precompact
}

precompact_lock_timeout() {
  precompact_fixture '{}'
  hold_journal_lock
  run writer_hook compaction-instructions
  release_journal_lock
  assert_precompact_output
  [ "$(wc -l < "$BATS_TEST_TMPDIR/stderr")" -eq 1 ]
  [ ! -e "$JOURNAL" ]
}

pause_with_notes() {
  writer_fixture
  export CLAUDE_PLUGIN_ROOT="$PROJECT_ROOT" ARGUMENTS="$1"
  awk -F '`' '/Append journal/ { for (part = 2; part <= NF; part += 2) if ($part ~ /^bash /) print $part }' \
    "$PROJECT_ROOT/commands/pause.md" > "$BATS_TEST_TMPDIR/pause-command.sh"
  run bash "$BATS_TEST_TMPDIR/pause-command.sh"
  [ "$status" -eq 0 ]
  assert_writer_entry pause
  assert_field 'Original request' "$ARGUMENTS"
  [ ! -e "$PWD/notes-executed" ]
}

pause_empty_notes() { pause_with_notes ''; }
pause_literal_notes() { pause_with_notes 'quotes " and '\'' plus $(touch notes-executed) `touch notes-executed` ; & | < > $HOME'; }

phase_writer_fixture() {
  writer_fixture
  local artifact="${1:-VERIFICATION.md}" result="${2:-PASS}" phase="${3:-01-demo}" input
  mkdir -p "$LBWC_PLANNING_DIR/phases/$phase"
  printf -- '---\nresult: %s\n---\n' "$result" > "$LBWC_PLANNING_DIR/phases/$phase/$artifact"
  input=$(jq -nc --arg path "$LBWC_PLANNING_DIR/phases/$phase/$artifact" '{tool_input:{file_path:$path}}')
  printf -v WRITER_INPUT '%s' "$input"
}

wait_for_saved_completion() {
  local attempt
  for attempt in $(seq 1 100); do
    grep -q '^Status: complete$' "$LBWC_PLANNING_DIR/STATE.md" && return 0
    sleep 0.01
  done
  return 1
}

phase_completion_saves_before_journal() {
  phase_writer_fixture
  hold_journal_lock
  writer_hook state-updater &
  local updater=$!
  wait_for_saved_completion || { release_journal_lock; wait "$updater"; return 1; }
  [ ! -e "$JOURNAL" ] || { release_journal_lock; wait "$updater"; return 1; }
  release_journal_lock
  wait "$updater"
  [ ! -s "$BATS_TEST_TMPDIR/stderr" ]
  assert_writer_entry phase-end
}

phase_custom_directory() {
  export LBWC_PLANNING_DIR="$PWD/custom planning"
  mkdir -p "$LBWC_PLANNING_DIR/phases/01-demo"
  printf 'Phase: 1\nStatus: in_progress\nPlans: 0/1\nProgress: 0%%\n' > "$LBWC_PLANNING_DIR/STATE.md"
  printf '# Plan\n' > "$LBWC_PLANNING_DIR/phases/01-demo/PLAN.md"
  printf -- '---\nresult: PASS\n---\n' > "$LBWC_PLANNING_DIR/phases/01-demo/VERIFICATION.md"
  local input
  input=$(jq -nc --arg path "$LBWC_PLANNING_DIR/phases/01-demo/VERIFICATION.md" '{tool_input:{file_path:$path}}')
  printf -v WRITER_INPUT '%s' "$input"
  printf -v JOURNAL '%s' "$LBWC_PLANNING_DIR/EXPLORER-JOURNAL.md"
  unset LBWC_PLANNING_DIR
  run writer_hook state-updater
  [ "$status" -eq 0 ]
  assert_writer_entry phase-end
  grep -q '^Status: complete$' "$PWD/custom planning/STATE.md"
  [ ! -e "$PWD/.lbwc-planning/EXPLORER-JOURNAL.md" ]
}

phase_does_not_append() {
  phase_writer_fixture "$@"
  journal append --trigger pause --request 'existing history'
  cp "$JOURNAL" "$BATS_TEST_TMPDIR/before-journal"
  run writer_hook state-updater
  [ "$status" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/before-journal" "$JOURNAL"
}

phase_repeat_pass() {
  phase_writer_fixture
  printf 'Phase: 1\nStatus: complete\nPlans: 0/1\nProgress: 0%%\n' > "$LBWC_PLANNING_DIR/STATE.md"
  journal append --trigger phase-end
  cp "$JOURNAL" "$BATS_TEST_TMPDIR/before-journal"
  run writer_hook state-updater
  [ "$status" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/before-journal" "$JOURNAL"
}

phase_plan() { phase_does_not_append PLAN.md; }
phase_summary() { phase_does_not_append SUMMARY.md; }
phase_fail() { phase_does_not_append VERIFICATION.md FAIL; }
phase_partial() { phase_does_not_append VERIFICATION.md PARTIAL; }
phase_unknown() { phase_does_not_append VERIFICATION.md UNKNOWN; }
phase_other() { phase_does_not_append VERIFICATION.md PASS 02-other; }

phase_save_failure() {
  phase_writer_fixture
  cp "$LBWC_PLANNING_DIR/STATE.md" "$BATS_TEST_TMPDIR/before-state"
  chmod u-w "$LBWC_PLANNING_DIR"
  run writer_hook state-updater
  chmod u+w "$LBWC_PLANNING_DIR"
  [ "$status" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/before-state" "$LBWC_PLANNING_DIR/STATE.md"
  [ ! -e "$JOURNAL" ]
}

phase_journal_failure_keeps_completion() {
  phase_writer_fixture
  hold_journal_lock
  export LBWC_EXPLORER_JOURNAL_LOCK_TIMEOUT=0
  run writer_hook state-updater
  release_journal_lock
  [ "$status" -eq 0 ]
  grep -q '^Status: complete$' "$LBWC_PLANNING_DIR/STATE.md"
  [ "$(wc -l < "$BATS_TEST_TMPDIR/stderr")" -eq 1 ]
  [ ! -e "$JOURNAL" ]
}
