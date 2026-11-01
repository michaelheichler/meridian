TODO_ANCHOR=""
TODO_STOP_PATTERN=""
TODO_HAS_SECTION=false

ref_tracking_status() {
  local state_path="$1" ref="$2" grep_status=0
  grep -qF "(ref:${ref})" "$state_path" || grep_status=$?
  [ "$grep_status" -eq 0 ] && return 0
  [ "$grep_status" -gt 1 ] && return 2
  return 1
}

read_flat_todos() {
  awk '
    /^## Todos$/ { found=1; next }
    found && /^## / { exit }
    found && /^### / { exit }
    found && /^- / { print }
  ' "$1"
}

use_todo_anchor() {
  TODO_HAS_SECTION=true
  TODO_ANCHOR="$1"
  TODO_STOP_PATTERN="$2"
}

choose_todo_anchor() {
  local state_path="$1" flat_todos="$2" pending_status=0 todos_status=0

  TODO_HAS_SECTION=false
  if [ -n "$flat_todos" ]; then
    use_todo_anchor '^## Todos$' '(^### )|(^## )'
    return 0
  fi

  grep -Eq '^### Pending Todos$' "$state_path" || pending_status=$?
  if [ "$pending_status" -eq 0 ]; then
    use_todo_anchor '^### Pending Todos$' '(^### Completed Todos$)|(^## )'
    return 0
  fi
  [ "$pending_status" -le 1 ] || return 1

  grep -Eq '^## Todos$' "$state_path" || todos_status=$?
  [ "$todos_status" -le 1 ] || return 1
  if [ "$todos_status" -eq 0 ]; then
    use_todo_anchor '^## Todos$' '(^### )|(^## )'
  fi
  return 0
}

append_todos_section() {
  local state_path="$1" tmp_file="$2" todo_line="$3"
  cat "$state_path" > "$tmp_file" || return 1
  printf '\n## Todos\n%s\n' "$todo_line" >> "$tmp_file" || return 1
}

insert_into_todos_section() {
  local state_path="$1" tmp_file="$2" todo_line="$3"
  awk -v todo_line="$todo_line" -v anchor="$TODO_ANCHOR" -v stop_re="$TODO_STOP_PATTERN" \
    -f "$SCRIPT_DIR/lib/uat-deviation-insert.awk" "$state_path" > "$tmp_file"
}

commit_todo_tmp() {
  local tmp_file="$1" state_path="$2" ref="$3"
  if ! grep -qF "(ref:${ref})" "$tmp_file"; then
    rm -f "$tmp_file"
    return 1
  fi
  if ! mv "$tmp_file" "$state_path"; then
    rm -f "$tmp_file"
    return 1
  fi
  return 0
}

insert_todo_line() {
  local state_path="$1" todo_line="$2" ref="$3"
  local tmp_file flat_todos tracked_rc=0

  ref_tracking_status "$state_path" "$ref" || tracked_rc=$?
  [ "$tracked_rc" -ne 0 ] || return 2
  [ "$tracked_rc" -ne 2 ] || return 1

  tmp_file=$(mktemp "${state_path}.tmp.XXXXXX") || return 1

  if ! flat_todos=$(read_flat_todos "$state_path"); then
    rm -f "$tmp_file"
    return 1
  fi
  if ! choose_todo_anchor "$state_path" "$flat_todos"; then
    rm -f "$tmp_file"
    return 1
  fi

  if [ "$TODO_HAS_SECTION" != true ]; then
    append_todos_section "$state_path" "$tmp_file" "$todo_line" || { rm -f "$tmp_file"; return 1; }
  else
    insert_into_todos_section "$state_path" "$tmp_file" "$todo_line" || { rm -f "$tmp_file"; return 1; }
  fi
  commit_todo_tmp "$tmp_file" "$state_path" "$ref"
}
