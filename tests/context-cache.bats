#!/usr/bin/env bats

load test_helper

build_workspace() {
  WS="${1:-$TEST_TEMP_DIR}"
  PLANNING="$WS/.lbwc-planning"
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
  git config user.name "LBWC Test"
  git config user.email "lbwc-tests@example.com"
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
  [ "$1" = v1 ] || HASH_ENV="LBWC_PLANNING_DIR=$ALT_PLANNING_DIR"
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

@test "cache-context follows the target repo off-root across committed changes" {
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
}

@test "cache-context reports hit only when a cache file matches the hash" {
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

@test "compile-context populates the cache and one index entry per role" {
  cd "$TEST_TEMP_DIR"
  run bash "$SCRIPTS_DIR/compile-context.sh" 02 lead .lbwc-planning/phases .lbwc-planning/phases/02-test-phase/02-01-PLAN.md
  [ "$status" -eq 0 ]
  run bash "$SCRIPTS_DIR/compile-context.sh" 02 dev .lbwc-planning/phases .lbwc-planning/phases/02-test-phase/02-01-PLAN.md
  [ "$status" -eq 0 ]
  run bash "$SCRIPTS_DIR/compile-context.sh" 02 qa .lbwc-planning/phases .lbwc-planning/phases/02-test-phase/02-01-PLAN.md
  [ "$status" -eq 0 ]

  index="$PLANNING/.cache/context-index.json"
  [ "$(ls "$PLANNING/.cache/context/" | wc -l | tr -d ' ')" -eq 3 ]
  [ "$(jq '.entries | keys | length' "$index")" -eq 3 ]

  dev_entry=$(jq -c '.entries | to_entries[] | select(.value.role == "dev") | .value' "$index")
  [ "$(echo "$dev_entry" | jq -r '.phase')" = "02" ]
  [ "$(echo "$dev_entry" | jq 'has("path") and has("role") and has("phase") and has("timestamp")')" = "true" ]
  [ -f "$(echo "$dev_entry" | jq -r '.path')" ]
  [ -n "$(echo "$dev_entry" | jq -r '.timestamp | select(. != null)')" ]
}

@test "compile-context serves a repeat run from cache and refreshes the index timestamp" {
  cd "$TEST_TEMP_DIR"
  run bash "$SCRIPTS_DIR/compile-context.sh" 02 lead .lbwc-planning/phases .lbwc-planning/phases/02-test-phase/02-01-PLAN.md
  [ "$status" -eq 0 ]
  first_stamp=$(jq -r '.entries | to_entries[0].value.timestamp' "$PLANNING/.cache/context-index.json")

  # Timestamps have one-second resolution, so the repeat run must wait to differ
  sleep 1

  run bash "$SCRIPTS_DIR/compile-context.sh" 02 lead .lbwc-planning/phases .lbwc-planning/phases/02-test-phase/02-01-PLAN.md
  [ "$status" -eq 0 ]
  second_stamp=$(jq -r '.entries | to_entries[0].value.timestamp' "$PLANNING/.cache/context-index.json")

  grep -q "Test goal" "$PHASE_DIR/.context-lead.md"
  [ "$first_stamp" != "$second_stamp" ]
}

@test "compile-context still compiles when the index file is corrupt" {
  cd "$TEST_TEMP_DIR"
  mkdir -p "$PLANNING/.cache"
  echo "NOT VALID JSON{{{{" > "$PLANNING/.cache/context-index.json"

  run bash "$SCRIPTS_DIR/compile-context.sh" 02 dev .lbwc-planning/phases .lbwc-planning/phases/02-test-phase/02-01-PLAN.md
  [ "$status" -eq 0 ]
  [ -f "$PHASE_DIR/.context-dev.md" ]
}

@test "compile-context includes research findings only when RESEARCH.md exists" {
  while IFS='|' read -r label write_research expected_count; do
    [ -n "$label" ] || continue
    build_workspace "$TEST_TEMP_DIR/research-$label"
    cd "$WS" || return 1
    [ "$write_research" = yes ] && printf '## Findings\n- Test finding\n' > "$PHASE_DIR/02-RESEARCH.md"

    run bash "$SCRIPTS_DIR/compile-context.sh" 02 lead .lbwc-planning/phases
    [ "$status" -eq 0 ] || { case_fail "$label" "compile failed status=$status"; return 1; }
    heading_count=$(grep -c "Research Findings" "$PHASE_DIR/.context-lead.md" || true)
    finding_count=$(grep -c "Test finding" "$PHASE_DIR/.context-lead.md" || true)
    [ "$heading_count" -eq "$expected_count" ] || { case_fail "$label" "heading count $heading_count, expected $expected_count"; return 1; }
    [ "$finding_count" -eq "$expected_count" ] || { case_fail "$label" "finding count $finding_count, expected $expected_count"; return 1; }
  done <<'CASES'
with-research|yes|1
without-research|no|0
CASES
}

@test "compile-context lead reads the legacy Decisions heading and strips skills and todos" {
  cd "$TEST_TEMP_DIR"
  printf '%s\n' '# State' '' '## Decisions' '- Keep feature flags conservative' '' \
    '### skills' '**Installed:** foo, bar' '**Suggested:** baz' '' \
    '### Pending Todos' '- Migrate session store' > .lbwc-planning/STATE.md

  run bash "$SCRIPTS_DIR/compile-context.sh" 02 lead .lbwc-planning/phases .lbwc-planning/phases/02-test-phase/02-01-PLAN.md
  [ "$status" -eq 0 ]
  grep -q 'Keep feature flags conservative' "$PHASE_DIR/.context-lead.md"
  ! grep -q 'Installed:' "$PHASE_DIR/.context-lead.md"
  ! grep -q 'Suggested:' "$PHASE_DIR/.context-lead.md"
  ! grep -q 'Migrate session store' "$PHASE_DIR/.context-lead.md"
}

@test "compile-context explicit phase and plan beat a conflicting LBWC_PLANNING_DIR" {
  create_alternate_context_workspace

  cd "$TEST_TEMP_DIR" || return 1
  run env LBWC_PLANNING_DIR="$ALT_PLANNING_DIR" \
    bash "$SCRIPTS_DIR/compile-context.sh" 02 lead .lbwc-planning/phases \
    .lbwc-planning/phases/02-test-phase/02-01-PLAN.md
  [ "$status" -eq 0 ]
  grep -q 'Test goal' "$PHASE_DIR/.context-lead.md"
  ! grep -q 'Alternate goal' "$PHASE_DIR/.context-lead.md"
}
