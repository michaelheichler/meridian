PROJECT_B1=$(new_project)
CONTROL_ROOT_B1=$(new_control_root "$PROJECT_B1" wf-det scout nova-route balanced)
CONTRACT_B1=$(bash "$TASK_CONTRACT" issue "$PROJECT_B1" det-1 \
  --command integration-test --role scout --team solo --job "deterministic job" \
  --group fixed \
  --control-root "$CONTROL_ROOT_B1" --requested-backend workflow --resolved-backend workflow \
  --write-capability directory:notes)
TASK_ID_B1=$(basename "$CONTRACT_B1" .json)
AGEN_OUT_B1=$(LBWC_AGENT_RANDOM_SEED=202 run_with_modern_bash "$AGENT_GENERATOR" scout \
  --job "deterministic job" --contract "$CONTRACT_B1" --task-id "$TASK_ID_B1" \
  --control-root "$CONTROL_ROOT_B1" --write-capability directory:notes \
  --execution-backend workflow 2>&1)
NAME_B1=$(grep '^SPAWN_READY' <<< "$AGEN_OUT_B1" | awk '{print $2}')
run_with_modern_bash "$WORKFLOW_GENERATOR" solo scout \
  --job "deterministic job" --contract "$CONTRACT_B1" --task-id "$TASK_ID_B1" \
  --control-root "$CONTROL_ROOT_B1" --name "$NAME_B1" >/dev/null 2>&1
FIRST_JS="$CONTROL_ROOT_B1/workflows/$TASK_ID_B1.js"

PROJECT_B2=$(new_project)
CONTROL_ROOT_B2=$(new_control_root "$PROJECT_B2" wf-det scout nova-route balanced)
CONTRACT_B2=$(bash "$TASK_CONTRACT" issue "$PROJECT_B2" det-1 \
  --command integration-test --role scout --team solo --job "deterministic job" \
  --group fixed \
  --control-root "$CONTROL_ROOT_B2" --requested-backend workflow --resolved-backend workflow \
  --write-capability directory:notes)
TASK_ID_B2=$(basename "$CONTRACT_B2" .json)
AGEN_OUT_B2=$(LBWC_AGENT_RANDOM_SEED=202 run_with_modern_bash "$AGENT_GENERATOR" scout \
  --job "deterministic job" --contract "$CONTRACT_B2" --task-id "$TASK_ID_B2" \
  --control-root "$CONTROL_ROOT_B2" --write-capability directory:notes \
  --execution-backend workflow 2>&1)
NAME_B2=$(grep '^SPAWN_READY' <<< "$AGEN_OUT_B2" | awk '{print $2}')
run_with_modern_bash "$WORKFLOW_GENERATOR" solo scout \
  --job "deterministic job" --contract "$CONTRACT_B2" --task-id "$TASK_ID_B2" \
  --control-root "$CONTROL_ROOT_B2" --name "$NAME_B2" >/dev/null 2>&1
SECOND_JS="$CONTROL_ROOT_B2/workflows/$TASK_ID_B2.js"

check_test "the task id is identical across the two isolated runs" "$TASK_ID_B1" = "$TASK_ID_B2"
check_test "the minted agent name is identical across the two isolated runs" "$NAME_B1" = "$NAME_B2"
check_test "the first deterministic run wrote a script" -f "$FIRST_JS"
check_test "the second deterministic run wrote a script" -f "$SECOND_JS"
if [ -f "$FIRST_JS" ] && [ -f "$SECOND_JS" ]; then
  cmp -s "$FIRST_JS" "$SECOND_JS"
  check "two identical invocations produce byte-identical files" "$?"
else
  check "two identical invocations produce byte-identical files" 1
fi

PROJECT_I=$(new_project)
CONTROL_ROOT_I=$(new_control_root "$PROJECT_I" wf-disabled-config scout nova-route balanced)
jq '.workflow_execution.enabled = false' "$CONTROL_ROOT_I/config.json" > "$CONTROL_ROOT_I/config.json.tmp"
mv "$CONTROL_ROOT_I/config.json.tmp" "$CONTROL_ROOT_I/config.json"
CONTRACT_I=$(bash "$TASK_CONTRACT" issue "$PROJECT_I" disabled-config-1 \
  --command integration-test --role scout --team solo --job "disabled config job" \
  --group fixed \
  --control-root "$CONTROL_ROOT_I" --requested-backend workflow --resolved-backend workflow \
  --write-capability directory:notes)
TASK_ID_I=$(basename "$CONTRACT_I" .json)
WGEN_DISABLED_CONFIG=$(run_with_modern_bash "$WORKFLOW_GENERATOR" solo scout \
  --job "disabled config job" --contract "$CONTRACT_I" --task-id "$TASK_ID_I" \
  --control-root "$CONTROL_ROOT_I" --name "lbwc-scout-unused-unused-unused" 2>&1)
check_test "generation is refused when workflow_execution.enabled is false" "$?" -ne 0
grep -qi 'workflow backend is disabled in configuration' <<< "$WGEN_DISABLED_CONFIG"
check "the refusal names the disabled configuration" "$?"
check_test "the refused disabled-config attempt leaves no workflow script" ! -e "$CONTROL_ROOT_I/workflows/$TASK_ID_I.js"

PROJECT_J=$(new_project)
CONTROL_ROOT_J=$(new_control_root "$PROJECT_J" wf-unavailable-cap scout nova-route balanced)
jq '.workflow = {available:false, unavailable_reasons:["Claude Code 2.1.100 is older than the workflow version floor 2.1.154."]}' \
  "$CONTROL_ROOT_J/claude-capabilities.json" > "$CONTROL_ROOT_J/claude-capabilities.json.tmp"
mv "$CONTROL_ROOT_J/claude-capabilities.json.tmp" "$CONTROL_ROOT_J/claude-capabilities.json"
CONTRACT_J=$(bash "$TASK_CONTRACT" issue "$PROJECT_J" unavailable-cap-1 \
  --command integration-test --role scout --team solo --job "unavailable capability job" \
  --group fixed \
  --control-root "$CONTROL_ROOT_J" --requested-backend workflow --resolved-backend workflow \
  --write-capability directory:notes)
TASK_ID_J=$(basename "$CONTRACT_J" .json)
WGEN_UNAVAILABLE_CAP=$(run_with_modern_bash "$WORKFLOW_GENERATOR" solo scout \
  --job "unavailable capability job" --contract "$CONTRACT_J" --task-id "$TASK_ID_J" \
  --control-root "$CONTROL_ROOT_J" --name "lbwc-scout-unused-unused-unused" 2>&1)
check_test "generation is refused when the capability catalog reports unavailable" "$?" -ne 0
grep -qi 'workflow backend is unavailable' <<< "$WGEN_UNAVAILABLE_CAP"
check "the refusal reports unavailability" "$?"
grep -qF 'Claude Code 2.1.100 is older than the workflow version floor 2.1.154.' <<< "$WGEN_UNAVAILABLE_CAP"
check "the refusal names the unavailable reason verbatim" "$?"
check_test "the refused unavailable-capability attempt leaves no workflow script" ! -e "$CONTROL_ROOT_J/workflows/$TASK_ID_J.js"

PROJECT_K=$(new_project)
CONTROL_ROOT_K=$(new_control_root "$PROJECT_K" wf-live-disable scout nova-route balanced)
CONTRACT_K=$(bash "$TASK_CONTRACT" issue "$PROJECT_K" live-disable-1 \
  --command integration-test --role scout --team solo --job "live disable job" \
  --group fixed \
  --control-root "$CONTROL_ROOT_K" --requested-backend workflow --resolved-backend workflow \
  --write-capability directory:notes)
TASK_ID_K=$(basename "$CONTRACT_K" .json)
WGEN_LIVE_DISABLE=$(CLAUDE_CODE_DISABLE_WORKFLOWS=1 run_with_modern_bash "$WORKFLOW_GENERATOR" solo scout \
  --job "live disable job" --contract "$CONTRACT_K" --task-id "$TASK_ID_K" \
  --control-root "$CONTROL_ROOT_K" --name "lbwc-scout-unused-unused-unused" 2>&1)
check_test "generation fails closed when CLAUDE_CODE_DISABLE_WORKFLOWS is live-set against a stale available catalog" "$?" -ne 0
grep -qi 'CLAUDE_CODE_DISABLE_WORKFLOWS is set in this session' <<< "$WGEN_LIVE_DISABLE"
check "the refusal names the live CLAUDE_CODE_DISABLE_WORKFLOWS override" "$?"

PROJECT_L=$(new_project)
CONTROL_ROOT_L=$(new_control_root "$PROJECT_L" wf-live-subagent scout nova-route balanced)
CONTRACT_L=$(bash "$TASK_CONTRACT" issue "$PROJECT_L" live-subagent-1 \
  --command integration-test --role scout --team solo --job "live subagent model job" \
  --group fixed \
  --control-root "$CONTROL_ROOT_L" --requested-backend workflow --resolved-backend workflow \
  --write-capability directory:notes)
TASK_ID_L=$(basename "$CONTRACT_L" .json)
WGEN_LIVE_SUBAGENT=$(CLAUDE_CODE_SUBAGENT_MODEL=claude-opus run_with_modern_bash "$WORKFLOW_GENERATOR" solo scout \
  --job "live subagent model job" --contract "$CONTRACT_L" --task-id "$TASK_ID_L" \
  --control-root "$CONTROL_ROOT_L" --name "lbwc-scout-unused-unused-unused" 2>&1)
check_test "generation fails closed when CLAUDE_CODE_SUBAGENT_MODEL is live-set against a stale available catalog" "$?" -ne 0
grep -qi 'CLAUDE_CODE_SUBAGENT_MODEL is set in this session' <<< "$WGEN_LIVE_SUBAGENT"
check "the refusal names the live CLAUDE_CODE_SUBAGENT_MODEL override" "$?"
