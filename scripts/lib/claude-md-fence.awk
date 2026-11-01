function fence_length(line, char,    i) {
  i = 1
  while (substr(line, i, 1) == char) {
    i++
  }
  return i - 1
}

function is_fence_line(line,    trimmed, char) {
  trimmed = line
  sub(/^[[:space:]]*/, "", trimmed)
  char = substr(trimmed, 1, 1)
  if (char != "`" && char != "~") {
    return 0
  }
  return fence_length(trimmed, char) >= 3
}

function update_fence(line,    trimmed, char, run_length, remainder) {
  trimmed = line
  sub(/^[[:space:]]*/, "", trimmed)
  char = substr(trimmed, 1, 1)
  run_length = fence_length(trimmed, char)
  remainder = substr(trimmed, run_length + 1)
  if (!in_fence) {
    in_fence = 1
    fence_char = char
    fence_length_active = run_length
  } else if (char == fence_char && run_length >= fence_length_active && remainder !~ /[^[:space:]]/) {
    in_fence = 0
    fence_char = ""
    fence_length_active = 0
  }
}
