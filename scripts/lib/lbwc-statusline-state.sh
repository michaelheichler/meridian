read_frontmatter_value() {
  local path="$1" key="$2"
  [ -f "$path" ] || return 0
  awk -v key="$key" '
    NR == 1 && /^---[[:space:]]*$/ { frontmatter = 1; next }
    frontmatter && /^---[[:space:]]*$/ { exit }
    frontmatter && index($0, key ":") == 1 {
      sub("^[^:]*:[[:space:]]*", "")
      gsub(/["'\''[:space:]]/, "")
      print
      exit
    }
  ' "$path" 2>/dev/null
}

latest_matching_file() {
  local directory="$1" pattern="$2" path latest=""
  [ -d "$directory" ] || return 0
  for path in "$directory"/$pattern; do
    [ -f "$path" ] || continue
    latest="$path"
  done
  [ -n "$latest" ] && printf '%s\n' "$latest"
}

read_native_fields() {
  jq -r '[
    (.model.display_name // .model.id // "Claude"),
    (.effort // .model.effort // .model.reasoning_effort // "default"),
    (.workspace.project_dir // .workspace.current_dir // .cwd // ""),
    (.context_window.used_percentage // 0 | floor),
    (.context_window.current_usage.input_tokens // 0 | floor),
    (.context_window.current_usage.output_tokens // 0 | floor),
    (.context_window.current_usage.cache_creation_input_tokens // 0 | floor),
    (.context_window.current_usage.cache_read_input_tokens // 0 | floor),
    (.cost.total_cost_usd // 0),
    (.cost.total_duration_ms // 0 | floor),
    (.cost.total_lines_added // 0 | floor),
    (.cost.total_lines_removed // 0 | floor),
    (.rate_limits.five_hour.used_percentage // ""),
    (.rate_limits.five_hour.resets_at // ""),
    (.rate_limits.seven_day.used_percentage // ""),
    (.rate_limits.seven_day.resets_at // "")
  ] | map(tostring) | join("\u001f")' <<< "$STATUS_INPUT"
}

reset_orchestration_state() {
  PHASE="none"
  TASK="none"
  PAIR="none"
  TRIO="none"
  QA_STATE="pending"
  UAT_STATE="pending"
  TELEMETRY_STATE="off"
}

read_manifest_state() {
  local manifest="$PLANNING_DIR/.agent-manifest.json" active contract_path
  if [ -f "$manifest" ] && active=$(jq -ce '[.agents[] | select(.state == "registered" or .state == "running")]' "$manifest" 2>/dev/null); then
    TASK=$(jq -r 'map(.task_identity // empty) | first // "none"' <<< "$active")
    PAIR=$(jq -r '[group_by(.pair_id)[] | select(.[0].pair_id != null and length == 2)] | if length == 0 then "none" else (length|tostring) + " active (" + (.[0] | map(.role) | join("+")) + ")" end' <<< "$active")
    TRIO=$(jq -r '[group_by(.pair_id)[] | select(.[0].pair_id != null and length == 3)] | if length == 0 then "none" else (length|tostring) + " active (" + (.[0] | map(.role) | join("+")) + ")" end' <<< "$active")
    contract_path=$(jq -r 'map(.contract_path // empty) | first // empty' <<< "$active")
    if [ -f "$contract_path" ]; then
      PHASE=$(jq -r '.phase // "none"' "$contract_path" 2>/dev/null || printf 'none')
    fi
  fi
}

read_phase_from_state_file() {
  if [ "$PHASE" = "none" ] && [ -f "$PLANNING_DIR/STATE.md" ]; then
    PHASE=$(sed -n 's/^Phase:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$PLANNING_DIR/STATE.md" 2>/dev/null | head -1)
    PHASE=${PHASE:-none}
  fi
}

find_phase_dir() {
  local phase_dir=""
  case "$PHASE" in
    ''|*[!0-9]*) ;;
    *)
      if [ -d "$PLANNING_DIR/phases" ]; then
        for phase_dir in "$PLANNING_DIR/phases"/"$(printf '%02d' "$((10#$PHASE))")"-*/; do
          [ -d "$phase_dir" ] && break
          phase_dir=""
        done
      fi
      ;;
  esac
  printf '%s' "$phase_dir"
}

read_quality_states() {
  local phase_dir verification uat
  phase_dir=$(find_phase_dir)
  if [ -n "$phase_dir" ] && [ -d "$phase_dir" ]; then
    verification=$(latest_matching_file "$phase_dir" '*-VERIFICATION.md')
    uat=$(latest_matching_file "$phase_dir" '*-UAT.md')
    [ -n "$verification" ] && QA_STATE=$(read_frontmatter_value "$verification" result)
    [ -n "$uat" ] && UAT_STATE=$(read_frontmatter_value "$uat" status)
    QA_STATE=${QA_STATE:-pending}
    UAT_STATE=${UAT_STATE:-pending}
  fi
}

read_telemetry_state() {
  local telemetry="$PLANNING_DIR/telemetry/session.jsonl" report total outcomes
  if [ -f "$telemetry" ]; then
    report=$(bash "$SCRIPT_DIR/telemetry-report.sh" --root "$PLANNING_DIR" 2>/dev/null) || report=""
    if jq -e 'type == "object"' >/dev/null 2>&1 <<< "$report"; then
      total=$(jq -r '.total // 0' <<< "$report")
      outcomes=$(jq -r '.outcomes | to_entries | map(.key + ":" + (.value|tostring)) | join(",")' <<< "$report")
      TELEMETRY_STATE="$total events${outcomes:+ ($outcomes)}"
    else
      TELEMETRY_STATE="tamper/error"
    fi
  fi
}

read_orchestration_state() {
  reset_orchestration_state
  [ -d "$PLANNING_DIR" ] || return 0
  read_manifest_state
  read_phase_from_state_file
  read_quality_states
  read_telemetry_state
}

is_git_worktree() {
  local git_dir common_dir
  git -C "$PROJECT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  git_dir=$(git -C "$PROJECT_ROOT" rev-parse --path-format=absolute --git-dir 2>/dev/null) || return 1
  common_dir=$(git -C "$PROJECT_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ "$git_dir" != "$common_dir" ]
}
