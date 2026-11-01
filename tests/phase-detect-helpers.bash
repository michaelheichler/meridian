#!/usr/bin/env bash
set -u

load test_helper

PD_PLAN_DIR=".lbwc-planning"
PD_PHASES=".lbwc-planning/phases"
PD_MILESTONES=".lbwc-planning/milestones"
PD_FIXTURE_BUILDER="$BATS_TEST_DIRNAME/fixtures/phase-detect-output/setup-case.bash"

pd_setup() {
  setup_temp_dir
  create_test_config
  cd "$TEST_TEMP_DIR" || return 1
  git init --quiet
  git config user.email "test@test.com"
  git config user.name "Test"
  touch dummy && git add dummy && git commit -m "init" --quiet
  git tag pd-base
  pd_new_session
}

pd_new_session() {
  export PD_CASE_SEQ=$(( ${PD_CASE_SEQ:-0} + 1 ))
  export CLAUDE_SESSION_ID="phase-detect-${BATS_TEST_NUMBER:-0}-$$-$PD_CASE_SEQ-$RANDOM"
}

pd_teardown() {
  rm -f "/tmp/.lbwc-phase-detect-${CLAUDE_SESSION_ID:-default}.txt" 2>/dev/null || true
  rm -rf "/tmp/.lbwc-phase-detect-live-${CLAUDE_SESSION_ID:-default}.lock" 2>/dev/null || true
  rm -rf "/tmp/.lbwc-plugin-root-link-${CLAUDE_SESSION_ID:-default}" 2>/dev/null || true
  unset CLAUDE_SESSION_ID
  cd "$PROJECT_ROOT" || true
  teardown_temp_dir
}

pd_reset() {
  git reset --hard --quiet pd-base
  git clean -fdxq
  mkdir -p "$PD_PLAN_DIR"
  create_test_config
  export PD_SCRIPTS_DIR="$SCRIPTS_DIR"
  export PD_PATH_PREFIX=""
  export PD_RAW=""
  pd_new_session
}

pd_md() {
  local file="$1"
  shift
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$@" > "$file"
}

pd_project() {
  echo "# My Project" > "$PD_PLAN_DIR/PROJECT.md"
}

pd_config() {
  local tmp
  tmp="$(mktemp)"
  jq "$1" "$PD_PLAN_DIR/config.json" > "$tmp" && mv "$tmp" "$PD_PLAN_DIR/config.json"
}

pd_phase_number() {
  local slug="$1"
  printf '%s' "${slug%%-*}"
}

pd_summary() {
  pd_md "$1" '---' 'status: complete' '---' 'Done.'
}

pd_done() {
  local slug="$1" root="${2:-$PD_PHASES}" num
  num="$(pd_phase_number "$slug")"
  mkdir -p "$root/$slug"
  touch "$root/$slug/$num-01-PLAN.md"
  pd_summary "$root/$slug/$num-01-SUMMARY.md"
}

pd_done_flat() {
  local slug="$1" root="${2:-$PD_PHASES}" num
  num="$(pd_phase_number "$slug")"
  mkdir -p "$root/$slug"
  echo "# Plan" > "$root/$slug/$num-PLAN.md"
  printf '%s\n' '---' 'status: complete' '---' '# Summary' 'Done.' > "$root/$slug/$num-SUMMARY.md"
}

pd_plan() {
  local slug="$1" count="$2" root="${3:-$PD_PHASES}" num
  num="$(pd_phase_number "$slug")"
  mkdir -p "$root/$slug"
  touch "$root/$slug/$num-0$count-PLAN.md"
}

pd_shipped() {
  mkdir -p "$PD_MILESTONES/$1"
  echo "# Shipped" > "$PD_MILESTONES/$1/SHIPPED.md"
}

pd_uat() {
  local file="$1" status="$2" severity="$3" phase="${4:-}"
  mkdir -p "$(dirname "$file")"
  {
    printf '%s\n' '---'
    [ -z "$phase" ] || printf 'phase: %s\n' "$phase"
    printf 'status: %s\n' "$status"
    printf '%s\n' '---'
    if [ "$severity" = "-" ]; then
      printf '%s\n' 'All tests passed.'
    else
      printf '%s\n' "- Severity: $severity"
    fi
  } > "$file"
}

pd_uat_issue() {
  local file="$1" phase="$2" status="$3" description="$4" severity="$5" round="${6:-}"
  mkdir -p "$(dirname "$file")"
  {
    printf '%s\n' '---' "phase: $phase"
    [ -z "$round" ] || printf 'round: %s\n' "$round"
    printf '%s\n' "status: $status" 'issues: 1' '---' '' '## Tests' '' "### P${phase}-T1: sample test" '' \
      '- **Result:** issue' '- **Issue:** sample issue' "  - Description: $description" "  - Severity: $severity"
  } > "$file"
}

pd_commit_file() {
  local file="$1" content="$2" message="$3"
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$content" > "$file"
  git add "$file"
  git commit -m "$message" --quiet
}

pd_verified_pass() {
  local file="$1" plan="$2" commit="$3"
  pd_md "$file" '---' 'result: PASS' 'writer: write-verification.sh' 'plans_verified:' "  - $plan" \
    "verified_at_commit: ${commit}" '---' '# Verification' 'Passed.'
}

pd_known_issues() {
  local file="$1" phase="$2" seen_in="$3" last_seen_in="$4" last_round="$5" times="$6"
  mkdir -p "$(dirname "$file")"
  cat > "$file" <<EOF
{
  "schema_version": 1,
  "phase": "$phase",
  "issues": [
    {
      "test": "FIGIRegistryServiceTests",
      "file": "Tests/FIGIRegistryServiceTests.swift",
      "error": "compositeFigi missing",
      "first_seen_in": "$seen_in",
      "last_seen_in": "$last_seen_in",
      "first_seen_round": 0,
      "last_seen_round": $last_round,
      "times_seen": $times
    }
  ]
}
EOF
}

pd_shim() {
  local name="$1" relative="$2" body="$3"
  export PD_SCRIPTS_DIR="$TEST_TEMP_DIR/scripts-$name"
  cp -R "$SCRIPTS_DIR" "$PD_SCRIPTS_DIR"
  printf '%s\n' '#!/usr/bin/env bash' "$body" > "$PD_SCRIPTS_DIR/$relative"
  chmod +x "$PD_SCRIPTS_DIR/$relative"
}

pd_fake_bin() {
  local name="$1" body="$2"
  export PD_PATH_PREFIX="$TEST_TEMP_DIR/fake-bin"
  mkdir -p "$PD_PATH_PREFIX"
  printf '%s\n' '#!/usr/bin/env bash' "$body" > "$PD_PATH_PREFIX/$name"
  chmod +x "$PD_PATH_PREFIX/$name"
}

pd_run() {
  local saved_path="$PATH"
  PATH="${PD_PATH_PREFIX:+$PD_PATH_PREFIX:}$PATH"
  if [ -n "${PD_RAW:-}" ]; then
    run bash "$PD_SCRIPTS_DIR/phase-detect.sh"
  else
    run_phase_detect "$PD_SCRIPTS_DIR"
  fi
  PATH="$saved_path"
}

pd_milestone_marker() {
  printf '%s\n' "$output" \
    | awk '/^---MILESTONE_UAT_EXTRACT_START---$/{f=1; next} /^---MILESTONE_UAT_EXTRACT_END---$/{exit} f{print}' \
    | awk '/^milestone_phase_dir=/{next} /^---$/{exit} {print}'
}

pd_parity_holds() {
  local phase_dir="$1" expected marker
  expected="$(bash "$SCRIPTS_DIR/extract-uat-issues.sh" "$phase_dir")" || return 1
  marker="$(pd_milestone_marker)"
  [ "$marker" = "$expected" ]
}

pd_token_file() {
  printf '%s' "${1%@*}"
}

pd_file_has_line() {
  local spec="$1" file line
  file="${spec%@*}"
  line="${spec##*@}"
  grep -qx -- "$line" "$file"
}

pd_token_holds() {
  local token="$1"
  case "$token" in
    '!@'*) ! grep -q -- "^${token##*@}" "$(pd_token_file "${token#!@}")" ;;
    '!'*) ! grep -qF -- "${token#!}" <<< "$output" ;;
    '^'*) grep -qxF -- "${token#^}" <<< "$output" ;;
    '='*) [ "$output" = "$(printf '%b' "${token#=}")" ] ;;
    '@'*) pd_file_has_line "${token#@}" ;;
    '+'*) [ -e "${token#+}" ] ;;
    '-'*) [ ! -e "${token#-}" ] ;;
    '%'*) pd_parity_holds "${token#%}" ;;
    *' '* | *'|'*) grep -qF -- "$token" <<< "$output" ;;
    *) grep -qxF -- "$token" <<< "$output" ;;
  esac
}

pd_case() {
  local label="$1" setup="$2" tokens="$3" token
  local -a command_line wanted
  pd_reset
  read -r -a command_line <<< "$setup"
  "${command_line[@]}" || { printf 'case=%s setup failed\n' "$label" >&2; return 1; }
  pd_run
  [ "$status" -eq 0 ] || { printf 'case=%s exit status %s\n%s\n' "$label" "$status" "$output" >&2; return 1; }
  IFS='~' read -r -a wanted <<< "$tokens"
  for token in "${wanted[@]}"; do
    pd_token_holds "$token" || { printf 'case=%s expected token [%s]\n%s\n' "$label" "$token" "$output" >&2; return 1; }
  done
}

pd_table() {
  local label setup tokens
  while IFS='#' read -r -u 3 label setup tokens; do
    [ -n "$label" ] || continue
    pd_case "$label" "$setup" "$tokens" || return 1
  done 3<&0 0< /dev/null
}
