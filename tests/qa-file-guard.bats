#!/usr/bin/env bats

load test_helper
load guard_helper

setup() {
  setup_temp_dir
  EXTERNAL_TEST_DIR=""
  GUARD_ID="dev-1"
  GUARD_CONTROL_ROOT=""
  mkdir -p "$TEST_TEMP_DIR/secondary"
  cd "$TEST_TEMP_DIR"
}

teardown() {
  [ -z "$EXTERNAL_TEST_DIR" ] || rm -rf "$EXTERNAL_TEST_DIR"
  cd "$PROJECT_ROOT"
  teardown_temp_dir
}

run_guard() {
  local path="$1" agent_id="${2:-}" tool="${3:--}" cwd_mode="${4:--}"
  local key=file_path json_cwd="" planning=""
  [ "$tool" != "-" ] || tool=Write
  [ "$tool" != "NotebookEdit" ] || key=notebook_path
  case "$cwd_mode" in
    root) json_cwd="$TEST_TEMP_DIR" ;;
    secondary) json_cwd="$TEST_TEMP_DIR/secondary"; planning="$TEST_TEMP_DIR/.lbwc-planning" ;;
    secondary-noenv) json_cwd="$TEST_TEMP_DIR/secondary" ;;
  esac
  payload "tool_name=$tool" "tool_input.$key=$path" "agent_id=$agent_id" ${json_cwd:+"cwd=$json_cwd"} \
    | LBWC_PLANNING_DIR="$planning" LBWC_CONTROL_ROOT="$GUARD_CONTROL_ROOT" bash "$SCRIPTS_DIR/file-guard.sh"
}

run_raw_guard() {
  printf '%s' "$1" | bash "$SCRIPTS_DIR/file-guard.sh"
}

write_worker_manifest() {
  write_manifest "$TEST_TEMP_DIR/.lbwc-planning" "$(jq -cn --arg id "$1" --argjson entry "$2" '{agents:{($id):$entry}}')"
}

capability_entry() {
  local role="$1" kind="$2" path="$3"
  jq -cn --arg root "$TEST_TEMP_DIR" --arg role "$role" --arg kind "$kind" --arg path "$path" \
    '{role:$role,project_root:$root,capabilities:[{access:"write",kind:$kind,path:$path}]}'
}

issue_contract() {
  local dispatch="$1" task="$2" path
  path=$(bash "$SCRIPTS_DIR/task-contract.sh" issue "$TEST_TEMP_DIR" "$task" "${@:3}")
  [ "$dispatch" = "undispatched" ] || bash "$SCRIPTS_DIR/task-contract.sh" state "$TEST_TEMP_DIR" "$(basename "$path" .json)" dispatched >/dev/null
  printf '%s' "$path"
}

build_contract_worker() {
  local mutation="$1" contract id digest contract_id task_identity allowance=src/allowed.py contract_path
  contract=$(issue_contract "$mutation" task-1 --command test --role python-engineer --team solo --job "guard write" --write-allowance "$allowance")
  id=$(basename "$contract" .json)
  digest=$(jq -r .contract_digest "$contract")
  contract_id=$id
  task_identity=$id
  contract_path=$contract
  case "$mutation" in
    missing) contract_path="$TEST_TEMP_DIR/missing.json"; digest=deadbeef ;;
    tampered) jq '.write_allowances = ["src/other.py"]' "$contract" > "$contract.tmp" && mv "$contract.tmp" "$contract" ;;
    wrong-id) contract_id=wrong-id ;;
    stale-task) task_identity=old-task ;;
    wrong-digest) digest=deadbeef ;;
    allowance-drift) allowance=src/other.py ;;
  esac
  if [ "$mutation" = "no-contract-path" ]; then
    GUARD_ID=lbwc-dev-a
    write_worker_manifest "$GUARD_ID" "$(jq -cn --arg root "$TEST_TEMP_DIR" --arg allowance "$allowance" '{role:"python-engineer",project_root:$root,write_allowances:[$allowance]}')"
    return 0
  fi
  write_worker_manifest dev-1 "$(jq -cn --arg root "$TEST_TEMP_DIR" --arg allowance "$allowance" --arg path "$contract_path" --arg cid "$contract_id" --arg digest "$digest" --arg task "$task_identity" \
    '{role:"python-engineer",project_root:$root,write_allowances:[$allowance],contract_path:$path,contract_id:$cid,contract_digest:$digest,task_identity:$task}')"
}

build_root_capability_worker() {
  local contract id
  GUARD_CONTROL_ROOT="$TEST_TEMP_DIR/.temporary-agent-runfiles/runs/root-secrets"
  mkdir -p "$GUARD_CONTROL_ROOT"
  contract=$(issue_contract dispatched root-secrets --command team --role python-engineer --team solo --job "root scope" \
    --control-root "$GUARD_CONTROL_ROOT" --write-capability directory:.)
  id=$(basename "$contract" .json)
  jq -cn --arg root "$TEST_TEMP_DIR" --arg path "$contract" --arg id "$id" --arg digest "$(jq -r .contract_digest "$contract")" \
    '{agents:{"dev-1":{role:"python-engineer",project_root:$root,schema_version:3,capabilities:[{access:"write",kind:"directory",path:"."}],write_allowances:["."],contract_path:$path,contract_id:$id,contract_digest:$digest,task_identity:$id}}}' \
    > "$GUARD_CONTROL_ROOT/agent-manifest.json"
}

build_link_layout() {
  rm -rf "$TEST_TEMP_DIR/hooks"
  [ -z "$EXTERNAL_TEST_DIR" ] || rm -rf "$EXTERNAL_TEST_DIR"
  EXTERNAL_TEST_DIR=""
  write_worker_manifest dev-1 "$(jq -cn --arg root "$TEST_TEMP_DIR" '{role:"python-engineer",project_root:$root,write_allowances:["hooks/skill_gate.py"]}')"
  case "$1" in
    target-outside)
      EXTERNAL_TEST_DIR=$(mktemp -d)
      mkdir -p "$TEST_TEMP_DIR/hooks"
      touch "$EXTERNAL_TEST_DIR/skill_gate.py"
      ln -s "$EXTERNAL_TEST_DIR/skill_gate.py" "$TEST_TEMP_DIR/hooks/skill_gate.py"
      ;;
    parent-outside)
      EXTERNAL_TEST_DIR=$(mktemp -d)
      ln -s "$EXTERNAL_TEST_DIR" "$TEST_TEMP_DIR/hooks"
      ;;
    self-referential)
      mkdir -p "$TEST_TEMP_DIR/hooks"
      ln -s "skill_gate.py" "$TEST_TEMP_DIR/hooks/skill_gate.py"
      ;;
  esac
}

build_scenario() {
  local role="$1" grant="$2"
  GUARD_ID=dev-1
  GUARD_CONTROL_ROOT=""
  rm -f "$TEST_TEMP_DIR/.lbwc-planning/.agent-manifest.json"
  case "$grant" in
    unscoped) GUARD_ID="" ;;
    unregistered-lbwc) GUARD_ID=lbwc-ghost ;;
    lbwc-allow:*)
      GUARD_ID=lbwc-dev-a
      write_worker_manifest lbwc-dev-a "$(jq -cn --arg root "$TEST_TEMP_DIR" --arg role "$role" --arg path "${grant#lbwc-allow:}" '{role:$role,project_root:$root,write_allowances:[$path]}')"
      ;;
    main-pair-*)
      GUARD_ID=""
      write_worker_manifest lbwc-dev-a "$(jq -cn --arg state "${grant#main-pair-}" '{role:"python-engineer",state:$state}')"
      ;;
    allow:*)
      write_worker_manifest dev-1 "$(jq -cn --arg root "$TEST_TEMP_DIR" --arg role "$role" --arg path "${grant#allow:}" '{role:$role,project_root:$root,write_allowances:[$path]}')"
      ;;
    dir:*) write_worker_manifest dev-1 "$(capability_entry "$role" directory "${grant#dir:}")" ;;
    file:*) write_worker_manifest dev-1 "$(capability_entry "$role" file "${grant#file:}")" ;;
    none) write_worker_manifest dev-1 "$(jq -cn --arg root "$TEST_TEMP_DIR" --arg role "$role" '{role:$role,project_root:$root}')" ;;
    no-root) write_worker_manifest dev-1 "$(jq -cn --arg role "$role" '{role:$role,write_allowances:["src/main.py"]}')" ;;
    contract:*) build_contract_worker "${grant#contract:}" ;;
    root-capability) build_root_capability_worker ;;
    link:*) build_link_layout "${grant#link:}" ;;
  esac
}

guard_case() {
  build_scenario "$2" "$3" </dev/null
  run run_guard "$4" "$GUARD_ID" "${5:--}" "${6:--}"
}

@test "file-guard allows every in-scope write and leaves the tree untouched" {
  local before after
  while IFS='|' read -r label role grant path tool cwd_mode; do
    [ -n "$label" ] || continue
    build_scenario "$role" "$grant" </dev/null
    before=$(tree_digest "$TEST_TEMP_DIR")
    run run_guard "$path" "$GUARD_ID" "${tool:--}" "${cwd_mode:--}"
    after=$(tree_digest "$TEST_TEMP_DIR")
    expect_status "$label" 0
    expect_output_empty "$label"
    expect_same_digest "$label" "$before" "$after"
  done <<'CASES'
no-agent-identity|-|unscoped|src/main.py|-|-
exact-hook-allowance|python-engineer|allow:hooks/skill_gate.py|hooks/skill_gate.py|-|-
notebook-exact-allowance|python-engineer|allow:notebooks/a.ipynb|notebooks/a.ipynb|NotebookEdit|-
scout-planning-file|scout|allow:.lbwc-planning/phases/01-x/RESEARCH.md|.lbwc-planning/phases/01-x/RESEARCH.md|-|-
architect-planning-file|architect|allow:.lbwc-planning/ROADMAP.md|.lbwc-planning/ROADMAP.md|-|-
lead-planning-file|lead|allow:.lbwc-planning/STATE.md|.lbwc-planning/STATE.md|-|-
docs-markdown-file|docs|allow:README.md|README.md|-|-
docs-planning-file|docs|allow:.lbwc-planning/notes.json|.lbwc-planning/notes.json|-|-
qa-author-tests-dir|qa-author|allow:tests/test_thing.py|tests/test_thing.py|-|-
qa-author-explicit-hook-cwd|qa-author|allow:tests/helpers.py|tests/helpers.py|-|root
test-dev-dot-test-name|test-dev|allow:src/thing.test.ts|src/thing.test.ts|-|-
test-dev-underscore-test-name|test-dev|allow:pkg/util_test.go|pkg/util_test.go|-|-
test-dev-dot-spec-name|test-dev|allow:src/thing.spec.ts|src/thing.spec.ts|-|-
test-dev-test-directory|test-dev|allow:src/test/fixture.json|src/test/fixture.json|-|-
schema3-directory-descendant|web-engineer|dir:src/web|src/web/page.ts|-|-
schema3-directory-itself|web-engineer|dir:src/web|src/web|-|-
schema3-repository-root|web-engineer|dir:.|src/main.py|-|-
schema3-exact-file|web-engineer|file:src/one.py|src/one.py|-|-
contract-exact-allowance|python-engineer|contract:ok|src/allowed.py|-|-
main-session-docs-while-pair-open|-|main-pair-running|docs/notes.md|-|-
main-session-agent-definition-while-pair-open|-|main-pair-registered|.claude/agents/forged.md|-|-
main-session-product-after-pair-used|-|main-pair-used|src/main.py|-|-
CASES
}

@test "file-guard denies writes outside the role domain, the allowance, the contract, an open pair or a safe path shape" {
  while IFS='|' read -r label role grant path tool cwd_mode reason; do
    [ -n "$label" ] || continue
    guard_case "$label" "$role" "$grant" "$(printf '%b' "$path")" "$tool" "$cwd_mode"
    expect_status "$label" 2
    expect_output_has "$label" "$reason"
  done <<'CASES'
scout-product-source|scout|allow:src/main.py|src/main.py|-|-|role 'scout' can only write under the control root
architect-product-source|architect|allow:src/main.py|src/main.py|-|-|role 'architect' can only write under the control root
lead-product-source|lead|allow:src/main.py|src/main.py|-|-|role 'lead' can only write under the control root
docs-product-source|docs|allow:src/main.py|src/main.py|-|-|role 'docs' can only write documentation files
qa-author-product-source|qa-author|allow:src/main.py|src/main.py|-|-|role 'qa-author' can only write test files
test-dev-product-source|test-dev|allow:src/main.py|src/main.py|-|-|role 'test-dev' can only write test files
manifest-entry-without-project-root|python-engineer|no-root|src/main.py|-|-|outside worker 'dev-1' assigned write allowance
different-hook-path|python-engineer|allow:hooks/skill_gate.py|hooks/context_usage.py|-|-|outside worker 'dev-1' assigned write allowance
notebook-outside-allowance|python-engineer|allow:notebooks/allowed.ipynb|notebooks/unassigned.ipynb|NotebookEdit|-|outside worker 'dev-1' assigned write allowance
schema3-sibling-directory|web-engineer|dir:src/web|src/api/page.ts|-|-|outside worker 'dev-1' assigned write allowance
schema3-prefix-lookalike-directory|web-engineer|dir:src/web|src/webapp/page.ts|-|-|outside worker 'dev-1' assigned write allowance
schema3-exact-file-other-path|web-engineer|file:src/one.py|src/two.py|-|-|outside worker 'dev-1' assigned write allowance
worker-without-allowance|python-engineer|none|src/main.py|-|-|has no assigned write allowance
cwd-outside-primary-workspace|python-engineer|allow:hooks/skill_gate.py|hooks/skill_gate.py|-|secondary|primary workspace
generated-worker-outside-primary-without-override|python-engineer|lbwc-allow:hooks/skill_gate.py|hooks/skill_gate.py|-|secondary-noenv|primary workspace
generated-identity-without-manifest-entry|python-engineer|unregistered-lbwc|src/main.py|-|-|manifest capability could not be resolved
protected-critical-policy|python-engineer|allow:config/subagent-critical-execution.txt|config/subagent-critical-execution.txt|-|-|cannot write LBWC policy
protected-destructive-list|python-engineer|allow:config/destructive-commands.txt|config/destructive-commands.txt|-|-|cannot write LBWC policy
protected-guard-script|python-engineer|allow:scripts/file-guard.sh|scripts/file-guard.sh|-|-|cannot write LBWC policy
protected-task-contract-script|python-engineer|allow:scripts/task-contract.sh|scripts/task-contract.sh|-|-|cannot write LBWC policy
protected-lifecycle-script|python-engineer|allow:scripts/agent-lifecycle.sh|scripts/agent-lifecycle.sh|-|-|cannot write LBWC policy
protected-manifest|python-engineer|allow:.lbwc-planning/.agent-manifest.json|.lbwc-planning/.agent-manifest.json|-|-|cannot write LBWC policy
protected-contract-store|python-engineer|allow:.lbwc-planning/.contracts/tasks/forged.json|.lbwc-planning/.contracts/tasks/forged.json|-|-|cannot write LBWC policy
protected-agent-definition|python-engineer|allow:.claude/agents/forged.md|.claude/agents/forged.md|-|-|cannot write LBWC policy
root-capability-planning-config|python-engineer|root-capability|.lbwc-planning/config.json|-|-|cannot write LBWC policy
root-capability-runfiles|python-engineer|root-capability|.temporary-agent-runfiles/runs/one/run.json|-|-|cannot write LBWC policy
root-capability-dotenv|python-engineer|root-capability|.env|-|-|cannot write LBWC policy
root-capability-private-key|python-engineer|root-capability|config/private.key|-|-|cannot write LBWC policy
root-capability-credentials|python-engineer|root-capability|credentials.json|-|-|cannot write LBWC policy
contract-file-missing|python-engineer|contract:missing|src/allowed.py|-|-|contract is missing, mismatched, stale, or outside allowance
contract-tampered|python-engineer|contract:tampered|src/allowed.py|-|-|contract is missing, mismatched, stale, or outside allowance
manifest-contract-id-mismatch|python-engineer|contract:wrong-id|src/allowed.py|-|-|contract is missing, mismatched, stale, or outside allowance
manifest-task-identity-stale|python-engineer|contract:stale-task|src/allowed.py|-|-|contract is missing, mismatched, stale, or outside allowance
manifest-digest-mismatch|python-engineer|contract:wrong-digest|src/allowed.py|-|-|contract is missing, mismatched, stale, or outside allowance
manifest-allowance-drifted|python-engineer|contract:allowance-drift|src/other.py|-|-|contract is missing, mismatched, stale, or outside allowance
contract-never-dispatched|python-engineer|contract:undispatched|src/allowed.py|-|-|contract is missing, mismatched, stale, or outside allowance
generated-identity-without-contract-path|python-engineer|contract:no-contract-path|src/allowed.py|-|-|contract is missing, mismatched, stale, or outside allowance
pair-running|-|main-pair-running|src/main.py|-|-|delegate product writes
pair-registered|-|main-pair-registered|src/main.py|-|-|delegate product writes
leading-parent-traversal|-|unscoped|../outside/secret.py|-|-|path traversal in file path
bare-parent-reference|-|unscoped|..|-|-|path traversal in file path
embedded-parent-traversal|-|unscoped|src/../../secret.py|-|-|path traversal in file path
trailing-parent-reference|-|unscoped|src/..|-|-|path traversal in file path
newline-in-path|-|unscoped|src/a\nb.py|-|-|newline in file path
CASES
}

@test "file-guard keeps exact allowances inside the canonical primary root" {
  while IFS='|' read -r label layout path; do
    [ -n "$label" ] || continue
    build_scenario python-engineer "link:$layout" </dev/null
    run timeout 2s bash "$SCRIPTS_DIR/file-guard.sh" <<< "$(payload "tool_name=Write" "tool_input.file_path=$path" "agent_id=dev-1")"
    expect_status "$label" 2
    expect_output_has "$label" "canonical primary root"
  done <<'CASES'
symlinked-target-outside-root|target-outside|hooks/skill_gate.py
symlinked-parent-outside-root|parent-outside|hooks/skill_gate.py
self-referential-symlink-ends-promptly|self-referential|hooks/skill_gate.py
absolute-path-outside-root|absolute|/elsewhere/hooks/skill_gate.py
CASES
}

@test "file-guard ignores calls that carry no file path and fails closed when jq is missing" {
  local no_jq_path="$TEST_TEMP_DIR/no-jq-bin"

  run run_raw_guard ''
  expect_status empty-stdin 0
  expect_output_empty empty-stdin

  run run_raw_guard '{"tool_name":"Write","tool_input":{}}'
  expect_status tool-input-without-path 0
  expect_output_empty tool-input-without-path

  mkdir -p "$no_jq_path"
  ln -s "$(command -v bash)" "$no_jq_path/bash"
  run env PATH="$no_jq_path" bash -c "printf '%s' '{}' | bash '$SCRIPTS_DIR/file-guard.sh'"
  expect_status jq-missing 2
  expect_output_has jq-missing "jq not available"
}

@test "file-guard stays registered for Write, Edit, and NotebookEdit" {
  run jq -e '
    .hooks.PreToolUse[]
    | select(.matcher == "Write|Edit|NotebookEdit")
    | .hooks[]
    | select(.command | contains("file-guard.sh"))
  ' "$PROJECT_ROOT/hooks/hooks.json"
  [ "$status" -eq 0 ]
}
