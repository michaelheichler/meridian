function trim(v) {
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
  return v
}
!/^\|/ { header_found = 0; next }
/^\|/ {
  if ($0 ~ /^\|[[:space:]-]+(\|[[:space:]-]+)+\|?[[:space:]]*$/) next
  if (!header_found) {
    status_col = 0; id_col = 0; desc_col = 0
    for (i = 2; i < NF; i++) {
      cell = trim($i)
      if (cell == "Status") status_col = i
      if (cell == "ID") id_col = i
      if (cell == "Truth/Condition") desc_col = i
      if (cell == "Artifact") desc_col = i
      if (cell == "Convention") desc_col = i
      if (cell == "Description") desc_col = i
      if (cell == "Link") desc_col = i
      if (cell == "Pattern") desc_col = i
      if (cell == "Requirement") desc_col = i
      if (cell == "From") desc_col = i
    }
    if (status_col > 0) header_found = 1
    next
  }
  if (status_col > 0) {
    status = trim($(status_col))
    gsub(/\*+/, "", status)
    status = trim(status)
    if (status == "FAIL") {
      fail_index++
      fail_id = (id_col > 0) ? trim($(id_col)) : ""
      if (fail_id == "") fail_id = sprintf("FAIL-ROW-%02d", fail_index)
      desc = (desc_col > 0) ? trim($(desc_col)) : "No description"
      printf "FAIL_ID: %s | ORIGINAL: %s | RESOLUTION_REQUIRED: code-fix, plan-amendment, or documented process-exception\n", fail_id, desc
    }
  }
}
