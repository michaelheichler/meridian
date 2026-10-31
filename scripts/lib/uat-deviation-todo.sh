collapse_spaces() {
  local value="${1:-}"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/ }"
  while [[ "$value" == *"  "* ]]; do
    value="${value//  / }"
  done
  trim_value "$value"
}

truncate_for_todo() {
  local value max
  value=$(collapse_spaces "${1:-}")
  max="${2:-120}"
  if [ "${#value}" -gt "$max" ] 2>/dev/null; then
    value="${value:0:$((max - 3))}..."
  fi
  printf '%s' "$value"
}

phase_identity() {
  local phase_dir="${1:-}"
  basename "${phase_dir%/}"
}

phase_number() {
  local phase_dir="${1:-}" base phase
  base=$(phase_identity "$phase_dir")
  phase=$(printf '%s' "$base" | sed 's/^\([0-9]*\).*/\1/')
  if [[ "$phase" =~ ^[0-9]+$ ]]; then
    printf '%02d' "$((10#$phase))"
  else
    printf '%s' "$base"
  fi
}

planning_root_for_phase() {
  local phase_dir="${1:-}" dir
  [ -n "$phase_dir" ] || return 1
  dir=$(CDPATH='' cd -- "$phase_dir" 2>/dev/null && pwd -P) || return 1
  while [ "$dir" != "/" ] && [ -n "$dir" ]; do
    if [ "$(basename "$dir")" = ".lbwc-planning" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir=$(dirname "$dir")
  done
  return 1
}

relative_to_phase() {
  local phase_dir="${1:-}" target="${2:-}" phase_root
  phase_root="${phase_dir%/}"
  [ -n "$phase_root" ] || phase_root="$phase_dir"
  case "$target" in
    "$phase_root"/*) printf '%s' "${target#"$phase_root/"}" ;;
    *) printf '%s' "$(basename "$target")" ;;
  esac
}

deviation_todo_ref() {
  local phase_dir="$1" signature="$2" source_plan="$3" source_path="$4" text="$5"
  printf '%s\n%s\n%s\n%s\n%s\n' \
    "$(phase_identity "$phase_dir")" \
    "$signature" \
    "$source_plan" \
    "$source_path" \
    "$text" \
    | sha256_text \
    | cut -c1-8
}

emit_todo_from_uat_status() {
  local status="$1" ref="${2:-}" line="${3:-}" detail_status="${4:-skipped}" detail_warning="${5:-}" todo_warning="${6:-}"
  printf 'todo_status=%s\n' "$status"
  [ -n "$ref" ] && printf 'todo_ref=%s\n' "$ref"
  [ -n "$line" ] && printf 'todo_line=%s\n' "$line"
  [ -n "$detail_status" ] && printf 'detail_status=%s\n' "$detail_status"
  [ -n "$detail_warning" ] && printf 'detail_warning=%s\n' "$detail_warning"
  [ -n "$todo_warning" ] && printf 'todo_warning=%s\n' "$todo_warning"
  return 0
}

build_deviation_detail_json() {
  local todo_line="$1" context="$2" source_plan="$3" source_path="$4" uat_rel="$5"
  local today="$6" signature="$7" phase_id="$8" checkpoint_id="$9"
  jq -cn \
    --arg summary "${todo_line#- }" \
    --arg context "$context" \
    --arg source_plan "$source_plan" \
    --arg source_path "$source_path" \
    --arg uat_path "$uat_rel" \
    --arg added "$today" \
    --arg signature "$signature" \
    --arg phase "$phase_id" \
    --arg checkpoint "$checkpoint_id" '
      {
        summary: $summary,
        context: $context,
        files: ([$source_path, $uat_path] | map(select(. != "")) | unique),
        added: $added,
        source: "uat-deviation",
        uat_deviation: {
          phase: $phase,
          checkpoint: $checkpoint,
          signature: $signature,
          source_plan: $source_plan,
          source_path: $source_path
        }
      }
    '
}

emit_detail_outcome() {
  local detail_out="$1" detail_status detail_message
  detail_status=$(printf '%s' "$detail_out" | jq -r '.status // "error"' 2>/dev/null || echo "error")
  if [ "$detail_status" = "ok" ]; then
    printf 'ok\t'
  else
    detail_message=$(printf '%s' "$detail_out" | jq -r '.message // "todo detail registry update failed"' 2>/dev/null || echo "todo detail registry update failed")
    printf 'warning\t%s' "$detail_message"
  fi
}

upsert_uat_deviation_detail() {
  local planning_root="$1" phase_dir="$2" uat_file="$3" checkpoint_id="$4" ref="$5" todo_line="$6"
  local signature="$7" source_plan="$8" source_path="$9" text="${10}"
  local detail_script details_path detail_json detail_out today uat_rel phase_id context

  detail_script="$SCRIPT_DIR/todo-details.sh"
  if [ ! -f "$detail_script" ]; then
    printf 'unavailable\ttodo-details.sh not found'
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'warning\tjq not available for todo detail registry update'
    return 0
  fi

  details_path="${planning_root%/}/todo-details.json"
  today=$(date +%Y-%m-%d)
  uat_rel=$(relative_to_phase "$phase_dir" "$uat_file")
  phase_id=$(phase_identity "$phase_dir")
  context="Accepted UAT summary deviation for phase ${phase_id}. Deviation: ${text}. Source plan: ${source_plan}. Source: ${source_path}. UAT checkpoint: ${uat_rel}#${checkpoint_id}."
  detail_json=$(build_deviation_detail_json "$todo_line" "$context" "$source_plan" "$source_path" "$uat_rel" "$today" "$signature" "$phase_id" "$checkpoint_id")

  detail_out=$(bash "$detail_script" add "$ref" "$detail_json" "$details_path" 2>/dev/null || true)
  emit_detail_outcome "$detail_out"
}

uat_deviation_gate() {
  if [ "$TODO_UAT_RESULT" != "pass" ] || [ "$TODO_UAT_DISPOSITION" != "accepted-process-exception" ]; then
    emit_todo_from_uat_status "not_accepted"
    return 1
  fi

  if [ -z "$TODO_UAT_SIGNATURE" ] || [ -z "$TODO_UAT_SOURCE_PLAN" ] || [ -z "$TODO_UAT_SOURCE_PATH" ] || [ -z "$TODO_UAT_DEVIATION" ]; then
    emit_todo_from_uat_status "missing_metadata"
    return 1
  fi
  return 0
}

compose_deviation_todo_line() {
  local phase_dir="$1" ref="$2" phase_num today summary
  phase_num=$(phase_number "$phase_dir")
  today=$(date +%Y-%m-%d)
  summary=$(truncate_for_todo "$TODO_UAT_DEVIATION" 110)
  printf '%s' "- [UAT-DEVIATION] ${TODO_UAT_SOURCE_PLAN}: ${summary} (phase ${phase_num}, see ${TODO_UAT_SOURCE_PATH}) (added ${today}) (ref:${ref})"
}

report_todo_detail() {
  local insert_status="$1" planning_root="$2" phase_dir="$3" uat_file="$4" checkpoint_id="$5" ref="$6" todo_line="$7"
  local detail_result detail_status detail_warning=""
  detail_result=$(upsert_uat_deviation_detail "$planning_root" "$phase_dir" "$uat_file" "$checkpoint_id" "$ref" "$todo_line" "$TODO_UAT_SIGNATURE" "$TODO_UAT_SOURCE_PLAN" "$TODO_UAT_SOURCE_PATH" "$TODO_UAT_DEVIATION")
  detail_status="${detail_result%%$'\t'*}"
  if [[ "$detail_result" == *$'\t'* ]]; then
    detail_warning="${detail_result#*$'\t'}"
  fi
  emit_todo_from_uat_status "$insert_status" "$ref" "$todo_line" "$detail_status" "$detail_warning"
}

require_todo_inputs() {
  [ -d "$1" ] || { echo "track-uat-deviations: phase dir not found: $1" >&2; exit 1; }
  [ -f "$2" ] || { echo "track-uat-deviations: UAT file not found: $2" >&2; exit 1; }
  [[ "$3" =~ ^D[0-9]+$ ]] || { echo "track-uat-deviations: checkpoint id must look like DNN: $3" >&2; exit 1; }
}

persist_deviation_todo() {
  local state_path="$1" todo_line="$2" ref="$3" planning_root="$4" phase_dir="$5" uat_file="$6" checkpoint_id="$7"
  local insert_status insert_rc=0
  insert_todo_line "$state_path" "$todo_line" "$ref" || insert_rc=$?
  case "$insert_rc" in
    0) insert_status="added" ;;
    2) insert_status="already_tracked" ;;
    *)
      emit_todo_from_uat_status "state_update_failed" "" "" "skipped" "" "STATE.md todo update failed; todo not persisted"
      return 0
      ;;
  esac

  report_todo_detail "$insert_status" "$planning_root" "$phase_dir" "$uat_file" "$checkpoint_id" "$ref" "$todo_line"
}

todo_from_uat() {
  local phase_dir uat_file checkpoint_id planning_root state_path ref todo_line
  phase_dir="${1:-}"
  uat_file="${2:-}"
  checkpoint_id="${3:-}"
  require_todo_inputs "$phase_dir" "$uat_file" "$checkpoint_id"

  if ! extract_requested_uat_deviation "$uat_file" "$checkpoint_id"; then
    emit_todo_from_uat_status "missing_metadata"
    return 0
  fi
  uat_deviation_gate || return 0

  planning_root=$(planning_root_for_phase "$phase_dir" || true)
  state_path="${planning_root%/}/STATE.md"
  if [ -z "$planning_root" ] || [ ! -f "$state_path" ]; then
    emit_todo_from_uat_status "no_state_file"
    return 0
  fi

  ref=$(deviation_todo_ref "$phase_dir" "$TODO_UAT_SIGNATURE" "$TODO_UAT_SOURCE_PLAN" "$TODO_UAT_SOURCE_PATH" "$TODO_UAT_DEVIATION")
  todo_line=$(compose_deviation_todo_line "$phase_dir" "$ref")
  persist_deviation_todo "$state_path" "$todo_line" "$ref" "$planning_root" "$phase_dir" "$uat_file" "$checkpoint_id"
}
