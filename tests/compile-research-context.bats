#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load test_helper

setup() {
  setup_temp_dir
  export MERIDIAN_PLANNING_DIR="$TEST_TEMP_DIR/.meridian"
  mkdir -p "$MERIDIAN_PLANNING_DIR"

  cd "$TEST_TEMP_DIR"
  git init --quiet
  git config user.email "test@test.com"
  git config user.name "Test"
  touch dummy
  git add dummy
  git commit -m "init" --quiet
}

teardown() {
  teardown_temp_dir
}

fail_case() {
  printf 'case=%s %s\nactual=[%s]\n' "$1" "$2" "$3" >&2
  return 1
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

compile_context() {
  bash "$SCRIPTS_DIR/compile-research-context.sh" "$@"
}

create_research_file() {
  local slug="$1"
  cd "$TEST_TEMP_DIR"
  eval "$(bash "$SCRIPTS_DIR/research-session-state.sh" start "$MERIDIAN_PLANNING_DIR" "$slug")"
  cat > "$research_file" << ENDCONTENT
---
title: ${slug}
type: standalone-research
status: complete
confidence: high
created: $(date '+%Y-%m-%d %H:%M:%S')
updated: $(date '+%Y-%m-%d %H:%M:%S')
base_commit: $(git -C "$TEST_TEMP_DIR" rev-parse HEAD)
linked_sessions: []
---

Research findings about ${slug}.
ENDCONTENT
  echo "$research_file"
}

build_fixture() {
  local entry
  for entry in $(printf '%s' "$1" | tr ',' ' '); do
    case "$entry" in
      done:*) create_research_file "${entry#done:}" > /dev/null ;;
      active:*)
        cd "$TEST_TEMP_DIR"
        bash "$SCRIPTS_DIR/research-session-state.sh" start "$MERIDIAN_PLANNING_DIR" "${entry#active:}" > /dev/null
        ;;
    esac
  done
}

add_commits() {
  local count="$1" target="$2" index
  index=0
  while [ "$index" -lt "$count" ]; do
    index=$((index + 1))
    if [ "$target" = "planning" ]; then
      echo "change $index" > "$TEST_TEMP_DIR/.meridian/state-change-$index"
      git -C "$TEST_TEMP_DIR" add .meridian
    else
      echo "change $index" >> "$TEST_TEMP_DIR/dummy"
      git -C "$TEST_TEMP_DIR" add dummy
    fi
    git -C "$TEST_TEMP_DIR" commit -m "commit $index" --quiet
  done
}

@test "description matching emits the fresh best research with two keyword hits, warns when stale, and otherwise nothing" {
  local label fixture description expected absent commits target want_content want_warning
  while IFS='|' read -r label fixture description; do
    [ -n "$label" ] || continue
    rm -rf "$MERIDIAN_PLANNING_DIR/research"
    build_fixture "$fixture"
    cd "$TEST_TEMP_DIR"
    if [ "$fixture" = "MISSING" ]; then
      run --separate-stderr compile_context "/nonexistent/dir" "$description"
    elif [ -z "$description" ]; then
      run --separate-stderr compile_context "$MERIDIAN_PLANNING_DIR"
    else
      run --separate-stderr compile_context "$MERIDIAN_PLANNING_DIR" "$description"
    fi
    [ "$status" -eq 0 ] || fail_case "$label" "status=0" "status=$status output=$output"
    [ -z "$output" ] || fail_case "$label" "empty stdout" "$output"
  done <<'CASES'
no-research|none|some bug
planning-dir-missing|MISSING|some query
active-research-only|active:active-only|active only
no-description-single|done:only-topic|
no-description-multiple|done:topic-one,done:topic-two|
one-keyword-single|done:api-design|api crash report
one-keyword-multiple|done:swift-concurrency-patterns,done:python-web-server|swift memory leak
no-keyword-match|done:topic-alpha,done:topic-beta|something completely unrelated
only-short-keywords|done:api-design,done:ui-layout|an is at
CASES

  while IFS='|' read -r label fixture description expected absent; do
    [ -n "$label" ] || continue
    rm -rf "$MERIDIAN_PLANNING_DIR/research"
    build_fixture "$fixture"
    cd "$TEST_TEMP_DIR"
    run --separate-stderr compile_context "$MERIDIAN_PLANNING_DIR" "$description"
    [ "$status" -eq 0 ] || fail_case "$label" "status=0" "status=$status output=$output"
    expect_has "$label" "$expected" "$output"
    expect_lacks "$label fresh" "commits have landed" "$output"
    [ -z "$absent" ] || expect_lacks "$label other file" "$absent" "$output"
  done <<'CASES'
single-file|done:api-design|api design issue|Research findings about api-design|
picks-matching-file|done:swift-concurrency-patterns,done:python-web-server|swift concurrency issue|Research findings about swift-concurrency-patterns|python-web-server
CASES

  while IFS='|' read -r label commits target want_content want_warning; do
    [ -n "$label" ] || continue
    rm -rf "$MERIDIAN_PLANNING_DIR/research"
    create_research_file "stale-case" > /dev/null
    add_commits "$commits" "$target"
    run --separate-stderr compile_context "$MERIDIAN_PLANNING_DIR" "stale case"
    [ "$status" -eq 0 ] || fail_case "$label" "status=0" "status=$status output=$output"
    if [ "$want_content" = "yes" ]; then
      expect_has "$label content" "Research findings about stale-case" "$output"
    else
      [ -z "$output" ] || fail_case "$label" "empty stdout" "$output"
    fi
    if [ "$want_warning" = "yes" ]; then
      expect_has "$label warning" "commits have landed" "$output"
    else
      expect_lacks "$label warning" "commits have landed" "$output"
    fi
  done <<'CASES'
no-new-commits|0|dummy|yes|no
five-commits-warn|5|dummy|yes|yes
ten-commits-still-warn|10|dummy|yes|yes
eleven-commits-skipped|11|dummy|no|no
planning-only-commits-ignored|11|planning|yes|no
CASES
}

@test "explicit file override returns the content even when stale and nothing for a nonexistent file" {
  local label commits rfile
  while IFS='|' read -r label commits; do
    [ -n "$label" ] || continue
    rm -rf "$MERIDIAN_PLANNING_DIR/research"
    rfile=$(create_research_file "override-$label")
    add_commits "$commits" dummy
    run --separate-stderr compile_context "$MERIDIAN_PLANNING_DIR" --file "$rfile"
    [ "$status" -eq 0 ] || fail_case "$label" "status=0" "status=$status output=$output"
    expect_has "$label" "Research findings about override-$label" "$output"
    expect_lacks "$label" "commits have landed" "$output"
  done <<'CASES'
fresh|0
stale|11
CASES

  run --separate-stderr compile_context "$MERIDIAN_PLANNING_DIR" --file "/nonexistent/path.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
