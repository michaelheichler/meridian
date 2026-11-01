claude_config_dir() {
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    printf '%s\n' "$CLAUDE_CONFIG_DIR"
  elif [ -d "$HOME/.config/claude-code" ]; then
    printf '%s\n' "$HOME/.config/claude-code"
  else
    printf '%s\n' "$HOME/.claude"
  fi
}

integration_binary() {
  if command -v rtk >/dev/null 2>&1; then
    command -v rtk
  elif [ -x "$RTK_BINARY" ]; then
    printf '%s\n' "$RTK_BINARY"
  else
    return 1
  fi
}

hook_is_active() {
  local settings="$1" hook="$2"
  [ -f "$settings" ] || return 1
  jq -e --arg hook "$hook" 'any(.hooks.PreToolUse[]?.hooks[]?; .type == "command" and ((.command // "") | contains($hook)))' "$settings" >/dev/null 2>&1
}

init_preflight() {
  printf '%s\n' 'RTK hook preflight' \
    'Method: rtk init -g --auto-patch in an isolated staging directory' \
    'Will run: validate the existing RTK binary and publish its generated hook' \
    "Writes: RTK config and Claude Code user config under $(claude_config_dir)" \
    'Fallback: jq patches settings.json and preserves existing PreToolUse hooks' \
    'Restart: restart Claude Code after setup' \
    'Risk: PreToolUse updatedInput can fail, see anthropics/claude-code#15897' \
    'Next step: run init --yes, then the separate Bash-tool runtime smoke'
}

publish_integration() {
  local directory="$1" original="$2" staged="$3" hook settings temporary command
  hook="$directory/hooks/rtk-rewrite.sh"
  settings="$directory/settings.json"
  [ ! -L "$directory" ] && [ ! -L "$directory/hooks" ] && [ ! -L "$settings" ] && [ ! -L "$hook" ] || die 'RTK integration paths must not be symbolic links'
  mkdir -p "$directory/hooks" || die 'cannot create Claude Code hook directory'
  cp "$staged/.claude/hooks/rtk-rewrite.sh" "$hook" || die 'cannot publish generated RTK hook'
  chmod 700 "$hook" || die 'cannot protect generated RTK hook'
  command=$(jq -nr --arg directory "$directory" --arg hook "$hook" '"env XDG_CONFIG_HOME=" + ($directory | @sh) + " bash " + ($hook | @sh)')
  temporary=$(mktemp "$directory/.rtk-settings.XXXXXX") || die 'cannot stage Claude Code settings'
  if ! jq --arg command "$command" --arg hook "$hook" '
    if any(.hooks.PreToolUse[]?.hooks[]?; .type == "command" and ((.command // "") | contains($hook))) then .
    else .hooks.PreToolUse = ((.hooks.PreToolUse // []) + [{matcher:"Bash",hooks:[{type:"command",command:$command}]}]) end
  ' "$original" > "$temporary" || ! chmod 600 "$temporary" || ! mv "$temporary" "$settings"; then
    rm -f "$temporary"
    die 'cannot patch Claude Code settings'
  fi
  if [ -f "$staged/.claude/RTK.md" ]; then
    [ ! -L "$directory/RTK.md" ] || die 'RTK instructions must not be a symbolic link'
    cp "$staged/.claude/RTK.md" "$directory/RTK.md" || die 'cannot publish RTK instructions'
  fi
  hook_is_active "$settings" "$hook" || die 'RTK hook activation failed'
}

publish_rtk_config() {
  local directory="$1" candidate
  [ ! -L "$directory/rtk" ] && [ ! -L "$directory/rtk/config.toml" ] || die 'RTK config must not be a symbolic link'
  [ ! -e "$directory/rtk/config.toml" ] || return 0
  for candidate in "$TEMP_DIR/config/rtk/config.toml" "$TEMP_DIR/home/.config/rtk/config.toml" "$TEMP_DIR/home/Library/Application Support/rtk/config.toml"; do
    [ -f "$candidate" ] || continue
    mkdir -p "$directory/rtk" || die 'cannot create RTK config directory'
    cp "$candidate" "$directory/rtk/config.toml" || die 'cannot publish RTK config'
    chmod 600 "$directory/rtk/config.toml" || die 'cannot protect RTK config'
    return 0
  done
}

init_integration() {
  local dry_run="$1" binary directory original
  init_preflight
  [ "$dry_run" = false ] || return 0
  require_jq
  assert_safe_state
  binary=$(command -v rtk) || die 'init requires an RTK binary already on PATH'
  "$binary" --version >/dev/null 2>&1 || die 'RTK binary validation failed'
  directory=$(claude_config_dir)
  TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lbwc-rtk-init.XXXXXX") || die 'cannot stage RTK integration'
  original="$TEMP_DIR/settings.json"
  if [ -e "$directory/settings.json" ]; then
    cp "$directory/settings.json" "$original" || die 'cannot read Claude Code settings'
  else
    printf '{}\n' > "$original"
  fi
  jq -e 'type == "object" and ((.hooks // {}) | type == "object") and ((.hooks.PreToolUse // []) | type == "array")' "$original" >/dev/null || die 'Claude Code settings are malformed'
  mkdir -p "$TEMP_DIR/home" "$TEMP_DIR/config" "$TEMP_DIR/cache" "$TEMP_DIR/data"
  HOME="$TEMP_DIR/home" CLAUDE_CONFIG_DIR="$TEMP_DIR/home/.claude" XDG_CONFIG_HOME="$TEMP_DIR/config" XDG_CACHE_HOME="$TEMP_DIR/cache" XDG_DATA_HOME="$TEMP_DIR/data" \
    "$binary" init -g --auto-patch || die 'RTK hook setup failed'
  [ -f "$TEMP_DIR/home/.claude/hooks/rtk-rewrite.sh" ] || die 'RTK init did not generate its rewrite hook'
  publish_integration "$directory" "$original" "$TEMP_DIR/home"
  publish_rtk_config "$directory"
  printf 'init: RTK hook active in %s, restart Claude Code and run runtime smoke\n' "$directory"
}

doctor_json() {
  local binary='' directory settings hook compatibility=absent detail='No RTK artifacts found' health=SKIP artifacts=false
  require_jq
  assert_safe_state
  directory=$(claude_config_dir)
  settings="$directory/settings.json"
  hook="$directory/hooks/rtk-rewrite.sh"
  binary=$(integration_binary) || true
  if [ -n "$binary" ] || [ -e "$STATE_DIR" ] || [ -e "$hook" ] || [ -e "$directory/RTK.md" ] || [ -d "$directory/rtk" ] || [ -d "${XDG_CONFIG_HOME:-$HOME/.config}/rtk" ] \
    || [ -d "$HOME/Library/Application Support/rtk" ] || [ -e "$PWD/.claude/RTK.md" ] || [ -e "$PWD/.claude/hooks/rtk-rewrite.sh" ]; then
    artifacts=true
    health=WARN
    compatibility=unverified
    detail='RTK artifacts exist, runtime hook proof is required'
  fi
  if [ -e "$settings" ] && ! jq -e 'type == "object"' "$settings" >/dev/null 2>&1; then
    health=WARN
    detail='Claude Code settings are unreadable or malformed'
  elif hook_is_active "$settings" "$hook"; then
    artifacts=true
    health=WARN
    compatibility=hook_active_unverified
    detail='RTK hook is active, runtime hook proof is required'
  fi
  jq -cn --arg doctor_status "$health" --arg doctor_detail "$detail" --arg compatibility "$compatibility" --arg binary "$binary" --argjson artifacts "$artifacts" \
    '{doctor_status:$doctor_status,doctor_detail:$doctor_detail,compatibility:$compatibility,compatibility_basis:"offline static inspection",rtk_present:($binary != ""),artifacts_present:$artifacts,updated_input_risk:true,proof_source:null,diagnostic_caveat:"Local proxy smoke does not prove PreToolUse updatedInput rewrites",upstream_issue:"anthropics/claude-code#15897"}'
}

smoke_start() {
  local directory project transcript='' nonce marker start=0
  require_jq
  ensure_state_dir
  directory=$(claude_config_dir)
  project=$(pwd -P | tr '/.' '--')
  case "${CLAUDE_SESSION_ID:-}" in
    ''|*[!a-zA-Z0-9_-]*) ;;
    *) transcript="$directory/projects/$project/$CLAUDE_SESSION_ID.jsonl" ;;
  esac
  if [ -n "$transcript" ] && [ -r "$transcript" ]; then
    start=$(wc -l < "$transcript" | tr -d ' ')
  fi
  marker=$(mktemp "$STATE_DIR/.smoke-nonce.XXXXXX") || die 'cannot create smoke nonce'
  nonce=${marker##*/}
  if ! jq -cn --arg nonce "$nonce" --arg transcript "$transcript" --argjson start "$start" \
    '{nonce:$nonce,transcript:$transcript,start_line:$start,compatibility:"unverified"}' > "$marker" || ! chmod 600 "$marker" || ! mv "$marker" "$STATE_DIR/rtk-smoke.json"; then
    rm -f "$marker"
    die 'cannot save smoke start marker'
  fi
  printf 'RTK smoke start %s\nRun separate Bash tool calls in order\nls -la .\ngit status --short\ngit log -n 2 --oneline\nThen run smoke-finish\n' "$nonce"
}

smoke_finish() {
  local marker="$STATE_DIR/rtk-smoke.json" transcript start observed='[]' nonce
  require_jq
  assert_safe_state
  [ -f "$marker" ] && [ ! -L "$marker" ] || die 'smoke-finish requires smoke-start'
  jq -e '(.nonce | type == "string") and (.transcript | type == "string") and (.start_line | type == "number" and . >= 0)' "$marker" >/dev/null || die 'smoke marker is malformed'
  nonce=$(jq -r '.nonce' "$marker")
  transcript=$(jq -r '.transcript' "$marker")
  start=$(jq -r '.start_line + 1' "$marker")
  if [ -n "$transcript" ] && [ -r "$transcript" ]; then
    path_is_within "$transcript" "$(claude_config_dir)/projects" || die 'smoke transcript is outside Claude Code projects'
    observed=$(tail -n "+$start" "$transcript" | jq -sc '
      [.[] | .message.content[]? | select(.type == "tool_use" and .name == "Bash") | .input.command
       | select(. == "ls -la ." or . == "git status --short" or . == "git log -n 2 --oneline")]
    ') || die 'smoke transcript is malformed'
  fi
  jq -cn --arg nonce "$nonce" --argjson observed "$observed" \
    '{nonce:$nonce,observed_commands:$observed,compatibility:"unverified",proof_source:null,diagnostic_caveat:"Transcript command requests alone do not prove successful RTK updatedInput rewrites. No authoritative rewrite evidence collector is installed."}'
}

integration_smoke() {
  local json="$1" state
  assert_safe_state
  RTK_BINARY=$(integration_binary) || die 'smoke requires an existing RTK binary'
  TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lbwc-rtk-smoke.XXXXXX") || die 'cannot isolate RTK smoke tracking'
  state=$(RTK_DB_PATH="$TEMP_DIR/tracking.db" smoke) || die 'RTK local proxy smoke failed'
  if [ "$json" = true ]; then
    require_jq
    jq -cn --arg state "$state" '{local_smoke:"pass",claude_code_smoke:$state,compatibility:"unverified",proof_source:null}'
  else
    printf 'smoke: local proxy passed, Claude Code %s, compatibility=unverified\n' "$state"
  fi
}
