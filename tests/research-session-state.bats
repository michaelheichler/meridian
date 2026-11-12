#!/usr/bin/env bats

load test_helper
load gate_case_helper
load isolated_case_helper

setup() {
  setup_temp_dir
  export MERIDIAN_PLANNING_DIR="$TEST_TEMP_DIR/.meridian"
  mkdir -p "$MERIDIAN_PLANNING_DIR"
  git -C "$TEST_TEMP_DIR" init --quiet 2>/dev/null || true
  git -C "$TEST_TEMP_DIR" config user.email "test@test.com" 2>/dev/null || true
  git -C "$TEST_TEMP_DIR" config user.name "Test" 2>/dev/null || true
  touch "$TEST_TEMP_DIR/dummy"
  git -C "$TEST_TEMP_DIR" add dummy 2>/dev/null || true
  git -C "$TEST_TEMP_DIR" commit -m "init" --quiet 2>/dev/null || true
  reset_case_failures
}

teardown() {
  teardown_temp_dir
}

rss() {
  bash "$SCRIPTS_DIR/research-session-state.sh" "$@"
}

fail_case() {
  record_case_failure "$1" "$2 actual=[$3]"
}

expect_eq() {
  [ "$2" = "$3" ] || fail_case "$1" "expected=[$2]" "$3"
}

expect_has() {
  case "$3" in
    *"$2"*) ;;
    *) fail_case "$1" "expected to contain=[$2]" "$3" ;;
  esac
}

expect_lacks() {
  case "$3" in
    *"$2"*) fail_case "$1" "expected to lack=[$2]" "$3" ;;
  esac
}

# Body text can repeat field names, so only lines inside the frontmatter count.
fm_get() {
  awk -v field="$2" '
    /^---$/ { if (!s) { s=1; next } exit }
    s && index($0, field ":") == 1 {
      v = substr($0, length(field) + 2)
      sub(/^[[:space:]]*/, "", v)
      print v
      exit
    }
  ' "$1"
}

start_session() {
  cd "$TEST_TEMP_DIR"
  eval "$(rss start "$MERIDIAN_PLANNING_DIR" "$1")"
}

write_session() {
  mkdir -p "$MERIDIAN_PLANNING_DIR/research"
  printf -- '---\ntitle: %s\nstatus: %s\n---\n' "$2" "$3" > "$MERIDIAN_PLANNING_DIR/research/$1.md"
}

research_start() {
  local head_commit label input expected slug_part
  printf '# Legacy Research\nOld findings.\n' > "$MERIDIAN_PLANNING_DIR/RESEARCH-legacy.md"
  start_session "new-session"
  [ ! -f "$MERIDIAN_PLANNING_DIR/RESEARCH-legacy.md" ] || fail_case legacy-migrated "legacy file removed" "present"
  [ -f "$research_file" ] || fail_case legacy-migrated "session file exists" "$research_file"
  expect_eq "files in research/" "2" "$(find "$MERIDIAN_PLANNING_DIR/research" -name '*.md' | wc -l | tr -d ' ')"

  cd "$TEST_TEMP_DIR"
  head_commit=$(git rev-parse HEAD)
  run rss start "$MERIDIAN_PLANNING_DIR" "test-topic"
  expect_eq "start status" "0" "$status"
  expect_has "output ids" "research_id=" "$output"
  expect_has "output file" "research_file=" "$output"
  eval "$output"
  [ -f "$research_file" ] || fail_case "research file" "file exists" "$research_file"
  expect_has "file location" "/research/" "$research_file"
  expect_eq "status" "active" "$(fm_get "$research_file" status)"
  expect_eq "type" "standalone-research" "$(fm_get "$research_file" type)"
  expect_eq "base_commit" "$head_commit" "$(fm_get "$research_file" base_commit)"

  while IFS='|' read -r label input expected; do
    [ -n "$label" ] || continue
    cd "$TEST_TEMP_DIR"
    run rss start "$MERIDIAN_PLANNING_DIR" "$input"
    [ "$status" -eq 0 ] || fail_case "$label" "status=0" "status=$status output=$output"
    eval "$output"
    slug_part="${research_id#*-*-}"
    expect_eq "$label" "$expected" "$slug_part"
  done <<'CASES'
lowercase-and-dashes|My Research Has Spaces & Symbols!|my-research-has-spaces-symbols
truncated-at-50|this-is-a-very-long-slug-that-exceeds-fifty-characters-and-should-be-truncated|this-is-a-very-long-slug-that-exceeds-fifty-charac
all-symbols-fall-back|!!!|research
CASES

  assert_no_case_failures
}

research_complete() {
  start_session "complete-test"

  run rss complete "$MERIDIAN_PLANNING_DIR" "$research_id"
  [ "$status" -eq 0 ]
  expect_eq "output" "complete" "$output"
  expect_eq "frontmatter status" "complete" "$(fm_get "$research_file" status)"

  assert_no_case_failures
}

research_get() {
  local migrated_file session_id
  start_session "get-test"
  run rss get "$MERIDIAN_PLANNING_DIR" "$research_id"
  expect_eq "get status" "0" "$status"
  expect_has "id" "research_id=" "$output"
  expect_has "status" "research_status=active" "$output"
  expect_has "base commit" "research_base_commit=" "$output"

  printf -- '---\ntitle: Only Title\n---\n\nBody.\n' > "$MERIDIAN_PLANNING_DIR/RESEARCH-roundtrip.md"
  run rss migrate "$MERIDIAN_PLANNING_DIR"
  expect_eq "roundtrip migrate status" "0" "$status"
  migrated_file=$(find "$MERIDIAN_PLANNING_DIR/research" -name '*-roundtrip.md')
  session_id="${migrated_file##*/}"
  session_id="${session_id%.md}"
  run rss get "$MERIDIAN_PLANNING_DIR" "$session_id"
  expect_eq "roundtrip get status" "0" "$status"
  eval "$output"
  expect_eq "roundtrip status" "complete" "$research_status"
  expect_eq "roundtrip confidence" "medium" "$research_confidence"
  [ -n "$research_created" ] || fail_case "roundtrip created" "non-empty" "$output"
  [ -n "$research_updated" ] || fail_case "roundtrip updated" "non-empty" "$output"

  assert_no_case_failures
}

research_rejects_bad_input() {
  local label args fragment
  start_session "reject-fixture"
  while IFS='|' read -r label args fragment; do
    [ -n "$label" ] || continue
    args="${args//@PD@/$MERIDIAN_PLANNING_DIR}"
    run rss $args
    [ "$status" -eq 1 ] || fail_case "$label" "status=1" "status=$status output=$output"
    expect_has "$label" "$fragment" "$output"
  done <<'CASES'
get-traversal|get @PD@ ../../etc/passwd|invalid session name
complete-traversal|complete @PD@ ../foo|invalid session name
get-malformed-format|get @PD@ not-valid-format|invalid session name
complete-malformed-format|complete @PD@ nonexistent-id|invalid session name
get-missing-session|get @PD@ 20200101-000000-missing|not found
complete-missing-session|complete @PD@ 20200101-000000-missing|not found
get-without-id|get @PD@|Usage
complete-without-id|complete @PD@|Usage
start-without-slug|start @PD@|Usage
list-invalid-filter|list @PD@ --status bogus|invalid status filter
no-planning-dir|start|Usage
unknown-command|bogus @PD@|unknown command
CASES

  assert_no_case_failures
}

research_list() {
  local label setup_kind args want_lines present absent
  while IFS='|' read -r label setup_kind args want_lines present absent; do
    [ -n "$label" ] || continue
    rm -rf "$MERIDIAN_PLANNING_DIR/research"
    if [ "$setup_kind" = "sessions" ]; then
      write_session "20200101-000000-one" "one" "active"
      write_session "20200102-000000-two" "two" "complete"
    fi
    run rss list "$MERIDIAN_PLANNING_DIR" $args
    [ "$status" -eq 0 ] || fail_case "$label" "status=0" "status=$status output=$output"
    if [ "$want_lines" = "0" ]; then
      expect_eq "$label output" "" "$output"
      continue
    fi
    expect_eq "$label line count" "$want_lines" "$(printf '%s\n' "$output" | wc -l | tr -d ' ')"
    expect_has "$label present" "$present" "$output"
    [ -z "$absent" ] || expect_lacks "$label absent" "$absent" "$output"
  done <<'CASES'
no-research|none||0||
unfiltered|sessions||2|"status":"active"|
only-complete|sessions|--status complete|1|"status":"complete"|"status":"active"
only-active|sessions|--status active|1|"status":"active"|"status":"complete"
CASES

  assert_no_case_failures
}

research_latest() {
  local label prepare field
  while IFS='|' read -r label prepare; do
    [ -n "$label" ] || continue
    rm -rf "$MERIDIAN_PLANNING_DIR/research"
    [ "$prepare" != "empty-dir" ] || mkdir -p "$MERIDIAN_PLANNING_DIR/research"
    run rss latest "$MERIDIAN_PLANNING_DIR"
    [ "$status" -eq 0 ] || fail_case "$label" "status=0" "status=$status output=$output"
    for field in id file title status confidence base_commit created updated; do
      printf '%s\n' "$output" | grep -qx "research_$field=" \
        || fail_case "$label" "line research_$field= present" "$output"
    done
  done <<'CASES'
no-research-dir|none
empty-research-dir|empty-dir
CASES

  write_session "20200101-000000-zzz" "older" "active"
  write_session "20210101-000000-aaa" "newer" "active"
  run rss latest "$MERIDIAN_PLANNING_DIR"
  expect_eq "newest status" "0" "$status"
  expect_has "newest id" "research_id=20210101-000000-aaa" "$output"
  expect_lacks "older id" "20200101-000000-zzz" "$output"

  assert_no_case_failures
}

@test "research session state preserves creation, migration, selection and completion contracts" {
  run_scenario_cases research_start research_complete research_get research_rejects_bad_input \
    research_list research_latest research_migrate
}

research_migrate() {
  local label files file migrated_file slug content expectations pair field want got
  while IFS='|' read -r label files; do
    [ -n "$label" ] || continue
    for file in $files; do
      echo "content" > "$MERIDIAN_PLANNING_DIR/$file"
    done
    run rss migrate "$MERIDIAN_PLANNING_DIR"
    [ "$status" -eq 0 ] || fail_case "$label" "status=0" "status=$status output=$output"
    expect_has "$label" "migrated=0" "$output"
    for file in $files; do
      [ -f "$MERIDIAN_PLANNING_DIR/$file" ] || fail_case "$label" "$file kept in place" "$(ls "$MERIDIAN_PLANNING_DIR")"
    done
    find "$MERIDIAN_PLANNING_DIR" -maxdepth 1 -name '*.md' -delete
  done <<'CASES'
empty-dir|
non-research-files|STATE.md OTHER-topic.md
CASES

  printf '# My Custom Title\nSome content here.\n' > "$MERIDIAN_PLANNING_DIR/RESEARCH-titled.md"
  run rss migrate "$MERIDIAN_PLANNING_DIR"
  expect_eq "titled status" "0" "$status"
  expect_has "count" "migrated=1" "$output"
  [ ! -f "$MERIDIAN_PLANNING_DIR/RESEARCH-titled.md" ] || fail_case "titled source" "removed" "present"
  migrated_file=$(find "$MERIDIAN_PLANNING_DIR/research" -name '*.md')
  expect_eq "files in research/" "1" "$(printf '%s\n' "$migrated_file" | wc -l | tr -d ' ')"
  expect_eq "first line" "---" "$(head -1 "$migrated_file")"
  expect_eq "title" '"My Custom Title"' "$(fm_get "$migrated_file" title)"
  expect_eq "status" "complete" "$(fm_get "$migrated_file" status)"
  expect_eq "type" "standalone-research" "$(fm_get "$migrated_file" type)"
  expect_eq "base_commit" "unknown" "$(fm_get "$migrated_file" base_commit)"

  while IFS='|' read -r label slug content expectations; do
    [ -n "$label" ] || continue
    printf '%b' "$content" > "$MERIDIAN_PLANNING_DIR/RESEARCH-$slug.md"
    run rss migrate "$MERIDIAN_PLANNING_DIR"
    [ "$status" -eq 0 ] || fail_case "$label" "status=0" "status=$status output=$output"
    expect_has "$label count" "migrated=1" "$output"
    migrated_file=$(find "$MERIDIAN_PLANNING_DIR/research" -name "*-$slug.md")
    [ -f "$migrated_file" ] || fail_case "$label" "migrated file for $slug" "$(ls "$MERIDIAN_PLANNING_DIR/research")"
    expect_eq "$label first line" "---" "$(head -1 "$migrated_file")"
    for pair in $(printf '%s' "$expectations" | tr ';' '\n' | tr ' ' '_'); do
      field="${pair%%=*}"
      want="${pair#*=}"
      want="${want//_/ }"
      got=$(fm_get "$migrated_file" "$field")
      if [ "$want" = "~" ]; then
        [ -n "$got" ] || fail_case "$label" "field $field non-empty" "$got"
      else
        expect_eq "$label field $field" "$want" "$got"
      fi
    done
  done <<'CASES'
keeps-existing-values|has-fm|---\ntitle: Has Frontmatter\ntype: standalone-research\nstatus: active\nconfidence: high\nbase_commit: abc123\n---\n\nBody.\n|status=complete;base_commit=abc123;title=Has Frontmatter;confidence=high
backfills-missing-fields|partial-fm|---\ntitle: Partial Frontmatter\nconfidence: high\n---\n\nBody.\n|status=complete;base_commit=unknown;type=standalone-research;title=Partial Frontmatter;confidence=high
backfills-every-template-field|allfields|---\ntitle: Only Title\n---\n\nBody.\n|status=complete;base_commit=unknown;type=standalone-research;confidence=medium;created=~;updated=~;linked_sessions=[];title=Only Title
preserves-updated-timestamp|upd-preserve|---\ntitle: Updated Preserve\nstatus: active\nupdated: 2023-06-15 10:30:00\n---\n\nBody.\n|status=complete;updated=2023-06-15 10:30:00
fills-blank-values|blank-vals|---\ntitle: Blank Values\nconfidence:\nbase_commit:\n---\n\nBody.\n|confidence=medium;base_commit=unknown;title=Blank Values
ignores-matching-tokens-in-body|bodytoken|---\ntitle: Body Token Test\nconfidence: high\n---\n\nMentions status: active and base_commit: abc123 in prose.\n|status=complete;base_commit=unknown;confidence=high
CASES

  assert_no_case_failures
}
