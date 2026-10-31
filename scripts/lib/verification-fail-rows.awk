function trim(v) {
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
  return v
}
!/^\|/ { header_found = 0; next }
/^\|/ {
  if ($0 ~ /^\|[[:space:]-]+(\|[[:space:]-]+)+\|?[[:space:]]*$/) next
  if (!header_found) {
    status_col = 0
    for (i = 2; i < NF; i++) {
      cell = trim($i)
      if (cell == "Status") status_col = i
    }
    if (status_col > 0) header_found = 1
    next
  }
  if (status_col > 0) {
    status = trim($(status_col))
    gsub(/\*+/, "", status)
    status = trim(status)
    if (status == "FAIL") {
      found = 1
      exit
    }
  }
}
END { exit(found ? 0 : 1) }
