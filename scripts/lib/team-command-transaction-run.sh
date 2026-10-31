require_run_manifest() {
  local expected_contract="$1" requested="$2" resolved="$3" out_roster="$4" out_manifest="$5"
  local roster_json control_root_record manifest_path
  roster_json=$(jq -ce '.teammates // [] | map(.name)' "$RUN_ROOT/run.json") \
    || fail_diag 'run state roster is unreadable'
  [ "$(jq 'length' <<< "$roster_json")" -ge 1 ] || fail_diag 'run state has no teammates'
  control_root_record=$(jq -r '.control_root // empty' "$RUN_ROOT/run.json")
  [ -n "$control_root_record" ] || fail_diag 'run state is missing its control root record'
  manifest_path=$(lbwc_control_root_manifest_path "$control_root_record" 2>/dev/null) \
    || fail_diag "control root is unavailable: $control_root_record"
  [ -f "$manifest_path" ] || fail_diag "agent manifest is missing: $manifest_path"
  jq -e 'type == "object" and (.agents | type == "object")' "$manifest_path" >/dev/null \
    || fail_diag 'agent manifest is unreadable'
  jq -e --argjson roster "$roster_json" --arg contract "$expected_contract" \
    --arg requested "$requested" --arg resolved "$resolved" '
    . as $manifest
    | all($roster[];
        ($manifest.agents[.] | type == "object")
        and $manifest.agents[.].contract_id == $contract
        and ($manifest.agents[.].execution | type == "object")
        and $manifest.agents[.].execution.requested_backend == $requested
        and $manifest.agents[.].execution.resolved_backend == $resolved
      )
  ' "$manifest_path" >/dev/null || fail_diag 'manifest backend metadata does not match the contract'
  printf -v "$out_roster" '%s' "$roster_json"
  printf -v "$out_manifest" '%s' "$manifest_path"
}

require_run_roster() {
  local out_roster="$1" out_manifest="$2"
  require_run_contract
  require_run_manifest "$EXPECTED_CONTRACT" "$CONTRACT_REQUESTED_BACKEND" "$CONTRACT_RESOLVED_BACKEND" "$out_roster" "$out_manifest"
}
