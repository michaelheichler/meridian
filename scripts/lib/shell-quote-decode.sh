DECODED_VALUE=""

decode_octal_escape() {
  local text="$1" idx="$2" digits="" probe
  while [ "${#digits}" -lt 3 ]; do
    probe="${text:$((idx + ${#digits})):1}"
    case "$probe" in
      [0-7]) digits="$digits$probe" ;;
      *) break ;;
    esac
  done
  ESCAPE_CONSUMED="${#digits}"
  printf -v ESCAPE_TEXT '%b' "\\0$digits"
}

decode_hex_escape() {
  local text="$1" idx="$2" digits="" probe
  while [ "${#digits}" -lt 2 ]; do
    probe="${text:$((idx + ${#digits})):1}"
    case "$probe" in
      [0-9a-fA-F]) digits="$digits$probe" ;;
      *) break ;;
    esac
  done
  ESCAPE_CONSUMED="${#digits}"
  printf -v ESCAPE_TEXT '%b' "\\x$digits"
}

decode_ansi_escape() {
  local text="$1" idx="$2" code="${1:$2:1}"
  ESCAPE_CONSUMED=1
  case "$code" in
    n) ESCAPE_TEXT=$'\n' ;;
    t) ESCAPE_TEXT=$'\t' ;;
    r) ESCAPE_TEXT=$'\r' ;;
    a) ESCAPE_TEXT=$'\a' ;;
    b) ESCAPE_TEXT=$'\b' ;;
    f) ESCAPE_TEXT=$'\f' ;;
    v) ESCAPE_TEXT=$'\v' ;;
    e|E) ESCAPE_TEXT=$'\033' ;;
    [0-7]) decode_octal_escape "$text" "$idx" ;;
    x) decode_hex_escape "$text" "$((idx + 1))"; ESCAPE_CONSUMED=$((ESCAPE_CONSUMED + 1)) ;;
    *) ESCAPE_TEXT="$code" ;;
  esac
}

decode_ansi_c_body() {
  local text="$1" out="" idx=0 len="${#1}" letter
  while [ "$idx" -lt "$len" ]; do
    letter="${text:$idx:1}"
    idx=$((idx + 1))
    if [ "$letter" != "\\" ]; then
      out="$out$letter"
      continue
    fi
    decode_ansi_escape "$text" "$idx"
    out="$out$ESCAPE_TEXT"
    idx=$((idx + ESCAPE_CONSUMED))
  done
  DECODED_VALUE="$out"
}

decode_backslash_form() {
  local text="$1" out="" idx=0 len="${#1}" letter
  while [ "$idx" -lt "$len" ]; do
    letter="${text:$idx:1}"
    idx=$((idx + 1))
    if [ "$letter" = "\\" ]; then
      letter="${text:$idx:1}"
      idx=$((idx + 1))
    fi
    out="$out$letter"
  done
  DECODED_VALUE="$out"
}

decode_printf_q() {
  local quoted="$1"
  case "$quoted" in
    "''") DECODED_VALUE="" ;;
    "\$'"*"'") decode_ansi_c_body "${quoted:2:$((${#quoted} - 3))}" ;;
    *) decode_backslash_form "$quoted" ;;
  esac
}
