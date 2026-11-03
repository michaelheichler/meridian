meridian_control_root_canonical_path() {
  local candidate="$1"
  [ -n "$candidate" ] || return 1
  [ -d "$candidate" ] || return 1
  [ ! -L "$candidate" ] || return 1
  (CDPATH='' cd -- "$candidate" 2>/dev/null && pwd -P 2>/dev/null) || return 1
}

meridian_control_root_is_valid_json() {
  local config_path="$1"
  command -v jq >/dev/null 2>&1 || return 1
  [ -f "$config_path" ] || return 1
  jq -e 'type == "object"' "$config_path" >/dev/null 2>&1
}

meridian_control_root_export() {
  export MERIDIAN_CONTROL_ROOT_KIND="$1"
  export MERIDIAN_CONTROL_ROOT="$2"
  export MERIDIAN_PROJECT_ROOT="$3"
  printf '%s\n' "$2"
}

meridian_control_root_validate_planning() {
  local canonical="$1" allow_manifest_only="$2"
  if ! meridian_control_root_is_valid_json "$canonical/config.json"; then
    [ "$allow_manifest_only" = "1" ] || return 1
    [ -f "$canonical/.agent-manifest.json" ] || return 1
  fi
  meridian_control_root_export "active-planning" "$canonical" "$(dirname "$canonical")"
}

meridian_control_root_validate_run() {
  local canonical="$1" run_parent run_parent_parent run_id
  run_parent=$(dirname "$canonical")
  run_parent_parent=$(dirname "$run_parent")
  run_id=$(basename "$canonical")
  [ "$(basename "$run_parent")" = "runs" ] || return 1
  [ "$(basename "$run_parent_parent")" = ".temporary-agent-runfiles" ] || return 1
  [[ "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  meridian_control_root_export "temporary-run" "$canonical" "$(dirname "$run_parent_parent")"
}

meridian_control_root_validate() {
  local candidate="$1" allow_manifest_only="${2:-0}" canonical

  canonical=$(meridian_control_root_canonical_path "$candidate") || return 1
  case "$(basename "$canonical")" in
    .meridian)
      meridian_control_root_validate_planning "$canonical" "$allow_manifest_only" || return 1
      return 0
      ;;
  esac
  meridian_control_root_validate_run "$canonical"
}

meridian_control_root_project_root() {
  local control_root
  control_root=$(meridian_control_root_canonical_path "$1") || return 1
  case "$(basename "$control_root")" in
    .meridian) dirname "$control_root" ;;
    *) dirname "$(dirname "$(dirname "$control_root")")" ;;
  esac
}

meridian_control_root_manifest_path() {
  local control_root
  control_root=$(meridian_control_root_canonical_path "$1") || return 1
  if [ "$(basename "$control_root")" = ".meridian" ]; then
    printf '%s/.agent-manifest.json\n' "$control_root"
  else
    printf '%s/agent-manifest.json\n' "$control_root"
  fi
}

meridian_control_root_lock_path() {
  local control_root
  control_root=$(meridian_control_root_canonical_path "$1") || return 1
  if [ "$(basename "$control_root")" = ".meridian" ]; then
    printf '%s/.agent-manifest.lock\n' "$control_root"
  else
    printf '%s/agent-manifest.lock\n' "$control_root"
  fi
}

meridian_control_root_workflow_manifest_path() {
  local control_root
  control_root=$(meridian_control_root_canonical_path "$1") || return 1
  if [ "$(basename "$control_root")" = ".meridian" ]; then
    printf '%s/.workflow-manifest.json\n' "$control_root"
  else
    printf '%s/workflow-manifest.json\n' "$control_root"
  fi
}

meridian_control_root_workflow_manifest_lock_path() {
  local control_root
  control_root=$(meridian_control_root_canonical_path "$1") || return 1
  if [ "$(basename "$control_root")" = ".meridian" ]; then
    printf '%s/.workflow-manifest.lock\n' "$control_root"
  else
    printf '%s/workflow-manifest.lock\n' "$control_root"
  fi
}

meridian_control_root_workflows_dir() {
  local control_root
  control_root=$(meridian_control_root_canonical_path "$1") || return 1
  printf '%s/workflows\n' "$control_root"
}

meridian_control_root_contracts_dir() {
  local control_root
  control_root=$(meridian_control_root_canonical_path "$1") || return 1
  if [ "$(basename "$control_root")" = ".meridian" ]; then
    printf '%s/.contracts/tasks\n' "$control_root"
  else
    printf '%s/contracts/tasks\n' "$control_root"
  fi
}

meridian_control_root_generated_agents_dir() {
  local project_root
  project_root=$(meridian_control_root_project_root "$1") || return 1
  printf '%s/.claude/agents\n' "$project_root"
}

meridian_control_root_find_run() {
  local current="$1" candidate="$1/.temporary-agent-runfiles/runs" run_candidate selected_run=""
  [ -d "$candidate" ] || return 2
  for run_candidate in "$candidate"/*; do
    [ -d "$run_candidate" ] || continue
    if [ "$current" = "$(meridian_control_root_project_root "$run_candidate" 2>/dev/null || true)" ] && meridian_control_root_validate "$run_candidate" 0 >/dev/null 2>&1; then
      [ -z "$selected_run" ] || return 1
      selected_run=$(meridian_control_root_canonical_path "$run_candidate") || return 1
    fi
  done
  [ -n "$selected_run" ] || return 2
  printf '%s\n' "$selected_run"
}

meridian_control_root_find_from_start() {
  local start="$1" current candidate run_status
  current=$(CDPATH='' cd -- "$start" 2>/dev/null && pwd -P) || return 1
  while :; do
    candidate="$current/.meridian"
    if [ -d "$candidate" ] && meridian_control_root_validate "$candidate" 1 >/dev/null 2>&1; then
      printf '%s\n' "$(meridian_control_root_canonical_path "$candidate")"
      return 0
    fi

    run_status=0
    meridian_control_root_find_run "$current" || run_status=$?
    [ "$run_status" -ne 0 ] || return 0
    [ "$run_status" -ne 1 ] || return 1

    [ "$current" = "/" ] && break
    current=$(dirname "$current")
  done
  return 1
}

meridian_resolve_control_root() {
  local requested_control="${1:-}" requested_project="${2:-}" start="${3:-${PWD:-}}" candidate

  if [ -n "$requested_control" ]; then
    meridian_control_root_validate "$requested_control" 0
    return $?
  fi
  if [ -n "${MERIDIAN_CONTROL_ROOT:-}" ]; then
    meridian_control_root_validate "$MERIDIAN_CONTROL_ROOT" 0
    return $?
  fi
  if [ -n "${MERIDIAN_PLANNING_DIR:-}" ]; then
    meridian_control_root_validate "$MERIDIAN_PLANNING_DIR" 1
    return $?
  fi
  if [ -n "$requested_project" ]; then
    candidate=$(CDPATH='' cd -- "$requested_project" 2>/dev/null && pwd -P)/.meridian || return 1
    meridian_control_root_validate "$candidate" 0
    return $?
  fi
  meridian_control_root_find_from_start "$start"
}
