_init_emit_context=false
_init_context_file=""
RESEARCH_PATH=""
PLAN_PATH=""

init_state_files() {
  local severity="$1"
  local initial_stage
  case "$severity" in
    major|critical) initial_stage="research" ;;
    minor)          initial_stage="fix" ;;
    *)              initial_stage="research" ;;
  esac

  mkdir -p "$PHASE_DIR/remediation/uat/round-01"

  printf 'stage=%s\nround=01\nlayout=round-dir\n' "$initial_stage" > "$STATE_FILE"

  rm -f "$LEGACY_STATE_FILE"
  rm -f "$LEGACY_REMED_STATE_FILE"

  reconcile_uat_state "$STATE_FILE"

  echo "$initial_stage"
}

find_init_uat_file() {
  if type latest_non_source_uat &>/dev/null; then
    latest_non_source_uat "$PHASE_DIR"
  else
    find "$PHASE_DIR" -maxdepth 1 ! -name '.*' -name '[0-9]*-UAT.md' ! -name '*SOURCE-UAT.md' 2>/dev/null | sort | tail -1
  fi
}

read_uat_content() {
  local content
  content=$(cat "$1")
  printf '%s\n' "$content" | sed -E '/^---[[:space:]]*$/,/^---[[:space:]]*$/{
      s/^([[:space:]]*(phase|round)[[:space:]]*:[[:space:]]*)"([0-9]+)"/\1\3/
    }'
}

context_already_seeded() {
  awk '
    BEGIN { in_fm=0; found=0 }
    NR==1 && /^---[[:space:]]*$/ { in_fm=1; next }
    in_fm && /^---[[:space:]]*$/ { exit }
    in_fm && /^pre_seeded[[:space:]]*:[[:space:]]*"?true"?[[:space:]]*$/ { found=1; exit }
    END { exit !found }
  ' "$1" 2>/dev/null
}

reseed_context() {
  local context_file="$1" uat_content="$2"
  awk '/^## UAT Remediation Issues[[:space:]]*$/ { exit } { print }' \
    "$context_file" > "${context_file}.tmp" && mv "${context_file}.tmp" "$context_file"
  {
    echo "## UAT Remediation Issues"
    echo ""
    printf '%s\n' "$uat_content"
  } >> "$context_file"
}

mark_context_pre_seeded() {
  local context_file="$1"
  if head -1 "$context_file" | grep -q '^---[[:space:]]*$'; then
    awk '
      NR==1 && /^---[[:space:]]*$/ { print; next }
      !inserted && /^---[[:space:]]*$/ { print "pre_seeded: true"; inserted=1 }
      { print }
    ' "$context_file" > "${context_file}.tmp" && mv "${context_file}.tmp" "$context_file"
  else
    {
      echo "---"
      echo "pre_seeded: true"
      echo "---"
      echo ""
      cat "$context_file"
    } > "${context_file}.tmp" && mv "${context_file}.tmp" "$context_file"
  fi
}

seed_new_context() {
  local context_file="$1" uat_content="$2"
  mark_context_pre_seeded "$context_file"
  {
    echo ""
    echo "---"
    echo ""
    echo "## UAT Remediation Issues"
    echo ""
    printf '%s\n' "$uat_content"
  } >> "$context_file"
}

create_context_file() {
  local uat_content="$1" phase_basename phase_num
  phase_basename=$(basename "$PHASE_DIR")
  phase_num="${phase_basename%%[^0-9]*}"
  _init_context_file="$PHASE_DIR/${phase_num}-CONTEXT.md"

  {
    echo "---"
    echo "pre_seeded: true"
    echo "---"
    echo ""
    echo "# Phase ${phase_num}: UAT Remediation Context"
    echo ""
    echo "## UAT Remediation Issues"
    echo ""
    printf '%s\n' "$uat_content"
  } > "$_init_context_file"
}

do_init() {
  local severity="$1" context_file uat_file uat_content
  init_state_files "$severity"
  _init_emit_context=false
  _init_context_file=""

  context_file=$(find "$PHASE_DIR" -maxdepth 1 ! -name '.*' -name '[0-9]*-CONTEXT.md' 2>/dev/null | sort | head -1)
  uat_file=$(find_init_uat_file)
  [ -n "$uat_file" ] && [ -f "$uat_file" ] || return 0

  uat_content=$(read_uat_content "$uat_file")
  if [ -n "$context_file" ] && [ -f "$context_file" ]; then
    if context_already_seeded "$context_file"; then
      reseed_context "$context_file" "$uat_content"
    else
      seed_new_context "$context_file" "$uat_content"
    fi
    _init_context_file="$context_file"
  else
    create_context_file "$uat_content"
  fi
  _init_emit_context=true
}

emit_init_context() {
  if [ "$_init_emit_context" = true ] && [ -n "$_init_context_file" ] && [ -f "$_init_context_file" ]; then
    echo "---CONTEXT---"
    cat "$_init_context_file"
  fi
}

resolve_research_path() {
  local round_dir="$1" round="$2" layout="$3"
  local rr_research="${round_dir}/R${round}-RESEARCH.md"
  local phase_prefix legacy_per_plan legacy_phase_level
  RESEARCH_PATH=""
  if [ -f "$rr_research" ]; then
    RESEARCH_PATH="$rr_research"
  elif [ "$layout" = "legacy" ]; then
    phase_prefix=$(extract_phase_num)
    legacy_per_plan=$(find "$PHASE_DIR" -maxdepth 1 -name "${phase_prefix}-*-RESEARCH.md" ! -name '.*' 2>/dev/null | sort | tail -1)
    legacy_phase_level="${PHASE_DIR}/${phase_prefix}-RESEARCH.md"
    if [ -n "$legacy_per_plan" ] && [ -f "$legacy_per_plan" ]; then
      RESEARCH_PATH="$legacy_per_plan"
    elif [ -f "$legacy_phase_level" ]; then
      RESEARCH_PATH="$legacy_phase_level"
    fi
  fi
}

resolve_plan_path() {
  local round_dir="$1" round="$2" layout="$3"
  local rr_plan="${round_dir}/R${round}-PLAN.md"
  local phase_prefix legacy_plan
  PLAN_PATH=""
  if [ -f "$rr_plan" ]; then
    PLAN_PATH="$rr_plan"
  elif [ "$layout" = "legacy" ]; then
    phase_prefix=$(extract_phase_num)
    legacy_plan=$(find "$PHASE_DIR" -maxdepth 1 -name "${phase_prefix}-*-PLAN.md" ! -name '.*' 2>/dev/null | sort | tail -1)
    if [ -n "$legacy_plan" ] && [ -f "$legacy_plan" ]; then
      PLAN_PATH="$legacy_plan"
    fi
  fi
}

emit_plan_metadata() {
  local round round_dir layout summary_path

  round=$(get_round)
  round_dir=$(get_round_dir)
  layout=$(get_layout)
  summary_path="${round_dir}/R${round}-SUMMARY.md"

  resolve_research_path "$round_dir" "$round" "$layout"
  resolve_plan_path "$round_dir" "$round" "$layout"

  echo "round=${round}"
  echo "round_dir=${round_dir}"
  echo "research_path=${RESEARCH_PATH}"
  echo "plan_path=${PLAN_PATH}"
  echo "summary_path=${summary_path}"
}
