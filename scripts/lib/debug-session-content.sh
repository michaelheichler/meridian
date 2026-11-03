normalize_content() {
  printf '%s' "$1" | awk -v blank_re="$BLANK_LINE_RE" '
    function is_blank(line) {
      return line ~ blank_re
    }
    { buf[++n] = $0 }
    END {
      start = 1
      while (start <= n && is_blank(buf[start])) start++
      end = n
      while (end >= start && is_blank(buf[end])) end--
      for (i = start; i <= end; i++) print buf[i]
    }
  '
}

write_normalized_content_file() {
  local content="$1" file="$2"
  normalize_content "$content" > "$file"
}

normalize_block_body() {
  normalize_content "$1"
}

escape_table_cell() {
  awk '
    BEGIN { first = 1 }
    {
      sub(/\r$/, "", $0)
      gsub(/\|/, "\\|", $0)
      if (!first) printf "<br>"
      printf "%s", $0
      first = 0
    }
  '
}
