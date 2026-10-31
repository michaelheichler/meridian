TEAMS_SETTINGS_PATH=""
TEAMS_PROJECT_ROOT=""
TEAMS_APPROVED=false
TEAMS_EXPLICIT=false

default_claude_settings_path() {
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    printf '%s\n' "$CLAUDE_CONFIG_DIR/settings.json"
  elif [ -d "$HOME/.config/claude-code" ]; then
    printf '%s\n' "$HOME/.config/claude-code/settings.json"
  else
    printf '%s\n' "$HOME/.claude/settings.json"
  fi
}

agent_teams_file_is_object() {
  jq -e 'type == "object"' "$1" >/dev/null 2>&1
}

agent_teams_file_setting() {
  local settings_path="$1" setting_value
  [ -f "$settings_path" ] || return 1
  agent_teams_file_is_object "$settings_path" || return 1
  if ! jq -e '(.env | type) == "object" and (.env | has("CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"))' \
    "$settings_path" >/dev/null 2>&1; then
    return 1
  fi
  setting_value=$(jq -r '.env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS | tostring' "$settings_path")
  printf '%s\n' "$setting_value"
}

agent_teams_settings_candidates() {
  local settings_path="$1" project_root="$2" settings_explicit="$3"
  local dir
  if [ "$settings_explicit" = true ]; then
    printf '%s\n' "$settings_path"
    return 0
  fi
  dir=$(dirname "$settings_path")
  if [ -n "$project_root" ]; then
    printf '%s\n' "$project_root/.claude/settings.local.json"
    printf '%s\n' "$project_root/.claude/settings.json"
  fi
  printf '%s\n' "$dir/settings.local.json"
  printf '%s\n' "$settings_path"
}

agent_teams_environment_status() {
  [ -n "${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS+x}" ] || return 1
  if [ "$CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS" = "1" ]; then
    jq -n '{enabled:true,source:"environment"}'
  else
    jq -n '{enabled:false,source:"environment"}'
  fi
}

agent_teams_candidate_status() {
  local candidate="$1" fail_closed="$2" setting_value
  if [ -f "$candidate" ] && ! agent_teams_file_is_object "$candidate"; then
    [ "$fail_closed" = true ] && fail "settings file is not valid JSON: $candidate"
    return 1
  fi
  setting_value=$(agent_teams_file_setting "$candidate") || return 1
  if [ "$setting_value" = "1" ]; then
    jq -n --arg path "$candidate" '{enabled:true,source:"settings",settings_path:$path}'
  else
    jq -n --arg path "$candidate" '{enabled:false,source:"settings",settings_path:$path}'
  fi
}

agent_teams_status() {
  local settings_path="$1" project_root="$2" settings_explicit="$3"
  local candidate seen="" fail_closed=false
  agent_teams_environment_status && return 0
  [ "$settings_explicit" = true ] && fail_closed=true
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    case " $seen " in
      *" $candidate "*) continue ;;
    esac
    seen="$seen $candidate"
    agent_teams_candidate_status "$candidate" "$fail_closed" && return 0
  done < <(agent_teams_settings_candidates "$settings_path" "$project_root" "$settings_explicit")
  jq -n --arg path "$settings_path" '{enabled:false,source:"none",settings_path:$path}'
}

agent_teams_check() {
  local status_json enabled
  status_json=$(agent_teams_status "$1" "$2" "$3")
  enabled=$(jq -r '.enabled' <<< "$status_json")
  if [ "$enabled" = true ]; then
    printf '%s\n' 'TEAM CHECK IS ENABLED. MOVE TO THE NEXT CHECK.'
  else
    printf '%s\n' 'TEAM CHECK IS NOT ENABLED.'
  fi
}

agent_teams_enable() {
  local settings_path="$1" approved="$2" temporary
  [ "$approved" = true ] || fail 'agent teams setting requires explicit approval'
  mkdir -p "$(dirname "$settings_path")"
  [ -f "$settings_path" ] || printf '{}\n' > "$settings_path"
  jq -e 'type == "object"' "$settings_path" >/dev/null 2>&1 || fail "settings file is not valid JSON: $settings_path"
  temporary="${settings_path}.lbwc-agent-teams.tmp.${BASHPID:-$$}"
  jq '.env = (.env // {}) | .env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1"' "$settings_path" > "$temporary" || {
    rm -f "$temporary"
    fail "could not write agent teams setting: $settings_path"
  }
  mv -f "$temporary" "$settings_path" || {
    rm -f "$temporary"
    fail "could not persist agent teams setting: $settings_path"
  }
  jq -n --arg path "$settings_path" '{enabled:true,source:"settings",settings_path:$path,restart_required:true,message:"Agent Teams enabled in settings. You must restart Claude Code before running /lbwc:team."}'
}

parse_agent_teams_options() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --settings)
        [ "$#" -ge 2 ] || fail '--settings requires a path'
        TEAMS_SETTINGS_PATH="$2"
        TEAMS_EXPLICIT=true
        shift 2
        ;;
      --project-root)
        [ "$#" -ge 2 ] || fail '--project-root requires a path'
        TEAMS_PROJECT_ROOT="$2"
        shift 2
        ;;
      --approved)
        TEAMS_APPROVED=true
        shift
        ;;
      *)
        fail "unknown agent teams option: $1"
        ;;
    esac
  done
}

dispatch_agent_teams() {
  case "$1" in
    agent-teams-status)
      [ "$TEAMS_APPROVED" = false ] || fail '--approved is not valid for status'
      agent_teams_status "$TEAMS_SETTINGS_PATH" "$TEAMS_PROJECT_ROOT" "$TEAMS_EXPLICIT"
      ;;
    agent-teams-check)
      [ "$TEAMS_APPROVED" = false ] || fail '--approved is not valid for check'
      agent_teams_check "$TEAMS_SETTINGS_PATH" "$TEAMS_PROJECT_ROOT" "$TEAMS_EXPLICIT"
      ;;
    agent-teams-enable) agent_teams_enable "$TEAMS_SETTINGS_PATH" "$TEAMS_APPROVED" ;;
    *) return 1 ;;
  esac
}

global_command() {
  local command="$1"
  shift
  parse_agent_teams_options "$@"
  if [ -z "$TEAMS_SETTINGS_PATH" ]; then
    TEAMS_SETTINGS_PATH=$(default_claude_settings_path)
  fi
  dispatch_agent_teams "$command"
}
