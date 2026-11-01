#!/usr/bin/env bats

load gate_case_helper
load gate_case_files

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS_DIR="$REPO_ROOT/scripts"
  TEST_ROOT="$BATS_TEST_TMPDIR"
  reset_case_failures
}

fresh_dir() {
  local dir="$TEST_ROOT/$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

expect_exact_line() {
  local label=$1 file=$2 line=$3
  grep -Fxq -- "$line" "$file" 2>/dev/null \
    || record_case_failure "$label" "file=$file lacks exact line=[$line] content=$(cat "$file" 2>&1)"
}

expect_no_exact_line() {
  local label=$1 file=$2 line=$3
  ! grep -Fxq -- "$line" "$file" 2>/dev/null \
    || record_case_failure "$label" "file=$file has exact line=[$line]"
}

expect_exact_output() {
  local label=$1 want=$2
  [ "$output" = "$want" ] || record_case_failure "$label" "output=[$output] want=[$want]"
}

@test "bootstrap-project writes description and core value to the output path" {
  local dir project
  dir=$(fresh_dir project)

  project="$dir/.lbwc-planning/PROJECT.md"
  run bash "$SCRIPTS_DIR/bootstrap/bootstrap-project.sh" "$project" "Example Project" "Example description"
  expect_case "default-core-value" 0 ""
  expect_path "default-core-value-file" "$project"
  expect_exact_line "default-description" "$project" 'Example description'
  expect_exact_line "core-value-defaults-to-description" "$project" '**Core value:** Example description'

  project="$dir/custom/PROJECT.md"
  run bash "$SCRIPTS_DIR/bootstrap/bootstrap-project.sh" "$project" "Example Project" "Example description" "Ship safely"
  expect_case "explicit-core-value" 0 ""
  expect_exact_line "explicit-core-value-line" "$project" '**Core value:** Ship safely'

  run bash "$SCRIPTS_DIR/bootstrap/bootstrap-project.sh" "$dir/never/PROJECT.md" "Only name"
  expect_case "too-few-arguments" 1 "Usage: bootstrap-project.sh"
  expect_no_path "too-few-arguments-writes-nothing" "$dir/never"

  assert_no_case_failures
}

@test "bootstrap-state validates input and writes or merges the state file" {
  local dir state label count
  dir=$(fresh_dir state-reject)

  run bash "$SCRIPTS_DIR/bootstrap/bootstrap-state.sh" "$dir/STATE.md" "Proj" "Mile"
  expect_case "missing-phase-count" 1 "Usage: bootstrap-state.sh"

  while IFS='|' read -r label count; do
    [ -n "$label" ] || continue
    run bash "$SCRIPTS_DIR/bootstrap/bootstrap-state.sh" "$dir/$label/STATE.md" "Proj" "Mile" "$count"
    expect_case "$label" 1 "PHASE_COUNT must be a positive integer, got: '$count'"
    expect_no_path "$label-writes-nothing" "$dir/$label"
  done <<'CASES'
zero|0
negative|-2
text|abc
leading-zero|01
decimal|1.5
CASES

  dir=$(fresh_dir state-fresh)
  state="$dir/nested/STATE.md"

  run bash "$SCRIPTS_DIR/bootstrap/bootstrap-state.sh" "$state" "Demo App" "Launch" 3
  expect_case "fresh" 0 ""
  expect_exact_line "project" "$state" '**Project:** Demo App'
  expect_exact_line "milestone" "$state" '**Milestone:** Launch'
  expect_exact_line "current-phase" "$state" 'Phase: 1 of 3'
  expect_exact_line "first-phase-pending-planning" "$state" '- **Phase 1:** Pending planning'
  expect_exact_line "second-phase" "$state" '- **Phase 2:** Pending'
  expect_exact_line "third-phase" "$state" '- **Phase 3:** Pending'
  expect_no_exact_line "no-fourth-phase" "$state" '- **Phase 4:** Pending'
  expect_exact_line "empty-decisions" "$state" '| _(No decisions yet)_ | | |'
  expect_exact_line "decisions-header" "$state" '| Decision | Date | Rationale |'
  expect_exact_line "default-todos" "$state" 'None.'
  expect_exact_line "default-blockers" "$state" 'None'
  expect_no_exact_line "no-codebase-profile" "$state" '## Codebase Profile'
  expect_file_line "activity-log" "$state" "^- [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}: Created Launch milestone (3 phases)$"
  expect_jq "details-sidecar" "$dir/nested/todo-details.json" '.schema_version == 1 and (.items | length) == 0'

  dir=$(fresh_dir state-sidecar)
  printf '%s\n' '{"schema_version":1,"items":{"keep":{}}}' > "$dir/todo-details.json"

  run bash "$SCRIPTS_DIR/bootstrap/bootstrap-state.sh" "$dir/STATE.md" "Proj" "Mile" 1

  expect_case "sidecar" 0 ""
  expect_jq "sidecar-preserved" "$dir/todo-details.json" '.items.keep != null'

  dir=$(fresh_dir state-rerun)
  state="$dir/STATE.md"
  printf '%b' '# State\n\n## Key Decisions\n| Decision | Date | Rationale |\n|---|---|---|\n| Use bash | | |\n| Use bash | 2026-01-01 | simple |\n| _(No decisions yet)_ | | |\n- **Pick jq**\n- none\n\n## Todos\n- first todo\n- None\n* second todo\n\n## Blockers\nWaiting on review\n\n## Codebase Profile\nLanguage: bash\n\n## Activity Log\n- old entry\n' > "$state"

  run bash "$SCRIPTS_DIR/bootstrap/bootstrap-state.sh" "$state" "Demo" "Next" 2

  expect_case "rerun" 0 ""
  expect_exact_line "richer-duplicate-wins" "$state" '| Use bash | 2026-01-01 | simple |'
  expect_no_exact_line "poorer-duplicate-dropped" "$state" '| Use bash | | |'
  expect_exact_line "bullet-decision-becomes-row" "$state" '| **Pick jq** | | |'
  expect_no_exact_line "none-bullet-dropped" "$state" '| none | | |'
  expect_exact_line "todo-kept" "$state" '- first todo'
  expect_exact_line "star-todo-kept" "$state" '* second todo'
  expect_no_exact_line "none-todo-dropped" "$state" '- None'
  expect_exact_line "blockers-kept" "$state" 'Waiting on review'
  expect_exact_line "codebase-heading" "$state" '## Codebase Profile'
  expect_exact_line "codebase-kept" "$state" 'Language: bash'
  expect_no_exact_line "old-activity-dropped" "$state" '- old entry'

  dir=$(fresh_dir state-placeholders)
  state="$dir/STATE.md"
  printf '%b' '# State\n\n## Key Decisions\n| Decision | Date | Rationale |\n\n## Todos\n- None\n\n## Blockers\n\n## Codebase Profile\nNone.\n\n' > "$state"

  run bash "$SCRIPTS_DIR/bootstrap/bootstrap-state.sh" "$state" "Demo" "Next" 1

  expect_case "placeholders" 0 ""
  expect_exact_line "todos-reset" "$state" 'None.'
  expect_exact_line "blockers-reset" "$state" 'None'
  expect_exact_line "decisions-reset" "$state" '| _(No decisions yet)_ | | |'
  expect_no_exact_line "empty-codebase-dropped" "$state" '## Codebase Profile'

  dir=$(fresh_dir state-pending)
  state="$dir/STATE.md"
  printf '%b' '# State\n\n## Key Decisions\n| Pick | 2026 | why |\n### Skills\n- skill noise\n### Pending Todos\n- carried todo\n\n## Blockers\nNone\n' > "$state"

  run bash "$SCRIPTS_DIR/bootstrap/bootstrap-state.sh" "$state" "Demo" "Next" 1

  expect_case "pending-todos" 0 ""
  expect_exact_line "pending-todo-moved" "$state" '- carried todo'
  expect_exact_line "decision-kept" "$state" '| Pick | 2026 | why |'
  expect_no_exact_line "skills-noise-dropped" "$state" '- skill noise'
  assert_no_case_failures
}

@test "derive-milestone-slug derives, numbers and de-duplicates milestone slugs" {
  local dir plan suffix label roadmap state phases expected phase
  while IFS='|' read -r label roadmap state phases expected; do
    [ -n "$label" ] || continue
    dir=$(fresh_dir "slug-$label")
    mkdir -p "$dir/.lbwc-planning"
    printf '%b' "$roadmap" > "$dir/.lbwc-planning/ROADMAP.md"
    [ -z "$state" ] || printf '%b' "$state" > "$dir/.lbwc-planning/STATE.md"
    for phase in $phases; do
      mkdir -p "$dir/.lbwc-planning/phases/$phase"
    done
    run bash "$SCRIPTS_DIR/derive-milestone-slug.sh" "$dir/.lbwc-planning"
    expect_case "$label" 0 "$expected"
    expect_exact_output "$label" "$expected"
  done <<'CASES'
roadmap-phase-names|## Phase 1: Safer archives\n|||01-safer-archives
roadmap-first-three-phases|## Phase 1: One\n## Phase 2: Two\n## Phase 3: Three\n## Phase 4: Four\n|||01-one-two-three
roadmap-dash-punctuation|## Phase 1: Core \xE2\x80\x94 Setup\n## Phase 2: Docs & Tips!\n|||01-core-setup-docs-tips
state-milestone-wins|## Phase 1: Ignored\n|**Milestone:** Launch Day 2\n||01-launch-day-2
state-blank-milestone-falls-back|## Phase 1: Fallback\n|**Milestone:**   \n||01-fallback
numbered-list|1. **Alpha** - first\n2. Beta - second\n|||01-alpha-beta
bullet-list|- [ ] Phase 1: Gamma - x\n* [x] Delta\n|||01-gamma-delta
phase-directories|nothing to parse\n||01-first-phase 03-second-phase|01-first-phase-second-phase
long-names-truncate-at-word|## Phase 1: aaaaaaaaaaaaaaaaaaaa\n## Phase 2: bbbbbbbbbbbbbbbbbbbb\n## Phase 3: cccccccccccccccccccc\n|||01-aaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbbbbbb
CASES

  dir=$(fresh_dir slug-dated)
  mkdir -p "$dir/.lbwc-planning"
  printf '%s\n' 'prose only' > "$dir/.lbwc-planning/ROADMAP.md"

  run bash "$SCRIPTS_DIR/derive-milestone-slug.sh" "$dir/.lbwc-planning"

  expect_case "dated" 0 "01-milestone-$(date +%Y%m%d)"

  dir=$(fresh_dir slug-collide)
  plan="$dir/.lbwc-planning"
  mkdir -p "$plan/milestones/01-old" "$plan/milestones/02-other"
  printf '%s\n' '## Phase 1: Fresh work' > "$plan/ROADMAP.md"

  run bash "$SCRIPTS_DIR/derive-milestone-slug.sh" "$plan"
  expect_case "counts-existing-milestones" 0 "03-fresh-work"
  expect_exact_output "counts-existing-milestones-exact" "03-fresh-work"

  rm -rf "$plan/milestones"
  mkdir -p "$plan/milestones/02-fresh-work"
  run bash "$SCRIPTS_DIR/derive-milestone-slug.sh" "$plan"
  expect_case "colliding-name-gets-suffix" 0 "02-fresh-work-1"
  expect_exact_output "colliding-name-gets-suffix-exact" "02-fresh-work-1"


  dir=$(fresh_dir slug-fail)
  plan="$dir/.lbwc-planning"
  mkdir -p "$plan"

  run bash "$SCRIPTS_DIR/derive-milestone-slug.sh" "$plan"
  expect_case "missing-roadmap" 1 "ROADMAP.md not found at $plan/ROADMAP.md"

  printf '%s\n' '## Phase 1: Busy' > "$plan/ROADMAP.md"
  mkdir -p "$plan/milestones/12-busy"
  suffix=1
  while [ "$suffix" -le 10 ]; do
    mkdir -p "$plan/milestones/12-busy-$suffix"
    suffix=$((suffix + 1))
  done

  run bash "$SCRIPTS_DIR/derive-milestone-slug.sh" "$plan"
  expect_case "exhausted-suffixes" 1 "cannot find unique slug (tried 12-busy through 12-busy-10)"

  assert_no_case_failures
}

write_phase_detect_stub() {
  local dir=$1 kv=$2
  cp "$SCRIPTS_DIR/archive-uat-guard.sh" "$dir/archive-uat-guard.sh"
  { echo '#!/usr/bin/env bash'; echo "printf '%s\\n' $kv"; } > "$dir/phase-detect.sh"
}

@test "archive-uat-guard allows archiving when no UAT work is pending" {
  local dir label kv
  while IFS='|' read -r label kv; do
    [ -n "$label" ] || continue
    dir=$(fresh_dir "guard-ok-$label")
    write_phase_detect_stub "$dir" "$kv"
    run bash "$dir/archive-uat-guard.sh"
    expect_case_silent "$label" 0
  done <<'CASES'
clean|phase_detect_complete=true planning_dir_exists=true project_exists=true uat_issues_phase=none uat_blocking_phase=none milestone_uat_issues=false
no-planning-dir|phase_detect_complete=true planning_dir_exists=false project_exists=true uat_issues_phase=01
no-project|phase_detect_complete=true planning_dir_exists=true project_exists=false uat_issues_phase=01
CASES

  assert_no_case_failures
}

@test "archive-uat-guard blocks archiving with exit 2 and a reason" {
  local dir label kv fragment
  local common='phase_detect_complete=true planning_dir_exists=true project_exists=true'
  while IFS='|' read -r label kv fragment; do
    [ -n "$label" ] || continue
    dir=$(fresh_dir "guard-block-$label")
    case "$kv" in
      @*) kv="$common ${kv#@}" ;;
    esac
    write_phase_detect_stub "$dir" "$kv"
    run bash "$dir/archive-uat-guard.sh"
    expect_case "$label" 2 "$fragment"
  done <<'CASES'
phase-detect-error|phase_detect_error=true|Archive blocked: phase detection failed
phase-detect-incomplete|phase_detect_complete=false|Archive blocked: phase detection failed
phase-detect-empty||Archive blocked: phase detection failed
active-phase-issues|@uat_issues_phase=01 uat_blocking_phase=none milestone_uat_issues=false|unresolved active-phase UAT issues in Phase 01
blocking-issues-found|@uat_issues_phase=none uat_blocking_phase=02 uat_blocking_status=issues_found|unresolved active-phase UAT issues in Phase 02
blocking-in-progress|@uat_issues_phase=none uat_blocking_phase=02 uat_blocking_status=active|active-phase UAT is still in progress for Phase 02
blocking-status-unset|@uat_issues_phase=none uat_blocking_phase=03|active-phase UAT is still in progress for Phase 03
milestone-issues-located|@uat_issues_phase=none uat_blocking_phase=none milestone_uat_issues=true milestone_uat_slug=v1 milestone_uat_phase=04|unresolved milestone UAT issues in v1 Phase 04
milestone-issues-unlocated|@uat_issues_phase=none uat_blocking_phase=none milestone_uat_issues=true|unresolved milestone UAT issues detected
CASES

  assert_no_case_failures
}

@test "normalize-plan-filenames renames bare plans and keeps existing destinations" {
  local phase="$TEST_ROOT/.lbwc-planning/phases/01-bootstrap"
  mkdir -p "$phase"
  printf '%s\n' '# Existing' > "$phase/01-PLAN.md"
  printf '%s\n' '# Source' > "$phase/PLAN-1.md"
  printf '%s\n' '# Fresh' > "$phase/PLAN-2.md"

  run bash "$SCRIPTS_DIR/normalize-plan-filenames.sh" "$phase"

  expect_case "normalize" 0 "renamed: PLAN-2.md -> 02-PLAN.md"
  expect_output_has "normalize-skip-notice" "skipped: PLAN-1.md (target 01-PLAN.md already exists)"
  expect_path "source-kept" "$phase/PLAN-1.md"
  expect_exact_line "destination-intact" "$phase/01-PLAN.md" '# Existing'
  expect_exact_line "renamed-content" "$phase/02-PLAN.md" '# Fresh'
  expect_no_path "renamed-source-gone" "$phase/PLAN-2.md"
  assert_no_case_failures
}

@test "migrate-config writes an LBWC configuration version" {
  local dir config
  dir=$(fresh_dir migrate)
  config="$dir/.lbwc-planning/config.json"
  mkdir -p "$dir/.lbwc-planning"
  printf '%s\n' '{"config_version":1}' > "$config"

  run bash "$SCRIPTS_DIR/migrate-config.sh" "$config"

  expect_case "migrate" 0 ""
  expect_jq "version-at-least-one" "$config" '.config_version >= 1'
  assert_no_case_failures
}

@test "suggest-next uses LBWC command names" {
  local dir
  dir=$(fresh_dir suggest)
  mkdir -p "$dir/.lbwc-planning"

  run env LBWC_PLANNING_DIR="$dir/.lbwc-planning" bash "$SCRIPTS_DIR/suggest-next.sh"

  expect_case "suggest" 0 "/lbwc:"
  assert_no_case_failures
}
