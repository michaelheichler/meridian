VALID_STATUSES="investigating fix_applied qa_pending qa_failed uat_pending uat_failed complete"
VALID_DETAIL_STATUSES="ok not_found error none"

DEBUG_SESSION_INSPECT_STATUS=""
DEBUG_SESSION_INSPECT_QA_ROUND=""
DEBUG_SESSION_INSPECT_UAT_ROUND=""
DEBUG_SESSION_INSPECT_QA_LAST_RESULT=""
DEBUG_SESSION_INSPECT_UAT_LAST_RESULT=""

validate_status() {
  local s="$1"
  for v in $VALID_STATUSES; do
    [ "$s" = "$v" ] && return 0
  done
  echo "Error: invalid status '$s'. Valid: $VALID_STATUSES" >&2
  return 1
}

validate_detail_status() {
  local s="$1"
  for v in $VALID_DETAIL_STATUSES; do
    [ "$s" = "$v" ] && return 0
  done
  echo "Error: invalid detail status '$s'. Valid: $VALID_DETAIL_STATUSES" >&2
  return 1
}

read_field() {
  local file="$1" field="$2"
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

inspect_normalization_fields() {
  local file="$1"
  local old_ifs="$IFS"

  IFS=$'\t' read -r \
    DEBUG_SESSION_INSPECT_STATUS \
    DEBUG_SESSION_INSPECT_QA_ROUND \
    DEBUG_SESSION_INSPECT_UAT_ROUND \
    DEBUG_SESSION_INSPECT_QA_LAST_RESULT \
    DEBUG_SESSION_INSPECT_UAT_LAST_RESULT <<EOF
$(awk -f "$SCRIPT_DIR/lib/debug-session-inspect.awk" "$file")
EOF

  IFS="$old_ifs"
}

rewrite_frontmatter_field() {
  local file="$1" field="$2" value="$3"
  awk -v field="$field" -v value="$value" '
    BEGIN { in_fm = 0; delim = 0 }
    $0 == "---" {
      delim++
      if (delim == 1) in_fm = 1
      else if (delim == 2) in_fm = 0
      print; next
    }
    in_fm && $0 ~ ("^" field ":") {
      print field ": " value
      next
    }
    { print }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  return 0
}

update_field() {
  local file="$1" field="$2" value="$3" now
  if grep -q "^${field}:" "$file" 2>/dev/null; then
    rewrite_frontmatter_field "$file" "$field" "$value"
  fi
  if [ "$field" != "updated" ]; then
    now=$(date '+%Y-%m-%d %H:%M:%S')
    update_field "$file" "updated" "$now"
  fi
}

validate_session_name() {
  local name="$1"
  local base="${name%.md}"
  case "$name" in
    */* | *..* | "")
      echo "Error: invalid session name (path traversal rejected): $name" >&2
      return 1 ;;
  esac
  case "$name" in
    *.md) ;;
    *.*)
      echo "Error: invalid session name (must be .md): $name" >&2
      return 1 ;;
  esac
  case "$base" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-*) ;;
    *)
      echo "Error: invalid session name (expected YYYYMMDD-HHMMSS-slug format): $name" >&2
      return 1 ;;
  esac
  return 0
}

safe_move_session() {
  local src="$1"
  local target_dir="$2"
  local fname
  fname=$(basename "$src")
  local dest="$target_dir/$fname"
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    echo "Error: destination already exists, refusing to overwrite: $dest" >&2
    return 1
  fi
  mkdir -p "$target_dir"
  mv "$src" "$dest"
  echo "$dest"
}

clear_pointer_if() {
  local pointer
  [ -f "$ACTIVE_FILE" ] || return 0
  pointer=$(cat "$ACTIVE_FILE" 2>/dev/null | tr -d '[:space:]')
  if [ "$pointer" = "$1" ]; then
    rm -f "$ACTIVE_FILE"
  fi
}

session_target_dir() {
  if [ "$1" = "complete" ]; then
    printf '%s\n' "$COMPLETED_DIR"
  else
    printf '%s\n' "$ACTIVE_DIR"
  fi
}
