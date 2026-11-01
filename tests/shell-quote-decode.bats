#!/usr/bin/env bats

load script_contract_helper

quote_rows() {
  local label quoted expected value
  while IFS='|' read -r label quoted expected; do
    printf -v value '%b' "$expected"
    run /bin/bash -c 'source "$1/lib/shell-quote-decode.sh"; decode_printf_q "$2"; printf "%sX" "$DECODED_VALUE"' bash "$SCRIPTS_DIR" "$quoted"
    expect_case "$label" 0
    [ "$output" = "${value}X" ] || record_case_failure "$label" "decoded value differs"
  done
  assert_no_case_failures
}

@test "shell-quoted session metadata decodes escapes as data without executing substitutions" {
  quote_rows <<'CASES'
empty|''|
backslash-spaces|session\ file.md|session file.md
literal-substitution|\$\(touch\ marker\)|$(touch marker)
ansi-controls|$'a\nb\tc\rd\ae\bf\fg\vh\e'|a\nb\tc\rd\ae\bf\fg\vh\033
uppercase-escape|$'\E'|\033
octal|$'\101\12Z'|A\nZ
hex|$'\x41\x5aZ'|AZZ
quotes|$'it\'s\\safe'|it's\\safe
CASES
}
