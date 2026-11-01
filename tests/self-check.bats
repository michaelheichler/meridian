#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load test_helper

setup() {
  WORK="$(mktemp -d)"
  WORK="$(cd "$WORK" && pwd -P)"
  mkdir -p "$WORK/scripts/lib" "$WORK/.lbwc-planning" "$WORK/templates/agent-roles" "$WORK/.claude/agents"
  local script
  for script in agent-spawn-guard agent-lifecycle task-contract claude-capabilities; do
    copy_script_with_libs "$SCRIPTS_DIR/$script.sh" "$WORK/scripts/$script.sh"
  done
  cp "$PROJECT_ROOT/templates/agent-roles/defaults.json" "$WORK/templates/agent-roles/defaults.json"
  cp "$BATS_TEST_DIRNAME/fixture-agent-manifest.sh" "$WORK/scripts/lib/agent-manifest.sh"
  chmod +x "$WORK/scripts/agent-spawn-guard.sh" "$WORK/scripts/agent-lifecycle.sh" "$WORK/scripts/task-contract.sh"
  MANIFEST="$WORK/.lbwc-planning/.agent-manifest.json"
  use_claude_fixture "$WORK/host-claude"
}

teardown() {
  rm -rf "$WORK"
}

issue_dispatched_contract() {
  local slug="$1" command_name="$2" role="$3" team="$4" job="$5" contract_path contract_id
  contract_path=$(bash "$WORK/scripts/task-contract.sh" issue "$WORK" "$slug" --command "$command_name" --role "$role" --team "$team" --job "$job")
  contract_id=$(jq -r '.contract_id' "$contract_path")
  bash "$WORK/scripts/task-contract.sh" state "$WORK" "$contract_id" dispatched >/dev/null
  printf '%s\n' "$contract_path"
}

write_pair_manifest() {
  local pair_contract solo_contract
  pair_contract=$(issue_dispatched_contract pair-fixture build python-engineer pair "pair fixture")
  solo_contract=$(issue_dispatched_contract scout-fixture research scout solo "scout fixture")
  jq -n --arg root "$WORK" \
    --arg pair_contract "$pair_contract" --arg pair_id "$(jq -r '.contract_id' "$pair_contract")" --arg pair_digest "$(jq -r '.contract_digest' "$pair_contract")" \
    --arg solo_contract "$solo_contract" --arg solo_id "$(jq -r '.contract_id' "$solo_contract")" --arg solo_digest "$(jq -r '.contract_digest' "$solo_contract")" '{
    agents: {
      "lbwc-dev-a": {name:"lbwc-dev-a", role:"python-engineer", state:"registered", pair_id:"p1", pair_role:"engineer", project_root:$root, write_allowances:[], contract_enabled:true, contract_path:$pair_contract, contract_id:$pair_id, contract_digest:$pair_digest, task_identity:$pair_id, model:"sonnet", maxTurns:40, permissionMode:"default", created_at:"2026-08-06T00:00:00Z"},
      "lbwc-critic-a": {name:"lbwc-critic-a", role:"python-critic", state:"registered", pair_id:"p1", pair_role:"critic", project_root:$root, write_allowances:[], contract_enabled:true, contract_path:$pair_contract, contract_id:$pair_id, contract_digest:$pair_digest, task_identity:$pair_id, model:"sonnet", maxTurns:40, permissionMode:"default", created_at:"2026-08-06T00:00:00Z"},
      "lbwc-scout-x": {name:"lbwc-scout-x", role:"scout", state:"registered", pair_id:null, pair_role:null, project_root:$root, write_allowances:[], contract_enabled:true, contract_path:$solo_contract, contract_id:$solo_id, contract_digest:$solo_digest, task_identity:$solo_id, created_at:"2026-08-06T00:00:00Z"}
    }
  }' > "$MANIFEST"
}

spawn_guard() {
  local agent="$1"
  cd "$WORK" || return 1
  printf '{"tool_name":"Agent","tool_input":{"subagent_type":"%s"}}' "$agent" | bash scripts/agent-spawn-guard.sh
}

@test "spawn guard blocks an unrelated role while a pair is open" {
  write_pair_manifest
  local before
  before=$(cksum < "$MANIFEST")

  run -2 --separate-stderr spawn_guard lbwc-scout-x

  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Pair p1 "*"is open, spawn every member before starting other work."* ]]
  [ "$(cksum < "$MANIFEST")" = "$before" ]
}

@test "spawn guard allows the paired name and flips its manifest entry to running" {
  write_pair_manifest

  run -0 spawn_guard lbwc-dev-a

  [ "$status" -eq 0 ]
  [ "$(jq -r '.agents["lbwc-dev-a"].state' "$MANIFEST")" = "running" ]
}

@test "touch stop marks the entry used by exact name and keeps the rendered agent definition" {
  jq -n '{agents: {"lbwc-dev-random-suffix": {name:"lbwc-dev-random-suffix", role:"engineer", state:"running", created_at:"2026-08-06T00:00:00Z", last_activity_at:"2026-08-06T00:00:00Z"}}}' > "$MANIFEST"
  local deffile="$WORK/.claude/agents/lbwc-dev-random-suffix.md"
  printf 'placeholder\n' > "$deffile"

  cd "$WORK"
  run bash -c "echo '{\"hook_event_name\":\"SubagentStop\",\"agent_type\":\"lbwc-dev-random-suffix\"}' | bash scripts/agent-lifecycle.sh touch stop"

  [ "$status" -eq 0 ]
  [ "$(jq -r '.agents["lbwc-dev-random-suffix"].state' "$MANIFEST")" = "used" ]
  [ -f "$deffile" ]
}

@test "sweep expires a registered entry older than one hour and keeps the rendered agent definition" {
  jq -n '{agents: {"lbwc-scout-stale": {name:"lbwc-scout-stale", role:"scout", state:"registered", created_at:"2020-01-01T00:00:00Z"}}}' > "$MANIFEST"
  local deffile="$WORK/.claude/agents/lbwc-scout-stale.md"
  printf 'placeholder\n' > "$deffile"

  cd "$WORK"
  run bash scripts/agent-lifecycle.sh sweep

  [ "$status" -eq 0 ]
  [ "$(jq -r '.agents["lbwc-scout-stale"].state' "$MANIFEST")" = "expired" ]
  [ -f "$deffile" ]
}
