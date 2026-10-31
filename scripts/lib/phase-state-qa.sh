qa_state_value() {
  local fallback="$1" state_file="$2" phase_num="$3" filter="$4"
  jq -r --arg phase "$phase_num" "$filter" "$state_file" 2>/dev/null || printf '%s\n' "$fallback"
}

qa_explicit_flag() {
  local value
  value=$(qa_state_value "__absent__" "$1" "$2" "$3")
  if [ "$value" = "true" ] || [ "$value" = "false" ]; then
    printf '%s\n' "$value"
    return 0
  fi
  return 1
}

qa_state_phase_differs() {
  local state_file="$1" phase_num="$2" state_phase
  state_phase=$(qa_state_value "__absent__" "$state_file" "$phase_num" '.phase // "__absent__"')
  [ "$state_phase" != "__absent__" ] && [ "$state_phase" != "$phase_num" ] && [ "$(printf '%s' "$state_phase" | sed 's/^0*//')" != "$phase_num" ]
}

qa_turbo_effort() {
  local state_file="$1" effort phase_effort
  effort=$(qa_state_value "" "$state_file" "" '.effort // ""')
  phase_effort=$(qa_state_value "" "$state_file" "" '.phase_effort // ""')
  if [ "$effort" = "turbo" ] || [ "$phase_effort" = "turbo" ]; then
    printf '%s\n' "false"
  else
    printf '%s\n' "true"
  fi
}

qa_required_for_phase() {
  local phase_dir="$1"
  local planning_root state_file phase_num

  planning_root=$(planning_root_from_phase_dir "$phase_dir")
  state_file="${planning_root}/.execution-state.json"
  if [ ! -f "$state_file" ]; then
    printf '%s\n' "true"
    return 0
  fi

  phase_num=$(basename "${phase_dir%/}" | sed 's/^\([0-9]*\).*/\1/' | sed 's/^0*//')
  phase_num="${phase_num:-0}"
  qa_explicit_flag "$state_file" "$phase_num" 'if (.phase_qa_required | type) == "object" and (.phase_qa_required | has($phase)) then .phase_qa_required[$phase] else "__absent__" end' && return 0
  if qa_state_phase_differs "$state_file" "$phase_num"; then
    printf '%s\n' "true"
    return 0
  fi
  qa_explicit_flag "$state_file" "$phase_num" 'if has("qa_required") then .qa_required else "__absent__" end' && return 0
  qa_turbo_effort "$state_file"
}
