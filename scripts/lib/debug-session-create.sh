DETAIL_RELATED_FILES='[]'
DETAIL_CONTEXT=''

print_session_metadata() {
  local session_path="$1"
  local session_name
  session_name=$(basename "$session_path")
  local session_id="${session_name%.md}"
  printf 'session_id=%q\n' "$session_id"
  printf 'session_file=%q\n' "$session_path"
  printf 'session_status=%q\n' "$(read_field "$session_path" "status")"
  printf 'title=%q\n' "$(read_field "$session_path" "title")"
  printf 'qa_round=%q\n' "$(read_field "$session_path" "qa_round")"
  printf 'qa_last_result=%q\n' "$(read_field "$session_path" "qa_last_result")"
  printf 'uat_round=%q\n' "$(read_field "$session_path" "uat_round")"
  printf 'uat_last_result=%q\n' "$(read_field "$session_path" "uat_last_result")"
  printf 'created=%q\n' "$(read_field "$session_path" "created")"
  printf 'updated=%q\n' "$(read_field "$session_path" "updated")"
}

render_session_template() {
  local body
  body=$(< "$SCRIPT_DIR/lib/debug-session-template.tmpl")
  body="${body//@H3@/###}"
  body="${body//@H2@/##}"
  body="${body//@H1@/#}"
  body="${body//@SESSION_ID@/$1}"
  body="${body//@SLUG@/$2}"
  body="${body//@NOW@/$3}"
  printf '%s\n' "$body"
}

create_session() {
  local slug_input="$1"
  local slug_sanitized timestamp now session_id session_file

  slug_sanitized=$(printf '%s' "$slug_input" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//' | head -c 50)
  if [ -z "$slug_sanitized" ]; then
    slug_sanitized="debug"
  fi

  mkdir -p "$ACTIVE_DIR"
  timestamp=$(date '+%Y%m%d-%H%M%S')
  session_id="${timestamp}-${slug_sanitized}"
  session_file="$ACTIVE_DIR/${session_id}.md"
  now=$(date '+%Y-%m-%d %H:%M:%S')

  if [ -f "$session_file" ]; then
    echo "Error: session file already exists: $session_file" >&2
    return 1
  fi

  render_session_template "$session_id" "$slug_sanitized" "$now" > "$session_file"
  echo "${session_id}.md" > "$ACTIVE_FILE"

  printf 'session_id=%q\n' "$session_id"
  printf 'session_file=%q\n' "$session_file"
}

extract_ok_detail() {
  local detail_result_json="$1" detail_result_status
  if [ -z "$detail_result_json" ]; then
    echo "Error: detail status ok requires TODO_DETAIL_RESULT_JSON" >&2
    return 1
  fi

  detail_result_status=$(printf '%s' "$detail_result_json" | jq -r '.status // empty')
  if [ "$detail_result_status" != "ok" ]; then
    echo "Error: detail status ok requires todo-details.sh get output with status=ok" >&2
    return 1
  fi

  DETAIL_RELATED_FILES=$(printf '%s' "$detail_result_json" | jq -c '(.detail.files // []) | if type == "array" then . else [] end')
  DETAIL_CONTEXT=$(printf '%s' "$detail_result_json" | jq -r '.detail.context // empty')
}

emit_source_todo() {
  jq -cn \
    --arg mode "source-todo" \
    --arg text "$1" \
    --arg raw_line "$2" \
    --arg ref "$3" \
    --arg detail_status "$4" \
    --argjson related_files "$5" \
    --arg detail_context "$6" \
    '{mode:$mode, text:$text, raw_line:$raw_line, ref:$ref, detail_status:$detail_status, related_files:$related_files, detail_context:$detail_context}'
}

build_source_todo_from_selected() {
  local detail_status="$1"
  local selected_json detail_result_json text raw_line ref

  validate_detail_status "$detail_status" || return 1

  selected_json=$(cat)
  if ! printf '%s' "$selected_json" | jq empty >/dev/null 2>&1; then
    echo "Error: invalid selected todo JSON" >&2
    return 1
  fi

  detail_result_json="${TODO_DETAIL_RESULT_JSON:-}"
  if [ -n "$detail_result_json" ] && ! printf '%s' "$detail_result_json" | jq empty >/dev/null 2>&1; then
    echo "Error: invalid TODO_DETAIL_RESULT_JSON payload" >&2
    return 1
  fi

  text=$(printf '%s' "$selected_json" | jq -r '.command_text // .normalized_text // .text // "none"')
  raw_line=$(printf '%s' "$selected_json" | jq -r '.line // .text // "none"')
  ref=$(printf '%s' "$selected_json" | jq -r '.ref // "none"')
  DETAIL_RELATED_FILES='[]'
  DETAIL_CONTEXT=''

  if [ "$detail_status" = "ok" ]; then
    extract_ok_detail "$detail_result_json" || return 1
  fi

  emit_source_todo "$text" "$raw_line" "$ref" "$detail_status" "$DETAIL_RELATED_FILES" "$DETAIL_CONTEXT"
}

restore_active_pointer() {
  if [ "$1" -eq 1 ]; then
    printf '%s\n' "$2" > "$ACTIVE_FILE"
  else
    rm -f "$ACTIVE_FILE"
  fi
}

start_with_source_todo() {
  local slug_input="$1"
  local source_todo_json session_output session_file previous_active_pointer had_previous_pointer=0
  source_todo_json=$(cat)

  previous_active_pointer=""
  if [ -f "$ACTIVE_FILE" ]; then
    previous_active_pointer=$(cat "$ACTIVE_FILE" 2>/dev/null || true)
    had_previous_pointer=1
  fi

  if ! session_output=$(create_session "$slug_input"); then
    return 1
  fi

  session_file="$ACTIVE_DIR/$(< "$ACTIVE_FILE")"

  if ! printf '%s' "$source_todo_json" | bash "$SCRIPT_DIR/write-debug-session.sh" "$session_file" >/dev/null; then
    rm -f "$session_file"
    restore_active_pointer "$had_previous_pointer" "$previous_active_pointer"
    echo "Error: failed to persist Source Todo for new debug session" >&2
    return 1
  fi

  printf '%s\n' "$session_output"
}

start_with_selected_todo() {
  local slug_input="$1"
  local detail_status="${2:-none}"
  local selected_json source_todo_json

  validate_detail_status "$detail_status" || return 1

  selected_json=$(cat)
  if ! source_todo_json=$(build_source_todo_from_selected "$detail_status" <<< "$selected_json"); then
    return 1
  fi

  printf '%s' "$source_todo_json" | start_with_source_todo "$slug_input"
}
