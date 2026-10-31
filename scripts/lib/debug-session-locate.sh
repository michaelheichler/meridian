CANDIDATES=()

skip_normalization_needed() {
  [ "$DEBUG_SESSION_INSPECT_STATUS" = "complete" ] \
    && [ "${DEBUG_SESSION_INSPECT_QA_ROUND:-0}" = "0" ] \
    && [ "${DEBUG_SESSION_INSPECT_UAT_ROUND:-0}" = "0" ] \
    && [ "$DEBUG_SESSION_INSPECT_QA_LAST_RESULT" = "pending" ] \
    && [ "$DEBUG_SESSION_INSPECT_UAT_LAST_RESULT" = "pending" ]
}

rewrite_skipped_results() {
  local file="$1" now="$2"
  awk -v skipped="$SKIPPED_NO_FIX_REQUIRED" -v now="$now" '
    BEGIN { in_fm = 0; delim = 0 }
    $0 == "---" {
      delim++
      if (delim == 1) in_fm = 1
      else if (delim == 2) in_fm = 0
      print
      next
    }
    in_fm && /^qa_last_result:/ {
      print "qa_last_result: " skipped
      next
    }
    in_fm && /^uat_last_result:/ {
      print "uat_last_result: " skipped
      next
    }
    in_fm && /^updated:/ {
      print "updated: " now
      next
    }
    { print }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  return 0
}

normalize_completed_no_verification_results() {
  local file="$1"
  local fields_state="${2:-}"
  local now
  [ -f "$file" ] && [ ! -L "$file" ] || return 1

  if [ "$fields_state" != "preloaded" ]; then
    inspect_normalization_fields "$file" || return 1
  fi
  skip_normalization_needed || return 0

  now=$(date '+%Y-%m-%d %H:%M:%S')
  rewrite_skipped_results "$file" "$now"

  DEBUG_SESSION_INSPECT_QA_LAST_RESULT="$SKIPPED_NO_FIX_REQUIRED"
  DEBUG_SESSION_INSPECT_UAT_LAST_RESULT="$SKIPPED_NO_FIX_REQUIRED"
}

heal_completed_collision() {
  local file="$1" fname collision_file moved
  fname=$(basename "$file")
  collision_file="$ACTIVE_DIR/$fname"
  [ -f "$collision_file" ] && [ ! -L "$collision_file" ] && [ "$(read_field "$collision_file" "status")" = "complete" ] || return 1
  safe_move_session "$collision_file" "$COMPLETED_DIR" > /dev/null 2>&1 || return 1
  clear_pointer_if "$fname"
  if moved=$(safe_move_session "$file" "$ACTIVE_DIR" 2>/dev/null); then
    echo "$moved"
    return 0
  fi
  return 1
}

reconcile_session_location() {
  local file="$1"
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  inspect_normalization_fields "$file" || return 1
  normalize_completed_no_verification_results "$file" preloaded || return 1

  local target_dir moved
  target_dir=$(session_target_dir "$DEBUG_SESSION_INSPECT_STATUS")
  if [ "$(dirname "$file")" = "$target_dir" ]; then
    echo "$file"
    return 0
  fi

  if moved=$(safe_move_session "$file" "$target_dir" 2>/dev/null); then
    echo "$moved"
    return 0
  fi

  [ "$target_dir" = "$ACTIVE_DIR" ] || return 1
  heal_completed_collision "$file"
}

migrate_legacy_session() {
  local file="$1"
  local fname file_status target_dir new_path
  if [ "$(dirname "$file")" != "$DEBUG_DIR" ]; then
    echo "$file"
    return 0
  fi
  inspect_normalization_fields "$file" || return 1
  normalize_completed_no_verification_results "$file" preloaded || return 1
  fname=$(basename "$file")
  file_status="$DEBUG_SESSION_INSPECT_STATUS"
  target_dir=$(session_target_dir "$file_status")
  if ! new_path=$(safe_move_session "$file" "$target_dir"); then
    echo "$file"
    return 1
  fi
  if [ "$file_status" = "complete" ]; then
    clear_pointer_if "$fname"
  fi
  echo "$new_path"
}

echo_if_active_path() {
  [[ "$1" == "$ACTIVE_DIR/"* ]] || return 1
  echo "$1"
}

resolve_in_active_dir() {
  local session_path="$ACTIVE_DIR/$1" reconciled
  [ -f "$session_path" ] && [ ! -L "$session_path" ] || return 1
  if reconciled=$(reconcile_session_location "$session_path") && echo_if_active_path "$reconciled"; then
    return 0
  fi
  rm -f "$ACTIVE_FILE"
}

resolve_in_legacy_dir() {
  local legacy_path="$DEBUG_DIR/$1" migrated
  [ -f "$legacy_path" ] && [ ! -L "$legacy_path" ] || return 1
  if migrated=$(migrate_legacy_session "$legacy_path") && echo_if_active_path "$migrated"; then
    return 0
  fi
  return 1
}

resolve_in_completed_dir() {
  local completed_path="$COMPLETED_DIR/$1" reconciled
  [ -f "$completed_path" ] && [ ! -L "$completed_path" ] || return 1
  if reconciled=$(reconcile_session_location "$completed_path") && echo_if_active_path "$reconciled"; then
    return 0
  fi
  rm -f "$ACTIVE_FILE"
}

get_active_session_path() {
  [ -f "$ACTIVE_FILE" ] || return 0
  local session_name
  session_name=$(cat "$ACTIVE_FILE" 2>/dev/null | tr -d '[:space:]')
  [ -n "$session_name" ] || return 0
  if ! validate_session_name "$session_name"; then
    rm -f "$ACTIVE_FILE"
    return 0
  fi
  resolve_in_active_dir "$session_name" && return 0
  resolve_in_legacy_dir "$session_name" && return 0
  resolve_in_completed_dir "$session_name" && return 0
  rm -f "$ACTIVE_FILE"
}

warn_unmigrated() {
  echo "Warning: could not migrate legacy session $(basename "$1")" >&2
}

retry_legacy_after_collision() {
  local legacy_f="$1" collision_file
  collision_file="$ACTIVE_DIR/$(basename "$legacy_f")"
  if [ -f "$collision_file" ] && [ ! -L "$collision_file" ] && [ "$(read_field "$collision_file" "status")" = "complete" ]; then
    if safe_move_session "$collision_file" "$COMPLETED_DIR" > /dev/null 2>&1; then
      clear_pointer_if "$(basename "$collision_file")"
    fi
    if ! migrate_legacy_session "$legacy_f" > /dev/null 2>&1; then
      warn_unmigrated "$legacy_f"
    fi
  else
    warn_unmigrated "$legacy_f"
  fi
}

migrate_legacy_sessions() {
  local legacy_f
  for legacy_f in "$DEBUG_DIR"/*.md; do
    [ -f "$legacy_f" ] && [ ! -L "$legacy_f" ] || continue
    if ! migrate_legacy_session "$legacy_f" > /dev/null 2>&1; then
      retry_legacy_after_collision "$legacy_f"
    fi
  done
}

reconcile_dir_sessions() {
  local dir="$1" f
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.md; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    reconcile_session_location "$f" > /dev/null 2>&1 || true
  done
}

gather_candidates() {
  local f legacy_f active_dup
  CANDIDATES=()
  if [ -d "$ACTIVE_DIR" ]; then
    for f in "$ACTIVE_DIR"/*.md; do
      [ -f "$f" ] && [ ! -L "$f" ] && CANDIDATES+=("$f")
    done
  fi
  for legacy_f in "$DEBUG_DIR"/*.md; do
    [ -f "$legacy_f" ] && [ ! -L "$legacy_f" ] || continue
    active_dup="$ACTIVE_DIR/$(basename "$legacy_f")"
    if [ -f "$active_dup" ] && [ ! -L "$active_dup" ]; then
      continue
    fi
    CANDIDATES+=("$legacy_f")
  done
}

find_latest_unresolved() {
  [ -d "$DEBUG_DIR" ] || return 0
  migrate_legacy_sessions
  reconcile_dir_sessions "$ACTIVE_DIR"
  reconcile_dir_sessions "$COMPLETED_DIR"
  gather_candidates
  local files=() _basename path i status c
  if [ ${#CANDIDATES[@]} -gt 0 ]; then
    while IFS=$'\t' read -r _basename path; do
      [ -n "$path" ] && files+=("$path")
    done < <(for c in "${CANDIDATES[@]}"; do printf '%s\t%s\n' "$(basename "$c")" "$c"; done | LC_ALL=C sort -t$'\t' -k1,1)
  fi
  for (( i=${#files[@]}-1; i>=0; i-- )); do
    status=$(read_field "${files[$i]}" "status")
    if [ "$status" != "complete" ]; then
      echo "${files[$i]}"
      return 0
    fi
  done
}
