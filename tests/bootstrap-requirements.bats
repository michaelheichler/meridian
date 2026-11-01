#!/usr/bin/env bats

load test_helper
load gate_case_helper
load gate_case_files
load text_case_helper

setup() {
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK" "$BATS_TEST_TMPDIR/home"
  export HOME="$BATS_TEST_TMPDIR/home"
  git init -q "$WORK"
  cd "$WORK"
  REQS="$SCRIPTS_DIR/bootstrap/bootstrap-requirements.sh"
  reset_case_failures
}

teardown() {
  await_git_ai
}

@test "bootstrap-requirements rejects missing and malformed discovery input" {
  write_text "$WORK/bad.json" "{not json"

  run bash "$REQS" "$WORK/out/REQUIREMENTS.md"
  expect_case "too-few-arguments" 1 "Usage: bootstrap-requirements.sh"
  run bash "$REQS" "$WORK/out/REQUIREMENTS.md" "$WORK/absent.json"
  expect_case "missing-discovery" 1 "$WORK/absent.json"
  run bash "$REQS" "$WORK/out/REQUIREMENTS.md" "$WORK/bad.json"
  expect_case "invalid-json" 1 "$WORK/bad.json"
  expect_no_path "rejections-write-nothing" "$WORK/out"

  assert_no_case_failures
}

@test "bootstrap-requirements numbers answered then inferred requirements and records research availability" {
  local out="$WORK/mixed/REQUIREMENTS.md" discovery="$WORK/mixed/discovery.json"
  write_text "$discovery" '{
    "answered": ["Users log in", {"category": "goal", "answer": "Teams pay monthly"}, "", {"answer": ""}, 7],
    "inferred": [{"text": "Export CSV", "priority": "Nice-to-have"}, "Audit log", {"text": ""}]
  }'
  run bash "$REQS" "$out" "$discovery"
  expect_case_silent "mixed" 0
  expect_exact_line "answered-string-first" "$out" "### REQ-01: Users log in"
  expect_exact_line "answered-object" "$out" "### REQ-02: Teams pay monthly"
  expect_exact_line "inferred-after-answered" "$out" "### REQ-03: Export CSV"
  expect_exact_line "inferred-plain-string" "$out" "### REQ-04: Audit log"
  expect_no_file_line "blank-and-non-text-entries-skipped" "$out" "^### REQ-05"
  expect_exact_line "inferred-priority-kept" "$out" "**Nice-to-have**"
  expect_line_count "default-priority-must-have" "$out" "**Must-have**" 3
  expect_jq "mixed-no-research" "$discovery" '.research_summary == {"available": false}'

  out="$WORK/empty/REQUIREMENTS.md"
  discovery="$WORK/empty/discovery.json"
  write_text "$discovery" '{}'
  run bash "$REQS" "$out" "$discovery"
  expect_case_silent "empty-discovery" 0
  expect_path "empty-discovery-writes-file" "$out"
  expect_no_file_line "empty-discovery-has-no-requirements" "$out" "^### REQ-"

  out="$WORK/research/REQUIREMENTS.md"
  discovery="$WORK/research/discovery.json"
  write_text "$discovery" '{"answered": [{"category": "goal", "answer": "Ship"}, {"category": "scope", "answer": "Billing portal for teams"}]}'
  write_text "$WORK/research/research.md" "# Research"
  run bash "$REQS" "$out" "$discovery" "$WORK/research/research.md"
  expect_case_silent "research" 0
  expect_jq "research-domain-from-scope-answer" "$discovery" \
    '.research_summary.available == true and .research_summary.domain == "Billing" and .research_summary.key_findings == []'
  expect_jq "research-keeps-answers" "$discovery" '.answered | length == 2'

  run bash "$REQS" "$WORK/missing-research/REQUIREMENTS.md" "$discovery" "$WORK/research/absent.md"
  expect_case_silent "absent-research-file" 0
  expect_jq "absent-research-file-not-available" "$discovery" '.research_summary == {"available": false}'

  assert_no_case_failures
}
