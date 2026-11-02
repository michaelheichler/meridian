#!/usr/bin/env bats

load test_helper
load todo_helper
load gate_case_helper
load isolated_case_helper

setup() {
  setup_temp_dir
  create_test_config
  cd "$TEST_TEMP_DIR"
  DETAILS_PATH="$TEST_TEMP_DIR/.lbwc-planning/todo-details.json"
  LEGACY_DIR="$TEST_TEMP_DIR/.lbwc-planning/todo-details"
}

teardown() {
  teardown_temp_dir
}

details() {
  run bash "$SCRIPTS_DIR/todo-details.sh" "$@"
}

seed_registry() {
  case "$1" in
    -) rm -f "$DETAILS_PATH" ;;
    *) printf '%s\n' "$1" > "$DETAILS_PATH" ;;
  esac
}

seed_legacy() {
  rm -rf "$LEGACY_DIR"
  case "$2" in
    -) ;;
    *)
      mkdir -p "$LEGACY_DIR"
      printf '%s\n' "$2" > "$LEGACY_DIR/$1.json"
      ;;
  esac
}

seed_registry_with_keys() {
  jq -cn --arg keys "$1" '{schema_version:1, items: ($keys | split(",") | map({(.): {summary:"s",context:"",files:[],added:"2026-04-12",source:"user"}}) | add)}' > "$DETAILS_PATH"
}

write_state_with_refs() {
  local heading="$1" refs="$2" ref
  printf '# State\n%s\n- Plain todo without a ref (added 2026-04-12)\n' "$heading" > "$TEST_TEMP_DIR/.lbwc-planning/STATE.md"
  for ref in ${refs//,/ }; do
    printf -- '- Todo (ref:%s)\n' "$ref" >> "$TEST_TEMP_DIR/.lbwc-planning/STATE.md"
  done
}

expect_registry() {
  local actual
  actual=$(jq -r "$2" "$DETAILS_PATH" 2>&1)
  [ "$actual" = "$3" ] || fail_case "$1" "registry $2 = '$actual' expected '$3'"
}

add_detail_and_recover_registry() {
  local long_context detail ctx_len
  while IFS='|' read -r label registry hash detail expected_summary; do
    [ -n "$label" ] || continue
    seed_registry "$registry"
    seed_legacy "$hash" -
    details add "$hash" "$detail" "$DETAILS_PATH"
    expect_status "$label" 0
    expect_json "$label" '.status' ok
    expect_json "$label" '.action' upserted
    expect_registry "$label" '.schema_version' 1
    expect_registry "$label" ".items[\"$hash\"].summary" "$expected_summary"
    [ ! -e "$LEGACY_DIR/$hash.json" ] || fail_case "$label" "legacy fallback file was created"
  done <<'CASES'
empty-registry|{"schema_version":1,"items":{}}|a1b2c3d4|{"summary":"Fix parser bug","context":"The parser fails on empty input","files":["src/parser.ts"],"added":"2026-04-12","source":"user"}|Fix parser bug
missing-registry-file|-|deadbeef|{"summary":"New todo","context":"Some context","files":[],"added":"2026-04-12","source":"user"}|New todo
existing-entry-is-replaced|{"schema_version":1,"items":{"a1b2c3d4":{"summary":"Old","context":"Old context","files":[],"added":"2026-01-01","source":"user"}}}|a1b2c3d4|{"summary":"Updated","context":"New context","files":["new.ts"],"added":"2026-04-12","source":"user"}|Updated
malformed-registry-is-reset|not json|a1b2c3d4|{"summary":"Recover","context":"New","files":[],"added":"2026-04-12","source":"user"}|Recover
CASES

  seed_registry '{"schema_version":1,"items":{}}'
  long_context=$(printf 'x%.0s' $(seq 1 2500))
  detail=$(jq -n --arg ctx "$long_context" '{"summary":"Long","context":$ctx,"files":[],"added":"2026-04-12","source":"user"}')

  details add "12345678" "$detail" "$DETAILS_PATH"
  [ "$status" -eq 0 ]
  ctx_len=$(jq -r '.items["12345678"].context | length' "$DETAILS_PATH")
  [ "$ctx_len" -le 2012 ]
  [ "$ctx_len" -gt 2000 ]

  seed_registry '{"schema_version":1,"items":{}}'
  jq -n '{"summary":"User'\''s repro doesn'\''t work","context":"The user'\''s test doesn'\''t pass","files":[],"added":"2026-04-12","source":"user"}' > "$TEST_TEMP_DIR/detail.json"

  run bash -c "bash \"$SCRIPTS_DIR/todo-details.sh\" add abcd1234 - \"$DETAILS_PATH\" < \"$TEST_TEMP_DIR/detail.json\""
  [ "$status" -eq 0 ]

  expect_registry stdin-detail '.items.abcd1234.summary' "User's repro doesn't work"
}

get_detail_with_legacy_fallback() {
  while IFS='|' read -r label registry legacy hash expected_status summary context files_len; do
    [ -n "$label" ] || continue
    seed_registry "$registry"
    seed_legacy "$hash" "$legacy"
    details get "$hash" "$DETAILS_PATH"
    expect_status "$label" 0
    expect_valid_json "$label"
    expect_json "$label" '.status' "$expected_status"
    expect_json "$label" '.hash' "$hash"
    expect_json_unless_dash "$label" '.detail.summary' "$summary"
    expect_json_unless_dash "$label" '.detail.context' "$context"
    expect_json_unless_dash "$label" '.detail.files | length' "$files_len"
  done <<'CASES'
registry-entry|{"schema_version":1,"items":{"a1b2c3d4":{"summary":"Test","context":"Detail here","files":["a.ts"],"added":"2026-04-12","source":"user"}}}|-|a1b2c3d4|ok|Test|Detail here|1
structurally-empty-detail-stays-ok|{"schema_version":1,"items":{"feedcafe":{"summary":"Sparse","context":"","files":[],"added":"2026-04-12","source":"user"}}}|-|feedcafe|ok|Sparse||0
legacy-fallback-when-registry-file-missing|-|{"summary":"Legacy summary","context":"Legacy context","files":["legacy.ts"],"added":"2026-04-12","source":"user"}|a1b2c3d4|ok|Legacy summary|Legacy context|1
missing-hash|{"schema_version":1,"items":{}}|-|deadbeef|not_found|-|-|-
missing-registry-file|-|-|a1b2c3d4|not_found|-|-|-
malformed-registry|not json|-|a1b2c3d4|not_found|-|-|-
invalid-hash-with-quote-and-backslash|{"schema_version":1,"items":{}}|-|a"b\c|not_found|-|-|-
CASES
}

remove_only_selected_detail() {
  while IFS='|' read -r label registry legacy hash action kept_key kept_summary; do
    [ -n "$label" ] || continue
    seed_registry "$registry"
    seed_legacy "$hash" "$legacy"
    details remove "$hash" "$DETAILS_PATH"
    expect_status "$label" 0
    expect_json "$label" '.status' ok
    expect_json "$label" '.action' "$action"
    expect_registry "$label" ".items | has(\"$hash\")" false
    [ ! -e "$LEGACY_DIR/$hash.json" ] || fail_case "$label" "legacy fallback file survived"
    case "$kept_key" in
      -) ;;
      *) expect_registry "$label" ".items.$kept_key.summary" "$kept_summary" ;;
    esac
    details get "$hash" "$DETAILS_PATH"
    expect_json "$label" '.status' not_found
  done <<'CASES'
existing-entry|{"schema_version":1,"items":{"a1b2c3d4":{"summary":"Test","context":"Detail","files":[],"added":"2026-04-12","source":"user"}}}|-|a1b2c3d4|removed|-|-
missing-hash-leaves-other-entries|{"schema_version":1,"items":{"other":{"summary":"Keep","context":"","files":[],"added":"2026-04-12","source":"user"}}}|-|deadbeef|noop|other|Keep
legacy-alongside-registry-entry|{"schema_version":1,"items":{"deadbeef":{"summary":"Canonical","context":"Registry copy","files":[],"added":"2026-04-12","source":"user"}}}|{"summary":"Legacy","context":"Legacy copy","files":[],"added":"2026-04-12","source":"user"}|deadbeef|removed|-|-
CASES

  seed_registry 'not json'
  seed_legacy deadbeef '{"summary":"Legacy only","context":"Cleanup should still happen","files":[],"added":"2026-04-12","source":"user"}'

  details remove deadbeef "$DETAILS_PATH"
  [ "$status" -eq 0 ]

  expect_json malformed '.status' ok
  expect_json malformed '.action' removed
  expect_json malformed '.canonical_status' malformed
  expect_json malformed '.legacy_removed' true
  [[ "$(echo "$output" | jq -r '.warning')" == *'Malformed todo-details.json'* ]]
  [ ! -f "$LEGACY_DIR/deadbeef.json" ]
  [ "$(cat "$DETAILS_PATH")" = "not json" ]
}

list_detail_counts() {
  while IFS='|' read -r label registry expected_status count; do
    [ -n "$label" ] || continue
    seed_registry "$registry"
    details list "$DETAILS_PATH"
    expect_status "$label" 0
    expect_json "$label" '.status' "$expected_status"
    expect_json_unless_dash "$label" '.count' "$count"
  done <<'CASES'
two-entries|{"schema_version":1,"items":{"aaa":{"summary":"A","context":"","files":[],"added":"2026-01-01","source":"user"},"bbb":{"summary":"B","context":"","files":[],"added":"2026-01-02","source":"known-issue"}}}|ok|2
no-entries|{"schema_version":1,"items":{}}|ok|0
missing-registry-file|-|ok|0
malformed-registry|not json|error|-
CASES
}

@test "todo details preserve registry behavior across lifecycle commands" {
  run_scenario_cases add_detail_and_recover_registry get_detail_with_legacy_fallback \
    remove_only_selected_detail list_detail_counts collect_unreferenced_details
}

collect_unreferenced_details() {
  while IFS='|' read -r label heading refs keys kept_keys action; do
    [ -n "$label" ] || continue
    write_state_with_refs "$heading" "$refs"
    seed_registry_with_keys "$keys"
    details gc "$TEST_TEMP_DIR/.lbwc-planning/STATE.md" "$DETAILS_PATH"
    expect_status "$label" 0
    expect_json "$label" '.action' "$action"
    expect_registry "$label" '.items | keys | join(",")' "$kept_keys"
  done <<'CASES'
orphan-removed|## Todos|a1b2c3d4|a1b2c3d4,deadbeef|a1b2c3d4|gc
all-referenced-kept|## Todos|aaaa1111,bbbb2222|aaaa1111,bbbb2222|aaaa1111,bbbb2222|noop
legacy-pending-todos-heading|### Pending Todos|aaaa1111,cccc3333|aaaa1111,bbbb2222,cccc3333|aaaa1111,cccc3333|gc
CASES
}
