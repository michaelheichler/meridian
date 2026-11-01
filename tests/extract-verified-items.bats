#!/usr/bin/env bats

load test_helper
load gate_case_helper
load rejection_case_helper

setup() {
  setup_temp_dir
  REPO="$TEST_TEMP_DIR/repo"
  setup_unrelated_git_repo "$REPO"
  cd "$REPO" || return 1
  SCRIPT="$SCRIPTS_DIR/extract-verified-items.sh"
  PHASES="$REPO/.lbwc-planning/phases"
  HEADER="QA-VERIFIED ITEMS (do NOT generate UAT checkpoints for these):"
  EM_DASH=$'\xE2\x80\x94'
}

teardown() {
  cd "$PROJECT_ROOT" || true
  teardown_temp_dir
}

write_verified() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" | bash "$SCRIPTS_DIR/write-verification.sh" "$1" > /dev/null
}

deterministic_payload() {
  cat <<'JSON'
{"phase":"01","tier":"standard","result":"PASS","checks":{"passed":7,"failed":0,"total":8},
 "checks_detail":[
  {"id":"MH-01","status":"PASS","category":"must_have","description":"Login works","evidence":"exit 0"},
  {"id":"AR-1","status":"PASS","category":"artifact","description":"docs/api.md written","evidence":"present"},
  {"id":"KL-1","status":"PASS","category":"key_link","description":"qa.md calls the writer","evidence":"grep"},
  {"id":"AP-1","status":"PASS","category":"anti_pattern","description":"No TODO markers","evidence":"none found"},
  {"id":"SK-1","status":"PASS","category":"skill_augmented","description":"Shell lint clean","evidence":"0 findings"},
  {"id":"REQ-1","status":"PASS","category":"requirement","description":"Retry policy","plan_ref":"R9","evidence":"docs"},
  {"id":"CV-1","status":"WARN","category":"convention","description":"Naming","file":"src/a.sh","detail":"camelCase"},
  {"id":"OT-1","status":"PASS","category":"misc","description":"Pipe a|b kept","evidence":"seen"}
 ]}
JSON
}

legacy_verification() {
  mkdir -p "$(dirname "$1")"
  {
    printf -- '---\nphase: 01\n---\n\n'
    printf '\xE2\x9C\x93 **Login works** %s checked by hand\n' "$EM_DASH"
    printf '\xE2\x9A\xA0 **Slow load** %s takes 3s\n\n' "$EM_DASH"
    printf '| Metric | Passed | Failed | Warned |\n|---|---|---|---|\n| **Total** | **5** | **1** | **2** |\n\n'
    printf '**Verdict:** PASS with warnings\n'
  } > "$1"
}

expect_lines() {
  local label="$1" want="$2"
  [ "$output" = "$want" ] || record_case_failure "$label" "output=[$output] want=[$want]"
}

@test "verified items list each deterministic check with its status and the QA totals, read legacy checkmark reports, and follow the authoritative remediation verification" {
  local core_items="  PASS MH-01: Login works
  PASS AR-1: docs/api.md written
  PASS KL-1: qa.md calls the writer
  PASS AP-1: No TODO markers
  WARN CV-1: Naming
  PASS REQ-1: Retry policy
  PASS SK-1: Shell lint clean
  PASS OT-1: Pipe a|b kept

  QA: PASS (7/8 passed, 0 failed, tier: standard)"
  reset_case_failures

  write_verified "$PHASES/01-core/01-VERIFICATION.md" "$(deterministic_payload)"
  run bash "$SCRIPT" "$PHASES/01-core"
  expect_case deterministic 0
  expect_lines deterministic "$HEADER
$core_items"

  legacy_verification "$PHASES/02-legacy/02-VERIFICATION.md"
  run bash "$SCRIPT" "$PHASES/02-legacy"
  expect_case legacy 0
  expect_lines legacy "$HEADER
  "$'\xE2\x9C\x93'" Login works
  "$'\xE2\x9A\xA0'" Slow load
  QA totals: 5 passed, 1 failed, 2 warned

  Verdict: PASS with warnings"

  mkdir -p "$PHASES/03-renamed"
  legacy_verification "$PHASES/03-renamed/early-VERIFICATION.md"
  run bash "$SCRIPT" "$PHASES/03-renamed"
  expect_case noncanonical-name-fallback 0 "QA totals: 5 passed, 1 failed, 2 warned"

  write_verified "$PHASES/04-fixed/04-VERIFICATION.md" "$(deterministic_payload)"
  write_verified "$PHASES/04-fixed/remediation/qa/round-01/R01-VERIFICATION.md" \
    '{"tier":"quick","result":"PASS","checks":{"passed":1,"failed":0,"total":1},"checks_detail":[{"id":"RX-1","status":"PASS","category":"must_have","description":"Round fix holds"}]}'
  printf 'stage=done\nround=01\n' > "$PHASES/04-fixed/remediation/qa/.qa-remediation-stage"
  run bash "$SCRIPT" "$PHASES/04-fixed"
  expect_case remediation-done 0
  expect_lines remediation-done "$HEADER
  PASS RX-1: Round fix holds

  QA: PASS (1/1 passed, 0 failed, tier: quick)"

  rm "$PHASES/04-fixed/remediation/qa/round-01/R01-VERIFICATION.md"
  run bash "$SCRIPT" "$PHASES/04-fixed"
  expect_case_silent remediation-done-without-round-artifact 0

  mkdir -p "$PHASES/05-empty"
  run bash "$SCRIPT" "$PHASES/05-empty"
  expect_case_silent phase-without-verification 0
  run bash "$SCRIPT" "$PHASES/absent"
  expect_case_silent missing-phase-dir 0

  run bash "$SCRIPT" "$PHASES/01-core" "$PHASES/05-empty"
  expect_case several-phases 0
  expect_lines several-phases "$HEADER
  Phase: 01-core
$core_items
  Phase: 05-empty"

  assert_no_case_failures
}
