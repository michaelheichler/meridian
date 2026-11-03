logging_gate() {
  bash -c '. "$1"; debug_logging_gate fixture PreToolUse; printf "visible output\n"; printf "visible error\n" >&2; exit "$2"' logging "$SCRIPTS_DIR/lib/debug-logging.sh" "$1"
}

logging_capture() {
  logging_gate "$1" > "$2-out" 2> "$2-err"
}
logging_decision() {
  local code=$1 decision=$2 reason=$3
  run logging_gate "$code"
  [ "$status" -eq "$code" ]
  [ "$output" = $'visible output\nvisible error' ]
  grep -Eq " component=gate event=PreToolUse check=fixture decision=$decision duration_ms=[0-9]+ reason=$reason$" "$LBWC_PLANNING_DIR/.debug.log"
  [ "$(wc -l < "$LBWC_PLANNING_DIR/.debug.log" | tr -d ' ')" -eq 1 ]
}
logging_allow() { logging_decision 0 allow completed; }
logging_deny() { logging_decision 2 deny blocked; }
logging_error() { logging_decision 1 error nonzero; }
logging_timeout() { logging_decision 124 timeout deadline; }
logging_disabled() {
  local config=$1
  printf '{}\n' > "$LBWC_PLANNING_DIR/config.json"
  run logging_capture 2 baseline
  local baseline_status=$status
  printf '%s\n' "$config" > "$LBWC_PLANNING_DIR/config.json"
  run logging_capture 2 configured
  [ "$status" -eq "$baseline_status" ]
  cmp baseline-out configured-out
  cmp baseline-err configured-err
  [ -z "$(find "$LBWC_PLANNING_DIR" -name '.debug.log*' -print)" ]
}
logging_missing() { logging_disabled '{}'; }
logging_off() { logging_disabled '{"debug_logging":false}'; }
logging_payload() {
  jq -n --arg cwd "$PWD" '{cwd:$cwd,hook_event_name:"PreToolUse",tool_name:"Read",tool_input:{file_path:"PAYLOAD_SECRET_921"}}' > payload
  run bash -c 'python3 "$1/hooks/dispatch.py" < payload' logging "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  python3 -c 'import pathlib,re,sys
text=pathlib.Path(sys.argv[1]).read_text()
assert text
assert "PAYLOAD_SECRET_921" not in text
pattern=r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ component=(gate|dispatcher) event=PreToolUse check=[a-z_-]+(\.sh)? decision=(allow|deny|warn|error|timeout|retry) duration_ms=(\d+|unknown) reason=[a-z_]+"
assert all(re.fullmatch(pattern,line) for line in text.splitlines())' "$LBWC_PLANNING_DIR/.debug.log"
}
logging_readonly() {
  chmod u-w "$LBWC_PLANNING_DIR"
  run logging_gate 2
  [ "$status" -eq 2 ]
  [ "$output" = $'visible output\nvisible error' ]
  [ ! -e "$LBWC_PLANNING_DIR/.debug.log" ]
}
logging_missing_dir() {
  . "$SCRIPTS_DIR/lib/debug-logging.sh"
  debug_logging_init
  rm -r "$LBWC_PLANNING_DIR"
  run debug_logging_append gate PreToolUse fixture deny 0 blocked
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$LBWC_PLANNING_DIR" ]
}
logging_slow() {
  mkdir plugin
  cp -R "$PROJECT_ROOT/hooks" "$SCRIPTS_DIR" plugin/
  jq -n --arg cwd "$PWD" '{cwd:$cwd,session_id:"logging-session",hook_event_name:"PreToolUse",tool_name:"AskUserQuestion",tool_input:{}}' > payload
  printf '{}\n' > "$LBWC_PLANNING_DIR/config.json"
  run bash -c 'python3 plugin/hooks/dispatch.py < payload > baseline-out 2> baseline-err'
  local baseline_status=$status
  grep -q '"permissionDecision": "deny"' baseline-out
  printf '{"debug_logging":true}\n' > "$LBWC_PLANNING_DIR/config.json"
  python3 -c 'import pathlib,sys
path=pathlib.Path(sys.argv[1])
text=path.read_text()
text=text.replace("debug_logging_append() (", "debug_logging_append() (\n  touch \"$DEBUG_LOGGING_DIR/delay-started\"\n  sleep 6")
path.write_text(text)' plugin/scripts/lib/debug-logging.sh
  run bash -c 'python3 plugin/hooks/dispatch.py < payload > slow-out 2> slow-err'
  [ "$status" -eq "$baseline_status" ]
  cmp baseline-out slow-out
  cmp baseline-err slow-err
  [ -e "$LBWC_PLANNING_DIR/delay-started" ]
}
logging_ignored() {
  run bash "$SCRIPTS_DIR/planning-git.sh" sync-ignore
  [ "$status" -eq 0 ]
  printf 'current\n' > "$LBWC_PLANNING_DIR/.debug.log"
  printf 'archive\n' > "$LBWC_PLANNING_DIR/.debug.log.1"
  run git check-ignore .lbwc-planning/.debug.log .lbwc-planning/.debug.log.1
  [ "$status" -eq 0 ]
  [ "$output" = $'.lbwc-planning/.debug.log\n.lbwc-planning/.debug.log.1' ]
}
logging_append() {
  bash -c '. "$1"; DEBUG_LOGGING_ENABLED=true; DEBUG_LOGGING_DIR="$2"; debug_logging_append gate PreToolUse fixture allow 0 completed' logging "$SCRIPTS_DIR/lib/debug-logging.sh" "$LBWC_PLANNING_DIR"
}
logging_boundary() {
  logging_append
  local length
  length=$(wc -c < "$LBWC_PLANNING_DIR/.debug.log")
  python3 -c 'import pathlib,sys
pathlib.Path(sys.argv[1]).write_bytes(b"x" * (1048576-int(sys.argv[2])))' "$LBWC_PLANNING_DIR/.debug.log" "$length"
  logging_append
}
logging_exact_limit() {
  logging_boundary
  [ "$(wc -c < "$LBWC_PLANNING_DIR/.debug.log" | tr -d ' ')" -eq 1048576 ]
  [ ! -e "$LBWC_PLANNING_DIR/.debug.log.1" ]
}
logging_rotate() {
  logging_boundary
  cp "$LBWC_PLANNING_DIR/.debug.log" expected-archive
  printf 'older archive\n' > "$LBWC_PLANNING_DIR/.debug.log.1"
  logging_append
  cmp expected-archive "$LBWC_PLANNING_DIR/.debug.log.1"
  [ "$(wc -l < "$LBWC_PLANNING_DIR/.debug.log" | tr -d ' ')" -eq 1 ]
  grep -q 'decision=allow.*reason=completed' "$LBWC_PLANNING_DIR/.debug.log"
}
logging_concurrent() {
  local writer pid pids=()
  for writer in 1 2 3 4 5 6 7 8; do
    logging_append &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do wait "$pid"; done
  python3 -c 'import pathlib,re,sys
lines=pathlib.Path(sys.argv[1]).read_text().splitlines()
assert len(lines)==8
assert all(re.fullmatch(r"\S+ component=gate event=PreToolUse check=fixture decision=allow duration_ms=0 reason=completed",line) for line in lines)' "$LBWC_PLANNING_DIR/.debug.log"
}
config_fixture() {
  mkdir -p fixture/commands fixture/scripts/lib
  printf '| Key | Type | Default | Purpose |\n| sample | boolean | false | Sample setting |\n' > fixture/commands/config.md
  printf 'jq '\''.sample'\'' "$config_path"\n' > fixture/scripts/read.sh
  printf '.sample | type == "boolean"\n' > fixture/scripts/lib/lbwc-config-validate.jq
}
config_run() {
  run python3 "$SCRIPTS_DIR/dev/check_config_keys.py" "$PWD/fixture"
}
config_matching() {
  config_fixture
  config_run
  [ "$status" -eq 0 ]
}
config_unread() {
  config_fixture
  rm fixture/scripts/read.sh
  config_run
  [ "$status" -eq 1 ]
  [[ "$output" == *'Documented without a reader  sample'* ]]
}
config_undocumented() {
  config_fixture
  printf '| Key | Type | Default | Purpose |\n' > fixture/commands/config.md
  config_run
  [ "$status" -eq 1 ]
  [[ "$output" == *'Read without documentation  sample'* ]]
}
config_stored() {
  config_fixture
  rm fixture/scripts/read.sh
  printf '| sample | boolean | false | [persistence-only] |\n' > fixture/commands/config.md
  config_run
  [ "$status" -eq 0 ]
}
config_real() {
  run python3 "$SCRIPTS_DIR/dev/check_config_keys.py" "$PROJECT_ROOT"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" > audit-output
  python3 -c 'import pathlib,sys
lines=pathlib.Path(sys.argv[1]).read_text().splitlines()
missing={line.split()[4] for line in lines if line.startswith("Documented without a reader  ")}
extra={line.split()[3] for line in lines if line.startswith("Read without documentation  ")}
assert missing == {"tmux_execution.restrictions"}, missing
assert extra == set(), extra' audit-output
}
