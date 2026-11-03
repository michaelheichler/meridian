worktree_isolation_enabled() {
  local isolation_config isolation_value isolation_project isolation_path="$1/config.json"
  if [ ! -e "$isolation_path" ]; then
    isolation_project=$(lbwc_control_root_project_root "$1") || fail 'cannot resolve worktree isolation project'
    isolation_path="$isolation_project/.lbwc-planning/config.json"
  fi
  isolation_config=$(read_existing_config "$isolation_path") || fail 'cannot read worktree isolation configuration'
  isolation_value=$(jq -er '.worktree_isolation as $isolation | if has("worktree_isolation") then ($isolation | if type == "string" then . else "__invalid__" end) else "off" end' <<<"$isolation_config") || fail 'cannot read worktree_isolation'
  case "$isolation_value" in
    on) return 0 ;;
    off) return 1 ;;
    *) fail 'worktree_isolation must be off or on' ;;
  esac
}

worker_may_write_code() {
  case "$1" in
    Explore|Plan|coding-dijkstra-critic|python-critic|web-code-critic|lead-critic|qa|ux-oracle|deviq|architect|scout|docs|lead) return 1 ;;
    *) return 0 ;;
  esac
}
