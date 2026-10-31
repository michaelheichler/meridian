require_run_manifest() {
  ROSTER_JSON=$(jq -ce '.teammates // [] | map(.name)' "$RUN_ROOT/run.json") \
    || fail_diag 'run state roster is unreadable'
  [ "$(jq 'length' <<< "$ROSTER_JSON")" -ge 1 ] || fail_diag 'run state has no teammates'
  CONTROL_ROOT_RECORD=$(jq -r '.control_root // empty' "$RUN_ROOT/run.json")
  [ -n "$CONTROL_ROOT_RECORD" ] || fail_diag 'run state is missing its control root record'
  MANIFEST_PATH=$(lbwc_control_root_manifest_path "$CONTROL_ROOT_RECORD" 2>/dev/null) \
    || fail_diag "control root is unavailable: $CONTROL_ROOT_RECORD"
  [ -f "$MANIFEST_PATH" ] || fail_diag "agent manifest is missing: $MANIFEST_PATH"
  jq -e 'type == "object" and (.agents | type == "object")' "$MANIFEST_PATH" >/dev/null \
    || fail_diag 'agent manifest is unreadable'
  jq -e --argjson roster "$ROSTER_JSON" --arg contract "$EXPECTED_CONTRACT" \
    --arg requested "$CONTRACT_REQUESTED_BACKEND" --arg resolved "$CONTRACT_RESOLVED_BACKEND" '
    . as $manifest
    | all($roster[];
        ($manifest.agents[.] | type == "object")
        and $manifest.agents[.].contract_id == $contract
        and ($manifest.agents[.].execution | type == "object")
        and $manifest.agents[.].execution.requested_backend == $requested
        and $manifest.agents[.].execution.resolved_backend == $resolved
      )
  ' "$MANIFEST_PATH" >/dev/null || fail_diag 'manifest backend metadata does not match the contract'
}

require_run_roster() {
  require_run_contract
  require_run_manifest
}
