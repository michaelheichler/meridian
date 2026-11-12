MATCH_FOUND=false
MATCH_SESSION_ID=""
MATCH_SESSION_FILE=""
MATCH_SESSION_STATUS=""
SEL_REF=""
SEL_RAW=""
SEL_IDENTITY=0
REF_COUNT_CACHED=""

read_frontmatter_field() {
  local file="$1"
  local field="$2"
  awk -v field="$field" '
    /^---$/ { if (!started) { started=1; in_fm=1; next } if (in_fm) exit }
    in_fm && index($0, field ":") == 1 {
      val = substr($0, length(field) + 2)
      sub(/^[[:space:]]*/, "", val)
      print val
      exit
    }
  ' "$file"
}

read_source_todo_field() {
  local file="$1"
  local label="$2"
  awk -v label="$label" '
    $0 == "## Source Todo" { in_source = 1; next }
    in_source && /^## / { exit }
    in_source {
      prefix = "- **" label ":** "
      if (index($0, prefix) == 1) {
        print substr($0, length(prefix) + 1)
        exit
      }
    }
  ' "$file"
}

live_ref_count() {
  local ref="$1"
  local list_json list_status

  if [ -z "$ref" ] || [ "$ref" = "null" ]; then
    printf '0\n'
    return 0
  fi

  list_json=$(MERIDIAN_PLANNING_DIR="$PLANNING_DIR" bash "$SCRIPT_DIR/list-todos.sh" 2>/dev/null || true)
  list_status=$(printf '%s' "$list_json" | jq -r '.status // "error"' 2>/dev/null || echo "error")
  if [ "$list_status" != "ok" ]; then
    printf '0\n'
    return 0
  fi

  printf '%s' "$list_json" | jq -r --arg ref "$ref" '[.items[] | select((.ref // "") == $ref)] | length' 2>/dev/null || printf '0\n'
}

canonicalize_debug_sessions() {
  env MERIDIAN_PLANNING_DIR="$PLANNING_DIR" bash "$SCRIPT_DIR/debug-session-state.sh" list "$PLANNING_DIR" >/dev/null 2>&1 || true
}

load_ref_count() {
  local _lrc_out="$1" _lrc_count
  _lrc_count=$(live_ref_count "$SEL_REF")
  case "$_lrc_count" in
    ''|*[!0-9]*) _lrc_count=0 ;;
  esac
  printf -v "$_lrc_out" '%s' "$_lrc_count"
}

matches_by_ref() {
  local source_ref="$1" source_raw_line="$2"
  [ "$source_ref" = "$SEL_REF" ] || return 1
  [ "$source_raw_line" != "$SEL_RAW" ] || return 0
  [ -n "$REF_COUNT_CACHED" ] || load_ref_count REF_COUNT_CACHED
  [ "$REF_COUNT_CACHED" = "1" ]
}

matches_by_raw_line() {
  local source_ref="$1" source_raw_line="$2"
  [ -z "$source_ref" ] || return 1
  [ "$source_raw_line" = "$SEL_RAW" ] && [ "${SEL_IDENTITY:-0}" = "1" ]
}

session_matches_selected() {
  if [ -n "$SEL_REF" ] && [ "$SEL_REF" != "null" ]; then
    matches_by_ref "$1" "$2"
  else
    matches_by_raw_line "$1" "$2"
  fi
}

load_selected_identity() {
  local selected_json="$1"
  MATCH_FOUND=false
  MATCH_SESSION_ID=""
  MATCH_SESSION_FILE=""
  MATCH_SESSION_STATUS=""
  SEL_REF=$(printf '%s' "$selected_json" | jq -r '.ref // empty')
  SEL_RAW=$(printf '%s' "$selected_json" | jq -r '.line // .raw_line // .text // empty')
  SEL_IDENTITY=$(printf '%s' "$selected_json" | jq -r '.identity_total // 0')
  REF_COUNT_CACHED=""
}

find_completed_source_todo_match() {
  local debugging_dir="${PLANNING_DIR%/}/debugging"
  local completed_dir="${PLANNING_DIR%/}/debugging/completed"
  local file session_status source_ref source_raw_line

  load_selected_identity "$1"
  [ -d "$debugging_dir" ] || return 0
  canonicalize_debug_sessions

  for file in "$completed_dir"/*.md "$debugging_dir"/*.md; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    session_status=$(read_frontmatter_field "$file" "status")
    [ "$session_status" = "complete" ] || continue

    source_ref=$(read_source_todo_field "$file" "Ref")
    source_raw_line=$(read_source_todo_field "$file" "Raw Line")
    case "$source_ref" in
      none|null) source_ref="" ;;
    esac

    if session_matches_selected "$source_ref" "$source_raw_line"; then
      MATCH_FOUND=true
      MATCH_SESSION_FILE="$file"
      MATCH_SESSION_ID="$(basename "$file" .md)"
      MATCH_SESSION_STATUS="$session_status"
      return 0
    fi
  done
  return 0
}
