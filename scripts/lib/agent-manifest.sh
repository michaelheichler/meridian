AGENT_MANIFEST_SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$AGENT_MANIFEST_SCRIPT_DIR/meridian-control-root.sh" 2>/dev/null || return 1
. "$AGENT_MANIFEST_SCRIPT_DIR/manifest-lock.sh" 2>/dev/null || return 1

agent_manifest_control_root() {
  local requested="${1:-.meridian}" resolved
  resolved=$(meridian_control_root_validate "$requested" 1 2>/dev/null) || return 1
  printf '%s\n' "$resolved"
}

agent_manifest_path() {
  meridian_control_root_manifest_path "${1:-.meridian}"
}

agent_manifest_lock_path() {
  meridian_control_root_lock_path "${1:-.meridian}"
}

agent_manifest_acquire_lock() {
  local planning_dir="${1:-.meridian}" lock_dir control_root
  control_root=$(agent_manifest_control_root "$planning_dir") || return 1
  lock_dir=$(agent_manifest_lock_path "$control_root")
  manifest_lock_acquire "$lock_dir" AGENT_MANIFEST
}

agent_manifest_release_lock() {
  local lock_dir control_root
  control_root=$(agent_manifest_control_root "${1:-.meridian}") || return 1
  lock_dir=$(agent_manifest_lock_path "$control_root")
  manifest_lock_release "$lock_dir"
}

agent_manifest_with_lock() {
  local planning_dir="${1:-.meridian}" callback="${2:-}" lock_dir control_root
  shift 2 || return 1
  [ -n "$callback" ] || return 1
  control_root=$(agent_manifest_control_root "$planning_dir") || return 1
  lock_dir=$(agent_manifest_lock_path "$control_root")
  manifest_lock_with_lock "$lock_dir" AGENT_MANIFEST "$callback" "$@"
}

agent_manifest_read() {
  local planning_dir="${1:-.meridian}" path control_root
  control_root=$(agent_manifest_control_root "$planning_dir") || return 1
  path=$(agent_manifest_path "$control_root")
  manifest_read "$path" agents
}

agent_manifest_write() {
  local planning_dir="$1" manifest="$2" path control_root
  control_root=$(agent_manifest_control_root "$planning_dir") || return 1
  path=$(agent_manifest_path "$control_root")
  manifest_write "$path" agents "$manifest"
}

agent_manifest_safe_name() {
  case "${1:-}" in
    ''|.|..|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-]*) return 1 ;;
  esac
}

agent_manifest_definition_path() {
  local planning_dir="$1" name="$2" project_root control_root
  agent_manifest_safe_name "$name" || return 1
  control_root=$(agent_manifest_control_root "$planning_dir") || return 1
  project_root=$(meridian_control_root_project_root "$control_root") || return 1
  printf '%s/.claude/agents/%s.md\n' "$project_root" "$name"
}

manifest_new_pair_id() {
  local timestamp rand
  timestamp=$(date +%s%N 2>/dev/null || date +%s)
  rand=$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  [ -n "$rand" ] || rand="$RANDOM$RANDOM"
  printf 'pair-%s-%s\n' "$timestamp" "$rand"
}

manifest_find_open_pair() {
  local planning_dir="${1:-.meridian}" manifest
  manifest=$(agent_manifest_read "$planning_dir") || return 1
  jq -r '
    [.agents[] | select(.pair_id != null and (.state == "registered" or .state == "running"))]
    | group_by(.pair_id)
    | map(select(length == 1))
    | (.[0].[0].pair_id // empty)
  ' <<< "$manifest"
}

manifest_pair_partner_state() {
  local planning_dir="${1:-.meridian}" pair_id="${2:-}" exclude_name="${3:-}" manifest
  [ -n "$pair_id" ] || { printf 'none\n'; return 0; }
  manifest=$(agent_manifest_read "$planning_dir") || return 1
  jq -r --arg pid "$pair_id" --arg exclude "$exclude_name" '
    [.agents[] | select(.pair_id == $pid and .name != $exclude)]
    | (.[0].state // "none")
  ' <<< "$manifest"
}
