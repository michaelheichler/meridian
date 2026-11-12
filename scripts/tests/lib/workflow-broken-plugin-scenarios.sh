PLUGIN_FIXTURE_PHASE_BROKEN="$WORK_ROOT/plugin-phase-broken"
mkdir -p "$PLUGIN_FIXTURE_PHASE_BROKEN"
cp -R "$PLUGIN_ROOT/scripts" "$PLUGIN_ROOT/templates" "$PLUGIN_ROOT/config" "$PLUGIN_FIXTURE_PHASE_BROKEN/"
sed -i.bak 's/map(select(length > 0))/map(select(length > 0)) + ["Ghost Phase"]/' \
  "$PLUGIN_FIXTURE_PHASE_BROKEN/scripts/render-workflow-template.sh"
rm -f "$PLUGIN_FIXTURE_PHASE_BROKEN/scripts/render-workflow-template.sh.bak"

PROJECT_E=$(new_project)
CONTROL_ROOT_E=$(new_control_root "$PROJECT_E" wf-phase-broken scout nova-route balanced)
CONTRACT_E=$(bash "$PLUGIN_FIXTURE_PHASE_BROKEN/scripts/task-contract.sh" issue "$PROJECT_E" phase-1 \
  --command integration-test --role scout --team solo --job "phase mismatch job" \
  --group fixed \
  --control-root "$CONTROL_ROOT_E" --requested-backend workflow --resolved-backend workflow \
  --write-capability directory:notes)
TASK_ID_E=$(basename "$CONTRACT_E" .json)
AGEN_OUT_E=$(MERIDIAN_AGENT_RANDOM_SEED=404 run_with_modern_bash "$PLUGIN_FIXTURE_PHASE_BROKEN/scripts/agent-generator.sh" scout \
  --job "phase mismatch job" --contract "$CONTRACT_E" --task-id "$TASK_ID_E" \
  --control-root "$CONTROL_ROOT_E" --write-capability directory:notes \
  --execution-backend workflow 2>&1)
NAME_E=$(grep '^SPAWN_READY' <<< "$AGEN_OUT_E" | awk '{print $2}')
check_test "phase-mismatch fixture mints an agent" -n "$NAME_E"
WGEN_PHASE_MISMATCH=$(run_with_modern_bash "$PLUGIN_FIXTURE_PHASE_BROKEN/scripts/workflow-generator.sh" solo scout \
  --job "phase mismatch job" --contract "$CONTRACT_E" --task-id "$TASK_ID_E" \
  --control-root "$CONTROL_ROOT_E" --name "$NAME_E" 2>&1)
WGEN_PHASE_MISMATCH_RC=$?
check_test "a meta.phases entry absent from the rendered body is refused" "$WGEN_PHASE_MISMATCH_RC" -ne 0
grep -qi 'phase() calls do not match meta.phases' <<< "$WGEN_PHASE_MISMATCH"; check "the refusal names the phase mismatch" "$?"
check_test "the refused phase-mismatch attempt leaves no workflow script" ! -e "$CONTROL_ROOT_E/workflows/$TASK_ID_E.js"

PLUGIN_FIXTURE_SYNTAX_BROKEN="$WORK_ROOT/plugin-syntax-broken"
mkdir -p "$PLUGIN_FIXTURE_SYNTAX_BROKEN"
cp -R "$PLUGIN_ROOT/scripts" "$PLUGIN_ROOT/templates" "$PLUGIN_ROOT/config" "$PLUGIN_FIXTURE_SYNTAX_BROKEN/"
printf '\nfunction (((;\n' >> "$PLUGIN_FIXTURE_SYNTAX_BROKEN/templates/workflows/solo.js.tpl"

PROJECT_F=$(new_project)
CONTROL_ROOT_F=$(new_control_root "$PROJECT_F" wf-syntax-broken scout nova-route balanced)
CONTRACT_F=$(bash "$PLUGIN_FIXTURE_SYNTAX_BROKEN/scripts/task-contract.sh" issue "$PROJECT_F" syntax-1 \
  --command integration-test --role scout --team solo --job "syntax failure job" \
  --group fixed \
  --control-root "$CONTROL_ROOT_F" --requested-backend workflow --resolved-backend workflow \
  --write-capability directory:notes)
TASK_ID_F=$(basename "$CONTRACT_F" .json)
AGEN_OUT_F=$(MERIDIAN_AGENT_RANDOM_SEED=505 run_with_modern_bash "$PLUGIN_FIXTURE_SYNTAX_BROKEN/scripts/agent-generator.sh" scout \
  --job "syntax failure job" --contract "$CONTRACT_F" --task-id "$TASK_ID_F" \
  --control-root "$CONTROL_ROOT_F" --write-capability directory:notes \
  --execution-backend workflow 2>&1)
NAME_F=$(grep '^SPAWN_READY' <<< "$AGEN_OUT_F" | awk '{print $2}')
check_test "syntax-failure fixture mints an agent" -n "$NAME_F"
WGEN_SYNTAX_FAIL=$(run_with_modern_bash "$PLUGIN_FIXTURE_SYNTAX_BROKEN/scripts/workflow-generator.sh" solo scout \
  --job "syntax failure job" --contract "$CONTRACT_F" --task-id "$TASK_ID_F" \
  --control-root "$CONTROL_ROOT_F" --name "$NAME_F" 2>&1)
WGEN_SYNTAX_FAIL_RC=$?
check_test "invalid JavaScript in the rendered body is refused" "$WGEN_SYNTAX_FAIL_RC" -ne 0
grep -qi 'node syntax check' <<< "$WGEN_SYNTAX_FAIL"; check "the refusal names the node syntax check" "$?"
check_test "the refused syntax-failure attempt leaves no workflow script" ! -e "$CONTROL_ROOT_F/workflows/$TASK_ID_F.js"

NO_NODE_PATH_DIR="$WORK_ROOT/no-node-path"
mkdir -p "$NO_NODE_PATH_DIR"
ln -s "$GENERATOR_BASH" "$NO_NODE_PATH_DIR/bash"
for no_node_tool in jq shasum awk sed grep head tail cat mktemp mv rm mkdir date python3 dirname basename; do
  no_node_tool_path=$(command -v "$no_node_tool") \
    || { printf 'workflow-generator-core: required tool not found: %s\n' "$no_node_tool" >&2; exit 1; }
  ln -s "$no_node_tool_path" "$NO_NODE_PATH_DIR/$no_node_tool"
done

run_without_node() {
  env PATH="$NO_NODE_PATH_DIR" "$GENERATOR_BASH" "$@"
}

PROJECT_H=$(new_project)
CONTROL_ROOT_H=$(new_control_root "$PROJECT_H" wf-no-node scout nova-route balanced)
CONTRACT_H=$(bash "$TASK_CONTRACT" issue "$PROJECT_H" no-node-1 \
  --command integration-test --role scout --team solo --job "node absent fallback job" \
  --group fixed \
  --control-root "$CONTROL_ROOT_H" --requested-backend workflow --resolved-backend workflow \
  --write-capability directory:notes)
TASK_ID_H=$(basename "$CONTRACT_H" .json)
AGEN_OUT_H=$(MERIDIAN_AGENT_RANDOM_SEED=909 run_with_modern_bash "$AGENT_GENERATOR" scout \
  --job "node absent fallback job" --contract "$CONTRACT_H" --task-id "$TASK_ID_H" \
  --control-root "$CONTROL_ROOT_H" --write-capability directory:notes \
  --execution-backend workflow 2>&1)
NAME_H=$(grep '^SPAWN_READY' <<< "$AGEN_OUT_H" | awk '{print $2}')
check_test "node-absent fixture mints an agent" -n "$NAME_H"

WGEN_OUT_H=$(run_without_node "$WORKFLOW_GENERATOR" solo scout \
  --job "node absent fallback job" --contract "$CONTRACT_H" --task-id "$TASK_ID_H" \
  --control-root "$CONTROL_ROOT_H" --name "$NAME_H" 2>&1)
WGEN_H_RC=$?
check "a well-formed render still succeeds with node absent from PATH" "$WGEN_H_RC"
grep -q '^WORKFLOW_READY' <<< "$WGEN_OUT_H"; check "the node-absent success prints a WORKFLOW_READY line" "$?"
grep -qi 'node not found, falling back' <<< "$WGEN_OUT_H"; check "the node-absent success emits the fallback warning" "$?"
check_test "the node-absent success wrote a workflow script" -f "$CONTROL_ROOT_H/workflows/$TASK_ID_H.js"

WGEN_SYNTAX_FAIL_NO_NODE=$(run_without_node "$PLUGIN_FIXTURE_SYNTAX_BROKEN/scripts/workflow-generator.sh" solo scout \
  --job "syntax failure job" --contract "$CONTRACT_F" --task-id "$TASK_ID_F" \
  --control-root "$CONTROL_ROOT_F" --name "$NAME_F" 2>&1)
WGEN_SYNTAX_FAIL_NO_NODE_RC=$?
check_test "invalid JavaScript is refused with node absent from PATH" "$WGEN_SYNTAX_FAIL_NO_NODE_RC" -ne 0
grep -qi 'has unbalanced parentheses, braces, or brackets' <<< "$WGEN_SYNTAX_FAIL_NO_NODE"
check "the node-absent refusal names the fallback balance check" "$?"
check_test "the node-absent refused syntax-failure attempt leaves no workflow script" ! -e "$CONTROL_ROOT_F/workflows/$TASK_ID_F.js"

PLUGIN_FIXTURE_QUOTE_BLIND="$WORK_ROOT/plugin-quote-blind"
mkdir -p "$PLUGIN_FIXTURE_QUOTE_BLIND"
cp -R "$PLUGIN_ROOT/scripts" "$PLUGIN_ROOT/templates" "$PLUGIN_ROOT/config" "$PLUGIN_FIXTURE_QUOTE_BLIND/"
printf '\nconst QUOTE_PROBE = '\''don"t trust embedded quotes'\'';\nconst LEAKED_FORBIDDEN_TOKEN = require("nefarious");\n' \
  >> "$PLUGIN_FIXTURE_QUOTE_BLIND/templates/workflows/solo.js.tpl"

PROJECT_QB=$(new_project)
CONTROL_ROOT_QB=$(new_control_root "$PROJECT_QB" wf-quote-blind scout nova-route balanced)
CONTRACT_QB=$(bash "$PLUGIN_FIXTURE_QUOTE_BLIND/scripts/task-contract.sh" issue "$PROJECT_QB" quote-1 \
  --command integration-test --role scout --team solo --job "single quote blinding job" \
  --group fixed \
  --control-root "$CONTROL_ROOT_QB" --requested-backend workflow --resolved-backend workflow \
  --write-capability directory:notes)
TASK_ID_QB=$(basename "$CONTRACT_QB" .json)
AGEN_OUT_QB=$(MERIDIAN_AGENT_RANDOM_SEED=111 run_with_modern_bash "$PLUGIN_FIXTURE_QUOTE_BLIND/scripts/agent-generator.sh" scout \
  --job "single quote blinding job" --contract "$CONTRACT_QB" --task-id "$TASK_ID_QB" \
  --control-root "$CONTROL_ROOT_QB" --write-capability directory:notes \
  --execution-backend workflow 2>&1)
NAME_QB=$(grep '^SPAWN_READY' <<< "$AGEN_OUT_QB" | awk '{print $2}')
check_test "single-quote-blinding fixture mints an agent" -n "$NAME_QB"

WGEN_QUOTE_BLIND=$(run_with_modern_bash "$PLUGIN_FIXTURE_QUOTE_BLIND/scripts/workflow-generator.sh" solo scout \
  --job "single quote blinding job" --contract "$CONTRACT_QB" --task-id "$TASK_ID_QB" \
  --control-root "$CONTROL_ROOT_QB" --name "$NAME_QB" 2>&1)
WGEN_QUOTE_BLIND_RC=$?
check_test "a forbidden token hidden behind a single-quoted string is refused, not blinded" "$WGEN_QUOTE_BLIND_RC" -ne 0
grep -qi "forbidden token 'require(' found outside a string literal" <<< "$WGEN_QUOTE_BLIND"
check "the refusal names the forbidden token leaked past the single-quoted string" "$?"
check_test "the refused single-quote-blinding attempt leaves no workflow script" ! -e "$CONTROL_ROOT_QB/workflows/$TASK_ID_QB.js"
