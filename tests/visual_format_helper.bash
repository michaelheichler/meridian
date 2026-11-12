visual_research_fixture() {
  local base
  base=$(git rev-parse HEAD)
  case "$SCENARIO" in
    research-unknown) base=unknown ;;
    research-stale)
      printf 'change\n' >> dummy
      git add dummy
      git commit -qm change
      await_git_ai
      ;;
  esac
  RESEARCH="$MERIDIAN_PLANNING_DIR/research/20260101-120000-api-design.md"
  mkdir -p "$(dirname "$RESEARCH")"
  printf '%s\n' '---' 'title: api design' 'status: complete' 'type: standalone-research' \
    'confidence: high' 'created: 2026-01-01 12:00:00' 'updated: 2026-01-01 12:00:00' \
    "base_commit: $base" 'linked_sessions: []' '---' '✓ ✔ ⚠ → ➜ ✦ ● ◐ ✖ ✗ ○ ▮ ▯ ╔═╗║╚╝─' > "$RESEARCH"
}

visual_fixture() {
  mkdir -p "$MERIDIAN_PLANNING_DIR/phases/01-core" "$PLUGIN/commands" "$PLUGIN/.claude-plugin"
  printf '%s\n' '{"name":"sample"}' > "$PLUGIN/.claude-plugin/plugin.json"
  printf '%s\n' '---' 'category: lifecycle' 'description: Continue.' '---' > "$PLUGIN/commands/go.md"
  visual_research_fixture
  case "$SCENARIO" in
    help-no-commands) rm -rf "$PLUGIN/commands" ;;
    help-no-manifest) rm "$PLUGIN/.claude-plugin/plugin.json" ;;
    help-no-name) printf '{}\n' > "$PLUGIN/.claude-plugin/plugin.json" ;;
    legacy)
      printf '%s\n' '✓ **Checked**' '⚠ **Warning**' > "$MERIDIAN_PLANNING_DIR/phases/01-core/01-VERIFICATION.md"
      ;;
    deterministic)
      printf '%b\n' '---' 'result: PASS' 'total: 1' 'passed: 1' '---' \
        '## Must-Have Checks' '| \043 | ID | Description | Status |' '| 1 | QA-1 | ✓ → ⚠ | PASS |' \
        > "$MERIDIAN_PLANNING_DIR/phases/01-core/01-VERIFICATION.md"
      ;;
    research-explicit-no-newline) printf '✓ → ⚠' > "$RESEARCH" ;;
    migration) mv "$RESEARCH" "$MERIDIAN_PLANNING_DIR/RESEARCH-api-design.md" ;;
  esac
  printf 'visual-session|100|200000\n' > "$MERIDIAN_PLANNING_DIR/.context-usage"
}

visual_config() {
  local mode="$1" autonomy=standard
  [ "$SCENARIO" != compact-auto ] || autonomy=confident
  case "$mode" in
    missing-config) rm -f "$MERIDIAN_PLANNING_DIR/config.json" ;;
    missing-key) printf '{"autonomy":"%s"}\n' "$autonomy" > "$MERIDIAN_PLANNING_DIR/config.json" ;;
    *) printf '{"autonomy":"%s","visual_format":"%s"}\n' "$autonomy" "$mode" > "$MERIDIAN_PLANNING_DIR/config.json" ;;
  esac
}

visual_invoke() {
  local scripts="$1/scripts"
  case "$SCENARIO" in
    help*) bash "$scripts/help-output.sh" "$PLUGIN" ;;
    legacy|deterministic) bash "$scripts/extract-verified-items.sh" "$MERIDIAN_PLANNING_DIR/phases/01-core" ;;
    research-explicit*) bash "$scripts/compile-research-context.sh" "$MERIDIAN_PLANNING_DIR" --file "$RESEARCH" ;;
    research-*) bash "$scripts/compile-research-context.sh" "$MERIDIAN_PLANNING_DIR" 'api design' ;;
    migration) bash "$scripts/research-session-state.sh" migrate "$MERIDIAN_PLANNING_DIR" ;;
    compact-*) bash "$scripts/suggest-compact.sh" execute ;;
    next) bash "$scripts/suggest-next.sh" init ;;
  esac
}

visual_ascii_expected() {
  perl -pe 's/✓|✔/[ok]/g; s/⚠/[!]/g; s/→|➜/->/g; s/✦/*/g; s/●/~/g; s/◐/[..]/g; s/✖|✗/[x]/g; s/○/-/g; s/ · / | /g; s/▮/#/g; s/▯/-/g; s/╔|╗|╚|╝/+/g; s/═|─/-/g; s/║/|/g' "$1"
}

visual_check_bytes() {
  local stream="$1" expected="$ROW/expected-$1" grep_status
  if [ "$MODE" = ascii ]; then
    visual_ascii_expected "$ROW/old-$stream" > "$expected"
    grep_status=0
    LC_ALL=C grep -q $'[\x80-\xFF]' "$ROW/new-$stream" || grep_status=$?
    [ "$grep_status" -eq 1 ] || record_case_failure "$LABEL/$stream" "non-ASCII bytes or grep error $grep_status"
  else
    cp "$ROW/old-$stream" "$expected"
  fi
  cmp -s "$expected" "$ROW/new-$stream" \
    || record_case_failure "$LABEL/$stream" "byte mismatch"
}

visual_check_artifacts() {
  diff -r "$ROW/old-artifacts" "$MERIDIAN_PLANNING_DIR" > "$ROW/artifact-diff" \
    || record_case_failure "$LABEL" "rendering changed artifact contents"
  case "$SCENARIO" in
    migration)
      cmp -s "$ROW/snapshot/RESEARCH-api-design.md" "$MERIDIAN_PLANNING_DIR/research/"*.md \
        || record_case_failure "$LABEL" 'migration changed artifact bytes'
      ;;
    research-*)
      shasum "$ROW/snapshot/research/"*.md | cut -d ' ' -f 1 > "$ROW/hash-before"
      shasum "$MERIDIAN_PLANNING_DIR/research/"*.md | cut -d ' ' -f 1 > "$ROW/hash-after"
      cmp -s "$ROW/hash-before" "$ROW/hash-after" || record_case_failure "$LABEL" 'source research hash changed'
      ;;
  esac
}

visual_check_row() {
  [ "$new_status" -eq "$old_status" ] || record_case_failure "$LABEL" "status $new_status expected $old_status"
  visual_check_bytes out
  visual_check_bytes err
  if [ "$MODE" = ascii ]; then
    if cmp -s "$ROW/old-out" "$ROW/expected-out" && cmp -s "$ROW/old-err" "$ROW/expected-err"; then
      record_case_failure "$LABEL" 'fixture did not exercise a converted glyph'
    fi
  fi
  visual_check_artifacts
}

visual_row() {
  local SCENARIO="$1" MODE="$2" LABEL="$1/$2" ROW old_status new_status
  ROW="$TEST_TEMP_DIR/$LABEL"
  mkdir -p "$ROW"
  export MERIDIAN_PLANNING_DIR="$ROW/.meridian" CLAUDE_PLUGIN_ROOT="$ROW/plugin"
  local PLUGIN="$CLAUDE_PLUGIN_ROOT" RESEARCH
  visual_fixture
  visual_config "$MODE"
  cp -Rp "$MERIDIAN_PLANNING_DIR" "$ROW/snapshot"
  old_status=0
  visual_invoke "$BASELINE" > "$ROW/old-out" 2> "$ROW/old-err" || old_status=$?
  cp -Rp "$MERIDIAN_PLANNING_DIR" "$ROW/old-artifacts"
  rm -rf "$MERIDIAN_PLANNING_DIR"
  cp -Rp "$ROW/snapshot" "$MERIDIAN_PLANNING_DIR"
  new_status=0
  visual_invoke "$SUBJECT" > "$ROW/new-out" 2> "$ROW/new-err" || new_status=$?
  visual_check_row
}

visual_matrix() {
  local mode="$1" scenario
  for scenario in help help-no-commands help-no-manifest help-no-name legacy deterministic \
    research-explicit research-explicit-no-newline research-fresh research-unknown research-stale migration \
    compact-standard compact-auto next; do
    visual_row "$scenario" "$mode"
  done
}
