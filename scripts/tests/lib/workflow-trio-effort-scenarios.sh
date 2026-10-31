PROJECT_C=$(new_project)
CONTROL_ROOT_C=$(new_control_root "$PROJECT_C" wf-trio \
  web-engineer nova-route balanced \
  web-code-critic nova-route fast \
  test-dev nova-route thorough)
CONTRACT_C=$(bash "$TASK_CONTRACT" issue "$PROJECT_C" trio-1 \
  --command integration-test --role web-engineer --team trio --job "trio job" \
  --group fixed \
  --control-root "$CONTROL_ROOT_C" --requested-backend workflow --resolved-backend workflow \
  --write-capability directory:src)
TASK_ID_C=$(basename "$CONTRACT_C" .json)

AGEN_OUTPUT_C=$(LBWC_AGENT_RANDOM_SEED=707 run_with_modern_bash "$AGENT_GENERATOR" --trio web-engineer \
  --job "trio job" --contract "$CONTRACT_C" --task-id "$TASK_ID_C" \
  --control-root "$CONTROL_ROOT_C" --write-capability directory:src \
  --execution-backend workflow 2>&1)
AGEN_RC_C=$?
check "agent-generator mints a real workflow-backend trio" "$AGEN_RC_C"

ENGINEER_C=$(nth_spawn_ready_name "$AGEN_OUTPUT_C" 1)
CRITIC_C=$(nth_spawn_ready_name "$AGEN_OUTPUT_C" 2)
TESTDEV_C=$(nth_spawn_ready_name "$AGEN_OUTPUT_C" 3)
check_test "SPAWN_READY output names a trio engineer" -n "$ENGINEER_C"
check_test "SPAWN_READY output names a trio critic" -n "$CRITIC_C"
check_test "SPAWN_READY output names a trio test-dev" -n "$TESTDEV_C"

WGEN_OUTPUT_C=$(run_with_modern_bash "$WORKFLOW_GENERATOR" trio web-engineer \
  --job "trio job" --contract "$CONTRACT_C" --task-id "$TASK_ID_C" \
  --control-root "$CONTROL_ROOT_C" --autonomy standard \
  --engineer-name "$ENGINEER_C" --critic-name "$CRITIC_C" --testdev-name "$TESTDEV_C" 2>&1)
check "workflow-generator accepts the fed trio SPAWN_READY names" "$?"
grep -q '^WORKFLOW_READY' <<< "$WGEN_OUTPUT_C"; check "trio generation prints a WORKFLOW_READY line" "$?"

SCRIPT_C="$CONTROL_ROOT_C/workflows/$TASK_ID_C.js"
check_test "the rendered trio workflow script exists" -f "$SCRIPT_C"
check_test "the rendered script names the engineer agent type" "$(grep -c "\"$ENGINEER_C\"" "$SCRIPT_C")" -ge 1
check_test "the rendered script names the critic agent type" "$(grep -c "\"$CRITIC_C\"" "$SCRIPT_C")" -ge 1
check_test "the rendered script names the test-dev agent type" "$(grep -c "\"$TESTDEV_C\"" "$SCRIPT_C")" -ge 1

ENGINEER_EFFORT_C=$(grep -m1 '^effort:' "$PROJECT_C/.claude/agents/$ENGINEER_C.md" | sed 's/^effort: "//; s/"$//')
CRITIC_EFFORT_C=$(grep -m1 '^effort:' "$PROJECT_C/.claude/agents/$CRITIC_C.md" | sed 's/^effort: "//; s/"$//')
TESTDEV_EFFORT_C=$(grep -m1 '^effort:' "$PROJECT_C/.claude/agents/$TESTDEV_C.md" | sed 's/^effort: "//; s/"$//')
check_test "each trio member resolved its own distinct effort" \
  "$ENGINEER_EFFORT_C:$CRITIC_EFFORT_C:$TESTDEV_EFFORT_C" = "balanced:fast:thorough"
check_test "the rendered script carries the engineer's own resolved effort" \
  "$(grep -c "const ENGINEER_EFFORT = \"$ENGINEER_EFFORT_C\";" "$SCRIPT_C")" -eq 1
check_test "the rendered script carries the critic's own resolved effort" \
  "$(grep -c "const CRITIC_EFFORT = \"$CRITIC_EFFORT_C\";" "$SCRIPT_C")" -eq 1
check_test "the rendered script carries the test-dev's own resolved effort" \
  "$(grep -c "const TESTDEV_EFFORT = \"$TESTDEV_EFFORT_C\";" "$SCRIPT_C")" -eq 1

WORKFLOW_MANIFEST_C="$CONTROL_ROOT_C/workflow-manifest.json"
ROSTER_C=$(jq -c --arg id "$TASK_ID_C" '.workflows[$id].roster // []' "$WORKFLOW_MANIFEST_C")
EXPECTED_ROSTER_C=$(jq -cn --arg e "$ENGINEER_C" --arg c "$CRITIC_C" --arg t "$TESTDEV_C" '[$e, $c, $t]')
check_test "the registered roster holds exactly the three trio names in order" "$ROSTER_C" = "$EXPECTED_ROSTER_C"

PROJECT_G=$(new_project)
CONTROL_ROOT_G=$(new_control_root "$PROJECT_G" wf-no-effort scout nova-route "")
CONTRACT_G=$(bash "$TASK_CONTRACT" issue "$PROJECT_G" effort-1 \
  --command integration-test --role scout --team solo --job "unresolved effort job" \
  --group fixed \
  --control-root "$CONTROL_ROOT_G" --requested-backend workflow --resolved-backend workflow \
  --write-capability directory:notes)
TASK_ID_G=$(basename "$CONTRACT_G" .json)
AGEN_OUT_G=$(LBWC_AGENT_RANDOM_SEED=808 run_with_modern_bash "$AGENT_GENERATOR" scout \
  --job "unresolved effort job" --contract "$CONTRACT_G" --task-id "$TASK_ID_G" \
  --control-root "$CONTROL_ROOT_G" --write-capability directory:notes \
  --execution-backend workflow 2>&1)
NAME_G=$(grep '^SPAWN_READY' <<< "$AGEN_OUT_G" | awk '{print $2}')
check_test "unresolved-effort fixture mints an agent" -n "$NAME_G"
check_test "the minted definition carries no effort frontmatter line" \
  "$(grep -c '^effort:' "$PROJECT_G/.claude/agents/$NAME_G.md")" -eq 0

WGEN_OUT_G=$(run_with_modern_bash "$WORKFLOW_GENERATOR" solo scout \
  --job "unresolved effort job" --contract "$CONTRACT_G" --task-id "$TASK_ID_G" \
  --control-root "$CONTROL_ROOT_G" --name "$NAME_G" 2>&1); WGEN_G_RC=$?
check "workflow generation succeeds for an agent with no resolved effort" "$WGEN_G_RC"
grep -q '^WORKFLOW_READY' <<< "$WGEN_OUT_G"; check "unresolved-effort generation prints a WORKFLOW_READY line" "$?"

SCRIPT_G="$CONTROL_ROOT_G/workflows/$TASK_ID_G.js"
check_test "the unresolved-effort workflow script exists" -f "$SCRIPT_G"
case "$(cat "$SCRIPT_G" 2>/dev/null)" in
  *"const EFFORT = null;"*) check "the rendered EFFORT constant is the null literal" 0 ;;
  *) check "the rendered EFFORT constant is the null literal" 1 ;;
esac

if command -v node >/dev/null 2>&1; then
  HARNESS="$PLUGIN_ROOT/tests/fixtures/workflow-harness.cjs"
  HARNESS_OUT_G=$(node "$HARNESS" "$SCRIPT_G" '["ok"]' 2>&1); HARNESS_RC_G=$?
  check "the harness runs the unresolved-effort script" "$HARNESS_RC_G"
  check_test "the rendered agent options carry no effort key" \
    "$(jq -r '.agentCalls[0].hasEffort' <<< "$HARNESS_OUT_G")" = false
fi
