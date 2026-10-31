$0 == "---" {
  delim++
  if (delim == 1) { in_fm = 1; next }
  if (delim == 2) exit
}
!in_fm { next }
match($0, /^(status|qa_round|uat_round|qa_last_result|uat_last_result):[[:space:]]*/) {
  key = $0
  sub(/:.*/, "", key)
  seen[key] = substr($0, RLENGTH + 1)
}
END {
  printf "%s\t%s\t%s\t%s\t%s\n", seen["status"], seen["qa_round"], seen["uat_round"], seen["qa_last_result"], seen["uat_last_result"]
}
