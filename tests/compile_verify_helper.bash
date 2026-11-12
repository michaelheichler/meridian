cvc_set() {
  printf -v "$1" '%s' "$2"
}

cvc_setup() {
  setup_temp_dir
  cvc_set PHASE_DIR "$TEST_TEMP_DIR/.meridian/phases/03-test-phase"
  mkdir -p "$PHASE_DIR"
}

cvc_reset() {
  rm -rf "$PHASE_DIR"
  mkdir -p "$PHASE_DIR"
}

cvc_frontmatter() {
  local path="$PHASE_DIR/$1"
  shift
  mkdir -p "$(dirname "$path")"
  { echo '---'; printf '%s\n' "$@"; echo '---'; } > "$path"
}

cvc_plan() {
  local path="$1" id="$2" title="$3" musthaves="$4" item
  local fields=()
  [ -z "$id" ] || fields+=("plan: $id")
  fields+=("title: $title")
  if [ -n "$musthaves" ]; then
    fields+=("must_haves:")
    while IFS= read -r item; do
      fields+=("  - $item")
    done <<< "${musthaves//;;/$'\n'}"
  fi
  cvc_frontmatter "$path" "${fields[@]}"
}

cvc_summary() {
  cvc_frontmatter "$1" "status: $2"
  printf '%s\n' '## What Was Built' "- $3" >> "$PHASE_DIR/$1"
  [ -z "${4:-}" ] || printf '%s\n' '## Files Modified' "- \`$4\` -- created" >> "$PHASE_DIR/$1"
}

cvc_round() {
  local dir="remediation/$1/round-$2"
  [ "$1" != legacy ] || dir="remediation/round-$2"
  cvc_plan "$dir/R$2-PLAN.md" "R$2" "$3" "${6:-}"
  [ -z "$4" ] || cvc_summary "$dir/R$2-SUMMARY.md" "$4" "$5"
}

cvc_stage() {
  local kind="$1" stage="$2" round="$3" layout="${4:-}"
  local stage_file="$PHASE_DIR/remediation/$kind/.$kind-remediation-stage"
  mkdir -p "$PHASE_DIR/remediation/$kind"
  printf 'stage=%s\nround=%s\n' "$stage" "$round" > "$stage_file"
  [ -z "$layout" ] || printf 'layout=%s\n' "$layout" >> "$stage_file"
}

cvc_run() {
  local word dir="$PHASE_DIR"
  local args=()
  for word in $1; do
    case "$word" in
      EMPTY) args+=("") ;;
      NOPHASE) dir="$TEST_TEMP_DIR/nonexistent" ;;
      *) args+=("$word") ;;
    esac
  done
  cd "$TEST_TEMP_DIR" || return 1
  run bash "$SCRIPTS_DIR/compile-verify-context.sh" "${args[@]}" "$dir" < /dev/null
}

cvc_assert() {
  local op="${1%% *}" text="${1#* }" pattern history
  case "$op" in
    '?+') [[ "$CVC_TARGET" == *"$text"* ]] ;;
    '?-') [[ "$CVC_TARGET" != *"$text"* ]] ;;
    '?=') [[ "$output" == "$text" ]] ;;
    '?^') [[ "${lines[0]}" == "$text" ]] ;;
    '?<')
      pattern="*${text//>>/*}*"
      [[ "$CVC_TARGET" == $pattern ]]
      ;;
    '?h-')
      history=$(echo "$output" | awk '/VERIFICATION HISTORY/,0')
      [[ "$history" != *"$text"* ]]
      ;;
    *) return 2 ;;
  esac
}

cvc_report() {
  echo "case=$CVC_LABEL failed on: $1" >&2
  echo "status=$status expected_status=$CVC_STATUS flags=$CVC_FLAGS" >&2
  echo "output=$output" >&2
}

cvc_ensure_run() {
  [ -z "$CVC_RAN" ] || return 0
  cvc_run "$CVC_FLAGS"
  cvc_set CVC_RAN 1
  cvc_set CVC_TARGET "$output"
  [ "$status" -eq "$CVC_STATUS" ] || { cvc_report "exit status"; return 1; }
}

cvc_new_case() {
  cvc_set CVC_LABEL "$1"
  cvc_set CVC_FLAGS ""
  cvc_set CVC_RAN ""
  cvc_set CVC_STATUS 0
  cvc_reset
}

cvc_section() {
  cvc_ensure_run || return 1
  cvc_set CVC_TARGET "$(awk -v header="$1" 'index($0, header) == 1 { on = 1 } on { print } on && /^$/ { exit }' <<< "$output")"
}

cvc_verification_macro() {
  local a b c d keep="$CVC_FILE"
  case "$1" in
    "@v "*)
      IFS='|' read -r a b <<< "${1#@v }"
      cvc_frontmatter "$a" "result: $b"
      cvc_set CVC_FILE "$PHASE_DIR/$a"
      ;;
    "@vt "*)
      IFS='|' read -r a b <<< "${1#@vt }"
      cvc_frontmatter "$a" "result: $b"
      printf '%s\n' '## Checks' '| ID | Category | Description | Status | Evidence |' \
        '|----|----------|-------------|--------|----------|' >> "$PHASE_DIR/$a"
      cvc_set CVC_FILE "$PHASE_DIR/$a"
      ;;
    "@h "*)
      printf '## %s\n' "${1#@h }" >> "$keep"
      cvc_set CVC_FILE "$keep"
      ;;
    "@row "*)
      IFS='|' read -r a b c d <<< "${1#@row }"
      printf '| %s | must_have | %s | %s | %s |\n' "$a" "$b" "$c" "$d" >> "$keep"
      cvc_set CVC_FILE "$keep"
      ;;
    *) return 1 ;;
  esac
}

cvc_macro() {
  local a b c d e f keep="$CVC_FILE"
  cvc_set CVC_FILE ""
  case "$1" in
    "@ "*)
      cvc_set CVC_FILE "$PHASE_DIR/${1#@ }"
      mkdir -p "$(dirname "$CVC_FILE")"
      : > "$CVC_FILE"
      ;;
    "@dir "*) mkdir -p "$PHASE_DIR/${1#@dir }" ;;
    "@plan "*) IFS='|' read -r a b c d <<< "${1#@plan }"; cvc_plan "$a" "$b" "$c" "$d" ;;
    "@sum "*) IFS='|' read -r a b c d <<< "${1#@sum }"; cvc_summary "$a" "$b" "$c" "$d" ;;
    "@round "*) IFS='|' read -r a b c d e f <<< "${1#@round }"; cvc_round "$a" "$b" "$c" "$d" "$e" "$f" ;;
    "@stage "*) IFS='|' read -r a b c d <<< "${1#@stage }"; cvc_stage "$a" "$b" "$c" "$d" ;;
    "@template-comment")
      printf '%s\n' '<!-- Or write `None` / `No deviations` as plain text when there were no deviations.' \
        '     If there are multiple deviations, use one bullet per deviation. -->' >> "$keep"
      cvc_set CVC_FILE "$keep"
      ;;
    *) cvc_set CVC_FILE "$keep"; cvc_verification_macro "$1" ;;
  esac
}

cvc_run_cases() {
  local line
  while IFS= read -r line; do
    case "$line" in
      "== "*) cvc_new_case "${line#== }"; cvc_set CVC_FILE "" ;;
      "@"*) cvc_macro "$line" ;;
      "?f "*) cvc_set CVC_FLAGS "${line#?f }" ;;
      "?s "*) cvc_set CVC_STATUS "${line#?s }" ;;
      "?run "*) cvc_set CVC_FLAGS "${line#?run }"; cvc_set CVC_RAN "" ;;
      "?in "*) cvc_section "${line#?in }" || return 1 ;;
      "?"*)
        cvc_ensure_run || return 1
        cvc_assert "$line" || { cvc_report "$line"; return 1; }
        ;;
      *) [ -z "$line" ] || [ -z "$CVC_FILE" ] || printf '%s\n' "${line//%N/#}" >> "$CVC_FILE" ;;
    esac
  done
  cvc_ensure_run
}
