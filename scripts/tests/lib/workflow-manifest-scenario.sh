PROJECT_D=$(new_project)
CONTROL_ROOT_D=$(new_control_root "$PROJECT_D" wf-manifest scout nova-route balanced)
CONTRACT_D=$(bash "$TASK_CONTRACT" issue "$PROJECT_D" manifest-1 \
  --command integration-test --role scout --team solo --job "manifest mismatch job" \
  --group fixed \
  --control-root "$CONTROL_ROOT_D" --requested-backend workflow --resolved-backend workflow \
  --write-capability directory:notes)
TASK_ID_D=$(basename "$CONTRACT_D" .json)
AGEN_OUT_D=$(LBWC_AGENT_RANDOM_SEED=303 run_with_modern_bash "$AGENT_GENERATOR" scout \
  --job "manifest mismatch job" --contract "$CONTRACT_D" --task-id "$TASK_ID_D" \
  --control-root "$CONTROL_ROOT_D" --write-capability directory:notes \
  --execution-backend workflow 2>&1)
NAME_D=$(grep '^SPAWN_READY' <<< "$AGEN_OUT_D" | awk '{print $2}')
check_test "manifest-mismatch fixture mints an agent" -n "$NAME_D"

MANIFEST_D_PATH="$CONTROL_ROOT_D/agent-manifest.json"
DEF_PATH_D="$PROJECT_D/.claude/agents/$NAME_D.md"

mutate_manifest_field_d() {
  local field="$1" value="$2"
  jq --arg n "$NAME_D" --arg f "$field" --arg v "$value" '.agents[$n][$f] = $v' "$MANIFEST_D_PATH" > "$MANIFEST_D_PATH.tmp"
  mv "$MANIFEST_D_PATH.tmp" "$MANIFEST_D_PATH"
}
run_wgen_d() {
  run_with_modern_bash "$WORKFLOW_GENERATOR" solo scout \
    --job "manifest mismatch job" --contract "$CONTRACT_D" --task-id "$TASK_ID_D" \
    --control-root "$CONTROL_ROOT_D" --name "$NAME_D" 2>&1
}

ORIG_ROLE_D=$(jq -r --arg n "$NAME_D" '.agents[$n].role' "$MANIFEST_D_PATH")
mutate_manifest_field_d role "not-scout"
WGEN_ROLE_MISMATCH=$(run_wgen_d); WGEN_ROLE_RC=$?
check_test "a manifest role mismatch is refused" "$WGEN_ROLE_RC" -ne 0
grep -qi 'manifest role mismatch' <<< "$WGEN_ROLE_MISMATCH"; check "the refusal names the manifest role mismatch" "$?"
check_test "the refused role-mismatch attempt leaves no workflow script" ! -e "$CONTROL_ROOT_D/workflows/$TASK_ID_D.js"
mutate_manifest_field_d role "$ORIG_ROLE_D"

ORIG_CONTRACT_ID_D=$(jq -r --arg n "$NAME_D" '.agents[$n].contract_id' "$MANIFEST_D_PATH")
mutate_manifest_field_d contract_id "bogus-contract-id"
WGEN_CID_MISMATCH=$(run_wgen_d); WGEN_CID_RC=$?
check_test "a manifest contract id mismatch is refused" "$WGEN_CID_RC" -ne 0
grep -qi 'manifest contract id mismatch' <<< "$WGEN_CID_MISMATCH"; check "the refusal names the manifest contract id mismatch" "$?"
mutate_manifest_field_d contract_id "$ORIG_CONTRACT_ID_D"

ORIG_TASK_IDENTITY_D=$(jq -r --arg n "$NAME_D" '.agents[$n].task_identity' "$MANIFEST_D_PATH")
mutate_manifest_field_d task_identity "bogus-task-identity"
WGEN_TID_MISMATCH=$(run_wgen_d); WGEN_TID_RC=$?
check_test "a manifest task identity mismatch is refused" "$WGEN_TID_RC" -ne 0
grep -qi 'manifest task identity mismatch' <<< "$WGEN_TID_MISMATCH"; check "the refusal names the manifest task identity mismatch" "$?"
mutate_manifest_field_d task_identity "$ORIG_TASK_IDENTITY_D"

ORIG_DEFINITION_SHA_D=$(jq -r --arg n "$NAME_D" '.agents[$n].definition_sha256' "$MANIFEST_D_PATH")
mutate_manifest_field_d definition_sha256 "0000000000000000000000000000000000000000000000000000000000000000"
WGEN_DIGEST_MISMATCH=$(run_wgen_d); WGEN_DIGEST_RC=$?
check_test "a manifest definition digest mismatch is refused" "$WGEN_DIGEST_RC" -ne 0
grep -qi 'manifest definition digest mismatch' <<< "$WGEN_DIGEST_MISMATCH"; check "the refusal names the manifest definition digest mismatch" "$?"
mutate_manifest_field_d definition_sha256 "$ORIG_DEFINITION_SHA_D"

check_test "the minted definition file exists before the missing-file test" -f "$DEF_PATH_D"
mv "$DEF_PATH_D" "$DEF_PATH_D.bak"
WGEN_MISSING_DEF=$(run_wgen_d); WGEN_MISSING_DEF_RC=$?
check_test "a missing agent definition file is refused" "$WGEN_MISSING_DEF_RC" -ne 0
grep -qi 'agent definition file is missing' <<< "$WGEN_MISSING_DEF"; check "the refusal names the missing definition file" "$?"
mv "$DEF_PATH_D.bak" "$DEF_PATH_D"

run_wgen_d >/dev/null 2>&1; WGEN_D_CLEAN_RC=$?
check "the manifest-mismatch fixture generates cleanly once every field is restored" "$WGEN_D_CLEAN_RC"
check_test "the restored fixture wrote a workflow script" -f "$CONTROL_ROOT_D/workflows/$TASK_ID_D.js"
