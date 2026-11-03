ADVERSARIAL_JOB=$'evil "job" with \\ backslash\nnewline `backtick` ${evil} and */ close-comment mentions import and require( and Date.now and Math.random too @@JOB@@'

PROJECT_A=$(new_project)
CONTROL_ROOT_A=$(new_control_root "$PROJECT_A" wf-pair \
  web-engineer nova-route balanced \
  web-code-critic nova-route fast)

CONTRACT_A=$(bash "$TASK_CONTRACT" issue "$PROJECT_A" pair-1 \
  --command integration-test --role web-engineer --team pair --job "$ADVERSARIAL_JOB" \
  --group fixed \
  --control-root "$CONTROL_ROOT_A" --requested-backend workflow --resolved-backend workflow \
  --write-capability directory:src)
TASK_ID_A=$(basename "$CONTRACT_A" .json)

AGEN_OUTPUT_A=$(MERIDIAN_AGENT_RANDOM_SEED=101 run_with_modern_bash "$AGENT_GENERATOR" --pair web-engineer \
  --job "$ADVERSARIAL_JOB" --contract "$CONTRACT_A" --task-id "$TASK_ID_A" \
  --control-root "$CONTROL_ROOT_A" --write-capability directory:src \
  --execution-backend workflow 2>&1)
AGEN_RC_A=$?
check "agent-generator mints a real workflow-backend pair" "$AGEN_RC_A"

ENGINEER_A=$(engineer_name_from_output "$AGEN_OUTPUT_A")
CRITIC_A=$(critic_name_from_output "$AGEN_OUTPUT_A")
check_test "SPAWN_READY output names an engineer" -n "$ENGINEER_A"
check_test "SPAWN_READY output names a critic" -n "$CRITIC_A"

WGEN_OUTPUT_A=$(run_with_modern_bash "$WORKFLOW_GENERATOR" pair web-engineer \
  --job "$ADVERSARIAL_JOB" --contract "$CONTRACT_A" --task-id "$TASK_ID_A" \
  --control-root "$CONTROL_ROOT_A" --autonomy standard \
  --engineer-name "$ENGINEER_A" --critic-name "$CRITIC_A" 2>&1)
WGEN_RC_A=$?
check "workflow-generator accepts the fed SPAWN_READY names" "$WGEN_RC_A"
grep -q '^WORKFLOW_READY' <<< "$WGEN_OUTPUT_A"; check "prints a WORKFLOW_READY line" "$?"

SCRIPT_A="$CONTROL_ROOT_A/workflows/$TASK_ID_A.js"
check_test "the rendered workflow script exists" -f "$SCRIPT_A"

META_LINE_A=$(head -n1 "$SCRIPT_A")
META_JSON_A=${META_LINE_A#"export const meta = "}
META_JSON_A=${META_JSON_A%";"}
jq -e . <<< "$META_JSON_A" >/dev/null 2>&1
check "line 1 parses as JSON through jq -e" "$?"

BODY_PHASES_A=$(tail -n +2 "$SCRIPT_A" | grep -oE 'phase\("[^"]*"\)' | sed -E 's/^phase\("//; s/"\)$//' | jq -Rcs 'split("\n") | map(select(length > 0))')
META_PHASES_A=$(jq -c '.phases' <<< "$META_JSON_A")
check_test "every phase() title matches meta.phases" "$BODY_PHASES_A" = "$META_PHASES_A"

for forbidden in import 'require(' 'Date.now' 'Math.random'; do
  grep -qF "$forbidden" "$SCRIPT_A"
  check "adversarial job mentioning '$forbidden' still lets generation succeed" "$?"
done
check_test "adversarial job round-trips through the JOB constant, forbidden words included" \
  "$(grep -c 'mentions import and require( and Date.now and Math.random too' "$SCRIPT_A")" -ge 1

for forbidden in import 'require(' 'Date.now' 'Math.random'; do
  forbidden_token_confined_to_known_lines "$SCRIPT_A" "$forbidden"
  check "forbidden token '$forbidden' appears only inside the JOB constant or the meta line" "$?"
done

if command -v node >/dev/null 2>&1; then
  SYNTAX_WRAP="$WORK_ROOT/syntax-check.mjs"
  { printf '(async () => {\n'; tail -n +2 "$SCRIPT_A"; printf '\n})\n'; } > "$SYNTAX_WRAP"
  node --check --input-type=module - < "$SYNTAX_WRAP" >/dev/null 2>&1
  check "the rendered script passes node --check" "$?"
fi

WORKFLOW_MANIFEST_A="$CONTROL_ROOT_A/workflow-manifest.json"
REGISTERED_ARGS_DIGEST_A=$(jq -r --arg id "$TASK_ID_A" '.workflows[$id].args_digest // empty' "$WORKFLOW_MANIFEST_A")
EXPECTED_ARGS_DIGEST=$(printf 'null' | shasum -a 256 | awk '{print $1}')
check_test "the registered args_digest is pinned to sha256(\"null\")" "$REGISTERED_ARGS_DIGEST_A" = "$EXPECTED_ARGS_DIGEST"

WGEN_UNREGISTERED=$(run_with_modern_bash "$WORKFLOW_GENERATOR" pair web-engineer \
  --job "$ADVERSARIAL_JOB" --contract "$CONTRACT_A" --task-id "$TASK_ID_A" \
  --control-root "$CONTROL_ROOT_A" --autonomy standard \
  --engineer-name "meridian-web-engineer-bogus-bogus-bogus" --critic-name "$CRITIC_A" 2>&1)
check_test "a name absent from the manifest is refused" "$?" -ne 0
grep -qi 'not registered' <<< "$WGEN_UNREGISTERED"; check "the refusal names the missing manifest entry" "$?"

WGEN_TAMPERED=$(run_with_modern_bash "$WORKFLOW_GENERATOR" pair web-engineer \
  --job "tampered job text, not what the contract was issued for" --contract "$CONTRACT_A" --task-id "$TASK_ID_A" \
  --control-root "$CONTROL_ROOT_A" --autonomy standard \
  --engineer-name "$ENGINEER_A" --critic-name "$CRITIC_A" 2>&1)
check_test "tampered job text is refused" "$?" -ne 0
grep -qi 'job digest mismatch' <<< "$WGEN_TAMPERED"; check "the refusal names the job digest mismatch" "$?"

SCRIPT_A_BEFORE_RETRY=$(cat "$SCRIPT_A")
run_with_modern_bash "$WORKFLOW_GENERATOR" pair web-engineer \
  --job "$ADVERSARIAL_JOB" --contract "$CONTRACT_A" --task-id "$TASK_ID_A" \
  --control-root "$CONTROL_ROOT_A" --autonomy standard \
  --engineer-name "$ENGINEER_A" --critic-name "$CRITIC_A" >/dev/null 2>&1
check_test "a duplicate generation for an already-registered contract is refused" "$?" -ne 0
check_test "the refused duplicate leaves the original script on disk" -f "$SCRIPT_A"
if [ -f "$SCRIPT_A" ]; then
  check_test "the refused duplicate does not alter the original script" "$(cat "$SCRIPT_A")" = "$SCRIPT_A_BEFORE_RETRY"
else
  check "the refused duplicate does not alter the original script" 1
fi
