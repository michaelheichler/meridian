#!/usr/bin/env bats

load test_helper
load gate_case_helper

setup() {
  setup_temp_dir
  mkdir -p "$TEST_TEMP_DIR/project"
  cd "$TEST_TEMP_DIR/project"
  git init -q
  git config user.email test@example.invalid
  git config user.name Test
  printf 'initial\n' > app.py
  git add app.py
  git -c core.hooksPath=/dev/null commit -qm initial
  BASE=$(git rev-parse HEAD)
  PHASE="$(pwd -P)/.lbwc-planning/phases/01-work"
  ROUND="$PHASE/remediation/qa/round-01"
  SCRIPT="$SCRIPTS_DIR/qa-result-gate.sh"
  reset_case_failures
}

teardown() {
  await_git_ai
  cd "$PROJECT_ROOT"
  teardown_temp_dir
}

round_fixture() {
  local classification="$1" evidence="$2"
  rm -rf "$PHASE"
  mkdir -p "$ROUND"
  printf -- '---\nresult: FAIL\nwriter: write-verification.sh\nverified_at_commit: %s\n---\n| ID | Status |\n| F1 | FAIL |\n' "$BASE" > "$PHASE/01-VERIFICATION.md"
  printf -- '---\nplan: 01\n---\n' > "$PHASE/01-PLAN.md"
  printf 'stage=verify\nround=01\nround_started_at_commit=%s\nsource_verification_path=%s/01-VERIFICATION.md\nsource_fail_count=1\n' "$BASE" "$PHASE" > "$PHASE/remediation/qa/.qa-remediation-stage"
  printf -- '---\nround: 01\nfail_classifications: [{id: F1, %s}]\n---\n' "$classification" > "$ROUND/R01-PLAN.md"
  printf -- '---\nstatus: complete\n%s\ndeviations: []\n---\n' "$evidence" > "$ROUND/R01-SUMMARY.md"
  printf -- '---\nresult: PASS\nwriter: write-verification.sh\nplans_verified: [R01]\n---\n' > "$ROUND/R01-VERIFICATION.md"
}

commit_product() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  printf 'fixed %s\n' "$path" > "$path"
  git add "$path"
  git -c core.hooksPath=/dev/null commit -qm fix
}

@test "code fixes require implementation evidence rather than documentation or repository hygiene" {
  local label path expected
  while IFS='|' read -r label path expected; do
    round_fixture 'type: code-fix, rationale: repair behavior' "files_modified: ['$path']"
    commit_product "$path"
    run bash "$SCRIPT" "$PHASE"
    expect_case "$label" 0 "qa_gate_routing=$expected"
  done <<'CASES'
source-code|src/worker.py|PROCEED_TO_UAT
static-asset|public/logo.svg|PROCEED_TO_UAT
resource-text|resources/prompt.txt|PROCEED_TO_UAT
asset-catalog|App/Assets.xcassets/icon/Contents.json|PROCEED_TO_UAT
documentation|docs/worker.py|REMEDIATION_REQUIRED
readme|README.md|REMEDIATION_REQUIRED
hygiene|.gitignore|REMEDIATION_REQUIRED
plugin-metadata|.claude-plugin/plugin.json|REMEDIATION_REQUIRED
CASES
  assert_no_case_failures
}

@test "documentation fixes require the exact named documentation path" {
  local label required recorded expected
  while IFS='|' read -r label required recorded expected; do
    round_fixture "type: doc-fix, path: '$required', rationale: repair user guide" "files_modified: ['$recorded']"
    commit_product "$recorded"
    run bash "$SCRIPT" "$PHASE"
    expect_case "$label" 0 "qa_gate_routing=$expected"
  done <<'CASES'
matching-guide|docs/guide.md|docs/guide.md|PROCEED_TO_UAT
normalized-guide|./docs/intro.md|docs/intro.md|PROCEED_TO_UAT
wrong-guide|docs/missing.md|docs/other.md|REMEDIATION_REQUIRED
not-documentation|src/worker.py|README.md|REMEDIATION_REQUIRED
CASES
  assert_no_case_failures
}

commit_evidence_fixture() {
  local mode="$1" evidence_commit
  evidence_commit=$(git rev-parse HEAD)
  case "$mode" in
    valid) commit_product src/committed.py; evidence_commit=$(git rev-parse HEAD) ;;
    anchor) evidence_commit="$BASE" ;;
    invalid) evidence_commit=not-a-commit ;;
    empty) git -c core.hooksPath=/dev/null commit --allow-empty -qm empty; evidence_commit=$(git rev-parse HEAD) ;;
    sibling)
      git checkout -qb evidence-side "$BASE"
      commit_product src/side.py
      evidence_commit=$(git rev-parse HEAD)
      git checkout -q -
      ;;
  esac
  round_fixture 'type: code-fix, rationale: repair behavior' "commit_hashes: ['$evidence_commit']"
}

@test "commit evidence must name nonempty changes after the round anchor on the current history" {
  local label mode expected
  while IFS='|' read -r label mode expected; do
    commit_evidence_fixture "$mode"
    run bash "$SCRIPT" "$PHASE"
    expect_case "$label" 0 "qa_gate_routing=$expected"
  done <<'CASES'
round-local-code|valid|PROCEED_TO_UAT
anchor-is-not-work|anchor|REMEDIATION_REQUIRED
unresolvable-commit|invalid|REMEDIATION_REQUIRED
empty-commit|empty|REMEDIATION_REQUIRED
other-branch|sibling|REMEDIATION_REQUIRED
CASES
  assert_no_case_failures
}

@test "uncommitted product files cannot prove a code fix while round planning files can document an exception" {
  round_fixture 'type: code-fix, rationale: repair behavior' 'files_modified: [uncommitted.py]'
  printf 'not committed\n' > uncommitted.py
  run bash "$SCRIPT" "$PHASE"
  expect_case uncommitted-code 0 'qa_gate_routing=REMEDIATION_REQUIRED'
  expect_case unavailable-code-evidence 0 'qa_gate_round_change_evidence_unavailable=true'
  round_fixture 'type: process-exception, rationale: historical commit cannot change' 'files_modified: [remediation/qa/round-01/R01-PLAN.md]'
  run bash "$SCRIPT" "$PHASE"
  expect_case round-plan-evidence 0 'qa_gate_routing=PROCEED_TO_UAT'
  assert_no_case_failures
}

@test "ignored planning evidence stays usable for process exceptions and reports that provenance" {
  printf '.lbwc-planning/\n' > .gitignore
  git add .gitignore
  git -c core.hooksPath=/dev/null commit -qm ignore
  round_fixture 'type: process-exception, rationale: historical commit cannot change' 'files_modified: [remediation/qa/round-01/R01-SUMMARY.md]'
  run bash "$SCRIPT" "$PHASE"
  expect_case ignored-round-evidence 0 'qa_gate_routing=PROCEED_TO_UAT'
  expect_case ignored-provenance 0 'qa_gate_planning_ignored_evidence=true'
  assert_no_case_failures
}
