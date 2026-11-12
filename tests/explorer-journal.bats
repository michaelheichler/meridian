#!/usr/bin/env bats

load test_helper
load gate_case_helper
load isolated_case_helper
load journal_writers_helper

setup() {
  unset MERIDIAN_CONTROL_ROOT MERIDIAN_PROJECT_ROOT MERIDIAN_PLANNING_DIR
  export MERIDIAN_PLANNING_DIR="$BATS_TEST_TMPDIR/planning"
  mkdir -p "$MERIDIAN_PLANNING_DIR"
  JOURNAL="$MERIDIAN_PLANNING_DIR/EXPLORER-JOURNAL.md"
}

teardown() { await_git_ai; }

journal() {
  bash -x "$SCRIPTS_DIR/explorer-journal.sh" "$@" 2>> "$BATS_TEST_TMPDIR/trace"
}

assert_field() {
  local label="$1" expected="$2" actual
  actual=$(awk -v label="### $label" '
    /^### / { active = ($0 == label); next }
    active && /^    / { sub(/^    /, ""); print }
  ' "$JOURNAL")
  [ "$actual" = "$expected" ]
}

seed_entries() {
  local sequence
  for sequence in 1 2 3; do
    printf '## 2001-02-03T04:05:06Z pause\n\n### Original request\n\n    seed-%s\n' "$sequence"
    printf '    %02400d\n' 0
  done > "$JOURNAL"
}

archive_then_live() {
  cat "$MERIDIAN_PLANNING_DIR/journal-archive/"*.md "$JOURNAL"
}

rotation_preserves_order() {
  seed_entries
  cp "$JOURNAL" "$BATS_TEST_TMPDIR/before"
  journal append --trigger pause --request "newest $(printf '%01800d' 0)"
  journal current > "$BATS_TEST_TMPDIR/current"
  cat "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/current" > "$BATS_TEST_TMPDIR/expected"
  archive_then_live > "$BATS_TEST_TMPDIR/all"
  cmp "$BATS_TEST_TMPDIR/expected" "$BATS_TEST_TMPDIR/all"
  [ "$(grep -c '^## ' "$BATS_TEST_TMPDIR/all")" -eq 4 ]
  [ "$(grep -c '^## ' "$MERIDIAN_PLANNING_DIR/journal-archive/EXPLORER-JOURNAL-2001-02-03.md")" -gt 0 ]
  [ "$(wc -c < "$JOURNAL")" -lt 8192 ]
}

concurrent_rotation_preserves_requests() {
  local sequence worker
  local workers=()
  seed_entries
  for sequence in $(seq 1 20); do
    printf '    concurrent-%02d\n' "$sequence"
  done > "$BATS_TEST_TMPDIR/expected"
  for sequence in $(seq 1 20); do
    journal append --trigger phase-end --request "$(printf 'concurrent-%02d' "$sequence")" &
    workers+=("$!")
  done
  for worker in "${workers[@]}"; do
    wait "$worker" || return 1
  done
  archive_then_live > "$BATS_TEST_TMPDIR/all"
  grep '^    concurrent-' "$BATS_TEST_TMPDIR/all" | LC_ALL=C sort > "$BATS_TEST_TMPDIR/actual"
  cmp "$BATS_TEST_TMPDIR/expected" "$BATS_TEST_TMPDIR/actual"
  [ "$(grep -c '^## ' "$BATS_TEST_TMPDIR/all")" -eq 23 ]
  [ "$(wc -c < "$JOURNAL")" -lt 8192 ]
}

same_date_archive_accumulates() {
  seed_entries
  mkdir -p "$MERIDIAN_PLANNING_DIR/journal-archive"
  local archive="$MERIDIAN_PLANNING_DIR/journal-archive/EXPLORER-JOURNAL-2001-02-03.md"
  printf '## 2001-02-03T00:00:00Z pause\n    archived-earlier\n' > "$archive"
  cat "$archive" "$JOURNAL" > "$BATS_TEST_TMPDIR/before"
  journal append --trigger pause --request "latest $(printf '%01800d' 0)"
  journal current > "$BATS_TEST_TMPDIR/current"
  cat "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/current" > "$BATS_TEST_TMPDIR/expected"
  archive_then_live > "$BATS_TEST_TMPDIR/all"
  cmp "$BATS_TEST_TMPDIR/expected" "$BATS_TEST_TMPDIR/all"
}

oversized_newest_survives() {
  local payload
  payload=$(printf '%09000d' 0)
  journal append --trigger pause --request earlier
  journal current > "$BATS_TEST_TMPDIR/earlier"
  journal append --trigger pause --request "$payload"
  assert_field 'Original request' "$payload"
  [ "$(grep -c '^## ' "$JOURNAL")" -eq 1 ]
  [ "$(wc -c < "$JOURNAL")" -gt 8192 ]
  cat "$MERIDIAN_PLANNING_DIR/journal-archive/"*.md > "$BATS_TEST_TMPDIR/archive"
  cmp "$BATS_TEST_TMPDIR/earlier" "$BATS_TEST_TMPDIR/archive"
}

metadata_for_trigger() {
  local trigger="$1" branch head worktrees diff_stat stashes
  git config user.name 'Journal Test'
  git config user.email journal@example.invalid
  printf 'initial\n' > tracked
  git add tracked
  git commit -qm initial
  printf 'stashed\n' >> tracked
  git stash push -qm journal-fixture
  printf 'changed\n' >> tracked
  branch=$(git symbolic-ref --short HEAD)
  head=$(git rev-parse HEAD)
  worktrees=$(git worktree list)
  diff_stat=$(git diff --stat)
  stashes=$(git stash list)
  journal append --trigger "$trigger" --command 'inspect changes' --request 'retain context' \
    --questions 'what remains?' --next 'review results'
  grep -Eq "^## [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z $trigger$" "$JOURNAL"
  assert_field Branch "$branch"
  assert_field HEAD "$head"
  assert_field Worktrees "$worktrees"
  assert_field 'Diff stat' "$diff_stat"
  assert_field Stashes "$stashes"
  assert_field 'Active command' 'inspect changes'
  assert_field 'Original request' 'retain context'
  assert_field 'Open questions' 'what remains?'
  assert_field 'Next step' 'review results'
}

metadata_precompact() { metadata_for_trigger precompact; }
metadata_pause() { metadata_for_trigger pause; }
metadata_phase_end() { metadata_for_trigger phase-end; }

free_text_survives() {
  local text=$'first line\n\n## forged entry\n### Branch\n- [ ] café 日本語\n    indented'
  journal append --trigger pause --command "$text" --request "$text" --questions '' --next "$text"
  assert_field 'Active command' "$text"
  assert_field 'Original request' "$text"
  assert_field 'Open questions' ''
  assert_field 'Next step' "$text"
  [ "$(grep -c '^## ' "$JOURNAL")" -eq 1 ]
  journal current > "$BATS_TEST_TMPDIR/current"
  cmp "$JOURNAL" "$BATS_TEST_TMPDIR/current"
}

current_returns_newest() {
  journal append --trigger pause --request older
  journal append --trigger precompact --request newest
  sed -n '/^## .* precompact$/,$p' "$JOURNAL" > "$BATS_TEST_TMPDIR/expected"
  journal current > "$BATS_TEST_TMPDIR/current"
  cmp "$BATS_TEST_TMPDIR/expected" "$BATS_TEST_TMPDIR/current"
}

current_without_journal() {
  journal current > "$BATS_TEST_TMPDIR/current"
  [ ! -s "$BATS_TEST_TMPDIR/current" ]
  [ ! -e "$JOURNAL" ]
}

outside_git_has_unavailable_metadata() {
  mkdir -p "$BATS_TEST_TMPDIR/outside"
  cd "$BATS_TEST_TMPDIR/outside"
  journal append --trigger pause
  assert_field Branch unavailable
  assert_field HEAD unavailable
  assert_field Worktrees unavailable
  assert_field 'Diff stat' unavailable
  assert_field Stashes unavailable
}

planning_override() {
  journal append --trigger pause --request redirected
  journal current > "$BATS_TEST_TMPDIR/current"
  cmp "$JOURNAL" "$BATS_TEST_TMPDIR/current"
  [ ! -e .meridian/EXPLORER-JOURNAL.md ]
}

ancestor_discovery() {
  unset MERIDIAN_PLANNING_DIR
  mkdir -p .meridian nested/child
  printf '{}\n' > .meridian/config.json
  JOURNAL="$PWD/.meridian/EXPLORER-JOURNAL.md"
  cd nested/child
  journal append --trigger pause --request discovered
  journal current > "$BATS_TEST_TMPDIR/current"
  cmp "$JOURNAL" "$BATS_TEST_TMPDIR/current"
  assert_field 'Original request' discovered
  [ ! -e .meridian/EXPLORER-JOURNAL.md ]
}

held_lock_prevents_writes() {
  local lock="$MERIDIAN_PLANNING_DIR/.explorer-journal.lock"
  . "$SCRIPTS_DIR/lib/manifest-lock.sh"
  journal append --trigger pause --request original
  cp "$JOURNAL" "$BATS_TEST_TMPDIR/before"
  manifest_lock_acquire "$lock" EXPLORER_JOURNAL
  run env MERIDIAN_EXPLORER_JOURNAL_LOCK_TIMEOUT=0 bash -x "$SCRIPTS_DIR/explorer-journal.sh" append --trigger pause --request rejected
  manifest_lock_release "$lock"
  [ "$status" -ne 0 ]
  cmp "$BATS_TEST_TMPDIR/before" "$JOURNAL"
  [ ! -d "$MERIDIAN_PLANNING_DIR/journal-archive" ]
}

reject_arguments() {
  run journal "$@"
  [ "$status" -eq 2 ]
  grep -q '^Usage:' "$BATS_TEST_TMPDIR/trace"
  [ ! -e "$JOURNAL" ]
}

missing_subcommand() { reject_arguments; }
unknown_subcommand() { reject_arguments unknown; }
missing_trigger() { reject_arguments append; }
unsupported_trigger() { reject_arguments append --trigger unknown; }
unknown_flag() { reject_arguments append --trigger pause --unknown value; }
missing_value() { reject_arguments append --trigger pause --request; }
missing_trigger_value() { reject_arguments append --trigger; }
extra_current_argument() { reject_arguments current unexpected; }

@test "compaction and pause preserve recovery context without disrupting their caller" {
  run_scenario_cases precompact_retains_context precompact_without_context \
    precompact_waits_for_lock precompact_lock_timeout pause_empty_notes pause_literal_notes
}

@test "only a newly saved phase completion appends history and journal failure preserves completion" {
  run_scenario_cases phase_completion_saves_before_journal phase_custom_directory \
    phase_repeat_pass phase_plan phase_summary phase_fail phase_partial phase_unknown \
    phase_other phase_save_failure phase_journal_failure_keeps_completion
}

@test "journal rotation and concurrent writers preserve complete ordered history" {
  run_scenario_cases rotation_preserves_order concurrent_rotation_preserves_requests \
    same_date_archive_accumulates oversized_newest_survives
}

@test "journal entries retain metadata and free text and current returns the newest entry" {
  run_scenario_cases metadata_precompact metadata_pause metadata_phase_end free_text_survives \
    current_returns_newest current_without_journal outside_git_has_unavailable_metadata
}

@test "journal validates requests and respects storage discovery and held locks" {
  run_scenario_cases missing_subcommand unknown_subcommand missing_trigger unsupported_trigger \
    unknown_flag missing_value missing_trigger_value extra_current_argument \
    planning_override ancestor_discovery held_lock_prevents_writes
}
