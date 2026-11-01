fail_case() {
  echo "case=$1 $2" >&2
  echo "output=$output" >&2
  return 1
}

expect_status() {
  [ "$status" -eq "$2" ] || fail_case "$1" "expected exit status $2 got $status"
}

expect_json() {
  local actual
  actual=$(printf '%s' "$output" | jq -r "$2")
  [ "$actual" = "$3" ] || fail_case "$1" "expected $2 = '$3' got '$actual'"
}

expect_json_unless_dash() {
  case "$3" in
    -) ;;
    *) expect_json "$1" "$2" "$3" ;;
  esac
}

expect_same_json() {
  local left right
  left=$(printf '%s' "$2" | jq -cS '.')
  right=$(printf '%s' "$3" | jq -cS '.')
  [ "$left" = "$right" ] || fail_case "$1" "json differs, left=$left right=$right"
}

expect_valid_json() {
  printf '%s' "$output" | jq empty 2>/dev/null || fail_case "$1" "output is not valid JSON"
}

expect_file_has() {
  grep -qF -- "$3" "$2" || fail_case "$1" "expected '$3' in $2"
}

expect_file_has_line() {
  grep -qxF -- "$3" "$2" || fail_case "$1" "expected line '$3' in $2"
}

expect_file_lacks_line() {
  if grep -qxF -- "$3" "$2"; then
    fail_case "$1" "unexpected line '$3' in $2"
  fi
}

expect_file_matches() {
  local label="$1" path="$2" patterns="$3" pattern
  local IFS='~'
  for pattern in $patterns; do
    case "$pattern" in
      =*) expect_file_has_line "$label" "$path" "${pattern#=}" ;;
      *) expect_file_has "$label" "$path" "$pattern" ;;
    esac
  done
}

expect_file_lacks_lines() {
  local label="$1" path="$2" lines="$3" line
  local IFS='~'
  for line in $lines; do
    expect_file_lacks_line "$label" "$path" "$line"
  done
}
