SESSION_PATH=""
RESUME_PATH=""
COUNT=0
HEALED_FILES=""

command_usage() {
  echo "Usage: debug-session-state.sh $1" >&2
  exit 1
}

cmd_start() {
  [ -n "${1:-}" ] || command_usage "start <planning-dir> <slug>"
  create_session "$1"
}

cmd_start_with_source_todo() {
  [ -n "${1:-}" ] || command_usage "start-with-source-todo <planning-dir> <slug>"
  start_with_source_todo "$1"
}

cmd_start_with_selected_todo() {
  [ -n "${1:-}" ] || command_usage "start-with-selected-todo <planning-dir> <slug> <detail-status>"
  start_with_selected_todo "$1" "${2:-none}"
}

cmd_get() {
  local session_path
  session_path=$(get_active_session_path)
  if [ -z "$session_path" ]; then
    echo "active_session=none"
    exit 0
  fi
  echo "active_session=true"
  print_session_metadata "$session_path"
}

cmd_get_or_latest() {
  local session_path
  session_path=$(get_active_session_path)
  if [ -z "$session_path" ]; then
    session_path=$(find_latest_unresolved)
    if [ -z "$session_path" ]; then
      echo "active_session=none"
      exit 0
    fi
    echo "active_session=fallback"
    basename "$session_path" > "$ACTIVE_FILE"
  else
    echo "active_session=true"
  fi
  print_session_metadata "$session_path"
}

resolve_resume_path() {
  local name="$1" legacy_path
  RESUME_PATH="$ACTIVE_DIR/$name"
  if [ ! -f "$RESUME_PATH" ]; then
    RESUME_PATH="$COMPLETED_DIR/$name"
  fi
  [ ! -f "$RESUME_PATH" ] || return 0
  legacy_path="$DEBUG_DIR/$name"
  if [ -f "$legacy_path" ] && [ ! -L "$legacy_path" ]; then
    if ! RESUME_PATH=$(migrate_legacy_session "$legacy_path"); then
      echo "Error: could not migrate legacy session: $name" >&2
      exit 1
    fi
  else
    RESUME_PATH=""
  fi
}

cmd_resume() {
  [ -n "${1:-}" ] || command_usage "resume <planning-dir> <session-id>"
  local session_name="$1" session_file_status
  validate_session_name "$session_name" || exit 1
  case "$session_name" in
    *.md) ;;
    *) session_name="${session_name}.md" ;;
  esac
  resolve_resume_path "$session_name"
  SESSION_PATH="$RESUME_PATH"
  if [ -z "$SESSION_PATH" ] || [ ! -f "$SESSION_PATH" ]; then
    echo "Error: session file not found: $session_name" >&2
    exit 1
  fi
  if [ -L "$SESSION_PATH" ]; then
    echo "Error: refusing to resume symlink session file: $SESSION_PATH" >&2
    exit 1
  fi
  SESSION_PATH=$(reconcile_session_location "$SESSION_PATH") || exit 1
  session_file_status=$(read_field "$SESSION_PATH" "status")
  if [ "$session_file_status" = "complete" ]; then
    clear_pointer_if "$session_name"
  else
    echo "$session_name" > "$ACTIVE_FILE"
  fi
  echo "active_session=true"
  print_session_metadata "$SESSION_PATH"
}

finish_completed_session() {
  local fname
  normalize_completed_no_verification_results "$SESSION_PATH" || exit 1
  fname=$(basename "$SESSION_PATH")
  if [ "$(dirname "$SESSION_PATH")" != "$COMPLETED_DIR" ]; then
    SESSION_PATH=$(safe_move_session "$SESSION_PATH" "$COMPLETED_DIR") || exit 1
  fi
  clear_pointer_if "$fname"
}

cmd_set_status() {
  local new_status="${1:-}"
  [ -n "$new_status" ] || command_usage "set-status <planning-dir> <status>"
  validate_status "$new_status" || exit 1
  SESSION_PATH=$(get_active_session_path)
  if [ -z "$SESSION_PATH" ]; then
    echo "Error: no active debug session" >&2
    exit 1
  fi
  update_field "$SESSION_PATH" "status" "$new_status"
  if [ "$new_status" = "complete" ]; then
    finish_completed_session
  fi
  echo "status=$new_status"
  echo "session_file=$SESSION_PATH"
}

bump_round() {
  local round_field="$1" result_field="$2" current new_round
  SESSION_PATH=$(get_active_session_path)
  if [ -z "$SESSION_PATH" ]; then
    echo "Error: no active debug session" >&2
    exit 1
  fi
  current=$(read_field "$SESSION_PATH" "$round_field")
  new_round=$(( ${current:-0} + 1 ))
  update_field "$SESSION_PATH" "$round_field" "$new_round"
  update_field "$SESSION_PATH" "$result_field" "pending"
  echo "${round_field}=$new_round"
}

cmd_clear_active() {
  rm -f "$ACTIVE_FILE"
  echo "active_session=cleared"
}

emit_session_line() {
  local file="$1" location="$2" session_id file_status title
  session_id=$(read_field "$file" "session_id")
  file_status=$(read_field "$file" "status")
  title=$(read_field "$file" "title")
  echo "session=${session_id}|${file_status}|${title}|${location}"
  COUNT=$((COUNT + 1))
}

list_active_dir_sessions() {
  local f reconciled
  [ -d "$ACTIVE_DIR" ] || return 0
  for f in "$ACTIVE_DIR"/*.md; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    reconciled="$f"
    if reconciled=$(reconcile_session_location "$f"); then
      if [[ "$reconciled" == "$COMPLETED_DIR/"* ]]; then
        HEALED_FILES="${HEALED_FILES}$(basename "$reconciled"):"
        emit_session_line "$reconciled" "completed"
        continue
      fi
    fi
    emit_session_line "$reconciled" "active"
  done
}

list_completed_dir_sessions() {
  local f reconciled
  [ -d "$COMPLETED_DIR" ] || return 0
  for f in "$COMPLETED_DIR"/*.md; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    reconciled="$f"
    if reconciled=$(reconcile_session_location "$f"); then
      if [[ "$reconciled" == "$ACTIVE_DIR/"* ]]; then
        emit_session_line "$reconciled" "active"
        continue
      fi
    fi
    if [ -n "$HEALED_FILES" ] && printf '%s' "$HEALED_FILES" | grep -qF "$(basename "$reconciled"):"; then
      continue
    fi
    emit_session_line "$reconciled" "completed"
  done
}

list_legacy_sessions() {
  local f location
  for f in "$DEBUG_DIR"/*.md; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    location="active"
    if [ "$(read_field "$f" "status")" = "complete" ]; then
      location="completed"
    fi
    emit_session_line "$f" "$location"
  done
}

cmd_list() {
  if [ ! -d "$DEBUG_DIR" ]; then
    echo "no_sessions=true"
    exit 0
  fi
  migrate_legacy_sessions
  list_active_dir_sessions
  list_completed_dir_sessions
  list_legacy_sessions
  if [ "$COUNT" -eq 0 ]; then
    echo "no_sessions=true"
  fi
  echo "session_count=$COUNT"
}
