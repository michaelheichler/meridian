#!/usr/bin/env bats

load capability_helper

setup() {
  setup_capability_sandbox
  BINARY="$TEST_ROOT/claude"
}

teardown() {
  teardown_capability_sandbox
}

refresh_at_frozen_time() {
  local shim_dir="$TEST_ROOT/clock-bin"
  mkdir -p "$shim_dir"
  printf '%s\n' "$1" > "$TEST_ROOT/frozen-now"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case "$*" in' \
    '  *%Y-%m-%dT%H:%M:%SZ*) cat "$FROZEN_NOW_FILE" ;;' \
    '  *) exec "$REAL_DATE" "$@" ;;' \
    'esac' > "$shim_dir/date"
  chmod +x "$shim_dir/date"
  run env PATH="$shim_dir:$PATH" FROZEN_NOW_FILE="$TEST_ROOT/frozen-now" REAL_DATE="$(command -v date)" \
    CLAUDE_CODE_EXECPATH="$BINARY" bash "$SCRIPT" refresh "$PLANNING_DIR"
}

compose_catalog() {
  env -u CDPATH bash -c '. "$1"; lbwc_compose_model_catalog "$2" "$3" "$4"' _ \
    "$REPO_ROOT/scripts/lib/compose-model-catalog.sh" "$1" "$2" "$3"
}

@test "refresh saves exact binary-derived models and global reasoning values" {
  local binary="$TEST_ROOT/fixture bin/claude"
  make_claude_fixture "$binary"

  run env CLAUDE_CODE_EXECPATH="$binary" bash "$SCRIPT" refresh "$PLANNING_DIR"

  [ "$status" -eq 0 ]
  [ -f "$CATALOG" ]
  run jq -e --arg binary "$(realpath "$binary")" '
    .schema_version == 1
    and .source.binary_path == $binary
    and .source.version == "91.7.3 (Fixture Code)"
    and (.source.sha256 | test("^[[:xdigit:]]{64}$"))
    and (.source.detected_at | type == "string" and length > 0)
    and .models == [
      {selector:"claude-amber-route", label:"Amber Route", description:"Amber Route"},
      {selector:"claude-violet-route", label:"Violet Route", description:"Violet Route"},
      {selector:"amber", label:"amber", description:"amber"},
      {selector:"violet", label:"violet", description:"violet"}
    ]
    and .host_agent_enum == ["amber", "violet"]
    and .agent_model_ids == {
      "claude-amber-route":"amber",
      "claude-violet-route":"violet",
      "amber":"amber",
      "violet":"violet"
    }
    and .reasoning.scope == "global"
    and .reasoning.accepted_values == ["careful", "brisk", "exhaustive"]
    and .reasoning.model_associations == {}
  ' "$CATALOG"
  [ "$status" -eq 0 ]
  [ ! -e "$INVOCATION_MARKER" ]
}

@test "refresh keeps first-seen exact values while deduplicating selectors" {
  write_claude_fixture \
    "$BINARY" \
    '5.4.3 (Arbitrary Fixture)' \
    'reflective, rapid, reflective, expansive' \
    '[{id:"claude-copper-one",family:"copper",display_name:"Copper One"},{id:"claude-copper-one",family:"copper",display_name:"Replacement"},{id:"claude-silver-two",family:"silver",display_name:"Silver Two"}]' \
    ''

  run env CLAUDE_CODE_EXECPATH="$BINARY" bash "$SCRIPT" refresh "$PLANNING_DIR"

  [ "$status" -eq 0 ]
  catalog_matches '
    .models == [
      {selector:"claude-copper-one", label:"Copper One", description:"Copper One"},
      {selector:"claude-silver-two", label:"Silver Two", description:"Silver Two"},
      {selector:"copper", label:"copper", description:"copper"},
      {selector:"silver", label:"silver", description:"silver"}
    ]
    and .reasoning.accepted_values == ["reflective", "rapid", "expansive"]
  '
}

@test "refresh records exposed model-to-reasoning associations without restrictions" {
  write_claude_fixture \
    "$BINARY" \
    '8.2.1 (Association Fixture)' \
    'measured, nimble, exhaustive' \
    '[{id:"claude-cedar",family:"cedar",display_name:"Cedar"},{id:"claude-birch",family:"birch",display_name:"Birch"}]' \
    'modelReasoningEfforts:{"claude-cedar":["measured","exhaustive"]}'

  run env CLAUDE_CODE_EXECPATH="$BINARY" bash "$SCRIPT" refresh "$PLANNING_DIR"

  [ "$status" -eq 0 ]
  catalog_matches '
    .reasoning.scope == "global"
    and .reasoning.accepted_values == ["measured", "nimble", "exhaustive"]
    and .reasoning.model_associations == {"claude-cedar":["measured", "exhaustive"]}
  '
}

@test "refresh regenerates provenance and detection time when executable bytes change" {
  local first_fingerprint
  make_claude_fixture "$BINARY"
  refresh_at_frozen_time 2035-01-02T03:04:05Z
  [ "$status" -eq 0 ]
  first_fingerprint=$(jq -r '.source.sha256' "$CATALOG")
  write_claude_fixture \
    "$BINARY" \
    '91.7.4 (Fixture Code)' \
    'patient, direct' \
    '[{id:"claude-indigo",family:"indigo",display_name:"Indigo"}]' \
    ''

  refresh_at_frozen_time 2035-01-02T03:04:06Z

  [ "$status" -eq 0 ]
  run jq -e --arg previous "$first_fingerprint" '
    .source.sha256 != $previous
    and .source.detected_at == "2035-01-02T03:04:06Z"
    and .source.version == "91.7.4 (Fixture Code)"
    and [.models[].selector] == ["claude-indigo", "indigo"]
    and .reasoning.accepted_values == ["patient", "direct"]
  ' "$CATALOG"
  [ "$status" -eq 0 ]
}

@test "failed extraction preserves the prior catalog byte for byte" {
  local before after temp_dir="$TEST_ROOT/capability-temp"
  mkdir -p "$temp_dir"
  make_claude_fixture "$BINARY"
  run env TMPDIR="$temp_dir" CLAUDE_CODE_EXECPATH="$BINARY" bash "$SCRIPT" refresh "$PLANNING_DIR"
  [ "$status" -eq 0 ]
  before=$(file_sha "$CATALOG")
  write_claude_fixture "$BINARY" '91.7.5 (Broken Fixture)' 'patient, direct' '[]' ''

  run env TMPDIR="$temp_dir" CLAUDE_CODE_EXECPATH="$BINARY" bash "$SCRIPT" refresh "$PLANNING_DIR"

  [ "$status" -ne 0 ]
  [[ "$output" == *"no validated model catalog"* ]]
  after=$(file_sha "$CATALOG")
  [ "$before" = "$after" ]
  run find "$PLANNING_DIR" -maxdepth 1 -name '.claude-capabilities.json.tmp.*' -print
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run find "$temp_dir" -mindepth 1 -print
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "refresh omits model entries that are incomplete or come from an unrelated UI table" {
  while IFS='|' read -r label models_json unrelated_table; do
    [ -n "$label" ] || continue
    rm -f "$CATALOG"
    write_claude_fixture "$BINARY" '12.4.6 (Metadata Boundary Fixture)' 'steady, swift' \
      "$models_json" '' "$unrelated_table"

    run env CLAUDE_CODE_EXECPATH="$BINARY" bash "$SCRIPT" refresh "$PLANNING_DIR" </dev/null

    [ "$status" -eq 0 ] || { case_fail "$label" "refresh status=$status"; return 1; }
    catalog_matches '.models == [{selector:"claude-maple", label:"Maple", description:"Maple"},{selector:"maple", label:"maple", description:"maple"}]' \
      || { case_fail "$label" "unexpected models"; return 1; }
  done <<'CASES'
incomplete-triple|[{id:"claude-maple",family:"maple",display_name:"Maple"},{id:"claude-incomplete",family:"incomplete"}]|
unrelated-ui-table|[{id:"claude-maple",family:"maple",display_name:"Maple"}]|ui:[{id:"maple",label:"Unrelated Maple",description:"Unrelated UI choice"}]
CASES
}

@test "composing a catalog from host-sized candidates and records succeeds without argv overflow" {
  local records="$TEST_ROOT/records.json" candidates="$TEST_ROOT/candidates.txt" composed="$TEST_ROOT/composed.json"
  jq -nc '[range(30000) | {selector:"claude-m\(.)", label:"L", description:"L", group:"g\(. % 3)"}]' > "$records"
  jq -nc 'range(45000) | ["g0","g1","g2","x1","x2","x3"]' > "$candidates"
  [ "$(wc -c < "$records")" -gt 2000000 ]
  [ "$(wc -c < "$candidates")" -gt 1300000 ]

  run compose_catalog "$records" "$candidates" "$composed"

  [ "$status" -eq 0 ]
  run jq -e '
    .host_agent_enum == ["g0","g1","g2","x1","x2","x3"]
    and (.models | length) == 30006
  ' "$composed"
  [ "$status" -eq 0 ]
}

@test "composing a catalog ignores noise and blank candidate lines and keeps the matching host enum" {
  local records="$TEST_ROOT/records.json" candidates="$TEST_ROOT/candidates.txt" composed="$TEST_ROOT/composed.json"
  printf '%s' '[{"selector":"a","label":"A","description":"A","group":"g"},{"selector":"b","label":"B","description":"B","group":"h"}]' > "$records"
  printf '["g","h","a"]\nnoise\n\n["a"]' > "$candidates"

  run compose_catalog "$records" "$candidates" "$composed"

  [ "$status" -eq 0 ]
  run jq -e '
    . == {
      models: [
        {selector:"a", label:"A", description:"A"},
        {selector:"b", label:"B", description:"B"},
        {selector:"g", label:"g", description:"g"},
        {selector:"h", label:"h", description:"h"}
      ],
      agent_model_ids: {a:"a", b:"h", g:"g", h:"h"},
      host_agent_enum: ["g","h","a"]
    }
  ' "$composed"
  [ "$status" -eq 0 ]
}

@test "validate rejects a malformed catalog schema" {
  local malformed="$TEST_ROOT/malformed.json"
  printf '%s\n' '{"schema_version":1,"source":{},"models":[],"reasoning":{}}' > "$malformed"

  run bash "$SCRIPT" validate "$malformed"

  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid Claude Code capability catalog"* ]]
}

@test "installed Claude Code yields a validated catalog without a model call" {
  local installed
  installed=$(command -v claude 2>/dev/null || true)
  [ -n "$installed" ] || skip 'Claude Code is not installed'

  run env -u CLAUDE_CODE_EXECPATH bash "$SCRIPT" refresh "$PLANNING_DIR"

  [ "$status" -eq 0 ]
  run jq -e --arg binary "$(realpath "$installed")" '
    .source.binary_path == $binary
    and (.source.version | length > 0)
    and (.models | length > 0)
    and (.reasoning.accepted_values | length > 0)
  ' "$CATALOG"
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" validate "$CATALOG"
  [ "$status" -eq 0 ]
}
