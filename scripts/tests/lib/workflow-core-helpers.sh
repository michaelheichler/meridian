check() {
  local description="$1" condition="$2"
  if [ "$condition" -eq 0 ]; then
    printf 'PASS: %s\n' "$description"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s\n' "$description"
    FAIL=$((FAIL + 1))
  fi
}

check_test() {
  local description="$1"
  shift
  if test "$@"; then
    check "$description" 0
  else
    check "$description" 1
  fi
}

new_project() {
  local dir
  dir=$(mktemp -d "$WORK_ROOT/project.XXXXXX")
  mkdir -p "$dir/.meridian"
  printf '%s\n' "$dir"
}

new_control_root() {
  local project="$1" run_id="$2" control_root roles_json
  shift 2
  control_root="$project/.temporary-agent-runfiles/runs/$run_id"
  mkdir -p "$control_root"
  roles_json='{}'
  while [ "$#" -ge 3 ]; do
    roles_json=$(jq -c --arg r "$1" --arg m "$2" --arg e "$3" '. + {($r): {model:$m, reasoning:$e, status:"resolved"}}' <<< "$roles_json")
    shift 3
  done
  jq -n --argjson roles "$roles_json" '{schema_version:1, routing_source:"temporary-control-root", routing:{active_profile:"balanced", profiles:{balanced:{roles:$roles}}}}' \
    > "$control_root/routing.json"
  jq -n '{workflow_execution:{enabled:true}}' > "$control_root/config.json"
  jq -n '{workflow:{available:true, unavailable_reasons:[]}}' > "$control_root/claude-capabilities.json"
  printf '%s\n' "$control_root"
}

run_with_modern_bash() {
  env PATH="$(dirname "$GENERATOR_BASH"):$PATH" "$GENERATOR_BASH" "$@"
}

engineer_name_from_output() {
  printf '%s\n' "$1" | grep '^ENGINEER: SPAWN_READY' | awk '{print $3}'
}

critic_name_from_output() {
  printf '%s\n' "$1" | grep '^CRITIC: SPAWN_READY' | awk '{print $3}'
}

nth_spawn_ready_name() {
  printf '%s\n' "$1" | grep 'SPAWN_READY' | sed -n "${2}p" | awk '{print $NF}'
}

forbidden_token_confined_to_known_lines() {
  local file="$1" forbidden="$2" leaked
  leaked=$(grep -Fn "$forbidden" "$file" | grep -v '^1:' | grep -v 'const JOB = ')
  [ -z "$leaked" ]
}
