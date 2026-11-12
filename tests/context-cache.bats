#!/usr/bin/env bats

load test_helper
load gate_case_helper

build_workspace() {
  WS="${1:-$TEST_TEMP_DIR}"
  PLANNING="$WS/.meridian"
  PHASE_DIR="$PLANNING/phases/${2:-02-test-phase}"
  PLAN="$PHASE_DIR/02-01-PLAN.md"

  rm -rf "$PLANNING"
  mkdir -p "$PHASE_DIR"
  echo '{}' > "$PLANNING/config.json"
  printf '%s\n' '# Test Roadmap' '## Phase 2: Test Phase' '**Goal:** Test goal' \
    '**Success:** Tests pass' '**Reqs:** REQ-01' > "$PLANNING/ROADMAP.md"
  printf '%s\n' '---' 'phase: 2' 'plan: 1' 'title: "Test Plan"' 'wave: 1' 'depends_on: []' \
    'must_haves: ["test"]' '---' '# Test Plan' '## Tasks' '### Task 1: Test' \
    '- **Files:** test.sh' '- **Action:** Test' > "$PLAN"
}

setup() {
  setup_temp_dir
  build_workspace
  HASH_ENV=""
  RUN_FROM=""
}

teardown() {
  teardown_temp_dir
}

hash_for_role() {
  cd "${RUN_FROM:-$WS}" || return 1
  run env ${HASH_ENV:+"$HASH_ENV"} bash "$SCRIPTS_DIR/cache-context.sh" 02 "$1" "$PLANNING/config.json" "$PLAN"
  HASH=$(echo "$output" | cut -d' ' -f2)
  [ "$status" -eq 0 ]
}

case_fail() {
  echo "case=$1 $2" >&2
  echo "output=$output" >&2
}

create_nested_context_workspace() {
  NESTED_REPO_ROOT="$TEST_TEMP_DIR/mono"
  rm -rf "$NESTED_REPO_ROOT"
  build_workspace "$NESTED_REPO_ROOT/apps/proj"
  NESTED_WORKSPACE_ROOT="$WS"
}

create_alternate_context_workspace() {
  local saved_ws="$WS"
  build_workspace "$TEST_TEMP_DIR/alternate-workspace" 02-alt-phase
  ALT_PLANNING_DIR="$PLANNING"
  sed 's/Test goal/Alternate goal/' "$PLANNING/ROADMAP.md" > "$PLANNING/ROADMAP.new"
  mv "$PLANNING/ROADMAP.new" "$PLANNING/ROADMAP.md"
  build_workspace "$saved_ws"
}

init_test_repo() {
  git init -q
  git config user.name "MERIDIAN Test"
  git config user.email "meridian-tests@example.com"
}

mut_rerun() { :; }
mut_plan() { [ "$1" = v2 ] && echo "# Modified" >> "$PLAN"; return 0; }
mut_roadmap() { printf '%s\n' '## Phase 2: Test Phase' "**Goal:** Goal $1" '**Reqs:** REQ-01' > "$PLANNING/ROADMAP.md"; }
mut_milestone() { echo "# Milestone Context $1" > "$PLANNING/CONTEXT.md"; }
mut_requirements() { echo "- [REQ-01] Requirement $1" > "$PLANNING/REQUIREMENTS.md"; }
mut_state() { printf '# State\n\n## Key Decisions\n| Use API %s | | |\n' "$1" > "$PLANNING/STATE.md"; }
mut_conventions() { echo "{\"conventions\":[{\"tag\":\"STYLE\",\"rule\":\"Use $1\"}]}" > "$PLANNING/conventions.json"; }
mut_research() { printf '## Findings\n- %s\n' "$1" > "$PHASE_DIR/02-RESEARCH.md"; }
mut_delta() {
  printf '## Files Modified\n- sample.txt\n' > "$PHASE_DIR/02-01-SUMMARY.md"
  echo "$1" > "$WS/sample.txt"
}
mut_rolling_on() {
  jq '. + {"rolling_summary": true}' "$PLANNING/config.json" > "$PLANNING/config.tmp" && mv "$PLANNING/config.tmp" "$PLANNING/config.json"
  echo "# Rolling Context $1" > "$PLANNING/ROLLING-CONTEXT.md"
}
mut_rolling_off() {
  local unrelated_repo="$TEST_TEMP_DIR/unrelated-git"
  [ -d "$unrelated_repo" ] || setup_unrelated_git_repo "$unrelated_repo"
  RUN_FROM="$unrelated_repo"
  echo "# Rolling Context $1" > "$PLANNING/ROLLING-CONTEXT.md"
  [ "$1" = v1 ] || echo "modified" >> "$unrelated_repo/unrelated.txt"
}
mut_env_planning_dir() {
  create_alternate_context_workspace
  [ "$1" = v1 ] || HASH_ENV="MERIDIAN_PLANNING_DIR=$ALT_PLANNING_DIR"
  return 0
}

@test "cache-context fingerprints each role input and ignores unrelated state" {
  while IFS='|' read -r label role mutator expect root phase_name; do
    [ -n "$label" ] || continue
    build_workspace "$TEST_TEMP_DIR/$root" "$phase_name"
    HASH_ENV=""
    RUN_FROM=""

    "$mutator" v1
    hash_for_role "$role" || { case_fail "$label" "first hash failed status=$status"; return 1; }
    first_hash="$HASH"

    "$mutator" v2
    hash_for_role "$role" || { case_fail "$label" "second hash failed status=$status"; return 1; }

    if [ "$expect" = same ]; then
      [ "$first_hash" = "$HASH" ] || { case_fail "$label" "expected same hash, got $first_hash then $HASH"; return 1; }
    else
      [ "$first_hash" != "$HASH" ] || { case_fail "$label" "expected a changed hash, got $HASH twice"; return 1; }
    fi
  done <<'CASES'
identical-rerun|dev|mut_rerun|same|ws-a|02-test-phase
plan-edit|dev|mut_plan|differs|ws-b|02-test-phase
roadmap-edit|dev|mut_roadmap|differs|ws-c|02-test-phase
milestone-context-edit|dev|mut_milestone|differs|ws-d|02-test-phase
requirements-edit-lead|lead|mut_requirements|differs|ws-e|02-test-phase
state-edit-lead|lead|mut_state|differs|ws-f|02-test-phase
conventions-edit-dev|dev|mut_conventions|differs|ws-g|02-test-phase
conventions-edit-scout|scout|mut_conventions|differs|ws-h|02-test-phase
research-edit-dev|dev|mut_research|differs|ws-i|02-test-phase
research-edit-path-with-spaces|dev|mut_research|differs|space dir|02-test phase
delta-content-edit-same-file-list|dev|mut_delta|differs|ws-j|02-test-phase
rolling-context-edit-flag-on|dev|mut_rolling_on|differs|ws-k|02-test-phase
rolling-context-edit-flag-off-ambient-repo-dirty|dev|mut_rolling_off|same|ws-l|02-test-phase
explicit-paths-beat-conflicting-planning-dir|dev|mut_env_planning_dir|same|ws-m|02-test-phase
CASES
}

@test "cache-context follows the target repo off-root across committed changes and reports a hit only for a matching cache file" {
  while IFS='|' read -r label layout mutation expect; do
    [ -n "$label" ] || continue
    unrelated_repo="$TEST_TEMP_DIR/unrelated-git"
    rm -rf "$unrelated_repo"
    setup_unrelated_git_repo "$unrelated_repo"

    if [ "$layout" = flat ]; then
      build_workspace "$TEST_TEMP_DIR/flat-$label"
      repo_root="$WS"
      sample_path="$WS/sample.txt"
      cd "$repo_root" || return 1
      init_test_repo
      printf '# Summary\n## Files Modified\n- sample.txt\n## Deviations\n' > "$PHASE_DIR/02-01-SUMMARY.md"
      echo 'v1' > sample.txt
      git add -A
      git commit -qm 'init target repo'
    else
      create_nested_context_workspace
      repo_root="$NESTED_REPO_ROOT"
      sample_path="$NESTED_WORKSPACE_ROOT/sample.txt"
      cd "$repo_root" || return 1
      init_test_repo
      echo 'v1' > "$sample_path"
      git add -A
      git commit -qm 'init nested workspace'
    fi
    echo 'v2' > "$sample_path"
    git add -A
    git commit -qm 'update sample v2'

    RUN_FROM="$unrelated_repo"
    hash_for_role dev || { case_fail "$label" "first hash failed status=$status"; return 1; }
    first_hash="$HASH"

    cd "$repo_root" || return 1
    if [ "$mutation" = sample ]; then
      echo 'v3' > "$sample_path"
    else
      echo 'shared change' > "$repo_root/shared.txt"
    fi
    git add -A
    git commit -qm 'change after first hash'

    hash_for_role dev || { case_fail "$label" "second hash failed status=$status"; return 1; }

    if [ "$expect" = same ]; then
      [ "$first_hash" = "$HASH" ] || { case_fail "$label" "expected same hash, got $first_hash then $HASH"; return 1; }
    else
      [ "$first_hash" != "$HASH" ] || { case_fail "$label" "expected a changed hash, got $HASH twice"; return 1; }
    fi
  done <<'CASES'
flat-repo-committed-content|flat|sample|differs
nested-workspace-committed-content|nested|sample|differs
nested-workspace-sibling-noise|nested|sibling|same
CASES

  RUN_FROM=""
  while IFS='|' read -r label seed expected_status; do
    [ -n "$label" ] || continue
    build_workspace "$TEST_TEMP_DIR/hit-$label"
    hash_for_role dev || { case_fail "$label" "hash failed status=$status"; return 1; }
    if [ "$seed" = yes ]; then
      mkdir -p "$PLANNING/.cache/context"
      echo "# cached" > "$PLANNING/.cache/context/${HASH}.md"
    fi

    hash_for_role dev || { case_fail "$label" "rerun failed status=$status"; return 1; }
    echo "$output" | grep -q "^$expected_status " || { case_fail "$label" "expected status $expected_status"; return 1; }
  done <<'CASES'
no-cache-file|no|miss
matching-cache-file|yes|hit
CASES
}

compile_in_workspace() {
  run bash "$SCRIPTS_DIR/compile-context.sh" 02 "$1" .meridian/phases .meridian/phases/02-test-phase/02-01-PLAN.md
}

expect_context_has() {
  grep -qF -- "$3" "$PHASE_DIR/.context-$2.md" \
    || record_case_failure "$1" "context-$2 lacks [$3]"
}

expect_context_lacks() {
  run grep -qF -- "$3" "$PHASE_DIR/.context-$2.md"
  [ "$status" -eq 1 ] || record_case_failure "$1" "context-$2 holds [$3] grep status=$status"
}

@test "compile-context caches each role, refreshes the index, survives a corrupt index, and selects its inputs" {
  local index dev_entry first_stamp second_stamp label write_research expected_count heading_count finding_count
  reset_case_failures

  build_workspace "$TEST_TEMP_DIR/populate"
  cd "$WS" || return 1
  compile_in_workspace lead
  expect_case populate-lead 0
  compile_in_workspace dev
  expect_case populate-dev 0
  compile_in_workspace qa
  expect_case populate-qa 0
  index="$PLANNING/.cache/context-index.json"
  [ "$(ls "$PLANNING/.cache/context/" | wc -l | tr -d ' ')" -eq 3 ] || record_case_failure populate-files "expected 3 cache files"
  [ "$(jq '.entries | keys | length' "$index")" -eq 3 ] || record_case_failure populate-index "expected 3 index entries"
  dev_entry=$(jq -c '.entries | to_entries[] | select(.value.role == "dev") | .value' "$index")
  [ "$(echo "$dev_entry" | jq -r '.phase')" = "02" ] || record_case_failure populate-dev-entry "phase is not 02 entry=$dev_entry"
  [ "$(echo "$dev_entry" | jq 'has("path") and has("role") and has("phase") and has("timestamp")')" = "true" ] \
    || record_case_failure populate-dev-entry "entry lacks a key entry=$dev_entry"
  [ -f "$(echo "$dev_entry" | jq -r '.path')" ] || record_case_failure populate-dev-entry "entry path is missing"
  [ -n "$(echo "$dev_entry" | jq -r '.timestamp | select(. != null)')" ] || record_case_failure populate-dev-entry "entry timestamp is null"

  build_workspace "$TEST_TEMP_DIR/repeat"
  cd "$WS" || return 1
  compile_in_workspace lead
  expect_case repeat-first 0
  first_stamp=$(jq -r '.entries | to_entries[0].value.timestamp' "$PLANNING/.cache/context-index.json")
  # Timestamps have one-second resolution, so the repeat run must wait to differ
  sleep 1
  compile_in_workspace lead
  expect_case repeat-second 0
  second_stamp=$(jq -r '.entries | to_entries[0].value.timestamp' "$PLANNING/.cache/context-index.json")
  expect_context_has repeat-from-cache lead "Test goal"
  [ "$first_stamp" != "$second_stamp" ] || record_case_failure repeat-timestamp "timestamp stayed $first_stamp"

  build_workspace "$TEST_TEMP_DIR/corrupt-index"
  cd "$WS" || return 1
  mkdir -p "$PLANNING/.cache"
  echo "NOT VALID JSON{{{{" > "$PLANNING/.cache/context-index.json"
  compile_in_workspace dev
  expect_case corrupt-index 0
  [ -f "$PHASE_DIR/.context-dev.md" ] || record_case_failure corrupt-index "dev context missing"

  while IFS='|' read -r label write_research expected_count; do
    [ -n "$label" ] || continue
    build_workspace "$TEST_TEMP_DIR/research-$label"
    cd "$WS" || return 1
    [ "$write_research" = no ] || printf '## Findings\n- Test finding\n' > "$PHASE_DIR/02-RESEARCH.md"
    run bash "$SCRIPTS_DIR/compile-context.sh" 02 lead .meridian/phases
    expect_case "$label" 0
    heading_count=$(grep -c "Research Findings" "$PHASE_DIR/.context-lead.md" || true)
    finding_count=$(grep -c "Test finding" "$PHASE_DIR/.context-lead.md" || true)
    [ "$heading_count" -eq "$expected_count" ] || record_case_failure "$label" "heading count $heading_count, expected $expected_count"
    [ "$finding_count" -eq "$expected_count" ] || record_case_failure "$label" "finding count $finding_count, expected $expected_count"
  done <<'CASES'
with-research|yes|1
without-research|no|0
CASES

  build_workspace "$TEST_TEMP_DIR/legacy-decisions"
  cd "$WS" || return 1
  printf '%s\n' '# State' '' '## Decisions' '- Keep feature flags conservative' '' \
    '### skills' '**Installed:** foo, bar' '**Suggested:** baz' '' \
    '### Pending Todos' '- Migrate session store' > .meridian/STATE.md
  compile_in_workspace lead
  expect_case legacy-decisions 0
  expect_context_has legacy-decisions lead 'Keep feature flags conservative'
  expect_context_lacks legacy-decisions-strips-installed lead 'Installed:'
  expect_context_lacks legacy-decisions-strips-suggested lead 'Suggested:'
  expect_context_lacks legacy-decisions-strips-todos lead 'Migrate session store'

  build_workspace "$TEST_TEMP_DIR/explicit-paths"
  create_alternate_context_workspace
  cd "$WS" || return 1
  run env MERIDIAN_PLANNING_DIR="$ALT_PLANNING_DIR" \
    bash "$SCRIPTS_DIR/compile-context.sh" 02 lead .meridian/phases \
    .meridian/phases/02-test-phase/02-01-PLAN.md
  expect_case explicit-paths 0
  expect_context_has explicit-paths lead 'Test goal'
  expect_context_lacks explicit-paths-ignores-alternate lead 'Alternate goal'

  assert_no_case_failures
}

cache_input_rows() {
  local label role input expected first_hash second_hash
  cd "$TEST_TEMP_DIR" || return 1
  git init -q
  reset_case_failures
  printf '%s\n' '.meridian/' > .gitignore
  git -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -qm baseline
  await_git_ai
  mkdir -p "$PLANNING/codebase"
  while IFS='|' read -r label role input expected; do
    printf '%s\n' 'Initial map' > "$PLANNING/codebase/architecture.md"
    printf '%s\n' 'Initial research' > "$PHASE_DIR/02-RESEARCH.md"
    run bash "$SCRIPTS_DIR/cache-context.sh" 02 "$role"
    expect_case "$label-initial" 0
    first_hash="${output#* }"
    case "$input" in
      map) printf '%s\n' 'Changed map' > "$PLANNING/codebase/architecture.md" ;;
      research) printf '%s\n' 'Changed research' > "$PHASE_DIR/02-RESEARCH.md" ;;
    esac
    run bash "$SCRIPTS_DIR/cache-context.sh" 02 "$role"
    expect_case "$label-changed" 0
    second_hash="${output#* }"
    if [ "$expected" = different ]; then
      [ "$first_hash" != "$second_hash" ] || record_case_failure "$label" 'context edit did not invalidate hash'
    else
      [ "$first_hash" = "$second_hash" ] || record_case_failure "$label" 'unconsumed context invalidated hash'
    fi
  done
  assert_no_case_failures
}

@test "context cache invalidates discovered research and codebase inputs only for roles that consume them" {
  cache_input_rows <<'CASES'
dev-map|dev|map|different
qa-map|qa|map|different
lead-map|lead|map|different
scout-map|scout|map|same
dev-research|dev|research|different
qa-research|qa|research|same
CASES
}
