#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  SCRIPT="$REPO_ROOT/scripts/tmux-bus.sh"
  unset TMUX TMUX_PANE
  TEST_ROOT="$(mktemp -d)"
  use_control_root project
}

teardown() {
  rm -rf "$TEST_ROOT"
}

use_control_root() {
  PROJECT_ROOT="$TEST_ROOT/$1"
  CONTROL_ROOT="$PROJECT_ROOT/.lbwc-planning"
  mkdir -p "$CONTROL_ROOT"
  printf '%s\n' '{}' > "$CONTROL_ROOT/config.json"
}

bus_with_agent() {
  use_control_root "$1"
  fixture_bus
  plant_agent agent-a child-session-a
}

run_bus() {
  run bash "$SCRIPT" --control-root "$CONTROL_ROOT" "$@"
}

source_runtime() {
  source "$REPO_ROOT/scripts/lib/lbwc-control-root.sh"
  source "$REPO_ROOT/scripts/lib/tmux-runtime.sh"
  tmux_runtime_configure "$CONTROL_ROOT"
}

ensure_bus_layout() {
  tmux_runtime_ensure
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/inboxes"
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/outbox"
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/outbox/main"
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/transactions"
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/claims"
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/credentials"
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/heartbeats"
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/locks"
}

fixture_bus() {
  local hash registry
  source_runtime
  ensure_bus_layout
  MAIN_CAPABILITY=$(tmux_runtime_capability)
  hash=$(tmux_runtime_capability_hash "$MAIN_CAPABILITY")
  registry=$(jq -n --arg main main-session --arg hash "$hash" '{
    schema_version: 2,
    main: {agent_id: $main, session_id: $main, role: "orchestrator", capability_hash: $hash},
    tmux: {session: null, orchestrator_target: null, orchestrator_pane: null, topology: "pending", managed_session: false, ownership_token: null},
    agents: [],
    routes: {($main): {inbox: $main, tmux_target: null}}
  }')
  tmux_runtime_write_registry_route_bundle "$registry"
  tmux_runtime_initialize_inbox main-session
}

plant_agent() {
  local agent_id="$1" session_id="$2" hash registry updated
  AGENT_CAPABILITY=$(tmux_runtime_capability)
  hash=$(tmux_runtime_capability_hash "$AGENT_CAPABILITY")
  registry=$(tmux_runtime_registry_read)
  updated=$(jq --arg id "$agent_id" --arg session "$session_id" --arg hash "$hash" '
    .agents += [{
      agent_id: $id,
      parent_id: .main.agent_id,
      contract_id: "contract-1",
      generated_name: $id,
      tmux_target: "lbwc-test-main:0.1",
      tmux_pane_id: null,
      claude_session_id: $session,
      capability_hash: $hash,
      state: "registered",
      heartbeat_at_ms: null
    }]
    | .routes[$id] = {inbox: $id, tmux_target: "lbwc-test-main:0.1"}
  ' <<<"$registry")
  tmux_runtime_write_registry_route_bundle "$updated"
  tmux_runtime_initialize_inbox "$agent_id"
}

rewrite_json() {
  local path="$1" filter="$2"
  jq "$filter" "$path" > "$TEST_ROOT/rewrite.json"
  chmod 600 "$TEST_ROOT/rewrite.json"
  mv "$TEST_ROOT/rewrite.json" "$path"
}

agent_runs_stale() {
  run_bus stale --agent-id agent-a --session-id child-session-a --role agent --capability "$AGENT_CAPABILITY" --subject-agent-id agent-a --threshold-ms 1
}

agent_runs_compact() {
  run_bus compact --orchestrator-id agent-a --orchestrator-session-id child-session-a --orchestrator-capability "$AGENT_CAPABILITY" --retain 1
}

publish_main_job() {
  local recipient="$1"
  shift
  run_bus publish --to "$recipient" --from-agent-id main-session --from-session-id main-session --from-role orchestrator --capability "$MAIN_CAPABILITY" --type job --correlation-id contract-1 --payload '{"brief":"work"}' "$@"
}

@test "releasing one lock leaves the remaining acquired name" {
  source_runtime
  ensure_bus_layout
  tmux_runtime_lock_acquire first 5000 30000
  tmux_runtime_lock_acquire second 5000 30000
  [ "${#TMUX_RUNTIME_LOCKS[@]}" -eq 2 ]
  tmux_runtime_lock_release first
  [ "${#TMUX_RUNTIME_LOCKS[@]}" -eq 1 ]
  [ "${TMUX_RUNTIME_LOCKS[0]}" = second ]
  tmux_runtime_lock_release second
}

@test "init refuses to mint a registry without provision and requires the main capability once initialized" {
  run_bus init --main-id main-session --main-session-id main-session
  [ "$status" -ne 0 ]
  [[ "$output" == *"bus is not provisioned"* ]]
  [ ! -e "$CONTROL_ROOT/.runtime/tmux-bus/registry.json" ]

  fixture_bus
  run_bus init --main-id main-session --main-session-id main-session
  [ "$status" -ne 0 ]
  [[ "$output" == *"session and capability"* ]]
  run_bus init --main-id main-session --main-session-id main-session --orchestrator-capability "$MAIN_CAPABILITY"
  [ "$status" -eq 0 ]
  run jq -e '.schema_version == 2 and .main.agent_id == "main-session" and .routes["main-session"].inbox == "main-session"' "$CONTROL_ROOT/.runtime/tmux-bus/registry.json"
  [ "$status" -eq 0 ]
}

bus_case_malformed_registry_keeps_live_files() {
  local runtime_bus
  use_control_root malformed-registry
  fixture_bus
  runtime_bus="$CONTROL_ROOT/.runtime/tmux-bus"
  cp "$runtime_bus/registry.json" "$TEST_ROOT/registry-before.json"
  cp "$runtime_bus/routing-table.json" "$TEST_ROOT/routing-before.json"
  printf '%s\n' '{not valid json' > "$runtime_bus/registry.json"
  chmod 600 "$runtime_bus/registry.json"
  run_bus routing-refresh --orchestrator-id main-session --orchestrator-session-id main-session --orchestrator-capability "$MAIN_CAPABILITY"
  [ "$status" -ne 0 ]
  [ "$(cat "$runtime_bus/registry.json")" = '{not valid json' ]
  cmp "$TEST_ROOT/routing-before.json" "$runtime_bus/routing-table.json"
}

bus_case_poll_rejects_shared_registry() {
  bus_with_agent shared-registry
  chmod 644 "$CONTROL_ROOT/.runtime/tmux-bus/registry.json"
  run_bus poll --from agent-a --agent-id main-session --session-id main-session --role orchestrator --capability "$MAIN_CAPABILITY" --types result
  [ "$status" -ne 0 ]
  [[ "$output" == *"private file"* ]]
}

@test "a malformed or non-private registry fails closed without rewriting live files" {
  bus_case_malformed_registry_keeps_live_files
  bus_case_poll_rejects_shared_registry
}

bus_case_principals_deliver_replies_to_main() {
  local result_id
  bus_with_agent principal-replies
  run_bus publish --to main-session --from-agent-id agent-a --from-session-id child-session-a --from-role agent --capability "$AGENT_CAPABILITY" --type result --correlation-id contract-1 --payload '{"result":"done"}'
  [ "$status" -eq 0 ]
  result_id="$output"
  run jq -e --arg message_id "$result_id" '.message_id == $message_id and .from.agent_id == "agent-a" and .to.agent_id == "main-session"' "$CONTROL_ROOT/.runtime/tmux-bus/inboxes/main-session/result.json"
  [ "$status" -eq 0 ]
  run_bus publish --to main-session --from-agent-id agent-a --from-session-id child-session-a --from-role agent --capability "$MAIN_CAPABILITY" --type shutdown_response --correlation-id contract-1 --payload '{}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"principal session, role, or capability"* ]]
}

bus_case_publish_records_transaction() {
  local message_id
  bus_with_agent publish-transaction
  publish_main_job agent-a
  [ "$status" -eq 0 ]
  message_id="$output"
  run jq -e --arg message_id "$message_id" '.message_id == $message_id and .state == "committed"' "$CONTROL_ROOT/.runtime/tmux-bus/transactions/$message_id.json"
  [ "$status" -eq 0 ]
  [ -f "$CONTROL_ROOT/.runtime/tmux-bus/inboxes/agent-a/job.json" ]
  [ -f "$CONTROL_ROOT/.runtime/tmux-bus/outbox/main/$message_id.json" ]
}

bus_case_publish_rejects_incomplete_job_body() {
  bus_with_agent incomplete-job-body
  run_bus publish --to agent-a --from-agent-id main-session --from-session-id main-session --from-role orchestrator --capability "$MAIN_CAPABILITY" --type job --correlation-id invalid-body --payload '{}'
  [ "$status" -ne 0 ]
  [ ! -e "$CONTROL_ROOT/.runtime/tmux-bus/inboxes/agent-a/job.json" ]
}

bus_case_symlinked_inbox_cannot_redirect() {
  bus_with_agent symlinked-inbox
  rm -rf "$CONTROL_ROOT/.runtime/tmux-bus/inboxes/agent-a"
  mkdir "$TEST_ROOT/outside-inbox"
  ln -s "$TEST_ROOT/outside-inbox" "$CONTROL_ROOT/.runtime/tmux-bus/inboxes/agent-a"
  publish_main_job agent-a
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_ROOT/outside-inbox/job.json" ]
}

bus_case_concurrent_publish_serializes() {
  bus_with_agent concurrent-publish
  run env CONTROL_ROOT="$CONTROL_ROOT" SCRIPT="$SCRIPT" MAIN_CAPABILITY="$MAIN_CAPABILITY" bash -c '
    bash "$SCRIPT" --control-root "$CONTROL_ROOT" publish --to agent-a --from-agent-id main-session --from-session-id main-session --from-role orchestrator --capability "$MAIN_CAPABILITY" --type job --correlation-id one --payload "{\"brief\":\"one\",\"n\":1}" &
    first=$!
    bash "$SCRIPT" --control-root "$CONTROL_ROOT" publish --to agent-a --from-agent-id main-session --from-session-id main-session --from-role orchestrator --capability "$MAIN_CAPABILITY" --type job --correlation-id two --payload "{\"brief\":\"two\",\"n\":2}" &
    second=$!
    wait "$first"; first_status=$?
    wait "$second"; second_status=$?
    { [ "$first_status" -eq 0 ] && [ "$second_status" -ne 0 ]; } || { [ "$first_status" -ne 0 ] && [ "$second_status" -eq 0 ]; }
  '
  [ "$status" -eq 0 ]
  run jq -e '.schema_version == 1 and (.body.n | IN(1, 2))' "$CONTROL_ROOT/.runtime/tmux-bus/inboxes/agent-a/job.json"
  [ "$status" -eq 0 ]
}

bus_case_publish_backpressure_or_timeout() {
  local first_id ack_watcher
  bus_with_agent publish-backpressure
  publish_main_job agent-a
  [ "$status" -eq 0 ]
  first_id="$output"
  run_bus claim --agent-id agent-a --session-id child-session-a --capability "$AGENT_CAPABILITY" --type job --lease-ms 1000
  [ "$status" -eq 0 ]
  env SCRIPT="$SCRIPT" CONTROL_ROOT="$CONTROL_ROOT" CAPABILITY="$AGENT_CAPABILITY" MESSAGE_ID="$first_id" LOCK="$CONTROL_ROOT/.runtime/tmux-bus/locks/delivery.agent-a.job.lock" bash -c '
    for ((attempt = 0; attempt < 1000; attempt++)); do
      [ -e "$LOCK" ] && break
      sleep 0.005
    done
    [ -e "$LOCK" ] || exit 1
    bash "$SCRIPT" --control-root "$CONTROL_ROOT" ack --agent-id agent-a --session-id child-session-a --capability "$CAPABILITY" --message-id "$MESSAGE_ID" >/dev/null' &
  ack_watcher=$!
  publish_main_job agent-a --timeout-ms 5000
  [ "$status" -eq 0 ]
  wait "$ack_watcher"
  [ -f "$CONTROL_ROOT/.runtime/tmux-bus/inboxes/agent-a/acked/$first_id.json" ]
  run_bus publish --to agent-a --from-agent-id main-session --from-session-id main-session --from-role orchestrator --capability "$MAIN_CAPABILITY" --type job --correlation-id blocked --payload '{}' --timeout-ms 500
  [ "$status" -ne 0 ]
  [[ "$output" == *"timed out waiting"* ]]
}

@test "publish delivers through a recorded transaction, authenticates principals, serializes one inbox and honours backpressure" {
  bus_case_principals_deliver_replies_to_main
  bus_case_publish_records_transaction
  bus_case_publish_rejects_incomplete_job_body
  bus_case_symlinked_inbox_cannot_redirect
  bus_case_concurrent_publish_serializes
  bus_case_publish_backpressure_or_timeout
}

@test "recover completes a prepared delivery transaction idempotently" {
  bus_with_agent recover
  publish_main_job agent-a
  [ "$status" -eq 0 ]
  message_id="$output"
  rm "$CONTROL_ROOT/.runtime/tmux-bus/outbox/main/$message_id.json"
  rewrite_json "$CONTROL_ROOT/.runtime/tmux-bus/transactions/$message_id.json" '.state = "prepared"'

  run_bus recover --orchestrator-id main-session --orchestrator-session-id main-session --orchestrator-capability "$MAIN_CAPABILITY" --message-id "$message_id"
  [ "$status" -eq 0 ]
  [ -f "$CONTROL_ROOT/.runtime/tmux-bus/outbox/main/$message_id.json" ]
  run_bus recover --orchestrator-id main-session --orchestrator-session-id main-session --orchestrator-capability "$MAIN_CAPABILITY" --message-id "$message_id"
  [ "$status" -eq 0 ]

  rewrite_json "$CONTROL_ROOT/.runtime/tmux-bus/transactions/$message_id.json" 'del(.envelope.from.session_id)'
  run_bus recover --orchestrator-id main-session --orchestrator-session-id main-session --orchestrator-capability "$MAIN_CAPABILITY" --message-id "$message_id"
  [ "$status" -ne 0 ]
  [[ "$output" == *"envelope is malformed"* ]]
}

bus_case_main_consumes_sender_result() {
  local result_id
  bus_with_agent main-consumes-result
  run_bus publish --to main-session --from-agent-id agent-a --from-session-id child-session-a --from-role agent --capability "$AGENT_CAPABILITY" --type result --correlation-id contract-1 --payload '{"result":"done"}'
  [ "$status" -eq 0 ]
  result_id="$output"
  run_bus poll --from agent-a --agent-id main-session --session-id main-session --role orchestrator --capability "$MAIN_CAPABILITY" --types result
  [ "$status" -eq 0 ]
  [ "$(jq -r '.message_id' <<<"$output")" = "$result_id" ]
  run_bus claim --agent-id main-session --session-id main-session --capability "$MAIN_CAPABILITY" --type result --lease-ms 1000
  [ "$status" -eq 0 ]
  run_bus ack --agent-id main-session --session-id main-session --capability "$MAIN_CAPABILITY" --message-id "$result_id"
  [ "$status" -eq 0 ]
}

bus_case_await_honors_millisecond_timeout() {
  local start_ms end_ms
  bus_with_agent await-timeout
  start_ms="$(perl -MTime::HiRes=time -e 'printf "%.0f", time * 1000')"
  run_bus await --from agent-a --agent-id main-session --session-id main-session --role orchestrator --capability "$MAIN_CAPABILITY" --types result --timeout-ms 30
  end_ms="$(perl -MTime::HiRes=time -e 'printf "%.0f", time * 1000')"
  [ "$status" -eq 1 ]
  [ $((end_ms - start_ms)) -lt 10000 ]
}

bus_case_poll_without_principal_prints_usage() {
  bus_with_agent poll-usage
  run_bus poll --from agent-a --types result
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* ]]
}

bus_case_poll_rejects_bad_sent_at() {
  local label filter inbox_job
  bus_with_agent bad-sent-at
  inbox_job="$CONTROL_ROOT/.runtime/tmux-bus/inboxes/agent-a/job.json"
  while IFS='|' read -r label filter; do
    [ -n "$label" ] || continue
    rm -f "$inbox_job"
    publish_main_job agent-a
    [ "$status" -eq 0 ] || { echo "case=$label publish status=$status output=$output" >&2; return 1; }
    rewrite_json "$inbox_job" "$filter"
    run_bus poll --from agent-a --agent-id agent-a --session-id child-session-a --role agent --capability "$AGENT_CAPABILITY" --types job
    [ "$status" -ne 0 ] || { echo "case=$label poll accepted status=$status output=$output" >&2; return 1; }
    [[ "$output" == *"malformed message"* ]] || { echo "case=$label output=$output" >&2; return 1; }
  done <<'CASES'
missing-sent-at|del(.sent_at)
impossible-calendar-date|.sent_at = "2026-02-30T12:00:00Z"
CASES
}

@test "poll and await consume one sender's messages, honour millisecond timeouts, and reject usage errors or malformed envelopes" {
  bus_case_main_consumes_sender_result
  bus_case_await_honors_millisecond_timeout
  bus_case_poll_without_principal_prints_usage
  bus_case_poll_rejects_bad_sent_at
}

bus_case_concurrent_claim_gives_one_lease() {
  local message_id
  bus_with_agent concurrent-claim
  publish_main_job agent-a
  [ "$status" -eq 0 ]
  message_id="$output"
  run env CONTROL_ROOT="$CONTROL_ROOT" SCRIPT="$SCRIPT" AGENT_CAPABILITY="$AGENT_CAPABILITY" bash -c '
    bash "$SCRIPT" --control-root "$CONTROL_ROOT" claim --agent-id agent-a --session-id child-session-a --capability "$AGENT_CAPABILITY" --type job --lease-ms 1000 >/dev/null &
    first=$!
    bash "$SCRIPT" --control-root "$CONTROL_ROOT" claim --agent-id agent-a --session-id child-session-a --capability "$AGENT_CAPABILITY" --type job --lease-ms 1000 >/dev/null &
    second=$!
    wait "$first"; first_status=$?
    wait "$second"; second_status=$?
    { [ "$first_status" -eq 0 ] && [ "$second_status" -ne 0 ]; } || { [ "$first_status" -ne 0 ] && [ "$second_status" -eq 0 ]; }
  '
  [ "$status" -eq 0 ]
  run_bus ack --agent-id agent-a --session-id child-session-a --capability "$AGENT_CAPABILITY" --message-id "$message_id"
  [ "$status" -eq 0 ]
  [ -f "$CONTROL_ROOT/.runtime/tmux-bus/inboxes/agent-a/acked/$message_id.json" ]
  [ ! -e "$CONTROL_ROOT/.runtime/tmux-bus/claims/agent-a.job.claim" ]
}

bus_case_dead_owner_claim_reclaimed() {
  local message_id claim
  bus_with_agent dead-owner-claim
  publish_main_job agent-a
  [ "$status" -eq 0 ]
  message_id="$output"
  claim="$CONTROL_ROOT/.runtime/tmux-bus/claims/agent-a.job.claim"
  mkdir "$claim"
  chmod 700 "$claim"
  printf '%s\n' "{\"message_id\":\"$message_id\",\"agent_id\":\"agent-a\",\"session_id\":\"child-session-a\",\"pid\":99999999,\"acquired_at_ms\":1,\"lease_ms\":1}" > "$claim/owner.json"
  chmod 600 "$claim/owner.json"
  run_bus claim --agent-id agent-a --session-id child-session-a --capability "$AGENT_CAPABILITY" --type job --lease-ms 1000
  [ "$status" -eq 0 ]
  printf '%s\n' '{bad json' > "$claim/owner.json"
  run_bus ack --agent-id agent-a --session-id child-session-a --capability "$AGENT_CAPABILITY" --message-id "$message_id"
  [ "$status" -ne 0 ]
  [ -f "$CONTROL_ROOT/.runtime/tmux-bus/inboxes/agent-a/job.json" ]
}

bus_case_ack_rejects_symlinked_acked_dir() {
  local message_id
  bus_with_agent symlinked-acked
  publish_main_job agent-a
  [ "$status" -eq 0 ]
  message_id="$output"
  run_bus claim --agent-id agent-a --session-id child-session-a --capability "$AGENT_CAPABILITY" --type job --lease-ms 1000
  [ "$status" -eq 0 ]
  rm -rf "$CONTROL_ROOT/.runtime/tmux-bus/inboxes/agent-a/acked"
  mkdir "$TEST_ROOT/outside-acked"
  ln -s "$TEST_ROOT/outside-acked" "$CONTROL_ROOT/.runtime/tmux-bus/inboxes/agent-a/acked"
  run_bus ack --agent-id agent-a --session-id child-session-a --capability "$AGENT_CAPABILITY" --message-id "$message_id"
  [ "$status" -ne 0 ]
  [ -f "$CONTROL_ROOT/.runtime/tmux-bus/inboxes/agent-a/job.json" ]
  [ ! -e "$TEST_ROOT/outside-acked/$message_id.json" ]
}

bus_case_descriptor_move_never_clobbers() {
  local helper root
  bus_with_agent descriptor-move
  helper="$REPO_ROOT/scripts/lib/tmux-private-fs.py"
  root="$CONTROL_ROOT/.runtime/tmux-bus"
  printf '%s\n' '{"source":"one"}' > "$root/inboxes/agent-a/job.json"
  chmod 600 "$root/inboxes/agent-a/job.json"
  printf '%s\n' '{"source":"two"}' > "$root/inboxes/agent-a/result.json"
  chmod 600 "$root/inboxes/agent-a/result.json"
  run env ROOT="$root" HELPER="$helper" bash -c '
    python3 "$HELPER" move --root "$ROOT" --source inboxes/agent-a/job.json --destination inboxes/agent-a/acked/race.json &
    first=$!
    python3 "$HELPER" move --root "$ROOT" --source inboxes/agent-a/result.json --destination inboxes/agent-a/acked/race.json &
    second=$!
    wait "$first"; first_status=$?
    wait "$second"; second_status=$?
    { [ "$first_status" -eq 0 ] && [ "$second_status" -ne 0 ]; } || { [ "$first_status" -ne 0 ] && [ "$second_status" -eq 0 ]; }
  '
  [ "$status" -eq 0 ]
  [ -f "$root/inboxes/agent-a/acked/race.json" ]
  [ -e "$root/inboxes/agent-a/job.json" ] || [ -e "$root/inboxes/agent-a/result.json" ]
}

bus_case_ack_resumes_interrupted_states() {
  local message_id
  bus_with_agent ack-resume
  publish_main_job agent-a
  [ "$status" -eq 0 ]
  message_id="$output"
  run_bus claim --agent-id agent-a --session-id child-session-a --capability "$AGENT_CAPABILITY" --type job --lease-ms 1000
  [ "$status" -eq 0 ]
  run env LBWC_TMUX_FS_FAIL_AFTER_ACK_LINK=1 bash "$SCRIPT" --control-root "$CONTROL_ROOT" ack --agent-id agent-a --session-id child-session-a --capability "$AGENT_CAPABILITY" --message-id "$message_id"
  [ "$status" -ne 0 ]
  [ -f "$CONTROL_ROOT/.runtime/tmux-bus/inboxes/agent-a/job.json" ]
  [ -f "$CONTROL_ROOT/.runtime/tmux-bus/inboxes/agent-a/acked/$message_id.json" ]
  run_bus ack --agent-id agent-a --session-id child-session-a --capability "$AGENT_CAPABILITY" --message-id "$message_id"
  [ "$status" -eq 0 ]
  [ ! -e "$CONTROL_ROOT/.runtime/tmux-bus/inboxes/agent-a/job.json" ]
  [ ! -e "$CONTROL_ROOT/.runtime/tmux-bus/claims/agent-a.job.claim" ]
  mkdir "$CONTROL_ROOT/.runtime/tmux-bus/claims/agent-a.result.claim"
  chmod 700 "$CONTROL_ROOT/.runtime/tmux-bus/claims/agent-a.result.claim"
  printf '%s\n' "{\"message_id\":\"$message_id\",\"agent_id\":\"agent-a\",\"session_id\":\"child-session-a\"}" > "$CONTROL_ROOT/.runtime/tmux-bus/claims/agent-a.result.claim/owner.json"
  chmod 600 "$CONTROL_ROOT/.runtime/tmux-bus/claims/agent-a.result.claim/owner.json"
  run_bus ack --agent-id agent-a --session-id child-session-a --capability "$AGENT_CAPABILITY" --message-id "$message_id"
  [ "$status" -eq 0 ]
  [ ! -e "$CONTROL_ROOT/.runtime/tmux-bus/claims/agent-a.result.claim" ]
}

@test "claim grants one lease and ack moves messages safely, resumes interruptions and rejects unsafe state" {
  bus_case_concurrent_claim_gives_one_lease
  bus_case_dead_owner_claim_reclaimed
  bus_case_ack_rejects_symlinked_acked_dir
  bus_case_descriptor_move_never_clobbers
  bus_case_ack_resumes_interrupted_states
}

bus_case_heartbeat_epoch_and_stale() {
  bus_with_agent heartbeat-stale
  run_bus heartbeat --agent-id agent-a --session-id child-session-a --capability "$AGENT_CAPABILITY" --state idle
  [ "$status" -eq 0 ]
  run jq -e '.agents[0].state == "idle" and (.agents[0].heartbeat_at_ms > 1000000000000)' "$CONTROL_ROOT/.runtime/tmux-bus/registry.json"
  [ "$status" -eq 0 ]
  run jq -e '.from.agent_id == "agent-a" and .to.agent_id == "main-session" and .type == "heartbeat" and .body.state == "idle"' "$CONTROL_ROOT/.runtime/tmux-bus/inboxes/main-session/heartbeat.agent-a.json"
  [ "$status" -eq 0 ]
  run_bus stale --agent-id main-session --session-id main-session --role orchestrator --capability "$MAIN_CAPABILITY" --subject-agent-id agent-a --threshold-ms 10000
  [ "$status" -eq 0 ]
  rewrite_json "$CONTROL_ROOT/.runtime/tmux-bus/registry.json" '.agents[0].heartbeat_at_ms = 1'
  run_bus stale --agent-id main-session --session-id main-session --role orchestrator --capability "$MAIN_CAPABILITY" --subject-agent-id agent-a --threshold-ms 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"stale"* ]]
}

bus_case_heartbeat_keeps_failed_agents_failed() {
  bus_with_agent heartbeat-failed
  run_bus heartbeat --agent-id agent-a --session-id child-session-a --capability "$AGENT_CAPABILITY" --state running
  [ "$status" -eq 0 ]
  rewrite_json "$CONTROL_ROOT/.runtime/tmux-bus/registry.json" '.agents[0].state = "failed"'
  run_bus heartbeat --agent-id agent-a --session-id child-session-a --capability "$AGENT_CAPABILITY" --state running
  [ "$status" -ne 0 ]
  [[ "$output" == *"terminal lifecycle state"* ]]
  run jq -e '.agents[] | select(.agent_id == "agent-a") | .state == "failed"' "$CONTROL_ROOT/.runtime/tmux-bus/registry.json"
  [ "$status" -eq 0 ]
}

bus_case_heartbeat_shutdown_drops_route() {
  bus_with_agent heartbeat-shutdown
  run_bus heartbeat --agent-id agent-a --session-id child-session-a --capability "$AGENT_CAPABILITY" --state shutdown
  [ "$status" -eq 0 ]
  run jq -e '.agents[] | select(.agent_id == "agent-a") | .state == "shutdown"' "$CONTROL_ROOT/.runtime/tmux-bus/registry.json"
  [ "$status" -eq 0 ]
  run jq -e '.routes | keys | sort == ["main-session"]' "$CONTROL_ROOT/.runtime/tmux-bus/registry.json"
  [ "$status" -eq 0 ]
  run jq -e '.routes | keys | sort == ["main-session"]' "$CONTROL_ROOT/.runtime/tmux-bus/routing-table.json"
  [ "$status" -eq 0 ]
}

bus_case_main_reads_requested_heartbeat() {
  local agent_a_capability agent_b_capability
  bus_with_agent requested-heartbeat
  agent_a_capability="$AGENT_CAPABILITY"
  plant_agent agent-b child-session-b
  agent_b_capability="$AGENT_CAPABILITY"
  run_bus heartbeat --agent-id agent-a --session-id child-session-a --capability "$agent_a_capability" --state idle
  [ "$status" -eq 0 ]
  run_bus heartbeat --agent-id agent-b --session-id child-session-b --capability "$agent_b_capability" --state running
  [ "$status" -eq 0 ]
  run_bus poll --from agent-a --agent-id main-session --session-id main-session --role orchestrator --capability "$MAIN_CAPABILITY" --types heartbeat
  [ "$status" -eq 0 ]
  run jq -e '.from.agent_id == "agent-a" and .to.agent_id == "main-session" and .type == "heartbeat"' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "heartbeat records epoch milliseconds for stale checks, keeps terminal states, drops shutdown routes, and reaches main per agent" {
  bus_case_heartbeat_epoch_and_stale
  bus_case_heartbeat_keeps_failed_agents_failed
  bus_case_heartbeat_shutdown_drops_route
  bus_case_main_reads_requested_heartbeat
}

bus_case_non_main_principal_rejected() {
  local label
  bus_with_agent non-main-principal
  for label in agent_runs_stale agent_runs_compact; do
    "$label"
    [ "$status" -ne 0 ] || { echo "case=$label accepted output=$output" >&2; return 1; }
    [[ "$output" == *"principal session, role, or capability"* || "$output" == *"main orchestrator"* ]] || { echo "case=$label output=$output" >&2; return 1; }
  done
}

bus_case_compact_retains_newest() {
  local helper acked
  bus_with_agent compact-retain
  helper="$REPO_ROOT/scripts/lib/tmux-private-fs.py"
  acked="$CONTROL_ROOT/.runtime/tmux-bus/inboxes/agent-a/acked"
  python3 "$helper" write-json --root "$CONTROL_ROOT/.runtime/tmux-bus" --relative "inboxes/agent-a/acked/old.json" --document '{"n":1}'
  python3 "$helper" write-json --root "$CONTROL_ROOT/.runtime/tmux-bus" --relative "inboxes/agent-a/acked/name with spaces.json" --document '{"n":2}'
  python3 "$helper" write-json --root "$CONTROL_ROOT/.runtime/tmux-bus" --relative "inboxes/agent-a/acked/newest.json" --document '{"n":3}'
  touch -t 202001010000 "$acked/old.json"
  touch -t 202001010001 "$acked/name with spaces.json"
  touch -t 202001010002 "$acked/newest.json"
  run_bus compact --orchestrator-id main-session --orchestrator-session-id main-session --orchestrator-capability "$MAIN_CAPABILITY" --retain 2
  [ "$status" -eq 0 ]
  [ ! -e "$acked/old.json" ]
  [ -f "$acked/name with spaces.json" ]
  [ -f "$acked/newest.json" ]
}

@test "stale and compact reject a non-main principal and compact retains the newest json files including names with spaces" {
  bus_case_non_main_principal_rejected
  bus_case_compact_retains_newest
}
