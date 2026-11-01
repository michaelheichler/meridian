#!/usr/bin/env bats

load capability_helper

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  test_root="$(mktemp -d)"
  TEST_ROOT="$(cd "$test_root" && pwd -P)"
  PLUGIN_ROOT="$TEST_ROOT/plugin"
  PROJECT="$TEST_ROOT/init-project"
  TRACE="$TEST_ROOT/init-trace"
  mkdir -p "$PLUGIN_ROOT/scripts" "$PROJECT/.lbwc-planning"
}

teardown() {
  rm -rf "$TEST_ROOT"
}

extract_init_bootstrap() {
  # Template blocks come first, so skip to the lbwc-config.sh block.
  awk '
    /^[[:space:]]*```bash$/ { capture = 1; block = ""; next }
    capture && /^[[:space:]]*```$/ {
      if (block ~ /lbwc-config\.sh/) { printf "%s", block; exit }
      capture = 0
      next
    }
    capture { sub(/^[[:space:]]{3}/, ""); block = block $0 "\n" }
  ' "$REPO_ROOT/commands/init.md"
}

write_tracing_stub() {
  local path="$1" label="$2" exit_code="$3"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    "printf '$label:%s\\n' \"\$*\" >> \"\$INIT_TRACE\"" \
    "exit $exit_code" > "$path"
  chmod +x "$path"
}

expected_trace() {
  case "$1" in
    config) printf '%s' 'lbwc-config:init .lbwc-planning' ;;
    config-then-model) printf '%s\n%s' 'lbwc-config:init .lbwc-planning' 'lbwc-model:refresh .lbwc-planning' ;;
  esac
}

@test "init bootstrap runs configuration then one model refresh and fails closed on any failure" {
  local bootstrap failure_message='LBWC model catalog and routing refresh failed.' printed

  bootstrap=$(extract_init_bootstrap)
  [ -n "$bootstrap" ]

  while IFS='|' read -r label config_exit model_exit expected_status trace_kind shows_message; do
    [ -n "$label" ] || continue
    rm -f "$TRACE" "$PLUGIN_ROOT/scripts/lbwc-model"
    write_tracing_stub "$PLUGIN_ROOT/scripts/lbwc-config.sh" lbwc-config "$config_exit"
    [ "$model_exit" = absent ] || write_tracing_stub "$PLUGIN_ROOT/scripts/lbwc-model" lbwc-model "$model_exit"

    run env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" INIT_TRACE="$TRACE" bash -c "cd \"$PROJECT\" && $bootstrap" </dev/null

    [ "$status" -eq "$expected_status" ] || { case_fail "$label" "status=$status expected=$expected_status"; return 1; }
    [ "$(cat "$TRACE")" = "$(expected_trace "$trace_kind")" ] \
      || { case_fail "$label" "trace=$(cat "$TRACE")"; return 1; }
    printed=no
    [[ "$output" == *"$failure_message"* ]] && printed=yes
    [ "$printed" = "$shows_message" ] || { case_fail "$label" "failure message printed=$printed expected=$shows_message"; return 1; }
  done <<'CASES'
config-fails|31|0|1|config|no
model-refresh-fails|0|47|1|config-then-model|yes
both-succeed|0|0|0|config-then-model|no
model-cli-missing|0|absent|1|config|yes
CASES
}
