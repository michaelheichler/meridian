function heading_title(line,    marks, title) {
  if (line !~ /^#+[[:space:]]/) {
    return ""
  }
  marks = line
  sub(/[^#].*$/, "", marks)
  if (length(marks) > 6) {
    return ""
  }
  title = line
  sub(/^#+[[:space:]]+/, "", title)
  sub(/[[:space:]]+$/, "", title)
  return title
}

function matches_outside_fence(line,    trimmed) {
  trimmed = line
  sub(/[[:space:]]+$/, "", trimmed)
  if (mode == "exact") {
    return trimmed == needle
  }
  if (mode == "title") {
    return needle == heading_title(line)
  }
  return index(line, needle) > 0
}

BEGIN {
  in_fence = 0
  fence_char = ""
  fence_length_active = 0
  found = 0
}

{
  if (is_fence_line($0)) {
    update_fence($0)
    next
  }
  if (in_fence) {
    next
  }
  if (matches_outside_fence($0)) {
    found = 1
    exit 0
  }
}

END {
  exit found ? 0 : 1
}
