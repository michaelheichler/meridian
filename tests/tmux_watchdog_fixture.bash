#!/usr/bin/env bash

fixture_watchdog_bus() {
  local hash registry
  source "$REPO_ROOT/scripts/lib/meridian-control-root.sh"
  source "$REPO_ROOT/scripts/lib/tmux-runtime.sh"
  tmux_runtime_configure "$CONTROL_ROOT"
  tmux_runtime_ensure
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/inboxes"
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/outbox"
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/outbox/main"
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/transactions"
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/claims"
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/credentials"
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/heartbeats"
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/locks"
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

plant_bound_agent() {
  local target="$1" pane_id="$2" hash registry updated
  AGENT_CAPABILITY=$(tmux_runtime_capability)
  hash=$(tmux_runtime_capability_hash "$AGENT_CAPABILITY")
  registry=$(tmux_runtime_registry_read)
  updated=$(jq --arg target "$target" --arg pane "$pane_id" --arg hash "$hash" --argjson heartbeat 1 '
    .agents += [{
      agent_id: "agent-a",
      parent_id: .main.agent_id,
      contract_id: "contract-a",
      generated_name: "agent-a",
      tmux_target: $target,
      tmux_pane_id: (if $pane == "" then null else $pane end),
      claude_session_id: "agent-session",
      capability_hash: $hash,
      state: "running",
      heartbeat_at_ms: $heartbeat
    }]
    | .routes["agent-a"] = {inbox: "agent-a", tmux_target: $target}
  ' <<<"$registry")
  tmux_runtime_write_registry_route_bundle "$updated" || return 1
  tmux_runtime_initialize_inbox agent-a
}
