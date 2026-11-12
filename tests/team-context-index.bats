#!/usr/bin/env bats

load test_helper
load gate_case_helper

setup() {
  setup_temp_dir
  SCRIPT="$SCRIPTS_DIR/team-context-index.sh"
  reset_case_failures
}

teardown() {
  teardown_temp_dir
}

fresh_project() {
  ROW_DIR="$TEST_TEMP_DIR/$1"
  PROJECT_DIR="$ROW_DIR/project"
  RUN_DIR="$PROJECT_DIR/.temporary-agent-runfiles/runs/run-1"
  mkdir -p "$PROJECT_DIR" "$RUN_DIR"
}

run_index() {
  run bash "$SCRIPT" --project-root "$PROJECT_DIR" --run-root "$RUN_DIR" "$@"
}

run_index_with_home() {
  run env HOME="$1" bash "$SCRIPT" --project-root "$PROJECT_DIR" --run-root "$RUN_DIR"
}

expect_index() {
  local label=$1 file=$2
  shift 2
  jq -e "$@" "$file" >/dev/null 2>&1 \
    || record_case_failure "$label" "index check failed file=$file content=$(cat "$file" 2>&1)"
}

write_settings_with_plans() {
  mkdir -p "$1"
  printf '%s\n' '# Claude plan' > "$1/plan.md"
  jq -n --arg plans "$1" '{plansDirectory: $plans}' > "$ROW_DIR/settings.json"
}

@test "team-context-index selects plans by authority, keeps injected text inert, and digests indexes without creating planning state" {
  local explicit marker digest map_digest

  fresh_project explicit
  mkdir -p "$PROJECT_DIR/.planning/phases"
  printf '%s\n' '# GSD plan' > "$PROJECT_DIR/.planning/phases/01-PLAN.md"
  printf '%s\n' '# Generic plan' > "$PROJECT_DIR/generic.md"
  explicit="$ROW_DIR/explicit.md"
  marker="$ROW_DIR/injection-marker"
  printf '%s\n' '# Explicit plan' > "$explicit"
  run_index --plan "$explicit" --instruction "Use this text \$(touch '$marker')"
  expect_case explicit-plan-and-instruction 0 ""
  [ ! -e "$marker" ] || record_case_failure explicit-instruction-not-executed "marker exists"
  expect_index explicit-selection "$RUN_DIR/plan-index.json" \
    --arg path "$(cd "$(dirname "$explicit")" && pwd -P)/$(basename "$explicit")" \
    '(.selection.status == "explicit") and
     (.selection.authority == "explicit-plan-and-instruction") and
     (.selection.selected_plan.canonical_path == $path) and
     (.request.instruction | contains("$(touch"))'

  fresh_project no-instruction
  printf '%s\n' '# Older plan' > "$PROJECT_DIR/older.md"
  printf '%s\n' '# Newer plan' > "$PROJECT_DIR/newer.md"
  touch -t 202601010101 "$PROJECT_DIR/older.md"
  touch -t 202602020202 "$PROJECT_DIR/newer.md"
  run_index
  expect_case no-instruction 0 ""
  expect_index no-instruction-needs-user-selection "$RUN_DIR/plan-index.json" '
    (.selection.status == "needs-user-selection") and
    (.selection.selected_plan == null) and
    ((.selection.display_candidates | length) == 2) and
    (.selection.display_candidates[0].canonical_path | endswith("/newer.md")) and
    (.selection.display_candidates[1].canonical_path | endswith("/older.md"))'

  fresh_project prompt-injection
  marker="$ROW_DIR/prompt-marker"
  printf '%s\n' '# $(touch '"$marker"')' '!`touch '"$marker"'`' > "$PROJECT_DIR/plan.md"
  run_index
  expect_case prompt-injection 0 ""
  [ ! -e "$marker" ] || record_case_failure prompt-injection-not-executed "marker exists"
  expect_index prompt-injection-title-kept "$RUN_DIR/plan-index.json" --arg marker "$marker" \
    '.candidates[0].title | contains("$(touch") and contains($marker)'

  fresh_project no-planning-dir
  printf '%s\n' '# Plan' > "$PROJECT_DIR/plan.md"
  run_index
  expect_case no-planning-dir 0 ""
  [ ! -d "$PROJECT_DIR/.meridian" ] || record_case_failure no-planning-dir-created ".meridian exists"
  [ -f "$RUN_DIR/plan-index.json" ] || record_case_failure no-planning-dir-plan-index "plan-index.json missing"
  [ -f "$RUN_DIR/codebase-index.json" ] || record_case_failure no-planning-dir-codebase-index "codebase-index.json missing"

  fresh_project digests
  printf '%s\n' '# Digest me' > "$PROJECT_DIR/plan.md"
  mkdir -p "$PROJECT_DIR/.meridian/codebase"
  printf '%s\n' \
    'mapped_at: 2026-01-01T00:00:00Z' \
    'git_hash: 0000000000000000000000000000000000000000' \
    'file_count: 1' \
    > "$PROJECT_DIR/.meridian/codebase/META.md"
  printf '%s\n' '# Stack' > "$PROJECT_DIR/.meridian/codebase/STACK.md"
  run_index
  expect_case digests 0 ""
  digest=$(shasum -a 256 "$PROJECT_DIR/plan.md" | awk '{print $1}')
  map_digest=$(shasum -a 256 "$PROJECT_DIR/.meridian/codebase/META.md" | awk '{print $1}')
  expect_index digests-plan-path-and-digest "$RUN_DIR/plan-index.json" \
    --arg path "$(cd "$PROJECT_DIR" && pwd -P)/plan.md" --arg digest "sha256:$digest" \
    '.candidates[0].canonical_path == $path and .candidates[0].digest == $digest'
  expect_index digests-stale-codebase-map "$RUN_DIR/codebase-index.json" \
    --arg path "$(cd "$PROJECT_DIR/.meridian/codebase" && pwd -P)/META.md" --arg digest "sha256:$map_digest" \
    '.artifacts | any(.canonical_path == $path and .digest == $digest and .freshness == "stale")'

  assert_no_case_failures
}

@test "team-context-index tiers adapter, generic and Claude plan candidates and applies every cap" {
  local n plans_dir claude_home

  fresh_project gsd-and-generic-cap
  mkdir -p "$PROJECT_DIR/.planning/phases"
  printf '%s\n' '---' 'title: GSD work' '---' '# GSD work' > "$PROJECT_DIR/.planning/phases/01-01-PLAN.md"
  for n in $(seq 1 70); do
    printf '# Generic %s\n' "$n" > "$PROJECT_DIR/generic-$n.md"
  done
  run_index
  expect_case gsd-and-generic-cap 0 ""
  expect_index gsd-verified-generic-capped "$RUN_DIR/plan-index.json" '
    .caps.generic_max_files == 64 and
    ([.candidates[] | select(.source_system == "gsd" and .trust_tier == "verified-adapter")] | length) == 1 and
    ([.candidates[] | select(.source_system == "markdown" and .trust_tier == "unverified-markdown")] | length) == 64'

  fresh_project oversized
  dd if=/dev/zero of="$PROJECT_DIR/oversized.md" bs=1048577 count=1 2>/dev/null
  printf '%s\n' '# Small plan' > "$PROJECT_DIR/small.md"
  run_index
  expect_case oversized 0 ""
  expect_index oversized-skipped "$RUN_DIR/plan-index.json" '
    .caps.max_file_bytes == 1048576 and
    ([.candidates[] | select(.canonical_path | endswith("/oversized.md"))] | length) == 0 and
    ([.candidates[] | select(.canonical_path | endswith("/small.md"))] | length) == 1'

  fresh_project configured-plans
  plans_dir="$ROW_DIR/claude-plans"
  write_settings_with_plans "$plans_dir"
  run_index --settings "$ROW_DIR/settings.json"
  expect_case configured-plans 0 ""
  expect_index configured-plans-fallback-tier "$RUN_DIR/plan-index.json" --arg path "$(cd "$plans_dir" && pwd -P)/plan.md" '
    .candidates[0].source_system == "claude-code" and
    .candidates[0].precedence_tier == 5 and
    .candidates[0].canonical_path == $path and
    .candidates[0].trust_tier == "unverified-markdown"'

  fresh_project configured-plans-inside-project
  write_settings_with_plans "$PROJECT_DIR/custom-plans"
  run_index --settings "$ROW_DIR/settings.json"
  expect_case configured-plans-inside-project 0 ""
  expect_index configured-plans-inside-project-once "$RUN_DIR/plan-index.json" '
    ([.candidates[] | select(.canonical_path | endswith("/custom-plans/plan.md"))] | length) == 1 and
    ([.candidates[] | select(.canonical_path | endswith("/custom-plans/plan.md"))][0].precedence_tier) == 5'

  fresh_project default-plans
  claude_home="$ROW_DIR/home"
  plans_dir="$claude_home/.claude/plans"
  mkdir -p "$plans_dir"
  printf '%s\n' '# Fallback plan' > "$plans_dir/plan.md"
  run_index_with_home "$claude_home"
  expect_case default-plans 0 ""
  expect_index default-plans-fallback "$RUN_DIR/plan-index.json" --arg path "$(cd "$plans_dir" && pwd -P)/plan.md" \
    '(.candidates[0].canonical_path == $path) and
     (.candidates[0].detection_evidence | any(. == "default Claude Code plans directory"))'

  fresh_project default-plans-cap
  claude_home="$ROW_DIR/home"
  plans_dir="$claude_home/.claude/plans"
  mkdir -p "$plans_dir"
  for n in $(seq 1 20); do
    printf '# Claude %s\n' "$n" > "$plans_dir/plan-$n.md"
    touch -t "202601$(printf '%02d' "$n")0101" "$plans_dir/plan-$n.md"
  done
  run_index_with_home "$claude_home"
  expect_case default-plans-cap 0 ""
  expect_index default-plans-capped-newest-first "$RUN_DIR/plan-index.json" '
    ([.candidates[] | select(.source_system == "claude-code")] | length) == 16 and
    ([.candidates[] | select(.source_system == "claude-code")][0].canonical_path | endswith("/plan-20.md"))'

  assert_no_case_failures
}
