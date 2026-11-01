#!/usr/bin/env bats

load gate_case_helper

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/lbwc-conventions.sh"
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lbwc-conventions.XXXXXX")"
  PROJECT_DIR="$TEST_ROOT/project"
  PLANNING_DIR="$PROJECT_DIR/.lbwc-planning"
  ARTIFACT="$PLANNING_DIR/conventions.json"
  mkdir -p "$PLANNING_DIR/codebase"
  reset_case_failures
}

teardown() {
  rm -rf "$TEST_ROOT"
}

run_conventions() {
  run bash "$SCRIPT" "$@"
}

reset_planning() {
  rm -rf "$PLANNING_DIR"
  mkdir -p "$PLANNING_DIR/codebase"
}

write_candidates() {
  local path="$1"
  shift
  jq -n --argjson conventions "$1" '{schema_version: 1, conventions: $conventions}' > "$path"
}

artifact_digest() {
  shasum -a 256 "$ARTIFACT"
}

seed_convention() {
  run_conventions add "$PLANNING_DIR" "$1" "$2"
  expect_case "seed-$2" 0
}

expect_count() {
  local label="$1" want="$2" got
  got=$(jq '.conventions | length' "$ARTIFACT")
  [ "$got" = "$want" ] || record_case_failure "$label" "expected $want conventions, got $got"
}

expect_exact_output() {
  local label="$1" want="$2"
  [ "$output" = "$want" ] || record_case_failure "$label" "expected output=[$want] got=[$output]"
}

expect_artifact_jq() {
  local label="$1" program="$2"
  jq -e "$program" "$ARTIFACT" >/dev/null || record_case_failure "$label" "artifact did not satisfy: $program"
}

@test "add records user conventions and honours an explicit conflict resolution" {
  run_conventions --json add "$PLANNING_DIR" naming "Components use PascalCase"
  expect_case add-json 0
  expect_artifact_jq add-projection '.conventions == [{
    added: (.conventions[0].added),
    category: "naming",
    confidence: null,
    detected_from: null,
    id: "CONV-001",
    rule: "Components use PascalCase",
    source: "user-defined",
    tag: "NAMING"
  }] and (.conventions[0].added | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))'

  reset_planning
  run_conventions add "$PLANNING_DIR" style "Use formatter"
  expect_case human-success 0
  [[ "$output" == *$'\nNext: continue your current LBWC workflow.' ]] \
    || record_case_failure human-success "output does not end with next guidance: $output"

  reset_planning
  seed_convention style "Use tabs for indentation"
  run_conventions add "$PLANNING_DIR" style "Use spaces for indentation" --conflicts-with CONV-001 --keep-both
  expect_case keep-both 0
  expect_count keep-both 2

  reset_planning
  seed_convention tooling "Use npm"
  run_conventions add "$PLANNING_DIR" tooling "Use pnpm" --conflicts-with CONV-001 --replace CONV-001
  expect_case replace-selected 0
  expect_count replace-selected 1
  expect_artifact_jq replace-selected '.conventions[0].rule == "Use pnpm" and .conventions[0].source == "user-defined"'

  assert_no_case_failures
}

add_rejected_row() {
  local label="$1" want_status="$2" fragment="$3" before
  shift 3
  before=$(artifact_digest)
  run_conventions add "$PLANNING_DIR" "$@"
  expect_case "$label" "$want_status" "$fragment"
  [ "$(artifact_digest)" = "$before" ] || record_case_failure "$label" "artifact changed"
}

@test "add rejects invalid input and leaves the convention state untouched" {
  local target="$TEST_ROOT/target.json" before

  seed_convention naming "Components use PascalCase"
  add_rejected_row multiline-rule 2 "convention rule must be one non-empty line" style $'Use formatter\nUse linter'
  expect_exact_output multiline-rule "Error: convention rule must be one non-empty line"
  add_rejected_row redundant-rule 3 "redundant with CONV-001" naming "  components   USE pascalcase  "

  reset_planning
  seed_convention style "Use tabs for indentation"
  add_rejected_row unresolved-conflict 4 "conflict with CONV-001 requires --replace or --keep-both" \
    style "Use spaces for indentation" --conflicts-with CONV-001
  expect_count unresolved-conflict 1

  reset_planning
  printf '%s\n' '{"conventions":"wrong"}' > "$ARTIFACT"
  add_rejected_row malformed-artifact 2 "" style "Use formatter"

  reset_planning
  printf '%s\n' '{"protected":true}' > "$target"
  ln -s "$target" "$ARTIFACT"
  run_conventions add "$PLANNING_DIR" other "Keep this rule"
  expect_case symbolic-artifact 2
  [ "$(jq -r '.protected' "$target")" = true ] || record_case_failure symbolic-artifact "target was rewritten"
  [ -L "$ARTIFACT" ] || record_case_failure symbolic-artifact "symbolic link was replaced"

  reset_planning
  mkdir "$PLANNING_DIR/.conventions.lock"
  run_conventions add "$PLANNING_DIR" style "Use formatter"
  expect_case failed-lock-acquisition 2 "could not acquire conventions lock"
  [ -d "$PLANNING_DIR/.conventions.lock" ] || record_case_failure failed-lock-acquisition "foreign lock was removed"
  [ ! -e "$ARTIFACT" ] || record_case_failure failed-lock-acquisition "artifact was written"

  assert_no_case_failures
}

@test "remove requires confirmation and removes only the selected id" {
  seed_convention testing "Run unit tests"
  seed_convention style "Format before commit"

  run_conventions remove "$PLANNING_DIR" CONV-001
  expect_case remove-without-confirmation 4
  expect_count remove-without-confirmation 2

  run_conventions remove "$PLANNING_DIR" CONV-001 --yes
  expect_case remove-confirmed 0
  [ "$(jq -r '.conventions[].id' "$ARTIFACT")" = "CONV-002" ] \
    || record_case_failure remove-confirmed "unexpected remaining ids"

  assert_no_case_failures
}

@test "list and group emit stable JSON and migrate legacy entries" {
  run_conventions --json list "$PLANNING_DIR"
  expect_case empty-list 0
  expect_exact_output empty-list '{"conventions":[],"schema_version":1}'
  [ ! -e "$ARTIFACT" ] || record_case_failure empty-list "list created the artifact"

  seed_convention testing "Tests use Bats"
  seed_convention naming "Shell functions use snake_case"
  run_conventions --json group "$PLANNING_DIR"
  expect_case group-order 0
  expect_exact_output group-order \
    "$(jq -cS '{naming: [.conventions[1]], testing: [.conventions[0]]}' "$ARTIFACT")"

  reset_planning
  printf '%s\n' '{"conventions":[{"tag":"STYLE","rule":"Use formatter"}]}' > "$ARTIFACT"
  run_conventions --json list "$PLANNING_DIR"
  expect_case legacy-migration 0
  [ "$(jq -r '.conventions[0] | [.tag, .rule, .source, .category] | @tsv' <<< "$output")" = $'STYLE\tUse formatter\tuser-defined\tstyle' ] \
    || record_case_failure legacy-migration "unexpected migrated entry: $output"

  assert_no_case_failures
}

@test "refresh and reconcile apply detected candidates without losing user conventions" {
  local candidates="$TEST_ROOT/candidates.json" before first second

  seed_convention naming "Components use PascalCase"
  write_candidates "$candidates" '[
    {"rule":"Tests live beside source files","category":"testing","confidence":"high","detected_from":"PATTERNS.md"}
  ]'
  run_conventions refresh "$PLANNING_DIR" "$candidates"
  expect_case refresh-first-detection 0
  write_candidates "$candidates" '[
    {"rule":"components use pascalcase","category":"naming","confidence":"high","detected_from":"ARCHITECTURE.md"},
    {"rule":"Use shellcheck for shell scripts","category":"tooling","confidence":"medium","detected_from":"CONCERNS.md"}
  ]'
  run_conventions refresh "$PLANNING_DIR" "$candidates"
  expect_case refresh-replaces-stale 0
  expect_count refresh-replaces-stale 2
  expect_artifact_jq refresh-replaces-stale '
    (.conventions[] | select(.source == "user-defined") | .rule) == "Components use PascalCase"
    and (.conventions[] | select(.source == "auto-detected") | .rule) == "Use shellcheck for shell scripts"
    and (.conventions | any(.rule == "Tests live beside source files") | not)
  '

  reset_planning
  seed_convention tooling "Use pnpm"
  write_candidates "$candidates" '[
    {"rule":"Use npm","category":"tooling","confidence":"high","detected_from":"STACK.md","conflicts_with":["CONV-001"]}
  ]'
  run_conventions refresh "$PLANNING_DIR" "$candidates"
  expect_case refresh-drops-conflicting 0
  expect_count refresh-drops-conflicting 1
  expect_artifact_jq refresh-drops-conflicting '.conventions[0].rule == "Use pnpm"'

  reset_planning
  write_candidates "$candidates" '[
    {"rule":"B rule","category":"style","confidence":"medium","detected_from":"PATTERNS.md"},
    {"rule":"A rule","category":"naming","confidence":"high","detected_from":"ARCHITECTURE.md"}
  ]'
  run_conventions refresh "$PLANNING_DIR" "$candidates"
  expect_case stable-first-refresh 0
  first="$(bash "$SCRIPT" --json list "$PLANNING_DIR")"
  run_conventions refresh "$PLANNING_DIR" "$candidates"
  expect_case stable-second-refresh 0
  second="$(bash "$SCRIPT" --json list "$PLANNING_DIR")"
  [ "$first" = "$second" ] || record_case_failure stable-json "repeated refresh changed the artifact"

  reset_planning
  seed_convention naming "Components use PascalCase"
  write_candidates "$candidates" '[
    {"rule":"Tests use Bats","category":"testing","confidence":"high","detected_from":"PATTERNS.md"}
  ]'
  run_conventions refresh "$PLANNING_DIR" "$candidates"
  expect_case human-refresh-output 0 "Added: 1 | Updated: 0 | Removed: 0 | Kept: 1"
  [[ "$output" == *"ID"*"Category"*"Source"*"Confidence"*"Rule"* ]] \
    || record_case_failure human-refresh-output "table header missing: $output"

  reset_planning
  seed_convention patterns "Services use repository objects"
  before="$(artifact_digest)"
  write_candidates "$candidates" '[
    {"rule":"HTTP handlers are thin","category":"patterns","confidence":"high","detected_from":"ARCHITECTURE.md"}
  ]'
  run_conventions --json reconcile "$PLANNING_DIR" "$candidates"
  expect_case reconcile-preview 0
  [ "$(jq -r '.conventions | length' <<< "$output")" -eq 2 ] \
    || record_case_failure reconcile-preview "preview does not hold both conventions"
  [ "$(artifact_digest)" = "$before" ] || record_case_failure reconcile-preview "preview mutated the artifact"

  assert_no_case_failures
}

@test "refresh and list reject malformed candidates and artifacts atomically" {
  local before

  seed_convention testing "Tests use fixtures"
  before="$(artifact_digest)"
  printf '%s\n' '{broken' > "$TEST_ROOT/broken.json"
  run_conventions refresh "$PLANNING_DIR" "$TEST_ROOT/broken.json"
  expect_case malformed-candidates 2
  [ "$(artifact_digest)" = "$before" ] || record_case_failure malformed-candidates "artifact changed"

  printf '%s\n' '{"schema_version":2,"conventions":[]}' > "$TEST_ROOT/version-two.json"
  run_conventions refresh "$PLANNING_DIR" "$TEST_ROOT/version-two.json"
  expect_case candidate-schema-version 2
  expect_exact_output candidate-schema-version "Error: invalid convention candidates"
  [ "$(artifact_digest)" = "$before" ] || record_case_failure candidate-schema-version "artifact changed"

  reset_planning
  write_candidates "$TEST_ROOT/unknown-conflict.json" '[
    {"rule":"Use pnpm","category":"tooling","confidence":"high","detected_from":"STACK.md","conflicts_with":["CONV-999"]}
  ]'
  run_conventions refresh "$PLANNING_DIR" "$TEST_ROOT/unknown-conflict.json"
  expect_case unknown-conflict-reference 2 "unknown conflict reference: CONV-999"
  [ ! -e "$ARTIFACT" ] || record_case_failure unknown-conflict-reference "artifact was written"

  printf '%s\n' '{"schema_version":2,"conventions":[]}' > "$ARTIFACT"
  run_conventions --json list "$PLANNING_DIR"
  expect_case artifact-schema-version 2
  expect_exact_output artifact-schema-version "Error: invalid conventions artifact"

  printf '%s\n' '{"conventions":[{"id":"CONV-001","tag":"STYLE","rule":"Use formatter","source":"user-defined","category":"style","confidence":null,"detected_from":null,"added":"2026-08-10"}]}' > "$ARTIFACT"
  run_conventions --json list "$PLANNING_DIR"
  expect_case artifact-without-schema-version 2
  expect_exact_output artifact-without-schema-version "Error: invalid conventions artifact"

  assert_no_case_failures
}

@test "planning traversal and symbolic link boundaries fail closed" {
  local physical_project="$TEST_ROOT/physical-project"

  run_conventions list "$PROJECT_DIR/child/../.lbwc-planning"
  expect_case traversal 2 traversal

  mv "$PLANNING_DIR" "$PROJECT_DIR/real-planning"
  ln -s "$PROJECT_DIR/real-planning" "$PLANNING_DIR"
  run_conventions list "$PLANNING_DIR"
  expect_case symlinked-planning-directory 2 "symbolic link"

  mkdir -p "$physical_project/.lbwc-planning"
  ln -s "$physical_project" "$TEST_ROOT/linked-project"
  run_conventions list "$TEST_ROOT/linked-project/.lbwc-planning"
  expect_case ancestor-symlink 2 "symbolic link paths are not allowed:"
  [[ "$output" == *"linked-project"* ]] \
    || record_case_failure ancestor-symlink "output does not name the linked ancestor: $output"

  assert_no_case_failures
}
