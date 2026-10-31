has_project=false
phase_count=0
next_unplanned=""
next_unbuilt=""
all_done=false
last_qa_result=""
map_exists=false

effort="balanced"
active_phase_dir=""
active_phase_num=""
active_phase_name=""
active_phase_plans=0
deviation_count=0
failing_plan_ids=""
map_staleness=-1
cfg_autonomy="standard"
has_uat=false
milestone_uat_issues=false
milestone_uat_phase="none"
milestone_uat_slug="none"
milestone_uat_count=0
current_uat_issues_phase=""
current_uat_issues_slug=""
current_uat_issues_label=""
current_uat_major_or_higher=false
current_uat_round_count=0
current_uat_blocking_phase=""
cfg_require_phase_discussion=false
next_undiscussed=""
next_preseeded=""
cfg_auto_uat=false
has_unverified_phases=false
first_unverified_phase=""
first_unverified_slug=""
next_phase_state=""
pd_next_phase=""
PD_OUT=""
SN_PHASE_DIRS=()
last_phase_dir=""
last_phase_num=""
last_phase_name=""
last_phase_plans=0

read_deviations_field() {
  local file="$1"
  awk '
    BEGIN { in_fm = 0 }
    NR == 1 && /^---[[:space:]]*$/ { in_fm = 1; next }
    in_fm && /^---[[:space:]]*$/ { exit }
    in_fm && tolower($0) ~ /^[[:space:]]*deviations[[:space:]]*:/ {
      value = $0
      sub(/^[^:]*:[[:space:]]*/, "", value)
      gsub(/[[:space:]]+$/, "", value)
      print value
      exit
    }
  ' "$file" 2>/dev/null || true
}

pd_field() {
  echo "$PD_OUT" | grep -m1 "^$1=" | sed 's/^[^=]*=//' || true
}

set_from_pd() {
  local value
  value=$(pd_field "$2")
  if [ -n "$value" ]; then
    printf -v "$1" '%s' "$value"
  fi
  return 0
}

apply_uat_issue_fields() {
  local uat_phase uat_slug uat_major uat_round_count uat_blocking_phase
  uat_phase=$(pd_field uat_issues_phase)
  uat_slug=$(pd_field uat_issues_slug)
  uat_major=$(pd_field uat_issues_major_or_higher)
  uat_round_count=$(pd_field uat_round_count)
  uat_blocking_phase=$(pd_field uat_blocking_phase)
  if [ -n "$uat_phase" ] && [ "$uat_phase" != "none" ]; then
    current_uat_issues_phase="$uat_phase"
    current_uat_issues_slug="${uat_slug:-}"
    if [ "$uat_major" = "true" ]; then current_uat_major_or_higher=true; fi
    if [ -n "$uat_round_count" ]; then current_uat_round_count="$uat_round_count"; fi
  fi
  if [ -n "$uat_blocking_phase" ] && [ "$uat_blocking_phase" != "none" ]; then
    current_uat_blocking_phase="$uat_blocking_phase"
  fi
  return 0
}

build_uat_issues_label() {
  local display_round
  if [ -n "$current_uat_issues_phase" ] && [ -n "$current_uat_issues_slug" ]; then
    current_uat_issues_label="Phase $current_uat_issues_phase ($current_uat_issues_slug)"
  elif [ -n "$current_uat_issues_phase" ]; then
    current_uat_issues_label="Phase $current_uat_issues_phase"
  else
    current_uat_issues_label=""
  fi
  if [ -n "$current_uat_issues_label" ] && [ "$current_uat_round_count" -gt 0 ] 2>/dev/null; then
    display_round=$((current_uat_round_count + 1))
    current_uat_issues_label="$current_uat_issues_label, Round $display_round"
  fi
  return 0
}

apply_phase_detect_fields() {
  local has_unverified
  set_from_pd milestone_uat_issues milestone_uat_issues
  set_from_pd milestone_uat_phase milestone_uat_phase
  set_from_pd milestone_uat_slug milestone_uat_slug
  set_from_pd milestone_uat_count milestone_uat_count
  set_from_pd cfg_require_phase_discussion config_require_phase_discussion
  has_unverified=$(pd_field has_unverified_phases)
  if [ "$has_unverified" = "true" ]; then has_unverified_phases=true; fi
  set_from_pd first_unverified_phase first_unverified_phase
  set_from_pd first_unverified_slug first_unverified_slug
  set_from_pd next_phase_state next_phase_state
  set_from_pd pd_next_phase next_phase
  apply_uat_issue_fields
  build_uat_issues_label
}

load_phase_detect_state() {
  local complete
  PD_OUT=$(bash "$SCRIPT_DIR/phase-detect.sh" 2>/dev/null || true)
  complete=$(printf '%s\n' "$PD_OUT" | awk -F= '/^phase_detect_complete=/{print $2; exit}')
  if [ -n "$PD_OUT" ] && [ "$PD_OUT" != "phase_detect_error=true" ] && [ "${complete:-}" = "true" ]; then
    apply_phase_detect_fields
  fi
  return 0
}

upgrade_config_profile() {
  local config="$1" tmp
  if ! jq -e '.model_profile' "$config" >/dev/null 2>&1; then
    tmp=$(mktemp)
    jq '. + {model_profile: "quality", model_overrides: {}}' "$config" > "$tmp" && mv "$tmp" "$config"
  fi
  return 0
}

load_project_config() {
  local config="$PLANNING_DIR/config.json" effort_value autonomy_value auto_uat_value

  if [ -f "$PLANNING_DIR/PROJECT.md" ] && ! grep -q '{project-name}' "$PLANNING_DIR/PROJECT.md" 2>/dev/null; then
    has_project=true
  fi

  if [ -f "$config" ] && command -v jq >/dev/null 2>&1; then
    upgrade_config_profile "$config"
    effort_value=$(jq -r '.effort // "balanced"' "$config" 2>/dev/null)
    if [ -n "$effort_value" ] && [ "$effort_value" != "null" ]; then effort="$effort_value"; fi
    autonomy_value=$(jq -r '.autonomy // "standard"' "$config" 2>/dev/null)
    if [ -n "$autonomy_value" ] && [ "$autonomy_value" != "null" ]; then cfg_autonomy="$autonomy_value"; fi
    auto_uat_value=$(jq -r '.auto_uat // "false"' "$config" 2>/dev/null)
    if [ "$auto_uat_value" = "true" ]; then cfg_auto_uat=true; fi
  fi
  return 0
}

collect_phase_dirs() {
  local phase_dir_entry
  SN_PHASE_DIRS=()
  while IFS= read -r phase_dir_entry; do
    [ -n "$phase_dir_entry" ] || continue
    SN_PHASE_DIRS+=("${phase_dir_entry%/}/")
  done < <(list_child_dirs_sorted "$PHASES_DIR")
}

find_preseeded_context() {
  local dir="$1" phase_num="$2" ctx_file
  while IFS= read -r ctx_file; do
    [ -n "$ctx_file" ] || continue
    if awk '
      BEGIN { in_fm=0; found=0 }
      NR==1 && /^---[[:space:]]*$/ { in_fm=1; next }
      in_fm && /^---[[:space:]]*$/ { exit }
      in_fm && /^pre_seeded[[:space:]]*:[[:space:]]*"?true"?[[:space:]]*$/ { found=1; exit }
      END { exit !found }
    ' "$ctx_file" 2>/dev/null; then
      next_preseeded="$phase_num"
      return 0
    fi
  done < <(find "$dir" -maxdepth 1 ! -name '.*' -name '[0-9]*-CONTEXT.md' 2>/dev/null | sort)
  return 0
}

detect_discussion_state() {
  local dir="$1" phase_num="$2" context_files
  [ "$cfg_require_phase_discussion" = "true" ] && [ -z "$next_undiscussed" ] || return 0
  context_files=$(find "$dir" -maxdepth 1 ! -name '.*' -name '[0-9]*-CONTEXT.md' 2>/dev/null | wc -l | tr -d ' ')
  if [ "$context_files" -eq 0 ]; then
    next_undiscussed="$phase_num"
  elif [ -z "$next_preseeded" ]; then
    find_preseeded_context "$dir" "$phase_num"
  fi
  return 0
}

classify_phase() {
  local dir="$1" phase_num phase_slug plans summaries
  [ -d "$dir" ] || return 0
  phase_num=$(basename "$dir" | sed 's/[^0-9].*//')
  if [ -z "$phase_num" ] || ! echo "$phase_num" | grep -qE '^[0-9]+$'; then
    return 0
  fi
  phase_count=$((phase_count + 1))
  phase_slug=$(basename "$dir" | sed 's/^[0-9]*-//')

  plans=$(count_phase_plans "$dir")
  summaries=$(count_complete_summaries "$dir")

  if [ "$plans" -eq 0 ] && [ -z "$next_unplanned" ]; then
    detect_discussion_state "$dir" "$phase_num"
    next_unplanned="$phase_num"
    set_active_phase "$dir" "$phase_num" "$phase_slug" 0
  elif [ "$plans" -gt 0 ] && [ "$summaries" -lt "$plans" ] && [ -z "$next_unbuilt" ]; then
    next_unbuilt="$phase_num"
    set_active_phase "$dir" "$phase_num" "$phase_slug" "$plans"
  fi

  last_phase_dir="$dir"
  last_phase_num="$phase_num"
  last_phase_name="$phase_slug"
  last_phase_plans="$plans"
}

set_active_phase() {
  printf -v active_phase_dir '%s' "$1"
  printf -v active_phase_num '%s' "$2"
  printf -v active_phase_name '%s' "$3"
  printf -v active_phase_plans '%s' "$4"
}

scan_qa_results() {
  local dir verification_path result
  for dir in "$PHASES_DIR"/*/; do
    [ -d "$dir" ] || continue
    verification_path=$(bash "$RESOLVE_VERIF_SCRIPT" authoritative "${dir%/}" 2>/dev/null || true)
    [ -n "$verification_path" ] || continue
    [ -f "$verification_path" ] || continue
    result=$(grep -m1 '^result:' "$verification_path" 2>/dev/null | sed 's/result:[[:space:]]*//' | tr '[:upper:]' '[:lower:]' || true)
    if [ -n "$result" ]; then last_qa_result="$result"; fi
  done
  return 0
}

scan_summaries() {
  local summary_file deviations status plan_id
  for summary_file in "$active_phase_dir"/*-SUMMARY.md "$active_phase_dir"/SUMMARY.md; do
    [ -f "$summary_file" ] || continue
    deviations=$(read_deviations_field "$summary_file")
    case "$deviations" in
      0|"[]"|"") ;;
      [0-9]*) deviation_count=$((deviation_count + deviations)) ;;
      *) deviation_count=$((deviation_count + 1)) ;;
    esac
    status=$(read_status_field "$summary_file")
    if [ "$status" = "failed" ] || [ "$status" = "partial" ]; then
      plan_id=$(basename "$summary_file" | sed 's/-SUMMARY.md//')
      failing_plan_ids="${failing_plan_ids:+$failing_plan_ids }$plan_id"
    fi
  done
  return 0
}

mark_uat_if_complete() {
  local status
  status=$(read_status_field "$1")
  if [ "$status" = "complete" ] || [ "$status" = "passed" ]; then
    has_uat=true
  fi
  return 0
}

scan_uat_files() {
  local uat_file
  for uat_file in "$active_phase_dir"/*-UAT.md; do
    [ -f "$uat_file" ] || continue
    case "$uat_file" in
      *SOURCE-UAT.md) continue ;;
    esac
    mark_uat_if_complete "$uat_file"
  done
  if [ "$has_uat" != true ]; then
    for uat_file in "$active_phase_dir"/remediation/uat/round-*/R*-UAT.md; do
      [ -f "$uat_file" ] || continue
      mark_uat_if_complete "$uat_file"
    done
  fi
  return 0
}

scan_phases() {
  local dir
  [ -d "$PHASES_DIR" ] || return 0
  collect_phase_dirs

  if [ ${#SN_PHASE_DIRS[@]} -gt 0 ]; then
    for dir in "${SN_PHASE_DIRS[@]}"; do
      classify_phase "$dir"
    done
  fi

  if [ -z "$active_phase_dir" ] && [ -n "$last_phase_dir" ]; then
    set_active_phase "$last_phase_dir" "$last_phase_num" "$last_phase_name" "$last_phase_plans"
  fi

  if [ "$phase_count" -gt 0 ] && [ -z "$next_unplanned" ] && [ -z "$next_unbuilt" ] && [ -z "$current_uat_issues_phase" ] && [ -z "$current_uat_blocking_phase" ]; then
    all_done=true
  fi

  scan_qa_results

  if [ -n "$active_phase_dir" ] && [ -d "$active_phase_dir" ]; then
    scan_summaries
    scan_uat_files
  fi
  return 0
}

scan_codebase_map() {
  local meta git_hash file_count changed
  [ -d "$PLANNING_DIR/codebase" ] || return 0
  map_exists=true
  meta="$PLANNING_DIR/codebase/META.md"
  if [ -f "$meta" ] && git rev-parse --git-dir >/dev/null 2>&1; then
    git_hash=$(grep '^git_hash:' "$meta" 2>/dev/null | awk '{print $2}' || true)
    file_count=$(grep '^file_count:' "$meta" 2>/dev/null | awk '{print $2}' || true)
    if [ -n "$git_hash" ] && [ -n "$file_count" ] && [ "$file_count" -gt 0 ] 2>/dev/null; then
      if git cat-file -e "$git_hash" 2>/dev/null; then
        changed=$(git diff --name-only "$git_hash"..HEAD 2>/dev/null | wc -l | tr -d ' ')
        map_staleness=$((changed * 100 / file_count))
      else
        map_staleness=100
      fi
    fi
  fi
  return 0
}

load_planning_state() {
  [ -d "$PLANNING_DIR" ] || return 0
  load_phase_detect_state

  PHASES_DIR="$PLANNING_DIR/phases"
  load_project_config
  scan_phases
  scan_codebase_map
  return 0
}
