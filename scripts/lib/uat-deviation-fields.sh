TODO_UAT_SIGNATURE=""
TODO_UAT_SOURCE_PLAN=""
TODO_UAT_SOURCE_PATH=""
TODO_UAT_DEVIATION=""
TODO_UAT_RESULT=""
TODO_UAT_DISPOSITION=""

reset_uat_deviation_fields() {
  TODO_UAT_SIGNATURE=""
  TODO_UAT_SOURCE_PLAN=""
  TODO_UAT_SOURCE_PATH=""
  TODO_UAT_DEVIATION=""
  TODO_UAT_RESULT=""
  TODO_UAT_DISPOSITION=""
}

capture_uat_deviation_field() {
  local line="$1"
  if [[ "$line" == "- **Deviation Signature:**"* ]]; then
    TODO_UAT_SIGNATURE=$(strip_uat_metadata_value "$line" "- **Deviation Signature:**")
  elif [[ "$line" == "- **Source Plan:**"* ]]; then
    TODO_UAT_SOURCE_PLAN=$(strip_uat_metadata_value "$line" "- **Source Plan:**")
  elif [[ "$line" == "- **Source Summary:**"* ]]; then
    TODO_UAT_SOURCE_PATH=$(strip_uat_metadata_value "$line" "- **Source Summary:**")
  elif [[ "$line" == "- **Source Path:**"* ]]; then
    TODO_UAT_SOURCE_PATH=$(strip_uat_metadata_value "$line" "- **Source Path:**")
  elif [[ "$line" == "- **Deviation:**"* ]]; then
    TODO_UAT_DEVIATION=$(strip_uat_metadata_value "$line" "- **Deviation:**")
  elif [[ "$line" == "- **Result:**"* ]]; then
    TODO_UAT_RESULT=$(lower_value "$(strip_uat_metadata_value "$line" "- **Result:**")")
  elif [[ "$line" == "- **Disposition:**"* ]]; then
    TODO_UAT_DISPOSITION=$(lower_value "$(strip_uat_metadata_value "$line" "- **Disposition:**")")
  fi
}

extract_requested_uat_deviation() {
  local uat_file="$1" checkpoint_id="$2"
  local line in_target=false

  reset_uat_deviation_fields

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    if [[ "$line" == "### "* ]]; then
      if [ "$in_target" = true ]; then
        return 0
      fi
      if [[ "$line" =~ ^###[[:space:]]${checkpoint_id}(:|[[:space:]]) ]]; then
        in_target=true
      else
        in_target=false
      fi
      continue
    fi

    [ "$in_target" = true ] || continue
    capture_uat_deviation_field "$line"
  done < "$uat_file"

  [ "$in_target" = true ]
}
