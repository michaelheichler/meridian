$0 ~ anchor {
  in_todos = 1
  print
  next
}
in_todos && $0 ~ stop_re {
  if (!inserted) {
    print todo_line
    inserted = 1
  }
  in_todos = 0
  print
  next
}
in_todos && /^[[:space:]]*None\.?[[:space:]]*$/ {
  if (!inserted) {
    print todo_line
    inserted = 1
  }
  next
}
in_todos && /^[[:space:]]*$/ { next }
{ print }
END {
  if (in_todos && !inserted) {
    print todo_line
  }
}
