function trim(v) {
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
  return v
}
/^\|/ {
  if ($0 ~ /^\|[[:space:]-]+(\|[[:space:]-]+)+\|?[[:space:]]*$/) next
  for (i = 2; i < NF; i++) {
    cell = trim($i)
    if (cell == "Status") {
      status_col = i
      next
    }
  }
  if (status_col > 0) {
    status = trim($(status_col))
    gsub(/\*+/, "", status)
    status = trim(status)
    if (status == "FAIL") print
  }
}
