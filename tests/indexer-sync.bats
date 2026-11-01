#!/usr/bin/env bats

load test_helper
load gate_case_helper
load gate_case_files

setup() {
  REPO_ROOT="$BATS_TEST_DIRNAME/.."
  SCRIPT="$REPO_ROOT/scripts/indexer-sync.sh"
  TEST_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
  PROJECT_DIR="$TEST_ROOT/project"
  FAKE_BIN="$TEST_ROOT/bin"
  PLUGIN_ROOT="$TEST_ROOT/plugin"
  PLUGIN_DIR="$PLUGIN_ROOT/scripts"
  NODE_LOG="$TEST_ROOT/node.log"
  mkdir -p "$PROJECT_DIR" "$FAKE_BIN" "$PLUGIN_DIR/lib"

  git -C "$PROJECT_DIR" init -q
  git -C "$PROJECT_DIR" config user.email "test@test.com"
  git -C "$PROJECT_DIR" config user.name "Test"
  printf '%s\n' 'initial' > "$PROJECT_DIR/source.txt"
  git -C "$PROJECT_DIR" add source.txt
  git -C "$PROJECT_DIR" commit -qm "init"
  CURRENT_COMMIT="$(git -C "$PROJECT_DIR" rev-parse --short HEAD)"

  cp "$SCRIPT" "$PLUGIN_DIR/indexer-sync.sh"
  cp "$REPO_ROOT/scripts/ensure-plugin-root-link.sh" "$PLUGIN_DIR/ensure-plugin-root-link.sh"
  cp "$REPO_ROOT/scripts/resolve-plugin-root.sh" "$PLUGIN_DIR/resolve-plugin-root.sh"
  copy_script_with_libs "$REPO_ROOT/scripts/lib/lbwc-control-root.sh" "$PLUGIN_DIR/lib/lbwc-control-root.sh"
  cp "$REPO_ROOT/scripts/lib/lbwc-target-root.sh" "$PLUGIN_DIR/lib/lbwc-target-root.sh"
  cat > "$TEST_ROOT/probe-stub.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${PROBE_FAIL:-false}" != true ] || exit 1
jq -n \
  --argjson available "${PROBE_GITNEXUS_AVAILABLE:-false}" \
  --argjson indexed "${PROBE_GITNEXUS_INDEXED:-false}" \
  --arg route "${PROBE_ROUTE:-grep-only}" \
  '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:({gitnexus:{available:$available,indexed:$indexed},recommended_route:$route} | tostring)}}'
EOF
  chmod +x "$TEST_ROOT/probe-stub.sh"

  cat > "$FAKE_BIN/node" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$NODE_LOG"
case "${2:-}" in
  analyze)
    [ "${INDEXER_ANALYZE_MODE:-ok}" != fail ] || exit 1
    printf '%s\n' \
      'Repository indexed successfully (6.6s)' \
      '6,864 nodes | 8,200 edges | 138 clusters | 90 flows' \
      '/Users/michael/dev/skills/lbwc'
    ;;
  status)
    case "${INDEXER_STATUS_MODE:-fresh}" in
      fresh)
        printf 'Repository: %s\nBranch: main\nIndexed: 8/14/2026, 2:32:25 PM\nIndexed commit: %s\nCurrent commit: %s\nStatus: ✅ up-to-date\n' \
          "$PROJECT_DIR" "$INDEXED_COMMIT" "$CURRENT_COMMIT"
        ;;
      mismatch)
        printf 'Indexed commit: 0000000\nCurrent commit: %s\nStatus: ✅ up-to-date\n' "$CURRENT_COMMIT"
        ;;
      fail)
        exit 1
        ;;
      *)
        printf 'Repository: %s\nBranch: main\nIndexed: 8/13/2026, 11:08:53 AM\nIndexed commit: 0000000\nCurrent commit: %s\nStatus: ⚠️ stale (re-run gitnexus analyze)\n' \
          "$PROJECT_DIR" "$CURRENT_COMMIT"
        ;;
    esac
    ;;
  *)
    printf 'unexpected node arguments: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$FAKE_BIN/node"
  COMMAND_SESSION_ID="indexer-sync-${BATS_TEST_NUMBER}-$$"
  ROOT_LINK="/tmp/.lbwc-plugin-root-link-${COMMAND_SESSION_ID}"
  rm -rf "$ROOT_LINK"
  export NODE_LOG PROJECT_DIR CURRENT_COMMIT INDEXED_COMMIT="$CURRENT_COMMIT" COMMAND_SESSION_ID ROOT_LINK
  SYNC_JSON="$PROJECT_DIR/.lbwc-planning/.runtime/indexer-sync.json"
  cd "$PROJECT_DIR"
  reset_case_failures
  reset_row
}

teardown() {
  cd "$REPO_ROOT"
  if command -v git-ai >/dev/null; then
    git-ai await --timeout 5 >/dev/null 2>&1 || true
  fi
  rm -rf "$TEST_ROOT"
  rm -rf "$ROOT_LINK"
}

reset_row() {
  rm -rf "$PROJECT_DIR/.lbwc-planning" "$PROJECT_DIR/.gitnexus" "$NODE_LOG" "$FAKE_BIN/jq"
  cp "$TEST_ROOT/probe-stub.sh" "$PLUGIN_DIR/probe-map-tools.sh"
  unset INDEXER_STATUS_MODE INDEXER_ANALYZE_MODE PROBE_FAIL
  set_probe false false grep-only
}

write_index() {
  mkdir -p "$PROJECT_DIR/.gitnexus"
  printf '%s\n' 'fixture' > "$PROJECT_DIR/.gitnexus/run.cjs"
}

set_probe() {
  PROBE_GITNEXUS_AVAILABLE="$1"
  PROBE_GITNEXUS_INDEXED="$2"
  PROBE_ROUTE="$3"
  export PROBE_GITNEXUS_AVAILABLE PROBE_GITNEXUS_INDEXED PROBE_ROUTE
}

initialize_planning() {
  mkdir -p "$PROJECT_DIR/.lbwc-planning"
  printf '%s\n' '{}' > "$PROJECT_DIR/.lbwc-planning/config.json"
}

run_sync() {
  run env \
    PATH="$FAKE_BIN:$PATH" \
    LBWC_PLANNING_DIR="$PROJECT_DIR/.lbwc-planning" \
    bash "$PLUGIN_DIR/indexer-sync.sh" --project-root "$PROJECT_DIR" "$@"
}

node_calls() {
  grep -c -- "$1" "$NODE_LOG" 2>/dev/null || true
}

extract_gate() {
  local command_name="$1"
  awk '
    /^## Index freshness gate$/ { in_gate=1; next }
    in_gate && /^## / { exit }
    in_gate && /^[[:space:]]*bash .*indexer-sync\.sh/ { print; exit }
  ' "$REPO_ROOT/commands/$command_name.md"
}

run_command_gate() {
  local command_name="$1" gate
  gate="$(extract_gate "$command_name")"
  gate="${gate//\{LINK\}/$PLUGIN_ROOT}"
  gate="${gate//\{PROJECT_ROOT\}/$PROJECT_DIR}"
  run bash -c "cd \"$PROJECT_DIR\" && $gate"
}

resolve_build_context() {
  local directive
  directive="$(awk '/^!`/{sub(/^!`/,""); sub(/`$/,""); print; exit}' "$REPO_ROOT/commands/build.md")"
  [ -n "$directive" ] || return 1

  run env -u LINK -u PROJECT_ROOT \
    CLAUDE_SESSION_ID="$COMMAND_SESSION_ID" \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    bash -c "cd \"$PROJECT_DIR\" && $directive"
  [ "$status" -eq 0 ] || return "$status"

  RESOLVED_LINK="$(printf '%s\n' "$output" | awk -F': ' '/^Plugin root: /{print $2; exit}')"
  RESOLVED_PROJECT_ROOT="$(printf '%s\n' "$output" | awk -F': ' '/^Project root: /{print $2; exit}')"
  [ "$RESOLVED_LINK" = "$PLUGIN_ROOT" ]
  [ "$RESOLVED_PROJECT_ROOT" = "$PROJECT_DIR" ]
}

run_resolved_build_gate() {
  local gate
  resolve_build_context || return $?
  gate="$(extract_gate build)"
  gate="${gate//\{LINK\}/$RESOLVED_LINK}"
  gate="${gate//\{PROJECT_ROOT\}/$RESOLVED_PROJECT_ROOT}"
  [[ "$gate" != *'{'* ]] || return 1

  run env \
    PATH="$FAKE_BIN:$PATH" \
    LBWC_PLANNING_DIR="$PROJECT_DIR/.lbwc-planning" \
    bash -c "cd \"$PROJECT_DIR\" && $gate"
}

@test "indexer-sync records usable routes, blocks missing, stale, failed and unsupported indexes, and rejects bad arguments" {
  set_probe false false grep-only
  run_sync
  expect_status fresh-project-grep-only 0
  expect_no_path fresh-project-grep-only "$PROJECT_DIR/.lbwc-planning"
  expect_no_path fresh-project-grep-only "$NODE_LOG"

  reset_row
  mkdir -p "$PROJECT_DIR/.lbwc-planning"
  run_sync
  expect_status uninitialized-planning 0
  expect_no_path uninitialized-planning "$PROJECT_DIR/.lbwc-planning/MAP-TOOLS.json"
  expect_no_path uninitialized-planning "$PROJECT_DIR/.lbwc-planning/.runtime"

  reset_row
  initialize_planning
  run_sync
  expect_status grep-only 0
  expect_no_path grep-only "$NODE_LOG"
  expect_jq grep-only "$SYNC_JSON" '.map_route == "grep-only" and .gitnexus == "unavailable"'

  reset_row
  initialize_planning
  set_probe true false grep-only
  run_sync
  expect_status grep-only-gitnexus-available 0
  expect_jq grep-only-gitnexus-available "$SYNC_JSON" '.map_route == "grep-only" and .gitnexus == "not-selected"'

  reset_row
  initialize_planning
  write_index
  set_probe true true gitnexus
  run_sync
  expect_status gitnexus-fresh 0
  [ "$(node_calls '.gitnexus/run.cjs analyze')" = 1 ] || record_case_failure gitnexus-fresh "analyze did not run exactly once"
  [ "$(node_calls '.gitnexus/run.cjs status')" = 1 ] || record_case_failure gitnexus-fresh "status did not run exactly once"
  expect_jq gitnexus-fresh "$SYNC_JSON" \
    ".map_route == \"gitnexus\" and .gitnexus == \"up-to-date\" and .indexed_commit == \"$CURRENT_COMMIT\" and .capability_gap == null"

  reset_row
  initialize_planning
  set_probe false false serena
  run_sync
  expect_case serena-gap 0 "Serena route selected"
  expect_output_has serena-gap "serena-refresh-unsupported"
  expect_no_path serena-gap "$NODE_LOG"
  expect_jq serena-gap "$SYNC_JSON" '
    .map_route == "serena"
    and .gitnexus == "not-selected"
    and .capability_gap == {status: "unsupported", code: "serena-refresh-unsupported", route: "serena"}'

  reset_row
  initialize_planning
  set_probe false false lsp
  run_sync
  expect_case lsp-gap 0 "LSP route selected"
  expect_jq lsp-gap "$SYNC_JSON" '.map_route == "lsp" and .capability_gap.code == "lsp-refresh-unsupported"'

  reset_row
  initialize_planning
  set_probe true false gitnexus
  run_sync
  expect_case index-missing 1 "GitNexus index is missing"
  expect_no_path index-missing "$NODE_LOG"
  expect_jq index-missing "$SYNC_JSON" '.map_route == "gitnexus" and .gitnexus == "missing"'

  reset_row
  initialize_planning
  write_index
  set_probe false true gitnexus
  run_sync
  expect_case index-present-gitnexus-unavailable 1 "GitNexus index is missing"
  expect_no_path index-present-gitnexus-unavailable "$NODE_LOG"

  reset_row
  initialize_planning
  write_index
  set_probe true true gitnexus
  INDEXER_STATUS_MODE=stale
  export INDEXER_STATUS_MODE
  run_sync
  expect_case status-stale 1 "GitNexus index is stale"
  [ "$(node_calls '.gitnexus/run.cjs analyze')" = 1 ] || record_case_failure status-stale "analyze did not run before the stale verdict"
  expect_jq status-stale "$SYNC_JSON" '.map_route == "gitnexus" and (.gitnexus | contains("stale"))'

  reset_row
  initialize_planning
  write_index
  set_probe true true gitnexus
  INDEXER_STATUS_MODE=mismatch
  export INDEXER_STATUS_MODE
  run_sync
  expect_case commit-mismatch 1 "GitNexus index is stale"
  expect_jq commit-mismatch "$SYNC_JSON" '.gitnexus == "up-to-date" and .indexed_commit == "0000000"'

  reset_row
  initialize_planning
  write_index
  set_probe true true gitnexus
  INDEXER_ANALYZE_MODE=fail
  export INDEXER_ANALYZE_MODE
  run_sync
  expect_case analyze-failed 1 "GitNexus analyze failed"
  expect_jq analyze-failed "$SYNC_JSON" '.gitnexus == "analyze-failed"'

  reset_row
  initialize_planning
  write_index
  set_probe true true gitnexus
  INDEXER_STATUS_MODE=fail
  export INDEXER_STATUS_MODE
  run_sync
  expect_case status-failed 1 "GitNexus status failed"
  expect_jq status-failed "$SYNC_JSON" '.gitnexus == "status-failed"'

  reset_row
  initialize_planning
  set_probe false false unknown
  run_sync
  expect_case unknown-route 1 "unsupported map route"
  expect_output_has unknown-route "unknown"
  expect_jq unknown-route "$SYNC_JSON" '
    .map_route == "unknown"
    and .capability_gap == {status: "unsupported", code: "unknown-map-route", route: "unknown"}'

  reset_row
  initialize_planning
  set_probe false false grep-only
  run_sync --require-gitnexus
  expect_case require-gitnexus-other-route 1 "GitNexus index is required"
  expect_jq require-gitnexus-other-route "$SYNC_JSON" '.gitnexus == "required"'

  reset_row
  initialize_planning
  set_probe true false gitnexus
  run_sync --require-gitnexus
  expect_case require-gitnexus-no-index 1 "GitNexus index is required"

  reset_row
  initialize_planning
  write_index
  set_probe true true gitnexus
  cat > "$FAKE_BIN/jq" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
  chmod +x "$FAKE_BIN/jq"
  run_sync
  expect_case jq-missing 2 "jq is required"

  reset_row
  initialize_planning
  rm -f "$PLUGIN_DIR/probe-map-tools.sh"
  run_sync
  expect_case probe-unavailable 2 "required map-tools probe is unavailable"
  expect_jq probe-unavailable "$SYNC_JSON" '.gitnexus == "probe-missing"'

  reset_row
  initialize_planning
  PROBE_FAIL=true
  export PROBE_FAIL
  run_sync
  expect_case probe-fails 2 "map-tools probe failed"
  expect_jq probe-fails "$SYNC_JSON" '.gitnexus == "probe-failed"'

  reset_row
  rm -f "$PLUGIN_DIR/probe-map-tools.sh"
  run_sync
  expect_case probe-unavailable-uninitialized 2 "required map-tools probe is unavailable"
  expect_no_path probe-unavailable-uninitialized "$PROJECT_DIR/.lbwc-planning"

  run bash "$PLUGIN_DIR/indexer-sync.sh" --help
  expect_case help-flag 0 "Usage:"

  run bash "$PLUGIN_DIR/indexer-sync.sh" --project-root
  expect_case root-without-value 2 "Usage:"

  run bash "$PLUGIN_DIR/indexer-sync.sh" --bogus
  expect_case unknown-option 2 "Usage:"

  run bash "$PLUGIN_DIR/indexer-sync.sh" --project-root "$TEST_ROOT/does-not-exist"
  expect_case root-inaccessible 2 "project root is not accessible"

  assert_no_case_failures
}

@test "indexer-sync command gates: vibe, team and build run the helper and stop when it fails" {
  run_command_gate vibe
  expect_status vibe-gate 0
  run_command_gate team
  expect_status team-gate 0
  expect_no_path command-gates "$PROJECT_DIR/.lbwc-planning"

  [ "$(grep -c '^!`' "$REPO_ROOT/commands/build.md")" = 1 ] || record_case_failure build-directive "build.md must hold exactly one context directive"
  run_resolved_build_gate
  expect_status build-gate 0
  [ "$RESOLVED_LINK" = "$PLUGIN_ROOT" ] || record_case_failure build-gate "resolved plugin root is $RESOLVED_LINK"
  [ "$RESOLVED_PROJECT_ROOT" = "$PROJECT_DIR" ] || record_case_failure build-gate "resolved project root is $RESOLVED_PROJECT_ROOT"
  expect_no_path build-gate "$PROJECT_DIR/.lbwc-planning"

  reset_row
  rm -f "$PLUGIN_DIR/probe-map-tools.sh"
  run_command_gate vibe
  expect_case vibe-gate-helper-fails 2 "required map-tools probe is unavailable"
  run_command_gate team
  expect_case team-gate-helper-fails 2 "required map-tools probe is unavailable"
  run_resolved_build_gate
  expect_case build-gate-helper-fails 2 "required map-tools probe is unavailable"
  expect_no_path command-gates-helper-fails "$PROJECT_DIR/.lbwc-planning"

  assert_no_case_failures
}

@test "indexer-sync gate order: team and build run the helper before any state work" {
  local gate_line enable_line preflight_line catalog_line phase_line plan_line

  gate_line="$(grep -n 'indexer-sync.sh' "$REPO_ROOT/commands/team.md" | cut -d: -f1)"
  catalog_line="$(grep -n 'lbwc-model" refresh' "$REPO_ROOT/commands/team.md" | cut -d: -f1)"
  enable_line="$(grep -n 'agent-teams-enable --approved' "$REPO_ROOT/commands/team.md" | cut -d: -f1)"
  preflight_line="$(grep -n '\*\*Preflight (read-only)\.\*\*' "$REPO_ROOT/commands/team.md" | cut -d: -f1)"
  [ "$gate_line" -lt "$enable_line" ] || record_case_failure team-before-enable "gate=$gate_line enable=$enable_line"
  [ "$gate_line" -lt "$preflight_line" ] || record_case_failure team-before-preflight "gate=$gate_line preflight=$preflight_line"
  [ "$gate_line" -lt "$catalog_line" ] || record_case_failure team-before-catalog "gate=$gate_line catalog=$catalog_line"
  [ "$catalog_line" -lt "$preflight_line" ] || record_case_failure catalog-before-preflight "catalog=$catalog_line preflight=$preflight_line"

  gate_line="$(grep -n 'bash "{LINK}/scripts/indexer-sync.sh"' "$REPO_ROOT/commands/build.md" | cut -d: -f1)"
  phase_line="$(grep -n 'phase-detect.sh' "$REPO_ROOT/commands/build.md" | cut -d: -f1)"
  plan_line="$(grep -n 'Read the selected root' "$REPO_ROOT/commands/build.md" | cut -d: -f1)"
  [ "$gate_line" -lt "$phase_line" ] || record_case_failure build-before-phase "gate=$gate_line phase=$phase_line"
  [ "$gate_line" -lt "$plan_line" ] || record_case_failure build-before-plan "gate=$gate_line plan=$plan_line"

  assert_no_case_failures
}
